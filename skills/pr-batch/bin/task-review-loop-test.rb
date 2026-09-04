#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
PINNED_JSON_SCHEMER_VERSION = File.read(File.expand_path("../../../.json-schemer-version", __dir__)).strip
gem "json_schemer", PINNED_JSON_SCHEMER_VERSION
require "json_schemer"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

HELPER = File.expand_path("task-review-loop", __dir__)
FIXTURES = File.expand_path("../fixtures/task-review-loop-replays.json", __dir__)
SCHEMA = File.expand_path("../../../docs/schemas/task-review-loop-v1.schema.json", __dir__)
NOTICES = File.expand_path("../../../THIRD_PARTY-NOTICES.md", __dir__)
VALIDATE = File.expand_path("../../../bin/validate", __dir__)
INSTALLER = File.expand_path("../../../bin/install-agent-workflows", __dir__)
BASE_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_SHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
FIX_HEAD_SHA = "cccccccccccccccccccccccccccccccccccccccc"
OTHER_HEAD_SHA = "dddddddddddddddddddddddddddddddddddddddd"
CAP_HEAD_SHAS = %w[
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  cccccccccccccccccccccccccccccccccccccccc
  dddddddddddddddddddddddddddddddddddddddd
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  ffffffffffffffffffffffffffffffffffffffff
  9999999999999999999999999999999999999999
].freeze
REPO_ROOT = File.expand_path("../../..", __dir__)
TASK_IDENTITY = {
  "batch_id" => "aw-medium-wave11-20260901",
  "lane_id" => "issue-392-task-review",
  "plan_id" => "issue-392-core-contract",
  "plan_digest" => "sha256:#{'1' * 64}",
  "task_id" => "task-review-loop-core"
}.freeze
CAP_AUTHORITY_ENV = {
  "AGENT_WORKFLOW_TASK_REVIEW_COORDINATOR_ID" => "coordinator-a",
  "AGENT_WORKFLOW_TASK_REVIEW_WAIVER_AUTHORITY_REFS" => JSON.generate(["maintainer://justin"])
}.freeze

