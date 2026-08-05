#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

require_relative "../skills/secure-github-actions/lib/secure_github_actions_scanner"
# Load-bearing: bin/validate runs this file, so keep the focused scanner suite required here.
require_relative "../skills/secure-github-actions/bin/secure-github-actions-scan-test"

class RepositorySecurityPolicyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_repository_github_actions_pass_the_shared_security_scanner
    result = SecureGitHubActions::Scanner.new(ROOT).scan
    rendered_findings = result.findings.map do |finding|
      location = finding.fetch("location")
      "#{location.fetch('file')}:#{location.fetch('symbol')} " \
        "[#{finding.fetch('rule_id')}] #{finding.fetch('title')}"
    end

    assert_empty rendered_findings, "GitHub Actions security findings:\n#{rendered_findings.join("\n")}"
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
end
