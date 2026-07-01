#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
PLAN_PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/plan-pr-batch/SKILL.md")

TEXT_FENCE = "```text\n"

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def extract_goal_prompt_template(skill_text)
  heading_index = skill_text.index("## Goal Prompt for pr-batch")
  raise "missing Goal Prompt for pr-batch section" unless heading_index

  fence_start = skill_text.index(TEXT_FENCE, heading_index)
  raise "missing text fence in Goal Prompt section" unless fence_start

  fence_body_start = fence_start + TEXT_FENCE.length
  section_body = skill_text[fence_body_start..]
  fence_end = section_body.index(/^```\s*$/)
  raise "missing closing fence in Goal Prompt section" unless fence_end

  section_body[0...fence_end]
end

def assert_text_includes(text, phrase, label)
  assert text.include?(phrase), "#{label} is missing required phrase: #{phrase}"
end

class GoalCompletionContractTest < Minitest::Test
  def setup
    @workflow = read_repo_file(WORKFLOW_PATH)
    @pr_batch_skill = read_repo_file(PR_BATCH_SKILL_PATH)
    @plan_pr_batch_skill = read_repo_file(PLAN_PR_BATCH_SKILL_PATH)
    @plan_goal_prompt = extract_goal_prompt_template(@plan_pr_batch_skill)
  end

  def test_canonical_contract_is_present_in_workflow_and_goal_sources
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "Goal Mode Completion Contract", label
      assert_text_includes text, "waiting-on-checks-or-review` is not an overall Goal-mode terminal state", label
      assert_text_includes text, "report NOT COMPLETE", label
      assert_text_includes text, "pending, missing, or untriaged current-head CI", label
      assert_text_includes text, "unresolved current-head review threads", label
      assert_text_includes text, "UNKNOWN", label
    end
  end

  def test_pending_hosted_checks_pressure_scenario_is_not_complete
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "A batch with 5 PRs, 3 pending hosted checks, and clean review threads is NOT COMPLETE", label
    end
  end

  def test_ready_no_merge_authority_is_terminal_only_without_merge_authority
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "`ready-no-merge-authority` is terminal only when `merge_authority` does not allow merging", label
    end
  end

  def test_auto_merge_done_means_merged_or_blocked
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "With `auto_merge_when_gates_pass`, done means merged and closed out unless a real blocker prevents it", label
    end
  end

  def test_normal_restart_stays_pause_resume_not_cancel_relaunch
    assert_text_includes @workflow, "pause, not cancellation", "workflows/pr-processing.md"
    assert_text_includes @workflow, "do not use this pause flow; use", "workflows/pr-processing.md"
    assert_text_includes @workflow, "Cancelling Or Stopping A Batch", "workflows/pr-processing.md"
    assert_text_includes @pr_batch_skill, "Preserve claims and worktrees", "skills/pr-batch/SKILL.md"
    assert_text_includes @pr_batch_skill, "updated skills", "skills/pr-batch/SKILL.md"
    assert_text_includes @pr_batch_skill, "launching fresh workers", "skills/pr-batch/SKILL.md"
  end
end
