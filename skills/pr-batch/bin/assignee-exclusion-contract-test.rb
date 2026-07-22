#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

# A human assignee reserves work: owned means skip. This invariant must be
# documented in the batch selection/triage skills and the docs that restate
# them, so assignee-aware exclusion is not silently dropped. "Automation" is
# defined via the existing trust config, not a new undefined term, and the
# assignee classification cannot rely on `no:assignee` alone.
OWNED_MEANS_SKIP = "a human assignee — any assignee outside the repo's resolved automation set — marks an issue or " \
                   "PR as reserved: owned means skip"
AUTOMATION_SET = "Resolve the automation set from the trust config's `trusted_bots` via the `pr-security-preflight` " \
                 "resolution chain, plus any assignee whose login carries the GitHub `[bot]` suffix; `trusted_users` " \
                 "are human actors and stay reservable. When the set cannot be resolved, treat any assignee as a " \
                 "human reservation and skip."
POST_FETCH_CLASSIFY = "Fetch the full scoped set and classify assignees after fetch — `no:assignee` alone omits " \
                      "automation-only-assigned items that stay eligible, so it is only a shortcut when the repo " \
                      "uses no automation self-assignment."

class AssigneeExclusionContractTest < Minitest::Test
  def setup
    @plan_pr_batch = read("skills/plan-pr-batch/SKILL.md")
    @triage = read("skills/triage/SKILL.md")
    @plan_issue_triage = read("skills/plan-issue-triage/SKILL.md")
    @docs_pr_batch = read("docs/pr-batch-skills.md")
    @docs_issue_eval = read("docs/issue-evaluation.md")
  end

  def test_selection_skills_and_docs_state_owned_means_skip
    [@plan_pr_batch, @triage, @plan_issue_triage, @docs_pr_batch, @docs_issue_eval].each do |text|
      assert_rule text, OWNED_MEANS_SKIP
    end
  end

  def test_batch_shaping_skills_define_automation_via_trust_config_and_classify_after_fetch
    [@plan_pr_batch, @triage].each do |text|
      assert_rule text, AUTOMATION_SET
      assert_rule text, POST_FETCH_CLASSIFY
    end
  end

  private

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def assert_rule(text, rule)
    assert_includes text.gsub(/\s+/, " "), rule
  end
end
