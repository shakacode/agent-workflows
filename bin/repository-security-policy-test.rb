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

  def test_human_security_review_runs_only_from_trusted_base_events
    path = File.join(ROOT, ".github/workflows/human-security-review.yml")
    workflow = File.read(path)

    assert_match(/^  pull_request_target:$/m, workflow)
    refute_match(/^  pull_request_review:$/m, workflow)
    assert_match(/^  schedule:$/m, workflow)
    assert_match(/^  workflow_dispatch:$/m, workflow)
    assert_includes workflow, "ref: ${{ github.event.pull_request.base.sha || github.sha }}"
    assert_includes workflow, "persist-credentials: false"
    assert_includes workflow, "bin/human-security-review-gate"
    assert_includes workflow, '--expected-head "$HEAD_SHA"'
    assert_includes workflow, "pulls?state=open&per_page=100"
    assert_match(/^  statuses: write$/m, workflow)
    assert_includes workflow, "repos/$GITHUB_REPOSITORY/statuses/$HEAD_SHA"
    assert_includes workflow, "context=human-security-review/exact-head"
  end

  def test_execution_and_agent_instruction_surfaces_have_human_code_owners
    owners = File.read(File.join(ROOT, ".github/CODEOWNERS"))
    protected_patterns = %w[
      /AGENTS.md
      /.agents/
      /.claude-plugin/
      /.codex-plugin/
      /.github/
      /bin/
      /skills/
      /workflows/
      **/*.sh
      **/*.bash
    ]

    protected_patterns.each do |pattern|
      assert_match(%r{^#{Regexp.escape(pattern)}\s+@shakacode/admins$}m, owners)
    end
  end

  def test_autonomous_merge_policy_routes_every_execution_surface_to_humans
    policy = YAML.safe_load_file(File.join(ROOT, ".agents/agent-workflow.yml"), aliases: false)
    patterns = policy.dig("autonomous_merge", "human_review_paths").map { |entry| entry.fetch("pattern") }
    expected = %w[
      AGENTS.md
      .agents/**
      .claude-plugin/**
      .codex-plugin/**
      .github/**
      bin/**
      skills/**
      workflows/**
      **/*.sh
      **/*.bash
    ]

    assert_empty expected - patterns
  end

  def test_dependabot_proposes_pinned_action_updates_for_human_review
    config = YAML.safe_load_file(File.join(ROOT, ".github/dependabot.yml"), aliases: false)
    action_updates = config.fetch("updates").find do |entry|
      entry["package-ecosystem"] == "github-actions" && entry["directory"] == "/"
    end

    refute_nil action_updates
    assert_equal "weekly", action_updates.dig("schedule", "interval")
  end
end
