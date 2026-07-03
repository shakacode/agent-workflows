#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

SCRIPT = File.expand_path("autoreview-target-state", __dir__)
load SCRIPT

class AutoreviewTargetStateTest < Minitest::Test
  def test_untracked_only_work_uses_uncommitted_review
    result = classify(dirty: true, untracked_only: true, branch_diff: false)

    assert_equal "LOCAL_UNTRACKED_ONLY", result["state"]
    assert_equal "ready", result["disposition"]
    assert_equal ["codex review --uncommitted"], commands(result)
  end

  def test_branch_plus_dirty_local_work_requires_split_target
    result = classify(dirty: true, branch_diff: true)

    assert_equal "BRANCH_PLUS_DIRTY_LOCAL", result["state"]
    assert_equal "not_ready", result["disposition"]
    assert_equal [
      %(codex review --base "origin/main"),
      "codex review --uncommitted"
    ], commands(result)
  end

  def test_non_main_pr_base_drives_branch_review_base
    result = classify(
      pr: { "state" => "found", "base" => "release/1.2" },
      branch_diff: true
    )

    assert_equal "BRANCH_PR_DIFF", result["state"]
    assert_equal "ready", result["disposition"]
    assert_equal "release/1.2", result["base"]
    assert_equal [%(codex review --base "origin/release/1.2")], commands(result)
  end

  def test_no_pr_for_current_branch_is_expected_state
    result = classify(
      pr: { "state" => "no_pr", "reason" => "no pull requests found for branch" },
      branch_diff: true
    )

    assert_equal "BRANCH_NO_PR_DIFF", result["state"]
    assert_equal "ready", result["disposition"]
    assert_equal "no_pr", result["pr_state"]
    assert_equal [%(codex review --base "origin/main")], commands(result)
  end

  def test_detached_head_is_blocked
    result = classify(attached: false, branch: nil, branch_diff: :unknown)

    assert_equal "DETACHED_HEAD", result["state"]
    assert_equal "blocked", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_pr_base_probe_failure_is_unknown
    result = classify(
      pr: { "state" => "unknown", "reason" => "gh auth failed" },
      branch_diff: true
    )

    assert_equal "PR_BASE_UNKNOWN", result["state"]
    assert_equal "UNKNOWN", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_pr_base_probe_failure_with_dirty_branch_work_is_still_unknown
    result = classify(
      dirty: true,
      pr: { "state" => "unknown", "reason" => "gh auth failed" },
      branch_diff: true
    )

    assert_equal "PR_BASE_UNKNOWN", result["state"]
    assert_equal "UNKNOWN", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_base_diff_failure_is_unknown
    result = classify(branch_diff: :unknown)

    assert_equal "BASE_DIFF_UNKNOWN", result["state"]
    assert_equal "UNKNOWN", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_base_diff_failure_with_dirty_work_is_still_unknown
    result = classify(dirty: true, untracked_only: true, branch_diff: :unknown)

    assert_equal "BASE_DIFF_UNKNOWN", result["state"]
    assert_equal "UNKNOWN", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_clean_branch_without_diff_is_not_ready
    result = classify(branch_diff: false)

    assert_equal "NO_REVIEW_TARGET", result["state"]
    assert_equal "not_ready", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_clean_branch_without_diff_is_not_ready_even_when_pr_probe_is_unknown
    result = classify(
      pr: { "state" => "unknown", "reason" => "gh auth failed" },
      branch_diff: false
    )

    assert_equal "NO_REVIEW_TARGET", result["state"]
    assert_equal "not_ready", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_default_branch_with_local_commits_is_blocked
    result = classify(branch: "main", branch_diff: true)

    assert_equal "DEFAULT_BRANCH_WITH_LOCAL_COMMITS", result["state"]
    assert_equal "blocked", result["disposition"]
    assert_empty result["review_targets"]
  end

  def test_no_pr_output_detection
    assert AutoreviewTargetState.no_pr_output?("no pull requests found for branch")
    refute AutoreviewTargetState.no_pr_output?("HTTP 401: bad credentials")
  end

  def test_configured_base_resolves_from_git_root_when_called_in_subdirectory
    Dir.mktmpdir("autoreview-target-state") do |dir|
      system("git", "init", "-q", dir)
      FileUtils.mkdir_p(File.join(dir, ".agents"))
      File.write(File.join(dir, ".agents", "agent-workflow.yml"), "base_branch: release/2.0\n")
      FileUtils.mkdir_p(File.join(dir, "nested"))

      Dir.chdir(File.join(dir, "nested")) do
        assert_equal "release/2.0", AutoreviewTargetState.configured_base
      end
    end
  end

  private

  def classify(overrides = {})
    AutoreviewTargetState.classify({
      attached: true,
      branch: "feature",
      configured_base: "main",
      dirty: false,
      untracked_only: false,
      pr: { "state" => "no_pr", "reason" => "no pull requests found" },
      branch_diff: false
    }.merge(overrides))
  end

  def commands(result)
    result.fetch("review_targets").map { |target| target.fetch("command") }
  end
end
