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
    @prompt_intake = read_repo_file("workflows/pr-batch-intake.md")
    @triage_skill = read_repo_file("skills/triage/SKILL.md")
    @source_docs = read_repo_file("docs/pr-batch-skills.md")
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
      "workflows/pr-batch-intake.md" => @prompt_intake,
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
      "skills/triage/SKILL.md" => @triage_skill,
      "workflows/pr-batch-intake.md" => @prompt_intake
    }
    GoalPromptDriftContract.check_security_pins!(surfaces:, batch_plan_preflight: @batch_plan_preflight)

    mutated = surfaces.transform_values(&:dup)
    mutated.fetch("workflows/pr-batch-intake.md").sub!(
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
      "successful security-preflight source URL, `body` field, and SHA-256 snapshot",
      "verifies identity and digest before it interprets the source",
      "`batch_plan_binding`",
      "workers never race GitHub read-modify-write updates",
      "split the trust boundaries into separate runs",
      "complete Batch Plan for that coordinator group or an exact durable plan-state reference",
      "multi-target group remains one coordinator launch with one target per worker lane"
    ].each { |phrase| assert_includes normalized, phrase }
  end

  def test_launcher_record_owns_launch_provenance_and_append_only_observations
    launcher_record = extract_markdown_section(@workflow, "### Launcher Run Record")

    [
      "Run ID: <immutable unique per-execution run_id>",
      "Record destination: <exact issue or pull-request work-item URL authorized for every lane, or existing durable plan/backend destination authorized for every lane>",
      "Batch Plan binding: <SHA-256 of exact delivered UTF-8 plan bytes, or immutable reference plus exact revision/content digest>",
      "Prompt created at: <timestamp>",
      "Model at prompt creation: <observed value or UNKNOWN>",
      "Workflow at prompt creation: <version or UNKNOWN>",
      "Later workflow observations: <timestamped append-only entries or none>",
      "Target lanes:",
      "Lane: <lane id; repeat this entry once per planned target>",
      "Target: <exact issue, pull-request, or durable override identity>",
      "Replay identity: <existing lane_id, dispatcher, instance_id, and launch token>",
      "Prompt source: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>",
      "Selected at: <timestamp>",
      "Prompt digest at selection: <SHA-256 of the canonical source bytes fetched when selected; or not applicable — trusted-ad-hoc-override>",
      "Launched at: <timestamp or pending>",
      "Prompt digest at launch: <SHA-256 of the canonical source bytes re-fetched at launch or pending; or not applicable — trusted-ad-hoc-override>",
      "Worker started at: <timestamp or pending>",
      "Prompt digest observed by worker: <SHA-256 of the canonical source bytes re-fetched by the worker or pending; or not applicable — trusted-ad-hoc-override>",
      "Model observed by worker: <observed value or UNKNOWN>",
      "Workflow observed at worker start: <version or UNKNOWN>"
    ].each { |field| assert_includes launcher_record, field }

    normalized = launcher_record.gsub(/\s+/, " ")
    assert_includes normalized, "field by field"
    assert_includes normalized, "does not block launch"
    assert_includes normalized, "collapsed `<details>`"
    assert_includes normalized, "one entry for every planned target lane"
    assert_includes normalized, "without replacing earlier values"
    assert_includes normalized, "Reruns append a new collapsed record"
    assert_includes normalized, "coordinator directly appends the cheap lane launch timestamp and digest"
    assert_includes normalized, "existing immutable replay identity"
    assert_includes normalized, "exactly matching `run_id`, replay identity, and `batch_plan_binding`"
    assert_includes normalized, "not the deterministic launch token"
    assert_includes normalized, "Do not add these fields to the human-authored prompt"
    assert_includes normalized, "successful `pr-security-preflight` snapshot"
    assert_includes normalized, "do not put the digest inside the bytes it hashes"
    assert_includes normalized, "sole writer for that record"
    assert_includes normalized, "workers return bound observation payloads"
    assert_includes normalized, "Never put a private `plan-state://` or `batch://` identity in a public run record"
    assert_includes normalized, "do not invent another snapshot, byte encoding, or record schema"
    assert_includes normalized, "not applicable — trusted-ad-hoc-override"
    assert_includes normalized, "exact GitHub API `body` string"
    assert_includes normalized, "without Unicode normalization, Markdown rendering, whitespace trimming, or newline insertion or removal"
    assert_includes normalized, "verifies both the replay identity and observed digest before it interprets the source"
    assert_includes normalized, "`auto` maps to machine `auto_merge_when_gates_pass`; `ask` maps to machine `ask`"
    assert_includes normalized, "machine-only `merge_authority: none`"
  end
end
