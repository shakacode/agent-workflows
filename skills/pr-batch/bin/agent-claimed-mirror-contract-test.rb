#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

# Selection/triage must exclude an agent-claimed item, closing the loop so the
# mirrored label is actually respected as an ownership marker. The check goes
# through the seam label, not a hardcoded name, so a renamed consumer label works.
SELECTION_SKIP = "Also skip any issue or PR labeled with the seam's claim label (`agent_claimed_label`, default " \
                 "`agent-claimed`) — an active agent lane claim — and list it as reserved; owned means skip for " \
                 "agents as for humans."

class AgentClaimedMirrorContractTest < Minitest::Test
  def setup
    @workflow = read("workflows/pr-processing.md")
    @pr_batch = read("skills/pr-batch/SKILL.md")
    @component = read("workflows/pr-batch-coordination-observability.md")
    @backend_doc = read("docs/coordination-backend.md")
    @seam = read(".agents/agent-workflow.yml")
    @selection = {
      "plan-pr-batch" => read("skills/plan-pr-batch/SKILL.md"),
      "triage" => read("skills/triage/SKILL.md"),
      "plan-issue-triage" => read("skills/plan-issue-triage/SKILL.md"),
      "docs/pr-batch-skills.md" => read("docs/pr-batch-skills.md"),
      "docs/issue-evaluation.md" => read("docs/issue-evaluation.md")
    }
  end

  def test_workflow_defines_the_claim_label_mirror_and_symmetry
    assert_includes @component, "`agent_claimed_label` (default\n   `agent-claimed`)"
    assert_rule @component, "After claim, mirror"
    assert_rule @component, "visible hint, not the lock"
    assert_rule @component, "only after verifying the same holder/generation"
    assert_rule @component, "does not call a backend, post public claim comments, or mirror a claim label"
    assert_rule @backend_doc,
                "plus a daemon backstop that removes the label for claims whose heartbeat lease expires without a clean release."
    assert_rule @backend_doc, "The label is a visible hint, not the lock"
    assert_includes @workflow, "pr-batch-coordination-observability.md"
  end

  def test_claim_label_is_seam_configurable
    assert_includes @seam, "agent_claimed_label:"
  end

  def test_pr_batch_skill_mirrors_the_claim_to_a_label
    assert_includes @pr_batch, "pr-batch-coordination-observability.md"
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
