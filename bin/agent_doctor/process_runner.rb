# frozen_string_literal: true

module AgentDoctor
  class ProcessRunner
    DEFAULT_STDOUT_LIMIT = 1024 * 1024
    DEFAULT_STDERR_LIMIT = 64 * 1024

    def initialize(timeout: 10.0, stdout_limit: DEFAULT_STDOUT_LIMIT, stderr_limit: DEFAULT_STDERR_LIMIT)
      @timeout = timeout
      @stdout_limit = stdout_limit
      @stderr_limit = stderr_limit
    end

    def capture(command, timeout: @timeout, environment: nil)
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      spawn_arguments = [*command, { out: stdout_writer, err: stderr_writer, pgroup: true }]
      spawn_arguments.unshift(environment) if environment
      pid = Process.spawn(*spawn_arguments)
      stdout_writer.close
      stderr_writer.close
      stdout = +""
      stderr = +""
      streams = { stdout_reader => [stdout, @stdout_limit], stderr_reader => [stderr, @stderr_limit] }
      deadline = monotonic + timeout
      child_status = nil
      failure = nil

      until child_status && streams.empty?
        remaining = deadline - monotonic
        if remaining <= 0
          failure = "diagnostic timed out"
          terminate_group(pid)
          break
        end
        readable = IO.select(streams.keys, nil, nil, [remaining, 0.05].min)&.first
        Array(readable).each do |io|
          buffer, limit = streams.fetch(io)
          chunk = io.read_nonblock(16 * 1024)
          available = limit - buffer.bytesize
          buffer << chunk.byteslice(0, available) if available.positive?
          if chunk.bytesize > available
            failure = "output exceeded diagnostic size limit"
            terminate_group(pid)
            break
          end
        rescue IO::WaitReadable
          next
        rescue EOFError
          streams.delete(io)
          io.close
        end
        break if failure

        child_status ||= Process.waitpid2(pid, Process::WNOHANG)&.last
      end

      { stdout: stdout, stderr: stderr, exit: child_status&.exitstatus, failure: failure }
    rescue SystemCallError => e
      { stdout: "", stderr: "", exit: nil, failure: "unable to start diagnostic: #{e.class}" }
    ensure
      [stdout_reader, stdout_writer, stderr_reader, stderr_writer].compact.each do |io|
        io.close unless io.closed?
      end
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def terminate_group(pid)
      signal_group("TERM", pid)
      deadline = monotonic + 0.5
      while process_group_alive?(pid) && monotonic < deadline
        reap_leader(pid, Process::WNOHANG)
        sleep 0.02
      end
      signal_group("KILL", pid) if process_group_alive?(pid)
      reap_leader(pid, 0)
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def reap_leader(pid, flags)
      Process.waitpid2(pid, flags)
    rescue Errno::ECHILD
      nil
    end
  end
end
