# frozen_string_literal: true

require "digest"
require "open3"

module AutonomousMergeRuntimeTrust
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

  module_function

  def verify(repo_root:, base_sha:, claim:, calibration_path:)
    sources = runtime_sources(calibration_path)
    unreadable = sources.filter_map do |role, source|
      "#{role} runtime source is unavailable" unless File.file?(source.fetch(:path))
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
      rejected(claim, ["trusted helper provenance is missing or invalid"])
    end
  rescue SystemCallError => e
    rejected(claim, ["runtime trust verification failed: #{e.message}"])
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

  def verify_trusted_base(repo_root:, base_sha:, claim:, sources:)
    errors = []
    manifest = {}
    sources.each do |role, source|
      runtime_bytes = File.binread(source.fetch(:path))
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
