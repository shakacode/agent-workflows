#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class PrWalkthroughContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SKILL = File.join(ROOT, "skills/pr-walkthrough/SKILL.md")
  WORKFLOW = File.join(ROOT, "workflows/pr-processing.md")
  PR_BATCH = File.join(ROOT, "skills/pr-batch/SKILL.md")
  PR_MONITORING = File.join(ROOT, "skills/pr-monitoring/SKILL.md")

  def test_skill_is_exact_head_interactive_and_complete
    skill = File.read(SKILL).gsub(/\s+/, " ")

    [
      "Inspect the complete file list and diff before presenting Step 1.",
      "Maintain a private coverage ledger",
      "Present exactly one conceptual change per response.",
      "Why this approach",
      "Then stop. Do not include the next conceptual change in the same response.",
      "Advance only after explicit readiness",
      "A walkthrough response, `next`, or positive reaction is never merge approval.",
      "If the head changes during the walkthrough"
    ].each do |contract|
      assert_includes skill, contract
    end
  end

  def test_ask_authority_automatically_walks_through_before_merge_decision
    [WORKFLOW, PR_BATCH, PR_MONITORING].each do |path|
      text = File.read(path).gsub(/\s+/, " ")

      assert_includes text, "automatically start the exact-head PR walkthrough"
      assert_includes text, "full interactive mode for large or complex PRs"
      assert_includes text, "refresh the head and ordinary readiness"
      assert_includes text, "one final merge decision"
    end
  end
end
