#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

PR_BODY_CONTRACT_ROOT = File.expand_path("../../..", __dir__)
PR_BODY_CONTRACT_WORKFLOW_PATH = File.join(PR_BODY_CONTRACT_ROOT, "workflows/pr-processing.md")
PR_BODY_CONTRACT_PR_BATCH_SKILL_PATH = File.join(PR_BODY_CONTRACT_ROOT, "skills/pr-batch/SKILL.md")
PR_BODY_CONTRACT_AUDIT_RECEIPT_PATH = File.join(PR_BODY_CONTRACT_ROOT, "skills/post-merge-audit/bin/completed-batch-audit-receipt")

class PrBodyHumanFirstContractTest < Minitest::Test
  def test_canonical_pr_body_keeps_human_context_visible_and_collapses_agent_evidence_once
    workflow = File.read(PR_BODY_CONTRACT_WORKFLOW_PATH, encoding: "UTF-8")
    pr_batch_skill = File.read(PR_BODY_CONTRACT_PR_BATCH_SKILL_PATH, encoding: "UTF-8")
    audit_receipt = File.read(PR_BODY_CONTRACT_AUDIT_RECEIPT_PATH, encoding: "UTF-8")
    normalized_workflow = workflow.gsub(/\s+/, " ")

    assert_includes workflow, "### Human-First PR Description Contract"
    assert_includes workflow, "Only a PR body uses the [Human-First PR Description Contract]"
    assert_includes normalized_workflow, "This layout is a default, not a replacement"
    assert_includes normalized_workflow, "Merge every repository-required PR template section and AGENTS.md seam"
    assert_includes normalized_workflow, "Keep required human-visible sections and checklists outside `Agent details`"
    contract = workflow.split("### Human-First PR Description Contract", 2).last
    template = contract.match(/```markdown\n(.*?)\n```/m)[1]

    ["Why", "What changed", "How to review and verify"].each do |heading|
      assert_includes template, "## #{heading}"
    end
    refute_includes template, "## Maintainer attention"
    assert_includes template, "<details>\n<summary>Agent details</summary>"
    assert_equal 1, template.scan("<details>").length
    assert_equal 1, template.scan("</details>").length
    assert_includes workflow, "Human-authored product or design detail may use its own"
    assert_includes workflow, "Include `## Maintainer attention` before"
    assert_includes workflow, "do not add a `None.` placeholder"
    assert_includes normalized_workflow, "When the evidence destination is a PR description"
    assert_includes normalized_workflow, "In a handoff, issue comment, or saved evidence file"

    ["### Commands and results", "### Exact-head and replay evidence",
     "### Coordination and reviewer telemetry", "### Decision log",
     "### Merge confidence", "### Audit receipts", "<!-- qa-evidence v2",
     "<!-- priority-finding-dispositions v1"].each do |agent_detail|
      assert_includes template, agent_detail
    end
    refute_match(/^### QA Evidence$/, template)
    assert_includes template, "Insert the complete canonical `### QA Evidence` block"

    assert_includes pr_batch_skill, "Human-First PR Description Contract"
    assert_includes template, "Insert the helper-managed `#### Completed-batch audit` section here."
    assert_includes pr_batch_skill, "under `### Audit receipts`"
    assert_includes audit_receipt, "#### Completed-batch audit"
    refute_match(/^### Completed-batch audit$/, audit_receipt)
  end
end
