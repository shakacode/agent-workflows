# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "../../bin/agent_doctor/process_runner"

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
        fork do
          Signal.trap("TERM", "IGNORE")
          Signal.trap("HUP", "IGNORE")
          STDOUT.sync = true
          STDERR.sync = true
          File.write(ARGV.fetch(0), Process.pid)
          STDOUT.puts("holding stdout")
          STDERR.puts("holding stderr")
          sleep 60
        end
        sleep 0.01 until File.exist?(ARGV.fetch(0))
        exit! 0
      RUBY
      descendant_pid = nil

      begin
        result = runner(timeout: 0.2).capture([RbConfig.ruby, "-e", script, pid_file])
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
