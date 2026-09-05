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

class FailSecondAdmissionWriteStore < HeavyRootAdmission::Store
  attr_reader :failed_state

  private

  def write_state(state)
    @write_count = @write_count.to_i + 1
    if @write_count == 2
      @failed_state = Marshal.load(Marshal.dump(state))
      raise HeavyRootAdmission::Error, "simulated bound-state persistence failure"
    end

    super
  end
end

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

  def launch_arguments(state_dir, token:, owner: "maker", lane: "issue-604-maker", host: "M5", ceiling: 1,
                       scan_command: scanner_command(state_dir), command: [RbConfig.ruby, "-e", "exit 0"],
                       worktree: state_dir, log: File.join(state_dir, "#{token}.log"), **options)
    arguments = [
      "launch", "--state-dir", state_dir, "--host", host,
      "--owner", owner, "--lane", lane, "--worktree", worktree,
      "--command-class", options.fetch(:command_class, "validator"),
      "--launch-token", token, "--ceiling", ceiling.to_s,
      "--scan-command-json", scan_command,
      "--command-json", JSON.generate(command), "--log", log, "--json"
    ]
    arguments.concat(["--ttl", options.fetch(:ttl).to_s]) if options.key?(:ttl)
    arguments.concat(["--scan-timeout", options.fetch(:scan_timeout).to_s]) if options.key?(:scan_timeout)
    arguments
  end

  def run_launch(state_dir, **options)
    run_helper(*launch_arguments(state_dir, **options))
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
    true
  end

  def with_overridden_heavy_root_admission_methods(overrides)
    singleton = HeavyRootAdmission.singleton_class
    originals = {}
    overrides.each_key do |name|
      originals[name] = HeavyRootAdmission.method(name)
    end
    overrides.each do |name, replacement|
      singleton.define_method(name, &replacement.to_proc)
    end
    yield
  ensure
    originals&.each do |name, original|
      singleton.define_method(name, &original.to_proc)
    end
  end

  def test_two_launches_racing_for_one_slot_execute_exactly_one_command
    Dir.mktmpdir("heavy-root-admission-launch-race-test") do |state_dir|
      scanner = File.join(state_dir, "scan.rb")
      File.write(scanner, "require 'json'; puts JSON.generate(roots: [])\n")
      scan_command = JSON.generate([RbConfig.ruby, scanner])
      result_path = File.join(state_dir, "executed.txt")
      ready = Queue.new
      start = Queue.new

      attempts = %w[claimant-a claimant-b].map do |claimant|
        Thread.new do
          ready << true
          start.pop
          command = JSON.generate(
            [RbConfig.ruby, "-e", "File.open(ARGV.fetch(0), 'a') { |f| f.puts(ARGV.fetch(1)) }", result_path, claimant]
          )
          stdout, stderr, status = Open3.capture3(
            RbConfig.ruby,
            HELPER,
            "launch",
            "--state-dir", state_dir,
            "--host", "M5",
            "--owner", claimant,
            "--lane", "issue-604-#{claimant}",
            "--worktree", state_dir,
            "--command-class", "validator",
            "--launch-token", "launch-#{claimant}",
            "--ceiling", "1",
            "--scan-command-json", scan_command,
            "--command-json", command,
            "--log", File.join(state_dir, "#{claimant}.log"),
            "--json"
          )
          { claimant: claimant, stdout: stdout, stderr: stderr, status: status.exitstatus }
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      results = attempts.map(&:value)

      assert_equal [0, 3], results.map { |result| result.fetch(:status) }.sort,
                   "one helper-owned launch must win and one must be denied: #{results.inspect}"

      winner_result = results.find { |result| result.fetch(:status).zero? }
      loser_result = results.find { |result| result.fetch(:status) == 3 }
      winner = JSON.parse(winner_result.fetch(:stdout))
      loser = JSON.parse(loser_result.fetch(:stdout))

      assert_equal "launched", winner.fetch("decision")
      assert_equal "bound", winner.dig("reservation", "status")
      assert_equal "capacity-full", loser.fetch("reason")
      assert_equal(
        [winner.dig("reservation", "lane")],
        loser.fetch("current_owners").map { |row| row.fetch("lane") }
      )
      assert(
        wait_until do
          !HeavyRootAdmission.process_target_live?(winner.dig("reservation", "pid")) &&
            !HeavyRootAdmission.process_target_live?(-winner.dig("reservation", "pgid"))
        end,
        "the winning helper-owned command did not reach terminal"
      )
      sleep 0.05
      assert File.exist?(result_path), "the winning helper-owned command did not execute"
      assert_equal [winner_result.fetch(:claimant)], File.readlines(result_path, chomp: true)
    end
  end

  def test_bound_state_persistence_failure_aborts_the_gated_root_and_recovers_after_ttl
    Dir.mktmpdir("heavy-root-admission-persist-failure-test") do |state_dir|
      result_path = File.join(state_dir, "executed.txt")
      options = {
        state_dir: state_dir,
        host: "m5",
        owner: "maker",
        lane: "issue-604-maker",
        worktree: state_dir,
        command_class: "validator",
        launch_token: "failed-launch",
        ceiling: 1,
        ttl: 1,
        scan_timeout: 5,
        scan_command_json: scanner_command(state_dir),
        command: [RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'executed')", result_path],
        log: File.join(state_dir, "failed-launch.log")
      }
      failing_store = FailSecondAdmissionWriteStore.new(state_dir: state_dir, host: "m5")

      error = assert_raises(HeavyRootAdmission::Error) do
        HeavyRootAdmission.launch(options, store: failing_store)
      end
      assert_match(/simulated bound-state persistence failure/, error.message)

      attempted = failing_store.failed_state.fetch("reservations").fetch(0)
      pid = attempted.fetch("pid")
      pgid = attempted.fetch("pgid")
      refute HeavyRootAdmission.process_target_live?(pid), "the gated PID survived failed persistence"
      refute HeavyRootAdmission.process_target_live?(-pgid), "the gated process group survived failed persistence"
      refute File.exist?(result_path), "the command ran before its bound state was durable"
      refute File.exist?(options.fetch(:log)), "the gated child opened a writer before its bound state was durable"

      state_path = Dir[File.join(state_dir, "host-*.json")].fetch(0)
      persisted = JSON.parse(File.read(state_path, encoding: "UTF-8")).fetch("reservations").fetch(0)
      assert_equal "reserved", persisted.fetch("status")
      refute persisted.key?("pid")
      refute persisted.key?("pgid")

      recovery_store = HeavyRootAdmission::Store.new(
        state_dir: state_dir,
        host: "m5",
        clock: -> { Time.now.utc + 2 }
      )
      recovery = HeavyRootAdmission.launch(
        options.merge(launch_token: "recovery-launch", log: File.join(state_dir, "recovery.log")),
        store: recovery_store
      )
      assert_equal "launched", recovery.fetch("decision")
      assert_equal ["failed-launch"], recovery.fetch("recovered_prelaunch_tokens")
      assert wait_until { File.exist?(result_path) }, "fresh launch did not execute after bounded recovery"
      recovery_reservation = recovery.fetch("reservation")
      assert(
        wait_until do
          !HeavyRootAdmission.process_target_live?(recovery_reservation.fetch("pid")) &&
            !HeavyRootAdmission.process_target_live?(-recovery_reservation.fetch("pgid"))
        end,
        "recovery launch did not reach terminal"
      )
    end
  end

  def test_external_reserve_and_bind_commands_cannot_authorize_a_launch
    Dir.mktmpdir("heavy-root-admission-legacy-cli-test") do |state_dir|
      reserve = run_helper(
        "reserve", "--state-dir", state_dir, "--host", "M5",
        "--owner", "maker", "--lane", "issue-604-maker",
        "--worktree", state_dir, "--command-class", "validator",
        "--launch-token", "legacy-reserve", "--ceiling", "1",
        "--scan-command-json", scanner_command(state_dir), "--json"
      )
      bind = run_helper(
        "bind", "--state-dir", state_dir, "--host", "M5",
        "--launch-token", "legacy-reserve", "--pid", Process.pid.to_s,
        "--pgid", Process.getpgrp.to_s, "--json"
      )

      assert_equal 64, reserve.fetch(:status), reserve.inspect
      assert_equal 64, bind.fetch(:status), bind.inspect
      assert_match(/expected command: launch or release/i, reserve.fetch(:stderr))
      assert_match(/expected command: launch or release/i, bind.fetch(:stderr))
      assert_empty Dir[File.join(state_dir, "host-*.json")],
                   "legacy commands must not create pre-launch state"
    end
  end

  def test_lost_launch_receipt_requires_same_token_reconciliation
    Dir.mktmpdir("heavy-root-admission-lost-receipt-test") do |state_dir|
      token = "lost-receipt-launch"
      result_path = File.join(state_dir, "executed.txt")
      read_end, write_end = IO.pipe
      read_end.close
      error_path = File.join(state_dir, "helper.stderr")
      error_log = File.open(error_path, "w")
      helper_pid = Process.spawn(
        RbConfig.ruby,
        HELPER,
        *launch_arguments(
          state_dir,
          token: token,
          owner: "maker-#{'x' * 4096}",
          command: [RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'executed')", result_path]
        ),
        out: write_end,
        err: error_log
      )
      write_end.close
      error_log.close
      _waited_pid, _status = Process.wait2(helper_pid)

      assert wait_until { File.exist?(result_path) }, "the bound command did not execute before receipt loss"
      state_path = Dir[File.join(state_dir, "host-*.json")].fetch(0)
      reservation = JSON.parse(File.read(state_path, encoding: "UTF-8")).fetch("reservations").fetch(0)
      assert_equal "bound", reservation.fetch("status")
      assert_equal token, reservation.fetch("launch_token")

      capacity_workflow = File.read(CAPACITY_WORKFLOW, encoding: "UTF-8")
      assert_includes capacity_workflow, "A missing receipt or any nonzero `launch` outcome is `UNKNOWN`"
      assert_includes capacity_workflow, "reconcile the same launch token"
    ensure
      write_end&.close unless write_end&.closed?
      error_log&.close unless error_log&.closed?
    end
  end

  def test_bound_reservation_cannot_release_before_terminal_and_cleanup
    Dir.mktmpdir("heavy-root-admission-bind-test") do |state_dir|
      token = "launch-bound-root"
      scan_command = scanner_command(state_dir)
      launch = run_launch(
        state_dir,
        token: token,
        scan_command: scan_command,
        command: [RbConfig.ruby, "-e", "sleep 30"]
      )
      assert_equal 0, launch.fetch(:status), launch.inspect
      bound_reservation = JSON.parse(launch.fetch(:stdout)).fetch("reservation")
      pid = bound_reservation.fetch("pid")
      pgid = bound_reservation.fetch("pgid")

      begin
        assert_equal "bound", bound_reservation.fetch("status")
        refute_empty bound_reservation.fetch("pid_start_identity")

        launch_replay = run_launch(state_dir, token: token, scan_command: scan_command)
        assert_equal 3, launch_replay.fetch(:status), launch_replay.inspect
        replay_payload = JSON.parse(launch_replay.fetch(:stdout))
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
        HeavyRootAdmission.signal_process_group("TERM", pgid)
        wait_until do
          !HeavyRootAdmission.process_target_live?(pid) && !HeavyRootAdmission.process_target_live?(-pgid)
        end
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

      replacement = run_launch(
        state_dir,
        token: "launch-next",
        owner: "next-maker",
        lane: "issue-605-maker",
        scan_command: scan_command
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

  def test_zombie_bound_pid_does_not_keep_the_reservation_live_once_the_group_is_gone
    pid = 42_001
    pgid = 54_321
    expected_identity = "original process start"

    with_overridden_heavy_root_admission_methods(
      process_start_identity: ->(_target_pid) { expected_identity },
      process_zombie?: ->(_target_pid) { true },
      process_group_live?: ->(_pgid) { false }
    ) do
      refute HeavyRootAdmission.process_or_group_live?(pid, pgid, expected_identity)
    end
  end

  def test_zombie_bound_pid_still_waits_for_a_live_original_group
    pid = 42_001
    pgid = 54_321
    expected_identity = "original process start"

    with_overridden_heavy_root_admission_methods(
      process_start_identity: ->(_target_pid) { expected_identity },
      process_zombie?: ->(_target_pid) { true },
      process_group_live?: ->(_pgid) { true }
    ) do
      assert HeavyRootAdmission.process_or_group_live?(pid, pgid, expected_identity)
    end
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
      attempt = run_launch(
        state_dir,
        token: "launch-new",
        host: "M1",
        owner: "new-maker",
        lane: "issue-604-new-maker",
        ceiling: 2,
        scan_command: scan_command
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

    %w[bin/heavy-root-admission launch release --ceiling --scan-command-json --command-json --log
       --no-writer-cleanup].each do |term|
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
      first = run_launch(state_dir, token: "unique-launch", ceiling: 2, scan_command: scan_command)
      assert_equal 0, first.fetch(:status), first.inspect

      conflict = run_launch(
        state_dir,
        token: "unique-launch",
        owner: "other-maker",
        lane: "issue-999-other-maker",
        command_class: "review",
        ceiling: 2,
        scan_command: scan_command
      )

      assert_equal 1, conflict.fetch(:status), conflict.inspect
      assert_match(/launch token.*different (owner|lane|metadata)/i, conflict.fetch(:stderr))
    end
  end

  def test_bound_reservation_and_its_verified_live_root_count_as_one_occupant
    Dir.mktmpdir("heavy-root-admission-dedup-test") do |state_dir|
      empty_scan = scanner_command(state_dir)
      first = run_launch(
        state_dir,
        token: "launch-first",
        host: "M1",
        owner: "first-maker",
        lane: "pr-425-validator",
        ceiling: 2,
        scan_command: empty_scan,
        command: [RbConfig.ruby, "-e", "sleep 30"]
      )
      assert_equal 0, first.fetch(:status), first.inspect
      first_reservation = JSON.parse(first.fetch(:stdout)).fetch("reservation")
      live_groups = [first_reservation]

      begin
        live_scan = scanner_command(
          state_dir,
          roots: [
            {
              verified: true,
              owner: "first-maker",
              lane: "pr-425-validator",
              worktree: "/tmp/pr-425",
              command_class: "validator",
              pid: first_reservation.fetch("pid"),
              pgid: first_reservation.fetch("pgid")
            }
          ]
        )
        second = run_launch(
          state_dir,
          token: "launch-second",
          host: "M1",
          owner: "second-maker",
          lane: "pr-610-validator",
          ceiling: 2,
          scan_command: live_scan,
          command: [RbConfig.ruby, "-e", "sleep 30"]
        )
        assert_equal 0, second.fetch(:status), second.inspect
        live_groups << JSON.parse(second.fetch(:stdout)).fetch("reservation")

        third = run_launch(
          state_dir,
          token: "launch-third",
          host: "M1",
          owner: "third-maker",
          lane: "pr-999-review",
          command_class: "review",
          ceiling: 2,
          scan_command: live_scan
        )
        assert_equal 3, third.fetch(:status), third.inspect
        owners = JSON.parse(third.fetch(:stdout)).fetch("current_owners")
        assert_equal %w[pr-425-validator pr-610-validator], owners.map { |row| row.fetch("lane") }.sort
      ensure
        live_groups.each do |reservation|
          HeavyRootAdmission.signal_process_group("TERM", reservation.fetch("pgid"))
        end
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
      attempt = run_launch(
        state_dir,
        token: "launch-policy",
        host: "M1",
        ceiling: 2,
        scan_command: scan_command
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
      first = run_launch(
        state_dir,
        token: "launch-first",
        host: "M1",
        owner: "first-maker",
        lane: "pr-425-validator",
        scan_command: scan_command
      )
      second = run_launch(
        state_dir,
        token: "launch-second",
        host: "m1",
        owner: "second-maker",
        lane: "pr-610-validator",
        scan_command: scan_command
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
      attempt = run_launch(
        state_dir,
        token: "launch-with-descendant",
        scan_timeout: 1,
        scan_command: scan_command
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_equal 1, attempt.fetch(:status), attempt.inspect
      assert_operator elapsed, :<, 2.5, "scan timeout took #{elapsed.round(2)} seconds"
      assert_match(/whole-host scan exceeded 1s/i, attempt.fetch(:stderr))
      assert_empty Dir[File.join(state_dir, "host-*.json")]
    end
  end

  def test_malformed_scan_command_json_is_reported_as_usage_error
    Dir.mktmpdir("heavy-root-admission-scan-command-json-test") do |state_dir|
      attempt = run_launch(
        state_dir,
        token: "malformed-scan-command",
        scan_command: "[\"unterminated"
      )

      assert_equal 64, attempt.fetch(:status), attempt.inspect
      assert_match(/USAGE:.*--scan-command-json must be valid JSON/i, attempt.fetch(:stderr))
      refute_match(/whole-host scan did not return valid JSON/i, attempt.fetch(:stderr))
      assert_empty Dir[File.join(state_dir, "host-*.json")]
    end
  end

  def test_scan_requires_roots_field
    Dir.mktmpdir("heavy-root-admission-scan-roots-test") do |state_dir|
      scanner = File.join(state_dir, "scan-without-roots.rb")
      File.write(scanner, "require 'json'; puts JSON.generate({})\n")
      attempt = run_launch(
        state_dir,
        token: "missing-roots",
        scan_command: JSON.generate([RbConfig.ruby, scanner])
      )

      assert_equal 1, attempt.fetch(:status), attempt.inspect
      assert_match(/BLOCKED:.*scan JSON field `roots` must be an array/i, attempt.fetch(:stderr))
      refute_match(/KeyError|from .*heavy-root-admission/, attempt.fetch(:stderr))
      assert_empty Dir[File.join(state_dir, "host-*.json")]
    end
  end

  def test_scan_requires_worktree_and_command_class_provenance
    Dir.mktmpdir("heavy-root-admission-scan-provenance-test") do |state_dir|
      scan_command = scanner_command(
        state_dir,
        roots: [{ verified: true, owner: "maker", lane: "issue-604-maker", pid: Process.pid }]
      )
      attempt = run_launch(
        state_dir,
        token: "missing-provenance",
        owner: "other-maker",
        lane: "issue-604-other-maker",
        ceiling: 2,
        scan_command: scan_command
      )

      assert_equal 1, attempt.fetch(:status), attempt.inspect
      assert_match(/BLOCKED:.*needs owner, lane, worktree, command_class, and pid or pgid/i,
                   attempt.fetch(:stderr))
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

      attempt = run_launch(state_dir, token: "fresh-token")

      assert_equal 0, attempt.fetch(:status), attempt.inspect
      payload = JSON.parse(attempt.fetch(:stdout))
      assert_equal "launched", payload.fetch("decision")
      assert_equal 1, payload.fetch("occupied_after_launch")

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
      first = run_launch(
        state_dir,
        token: "single-use-token",
        owner: "first-maker",
        lane: "issue-604-first-maker",
        scan_command: scan_command
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

      reused = run_launch(
        state_dir,
        token: "single-use-token",
        owner: "other-maker",
        lane: "issue-999-other-maker",
        command_class: "review",
        scan_command: scan_command
      )

      assert_equal 3, reused.fetch(:status), reused.inspect
      payload = JSON.parse(reused.fetch(:stdout))
      assert_equal "previously-seen-launch-token", payload.fetch("reason")
      assert_match(/new launch token/i, payload.fetch("retry_when"))
    end
  end
end
