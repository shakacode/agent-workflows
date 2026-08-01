#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../bin/agent_doctor/autonomous_merge_policy"
require_relative "../lib/autonomous_merge_runtime_trust"

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
THRESHOLD_DOCUMENTATION_PARITY = "ADR 0003 is the source of truth for these copied portable defaults. " \
                                 "File, line, and commit maxima are enforced; max_reviewed_heads is " \
                                 "shadow-only until a checked calibration artifact explicitly graduates " \
                                 "it to enforcement."

class AutonomousMergeContractTest < Minitest::Test
  def test_runtime_records_are_keyword_structs_compatible_with_ruby_three_one
    records = [
      AutonomousMergePolicy::Result,
      AutonomousMergeRuntimeTrust::Result
    ]

    records.each do |record|
      assert_operator record, :<, Struct
      assert_equal true, record.keyword_init?
    end

    assert_equal(
      { accepted: true, provenance: "test", errors: [], manifest: {} },
      AutonomousMergeRuntimeTrust::Result.new(
        accepted: true,
        provenance: "test",
        errors: [],
        manifest: {}
      ).to_h
    )
  end

  def test_all_entry_points_preserve_eligibility_and_distinct_terminal_states
    PARITY_PATHS.each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8").gsub(/\s+/, " ")

      assert_includes text, NECESSARY_NOT_SUFFICIENT, path
      assert_includes text, UNKNOWN_IS_NOT_APPROVAL, path
      assert_includes text, HUMAN_STATE, path
      assert_includes text, UNKNOWN_STATE, path
    end
  end

  def test_canonical_workflow_binds_provider_runtime_and_consumer_policy_separately
    workflow = File.read(File.join(ROOT, "workflows/pr-processing.md"), encoding: "UTF-8")

    assert_includes workflow, "autonomous-merge-eligibility"
    assert_includes workflow, "--trusted-base"
    assert_includes workflow, "human-approved-for-current-head"
    assert_includes workflow, "shadow_triggered_gates"
    assert_includes workflow, '"${AGENT_WORKFLOWS_RUNNER[@]}" autonomous-merge-eligibility'
    assert_includes workflow, "provider-operation:<provider-revision>:<runtime-digest>"
    assert_includes workflow, "consumer base contributes policy only"
    refute_includes workflow, "TRUSTED_RUNTIME_ROOT"
    refute_includes workflow, "--trusted-helper-provenance"
    assert_includes workflow, "autonomous_merge_runtime_trust.rb"
    assert_match(/stdin\s+evaluation JSON is diagnostic-only/, workflow)
    assert_includes workflow, "role-length-framed runtime digest"
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

  def test_copied_threshold_defaults_document_reviewed_heads_as_shadow_only
    %w[docs/seam-design.md examples/agent-workflow.yml].each do |path|
      text = File.read(File.join(ROOT, path), encoding: "UTF-8")
                 .lines
                 .map { |line| line.sub(/\A# ?/, "") }
                 .join
                 .delete("`")
                 .gsub(/\s+/, " ")

      assert_includes text, THRESHOLD_DOCUMENTATION_PARITY, path
    end
  end
end
