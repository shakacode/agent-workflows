#!/usr/bin/env ruby
# frozen_string_literal: true

# Mechanical contract tests for the Step 10 checkpoint template.
# Run with: ruby .agents/skills/address-review/bin/address-review-summary-template-test.rb

require "minitest/autorun"
require "open3"
require "shellwords"
require "tmpdir"
require_relative "../../pr-batch/lib/github_comment_envelope"

load File.expand_path("fetch-pr-review-data", __dir__)

class AddressReviewSummaryTemplateTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path("../references/templates.md", __dir__)

  def template
    @template ||= File.read(TEMPLATE_PATH, encoding: Encoding::UTF_8)
  end

  def section_after(start_marker, end_marker)
    start = template.index(start_marker)
    refute_nil start, "missing template marker: #{start_marker.inspect}"
    finish = template.index(end_marker, start)
    refute_nil finish, "missing template marker: #{end_marker.inspect}"

    template[start...(finish + end_marker.length)]
  end

  def assert_in_order(text, *fragments)
    cursor = 0
    fragments.each do |fragment|
      position = text.index(fragment, cursor)
      refute_nil position, "missing or out-of-order fragment: #{fragment.inspect}"
      cursor = position + fragment.length
    end
  end

  def test_primary_checkpoint_keeps_outcome_visible_and_metadata_in_closed_details
    primary = section_after(
      'POSTING_CLIENT="${POSTING_CLIENT:-UNKNOWN}"',
      '} > "${summary_body_file}"'
    )

    assert_in_order(
      primary,
      "printf 'Address-review follow-up is complete.",
      "printf '## Review follow-up complete\\n\\n'",
      "printf '## Review follow-up needs another pass\\n\\n'",
      "printf '<details>\\n'",
      "printf '<summary>Address-review checkpoint</summary>\\n\\n'",
      "printf '**Runtime:** %s · %s\\n\\n'",
      "printf '```text\\naddress-review-checkpoint:v1\\n'",
      "printf 'kind: summary\\n'",
      "printf 'kind: status\\n'",
      "printf '**Scan scope:** %s\\n\\n' \"${SCAN_SCOPE}\"",
      "printf '### Findings that mattered\\n'",
      "printf '### Optional suggestions\\n'",
      "printf '### Skipped items\\n'",
      "printf '**Deferred-work tracking:** %s\\n\\n' \"${TRACKING_OUTCOME}\"",
      "printf '\\n</details>\\n'"
    )
    assert_includes primary, "**Next scan:** Start after this comment. Say `check all reviews` to rescan the full PR."
    assert_includes primary, "**Next scan:** Use `check all reviews`; this comment is not a cutoff."
    assert_equal 1, primary.scan("\${SCAN_SCOPE}").length
    assert_operator primary.index("\${SCAN_SCOPE}"), :>, primary.index("printf '<summary>Address-review checkpoint</summary>")
    refute_includes primary, "<details open>"
    refute_includes primary, "<!--"
    assert_includes template, '"${PR_BATCH_SKILL_DIR}/bin/github-comment-envelope" post-issue'
  end

  def test_primary_writer_envelope_and_cutoff_round_trip
    primary = section_after(
      'POSTING_CLIENT="${POSTING_CLIENT:-UNKNOWN}"',
      '} > "${summary_body_file}"'
    )

    Dir.mktmpdir do |dir|
      output = File.join(dir, "summary.md")
      environment = {
        "CUTOFF_SAFE" => "1",
        "SCAN_SCOPE" => "template test",
        "POSTING_CLIENT" => "Codex",
        "POSTING_MODEL_FAMILY" => "Astra",
        "TRACKING_OUTCOME" => "",
        "OPTIONAL_OUTCOMES" => ""
      }
      _stdout, stderr, status = Open3.capture3(
        environment, "sh", "-c", "summary_body_file=#{Shellwords.escape(output)}\n#{primary}"
      )
      assert status.success?, stderr

      payload = File.read(output)
      body = GitHubCommentEnvelope.render(body: payload, runner: "codex", host: "test-host", task_or_run: "template")
      normalized_payload = GitHubCommentEnvelope.payload(body)

      assert_equal payload, normalized_payload
      assert_equal "2026-09-13T00:00:00Z", FetchPrReviewData.compute_cutoff([
        { "body" => body, "payload_body" => normalized_payload, "created_at" => "2026-09-13T00:00:00Z" }
      ])

      {
        "before the disclosure" => payload.sub("\n<details>", "\n<pre>\n<details>"),
        "after the summary" => payload.sub("</summary>\n\n", "</summary>\n\n<pre>\n")
      }.each do |placement, malformed_payload|
        malformed_body = GitHubCommentEnvelope.render(
          body: malformed_payload, runner: "codex", host: "test-host", task_or_run: "template"
        )
        assert_nil FetchPrReviewData.visible_checkpoint_kind(malformed_body), placement
        assert_equal "", FetchPrReviewData.compute_cutoff([
          { "body" => malformed_body, "payload_body" => malformed_payload, "created_at" => "2026-09-13T00:00:00Z" }
        ]), placement
      end
    end
  end

  def test_source_writer_envelope_and_cutoff_round_trip
    source = section_after(
      "  SOURCE_STATE_HAS_PENDING=0",
      '} > "${source_summary_body_file}"'
    )

    Dir.mktmpdir do |dir|
      output = File.join(dir, "source-summary.md")
      environment = {
        "SOURCE_CUTOFF_SAFE" => "1",
        "SOURCE_STATE_ROWS" => "item\t160\tissue-comment\t1\t-\t2026-09-13T00:00:00Z\thandled",
        "REPLACEMENT_PR_URL" => "https://github.com/shakacode/agent-workflows/pull/817",
        "SOURCE_OUTCOMES" => "- Source feedback handled.",
        "POSTING_CLIENT" => "Codex",
        "POSTING_MODEL_FAMILY" => "Astra"
      }
      _stdout, stderr, status = Open3.capture3(
        environment, "sh", "-c", "source_summary_body_file=#{Shellwords.escape(output)}\n#{source}"
      )
      assert status.success?, stderr

      payload = File.read(output)
      body = GitHubCommentEnvelope.render(body: payload, runner: "codex", host: "test-host", task_or_run: "template")
      normalized_payload = GitHubCommentEnvelope.payload(body)

      assert_equal payload, normalized_payload
      assert_equal "summary", FetchPrReviewData.visible_checkpoint_kind(normalized_payload)
      assert_equal "2026-09-13T00:00:00Z", FetchPrReviewData.compute_cutoff([
        { "body" => body, "payload_body" => normalized_payload, "created_at" => "2026-09-13T00:00:00Z" }
      ])
    end
  end

  def test_posting_identity_uses_unknown_when_runtime_metadata_is_unavailable
    assert_includes template, 'POSTING_CLIENT="${POSTING_CLIENT:-UNKNOWN}"'
    assert_includes template, 'POSTING_MODEL_FAMILY="${POSTING_MODEL_FAMILY:-UNKNOWN}"'
    refute_includes template, "\${POSTING_CLIENT:?"
    refute_includes template, "\${POSTING_MODEL_FAMILY:?"
    assert_equal 2, template.scan("printf '**Runtime:** %s · %s\\n\\n'").length
  end

  def test_source_checkpoint_keeps_auditable_details_and_source_state
    source = section_after(
      "  SOURCE_STATE_HAS_PENDING=0",
      '} > "${source_summary_body_file}"'
    )

    assert_in_order(
      source,
      "printf 'Original review follow-up is complete.",
      "printf '## Original review follow-up complete\\n\\n'",
      "printf '## Original review follow-up needs another pass\\n\\n'",
      "printf '<details>\\n'",
      "printf '<summary>Address-review checkpoint</summary>\\n\\n'",
      "printf '**Runtime:** %s · %s\\n\\n'",
      "printf '```text\\naddress-review-checkpoint:v1\\n'",
      "printf 'kind: summary\\n'",
      "printf 'kind: status\\n'",
      "printf '**Replacement PR:** %s\\n\\n' \"${REPLACEMENT_PR_URL}\"",
      "printf '### Carried-over review outcomes\\n'",
      "printf '%s\\n\\n' \"${SOURCE_OUTCOMES}\"",
      "printf '```text\\naddress-review-source-state:v1\\n'",
      "printf '```\\n\\n</details>\\n'"
    )
    assert_includes source, "Every carried-over review item has a recorded outcome."
    assert_includes source, "Some carried-over review items still need an explicit outcome"
    refute_includes source, "<details open>"
    refute_includes source, "<!--"
  end

  def test_template_never_requests_open_details
    refute_includes template, "<details open>"
    assert_equal 2, template.scan("printf '<details>\\n'").length
  end

  def test_template_read_is_independent_of_default_external_encoding
    with_default_external_encoding(Encoding::US_ASCII) do
      assert_equal Encoding::UTF_8, template.encoding
      assert_equal 2, template.scan("printf '<details>\\n'").length
    end
  end

  private

  def with_default_external_encoding(encoding)
    original = Encoding.default_external
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = original
  end
end
