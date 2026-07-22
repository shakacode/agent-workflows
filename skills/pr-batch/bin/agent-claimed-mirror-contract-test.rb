#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

# An agent lane claim mirrors to a visible `agent-claimed` GitHub label so humans
# and other agents can see owned work, but the backend claim + heartbeat TTL stay
# the source of truth (labels go stale after restarts). Ownership is symmetric
# and decays: humans via the stale-assignment sweep, agents via heartbeat TTL.
APPLY_REMOVE_DAEMON = "apply it after a successful `agent-coord claim`, remove it when the claim is released, and " \
                      "let the coordination daemon remove it for claims that expire without a clean release."
HINT_NOT_LOCK = "it is a visible hint for people browsing GitHub, not the durable lock — the backend claim and " \
                "its heartbeat TTL remain the source of truth"
BACKEND_NA_SKIP = "Skip label mirroring entirely when `coordination_backend: n/a`"
OWNED_SYMMETRY = "Owned means skip is symmetric for humans and agents: a human assignee (see the assignee-aware " \
                 "batch selection and the stale-assignment sweep) or an `agent-claimed` label both mean skip, and " \
                 "both decay"
SWEEP_SKIPS_CLAIMED = "The stale-assignment sweep skips `agent-claimed` items"

class AgentClaimedMirrorContractTest < Minitest::Test
  def setup
    @workflow = read("workflows/pr-processing.md")
    @pr_batch = read("skills/pr-batch/SKILL.md")
  end

  def test_workflow_defines_the_agent_claimed_label_mirror_and_symmetry
    [APPLY_REMOVE_DAEMON, HINT_NOT_LOCK, BACKEND_NA_SKIP, OWNED_SYMMETRY, SWEEP_SKIPS_CLAIMED].each do |rule|
      assert_rule @workflow, rule
    end
  end

  def test_pr_batch_skill_mirrors_the_claim_to_a_label
    assert_includes @pr_batch, "agent-claimed"
    assert_rule @pr_batch, "apply after a successful claim, remove on release"
    assert_rule @pr_batch, "visible hint, not the durable lock"
  end

  private

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def assert_rule(text, rule)
    assert_includes text.gsub(/\s+/, " "), rule
  end
end
