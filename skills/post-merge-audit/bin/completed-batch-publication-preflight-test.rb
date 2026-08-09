#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"

SCRIPT = File.expand_path("completed-batch-publication-preflight", __dir__)
FIXTURES = File.expand_path("../fixtures", __dir__)
load SCRIPT

class CompletedBatchPublicationPreflightTest < Minitest::Test
  BACKEND = "agent-coord private backend"

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, name), encoding: "UTF-8"))
  end

  def no_backend_input
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input["coordination_status"] = {
      "contract" => "completed-batch-coordination-not-applicable",
      "version" => 1,
      "batch_id" => input.fetch("batch_id"),
      "mode" => "single_operator",
      "rationale" => "repository workflow seam declares coordination_backend: n/a",
      "source" => "https://github.com/shakacode/agent-workflows/blob/fb33440cbad49808898c4a15f8c3e0c9276b7470/.agents/agent-workflow.yml",
      "completed_at" => "2026-07-31T11:40:00Z",
      "targets" => JSON.parse(JSON.generate(input.fetch("expected_targets")))
    }
    input
  end

  def no_pr_input
    input = fixture("completed-batch-publication-hichee-terminal.json")
    number = 10_036
    target = input.fetch("expected_targets").find { |row| row.fetch("number") == number }
    target["type"] = "issue"
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == [number.to_s] }
    lane["issue_url"] = lane.delete("pr_url").sub("/pull/", "/issues/")
    lane["pr_state"] = "closed"
    snapshot = input.fetch("target_snapshots").find { |row| row.dig("target", "number") == number }
    snapshot.fetch("target")["type"] = "issue"
    snapshot["state"] = "closed"
    snapshot["head_sha"] = "not_applicable"
    snapshot["no_pr_evidence"] = {
      "url" => "https://github.com/shakacode/hichee/issues/10036",
      "rationale" => "closed issue; no implementation PR was created",
      "target" => JSON.parse(JSON.generate(snapshot.fetch("target")))
    }
    qa = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == number }
    qa.fetch("target")["type"] = "issue"
    qa["evidence"] = <<~MARKER
      <!-- qa-evidence v1
      required: no
      status: not_applicable
      head_sha: not_applicable
      tested_at: issue #10036 closed with no implementation PR
      scope: issue-only closeout
      automated_checks: not applicable
      manual_checks: not applicable
      findings: none
      release_blocking: not_applicable
      process_gap_disposition: not_applicable
      -->
    MARKER
    input
  end

  def qa_v2_evidence(head_sha:, user_visible_ui_change:)
    ui_change = user_visible_ui_change == "yes"
    destination = ui_change ? "github_pr" : "not_applicable"
    visual_evidence = if ui_change
                        "durable: before and after https://github.com/shakacode/hichee/pull/10049#visual"
                      else
                        "not applicable: no user-visible UI change"
                      end
    paint_check = ui_change ? "passed: painted target inspected" : "not applicable: no painted surface changed"
    <<~MARKER
      <!-- qa-evidence v2
      required: yes
      status: satisfied
      head_sha: #{head_sha}
      tested_at: PR/head #{head_sha}
      scope: exact-head QA
      automated_checks: focused specs
      manual_checks: verified
      user_visible_ui_change: #{user_visible_ui_change}
      visual_evidence_destination: #{destination}
      visual_evidence: #{visual_evidence}
      paint_check: #{paint_check}
      interaction_change: no
      interaction_evidence: not applicable: no interaction changed
      visual_fix: no
      negative_control: not applicable: no visual fix
      performance_impact: not_applicable
      performance_evidence: not applicable: no rendered-page, asset, or bundle impact
      findings: none
      release_blocking: clear
      process_gap_disposition: checklist+replay
      -->
    MARKER
  end

  def assess_input(
    input,
    backend: BACKEND,
    waiver_verifier: valid_waiver_verifier(input),
    target_verifier: valid_target_verifier(input),
    coordination_verifier: valid_coordination_verifier(input, backend)
  )
    CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: backend,
      waiver_verifier:,
      target_verifier:,
      coordination_verifier:
    )
  end

  def valid_target_verifier(input)
    lambda do |target:|
      row = input.fetch("target_snapshots").find { |candidate| candidate.fetch("target") == target }
      next unless row

      raw_head_sha = row["head_sha"].to_s.downcase
      head_sha = raw_head_sha.match?(CompletedBatchPublicationPreflight::SHA_PATTERN) ? raw_head_sha : nil
      {
        "target" => target,
        "state" => row.fetch("state"),
        "head_sha" => head_sha,
        "completed_at" => row.fetch("completed_at", "2026-08-01T00:00:00Z"),
        "verification_source" => "authenticated gh api"
      }
    end
  end

  def valid_coordination_verifier(input, backend)
    expected_backend = backend
    lambda do |backend:, batch_id:|
      next unless backend == expected_backend && batch_id == input.fetch("batch_id")

      input.fetch("coordination_status")
    end
  end

  def valid_waiver_verifier(input)
    row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
    comment = row && valid_waiver_comment(row, input)
    lambda do |host:, repo:, comment_id:|
      next unless comment
      next unless host == "github.com" && repo == "shakacode/hichee"
      next unless comment_id == comment.fetch("id")

      comment
    end
  end

  def valid_waiver_comment(row, input)
    target = row.fetch("target")
    snapshot = input.fetch("target_snapshots").find { |candidate| candidate.fetch("target") == target }
    head_sha = snapshot.fetch("head_sha")
    url = row.dig("maintainer_waiver", "url")
    comment_id = Integer(url[/#issuecomment-(\d+)\z/, 1], 10)
    target_url = "https://github.com/#{target.fetch('repo')}/pull/#{target.fetch('number')}"
    body = <<~BODY
      Maintainer exact-head QA waiver.

      <!-- qa-maintainer-waiver v1
      target: #{target_url}
      head_sha: #{head_sha}
      decision: waived
      -->
    BODY
    {
      "id" => comment_id,
      "html_url" => url,
      "issue_url" => "https://api.github.com/repos/#{target.fetch('repo')}/issues/#{target.fetch('number')}",
      "body" => body,
      "user" => { "login" => "justin808", "type" => "User" },
      "author_association" => "MEMBER",
      "created_at" => "2026-07-31T12:00:00Z",
      "updated_at" => "2026-07-31T12:00:00Z"
    }
  end

  def legacy_input
    fixture("completed-batch-publication-ror-legacy.json")
  end

  def legacy_decision_url
    "https://github.com/shakacode/react_on_rails/issues/4605#issuecomment-6000000000"
  end

  def valid_legacy_decision_comment(input)
    reconciliation = input.fetch("legacy_reconciliation")
    source_input = CompletedBatchPublicationPreflight.canonicalize(input)
    targets = CompletedBatchPublicationPreflight.validated_target_set(
      input.fetch("expected_targets"),
      [],
      "expected target"
    )
    canonical_reconciliation = CompletedBatchPublicationPreflight.canonical_legacy_reconciliation(
      reconciliation,
      targets,
      [],
      batch_id: input.fetch("batch_id")
    )
    marker = CompletedBatchPublicationPreflight.legacy_decision_marker(
      batch_id: input.fetch("batch_id"),
      expected_targets: targets,
      source_input_digest: CompletedBatchPublicationPreflight.digest(source_input),
      reconciliation: canonical_reconciliation
    )
    body = "Maintainer acceptance of immutable legacy reconciliation.\n\n#{marker}\n"
    {
      "id" => 6_000_000_000,
      "html_url" => legacy_decision_url,
      "issue_url" => "https://api.github.com/repos/shakacode/react_on_rails/issues/4605",
      "body" => body,
      "user" => { "login" => "justin808", "type" => "User" },
      "author_association" => "MEMBER",
      "created_at" => "2026-08-09T04:00:00Z",
      "updated_at" => "2026-08-09T04:00:00Z"
    }
  end

  def valid_legacy_decision_verifier(input)
    comment = valid_legacy_decision_comment(input)
    lambda do |host:, repo:, comment_id:|
      next unless host == "github.com" && repo == "shakacode/react_on_rails"
      next unless comment_id == 6_000_000_000

      comment
    end
  end

  def valid_coordination_audit_verifier(input, backend)
    expected_backend = backend
    lambda do |backend:, batch_id:|
      next unless backend == expected_backend && batch_id == input.fetch("batch_id")

      input.fetch("coordination_audit")
    end
  end

  def valid_coordination_claim_verifier(input, backend)
    expected_backend = backend
    lambda do |backend:, target:|
      next unless backend == expected_backend

      input.fetch("coordination_claim_statuses")
           .find { |row| row.fetch("target") == target }
           &.fetch("status")
    end
  end

  def assess_legacy(
    input,
    decision_comment: valid_legacy_decision_comment(input),
    audit_verifier: nil,
    claim_verifier: valid_coordination_claim_verifier(input, BACKEND)
  )
    audit_verifier ||= valid_coordination_audit_verifier(input, BACKEND)
    CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: ->(**) {},
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      coordination_claim_verifier: claim_verifier,
      coordination_audit_verifier: audit_verifier,
      reconciliation_decision_url: legacy_decision_url,
      reconciliation_verifier: ->(**) { decision_comment }
    )
  end

  def with_fake_waiver_gh(input, mode: "success", author_permission: "write")
    Dir.mktmpdir("completed-batch-publication-preflight") do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      gh = File.join(bin, "gh")
      File.write(gh, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"

        File.open(ENV.fetch("FAKE_GH_LOG"), "a") { |file| file.puts(ARGV.join(" ")) }
        args = ARGV.dup
        abort "expected api" unless args.shift == "api"
        abort "expected --hostname" unless args.shift == "--hostname"
        host = args.shift
        endpoint = args.shift
        targets = JSON.parse(ENV.fetch("FAKE_GH_TARGETS"))
        target = targets.find do |candidate|
          candidate.fetch("host") == host && candidate.fetch("endpoint") == endpoint
        end

        if target
          puts JSON.generate(target.fetch("payload"))
        elsif endpoint == "repos/shakacode/hichee/collaborators/justin808/permission"
          puts JSON.generate(
            "permission" => ENV.fetch("FAKE_GH_AUTHOR_PERMISSION"),
            "user" => { "login" => "justin808", "type" => "User" }
          )
        elsif endpoint.include?("/issues/comments/")
          exit 1 if ENV.fetch("FAKE_GH_MODE") == "not_found"

          puts ENV.fetch("FAKE_GH_COMMENT")
        else
          abort "unexpected endpoint: #{host} #{endpoint}"
        end
      RUBY
      agent_coord = File.join(bin, "agent-coord")
      File.write(agent_coord, <<~'RUBY')
        #!/usr/bin/env ruby
        abort "unexpected agent-coord arguments" unless ARGV == ["status", "--batch-id", ENV.fetch("FAKE_BATCH_ID"), "--json"]

        puts ENV.fetch("FAKE_COORDINATION_STATUS")
      RUBY
      FileUtils.chmod("+x", gh)
      FileUtils.chmod("+x", agent_coord)
      row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
      targets = input.fetch("target_snapshots").map do |snapshot|
        target = snapshot.fetch("target")
        endpoint_type = target.fetch("type") == "pull_request" ? "pulls" : "issues"
        payload = {
          "number" => target.fetch("number"),
          "html_url" => "https://#{target.fetch('host')}/#{target.fetch('repo')}/" \
                        "#{target.fetch('type') == 'pull_request' ? 'pull' : 'issues'}/#{target.fetch('number')}",
          "state" => "closed",
          "closed_at" => "2026-08-01T00:00:00Z"
        }
        if target.fetch("type") == "pull_request"
          payload["merged_at"] = "2026-07-31T12:00:00Z"
          payload["head"] = { "sha" => snapshot.fetch("head_sha") }
        end
        {
          "host" => target.fetch("host"),
          "endpoint" => "repos/#{target.fetch('repo')}/#{endpoint_type}/#{target.fetch('number')}",
          "payload" => payload
        }
      end
      env = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "FAKE_GH_LOG" => File.join(directory, "gh.log"),
        "FAKE_GH_MODE" => mode,
        "FAKE_GH_AUTHOR_PERMISSION" => author_permission,
        "FAKE_GH_COMMENT" => JSON.generate(valid_waiver_comment(row, input)),
        "FAKE_GH_TARGETS" => JSON.generate(targets),
        "FAKE_BATCH_ID" => input.fetch("batch_id"),
        "FAKE_COORDINATION_STATUS" => JSON.generate(input.fetch("coordination_status"))
      }
      yield env
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def process_state(pid)
    stat_path = "/proc/#{pid}/stat"
    return process_alive?(pid) ? "present" : nil unless File.file?(stat_path)

    stat = File.read(stat_path, encoding: "UTF-8")
    closing_parenthesis = stat.rindex(") ")
    return "present" unless closing_parenthesis

    stat[(closing_parenthesis + 2)..].split.first
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def wait_for_process_exit(pid, timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 while process_state(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    process_state(pid).nil?
  end

  def test_capture_process_timeout_terminates_descendant_process_group
    Dir.mktmpdir("completed-batch-process-group") do |directory|
      descendant_pid_path = File.join(directory, "descendant.pid")
      wrapper = 'sleep 30 & descendant=$!; printf "%s\n" "$descendant" > "$1"; wait "$descendant"'
      descendant_pid = nil

      assert_raises(Timeout::Error) do
        CompletedBatchPublicationPreflight.capture_process(
          ["/bin/sh", "-c", wrapper, "process-group-wrapper", descendant_pid_path],
          input: "",
          timeout: 0.5
        )
      end
      descendant_pid = Integer(File.read(descendant_pid_path), 10)

      assert wait_for_process_exit(descendant_pid),
             "timed process descendant #{descendant_pid} survived process-group cleanup " \
             "with state #{process_state(descendant_pid).inspect}"
    ensure
      Process.kill("KILL", descendant_pid) if descendant_pid && process_alive?(descendant_pid)
    end
  end

  def test_capture_process_timeout_reaps_nested_descendant_layers
    Dir.mktmpdir("completed-batch-nested-process-group") do |directory|
      process_ids_path = File.join(directory, "process-ids")
      intermediate_program = <<~'RUBY'
        leaf_pid = Process.spawn("/bin/sleep", "30")
        File.write(ARGV.fetch(0), [Process.ppid, Process.pid, leaf_pid].join("\n") + "\n")
        Process.wait(leaf_pid)
      RUBY
      leader_program = <<~'RUBY'
        intermediate_pid = Process.spawn(RbConfig.ruby, "-e", ARGV.fetch(1), ARGV.fetch(0))
        Process.wait(intermediate_pid)
      RUBY
      helper_program = <<~'RUBY'
        load ARGV.shift
        begin
          CompletedBatchPublicationPreflight.capture_process(
            [RbConfig.ruby, "-rrbconfig", "-e", ARGV.fetch(1), ARGV.fetch(0), ARGV.fetch(2)],
            input: "",
            timeout: 0.5
          )
          exit 1
        rescue Timeout::Error
          exit 0
        end
      RUBY
      process_ids = []
      helper_pid = Process.spawn(
        RbConfig.ruby,
        "-rrbconfig",
        "-e",
        helper_program,
        SCRIPT,
        process_ids_path,
        leader_program,
        intermediate_program
      )

      _pid, helper_status = Process.wait2(helper_pid)
      assert_predicate helper_status, :success?
      process_ids = File.readlines(process_ids_path, chomp: true).map { |line| Integer(line, 10) }
      assert_equal 3, process_ids.length

      %w[leader intermediate leaf].zip(process_ids).each do |label, pid|
        assert wait_for_process_exit(pid),
               "timed nested #{label} #{pid} survived process-group cleanup " \
               "with state #{process_state(pid).inspect}"
      end
    ensure
      process_ids.reverse_each do |pid|
        Process.kill("KILL", pid) if process_alive?(pid)
      rescue Errno::EPERM
        nil
      end
    end
  end

  def test_capture_process_timeout_kills_term_resistant_group_leader
    Dir.mktmpdir("completed-batch-term-resistant") do |directory|
      child_pid_path = File.join(directory, "child.pid")
      program = 'trap("TERM") {}; File.write(ARGV.fetch(0), Process.pid.to_s); sleep 30'
      child_pid = nil
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(Timeout::Error) do
        CompletedBatchPublicationPreflight.capture_process(
          [RbConfig.ruby, "-e", program, child_pid_path],
          input: "",
          timeout: 0.5
        )
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      child_pid = Integer(File.read(child_pid_path), 10)

      assert_operator elapsed, :<, 3
      assert wait_for_process_exit(child_pid),
             "TERM-resistant process-group leader #{child_pid} survived KILL escalation"
    ensure
      Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
    end
  end

  def test_public_claim_comment_fallback_never_invokes_private_coordination
    calls = []
    capture = lambda do |command, input:, timeout:|
      calls << { "command" => command, "input" => input, "timeout" => timeout }
      payload = {
        "scope" => { "kind" => "batch", "batch_id" => "batch-public" },
        "batches" => []
      }
      [JSON.generate(payload), "", Struct.new(:success?).new(true)]
    end
    original_capture = CompletedBatchPublicationPreflight.method(:capture_process)
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &capture)

    [
      "public claim-comment fallback",
      " Public　claim-comment \n fallback. "
    ].each do |backend|
      result = CompletedBatchPublicationPreflight.authenticated_coordination_status(
        backend:,
        batch_id: "batch-public"
      )

      assert_nil result, backend.inspect
    end
    assert_empty calls

    input = fixture("completed-batch-publication-hichee-terminal.json")
    assessment = assess_input(
      input,
      backend: "public claim-comment fallback",
      coordination_verifier: CompletedBatchPublicationPreflight.method(:authenticated_coordination_status)
    )
    refute assessment.fetch("eligible")
    assert_includes assessment.fetch("blockers"), "coordination status is not authenticated or fresh"
    assert_empty calls
  ensure
    if original_capture
      CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &original_capture)
    end
  end

  def test_authenticated_raw_batch_audit_accepts_the_expected_incomplete_exit_status
    input = legacy_input
    audit = input.fetch("coordination_audit")
    calls = []
    capture = lambda do |command, input:, timeout:|
      calls << { "command" => command, "input" => input, "timeout" => timeout }
      [JSON.generate(audit), "", Struct.new(:exitstatus).new(1)]
    end
    original_capture = CompletedBatchPublicationPreflight.method(:capture_process)
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &capture)

    result = CompletedBatchPublicationPreflight.authenticated_coordination_audit(
      backend: BACKEND,
      batch_id: input.fetch("batch_id")
    )

    assert_equal audit, result
    assert_equal 1, calls.length
    assert_equal "batch-audit", calls.first.fetch("command").fetch(3)
  ensure
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &original_capture) if original_capture
  end

  def test_authenticated_claim_status_uses_a_bounded_exact_target_read
    input = legacy_input
    row = input.fetch("coordination_claim_statuses").find do |candidate|
      candidate.dig("target", "number") == 4279
    end
    calls = []
    capture = lambda do |command, input:, timeout:|
      calls << { "command" => command, "input" => input, "timeout" => timeout }
      [JSON.generate(row.fetch("status")), "", Struct.new(:success?).new(true)]
    end
    original_capture = CompletedBatchPublicationPreflight.method(:capture_process)
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &capture)

    result = CompletedBatchPublicationPreflight.authenticated_coordination_claim_status(
      backend: BACKEND,
      target: row.fetch("target")
    )

    assert_equal row.fetch("status"), result
    assert_equal [
      CompletedBatchPublicationPreflight::AGENT_COORD_BOUNDED,
      "--timeout", CompletedBatchPublicationPreflight::COORDINATION_TIMEOUT_SECONDS.to_s,
      "status", "--repo", "shakacode/react_on_rails", "--target", "4279", "--json"
    ], calls.fetch(0).fetch("command")
  ensure
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, &original_capture) if original_capture
  end

  def test_premature_hichee_publication_replays_blocked_for_coordination_target_and_qa
    result = assess_input(fixture("completed-batch-publication-hichee-premature.json"))

    refute result.fetch("eligible")
    assert_equal "BLOCKED", result.fetch("verdict")
    assert_includes result.fetch("blockers"), "coordination batch is not completed"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10036 coordination lane is nonterminal"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10036 target is not merged"
    [10_026, 10_048, 10_049].each do |number|
      assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:#{number} QA evidence is absent"
    end
    target_numbers = result.fetch("targets").map { |target| target.fetch("number") }
    assert_equal [10_026, 10_036, 10_048, 10_049], target_numbers
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.fetch("snapshot_digest"))
    assert_equal "sha256:2e73bd93cdf88b511d2865d9572d6e9ba4ee3c13a65bf8048f8cded7f37e5ca5",
                 result.fetch("snapshot_digest")
  end

  def test_digest_bound_legacy_reconciliation_accepts_exact_missing_history_and_open_deferral
    input = legacy_input

    result = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: ->(**) {},
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      coordination_claim_verifier: valid_coordination_claim_verifier(input, BACKEND),
      coordination_audit_verifier: valid_coordination_audit_verifier(input, BACKEND),
      reconciliation_decision_url: legacy_decision_url,
      reconciliation_verifier: valid_legacy_decision_verifier(input)
    )

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal "accepted_legacy_reconciliation", result.fetch("completion_mode")
    assert_equal "accepted_legacy_reconciliation", result.dig("snapshot", "completion_mode")
    lanes = result.dig("snapshot", "coordination", "lanes")
    issue_only_merged = lanes.find { |row| row.fetch("name") == "d4605" }
    assert_equal "issue", issue_only_merged.dig("target", "type")
    assert_equal "merged", issue_only_merged.fetch("target_state")
    mixed_merged = lanes.select { |row| row.fetch("name") == "d4274" }
    assert_equal %w[issue pull_request], mixed_merged.map { |row| row.dig("target", "type") }.sort
    assert_equal ["merged"], mixed_merged.map { |row| row.fetch("target_state") }.uniq
    deferred = result.dig("snapshot", "targets").find { |row| row.dig("target", "number") == 4279 }
    assert_equal "open", deferred.fetch("state")
    assert_equal "accepted_deferral", deferred.fetch("disposition")
    assert_equal "justin808", deferred.fetch("disposition_owner")
    assert_equal legacy_decision_url, result.dig("snapshot", "legacy_reconciliation", "decision", "url")
    assert CompletedBatchPublicationPreflight.valid_receipt?(result)
    assert CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: BACKEND,
      waiver_verifier: valid_legacy_decision_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      coordination_claim_verifier: valid_coordination_claim_verifier(input, BACKEND),
      coordination_audit_verifier: valid_coordination_audit_verifier(input, BACKEND)
    )
  end

  def test_legacy_claim_gap_rejects_degraded_batch_claims_without_targeted_claim_evidence
    input = legacy_input
    input.delete("coordination_claim_statuses")

    result = assess_legacy(input, claim_verifier: nil)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "legacy reconciliation claims evidence is absent or does not cover the exact target manifest"
  end

  def test_legacy_claim_gap_requires_targeted_claim_evidence_for_every_manifest_target
    input = legacy_input
    input.fetch("coordination_claim_statuses").pop

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "legacy reconciliation claims evidence is absent or does not cover the exact target manifest"
  end

  def test_legacy_claim_gap_rejects_a_stale_targeted_claim_snapshot
    input = legacy_input
    captured = valid_coordination_claim_verifier(input, BACKEND)
    verifier = lambda do |backend:, target:|
      fresh = JSON.parse(JSON.generate(captured.call(backend:, target:)))
      fresh["events"] = [{ "kind" => "claim.released", "target" => target.fetch("number").to_s }]
      fresh
    end

    result = assess_legacy(input, claim_verifier: verifier)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "legacy reconciliation targeted claims evidence is not authenticated or fresh"
  end

  def test_legacy_claim_gap_cannot_mask_an_active_claim_from_another_batch
    input = legacy_input
    target_status = input.fetch("coordination_claim_statuses")
                         .find { |row| row.dig("target", "number") == 4279 }
                         .fetch("status")
    target_status["claims"] = [{
      "repo" => "shakacode/react_on_rails",
      "target" => "4279",
      "status" => "active",
      "batch_id" => "another-live-batch"
    }]

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/react_on_rails#issue:4279 has active coordination claim from batch another-live-batch"
    assert_equal [], input.dig("coordination_status", "claims"),
                 "the degraded batch-scoped omission must not mask the targeted active claim"
  end

  def test_legacy_claim_gap_rejects_a_target_read_whose_claims_section_is_degraded
    input = legacy_input
    target_status = input.fetch("coordination_claim_statuses").first.fetch("status")
    target_status.fetch("section_notes")["claims"] = "not checked in target scope"

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "legacy reconciliation targeted claims evidence is malformed or degraded"
  end

  def test_legacy_reconciliation_rejects_missing_raw_batch_audit
    input = legacy_input
    input.delete("coordination_audit")

    result = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: ->(**) {},
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND),
      coordination_claim_verifier: valid_coordination_claim_verifier(input, BACKEND),
      reconciliation_decision_url: legacy_decision_url,
      reconciliation_verifier: valid_legacy_decision_verifier(input)
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "raw coordination batch audit is absent or invalid"
  end

  def test_legacy_reconciliation_decision_is_exact_digest_bound_and_unchanged
    mutations = [
      ->(comment) { comment["body"] = comment.fetch("body").sub(/source_input_digest: sha256:[0-9a-f]+/, "source_input_digest: sha256:#{'0' * 64}") },
      ->(comment) { comment["body"] = comment.fetch("body").sub("ror-d-roadmap-evidence-20260715", "wrong-batch") },
      ->(comment) { comment["html_url"] = comment.fetch("html_url").sub("/4605#", "/4279#") },
      ->(comment) { comment["issue_url"] = comment.fetch("issue_url").sub("/4605", "/4279") },
      ->(comment) { comment["updated_at"] = "2026-08-09T04:01:00Z" }
    ]

    mutations.each_with_index do |mutate, index|
      input = legacy_input
      comment = valid_legacy_decision_comment(input)
      mutate.call(comment)
      result = assess_legacy(input, decision_comment: comment)

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "authenticated legacy reconciliation decision is absent, stale, or mismatched",
                      index
    end
  end

  def test_legacy_reconciliation_decision_rejects_semantically_equal_noncanonical_marker_bytes
    mutations = {
      "reordered fields" => lambda do |body|
        body.sub(/repository: ([^\n]+)\nbatch_status: ([^\n]+)/, "batch_status: \\2\nrepository: \\1")
      end,
      "alternate JSON whitespace" => lambda do |body|
        body.sub(/expected_targets: \[/, "expected_targets: [ ")
      end,
      "duplicate JSON key" => lambda do |body|
        body.sub('"fact":"batch.completed"', '"fact":"batch.completed","fact":"batch.completed"')
      end,
      "alternate JSON Unicode escape" => lambda do |body|
        body.sub('expected_targets: ["https', 'expected_targets: ["\\u0068ttps')
      end
    }

    mutations.each do |label, mutate|
      input = legacy_input
      comment = valid_legacy_decision_comment(input)
      comment["body"] = mutate.call(comment.fetch("body"))

      result = assess_legacy(input, decision_comment: comment)

      refute result.fetch("eligible"), label
      assert_includes result.fetch("blockers"),
                      "authenticated legacy reconciliation decision is absent, stale, or mismatched",
                      label
    end
  end

  def test_legacy_reconciliation_decision_requires_a_trusted_human_with_write_authority
    mutations = [
      ->(comment) { comment.fetch("user")["type"] = "Bot" },
      ->(comment) { comment.fetch("user")["login"] = "reconcile[bot]" },
      ->(comment) { comment["author_association"] = "NONE" }
    ]
    mutations.each_with_index do |mutate, index|
      input = legacy_input
      comment = valid_legacy_decision_comment(input)
      mutate.call(comment)
      result = assess_legacy(input, decision_comment: comment)

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "authenticated legacy reconciliation decision is absent, stale, or mismatched",
                      index
    end

    input = legacy_input
    no_permission = assess_legacy(input, decision_comment: nil)
    refute no_permission.fetch("eligible")
    assert_includes no_permission.fetch("blockers"),
                    "authenticated legacy reconciliation decision is absent, stale, or mismatched"
  end

  def test_legacy_reconciliation_requires_fresh_exact_raw_batch_audit_and_missing_fact_match
    input = legacy_input
    stale_audit = JSON.parse(JSON.generate(input.fetch("coordination_audit")))
    stale_audit.fetch("lanes").first["event_count"] += 1
    stale_result = assess_legacy(
      input,
      audit_verifier: ->(**) { stale_audit }
    )

    refute stale_result.fetch("eligible")
    assert_includes stale_result.fetch("blockers"), "raw coordination batch audit is not authenticated or fresh"

    input = legacy_input
    input.fetch("coordination_audit").fetch("lanes").first.fetch("missing").delete("terminal")
    mismatch = assess_legacy(input)
    refute mismatch.fetch("eligible")
    assert_includes mismatch.fetch("blockers"),
                    "legacy reconciliation missing facts do not match the raw coordination batch audit"
  end

  def test_legacy_reconciliation_rejects_live_contradictions
    input = legacy_input
    batch = input.dig("coordination_status", "batches", 0)
    batch["status"] = "completed"
    batch["completed_at"] = "2026-08-09T04:00:00Z"
    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "legacy reconciliation contradicts a completed coordination batch"
  end

  def test_legacy_reconciliation_rejects_a_completion_timestamp_without_completed_status
    input = legacy_input
    input.dig("coordination_status", "batches", 0)["completed_at"] = "2026-08-09T04:00:00Z"

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "legacy reconciliation batch completion timestamp contradicts its declared missing fact"
  end

  def test_legacy_reconciliation_rejects_coordination_projection_that_contradicts_authenticated_terminal_audit
    input = legacy_input
    lane = input.dig("coordination_status", "batches", 0, "lanes").find { |row| row["name"] == "d4605" }
    lane["status"] = "abandoned"

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/react_on_rails#issue:4605 coordination projection contradicts its terminal audit"
  end

  def test_legacy_reconciliation_rejects_an_undeclared_missing_lane_close_timestamp
    input = legacy_input
    input.fetch("legacy_reconciliation").fetch("missing_facts")
         .reject! { |row| row["fact"] == "lane.closed_at" && row["lane"] == "d4279" }

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane d4279 close timestamp is absent without an accepted legacy missing fact"
  end

  def test_legacy_reconciliation_rejects_a_lane_close_timestamp_that_contradicts_the_declared_gap
    input = legacy_input
    input.dig("coordination_status", "batches", 0, "lanes")
         .find { |lane| lane.fetch("name") == "d4279" }["closed_at"] = "2026-08-03T09:35:00Z"

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane d4279 close timestamp contradicts its accepted legacy missing fact"
  end

  def test_legacy_reconciliation_rejects_nonfinite_or_terminally_contradictory_lane_outcomes
    %w[closed blocked-user-input].each do |outcome|
      input = legacy_input
      input.dig("coordination_status", "batches", 0, "lanes")
           .find { |lane| lane.fetch("name") == "d4271" }["pr_state"] = outcome

      result = assess_legacy(input)

      refute result.fetch("eligible"), outcome
      assert_includes result.fetch("blockers"),
                      "coordination lane d4271 legacy target outcome is invalid or contradicts its terminal state",
                      outcome
    end
  end

  def test_legacy_reconciliation_rejects_no_pr_for_a_multi_target_lane_that_contains_a_pull_request
    input = legacy_input
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |candidate| candidate.fetch("name") == "d4274" }
    assert_equal %w[4274 4282], lane.fetch("targets")
    lane["pr_state"] = "no-pr"

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane d4274 legacy target outcome is invalid or contradicts its terminal state"
  end

  def test_legacy_reconciliation_rejects_an_invalid_lane_evidence_url
    input = legacy_input
    input.dig("coordination_status", "batches", 0, "lanes")
         .find { |lane| lane.fetch("name") == "d4271" }["evidence_url"] = "file:///tmp/not-durable"

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "coordination lane d4271 legacy evidence URL is absent or invalid"
  end

  def test_open_issue_remains_rejected_without_authenticated_accepted_deferral
    input = legacy_input
    input.delete("legacy_reconciliation")
    input.delete("coordination_audit")
    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "shakacode/react_on_rails#issue:4279 target is not closed"
  end

  def test_legacy_reconciliation_rejects_any_unmanifested_lane_target
    input = legacy_input
    input.fetch("expected_targets").reject! { |target| target.fetch("number") == 4282 }
    input.fetch("target_snapshots").reject! { |row| row.dig("target", "number") == 4282 }
    input.fetch("qa_evidence").reject! { |row| row.dig("target", "number") == 4282 }
    reconciliation = input.fetch("legacy_reconciliation")
    reconciliation.fetch("target_dispositions").reject! { |row| row.dig("target", "number") == 4282 }
    reconciliation.fetch("missing_facts").select { |row| row["lane"] == "d4274" }.each do |row|
      row.fetch("targets").reject! { |target| target.fetch("number") == 4282 }
    end

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "coordination lane d4274 target is absent or ambiguous"
    assert_includes result.fetch("blockers"),
                    "shakacode/react_on_rails#issue:4274 is absent from resolved coordination scope"
  end

  def test_legacy_missing_fact_must_bind_the_exact_multi_target_lane_set
    input = legacy_input
    fact = input.fetch("legacy_reconciliation").fetch("missing_facts")
                .find { |row| row["fact"] == "lane.closed_at" && row["lane"] == "d4274" }
    fact.fetch("targets").reject! { |target| target.fetch("number") == 4282 }

    result = assess_legacy(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "legacy reconciliation missing fact does not match the exact coordination lane target set"
  end

  def test_legacy_missing_facts_require_exact_path_reason_and_ordinary_gate
    mutations = [
      ->(fact) { fact.delete("path") },
      ->(fact) { fact["path"] = "coordination_audit.lanes[other].missing[claim.acquired]" },
      ->(fact) { fact.delete("reason") },
      ->(fact) { fact["ordinary_gate"] = "UNKNOWN" }
    ]
    mutations.each_with_index do |mutate, index|
      input = legacy_input
      fact = input.fetch("legacy_reconciliation").fetch("missing_facts").find { |row| row["lane"] == "d4605" }
      mutate.call(fact)
      result = assess_legacy(input, decision_comment: nil)

      refute result.fetch("eligible"), index
      assert(result.fetch("blockers").any? { |blocker| blocker.start_with?("legacy reconciliation missing fact") }, index)
    end
  end

  def test_legacy_artifact_binds_repository_status_workflow_version_creation_time_and_owner
    metadata_mutations = [
      ->(record) { record["repository"] = "shakacode/other" },
      ->(record) { record["workflow_version"] = "completed-batch-publication-preflight:v0" },
      ->(record) { record["created_at"] = "not-a-time" }
    ]
    metadata_mutations.each_with_index do |mutate, index|
      input = legacy_input
      mutate.call(input.fetch("legacy_reconciliation"))
      result = assess_legacy(input, decision_comment: nil)

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "legacy reconciliation repository, status, workflow version, or creation time is invalid",
                      index
    end

    input = legacy_input
    input.fetch("legacy_reconciliation")["batch_status"] = "completed"
    status_mismatch = assess_legacy(input)
    refute status_mismatch.fetch("eligible")
    assert_includes status_mismatch.fetch("blockers"),
                    "legacy reconciliation batch status does not match fresh coordination status"

    input = legacy_input
    deferred = input.fetch("legacy_reconciliation").fetch("target_dispositions")
                    .find { |row| row.fetch("disposition") == "accepted_deferral" }
    deferred.delete("owner")
    missing_owner = assess_legacy(input, decision_comment: nil)
    refute missing_owner.fetch("eligible")
    assert(missing_owner.fetch("blockers").any? { |blocker| blocker.include?("target disposition") })
  end

  def test_real_premature_marker_fixture_preserves_reported_hash_and_is_not_well_formed
    marker = File.read(
      File.join(FIXTURES, "completed-batch-publication-hichee-premature-marker.txt"),
      encoding: "UTF-8"
    )

    assert_equal "5ede1b523b283a091d74ce51a429a4d5fde200404cc37ae8c5eff32f6e0e6352",
                 Digest::SHA256.hexdigest(marker)
  end

  def test_four_terminal_reconciled_lanes_pass_with_exact_head_dispositions
    result = assess_input(fixture("completed-batch-publication-hichee-terminal.json"))

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal "ELIGIBLE", result.fetch("verdict")
    assert_empty result.fetch("blockers")
    target_numbers = result.fetch("targets").map { |target| target.fetch("number") }
    assert_equal [10_026, 10_036, 10_048, 10_049], target_numbers
    assert_equal(
      %w[WAIVED SATISFIED NOT_APPLICABLE SATISFIED],
      result.dig("snapshot", "qa").map { |qa| qa.fetch("verdict") }
    )
    waiver = result.dig("snapshot", "qa").first.fetch("maintainer_waiver")
    expected_body = valid_waiver_comment(
      fixture("completed-batch-publication-hichee-terminal.json").fetch("qa_evidence").last,
      fixture("completed-batch-publication-hichee-terminal.json")
    ).fetch("body")
    assert_equal 5_000_000_000, waiver.fetch("comment_id")
    assert_equal "justin808", waiver.fetch("author")
    assert_equal "MEMBER", waiver.fetch("author_association")
    assert_equal Digest::SHA256.hexdigest(expected_body), waiver.fetch("body_sha256")
    assert_equal "57e048ed10551eb3cf8414a4de0064443bef730d", waiver.fetch("head_sha")
    assert_equal 10_026, waiver.dig("target", "number")
    refute(result.dig("snapshot", "targets").any? { |target| target.key?("completed_at") })
    assert CompletedBatchPublicationPreflight.valid_receipt?(result)
    assert_equal "sha256:a926d6266be958f222901d99cdcd78e3e3fd6148f575971922d66d491d16a5da",
                 result.fetch("snapshot_digest")
  end

  def test_abandoned_or_superseded_lane_accepts_later_authenticated_target_completion_without_rewriting_closeout
    %w[abandoned superseded].each do |terminal_state|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      lane = input.dig("coordination_status", "batches", 0, "lanes")
                  .find { |row| row.fetch("targets") == ["10048"] }
      lane["status"] = terminal_state
      lane["terminal"] = terminal_state
      lane.delete("pr_state")
      lane.delete("evidence_url")

      result = assess_input(input)

      assert result.fetch("eligible"), result.fetch("blockers").join("\n")
      reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                              .find { |row| row.dig("target", "number") == 10_048 }
      assert_equal terminal_state, reconciled_lane.fetch("status")
      assert_equal terminal_state, reconciled_lane.fetch("terminal")
      assert_equal "authenticated_target_after_coordination_closeout",
                   reconciled_lane.fetch("completion_mode")
      reconciled_target = result.dig("snapshot", "targets")
                                .find { |row| row.dig("target", "number") == 10_048 }
      assert_equal "2026-08-01T00:00:00Z", reconciled_target.fetch("completed_at")
      assert_nil reconciled_lane.fetch("target_state")
      assert_nil reconciled_lane.fetch("evidence")
    end
  end

  def test_abandoned_issue_lane_accepts_later_authenticated_close
    input = no_pr_input
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10036"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                            .find { |row| row.dig("target", "number") == 10_036 }
    assert_equal "issue", reconciled_lane.dig("target", "type")
    assert_equal "authenticated_target_after_coordination_closeout",
                 reconciled_lane.fetch("completion_mode")
  end

  def test_abandoned_lane_stays_blocked_when_target_is_not_later_completed
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")
    input.fetch("target_snapshots")
         .find { |row| row.dig("target", "number") == 10_048 }["state"] = "open"

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination target state is not merged"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10048 target is not merged"
  end

  def test_abandoned_lane_stays_blocked_when_target_completed_before_coordination_closeout
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")
    input.fetch("target_snapshots")
         .find { |row| row.dig("target", "number") == 10_048 }["completed_at"] = "2026-07-30T08:43:03Z"

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination target state is not merged"
    reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                            .find { |row| row.dig("target", "number") == 10_048 }
    refute reconciled_lane.key?("completion_mode")
  end

  def test_abandoned_lane_cannot_reuse_pre_closeout_coordination_state_and_evidence
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    input.fetch("target_snapshots")
         .find { |row| row.dig("target", "number") == 10_048 }["completed_at"] = "2026-07-30T08:43:03Z"

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 target completion is not authenticated after " \
                    "coordination closeout"
  end

  def test_abandoned_lane_preserves_historical_open_state_when_target_later_authenticates_as_merged
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane["pr_state"] = "open"
    lane.delete("evidence_url")

    result = assess_input(input)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    reconciled_lane = result.dig("snapshot", "coordination", "lanes")
                            .find { |row| row.dig("target", "number") == 10_048 }
    assert_equal "open", reconciled_lane.fetch("target_state")
    assert_equal "authenticated_target_after_coordination_closeout",
                 reconciled_lane.fetch("completion_mode")
  end

  def test_authenticated_target_completion_does_not_rescue_nonterminal_lane
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "in_progress"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination lane is nonterminal"
    refute_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 target completion is not authenticated after " \
                    "coordination closeout"
  end

  def test_abandoned_lane_stays_blocked_without_authenticated_target_completion
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input, target_verifier: ->(target:) {})

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 target state/head is not authenticated or fresh"
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination target state is not merged"
  end

  def test_authenticated_target_completion_does_not_rescue_invalid_terminal_timestamp
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane["status"] = "abandoned"
    lane["terminal"] = "abandoned"
    lane["closed_at"] = nil
    lane.delete("pr_state")
    lane.delete("evidence_url")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination lane is nonterminal"
  end

  def test_done_lane_still_requires_coordination_terminal_evidence
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes")
                .find { |row| row.fetch("targets") == ["10048"] }
    lane.delete("evidence_url")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10048 coordination terminal evidence is absent"
  end

  def test_assess_fails_closed_without_live_target_and_coordination_verifiers
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input)
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "coordination status is not authenticated or fresh"
    input.fetch("expected_targets").each do |target|
      assert_includes result.fetch("blockers"),
                      "#{target.fetch('repo')}##{target.fetch('type')}:#{target.fetch('number')} " \
                      "target state/head is not authenticated or fresh"
    end
  end

  def test_snapshot_is_deterministic_under_source_array_reordering
    input = fixture("completed-batch-publication-hichee-terminal.json")
    baseline = assess_input(input)
    input.fetch("expected_targets").reverse!
    input.fetch("target_snapshots").rotate!
    input.fetch("qa_evidence").reverse!
    input.dig("coordination_status", "batches", 0, "lanes").rotate!
    replay = assess_input(input)

    assert_equal baseline.fetch("snapshot"), replay.fetch("snapshot")
    assert_equal baseline.fetch("snapshot_digest"), replay.fetch("snapshot_digest")
  end

  def test_receipt_binds_the_exact_raw_source_input
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)

    assert_equal CompletedBatchPublicationPreflight.canonicalize(input), result.fetch("source_input")
    assert_equal BACKEND, result.fetch("coordination_backend")
    assert_equal BACKEND, result.dig("snapshot", "coordination_backend")
    assert_equal CompletedBatchPublicationPreflight.digest(result.fetch("source_input")),
                 result.fetch("source_input_digest")
  end

  def test_reassessment_rejects_altered_raw_input_even_with_recomputed_digests
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)
    result.dig("source_input", "target_snapshots", 0)["head_sha"] = "b" * 40
    result["source_input_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("source_input"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND)
    )
  end

  def test_reassessment_rejects_source_input_coordination_mode_mismatch_with_recomputed_digests
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)
    result.fetch("source_input")["coordination_status"] = no_backend_input.fetch("coordination_status")
    result["source_input_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("source_input"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    assert CompletedBatchPublicationPreflight.valid_receipt?(result),
           "integrity digests alone must not authenticate the source-input backend mode"
    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: BACKEND,
      waiver_verifier: valid_waiver_verifier(input),
      target_verifier: valid_target_verifier(input),
      coordination_verifier: valid_coordination_verifier(input, BACKEND)
    )
  end

  def test_reassessment_rejects_trusted_backend_mismatch_before_live_refresh
    input = fixture("completed-batch-publication-hichee-terminal.json")
    result = assess_input(input)
    target_calls = []
    coordination_calls = []

    refute CompletedBatchPublicationPreflight.reassessed_receipt_valid?(
      result,
      coordination_backend: "n/a",
      waiver_verifier: ->(**) { flunk "waiver verifier must not run" },
      target_verifier: lambda { |**args|
        target_calls << args
        flunk "target verifier must not run"
      },
      coordination_verifier: lambda { |**args|
        coordination_calls << args
        flunk "coordination verifier must not run"
      }
    )
    assert_empty target_calls
    assert_empty coordination_calls
  end

  def test_unknown_and_in_progress_qa_block_completion
    %w[unknown in_progress].each do |status|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      qa = input.fetch("qa_evidence").first
      qa["evidence"] = qa.fetch("evidence")
                         .sub("status: satisfied", "status: #{status}")
                         .sub("release_blocking: clear", "release_blocking: blocked")
      result = assess_input(input)

      refute result.fetch("eligible"), status
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#pull_request:10049 QA disposition is #{status}", status
    end
  end

  def test_trusted_current_ui_classification_requires_visual_evidence_v2
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.fetch("qa_evidence").each { |row| row["user_visible_ui_change"] = "no" }
    qa = input.fetch("qa_evidence").first
    qa["user_visible_ui_change"] = "yes"
    qa["evidence"] = qa.fetch("evidence").sub(
      "scope: PR #10049 exact-head checks",
      "scope: current user-visible UI change"
    )

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10049 QA disposition is UNKNOWN"
    snapshot = result.dig("snapshot", "qa").find { |row| row.dig("target", "number") == 10_049 }
    assert_equal "yes", snapshot.fetch("user_visible_ui_change")
    assert_equal "UNKNOWN", snapshot.fetch("verdict")
  end

  def test_visual_evidence_v2_must_match_the_trusted_ui_classification
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.fetch("qa_evidence").each { |row| row["user_visible_ui_change"] = "no" }
    qa = input.fetch("qa_evidence").first
    qa["user_visible_ui_change"] = "yes"
    head_sha = input.fetch("target_snapshots").first.fetch("head_sha")
    qa["evidence"] = qa_v2_evidence(head_sha:, user_visible_ui_change: "no")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10049 QA UI classification contradicts trusted input"
  end

  def test_non_ui_v1_remains_eligible_and_v2_must_not_self_classify_as_ui
    input = fixture("completed-batch-publication-hichee-terminal.json")
    v1_result = assess_input(input)

    assert v1_result.fetch("eligible"), v1_result.fetch("blockers").join("\n")
    assert_equal(
      ["no"] * 4,
      v1_result.dig("snapshot", "qa").map { |row| row.fetch("user_visible_ui_change") }
    )

    qa = input.fetch("qa_evidence").first
    head_sha = input.fetch("target_snapshots").first.fetch("head_sha")
    qa["evidence"] = qa_v2_evidence(head_sha:, user_visible_ui_change: "yes")
    v2_result = assess_input(input)

    refute v2_result.fetch("eligible")
    assert_includes v2_result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10049 QA UI classification contradicts trusted input"
  end

  def test_missing_or_invalid_trusted_ui_classification_blocks
    [nil, "true", true, "YES", "UNKNOWN"].each do |classification|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      input.fetch("qa_evidence").each { |row| row["user_visible_ui_change"] = "no" }
      qa = input.fetch("qa_evidence").first
      if classification.nil?
        qa.delete("user_visible_ui_change")
      else
        qa["user_visible_ui_change"] = classification
      end

      result = assess_input(input)

      refute result.fetch("eligible"), classification.inspect
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#pull_request:10049 trusted QA UI classification is absent or invalid",
                      classification.inspect
    end
  end

  def test_closed_issue_without_pr_uses_typed_no_pr_evidence_instead_of_a_fabricated_sha
    input = no_pr_input
    number = 10_036
    snapshot = input.fetch("target_snapshots").find { |row| row.dig("target", "number") == number }

    result = assess_input(input)

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    issue_snapshot = result.dig("snapshot", "targets").find { |row| row.dig("target", "number") == number }
    assert_nil issue_snapshot.fetch("head_sha")
    assert_equal snapshot.fetch("no_pr_evidence"), issue_snapshot.fetch("no_pr_evidence")
    issue_qa = result.dig("snapshot", "qa").find { |row| row.dig("target", "number") == number }
    assert_equal "NOT_APPLICABLE", issue_qa.fetch("verdict")
  end

  def test_no_pr_issue_rejects_head_bound_satisfied_qa
    input = no_pr_input
    fabricated_head = "a" * 40
    qa = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == 10_036 }
    qa["evidence"] = qa.fetch("evidence")
                       .sub("required: no", "required: yes")
                       .sub("status: not_applicable", "status: satisfied")
                       .sub("head_sha: not_applicable", "head_sha: #{fabricated_head}")
                       .sub(
                         "tested_at: issue #10036 closed with no implementation PR",
                         "tested_at: PR/head #{fabricated_head}"
                       )
                       .sub("release_blocking: not_applicable", "release_blocking: clear")

    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#issue:10036 QA evidence contradicts typed no-PR disposition"
  end

  def test_no_pr_evidence_fails_closed_for_forged_url_target_or_rationale
    mutations = [
      ->(evidence) { evidence["url"] = evidence.fetch("url").sub("10036", "10048") },
      ->(evidence) { evidence.fetch("target")["number"] = 10_048 },
      ->(evidence) { evidence["rationale"] = "UNKNOWN" }
    ]

    mutations.each_with_index do |mutate, index|
      input = no_pr_input
      evidence = input.fetch("target_snapshots")
                      .find { |row| row.dig("target", "number") == 10_036 }
                      .fetch("no_pr_evidence")
      mutate.call(evidence)

      result = assess_input(input)

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#issue:10036 no-PR evidence is invalid or inconsistent",
                      index
    end
  end

  def test_waived_qa_requires_replayable_maintainer_waiver
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.fetch("qa_evidence").last.delete("maintainer_waiver")
    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable"
  end

  def test_forged_nonexistent_maintainer_waiver_comment_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    qa = input.fetch("qa_evidence").find { |row| row.key?("maintainer_waiver") }
    original_url = qa.dig("maintainer_waiver", "url")
    forged_url = "https://github.com/shakacode/hichee/pull/10026#issuecomment-999999999999999999"
    qa["evidence"] = qa.fetch("evidence").sub(original_url, forged_url)
    qa["maintainer_waiver"] = { "url" => forged_url }

    result = assess_input(input, waiver_verifier: ->(**_keywords) {})

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable"
  end

  def test_checker_reported_nonexistent_comment_and_caller_asserted_metadata_block
    input = fixture("completed-batch-publication-hichee-terminal.json")
    formerly_waived = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == 10_026 }
    satisfied_evidence = formerly_waived.fetch("evidence").sub("status: waived", "status: satisfied")
    satisfied_evidence = satisfied_evidence.sub(/findings: waived: .+/, "findings: none")
    satisfied_evidence = satisfied_evidence.sub("release_blocking: waived", "release_blocking: clear")
    formerly_waived["evidence"] = satisfied_evidence
    formerly_waived.delete("maintainer_waiver")

    forged_url = "https://github.com/shakacode/hichee/issues/10036#issuecomment-999999999999999999"
    newly_waived = input.fetch("qa_evidence").find { |row| row.dig("target", "number") == 10_036 }
    waived_evidence = newly_waived.fetch("evidence").sub("status: satisfied", "status: waived")
    waived_evidence = waived_evidence.sub("findings: none", "findings: waived: #{forged_url}")
    waived_evidence = waived_evidence.sub("release_blocking: clear", "release_blocking: waived")
    newly_waived["evidence"] = waived_evidence
    newly_waived["maintainer_waiver"] = {
      "url" => forged_url,
      "author" => "fabricated-maintainer",
      "author_association" => "MEMBER",
      "body_sha256" => "f" * 64
    }

    result = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10036 maintainer QA waiver is not replayable"
  end

  def test_authenticated_waiver_comment_metadata_and_marker_mismatches_block
    mutations = [
      ->(comment) { comment["id"] += 1 },
      ->(comment) { comment["html_url"] = comment.fetch("html_url").sub("5000000000", "5000000001") },
      ->(comment) { comment["issue_url"] = comment.fetch("issue_url").sub("10026", "10036") },
      ->(comment) { comment["author_association"] = "NONE" },
      ->(comment) { comment.fetch("user")["type"] = "Bot" },
      ->(comment) { comment["body"] = comment.fetch("body").sub("decision: waived", "decision: denied") },
      ->(comment) { comment["body"] = comment.fetch("body").sub("57e048ed", "67e048ed") },
      ->(comment) { comment["body"] = comment.fetch("body").sub("/pull/10026", "/pull/10036") }
    ]

    mutations.each_with_index do |mutate, index|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
      comment = valid_waiver_comment(row, input)
      mutate.call(comment)
      result = assess_input(input, waiver_verifier: ->(**_keywords) { comment })

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable",
                      index
    end
  end

  def test_eligible_waiver_receipt_requires_an_authenticated_comment_refresh
    input = fixture("completed-batch-publication-hichee-terminal.json")
    receipt = assess_input(input)

    refute CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: ->(**_keywords) {}
    )
    assert CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: valid_waiver_verifier(input)
    )

    changed_comment = valid_waiver_comment(input.fetch("qa_evidence").last, input)
    changed_comment["body"] = "#{changed_comment.fetch('body')}\nEdited after publication.\n"
    refute CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: ->(**_keywords) { changed_comment }
    )
  end

  def test_malformed_waiver_url_returns_false_instead_of_raising_during_refresh
    input = fixture("completed-batch-publication-hichee-terminal.json")
    receipt = assess_input(input)
    receipt.dig("snapshot", "qa", 0, "maintainer_waiver")["url"] = "https://[malformed"
    receipt["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(receipt.fetch("snapshot"))
    receipt["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      receipt.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.authenticated_waivers_valid?(
      receipt,
      waiver_verifier: valid_waiver_verifier(input)
    )
  end

  def test_expected_target_absent_from_coordination_scope_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.dig("coordination_status", "batches", 0, "lanes").pop
    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 is absent from resolved coordination scope"
  end

  def test_conflicting_lane_url_and_target_identity_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes", 0)
    lane["targets"] = ["10026"]
    result = assess_input(input)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane hc-b-10049 target is absent or ambiguous"
  end

  def test_eligible_receipt_requires_a_nonempty_valid_target_set
    result = assess_input(fixture("completed-batch-publication-hichee-terminal.json"))
    result["targets"] = []
    result["snapshot"]["targets"] = []
    result["snapshot"]["qa"] = []
    result["snapshot"]["coordination"]["lanes"] = []
    result["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("snapshot"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.valid_receipt?(result)
  end

  def test_recomputed_eligible_receipt_cannot_omit_coordination_and_qa_rows
    result = assess_input(fixture("completed-batch-publication-hichee-terminal.json"))
    result.dig("snapshot", "coordination")["lanes"] = []
    result["snapshot"]["qa"] = []
    result["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("snapshot"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.valid_receipt?(result)
  end

  def test_no_backend_single_operator_path_accepts_typed_durable_evidence
    result = assess_input(no_backend_input, backend: "n/a")

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal "not_applicable", result.dig("snapshot", "coordination", "status")
    assert_equal "single_operator", result.dig("snapshot", "coordination", "not_applicable", "mode")
  end

  def test_no_backend_path_rejects_missing_or_malformed_typed_evidence
    mutations = [
      ->(proof) { proof.delete("rationale") },
      ->(proof) { proof["source"] = "not a durable URL" },
      ->(proof) { proof.fetch("targets").pop },
      ->(proof) { proof["mode"] = "multi_operator" },
      ->(proof) { proof["completed_at"] = "not-a-timestamp" }
    ]

    mutations.each_with_index do |mutate, index|
      input = no_backend_input
      mutate.call(input.fetch("coordination_status"))
      result = assess_input(input, backend: "n/a")

      refute result.fetch("eligible"), index
      assert_includes result.fetch("blockers"),
                      "typed no-backend coordination evidence is absent or invalid",
                      index
    end
  end

  def test_cli_reads_the_repository_coordination_backend_seam
    input = fixture("completed-batch-publication-hichee-terminal.json")
    with_fake_waiver_gh(input) do |env|
      Tempfile.create(["agent-workflow", ".yml"]) do |config|
        config.write("coordination_backend: agent-coord private backend\n")
        config.flush
        out, err, status = Open3.capture3(
          env,
          "ruby",
          SCRIPT,
          "--workflow-config",
          config.path,
          "--input",
          File.join(FIXTURES, "completed-batch-publication-hichee-terminal.json")
        )

        assert status.success?, err
        result = JSON.parse(out)
        assert result.fetch("eligible")
        assert_equal "agent-coord private backend", result.dig("snapshot", "coordination_backend")
        calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
        assert_includes calls,
                        "api --hostname github.com repos/shakacode/hichee/pulls/10026"
        assert_includes calls,
                        "api --hostname github.com repos/shakacode/hichee/issues/comments/5000000000"
      end
    end
  end

  def test_cli_authenticated_waiver_comment_404_blocks_completion
    input = fixture("completed-batch-publication-hichee-terminal.json")
    row = input.fetch("qa_evidence").find { |candidate| candidate.key?("maintainer_waiver") }
    original_url = row.dig("maintainer_waiver", "url")
    missing_url = "https://github.com/shakacode/hichee/pull/10026#issuecomment-999999999999999999"
    row["evidence"] = row.fetch("evidence").sub(original_url, missing_url)
    row["maintainer_waiver"] = { "url" => missing_url }

    with_fake_waiver_gh(input, mode: "not_found") do |env|
      Tempfile.create(["agent-workflow", ".yml"]) do |config|
        config.write("coordination_backend: agent-coord private backend\n")
        config.flush
        Tempfile.create(["preflight", ".json"]) do |preflight|
          preflight.write(JSON.generate(input))
          preflight.flush
          out, _err, status = Open3.capture3(
            env,
            "ruby",
            SCRIPT,
            "--workflow-config",
            config.path,
            "--input",
            preflight.path
          )

          assert_equal 1, status.exitstatus
          result = JSON.parse(out)
          refute result.fetch("eligible")
          assert_includes result.fetch("blockers"),
                          "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable"
          assert_includes(
            File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true),
            "api --hostname github.com repos/shakacode/hichee/issues/comments/999999999999999999"
          )
        end
      end
    end
  end

  def test_cli_waiver_author_requires_current_write_permission
    %w[read triage collaborator].each do |permission|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      with_fake_waiver_gh(input, author_permission: permission) do |env|
        Tempfile.create(["agent-workflow", ".yml"]) do |config|
          config.write("coordination_backend: agent-coord private backend\n")
          config.flush
          out, _err, status = Open3.capture3(
            env,
            "ruby",
            SCRIPT,
            "--workflow-config",
            config.path,
            "--input",
            File.join(FIXTURES, "completed-batch-publication-hichee-terminal.json")
          )

          assert_equal 1, status.exitstatus, permission
          result = JSON.parse(out)
          refute result.fetch("eligible"), permission
          assert_includes result.fetch("blockers"),
                          "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable",
                          permission
          assert_includes(
            File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true),
            "api --hostname github.com repos/shakacode/hichee/collaborators/justin808/permission",
            permission
          )
        end
      end
    end
  end
end
