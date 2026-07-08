#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
SPEC_SKILL_PATH = File.join(ROOT, "skills/spec/SKILL.md")
PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
PLAN_PR_BATCH_SKILL_PATH = File.join(ROOT, "skills/plan-pr-batch/SKILL.md")
TRIAGE_SKILL_PATH = File.join(ROOT, "skills/triage/SKILL.md")

TEXT_FENCE = "```text\n"
CANONICAL_CONTRACT_LINK = "../../workflows/pr-processing.md#goal-mode-completion-contract"
CANONICAL_READINESS_LINK = "../../workflows/pr-processing.md#batch-handoff-format"
PENDING_CHECKS_PRESSURE = "A batch with 5 PRs, 3 pending hosted checks, and clean review threads is NOT COMPLETE"
BATCH_TITLE_LINE = "Batch title: <PROJECT> <A?> <MM-DD HH:MM> - <short title>."
PLAN_PR_BATCH_CODEX_GOAL_LINE = "/goal\n"
PLAN_PR_BATCH_INVOCATION_LINE = "Use $pr-batch to complete this batch with subagents.\n"
BATCH_TITLE_PLACEHOLDER = "<PROJECT> <A?> <MM-DD HH:MM> - <short title>"
DATE_COMMAND = "date +'%m-%d %H:%M'"
CANONICAL_READINESS_STATES = %w[
  merged
  ready-gates-clean
  ready-no-merge-authority
  waiting-on-checks-or-review
  external-gate-failing
  blocked-user-input
  no-pr-evidence
].freeze
READINESS_STATE_KEYS = /\b(?:final_state|readiness_state|target_state):\s*`?([A-Za-z0-9_-]+)`?/

def read_repo_file(path)
  File.read(path, encoding: "UTF-8")
end

