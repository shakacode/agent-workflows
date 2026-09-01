#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

class DependencyConflictPolicyContractTest < Minitest::Test
  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def test_canonical_policy_preserves_semantic_ordering_and_advisory_overlap
    workflow = read("workflows/pr-processing.md")

    assert_includes workflow, "### Dependency And Conflict Throughput Policy"
    assert_includes workflow, "Issue-authored semantic dependencies are authoritative ordering constraints"
    assert_includes workflow, "Never create, remove, or retype a semantic dependency merely because file-touch maps overlap"
    assert_includes workflow, "overlap is advisory until integration"
    assert_includes workflow, "Repeated overlap is a modularization signal, not a launch blocker"
    assert_includes workflow, "executable code, schemas, security boundaries, merge policy, or canonical contracts"
  end

  def test_artifact_ownership_is_a_consumer_seam_not_a_portable_default
    workflow = read("workflows/pr-processing.md")
    planner = read("skills/plan-pr-batch/SKILL.md")

    [workflow, planner].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_includes normalized, "consumer repository's `AGENTS.md` artifact-ownership seam"
      assert_includes normalized, "`defer`, `waive`, `dedicated-owner`, or"
    end
    assert_includes workflow, "This source repository's `deferred_to_update_changelog` rule is one such seam instance, not a portable default"
  end

  def test_non_safety_override_is_operational_and_cannot_touch_protected_gates
    workflow = read("workflows/pr-processing.md")
    override = workflow[%r{Record `Non-safety coordination override:.*?Missing or `UNKNOWN` reason/evidence is not an override\.}m]

    refute_nil override
    assert_includes override, "may set aside only that specifically evidenced non-safety stop"
    assert_includes override, "cannot alter an issue-authored semantic dependency"
    ["correctness", "merge authority", "security", "production", "release", "destructive-action"].each do |protected_gate|
      assert_includes override, protected_gate
    end
    refute_match(/may bypass|can bypass|may alter protected/i, override)
  end

  def test_planner_and_coordinator_surfaces_do_not_restore_overlap_ordering
    workflow = read("workflows/pr-processing.md")
    planner = read("skills/plan-pr-batch/SKILL.md")
    triage = read("skills/triage/SKILL.md")
    batch = read("skills/pr-batch/SKILL.md")
    guide = read("docs/pr-batch-skills.md")
    preflight = read("skills/plan-pr-batch/bin/batch-plan-preflight")

    assert_includes planner.gsub(/\s+/, " "), "do not infer or alter a semantic dependency from an overlap"
    assert_includes triage.gsub(/\s+/, " "), "file overlap is an integration advisory, not an inferred ordering edge"
    assert_includes batch, "File overlap is an integration advisory"
    assert_includes guide, "File\n   overlap is an integration advisory"
    assert_includes preflight, '"file-overlap-advisory"'
    refute_includes preflight, "serialized_by_edit_edge?"

    refute_includes triage, "file/risk disjointness"
    refute_includes triage, "Overlapping or `UNKNOWN` path lanes are sequenced"
    refute_includes workflow, "one disjoint lane per worker"
    refute_includes workflow, "Keep write scopes disjoint unless"
    refute_includes workflow, "file-collision\nordering"
    refute_includes workflow, "Build a dependency order from PR bodies, stacked branches, changed files, and review comments."
    refute_includes batch, "one disjoint lane per worker"
    refute_includes planner, "collision ordering"
    refute_includes guide, "Codex, Claude, generic, file-collision, or `UNKNOWN` path limits"
    refute_includes guide, "dependencies, collision ordering, or wave schedule"
  end
end
