#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "json_schemer"
require "minitest/autorun"
require "open3"
require "tmpdir"

HELPER = File.expand_path("task-review-loop", __dir__)
FIXTURES = File.expand_path("../fixtures/task-review-loop-replays.json", __dir__)
SCHEMA = File.expand_path("../../../docs/schemas/task-review-loop-v1.schema.json", __dir__)
BASE_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_SHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
FIX_HEAD_SHA = "cccccccccccccccccccccccccccccccccccccccc"
OTHER_HEAD_SHA = "dddddddddddddddddddddddddddddddddddddddd"

class TaskReviewLoopTest < Minitest::Test
  def test_schema_is_closed_and_accepts_the_clean_contract
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      validator = JSONSchemer.schema(JSON.parse(File.read(SCHEMA, encoding: "UTF-8")))

      assert validator.valid?(input)
      refute validator.valid?(input.merge("unexpected" => true))
    end
  end

  def test_reducer_rejects_fields_outside_the_closed_contract
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory).merge("unexpected" => true)
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      refute output.fetch("dependent_task_permitted")
      assert_equal ["input-schema-invalid"], output.fetch("reasons")
    end
  end

  def test_reducer_enforces_the_closed_schema_without_an_external_schema_runtime
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory).merge("review_state" => "UNKNOWN")
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["input-schema-invalid"], output.fetch("reasons")
    end
  end

  def test_clean_review_completes_the_task_and_permits_dependents
    replay = replay_case("clean-review")

    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      output, first_stdout = evaluate(input)
      replayed_output, second_stdout = evaluate(input)

      assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys)
      assert_equal output, replayed_output
      assert_equal first_stdout, second_stdout
    end
  end

  def test_current_initial_package_is_review_eligible
    replay = replay_case("review-eligible")

    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory).merge(
        "review_state" => "pending",
        "rounds" => [],
        "open_findings" => nil
      )
      output, = evaluate(input)

      assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys)
    end
  end

  def test_addressed_finding_with_consequential_fix_breakage_requires_another_fix
    replay = replay_case("addressed-finding-with-consequential-breakage")

    Dir.mktmpdir("task-review-loop") do |directory|
      output, = evaluate(consequential_breakage_input(directory))

      assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys)
    end
  end

  def test_stale_truncated_and_foreign_packages_fail_closed
    Dir.mktmpdir("task-review-loop") do |directory|
      base_input = clean_review_input(directory)
      foreign_identity = base_input.fetch("identity").merge("task_id" => "foreign-task")
      variants = {
        "stale-package" => base_input.merge("expected_current_head_sha" => OTHER_HEAD_SHA),
        "truncated-package" => rebind_package(
          base_input,
          "exact_diff" => base_input.dig("review_package", "exact_diff").merge("truncated" => true)
        ),
        "foreign-package" => rebind_package(base_input, "identity" => foreign_identity)
      }

      variants.each do |name, input|
        replay = replay_case(name)
        output, = evaluate(input)
        assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys), name
      end
    end
  end

  def test_worker_replacement_requires_fenced_evidence
    replay = replay_case("worker-replacement-evidence")

    Dir.mktmpdir("task-review-loop") do |directory|
      input = replacement_input(directory)
      missing_output, = evaluate(input)
      evidenced_output, = evaluate(
        input.merge(
          "replacement_evidence" => [{
            "round" => 1,
            "prior_implementer_id" => "implementer-a",
            "replacement_implementer_id" => "implementer-c",
            "reason" => "continuation_unavailable",
            "prior_instance_stopped" => true,
            "ownership_reconciled" => true,
            "evidence" => ["coordination://issue-392/replacement-1"]
          }]
        )
      )

      assert_equal "blocked", missing_output.fetch("status")
      assert_includes missing_output.fetch("reasons"), "worker-replacement-evidence-required"
      assert_equal replay.fetch("expected"), evidenced_output.slice(*replay.fetch("expected").keys)
    end
  end

  def test_five_round_cap_requires_complete_evidence_backed_adjudication_and_has_no_sixth_round
    replay = replay_case("five-round-cap-adjudicated")

    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      missing_output, = evaluate(input.merge("cap_adjudication" => nil))
      output, = evaluate(input)
      sixth_output, = evaluate(input.merge("rounds" => input.fetch("rounds") + [input.fetch("rounds").last]))

      assert_equal "blocked", missing_output.fetch("status")
      assert_includes missing_output.fetch("reasons"), "cap-adjudication-required"
      assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys)
      assert_equal "blocked", sixth_output.fetch("status")
      assert_includes sixth_output.fetch("reasons"), "round-cap-exceeded"
    end
  end

  def test_p0_cap_piercing_and_load_bearing_findings_block_progress_at_the_cap
    Dir.mktmpdir("task-review-loop") do |directory|
      base_input = cap_input(directory)
      variants = {
        "p0-cap-blocker" => cap_with_p0(base_input, directory),
        "cap-piercing-blocker" => base_input.merge(
          "finding_controls" => [{ "finding_id" => "finding-2", "load_bearing" => false, "cap_piercing" => true }]
        ),
        "load-bearing-blocker" => base_input.merge(
          "finding_controls" => [{ "finding_id" => "finding-2", "load_bearing" => true, "cap_piercing" => false }]
        )
      }

      variants.each do |name, input|
        replay = replay_case(name)
        output, = evaluate(input)
        assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys), name
      end
    end
  end

  def test_every_round_requires_a_reviewer_independent_from_its_implementer
    replay = replay_case("reviewer-independence")

    Dir.mktmpdir("task-review-loop") do |directory|
      output, = evaluate(non_independent_earlier_round_input(directory))

      assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys)
    end
  end

  def test_fix_package_binds_the_immediately_prior_round_digest
    Dir.mktmpdir("task-review-loop") do |directory|
      input = rebind_package(
        consequential_breakage_input(directory),
        "prior_round_digest" => "sha256:#{'f' * 64}"
      )
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["review-package-prior-round-digest-mismatch"], output.fetch("reasons")
    end
  end

  def test_re_review_package_is_scoped_to_the_fix_diff
    Dir.mktmpdir("task-review-loop") do |directory|
      input = rebind_package(consequential_breakage_input(directory), "scope" => "task")
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["review-package-scope-invalid"], output.fetch("reasons")
    end
  end

  def test_round_outcome_cannot_hide_an_open_normalized_finding
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      findings_path = write_findings(directory, "hidden-open-finding.json", [finding("hidden", head_sha: HEAD_SHA)])
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge("review_findings" => artifact(findings_path)).reject { |key, _value| key == "digest" }
      )
      input = input.merge("rounds" => rounds)
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "round-finding-outcome-mismatch"
    end
  end

  def test_open_finding_artifact_matches_the_latest_round_records
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      changed = finding(
        "finding-2",
        severity: "P1",
        consequential: true,
        independent_validation: {
          "status" => "confirmed",
          "validator" => "reviewer-b",
          "evidence" => ["different-evidence"]
        }
      )
      path = write_findings(directory, "changed-open-findings.json", [changed])
      input = input.merge("open_findings" => artifact(path).merge("ids" => ["finding-2"]))
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "open-findings-round-mismatch"
    end
  end

  private

  def replay_case(name)
    fixture = JSON.parse(File.read(FIXTURES, encoding: "UTF-8"))
    fixture.fetch("cases").find { |entry| entry.fetch("name") == name }.fetch("expected") => expected
    { "expected" => expected }
  end

  def clean_review_input(directory)
    identity = {
      "batch_id" => "aw-medium-wave11-20260901",
      "lane_id" => "issue-392-task-review",
      "plan_id" => "issue-392-core-contract",
      "plan_digest" => "sha256:#{'1' * 64}",
      "task_id" => "task-review-loop-core"
    }
    brief = with_digest(
      "identity" => identity,
      "requirements" => ["Reduce a clean exact-head task review."],
      "global_constraints" => ["Keep final whole-branch review separate."],
      "interfaces" => ["review-finding-v0"],
      "resolved_ambiguities" => []
    )
    report = with_digest(
      "identity" => identity,
      "brief_digest" => brief.fetch("digest"),
      "initial_implementer_id" => "implementer-a",
      "current_implementer_id" => "implementer-a",
      "status" => "done",
      "base_sha" => BASE_SHA,
      "head_sha" => HEAD_SHA,
      "commits" => [HEAD_SHA],
      "changed_paths" => ["lib/task-review.rb"],
      "verification" => [{ "command" => "ruby test/task-review-test.rb", "status" => "passed", "outcome" => "1 run" }],
      "concerns" => [],
      "open_context_needs" => []
    )
    diff_path = File.join(directory, "task.diff")
    File.write(diff_path, "diff --git a/lib/task-review.rb b/lib/task-review.rb\n+review\n")
    findings_path = File.join(directory, "review-findings.json")
    File.write(findings_path, JSON.generate("schema" => "review-finding-v0", "review_findings" => []))
    package = with_digest(
      "identity" => identity,
      "brief_digest" => brief.fetch("digest"),
      "worker_report_digest" => report.fetch("digest"),
      "scope" => "task",
      "base_sha" => BASE_SHA,
      "head_sha" => HEAD_SHA,
      "expected_current_head_sha" => HEAD_SHA,
      "implementer_id" => "implementer-a",
      "reviewer_id" => "reviewer-b",
      "commit_list" => [HEAD_SHA],
      "diff_stat" => "1 file changed, 1 insertion(+)",
      "exact_diff" => artifact(diff_path).merge("truncated" => false),
      "prior_round_digest" => nil
    )
    findings = artifact(findings_path)
    round = with_digest(
      "number" => 0,
      "kind" => "initial_review",
      "package_digest" => package.fetch("digest"),
      "base_sha" => BASE_SHA,
      "head_sha" => HEAD_SHA,
      "implementer_id" => "implementer-a",
      "reviewer_id" => "reviewer-b",
      "prior_round_digest" => nil,
      "review_findings" => findings,
      "addressed_finding_ids" => [],
      "open_finding_ids" => [],
      "new_consequential_finding_ids" => []
    )

    {
      "contract" => "task-review-loop",
      "version" => 1,
      "identity" => identity,
      "expected_current_head_sha" => HEAD_SHA,
      "task_brief" => brief,
      "worker_report" => report,
      "review_package" => package,
      "review_state" => "complete",
      "rounds" => [round],
      "open_findings" => findings.merge("ids" => []),
      "finding_controls" => [],
      "replacement_evidence" => [],
      "cap_adjudication" => nil
    }
  end

  def consequential_breakage_input(directory)
    input = clean_review_input(directory)
    original_package = input.fetch("review_package")
    initial_findings_path = write_findings(directory, "initial-findings.json", [finding("finding-1")])
    initial_round = with_digest(
      input.fetch("rounds").fetch(0).merge(
        "review_findings" => artifact(initial_findings_path),
        "open_finding_ids" => ["finding-1"]
      ).reject { |key, _value| key == "digest" }
    )

    report = with_digest(
      input.fetch("worker_report").merge(
        "head_sha" => FIX_HEAD_SHA,
        "commits" => [HEAD_SHA, FIX_HEAD_SHA]
      ).reject { |key, _value| key == "digest" }
    )
    fix_diff_path = File.join(directory, "fix.diff")
    File.write(fix_diff_path, "diff --git a/lib/task-review.rb b/lib/task-review.rb\n+fix\n")
    package = with_digest(
      original_package.merge(
        "worker_report_digest" => report.fetch("digest"),
        "scope" => "fix",
        "base_sha" => HEAD_SHA,
        "head_sha" => FIX_HEAD_SHA,
        "expected_current_head_sha" => FIX_HEAD_SHA,
        "commit_list" => [FIX_HEAD_SHA],
        "exact_diff" => artifact(fix_diff_path).merge("truncated" => false),
        "prior_round_digest" => initial_round.fetch("digest")
      ).reject { |key, _value| key == "digest" }
    )
    consequential = finding(
      "finding-2",
      severity: "P1",
      consequential: true,
      independent_validation: {
        "status" => "confirmed",
        "validator" => "reviewer-b",
        "evidence" => ["fix-diff://finding-2"]
      }
    )
    reviewed_findings_path = write_findings(
      directory,
      "round-1-findings.json",
      [finding("finding-1", disposition: "accepted_fixed"), consequential]
    )
    round = with_digest(
      "number" => 1,
      "kind" => "fix_re_review",
      "package_digest" => package.fetch("digest"),
      "base_sha" => HEAD_SHA,
      "head_sha" => FIX_HEAD_SHA,
      "implementer_id" => "implementer-a",
      "reviewer_id" => "reviewer-b",
      "prior_round_digest" => initial_round.fetch("digest"),
      "review_findings" => artifact(reviewed_findings_path),
      "addressed_finding_ids" => ["finding-1"],
      "open_finding_ids" => ["finding-2"],
      "new_consequential_finding_ids" => ["finding-2"]
    )
    open_findings_path = write_findings(directory, "open-findings.json", [consequential])

    input.merge(
      "expected_current_head_sha" => FIX_HEAD_SHA,
      "worker_report" => report,
      "review_package" => package,
      "rounds" => [initial_round, round],
      "open_findings" => artifact(open_findings_path).merge("ids" => ["finding-2"]),
      "finding_controls" => [{ "finding_id" => "finding-2", "load_bearing" => false, "cap_piercing" => false }]
    )
  end

  def replacement_input(directory)
    input = consequential_breakage_input(directory)
    report = with_digest(
      input.fetch("worker_report").merge("current_implementer_id" => "implementer-c")
           .reject { |key, _value| key == "digest" }
    )
    package = with_digest(
      input.fetch("review_package").merge(
        "worker_report_digest" => report.fetch("digest"),
        "implementer_id" => "implementer-c"
      ).reject { |key, _value| key == "digest" }
    )
    rounds = input.fetch("rounds").dup
    rounds[-1] = with_digest(
      rounds.last.merge(
        "package_digest" => package.fetch("digest"),
        "implementer_id" => "implementer-c"
      ).reject { |key, _value| key == "digest" }
    )
    input.merge("worker_report" => report, "review_package" => package, "rounds" => rounds)
  end

  def cap_input(directory)
    input = consequential_breakage_input(directory)
    open_finding = finding("finding-2")
    findings_path = write_findings(directory, "cap-open-findings.json", [open_finding])
    findings_artifact = artifact(findings_path)
    round_one_path = write_findings(
      directory,
      "cap-round-1-findings.json",
      [finding("finding-1", disposition: "accepted_fixed"), open_finding]
    )
    rounds = input.fetch("rounds").map(&:dup)
    rounds[1] = with_digest(
      rounds.fetch(1).merge(
        "review_findings" => artifact(round_one_path),
        "addressed_finding_ids" => ["finding-1"],
        "open_finding_ids" => ["finding-2"],
        "new_consequential_finding_ids" => []
      ).reject { |key, _value| key == "digest" }
    )
    (2..4).each do |number|
      rounds << with_digest(
        "number" => number,
        "kind" => "fix_re_review",
        "package_digest" => "sha256:#{number.to_s * 64}",
        "base_sha" => HEAD_SHA,
        "head_sha" => FIX_HEAD_SHA,
        "implementer_id" => "implementer-a",
        "reviewer_id" => "reviewer-b",
        "prior_round_digest" => rounds.last.fetch("digest"),
        "review_findings" => findings_artifact,
        "addressed_finding_ids" => [],
        "open_finding_ids" => ["finding-2"],
        "new_consequential_finding_ids" => []
      )
    end
    package = with_digest(
      input.fetch("review_package").merge(
        "base_sha" => FIX_HEAD_SHA,
        "prior_round_digest" => rounds.last.fetch("digest")
      )
           .reject { |key, _value| key == "digest" }
    )
    rounds << with_digest(
      "number" => 5,
      "kind" => "fix_re_review",
      "package_digest" => package.fetch("digest"),
      "base_sha" => FIX_HEAD_SHA,
      "head_sha" => FIX_HEAD_SHA,
      "implementer_id" => "implementer-a",
      "reviewer_id" => "reviewer-b",
      "prior_round_digest" => rounds.last.fetch("digest"),
      "review_findings" => findings_artifact,
      "addressed_finding_ids" => [],
      "open_finding_ids" => ["finding-2"],
      "new_consequential_finding_ids" => []
    )

    input.merge(
      "review_package" => package,
      "rounds" => rounds,
      "open_findings" => findings_artifact.merge("ids" => ["finding-2"]),
      "finding_controls" => [{ "finding_id" => "finding-2", "load_bearing" => false, "cap_piercing" => false }],
      "cap_adjudication" => {
        "round" => 5,
        "coordinator_id" => "coordinator-a",
        "findings" => [{
          "finding_id" => "finding-2",
          "disposition" => "deferred",
          "evidence" => ["issue://shakacode/agent-workflows/999"],
          "tracking_ref" => "issue://shakacode/agent-workflows/999"
        }]
      }
    )
  end

  def cap_with_p0(input, directory)
    p0 = finding("finding-2", severity: "P0")
    path = write_findings(directory, "cap-p0-findings.json", [p0])
    reference = artifact(path)
    rounds = input.fetch("rounds").dup
    rounds[-1] = with_digest(
      rounds.last.merge("review_findings" => reference).reject { |key, _value| key == "digest" }
    )
    input.merge(
      "rounds" => rounds,
      "open_findings" => reference.merge("ids" => ["finding-2"])
    )
  end

  def non_independent_earlier_round_input(directory)
    input = consequential_breakage_input(directory)
    rounds = input.fetch("rounds").dup
    rounds[0] = with_digest(
      rounds.fetch(0).merge("reviewer_id" => " IMPLEMENTER-A ").reject { |key, _value| key == "digest" }
    )
    package = with_digest(
      input.fetch("review_package").merge("prior_round_digest" => rounds.fetch(0).fetch("digest"))
           .reject { |key, _value| key == "digest" }
    )
    rounds[1] = with_digest(
      rounds.fetch(1).merge(
        "prior_round_digest" => rounds.fetch(0).fetch("digest"),
        "package_digest" => package.fetch("digest")
      ).reject { |key, _value| key == "digest" }
    )
    input.merge("review_package" => package, "rounds" => rounds)
  end

  def finding(
    id,
    severity: "P2",
    disposition: "must_fix",
    consequential: false,
    independent_validation: nil,
    head_sha: FIX_HEAD_SHA
  )
    record = {
      "id" => id,
      "source" => "task-review-loop-test",
      "target" => { "head_sha" => head_sha },
      "severity" => severity,
      "disposition" => disposition,
      "title" => "Finding #{id}",
      "body" => "Evidence-backed finding #{id}",
      "verification" => { "status" => "verified", "current_head_state" => "current" },
      "consequential" => consequential
    }
    record["independent_validation"] = independent_validation if independent_validation
    record
  end

  def rebind_package(input, changes)
    package = with_digest(input.fetch("review_package").merge(changes).reject { |key, _value| key == "digest" })
    rounds = input.fetch("rounds").dup
    rounds[-1] = with_digest(
      rounds.last.merge("package_digest" => package.fetch("digest")).reject { |key, _value| key == "digest" }
    )
    input.merge("review_package" => package, "rounds" => rounds)
  end

  def write_findings(directory, basename, findings)
    path = File.join(directory, basename)
    File.write(path, JSON.generate("schema" => "review-finding-v0", "review_findings" => findings))
    path
  end

  def artifact(path)
    bytes = File.binread(path)
    {
      "path" => path,
      "digest" => "sha256:#{Digest::SHA256.hexdigest(bytes)}",
      "byte_count" => bytes.bytesize
    }
  end

  def with_digest(record)
    record.merge("digest" => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(record)))}")
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, canonical| canonical[key] = canonicalize(value.fetch(key)) }
    when Array
      value.map { |entry| canonicalize(entry) }
    else
      value
    end
  end

  def evaluate(input)
    stdout, stderr, status = Open3.capture3(HELPER, stdin_data: JSON.generate(input))
    assert status.success?, stderr
    [JSON.parse(stdout), stdout]
  end
end
