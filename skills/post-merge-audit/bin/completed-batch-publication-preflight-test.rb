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
          "state" => "closed"
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
      assert_nil reconciled_lane.fetch("target_state")
      assert_nil reconciled_lane.fetch("evidence")
    end
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
