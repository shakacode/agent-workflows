#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

REPO_ROOT = File.expand_path("../../..", __dir__)
TEXT_FENCE = "```text\n"
EXPECTED_PROMPT = <<~TEXT
  Repository: OWNER/REPO
  Work item: <exact issue or trusted maintainer-comment URL>
  Task name: <repository, issue, and purpose>
  Instruction: Use PR-batch to fix this issue against current main.
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

class ReadableGoalPromptContractTest < Minitest::Test
  def setup
    @plan_skill = read_repo_file("skills/plan-pr-batch/SKILL.md")
    @pr_batch_skill = read_repo_file("skills/pr-batch/SKILL.md")
    @workflow = read_repo_file("workflows/pr-processing.md")
    @triage_skill = read_repo_file("skills/triage/SKILL.md")

    workflow_handoff = @workflow.split("### Plan To Goal Handoff", 2).fetch(1)
    @prompts = {
      "plan-pr-batch" => extract_prompt(@plan_skill, "## Goal Prompt for pr-batch"),
      "pr-batch" => extract_prompt(@pr_batch_skill, "## Goal Prompt Template"),
      "workflow" => workflow_handoff.split("### ", 2).first.then { |text| extract_prompt("## Prompt\n\n#{text}", "## Prompt") }
    }
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
      assert_includes normalized, "Fix issue 476 using $pr-batch with merge authority ask."
      assert_includes normalized, "exactly one trusted issue body or trusted maintainer comment"
      assert_includes normalized, "later trusted maintainer comment"
      assert_includes normalized, "Do not synthesize"
      assert_includes normalized, "re-fetch the exact UTF-8 source content from GitHub at launch"
      assert_includes normalized, "Do not wait for a telemetry aggregator"
      assert_includes normalized, "same readable prompt vocabulary for every host"
      assert_includes normalized, "outside the human-authored prompt"
    end
  end

  def test_launcher_record_owns_launch_provenance_and_append_only_observations
    launcher_record = @workflow.split("### Launcher Run Record", 2).fetch(1).split("### ", 2).first

    [
      "Prompt source: <exact issue or trusted maintainer-comment URL>",
      "Selected at: <timestamp>",
      "Prompt created at: <timestamp>",
      "Worker started at: <timestamp or pending>",
      "Prompt digest at launch: <SHA-256 of the exact source content re-fetched at launch>",
      "Model at prompt creation: <observed value or UNKNOWN>",
      "Model observed by worker: <observed value or UNKNOWN>",
      "Workflow at prompt creation: <version or UNKNOWN>",
      "Workflow observed at worker start: <version or UNKNOWN>",
      "Later workflow observations: <timestamped append-only entries or none>"
    ].each { |field| assert_includes launcher_record, field }

    normalized = launcher_record.gsub(/\s+/, " ")
    assert_includes normalized, "field by field"
    assert_includes normalized, "does not block launch"
    assert_includes normalized, "collapsed `<details>`"
    assert_includes normalized, "Reruns append"
    assert_includes normalized, "`auto` maps to machine `auto_merge_when_gates_pass`; `ask` maps to machine `ask`"
    assert_includes normalized, "machine-only `merge_authority: none`"
  end
end
