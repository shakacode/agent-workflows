# frozen_string_literal: true

require "digest"
require "fiddle/import"
require "open3"

module AutonomousMergeRuntimeTrust
  module RuntimeSourceSyscalls
    extend Fiddle::Importer
    dlload Fiddle.dlopen(nil)
    extern "int openat(int, const char *, int, unsigned int)"
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
    "../fixtures/autonomous-merge-reviewed-heads-calibration.json", __dir__
  )
  ACCEPTED_CLAIM_FORMS = "trusted-base:<40-hex-sha> or verified-installed-pack:<64-hex-digest>"

  module_function

  def verify(repo_root:, base_sha:, claim:, calibration_path:)
    sources = runtime_sources(calibration_path)
    unreadable = sources.filter_map do |role, source|
      "#{role} runtime source is unavailable" unless secure_runtime_source?(source.fetch(:path))
    end
    return rejected(claim, unreadable) unless unreadable.empty?

    case claim
    when /\Atrusted-base:([0-9a-f]{40})\z/
      claimed_sha = Regexp.last_match(1)
      return rejected(claim, ["trusted helper claim does not match resolved base"]) unless claimed_sha == base_sha

      verify_trusted_base(repo_root:, base_sha:, claim:, sources:)
    when /\Averified-installed-pack:([0-9a-f]{64})\z/
      expected = Regexp.last_match(1)
      actual = installed_pack_digest(sources)
      return rejected(claim, ["installed-pack runtime digest mismatch"]) unless expected == actual

      accepted(claim, sources.transform_values { |source| source.fetch(:path) })
    else
      rejected(claim, [unestablished_claim_failure(claim)])
    end
  rescue SystemCallError, RuntimeError => e
    rejected(claim, ["runtime trust verification failed: #{e.message}"])
  end

  def default_installed_pack_digest
    installed_pack_digest(runtime_sources(DEFAULT_CALIBRATION_PATH))
  end

  def unestablished_claim_failure(claim)
    if claim.nil? || claim.to_s.empty?
      "trusted helper provenance was not supplied; pass #{ACCEPTED_CLAIM_FORMS} " \
        "established independently of the evaluated repository"
    else
      "trusted helper provenance claim is not a recognized form; expected #{ACCEPTED_CLAIM_FORMS}"
    end
  end

  def installed_pack_digest(sources)
    runtime_library = sources.fetch("runtime-trust-library").fetch(:path)
    raw_pack_root = File.expand_path("../../..", File.dirname(runtime_library))
    pack_root = File.realpath(raw_pack_root)
    digest = Digest::SHA256.new
    sources.sort.each do |role, source|
      path = source.fetch(:path)
      expanded = File.expand_path(path)
      canonical_prefix = "#{pack_root}#{File::SEPARATOR}"
      raw_prefix = "#{raw_pack_root}#{File::SEPARATOR}"
      if expanded.start_with?(canonical_prefix)
        bound_path = expanded
        source_pack_root = pack_root
      elsif expanded.start_with?(raw_prefix)
        bound_path = File.join(pack_root, expanded.delete_prefix(raw_prefix))
        source_pack_root = pack_root
      else
        bound_path = expanded
        source_pack_root = nil
      end
      bytes = secure_runtime_source_bytes(bound_path, pack_root: source_pack_root)
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

  def verify_trusted_base(repo_root:, base_sha:, claim:, sources:)
    errors = []
    manifest = {}
    sources.each do |role, source|
      runtime_bytes = secure_runtime_source_bytes(source.fetch(:path))
      matches = source.fetch(:tree_paths).filter_map do |tree_path|
        tree_bytes, status = Open3.capture2(
          "git", "-C", repo_root, "show", "#{base_sha}:#{tree_path}",
          binmode: true
        )
        tree_path if status.success? && tree_bytes == runtime_bytes
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

  def secure_runtime_source?(path)
    secure_runtime_source_bytes(path)
    true
  rescue SystemCallError, RuntimeError
    false
  end

  def secure_runtime_source_bytes(path, pack_root: nil)
    raise "platform cannot refuse runtime-source symlinks" unless File.const_defined?(:NOFOLLOW)

    return secure_runtime_source_bytes_beneath(path, pack_root) if pack_root

    file = nil
    begin
      named = File.lstat(path)
      raise "runtime source is not a regular file" unless named.file? && !named.symlink?

      file = File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW)
      opened = file.stat
      unless opened.file? && opened.nlink == 1 && opened.dev == named.dev && opened.ino == named.ino
        raise "runtime source identity changed while opening"
      end

      file.binmode
      bytes = file.read
      file.rewind
      current = File.lstat(path)
      unless current.file? && !current.symlink? && current.nlink == 1 &&
             current.dev == opened.dev && current.ino == opened.ino && file.read == bytes
        raise "runtime source changed while being read"
      end

      bytes
    ensure
      file&.close
    end
  end

  def secure_runtime_source_bytes_beneath(path, pack_root)
    root = File.expand_path(pack_root)
    expanded = File.expand_path(path)
    prefix = "#{root}#{File::SEPARATOR}"
    raise "runtime source escapes the installed pack" unless expanded.start_with?(prefix)

    handles = []
    begin
      root_named = File.lstat(root)
      root_handle = File.open(root, File::RDONLY | File::NONBLOCK | File::NOFOLLOW)
      handles << root_handle
      root_opened = root_handle.stat
      unless root_named.directory? && !root_named.symlink? && root_opened.directory? &&
             root_named.dev == root_opened.dev && root_named.ino == root_opened.ino
        raise "installed pack root is redirected"
      end

      parts = expanded.delete_prefix(prefix).split(File::SEPARATOR)
      parts[0...-1].each do |part|
        directory = open_runtime_source_at(handles.last, part)
        handles << directory
        raise "runtime source ancestor is redirected" unless directory.stat.directory?
      end

      file = open_runtime_source_at(handles.last, parts.last)
      handles << file
      opened = file.stat
      raise "runtime source is not a single-link regular file" unless opened.file? && opened.nlink == 1

      file.binmode
      bytes = file.read
      file.rewind
      named = File.lstat(expanded)
      unless named.file? && !named.symlink? && named.nlink == 1 &&
             named.dev == opened.dev && named.ino == opened.ino && file.read == bytes
        raise "runtime source changed while being read"
      end

      bytes
    ensure
      handles.reverse_each(&:close)
    end
  end

  def open_runtime_source_at(directory, name)
    flags = File::RDONLY | File::NONBLOCK | File::NOFOLLOW
    fd = RuntimeSourceSyscalls.openat(directory.fileno, name, flags, 0)
    if fd == -1
      raise SystemCallError.new("openat runtime source #{name}", Fiddle.last_error)
    end

    File.for_fd(fd, "r", autoclose: true)
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
