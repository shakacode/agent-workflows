#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

SCRIPT = File.expand_path("validate-review-findings", __dir__)
load SCRIPT

class ValidateReviewFindingsTest < Minitest::Test
  FIXTURE_ROOT = File.expand_path("../test/fixtures/review-findings", __dir__)
  PROVENANCE_GUIDANCE_PATHS = %w[
    skills/adversarial-pr-review/SKILL.md
    skills/autoreview/SKILL.md
    workflows/continuous-evaluation-loop.md
    skills/post-merge-audit/SKILL.md
    skills/address-review/SKILL.md
  ].freeze
  PROVENANCE_GUIDANCE = "Populate optional receipt `provenance.model`, `provenance.effort`, and " \
                        "`provenance.usage` only from host-reported evidence for the actual review run."
  UNKNOWN_GUIDANCE = "Use literal `UNKNOWN` for unavailable values; never infer them or treat prompt text or " \
                     "model self-report as binding evidence."

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

  def test_docs_define_stable_usage_metrics_and_unknown_semantics
    path = File.expand_path("../docs/review-finding-schema.md", __dir__)
    text = File.read(path)

    assert_includes text, "Older receipts that omit all three fields remain valid."
    assert_includes text, "exact uppercase `UNKNOWN`"
    assert_includes text, "`cache_read_tokens` is not added to `total_tokens` by the validator"
    assert_includes text, "at least the sum of every known `input_tokens` and `output_tokens` component"
    assert_includes text, "Do not store raw prompts, responses, or transcript text"
    assert_includes text, "Cost per verified finding"
    assert_includes text, "False-positive rate"
    assert_includes text, "versioned external pricing snapshot"
  end

  def test_receipt_emitters_share_host_evidence_guidance
    root = File.expand_path("..", __dir__)

    PROVENANCE_GUIDANCE_PATHS.each do |relative_path|
      text = File.read(File.join(root, relative_path))
      assert_includes text, PROVENANCE_GUIDANCE, relative_path
      assert_includes text, UNKNOWN_GUIDANCE, relative_path
    end
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

  def test_representative_codex_and_claude_receipts_pass
    %w[codex-receipt-valid.json claude-receipt-valid.json].each do |name|
      path = File.join(FIXTURE_ROOT, name)

      assert_empty ValidateReviewFindings.validate_path(path), name
    end
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

  def test_receipt_provenance_rejects_negative_token_counts
    document = fixture_document("autoreview-receipt-valid.json")
    document.fetch("review_receipt").fetch("provenance").merge!(
      "model" => "gpt-5.6-sol",
      "effort" => "xhigh",
      "usage" => {
        "input_tokens" => -1,
        "output_tokens" => 34,
        "cache_read_tokens" => 100,
        "total_tokens" => 134
      }
    )

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: provenance.usage.input_tokens must be a nonnegative integer or UNKNOWN"
  end

  def test_receipt_provenance_validates_optional_field_shapes_and_unknown_sentinel
    document = fixture_document("autoreview-receipt-valid.json")
    provenance = document.fetch("review_receipt").fetch("provenance")
    provenance["model"] = []
    provenance["effort"] = "unknown"
    provenance["usage"] = "unknown"

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures, "report: review_receipt: provenance.model must be a non-empty string"
    assert_includes failures, "report: review_receipt: provenance.effort must use literal UNKNOWN when unknown"
    assert_includes failures, "report: review_receipt: provenance.usage must be an object or literal UNKNOWN"
  end

  def test_receipt_provenance_usage_requires_all_stable_metric_fields
    document = fixture_document("autoreview-receipt-valid.json")
    document.fetch("review_receipt").fetch("provenance")["usage"] = {
      "input_tokens" => 100,
      "output_tokens" => 25
    }

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures, "report: review_receipt: provenance.usage.cache_read_tokens must be present"
    assert_includes failures, "report: review_receipt: provenance.usage.total_tokens must be present"
  end

  def test_receipt_provenance_rejects_inconsistent_known_total
    document = fixture_document("autoreview-receipt-valid.json")
    usage = {
      "input_tokens" => 100,
      "output_tokens" => 25,
      "cache_read_tokens" => 80,
      "total_tokens" => 124
    }
    document.fetch("review_receipt").fetch("provenance")["usage"] = usage

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: provenance.usage.total_tokens cannot be less than known input_tokens + output_tokens"

    usage["total_tokens"] = 125
    assert_empty ValidateReviewFindings.validate_document(document, "report")
  end

  def test_receipt_provenance_total_covers_every_known_primary_token_component
    document = fixture_document("autoreview-receipt-valid.json")
    document.fetch("review_receipt").fetch("provenance")["usage"] = {
      "input_tokens" => "UNKNOWN",
      "output_tokens" => 25,
      "cache_read_tokens" => "UNKNOWN",
      "total_tokens" => 24
    }

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: provenance.usage.total_tokens cannot be less than known input_tokens + output_tokens"
  end

  def test_receipt_provenance_accepts_literal_unknown_values
    document = fixture_document("autoreview-receipt-valid.json")
    provenance = document.fetch("review_receipt").fetch("provenance")
    provenance.merge!("model" => "UNKNOWN", "effort" => "UNKNOWN", "usage" => "UNKNOWN")
    assert_empty ValidateReviewFindings.validate_document(document, "report")

    provenance["usage"] = ValidateReviewFindings::PROVENANCE_USAGE_FIELDS.to_h { |field| [field, "UNKNOWN"] }
    assert_empty ValidateReviewFindings.validate_document(document, "report")
  end

  def test_receipt_provenance_rejects_non_integral_token_counts
    [1.5, true, "12", nil, "unknown"].each do |value|
      document = fixture_document("autoreview-receipt-valid.json")
      document.fetch("review_receipt").fetch("provenance")["usage"] = {
        "input_tokens" => 100,
        "output_tokens" => value,
        "cache_read_tokens" => 25,
        "total_tokens" => 150
      }

      assert_includes ValidateReviewFindings.validate_document(document, "report"),
                      "report: review_receipt: provenance.usage.output_tokens must be a nonnegative integer or UNKNOWN"
    end
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
    finding_target = document.fetch("review_findings").first.fetch("target")
    target["base_sha"] = "origin/main"
    target["head_sha"] = "HEAD"
    finding_target["head_sha"] = target["head_sha"]

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures,
                    "report: review_receipt: committed target.base_sha must be a full hexadecimal Git object ID"
    assert_includes failures,
                    "report: review_receipt: committed target.head_sha must be a full hexadecimal Git object ID"

    target["base_sha"] = "a" * 64
    target["head_sha"] = "b" * 64
    finding_target["head_sha"] = target["head_sha"]
    assert_empty ValidateReviewFindings.validate_document(document, "report")

    target["base_sha"] = "A" * 40
    target["head_sha"] = "B" * 40
    finding_target["head_sha"] = target["head_sha"]
    assert_empty ValidateReviewFindings.validate_document(document, "report")

    target["base_sha"] = "A" * 40
    target["head_sha"] = "B" * 64
    finding_target["head_sha"] = target["head_sha"]
    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_receipt: committed target base_sha and head_sha must use the same Git object format"

    target["base_sha"] = "a" * 39
    target["head_sha"] = "g" * 40
    finding_target["head_sha"] = target["head_sha"]
    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures,
                    "report: review_receipt: committed target.base_sha must be a full hexadecimal Git object ID"
    assert_includes failures,
                    "report: review_receipt: committed target.head_sha must be a full hexadecimal Git object ID"
  end

  def test_finding_head_must_match_receipt_head_when_both_are_present
    document = fixture_document("autoreview-receipt-valid.json")
    receipt_head = document.fetch("review_receipt").fetch("target").fetch("head_sha")
    finding_target = document.fetch("review_findings").first.fetch("target")
    finding_target["head_sha"] = "f" * 40

    assert_includes ValidateReviewFindings.validate_document(document, "report"),
                    "report: review_findings[0]: target.head_sha must match review_receipt.target.head_sha"

    finding_target["head_sha"] = receipt_head.upcase
    assert_empty ValidateReviewFindings.validate_document(document, "report")

    finding_target.delete("head_sha")
    assert_empty ValidateReviewFindings.validate_document(document, "report")

    ["", " ", 123].each do |malformed_head|
      finding_target["head_sha"] = malformed_head
      assert_includes ValidateReviewFindings.validate_document(document, "report"),
                      "report: review_findings[0]: target.head_sha must be a non-empty string when review_receipt target is present"
    end
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
                    "report: review_receipt.source must be one of: autoreview, adversarial-pr-review, " \
                    "continuous-evaluation-loop, post-merge-audit, address-review"
  end

  def test_named_review_workflows_are_valid_receipt_sources
    %w[adversarial-pr-review continuous-evaluation-loop post-merge-audit address-review].each do |source|
      document = fixture_document("autoreview-receipt-valid.json")
      document.fetch("review_receipt")["source"] = source
      document.fetch("review_findings").first["source"] = source

      assert_empty ValidateReviewFindings.validate_document(document, source), source
    end
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

  def test_invalid_findings_container_does_not_hide_receipt_failures
    document = fixture_document("autoreview-receipt-valid.json")
    document["review_findings"] = {}
    document.fetch("review_receipt").delete("source")

    failures = ValidateReviewFindings.validate_document(document, "report")
    assert_includes failures, "report: review_findings must be an array"
    assert_includes failures, "report: review_receipt.source must be a non-empty string"
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
