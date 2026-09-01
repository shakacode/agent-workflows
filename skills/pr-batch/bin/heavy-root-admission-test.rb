#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

HELPER = File.expand_path("heavy-root-admission", __dir__)
ROOT = File.expand_path("../../..", __dir__)
CAPACITY_WORKFLOW = File.join(ROOT, "workflows/pr-batch-capacity-admission.md")

load HELPER

class HeavyRootAdmissionTest < Minitest::Test
  def run_helper(*arguments)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER, *arguments)
    { stdout: stdout, stderr: stderr, status: status.exitstatus }
  end

  def scanner_command(state_dir, roots: [], **policy)
    scanner = File.join(state_dir, "scan-#{Process.pid}-#{rand(1_000_000)}.rb")
    payload = { roots: roots }.merge(policy)
    File.write(scanner, "require 'json'; puts #{JSON.generate(JSON.generate(payload))}\n")
    JSON.generate([RbConfig.ruby, scanner])
  end

  def test_two_claimants_racing_for_one_slot_admit_exactly_one
    Dir.mktmpdir("heavy-root-admission-test") do |state_dir|
      scanner = File.join(state_dir, "scan.rb")
      File.write(scanner, "require 'json'; puts JSON.generate(roots: [])\n")
      scan_command = JSON.generate([RbConfig.ruby, scanner])
      ready = Queue.new
      start = Queue.new

      attempts = %w[claimant-a claimant-b].map do |claimant|
        Thread.new do
          ready << true
          start.pop
          stdout, stderr, status = Open3.capture3(
            RbConfig.ruby,
            HELPER,
            "reserve",
            "--state-dir", state_dir,
            "--host", "M5",
            "--owner", claimant,
            "--lane", "issue-604-#{claimant}",
            "--worktree", "/tmp/#{claimant}",
            "--command-class", "validator",
            "--launch-token", "launch-#{claimant}",
            "--ceiling", "1",
            "--ttl", "30",
            "--scan-command-json", scan_command,
            "--json"
          )
          { stdout: stdout, stderr: stderr, status: status.exitstatus }
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = attempts.map(&:value)

      assert_equal [0, 3], results.map { |result| result.fetch(:status) }.sort,
                   "one claimant must reserve the only slot and one must be denied: #{results.inspect}"

      winner = JSON.parse(results.find { |result| result.fetch(:status).zero? }.fetch(:stdout))
      loser = JSON.parse(results.find { |result| result.fetch(:status) == 3 }.fetch(:stdout))
      losing_owner_lanes = loser.fetch("current_owners").map { |row| row.fetch("lane") }

      assert_equal "reserved", winner.fetch("decision")
      assert_equal "capacity-full", loser.fetch("reason")
      assert_equal [winner.dig("reservation", "lane")], losing_owner_lanes
      assert_match(/reservation.*released/i, loser.fetch("retry_when"))
    end
  end

  def test_bound_reservation_cannot_release_before_terminal_and_cleanup
    Dir.mktmpdir("heavy-root-admission-bind-test") do |state_dir|
      token = "launch-bound-root"
      scan_command = scanner_command(state_dir)
      reserve = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "maker", "--lane", "issue-604-maker",
        "--worktree", "/tmp/maker", "--command-class", "validator",
        "--launch-token", token, "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )
      assert_equal 0, reserve.fetch(:status), reserve.inspect

      pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true)
      begin
        bind = run_helper(
          "bind", "--state-dir", state_dir, "--host", "M5",
          "--launch-token", token, "--pid", pid.to_s, "--pgid", pid.to_s, "--json"
        )
        assert_equal 0, bind.fetch(:status), bind.inspect
        bound_reservation = JSON.parse(bind.fetch(:stdout)).fetch("reservation")
        assert_equal "bound", bound_reservation.fetch("status")
        refute_empty bound_reservation.fetch("pid_start_identity")

        reserve_replay = run_helper(
          "reserve", "--state-dir", state_dir, "--host", "M5",
          "--owner", "maker", "--lane", "issue-604-maker",
          "--worktree", "/tmp/maker", "--command-class", "validator",
          "--launch-token", token, "--ceiling", "1",
          "--scan-command-json", scan_command, "--json"
        )
        assert_equal 3, reserve_replay.fetch(:status), reserve_replay.inspect
        replay_payload = JSON.parse(reserve_replay.fetch(:stdout))
        assert_equal "already-bound", replay_payload.fetch("reason")
        assert_equal pid, replay_payload.dig("reservation", "pid")
        assert_match(/do not relaunch/i, replay_payload.fetch("retry_when"))

        premature = run_helper(
          "release", "--state-dir", state_dir, "--host", "M5",
          "--launch-token", token, "--terminal-outcome", "exit 0",
          "--no-writer-cleanup", "--json"
        )
        assert_equal 1, premature.fetch(:status), premature.inspect
        assert_match(/still live/i, premature.fetch(:stderr))
      ensure
        Process.kill("TERM", pid)
        Process.wait(pid)
      end

      missing_cleanup = run_helper(
        "release", "--state-dir", state_dir, "--host", "M5",
        "--launch-token", token, "--terminal-outcome", "exit 0", "--json"
      )
      assert_equal 64, missing_cleanup.fetch(:status), missing_cleanup.inspect
      assert_match(/no-writer-cleanup/i, missing_cleanup.fetch(:stderr))

      release = run_helper(
        "release", "--state-dir", state_dir, "--host", "M5",
        "--launch-token", token, "--terminal-outcome", "exit 0",
        "--no-writer-cleanup", "--json"
      )
      assert_equal 0, release.fetch(:status), release.inspect
      assert_equal "released", JSON.parse(release.fetch(:stdout)).dig("reservation", "status")

      replacement = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "next-maker", "--lane", "issue-605-maker",
        "--worktree", "/tmp/next-maker", "--command-class", "validator",
        "--launch-token", "launch-next", "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )
      assert_equal 0, replacement.fetch(:status), replacement.inspect
    end
  end

  def test_pid_reuse_does_not_keep_an_old_bound_reservation_live
    assert HeavyRootAdmission.reused_process_identity?("original process start", "new process start")
  end

  def test_matching_bound_process_identity_remains_live
    refute HeavyRootAdmission.reused_process_identity?("original process start", "original process start")
  end

  def test_process_start_identity_is_stable_across_caller_locales
    original_lc_all = ENV.fetch("LC_ALL", nil)
    ENV["LC_ALL"] = "C"
    c_identity = HeavyRootAdmission.process_start_identity(Process.pid)
    ENV["LC_ALL"] = "definitely-not-an-installed-locale"
    other_identity = HeavyRootAdmission.process_start_identity(Process.pid)

    refute_empty c_identity
    assert_equal c_identity, other_identity
  ensure
    ENV["LC_ALL"] = original_lc_all
  end

  def test_reused_pid_still_preserves_a_live_original_process_group
    mismatched_identity = "not #{HeavyRootAdmission.process_start_identity(Process.pid)}"

    assert HeavyRootAdmission.process_or_group_live?(Process.pid, Process.getpgrp, mismatched_identity)
  end

  def test_reused_pid_without_a_live_original_process_group_can_release
    mismatched_identity = "not #{HeavyRootAdmission.process_start_identity(Process.pid)}"
    nonexistent_pgid = 2_000_000_000

    refute HeavyRootAdmission.process_or_group_live?(Process.pid, nonexistent_pgid, mismatched_identity)
  end

  def test_bound_root_dedup_requires_exact_pid_and_process_group
    reservation = { "status" => "bound", "pid" => 12_345, "pgid" => 12_345 }

    refute HeavyRootAdmission.root_matches_bound_reservation?(
      { "pid" => 12_345, "pgid" => 54_321 },
      reservation
    ), "a reused PID in a different group is a separate live root"
    refute HeavyRootAdmission.root_matches_bound_reservation?(
      { "pid" => 54_321, "pgid" => 12_345 },
      reservation
    ), "a matching group without the original PID is ambiguous"
    refute HeavyRootAdmission.root_matches_bound_reservation?(
      { "pid" => 12_345, "pgid" => nil },
      reservation
    ), "PID-only evidence cannot safely distinguish reuse"
    assert HeavyRootAdmission.root_matches_bound_reservation?(
      { "pid" => 12_345, "pgid" => 12_345 },
      reservation
    ), "the exact bound PID and PGID identify one scanned root"
  end

  def test_expired_prelaunch_token_is_recovered_but_cannot_be_reused
    Dir.mktmpdir("heavy-root-admission-expiry-test") do |state_dir|
      scan_command = scanner_command(state_dir)
      first = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "crashed-maker", "--lane", "issue-604-crashed-maker",
        "--worktree", "/tmp/crashed-maker", "--command-class", "validator",
        "--launch-token", "stale-launch", "--ceiling", "1", "--ttl", "1",
        "--scan-command-json", scan_command, "--json"
      )
      assert_equal 0, first.fetch(:status), first.inspect

      sleep 1.1

      reused = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "crashed-maker", "--lane", "issue-604-crashed-maker",
        "--worktree", "/tmp/crashed-maker", "--command-class", "validator",
        "--launch-token", "stale-launch", "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )
      assert_equal 3, reused.fetch(:status), reused.inspect
      reused_payload = JSON.parse(reused.fetch(:stdout))
      assert_equal "expired-launch-token", reused_payload.fetch("reason")
      assert_equal ["stale-launch"], reused_payload.fetch("recovered_prelaunch_tokens")
      assert_match(/new launch token/i, reused_payload.fetch("retry_when"))

      recovered = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "recovery-maker", "--lane", "issue-604-recovery-maker",
        "--worktree", "/tmp/recovery-maker", "--command-class", "validator",
        "--launch-token", "fresh-launch", "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )
      assert_equal 0, recovered.fetch(:status), recovered.inspect
    end
  end

  def test_unverified_live_root_blocks_admission_instead_of_being_treated_as_stale
    Dir.mktmpdir("heavy-root-admission-unverified-test") do |state_dir|
      scan_command = scanner_command(
        state_dir,
        roots: [
          {
            owner: "unknown-parent",
            lane: "pr-446-review",
            worktree: "/tmp/pr-446",
            command_class: "review",
            pid: 44_614,
            pgid: 44_614,
            verified: false
          }
        ]
      )
      attempt = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M1",
        "--owner", "new-maker", "--lane", "issue-604-new-maker",
        "--worktree", "/tmp/new-maker", "--command-class", "validator",
        "--launch-token", "launch-new", "--ceiling", "2",
        "--scan-command-json", scan_command, "--json"
      )

      assert_equal 1, attempt.fetch(:status), attempt.inspect
      assert_match(/must declare `verified`: true/i, attempt.fetch(:stderr))
      refute File.exist?(Dir[File.join(state_dir, "host-*.json")].first.to_s),
             "a failed verification must not create an admission reservation"
    end
  end

  def test_pr_batch_surfaces_route_heavy_roots_through_the_host_local_contract
    assert File.file?(CAPACITY_WORKFLOW), "missing canonical capacity-admission component"
    capacity_workflow = File.read(CAPACITY_WORKFLOW, encoding: "UTF-8")

    %w[bin/heavy-root-admission reserve bind release --ceiling --scan-command-json --no-writer-cleanup].each do |term|
      assert_includes capacity_workflow, term
    end
    assert_includes capacity_workflow, "ssh <m1-alias> 'zsh -lc"
    assert_includes capacity_workflow, "policy input"
    assert_includes capacity_workflow, "terminal/no-writer cleanup"
    assert_includes capacity_workflow, "output-pipe drain"
    assert_includes capacity_workflow, "Launch tokens are single-use"
    assert_includes capacity_workflow, "newest 128 records per host"
    assert_includes capacity_workflow, "replacement coordinator"
    assert_includes capacity_workflow, "PID reuse"

    {
      "skills/pr-batch/SKILL.md" => "workflows/pr-batch-capacity-admission.md",
      "workflows/pr-batch-worker-execution.md" => "pr-batch-capacity-admission.md",
      "workflows/pr-batch-integration-closeout.md" => "pr-batch-capacity-admission.md"
    }.each do |relative_path, route|
      surface = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")
      assert_includes surface, route, "#{relative_path} must route to the canonical component"
    end

    validate = File.read(File.join(ROOT, "bin/validate"), encoding: "UTF-8")
    assert_includes validate, "ruby skills/pr-batch/bin/heavy-root-admission-test.rb"
  end

  def test_launch_token_replay_rejects_different_lane_metadata
    Dir.mktmpdir("heavy-root-admission-token-test") do |state_dir|
      scan_command = scanner_command(state_dir)
      first = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "maker", "--lane", "issue-604-maker",
        "--worktree", "/tmp/maker", "--command-class", "validator",
        "--launch-token", "unique-launch", "--ceiling", "2",
        "--scan-command-json", scan_command, "--json"
      )
      assert_equal 0, first.fetch(:status), first.inspect

      conflict = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "other-maker", "--lane", "issue-999-other-maker",
        "--worktree", "/tmp/other-maker", "--command-class", "review",
        "--launch-token", "unique-launch", "--ceiling", "2",
        "--scan-command-json", scan_command, "--json"
      )

      assert_equal 1, conflict.fetch(:status), conflict.inspect
      assert_match(/launch token.*different (owner|lane|metadata)/i, conflict.fetch(:stderr))
    end
  end

  def test_bound_reservation_and_its_verified_live_root_count_as_one_occupant
    Dir.mktmpdir("heavy-root-admission-dedup-test") do |state_dir|
      empty_scan = scanner_command(state_dir)
      reserve = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M1",
        "--owner", "first-maker", "--lane", "pr-425-validator",
        "--worktree", "/tmp/pr-425", "--command-class", "validator",
        "--launch-token", "launch-first", "--ceiling", "2",
        "--scan-command-json", empty_scan, "--json"
      )
      assert_equal 0, reserve.fetch(:status), reserve.inspect

      pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true)
      begin
        bind = run_helper(
          "bind", "--state-dir", state_dir, "--host", "M1",
          "--launch-token", "launch-first", "--pid", pid.to_s, "--pgid", pid.to_s, "--json"
        )
        assert_equal 0, bind.fetch(:status), bind.inspect

        live_scan = scanner_command(
          state_dir,
          roots: [
            {
              verified: true,
              owner: "first-maker",
              lane: "pr-425-validator",
              worktree: "/tmp/pr-425",
              command_class: "validator",
              pid: pid,
              pgid: pid
            }
          ]
        )
        second = run_helper(
          "reserve", "--state-dir", state_dir, "--host", "M1",
          "--owner", "second-maker", "--lane", "pr-610-validator",
          "--worktree", "/tmp/pr-610", "--command-class", "validator",
          "--launch-token", "launch-second", "--ceiling", "2",
          "--scan-command-json", live_scan, "--json"
        )
        assert_equal 0, second.fetch(:status), second.inspect

        third = run_helper(
          "reserve", "--state-dir", state_dir, "--host", "M1",
          "--owner", "third-maker", "--lane", "pr-999-review",
          "--worktree", "/tmp/pr-999", "--command-class", "review",
          "--launch-token", "launch-third", "--ceiling", "2",
          "--scan-command-json", live_scan, "--json"
        )
        assert_equal 3, third.fetch(:status), third.inspect
        owners = JSON.parse(third.fetch(:stdout)).fetch("current_owners")
        assert_equal %w[pr-425-validator pr-610-validator], owners.map { |row| row.fetch("lane") }.sort
      ensure
        Process.kill("TERM", pid)
        Process.wait(pid)
      end
    end
  end

  def test_scanner_can_reduce_the_ceiling_from_live_load_and_memory_policy
    Dir.mktmpdir("heavy-root-admission-policy-test") do |state_dir|
      scan_command = scanner_command(
        state_dir,
        ceiling: 0,
        retry_when: "M1 load is normalized and memory pressure is healthy"
      )
      attempt = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M1",
        "--owner", "maker", "--lane", "issue-604-maker",
        "--worktree", "/tmp/maker", "--command-class", "validator",
        "--launch-token", "launch-policy", "--ceiling", "2",
        "--scan-command-json", scan_command, "--json"
      )

      assert_equal 3, attempt.fetch(:status), attempt.inspect
      payload = JSON.parse(attempt.fetch(:stdout))
      assert_equal 0, payload.fetch("ceiling")
      assert_equal "M1 load is normalized and memory pressure is healthy", payload.fetch("retry_when")
      assert_empty payload.fetch("current_owners")
    end
  end

  def test_host_alias_case_does_not_create_a_second_lock_domain
    Dir.mktmpdir("heavy-root-admission-host-test") do |state_dir|
      scan_command = scanner_command(state_dir)
      first = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M1",
        "--owner", "first-maker", "--lane", "pr-425-validator",
        "--worktree", "/tmp/first", "--command-class", "validator",
        "--launch-token", "launch-first", "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )
      second = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "m1",
        "--owner", "second-maker", "--lane", "pr-610-validator",
        "--worktree", "/tmp/second", "--command-class", "validator",
        "--launch-token", "launch-second", "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )

      assert_equal 0, first.fetch(:status), first.inspect
      assert_equal 3, second.fetch(:status), second.inspect
      owner_lanes = JSON.parse(second.fetch(:stdout)).fetch("current_owners").map { |row| row.fetch("lane") }
      assert_equal ["pr-425-validator"], owner_lanes
    end
  end

  def test_store_canonicalizes_host_before_selecting_the_lock_domain
    Dir.mktmpdir("heavy-root-admission-store-host-test") do |state_dir|
      first_store = HeavyRootAdmission::Store.new(state_dir: state_dir, host: " M1 ")
      first_store.locked_update do |state, _now|
        state.fetch("reservations") << { "launch_token" => "direct-store", "status" => "reserved" }
        { write: true, report: nil }
      end

      reservations = HeavyRootAdmission::Store.new(state_dir: state_dir, host: "m1").locked_update do |state, _now|
        { write: false, report: state.fetch("reservations") }
      end

      launch_tokens = reservations.map { |reservation| reservation.fetch("launch_token") }
      assert_equal ["direct-store"], launch_tokens
      assert_equal 1, Dir[File.join(state_dir, "host-*.json")].length
      assert_equal 1, Dir[File.join(state_dir, "host-*.lock")].length
    end
  end

  def test_scan_timeout_bounds_descendants_that_keep_output_pipes_open
    Dir.mktmpdir("heavy-root-admission-scan-descendant-test") do |state_dir|
      scanner = File.join(state_dir, "scan-with-descendant.rb")
      File.write(
        scanner,
        "require 'json'; fork { sleep 3 }; puts JSON.generate(roots: [])\n"
      )
      scan_command = JSON.generate([RbConfig.ruby, scanner])

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      attempt = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "maker", "--lane", "issue-604-maker",
        "--worktree", "/tmp/maker", "--command-class", "validator",
        "--launch-token", "launch-with-descendant", "--ceiling", "1",
        "--scan-timeout", "1", "--scan-command-json", scan_command, "--json"
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_equal 1, attempt.fetch(:status), attempt.inspect
      assert_operator elapsed, :<, 2.5, "scan timeout took #{elapsed.round(2)} seconds"
      assert_match(/whole-host scan exceeded 1s/i, attempt.fetch(:stderr))
      assert_empty Dir[File.join(state_dir, "host-*.json")]
    end
  end

  def test_terminal_reservations_are_pruned_by_age_and_count
    Dir.mktmpdir("heavy-root-admission-retention-test") do |state_dir|
      now = Time.utc(2026, 9, 1, 6, 0, 0)
      store = HeavyRootAdmission::Store.new(state_dir: state_dir, host: "M5", clock: -> { now })
      terminal_limit = HeavyRootAdmission::MAX_TERMINAL_RESERVATIONS
      retention_seconds = HeavyRootAdmission::TERMINAL_RETENTION_SECONDS

      store.locked_update do |state, _locked_at|
        state.fetch("reservations") << {
          "launch_token" => "active-token",
          "status" => "reserved",
          "expires_at" => HeavyRootAdmission.iso8601(now + 30)
        }
        state.fetch("reservations") << {
          "launch_token" => "too-old",
          "status" => "released",
          "released_at" => HeavyRootAdmission.iso8601(now - retention_seconds - 1)
        }
        (terminal_limit + 2).times do |index|
          status = index.even? ? "released" : "expired"
          state.fetch("reservations") << {
            "launch_token" => "recent-#{index}",
            "status" => status,
            "#{status}_at" => HeavyRootAdmission.iso8601(now - index)
          }
        end
        { write: true, report: nil }
      end

      retained = store.locked_update do |state, _locked_at|
        { write: false, report: state.fetch("reservations") }
      end
      persisted = HeavyRootAdmission::Store.new(state_dir: state_dir, host: "m5", clock: -> { now }).locked_update do |state, _locked_at|
        { write: false, report: state.fetch("reservations") }
      end
      terminal = retained.select { |reservation| %w[released expired].include?(reservation.fetch("status")) }

      assert_equal retained, persisted
      assert_equal terminal_limit, terminal.length
      assert_includes retained.map { |reservation| reservation.fetch("launch_token") }, "active-token"
      refute_includes terminal.map { |reservation| reservation.fetch("launch_token") }, "too-old"
      assert_equal((0...terminal_limit).map { |index| "recent-#{index}" }.sort,
                   terminal.map { |reservation| reservation.fetch("launch_token") }.sort)
    end
  end

  def test_malformed_terminal_timestamps_are_retained_without_blocking_admission
    Dir.mktmpdir("heavy-root-admission-malformed-terminal-test") do |state_dir|
      malformed_terminal = [
        { "launch_token" => "missing-released-at", "status" => "released" },
        { "launch_token" => "invalid-expired-at", "status" => "expired", "expired_at" => "not-a-time" }
      ]
      HeavyRootAdmission::Store.new(state_dir: state_dir, host: "M5").locked_update do |state, _now|
        state.fetch("reservations").concat(malformed_terminal)
        { write: true, report: nil }
      end

      attempt = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "maker", "--lane", "issue-604-maker",
        "--worktree", "/tmp/maker", "--command-class", "validator",
        "--launch-token", "fresh-token", "--ceiling", "1",
        "--scan-command-json", scanner_command(state_dir), "--json"
      )

      assert_equal 0, attempt.fetch(:status), attempt.inspect
      payload = JSON.parse(attempt.fetch(:stdout))
      assert_equal "reserved", payload.fetch("decision")
      assert_equal 1, payload.fetch("occupied_after_reservation")

      state_path = Dir[File.join(state_dir, "host-*.json")].fetch(0)
      persisted = JSON.parse(File.read(state_path, encoding: "UTF-8"))
      retained_terminal = persisted.fetch("reservations").select do |reservation|
        malformed_terminal.any? { |malformed| reservation["launch_token"] == malformed["launch_token"] }
      end
      assert_equal malformed_terminal, retained_terminal
    end
  end

  def test_a_launch_token_remains_single_use_after_its_terminal_record_is_pruned
    Dir.mktmpdir("heavy-root-admission-single-use-token-test") do |state_dir|
      scan_command = scanner_command(state_dir)
      first = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "first-maker", "--lane", "issue-604-first-maker",
        "--worktree", "/tmp/first-maker", "--command-class", "validator",
        "--launch-token", "single-use-token", "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )
      assert_equal 0, first.fetch(:status), first.inspect

      now = Time.utc(2026, 9, 1, 6, 0, 0)
      store = HeavyRootAdmission::Store.new(state_dir: state_dir, host: "M5", clock: -> { now })
      store.locked_update do |state, _locked_at|
        reservation = state.fetch("reservations").fetch(0)
        reservation["status"] = "released"
        reservation["released_at"] = HeavyRootAdmission.iso8601(
          now - HeavyRootAdmission::TERMINAL_RETENTION_SECONDS - 1
        )
        { write: true, report: nil }
      end
      retained = store.locked_update do |state, _locked_at|
        { write: false, report: state.fetch("reservations") }
      end
      assert_empty retained

      reused = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "other-maker", "--lane", "issue-999-other-maker",
        "--worktree", "/tmp/other-maker", "--command-class", "review",
        "--launch-token", "single-use-token", "--ceiling", "1",
        "--scan-command-json", scan_command, "--json"
      )

      assert_equal 3, reused.fetch(:status), reused.inspect
      payload = JSON.parse(reused.fetch(:stdout))
      assert_equal "previously-seen-launch-token", payload.fetch("reason")
      assert_match(/new launch token/i, payload.fetch("retry_when"))
    end
  end
end
