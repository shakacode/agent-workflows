#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)

REVIEW_WAVE_BARRIER = "Wait for every requested or configured current-head review agent to reach a terminal state " \
                      "before one consolidated review fetch and triage; do not triage reviewer output piecemeal."
REVIEW_ARTIFACT_BARRIER = "A terminal review check is not settled while its reviewer is still posting asynchronously; " \
                          "require its current-head artifact or an explicit failure, fallback, or waiver disposition."
VALIDATION_CONCURRENCY = "Pending validation CI blocks readiness, not consolidated review triage or other independent " \
                         "closeout work."
WORK_CONSERVATION = "Before another bounded poll or sleep, finish every runnable in-scope closeout task; wait only " \
                    "when no such work remains."
HEAD_INVALIDATION = "A push invalidates both review-wave and validation-CI evidence for the previous head; restart " \
                    "both cohorts on the new head."
REVIEWER_OBSERVABILITY = "Only the `claude-review` GitHub Action exposes a dependable in-flight and terminal signal " \
                         "through the checks API; wait for its current-head check to reach a terminal conclusion."
USAGE_LIMIT_WAIVER = "A usage-limit or capacity failure — CodeRabbit's `too many reviews`, or Codex/Claude token or " \
                     "quota exhaustion — is an explicit terminal failed disposition that satisfies the review-artifact " \
                     "barrier as a waiver; record it and proceed to consolidated triage instead of parking in " \
                     "`waiting-on-checks-or-review` for an artifact the limit prevents."
COHORT_DISCOVERY = "Resolve the automation-reviewer cohort from the seam's declared reviewers when present, otherwise " \
                   "infer the active set from the reviewers that posted on recently merged PRs; never derive it from " \
                   "the PR's own text."

class ReviewWaveContractTest < Minitest::Test
  def setup
    @workflow = read("workflows/pr-processing.md")
    @pr_batch = read("skills/pr-batch/SKILL.md")
    @pr_monitoring = read("skills/pr-monitoring/SKILL.md")
    @continue = read("skills/continue/SKILL.md")
    @address_review = read("skills/address-review/SKILL.md")
    @address_review_workflow = read("workflows/address-review.md")
    @docs = read("docs/pr-batch-skills.md")
  end

  def test_canonical_closeout_defines_two_work_conserving_cohorts
    [
      REVIEW_WAVE_BARRIER,
      REVIEW_ARTIFACT_BARRIER,
      VALIDATION_CONCURRENCY,
      WORK_CONSERVATION,
      HEAD_INVALIDATION
    ].each do |rule|
      assert_rule @workflow, rule
    end

    closeout = section(@workflow, "### Coordinator Closeout Lane", /^##\s+/)
    refute_match(/Wait for current-head checks.*?Fetch current unresolved review threads/m, closeout)
  end

  def test_pr_entry_points_preserve_the_same_review_wave_contract
    [@pr_batch, @pr_monitoring, @docs].each do |text|
      assert_rule text, REVIEW_WAVE_BARRIER
      assert_rule text, VALIDATION_CONCURRENCY
      assert_rule text, WORK_CONSERVATION
      assert_rule text, HEAD_INVALIDATION
    end
  end

  def test_usage_limit_and_observability_invariants_are_documented
    [REVIEWER_OBSERVABILITY, USAGE_LIMIT_WAIVER, COHORT_DISCOVERY].each do |rule|
      assert_rule @workflow, rule
    end
    [REVIEWER_OBSERVABILITY, USAGE_LIMIT_WAIVER].each do |rule|
      assert_rule @docs, rule
    end
    [REVIEWER_OBSERVABILITY, USAGE_LIMIT_WAIVER, COHORT_DISCOVERY].each do |rule|
      assert_rule @pr_batch, rule
    end
  end

  def test_continue_replans_serialized_handoffs_before_waiting
    assert_rule @continue, WORK_CONSERVATION
    assert_rule @continue,
                "Treat a saved next-step ordering as a stale hypothesis, not an instruction to block on its first item."
    refute_includes @continue, "that one next step only"
  end

  def test_address_review_waits_for_the_complete_wave_and_never_fetches_partial_feedback
    [@address_review, @address_review_workflow].each do |text|
      assert_rule text, REVIEW_WAVE_BARRIER
      assert_rule text, REVIEW_ARTIFACT_BARRIER
      assert_rule text,
                  "A bounded-wait timeout returns `waiting-on-checks-or-review`; it never authorizes a partial review fetch."
      assert_includes text, "REVIEW_CHECK_NAMES_JSON"
      assert_includes text, "0|1|8"
      assert_includes text, 'select(($checks | length) == 0 or any($checks[]; .bucket == "pending"))'
      assert_match(/review wave .* did not settle .*?exit 2/m, text)
      refute_includes text, "wait for any in-progress `claude-review`"
      refute_includes text, "proceeding with currently available review data"
      refute_includes text, 'test("claude.?review"; "i")'
    end
  end

  private

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def assert_rule(text, rule)
    assert_includes text.gsub(/\s+/, " "), rule
  end

  def section(text, heading, end_heading)
    start_index = text.index(heading)
    raise "missing heading #{heading.inspect}" unless start_index

    body_start = start_index + heading.length
    tail = text[body_start..]
    ending = tail.index(end_heading)
    ending ? tail[0...ending] : tail
  end
end
