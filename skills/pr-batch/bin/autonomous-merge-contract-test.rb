#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
PARITY_PATHS = %w[
  workflows/pr-processing.md
  skills/pr-batch/SKILL.md
  skills/pr-monitoring/SKILL.md
  skills/plan-pr-batch/SKILL.md
  skills/triage/SKILL.md
].freeze
NECESSARY_NOT_SUFFICIENT = "Ordinary readiness is necessary but not sufficient for autonomous merge; " \
                           "evaluate exact-head autonomous-merge eligibility after every ordinary gate passes."
UNKNOWN_IS_NOT_APPROVAL = "`UNKNOWN` is not `human-approval-required` and cannot be cleared by risk approval."
HUMAN_STATE = "`ready-human-review-required` carries the exact current head SHA, every triggered gate, " \
              "rollback status, and the exact durable human decision needed."
UNKNOWN_STATE = "`autonomous-merge-evidence-unknown` carries the exact current head SHA, evidence failure, " \
                "trusted-base policy provenance, and repair action."
GMCC_HUMAN_DECISION_BINDING = "auto=>exact verdict/head/sorted-gates/rollback; merge iff " \
                              "autonomous-merge-eligible OR human-approved-for-current-head+" \
                              "durable-decision(proven-human+merge-authority)"

class AutonomousMergeContractTest < Minitest::Test
  def test_all_entry_points_preserve_eligibility_and_distinct_terminal_states
    PARITY_PATHS.each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8").gsub(/\s+/, " ")

      assert_includes text, NECESSARY_NOT_SUFFICIENT, path
      assert_includes text, UNKNOWN_IS_NOT_APPROVAL, path
      assert_includes text, HUMAN_STATE, path
      assert_includes text, UNKNOWN_STATE, path
    end
  end

  def test_canonical_workflow_binds_helper_to_trusted_base_and_exact_current_head
    workflow = File.read(File.join(ROOT, "workflows/pr-processing.md"), encoding: "UTF-8")

    assert_includes workflow, "autonomous-merge-eligibility"
    assert_includes workflow, "--trusted-base"
    assert_includes workflow, "human-approved-for-current-head"
    assert_includes workflow, "shadow_triggered_gates"
    assert_includes workflow, "trusted-base materialization"
    assert_includes workflow, "verified installed Agent Workflows pack"
    assert_includes workflow, "--trusted-helper-provenance"
    assert_includes workflow, "autonomous_merge_runtime_trust.rb"
    assert_match(/stdin\s+evaluation JSON is diagnostic-only/, workflow)
    assert_includes workflow, "mechanically recomputes a length-framed manifest"
    assert_includes workflow, "remain coordinator procedures"
    assert_match(/`merge_authority`\s+remains separate from\s+eligibility/, workflow)
  end

  def test_goal_generation_surfaces_carry_both_autonomous_stop_states
    %w[
      workflows/pr-processing.md
      skills/pr-batch/SKILL.md
      skills/plan-pr-batch/SKILL.md
      skills/triage/SKILL.md
    ].each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8")

      assert_includes text, "GMCC-v3:"
      assert_includes text, "ready-human-review-required"
      assert_includes text, "autonomous-merge-evidence-unknown"
      assert_includes text, GMCC_HUMAN_DECISION_BINDING
    end
  end
end
