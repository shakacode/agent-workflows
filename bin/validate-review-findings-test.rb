#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

SCRIPT = File.expand_path("validate-review-findings", __dir__)
load SCRIPT

class ValidateReviewFindingsTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("../test/fixtures/review-findings", __dir__)

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

  def fixture_document(name)
    JSON.parse(File.read(File.join(FIXTURE_ROOT, name)))
  end

  def test_docs_example_passes
    path = File.expand_path("../docs/review-finding-schema.md", __dir__)

    assert_empty ValidateReviewFindings.validate_path(path)
  end

  def test_legacy_v0_document_without_receipt_still_passes
    assert_empty ValidateReviewFindings.validate_document(valid_document, "report")
  end

  def test_receipt_fixture_requires_independent_validation_for_p1
    path = File.join(FIXTURE_ROOT, "autoreview-receipt-invalid.json")

    assert_includes ValidateReviewFindings.validate_path(path),
                    "#{path}: review_findings[0]: consequential finding requires independent_validation"
  end

  def test_valid_receipt_fixture_passes
    path = File.join(FIXTURE_ROOT, "autoreview-receipt-valid.json")

    assert_empty ValidateReviewFindings.validate_path(path)
  end

  def test_review_receipt_shape_is_validated
    document = fixture_document("autoreview-receipt-valid.json")
    receipt = document.fetch("review_receipt")
    receipt.fetch("target").delete("head_sha")
    receipt.fetch("provenance")["engine"] = " "
    receipt.fetch("risk_lenses").first["status"] = "selected"
    receipt.fetch("coverage")["status"] = "covered"
    receipt.fetch("coverage")["limitations"] = "none"

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures, "report: review_receipt: target.head_sha must be a non-empty string"
    assert_includes failures, "report: review_receipt: provenance.engine must be a non-empty string"
    assert_includes failures,
                    "report: review_receipt: risk_lenses[0]: status must be one of: applied, not_applicable, degraded, unknown"
    assert_includes failures, "report: review_receipt: coverage: status must be one of: complete, partial, unknown"
    assert_includes failures, "report: review_receipt: coverage: limitations must be an array"
  end

  def test_independent_validation_shape_is_validated
    document = fixture_document("autoreview-receipt-valid.json")
    validation = document.fetch("review_findings").first.fetch("independent_validation")
    validation["status"] = "approved"
    validation["validator"] = " "
    validation["evidence"] = []

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures,
                    "report: review_findings[0]: independent_validation: status must be one of: confirmed, rejected, degraded"
    assert_includes failures,
                    "report: review_findings[0]: independent_validation.validator must be a non-empty string"
    assert_includes failures,
                    "report: review_findings[0]: independent_validation.evidence must be a non-empty array of strings"
  end

  def test_explicit_lower_severity_consequential_finding_requires_validation
    document = valid_document
    finding = document.fetch("review_findings").first
    finding["severity"] = "P2"
    finding["consequential"] = true

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[0]: consequential finding requires independent_validation"

    finding["consequential"] = "yes"
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[0]: consequential must be true or false"
  end

  def test_degraded_independent_validation_cannot_clear_consequential_finding
    document = fixture_document("autoreview-receipt-valid.json")
    finding = document.fetch("review_findings").first
    finding.fetch("independent_validation")["status"] = "degraded"
    finding["disposition"] = "accepted_fixed"

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[0]: degraded independent validation requires must_fix, needs_decision, or unknown disposition"

    finding["disposition"] = "unknown"
    assert_empty ValidateReviewFindings.validate_document(document, "report")
  end

  def test_confirmed_and_rejected_validation_match_finding_disposition
    document = fixture_document("autoreview-receipt-valid.json")
    finding = document.fetch("review_findings").first

    finding["disposition"] = "rejected_false_positive"
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[0]: confirmed independent validation cannot use a rejected disposition"

    finding.fetch("independent_validation")["status"] = "rejected"
    finding["disposition"] = "must_fix"
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[0]: rejected independent validation requires a rejected or unknown disposition"

    finding["disposition"] = "rejected_false_positive"
    assert_empty ValidateReviewFindings.validate_document(document, "report")
  end

  def test_complete_coverage_rejects_degraded_or_excluded_surface
    document = fixture_document("autoreview-receipt-valid.json")
    coverage = document.fetch("review_receipt").fetch("coverage")
    coverage["status"] = "complete"

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: complete coverage cannot include degraded or unknown lenses, excluded paths, or limitations"
  end

  def test_receipt_target_kind_is_required_and_uncommitted_cannot_be_complete
    document = fixture_document("autoreview-receipt-valid.json")
    target = document.fetch("review_receipt").fetch("target")

    target.delete("kind")
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: target.kind must be one of: committed, uncommitted"

    target["kind"] = "uncommitted"
    coverage = document.fetch("review_receipt").fetch("coverage")
    coverage["status"] = "complete"
    coverage["limitations"] = []
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: uncommitted target requires partial or unknown coverage with limitations"
  end

  def test_committed_receipt_requires_immutable_base_sha
    document = fixture_document("autoreview-receipt-valid.json")
    document.fetch("review_receipt").fetch("target").delete("base_sha")

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: target.base_sha must be a non-empty string"
  end

  def test_committed_receipt_rejects_symbolic_or_abbreviated_object_ids
    document = fixture_document("autoreview-receipt-valid.json")
    target = document.fetch("review_receipt").fetch("target")
    target["base_sha"] = "origin/main"
    target["head_sha"] = "HEAD"

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures,
                    "report: review_receipt: committed target.base_sha must be a full hexadecimal Git object ID"
    assert_includes failures,
                    "report: review_receipt: committed target.head_sha must be a full hexadecimal Git object ID"

    target["base_sha"] = "a" * 64
    target["head_sha"] = "b" * 64
    assert_empty ValidateReviewFindings.validate_document(document, "report")

    target["base_sha"] = "A" * 40
    target["head_sha"] = "B" * 64
    assert_empty ValidateReviewFindings.validate_document(document, "report")

    target["base_sha"] = "a" * 39
    target["head_sha"] = "g" * 40
    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures,
                    "report: review_receipt: committed target.base_sha must be a full hexadecimal Git object ID"
    assert_includes failures,
                    "report: review_receipt: committed target.head_sha must be a full hexadecimal Git object ID"
  end

  def test_autoreview_receipt_requires_source_and_unique_core_lenses
    document = fixture_document("autoreview-receipt-valid.json")
    receipt = document.fetch("review_receipt")

    receipt.delete("source")
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt.source must be a non-empty string"

    receipt["source"] = "autoreview"
    receipt["risk_lenses"] = [
      { "name" => "performance", "status" => "not_applicable", "reason" => "No performance-sensitive changes." }
    ]
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: autoreview risk_lenses must include: correctness, security"

    receipt["risk_lenses"] = [
      { "name" => "correctness", "status" => "applied", "reason" => "Core lens." },
      { "name" => "correctness", "status" => "applied", "reason" => "Duplicate lens." },
      { "name" => "security", "status" => "applied", "reason" => "Core lens." }
    ]
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: risk_lenses names must be unique"
  end

  def test_receipt_source_cannot_bypass_autoreview_lenses_with_alias
    document = fixture_document("autoreview-receipt-valid.json")
    receipt = document.fetch("review_receipt")
    receipt["source"] = "autoreview "
    receipt["risk_lenses"] = [
      { "name" => "performance", "status" => "not_applicable", "reason" => "No performance-sensitive changes." }
    ]

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt.source must be one of: autoreview"
  end

  def test_receipt_status_fields_are_required
    document = fixture_document("autoreview-receipt-valid.json")
    receipt = document.fetch("review_receipt")
    receipt.fetch("risk_lenses").first.delete("status")
    receipt.fetch("coverage").delete("status")
    document.fetch("review_findings").first.fetch("independent_validation").delete("status")

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures, "report: review_receipt: risk_lenses[0].status must be present"
    assert_includes failures, "report: review_receipt: coverage.status must be present"
    assert_includes failures, "report: review_findings[0]: independent_validation.status must be present"
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

  def test_missing_report_path_fails_without_backtrace
    Dir.mktmpdir("validate-review-findings") do |dir|
      path = File.join(dir, "missing.md")
      failures = ValidateReviewFindings.validate_path(path)

      assert_equal 1, failures.length
      assert_match(/\A#{Regexp.escape(path)}: /, failures.first)
      assert_includes failures.first, "No such file"
    end
  end
end
