#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"

SCRIPT = File.expand_path("validate-review-findings", __dir__)
load SCRIPT

class ValidateReviewFindingsTest < Minitest::Test
  def valid_document
    {
      "schema" => "review-finding-v0",
      "review_findings" => [
        {
          "id" => "adv-001",
          "source" => "adversarial-pr-review",
          "target" => {
            "repo" => "OWNER/REPO",
            "pr" => 123,
            "head_sha" => "abc123"
          },
          "severity" => "P1",
          "disposition" => "must_fix",
          "title" => "Current-head check result is stale",
          "body" => "The readiness report cites a check run from an older head SHA.",
          "verification" => {
            "status" => "verified",
            "current_head_state" => "stale"
          },
          "location" => {
            "file" => "workflows/pr-processing.md",
            "line" => 650
          },
          "evidence" => [
            "PR head SHA: abc123",
            "Check run SHA: def456"
          ]
        }
      ]
    }
  end

  def test_docs_example_passes
    path = File.expand_path("../docs/review-finding-schema.md", __dir__)

    assert_empty ValidateReviewFindings.validate_path(path)
  end

  def test_valid_document_passes
    assert_empty ValidateReviewFindings.validate_document(valid_document, "report")
  end

  def test_missing_required_field_fails
    document = valid_document
    document["review_findings"].first.delete("verification")

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[0]: missing required fields: verification"
  end

  def test_invalid_enum_values_fail
    document = valid_document
    finding = document["review_findings"].first
    finding["severity"] = "BLOCKING"
    finding["disposition"] = "ready"
    finding["verification"]["status"] = "confirmed"
    finding["verification"]["current_head_state"] = "latest"

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures, "report: review_findings[0]: severity must be one of: P0, P1, P2, P3, INFO"
    assert_includes failures, "report: review_findings[0]: disposition must be one of: must_fix, needs_decision, should_fix, accepted_fixed, deferred, waived_by_maintainer, rejected_false_positive, rejected_not_actionable, unknown"
    assert_includes failures, "report: review_findings[0]: verification: status must be one of: unverified, verified, contradicted, unknown"
    assert_includes failures, "report: review_findings[0]: verification: current_head_state must be one of: current, stale, not_applicable, unknown"
  end

  def test_duplicate_ids_fail
    document = valid_document
    document["review_findings"] << document["review_findings"].first.dup

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[1]: id must be unique within the report"
  end

  def test_markdown_without_review_findings_block_fails
    failures = ValidateReviewFindings.validate_markdown("# Empty\n", "example.md")

    assert_equal ["example.md: missing ```json review-findings fenced block"], failures
  end
end
