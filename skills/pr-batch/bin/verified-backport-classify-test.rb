#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

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

  def test_extra_cli_args_fail_with_a_distinct_usage_error
    stdout, stderr, status = Open3.capture3("ruby", HELPER, "first", "second")

    refute status.success?
    assert_equal "", stdout
    assert_equal 64, status.exitstatus
    assert_match(/usage: verified-backport-classify \[input\.json\]/, stderr)
  end

  def test_missing_input_file_reports_a_distinct_usage_error
    Dir.mktmpdir do |dir|
      missing_path = File.join(dir, "missing-input.json")
      stdout, stderr, status = Open3.capture3("ruby", HELPER, missing_path)

      refute status.success?
      assert_equal "", stdout
      assert_equal 66, status.exitstatus
      assert_match(/unable to read input file/, stderr)
    end
  end

  def test_schema_invalid_evidence_cannot_enter_the_fast_path
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence.dig("source_evidence", "reviews", 0)["url"] = "http://example.com/self-attested-review"

    refute_empty schema_errors(evidence)
    result = classify(evidence)

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

  def test_self_attested_review_and_arbitrary_selector_cannot_earn_the_fast_path
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    source_head = evidence.dig("source", "head_sha")
    evidence["source_evidence"] = {
      "reviews" => [{
        "id" => "self-attested-review",
        "head_sha" => source_head,
        "status" => "accepted",
        "url" => "https://github.com/shakacode/react_on_rails/pull/4656"
      }],
      "checks" => [{
        "id" => "arbitrary-selector",
        "name" => "detect-changes",
        "head_sha" => source_head,
        "status" => "passed",
        "url" => "https://github.com/shakacode/react_on_rails/actions/runs/29305769015/job/86998660379"
      }]
    }
    evidence["reused_evidence"] = [
      { "kind" => "review", "source_id" => "self-attested-review", "head_sha" => source_head },
      { "kind" => "check", "source_id" => "arbitrary-selector", "head_sha" => source_head }
    ]

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    refute result.fetch("fast_path")
  end

  def test_required_source_review_must_be_independent_from_the_author
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence.dig("source_evidence", "reviews", 0)["actor"] = evidence.dig("source", "author")

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    refute result.fetch("fast_path")
    assert_includes result.fetch("reasons"), "source-review-not-independent"
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
      "url" => "UNKNOWN"
    }]

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    refute result.fetch("forward_port_complete")
    assert_includes result.fetch("reasons"), "forward-port-disposition-missing"
  end

  def test_duplicate_behavior_change_identities_are_not_forward_port_complete
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence["review_generated_changes"] = [
      behavior_change("review-fix-1", "first behavior change"),
      behavior_change("review-fix-1", "different behavior change")
    ]
    evidence["forward_port_dispositions"] = [forward_port_disposition("review-fix-1", "tracked")]

    result = classify(evidence)

    refute result.fetch("forward_port_complete")
    assert_includes result.fetch("reasons"), "forward-port-disposition-missing"
  end

  def test_conflicting_forward_port_dispositions_are_not_complete
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence["review_generated_changes"] = [behavior_change("review-fix-1", "behavior change")]
    evidence["forward_port_dispositions"] = [
      forward_port_disposition("review-fix-1", "tracked"),
      forward_port_disposition("review-fix-1", "not-applicable")
    ]

    result = classify(evidence)

    refute result.fetch("forward_port_complete")
    assert_includes result.fetch("reasons"), "forward-port-disposition-missing"
  end

  def test_required_source_coverage_must_be_present_and_reused
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    omitted_check_id = evidence.dig("source_evidence", "required_coverage", "check_ids").last
    evidence.fetch("source_evidence").fetch("checks").reject! { |item| item.fetch("id") == omitted_check_id }
    evidence.fetch("reused_evidence").reject! { |item| item.fetch("source_id") == omitted_check_id }

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    refute result.fetch("fast_path")
    assert_includes result.fetch("reasons"), "source-required-coverage-incomplete"
  end

  def test_contradictory_target_policy_fails_closed
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence.fetch("target_requirements")["current_head_ci"] = "not-required"

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    assert_includes result.fetch("reasons"), "contradictory-target-policy"
    refute result.fetch("target_gates_waived")
  end

  def test_unknown_target_policy_is_missing_without_being_contradictory
    evidence = fixture("react-on-rails-4677-exact-validation-focused")
    evidence.fetch("target_requirements")["current_head_ci"] = "UNKNOWN"

    result = classify(evidence)

    assert_equal "ordinary-full", result.fetch("classification")
    assert_includes result.fetch("reasons"), "target-policy-missing"
    refute_includes result.fetch("reasons"), "contradictory-target-policy"
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

  def test_react_on_rails_4684_response_framing_links_the_actual_fix_thread
    evidence = fixture("react-on-rails-4684-semantic-review-fixes")
    response_change = evidence.fetch("review_generated_changes").find do |change|
      change.fetch("hunks").include?("accept the installed gh response framing without accepting arbitrary mixed framing")
    end
    response_disposition = evidence.fetch("forward_port_dispositions").find do |item|
      item.fetch("change_id") == response_change.fetch("id")
    end

    assert_equal "discussion-r3590737544", response_change.fetch("id")
    assert_equal "https://github.com/shakacode/react_on_rails/pull/4684#discussion_r3590737544",
                 response_disposition.fetch("url")
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

  def test_invalid_utf8_input_reports_a_distinct_read_error
    invalid_payload = JSON.generate(fixture("react-on-rails-4677-exact-validation-focused")).b + "\xFF".b

    [
      [
        "standard input",
        -> { Open3.capture3("ruby", HELPER, stdin_data: invalid_payload) },
        /unable to read input from standard input: EncodingError: standard input contains invalid UTF-8/
      ],
      [
        "input file",
        lambda do
          Dir.mktmpdir do |dir|
            path = File.join(dir, "invalid-utf8.json")
            File.binwrite(path, invalid_payload)
            Open3.capture3("ruby", HELPER, path)
          end
        end,
        /unable to read input file .*: EncodingError: input file .* contains invalid UTF-8/
      ]
    ].each do |label, runner, stderr_pattern|
      stdout, stderr, status = runner.call

      refute status.success?, label
      assert_equal "", stdout, label
      assert_equal 66, status.exitstatus, label
      assert_match(stderr_pattern, stderr, label)
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

  def behavior_change(id, rationale)
    {
      "id" => id,
      "files" => ["rakelib/release.rake"],
      "hunks" => [rationale],
      "behavior_change" => true,
      "rationale" => rationale
    }
  end

  def forward_port_disposition(change_id, status)
    {
      "change_id" => change_id,
      "status" => status,
      "rationale" => "Durable source-branch disposition.",
      "url" => "https://github.com/shakacode/react_on_rails/issues/4681"
    }
  end

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json"), encoding: "UTF-8"))
  end

  def schema_errors(evidence)
    schema = JSON.parse(File.read(SCHEMA, encoding: "UTF-8"))
    JSONSchemer.schema(schema).validate(evidence).to_a
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
