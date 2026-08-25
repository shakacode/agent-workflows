#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "../skills/secure-github-actions/lib/secure_github_actions_scanner"

class RepositorySecurityPolicyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  YAML_TIMESTAMP_CLASSES = [Date, Time].freeze

  def test_repository_passes_the_secure_github_actions_gate
    result = SecureGitHubActions::Scanner.new(ROOT).scan
    rendered = result.findings.map do |finding|
      location = finding.fetch("location")
      "#{location.fetch('file')}:#{location.fetch('line')} " \
        "[#{finding.fetch('rule_id')}] #{finding.fetch('title')}"
    end

    assert_empty rendered, "GitHub Actions security findings:\n#{rendered.join("\n")}"
  end

  def test_github_actions_are_pinned_to_full_commit_shas
    reference_sets = Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}")).map do |path|
      [path, workflow_uses(load_yaml_file(path))]
    end
    reference_sets.concat(action_paths.map do |path|
      [path, composite_uses(load_yaml_file(path))]
    end)

    mutable_uses = reference_sets.flat_map do |path, references|
      references.filter_map do |location, reference|
        next if acceptable_action_reference?(reference)

        "#{path.delete_prefix("#{ROOT}/")}:#{location}: #{reference.inspect}"
      end
    end

    assert_empty mutable_uses, "mutable GitHub Actions references:\n#{mutable_uses.join("\n")}"
  end

  def test_action_reference_scanner_reads_yaml_structure
    workflow = YAML.safe_load(<<~YAML, aliases: true)
      jobs:
        validate:
          steps: [{ uses : owner/action@v1, with: { uses: node20 } }]
        release: { uses: owner/workflow@v1 }
    YAML

    assert_equal [
      ["jobs.validate.steps.0.uses", "owner/action@v1"],
      ["jobs.release.uses", "owner/workflow@v1"]
    ], workflow_uses(workflow)
  end

  def test_action_reference_scanner_reads_composite_action_structure
    action = YAML.safe_load(<<~YAML, aliases: true)
      runs:
        using: composite
        steps: [{ uses : owner/action@v1, with: { uses: node20 } }]
    YAML

    assert_equal [["runs.steps.0.uses", "owner/action@v1"]], composite_uses(action)
  end

  def test_action_reference_scanner_accepts_timestamp_scalars_and_still_rejects_mutable_uses
    sha = "0123456789abcdef0123456789abcdef01234567"

    Dir.mktmpdir("repository-security-policy") do |root|
      immutable_workflow = File.join(root, "immutable.yml")
      mutable_workflow = File.join(root, "mutable.yml")
      File.write(immutable_workflow, <<~YAML)
        generated_on: 2026-08-02
        jobs:
          validate:
            steps: [{ uses: owner/action@#{sha} }]
      YAML
      File.write(mutable_workflow, <<~YAML)
        generated_at: 2026-08-02T12:34:56Z
        jobs:
          validate:
            steps: [{ uses: owner/action@v1 }]
      YAML

      immutable_references = workflow_uses(load_yaml_file(immutable_workflow))
      mutable_references = workflow_uses(load_yaml_file(mutable_workflow))

      assert_equal [["jobs.validate.steps.0.uses", "owner/action@#{sha}"]], immutable_references
      assert acceptable_action_reference?(immutable_references.first.last)
      assert_equal [["jobs.validate.steps.0.uses", "owner/action@v1"]], mutable_references
      refute acceptable_action_reference?(mutable_references.first.last)
    end
  end

  def test_action_scanner_keeps_nested_temp_named_directories
    Dir.mktmpdir("repository-security-policy") do |root|
      nested_action = File.join(root, "skills/example/tmp/action.yml")
      ignored_action = File.join(root, "tmp/action.yml")
      FileUtils.mkdir_p(File.dirname(nested_action))
      FileUtils.mkdir_p(File.dirname(ignored_action))
      File.write(nested_action, "name: nested\n")
      File.write(ignored_action, "name: ignored\n")

      assert_includes action_paths(root), nested_action
      refute_includes action_paths(root), ignored_action
    end
  end

  def test_action_scanner_excludes_case_aliased_root_on_case_insensitive_filesystems
    skip "filesystem is case-sensitive" unless filesystem_case_insensitive?

    Dir.mktmpdir("repository-security-policy") do |root|
      lowercase_root = File.join(root, "tmp")
      FileUtils.mkdir_p(lowercase_root)
      File.write(File.join(lowercase_root, "action.yml"), "name: ignored\n")
      intermediate = File.join(root, "tmp-case-rename")
      File.rename(lowercase_root, intermediate)
      uppercase_root = File.join(root, "TMP")
      File.rename(intermediate, uppercase_root)

      refute_includes action_paths(root), File.join(uppercase_root, "action.yml")
      refute acceptable_action_reference?("./TMP/action", root: root)
    end
  end

  def test_action_scanner_keeps_distinct_uppercase_root_on_case_sensitive_filesystems
    skip "filesystem is case-insensitive" if filesystem_case_insensitive?

    Dir.mktmpdir("repository-security-policy") do |root|
      excluded_action = File.join(root, "tmp/action.yml")
      distinct_action = File.join(root, "TMP/action.yml")
      FileUtils.mkdir_p(File.dirname(excluded_action))
      FileUtils.mkdir_p(File.dirname(distinct_action))
      File.write(excluded_action, "name: ignored\n")
      File.write(distinct_action, "name: included\n")

      refute_includes action_paths(root), excluded_action
      assert_includes action_paths(root), distinct_action
      assert acceptable_action_reference?("./TMP/action", root: root)
    end
  end

  def test_excluded_action_root_alias_does_not_use_regular_file_inode_identity
    skip "filesystem is case-insensitive" if filesystem_case_insensitive?

    Dir.mktmpdir("repository-security-policy") do |root|
      excluded_file = File.join(root, "tmp")
      alias_file = File.join(root, "TMP")
      File.write(excluded_file, "not a directory\n")
      File.link(excluded_file, alias_file)

      refute SecureGitHubActions.excluded_action_root?(root, "TMP/action.yml")
    end
  end

  def test_repository_local_references_are_bound_by_the_checkout
    sha = "0123456789abcdef0123456789abcdef01234567"

    assert acceptable_action_reference?("./.github/actions/example")
    assert acceptable_action_reference?("owner/action@#{sha}")
    assert acceptable_action_reference?("owner/action/subpath@#{sha}")
    assert acceptable_action_reference?("docker://alpine@sha256:#{'a' * 64}")
    refute acceptable_action_reference?("./tmp/evil")
    refute acceptable_action_reference?("./nested/../../outside")
    refute acceptable_action_reference?("owner/action@v1")
    refute acceptable_action_reference?("owner/action@v1@#{sha}")
    refute acceptable_action_reference?("docker://alpine@#{sha}")
    refute acceptable_action_reference?("docker://alpine:latest")
  end

  def test_routine_pull_requests_do_not_use_the_broad_custom_human_gate
    refute File.exist?(File.join(ROOT, ".github/workflows/human-security-review.yml"))
    refute File.exist?(File.join(ROOT, "bin/human-security-review-gate"))
  end

  def test_supply_chain_policy_places_human_review_at_release_promotion
    policy = File.read(File.join(ROOT, "docs/repository-supply-chain.md"))

    assert_includes policy, "Stable release promotion, not ordinary pull-request development"
    assert_includes policy, "agent-workflows/issues/296"
    assert_includes policy, "Automated reviews remain advisory"
    assert_includes policy, "There is no supported human-reviewed install or upgrade path today"
  end

  def test_dependabot_proposes_pinned_action_updates_for_review
    config = YAML.safe_load_file(File.join(ROOT, ".github/dependabot.yml"), aliases: false)
    action_updates = config.fetch("updates").find do |entry|
      entry["package-ecosystem"] == "github-actions" && entry["directory"] == "/"
    end

    refute_nil action_updates
    assert_equal "monthly", action_updates.dig("schedule", "interval")

    policy = File.read(File.join(ROOT, "docs/repository-supply-chain.md"))
    assert_includes policy, "Dependabot proposes Action updates monthly"
  end

  private

  def load_yaml_file(path)
    YAML.safe_load_file(path, permitted_classes: YAML_TIMESTAMP_CLASSES, aliases: true)
  end

  def action_paths(root = ROOT)
    paths = Dir.glob("**/action.{yml,yaml}", File::FNM_DOTMATCH, base: root).reject do |relative|
      SecureGitHubActions.excluded_action_root?(root, relative)
    end
    paths.map { |relative| File.join(root, relative) }
  end

  def filesystem_case_insensitive?
    Dir.mktmpdir("repository-security-policy-case-probe") do |root|
      lower = File.join(root, "case-probe")
      upper = File.join(root, "CASE-PROBE")
      Dir.mkdir(lower)
      return File.identical?(lower, upper)
    end
  end

  def acceptable_action_reference?(reference, root: ROOT)
    return false unless reference.is_a?(String)

    if reference.start_with?("./")
      segments = reference.delete_prefix("./").split("/")
      return !segments.empty? && !SecureGitHubActions.excluded_action_root?(root, segments.join("/")) &&
             segments.none? { |segment| segment.empty? || %w[. ..].include?(segment) }
    end
    return true if reference.match?(%r{\Adocker://[^\s@]+@sha256:[0-9a-fA-F]{64}\z})

    reference.match?(%r{\A[^\s@/]+/[^\s@/]+(?:/[^\s@/]+)*@[0-9a-f]{40}\z})
  end

  def workflow_uses(workflow)
    jobs = workflow.is_a?(Hash) ? workflow["jobs"] : nil
    return [] unless jobs.is_a?(Hash)

    jobs.flat_map do |job_name, job|
      next [] unless job.is_a?(Hash)

      references = job.key?("uses") ? [["jobs.#{job_name}.uses", job["uses"]]] : []
      references + step_uses(job["steps"], "jobs.#{job_name}.steps")
    end
  end

  def composite_uses(action)
    runs = action.is_a?(Hash) ? action["runs"] : nil
    return [] unless runs.is_a?(Hash)

    step_uses(runs["steps"], "runs.steps")
  end

  def step_uses(steps, path)
    return [] unless steps.is_a?(Array)

    steps.each_with_index.filter_map do |step, index|
      next unless step.is_a?(Hash) && step.key?("uses")

      ["#{path}.#{index}.uses", step["uses"]]
    end
  end
end
