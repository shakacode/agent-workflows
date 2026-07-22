#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

# An agent lane claim mirrors to a visible claim label (the seam's
# `agent_claimed_label`, default `agent-claimed`) so humans and other agents can
# see owned work, but the backend claim + heartbeat TTL stay the source of truth
# (labels go stale after restarts). Ownership is symmetric and decays: humans via
# the stale-assignment sweep, agents via heartbeat TTL. Selection and triage must
# skip agent-claimed items, or the label would be applied but never respected.
SEAM_LABEL = "the seam's claim\n  label (`agent_claimed_label`, default `agent-claimed`)".gsub(/\s+/, " ")
APPLY_REMOVE_DAEMON = "apply it after a successful `agent-coord claim`, remove it when the claim is released, and " \
                      "let the coordination daemon remove it for claims that expire without a clean release."
HINT_NOT_LOCK = "it is a visible hint for people browsing GitHub, not the durable lock — the backend claim and " \
                "its heartbeat TTL remain the source of truth"
BACKEND_NA_SKIP = "Skip label mirroring entirely when `coordination_backend: n/a`"
OWNED_SYMMETRY = "Owned means skip is symmetric for humans and agents: a human assignee (see the assignee-aware " \
                 "batch selection and the stale-assignment sweep) or an `agent-claimed` label both mean skip, and " \
                 "both decay"
SWEEP_SKIPS_CLAIMED = "The stale-assignment sweep skips `agent-claimed` items"
# Selection/triage must exclude an agent-claimed item, closing the loop so the
# mirrored label is actually respected as an ownership marker.
SELECTION_SKIP = "Also skip any issue or PR carrying the seam's `agent-claimed` label (an active agent lane " \
                 "claim), listing it as reserved — owned means skip for agents as for humans."

class AgentClaimedMirrorContractTest < Minitest::Test
  def setup
    @workflow = read("workflows/pr-processing.md")
    @pr_batch = read("skills/pr-batch/SKILL.md")
    @seam = read(".agents/agent-workflow.yml")
    @selection = {
      "plan-pr-batch" => read("skills/plan-pr-batch/SKILL.md"),
      "triage" => read("skills/triage/SKILL.md"),
      "plan-issue-triage" => read("skills/plan-issue-triage/SKILL.md")
    }
  end

  def test_workflow_defines_the_claim_label_mirror_and_symmetry
    [SEAM_LABEL, APPLY_REMOVE_DAEMON, HINT_NOT_LOCK, BACKEND_NA_SKIP, OWNED_SYMMETRY, SWEEP_SKIPS_CLAIMED].each do |rule|
      assert_rule @workflow, rule
    end
  end

  def test_claim_label_is_seam_configurable
    assert_includes @seam, "agent_claimed_label:"
  end

  def test_pr_batch_skill_mirrors_the_claim_to_a_label
    assert_includes @pr_batch, "agent-claimed"
    assert_rule @pr_batch, "apply on claim, remove on release"
    assert_rule @pr_batch, "hint not lock"
  end

  def test_selection_and_triage_skip_agent_claimed_items
    @selection.each do |name, text|
      assert_rule text, SELECTION_SKIP, "#{name} must skip agent-claimed items in selection"
    end
  end

  private

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def assert_rule(text, rule, message = nil)
    assert_includes text.gsub(/\s+/, " "), rule, message
  end
end
