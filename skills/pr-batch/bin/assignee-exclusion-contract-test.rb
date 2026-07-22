#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

# A human assignee reserves work: owned means skip. This invariant must be
# documented in the batch selection/triage skills and the docs that restate
# them, so assignee-aware exclusion is not silently dropped.
OWNED_MEANS_SKIP = "a human assignee (any assignee that is not the repo's automation identity) marks an issue or " \
                   "PR as reserved: owned means skip"
RESERVED_LISTING = "Use `no:assignee` in `gh` search filters where possible, otherwise filter after fetch, and list " \
                   "each excluded item as reserved with its assignee name; never silently drop reserved work."

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

  def test_batch_shaping_skills_require_reserved_listing_without_silent_drops
    [@plan_pr_batch, @triage].each do |text|
      assert_rule text, RESERVED_LISTING
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
