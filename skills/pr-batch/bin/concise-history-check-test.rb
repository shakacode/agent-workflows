#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "minitest/autorun"

CONCISE_HISTORY_ROOT = File.expand_path("../../..", __dir__)
CONCISE_HISTORY_SCRIPT = File.join(__dir__, "concise-history-check")
CONCISE_HISTORY_FIXTURE_ROOT = File.join(
  CONCISE_HISTORY_ROOT,
  "skills/pr-batch/fixtures/concise-history"
)
CONCISE_HISTORY_HEAD = "1111111111111111111111111111111111111111"
CONCISE_HISTORY_WORKFLOW = File.join(CONCISE_HISTORY_ROOT, "workflows/pr-batch-integration-closeout.md")
CONCISE_HISTORY_SKILL = File.join(CONCISE_HISTORY_ROOT, "skills/pr-batch/SKILL.md")
CONCISE_HISTORY_VALIDATE = File.join(CONCISE_HISTORY_ROOT, "bin/validate")

class ConciseHistoryCheckTest < Minitest::Test
  def run_check(pr_body: fixture("pr-body.md"), commit_message: fixture("commit-message.txt"))
    Open3.capture3(
      "ruby",
      CONCISE_HISTORY_SCRIPT,
      "--pr-body", pr_body,
      "--commit-message", commit_message,
      "--diff", fixture("small.diff"),
      "--expected-head-sha", CONCISE_HISTORY_HEAD,
      "--require-issue-linkage", "Fixes #318",
      "--require-provenance-trailer", "Co-Authored-By",
      "--require-provenance-trailer", "Agent-Session"
    )
  end

  def fixture(name)
    File.join(CONCISE_HISTORY_FIXTURE_ROOT, name)
  end

  def test_small_diff_keeps_replayable_evidence_in_pr_and_durable_context_in_history
    stdout, stderr, status = run_check

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal "concise-history-check", result.fetch("contract")
    assert_equal 1, result.fetch("version")
    assert_equal "PASS", result.fetch("status")
    assert_equal "SATISFIED", result.dig("pr_evidence", "replay_verdict")
    ["### Commands and results", "### QA Evidence", "### Coordination and reviewer telemetry",
     "### Decision log", "### Audit receipts"].each do |artifact|
      assert_includes result.dig("pr_evidence", "artifacts"), artifact
    end
    assert_equal ["Fixes #318"], result.dig("commit_history", "issue_linkage")
    assert_equal %w[Co-Authored-By Agent-Session], result.dig("commit_history", "provenance_trailers")
    assert_equal "Keep small-diff history concise", result.dig("commit_history", "subject")
    assert_equal true, result.dig("commit_history", "durable_rationale")
    assert_equal [], result.dig("commit_history", "duplicated_pr_artifacts")
    assert_equal({ "files" => 1, "added_lines" => 2, "deleted_lines" => 1 }, result.fetch("diff"))
  end

  def test_authoring_workflow_owns_and_runs_the_concise_history_boundary
    workflow = File.read(CONCISE_HISTORY_WORKFLOW, encoding: "UTF-8")
    skill = File.read(CONCISE_HISTORY_SKILL, encoding: "UTF-8")
    validation = File.read(CONCISE_HISTORY_VALIDATE, encoding: "UTF-8")
    normalized_workflow = workflow.gsub(/\s+/, " ")

    assert_includes normalized_workflow,
                    "Commit history owns the proportional durable explanation of what changed and why"
    assert_includes normalized_workflow,
                    "The PR's canonical `Agent details` disclosure owns replayable agent, QA, review, and decision evidence"
    assert_includes normalized_workflow, "Do not impose a universal line-count limit"
    assert_includes workflow, "concise-history-check"
    assert_includes skill, "concise-history-check"
    assert_includes validation, "ruby skills/pr-batch/bin/concise-history-check-test.rb"
  end

  def test_commit_message_cannot_copy_replay_markers_from_agent_details
    Tempfile.create("duplicated-agent-evidence") do |file|
      file.write(File.read(fixture("commit-message.txt"), encoding: "UTF-8"))
      file.write("\n<!-- qa-evidence v2 status: satisfied -->\n")
      file.flush

      stdout, _stderr, status = run_check(commit_message: file.path)

      refute status.success?
      result = JSON.parse(stdout)
      assert_equal "FAIL", result.fetch("status")
      assert_equal ["<!-- qa-evidence v2"], result.dig("commit_history", "duplicated_pr_artifacts")
      assert_includes result.fetch("errors"), "commit message duplicates PR-only artifacts"
    end
  end

  def test_commit_message_requires_durable_rationale_without_a_line_cap
    Tempfile.create("missing-rationale") do |file|
      file.write(<<~MESSAGE)
        Keep small-diff history concise

        Fixes #318

        Co-Authored-By: Fixture Agent <fixture-agent@example.com>
        Agent-Session: fixture-session-318
      MESSAGE
      file.flush

      stdout, _stderr, status = run_check(commit_message: file.path)

      refute status.success?
      result = JSON.parse(stdout)
      assert_equal false, result.dig("commit_history", "durable_rationale")
      assert_includes result.fetch("errors"), "commit message durable rationale is missing"
    end
  end
end
