# frozen_string_literal: true

require "digest"
require "pathname"
require "rbconfig"

module AutonomousMergeRuntimeTrust
  class ExecutableError < StandardError; end

  # Raised when trusted-base runtime verification exhausts the single bounded
  # autonomous replay deadline, or leaves descendants in its owned process
  # group. Carries the exact cleanup state so callers never report an
  # unconfirmed process group as an ordinary timeout.
  class ReplayTimeout < StandardError
    attr_reader :cleanup_confirmed, :phase

    def initialize(message, cleanup_confirmed:, phase:)
      super(message)
      @cleanup_confirmed = cleanup_confirmed
      @phase = phase
    end
  end

  Result = Struct.new(:accepted, :provenance, :errors, :manifest, keyword_init: true)

  RUNTIME_SOURCES = {
    "helper" => {
      path: File.expand_path("../bin/autonomous-merge-eligibility", __dir__),
      tree_paths: %w[
        skills/pr-batch/bin/autonomous-merge-eligibility
        .agents/skills/pr-batch/bin/autonomous-merge-eligibility
      ]
    },
    "closeout-helper" => {
      path: File.expand_path("../bin/autonomous-merge-closeout", __dir__),
      tree_paths: %w[
        skills/pr-batch/bin/autonomous-merge-closeout
        .agents/skills/pr-batch/bin/autonomous-merge-closeout
      ]
    },
    "decision-library" => {
      path: File.expand_path("autonomous_merge_decision.rb", __dir__),
      tree_paths: %w[
        skills/pr-batch/lib/autonomous_merge_decision.rb
        .agents/skills/pr-batch/lib/autonomous_merge_decision.rb
      ]
    },
    "evidence-library" => {
      path: File.expand_path("autonomous_merge_evidence.rb", __dir__),
      tree_paths: %w[
        skills/pr-batch/lib/autonomous_merge_evidence.rb
        .agents/skills/pr-batch/lib/autonomous_merge_evidence.rb
      ]
    },
    "integration-evidence-library" => {
      path: File.expand_path("current_integration_evidence.rb", __dir__),
      tree_paths: %w[
        skills/pr-batch/lib/current_integration_evidence.rb
        .agents/skills/pr-batch/lib/current_integration_evidence.rb
      ]
    },
    "policy-library" => {
      path: File.expand_path("../../../bin/agent_doctor/autonomous_merge_policy.rb", __dir__),
      tree_paths: %w[
        bin/agent_doctor/autonomous_merge_policy.rb
        .agents/bin/agent_doctor/autonomous_merge_policy.rb
      ]
    },
    "policy-glob-library" => {
      path: File.expand_path("../../../bin/agent_doctor/autonomous_merge_policy_globs.rb", __dir__),
      tree_paths: %w[
        bin/agent_doctor/autonomous_merge_policy_globs.rb
        .agents/bin/agent_doctor/autonomous_merge_policy_globs.rb
      ]
    },
    "policy-yaml-library" => {
      path: File.expand_path("../../../bin/agent_doctor/autonomous_merge_policy_yaml.rb", __dir__),
      tree_paths: %w[
        bin/agent_doctor/autonomous_merge_policy_yaml.rb
        .agents/bin/agent_doctor/autonomous_merge_policy_yaml.rb
      ]
    },
    "runtime-trust-library" => {
      path: File.expand_path(__FILE__),
      tree_paths: %w[
        skills/pr-batch/lib/autonomous_merge_runtime_trust.rb
        .agents/skills/pr-batch/lib/autonomous_merge_runtime_trust.rb
      ]
    }
  }.freeze
  CALIBRATION_TREE_PATHS = %w[
    skills/pr-batch/fixtures/autonomous-merge-reviewed-heads-calibration.json
    .agents/skills/pr-batch/fixtures/autonomous-merge-reviewed-heads-calibration.json
  ].freeze
  DEFAULT_CALIBRATION_PATH = File.expand_path(
    "../fixtures/autonomous-merge-reviewed-heads-calibration.json",
    __dir__
  )
  TRUSTED_BASE_PHASE = "trusted-base-runtime-verification"
  TRUSTED_BASE_TIMEOUT_SECONDS = 120
  TRUSTED_BASE_POLL_SECONDS = 0.01
  TRUSTED_BASE_TERMINATION_GRACE_SECONDS = 0.25
  TRUSTED_BASE_CLEANUP_CONFIRMED = "confirmed-zero"
  TRUSTED_BASE_CLEANUP_UNKNOWN = "UNKNOWN"
  READ_CHUNK_BYTES = 65_536

  module_function

  def verify(
    repo_root:, base_sha:, claim:, calibration_path:, git_command: nil, trusted_sources: nil,
    deadline: nil, own_process_group: true
  )
    sources = trusted_runtime_sources(calibration_path)
    if trusted_sources && sources != trusted_sources
      return rejected(claim, ["prevalidated runtime source binding mismatch"])
    end

    unreadable = sources.filter_map do |role, source|
      "#{role} runtime source is unavailable" unless File.file?(source.fetch(:path))
    end
    return rejected(claim, unreadable) unless unreadable.empty?

    case claim
    when /\Atrusted-base:([0-9a-f]{40})\z/
      claimed_sha = Regexp.last_match(1)
      return rejected(claim, ["trusted helper claim does not match resolved base"]) unless claimed_sha == base_sha

      verify_trusted_base(
        repo_root:, base_sha:, claim:, sources:,
        git_command: git_command || trusted_git_executable,
        deadline:, own_process_group:
      )
    when /\Averified-installed-pack:([0-9a-f]{64})\z/
      expected = Regexp.last_match(1)
      actual = installed_pack_digest(sources)
      return rejected(claim, ["installed-pack runtime digest mismatch"]) unless expected == actual

      accepted(claim, sources.transform_values { |source| source.fetch(:path) })
    else
      rejected(claim, ["trusted helper provenance is missing or invalid"])
    end
  rescue SystemCallError, ExecutableError => e
    rejected(claim, ["runtime trust verification failed: #{e.message}"])
  end

  def trusted_runtime_sources(calibration_path)
    runtime_sources(calibration_path).each_with_object({}) do |(role, source), trusted|
      trusted[role] = source.merge(
        path: trusted_runtime_source_path(
          source.fetch(:path),
          "autonomous merge #{role}",
          executable: %w[helper closeout-helper].include?(role)
        )
      )
    end
  end

  def trusted_runtime_source_path(path, label, executable: false)
    resolved = File.realpath(path)
    stat = File.lstat(resolved)
    unless stat.file? && [0, Process.euid].include?(stat.uid) && (stat.mode & 0o022).zero?
      raise ExecutableError, "#{label} runtime source is not a trusted regular file"
    end
    if executable && (stat.mode & 0o111).zero?
      raise ExecutableError, "#{label} runtime source is not executable"
    end

    ancestor = File.dirname(resolved)
    loop do
      validate_trusted_executable_ancestor!(File.lstat(ancestor), label)
      break if ancestor == File.dirname(ancestor)

      ancestor = File.dirname(ancestor)
    end
    resolved
  rescue SystemCallError => e
    raise ExecutableError, "#{label} runtime source could not be safely resolved: #{e.message}"
  end

  def trusted_git_executable
    candidate = if ENV.key?("AUTONOMOUS_MERGE_GIT")
                  ENV.fetch("AUTONOMOUS_MERGE_GIT")
                else
                  git_name = "git#{RbConfig::CONFIG.fetch('EXEEXT')}"
                  candidates = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map do |directory|
                    File.join(directory, git_name)
                  end
                  candidates.find { |path| File.file?(path) && File.executable?(path) }
                end
    raise ExecutableError, "AUTONOMOUS_MERGE_GIT could not be found on PATH" if candidate.nil?

    trusted_executable_path(candidate, "AUTONOMOUS_MERGE_GIT")
  end

  def trusted_executable_path(path, label)
    unless path.is_a?(String) && !path.empty? && Pathname.new(path).absolute?
      raise ExecutableError, "#{label} must be an absolute path"
    end

    resolved = File.realpath(path)
    stat = File.lstat(resolved)
    validate_trusted_executable_target!(stat, label)

    ancestor = File.dirname(resolved)
    loop do
      validate_trusted_executable_ancestor!(File.lstat(ancestor), label)
      break if ancestor == File.dirname(ancestor)

      ancestor = File.dirname(ancestor)
    end

    resolved
  rescue SystemCallError => e
    raise ExecutableError, "#{label} could not be safely resolved: #{e.message}"
  end

  def validate_trusted_executable_target!(stat, label)
    unless stat.file? && (stat.mode & 0o111).positive?
      raise ExecutableError, "#{label} target must be a regular executable file"
    end
    unless [0, Process.euid].include?(stat.uid)
      raise ExecutableError, "#{label} target owner is not trusted"
    end
    return if (stat.mode & 0o022).zero?

    raise ExecutableError, "#{label} target is group- or world-writable"
  end

  def validate_trusted_executable_ancestor!(stat, label)
    unless stat.directory? && [0, Process.euid].include?(stat.uid)
      raise ExecutableError, "#{label} ancestor is not a trusted directory"
    end
    return if (stat.mode & 0o022).zero?

    raise ExecutableError, "#{label} ancestor is group- or world-writable"
  end

  def installed_pack_digest(sources)
    digest = Digest::SHA256.new
    sources.sort.each do |role, source|
      bytes = File.binread(source.fetch(:path))
      digest << [role.bytesize].pack("N") << role
      digest << [bytes.bytesize].pack("Q>") << bytes
    end
    digest.hexdigest
  end

  def runtime_sources(calibration_path)
    RUNTIME_SOURCES.merge(
      "calibration-decision" => {
        path: File.expand_path(calibration_path),
        tree_paths: CALIBRATION_TREE_PATHS
      }
    )
  end

  # Every trusted-base read runs inside the caller's single bounded replay
  # deadline and owns its own process group, so a lazy-fetch stall in a partial
  # clone can no longer escape the advertised replay lifecycle. Path, owner,
  # mode, provenance, and byte-identity authentication are unchanged.
  def verify_trusted_base(
    repo_root:, base_sha:, claim:, sources:, git_command:, deadline: nil, own_process_group: true
  )
    deadline ||= monotonic_time + TRUSTED_BASE_TIMEOUT_SECONDS
    errors = []
    manifest = {}
    sources.each do |role, source|
      runtime_bytes = File.binread(source.fetch(:path))
      matches = source.fetch(:tree_paths).filter_map do |tree_path|
        tree_bytes, readable = bounded_trusted_base_read(
          git_command, repo_root, base_sha, tree_path, deadline, own_process_group:
        )
        tree_path if readable && tree_bytes == runtime_bytes
      end
      if matches.empty?
        errors << "#{role} is not byte-identical to any required source in trusted base #{base_sha}"
      else
        manifest[role] = matches.first
      end
    end
    return rejected(claim, errors) unless errors.empty?

    accepted(claim, manifest)
  end

  # Reads one trusted-base blob through a bounded child inside the caller's
  # single replay deadline. The bytes stay in a private pipe, exactly as the
  # previous capture did, so byte-identity authentication never round-trips
  # through a shared temp dir.
  #
  # +own_process_group+ says whether this read is the outermost owner. The
  # coordinator owns its reads and gives each one its own group so every
  # descendant can be reaped. A caller that is already running inside an
  # outer-owned replay group must pass false: nesting a new group there would
  # hide the child from the outer group kill and strand it as an orphan.
  # Returns the exact bytes only when git exited successfully within the deadline.
  def bounded_trusted_base_read(git_command, repo_root, base_sha, tree_path, deadline,
                                own_process_group: true)
    reaped = false
    reader, writer = IO.pipe
    reader.binmode
    redirects = { out: writer, err: File::NULL }
    redirects[:pgroup] = true if own_process_group
    pid = Process.spawn(
      git_command, "-C", repo_root, "show", "#{base_sha}:#{tree_path}", **redirects
    )
    writer.close
    bytes = drain_trusted_base_pipe(reader, pid, deadline, own_process_group)
    status = await_trusted_base_read(pid, deadline, own_process_group)
    reaped = true
    return [nil, false] unless status.success?

    [bytes, true]
  rescue ReplayTimeout
    # Cleanup already ran and produced the evidence carried by this error, so
    # the ensure below must not tear the same group down a second time.
    reaped = true
    raise
  ensure
    writer.close unless writer.nil? || writer.closed?
    reader&.close
    # Any unexpected exit still terminates and reaps everything this read owns,
    # so no git child or descendant outlives the verification.
    terminate_trusted_base_read(pid, own_process_group) if pid && !reaped
  end

  def drain_trusted_base_pipe(reader, pid, deadline, own_process_group)
    bytes = +""
    bytes.force_encoding(Encoding::BINARY)
    loop do
      remaining = deadline - monotonic_time
      raise_trusted_base_timeout(pid, "deadline", own_process_group) if remaining <= 0
      next unless IO.select([reader], nil, nil, remaining)

      begin
        bytes << reader.read_nonblock(READ_CHUNK_BYTES)
      rescue IO::WaitReadable
        next
      rescue EOFError
        break
      end
    end
    bytes
  end

  def await_trusted_base_read(pid, deadline, own_process_group)
    status = nil
    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      if waited
        status = waited.last
        break
      end
      break if monotonic_time >= deadline

      sleep TRUSTED_BASE_POLL_SECONDS
    end
    raise_trusted_base_timeout(pid, "deadline", own_process_group) if status.nil?
    return status unless own_process_group

    group_deadline = monotonic_time + TRUSTED_BASE_TERMINATION_GRACE_SECONDS
    return status if wait_for_trusted_base_process_group_exit(pid, group_deadline)

    raise_trusted_base_timeout(pid, "descendants", own_process_group)
  rescue Errno::ECHILD
    raise_trusted_base_timeout(pid, "deadline", own_process_group)
  end

  def raise_trusted_base_timeout(pid, reason, own_process_group)
    confirmed = terminate_trusted_base_read(pid, own_process_group)
    state = confirmed ? TRUSTED_BASE_CLEANUP_CONFIRMED : TRUSTED_BASE_CLEANUP_UNKNOWN
    detail = if reason == "descendants"
               "trusted-base runtime verification left descendants in its owned process group"
             else
               "trusted-base runtime verification exceeded the bounded autonomous replay deadline"
             end
    raise ReplayTimeout.new(
      "#{detail} (process group cleanup: #{state})",
      cleanup_confirmed: confirmed,
      phase: TRUSTED_BASE_PHASE
    )
  end

  def terminate_trusted_base_read(pid, own_process_group)
    return terminate_trusted_base_process_group(pid) if own_process_group

    terminate_trusted_base_child(pid)
  end

  # Terminates and reaps the whole owned process group, escalating TERM to KILL.
  # Returns true only when the group is observed empty.
  def terminate_trusted_base_process_group(pid)
    signal_trusted_base_target("TERM", -pid)
    grace = monotonic_time + TRUSTED_BASE_TERMINATION_GRACE_SECONDS
    wait_for_trusted_base_child(pid, grace)
    return true if wait_for_trusted_base_process_group_exit(pid, grace)

    signal_trusted_base_target("KILL", -pid)
    grace = monotonic_time + TRUSTED_BASE_TERMINATION_GRACE_SECONDS
    wait_for_trusted_base_child(pid, grace)
    wait_for_trusted_base_process_group_exit(pid, grace)
  end

  # Cleanup for a read that deliberately stayed inside an outer-owned group:
  # signal only this child, never the shared group, and confirm it is reaped.
  # Its own descendants stay inside the outer group the caller already reaps.
  def terminate_trusted_base_child(pid)
    signal_trusted_base_target("TERM", pid)
    grace = monotonic_time + TRUSTED_BASE_TERMINATION_GRACE_SECONDS
    return true unless wait_for_trusted_base_child(pid, grace).nil?

    signal_trusted_base_target("KILL", pid)
    grace = monotonic_time + TRUSTED_BASE_TERMINATION_GRACE_SECONDS
    !wait_for_trusted_base_child(pid, grace).nil?
  end

  # Cleanup must never raise: a signal failure has to surface as UNKNOWN
  # cleanup evidence, not escape and get rewritten as a generic trust failure.
  def signal_trusted_base_target(signal, target)
    Process.kill(signal, target)
  rescue SystemCallError
    nil
  end

  def wait_for_trusted_base_child(pid, deadline)
    while monotonic_time < deadline
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return waited.last if waited

      sleep TRUSTED_BASE_POLL_SECONDS
    end
    nil
  rescue Errno::ECHILD
    nil
  end

  def trusted_base_process_group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue SystemCallError
    true
  end

  def wait_for_trusted_base_process_group_exit(pid, deadline)
    while monotonic_time < deadline
      return true unless trusted_base_process_group_alive?(pid)

      sleep TRUSTED_BASE_POLL_SECONDS
    end
    !trusted_base_process_group_alive?(pid)
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def accepted(provenance, manifest)
    Result.new(accepted: true, provenance:, errors: [], manifest:)
  end

  def rejected(provenance, errors)
    Result.new(
      accepted: false,
      provenance: provenance || "UNKNOWN",
      errors:,
      manifest: {}
    )
  end
end
