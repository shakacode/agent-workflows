#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for fetch-pr-review-data.
# Run with: ruby .agents/skills/address-review/bin/fetch-pr-review-data-test.rb

require "minitest/autorun"
require "open3"
require_relative "../../pr-batch/lib/github_comment_envelope"

SCRIPT = File.expand_path("fetch-pr-review-data", __dir__)
load SCRIPT

class FetchPrReviewDataTest < Minitest::Test
  ISSUE_RAW = <<~JSON
    [[
      {"id":1,"node_id":"IC_1","body":"first","user":{"login":"alice"},"created_at":"2026-01-01T00:00:00Z"},
      {"id":2,"node_id":"IC_2","body":"<!-- address-review-summary -->\\nold","user":{"login":"bot"},"created_at":"2026-01-02T00:00:00Z"}
    ],[
      {"id":3,"node_id":"IC_3","body":"<!-- address-review-summary -->\\nnew \\ud83c\\udf89","user":{"login":"bot"},"created_at":"2026-01-03T00:00:00Z"},
      {"id":4,"node_id":"IC_4","body":"<!-- address-review-status -->\\nnot a cutoff","user":{"login":"bot"},"created_at":"2026-01-04T00:00:00Z"}
    ]]
  JSON

  # Production break: a completed review pass said only "evidence follows"
  # while its checkpoint was invisible. New visible checkpoints must still
  # advance the trusted cutoff without emitting an HTML marker.
  def test_visible_summary_checkpoint_advances_the_cutoff
    comments = [
      {
        "body" => <<~MARKDOWN.chomp,
          🤖 Codex address-review follow-up is complete. The next routine scan can start after this comment.

          ## Review follow-up complete

          Every review item in the selected scan has a recorded outcome.

          <details>
          <summary>Address-review checkpoint</summary>

          **Runtime:** Codex · Astra

          ```text
          address-review-checkpoint:v1
          kind: summary
          ```
          </details>
        MARKDOWN
        "created_at" => "2026-09-12T00:00:00Z"
      }
    ]

    assert_equal "2026-09-12T00:00:00Z", FetchPrReviewData.compute_cutoff(comments)
    refute_includes comments.first.fetch("body"), "<!--"
  end

  def test_template_payload_wrapped_by_the_envelope_advances_the_cutoff
    payload = <<~MARKDOWN.chomp
      Address-review follow-up is complete. The next routine scan can start after this comment.

      ## Review follow-up complete

      Every review item in the selected scan has a recorded outcome.

      <details>
      <summary>Address-review checkpoint</summary>

      **Runtime:** Codex · Astra

      ```text
      address-review-checkpoint:v1
      kind: summary
      ```
      </details>
    MARKDOWN
    body = GitHubCommentEnvelope.render(body: payload, runner: "codex", host: "M5", task_or_run: "task-8")
    normalized = FetchPrReviewData.build_issue_comments(
      [{ "body" => body, "user" => { "login" => "bot" }, "created_at" => "2026-09-13T00:00:00Z" }], trust
    ).first.first

    assert_equal "2026-09-13T00:00:00Z", FetchPrReviewData.compute_cutoff([normalized])
    assert_equal payload, normalized.fetch("payload_body")
  end

  def test_visible_checkpoint_accepts_configured_runner_prefixes
    payload = <<~MARKDOWN.chomp
      Address-review follow-up is complete.

      <details>
      <summary>Address-review checkpoint</summary>

      ```text
      address-review-checkpoint:v1
      kind: summary
      ```
      </details>
    MARKDOWN

    { "codex" => "Codex", "claude" => "Claude", "cursor" => "Cursor" }.each do |runner, display|
      body = "🤖 #{display} #{payload}"

      assert_equal "summary", FetchPrReviewData.visible_checkpoint_kind(body), runner
    end
  end

  def test_visible_checkpoint_in_a_four_backtick_example_does_not_advance_the_cutoff
    body = <<~MARKDOWN.chomp
      🤖 Codex address-review follow-up example:

      ````markdown
      Address-review follow-up is complete. The next routine scan can start after this comment.

      <details>
      <summary>Address-review checkpoint</summary>

      ```text
      address-review-checkpoint:v1
      kind: summary
      ```
      </details>
      ````
    MARKDOWN

    assert_nil FetchPrReviewData.visible_checkpoint_kind(body)
    assert_equal "", FetchPrReviewData.compute_cutoff([{ "body" => body, "created_at" => "2026-09-13T00:00:00Z" }])
  end

  def test_visible_checkpoint_requires_a_closed_disclosure_at_the_payload_boundary
    body = <<~MARKDOWN.chomp
      Address-review follow-up is complete. The next routine scan can start after this comment.

      <details>
      <summary>Address-review checkpoint</summary>

      ```text
      address-review-checkpoint:v1
      kind: summary
      ```
    MARKDOWN

    assert_nil FetchPrReviewData.visible_checkpoint_kind(body)
    assert_equal "", FetchPrReviewData.compute_cutoff([{ "body" => body, "created_at" => "2026-09-13T00:00:00Z" }])

    trailing_body = "#{body}\n</details>\nnot part of the checkpoint payload"
    assert_nil FetchPrReviewData.visible_checkpoint_kind(trailing_body)
    assert_equal "", FetchPrReviewData.compute_cutoff([{ "body" => trailing_body, "created_at" => "2026-09-13T00:00:00Z" }])
  end

  def test_visible_checkpoint_record_inside_html_comments_does_not_advance_the_cutoff
    ["<!--\n", "<!--\n"].each_with_index do |comment_opener, index|
      comment_closer = index.zero? ? "\n-->" : ""
      body = <<~MARKDOWN.chomp
        Address-review follow-up is complete. The next routine scan can start after this comment.

        <details>
        <summary>Address-review checkpoint</summary>

        #{comment_opener}```text
        address-review-checkpoint:v1
        kind: summary
        ```#{comment_closer}
        </details>
      MARKDOWN

      assert_nil FetchPrReviewData.visible_checkpoint_kind(body), "comment variant #{index}"
      assert_equal "", FetchPrReviewData.compute_cutoff([{ "body" => body, "created_at" => "2026-09-13T00:00:00Z" }])
    end
  end

  def test_visible_checkpoint_only_strips_eligible_inline_code_marker_literals
    checkpoint = lambda do |detail|
      <<~MARKDOWN.chomp
        Address-review follow-up is complete.

        <details>
        <summary>Address-review checkpoint</summary>

        ```text
        address-review-checkpoint:v1
        kind: summary
        ```

        #{detail}
        </details>
      MARKDOWN
    end

    ineligible_details = {
      "escaped opening delimiter" => "- Literal: \\`<!-- address-review-summary -->`.",
      "four-space indented literal" => "    `<!-- address-review-summary -->`",
      "tab-indented literal" => "\t`<!-- address-review-summary -->`",
      "unequal delimiters" => "- Literal: ``<!-- address-review-summary -->`.",
      "actual fenced code block" => "```text\n<!-- address-review-summary -->\n```"
    }
    (0..3).each do |spaces|
      ineligible_details["#{spaces} spaces plus tab-indented literal"] =
        "#{' ' * spaces}\t`<!-- address-review-summary -->`"
    end
    ineligible_details.each do |description, detail|
      body = checkpoint.call(detail)

      assert_nil FetchPrReviewData.visible_checkpoint_kind(body), description
      assert_equal "", FetchPrReviewData.compute_cutoff([{ "body" => body, "created_at" => "2026-09-13T00:00:00Z" }]), description
    end

    (0..4).each do |backslashes|
      detail = "- Literal: \\\\`<!-- address-review-summary -->#{'\\' * backslashes}`."

      assert_equal "summary", FetchPrReviewData.visible_checkpoint_kind(checkpoint.call(detail)), backslashes
    end
    assert_equal "summary", FetchPrReviewData.visible_checkpoint_kind(
      checkpoint.call(" ```<!-- address-review-summary -->```")
    )
    assert_equal "summary", FetchPrReviewData.visible_checkpoint_kind(
      checkpoint.call("- Fixed \\<details> parsing in a visible finding.")
    )
    (0..6).each do |backslashes|
      detail = "- Literal: #{'\\' * backslashes}<details>"
      kind = FetchPrReviewData.visible_checkpoint_kind(checkpoint.call(detail))
      if backslashes.odd?
        assert_equal "summary", kind, backslashes
      else
        assert_nil kind, backslashes
      end
    end
  end

  REVIEWS_RAW = <<~JSON
    [[
      {"id":10,"body":"fix the nil guard","state":"COMMENTED","user":{"login":"alice"},"submitted_at":"2026-01-04T00:00:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      {"id":11,"body":"","state":"APPROVED","user":{"login":"bob"}}
    ]]
  JSON

  INLINE_RAW = <<~JSON
    [[
      {"id":20,"node_id":"RC_20","path":"a.rb","user":{"login":"alice"},"pull_request_review_id":10,"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      {"id":21,"node_id":"RC_21","path":"b.rb","user":{"login":"alice"}},
      {"id":22,"node_id":"RC_22","path":"c.rb","user":{"login":"alice"}}
    ]]
  JSON

  THREADS_RAW = <<~JSON
    [{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
      {"id":"T_A","isResolved":true,"comments":{"nodes":[{"id":"RC_20","databaseId":20}]}},
      {"id":"T_B","isResolved":false,"comments":{"nodes":[{"id":"RC_21","databaseId":21}]}}
    ]}}}}}]
  JSON

  # These cases are about shaping, not trust, so every fixture actor is
  # actionable; the trust boundary itself is covered in the -trust-test suite.
  def trust
    config = GithubActorTrust.build_config(
      { "trusted_users" => %w[alice bob bot] },
      contents: "trusted_users: [alice, bob, bot]\n", path: "(test)", global: false
    )
    FetchPrReviewData::TrustBoundary.new(repo: "owner/repo", config:, source: "test")
  end

  def assembled
    FetchPrReviewData.assemble(
      repo: "owner/repo", pr_number: 1234,
      issue_raw: ISSUE_RAW, reviews_raw: REVIEWS_RAW, inline_raw: INLINE_RAW, threads_raw: THREADS_RAW,
      trust:
    )
  end

  def test_cutoff_is_latest_summary_marker_and_ignores_newer_status
    assert_equal "2026-01-03T00:00:00Z", assembled["review_cutoff_at"]
  end

  def test_cutoff_accepts_summary_as_first_payload_line_after_agent_envelope
    body = GitHubCommentEnvelope.render(
      body: "<!-- address-review-summary -->\ncurrent",
      runner: "codex",
      host: "M5",
      task_or_run: "task-7"
    )
    comments = [{ "body" => body, "user" => { "login" => "bot" }, "created_at" => "2026-01-05T00:00:00Z" }]
    normalized = FetchPrReviewData.build_issue_comments(comments, trust).first.first

    assert_equal "2026-01-05T00:00:00Z", FetchPrReviewData.compute_cutoff([normalized])
    assert_equal "<!-- address-review-summary -->\ncurrent", normalized.fetch("payload_body")
    assert_equal body, normalized.fetch("body")
  end

  def test_all_trusted_comment_collections_expose_the_unwrapped_payload_body
    payload = "Visible review feedback."
    body = GitHubCommentEnvelope.render(body: payload, runner: "codex", host: "M5", task_or_run: "task-7")
    review = { "id" => 10, "body" => body, "state" => "COMMENTED", "user" => { "login" => "alice" } }
    inline = { "id" => 20, "node_id" => "RC_20", "body" => body, "user" => { "login" => "alice" } }
    issue = { "id" => 30, "node_id" => "IC_30", "body" => body, "user" => { "login" => "alice" } }

    summary = FetchPrReviewData.build_review_summaries([review], trust).first.first
    comment = FetchPrReviewData.build_inline_comments([inline], {}, trust).first.first
    discussion = FetchPrReviewData.build_issue_comments([issue], trust).first.first

    [summary, comment, discussion].each do |row|
      assert_equal payload, row.fetch("payload_body")
      assert_equal body, row.fetch("body")
    end
  end

  def test_cutoff_rejects_a_legacy_html_envelope_with_a_suffixed_denial
    body = <<~BODY
      🤖 Codex No review checkpoint was recorded.
      <!-- agent-comment-attribution:v1
      runner: codex
      host: M5
      task_or_run: task-7
      -->

      <!-- address-review-summary -->
    BODY
    comments = [{ "body" => body, "user" => { "login" => "bot" }, "created_at" => "2026-01-05T00:00:00Z" }]
    normalized = FetchPrReviewData.build_issue_comments(comments, trust).first.first

    assert_empty FetchPrReviewData.compute_cutoff([normalized])
    assert_equal body, normalized.fetch("payload_body")
  end

  def test_drops_empty_review_summaries
    assert_equal([10], assembled["review_summaries"].map { |r| r["id"] })
  end

  # Production break: address-review cannot associate an inline concept with
  # its current walkthrough review, so it replies to and resolves that thread.
  def test_preserves_review_and_commit_identity_for_walkthrough_filtering
    summary = assembled["review_summaries"].fetch(0)
    comment = assembled["inline_comments"].find { |row| row["id"] == 20 }

    assert_equal "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", summary["commit_id"]
    assert_equal 10, comment["pull_request_review_id"]
    assert_equal "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", comment["commit_id"]
  end

  def test_joins_thread_metadata_by_node_id
    by_id = assembled["inline_comments"].to_h { |c| [c["id"], c] }
    assert_equal "T_A", by_id[20]["thread_id"]
    assert_equal true, by_id[20]["is_resolved"]
    assert_equal "T_B", by_id[21]["thread_id"]
    assert_equal false, by_id[21]["is_resolved"]
    # Orphan comment with no matching thread.
    assert_nil by_id[22]["thread_id"]
    assert_equal false, by_id[22]["is_resolved"]
  end

  def test_issue_comments_include_markers
    assert_equal 4, assembled["issue_comments"].length
  end

  def test_handles_empty_and_blank_inputs
    out = FetchPrReviewData.assemble(
      repo: "o/r", pr_number: 7, issue_raw: "", reviews_raw: "[]", inline_raw: "[[]]", threads_raw: nil,
      trust:
    )
    assert_equal "", out["review_cutoff_at"]
    assert_equal 0, out["inline_comments"].length
    assert_equal 0, out["review_threads"].length
  end

  def test_text_summary_counts
    text = FetchPrReviewData.text_summary(assembled)
    assert_includes text, "inline_comments: 3 (1 in resolved threads)"
    assert_includes text, "review_threads: 2 (1 resolved)"
  end

  def test_issue_comments_only_fetch_avoids_unrelated_review_endpoints
    runner = FetchPrReviewData::Runner.new
    calls = []
    runner.define_singleton_method(:rest) do |endpoint|
      calls << endpoint
      FetchPrReviewDataTest::ISSUE_RAW
    end
    runner.define_singleton_method(:capture!) { |*| raise "unexpected GraphQL fetch" }

    out = runner.send(:fetch, "owner/repo", 1234, trust, issue_comments_only: true)

    assert_equal ["repos/owner/repo/issues/1234/comments"], calls
    assert_equal 4, out.fetch("issue_comments").length
    assert_empty out.fetch("review_summaries")
    assert_empty out.fetch("inline_comments")
    assert_empty out.fetch("review_threads")
  end

  def test_issue_comments_only_option_is_parsed_and_documented
    options = FetchPrReviewData::Runner.new.send(:parse_args, ["1234", "--issue-comments-only"])

    assert options.fetch(:issue_comments_only)
    assert_includes FetchPrReviewData::USAGE, "--issue-comments-only"
  end

  def test_self_check_passes
    out, status = Open3.capture2("ruby", SCRIPT, "--self-check")
    assert status.success?, out
    assert_includes out, "self-check passed"
  end

  def test_help_exits_zero
    out, status = Open3.capture2e("ruby", SCRIPT, "--help")
    assert status.success?, out
    assert_includes out, "Usage: fetch-pr-review-data"
  end

  def test_rejects_non_integer_pr
    out, status = Open3.capture2e("ruby", SCRIPT, "not-a-number", "--repo", "owner/repo")
    refute status.success?
    assert_includes out, "positive integer PR number is required"
  end

  def test_rejects_zero_pr
    out, status = Open3.capture2e("ruby", SCRIPT, "0", "--repo", "owner/repo")
    refute status.success?
    assert_includes out, "positive integer PR number is required"
  end

  def test_rejects_bad_repo_form
    # gh is not reached for a malformed --repo, so this passes without network.
    out, status = Open3.capture2e("ruby", SCRIPT, "12", "--repo", "owneronly")
    refute status.success?
    assert_includes out, "--repo must be in OWNER/REPO form"
  end

  def test_rejects_repo_with_extra_path_segment
    out, status = Open3.capture2e("ruby", SCRIPT, "12", "--repo", "a/b/c")
    refute status.success?
    assert_includes out, "--repo must be in OWNER/REPO form"
  end

  def test_rejects_repo_with_empty_owner
    out, status = Open3.capture2e("ruby", SCRIPT, "12", "--repo", "/repo")
    refute status.success?
    assert_includes out, "--repo must be in OWNER/REPO form"
  end
end
