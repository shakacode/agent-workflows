#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
COMPONENT_PATH = File.join(ROOT, "workflows/pr-batch-worker-execution.md")
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")

def section(text, heading, next_heading)
  match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing section #{heading}" unless match

  finish = text.match(next_heading, match.end(0))
  text[match.end(0)...(finish ? finish.begin(0) : text.length)]
end

def squish(text)
  text.gsub(/\s+/, " ").strip
end

class WorkerExecutionContractTest < Minitest::Test
  def setup
    @component = File.read(COMPONENT_PATH, encoding: "UTF-8")
    @workflow = File.read(WORKFLOW_PATH, encoding: "UTF-8")
    @skill = File.read(SKILL_PATH, encoding: "UTF-8")
  end

  def test_component_has_one_bounded_execution_interface
    [
      "Boundary",
      "Input Contract",
      "Isolated Setup",
      "Implementation Loop",
      "Path Expansion",
      "Focused Validation",
      "Meaningful Stops And Human Attention",
      "Worker-To-Coordinator Handoff"
    ].each do |heading|
      assert_match(/^## #{Regexp.escape(heading)}$/, @component, heading)
    end

    assert_operator @component.bytesize, :<=, 11_000,
                    "worker execution must stay smaller than the duplicated source blocks it replaces"
    assert_includes @component, "It emits a committed implementation head and replayable evidence."
    assert_includes @component, "worker-execution-handoff v1"
  end

  def test_workflow_and_skill_are_routes_not_mirrors
    routes = {
      "workflow" => squish(section(@workflow, "### Worker Rules", /^###\s+/)),
      "pr-batch skill" => squish(section(@skill, "## Worker Rules", /^##\s+/))
    }

    routes.each do |label, route|
      assert_equal 1, route.scan("pr-batch-worker-execution.md").length, label
      assert_includes route, "focused validation", label
      assert_includes route, "implementation-head handoff", label
      refute_includes route, "git worktree add", "#{label} mirrors isolated setup"
      refute_includes route, "worker-execution-handoff v1", "#{label} mirrors the output schema"
      assert_operator route.bytesize, :<, 1_200, "#{label} is no longer a thin route"
    end
  end

  def test_isolation_and_dependency_permissions_fail_closed
    setup = squish(section(@component, "## Isolated Setup", /^##\s+/))

    assert_includes setup, "one target or one semantic lane"
    assert_includes setup, "git worktree add"
    assert_includes setup, "`isolation: 'worktree'`"
    assert_includes setup, "Pending `edit` remains read-only"
    assert_includes setup, "Pending `validation_open` permits only"
    assert_includes setup, "Pending `merge_order` does not restrict implementation"
    assert_includes setup, "missing or `UNKNOWN` stops the lane"
    assert_includes setup, "holder/generation/instance"
    assert_includes setup, "claim-only execution"
  end

  def test_expansion_preserves_reservation_and_resume_gates
    expansion = squish(section(@component, "## Path Expansion", /^##\s+/))

    %w[
      expansion-path-reservation
      batch-plan-preflight
      launch.held_lane_ids
      launch.eligible_lane_ids
      expansion-rename-reservation
      blocked-user-input
    ].each { |term| assert_includes expansion, term }
    assert_includes expansion, "Owned paths are coordination controls"
  end

  def test_loop_and_focused_validation_do_not_claim_closeout
    loop_contract = squish(section(@component, "## Implementation Loop", /^##\s+/))
    validation = squish(section(@component, "## Focused Validation", /^##\s+/))

    assert_includes loop_contract, "smallest cohesive change"
    assert_includes loop_contract, "edit/check/self-review cycle"
    assert_includes loop_contract, "Never weaken verification"
    assert_includes loop_contract, "exact full implementation"
    assert_includes loop_contract, "MODEL_ESCALATION_REQUEST"
    assert_includes validation, ".agents/bin/*"
    assert_includes validation, "exact command, exit"
    assert_includes validation, "It is not final"
    assert_includes validation, "integration/PR-closeout"
  end

  def test_only_meaningful_attention_stops_execution
    attention = squish(section(@component, "## Meaningful Stops And Human Attention", /^##\s+/))

    assert_includes attention, "reversible best judgment"
    assert_includes attention, "worker-attention v1"
    assert_includes attention, "`permission`, otherwise `question`, otherwise"
    assert_includes attention, "one exact decision or action required"
    assert_includes attention, "Do not ask merely"
    assert_includes attention, "verification would be weakened"
  end

  def test_handoff_binds_head_evidence_and_non_ownership
    handoff = squish(section(@component, "## Worker-To-Coordinator Handoff", /^##\s+/))

    %w[
      dashboard_url
      pr_url
      holder|UNKNOWN
      generation|UNKNOWN
      instance|UNKNOWN
      worker-execution-handoff
    ].each { |term| assert_includes handoff, term }
    assert_includes handoff, "full implementation"
    assert_includes handoff, "focused validation commands/results"
    assert_includes handoff, "clean committed implementation"
    assert_includes handoff, "override_name"
    assert_includes handoff, "trusted_authorizer"
    assert_includes handoff, "never claims final readiness"
    assert_includes handoff, "never carries the batch archive-readiness status"
  end
end
