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

  def test_skill_is_exact_diff_interactive_and_complete
    skill = File.read(SKILL).gsub(/\s+/, " ")

    phrases = [
      "Record a diff identity",
      "Inspect the complete file list and diff before presenting Step 1.",
      "**Live mode** is the default for a walkthrough requested in the current chat.",
      "**Published-review mode** applies only when the user or an authorized repository workflow explicitly requests a complete walkthrough on GitHub.",
      "Present exactly one conceptual change per response.",
      "Then stop. Do not include the next conceptual change in the same response.",
      "Advance only after explicit readiness"
    ]
    positions = phrases.map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }

    stale_positions = [
      "If the diff identity changes during the walkthrough",
      "invalidate the coverage ledger",
      "rebuild the map before advancing or returning control"
    ].map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    stale_positions.each_cons(2) { |before, after| assert_operator before, :<, after }

    assert_includes skill, "Choose the delivery mode separately from depth:"
    assert_includes skill, "Keep each response concise and conversational."
    assert_includes skill, "guidance, not required headings or a checklist"
    assert_includes skill, "Full mode means complete coverage and more steps when needed, not verbose responses."
    assert_includes skill, "Maintain a private coverage ledger"
    assert_includes skill, "PR link, diff identity, purpose, and prior behavior;"
    assert_includes skill, "Walkthrough participation is not merge approval."
  end

  def test_ask_authority_automatically_walks_through_before_merge_decision
    [WORKFLOW, INTEGRATION_CLOSEOUT, PR_MONITORING].each do |path|
      text = File.read(path).gsub(/\s+/, " ")

      phrases = [
        "automatically publish the complete exact-diff PR walkthrough",
        "Prepare every conceptual section up front",
        "mandatory inline-thread and no-anchor-stop rules",
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

  def test_published_review_mode_is_complete_exact_head_comment_only
    skill = File.read(SKILL).gsub(/\s+/, " ")

    phrases = [
      "Build the complete coverage ledger and every conceptual section before any GitHub mutation.",
      "Re-fetch the diff identity immediately before submission.",
      "Submit exactly one GitHub review with event `COMMENT`",
      "Publish every conceptual section in that same review as one separately replyable inline thread",
      "Include an idempotency marker and full head SHA in the review body.",
      "Published-review mode never waits for `next`."
    ]
    positions = phrases.map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }

    assert_includes skill, "never `APPROVE` or `REQUEST_CHANGES`"
    assert_includes skill, "walkthrough is not approval"
    assert_includes skill, "never blindly publish a duplicate walkthrough"
  end

  def test_pr_batch_routes_ask_authority_walkthrough_to_closeout_component
    pr_batch = File.read(PR_BATCH)

    assert_includes pr_batch,
                    "[automatic GitHub-native exact-diff walkthrough]" \
                    "(../../workflows/pr-batch-integration-closeout.md#ask-merge-authority-walkthrough-gate)"
  end

  def test_async_reply_consumption_needs_no_undefined_cutoff
    skill = File.read(SKILL).gsub(/\s+/, " ")
    reply_section = skill.split("## Consume Replies Asynchronously", 2).last
                         .split("## Close The Walkthrough", 2).first

    assert_includes reply_section, "On each ordinary task resume or authorized PR-state refresh"
    assert_includes reply_section, "read all replies across every walkthrough thread"
    assert_includes reply_section, "answer outstanding focused questions in their original threads"
    refute_includes reply_section, "cutoff"
  end

  def test_walkthrough_is_an_internal_current_task_phase_not_a_new_owner
    skill = File.read(SKILL).gsub(/\s+/, " ")
    phrases = [
      "The current task remains the sole user-facing coordinator.",
      "The walkthrough is an internal explanatory phase, not another task or owner.",
      "**Live mode** is the default for a walkthrough requested in the current chat.",
      "Questions may continue in the threads or, only when the user explicitly asks, in a separate live walkthrough.",
      "The current owning task consumes the PR discussion",
      "return control to the current task after the exact-diff walkthrough",
      "ask its one final merge decision separately"
    ]
    positions = phrases.map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }
  end

  def test_picker_defaults_to_live_mode_and_getting_started_ask_flow_publishes
    metadata = File.read(OPENAI_METADATA).gsub(/\s+/, " ")

    assert_includes metadata, "Explain a pull request one change at a time"
    assert_includes metadata, "walk me through this PR one change at a time"
    refute_includes metadata, "publish a complete exact-diff walkthrough"
    refute_includes metadata, "use live interaction only if I explicitly ask"

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

    assert_includes guide, "Asked for in chat, it runs live and read-only:"
    assert_includes guide, "pauses for your questions before continuing"
    refute_includes guide, "Ask for live exploration if you prefer one concept at a time in chat."
  end
end
