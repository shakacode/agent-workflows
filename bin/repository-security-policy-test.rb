#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class RepositorySecurityPolicyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_github_actions_are_pinned_to_full_commit_shas
    reference_sets = Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}")).map do |path|
      workflow = YAML.safe_load_file(path, aliases: true)
      [path, workflow_uses(workflow)]
    end
    action_paths = Dir.glob(File.join(ROOT, "**/action.{yml,yaml}"), File::FNM_DOTMATCH).reject do |path|
      relative_parts = path.delete_prefix("#{ROOT}/").split("/")
      (relative_parts & %w[.codex .git .tmp tmp]).any?
    end
    reference_sets.concat(action_paths.map do |path|
      action = YAML.safe_load_file(path, aliases: true)
      [path, composite_uses(action)]
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

  def test_repository_local_references_are_bound_by_the_checkout
    assert acceptable_action_reference?("./.github/actions/example")
    assert acceptable_action_reference?("owner/action@0123456789abcdef0123456789abcdef01234567")
    refute acceptable_action_reference?("owner/action@v1")
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
    assert_equal "weekly", action_updates.dig("schedule", "interval")
  end

  private

  def acceptable_action_reference?(reference)
    reference.is_a?(String) && (reference.start_with?("./") || reference.match?(/@[0-9a-f]{40}\z/))
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
