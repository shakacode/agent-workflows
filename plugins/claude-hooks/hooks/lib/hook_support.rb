# frozen_string_literal: true

require "date"
require "json"
require "yaml"

# Shared plumbing for the Claude Code SessionEnd adapter in this directory.
module HookSupport
  # A hook payload is a small JSON object. Cap the read so a malformed or
  # hostile stream cannot make a hook hang or exhaust memory.
  MAX_PAYLOAD_BYTES = 1024 * 1024

  # A SessionEnd writer is expected to close stdin after one small JSON value.
  # Bound real IO reads so a held-open pipe cannot consume the host's 5s budget.
  PAYLOAD_READ_TIMEOUT_SECONDS = 0.5

  # Preserve enough stderr to retain a useful first-line diagnostic while
  # keeping hook memory fixed even when an emitter is noisy or continuous.
  MAX_CAPTURED_STDERR_BYTES = 4096

  SEAM_RELATIVE_PATH = ".agents/agent-workflow.yml"

  # Values that mean "this repository has no coordination backend".
  ABSENT_BACKENDS = ["", "n/a", "na", "none"].freeze

  DISABLE_ENV = "AGENT_WORKFLOWS_HOOKS"

  # A NUL byte cannot survive exec: passing one to Process.spawn raises
  # ArgumentError. JSON permits \u0000, so any string taken from a hook payload
  # can contain one, and every value that becomes an argv element or a chdir
  # target must be checked before it is used.
  NUL = 0.chr

  module_function

  # True when an operator has switched the adapter off.
  def disabled?(env = ENV)
    env[DISABLE_ENV].to_s.strip.downcase == "off"
  end

  # Parse the hook payload from stdin. Returns the payload Hash, :oversized when
  # the stream is larger than the read cap, :timed_out when real IO is not
  # closed before the read deadline, or nil when it is absent or unparseable.
  #
  # The distinct oversized result lets the adapter report why it skipped the
  # event without retaining an unbounded input in memory.
  def read_payload(input = $stdin)
    raw = input.is_a?(IO) ? read_io_payload(input) : input.read(MAX_PAYLOAD_BYTES + 1)
    return raw if %i[oversized timed_out].include?(raw)
    return :oversized if raw && raw.bytesize > MAX_PAYLOAD_BYTES

    payload = JSON.parse(decodable(raw))
    payload.is_a?(Hash) ? payload : nil
  rescue JSON::ParserError, EncodingError, IOError, SystemCallError
    nil
  end

  def read_io_payload(input)
    raw = +"".b
    deadline = monotonic_now + PAYLOAD_READ_TIMEOUT_SECONDS

    loop do
      remaining_time = deadline - monotonic_now
      return :timed_out unless remaining_time.positive?
      return :timed_out unless IO.select([input], nil, nil, remaining_time)

      chunk = input.read_nonblock(MAX_PAYLOAD_BYTES + 1 - raw.bytesize, exception: false)
      next if chunk == :wait_readable
      return raw if chunk.nil?

      raw << chunk
      return :oversized if raw.bytesize > MAX_PAYLOAD_BYTES
    end
  end

  # Best-effort UTF-8 view of arbitrary bytes for JSON parsing.
  def decodable(raw)
    text = raw.to_s
    text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
    text.valid_encoding? ? text : text.scrub("")
  end

  # Nearest `.agents/agent-workflow.yml` at or above `start_dir`.
  def seam_path(start_dir)
    directory = File.expand_path(start_dir.to_s)
    loop do
      candidate = File.join(directory, SEAM_RELATIVE_PATH)
      return candidate if File.file?(candidate)

      parent = File.dirname(directory)
      return nil if parent == directory

      directory = parent
    end
  end

  # The seam's declared coordination backend, or nil when there is no readable
  # seam. `n/a` and friends are returned as nil so callers skip silently.
  def coordination_backend(start_dir)
    path = seam_path(start_dir)
    return nil unless path

    seam = YAML.safe_load_file(path, permitted_classes: [Date, Time], aliases: false)
    return nil unless seam.is_a?(Hash)

    backend = seam["coordination_backend"].to_s.strip
    return nil if ABSENT_BACKENDS.include?(backend.downcase)

    backend
  rescue Psych::Exception, SystemCallError
    nil
  end

  # True when this single value can legally be passed to exec.
  def safe_argument?(value)
    value.is_a?(String) && !value.include?(NUL)
  end

  # Run `argv` with a finite deadline in its own process group, with no shell
  # evaluation of any argument. On expiry the whole group gets TERM, then KILL
  # after a finite grace period.
  #
  # Returns a hash with :ok (the command exited 0 within the deadline), :status,
  # :stdout, :stderr, and :failure -- nil, "spawn_error", "unsafe_argument", or
  # "timeout".
  def run_bounded(argv, timeout_seconds:, grace_seconds: 0.5, chdir: nil)
    return { ok: false, status: nil, stdout: "", stderr: "", failure: "spawn_error" } if argv.nil? || argv.empty?

    # Reject unspawnable values before Process.spawn can raise on them.
    unless argv.all? { |value| safe_argument?(value) } && (chdir.nil? || safe_argument?(chdir))
      return { ok: false, status: nil, stdout: "", stderr: "argument contains a NUL byte", failure: "unsafe_argument" }
    end

    err_reader, err_writer = IO.pipe
    captured_stderr = +"".b
    stderr_drainer = Thread.new do
      loop do
        chunk = err_reader.readpartial(16 * 1024)
        remaining = MAX_CAPTURED_STDERR_BYTES - captured_stderr.bytesize
        captured_stderr << chunk.byteslice(0, remaining) if remaining.positive?
      end
    rescue EOFError
      nil
    rescue IOError
      nil
    end

    options = { out: File::NULL, err: err_writer, pgroup: true }
    options[:chdir] = chdir if chdir
    begin
      # The [command, argv0] form guarantees exec without a shell even when the
      # command is a single element or contains shell metacharacters.
      pid = Process.spawn([argv.first, argv.first], *argv.drop(1), **options)
      err_writer.close
      status, timed_out = await(pid, timeout_seconds, grace_seconds)
      finish_stderr_capture(err_reader, err_writer, stderr_drainer)
      {
        ok: !timed_out && status&.success? || false,
        status: status,
        stdout: "",
        stderr: decodable(captured_stderr),
        failure: timed_out ? "timeout" : nil
      }
    rescue SystemCallError, ArgumentError => e
      { ok: false, status: nil, stdout: "", stderr: e.message, failure: "spawn_error" }
    ensure
      finish_stderr_capture(err_reader, err_writer, stderr_drainer)
    end
  end

  def finish_stderr_capture(reader, writer, drainer)
    writer.close unless writer.closed?
    return if drainer.join(0.25)

    reader.close unless reader.closed?
    drainer.join(0.25)
  rescue IOError
    nil
  ensure
    reader.close unless reader.closed?
  end

  def await(pid, timeout_seconds, grace_seconds)
    deadline = monotonic_now + timeout_seconds
    leader_status = nil
    loop do
      unless leader_status
        waited = Process.waitpid2(pid, Process::WNOHANG)
        leader_status = waited[1] if waited
      end

      # Reaping the leader is not enough: descendants inherit its process
      # group. A remaining member keeps the group id allocated, so it is safe
      # to continue checking that same group until it becomes quiescent.
      return [leader_status, false] if leader_status && !process_group_alive?(pid)
      break if monotonic_now >= deadline

      sleep 0.02
    end

    terminate_group(pid, grace_seconds)
    [leader_status, true]
  rescue Errno::ECHILD
    return [leader_status, false] unless process_group_alive?(pid)

    sleep 0.02 while monotonic_now < deadline && process_group_alive?(pid)
    return [leader_status, false] unless process_group_alive?(pid)

    terminate_group(pid, grace_seconds)
    [leader_status, true]
  end

  def terminate_group(pid, grace_seconds)
    signal_group(pid, "TERM")
    deadline = monotonic_now + grace_seconds
    while monotonic_now < deadline
      reap_leader(pid)
      return unless process_group_alive?(pid)

      sleep 0.02
    end

    if process_group_alive?(pid)
      signal_group(pid, "KILL")
      kill_deadline = monotonic_now + grace_seconds
      while monotonic_now < kill_deadline
        reap_leader(pid)
        return unless process_group_alive?(pid)

        sleep 0.02
      end
    end

    reap_leader(pid)
  end

  def reap_leader(pid)
    Process.waitpid2(pid, Process::WNOHANG)
  rescue Errno::ECHILD
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

  def signal_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
