#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

load File.expand_path("completed-batch-publication-preflight", __dir__)
load File.expand_path("completed-batch-audit-receipt", __dir__)

class CompletedBatchAuditReceiptTest < Minitest::Test
  SCRIPT = File.expand_path("completed-batch-audit-receipt", __dir__)
  FIXTURES = File.expand_path("../fixtures", __dir__)
  WORKFLOW_CONFIG = File.expand_path("../../../.agents/agent-workflow.yml", __dir__)
  REAL_BACKEND = "agent-coord private backend"

  def marker(body)
    "<!-- completed-batch-audit v1\n#{body.chomp}\n-->\n"
  end

  def ready_marker
    marker(<<~BODY)
      batch_id: batch-184
      audit_status: complete
      verdict: clean
      scope_evidence: targets #184; audit report
      checker_evidence: checker sol/xhigh; independent from every maker; report #184
      findings: none
      followups_dispositions: none
    BODY
  end

  def followup_marker
    marker(<<~BODY)
      batch_id: batch-184
      audit_status: blocked
      verdict: follow-ups-remain
      scope_evidence: targets #184; audit report
      checker_evidence: checker sol/xhigh; independent from every maker; report #184
      findings: OUTSTANDING #184
      followups_dispositions: ref: #184; owner: maintainer; current status: open; disposition: fix; evidence: issue #184
    BODY
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

  def test_capture_process_timeout_terminates_descendant_after_wrapper_exits
    Dir.mktmpdir("completed-batch-receipt-process-group") do |directory|
      descendant_pid_path = File.join(directory, "descendant.pid")
      wrapper = 'sleep 30 >/dev/null 2>&1 & descendant=$!; printf "%s\n" "$descendant" > "$1"; wait "$descendant"'
      descendant_pid = nil

      assert_raises(Timeout::Error) do
        CompletedBatchAuditReceipt.capture_process(
          ["/bin/sh", "-c", wrapper, "process-group-wrapper", descendant_pid_path],
          input: "",
          timeout: 0.5
        )
      end
      descendant_pid = Integer(File.read(descendant_pid_path), 10)

      assert wait_for_process_exit(descendant_pid),
             "timed receipt-helper descendant #{descendant_pid} survived after its wrapper exited " \
             "with state #{process_state(descendant_pid).inspect}"
    ensure
      Process.kill("KILL", descendant_pid) if descendant_pid && process_alive?(descendant_pid)
    end
  end

  def test_capture_process_timeout_reaps_nested_descendant_layers
    Dir.mktmpdir("completed-batch-receipt-nested-process-group") do |directory|
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
          CompletedBatchAuditReceipt.capture_process(
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
               "timed nested receipt-helper #{label} #{pid} survived process-group cleanup " \
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
    Dir.mktmpdir("completed-batch-receipt-term-resistant") do |directory|
      child_pid_path = File.join(directory, "child.pid")
      program = 'trap("TERM") {}; File.write(ARGV.fetch(0), Process.pid.to_s); sleep 30'
      child_pid = nil
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(Timeout::Error) do
        CompletedBatchAuditReceipt.capture_process(
          [RbConfig.ruby, "-e", program, child_pid_path],
          input: "",
          timeout: 0.5
        )
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      child_pid = Integer(File.read(child_pid_path), 10)

      assert_operator elapsed, :<, 3
      assert wait_for_process_exit(child_pid),
             "TERM-resistant receipt-helper group leader #{child_pid} survived KILL escalation"
    ensure
      Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
    end
  end

  def test_legacy_complete_marker_is_parseable_but_not_ready_without_publication_snapshot
    result = CompletedBatchAuditReceipt.replay_marker(
      ready_marker,
      expected_batch_id: "batch-184"
    )

    assert result.fetch("well_formed")
    refute result.fetch("ready")
    assert_equal ["completed-batch-audit publication snapshot refresh required"], result.fetch("blockers")
    assert_equal "clean", result.dig("fields", "verdict")
  end

  def test_ror_blocked_receipt_becomes_ready_only_through_authenticated_accepted_deferral
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"),
      encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    targets = [{
      "host" => "github.com",
      "repo" => "shakacode/react_on_rails",
      "type" => "issue",
      "number" => 4731
    }]
    preflight = accepted_deferral_publication_preflight(targets.first)

    with_accepted_deferral_api(preflight, accepted_deferral_api(preflight)) do
      terminal = CompletedBatchAuditReceipt.terminalize_accepted_deferral(
        blocked,
        input:,
        expected_batch_id: "ror-d-issue-4731-20260817",
        targets:,
        publication_preflight: preflight,
        coordination_backend: REAL_BACKEND
      )
      replay = CompletedBatchAuditReceipt.replay_marker(
        terminal,
        expected_batch_id: "ror-d-issue-4731-20260817",
        expected_targets: targets,
        coordination_backend: REAL_BACKEND,
        publication_preflight: preflight
      )

      assert replay.fetch("well_formed")
      assert replay.fetch("ready")
      assert_empty replay.fetch("blockers")
      record = replay.fetch("records").fetch(0)
      assert_equal "terminal", record.fetch("current_status")
      assert_equal "accepted-deferral", record.fetch("disposition")
    end
  end

  def test_post_publication_accepted_deferral_reauthenticates_the_append_only_predecessor
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"),
      encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    targets = [{
      "host" => "github.com",
      "repo" => "shakacode/react_on_rails",
      "type" => "issue",
      "number" => 4731
    }]
    preflight = accepted_deferral_publication_preflight(targets.first)
    predecessor = accepted_deferral_predecessor_receipt(blocked)
    terminal = nil

    with_accepted_deferral_api(preflight, accepted_deferral_api(preflight, predecessor:)) do
      terminal = CompletedBatchAuditReceipt.terminalize_accepted_deferral(
        blocked,
        input:,
        expected_batch_id: "ror-d-issue-4731-20260817",
        targets:,
        publication_preflight: preflight,
        predecessor_receipt: predecessor,
        coordination_backend: REAL_BACKEND
      )
      replay = CompletedBatchAuditReceipt.replay_marker(
        terminal,
        expected_batch_id: "ror-d-issue-4731-20260817",
        expected_targets: targets,
        coordination_backend: REAL_BACKEND,
        publication_preflight: preflight
      )
      assert replay.fetch("ready")
    end

    corrupted_api = accepted_deferral_api(preflight, predecessor:, corrupt_predecessor: true)
    with_accepted_deferral_api(preflight, corrupted_api) do
      replay = CompletedBatchAuditReceipt.replay_marker(
        terminal,
        expected_batch_id: "ror-d-issue-4731-20260817",
        expected_targets: targets,
        coordination_backend: REAL_BACKEND,
        publication_preflight: preflight
      )
      refute replay.fetch("ready")
      assert_equal ["completed-batch-audit accepted deferral mismatch or stale"], replay.fetch("blockers")
    end
  end

  def test_supersede_posts_one_successor_comment_and_reuses_the_supplied_tracking_issue
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"), encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    target = {
      "host" => "github.com", "repo" => "shakacode/react_on_rails", "type" => "issue", "number" => 4731
    }
    preflight = accepted_deferral_publication_preflight(target)
    predecessor = accepted_deferral_predecessor_receipt(blocked)
    reference = CompletedBatchAuditReceipt.compact_reference("follow-ups-remain", predecessor)
    api, calls = accepted_deferral_supersede_api(preflight, predecessor:)

    with_accepted_deferral_api(preflight, api) do
      result = CompletedBatchAuditReceipt.supersede(
        expected_batch_id: "ror-d-issue-4731-20260817",
        targets: [target],
        reference:,
        accepted_deferral_input: input,
        publication_preflight: preflight,
        coordination_backend: REAL_BACKEND
      )

      assert result.fetch("ready")
      assert_equal "Conversation status: Ready for archiving.", result.fetch("final_status")
    end
    assert_equal(1, calls.count { |call| call[2] == "POST" })
    refute(calls.any? { |call| call[1].end_with?("/issues") && call[2] == "POST" })
  end

  def test_supersede_refuses_any_external_product_or_unknown_blocker_before_post
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"), encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    target = {
      "host" => "github.com", "repo" => "shakacode/react_on_rails", "type" => "issue", "number" => 4731
    }
    preflight = accepted_deferral_publication_preflight(target)
    predecessor = accepted_deferral_predecessor_receipt(blocked)
    reference = CompletedBatchAuditReceipt.compact_reference("follow-ups-remain", predecessor)

    ["release gate failed", "review evidence: UNKNOWN"].each do |blocker|
      api, calls = accepted_deferral_supersede_api(preflight, predecessor:)
      with_accepted_deferral_api(preflight, api) do
        assert_raises(CompletedBatchAuditReceipt::Error, blocker) do
          CompletedBatchAuditReceipt.supersede(
            expected_batch_id: "ror-d-issue-4731-20260817",
            targets: [target],
            reference:,
            accepted_deferral_input: input,
            publication_preflight: preflight,
            coordination_backend: REAL_BACKEND,
            other_blockers: [blocker]
          )
        end
      end
      refute(calls.any? { |call| call[2] == "POST" }, blocker)
    end
  end

  def test_accepted_deferral_rejects_corrupted_decision_tracking_owner_binding_and_product_evidence
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"),
      encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    target = {
      "host" => "github.com", "repo" => "shakacode/react_on_rails", "type" => "issue", "number" => 4731
    }
    preflight = accepted_deferral_publication_preflight(target)
    variants = {
      "decision" => ["decision: accepted-deferral", "decision: resolved"],
      "removed decision" => ["decision: accepted-deferral\n", ""],
      "tracking issue" => ["tracking_issue: https://github.com/shakacode/agent-workflows/issues/320",
                           "tracking_issue: https://github.com/shakacode/agent-workflows/issues/321"],
      "owner" => ["owner: agent-workflows-maintainer", "owner: UNKNOWN"],
      "batch" => ["batch_id: ror-d-issue-4731-20260817", "batch_id: other-batch"],
      "predecessor" => ["original_receipt_sha256: sha256:", "original_receipt_sha256: sha256:0"],
      "product evidence" => ["product_evidence_receipt: sha256:", "product_evidence_receipt: sha256:0"]
    }

    variants.each do |label, (needle, replacement)|
      api = accepted_deferral_api(preflight, mutate_decision: ->(body) { body.sub(needle, replacement) })
      with_accepted_deferral_api(preflight, api) do
        assert_raises(CompletedBatchAuditReceipt::Error, label) do
          CompletedBatchAuditReceipt.terminalize_accepted_deferral(
            blocked,
            input:,
            expected_batch_id: "ror-d-issue-4731-20260817",
            targets: [target],
            publication_preflight: preflight,
            coordination_backend: REAL_BACKEND
          )
        end
      end
    end
  end

  def test_accepted_deferral_rejects_substantive_or_unknown_product_blockers
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"), encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    target = {
      "host" => "github.com", "repo" => "shakacode/react_on_rails", "type" => "issue", "number" => 4731
    }

    ["release gate failed", "coordination lane UNKNOWN target is absent or ambiguous"].each do |blocker|
      preflight = accepted_deferral_publication_preflight(target, blockers: [blocker])
      with_accepted_deferral_api(preflight, accepted_deferral_api(preflight)) do
        assert_raises(CompletedBatchAuditReceipt::Error, blocker) do
          CompletedBatchAuditReceipt.terminalize_accepted_deferral(
            blocked,
            input:,
            expected_batch_id: "ror-d-issue-4731-20260817",
            targets: [target],
            publication_preflight: preflight,
            coordination_backend: REAL_BACKEND
          )
        end
      end
    end

    preflight = accepted_deferral_publication_preflight(target)
    preflight.fetch("snapshot").fetch("qa").first["status"] = "unknown"
    preflight["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(preflight.fetch("snapshot"))
    unsigned = preflight.reject { |key, _value| key == "receipt_digest" }
    preflight["receipt_digest"] = CompletedBatchPublicationPreflight.digest(unsigned)
    with_accepted_deferral_api(preflight, accepted_deferral_api(preflight)) do
      assert_raises(CompletedBatchAuditReceipt::Error, "unknown QA evidence") do
        CompletedBatchAuditReceipt.terminalize_accepted_deferral(
          blocked,
          input:,
          expected_batch_id: "ror-d-issue-4731-20260817",
          targets: [target],
          publication_preflight: preflight,
          coordination_backend: REAL_BACKEND
        )
      end
    end
  end

  def test_accepted_deferral_rejects_resealed_preflight_source_identity_corruption
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"), encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    target = {
      "host" => "github.com", "repo" => "shakacode/react_on_rails", "type" => "issue", "number" => 4731
    }
    preflight = accepted_deferral_publication_preflight(target)
    preflight.fetch("source_input")["batch_id"] = "other-batch"
    preflight["source_input_digest"] = CompletedBatchPublicationPreflight.digest(preflight.fetch("source_input"))
    unsigned = preflight.reject { |key, _value| key == "receipt_digest" }
    preflight["receipt_digest"] = CompletedBatchPublicationPreflight.digest(unsigned)

    with_accepted_deferral_api(preflight, accepted_deferral_api(preflight)) do
      assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.terminalize_accepted_deferral(
          blocked,
          input:,
          expected_batch_id: "ror-d-issue-4731-20260817",
          targets: [target],
          publication_preflight: preflight,
          coordination_backend: REAL_BACKEND
        )
      end
    end
  end

  def test_accepted_deferral_rejects_backend_mismatch_and_stale_coordination
    blocked = File.read(
      File.join(FIXTURES, "completed-batch-accepted-deferral-ror-blocked.txt"), encoding: "UTF-8"
    )
    input = JSON.parse(
      File.read(File.join(FIXTURES, "completed-batch-accepted-deferral-ror.json"), encoding: "UTF-8")
    )
    target = {
      "host" => "github.com", "repo" => "shakacode/react_on_rails", "type" => "issue", "number" => 4731
    }
    preflight = accepted_deferral_publication_preflight(target)

    with_stubbed_gh_api(accepted_deferral_api(preflight)) do
      assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.terminalize_accepted_deferral(
          blocked,
          input:,
          expected_batch_id: "ror-d-issue-4731-20260817",
          targets: [target],
          publication_preflight: preflight,
          coordination_backend: "n/a"
        )
      end

      stale = ->(backend:, batch_id:) { { "backend" => backend, "batch_id" => batch_id, "status" => "stale" } }
      with_stubbed_coordination_status(stale) do
        assert_raises(CompletedBatchAuditReceipt::Error) do
          CompletedBatchAuditReceipt.terminalize_accepted_deferral(
            blocked,
            input:,
            expected_batch_id: "ror-d-issue-4731-20260817",
            targets: [target],
            publication_preflight: preflight,
            coordination_backend: REAL_BACKEND
          )
        end
      end
    end
  end

  def test_real_premature_hichee_marker_replays_invalid_and_nonready
    marker = File.read(
      File.join(FIXTURES, "completed-batch-publication-hichee-premature-marker.txt"),
      encoding: "UTF-8"
    )
    result = CompletedBatchAuditReceipt.replay_marker(
      marker,
      expected_batch_id: "hc-b-20260730-backend-closeout"
    )

    refute result.fetch("well_formed")
    refute result.fetch("ready")
    assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
  end

  def test_complete_publish_requires_eligible_publication_preflight_before_post
    with_fake_gh do |env, directory|
      env.delete("COMPLETED_BATCH_AUDIT_PUBLICATION_PREFLIGHT")
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit publication preflight failed"], result.fetch("blockers")
      refute File.exist?(env.fetch("FAKE_GH_LOG")), "publication gate must run before anchor lookup or POST"
    end
  end

  def test_malformed_publication_preflight_snapshot_is_a_structured_failure
    with_fake_gh do |env, directory|
      File.write(
        env.fetch("COMPLETED_BATCH_AUDIT_PUBLICATION_PREFLIGHT"),
        JSON.generate("snapshot" => [])
      )
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit publication preflight failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit publication preflight failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      refute File.exist?(env.fetch("FAKE_GH_LOG")), "malformed preflight must fail before GitHub API access"
    end
  end

  def test_complete_publication_reauthenticates_waiver_receipt_before_post
    preflight = publication_preflight(waived: true)
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    missing_comment = lambda do |_host, _endpoint, **_options|
      raise CompletedBatchAuditReceipt::Error, "GitHub API request failed"
    end

    with_stubbed_gh_api(missing_comment) do
      assert_raises(CompletedBatchAuditReceipt::PublicationPreflightError) do
        CompletedBatchAuditReceipt.validate_publication_preflight!(
          preflight,
          expected_batch_id: "batch-184",
          targets: [target],
          coordination_backend: "n/a"
        )
      end
    end
  end

  def test_complete_publication_accepts_only_the_unchanged_authenticated_waiver
    preflight = publication_preflight(waived: true)
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    comment = publication_waiver_comment(head_sha: "a" * 40)
    target_payload = publication_target_payload
    authenticated_api = lambda do |_host, endpoint, **_options|
      case endpoint
      when "repos/acme/widgets/pulls/184"
        target_payload
      when "repos/acme/widgets/issues/comments/9184"
        comment
      when "repos/acme/widgets/collaborators/maintainer/permission"
        { "permission" => "write", "user" => { "login" => "maintainer", "type" => "User" } }
      else
        raise "unexpected endpoint: #{endpoint}"
      end
    end

    with_stubbed_gh_api(authenticated_api) do
      CompletedBatchAuditReceipt.validate_publication_preflight!(
        preflight,
        expected_batch_id: "batch-184",
        targets: [target],
        coordination_backend: "n/a"
      )
    end

    comment["body"] = "#{comment.fetch('body')}\nEdited after preflight.\n"
    with_stubbed_gh_api(authenticated_api) do
      assert_raises(CompletedBatchAuditReceipt::PublicationPreflightError) do
        CompletedBatchAuditReceipt.validate_publication_preflight!(
          preflight,
          expected_batch_id: "batch-184",
          targets: [target],
          coordination_backend: "n/a"
        )
      end
    end
  end

  def test_complete_publication_rejects_a_stale_authenticated_target_head
    preflight = publication_preflight
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    stale_target_payload = publication_target_payload(head_sha: "b" * 40)
    authenticated_api = lambda do |_host, endpoint, **_options|
      raise "unexpected endpoint: #{endpoint}" unless endpoint == "repos/acme/widgets/pulls/184"

      stale_target_payload
    end

    with_stubbed_gh_api(authenticated_api) do
      assert_raises(CompletedBatchAuditReceipt::PublicationPreflightError) do
        CompletedBatchAuditReceipt.validate_publication_preflight!(
          preflight,
          expected_batch_id: "batch-184",
          targets: [target],
          coordination_backend: "n/a"
        )
      end
    end
  end

  def test_complete_publication_rejects_forged_no_backend_receipt_in_trusted_real_backend_context
    preflight = publication_preflight
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    unexpected_api = lambda do |_host, endpoint, **_options|
      flunk "backend mismatch must fail before GitHub API call: #{endpoint}"
    end

    with_stubbed_gh_api(unexpected_api) do
      assert_raises(CompletedBatchAuditReceipt::PublicationPreflightError) do
        CompletedBatchAuditReceipt.validate_publication_preflight!(
          preflight,
          expected_batch_id: "batch-184",
          targets: [target],
          coordination_backend: REAL_BACKEND
        )
      end
    end
  end

  def test_complete_publication_rejects_real_backend_receipt_in_trusted_no_backend_context
    preflight = publication_preflight(coordination_backend: REAL_BACKEND)
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    api_calls = []
    authenticated_api = lambda do |_host, endpoint, **_options|
      api_calls << endpoint
      publication_target_payload
    end

    with_stubbed_gh_api(authenticated_api) do
      assert_raises(CompletedBatchAuditReceipt::PublicationPreflightError) do
        CompletedBatchAuditReceipt.validate_publication_preflight!(
          preflight,
          expected_batch_id: "batch-184",
          targets: [target],
          coordination_backend: "n/a"
        )
      end
    end
    assert_empty api_calls, "backend mismatch must fail before target freshness calls"
  end

  def test_complete_publication_accepts_matching_real_backend_after_live_coordination_refresh
    preflight = publication_preflight(coordination_backend: REAL_BACKEND)
    assert_equal REAL_BACKEND, preflight.fetch("coordination_backend")
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    coordination_calls = []
    coordination_status = preflight.dig("source_input", "coordination_status")
    coordination_verifier = lambda do |backend:, batch_id:|
      coordination_calls << [backend, batch_id]
      coordination_status
    end
    target_payload = publication_target_payload
    authenticated_api = lambda do |_host, endpoint, **_options|
      raise "unexpected endpoint: #{endpoint}" unless endpoint == "repos/acme/widgets/pulls/184"

      target_payload
    end

    with_stubbed_gh_api(authenticated_api) do
      with_stubbed_coordination_status(coordination_verifier) do
        CompletedBatchAuditReceipt.validate_publication_preflight!(
          preflight,
          expected_batch_id: "batch-184",
          targets: [target],
          coordination_backend: REAL_BACKEND
        )
      end
    end
    assert_equal [[REAL_BACKEND, "batch-184"]], coordination_calls
  end

  def test_complete_publication_blocks_public_claim_fallback_without_private_coordination
    backend = " Public　claim-comment \n fallback. "
    preflight = publication_preflight(coordination_backend: backend)
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    capture_calls = []
    capture = lambda do |command, input:, timeout:|
      capture_calls << { "command" => command, "input" => input, "timeout" => timeout }
      status = preflight.dig("source_input", "coordination_status")
      [JSON.generate(status), "", Struct.new(:success?).new(true)]
    end
    target_payload = publication_target_payload
    authenticated_api = lambda do |_host, endpoint, **_options|
      raise "unexpected endpoint: #{endpoint}" unless endpoint == "repos/acme/widgets/pulls/184"

      target_payload
    end

    with_stubbed_gh_api(authenticated_api) do
      with_stubbed_preflight_capture_process(capture) do
        assert_raises(CompletedBatchAuditReceipt::PublicationPreflightError) do
          CompletedBatchAuditReceipt.validate_publication_preflight!(
            preflight,
            expected_batch_id: "batch-184",
            targets: [target],
            coordination_backend: backend
          )
        end
      end
    end
    assert_empty capture_calls
  end

  def test_complete_publication_accepts_matching_no_backend_without_live_coordination_call
    preflight = publication_preflight
    assert_equal "n/a", preflight.fetch("coordination_backend")
    target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 184
    }
    coordination_calls = []
    coordination_verifier = lambda do |backend:, batch_id:|
      coordination_calls << [backend, batch_id]
      nil
    end
    target_payload = publication_target_payload
    authenticated_api = lambda do |_host, endpoint, **_options|
      raise "unexpected endpoint: #{endpoint}" unless endpoint == "repos/acme/widgets/pulls/184"

      target_payload
    end

    with_stubbed_gh_api(authenticated_api) do
      with_stubbed_coordination_status(coordination_verifier) do
        CompletedBatchAuditReceipt.validate_publication_preflight!(
          preflight,
          expected_batch_id: "batch-184",
          targets: [target],
          coordination_backend: "n/a"
        )
      end
    end
    assert_empty coordination_calls
  end

  def test_publish_binds_snapshot_and_replay_blocks_a_refreshed_snapshot_mismatch
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert published.fetch("ready")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, published.fetch("publication_snapshot_digest"))
      posted_body = File.read(env.fetch("FAKE_GH_BODY"), encoding: "UTF-8")
      assert_equal 1, posted_body.scan("<!-- completed-batch-audit v1").length
      assert_includes posted_body, "publication_snapshot: sha256:"

      stale_path = File.join(directory, "stale-preflight.json")
      File.write(stale_path, JSON.generate(publication_preflight(head_sha: "b" * 40)))
      env["COMPLETED_BATCH_AUDIT_PUBLICATION_PREFLIGHT"] = stale_path
      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("well_formed")
      refute replayed.fetch("ready")
      assert_equal ["completed-batch-audit publication snapshot mismatch or stale"], replayed.fetch("blockers")
      refute File.exist?(env.fetch("FAKE_COORDINATION_LOG")),
             "trusted n/a publish/replay must not invoke agent-coord"
    end
  end

  def test_publish_and_replay_cli_refresh_matching_real_backend_with_bounded_coordination
    with_fake_gh(coordination_backend: REAL_BACKEND) do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert published.fetch("ready")
      publish_coordination_calls = File.readlines(env.fetch("FAKE_COORDINATION_LOG"), chomp: true)
      refute_empty publish_coordination_calls
      assert(publish_coordination_calls.all? { |call| call == "status --batch-id batch-184 --json" })

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      assert JSON.parse(replay_out).fetch("ready")
      replay_coordination_calls = File.readlines(env.fetch("FAKE_COORDINATION_LOG"), chomp: true)
      assert_operator replay_coordination_calls.length, :>, publish_coordination_calls.length
      assert(replay_coordination_calls.all? { |call| call == "status --batch-id batch-184 --json" })
    end
  end

  def test_bound_snapshot_replay_requires_the_current_exact_target_manifest
    preflight = publication_preflight
    bound = CompletedBatchAuditReceipt.bind_publication_snapshot(ready_marker, preflight)
    different_target = {
      "host" => "github.com",
      "repo" => "acme/widgets",
      "type" => "pull_request",
      "number" => 185
    }

    result = CompletedBatchAuditReceipt.replay_marker(
      bound,
      expected_batch_id: "batch-184",
      publication_preflight: preflight,
      expected_targets: [different_target]
    )

    assert result.fetch("well_formed")
    refute result.fetch("ready")
    assert_equal ["completed-batch-audit publication snapshot mismatch or stale"], result.fetch("blockers")
  end

  def test_external_blocker_union_forces_derived_readiness_false
    result = CompletedBatchAuditReceipt.replay_marker(
      ready_marker,
      expected_batch_id: "batch-184",
      other_blockers: [" release owner confirmation "]
    )

    assert result.fetch("well_formed")
    refute result.fetch("ready")
    assert_equal(
      ["completed-batch-audit publication snapshot refresh required", "release owner confirmation"],
      result.fetch("blockers")
    )
    assert_equal(
      "Conversation status: Follow-ups remain — completed-batch-audit publication snapshot refresh required; " \
      "release owner confirmation.",
      CompletedBatchAuditReceipt.final_status(result)
    )
  end

  def test_malformed_external_blockers_fail_closed_with_sanitized_label
    invalid_blockers = ["", "line\nbreak", "<!-- injected -->", 42]

    invalid_blockers.each do |blocker|
      result = CompletedBatchAuditReceipt.replay_marker(
        ready_marker,
        expected_batch_id: "batch-184",
        other_blockers: [blocker]
      )

      assert result.fetch("well_formed"), blocker.inspect
      refute result.fetch("ready"), blocker.inspect
      assert_equal(
        [
          "completed-batch-audit publication snapshot refresh required",
          "completed-batch-audit external blocker invalid"
        ],
        result.fetch("blockers"),
        blocker.inspect
      )
    end

    mixed = CompletedBatchAuditReceipt.replay_marker(
      ready_marker,
      expected_batch_id: "batch-184",
      other_blockers: ["", " safe\towner ", "<!-- injected -->"]
    )
    assert_equal(
      [
        "completed-batch-audit publication snapshot refresh required",
        "completed-batch-audit external blocker invalid",
        "safe owner"
      ],
      mixed.fetch("blockers")
    )
    refute_includes CompletedBatchAuditReceipt.final_status(mixed), "<!--"
  end

  def test_cli_malformed_external_blockers_never_make_clean_receipt_ready
    ["", "line\nbreak", "<!-- injected -->"].each do |blocker|
      with_fake_gh do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path,
          "--other-blocker",
          blocker
        )

        assert status.success?, "#{blocker.inspect}: #{err}"
        result = JSON.parse(out)
        assert result.fetch("well_formed"), blocker.inspect
        refute result.fetch("ready"), blocker.inspect
        assert_equal(
          ["completed-batch-audit external blocker invalid"],
          result.fetch("blockers"),
          blocker.inspect
        )
        assert_nil(result.fetch("chat_reference")[blocker]) unless blocker.empty?
      end
    end
  end

  def test_verified_human_login_accepts_only_matching_user_objects
    invalid_users = [
      { "login" => "justin808" },
      { "login" => "justin808", "type" => "UNKNOWN" },
      { "login" => "justin808", "type" => "Organization" }
    ]

    invalid_users.each do |user|
      assert_raises(CompletedBatchAuditReceipt::Error, user.inspect) do
        CompletedBatchAuditReceipt.verified_human_login!(user, context: "test actor")
      end
    end
    assert_raises(CompletedBatchAuditReceipt::Error) do
      CompletedBatchAuditReceipt.verified_human_login!(
        { "login" => "other-maintainer", "type" => "User" },
        context: "test actor",
        expected_login: "justin808"
      )
    end
    assert_equal "justin808", CompletedBatchAuditReceipt.verified_human_login!(
      { "login" => "justin808", "type" => "User" },
      context: "test actor",
      expected_login: "justin808"
    )
    ["justin.emu", "justin emu", "justin/emu"].each do |login|
      assert_raises(CompletedBatchAuditReceipt::Error, login) do
        CompletedBatchAuditReceipt.verified_human_login!(
          { "login" => login, "type" => "User" },
          context: "test actor"
        )
      end
    end
  end

  def test_cli_usage_errors_use_documented_exit
    _out, _err, status = capture_receipt_cli("ruby", SCRIPT)

    assert_equal 64, status.exitstatus
  end

  def test_complete_publish_cli_requires_explicit_workflow_config
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      _out, err, status = Open3.capture3(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 64, status.exitstatus
      assert_includes err, "missing argument: --workflow-config"
      refute File.exist?(env.fetch("FAKE_GH_LOG"))
    end
  end

  def test_complete_publish_cli_rejects_malformed_workflow_config_before_api_calls
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      config_path = File.join(directory, "malformed-agent-workflow.yml")
      File.write(receipt_path, ready_marker)
      File.write(config_path, "coordination_backend: [\n")

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path,
        "--workflow-config",
        config_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
      assert_includes result.fetch("errors").join("\n"), "workflow config"
      refute File.exist?(env.fetch("FAKE_GH_LOG"))
    end
  end

  def test_cli_rejects_command_incompatible_input_options
    Dir.mktmpdir("completed-batch-audit-usage") do |directory|
      targets_path = write_json(directory, "targets.json", [])
      receipt_path = File.join(directory, "receipt.txt")
      reference_path = File.join(directory, "reference.txt")
      File.write(receipt_path, ready_marker)
      File.write(reference_path, "invalid reference")

      _out, _err, publish_status = capture_receipt_cli(
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path,
        "--reference-file",
        reference_path
      )
      _out, _err, replay_status = capture_receipt_cli(
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path,
        "--receipt",
        receipt_path
      )
      _out, _err, invalid_option_precedence_status = capture_receipt_cli(
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        File.join(directory, "missing-targets.json"),
        "--receipt",
        receipt_path,
        "--reference-file",
        reference_path
      )

      assert_equal 64, publish_status.exitstatus
      assert_equal 64, replay_status.exitstatus
      assert_equal 64, invalid_option_precedence_status.exitstatus
    end
  end

  def test_missing_reference_file_is_structured_integrity_failure
    Dir.mktmpdir("completed-batch-audit-missing-reference") do |directory|
      targets_path = write_json(directory, "targets.json", [])
      missing_reference = File.join(directory, "missing-reference.txt")

      out, _err, status = capture_receipt_cli(
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        missing_reference,
        "--other-blocker",
        " release owner confirmation ",
        "--other-blocker",
        "<!-- injected -->"
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal(
        [
          "completed-batch-audit marker invalid",
          "release owner confirmation",
          "completed-batch-audit external blocker invalid"
        ],
        result.fetch("blockers")
      )
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_missing_receipt_and_manifest_files_are_structured_integrity_failures
    Dir.mktmpdir("completed-batch-audit-missing-input") do |directory|
      targets_path = write_json(directory, "targets.json", [])
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      cases = {
        "receipt" => [
          "publish",
          "--expected-batch-id", "batch-184",
          "--targets-json", targets_path,
          "--receipt", File.join(directory, "missing-receipt.txt")
        ],
        "manifest" => [
          "publish",
          "--expected-batch-id", "batch-184",
          "--targets-json", File.join(directory, "missing-targets.json"),
          "--receipt", receipt_path
        ]
      }

      cases.each do |label, args|
        out, _err, status = capture_receipt_cli("ruby", SCRIPT, *args)

        assert_equal 1, status.exitstatus, label
        result = JSON.parse(out)
        refute result.fetch("well_formed"), label
        refute result.fetch("ready"), label
        assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers"), label
        assert_nil result.fetch("chat_reference"), label
      end
    end
  end

  def test_malformed_manifest_json_is_structured_integrity_failure
    Dir.mktmpdir("completed-batch-audit-malformed-manifest") do |directory|
      targets_path = File.join(directory, "targets.json")
      receipt_path = File.join(directory, "receipt.txt")
      File.write(targets_path, "{")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit marker invalid.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_cli_timeout_configuration_must_be_positive_integer_before_github_calls
    ["not-a-number", "0", "-1"].each do |timeout|
      with_fake_gh do |env, directory|
        env["COMPLETED_BATCH_AUDIT_GH_TIMEOUT_SECONDS"] = timeout
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, _err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus, timeout
        result = JSON.parse(out)
        assert_equal(
          %w[blockers chat_reference errors final_status ready well_formed],
          result.keys.sort,
          timeout
        )
        refute result.fetch("well_formed"), timeout
        refute result.fetch("ready"), timeout
        assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers"), timeout
        assert_equal(
          ["COMPLETED_BATCH_AUDIT_GH_TIMEOUT_SECONDS must be a positive integer"],
          result.fetch("errors"),
          timeout
        )
        assert_nil result.fetch("chat_reference"), timeout
        refute File.exist?(env.fetch("FAKE_GH_LOG")), timeout
      end
    end
  end

  def test_missing_or_wrong_batch_fails_closed
    missing = CompletedBatchAuditReceipt.replay_marker("", expected_batch_id: "batch-184")
    wrong_batch = CompletedBatchAuditReceipt.replay_marker(ready_marker, expected_batch_id: "batch-185")

    [missing, wrong_batch].each do |result|
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
    end
  end

  def test_deterministic_anchor_prefers_prs_then_normalized_repo_and_number
    targets = [
      { "host" => "github.com", "repo" => "Zulu/Repo", "type" => "issue", "number" => 1 },
      { "host" => "github.com", "repo" => "Acme/Widgets", "type" => "pull_request", "number" => 9 },
      { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 4 }
    ]

    anchor = CompletedBatchAuditReceipt.deterministic_targets(targets).first

    assert_equal "pull_request", anchor.fetch("type")
    assert_equal 4, anchor.fetch("number")
  end

  def test_publish_anchor_selection_never_falls_through_first_deterministic_target
    targets = [
      { "host" => "github.com", "repo" => "zulu/widgets", "type" => "pull_request", "number" => 185 },
      { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    ]
    calls = []
    fake_api = lambda do |host, endpoint, method: "GET", input: nil|
      calls << [host, endpoint, method, input]
      case endpoint
      when "user"
        { "login" => "justin808", "type" => "User" }
      when "repos/acme/widgets/issues/184"
        {
          "number" => 184,
          "html_url" => "https://github.com/acme/widgets/pull/184",
          "locked" => true,
          "pull_request" => {}
        }
      when "repos/zulu/widgets/issues/185"
        {
          "number" => 185,
          "html_url" => "https://github.com/zulu/widgets/pull/185",
          "locked" => false,
          "pull_request" => {}
        }
      when "repos/zulu/widgets/collaborators/justin808/permission"
        { "permission" => "write", "user" => { "login" => "justin808", "type" => "User" } }
      else
        flunk "unexpected API endpoint: #{endpoint}"
      end
    end

    error = nil
    with_stubbed_gh_api(fake_api) do
      error = assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.select_verified_anchor(targets)
      end
    end

    assert_equal "CompletedBatchAuditReceipt::AnchorVerificationError", error.class.name
    assert_equal [
      ["github.com", "user", "GET", nil],
      ["github.com", "repos/acme/widgets/issues/184", "GET", nil]
    ], calls
  end

  def test_target_host_validation_rejects_noncanonical_authorities
    invalid_hosts = [
      "https://github.com",
      "github.com/",
      ".github.com",
      "github..com",
      "-github.com",
      "github.com-",
      "github.com:0",
      "github.com:65536"
    ]

    invalid_hosts.each do |host|
      assert_raises(ArgumentError, host) do
        CompletedBatchAuditReceipt.deterministic_targets(
          [{ "host" => host, "repo" => "acme/widgets", "type" => "issue", "number" => 184 }]
        )
      end
    end
  end

  def test_readback_mutation_state_requires_positive_comment_id
    [nil, 0, -1, "not-an-id"].each do |comment_id|
      assert_raises(ArgumentError) do
        CompletedBatchAuditReceipt::PostReadbackError.new("invalid state", comment_id:)
      end
    end

    error = CompletedBatchAuditReceipt::PostReadbackError.new("valid state", comment_id: "9001")
    assert_equal 9001, error.comment_id
  end

  def test_typed_operational_errors_map_to_fixed_safe_blockers
    unsafe_message = "remote\n<!-- untrusted -->"
    cases = {
      CompletedBatchAuditReceipt::AnchorVerificationError.new(unsafe_message) =>
        "completed-batch-audit anchor verification failed",
      CompletedBatchAuditReceipt::ReplayGitHubApiError.new(unsafe_message) =>
        "completed-batch-audit replay GitHub API request failed",
      CompletedBatchAuditReceipt::PostOutcomeUnknownError.new(unsafe_message) =>
        "completed-batch-audit comment POST outcome unknown",
      CompletedBatchAuditReceipt::PostReadbackError.new(unsafe_message, comment_id: 9001) =>
        "completed-batch-audit comment readback verification failed",
      CompletedBatchAuditReceipt::PublicationPreflightError.new(unsafe_message) =>
        "completed-batch-audit publication preflight failed"
    }

    cases.each do |error, expected|
      blocker = CompletedBatchAuditReceipt.failure_blocker(error)
      assert_equal expected, blocker
      refute_includes blocker, "untrusted"
    end
    assert_equal(
      "completed-batch-audit marker invalid",
      CompletedBatchAuditReceipt.failure_blocker(CompletedBatchAuditReceipt::Error.new(unsafe_message))
    )
  end

  def test_empty_manifest_fails_closed_without_post_or_fallback_issue_creation
    with_fake_gh do |env, directory|
      targets_path = write_json(directory, "targets.json", [])
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit publication preflight failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit publication preflight failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      refute File.exist?(env.fetch("FAKE_GH_LOG"))
    end
  end

  def test_publish_posts_then_reads_back_before_emitting_compact_reference
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert result.fetch("well_formed")
      assert result.fetch("ready")
      assert_empty result.fetch("blockers")
      reference = result.fetch("chat_reference")
      assert_includes reference, "Completed-batch audit: clean"
      assert_includes reference, "https://github.com/acme/widgets/pull/184#issuecomment-9001"
      assert_match(/SHA-256 `[0-9a-f]{64}`/, reference)
      refute_includes reference, "<!-- completed-batch-audit"
      posted_comment = File.read(env.fetch("FAKE_GH_BODY"))
      assert posted_comment.start_with?("Completed-batch audit: replay evidence follows.\n\n")
      summary = result.fetch("pr_description_summary")
      assert_equal "https://github.com/acme/widgets/pull/184", summary.fetch("url")
      assert_includes summary.fetch("section"), CompletedBatchAuditReceipt::PR_SUMMARY_START
      assert_includes summary.fetch("section"), "#### Completed-batch audit"
      assert_includes summary.fetch("section"), "**Status:** Clean — no outstanding findings or follow-ups."
      assert_includes summary.fetch("section"), "pull/184#issuecomment-9001"
      assert_includes summary.fetch("section"), CompletedBatchAuditReceipt::PR_SUMMARY_END

      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(1, calls.count { |call| call.include?("--method POST") })
      assert_equal(0, calls.count { |call| call.include?("--method PATCH") })
      assert_operator(calls.index { |call| call.include?("--method POST") }, :<,
                      calls.index { |call| call.end_with?("repos/acme/widgets/issues/comments/9001") })
    end
  end

  def test_publish_accepts_the_documented_full_durable_comment_body
    [ready_marker, ready_marker.chomp].each do |supplied_marker|
      with_fake_gh do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        full_body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{supplied_marker}"
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, full_body)

        out, err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert status.success?, err
        result = JSON.parse(out)
        assert result.fetch("ready")
        posted_body = File.read(env.fetch("FAKE_GH_BODY"))
        assert posted_body.start_with?("#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n")
        bound_marker = CompletedBatchAuditReceipt.comment_marker(posted_body)
        assert_includes bound_marker, "publication_snapshot: sha256:"
        assert_equal "batch-184", CompletedBatchAuditReceipt.marker_fields(bound_marker).fetch("batch_id")
        assert_equal Digest::SHA256.hexdigest(posted_body), result.dig("receipt", "sha256")
      end
    end
  end

  def test_replay_parser_keeps_legacy_durable_comments_valid
    legacy_body = "#{CompletedBatchAuditReceipt::LEGACY_COMMENT_HEADER}\n\n#{ready_marker}"

    assert_equal ready_marker, CompletedBatchAuditReceipt.comment_marker(legacy_body)
    replayed = CompletedBatchAuditReceipt.replay_marker(
      CompletedBatchAuditReceipt.comment_marker(legacy_body),
      expected_batch_id: "batch-184"
    )
    assert replayed.fetch("well_formed")
    refute replayed.fetch("ready")
    assert_equal(
      ["completed-batch-audit publication snapshot refresh required"],
      replayed.fetch("blockers")
    )
  end

  def test_publish_canonicalizes_legacy_full_comment_to_the_concise_header
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, "#{CompletedBatchAuditReceipt::LEGACY_COMMENT_HEADER}\n\n#{ready_marker}")

      _out, err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert status.success?, err
      posted_body = File.read(env.fetch("FAKE_GH_BODY"))
      assert posted_body.start_with?("#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n")
      refute_includes posted_body, CompletedBatchAuditReceipt::LEGACY_COMMENT_HEADER
    end
  end

  def test_publish_canonicalizes_marker_wrapper_with_snapshot_binding_regardless_of_trailing_newline
    [ready_marker, ready_marker.chomp].each do |supplied_marker|
      with_fake_gh do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, supplied_marker)

        publish_out, publish_err, publish_status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert publish_status.success?, publish_err
        published = JSON.parse(publish_out)
        posted_body = File.read(env.fetch("FAKE_GH_BODY"))
        bound_marker = CompletedBatchAuditReceipt.comment_marker(posted_body)
        assert_includes bound_marker, "publication_snapshot: sha256:"
        assert_equal "batch-184", CompletedBatchAuditReceipt.marker_fields(bound_marker).fetch("batch_id")
        assert_equal Digest::SHA256.hexdigest(posted_body), published.dig("receipt", "sha256")

        reference_path = File.join(directory, "reference.txt")
        File.write(reference_path, published.fetch("chat_reference"))
        replay_out, replay_err, replay_status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "replay",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--reference-file",
          reference_path
        )

        assert replay_status.success?, replay_err
        replayed = JSON.parse(replay_out)
        assert replayed.fetch("ready")
        assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
      end
    end
  end

  def test_publish_rejects_extra_visible_text_around_a_full_durable_comment_body
    ["unexpected preface\n%s", "%sunexpected suffix\n"].each do |format|
      with_fake_gh do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        full_body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{ready_marker}"
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, format(format, full_body))

        out, _err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus
        result = JSON.parse(out)
        refute result.fetch("well_formed")
        refute result.fetch("ready")
        assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
        refute File.exist?(env.fetch("FAKE_GH_LOG"))
      end
    end
  end

  def test_replay_fetches_exact_comment_id_and_verifies_reference_bindings
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))

      out, err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert result.fetch("well_formed")
      assert result.fetch("ready")
      assert_empty result.fetch("blockers")
      assert_equal "Conversation status: Ready for archiving.", result.fetch("final_status")
      assert_equal JSON.parse(publish_out).fetch("chat_reference"), result.fetch("chat_reference")
    end
  end

  def test_replay_missing_remote_comment_remains_structured_exit_one
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))
      env["FAKE_GH_MODE"] = "readback-failure"
      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit replay GitHub API request failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit replay GitHub API request failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      refute result.key?("mutation_state")
    end
  end

  def test_cli_publish_and_replay_never_report_ready_with_external_blockers
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path,
        "--other-blocker",
        "release owner confirmation"
      )

      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert published.fetch("well_formed")
      refute published.fetch("ready")
      assert_equal ["release owner confirmation"], published.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — release owner confirmation.",
        published.fetch("final_status")
      )
      summary = published.fetch("pr_description_summary").fetch("section")
      assert_includes summary, "**Status:** Follow-ups remain — see the durable receipt."
      refute_includes summary, "**Status:** Clean"

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path,
        "--other-blocker",
        "release owner confirmation"
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("well_formed")
      refute replayed.fetch("ready")
      assert_equal ["release owner confirmation"], replayed.fetch("blockers")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
      replay_summary = replayed.fetch("pr_description_summary").fetch("section")
      assert_equal summary, replay_summary

      cleared_out, cleared_err, cleared_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert cleared_status.success?, cleared_err
      cleared = JSON.parse(cleared_out)
      assert cleared.fetch("ready")
      cleared_summary = cleared.fetch("pr_description_summary").fetch("section")
      assert_includes cleared_summary, "**Status:** Clean — no outstanding findings or follow-ups."
      refute_equal summary, cleared_summary
    end
  end

  def test_invalid_remote_reference_fails_closed_and_preserves_sanitized_external_blockers
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, _publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?
      reference = JSON.parse(publish_out).fetch("chat_reference")
      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, reference.sub(/SHA-256 `[0-9a-f]{64}`/, "SHA-256 `#{'0' * 64}`"))

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path,
        "--other-blocker",
        " release owner confirmation ",
        "--other-blocker",
        "release owner confirmation"
      )

      refute status.success?
      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      assert_equal ["completed-batch-audit marker invalid", "release owner confirmation"], result.fetch("blockers")
      assert_equal "Conversation status: Follow-ups remain — completed-batch-audit marker invalid; release owner confirmation.",
                   result.fetch("final_status")
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_post_success_readback_failure_reports_ambiguous_mutation_without_retry
    with_fake_gh(mode: "readback-failure") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      assert_equal "comment-created-readback-unknown", result.fetch("mutation_state")
      assert_equal 9001, result.fetch("comment_id")
      assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit comment readback verification failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(1, calls.count { |call| call.include?("--method POST") })
      assert_equal(1, calls.count { |call| call.end_with?("repos/acme/widgets/issues/comments/9001") })
    end
  end

  def test_post_success_invalid_readback_schema_is_a_remote_failure_not_usage
    %w[readback-invalid-json readback-array].each do |mode|
      with_fake_gh(mode:) do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, _err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus, mode
        result = JSON.parse(out)
        assert_equal "comment-created-readback-unknown", result.fetch("mutation_state"), mode
        assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers"), mode
        assert_nil result.fetch("chat_reference"), mode
      end
    end
  end

  def test_ambiguous_post_outcome_has_distinct_state_without_comment_id_or_retry
    %w[post-nonzero post-timeout post-invalid-json post-array post-missing-id].each do |mode|
      with_fake_gh(mode:) do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, _err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus, mode
        result = JSON.parse(out)
        assert_equal "comment-post-outcome-unknown", result.fetch("mutation_state"), mode
        refute result.key?("comment_id"), mode
        assert_equal ["completed-batch-audit comment POST outcome unknown"], result.fetch("blockers"), mode
        assert_equal(
          "Conversation status: Follow-ups remain — completed-batch-audit comment POST outcome unknown.",
          result.fetch("final_status"),
          mode
        )
        assert_nil result.fetch("chat_reference"), mode
        calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
        assert_equal 1, calls.count { |call| call.include?("--method POST") }, mode
        assert_equal 0, calls.count { |call| call.include?("issues/comments/") }, mode
      end
    end
  end

  def test_post_timeout_is_bounded_and_reaps_child_before_delayed_side_effect
    with_fake_gh(mode: "post-timeout") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = Timeout.timeout(10) do
        capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )
      end

      assert_equal 1, status.exitstatus
      child_pid = Integer(File.read(env.fetch("FAKE_GH_PID"), encoding: "UTF-8"), 10)
      assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.25
      sleep 0.05 while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      refute File.exist?(env.fetch("FAKE_GH_LATE_SIDE_EFFECT"))

      result = JSON.parse(out)
      assert_equal "comment-post-outcome-unknown", result.fetch("mutation_state")
      refute result.key?("comment_id")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      post_count = calls.count { |call| call.include?("--method POST") }
      assert_equal 1, post_count
    end
  end

  def test_compact_reference_preserves_explicit_github_enterprise_port
    reference = "Completed-batch audit: clean — " \
                "[durable v1 receipt](https://github.company.example:8443/acme/widgets/issues/184#issuecomment-9001); " \
                "SHA-256 `#{'a' * 64}`; author `maintainer`; " \
                "version `2026-07-18T18:00:00Z/2026-07-18T18:00:00Z`."

    parsed = CompletedBatchAuditReceipt.parse_reference(reference)

    assert_equal "github.company.example:8443", parsed.dig("target", "host")
    assert_equal "issue", parsed.dig("target", "type")
  end

  def test_publish_and_replay_canonicalize_explicit_default_https_port
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com:443", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      refute_includes published.fetch("chat_reference"), "github.com:443"

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("well_formed")
      assert replayed.fetch("ready")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
    end
  end

  def test_publish_and_replay_adopt_api_canonical_repo_casing
    with_fake_gh(mode: "canonical-repo-case") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert_includes published.fetch("chat_reference"), "github.com/Acme/Widgets/pull/184#issuecomment-9001"
      assert_equal "Acme/Widgets", published.dig("receipt", "repo")

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("ready")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_includes calls, "api --hostname github.com repos/Acme/Widgets/collaborators/justin808/permission"
      assert_includes calls, "api --hostname github.com repos/Acme/Widgets/issues/184/comments --method POST --input -"
      comment_read_count = calls.count { |call| call.end_with?("repos/Acme/Widgets/issues/comments/9001") }
      assert_equal 2, comment_read_count
    end
  end

  def test_target_payload_casing_exception_rejects_hostile_identity_changes
    target = { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    base = {
      "number" => 184,
      "html_url" => "https://github.com/Acme/Widgets/pull/184",
      "locked" => false,
      "pull_request" => {}
    }
    hostile_payloads = [
      base.merge("html_url" => "https://example.com/Acme/Widgets/pull/184"),
      base.merge("html_url" => "https://github.com/Acme/Other/pull/184"),
      base.merge("html_url" => "https://github.com/Acme/Widgets/issues/184"),
      base.merge("html_url" => "https://github.com/Acme/Widgets/pull/185"),
      base.merge("number" => 185)
    ]

    assert_equal "Acme/Widgets", CompletedBatchAuditReceipt.verify_target_payload!(base, target).fetch("repo")
    hostile_payloads.each do |payload|
      assert_raises(CompletedBatchAuditReceipt::Error, payload.fetch("html_url")) do
        CompletedBatchAuditReceipt.verify_target_payload!(payload, target)
      end
    end
  end

  def test_emu_login_with_underscore_round_trips_publish_and_replay
    with_fake_gh(mode: "emu-actor") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert_includes published.fetch("chat_reference"), "author `justin_emu`"

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      assert JSON.parse(replay_out).fetch("ready")
    end
  end

  def test_enterprise_issue_api_url_must_preserve_the_manifest_port
    target = {
      "host" => "github.company.example:8443",
      "repo" => "acme/widgets",
      "type" => "issue",
      "number" => 184
    }

    assert_raises(CompletedBatchAuditReceipt::Error) do
      CompletedBatchAuditReceipt.verify_issue_url!(
        "https://github.company.example:9443/api/v3/repos/acme/widgets/issues/184",
        target
      )
    end
  end

  def test_publish_rejects_a_different_but_valid_readback_body
    with_fake_gh(mode: "changed-valid-body") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers")
      assert_equal "comment-created-readback-unknown", result.fetch("mutation_state")
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_publish_rejects_bot_accounts_as_durable_receipt_authors
    with_fake_gh(mode: "bot-actor") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_equal(
        "Conversation status: Follow-ups remain — completed-batch-audit anchor verification failed.",
        result.fetch("final_status")
      )
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_publish_rejects_authenticated_bot_object_with_human_login
    with_fake_gh(mode: "actor-type-bot") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_publish_failure_matrix_fails_closed_after_exactly_one_post
    %w[wrong-author association-none edited wrong-url wrong-issue-url malformed-body invalid-user].each do |mode|
      with_fake_gh(mode:) do |env, directory|
        targets_path = write_json(
          directory,
          "targets.json",
          [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
        )
        receipt_path = File.join(directory, "receipt.txt")
        File.write(receipt_path, ready_marker)

        out, _err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "publish",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--receipt",
          receipt_path
        )

        assert_equal 1, status.exitstatus, mode
        result = JSON.parse(out)
        refute result.fetch("well_formed"), mode
        refute result.fetch("ready"), mode
        assert_equal ["completed-batch-audit comment readback verification failed"], result.fetch("blockers"), mode
        assert_nil result.fetch("chat_reference"), mode
        calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
        assert_equal 1, calls.count { |call| call.include?("--method POST") }, mode
      end
    end
  end

  def test_publish_rejects_comment_bot_object_with_human_login
    with_fake_gh(mode: "comment-type-bot") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal "comment-created-readback-unknown", result.fetch("mutation_state")
      assert_equal 9001, result.fetch("comment_id")
      assert_nil result.fetch("chat_reference")
    end
  end

  def test_replay_rejects_comment_bot_object_with_human_login
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))
      env["FAKE_GH_MODE"] = "comment-type-bot"
      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit marker invalid"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      refute result.key?("mutation_state")
    end
  end

  def test_replay_ignores_current_actor_permission_and_target_lock_state
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, JSON.parse(publish_out).fetch("chat_reference"))
      File.write(env.fetch("FAKE_GH_LOG"), "")
      env["FAKE_GH_MODE"] = "replay-current-state-changed"
      out, err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert result.fetch("well_formed")
      assert result.fetch("ready")
      assert_equal [
        "api --hostname github.com repos/acme/widgets/issues/comments/9001",
        "api --hostname github.com repos/acme/widgets/pulls/184"
      ], File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
    end
  end

  def test_invalid_permission_schema_fails_closed_before_posting
    with_fake_gh(mode: "invalid-permission-user") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_publish_rejects_permission_bot_object_with_human_login
    with_fake_gh(mode: "permission-type-bot") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)

      out, _err, status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert_equal 1, status.exitstatus
      result = JSON.parse(out)
      refute result.fetch("well_formed")
      refute result.fetch("ready")
      assert_equal ["completed-batch-audit anchor verification failed"], result.fetch("blockers")
      assert_nil result.fetch("chat_reference")
      calls = File.readlines(env.fetch("FAKE_GH_LOG"), chomp: true)
      assert_equal(0, calls.count { |call| call.include?("--method POST") })
    end
  end

  def test_issue_only_batch_can_anchor_and_replay_a_verified_nonready_receipt
    with_fake_gh(target_type: "issue") do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "issue", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, followup_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )

      assert publish_status.success?, publish_err
      published = JSON.parse(publish_out)
      assert published.fetch("well_formed")
      refute published.fetch("ready")
      assert_equal ["#184 (open): fix"], published.fetch("blockers")
      assert_includes published.fetch("chat_reference"), "/issues/184#issuecomment-9001"
      assert_equal "Conversation status: Follow-ups remain — #184 (open): fix.", published.fetch("final_status")

      reference_path = File.join(directory, "reference.txt")
      File.write(reference_path, published.fetch("chat_reference"))
      replay_out, replay_err, replay_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "replay",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--reference-file",
        reference_path
      )

      assert replay_status.success?, replay_err
      replayed = JSON.parse(replay_out)
      assert replayed.fetch("well_formed")
      refute replayed.fetch("ready")
      assert_equal published.fetch("chat_reference"), replayed.fetch("chat_reference")
    end
  end

  def test_replay_binding_matrix_uses_only_the_manifest_and_exact_comment_endpoint
    with_fake_gh do |env, directory|
      targets_path = write_json(
        directory,
        "targets.json",
        [{ "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }]
      )
      receipt_path = File.join(directory, "receipt.txt")
      File.write(receipt_path, ready_marker)
      publish_out, publish_err, publish_status = capture_receipt_cli(
        env,
        "ruby",
        SCRIPT,
        "publish",
        "--expected-batch-id",
        "batch-184",
        "--targets-json",
        targets_path,
        "--receipt",
        receipt_path
      )
      assert publish_status.success?, publish_err
      reference = JSON.parse(publish_out).fetch("chat_reference")
      variants = {
        "host" => reference.sub("github.com", "example.com"),
        "repo" => reference.sub("acme/widgets", "acme/other"),
        "type" => reference.sub("/pull/184", "/issues/184"),
        "number" => reference.sub("/pull/184", "/pull/185"),
        "id" => reference.sub("issuecomment-9001", "issuecomment-9002"),
        "result" => reference.sub("audit: clean", "audit: follow-ups-remain"),
        "version" => reference.sub(
          "2026-07-18T18:00:00Z/2026-07-18T18:00:00Z",
          "2026-07-18T18:00:01Z/2026-07-18T18:00:01Z"
        )
      }

      variants.each do |label, candidate|
        reference_path = File.join(directory, "#{label}.txt")
        File.write(reference_path, candidate)
        out, _err, status = capture_receipt_cli(
          env,
          "ruby",
          SCRIPT,
          "replay",
          "--expected-batch-id",
          "batch-184",
          "--targets-json",
          targets_path,
          "--reference-file",
          reference_path
        )
        assert_equal 1, status.exitstatus, label
        result = JSON.parse(out)
        refute result.fetch("well_formed"), label
        refute result.fetch("ready"), label
        assert_nil result.fetch("chat_reference"), label
      end

      log = File.read(env.fetch("FAKE_GH_LOG"), encoding: "UTF-8")
      refute_includes log, "https://"
      refute_match(%r{issues/comments(?:\s|$)}, log)
    end
  end

  def test_replay_rejects_noncanonical_verified_manifest_target_before_comment_readback
    targets = [
      { "host" => "github.com", "repo" => "zulu/widgets", "type" => "pull_request", "number" => 185 },
      { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    ]
    body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{ready_marker}"
    created_at = "2026-07-18T18:00:00Z"
    second_target_receipt = {
      "url" => "https://github.com/zulu/widgets/pull/185#issuecomment-9002",
      "sha256" => Digest::SHA256.hexdigest(body),
      "author" => "justin808",
      "created_at" => created_at,
      "updated_at" => created_at
    }
    reference = CompletedBatchAuditReceipt.compact_reference("clean", second_target_receipt)
    calls = []
    fake_api = lambda do |host, endpoint, method: "GET", input: nil|
      calls << [host, endpoint, method, input]
      case endpoint
      when "user"
        { "login" => "justin808", "type" => "User" }
      when "repos/acme/widgets/issues/184"
        {
          "number" => 184,
          "html_url" => "https://github.com/acme/widgets/pull/184",
          "locked" => false,
          "pull_request" => {}
        }
      when "repos/zulu/widgets/issues/185"
        {
          "number" => 185,
          "html_url" => "https://github.com/zulu/widgets/pull/185",
          "locked" => false,
          "pull_request" => {}
        }
      when "repos/acme/widgets/collaborators/justin808/permission",
           "repos/zulu/widgets/collaborators/justin808/permission"
        { "permission" => "write", "user" => { "login" => "justin808", "type" => "User" } }
      when "repos/zulu/widgets/issues/comments/9002"
        {
          "id" => 9002,
          "html_url" => second_target_receipt.fetch("url"),
          "issue_url" => "https://api.github.com/repos/zulu/widgets/issues/185",
          "user" => { "login" => "justin808", "type" => "User" },
          "author_association" => "MEMBER",
          "created_at" => created_at,
          "updated_at" => created_at,
          "body" => body
        }
      else
        flunk "unexpected API endpoint: #{endpoint}"
      end
    end

    with_stubbed_gh_api(fake_api) do
      assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.replay_reference(
          expected_batch_id: "batch-184",
          targets:,
          reference:
        )
      end
    end

    assert_empty calls
    refute(calls.any? { |_host, _endpoint, method, _input| method == "POST" })
  end

  def test_replay_github_api_failure_has_a_distinct_typed_error
    target = { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{ready_marker}"
    created_at = "2026-07-18T18:00:00Z"
    reference = CompletedBatchAuditReceipt.compact_reference(
      "clean",
      {
        "url" => "https://github.com/acme/widgets/pull/184#issuecomment-9001",
        "sha256" => Digest::SHA256.hexdigest(body),
        "author" => "justin808",
        "created_at" => created_at,
        "updated_at" => created_at
      }
    )
    failing_api = lambda do |_host, _endpoint, method: "GET", input: nil|
      flunk "unexpected non-GET request" unless method == "GET" && input.nil?

      raise CompletedBatchAuditReceipt::Error, "remote text must not become a blocker"
    end

    error = nil
    with_stubbed_gh_api(failing_api) do
      error = assert_raises(CompletedBatchAuditReceipt::Error) do
        CompletedBatchAuditReceipt.replay_reference(
          expected_batch_id: "batch-184",
          targets: [target],
          reference:
        )
      end
    end

    assert_equal "CompletedBatchAuditReceipt::ReplayGitHubApiError", error.class.name
  end

  def write_json(directory, name, value)
    path = File.join(directory, name)
    File.write(path, JSON.generate(value))
    path
  end

  def capture_receipt_cli(*arguments)
    command = arguments.dup
    script_index = command.index(SCRIPT)
    if script_index &&
       %w[publish replay supersede].include?(command[script_index + 1]) &&
       !command.include?("--workflow-config")
      environment = command.first.is_a?(Hash) ? command.first : {}
      workflow_config = environment.fetch("FAKE_WORKFLOW_CONFIG", WORKFLOW_CONFIG)
      command.concat(["--workflow-config", workflow_config])
    end
    stdout, stderr, status = Open3.capture3(*command)
    # The receipt CLI emits UTF-8 JSON, but Open3 labels captured output with
    # Encoding.default_external, which can be US-ASCII under an unset locale.
    [stdout.force_encoding(Encoding::UTF_8), stderr.force_encoding(Encoding::UTF_8), status]
  end

  def publication_preflight(head_sha: "a" * 40, waived: false, coordination_backend: "n/a")
    target = { "host" => "github.com", "repo" => "acme/widgets", "type" => "pull_request", "number" => 184 }
    waiver_url = "https://github.com/acme/widgets/pull/184#issuecomment-9184"
    evidence = <<~MARKER
      <!-- qa-evidence v1
      required: yes
      status: #{waived ? 'waived' : 'satisfied'}
      head_sha: #{head_sha}
      tested_at: PR/head #{head_sha}
      scope: PR #184 exact head
      automated_checks: focused tests
      manual_checks: not applicable: no manual surface
      findings: #{waived ? "waived: #{waiver_url}" : 'none'}
      release_blocking: #{waived ? 'waived' : 'clear'}
      process_gap_disposition: script
      -->
    MARKER
    qa_row = { "target" => target, "user_visible_ui_change" => "no", "evidence" => evidence }
    qa_row["maintainer_waiver"] = { "url" => waiver_url } if waived
    coordination_status = if coordination_backend == "n/a"
                            {
                              "contract" => "completed-batch-coordination-not-applicable",
                              "version" => 1,
                              "batch_id" => "batch-184",
                              "mode" => "single_operator",
                              "rationale" => "repository workflow seam declares coordination_backend: n/a",
                              "source" => "https://github.com/acme/widgets/blob/#{head_sha}/.agents/agent-workflow.yml",
                              "completed_at" => "2026-07-18T17:59:59Z",
                              "targets" => [target]
                            }
                          else
                            {
                              "scope" => { "kind" => "batch", "batch_id" => "batch-184" },
                              "batches" => [{
                                "batch_id" => "batch-184",
                                "repo" => "acme/widgets",
                                "status" => "completed",
                                "updated_at" => "2026-07-18T17:59:59Z",
                                "completed_at" => "2026-07-18T17:59:59Z",
                                "lanes" => [{
                                  "name" => "batch-184-pr-184",
                                  "targets" => ["184"],
                                  "status" => "done",
                                  "terminal" => "done",
                                  "closed_at" => "2026-07-18T17:59:59Z",
                                  "pr_state" => "merged",
                                  "pr_url" => "https://github.com/acme/widgets/pull/184",
                                  "evidence_url" => "https://github.com/acme/widgets/pull/184"
                                }]
                              }]
                            }
                          end
    input = {
      "contract" => "completed-batch-publication-preflight-input",
      "version" => 1,
      "batch_id" => "batch-184",
      "expected_targets" => [target],
      "coordination_status" => coordination_status,
      "target_snapshots" => [{
        "target" => target,
        "state" => "merged",
        "head_sha" => head_sha,
        "source" => "https://github.com/acme/widgets/pull/184"
      }],
      "qa_evidence" => [qa_row]
    }
    comment = publication_waiver_comment(head_sha:, url: waiver_url)
    CompletedBatchPublicationPreflight.assess(
      input,
      coordination_backend:,
      waiver_verifier: ->(**_keywords) { comment },
      target_verifier: lambda do |target:|
        {
          "target" => target,
          "state" => "merged",
          "head_sha" => head_sha,
          "completed_at" => "2026-07-18T17:59:59Z",
          "verification_source" => "authenticated gh api"
        }
      end,
      coordination_verifier: lambda do |backend:, batch_id:|
        coordination_status if backend == coordination_backend && batch_id == "batch-184"
      end
    )
  end

  def publication_target_payload(head_sha: "a" * 40)
    {
      "number" => 184,
      "html_url" => "https://github.com/acme/widgets/pull/184",
      "state" => "closed",
      "merged_at" => "2026-07-18T17:59:59Z",
      "head" => { "sha" => head_sha }
    }
  end

  def publication_waiver_comment(head_sha:, url: "https://github.com/acme/widgets/pull/184#issuecomment-9184")
    {
      "id" => Integer(url[/#issuecomment-(\d+)\z/, 1], 10),
      "html_url" => url,
      "issue_url" => "https://api.github.com/repos/acme/widgets/issues/184",
      "body" => <<~BODY,
        <!-- qa-maintainer-waiver v1
        target: https://github.com/acme/widgets/pull/184
        head_sha: #{head_sha}
        decision: waived
        -->
      BODY
      "user" => { "login" => "maintainer", "type" => "User" },
      "author_association" => "MEMBER",
      "created_at" => "2026-07-18T17:59:59Z",
      "updated_at" => "2026-07-18T17:59:59Z"
    }
  end

  def accepted_deferral_publication_preflight(target, blockers: nil)
    head_sha = "4" * 40
    result = {
      "contract" => "completed-batch-publication-preflight",
      "version" => 1,
      "batch_id" => "ror-d-issue-4731-20260817",
      "coordination_backend" => REAL_BACKEND,
      "eligible" => false,
      "verdict" => "BLOCKED",
      "targets" => [target],
      "blockers" => blockers || [
        "coordination lane ror-d-issue-4731 target is absent or ambiguous",
        "issue shakacode/react_on_rails#4731 is absent from resolved coordination scope"
      ],
      "source_input" => {
        "contract" => "completed-batch-publication-preflight-input",
        "version" => 1,
        "batch_id" => "ror-d-issue-4731-20260817",
        "expected_targets" => [target],
        "coordination_status" => {},
        "target_snapshots" => [],
        "qa_evidence" => []
      },
      "snapshot" => {
        "batch_id" => "ror-d-issue-4731-20260817",
        "coordination_backend" => REAL_BACKEND,
        "coordination" => {
          "status" => "completed",
          "updated_at" => "2026-08-17T20:00:00Z",
          "completed_at" => "2026-08-17T20:00:00Z",
          "lanes" => [],
          "verification_source" => "authenticated agent-coord-bounded"
        },
        "targets" => [{
          "target" => target,
          "state" => "closed",
          "head_sha" => head_sha,
          "no_pr_evidence" => nil,
          "source" => "https://github.com/shakacode/react_on_rails/pull/4918",
          "verification_source" => "authenticated gh api"
        }],
        "qa" => [{
          "target" => target,
          "head_sha" => head_sha,
          "verdict" => "SATISFIED",
          "status" => "satisfied",
          "user_visible_ui_change" => "no",
          "evidence_sha256" => "sha256:#{'5' * 64}",
          "maintainer_waiver" => nil
        }]
      }
    }
    result["source_input"] = CompletedBatchPublicationPreflight.canonicalize(result.fetch("source_input"))
    result["snapshot"] = CompletedBatchPublicationPreflight.canonicalize(result.fetch("snapshot"))
    result["source_input_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("source_input"))
    result["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("snapshot"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(result)
    result
  end

  def accepted_deferral_predecessor_receipt(marker)
    body = "#{CompletedBatchAuditReceipt::COMMENT_HEADER}\n\n#{marker}"
    {
      "url" => "https://github.com/shakacode/react_on_rails/issues/4731#issuecomment-5389270559",
      "comment_id" => 5_389_270_559,
      "sha256" => Digest::SHA256.hexdigest(body),
      "author" => "maintainer",
      "created_at" => "2026-08-17T23:00:00Z",
      "updated_at" => "2026-08-17T23:00:00Z",
      "marker" => marker,
      "body" => body
    }
  end

  def accepted_deferral_api(preflight, predecessor: nil, mutate_decision: nil, corrupt_predecessor: false)
    lambda do |_host, endpoint, **_options|
      case endpoint
      when "repos/shakacode/react_on_rails/issues/comments/5400000000"
        {
          "id" => 5_400_000_000,
          "html_url" => "https://github.com/shakacode/react_on_rails/issues/4731#issuecomment-5400000000",
          "issue_url" => "https://api.github.com/repos/shakacode/react_on_rails/issues/4731",
          "body" => begin
            body = <<~BODY
              <!-- completed-batch-accepted-deferral-decision v1
              batch_id: ror-d-issue-4731-20260817
              blocker_ref: https://github.com/shakacode/agent-workflows/issues/320
              blocker_category: workflow-process-mechanism-defect
              mechanism: publication-preflight-target-resolution
              tracking_issue: https://github.com/shakacode/agent-workflows/issues/320
              owner: agent-workflows-maintainer
              original_receipt_sha256: #{predecessor ? "sha256:#{predecessor.fetch('sha256')}" : "sha256:#{Digest::SHA256.hexdigest(File.read(File.join(FIXTURES, 'completed-batch-accepted-deferral-ror-blocked.txt'), encoding: 'UTF-8'))}"}
              original_receipt_url: #{predecessor&.fetch('url') || 'not-published'}
              original_receipt_author: #{predecessor&.fetch('author') || 'not-applicable'}
              original_receipt_created_at: #{predecessor&.fetch('created_at') || 'not-applicable'}
              original_receipt_updated_at: #{predecessor&.fetch('updated_at') || 'not-applicable'}
              product_evidence_receipt: #{preflight.fetch('receipt_digest')}
              decision: accepted-deferral
              -->
            BODY
            mutate_decision ? mutate_decision.call(body) : body
          end,
          "user" => { "login" => "maintainer", "type" => "User" },
          "author_association" => "MEMBER",
          "created_at" => "2026-08-18T00:00:00Z",
          "updated_at" => "2026-08-18T00:00:00Z"
        }
      when "repos/shakacode/react_on_rails/collaborators/maintainer/permission"
        { "permission" => "write", "user" => { "login" => "maintainer", "type" => "User" } }
      when "repos/shakacode/agent-workflows/issues/320"
        {
          "number" => 320,
          "html_url" => "https://github.com/shakacode/agent-workflows/issues/320",
          "state" => "open"
        }
      when "repos/shakacode/react_on_rails/issues/4731"
        {
          "number" => 4731,
          "html_url" => "https://github.com/shakacode/react_on_rails/issues/4731",
          "state" => "closed"
        }
      when "repos/shakacode/react_on_rails/pulls/4918"
        {
          "number" => 4918,
          "html_url" => "https://github.com/shakacode/react_on_rails/pull/4918",
          "state" => "closed",
          "merged_at" => "2026-08-17T20:00:00Z",
          "head" => { "sha" => "4" * 40 }
        }
      when "repos/shakacode/react_on_rails/issues/comments/5389270559"
        body = predecessor.fetch("body")
        body = body.sub("owner: agent-workflows-maintainer", "owner: changed-owner") if corrupt_predecessor
        {
          "id" => 5_389_270_559,
          "html_url" => predecessor.fetch("url"),
          "issue_url" => "https://api.github.com/repos/shakacode/react_on_rails/issues/4731",
          "body" => body,
          "user" => { "login" => predecessor.fetch("author"), "type" => "User" },
          "author_association" => "MEMBER",
          "created_at" => predecessor.fetch("created_at"),
          "updated_at" => predecessor.fetch("updated_at")
        }
      else
        raise "unexpected endpoint: #{endpoint}"
      end
    end
  end

  def accepted_deferral_supersede_api(preflight, predecessor:)
    calls = []
    posted_body = nil
    base = accepted_deferral_api(preflight, predecessor:)
    successor = method(:accepted_deferral_successor_comment)
    api = lambda do |host, endpoint, method: "GET", input: nil|
      calls << [host, endpoint, method]
      case [method, endpoint]
      when %w[GET user]
        { "login" => "maintainer", "type" => "User" }
      when ["POST", "repos/shakacode/react_on_rails/issues/4731/comments"]
        posted_body = JSON.parse(input).fetch("body")
        successor.call(posted_body)
      when ["GET", "repos/shakacode/react_on_rails/issues/comments/5400000001"]
        successor.call(posted_body)
      else
        base.call(host, endpoint, method:, input:)
      end
    end
    [api, calls]
  end

  def accepted_deferral_successor_comment(body)
    {
      "id" => 5_400_000_001,
      "html_url" => "https://github.com/shakacode/react_on_rails/issues/4731#issuecomment-5400000001",
      "issue_url" => "https://api.github.com/repos/shakacode/react_on_rails/issues/4731",
      "body" => body,
      "user" => { "login" => "maintainer", "type" => "User" },
      "author_association" => "MEMBER",
      "created_at" => "2026-08-18T01:00:00Z",
      "updated_at" => "2026-08-18T01:00:00Z"
    }
  end

  def with_stubbed_gh_api(callable)
    original = CompletedBatchAuditReceipt.method(:gh_api)
    CompletedBatchAuditReceipt.define_singleton_method(:gh_api, callable)
    yield
  ensure
    CompletedBatchAuditReceipt.define_singleton_method(:gh_api, original)
  end

  def with_accepted_deferral_api(preflight, callable, &block)
    coordination = lambda do |backend:, batch_id:|
      next unless backend == preflight.fetch("coordination_backend") && batch_id == preflight.fetch("batch_id")

      preflight.dig("source_input", "coordination_status")
    end
    with_stubbed_gh_api(callable) do
      with_stubbed_coordination_status(coordination, &block)
    end
  end

  def with_stubbed_coordination_status(callable)
    original = CompletedBatchAuditReceipt.method(:authenticated_publication_coordination_status)
    CompletedBatchAuditReceipt.define_singleton_method(:authenticated_publication_coordination_status, callable)
    yield
  ensure
    CompletedBatchAuditReceipt.define_singleton_method(:authenticated_publication_coordination_status, original)
  end

  def with_stubbed_preflight_capture_process(callable)
    original = CompletedBatchPublicationPreflight.method(:capture_process)
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, callable)
    yield
  ensure
    CompletedBatchPublicationPreflight.define_singleton_method(:capture_process, original)
  end

  def with_fake_gh(mode: nil, target_type: "pull_request", coordination_backend: "n/a")
    Dir.mktmpdir("completed-batch-audit-receipt") do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      gh = File.join(bin, "gh")
      File.write(gh, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"

        File.open(ENV.fetch("FAKE_GH_LOG"), "a") { |file| file.puts(ARGV.join(" ")) }
        args = ARGV.dup
        abort "expected api" unless args.shift == "api"
        if args[0] == "--hostname"
          args.shift
          host = args.shift
          abort "wrong host" unless host == "github.com"
        end
        endpoint = args.shift
        method = "GET"
        if (index = args.index("--method"))
          method = args.fetch(index + 1)
        end

        actor = if ENV["FAKE_GH_MODE"] == "bot-actor"
                  "automation[bot]"
                elsif ENV["FAKE_GH_MODE"] == "replay-current-state-changed"
                  "other-current-actor"
                elsif ENV["FAKE_GH_MODE"] == "emu-actor"
                  "justin_emu"
                else
                  "justin808"
                end
        durable_actor = ENV["FAKE_GH_MODE"] == "replay-current-state-changed" ? "justin808" : actor
        actor_type = ENV["FAKE_GH_MODE"] == "actor-type-bot" ? "Bot" : "User"
        target_type = ENV.fetch("FAKE_TARGET_TYPE")
        target_segment = target_type == "pull_request" ? "pull" : "issues"
        canonical_repo = ENV["FAKE_GH_MODE"] == "canonical-repo-case" ? "Acme/Widgets" : "acme/widgets"
        comment = lambda do |body|
          body = body.sub("checker sol/xhigh", "checker terra/high") if ENV["FAKE_GH_MODE"] == "changed-valid-body"
          body = "malformed durable body" if ENV["FAKE_GH_MODE"] == "malformed-body"
          result = {
            "id" => 9001,
            "node_id" => "IC_kwDO9001",
            "html_url" => "https://github.com/#{canonical_repo}/#{target_segment}/184#issuecomment-9001",
            "issue_url" => "https://api.github.com/repos/#{canonical_repo}/issues/184",
            "user" => {
              "login" => durable_actor,
              "type" => ENV["FAKE_GH_MODE"] == "comment-type-bot" ? "Bot" : "User"
            },
            "author_association" => "MEMBER",
            "created_at" => "2026-07-18T18:00:00Z",
            "updated_at" => "2026-07-18T18:00:00Z",
            "body" => body
          }
          result["user"]["login"] = "other-maintainer" if ENV["FAKE_GH_MODE"] == "wrong-author"
          result["user"] = "not-an-object" if ENV["FAKE_GH_MODE"] == "invalid-user"
          result["author_association"] = "NONE" if ENV["FAKE_GH_MODE"] == "association-none"
          result["updated_at"] = "2026-07-18T18:00:01Z" if ENV["FAKE_GH_MODE"] == "edited"
          result["html_url"] = result["html_url"].sub("issuecomment-9001", "issuecomment-9002") if ENV["FAKE_GH_MODE"] == "wrong-url"
          result["issue_url"] = result["issue_url"].sub("/issues/184", "/issues/185") if ENV["FAKE_GH_MODE"] == "wrong-issue-url"
          result
        end

        case [method, endpoint]
        when ["GET", "user"]
          puts JSON.generate("login" => actor, "type" => actor_type)
        when ["GET", "repos/acme/widgets/pulls/184"]
          puts JSON.generate(
            "number" => 184,
            "html_url" => "https://github.com/acme/widgets/pull/184",
            "state" => "closed",
            "merged_at" => "2026-07-18T17:59:59Z",
            "head" => { "sha" => "a" * 40 }
          )
        when ["GET", "repos/acme/widgets/issues/184"]
          target = {
            "number" => 184,
            "html_url" => "https://github.com/#{canonical_repo}/#{target_segment}/184",
            "locked" => ENV["FAKE_GH_MODE"] == "replay-current-state-changed"
          }
          target["pull_request"] = { "url" => "https://api.github.com/repos/acme/widgets/pulls/184" } if target_type == "pull_request"
          puts JSON.generate(target)
        when ["GET", "repos/#{canonical_repo}/collaborators/#{actor}/permission"]
          user = if ENV["FAKE_GH_MODE"] == "invalid-permission-user"
                   "not-an-object"
                 else
                   type = ENV["FAKE_GH_MODE"] == "permission-type-bot" ? "Bot" : "User"
                   { "login" => actor, "type" => type }
                 end
          permission = ENV["FAKE_GH_MODE"] == "replay-current-state-changed" ? "none" : "write"
          puts JSON.generate("permission" => permission, "user" => user)
        when ["POST", "repos/#{canonical_repo}/issues/184/comments"]
          payload = JSON.parse($stdin.read)
          File.write(ENV.fetch("FAKE_GH_BODY"), payload.fetch("body"))
          exit 1 if ENV["FAKE_GH_MODE"] == "post-nonzero"
          if ENV["FAKE_GH_MODE"] == "post-timeout"
            File.write(ENV.fetch("FAKE_GH_PID"), Process.pid.to_s)
            sleep 2
            File.write(ENV.fetch("FAKE_GH_LATE_SIDE_EFFECT"), "completed")
          end
          if ENV["FAKE_GH_MODE"] == "post-invalid-json"
            puts "{"
            exit
          end
          if ENV["FAKE_GH_MODE"] == "post-array"
            puts "[]"
            exit
          end
          if ENV["FAKE_GH_MODE"] == "post-missing-id"
            puts "{}"
            exit
          end
          puts JSON.generate(comment.call(payload.fetch("body")))
        when ["GET", "repos/#{canonical_repo}/issues/comments/9001"]
          exit 1 if ENV["FAKE_GH_MODE"] == "readback-failure"
          if ENV["FAKE_GH_MODE"] == "readback-invalid-json"
            puts "{"
            exit
          end
          if ENV["FAKE_GH_MODE"] == "readback-array"
            puts "[]"
            exit
          end
          puts JSON.generate(comment.call(File.read(ENV.fetch("FAKE_GH_BODY"))))
        else
          warn "unexpected fake gh call: #{method} #{endpoint} #{args.inspect}"
          exit 1
        end
      RUBY
      FileUtils.chmod(0o755, gh)
      agent_coord = File.join(bin, "agent-coord")
      File.write(agent_coord, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"

        expected = ["status", "--batch-id", ENV.fetch("FAKE_BATCH_ID"), "--json"]
        abort "unexpected agent-coord arguments: #{ARGV.inspect}" unless ARGV == expected
        File.open(ENV.fetch("FAKE_COORDINATION_LOG"), "a") { |file| file.puts(ARGV.join(" ")) }
        puts ENV.fetch("FAKE_COORDINATION_STATUS")
      RUBY
      FileUtils.chmod(0o755, agent_coord)
      preflight = publication_preflight(coordination_backend:)
      workflow_config = File.join(directory, "agent-workflow.yml")
      File.write(workflow_config, "coordination_backend: #{coordination_backend.inspect}\n")
      env = {
        "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
        "FAKE_GH_LOG" => File.join(directory, "gh.log"),
        "FAKE_GH_BODY" => File.join(directory, "comment-body.txt"),
        "FAKE_GH_PID" => File.join(directory, "gh.pid"),
        "FAKE_GH_LATE_SIDE_EFFECT" => File.join(directory, "gh-late-side-effect.txt"),
        "FAKE_GH_MODE" => mode.to_s,
        "FAKE_TARGET_TYPE" => target_type,
        "FAKE_BATCH_ID" => "batch-184",
        "FAKE_COORDINATION_LOG" => File.join(directory, "agent-coord.log"),
        "FAKE_COORDINATION_STATUS" => JSON.generate(preflight.dig("source_input", "coordination_status")),
        "FAKE_WORKFLOW_CONFIG" => workflow_config,
        "COMPLETED_BATCH_AUDIT_PUBLICATION_PREFLIGHT" => File.join(directory, "publication-preflight.json"),
        "COMPLETED_BATCH_AUDIT_GH_TIMEOUT_SECONDS" => mode == "post-timeout" ? "1" : nil
      }
      File.write(env.fetch("COMPLETED_BATCH_AUDIT_PUBLICATION_PREFLIGHT"), JSON.generate(preflight))
      yield env, directory
    end
  end
end
