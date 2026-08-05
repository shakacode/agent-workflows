# frozen_string_literal: true

require "date"
require "json"
require "tempfile"
require "yaml"

# Shared plumbing for the Claude Code hook adapters in this directory.
#
# These adapters are delivery mechanisms only. Every rule they enforce is
# written down and independently testable in a host-neutral validator; a hook is
# never the only place a rule lives.
module HookSupport
  # A hook payload is a small JSON object. Cap the read so a malformed or
  # hostile stream cannot make a hook hang or exhaust memory.
  MAX_PAYLOAD_BYTES = 1024 * 1024

  SEAM_RELATIVE_PATH = ".agents/agent-workflow.yml"

  # Values that mean "this repository has no coordination backend".
  ABSENT_BACKENDS = ["", "n/a", "na", "none"].freeze

  DISABLE_ENV = "AGENT_WORKFLOWS_HOOKS"

  module_function

  # The agent-workflows checkout that contains these hooks. Hook scripts resolve
  # their validators through this so the adapter and the rule it enforces can
  # never drift apart across installs.
  def pack_root
    File.expand_path("../../../..", __dir__)
  end

  # True when an operator has switched the adapters off. The hook process
  # inherits the agent runner's environment, not the inspected command's inline
  # `VAR=value` prefix, so a model cannot reach this switch from a tool call.
  def disabled?(env = ENV)
    env[DISABLE_ENV].to_s.strip.downcase == "off"
  end

  # Parse the hook payload from stdin. Returns nil when the payload is absent or
  # unreadable; callers treat that as "this gate cannot tell whether it applies"
  # and fail open rather than blocking every command on a malformed stream.
  def read_payload(input = $stdin)
    raw = input.read(MAX_PAYLOAD_BYTES)
    payload = JSON.parse(raw.to_s)
    payload.is_a?(Hash) ? payload : nil
  rescue JSON::ParserError, IOError, SystemCallError
    nil
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

  # Run `argv` with a finite deadline in its own process group, with no shell
  # evaluation of any argument. On expiry the whole group gets TERM, then KILL
  # after a finite grace period.
  #
  # Returns a hash with :ok (the command exited 0 within the deadline), :status,
  # :stdout, :stderr, and :failure (nil, "spawn_error", or "timeout").
  def run_bounded(argv, timeout_seconds:, grace_seconds: 0.5, chdir: nil)
    return { ok: false, status: nil, stdout: "", stderr: "", failure: "spawn_error" } if argv.nil? || argv.empty?

    out_file = Tempfile.new("agent-workflows-hook-out")
    err_file = Tempfile.new("agent-workflows-hook-err")
    options = { out: out_file.path, err: err_file.path, pgroup: true }
    options[:chdir] = chdir if chdir
    begin
      # The [command, argv0] form guarantees exec without a shell even when the
      # command is a single element or contains shell metacharacters.
      pid = Process.spawn([argv.first, argv.first], *argv.drop(1), **options)
      status, timed_out = await(pid, timeout_seconds, grace_seconds)
      {
        ok: !timed_out && status&.success? || false,
        status: status,
        stdout: File.read(out_file.path),
        stderr: File.read(err_file.path),
        failure: timed_out ? "timeout" : nil
      }
    rescue SystemCallError => e
      { ok: false, status: nil, stdout: "", stderr: e.message, failure: "spawn_error" }
    ensure
      out_file.close!
      err_file.close!
    end
  end

  def await(pid, timeout_seconds, grace_seconds)
    deadline = monotonic_now + timeout_seconds
    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return [waited[1], false] if waited
      break if monotonic_now >= deadline

      sleep 0.02
    end

    terminate_group(pid, grace_seconds)
    [nil, true]
  rescue Errno::ECHILD
    [nil, false]
  end

  def terminate_group(pid, grace_seconds)
    signal_group(pid, "TERM")
    deadline = monotonic_now + grace_seconds
    while monotonic_now < deadline
      return if Process.waitpid2(pid, Process::WNOHANG)

      sleep 0.02
    end
    signal_group(pid, "KILL")
    Process.waitpid2(pid, Process::WNOHANG)
  rescue Errno::ECHILD
    nil
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
