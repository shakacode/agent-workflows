# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "../../bin/agent_doctor/process_runner"
require_relative "../../bin/agent_doctor/timeout_budget"

class AgentDoctorProcessRunnerTest < Minitest::Test
  def test_captures_bounded_stdout_stderr_and_exit
    result = runner.capture([RbConfig.ruby, "-e", 'STDOUT.write("ok"); STDERR.write("note"); exit 1'])

    assert_equal "ok", result[:stdout]
    assert_equal "note", result[:stderr]
    assert_equal 1, result[:exit]
    assert_nil result[:failure]
  end

  def test_capture_can_override_child_environment
    result = runner.capture(
      [RbConfig.ruby, "-e", 'STDOUT.write(ENV.fetch("AGENT_DOCTOR_RUNNER_TEST"))'],
      environment: { "AGENT_DOCTOR_RUNNER_TEST" => "isolated" }
    )

    assert_equal "isolated", result[:stdout]
    assert_equal 0, result[:exit]
  end

  def test_rejects_oversized_output
    result = runner(stdout_limit: 8).capture([RbConfig.ruby, "-e", 'STDOUT.write("x" * 9)'])

    assert_equal "output exceeded diagnostic size limit", result[:failure]
    assert_operator result[:stdout].bytesize, :<=, 8
  end

  def test_retries_one_transient_spawn_capacity_failure
    attempts = 0
    spawn = lambda do |*arguments|
      attempts += 1
      raise Errno::EPERM if attempts == 1

      Process.spawn(*arguments)
    end

    result = runner(spawn: spawn).capture([RbConfig.ruby, "-e", 'STDOUT.write("ok")'])

    assert_equal 2, attempts
    assert_equal "ok", result[:stdout]
    assert_equal 0, result[:exit]
    assert_nil result[:failure]
  end

  def test_persistent_spawn_capacity_failure_is_reported_after_one_retry
    attempts = 0
    spawn = lambda do |*_arguments|
      attempts += 1
      raise Errno::EPERM
    end

    result = runner(spawn: spawn).capture([RbConfig.ruby, "-e", "exit 0"])

    assert_equal 2, attempts
    assert_equal "unable to start diagnostic: Errno::EPERM", result[:failure]
    assert_nil result[:exit]
  end

  def test_spawn_retry_consumes_the_original_capture_deadline
    attempts = 0
    spawn = lambda do |*arguments|
      attempts += 1
      raise Errno::EPERM if attempts == 1

      Process.spawn(*arguments)
    end
    ticks = [0.0, 0.01, 0.05, 0.11]
    process_runner = runner(timeout: 0.1, spawn: spawn)
    process_runner.define_singleton_method(:monotonic) { ticks.shift || 0.11 }
    process_runner.define_singleton_method(:sleep) { |_seconds| nil }

    result = process_runner.capture([RbConfig.ruby, "-e", "exit 0"])

    assert_equal 2, attempts
    assert_equal "diagnostic timed out", result[:failure]
    assert_nil result[:exit]
  end

  def test_helper_completing_after_meaningful_share_of_workflow_budget_is_successful
    Dir.mktmpdir do |directory|
      gate_path = File.join(directory, "completion-gate")
      child_pid = nil
      spawn = lambda do |*arguments|
        child_pid = Process.spawn(*arguments)
      end
      ticks = [0.0, 1.0, 3.0, 5.0]
      current_tick = nil
      gate_released = false
      process_runner = runner(timeout: AgentDoctor::TimeoutBudget::WORKFLOW_STATUS_DEFAULT, spawn: spawn)

      begin
        File.open(gate_path, File::RDWR | File::CREAT, 0o600) do |gate|
          gate.flock(File::LOCK_EX)
          process_runner.define_singleton_method(:monotonic) do
            current_tick = ticks.shift || current_tick + 0.05
            if current_tick >= 5.0 && !gate_released
              gate.flock(File::LOCK_UN)
              gate_released = true
            end
            current_tick
          end
          script = 'File.open(ARGV.fetch(0)) { |gate| gate.flock(File::LOCK_SH) }; STDOUT.write("ok")'

          result = process_runner.capture([RbConfig.ruby, "-e", script, gate_path])

          assert_equal "ok", result[:stdout]
          assert_equal 0, result[:exit]
          assert_nil result[:failure]
        end
      ensure
        kill_and_reap(child_pid)
      end
    end
  end

  def test_timeout_terminates_descendant_process_group
    Dir.mktmpdir do |directory|
      pid_file = File.join(directory, "child")
      script = "child = fork { sleep 60 }; File.write(ARGV.fetch(0), child); sleep 60"
      result = runner(timeout: 0.2).capture([RbConfig.ruby, "-e", script, pid_file])
      child_pid = Integer(File.read(pid_file))

      assert_equal "diagnostic timed out", result[:failure]
      assert eventually_stopped?(child_pid), "descendant remained running"
    end
  end

  def test_timeout_kills_stubborn_pipe_holder_after_leader_is_reaped
    Dir.mktmpdir do |directory|
      pid_file = File.join(directory, "descendant")
      script = <<~'RUBY'
        descendant = fork do
          Signal.trap("TERM", "IGNORE")
          Signal.trap("HUP", "IGNORE")
          STDOUT.sync = true
          STDERR.sync = true
          STDOUT.puts("holding stdout")
          STDERR.puts("holding stderr")
          sleep 60
        end
        File.write(ARGV.fetch(0), descendant)
        exit! 0
      RUBY
      descendant_pid = nil

      begin
        result = runner(timeout: 1.0).capture([RbConfig.ruby, "-e", script, pid_file])
        descendant_pid = Integer(File.read(pid_file))

        assert_equal "diagnostic timed out", result[:failure]
        assert_equal 0, result[:exit], "leader was not reaped before timeout cleanup"
        assert eventually_stopped?(descendant_pid), "TERM-ignoring pipe holder remained running"
      ensure
        Process.kill("KILL", descendant_pid) if descendant_pid && process_running?(descendant_pid)
      end
    end
  end

  def test_timeout_stays_bounded_when_descendant_escapes_with_setsid
    Dir.mktmpdir do |directory|
      pid_file = File.join(directory, "setsid-descendant")
      script = <<~'RUBY'
        fork do
          Process.setsid
          Signal.trap("TERM", "IGNORE")
          File.write(ARGV.fetch(0), Process.pid)
          sleep 60
        end
        sleep 0.01 until File.exist?(ARGV.fetch(0))
        sleep 60
      RUBY
      escaped_pid = nil

      begin
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = runner(timeout: 0.2).capture([RbConfig.ruby, "-e", script, pid_file])
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        escaped_pid = Integer(File.read(pid_file))

        assert_equal "diagnostic timed out", result[:failure]
        assert_operator elapsed, :<, 2.0, "setsid descendant made diagnostic timeout unbounded"
      ensure
        Process.kill("KILL", escaped_pid) if escaped_pid && process_running?(escaped_pid)
      end
    end
  end

  def test_process_liveness_check_does_not_depend_on_ps_access
    Dir.mktmpdir do |directory|
      ps = File.join(directory, "ps")
      File.write(ps, "#!/bin/sh\necho 'ps: Operation not permitted' >&2\nexit 126\n")
      File.chmod(0o755, ps)
      original_path = ENV.fetch("PATH", nil)

      begin
        ENV["PATH"] = directory
        refute eventually_stopped?(Process.pid), "live process was mistaken for stopped when ps was restricted"
      ensure
        ENV["PATH"] = original_path
      end
    end
  end

  def test_linux_zombie_state_counts_as_stopped_even_while_pid_exists
    Dir.mktmpdir do |proc_root|
      pid_root = File.join(proc_root, Process.pid.to_s)
      FileUtils.mkdir_p(pid_root)
      File.write(File.join(pid_root, "stat"), "#{Process.pid} (worker with ) in name) Z 1 2 3\n")

      refute process_running?(Process.pid, proc_root: proc_root), "zombie state was mistaken for a running process"
    end
  end

  def test_missing_command_is_normalized
    result = runner.capture(["definitely-missing-agent-doctor-command"])

    assert_match(/unable to start diagnostic: Errno::ENOENT/, result[:failure])
  end

  private

  def runner(**options)
    AgentDoctor::ProcessRunner.new(**options)
  end

  def eventually_stopped?(pid)
    50.times do
      return true unless process_running?(pid)

      sleep 0.02
    end
    false
  end

  def kill_and_reap(pid)
    return unless pid

    begin
      return if Process.waitpid(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      return
    end

    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    Process.waitpid(pid)
  rescue Errno::ECHILD
    nil
  end

  def process_running?(pid, proc_root: "/proc")
    return false if linux_zombie_or_dead?(pid, proc_root)

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def linux_zombie_or_dead?(pid, proc_root)
    stat = File.read(File.join(proc_root, pid.to_s, "stat"))
    closing_parenthesis = stat.rindex(")")
    closing_parenthesis && %w[Z X].include?(stat[closing_parenthesis + 2])
  rescue SystemCallError
    false
  end
end
