# frozen_string_literal: true

require "digest"
require "open3"
require "pathname"
require "rbconfig"

module AutonomousMergeRuntimeTrust
  class ExecutableError < StandardError; end

  Result = Struct.new(:accepted, :provenance, :errors, :manifest, keyword_init: true)

  RUNTIME_SOURCES = {
    "helper" => {
      path: File.expand_path("../bin/autonomous-merge-eligibility", __dir__),
      tree_paths: %w[
        skills/pr-batch/bin/autonomous-merge-eligibility
        .agents/skills/pr-batch/bin/autonomous-merge-eligibility
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

  module_function

  def verify(repo_root:, base_sha:, claim:, calibration_path:, git_command: nil)
    sources = runtime_sources(calibration_path)
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
        git_command: git_command || trusted_git_executable
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
    raise ExecutableError, "#{label} ancestor is world-writable" if (stat.mode & 0o002).positive?
    return unless (stat.mode & 0o020).positive? && stat.uid != Process.euid

    raise ExecutableError, "#{label} ancestor is group-writable by a foreign owner"
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

  def verify_trusted_base(repo_root:, base_sha:, claim:, sources:, git_command:)
    errors = []
    manifest = {}
    sources.each do |role, source|
      runtime_bytes = File.binread(source.fetch(:path))
      matches = source.fetch(:tree_paths).filter_map do |tree_path|
        tree_bytes, status = Open3.capture2(
          git_command, "-C", repo_root, "show", "#{base_sha}:#{tree_path}",
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