def extract_goal_prompt_template(skill_text, heading, end_heading: /^##\s+/)
  heading_index = skill_text.index(heading)
  raise "missing #{heading} section" unless heading_index

  fence_start = skill_text.index(TEXT_FENCE, heading_index)
  raise "missing text fence in Goal Prompt section" unless fence_start

  fence_body_start = fence_start + TEXT_FENCE.length
  next_heading = skill_text.match(end_heading, fence_body_start)
  section_end = next_heading ? next_heading.begin(0) : skill_text.length
  section_body = skill_text[fence_body_start...section_end]
  fence_offsets = []
  section_body.scan(/^```\s*$/) { fence_offsets << Regexp.last_match.begin(0) }

  raise "missing closing fence in Goal Prompt section" if fence_offsets.empty?
  if fence_offsets.length > 1
    raise "goal prompt template contains a nested bare fence line; use a non-text fence type instead"
  end

  section_body[0...fence_offsets.first]
end

def extract_markdown_section(text, heading, end_heading: /^###\s+/)
  heading_index = text.index(heading)
  raise "missing #{heading} section" unless heading_index

  body_start = heading_index + heading.length
  next_heading = text.match(end_heading, body_start)
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

def contract_line(text)
  text.lines.grep(/^Goal Mode Completion Contract:/).first&.chomp
end

def assert_text_includes(text, phrase, label)
  assert text.include?(phrase), "#{label} is missing required phrase: #{phrase}"
end

def invalid_readiness_marker_values(text)
  allowed = CANONICAL_READINESS_STATES + ["UNKNOWN"]
  text.scan(READINESS_STATE_KEYS).flatten.reject { |value| allowed.include?(value) }.uniq
end

class GoalCompletionContractTest < Minitest::Test
  def setup
    @workflow = read_repo_file(WORKFLOW_PATH)
    @spec_skill = read_repo_file(SPEC_SKILL_PATH)
    @pr_batch_skill = read_repo_file(PR_BATCH_SKILL_PATH)
    @plan_pr_batch_skill = read_repo_file(PLAN_PR_BATCH_SKILL_PATH)
    @triage_skill = read_repo_file(TRIAGE_SKILL_PATH)
    @workflow_contract_section = extract_markdown_section(@workflow, "### Goal Mode Completion Contract")
    @workflow_goal_prompt = extract_goal_prompt_template(
      @workflow,
      "### Plan To Goal Handoff",
      end_heading: /^###\s+/
    )
    @pr_batch_goal_prompt = extract_goal_prompt_template(@pr_batch_skill, "## Goal Prompt Template")
    @plan_goal_prompt = extract_goal_prompt_template(@plan_pr_batch_skill, "## Goal Prompt for pr-batch")
  end

  def test_canonical_contract_is_present_in_workflow_and_goal_sources
    {
      "workflows/pr-processing.md canonical contract" => @workflow_contract_section,
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
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

  def test_goal_prompts_include_thread_handle_and_registration_contract
    prompts = {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }
    registration_patterns = {
      "workflows/pr-processing.md goal prompt" => /register batch metadata before launch when supported/i,
      "skills/pr-batch goal prompt" => /register batch\s+metadata before launch when supported/i,
      "skills/plan-pr-batch goal prompt" => /register before launch when supported/i
    }

    prompts.each do |label, text|
      assert_text_includes text, "Thread handle: <batch-short>-<lane>-<word>", label
      assert_match registration_patterns.fetch(label), text, "#{label} is missing registration language"
      assert_text_includes text, "holder/generation", label
      assert_text_includes text, "UNKNOWN", label
    end
  end

  def test_thread_handle_derivation_guidance_is_documented
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, "first worker-specific line", label
      assert_text_includes text, "<batch-short>", label
      assert_text_includes text, "<lane>", label
      assert_text_includes text, "coordinator-chosen session word", label
    end
  end

  def test_lane_card_contract_is_documented
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, "Lane Card", label
      assert_text_includes text, "after a successful claim", label
      assert_text_includes text, "when the PR is opened", label
      assert_text_includes text, "holder", label
      assert_text_includes text, "dashboard_url", label
      assert_text_includes text, "pr_url", label
    end

    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "Lane Card:", label
      assert_text_includes text, "holder", label
      assert_text_includes text, "PR-open", label
      assert_text_includes text, "UNKNOWN", label
    end
  end

  def test_workflow_defines_canonical_readiness_vocabulary
    workflow_text = extract_markdown_section(@workflow, "### Batch Handoff Format", end_heading: /^###\s+/)
    CANONICAL_READINESS_STATES.each do |state|
      assert_text_includes workflow_text, "`#{state}`", "workflows/pr-processing.md"
    end
    assert_text_includes workflow_text, "UNKNOWN", "workflows/pr-processing.md"
  end

  def test_planning_skills_link_to_canonical_readiness_vocabulary
    {
      "skills/spec/SKILL.md" => extract_markdown_section(@spec_skill, "## Canonical Readiness Vocabulary", end_heading: /^##\s+/),
      "skills/plan-pr-batch/SKILL.md" => extract_markdown_section(@plan_pr_batch_skill, "## Canonical Readiness Vocabulary", end_heading: /^##\s+/),
      "skills/pr-batch/SKILL.md" => extract_markdown_section(@pr_batch_skill, "## Canonical Readiness Vocabulary", end_heading: /^##\s+/)
    }.each do |label, text|
      assert_text_includes text, CANONICAL_READINESS_LINK, label
      assert_text_includes text, "UNKNOWN", label
      assert_text_includes text, "JSON is not mandatory", label
    end
  end

  def test_structured_readiness_markers_use_canonical_values
    skill_text = {
      "skills/spec/SKILL.md" => @spec_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill
    }

    skill_text.each do |label, text|
      invalid_values = invalid_readiness_marker_values(text)
      assert_empty invalid_values, "#{label} contains invalid structured readiness values: #{invalid_values.join(', ')}"
    end
  end

  def test_structured_readiness_marker_validation_rejects_vague_ready
    invalid_values = invalid_readiness_marker_values("final_state: ready\nreadiness_state: `UNKNOWN`\ntarget_state: Unknown\n")
    assert_equal %w[ready Unknown], invalid_values
  end

  def test_skill_prose_points_to_canonical_contract_instead_of_pasting_it
    assert_text_includes @pr_batch_skill, CANONICAL_CONTRACT_LINK, "skills/pr-batch/SKILL.md"
    assert_equal 1, @pr_batch_skill.scan(PENDING_CHECKS_PRESSURE).length,
                 "skills/pr-batch/SKILL.md should keep the detailed pressure scenario only in the dispatch prompt"
  end

  def test_canonical_and_dispatch_prompt_contracts_stay_byte_for_byte_aligned
    workflow_contract = contract_line(@workflow_contract_section)
    workflow_goal_contract = contract_line(@workflow_goal_prompt)
    pr_batch_contract = @pr_batch_goal_prompt.lines.grep(/^Goal Mode Completion Contract:/).first
    plan_contract = @plan_goal_prompt.lines.grep(/^Goal Mode Completion Contract:/).first

    refute_nil workflow_contract, "workflows/pr-processing.md is missing the canonical contract line"
    refute_nil workflow_goal_contract, "workflows/pr-processing.md goal prompt is missing the contract line"
    refute_nil pr_batch_contract, "skills/pr-batch goal prompt is missing the contract line"
    refute_nil plan_contract, "skills/plan-pr-batch goal prompt is missing the contract line"
    assert_equal workflow_contract, workflow_goal_contract
    assert_equal workflow_contract, pr_batch_contract.chomp
    assert_equal workflow_contract, plan_contract.chomp
  end

  def test_goal_prompt_extractor_rejects_nested_bare_fence_lines
    skill_text = <<~TEXT
      ## Goal Prompt Template

      ```text
      Use $pr-batch.
      ```
      stray prose
      ```

      ## Next Section
    TEXT

    error = assert_raises(RuntimeError) { extract_goal_prompt_template(skill_text, "## Goal Prompt Template") }
    assert_match(/nested bare fence/, error.message)
  end

  def test_pending_hosted_checks_pressure_scenario_is_not_complete
    {
      "workflows/pr-processing.md" => @workflow,
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, PENDING_CHECKS_PRESSURE, label
    end
  end

  def test_goal_prompts_put_batch_title_after_target_invocation
    {
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt
    }.each do |label, text|
      assert text.start_with?("#{BATCH_TITLE_LINE}\n"),
             "#{label} must put the standard batch title line at the target-specific start"
    end

    assert @plan_goal_prompt.start_with?("#{PLAN_PR_BATCH_INVOCATION_LINE}#{BATCH_TITLE_LINE}\n"),
           "skills/plan-pr-batch shared goal prompt must put the standard batch title line after the invocation"

    codex_goal_prompt = "#{PLAN_PR_BATCH_CODEX_GOAL_LINE}#{@plan_goal_prompt}"
    assert codex_goal_prompt.start_with?("#{PLAN_PR_BATCH_CODEX_GOAL_LINE}#{PLAN_PR_BATCH_INVOCATION_LINE}#{BATCH_TITLE_LINE}\n"),
           "skills/plan-pr-batch Codex goal prompt must put the standard batch title line after the Codex prefix"
  end

  def test_batch_title_instructions_pin_local_date_source
    {
      "workflows/pr-processing.md" => @workflow,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, DATE_COMMAND, label
    end
  end

  def test_batch_title_skill_rules_use_canonical_placeholder
    {
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/plan-pr-batch/SKILL.md" => @plan_pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }.each do |label, text|
      assert_text_includes text, BATCH_TITLE_PLACEHOLDER, label
      refute_includes text, "<PROJECT> <A/B/C when multiple> <MM-DD HH:MM> - <descriptive title>",
                      "#{label} should not use the old batch title placeholder"
    end
  end

  def test_ready_no_merge_authority_is_terminal_only_without_merge_authority
    {
      "workflows/pr-processing.md" => @workflow,
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
      "skills/plan-pr-batch goal prompt" => @plan_goal_prompt
    }.each do |label, text|
      assert_text_includes text, "`ready-no-merge-authority` is terminal only when `merge_authority` does not allow merging", label
    end
  end

  def test_auto_merge_done_means_merged_or_blocked
    {
      "workflows/pr-processing.md" => @workflow,
      "workflows/pr-processing.md goal prompt" => @workflow_goal_prompt,
      "skills/pr-batch goal prompt" => @pr_batch_goal_prompt,
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
