#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/check_goal_prompt_drift"

REPO_ROOT = File.expand_path("../../..", __dir__)
TEXT_FENCE = "```text\n"
EXPECTED_PROMPT = <<~TEXT
  Repository: OWNER/REPO
  Work item: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>
  Task name: <repository, work item, and purpose>
  Instruction: Use PR-batch to complete this work item against the repository's configured base branch.
  Merge authority: <auto|ask>
  Human available after: <optional time; omit this line when not supplied>
TEXT

def read_repo_file(path)
  File.read(File.join(REPO_ROOT, path), encoding: "UTF-8")
end

def extract_prompt(text, heading)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing #{heading}" unless heading_match

  fence_start = text.index(TEXT_FENCE, heading_match.end(0))
  raise "missing text fence after #{heading}" unless fence_start

  body_start = fence_start + TEXT_FENCE.length
  body_end = text.index(/^```[[:blank:]]*$/, body_start)
  raise "missing closing fence after #{heading}" unless body_end

  text[body_start...body_end]
end

def extract_markdown_section(text, heading)
  heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing #{heading}" unless heading_match

  body_start = heading_match.end(0)
  next_heading = text.match(/^###\s+/, body_start)
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

class ReadableGoalPromptContractTest < Minitest::Test
  def setup
    @plan_skill = read_repo_file("skills/plan-pr-batch/SKILL.md")
    @pr_batch_skill = read_repo_file("skills/pr-batch/SKILL.md")
    @workflow = read_repo_file("workflows/pr-processing.md")
    @triage_skill = read_repo_file("skills/triage/SKILL.md")
    @source_docs = read_repo_file("docs/pr-batch-skills.md")
    @run_record_docs = read_repo_file("docs/github-task-prompts-and-run-records.md")
    @batch_plan_preflight = read_repo_file("skills/plan-pr-batch/bin/batch-plan-preflight")

    workflow_handoff = extract_markdown_section(@workflow, "### Plan To Goal Handoff")
    @prompts = {
      "plan-pr-batch" => extract_prompt(@plan_skill, "## Goal Prompt for pr-batch"),
      "pr-batch" => extract_prompt(@pr_batch_skill, "## Goal Prompt Template"),
      "workflow" => workflow_handoff.split("### ", 2).first.then { |text| extract_prompt("## Prompt\n\n#{text}", "## Prompt") }
    }
  end

  def test_source_host_cap_drift_rejects_an_in_memory_mutation
    surfaces = {
      "workflows/pr-processing.md" => @workflow,
      "skills/plan-pr-batch/SKILL.md" => @plan_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill,
      "docs/pr-batch-skills.md" => @source_docs
    }
    GoalPromptDriftContract.check_host_caps!(surfaces)

    mutated = surfaces.transform_values(&:dup)
    mutated.fetch("workflows/pr-processing.md").sub!(
      "`codex`: up to 10 independent items, or 8",
      "`codex`: up to 11 independent items, or 8"
    )

    error = assert_raises(RuntimeError) do
      GoalPromptDriftContract.check_host_caps!(mutated)
    end
    assert_includes error.message, "expected 10/8, found 11/8"
  end

  def test_security_pin_drift_rejects_an_in_memory_mutation
    surfaces = {
      "workflows/pr-processing.md" => @workflow,
      "skills/plan-pr-batch/SKILL.md" => @plan_skill,
      "skills/pr-batch/SKILL.md" => @pr_batch_skill,
      "skills/triage/SKILL.md" => @triage_skill
    }
    GoalPromptDriftContract.check_security_pins!(surfaces:, batch_plan_preflight: @batch_plan_preflight)

    mutated = surfaces.transform_values(&:dup)
    mutated.fetch("skills/pr-batch/SKILL.md").sub!(
      "When search finds no canonical issue or existing PR",
      "When no canonical issue or existing PR is found"
    )

    error = assert_raises(RuntimeError) do
      GoalPromptDriftContract.check_security_pins!(surfaces: mutated, batch_plan_preflight: @batch_plan_preflight)
    end
    assert_includes error.message, "canonical issue creation count is 0, expected 1"
  end

  def test_all_canonical_surfaces_share_one_readable_prompt
    assert_equal 1, @prompts.values.uniq.length
    assert_equal EXPECTED_PROMPT, @prompts.values.first

    @prompts.each do |label, prompt|
      [
        "Digest", "digest", "Selected", "Timestamp", "timestamp", "Observed", "observed",
        "Workflow", "workflow", "Coordination", "coordination", "Lane Card", "Manifest",
        "Dispatch", "Scope", "ft=", "GMCC-v4"
      ].each do |legacy_fragment|
        refute_includes prompt, legacy_fragment, "#{label} leaked #{legacy_fragment}"
      end
      refute_includes prompt, "none", "#{label} leaked machine-only merge authority"
    end
  end

  def test_generation_rules_make_one_trusted_source_authoritative
    [@plan_skill, @pr_batch_skill, @workflow, @triage_skill].each do |text|
      normalized = text.gsub(/\s+/, " ")
      assert_includes normalized, "Fix issue #123 using $pr-batch with merge authority ask."
      assert_includes normalized, "accepted canonical issue or pull-request body"
      assert_includes normalized, "later trusted maintainer comment"
      assert_includes normalized, "Do not synthesize"
      assert_includes normalized, "same readable prompt vocabulary for every host"
      assert_includes normalized, "outside the human-authored prompt"
    end
  end

  def test_source_docs_preserve_complete_handoff_and_digest_integrity
    normalized = @source_docs.gsub(/\s+/, " ")
    [
      "Prompt digest at selection",
      "exact GitHub API `body` string",
      "without Unicode normalization, Markdown rendering, whitespace trimming, or newline insertion or removal",
      "If the selection and launch digests differ, that dispatch stops",
      "deliberately reselected as a new run and the security preflight is rerun",
      "one compact collapsed run record with one entry per target lane",
      "directly appends `Launched at` plus `Prompt digest at launch`",
      "verifies both identity and digest before it interprets the source",
      "complete Batch Plan for that coordinator group or an exact durable plan-state reference",
      "multi-target group remains one coordinator launch with one target per worker lane"
    ].each { |phrase| assert_includes normalized, phrase }
  end

  def test_launcher_record_owns_launch_provenance_and_append_only_observations
    launcher_contract = @run_record_docs[/^## Launcher composition boundary\n.*?(?=^## )/m]
    compact_record = @run_record_docs[/^## Compact record\n.*?(?=^## )/m]
    refute_nil launcher_contract
    refute_nil compact_record

    [
      "<!-- agent-launcher-run-record:v1 -->",
      "Run ID:",
      "Launch retry key:",
      "Record destination:",
      "Prompt created at:",
      "Model at prompt creation:",
      "Workflow at prompt creation",
      "Later workflow observations:",
      "Target lanes:",
      "Lane:",
      "Target:",
      "Replay identity:",
      "Prompt source:",
      "Selected at:",
      "Prompt digest at selection:",
      "Launched at:",
      "Prompt digest at launch:",
      "Worker started at:",
      "Prompt digest observed by worker:",
      "Model observed by worker:",
      "Workflow observed at worker start"
    ].each { |field| assert_includes compact_record, field }

    normalized = launcher_contract.gsub(/\s+/, " ")
    assert_includes normalized, "one unique entry per planned lane"
    assert_includes normalized, "never substitutes for `run_id`"
    assert_includes normalized, "never independently published"
    assert_includes normalized, "does not inject outer identity, destination, or replay values into the helper"
    assert_includes normalized, "not applicable — trusted-ad-hoc-override"
    assert_includes normalized, "No outer dynamic value may create a Markdown link, HTML element, or active URI"

    [@pr_batch_skill, @workflow].each do |surface|
      heading = surface.equal?(@workflow) ? "### Launcher Run Record" : "## Launcher Run Record"
      router = surface[/^#{Regexp.escape(heading)}\n.*?(?=^(?:##|###) |\z)/m]
      refute_nil router
      assert_includes router, "docs/github-task-prompts-and-run-records.md"
      assert_includes router, "agent-run-record"
      assert_match(/source and\s+digest evidence/m, router)
      assert_match(/never inject.*through the helper/m, router)
      assert_match(/trusted-ad-hoc-override.*bypass|bypass.*trusted-ad-hoc-override/m, router)
    end
  end
end
