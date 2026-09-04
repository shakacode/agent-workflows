#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class PrWalkthroughContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SKILL = File.join(ROOT, "skills/pr-walkthrough/SKILL.md")
  WORKFLOW = File.join(ROOT, "workflows/pr-processing.md")
  INTEGRATION_CLOSEOUT = File.join(ROOT, "workflows/pr-batch-integration-closeout.md")
  PR_BATCH = File.join(ROOT, "skills/pr-batch/SKILL.md")
  PR_MONITORING = File.join(ROOT, "skills/pr-monitoring/SKILL.md")
  OPENAI_METADATA = File.join(ROOT, "skills/pr-walkthrough/agents/openai.yaml")
  GETTING_STARTED = File.join(ROOT, "docs/getting-started.md")

  def test_skill_is_exact_diff_github_native_and_complete
    skill = File.read(SKILL).gsub(/\s+/, " ")

    phrases = [
      "Record a diff identity",
      "Inspect the complete file list and diff before drafting the first published section.",
      "Prepare every section before publishing any of them.",
      "Prefer one GitHub `COMMENT` review tied to the exact head",
      "publish every conceptual section in that same submission as a separate inline review comment",
      "Publish all prepared sections in one pass.",
      "Do not wait for `next`"
    ]
    positions = phrases.map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }

    stale_positions = [
      "If the diff identity changes during preparation or before publication",
      "invalidate the coverage ledger",
      "rebuild the complete package before publishing"
    ].map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    stale_positions.each_cons(2) { |before, after| assert_operator before, :<, after }

    assert_includes skill, "Keep every section concise and conversational."
    assert_includes skill, "guidance, not required headings or a checklist"
    assert_includes skill, "Full mode means complete coverage and more sections when needed, not verbose comments."
    assert_includes skill, "Maintain a private coverage ledger"
    assert_includes skill, "PR link, diff identity, purpose, and prior behavior;"
    assert_includes skill, "Walkthrough participation is not merge approval."
    assert_includes skill, "Use live interactive mode only when the maintainer explicitly asks for live exploration."
  end

  def test_ask_authority_automatically_walks_through_before_merge_decision
    [WORKFLOW, INTEGRATION_CLOSEOUT, PR_MONITORING].each do |path|
      text = File.read(path).gsub(/\s+/, " ")

      phrases = [
        "automatically publish the complete exact-diff PR walkthrough",
        "Prepare every conceptual section up front",
        "separately replyable review comments",
        "without waiting for repeated chat turns",
        "The owning task consumes PR replies asynchronously",
        "After publication or an explicit skip, refresh the diff identity and ordinary readiness.",
        "If the diff identity changed, invalidate the walkthrough and readiness evidence, then rebuild and republish the walkthrough or stop.",
        "If an ordinary gate newly fails, stop.",
        "Ask one final merge decision only when the refreshed diff identity matches the recorded identity, ordinary readiness remains clean, and merge is allowed; a completed walkthrough must have explained that same diff identity.",
        "Walkthrough participation is not merge approval."
      ]
      positions = phrases.map do |phrase|
        position = text.index(phrase)
        assert position, "#{path}: expected #{phrase.inspect}"
        position
      end
      positions.each_cons(2) { |before, after| assert_operator before, :<, after, path }
    end
  end

  def test_pr_batch_routes_ask_authority_walkthrough_to_closeout_component
    pr_batch = File.read(PR_BATCH)

    assert_includes pr_batch,
                    "[automatic GitHub-native exact-diff walkthrough]" \
                    "(../../workflows/pr-batch-integration-closeout.md#ask-merge-authority-walkthrough-gate)"
  end

  def test_walkthrough_is_an_internal_current_task_phase_not_a_new_owner
    skill = File.read(SKILL).gsub(/\s+/, " ")
    phrases = [
      "The current task remains the sole user-facing coordinator.",
      "The walkthrough is an internal explanatory phase, not another task or owner.",
      "The current owning task consumes the PR discussion",
      "Use live interactive mode only when the maintainer explicitly asks",
      "retains control after publishing the exact-diff walkthrough",
      "ask its one final merge decision separately"
    ]
    positions = phrases.map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }
  end

  def test_picker_and_getting_started_use_github_native_default
    metadata = File.read(OPENAI_METADATA).gsub(/\s+/, " ")

    assert_includes metadata, "Publish a complete PR walkthrough on GitHub"
    assert_includes metadata, "publish a complete exact-diff walkthrough"
    assert_includes metadata, "separately replyable GitHub comments"
    assert_includes metadata, "use live interaction only if I explicitly ask"
    refute_includes metadata, "one change at a time"

    guide = File.read(GETTING_STARTED).gsub(/\s+/, " ")
    phrases = [
      "GitHub walkthrough published on PR #57 for the exact comparison",
      "All conceptual sections were posted in one pass.",
      "The owning task will consume PR replies asynchronously.",
      "Live exploration is available only when you explicitly request it.",
      "Diff identity unchanged since publication"
    ]
    positions = phrases.map do |phrase|
      position = guide.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }

    assert_operator guide.scan("separately replyable review thread").length, :>=, 2
    refute_includes guide, "Questions before the next change?"
    refute_includes guide, "Walkthrough (1/2):"
  end
end
