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

  def test_shipped_pending_filter_counts_synthetic_check_payloads
    pending_cases.each do |name, checks, expected_count|
      assert_equal expected_count, pending_count(checks, expected_reviewers), name
    end
  end

  def test_pending_fixtures_reject_inverted_and_missing_name_mutants
    shipped_filter = shipped_pending_filter
    mutants = {
      "inverted pending bucket" => shipped_filter.sub('.bucket == "pending"', '.bucket != "pending"'),
      "missing-name branch removed" => shipped_filter.sub("(\$checks | length) == 0 or ", "")
    }
    expected_counts = pending_cases.map(&:last)

    mutants.each do |name, mutant|
      refute_equal shipped_filter, mutant, "#{name} mutation did not apply"
      mutant_counts = pending_cases.map do |_case_name, checks, _expected_count|
        pending_count(checks, expected_reviewers, filter: mutant)
      end
      refute_equal expected_counts, mutant_counts, "fixtures survived #{name}"
    end
  end

  def test_shipped_review_wait_accepts_documented_gh_exit_codes
    [0, 1, 8].each do |gh_status|
      _stdout, stderr, status = run_shipped_review_wait("[]", gh_status)

      assert_predicate status, :success?, "gh exit #{gh_status}: #{stderr}"
    end
  end

  def test_shipped_review_wait_fails_closed_for_unknown_gh_exit_code
    _stdout, stderr, status = run_shipped_review_wait("[]", 2)

    assert_equal 2, status.exitstatus
    assert_includes stderr, "review-check state is UNKNOWN"
  end

  def test_shipped_review_wait_fails_closed_for_non_array_output
    _stdout, stderr, status = run_shipped_review_wait('{"name":"claude-review"}', 0)

    assert_equal 2, status.exitstatus
    assert_includes stderr, "malformed review-check state"
  end

  private

  def expected_reviewers
    %w[claude-review CodeRabbit]
  end

  def pending_cases
    [
      [
        "all pass",
        [
          { "name" => "claude-review", "bucket" => "pass" },
          { "name" => "CodeRabbit", "bucket" => "pass" }
        ],
        0
      ],
      [
        "one pending",
        [
          { "name" => "claude-review", "bucket" => "pending" },
          { "name" => "CodeRabbit", "bucket" => "pass" }
        ],
        1
      ],
      [
        "one failed",
        [
          { "name" => "claude-review", "bucket" => "fail" },
          { "name" => "CodeRabbit", "bucket" => "pass" }
        ],
        0
      ],
      [
        "expected name absent",
        [{ "name" => "claude-review", "bucket" => "pass" }],
        1
      ],
      ["empty array", [], 2],
      [
        "duplicate names with one pending",
        [
          { "name" => "claude-review", "bucket" => "pass" },
          { "name" => "claude-review", "bucket" => "pending" },
          { "name" => "CodeRabbit", "bucket" => "pass" }
        ],
        1
      ]
    ]
  end

  def pending_count(checks, expected, filter: shipped_pending_filter)
    stdout, stderr, status = Open3.capture3(
      "jq", "--argjson", "expected", JSON.generate(expected), filter,
      stdin_data: JSON.generate(checks)
    )
    raise "jq failed: #{stderr}" unless status.success?

    Integer(stdout, 10)
  end

  def shipped_pending_filter
    start_marker = %(jq --argjson expected "${REVIEW_CHECK_NAMES_JSON}" '\n)
    end_marker = "] | length')\""
    start_index = @address_review.index(start_marker)
    raise "missing shipped pending-wave jq invocation" unless start_index

    filter_start = start_index + start_marker.length
    filter_end = @address_review.index(end_marker, filter_start)
    raise "missing end of shipped pending-wave jq filter" unless filter_end

    @address_review[filter_start...(filter_end + "] | length".length)].strip
  end

  def run_shipped_review_wait(output, gh_status)
    gh_stub = <<~SH
      gh() {
        printf '%s' "${GH_STUB_OUTPUT}"
        return "${GH_STUB_STATUS}"
      }
    SH
    env = {
      "GH_STUB_OUTPUT" => output,
      "GH_STUB_STATUS" => gh_status.to_s,
      "REPO" => "shakacode/agent-workflows",
      "REVIEW_CHECK_NAMES_JSON" => "[]",
      "REVIEW_WAIT_PRS" => "227"
    }
    Open3.capture3(env, "/bin/sh", stdin_data: gh_stub + shipped_review_wait_loop)
  end

  def shipped_review_wait_loop
    start_marker = "  for REVIEW_WAIT_PR in ${REVIEW_WAIT_PRS}; do\n"
    end_marker = "  done\nfi\n```"
    start_index = @address_review.index(start_marker)
    raise "missing shipped review-wait loop" unless start_index

    end_index = @address_review.index(end_marker, start_index)
    raise "missing end of shipped review-wait loop" unless end_index

    @address_review[start_index...(end_index + "  done\n".length)]
  end

  def read(path)
    File.read(File.join(ROOT, path), encoding: "UTF-8")
  end

  def assert_rule(text, rule)
    assert_includes text.gsub(/\s+/, " "), rule
  end

  def section(text, heading, end_heading)
    heading_match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
    raise "missing heading #{heading.inspect}" unless heading_match

    body_start = heading_match.end(0)
    ending = text.match(end_heading, body_start)
    text[body_start...(ending ? ending.begin(0) : text.length)]
  end
end
