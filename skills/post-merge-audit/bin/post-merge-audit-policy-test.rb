#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

class PostMergeAuditPolicyTest < Minitest::Test
  REQUIRED_DEFAULT = "Create follow-up issues by default unless the user explicitly asks for report-only or no issue creation."
  REQUIRED_LEDGER_COMMENT_EXCEPTION = "Do not create unrelated comments; the release-gate ledger append is allowed when required before issue creation."
  REQUIRED_COMPARISON_HANDOFF = "Do not create issues directly from this comparison prompt; continue with the Default Issue Creation Prompt below to apply duplicate-search, release-gate ledger, and label rules."

  REQUIRED_FILES = [
    "skills/post-merge-audit/SKILL.md",
    "workflows/post-merge-audit.md",
    "workflows/pr-processing.md"
  ].freeze

  OBSOLETE_APPROVAL_GATES = [
    "Create GitHub issues only after the user approves the deduped issue plan.",
    "The audit should usually produce an issue plan for non-OK findings, but not create issues until approval.",
    "Do not create fixes, comments, labels, issues, changelog edits, reverts, or PRs until the user approves the audit report.",
    "Do not create fixes, issues, comments, labels, changelog edits, reverts, or PRs until the user approves the audit report and issue plan.",
    "Use only after the user approves the deduped issue plan.",
    "approved coordinator action",
    "any issue from the approved plan that could not be created"
  ].freeze

  def test_post_merge_audit_defaults_to_follow_up_issue_creation
    REQUIRED_FILES.each do |relative_path|
      text = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")

      assert_includes text, REQUIRED_DEFAULT, "#{relative_path} should state the default issue-creation behavior"
      OBSOLETE_APPROVAL_GATES.each do |obsolete|
        refute_includes text, obsolete, "#{relative_path} still has obsolete approval-gated issue creation text"
      end
    end
  end

  def test_release_gate_ledger_append_is_not_blocked_by_comment_ban
    [
      "skills/post-merge-audit/SKILL.md",
      "workflows/pr-processing.md"
    ].each do |relative_path|
      text = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")
      normalized_text = text.gsub(/\s+/, " ")

      assert_includes normalized_text, REQUIRED_LEDGER_COMMENT_EXCEPTION
    end
  end

  def test_comparison_prompt_hands_off_to_guarded_issue_creation
    text = File.read(File.join(ROOT, "workflows/post-merge-audit.md"), encoding: "UTF-8")
    normalized_text = text.gsub(/\s+/, " ")

    assert_includes normalized_text, REQUIRED_COMPARISON_HANDOFF
  end
end
