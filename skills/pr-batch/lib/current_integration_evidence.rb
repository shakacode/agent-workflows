# frozen_string_literal: true

require "digest"
require "etc"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../../../bin/agent_doctor/autonomous_merge_policy"

module CurrentIntegrationEvidence
  class Error < StandardError; end

  CONTRACT = "current-integration-evidence"
  VERSION = 1
  SHA = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  REPOSITORY = %r{\A[^/\s]+/[^/\s]+\z}
  BASE_REF = /\A[^\s~^:?*\[\\]+\z/
  SYSTEM_TOOL_DIRS = %w[
    /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin
  ].freeze
  BUILTIN_HIGH_RISK_PATTERNS = %w[
    .github/workflows/**
    .github/actions/**
  ].freeze
  GRAPHQL = <<~GRAPHQL
    query($owner: String!, $name: String!, $number: Int!, $qualifiedBase: String!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          headRefOid
          baseRefName
          potentialMergeCommit {
            oid
            tree { oid }
            parents(first: 3) { totalCount nodes { oid } }
          }
        }
        ref(qualifiedName: $qualifiedBase) { target { oid } }
      }
    }
  GRAPHQL

  module_function

  def base_unchanged(
    repo_root:, repo:, pr_number:, recorded_base_sha:, head_sha:, trusted_base_sha:,
    pr_paths:, policy:, base_ref: "main", snapshot_reader: method(:github_snapshot)
  )
    validate_inputs!(repo_root:, repo:, pr_number:, base_ref:, recorded_base_sha:, head_sha:,
                     trusted_base_sha:, pr_paths:, policy:)
    raise Error, "base-unchanged evidence requires matching recorded and current bases" unless
      recorded_base_sha == trusted_base_sha

    initial = snapshot_reader.call(repo:, pr_number:, base_ref:)
    validate_snapshot!(initial, base_ref:, head_sha:, trusted_base_sha:)
    final = snapshot_reader.call(repo:, pr_number:, base_ref:)
    validate_snapshot!(final, base_ref:, head_sha:, trusted_base_sha:)
    live_identity = %w[head_sha base_ref base_sha]
    unless final.values_at(*live_identity) == initial.values_at(*live_identity)
      raise Error, "current integration changed during evidence collection"
    end

    {
      "contract" => CONTRACT,
      "version" => VERSION,
      "repository" => repo,
      "pr" => pr_number,
      "recorded_base_sha" => recorded_base_sha,
      "head_sha" => head_sha,
      "current_base" => { "ref" => base_ref, "sha" => trusted_base_sha },
      "patch_identity" => nil,
      "candidate" => nil,
      "base_delta" => { "paths" => [] },
      "reuse" => { "decision" => "base-unchanged", "reasons" => ["base-unchanged"] },
      "telemetry" => {
        "validator_replays_avoided" => 0,
        "review_replays_avoided" => 0,
        "elapsed_seconds_saved" => nil
      }
    }
  end

  def collect(
    repo_root:, repo:, pr_number:, recorded_base_sha:, head_sha:, trusted_base_sha:,
    pr_paths:, policy:, changelog_path:, base_ref: "main", snapshot_reader: method(:github_snapshot)
  )
    validate_inputs!(repo_root:, repo:, pr_number:, base_ref:, recorded_base_sha:, head_sha:,
                     trusted_base_sha:, pr_paths:, policy:)
    initial = snapshot_reader.call(repo:, pr_number:, base_ref:)
    validate_snapshot!(initial, base_ref:, head_sha:, trusted_base_sha:)

    ensure_commit!(repo_root, recorded_base_sha, "recorded PR base")
    ensure_commit!(repo_root, head_sha, "PR head")
    ensure_commit!(repo_root, trusted_base_sha, "trusted current base")
    unless git_success?(repo_root, "merge-base", "--is-ancestor", recorded_base_sha, trusted_base_sha)
      raise Error, "recorded PR base is not an ancestor of the trusted current base"
    end

    recorded_tree = git_output!(repo_root, "rev-parse", "#{recorded_base_sha}^{tree}").strip
    head_tree = git_output!(repo_root, "rev-parse", "#{head_sha}^{tree}").strip
    patch_identity = framed_digest("current-integration-patch-v1", recorded_tree, head_tree)
    git_pr_paths = changed_paths(repo_root, recorded_base_sha, head_sha)
    expected_pr_paths = canonical_paths(pr_paths, "PR path")
    unless git_pr_paths == expected_pr_paths
      raise Error, "Git PR paths do not match complete GitHub changed-file evidence"
    end

    base_delta_paths = changed_paths(repo_root, recorded_base_sha, trusted_base_sha)
    candidate = candidate_from_snapshot(initial, trusted_base_sha:, head_sha:) ||
                local_candidate(repo_root, trusted_base_sha, head_sha)

    final = snapshot_reader.call(repo:, pr_number:, base_ref:)
    raise Error, "current integration changed during evidence collection" unless final == initial

    decision, reasons = reuse_decision(
      recorded_base_sha:, trusted_base_sha:, pr_paths: git_pr_paths,
      base_delta_paths:, policy:, changelog_path:
    )
    avoided = decision == "reuse-exact-head" ? 1 : 0

    {
      "contract" => CONTRACT,
      "version" => VERSION,
      "repository" => repo,
      "pr" => pr_number,
      "recorded_base_sha" => recorded_base_sha,
      "head_sha" => head_sha,
      "current_base" => { "ref" => base_ref, "sha" => trusted_base_sha },
      "patch_identity" => patch_identity,
      "candidate" => candidate,
      "base_delta" => { "paths" => base_delta_paths },
      "reuse" => { "decision" => decision, "reasons" => reasons },
      "telemetry" => {
        "validator_replays_avoided" => avoided,
        "review_replays_avoided" => avoided,
        "elapsed_seconds_saved" => nil
      }
    }
  end

  def github_snapshot(repo:, pr_number:, base_ref:)
    owner, name = repo.split("/", 2)
    stdout, stderr, status = Open3.capture3(
      ENV.fetch("CURRENT_INTEGRATION_GH", "gh"), "api", "graphql",
      "-f", "query=#{GRAPHQL}", "-f", "owner=#{owner}", "-f", "name=#{name}",
      "-F", "number=#{pr_number}", "-f", "qualifiedBase=refs/heads/#{base_ref}"
    )
    raise Error, "GitHub current-integration query failed: #{stderr.lines.first.to_s.strip}" unless status.success?

    payload = JSON.parse(stdout)
    unless Array(payload["errors"]).empty?
      raise Error, "GitHub current-integration query returned errors"
    end

    repository = payload.dig("data", "repository")
    pull_request = repository["pullRequest"] if repository.is_a?(Hash)
    current_ref = repository["ref"] if repository.is_a?(Hash)
    raise Error, "GitHub current-integration query returned no pull request" unless pull_request.is_a?(Hash)

    candidate = pull_request["potentialMergeCommit"]
    normalized_candidate = if candidate.nil?
                             nil
                           else
                             {
                               "oid" => candidate["oid"],
                               "tree_oid" => candidate.dig("tree", "oid"),
                               "parents" => Array(candidate.dig("parents", "nodes")).map { |node| node["oid"] },
                               "parent_count" => candidate.dig("parents", "totalCount")
                             }
                           end
    {
      "head_sha" => pull_request["headRefOid"],
      "base_ref" => pull_request["baseRefName"],
      "base_sha" => current_ref&.dig("target", "oid"),
      "candidate" => normalized_candidate
    }
  rescue JSON::ParserError, TypeError => e
    raise Error, "GitHub current-integration evidence is malformed: #{e.message}"
  rescue Errno::ENOENT
    raise Error, "GitHub CLI is unavailable"
  end

  def validate_inputs!(repo_root:, repo:, pr_number:, base_ref:, recorded_base_sha:, head_sha:,
                       trusted_base_sha:, pr_paths:, policy:)
    raise Error, "repository root is unavailable" unless File.directory?(repo_root)
    unless repo.is_a?(String) && repo.match?(REPOSITORY) &&
           repo.split("/", 2).none? { |segment| segment.start_with?("@") }
      raise Error, "repository must use safe OWNER/REPO form"
    end
    raise Error, "PR number must be positive" unless pr_number.is_a?(Integer) && pr_number.positive?
    unless base_ref.is_a?(String) && base_ref.match?(BASE_REF) &&
           !base_ref.include?("..") && !base_ref.start_with?("@")
      raise Error, "base ref is invalid"
    end
    unless git_success?(repo_root, "check-ref-format", "--branch", base_ref)
      raise Error, "base ref is invalid"
    end

    [recorded_base_sha, head_sha, trusted_base_sha].each do |sha|
      unless sha.is_a?(String) && sha.match?(SHA)
        raise Error, "integration identity requires full lowercase Git object IDs"
      end
    end
    raise Error, "PR paths must be a list" unless pr_paths.is_a?(Array)
    raise Error, "trusted autonomous policy is unavailable" unless policy.respond_to?(:safe_path_groups)
  end

  def validate_snapshot!(snapshot, base_ref:, head_sha:, trusted_base_sha:)
    raise Error, "GitHub current-integration evidence is malformed" unless snapshot.is_a?(Hash)
    raise Error, "GitHub PR head does not match evaluated head" unless snapshot["head_sha"] == head_sha
    raise Error, "GitHub PR base ref does not match expected base" unless snapshot["base_ref"] == base_ref
    raise Error, "live base ref does not match trusted current base" unless snapshot["base_sha"] == trusted_base_sha
  end

  def candidate_from_snapshot(snapshot, trusted_base_sha:, head_sha:)
    raw = snapshot["candidate"]
    return nil if raw.nil?
    unless raw.is_a?(Hash) && raw["oid"].is_a?(String) && raw["oid"].match?(SHA) &&
           raw["tree_oid"].is_a?(String) && raw["tree_oid"].match?(SHA) &&
           raw["parent_count"].is_a?(Integer) && raw["parent_count"] >= 0 &&
           raw["parents"].is_a?(Array) &&
           raw["parents"].length == [raw["parent_count"], 3].min &&
           raw["parents"].all? { |parent| parent.is_a?(String) && parent.match?(SHA) }
      raise Error, "GitHub current integration candidate identity is malformed"
    end
    # GitHub can retain a syntactically valid potential merge commit for an
    # older base immediately after the target branch advances. That is
    # provider unavailability, not authoritative evidence about the current
    # integration. Fall back to the isolated local merge-tree computation.
    return nil unless raw["parent_count"] == 2 && raw["parents"] == [trusted_base_sha, head_sha]

    {
      "source" => "github-potential-merge-commit",
      "oid" => raw.fetch("oid"),
      "tree_oid" => raw.fetch("tree_oid"),
      "parents" => raw.fetch("parents")
    }
  end

  def local_candidate(repo_root, trusted_base_sha, head_sha)
    Dir.mktmpdir("current-integration-merge-tree") do |directory|
      bare = File.join(directory, "repo.git")
      run_git_external!(repo_root, "init", "--bare", "--quiet", bare)
      object_path = git_output!(repo_root, "rev-parse", "--git-path", "objects").strip
      object_path = File.expand_path(object_path, repo_root) unless object_path.start_with?("/")
      object_dir = File.realpath(object_path)
      alternates = File.join(bare, "objects", "info", "alternates")
      FileUtils.mkdir_p(File.dirname(alternates))
      File.write(alternates, "#{object_dir}\n")
      stdout, stderr, status = safe_git_capture(
        "--git-dir", bare, "merge-tree", "--write-tree", trusted_base_sha, head_sha,
        outside_root: repo_root
      )
      raise Error, "trusted local synthetic merge is conflicted or unavailable: #{stderr.lines.first.to_s.strip}" unless
        status.success?

      tree_oid = stdout.lines.first.to_s.strip
      raise Error, "trusted local synthetic merge returned an invalid tree" unless tree_oid.match?(SHA)

      {
        "source" => "git-merge-tree",
        "oid" => nil,
        "tree_oid" => tree_oid,
        "parents" => [trusted_base_sha, head_sha]
      }
    end
  rescue SystemCallError => e
    raise Error, "trusted local synthetic merge is unavailable: #{e.message}"
  end

  def reuse_decision(recorded_base_sha:, trusted_base_sha:, pr_paths:, base_delta_paths:, policy:, changelog_path:)
    return ["base-unchanged", ["base-unchanged"]] if recorded_base_sha == trusted_base_sha

    reasons = []
    reasons << "path-overlap" unless (pr_paths & base_delta_paths).empty?
    reasons << "base-delta-high-risk" if base_delta_paths.any? { |path| policy_path?(path, policy) }
    reasons << "pr-delta-high-risk" if pr_paths.any? { |path| policy_path?(path, policy) }
    reasons.uniq!
    reasons.sort!
    return ["fresh-integration-required", reasons] unless reasons.empty?

    pr_safe = !pr_paths.empty? && pr_paths.all? do |path|
      reuse_safe_path?(path, policy:, changelog_path:)
    end
    base_safe = !base_delta_paths.empty? && base_delta_paths.all? do |path|
      reuse_safe_path?(path, policy:, changelog_path:)
    end
    safe_reasons = []
    safe_reasons << "base-delta-reuse-safe" if base_safe
    safe_reasons << "pr-delta-reuse-safe" if pr_safe
    return ["reuse-exact-head", safe_reasons] if pr_safe || base_safe

    ["fresh-integration-required", ["neither-delta-reuse-safe"]]
  end

  def reuse_safe_path?(path, policy:, changelog_path:)
    return false if policy_path?(path, policy)
    return true if changelog_path.is_a?(String) && path == changelog_path
    return true if policy.generated_paths.any? { |pattern| AutonomousMergePolicy.match?(pattern, path) }

    documentation = policy.safe_path_groups.fetch("documentation")
    documentation.fetch("include").any? { |pattern| AutonomousMergePolicy.match?(pattern, path) } &&
      documentation.fetch("exclude").none? { |pattern| AutonomousMergePolicy.match?(pattern, path) }
  end

  def policy_path?(path, policy)
    patterns = BUILTIN_HIGH_RISK_PATTERNS +
               AutonomousMergePolicy::BUILTIN_POLICY_PATTERNS + policy.policy_paths
    patterns.any? { |pattern| AutonomousMergePolicy.match?(pattern, path) } ||
      policy.human_review_paths.any? do |rule|
        AutonomousMergePolicy.match?(rule.fetch("pattern"), path)
      end
  end

  def canonical_paths(paths, label)
    normalized = paths.map do |path|
      unless path.is_a?(String) && !path.empty? && !path.start_with?("/") &&
             !path.include?("\\") && path.split("/", -1).none? { |part| part.empty? || %w[. ..].include?(part) }
        raise Error, "#{label} is not a canonical repository-relative path"
      end

      path
    end
    raise Error, "#{label} list contains duplicates" unless normalized.uniq.length == normalized.length

    normalized.sort
  end

  def changed_paths(repo_root, older, newer)
    raw = git_output!(repo_root, "diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", older, newer)
    canonical_paths(raw.split("\0", -1).reject(&:empty?), "Git changed path")
  end

  def framed_digest(*values)
    digest = Digest::SHA256.new
    values.each do |value|
      bytes = value.to_s.b
      digest << [bytes.bytesize].pack("Q>") << bytes
    end
    digest.hexdigest
  end

  def ensure_commit!(repo_root, sha, label)
    return if git_success?(repo_root, "cat-file", "-e", "#{sha}^{commit}")

    raise Error, "#{label} commit is unavailable"
  end

  def git_output!(repo_root, *arguments)
    stdout, stderr, status = safe_git_capture("-C", repo_root, *arguments, outside_root: repo_root)
    raise Error, "Git evidence command failed: #{stderr.lines.first.to_s.strip}" unless status.success?

    stdout
  end

  def git_success?(repo_root, *arguments)
    _stdout, _stderr, status = safe_git_capture("-C", repo_root, *arguments, outside_root: repo_root)
    status.success?
  end

  def run_git_external!(repo_root, *arguments)
    _stdout, stderr, status = safe_git_capture(*arguments, outside_root: repo_root)
    raise Error, "Git evidence setup failed: #{stderr.lines.first.to_s.strip}" unless status.success?
  end

  def safe_git_capture(*arguments, outside_root:)
    account = Etc.getpwuid(Process.uid)
    environment = {
      "HOME" => account.dir,
      "USER" => account.name,
      "LOGNAME" => account.name,
      "PATH" => SYSTEM_TOOL_DIRS.join(File::PATH_SEPARATOR),
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_NO_REPLACE_OBJECTS" => "1",
      "GIT_OPTIONAL_LOCKS" => "0",
      "GIT_TERMINAL_PROMPT" => "0"
    }
    Open3.capture3(
      environment,
      resolve_system_git!(outside_root:),
      *arguments,
      unsetenv_others: true
    )
  rescue ArgumentError
    raise Error, "local account identity is unavailable for uid #{Process.uid}"
  rescue Errno::ENOENT, Errno::EACCES => e
    raise Error, "Git could not be launched after trusted resolution: #{e.message}"
  end

  def resolve_system_git!(outside_root:)
    candidate = SYSTEM_TOOL_DIRS
                .map { |directory| File.join(directory, "git") }
                .find { |path| File.file?(path) && File.executable?(path) }
    raise Error, "Git is unavailable in approved system tool directories" unless candidate

    realpath = File.realpath(candidate)
    root = File.realpath(outside_root)
    prefix = "#{root}#{File::SEPARATOR}"
    if realpath == root || realpath.start_with?(prefix)
      raise Error, "Git must resolve outside the consumer repository"
    end

    stat = File.stat(realpath)
    unless stat.file? && File.executable?(realpath)
      raise Error, "Git is not an executable regular file"
    end

    realpath
  rescue Errno::ENOENT, Errno::EACCES
    raise Error, "Git is unavailable in approved system tool directories"
  end
end
