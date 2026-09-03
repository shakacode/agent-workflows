#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"

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
    @integration_closeout = read("workflows/pr-batch-integration-closeout.md")
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
      assert_rule @integration_closeout, rule
    end

    closeout = section(@integration_closeout, "### Coordinator Closeout Lane", /^##\s+/)
    refute_match(/Wait for current-head checks.*?Fetch current unresolved review threads/m, closeout)

    assert_includes @workflow,
                    "[Coordinator Closeout Lane](pr-batch-integration-closeout.md#coordinator-closeout-lane)"
  end

  def test_section_extractor_ignores_a_quoted_heading
    document = <<~MARKDOWN
      <!-- Keep `### Coordinator Closeout Lane` synchronized. -->
      decoy body

      ### Coordinator Closeout Lane

      real body

      ## Next
    MARKDOWN

    extracted = section(document, "### Coordinator Closeout Lane", /^##\s+/)

    assert_includes extracted, "real body"
    refute_includes extracted, "decoy body"
  end

  def test_pr_entry_points_preserve_the_same_review_wave_contract
    [@pr_monitoring, @docs].each do |text|
      assert_rule text, REVIEW_WAVE_BARRIER
      assert_rule text, VALIDATION_CONCURRENCY
      assert_rule text, WORK_CONSERVATION
      assert_rule text, HEAD_INVALIDATION
    end

    assert_includes @pr_batch,
                    "[Review-Wave And Validation Cohorts](../../workflows/pr-batch-integration-closeout.md#review-wave-and-validation-cohorts)"
  end

  def test_usage_limit_and_observability_invariants_are_documented
    [REVIEWER_OBSERVABILITY, USAGE_LIMIT_WAIVER, COHORT_DISCOVERY].each do |rule|
      assert_rule @integration_closeout, rule
    end
    [REVIEWER_OBSERVABILITY, USAGE_LIMIT_WAIVER].each do |rule|
      assert_rule @docs, rule
    end
    assert_includes @pr_batch,
                    "[Review-Wave And Validation Cohorts](../../workflows/pr-batch-integration-closeout.md#review-wave-and-validation-cohorts)"
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
      assert_rule text, USAGE_LIMIT_WAIVER
      assert_rule text,
                  "The named absence at timeout identifies the missing reviewer or stuck check, but it is not itself the explicit usage/capacity evidence required for a waiver; apply the unavailable-review waiver only with explicit evidence that the named reviewer is unavailable because of usage or capacity."
      assert_rule text,
                  "A bounded-wait timeout returns `waiting-on-checks-or-review`; it never authorizes a partial review fetch."
      assert_includes text, "REVIEW_CHECK_NAMES_JSON"
      assert_includes text, "REVIEW_WAVE_MISSING_CHECK_NAMES"
      assert_includes text, "REVIEW_WAVE_PENDING_CHECK_NAMES"
      assert_includes text, "REVIEW_UNAVAILABLE_WAIVERS_JSON"
      assert_includes text, "REVIEW_WAIVED_CHECK_NAMES_JSON"
      assert_includes text, "REVIEW_WAVE_STATUS_JSON"
      assert_includes text, "REVIEW_WAIT_HEAD_SHA_AFTER"
      assert_includes text, ".head_sha == $head"
      assert_includes text, "0|1|8"
      assert_match(/REVIEW_WAIT_HEAD_SHA_AFTER.*?!=.*?REVIEW_WAIT_HEAD_SHA.*?WAITED.*?-ge.*?MAX_WAIT.*?exit 2.*?sleep 15.*?WAITED=\$\(\(WAITED \+ 15\)\).*?continue/m, text)
      refute_match(/REVIEW_WAIT_HEAD_SHA_AFTER.*?!=.*?REVIEW_WAIT_HEAD_SHA.*?WAITED=0.*?continue/m, text)
      assert_includes text,
                      'select(($waived | index($name)) == null or any($checks[]; .bucket == "pending"))'
      assert_includes text, "pending_count:"
      assert_includes text, "missing_names:"
      assert_includes text, "pending_names:"
      assert_match(/review wave .* did not settle .* missing expected check-run names: \$\{REVIEW_WAVE_MISSING_CHECK_NAMES\}; pending expected check-run names: \$\{REVIEW_WAVE_PENDING_CHECK_NAMES\}.*?exit 2/m, text)
      refute_includes text, "wait for any in-progress `claude-review`"
      refute_includes text, "proceeding with currently available review data"
      refute_includes text, 'test("claude.?review"; "i")'
    end
  end

  def test_explicit_usage_waiver_makes_only_the_named_reviewer_terminal
    expected = %w[coderabbitai claude-review]
    terminal_checks = [{ "name" => "claude-review", "bucket" => "pass" }]
    pending_checks = terminal_checks + [{ "name" => "coderabbitai", "bucket" => "pending" }]
    head_sha = "a" * 40
    exact_waiver = waiver(pr_number: 684, check_name: "coderabbitai", head_sha: head_sha)
    stale_waiver = waiver(pr_number: 684, check_name: "coderabbitai", head_sha: "b" * 40)
    other_pr_waiver = waiver(pr_number: 683, check_name: "coderabbitai", head_sha: head_sha)
    unrelated_waiver = waiver(pr_number: 684, check_name: "unrelated-reviewer", head_sha: head_sha)

    [@address_review, @address_review_workflow].each do |text|
      assert waiver_evidence_valid?(text, [exact_waiver, stale_waiver, other_pr_waiver, unrelated_waiver])
      refute waiver_evidence_valid?(text, [exact_waiver.merge("reason" => "unknown")])
      assert_equal 1, review_wave_pending(text, expected, terminal_checks, [], 684, head_sha)
      assert_equal 0, review_wave_pending(text, expected, terminal_checks, [exact_waiver], 684, head_sha)
      assert_equal 1, review_wave_pending(text, expected, pending_checks, [exact_waiver], 684, head_sha)
      assert_equal 1, review_wave_pending(text, expected, terminal_checks, [unrelated_waiver], 684, head_sha)
      assert_equal 1, review_wave_pending(text, expected, terminal_checks, [stale_waiver], 684, head_sha)
      assert_equal 1, review_wave_pending(text, expected, terminal_checks, [other_pr_waiver], 684, head_sha)
    end

    assert_equal normalized_filter(jq_filter(@address_review, "REVIEW_WAIVED_CHECK_NAMES_JSON")),
                 normalized_filter(jq_filter(@address_review_workflow, "REVIEW_WAIVED_CHECK_NAMES_JSON"))
    assert_equal normalized_filter(jq_filter(@address_review, "REVIEW_WAVE_STATUS_JSON")),
                 normalized_filter(jq_filter(@address_review_workflow, "REVIEW_WAVE_STATUS_JSON"))
  end

  private

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def assert_rule(text, rule)
    assert_includes text.gsub(/\s+/, " "), rule
  end

  def review_wave_pending(text, expected, checks, waivers, pr_number, head_sha)
    waived = run_jq(
      jq_filter(text, "REVIEW_WAIVED_CHECK_NAMES_JSON"), waivers,
      "--argjson", "pr", pr_number.to_s, "--arg", "head", head_sha,
      "--argjson", "expected", JSON.generate(expected)
    )
    status = run_jq(
      jq_filter(text, "REVIEW_WAVE_STATUS_JSON"), checks,
      "--argjson", "expected", JSON.generate(expected), "--argjson", "waived", JSON.generate(waived)
    )
    status.fetch("pending_count")
  end

  def waiver_evidence_valid?(text, waivers)
    filter = text.match(%r{jq -e --arg host "\$\{GH_HOST\}" --arg repo "\$\{REPO\}" '(?<filter>.*?)' >/dev/null; then}m)
    raise "missing waiver validation jq filter" unless filter

    _stdout, _stderr, status = Open3.capture3(
      "jq", "-e", "--arg", "host", "github.com", "--arg", "repo", "shakacode/agent-workflows",
      filter[:filter], stdin_data: JSON.generate(waivers)
    )
    status.success?
  end

  def waiver(pr_number:, check_name:, head_sha:)
    {
      "pr_number" => pr_number,
      "head_sha" => head_sha,
      "check_name" => check_name,
      "reason" => "capacity",
      "evidence_url" => "https://github.com/shakacode/agent-workflows/pull/#{pr_number}#issuecomment-1",
      "observed_at" => "2026-09-03T10:00:00Z"
    }
  end

  def jq_filter(text, variable)
    match = text.match(/#{Regexp.escape(variable)}=.*?\|\s*\n\s*jq -c .*? '(?<filter>.*?)'\)"/m)
    raise "missing jq filter for #{variable}" unless match

    match[:filter]
  end

  def normalized_filter(filter)
    filter.gsub(/\s+/, " ").strip
  end

  def run_jq(filter, input, *arguments)
    stdout, stderr, status = Open3.capture3(
      "jq", "-c", *arguments, filter, stdin_data: JSON.generate(input)
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def section(text, heading, end_heading)
    heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
    raise "missing heading #{heading.inspect}" unless heading_match

    body_start = heading_match.end(0)
    ending = text.match(end_heading, body_start)
    text[body_start...(ending ? ending.begin(0) : text.length)]
  end
end
