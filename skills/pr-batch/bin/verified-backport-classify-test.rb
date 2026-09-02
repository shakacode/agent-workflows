#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

PINNED_JSON_SCHEMER_VERSION = ENV["JSON_SCHEMER_VERSION"]
gem "json_schemer", PINNED_JSON_SCHEMER_VERSION if PINNED_JSON_SCHEMER_VERSION
require "json_schemer"

ROOT = File.expand_path("../../..", __dir__)
HELPER = File.expand_path("verified-backport-classify", __dir__)
FIXTURES = File.expand_path("../fixtures/verified-backport", __dir__)
SCHEMA = File.join(ROOT, "docs/schemas/verified-backport-v1.json")

class VerifiedBackportClassifyTest < Minitest::Test
  def test_replay_evidence_conforms_to_the_verified_backport_schema
    schema = JSON.parse(File.read(SCHEMA, encoding: "UTF-8"))

    fixture_paths.each do |path|
      evidence = JSON.parse(File.read(path, encoding: "UTF-8"))
      errors = JSONSchemer.schema(schema).validate(evidence).to_a

      assert_empty errors, "#{File.basename(path)} schema errors: #{errors.inspect}"
    end
  end

  def test_exact_validation_focused_replay_enters_fast_path
    evidence = fixture("react-on-rails-4677-exact-validation-focused")

    stdout, stderr, status = Open3.capture3("ruby", HELPER, stdin_data: JSON.generate(evidence))

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal "exact", result.fetch("classification")
    assert result.fetch("fast_path")
    assert_empty result.fetch("reasons")
    refute result.fetch("target_gates_waived")
    assert_equal evidence.fetch("target_requirements"), result.fetch("target_requirements")
  end

  def test_malformed_nested_evidence_fails_closed_without_a_cli_error
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence.fetch("source_evidence")["reviews"] = ["not-an-evidence-object"]

    stdout, stderr, status = Open3.capture3("ruby", HELPER, stdin_data: JSON.generate(evidence))

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal "ordinary-full", result.fetch("classification")
    refute result.fetch("fast_path")
    assert_includes result.fetch("reasons"), "invalid-contract"
  end

  def test_exact_claim_without_both_review_and_ci_reuse_fails_closed
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence["reused_evidence"] = evidence.fetch("reused_evidence").select do |item|
      item.fetch("kind") == "review"
    end

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    assert_includes result.fetch("reasons"), "reused-evidence-incomplete"
  end

  def test_review_behavior_change_requires_a_durable_forward_port_url
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence["review_generated_changes"] = [{
      "id" => "review-fix-1",
      "files" => ["rakelib/release.rake"],
      "hunks" => ["release retry guard"],
      "behavior_change" => true,
      "rationale" => "Review changed release retry behavior."
    }]
    evidence["forward_port_dispositions"] = [{
      "change_id" => "review-fix-1",
      "status" => "tracked",
      "rationale" => "Follow-up recorded outside this receipt.",
      "url" => "not-a-durable-url"
    }]

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    refute result.fetch("forward_port_complete")
    assert_includes result.fetch("reasons"), "forward-port-disposition-missing"
  end

  def test_contradictory_target_policy_fails_closed
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence.fetch("target_requirements")["current_head_ci"] = "not-required"

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    assert_includes result.fetch("reasons"), "contradictory-target-policy"
    refute result.fetch("target_gates_waived")
  end

  def test_semantic_replays_retain_full_scrutiny_and_surface_review_fixes
    fixture_names = %w[
      react-on-rails-4676-semantic-review-fix
      react-on-rails-4684-semantic-review-fixes
    ]

    fixture_names.each do |name|
      result = classify(fixture(name))

      assert_equal "ordinary-full", result.fetch("classification"), name
      refute result.fetch("fast_path"), name
      assert_includes result.fetch("reasons"), "patch-relation-semantic-adaptation", name
      assert_includes result.fetch("reasons"), "review-generated-behavior-change", name
      assert result.fetch("forward_port_complete"), name
      assert_empty result.fetch("reused_evidence"), name
      refute result.fetch("target_gates_waived"), name
    end
  end

  def test_schema_extensions_do_not_accidentally_qualify_as_exact
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence["unrecognized_waiver"] = true

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    assert_includes result.fetch("reasons"), "invalid-contract"
  end

  def test_missing_stale_contradictory_conflicted_semantic_and_unknown_evidence_fail_closed
    mutations = {
      "missing" => ["invalid-contract", ->(item) { item.delete("source_evidence") }],
      "stale" => ["stale-source-evidence", lambda { |item|
        item.dig("source_evidence", "reviews", 0)["head_sha"] = "1" * 40
      }],
      "contradictory" => ["patch-identity-mismatch", lambda { |item|
        item["patch"]["target_patch_id"] = "2" * 40
      }],
      "conflicted" => ["patch-relation-conflicted", ->(item) { item["patch"]["relation"] = "conflicted" }],
      "semantic" => ["patch-relation-semantic-adaptation", lambda { |item|
        item["patch"]["relation"] = "semantic-adaptation"
      }],
      "unknown" => ["unknown-evidence", ->(item) { item["patch"]["relation"] = "UNKNOWN" }]
    }

    mutations.each do |name, (expected_reason, mutation)|
      evidence = fixture("react-on-rails-4677-exact-validation-focused")
      mutation.call(evidence)

      result = classify(evidence)

      assert_equal "ordinary-full", result.fetch("classification"), name
      refute result.fetch("fast_path"), name
      assert_includes result.fetch("reasons"), expected_reason, name
      assert_empty result.fetch("reused_evidence"), name
      refute result.fetch("target_gates_waived"), name
    end
  end

  def test_malformed_json_fails_closed_as_an_invalid_contract
    stdout, stderr, status = Open3.capture3("ruby", HELPER, stdin_data: "{not-json")

    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal "ordinary-full", result.fetch("classification")
    assert_equal ["invalid-contract"], result.fetch("reasons")
  end

  def test_schema_can_represent_unknown_string_evidence_while_classifier_fails_closed
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence.fetch("target")["branch"] = "UNKNOWN"
    schema = JSON.parse(File.read(SCHEMA, encoding: "UTF-8"))

    errors = JSONSchemer.schema(schema).validate(evidence).to_a
    result = classify(evidence)

    assert_empty errors
    assert_equal "ordinary-full", result.fetch("classification")
    assert_includes result.fetch("reasons"), "unknown-evidence"
  end

  private

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json"), encoding: "UTF-8"))
  end

  def classify(evidence)
    stdout, stderr, status = Open3.capture3("ruby", HELPER, stdin_data: JSON.generate(evidence))
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def fixture_paths
    Dir.glob(File.join(FIXTURES, "*.json")).sort
  end
end
