#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class SecureGitHubActionsReviewLensTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SURFACES = %w[
    skills/autoreview/SKILL.md
    skills/adversarial-pr-review/SKILL.md
    workflows/adversarial-pr-review.md
  ].freeze

  def test_workflow_diffs_activate_the_deterministic_security_lens
    SURFACES.each do |relative_path|
      text = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")

      assert_includes text, ".github/workflows/**", relative_path
      assert_includes text, "secure-github-actions-scan", relative_path
      assert_includes text, "necessary but not sufficient", relative_path
    end
  end

  def test_trusted_actions_policy_diffs_activate_the_deterministic_security_lens
    SURFACES.each do |relative_path|
      text = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")

      assert_includes text, ".agents/agent-workflow.yml", relative_path
      assert_includes text, "trusted_actions", relative_path
      assert_includes text, "secure-github-actions-scan", relative_path
    end
  end
end
