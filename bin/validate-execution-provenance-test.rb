#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class ValidateExecutionProvenanceTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin/validate-execution-provenance")
  FIXTURE_ROOT = File.join(ROOT, "test/fixtures/execution-provenance")

  def valid_document
    JSON.parse(File.read(File.join(FIXTURE_ROOT, "bound-exact-match-valid.json")))
  end

  def test_valid_exact_match_fixture_passes
    fixture = File.join(FIXTURE_ROOT, "bound-exact-match-valid.json")
    stdout, stderr, status = Open3.capture3(SCRIPT, fixture)

    assert status.success?, stderr
    assert_equal "PASS execution provenance schema\n", stdout
  end

  def test_docs_example_passes
    path = File.join(ROOT, "docs/execution-provenance-schema.md")

    assert_empty ValidateExecutionProvenance.validate_path(path)
  end

  def test_representative_disposition_fixtures_pass
    %w[
      bound-exact-match-valid.json
      unbound-exact-route-valid.json
      silent-substitution-valid.json
      coordinator-pair-inheritance-valid.json
      authorized-fallback-valid.json
    ].each do |name|
      assert_empty ValidateExecutionProvenance.validate_path(File.join(FIXTURE_ROOT, name)), name
    end
  end

  def test_repository_validation_runs_the_schema_and_its_tests
    validate = File.read(File.join(ROOT, "bin/validate"))

    assert_includes validate, "ruby bin/validate-execution-provenance-test.rb"
    assert_includes validate, "ruby bin/validate-execution-provenance"
  end

  def test_routing_and_review_docs_link_the_execution_receipt_contract
    routing = File.read(File.join(ROOT, "docs/agent-workflows-model-routing.md"))
    review = File.read(File.join(ROOT, "docs/review-finding-schema.md"))

    assert_includes routing, "[execution-provenance receipt schema](execution-provenance-schema.md)"
    assert_includes review, "[execution-provenance receipt](execution-provenance-schema.md)"
    assert_includes review, "does not replace a lane execution-provenance receipt"
  end

  def test_required_shape_and_closed_enums_are_validated
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt.delete("batch")
    receipt["role"] = "coding"
    receipt["route_policy"] = "best-effort"

    failures = ValidateExecutionProvenance.validate_document(document, "receipt")

    assert_includes failures, "receipt: execution_provenance.batch must be present"
    assert_includes failures,
                    "receipt: execution_provenance.role must be one of: implementation, review, QA, integration"
    assert_includes failures, "receipt: execution_provenance.route_policy must be exact-route"
  end

  def test_requested_and_observed_evidence_are_explicit_and_host_bound
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt.fetch("observed").delete("effort")
    receipt.fetch("observed")["model"] = "ＵＮＫＮＯＷＮ"
    receipt["binding_source"] = "model-self-report"

    failures = ValidateExecutionProvenance.validate_document(document, "receipt")

    assert_includes failures, "receipt: execution_provenance.observed.effort must be explicitly present"
    assert_includes failures,
                    "receipt: execution_provenance.observed.model must use literal UNKNOWN when unknown"
    assert_includes failures,
                    "receipt: execution_provenance.binding_source must be one of: host-session-metadata, " \
                    "structured-command-result, structured-api-result, UNKNOWN"
  end

  def test_unknown_observed_exact_route_requires_mismatch_disposition
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt["observed"] = { "model" => "UNKNOWN", "effort" => "UNKNOWN" }
    receipt["binding_source"] = "UNKNOWN"
    receipt["mismatch_reason"] = "Host route metadata was unavailable."

    failures = ValidateExecutionProvenance.validate_document(document, "receipt")
    assert_includes failures,
                    "receipt: execution_provenance.disposition bound-exact-match requires a known observed tuple"

    receipt["disposition"] = "unbound-exact-route"
    assert_empty ValidateExecutionProvenance.validate_document(document, "receipt")
  end

  def test_unknown_observed_tuple_cannot_satisfy_an_authorized_fallback
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt["observed"] = { "model" => "UNKNOWN", "effort" => "UNKNOWN" }
    receipt["binding_source"] = "UNKNOWN"
    receipt["mismatch_reason"] = "Host route metadata was unavailable."
    receipt["recorded_authority"] = "Maintainer approved a fallback."
    receipt["disposition"] = "authorized-fallback"

    assert_includes ValidateExecutionProvenance.validate_document(document, "receipt"),
                    "receipt: execution_provenance.authorized-fallback requires a known observed tuple"
  end

  def test_authorized_fallback_requires_recorded_authority
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt.fetch("observed")["model"] = "gpt-5.6-terra"
    receipt["mismatch_reason"] = "The exact route was unavailable before launch."
    receipt["disposition"] = "authorized-fallback"

    failures = ValidateExecutionProvenance.validate_document(document, "receipt")
    assert_includes failures,
                    "receipt: execution_provenance.authorized-fallback requires non-UNKNOWN recorded_authority"

    receipt["recorded_authority"] = "Justin approved the fallback before launch."
    assert_empty ValidateExecutionProvenance.validate_document(document, "receipt")

    receipt["disposition"] = "silent-substitution"
    assert_includes ValidateExecutionProvenance.validate_document(document, "receipt"),
                    "receipt: execution_provenance.silent-substitution requires recorded_authority UNKNOWN"
  end

  def test_disposition_must_match_route_and_binding_evidence
    substituted = valid_document
    substituted_receipt = substituted.fetch("execution_provenance")
    substituted_receipt.fetch("observed")["model"] = "gpt-5.6-terra"
    assert_includes ValidateExecutionProvenance.validate_document(substituted, "receipt"),
                    "receipt: execution_provenance.bound-exact-match requires observed to equal requested"

    silent = valid_document
    silent_receipt = silent.fetch("execution_provenance")
    silent_receipt["disposition"] = "silent-substitution"
    silent_receipt["mismatch_reason"] = "Observed route differed."
    assert_includes ValidateExecutionProvenance.validate_document(silent, "receipt"),
                    "receipt: execution_provenance.silent-substitution requires observed to differ from requested"

    mixed = valid_document
    mixed.fetch("execution_provenance").fetch("observed")["effort"] = "UNKNOWN"
    assert_includes ValidateExecutionProvenance.validate_document(mixed, "receipt"),
                    "receipt: execution_provenance.observed must be entirely known or entirely UNKNOWN"

    unbound = valid_document
    unbound_receipt = unbound.fetch("execution_provenance")
    unbound_receipt["observed"] = { "model" => "UNKNOWN", "effort" => "UNKNOWN" }
    unbound_receipt["disposition"] = "unbound-exact-route"
    unbound_receipt["mismatch_reason"] = "Host route metadata was unavailable."
    assert_includes ValidateExecutionProvenance.validate_document(unbound, "receipt"),
                    "receipt: execution_provenance.UNKNOWN observed tuple requires binding_source UNKNOWN"
  end

  def test_influenced_commits_and_attribution_confidence_are_validated
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt["influenced_commits"] = ["abc123", "g" * 40]
    receipt["attribution_confidence"] = "probable"

    failures = ValidateExecutionProvenance.validate_document(document, "receipt")
    assert_includes failures,
                    "receipt: execution_provenance.influenced_commits[0] must be a full hexadecimal Git object ID"
    assert_includes failures,
                    "receipt: execution_provenance.influenced_commits[1] must be a full hexadecimal Git object ID"
    assert_includes failures,
                    "receipt: execution_provenance.attribution_confidence must be one of: exact, timeline-derived, mixed, UNKNOWN"

    receipt["influenced_commits"] = []
    receipt["attribution_confidence"] = "exact"
    assert_includes ValidateExecutionProvenance.validate_document(document, "receipt"),
                    "receipt: execution_provenance.exact attribution requires at least one influenced commit"

    receipt["influenced_commits"] = ["a" * 64]
    assert_empty ValidateExecutionProvenance.validate_document(document, "receipt")
  end

  def test_timestamps_are_rfc3339_and_ordered
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt["started_at"] = "2026-08-11 10:00:00"
    receipt["ended_at"] = "yesterday"

    failures = ValidateExecutionProvenance.validate_document(document, "receipt")
    assert_includes failures, "receipt: execution_provenance.started_at must be an RFC 3339 timestamp"
    assert_includes failures, "receipt: execution_provenance.ended_at must be an RFC 3339 timestamp"

    receipt["started_at"] = "2026-08-11T10:00:00-10:00"
    receipt["ended_at"] = "2026-08-11T09:59:59-10:00"
    assert_includes ValidateExecutionProvenance.validate_document(document, "receipt"),
                    "receipt: execution_provenance.ended_at must not precede started_at"
  end

  def test_identity_host_and_reason_fields_are_explicit
    document = valid_document
    receipt = document.fetch("execution_provenance")
    receipt["batch"] = " "
    receipt.fetch("host").delete("version")
    receipt["dispatcher"] = "unknown"
    receipt["session_id"] = "unknown"
    receipt["mismatch_reason"] = "ＵＮＫＮＯＷＮ"

    failures = ValidateExecutionProvenance.validate_document(document, "receipt")
    assert_includes failures, "receipt: execution_provenance.batch must be a non-empty string"
    assert_includes failures, "receipt: execution_provenance.host.version must be explicitly present"
    assert_includes failures, "receipt: execution_provenance.dispatcher must use literal UNKNOWN when unknown"
    assert_includes failures, "receipt: execution_provenance.session_id must use literal UNKNOWN when unknown"
    assert_includes failures,
                    "receipt: execution_provenance.mismatch_reason must use literal UNKNOWN when unknown"
  end

  def test_mismatch_reason_and_authority_match_the_disposition
    exact = valid_document
    exact.fetch("execution_provenance")["mismatch_reason"] = "No mismatch."
    assert_includes ValidateExecutionProvenance.validate_document(exact, "receipt"),
                    "receipt: execution_provenance.bound-exact-match requires mismatch_reason UNKNOWN"

    silent = valid_document
    silent_receipt = silent.fetch("execution_provenance")
    silent_receipt.fetch("observed")["model"] = "gpt-5.6-terra"
    silent_receipt["disposition"] = "silent-substitution"
    assert_includes ValidateExecutionProvenance.validate_document(silent, "receipt"),
                    "receipt: execution_provenance.silent-substitution requires a non-UNKNOWN mismatch_reason"

    exact_receipt = exact.fetch("execution_provenance")
    exact_receipt["mismatch_reason"] = "UNKNOWN"
    exact_receipt["recorded_authority"] = "Unrelated approval"
    assert_includes ValidateExecutionProvenance.validate_document(exact, "receipt"),
                    "receipt: execution_provenance.bound-exact-match requires recorded_authority UNKNOWN"
  end
end

load ValidateExecutionProvenanceTest::SCRIPT
