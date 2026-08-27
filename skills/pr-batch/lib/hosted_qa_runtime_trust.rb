# frozen_string_literal: true

require "digest"

module HostedQaRuntimeTrust
  Result = Struct.new(:accepted, :provenance, :errors, :manifest, keyword_init: true)

  RUNTIME_SOURCES = {
    "helper" => {
      path: File.expand_path("../bin/hosted-qa-readiness", __dir__),
      tree_paths: %w[
        skills/pr-batch/bin/hosted-qa-readiness
        .agents/skills/pr-batch/bin/hosted-qa-readiness
      ]
    },
    "runtime-trust-library" => {
      path: File.expand_path(__FILE__),
      tree_paths: %w[
        skills/pr-batch/lib/hosted_qa_runtime_trust.rb
        .agents/skills/pr-batch/lib/hosted_qa_runtime_trust.rb
      ]
    },
    "hosted-policy-library" => {
      path: File.expand_path("../../../bin/agent_doctor/hosted_qa_policy.rb", __dir__),
      tree_paths: %w[
        bin/agent_doctor/hosted_qa_policy.rb
        .agents/bin/agent_doctor/hosted_qa_policy.rb
      ]
    },
    "autonomous-policy-library" => {
      path: File.expand_path("../../../bin/agent_doctor/autonomous_merge_policy.rb", __dir__),
      tree_paths: %w[
        bin/agent_doctor/autonomous_merge_policy.rb
        .agents/bin/agent_doctor/autonomous_merge_policy.rb
      ]
    },
    "autonomous-policy-glob-library" => {
      path: File.expand_path("../../../bin/agent_doctor/autonomous_merge_policy_globs.rb", __dir__),
      tree_paths: %w[
        bin/agent_doctor/autonomous_merge_policy_globs.rb
        .agents/bin/agent_doctor/autonomous_merge_policy_globs.rb
      ]
    },
    "autonomous-policy-yaml-library" => {
      path: File.expand_path("../../../bin/agent_doctor/autonomous_merge_policy_yaml.rb", __dir__),
      tree_paths: %w[
        bin/agent_doctor/autonomous_merge_policy_yaml.rb
        .agents/bin/agent_doctor/autonomous_merge_policy_yaml.rb
      ]
    },
    "closeout-replay-helper" => {
      path: File.expand_path("../../post-merge-audit/bin/closeout-evidence-replay", __dir__),
      tree_paths: %w[
        skills/post-merge-audit/bin/closeout-evidence-replay
        .agents/skills/post-merge-audit/bin/closeout-evidence-replay
      ]
    },
    "completed-publication-preflight-helper" => {
      path: File.expand_path("../../post-merge-audit/bin/completed-batch-publication-preflight", __dir__),
      tree_paths: %w[
        skills/post-merge-audit/bin/completed-batch-publication-preflight
        .agents/skills/post-merge-audit/bin/completed-batch-publication-preflight
      ]
    }
  }.freeze

  module_function

  def verify(repo_root:, base_sha:, claim:, git_capture:)
    errors = runtime_source_errors(repo_root)
    return rejected(claim, errors) unless errors.empty?

    case claim
    when /\Atrusted-base:([0-9a-f]{40})\z/
      claimed_sha = Regexp.last_match(1)
      return rejected(claim, ["trusted helper claim does not match resolved base"]) unless claimed_sha == base_sha

      verify_trusted_base(repo_root:, base_sha:, claim:, git_capture:)
    when /\Averified-installed-pack:([0-9a-f]{64})\z/
      expected = Regexp.last_match(1)
      actual = installed_pack_digest
      return rejected(claim, ["installed-pack runtime digest mismatch"]) unless expected == actual

      accepted(claim, RUNTIME_SOURCES.transform_values { |source| source.fetch(:path) })
    else
      rejected(claim, ["trusted hosted QA helper provenance is missing or invalid"])
    end
  rescue SystemCallError => e
    rejected(claim, ["hosted QA runtime trust verification failed: #{e.message}"])
  end

  def installed_pack_digest
    digest = Digest::SHA256.new
    RUNTIME_SOURCES.sort.each do |role, source|
      bytes = File.binread(source.fetch(:path))
      digest << [role.bytesize].pack("N") << role
      digest << [bytes.bytesize].pack("Q>") << bytes
    end
    digest.hexdigest
  end

  def runtime_source_errors(repo_root)
    RUNTIME_SOURCES.filter_map do |role, source|
      path = source.fetch(:path)
      if !File.file?(path)
        "#{role} runtime source is unavailable"
      elsif path_within_repository?(repo_root, path)
        "#{role} runtime source must be outside the evaluated repository"
      end
    end
  end

  def path_within_repository?(repo_root, path)
    repository_paths = [File.expand_path(repo_root), File.realpath(repo_root)].uniq
    source_paths = [File.expand_path(path), File.realpath(path)].uniq
    source_paths.any? do |source_path|
      repository_paths.any? do |repository_path|
        source_path == repository_path || source_path.start_with?("#{repository_path}#{File::SEPARATOR}")
      end
    end
  end

  def verify_trusted_base(repo_root:, base_sha:, claim:, git_capture:)
    errors = []
    manifest = {}
    RUNTIME_SOURCES.each do |role, source|
      runtime_bytes = File.binread(source.fetch(:path))
      matches = source.fetch(:tree_paths).filter_map do |tree_path|
        tree_bytes, _stderr, status = git_capture.call(repo_root, "show", "#{base_sha}:#{tree_path}")
        tree_path if status.success? && tree_bytes.b == runtime_bytes
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
    Result.new(accepted: false, provenance: provenance || "UNKNOWN", errors:, manifest: {})
  end
end