class TaskReviewLoopTest < Minitest::Test
  def test_schema_is_closed_and_accepts_the_clean_contract
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      validator = JSONSchemer.schema(JSON.parse(File.read(SCHEMA, encoding: "UTF-8")))

      assert validator.valid?(input)
      refute validator.valid?(input.merge("unexpected" => true))
      refute validator.valid?(
        input.merge("rounds" => [input.fetch("rounds").first.reject { |key, _value| key == "worker_report" }])
      )
    end
  end

  def test_schema_covers_replacement_rounds_open_findings_and_cap_adjudication
    Dir.mktmpdir("task-review-loop") do |directory|
      validator = JSONSchemer.schema(JSON.parse(File.read(SCHEMA, encoding: "UTF-8")))
      replacement = replacement_input(directory).merge("replacement_evidence" => [replacement_record])

      assert validator.valid?(replacement)
      refute validator.valid?(
        replacement.merge(
          "replacement_evidence" => [replacement_record.reject { |key, _value| key == "identity" }]
        )
      )
      assert validator.valid?(cap_input(directory))
    end
  end

  def test_pinned_adapted_source_has_one_superpowers_mit_notice
    notices = File.read(NOTICES, encoding: "UTF-8")
    superpowers = notices.split("## obra/superpowers", 2).fetch(1)

    assert_equal 1, notices.scan("## obra/superpowers").length
    assert_equal 1, superpowers.scan("skills/subagent-driven-development/SKILL.md").length
    assert_equal 1, superpowers.scan("MIT License").length
    assert_equal 1, superpowers.scan("Copyright (c) 2025 Jesse Vincent").length
  end

  def test_repository_validation_runs_the_replay_suite_once
    validation = File.read(VALIDATE, encoding: "UTF-8")

    assert_equal 1, validation.scan("ruby skills/pr-batch/bin/task-review-loop-test.rb").length
  end

  def test_flat_install_ships_the_schema_and_canonical_finding_validator
    Dir.mktmpdir("task-review-loop-install") do |directory|
      target = File.join(directory, "agent-home")
      Dir.mkdir(target)
      _stdout, stderr, status = Open3.capture3(
        INSTALLER,
        "--host", "codex",
        "--target", target,
        "--mode", "copy",
        "--delivery-mode", "flat"
      )

      assert status.success?, stderr
      assert File.file?(File.join(target, "docs/schemas/task-review-loop-v1.schema.json"))
      assert File.executable?(File.join(target, "bin/validate-review-findings"))

      stdout, helper_stderr, helper_status = Open3.capture3(
        File.join(target, "skills/pr-batch/bin/task-review-loop"),
        stdin_data: "{}"
      )
      assert helper_status.success?, helper_stderr
      assert_equal "blocked", JSON.parse(stdout).fetch("status")
    end
  end

  def test_flat_install_refuses_an_unowned_schema_directory_symlink
    Dir.mktmpdir("task-review-loop-install") do |directory|
      target = File.join(directory, "agent-home")
      external = File.join(directory, "external-schemas")
      FileUtils.mkdir_p(File.join(target, "docs"))
      Dir.mkdir(external)
      sentinel = File.join(external, "keep.txt")
      File.write(sentinel, "unowned\n")
      File.symlink(external, File.join(target, "docs/schemas"))

      _stdout, stderr, status = Open3.capture3(
        INSTALLER,
        "--host", "codex",
        "--target", target,
        "--mode", "copy",
        "--delivery-mode", "flat"
      )

      refute status.success?
      assert_includes stderr, "Refusing to replace unowned schema directory symlink"
      assert File.symlink?(File.join(target, "docs/schemas"))
      assert_equal "unowned\n", File.read(sentinel)
    end
  end

  def test_flat_install_refuses_a_newly_colliding_personal_finding_validator
    Dir.mktmpdir("task-review-loop-install") do |directory|
      target = File.join(directory, "agent-home")
      validator = File.join(target, "bin/validate-review-findings")
      FileUtils.mkdir_p(File.dirname(validator))
      File.write(validator, "personal validator\n")

      _stdout, stderr, status = Open3.capture3(
        INSTALLER,
        "--host", "codex",
        "--target", target,
        "--mode", "copy",
        "--delivery-mode", "flat"
      )

      refute status.success?
      assert_includes stderr, "Refusing to replace unowned pack helper"
      assert_equal "personal validator\n", File.read(validator)
    end
  end

  def test_flat_copy_upgrade_from_a_non_git_source_uses_the_recorded_helper_fingerprint
    Dir.mktmpdir("task-review-loop-install") do |directory|
      source = File.join(directory, "source")
      target = File.join(directory, "agent-home")
      Dir.mkdir(source)
      Dir.mkdir(target)
      _stdout, copy_stderr, copy_status = Open3.capture3(
        "rsync", "-a", "--exclude", ".git", "#{REPO_ROOT}/", "#{source}/"
      )
      assert copy_status.success?, copy_stderr

      installer = File.join(source, "bin/install-agent-workflows")
      validator = File.join(source, "bin/validate-review-findings")
      _stdout, stderr, status = Open3.capture3(
        installer,
        "--host", "codex",
        "--target", target,
        "--mode", "copy",
        "--delivery-mode", "flat"
      )
      assert status.success?, stderr

      File.open(validator, "a") { |file| file.write("\n# non-git helper v2\n") }
      _stdout, stderr, status = Open3.capture3(
        installer,
        "--host", "codex",
        "--target", target,
        "--mode", "copy",
        "--delivery-mode", "flat"
      )

      assert status.success?, stderr
      assert_equal File.binread(validator), File.binread(File.join(target, "bin/validate-review-findings"))
      metadata = JSON.parse(File.read(File.join(target, ".agent-workflows-install.json"), encoding: "UTF-8"))
      assert_equal Digest::SHA256.file(validator).hexdigest,
                   metadata.fetch("managed_pack_helper_copy_fingerprints").fetch("validate-review-findings")
    end
  end

  def test_missing_canonical_finding_validator_fails_closed_without_a_load_error
    Dir.mktmpdir("task-review-loop-pinned") do |directory|
      helper = File.join(directory, ".agents/skills/pr-batch/bin/task-review-loop")
      FileUtils.mkdir_p(File.dirname(helper))
      FileUtils.cp(HELPER, helper)

      stdout, stderr, status = Open3.capture3(helper, stdin_data: "{}")

      assert status.success?, stderr
      assert_empty stderr
      assert_equal "blocked", JSON.parse(stdout).fetch("status")
      assert_equal ["validate-review-findings-unavailable"], JSON.parse(stdout).fetch("reasons")
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

  def test_whitespace_only_exact_diff_is_rejected_as_empty
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      path = input.dig("review_package", "exact_diff", "path")
      File.binwrite(path, " \n\t")
      input = rebind_package(input, "exact_diff" => artifact(path).merge("truncated" => false))

      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["exact-diff-empty"], output.fetch("reasons")
    end
  end

  def test_invalid_artifact_path_reduces_to_blocked_instead_of_crashing
    Dir.mktmpdir("task-review-loop") do |directory|
      input = rebind_package(
        clean_review_input(directory),
        "exact_diff" => {
          "path" => "bad\0path",
          "digest" => "sha256:#{'1' * 64}",
          "byte_count" => 1,
          "truncated" => false
        }
      )

      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["exact-diff-unreadable"], output.fetch("reasons")
    end
  end

  def test_validated_findings_artifacts_are_not_reloaded_during_reduction
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      findings_path = input.dig("open_findings", "path")
      script = <<~'RUBY'
        target = ENV.fetch("TASK_REVIEW_FINDINGS_PATH")
        reads = 0
        original_binread = File.method(:binread)
        File.define_singleton_method(:binread) do |path, *args|
          if path == target
            reads += 1
            raise Errno::ENOENT, path if reads > 1
          end
          original_binread.call(path, *args)
        end
        load ARGV.fetch(0)
      RUBY

      stdout, stderr, status = Open3.capture3(
        CAP_AUTHORITY_ENV.merge("TASK_REVIEW_FINDINGS_PATH" => findings_path),
        RbConfig.ruby,
        "-e",
        script,
        HELPER,
        stdin_data: JSON.generate(input)
      )

      assert status.success?, stderr
      assert_equal "task_complete", JSON.parse(stdout).fetch("status")
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

  def test_pending_initial_reviewer_cannot_be_a_replaced_implementer
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      report = with_digest(
        input.fetch("worker_report").merge("current_implementer_id" => "implementer-c")
             .reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge(
          "worker_report_digest" => report.fetch("digest"),
          "implementer_id" => "implementer-c",
          "reviewer_id" => "implementer-a"
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge(
          "worker_report" => report,
          "review_package" => package,
          "review_state" => "pending",
          "rounds" => [],
          "open_findings" => nil
        )
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "reviewer-not-independent"
    end
  end

  def test_exact_diff_range_must_change_the_head
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      report = with_digest(
        input.fetch("worker_report").merge("base_sha" => HEAD_SHA).reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge(
          "worker_report_digest" => report.fetch("digest"),
          "base_sha" => HEAD_SHA
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge(
          "worker_report" => report,
          "review_package" => package,
          "review_state" => "pending",
          "rounds" => [],
          "open_findings" => nil
        )
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-package-empty-range"
    end
  end

  def test_completed_review_round_range_must_change_the_head
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      rounds = input.fetch("rounds").dup
      rounds[0] = with_digest(
        rounds[0].merge("base_sha" => HEAD_SHA).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(input.merge("rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-round-empty-range"
    end
  end

  def test_pending_fix_review_requires_the_prior_open_finding_artifact
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      input = input.merge(
        "review_state" => "pending",
        "rounds" => [input.fetch("rounds").first],
        "open_findings" => nil,
        "finding_controls" => []
      )
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["open-findings-required"], output.fetch("reasons")
    end
  end

  def test_pending_fix_package_and_prior_open_findings_are_review_eligible
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      initial_round = input.fetch("rounds").first
      input = input.merge(
        "review_state" => "pending",
        "rounds" => [initial_round],
        "open_findings" => initial_round.fetch("review_findings").merge("ids" => ["finding-1"]),
        "finding_controls" => [{ "finding_id" => "finding-1", "load_bearing" => false, "cap_piercing" => false }]
      )
      output, = evaluate(input)

      assert_equal "review_eligible", output.fetch("status")
      refute output.fetch("dependent_task_permitted")
      assert_equal ["exact-review-package-current"], output.fetch("reasons")
    end
  end

  def test_pending_replacement_package_uses_fenced_transition_evidence
    Dir.mktmpdir("task-review-loop") do |directory|
      input = replacement_input(directory)
      initial_round = input.fetch("rounds").first
      input = input.merge(
        "review_state" => "pending",
        "rounds" => [initial_round],
        "open_findings" => initial_round.fetch("review_findings").merge("ids" => ["finding-1"]),
        "finding_controls" => [{ "finding_id" => "finding-1", "load_bearing" => false, "cap_piercing" => false }],
        "replacement_evidence" => [replacement_record]
      )
      output, = evaluate(input)

      assert_equal "review_eligible", output.fetch("status")
      assert_equal ["exact-review-package-current"], output.fetch("reasons")
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
        "stale-package" => rebind_package(base_input, "expected_current_head_sha" => OTHER_HEAD_SHA),
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
        input.merge("replacement_evidence" => [replacement_record])
      )

      assert_equal "blocked", missing_output.fetch("status")
      assert_includes missing_output.fetch("reasons"), "worker-replacement-evidence-required"
      assert_equal replay.fetch("expected"), evidenced_output.slice(*replay.fetch("expected").keys)
    end
  end

  def test_replacement_before_initial_review_requires_round_zero_evidence
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
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
      pending = input.merge(
        "worker_report" => report,
        "review_package" => package,
        "review_state" => "pending",
        "rounds" => [],
        "open_findings" => nil,
        "finding_controls" => []
      )
      missing_output, = evaluate(pending)
      evidenced_output, = evaluate(
        pending.merge("replacement_evidence" => [replacement_record(round: 0)])
      )

      assert_equal "blocked", missing_output.fetch("status")
      assert_includes missing_output.fetch("reasons"), "worker-replacement-evidence-required"
      assert_equal "review_eligible", evidenced_output.fetch("status")
    end
  end

  def test_replacement_evidence_must_describe_an_actual_implementer_transition
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory).merge("replacement_evidence" => [replacement_record])
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["worker-replacement-evidence-foreign"], output.fetch("reasons")
    end
  end

  def test_replacement_evidence_is_bound_to_the_task_identity
    Dir.mktmpdir("task-review-loop") do |directory|
      foreign_identity = TASK_IDENTITY.merge("task_id" => "another-task")
      evidence = replacement_record.merge("identity" => foreign_identity)
      input = replacement_input(directory).merge("replacement_evidence" => [evidence])

      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "worker-replacement-evidence-foreign"
      refute output.fetch("dependent_task_permitted")
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

  def test_cap_adjudication_requires_the_configured_coordinator
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      adjudication = input.fetch("cap_adjudication").merge("coordinator_id" => "implementer-a")
      output, = evaluate(input.merge("cap_adjudication" => adjudication))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "cap-coordinator-unauthorized"
      refute output.fetch("dependent_task_permitted")
    end
  end

  def test_cap_adjudication_fails_closed_without_authority_policy
    Dir.mktmpdir("task-review-loop") do |directory|
      output, = evaluate(
        cap_input(directory),
        "AGENT_WORKFLOW_TASK_REVIEW_COORDINATOR_ID" => nil,
        "AGENT_WORKFLOW_TASK_REVIEW_WAIVER_AUTHORITY_REFS" => nil
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "cap-authority-policy-invalid"
      refute output.fetch("dependent_task_permitted")
    end
  end

  def test_cap_waiver_requires_a_configured_authority_reference
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      record = input.dig("cap_adjudication", "findings", 0).merge(
        "disposition" => "waived",
        "authority_ref" => "arbitrary://self-asserted"
      ).reject { |key, _value| key == "tracking_ref" }
      adjudication = input.fetch("cap_adjudication").merge("findings" => [record])
      output, = evaluate(input.merge("cap_adjudication" => adjudication))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "cap-waiver-authority-untrusted"
      refute output.fetch("dependent_task_permitted")
    end
  end

  def test_cap_waiver_accepts_the_configured_authority_reference
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      record = input.dig("cap_adjudication", "findings", 0).merge(
        "disposition" => "waived",
        "authority_ref" => "maintainer://justin"
      ).reject { |key, _value| key == "tracking_ref" }
      adjudication = input.fetch("cap_adjudication").merge("findings" => [record])
      output, = evaluate(input.merge("cap_adjudication" => adjudication))

      assert_equal "task_complete", output.fetch("status")
      assert_equal ["cap-adjudicated"], output.fetch("reasons")
      assert output.fetch("dependent_task_permitted")
    end
  end

  def test_fabricated_historical_package_digest_cannot_advance_cap_adjudication
    replay = replay_case("fabricated-historical-package")

    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      rounds = input.fetch("rounds").dup
      fabricated_digest = "sha256:#{'0' * 64}"
      fabricated_package = rounds.fetch(2).fetch("review_package").merge("digest" => fabricated_digest)
      rounds[2] = with_digest(
        rounds.fetch(2).merge(
          "package_digest" => fabricated_digest,
          "review_package" => fabricated_package
        ).reject { |key, _value| key == "digest" }
      )

      output, = evaluate(input.merge("rounds" => rounds))

      assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys)
      assert_includes output.fetch("reasons"), "review-round-package-invalid"
      refute_includes output.fetch("reasons"), "cap-adjudicated"
    end
  end

  def test_historical_package_commit_range_cannot_advance_cap_adjudication
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      rounds = input.fetch("rounds").dup
      historical_round = rounds.fetch(2)
      historical_package = with_digest(
        historical_round.fetch("review_package").merge(
          "commit_list" => [historical_round.fetch("base_sha"), historical_round.fetch("head_sha")]
        ).reject { |key, _value| key == "digest" }
      )
      rounds[2] = with_digest(
        historical_round.merge(
          "package_digest" => historical_package.fetch("digest"),
          "review_package" => historical_package
        ).reject { |key, _value| key == "digest" }
      )

      output, = evaluate(input.merge("rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_equal false, output.fetch("dependent_task_permitted")
      assert_includes output.fetch("reasons"), "review-round-package-range-mismatch"
      refute_includes output.fetch("reasons"), "cap-adjudicated"
    end
  end

  def test_historical_package_worker_report_digest_resolves_to_its_retained_report
    replay = replay_case("historical-package-report-digest-mismatch")

    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      rounds = input.fetch("rounds").dup
      historical_package = with_digest(
        rounds.fetch(0).fetch("review_package").merge(
          "worker_report_digest" => "sha256:#{'0' * 64}"
        ).reject { |key, _value| key == "digest" }
      )
      rounds[0] = with_digest(
        rounds.fetch(0).merge(
          "package_digest" => historical_package.fetch("digest"),
          "review_package" => historical_package
        ).reject { |key, _value| key == "digest" }
      )
      current_package = with_digest(
        input.fetch("review_package").merge(
          "prior_round_digest" => rounds.fetch(0).fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      rounds[1] = with_digest(
        rounds.fetch(1).merge(
          "package_digest" => current_package.fetch("digest"),
          "review_package" => current_package,
          "prior_round_digest" => rounds.fetch(0).fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )

      output, = evaluate(input.merge("review_package" => current_package, "rounds" => rounds))

      assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys)
    end
  end

  def test_non_reviewable_historical_report_fails_closed
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      rounds = input.fetch("rounds").dup
      historical_report = with_digest(
        rounds.fetch(0).fetch("worker_report").merge("status" => "blocked")
              .reject { |key, _value| key == "digest" }
      )
      historical_package = with_digest(
        rounds.fetch(0).fetch("review_package").merge(
          "worker_report_digest" => historical_report.fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      rounds[0] = with_digest(
        rounds.fetch(0).merge(
          "package_digest" => historical_package.fetch("digest"),
          "review_package" => historical_package,
          "worker_report" => historical_report
        ).reject { |key, _value| key == "digest" }
      )
      current_package = with_digest(
        input.fetch("review_package").merge(
          "prior_round_digest" => rounds.fetch(0).fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      rounds[1] = with_digest(
        rounds.fetch(1).merge(
          "package_digest" => current_package.fetch("digest"),
          "review_package" => current_package,
          "prior_round_digest" => rounds.fetch(0).fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )

      output, = evaluate(input.merge("review_package" => current_package, "rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-round-report-not-reviewable"
      refute output.fetch("dependent_task_permitted")
    end
  end

  def test_invalid_historical_report_round_heads_fail_the_package_range_closed
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      rounds = input.fetch("rounds").dup
      historical_report = with_digest(
        rounds.fetch(0).fetch("worker_report").merge(
          "commits" => [OTHER_HEAD_SHA]
        ).reject { |key, _value| key == "digest" }
      )
      historical_package = with_digest(
        rounds.fetch(0).fetch("review_package").merge(
          "worker_report_digest" => historical_report.fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      rounds[0] = with_digest(
        rounds.fetch(0).merge(
          "package_digest" => historical_package.fetch("digest"),
          "review_package" => historical_package,
          "worker_report" => historical_report
        ).reject { |key, _value| key == "digest" }
      )
      current_package = with_digest(
        input.fetch("review_package").merge(
          "prior_round_digest" => rounds.fetch(0).fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      rounds[1] = with_digest(
        rounds.fetch(1).merge(
          "package_digest" => current_package.fetch("digest"),
          "review_package" => current_package,
          "prior_round_digest" => rounds.fetch(0).fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )

      output, = evaluate(input.merge("review_package" => current_package, "rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-round-package-range-mismatch"
      refute output.fetch("dependent_task_permitted")
    end
  end

  def test_pending_package_after_round_five_cannot_start_a_sixth_fix_round
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      package = with_digest(
        input.fetch("review_package").merge(
          "prior_round_digest" => input.fetch("rounds").last.fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge("review_state" => "pending", "review_package" => package, "cap_adjudication" => nil)
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "round-cap-reached"
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

  def test_explicit_blocked_cap_adjudication_cannot_complete_the_task
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      adjudication = input.fetch("cap_adjudication").merge(
        "findings" => [{
          "finding_id" => "finding-2",
          "disposition" => "blocked",
          "evidence" => ["review://round-5/finding-2"]
        }]
      )
      output, = evaluate(input.merge("cap_adjudication" => adjudication))

      assert_equal "blocked", output.fetch("status")
      refute output.fetch("dependent_task_permitted")
      assert_equal ["cap-adjudicated-blocked"], output.fetch("reasons")
    end
  end

  def test_clean_cap_round_rejects_foreign_adjudication_records
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      final_head = input.fetch("rounds").last.fetch("head_sha")
      addressed = finding(
        "finding-2",
        severity: "P1",
        disposition: "accepted_fixed",
        consequential: true,
        independent_validation: {
          "status" => "confirmed",
          "validator" => "reviewer-b",
          "evidence" => ["fix-diff://finding-2"]
        },
        head_sha: final_head
      )
      findings_path = write_findings(directory, "clean-cap-findings.json", [addressed])
      rounds = input.fetch("rounds").dup
      open_path = write_findings(
        directory,
        "clean-cap-open-findings.json",
        [],
        receipt: review_receipt(head_sha: rounds.last.fetch("head_sha"), base_sha: rounds.last.fetch("base_sha"))
      )
      rounds[-1] = with_digest(
        rounds.last.merge(
          "review_findings" => artifact(findings_path),
          "addressed_finding_ids" => ["finding-2"],
          "open_finding_ids" => []
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge(
          "rounds" => rounds,
          "open_findings" => artifact(open_path).merge("ids" => []),
          "finding_controls" => []
        )
      )

      assert_equal "blocked", output.fetch("status")
      assert_equal ["cap-adjudication-unexpected"], output.fetch("reasons")
    end
  end

  def test_adjudication_cannot_end_the_loop_before_the_cap
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      adjudication = cap_input(directory).fetch("cap_adjudication")
      output, = evaluate(input.merge("cap_adjudication" => adjudication))

      assert_equal "blocked", output.fetch("status")
      assert_equal ["cap-adjudication-premature"], output.fetch("reasons")
    end
  end

  def test_unknown_sentinel_variants_cannot_supply_cap_evidence
    Dir.mktmpdir("task-review-loop") do |directory|
      input = cap_input(directory)
      adjudication = input.fetch("cap_adjudication").merge(
        "findings" => [{
          "finding_id" => "finding-2",
          "disposition" => "deferred",
          "evidence" => ["\u00a0unknown\u00a0"],
          "tracking_ref" => "issue://shakacode/agent-workflows/999"
        }]
      )
      output, = evaluate(input.merge("cap_adjudication" => adjudication))

      assert_equal "blocked", output.fetch("status")
      assert_equal ["input-schema-invalid"], output.fetch("reasons")
    end
  end

  def test_every_round_requires_a_reviewer_independent_from_its_implementer
    Dir.mktmpdir("task-review-loop") do |directory|
      output, = evaluate(non_independent_earlier_round_input(directory))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "reviewer-not-independent"
      refute output.fetch("dependent_task_permitted")
    end
  end

  def test_reviewer_independence_normalizes_unicode_whitespace
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      reviewer = "\u00a0IMPLEMENTER-A\u00a0"
      package = with_digest(
        input.fetch("review_package").merge("reviewer_id" => reviewer)
             .reject { |key, _value| key == "digest" }
      )
      round = with_digest(
        input.fetch("rounds").first.merge(
          "package_digest" => package.fetch("digest"),
          "review_package" => package,
          "reviewer_id" => reviewer
        ).reject { |key, _value| key == "digest" }
      )

      output, = evaluate(input.merge("review_package" => package, "rounds" => [round]))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "reviewer-not-independent"
    end
  end

  def test_deferred_review_finding_remains_open_until_cap_adjudication
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      deferred = finding("finding-deferred", disposition: "deferred", head_sha: HEAD_SHA)
      path = write_findings(directory, "deferred-findings.json", [deferred])
      reference = artifact(path)
      round = with_digest(
        input.fetch("rounds").first.merge(
          "review_findings" => reference,
          "open_finding_ids" => ["finding-deferred"]
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge(
          "rounds" => [round],
          "open_findings" => reference.merge("ids" => ["finding-deferred"]),
          "finding_controls" => [{
            "finding_id" => "finding-deferred",
            "load_bearing" => false,
            "cap_piercing" => false
          }]
        )
      )

      assert_equal "fix_required", output.fetch("status")
      refute output.fetch("dependent_task_permitted")
      assert_equal ["open-findings-require-fix"], output.fetch("reasons")
    end
  end

  def test_re_review_cannot_reuse_an_open_finding_id_for_different_content
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      replacement = finding("finding-1", disposition: "accepted_fixed")
      replacement["title"] = "Different observation"
      replacement["body"] = "This is not the original finding."
      path = write_findings(directory, "finding-id-collision.json", [replacement])
      reference = artifact(path)
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge(
          "review_findings" => reference,
          "addressed_finding_ids" => ["finding-1"],
          "open_finding_ids" => [],
          "new_consequential_finding_ids" => []
        ).reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge("prior_round_digest" => rounds.first.fetch("digest"))
             .reject { |key, _value| key == "digest" }
      )
      rounds[-1] = with_digest(
        rounds.last.merge("package_digest" => package.fetch("digest"), "review_package" => package)
              .reject { |key, _value| key == "digest" }
      )
      empty_path = write_findings(
        directory,
        "empty-open-findings.json",
        [],
        receipt: review_receipt(head_sha: FIX_HEAD_SHA, base_sha: HEAD_SHA)
      )

      output, = evaluate(
        input.merge(
          "review_package" => package,
          "rounds" => rounds,
          "open_findings" => artifact(empty_path).merge("ids" => []),
          "finding_controls" => []
        )
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "prior-open-finding-lineage-mismatch"
    end
  end

  def test_re_review_cannot_recycle_an_addressed_finding_id
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      rounds = input.fetch("rounds").dup
      prior_document = JSON.parse(File.read(rounds[1].dig("review_findings", "path")))
      prior_breakage = prior_document.fetch("review_findings").find { |finding| finding["id"] == "finding-2" }
      addressed_breakage = Marshal.load(Marshal.dump(prior_breakage))
      addressed_breakage["target"] = addressed_breakage.fetch("target").merge("head_sha" => OTHER_HEAD_SHA)
      addressed_breakage["disposition"] = "accepted_fixed"
      recycled = finding("finding-1", head_sha: OTHER_HEAD_SHA)
      recycled["title"] = "Different observation"
      recycled["body"] = "This id was already addressed in the prior round."
      round_path = write_findings(directory, "recycled-addressed-id.json", [addressed_breakage, recycled])
      open_path = write_findings(directory, "recycled-addressed-open.json", [recycled])
      report = with_digest(
        input.fetch("worker_report").merge(
          "head_sha" => OTHER_HEAD_SHA,
          "commits" => [HEAD_SHA, FIX_HEAD_SHA, OTHER_HEAD_SHA]
        ).reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge(
          "worker_report_digest" => report.fetch("digest"),
          "base_sha" => FIX_HEAD_SHA,
          "head_sha" => OTHER_HEAD_SHA,
          "expected_current_head_sha" => OTHER_HEAD_SHA,
          "commit_list" => [OTHER_HEAD_SHA],
          "prior_round_digest" => rounds[1].fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      rounds << with_digest(
        "number" => 2,
        "kind" => "fix_re_review",
        "package_digest" => package.fetch("digest"),
        "review_package" => package,
        "worker_report" => report,
        "base_sha" => FIX_HEAD_SHA,
        "head_sha" => OTHER_HEAD_SHA,
        "implementer_id" => "implementer-a",
        "reviewer_id" => "reviewer-b",
        "prior_round_digest" => rounds[1].fetch("digest"),
        "review_findings" => artifact(round_path),
        "addressed_finding_ids" => ["finding-2"],
        "open_finding_ids" => ["finding-1"],
        "new_consequential_finding_ids" => []
      )

      output, = evaluate(
        input.merge(
          "expected_current_head_sha" => OTHER_HEAD_SHA,
          "worker_report" => report,
          "review_package" => package,
          "rounds" => rounds,
          "open_findings" => artifact(open_path).merge("ids" => ["finding-1"]),
          "finding_controls" => [{
            "finding_id" => "finding-1",
            "load_bearing" => false,
            "cap_piercing" => false
          }]
        )
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "finding-id-reused"
    end
  end

  def test_consequential_new_breakage_must_remain_open_for_a_later_fix_round
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      rounds = input.fetch("rounds").dup
      records = JSON.parse(File.read(rounds[1].dig("review_findings", "path"))).fetch("review_findings")
      records.find { |finding| finding["id"] == "finding-2" }["disposition"] = "accepted_fixed"
      path = write_findings(directory, "premature-consequential-fix.json", records)
      rounds[1] = with_digest(
        rounds[1].merge(
          "review_findings" => artifact(path),
          "addressed_finding_ids" => %w[finding-1 finding-2],
          "open_finding_ids" => []
        ).reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge("prior_round_digest" => rounds[0].fetch("digest"))
             .reject { |key, _value| key == "digest" }
      )
      rounds[1] = with_digest(
        rounds[1].merge("package_digest" => package.fetch("digest"), "review_package" => package)
                 .reject { |key, _value| key == "digest" }
      )
      empty_path = write_findings(
        directory,
        "premature-consequential-open.json",
        [],
        receipt: review_receipt(head_sha: FIX_HEAD_SHA, base_sha: HEAD_SHA)
      )

      output, = evaluate(
        input.merge(
          "review_package" => package,
          "rounds" => rounds,
          "open_findings" => artifact(empty_path).merge("ids" => []),
          "finding_controls" => []
        )
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "new-consequential-finding-not-open"
    end
  end

  def test_review_receipt_must_bind_the_round_base_and_head
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      document = {
        "schema" => "review-finding-v0",
        "reviewer_id" => "reviewer-b",
        "review_receipt" => review_receipt(head_sha: OTHER_HEAD_SHA),
        "review_findings" => []
      }
      path = File.join(directory, "foreign-receipt.json")
      File.write(path, JSON.generate(document))
      reference = artifact(path)
      round = with_digest(
        input.fetch("rounds").first.merge("review_findings" => reference)
             .reject { |key, _value| key == "digest" }
      )

      output, = evaluate(
        input.merge("rounds" => [round], "open_findings" => reference.merge("ids" => []))
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-findings-foreign"
    end
  end

  def test_empty_findings_without_a_review_receipt_fail_closed
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      path = File.join(directory, "empty-findings-without-receipt.json")
      File.write(
        path,
        JSON.generate(
          "schema" => "review-finding-v0",
          "reviewer_id" => "reviewer-b",
          "review_findings" => []
        )
      )
      reference = artifact(path)
      round = with_digest(
        input.fetch("rounds").first.merge("review_findings" => reference)
             .reject { |key, _value| key == "digest" }
      )

      output, = evaluate(
        input.merge("rounds" => [round], "open_findings" => reference.merge("ids" => []))
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-findings-foreign"
      assert_includes output.fetch("reasons"), "open-findings-foreign"
    end
  end

  def test_findings_reviewer_must_match_the_round_reviewer
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      document = {
        "schema" => "review-finding-v0",
        "reviewer_id" => "implementer-a",
        "review_receipt" => review_receipt,
        "review_findings" => []
      }
      path = File.join(directory, "implementer-findings.json")
      File.write(path, JSON.generate(document))
      reference = artifact(path)
      round = with_digest(
        input.fetch("rounds").first.merge("review_findings" => reference)
             .reject { |key, _value| key == "digest" }
      )

      output, = evaluate(
        input.merge("rounds" => [round], "open_findings" => reference.merge("ids" => []))
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-findings-foreign"
      assert_includes output.fetch("reasons"), "open-findings-foreign"
    end
  end

  def test_empty_findings_require_complete_review_coverage
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      receipt = review_receipt
      receipt["coverage"] = {
        "status" => "partial",
        "included_paths" => [],
        "excluded_paths" => ["lib/task-review.rb"],
        "limitations" => ["The task path was not reviewed."]
      }
      document = {
        "schema" => "review-finding-v0",
        "reviewer_id" => "reviewer-b",
        "review_receipt" => receipt,
        "review_findings" => []
      }
      path = File.join(directory, "partial-clean-findings.json")
      File.write(path, JSON.generate(document))
      reference = artifact(path)
      round = with_digest(
        input.fetch("rounds").first.merge("review_findings" => reference)
             .reject { |key, _value| key == "digest" }
      )

      output, = evaluate(
        input.merge("rounds" => [round], "open_findings" => reference.merge("ids" => []))
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-findings-incomplete-coverage"
      assert_includes output.fetch("reasons"), "open-findings-incomplete-coverage"
    end
  end

  def test_nonempty_findings_require_a_complete_range_bound_review_receipt
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      addressed = finding(
        "finding-1",
        disposition: "accepted_fixed",
        head_sha: HEAD_SHA,
        independent_validation: {
          "status" => "confirmed",
          "validator" => "reviewer-b",
          "evidence" => ["fix-diff://finding-1"]
        }
      )
      partial_receipt = review_receipt
      partial_receipt["coverage"] = {
        "status" => "partial",
        "included_paths" => [],
        "excluded_paths" => ["lib/task-review.rb"],
        "limitations" => ["The task path was not reviewed."]
      }
      variants = {
        "missing" => nil,
        "partial" => partial_receipt
      }

      variants.each do |name, receipt|
        findings_path = write_findings(directory, "#{name}-nonempty-findings.json", [addressed], receipt: receipt)
        findings = artifact(findings_path)
        round = with_digest(
          input.fetch("rounds").last.merge(
            "review_findings" => findings,
            "addressed_finding_ids" => ["finding-1"]
          ).reject { |key, _value| key == "digest" }
        )
        output, = evaluate(input.merge("rounds" => [round]))

        assert_equal "blocked", output.fetch("status"), name
        assert_includes output.fetch("reasons"), "review-findings-incomplete-coverage", name
        refute output.fetch("dependent_task_permitted"), name
      end
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

  def test_review_package_commit_list_is_bound_to_the_worker_report_and_head
    Dir.mktmpdir("task-review-loop") do |directory|
      input = rebind_package(clean_review_input(directory), "commit_list" => [OTHER_HEAD_SHA])
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["review-package-commit-list-mismatch"], output.fetch("reasons")
    end
  end

  def test_current_fix_package_covers_the_exact_report_slice_after_its_base
    replay = replay_case("current-fix-package-wrong-range")

    Dir.mktmpdir("task-review-loop") do |directory|
      input = rebind_report(
        consequential_breakage_input(directory),
        "commits" => [HEAD_SHA, OTHER_HEAD_SHA, FIX_HEAD_SHA]
      )
      variants = {
        "omitted-intermediate-commit" => input,
        "included-reviewed-base" => rebind_package(
          input,
          "commit_list" => [HEAD_SHA, OTHER_HEAD_SHA, FIX_HEAD_SHA]
        )
      }

      variants.each do |name, variant|
        output, = evaluate(variant)

        assert_equal replay.fetch("expected"), output.slice(*replay.fetch("expected").keys), name
      end
    end
  end

  def test_initial_task_package_covers_the_full_worker_report_commit_sequence
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      input = rebind_report(input, "commits" => [OTHER_HEAD_SHA, HEAD_SHA])
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["review-package-commit-list-mismatch"], output.fetch("reasons")
    end
  end

  def test_worker_report_rejects_commits_after_the_declared_head
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      input = rebind_report(input, "commits" => [HEAD_SHA, OTHER_HEAD_SHA])
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_equal ["review-package-commit-list-mismatch"], output.fetch("reasons")
    end
  end

  def test_worker_report_retains_every_completed_round_head_in_order
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      input = rebind_report(input, "commits" => [FIX_HEAD_SHA])
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "worker-report-round-heads-mismatch"
    end
  end

  def test_clean_review_cannot_start_or_complete_a_gratuitous_fix_round
    Dir.mktmpdir("task-review-loop") do |directory|
      clean = clean_review_input(directory)
      report = with_digest(
        clean.fetch("worker_report").merge(
          "head_sha" => OTHER_HEAD_SHA,
          "commits" => [HEAD_SHA, OTHER_HEAD_SHA]
        ).reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        clean.fetch("review_package").merge(
          "worker_report_digest" => report.fetch("digest"),
          "scope" => "fix",
          "base_sha" => HEAD_SHA,
          "head_sha" => OTHER_HEAD_SHA,
          "expected_current_head_sha" => OTHER_HEAD_SHA,
          "commit_list" => [OTHER_HEAD_SHA],
          "prior_round_digest" => clean.fetch("rounds").first.fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      prior = clean.fetch("rounds").first
      pending = clean.merge(
        "expected_current_head_sha" => OTHER_HEAD_SHA,
        "worker_report" => report,
        "review_package" => package,
        "review_state" => "pending",
        "rounds" => [prior],
        "open_findings" => prior.fetch("review_findings").merge("ids" => []),
        "finding_controls" => []
      )
      pending_output, = evaluate(pending)

      round = with_digest(
        prior.merge(
          "number" => 1,
          "kind" => "fix_re_review",
          "package_digest" => package.fetch("digest"),
          "review_package" => package,
          "worker_report" => report,
          "base_sha" => HEAD_SHA,
          "head_sha" => OTHER_HEAD_SHA,
          "prior_round_digest" => prior.fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      complete_output, = evaluate(
        pending.merge("review_state" => "complete", "rounds" => [prior, round])
      )

      assert_equal "blocked", pending_output.fetch("status")
      assert_includes pending_output.fetch("reasons"), "fix-round-without-open-findings"
      assert_equal "blocked", complete_output.fetch("status")
      assert_includes complete_output.fetch("reasons"), "fix-round-without-open-findings"
    end
  end

  def test_incomplete_worker_report_cannot_enter_review
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      report = with_digest(
        input.fetch("worker_report").merge("status" => "needs_context").reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge("worker_report_digest" => report.fetch("digest"))
             .reject { |key, _value| key == "digest" }
      )
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge(
          "package_digest" => package.fetch("digest"),
          "review_package" => package,
          "worker_report" => report
        )
              .reject { |key, _value| key == "digest" }
      )
      output, = evaluate(input.merge("worker_report" => report, "review_package" => package, "rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_equal ["worker-report-not-reviewable"], output.fetch("reasons")
    end
  end

  def test_completed_round_binds_the_review_package_range_and_actors
    Dir.mktmpdir("task-review-loop") do |directory|
      input = clean_review_input(directory)
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge("head_sha" => OTHER_HEAD_SHA).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(input.merge("rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-round-package-binding-mismatch"
    end
  end

  def test_every_completed_round_chains_from_the_task_base_and_prior_head
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      rounds = input.fetch("rounds").dup
      rounds[0] = with_digest(
        rounds.fetch(0).merge("base_sha" => OTHER_HEAD_SHA).reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge("prior_round_digest" => rounds.fetch(0).fetch("digest"))
             .reject { |key, _value| key == "digest" }
      )
      rounds[1] = with_digest(
        rounds.fetch(1).merge(
          "prior_round_digest" => rounds.fetch(0).fetch("digest"),
          "package_digest" => package.fetch("digest"),
          "review_package" => package
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(input.merge("review_package" => package, "rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-round-base-chain-mismatch"
    end
  end

  def test_re_review_package_is_scoped_to_the_fix_diff
    Dir.mktmpdir("task-review-loop") do |directory|
      input = rebind_package(consequential_breakage_input(directory), "scope" => "task")
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-package-scope-invalid"
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

  def test_re_review_cannot_omit_a_previously_open_finding
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      empty_path = write_findings(
        directory,
        "empty-re-review.json",
        [],
        receipt: review_receipt(head_sha: FIX_HEAD_SHA, base_sha: HEAD_SHA)
      )
      empty_reference = artifact(empty_path)
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge(
          "review_findings" => empty_reference,
          "addressed_finding_ids" => [],
          "open_finding_ids" => [],
          "new_consequential_finding_ids" => []
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge("rounds" => rounds, "open_findings" => empty_reference.merge("ids" => []), "finding_controls" => [])
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "prior-open-finding-outcome-mismatch"
    end
  end

  def test_re_review_rejects_unrelated_new_non_consequential_findings
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      unrelated = finding("unrelated-p2")
      round_path = write_findings(
        directory,
        "unrelated-round-findings.json",
        [finding("finding-1", disposition: "accepted_fixed"), unrelated]
      )
      open_path = write_findings(directory, "unrelated-open-findings.json", [unrelated])
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge(
          "review_findings" => artifact(round_path),
          "addressed_finding_ids" => ["finding-1"],
          "open_finding_ids" => ["unrelated-p2"],
          "new_consequential_finding_ids" => []
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge(
          "rounds" => rounds,
          "open_findings" => artifact(open_path).merge("ids" => ["unrelated-p2"]),
          "finding_controls" => [
            { "finding_id" => "unrelated-p2", "load_bearing" => false, "cap_piercing" => false }
          ]
        )
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "unrelated-new-finding"
    end
  end

  def test_existing_review_finding_validator_remains_authoritative
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      invalid = finding("finding-2").merge("disposition" => "fixed_elsewhere")
      path = write_findings(directory, "invalid-findings.json", [invalid])
      reference = artifact(path)
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge("review_findings" => reference).reject { |key, _value| key == "digest" }
      )
      input = input.merge(
        "rounds" => rounds,
        "open_findings" => reference.merge("ids" => ["finding-2"])
      )
      output, = evaluate(input)

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-findings-invalid"
      assert_includes output.fetch("reasons"), "open-findings-invalid"
    end
  end

  def test_review_findings_are_bound_to_the_task_identity_and_reviewed_head
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      foreign = finding(
        "finding-2",
        severity: "P1",
        consequential: true,
        independent_validation: {
          "status" => "confirmed",
          "validator" => "reviewer-b",
          "evidence" => ["fix-diff://finding-2"]
        }
      )
      foreign["target"] = foreign.fetch("target").merge("task_id" => "foreign-task")
      round_path = write_findings(
        directory,
        "foreign-round-findings.json",
        [finding("finding-1", disposition: "accepted_fixed"), foreign]
      )
      open_path = write_findings(directory, "foreign-open-findings.json", [foreign])
      rounds = input.fetch("rounds").dup
      rounds[-1] = with_digest(
        rounds.last.merge("review_findings" => artifact(round_path)).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(
        input.merge("rounds" => rounds, "open_findings" => artifact(open_path).merge("ids" => ["finding-2"]))
      )

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "review-findings-foreign"
    end
  end

  def test_consequential_breakage_must_be_new_in_the_fix_diff
    Dir.mktmpdir("task-review-loop") do |directory|
      input = consequential_breakage_input(directory)
      prior_consequential = finding(
        "finding-2",
        severity: "P1",
        consequential: true,
        head_sha: HEAD_SHA,
        independent_validation: {
          "status" => "confirmed",
          "validator" => "reviewer-b",
          "evidence" => ["task-diff://finding-2"]
        }
      )
      path = write_findings(
        directory,
        "prior-consequential-findings.json",
        [finding("finding-1", head_sha: HEAD_SHA), prior_consequential]
      )
      rounds = input.fetch("rounds").dup
      rounds[0] = with_digest(
        rounds.fetch(0).merge(
          "review_findings" => artifact(path),
          "open_finding_ids" => %w[finding-1 finding-2]
        ).reject { |key, _value| key == "digest" }
      )
      package = with_digest(
        input.fetch("review_package").merge("prior_round_digest" => rounds.fetch(0).fetch("digest"))
             .reject { |key, _value| key == "digest" }
      )
      rounds[1] = with_digest(
        rounds.fetch(1).merge(
          "prior_round_digest" => rounds.fetch(0).fetch("digest"),
          "package_digest" => package.fetch("digest"),
          "review_package" => package
        ).reject { |key, _value| key == "digest" }
      )
      output, = evaluate(input.merge("review_package" => package, "rounds" => rounds))

      assert_equal "blocked", output.fetch("status")
      assert_includes output.fetch("reasons"), "new-consequential-finding-not-new"
    end
  end

  private

  def replay_case(name)
    fixture = JSON.parse(File.read(FIXTURES, encoding: "UTF-8"))
    fixture.fetch("cases").find { |entry| entry.fetch("name") == name }.fetch("expected") => expected
    { "expected" => expected }
  end

  def clean_review_input(directory)
    identity = TASK_IDENTITY
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
    File.write(
      findings_path,
      JSON.generate(
        "schema" => "review-finding-v0",
        "reviewer_id" => "reviewer-b",
        "review_receipt" => review_receipt,
        "review_findings" => []
      )
    )
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
      "review_package" => package,
      "worker_report" => report,
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
    initial_findings_path = write_findings(
      directory,
      "initial-findings.json",
      [finding("finding-1", head_sha: HEAD_SHA)]
    )
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
      "review_package" => package,
      "worker_report" => report,
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
        "review_package" => package,
        "worker_report" => report,
        "implementer_id" => "implementer-c"
      ).reject { |key, _value| key == "digest" }
    )
    input.merge("worker_report" => report, "review_package" => package, "rounds" => rounds)
  end

  def replacement_record(round: 1)
    {
      "identity" => TASK_IDENTITY,
      "round" => round,
      "prior_implementer_id" => "implementer-a",
      "replacement_implementer_id" => "implementer-c",
      "reason" => "continuation_unavailable",
      "prior_instance_stopped" => true,
      "ownership_reconciled" => true,
      "evidence" => ["coordination://issue-392/replacement-1"]
    }
  end

  def cap_input(directory)
    input = consequential_breakage_input(directory)
    open_finding = finding(
      "finding-2",
      consequential: true,
      independent_validation: {
        "status" => "confirmed",
        "validator" => "reviewer-b",
        "evidence" => ["fix-diff://finding-2"]
      }
    )
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
        "new_consequential_finding_ids" => ["finding-2"]
      ).reject { |key, _value| key == "digest" }
    )
    (2..4).each do |number|
      round_finding = finding(
        "finding-2",
        consequential: true,
        independent_validation: {
          "status" => "confirmed",
          "validator" => "reviewer-b",
          "evidence" => ["fix-diff://finding-2"]
        },
        head_sha: CAP_HEAD_SHAS.fetch(number)
      )
      round_findings_path = write_findings(directory, "cap-round-#{number}-findings.json", [round_finding])
      round_diff_path = File.join(directory, "cap-round-#{number}.diff")
      File.write(round_diff_path, "diff --git a/lib/task-review.rb b/lib/task-review.rb\n+cap fix #{number}\n")
      round_report = with_digest(
        input.fetch("worker_report").merge(
          "head_sha" => CAP_HEAD_SHAS.fetch(number),
          "commits" => CAP_HEAD_SHAS.first(number + 1)
        ).reject { |key, _value| key == "digest" }
      )
      round_package = with_digest(
        input.fetch("review_package").merge(
          "worker_report_digest" => round_report.fetch("digest"),
          "base_sha" => CAP_HEAD_SHAS.fetch(number - 1),
          "head_sha" => CAP_HEAD_SHAS.fetch(number),
          "expected_current_head_sha" => CAP_HEAD_SHAS.fetch(number),
          "commit_list" => [CAP_HEAD_SHAS.fetch(number)],
          "exact_diff" => artifact(round_diff_path).merge("truncated" => false),
          "prior_round_digest" => rounds.last.fetch("digest")
        ).reject { |key, _value| key == "digest" }
      )
      rounds << with_digest(
        "number" => number,
        "kind" => "fix_re_review",
        "package_digest" => round_package.fetch("digest"),
        "review_package" => round_package,
        "worker_report" => round_report,
        "base_sha" => CAP_HEAD_SHAS.fetch(number - 1),
        "head_sha" => CAP_HEAD_SHAS.fetch(number),
        "implementer_id" => "implementer-a",
        "reviewer_id" => "reviewer-b",
        "prior_round_digest" => rounds.last.fetch("digest"),
        "review_findings" => artifact(round_findings_path),
        "addressed_finding_ids" => [],
        "open_finding_ids" => ["finding-2"],
        "new_consequential_finding_ids" => []
      )
    end
    final_head = CAP_HEAD_SHAS.fetch(5)
    final_finding = finding(
      "finding-2",
      consequential: true,
      independent_validation: {
        "status" => "confirmed",
        "validator" => "reviewer-b",
        "evidence" => ["fix-diff://finding-2"]
      },
      head_sha: final_head
    )
    final_findings_path = write_findings(directory, "cap-round-5-findings.json", [final_finding])
    final_findings_artifact = artifact(final_findings_path)
    final_diff_path = File.join(directory, "cap-round-5.diff")
    File.write(final_diff_path, "diff --git a/lib/task-review.rb b/lib/task-review.rb\n+cap fix 5\n")
    report = with_digest(
      input.fetch("worker_report").merge(
        "head_sha" => final_head,
        "commits" => CAP_HEAD_SHAS
      ).reject { |key, _value| key == "digest" }
    )
    package = with_digest(
      input.fetch("review_package").merge(
        "worker_report_digest" => report.fetch("digest"),
        "base_sha" => CAP_HEAD_SHAS.fetch(4),
        "head_sha" => final_head,
        "expected_current_head_sha" => final_head,
        "commit_list" => [final_head],
        "exact_diff" => artifact(final_diff_path).merge("truncated" => false),
        "prior_round_digest" => rounds.last.fetch("digest")
      )
           .reject { |key, _value| key == "digest" }
    )
    rounds << with_digest(
      "number" => 5,
      "kind" => "fix_re_review",
      "package_digest" => package.fetch("digest"),
      "review_package" => package,
      "worker_report" => report,
      "base_sha" => CAP_HEAD_SHAS.fetch(4),
      "head_sha" => final_head,
      "implementer_id" => "implementer-a",
      "reviewer_id" => "reviewer-b",
      "prior_round_digest" => rounds.last.fetch("digest"),
      "review_findings" => final_findings_artifact,
      "addressed_finding_ids" => [],
      "open_finding_ids" => ["finding-2"],
      "new_consequential_finding_ids" => []
    )

    input.merge(
      "expected_current_head_sha" => final_head,
      "worker_report" => report,
      "review_package" => package,
      "rounds" => rounds,
      "open_findings" => final_findings_artifact.merge("ids" => ["finding-2"]),
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
    p0 = finding(
      "finding-2",
      severity: "P0",
      consequential: true,
      independent_validation: {
        "status" => "confirmed",
        "validator" => "reviewer-b",
        "evidence" => ["fix-diff://finding-2"]
      },
      head_sha: input.fetch("expected_current_head_sha")
    )
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
    historical_package = with_digest(
      rounds.fetch(0).fetch("review_package").merge("reviewer_id" => " IMPLEMENTER-A ")
            .reject { |key, _value| key == "digest" }
    )
    rounds[0] = with_digest(
      rounds.fetch(0).merge(
        "package_digest" => historical_package.fetch("digest"),
        "review_package" => historical_package,
        "reviewer_id" => " IMPLEMENTER-A "
      ).reject { |key, _value| key == "digest" }
    )
    package = with_digest(
      input.fetch("review_package").merge("prior_round_digest" => rounds.fetch(0).fetch("digest"))
           .reject { |key, _value| key == "digest" }
    )
    rounds[1] = with_digest(
      rounds.fetch(1).merge(
        "prior_round_digest" => rounds.fetch(0).fetch("digest"),
        "package_digest" => package.fetch("digest"),
        "review_package" => package
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
      "target" => TASK_IDENTITY.merge("head_sha" => head_sha),
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

  def review_receipt(head_sha: HEAD_SHA, base_sha: BASE_SHA)
    {
      "source" => "adversarial-pr-review",
      "target" => {
        "kind" => "committed",
        "base_ref" => "origin/main",
        "base_sha" => base_sha,
        "head_sha" => head_sha
      },
      "provenance" => { "engine" => "test", "invocation" => "test" },
      "risk_lenses" => [{ "name" => "correctness", "status" => "applied", "reason" => "test" }],
      "coverage" => {
        "status" => "complete",
        "included_paths" => ["lib/task-review.rb"],
        "excluded_paths" => [],
        "limitations" => []
      }
    }
  end

  def rebind_package(input, changes)
    package = with_digest(input.fetch("review_package").merge(changes).reject { |key, _value| key == "digest" })
    rounds = input.fetch("rounds").dup
    round_changes = { "package_digest" => package.fetch("digest"), "review_package" => package }
    round_changes["worker_report"] = input.fetch("worker_report") if input["review_state"] == "complete"
    rounds[-1] = with_digest(
      rounds.last.merge(round_changes)
            .reject { |key, _value| key == "digest" }
    )
    input.merge("review_package" => package, "rounds" => rounds)
  end

  def rebind_report(input, changes)
    report = with_digest(input.fetch("worker_report").merge(changes).reject { |key, _value| key == "digest" })
    rebind_package(input.merge("worker_report" => report), "worker_report_digest" => report.fetch("digest"))
  end

  def write_findings(directory, basename, findings, receipt: :auto)
    path = File.join(directory, basename)
    document = {
      "schema" => "review-finding-v0",
      "reviewer_id" => "reviewer-b",
      "review_findings" => findings
    }
    if receipt == :auto
      head_sha = findings.first&.dig("target", "head_sha") || HEAD_SHA
      head_index = CAP_HEAD_SHAS.index(head_sha)
      base_sha = head_index&.positive? ? CAP_HEAD_SHAS.fetch(head_index - 1) : BASE_SHA
      receipt = review_receipt(head_sha: head_sha, base_sha: base_sha)
    end
    document["review_receipt"] = receipt if receipt
    File.write(
      path,
      JSON.generate(document)
    )
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

  def evaluate(input, env = {})
    stdout, stderr, status = Open3.capture3(CAP_AUTHORITY_ENV.merge(env), HELPER, stdin_data: JSON.generate(input))
    assert status.success?, stderr
    [JSON.parse(stdout), stdout]
  end
end
