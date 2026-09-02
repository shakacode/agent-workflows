# frozen_string_literal: true

require "tempfile"

module ManualTesting
  class BoundedCommand
    DEFAULT_TIMEOUT_SECONDS = 30.0
    DEFAULT_OUTPUT_LIMIT_BYTES = 64 * 1024
    POLL_SECONDS = 0.05
    TERM_GRACE_SECONDS = 1.0
    KILL_GRACE_SECONDS = 1.0

    Result = Data.define(:stdout, :stderr, :status, :timed_out, :output_too_large)

    def initialize(timeout: DEFAULT_TIMEOUT_SECONDS, output_limit: DEFAULT_OUTPUT_LIMIT_BYTES)
      @timeout = timeout
      @output_limit = output_limit
    end

    def capture(command, chdir: nil, env: {})
      stdout_file = Tempfile.new("manual-testing-command-stdout")
      stderr_file = Tempfile.new("manual-testing-command-stderr")
      environment = {
        "BASH_ENV" => nil,
        "ENV" => nil,
        "RUBYOPT" => nil,
        "RUBYLIB" => nil,
        "ZDOTDIR" => nil
      }.merge(env)
      spawn_options = {
        in: File::NULL,
        out: stdout_file.path,
        err: stderr_file.path,
        pgroup: true
      }
      spawn_options[:chdir] = chdir if chdir
      pid = Process.spawn(environment, *command, **spawn_options)
      deadline = monotonic_now + @timeout
      status = nil
      timed_out = false

      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        if waited
          status = waited[1]
          break
        end
        if monotonic_now >= deadline
          timed_out = true
          terminate_process_group(pid)
          break
        end
        sleep POLL_SECONDS
      end

      stdout_file.rewind
      stderr_file.rewind
      stdout = stdout_file.read(@output_limit + 1) || ""
      stderr = stderr_file.read(@output_limit + 1) || ""
      Result.new(
        stdout: stdout.byteslice(0, @output_limit),
        stderr: stderr.byteslice(0, @output_limit),
        status:,
        timed_out:,
        output_too_large: stdout.bytesize > @output_limit || stderr.bytesize > @output_limit
      )
    ensure
      stdout_file&.close!
      stderr_file&.close!
    end

    private

    def terminate_process_group(pid)
      signal_group(pid, "TERM")
      status = wait_for_group(pid, monotonic_now + TERM_GRACE_SECONDS)
      return status unless process_group_alive?(pid)

      signal_group(pid, "KILL")
      wait_for_group(pid, monotonic_now + KILL_GRACE_SECONDS)
    end

    def wait_for_group(pid, deadline)
      status = nil
      while monotonic_now < deadline
        unless status
          waited = Process.waitpid2(pid, Process::WNOHANG)
          status = waited[1] if waited
        end
        return status unless process_group_alive?(pid)

        sleep POLL_SECONDS
      end
      status
    rescue Errno::ECHILD
      status
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def signal_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
