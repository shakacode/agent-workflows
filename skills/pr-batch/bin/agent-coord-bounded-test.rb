#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

SCRIPT = File.expand_path("agent-coord-bounded", __dir__)
load SCRIPT

class AgentCoordBoundedTest < Minitest::Test
  def test_exposes_runner_without_executing_cli_when_required
    code = "load #{SCRIPT.dump}; print AgentCoordBoundedRunner.name"
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", code)

    assert_predicate status, :success?
    assert_equal "AgentCoordBoundedRunner", stdout
    assert_empty stderr
  end

  def test_runner_times_out_only_after_injected_monotonic_clock_advances
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      child_pid_file = File.join(dir, "child.pid")

      with_fake_agent_coord(<<~RUBY, "AGENT_COORD_CHILD_PID" => child_pid_file) do |env|
        File.write(ENV.fetch("AGENT_COORD_CHILD_PID"), Process.pid.to_s)
        sleep 10
      RUBY
        clock = ManualClock.new
        polls_while_ready = 0
        readiness_deadline = monotonic_now + 5
        sleeper = lambda do |seconds|
          if clock.now.zero?
            unless File.size?(child_pid_file)
              raise "fake child did not become ready" if monotonic_now >= readiness_deadline

              sleep 0.01
              next
            end

            polls_while_ready += 1
            clock.advance(1) if polls_while_ready == 3
            next
          end

          sleep seconds
          clock.advance(seconds)
        end
        stdout = StringIO.new
        stderr = StringIO.new
        runner = AgentCoordBoundedRunner.new(clock: clock.method(:now), sleeper:, stdout:, stderr:)

        exit_code = runner.run(%w[agent-coord status], timeout: 1, env:)

        assert_equal 124, exit_code
        assert_equal 3, polls_while_ready
        assert_empty stdout.string
        assert_includes stderr.string, "agent-coord-bounded: timed out after 1s: agent-coord status"

        child_pid = File.read(child_pid_file).to_i
        assert wait_until(timeout: 5) { !process_alive?(child_pid) }, "fake agent-coord survived timeout cleanup"
      end
    end
  end

  def test_runner_cleans_up_process_group_and_preserves_original_readiness_failure
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      child_pid_file = File.join(dir, "child.pid")
      helper_pid_file = File.join(dir, "helper.pid")
      child_pid = nil
      helper_pid = nil

      process_env = {
        "AGENT_COORD_CHILD_PID" => child_pid_file,
        "AGENT_COORD_HELPER_PID" => helper_pid_file
      }
      with_fake_agent_coord(<<~RUBY, process_env) do |env|
        helper_code = "File.write(ENV.fetch('AGENT_COORD_HELPER_PID'), Process.pid.to_s); sleep 10"
        Process.spawn({ "AGENT_COORD_HELPER_PID" => ENV.fetch("AGENT_COORD_HELPER_PID") },
                      #{RbConfig.ruby.dump}, "-e", helper_code)
        File.write(ENV.fetch("AGENT_COORD_CHILD_PID"), Process.pid.to_s)
        sleep 10
      RUBY
        readiness_polls = 0
        injected_failure = false
        readiness_deadline = monotonic_now + 5
        sleeper = lambda do |_seconds|
          sleep 0.01
          unless File.size?(child_pid_file) && File.size?(helper_pid_file)
            raise "fake process group did not become ready" if monotonic_now >= readiness_deadline

            next
          end

          readiness_polls += 1
          if readiness_polls == 3
            injected_failure = true
            raise ReadinessTimeout, "fake readiness did not arrive"
          end
        end
        runner = AgentCoordBoundedRunner.new(
          clock: -> { 0.0 },
          sleeper:,
          stdout: StringIO.new,
          stderr: StringIO.new
        )
        original_emergency_cleanup = runner.method(:emergency_cleanup_process_group)
        runner.define_singleton_method(:emergency_cleanup_process_group) do |pid|
          original_emergency_cleanup.call(pid)
          raise Errno::EPERM, "injected cleanup failure"
        end

        original_waitpid = Process.method(:waitpid)
        original_waitpid2 = Process.method(:waitpid2)
        cleanup_polls = 0
        Process.define_singleton_method(:waitpid) do |pid, *arguments|
          if injected_failure && File.size?(child_pid_file) && pid == File.read(child_pid_file).to_i
            raise "emergency cleanup used blocking waitpid"
          end

          original_waitpid.call(pid, *arguments)
        end
        Process.define_singleton_method(:waitpid2) do |pid, flags = 0|
          if injected_failure && File.size?(child_pid_file) && pid == File.read(child_pid_file).to_i
            raise "emergency cleanup did not use WNOHANG" unless flags == Process::WNOHANG

            cleanup_polls += 1
            next nil if cleanup_polls <= 3
          end

          original_waitpid2.call(pid, flags)
        end

        begin
          error = assert_raises(ReadinessTimeout) do
            runner.run(%w[agent-coord status], timeout: 1.0, env:)
          end
          assert_equal "fake readiness did not arrive", error.message
        ensure
          Process.define_singleton_method(:waitpid, original_waitpid)
          Process.define_singleton_method(:waitpid2, original_waitpid2)
        end

        child_pid = File.read(child_pid_file).to_i
        helper_pid = File.read(helper_pid_file).to_i
        assert_operator cleanup_polls, :>, 3
        assert_operator cleanup_polls, :<=, 25
        assert_raises(Errno::ECHILD) { Process.waitpid(child_pid, Process::WNOHANG) }
        assert wait_until(timeout: 5) { !process_alive?(child_pid) },
               "fake agent-coord survived readiness failure"
        assert wait_until(timeout: 5) { !process_alive?(helper_pid) },
               "fake helper survived readiness failure"
      ensure
        Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
        Process.kill("KILL", helper_pid) if helper_pid && process_alive?(helper_pid)
      end
    end
  end

  def test_forwards_agent_coord_exit_status_stdout_and_stderr
    with_fake_agent_coord(<<~RUBY) do |env|
      $stderr.print "fake stderr"
      puts "fake stdout"
      exit 7
    RUBY
      stdout, stderr, status = run_script(env, "status", "--repo", "example/repo")

      assert_equal 7, status.exitstatus
      assert_equal "fake stdout\n", stdout
      assert_equal "fake stderr", stderr
    end
  end

  def test_times_out_and_reports_unknown_friendly_status
    with_fake_agent_coord(<<~RUBY) do |env|
      sleep 5
    RUBY
      stdout, stderr, status = run_script(env, "--timeout", "1", "doctor", "--json")

      assert_equal 124, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "agent-coord-bounded: timed out after 1.0s"
      assert_includes stderr, "agent-coord doctor --json"
    end
  end

  def test_runner_replays_partial_output_after_deterministic_timeout
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      ready_file = File.join(dir, "ready")

      with_fake_agent_coord(<<~RUBY, "AGENT_COORD_READY_FILE" => ready_file) do |env|
        puts "partial json output"
        $stderr.puts "partial stderr output"
        $stdout.flush
        $stderr.flush
        File.write(ENV.fetch("AGENT_COORD_READY_FILE"), Process.pid.to_s)
        sleep 10
      RUBY
        exit_code, stdout, stderr = run_runner_after_ready(env, ready_file, "doctor", "--json")

        assert_equal 124, exit_code
        assert_equal "partial json output\n", stdout
        assert_includes stderr, "partial stderr output"
        assert_includes stderr, "agent-coord-bounded: timed out after 1.0s"
        assert_includes stderr, "agent-coord doctor --json"
      end
    end
  end

  def test_requires_agent_coord_arguments
    stdout, stderr, status = run_script({}, "--timeout", "1")

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "Usage: agent-coord-bounded"
  end

  def test_rejects_non_finite_timeout
    stdout, stderr, status = run_script({}, "--timeout", "1e999", "status")

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "--timeout must be a positive finite number"
  end

  def test_rejects_zero_timeout
    stdout, stderr, status = run_script({}, "--timeout", "0", "status")

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "--timeout must be a positive finite number"
  end

  def test_rejects_negative_timeout
    stdout, stderr, status = run_script({}, "--timeout", "-1", "status")

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "--timeout must be a positive finite number"
  end

  def test_rejects_invalid_default_timeout_without_backtrace
    env = { "AGENT_COORD_BOUNDED_TIMEOUT_SECONDS" => "not-a-number" }
    stdout, stderr, status = run_script(env, "status")

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "AGENT_COORD_BOUNDED_TIMEOUT_SECONDS must be a positive finite number"
    refute_includes stderr, "\n\tfrom "
  end

  def test_timeout_option_overrides_invalid_default_timeout
    with_fake_agent_coord(<<~RUBY, "AGENT_COORD_BOUNDED_TIMEOUT_SECONDS" => "not-a-number") do |env|
      puts "ok"
    RUBY
      stdout, stderr, status = run_script(env, "--timeout", "20", "status")

      assert_predicate status, :success?
      assert_equal "ok\n", stdout
      assert_empty stderr
    end
  end

  def test_help_does_not_parse_invalid_default_timeout
    stdout, stderr, status = run_script({ "AGENT_COORD_BOUNDED_TIMEOUT_SECONDS" => "not-a-number" }, "--help")

    assert_predicate status, :success?
    assert_includes stdout, "Usage: agent-coord-bounded"
    assert_empty stderr
  end

  def test_reports_missing_agent_coord_without_backtrace
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      stdout, stderr, status = run_script({ "PATH" => dir }, "status", "--repo", "example/repo")

      assert_equal 127, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "agent-coord-bounded: unable to start"
      assert_includes stderr, "agent-coord status --repo example/repo"
      refute_includes stderr, "\n\tfrom "
    end
  end

  def test_terminates_agent_coord_process_group_when_interrupted
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      child_pid_file = File.join(dir, "child.pid")
      wrapper_stdout_file = File.join(dir, "wrapper.stdout")
      wrapper_stderr_file = File.join(dir, "wrapper.stderr")
      wrapper_pid = nil
      child_pid = nil

      with_fake_agent_coord(<<~RUBY, "AGENT_COORD_CHILD_PID" => child_pid_file) do |env|
        puts "interrupted stdout output"
        $stderr.puts "interrupted stderr output"
        $stdout.flush
        $stderr.flush
        File.write(ENV.fetch("AGENT_COORD_CHILD_PID"), Process.pid.to_s)
        sleep 10
      RUBY
        wrapper_pid = Process.spawn(env, RbConfig.ruby, SCRIPT, "--timeout", "20", "status",
                                    out: wrapper_stdout_file, err: wrapper_stderr_file)

        assert wait_until(timeout: 5) { File.size?(child_pid_file) }, "fake agent-coord did not start"

        child_pid = File.read(child_pid_file).to_i
        Process.kill("TERM", wrapper_pid)
        _, status = Process.waitpid2(wrapper_pid)

        assert_equal 143, status.exitstatus
        assert_equal "interrupted stdout output\n", File.read(wrapper_stdout_file)
        assert_includes File.read(wrapper_stderr_file), "interrupted stderr output"
        assert wait_until(timeout: 5) { !process_alive?(child_pid) }, "fake agent-coord survived wrapper termination"
      ensure
        Process.kill("KILL", wrapper_pid) if wrapper_pid && process_alive?(wrapper_pid)
        Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
      end
    end
  end

  def test_timeout_kills_remaining_process_group_helpers
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      helper_pid_file = File.join(dir, "helper.pid")
      helper_pid = nil

      with_fake_agent_coord(<<~RUBY, "AGENT_COORD_HELPER_PID" => helper_pid_file) do |env|
        helper_code = "trap('TERM') {}; File.write(ENV.fetch('AGENT_COORD_HELPER_PID'), Process.pid.to_s); sleep 10"
        helper_pid = Process.spawn({ "AGENT_COORD_HELPER_PID" => ENV.fetch("AGENT_COORD_HELPER_PID") },
                                   #{RbConfig.ruby.dump}, "-e", helper_code)
        Process.detach(helper_pid)
        sleep 10
      RUBY
        exit_code, stdout, stderr = run_runner_after_ready(env, helper_pid_file, "status")

        assert_equal 124, exit_code
        assert_empty stdout
        assert_includes stderr, "agent-coord-bounded: timed out after 1.0s"
        assert wait_until(timeout: 5) { File.size?(helper_pid_file) }, "fake helper did not start"

        helper_pid = File.read(helper_pid_file).to_i
        assert wait_until(timeout: 5) { !process_alive?(helper_pid) }, "helper survived process-group cleanup"
      ensure
        Process.kill("KILL", helper_pid) if helper_pid && process_alive?(helper_pid)
      end
    end
  end

  def test_timeout_replays_helper_output_before_killing_process_group
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      helper_pid_file = File.join(dir, "helper.pid")
      term_observed_file = File.join(dir, "term-observed")
      output_release_file = File.join(dir, "output-release")
      output_flushed_file = File.join(dir, "output-flushed")
      helper_pid = nil

      helper_env = {
        "AGENT_COORD_HELPER_PID" => helper_pid_file,
        "AGENT_COORD_TERM_OBSERVED" => term_observed_file,
        "AGENT_COORD_OUTPUT_RELEASE" => output_release_file,
        "AGENT_COORD_OUTPUT_FLUSHED" => output_flushed_file
      }
      with_fake_agent_coord(<<~RUBY, helper_env) do |env|
        helper_code = <<~'HELPER'
          trap("TERM") do
            File.write(ENV.fetch("AGENT_COORD_TERM_OBSERVED"), Process.pid.to_s)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
            until File.size?(ENV.fetch("AGENT_COORD_OUTPUT_RELEASE"))
              exit! 70 if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

              sleep 0.01
            end
            puts "helper stdout after TERM"
            $stderr.puts "helper stderr after TERM"
            $stdout.flush
            $stderr.flush
            File.write(ENV.fetch("AGENT_COORD_OUTPUT_FLUSHED"), Process.pid.to_s)
            exit! 0
          end
          File.write(ENV.fetch("AGENT_COORD_HELPER_PID"), Process.pid.to_s)
          sleep 10
        HELPER
        helper_env = {
          "AGENT_COORD_HELPER_PID" => ENV.fetch("AGENT_COORD_HELPER_PID"),
          "AGENT_COORD_TERM_OBSERVED" => ENV.fetch("AGENT_COORD_TERM_OBSERVED"),
          "AGENT_COORD_OUTPUT_RELEASE" => ENV.fetch("AGENT_COORD_OUTPUT_RELEASE"),
          "AGENT_COORD_OUTPUT_FLUSHED" => ENV.fetch("AGENT_COORD_OUTPUT_FLUSHED")
        }
        helper_pid = Process.spawn(helper_env, #{RbConfig.ruby.dump}, "-e", helper_code)
        Process.detach(helper_pid)
        sleep 10
      RUBY
        post_term_sync = lambda do
          raise ReadinessTimeout, "helper did not observe TERM" unless wait_until(timeout: 5) do
            File.size?(term_observed_file)
          end

          File.write(output_release_file, "release")
          raise ReadinessTimeout, "helper output did not flush after TERM" unless wait_until(timeout: 5) do
            File.size?(output_flushed_file)
          end
        end
        exit_code, stdout, stderr = run_runner_after_ready(
          env,
          helper_pid_file,
          "status",
          post_timeout: post_term_sync
        )

        assert_equal 124, exit_code
        assert_includes stdout, "helper stdout after TERM"
        assert_includes stderr, "helper stderr after TERM"
        assert_includes stderr, "agent-coord-bounded: timed out after 1.0s"
        assert wait_until(timeout: 5) { File.size?(helper_pid_file) }, "fake helper did not start"

        helper_pid = File.read(helper_pid_file).to_i
        assert wait_until(timeout: 5) { !process_alive?(helper_pid) }, "helper survived process-group cleanup"
      ensure
        Process.kill("KILL", helper_pid) if helper_pid && process_alive?(helper_pid)
      end
    end
  end

  def test_process_alive_treats_eperm_as_alive
    original_kill = Process.method(:kill)
    # This patches Process globally for the duration of the assertion; the
    # ensure block restores it so later tests do not inherit the EPERM stub.
    Process.define_singleton_method(:kill) { |*| raise Errno::EPERM }

    assert process_alive?(1234)
  ensure
    Process.define_singleton_method(:kill, original_kill) if original_kill
  end

  private

  class ManualClock
    attr_reader :first_advance, :now

    def initialize
      @now = 0.0
    end

    def advance(seconds)
      @first_advance ||= seconds
      @now += seconds
    end
  end

  class ReadinessTimeout < StandardError
  end

  def run_script(env, *)
    Open3.capture3(env, RbConfig.ruby, SCRIPT, *)
  end

  def run_runner_after_ready(env, ready_file, *command, post_timeout: nil)
    clock = ManualClock.new
    stdout = StringIO.new
    stderr = StringIO.new
    readiness_deadline = monotonic_now + 5
    advanced = false
    sleeper = lambda do |seconds|
      unless advanced
        raise "fake helper did not become ready" if monotonic_now >= readiness_deadline

        if File.size?(ready_file)
          clock.advance(1.0)
          advanced = true
        else
          sleep 0.01
        end
        next
      end

      if post_timeout
        synchronization = post_timeout
        post_timeout = nil
        synchronization.call
      end
      sleep seconds
      clock.advance(seconds)
    end
    runner = AgentCoordBoundedRunner.new(clock: clock.method(:now), sleeper:, stdout:, stderr:)
    exit_code = runner.run(["agent-coord", *command], timeout: 1.0, env:)

    assert advanced, "logical timeout did not advance after fake helper readiness"
    assert_equal 1.0, clock.first_advance

    [exit_code, stdout.string, stderr.string]
  end

  def with_fake_agent_coord(body, extra_env = {})
    Dir.mktmpdir("agent-coord-bounded-test") do |dir|
      fake_bin = File.join(dir, "agent-coord")
      File.write(fake_bin, <<~RUBY)
        #!/usr/bin/env ruby
        #{body}
      RUBY
      FileUtils.chmod(0o755, fake_bin)
      env = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}" }.merge(extra_env)

      yield env
    end
  end

  def wait_until(timeout: 2)
    deadline = monotonic_now + timeout
    until monotonic_now >= deadline
      return true if yield

      sleep 0.05
    end

    false
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    !zombie_process?(pid)
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def zombie_process?(pid)
    stdout, status = Open3.capture2("ps", "-o", "stat=", "-p", pid.to_s)
    return false unless status.success?

    stdout.split.any? { |state| state.start_with?("Z") }
  rescue StandardError
    false
  end
end
