#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

class PrWalkthroughContractTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SKILL = File.join(ROOT, "skills/pr-walkthrough/SKILL.md")
  WORKFLOW = File.join(ROOT, "workflows/pr-processing.md")
  PR_BATCH = File.join(ROOT, "skills/pr-batch/SKILL.md")
  PR_MONITORING = File.join(ROOT, "skills/pr-monitoring/SKILL.md")

  def test_skill_is_exact_diff_interactive_and_complete
    skill = File.read(SKILL).gsub(/\s+/, " ")

    phrases = [
      "Record a diff identity",
      "Inspect the complete file list and diff before presenting Step 1.",
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

    assert_includes skill, "Keep each response concise and conversational."
    assert_includes skill, "guidance, not required headings or a checklist"
    assert_includes skill, "Full mode means complete coverage and more steps when needed, not verbose responses."
    assert_includes skill, "Maintain a private coverage ledger"
    assert_includes skill, "PR link, diff identity, purpose, and prior behavior;"
    assert_includes skill, "Walkthrough participation is not merge approval."
  end

  def test_ask_authority_automatically_walks_through_before_merge_decision
    [WORKFLOW, PR_BATCH, PR_MONITORING].each do |path|
      text = File.read(path).gsub(/\s+/, " ")

      phrases = [
        "automatically start the exact-diff PR walkthrough",
        "full interactive mode for large or complex PRs",
        "After it completes or is skipped, refresh the diff identity and ordinary readiness.",
        "If the diff identity changed, invalidate the walkthrough and readiness evidence, then restart the walkthrough or stop.",
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

  def test_walkthrough_is_an_internal_current_task_phase_not_a_new_owner
    skill = File.read(SKILL).gsub(/\s+/, " ")
    phrases = [
      "The current task remains the sole user-facing coordinator.",
      "The walkthrough is an internal explanatory phase, not another task or owner.",
      "Present exactly one conceptual change per response.",
      "return control to the current task",
      "ask its one final merge decision separately"
    ]
    positions = phrases.map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }
  end
end
