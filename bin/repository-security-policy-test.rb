#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class RepositorySecurityPolicyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_github_actions_are_pinned_to_full_commit_shas
    mutable_uses = Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}")).flat_map do |path|
      File.readlines(path, chomp: true).filter_map do |line|
        match = line.match(/^\s*-?\s*uses:\s*([^\s#]+)(?:\s*#.*)?$/)
        next unless match

        reference = match[1]
        "#{path.delete_prefix("#{ROOT}/")}: #{reference}" unless reference.match?(/@[0-9a-f]{40}\z/)
      end
    end

    assert_empty mutable_uses, "mutable GitHub Actions references:\n#{mutable_uses.join("\n")}"
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
    assert_includes policy, "status --porcelain=v1 --untracked-files=all"
    assert_includes policy, "merge-base --is-ancestor HEAD origin/main"
    assert_includes policy, 'git -C "$HOME/src/agent-workflows" diff --no-ext-diff HEAD..origin/main'
    reviewed_upgrade = 'upgrade-agent-workflows --host codex --source "$HOME/src/agent-workflows" --no-fetch'

    assert_includes policy, reviewed_upgrade
  end

  def test_dependabot_proposes_pinned_action_updates_for_review
    config = YAML.safe_load_file(File.join(ROOT, ".github/dependabot.yml"), aliases: false)
    action_updates = config.fetch("updates").find do |entry|
      entry["package-ecosystem"] == "github-actions" && entry["directory"] == "/"
    end

    refute_nil action_updates
    assert_equal "weekly", action_updates.dig("schedule", "interval")
  end
end
