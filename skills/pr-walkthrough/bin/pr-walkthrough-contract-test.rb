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
    [WORKFLOW, INTEGRATION_CLOSEOUT, PR_MONITORING].each do |path|
      text = File.read(path).gsub(/\s+/, " ")

      phrases = [
        "automatically start the exact-diff PR walkthrough",
        "full interactive mode for large or complex PRs",
        "After it completes or is skipped",
        "refresh the diff identity",
        "invalidate the walkthrough",
        "ordinary gate newly fails",
        "Ask one final merge decision only when the refreshed diff",
        "Walkthrough participation is not merge approval."
      ]
      positions = phrases.map do |phrase|
        position = text.index(phrase)
        assert position, "#{path}: expected #{phrase.inspect}"
        position
      end
      positions.each_cons(2) { |before, after| assert_operator before, :<, after, path }

      # The final-ask sentence itself must gate on current-integration
      # readiness, not just ordinary readiness — a substring match alone
      # would keep passing even if that condition were silently dropped.
      assert_match(
        /Ask one final merge decision only when the refreshed diff[^;]*ordinary readiness and current-integration readiness[^;]*clean[^;]*;/,
        text,
        "#{path}: final-ask sentence must require current-integration readiness, not just ordinary readiness"
      )
    end
  end

  def test_ask_walkthrough_requires_normalized_current_integration_success
    closeout = File.read(INTEGRATION_CLOSEOUT).gsub(/\s+/, " ")
    monitoring = File.read(PR_MONITORING).gsub(/\s+/, " ")
    skill = File.read(SKILL).gsub(/\s+/, " ")
    ask_gate_start = closeout.index("### Ask Merge Authority Walkthrough Gate")
    ask_gate_end = closeout.index("### Autonomous Merge Eligibility Gate", ask_gate_start)
    assert ask_gate_start
    assert ask_gate_end
    ask_gate = closeout[ask_gate_start...ask_gate_end]

    phrases = [
      "establish current-integration readiness from trusted live facts",
      "the exact head contains the current base",
      "normalized successful state",
      "`waiting-on-checks-or-review`",
      "automatically start the exact-diff PR walkthrough"
    ]
    positions = phrases.map do |phrase|
      position = ask_gate.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }
    assert_includes monitoring, "resolve the exact head and current base"
    assert_includes monitoring,
                    "exact-head CI has normalized successful state `READY` under `pr-ci-readiness` v2"
    assert_includes monitoring, "normalized successful state `READY`"
    assert_includes monitoring, "`waiting-on-checks-or-review`"
    assert_includes monitoring,
                    "does not claim or consume the later machine `current-integration-evidence` contract"

    assert_includes skill,
                    "Start only when the recorded head contains the current base and exact-head `pr-ci-readiness` v2 reports `READY`"
    assert_includes skill,
                    "do not claim the later machine `current-integration-evidence` contract"
    assert_includes skill,
                    "CURRENT-INTEGRATION CI IS NOT IN A NORMALIZED SUCCESSFUL STATE — NOT MERGE-READY."
    assert_includes skill, "`waiting-on-checks-or-review`"
  end

  def test_standalone_walkthrough_reports_unknown_not_a_hard_failure_claim
    skill = File.read(SKILL).gsub(/\s+/, " ")

    phrases = [
      "A standalone walkthrough not invoked by that gate",
      "never resolves ancestry or runs `pr-ci-readiness`",
      "it has no checklist result to consult",
      "so it reports current-integration readiness as not evaluated",
      "does not compute the checklist above itself",
      "reports current-integration readiness as **not evaluated (`UNKNOWN`)**",
      "never resolve ancestry or run `pr-ci-readiness` independently to manufacture",
      "a failed checklist there returns control to the caller with"
    ]
    positions = phrases.map do |phrase|
      position = skill.index(phrase)
      assert position, "expected #{phrase.inspect}"
      position
    end
    positions.each_cons(2) { |before, after| assert_operator before, :<, after }

    # A standalone walkthrough reports UNKNOWN for itself; the hard failure
    # banner in this section only describes the ask-caller precondition
    # (Establish The Exact Change, step 4), which must come after the UNKNOWN
    # claim in reading order.
    set_expectations_start = skill.index("## Set Expectations")
    present_one_change_start = skill.index("## Present One Change", set_expectations_start)
    set_expectations = skill[set_expectations_start...present_one_change_start]
    assert_operator set_expectations.index("not evaluated (`UNKNOWN`)"), :<,
                    set_expectations.index("CURRENT-INTEGRATION CI IS NOT IN A NORMALIZED SUCCESSFUL STATE")
  end

  def test_hard_failure_banner_is_scoped_to_the_applicable_sub_case
    skill = File.read(SKILL).gsub(/\s+/, " ")

    # A proven-behind ancestry result must take precedence over a CI failure
    # (not be masked by it) — the caller has two distinct banners, quoted in
    # both places this skill describes the caller's failed-checklist result.
    assert_equal 2, skill.scan("that gate's applicable hard-failure banner").length
    assert_equal 2,
                 skill.scan("behind-base banner routing to Integration And PR Publication step 3").length
    assert_equal 2, skill.scan("whenever ancestry fails, regardless of CI").length
    assert_equal 2, skill.scan("only when ancestry passed and CI itself is not `READY`").length
  end

  def test_pr_batch_routes_ask_authority_walkthrough_to_closeout_component
    pr_batch = File.read(PR_BATCH)

    assert_includes pr_batch,
                    "[automatic interactive exact-diff walkthrough]" \
                    "(../../workflows/pr-batch-integration-closeout.md#ask-merge-authority-walkthrough-gate)"
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
