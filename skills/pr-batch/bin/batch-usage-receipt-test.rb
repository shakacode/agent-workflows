#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "json_schemer"

HELPER = File.expand_path("batch-usage-receipt", __dir__)
FIXTURES = File.expand_path("../fixtures/batch-usage-receipt", __dir__)
load HELPER

class BatchUsageReceiptTest < Minitest::Test
  def sql_quote(value)
    return "NULL" if value.nil?

    "'#{value.to_s.gsub("'", "''")}'"
  end

  def run_fixture(name = nil, with_rate_card: false, fixture: nil, database_available: true, expect_success: true)
    fixture ||= JSON.parse(File.read(File.join(FIXTURES, "#{name}.json"), encoding: "UTF-8"))

    Dir.mktmpdir("batch-usage-receipt-test") do |directory|
      fixture.fetch("rollouts").each do |basename, records|
        jsonl = records.map { |record| JSON.generate(record) }.join("\n")
        File.write(File.join(directory, basename), "#{jsonl}\n")
      end

      database_path = File.join(directory, "state_5.sqlite")
      statements = +<<~SQL
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          rollout_path TEXT,
          model_provider TEXT NOT NULL,
          model TEXT,
          reasoning_effort TEXT
        );
        CREATE TABLE thread_spawn_edges (
          parent_thread_id TEXT NOT NULL,
          child_thread_id TEXT NOT NULL PRIMARY KEY,
          status TEXT NOT NULL
        );
      SQL
      fixture.fetch("threads").each do |thread|
        rollout_path = thread["rollout"] && File.join(directory, thread["rollout"])
        values = [
          thread.fetch("id"), rollout_path,
          thread.fetch("model_provider"), thread["model"], thread["reasoning_effort"]
        ].map { |value| sql_quote(value) }
        statements << "INSERT INTO threads VALUES (#{values.join(', ')});\n"
      end
      fixture.fetch("edges", []).each do |edge|
        values = edge.map { |value| sql_quote(value) }
        statements << "INSERT INTO thread_spawn_edges VALUES (#{values.join(', ')});\n"
      end
      if database_available
        _, database_stderr, database_status = Open3.capture3("sqlite3", database_path, stdin_data: statements)
        assert database_status.success?, database_stderr
      end

      manifest_path = File.join(directory, "manifest.json")
      File.write(manifest_path, "#{JSON.pretty_generate(fixture.fetch('manifest'))}\n")
      command = [
        "ruby", HELPER,
        "--state-db", database_path,
        "--manifest", manifest_path,
        "--from", fixture.dig("window", "from"),
        "--to", fixture.dig("window", "to")
      ]
      if with_rate_card
        rate_card_path = File.join(directory, "rate-card.json")
        File.write(rate_card_path, "#{JSON.pretty_generate(fixture.fetch('rate_card'))}\n")
        command.concat(["--rate-card", rate_card_path])
      end
      stdout, stderr, status = Open3.capture3(*command)
      if expect_success
        assert status.success?, stderr
        return [JSON.parse(stdout), stdout]
      end

      refute status.success?
      return [stderr, status]
    end
  end

  def test_forked_copied_history_is_not_rebound_or_double_counted
    receipt, = run_fixture("replay")

    assert_equal "batch-usage-receipt-v1", receipt.fetch("schema")
    assert_equal 30, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 20, receipt.dig("coordinator", "usage", "self_only", "total_tokens")
    assert_equal 10, receipt.dig("lanes", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 10, receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 2, receipt.dig("accounting", "replay_records_omitted")
    assert_equal 1, receipt.dig("accounting", "duplicate_samples_omitted")
    assert_equal "child-thread", receipt.dig("lanes", 0, "workers", 0, "evidence", "first_session_id")
    assert_equal "gpt-requested-worker", receipt.dig("lanes", 0, "workers", 0, "requested_route", "model")
    assert_equal "gpt-test-worker", receipt.dig("lanes", 0, "workers", 0, "observed_routes", 0, "model")
    assert_equal 2, receipt.dig("accounting", "session_rebind_attempts_ignored")
  end

  def test_cumulative_differencing_precedes_window_filter_and_accounts_for_seed_reset_and_compaction
    receipt, = run_fixture("reset-seed-compaction-window")

    assert_equal 19, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 115, receipt.dig("batch", "usage", "descendant_inclusive", "input_tokens")
    assert_equal 4, receipt.dig("batch", "usage", "descendant_inclusive", "output_tokens")
    assert_equal 1, receipt.dig("accounting", "inherited_seeds_omitted")
    assert_equal 1, receipt.dig("accounting", "counter_resets")
    assert_equal 1, receipt.dig("accounting", "compactions")
    assert_equal 1, receipt.dig("accounting", "duplicate_samples_omitted")
    assert_equal 0, receipt.dig("accounting", "session_rebind_attempts_ignored"),
                 "resume metadata with the same first session identity is not a rebind"
    assert_equal "full_history_before_window_filter", receipt.dig("window", "differencing")
  end

  def test_emitted_window_preserves_fractional_second_precision
    fixture = fixture_copy("replay")
    fixture["window"] = {
      "from" => "2026-08-01T00:00:00.500000000Z",
      "to" => "2026-08-02T00:00:00.800000000Z"
    }

    receipt, = run_fixture(fixture: fixture)

    assert_equal "2026-08-01T00:00:00.500000000Z", receipt.dig("window", "from_inclusive")
    assert_equal "2026-08-02T00:00:00.800000000Z", receipt.dig("window", "to_exclusive")
  end

  def test_first_sample_without_last_usage_is_unknown_instead_of_importing_cumulative_history
    receipt, = run_fixture("missing-first-last")

    expected = {
      "input_tokens" => "UNKNOWN",
      "output_tokens" => "UNKNOWN",
      "cache_read_tokens" => "UNKNOWN",
      "total_tokens" => "UNKNOWN"
    }
    assert_equal expected, receipt.dig("batch", "usage", "descendant_inclusive")
    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
    unknown_codes = receipt.dig("evidence", "unknown").map { |item| item.fetch("code") }
    assert_includes unknown_codes, "missing_first_last_token_usage"
  end

  def test_compaction_correlated_repeated_counter_vector_starts_a_new_epoch
    receipt, = run_fixture("compaction-reset")

    assert_equal 40, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 1, receipt.dig("accounting", "counter_resets")
    assert_equal 0, receipt.dig("accounting", "replay_records_omitted")
    assert_equal 1, receipt.dig("accounting", "duplicate_samples_omitted")
    assert_equal "complete", receipt.dig("evidence", "status")
  end

  def test_counter_decrease_without_boundary_evidence_is_structured_unknown
    receipt, = run_fixture("ambiguous-decrease")

    assert_equal(
      {
        "input_tokens" => 20,
        "output_tokens" => 6,
        "cache_read_tokens" => "UNKNOWN",
        "total_tokens" => 26
      },
      receipt.dig("batch", "usage", "descendant_inclusive")
    )
    assert_equal 0, receipt.dig("accounting", "counter_resets")
    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
    reasons = receipt.dig("evidence", "unknown")
    unknown_codes = reasons.map { |item| item.fetch("code") }
    assert_includes unknown_codes, "ambiguous_counter_decrease"
    refute_includes unknown_codes, "usage_counter_missing"
    ambiguous = reasons.find { |item| item["code"] == "ambiguous_counter_decrease" }
    assert_equal ["cache_read_tokens"], ambiguous["fields"]
  end

  def test_nested_fork_matches_its_own_copy_boundary_without_recounting_parent_usage
    receipt, = run_fixture("nested-replay")

    assert_equal 20, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 10, receipt.dig("lanes", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 5, receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 3, receipt.dig("accounting", "replay_records_omitted")
    assert_equal "complete", receipt.dig("evidence", "status")
  end

  def test_unknown_cache_counter_does_not_erase_known_primary_counters
    receipt, = run_fixture("partial-counter-unknown")

    assert_equal(
      {
        "input_tokens" => 8,
        "output_tokens" => 2,
        "cache_read_tokens" => "UNKNOWN",
        "total_tokens" => 10
      },
      receipt.dig("batch", "usage", "descendant_inclusive")
    )
    assert_equal 8, receipt.dig("coordinator", "usage", "self_only", "input_tokens")
    assert_equal "UNKNOWN", receipt.dig("coordinator", "usage", "self_only", "cache_read_tokens")
    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
  end

  def test_missing_observed_route_metadata_is_structured_unknown_without_erasing_usage
    fixture = fixture_copy("replay")
    fixture.fetch("threads").each do |thread|
      thread["model_provider"] = ""
      thread["model"] = nil
      thread["reasoning_effort"] = nil
    end
    fixture.fetch("rollouts").each_value do |records|
      records.reject! { |record| record["type"] == "turn_context" }
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal 30, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
    reasons = receipt.dig("evidence", "unknown").select { |item| item["code"] == "route_metadata_missing" }
    refute_empty reasons
    assert_equal %w[effort model provider], reasons.first.fetch("fields").sort
    assert_equal %w[effort host model provider usage], receipt.dig("coordinator", "observed_routes", 0).keys.sort
  end

  def test_spawn_edges_roll_up_descendants_once_and_reconcile_unattributed_usage
    receipt, = run_fixture("descendants")

    assert_equal 112, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 10, receipt.dig("coordinator", "usage", "self_only", "total_tokens")
    assert_equal 112, receipt.dig("coordinator", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 90, receipt.dig("lanes", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 20, receipt.dig("lanes", 0, "usage", "self_only", "total_tokens")
    assert_equal 30, receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 60, receipt.dig("lanes", 0, "usage", "unattributed", "total_tokens")
    assert_equal "balanced", receipt.dig("lanes", 0, "reconciliation", "status")
    assert_equal 7, receipt.dig("lanes", 1, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 5, receipt.dig("batch", "usage", "unattributed", "total_tokens")
    assert_equal "balanced", receipt.dig("batch", "reconciliation", "status")
  end

  def test_topology_invalid_lane_reconciliation_is_unknown_even_when_zero_usage_balances
    fixture = fixture_copy("descendants")
    fixture.dig("manifest", "lanes", 0, "workers", 0)["thread_id"] = "lane-b"
    token_info = fixture.dig("rollouts", "lane-b.jsonl", 1, "payload", "info")
    token_info.each_value { |usage| usage.transform_values! { 0 } }

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "reconciliation", "status")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "worker_outside_lane_scope" }
    assert_equal "lane-a", reason.fetch("lane_id")
  end

  def test_overlapping_lane_topology_forces_batch_reconciliation_unknown_when_zero_usage_balances
    fixture = fixture_copy("descendants")
    root_to_lane_b = fixture.fetch("edges").find { |edge| edge[1] == "lane-b" }
    root_to_lane_b[0] = "lane-a"
    token_info = fixture.dig("rollouts", "lane-b.jsonl", 1, "payload", "info")
    token_info.each_value { |usage| usage.transform_values! { 0 } }

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("batch", "reconciliation", "status")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "lane_scope_overlap" }
    assert_equal %w[lane-a lane-b], reason.fetch("lane_ids")
  end

  def test_lane_containing_coordinator_root_forces_batch_reconciliation_unknown
    fixture = fixture_copy("descendants")
    root_to_lane_a = fixture.fetch("edges").find { |edge| edge[1] == "lane-a" }
    root_to_lane_a[0] = "lane-a"
    root_to_lane_a[1] = "root"
    %w[root.jsonl lane-b.jsonl unattributed-root.jsonl].each do |rollout|
      token_info = fixture.dig("rollouts", rollout, 1, "payload", "info")
      token_info.each_value { |usage| usage.transform_values! { 0 } }
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("batch", "reconciliation", "status")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "coordinator_root_in_lane_scope" }
    assert_equal "lane-a", reason.fetch("lane_id")
    assert_equal "root", reason.fetch("thread_id")
  end

  def test_unavailable_state_does_not_claim_manifest_worker_topology_is_invalid
    receipt, = run_fixture(fixture: fixture_copy("descendants"), database_available: false)

    unknown_codes = receipt.dig("evidence", "unknown").map { |item| item.fetch("code") }
    assert_includes unknown_codes, "state_database_missing"
    refute_includes unknown_codes, "worker_outside_lane_scope"
    refute_includes unknown_codes, "worker_scope_overlap"
    refute_includes unknown_codes, "lane_scope_overlap"
  end

  def test_unsupported_or_missing_evidence_is_structured_unknown_and_content_never_leaks
    receipt, output = run_fixture("unknown-content-leakage")

    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
    assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal "UNKNOWN", receipt.dig("batch", "reconciliation", "status")
    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "evidence", "status")
    unknown_codes = receipt.dig("evidence", "unknown").map { |item| item.fetch("code") }
    assert_includes unknown_codes, "missing_total_token_usage"
    assert_includes unknown_codes, "thread_missing"
    assert_equal false, receipt.dig("privacy", "emitted_or_persisted_content")
    assert_equal %w[effort host model], receipt.dig("coordinator", "requested_route").keys.sort
    assert_equal %w[effort host model], receipt.dig("lanes", 0, "requested_route").keys.sort
    %w[
      PROMPT_SENTINEL RESPONSE_SENTINEL TOOL_RESULT_SENTINEL AUTH_SENTINEL ENV_SENTINEL
      MANIFEST_AUTH_SENTINEL MANIFEST_PROMPT_SENTINEL MANIFEST_RESPONSE_SENTINEL
    ].each do |sentinel|
      refute_includes output, sentinel
    end
    schema = receipt_schema
    assert_empty JSONSchemer.schema(schema).validate(receipt).to_a

    spoofed = JSON.parse(JSON.generate(receipt))
    spoofed.dig("coordinator", "requested_route")["usage"] = blank_usage_for_test
    refute_empty JSONSchemer.schema(schema).validate(spoofed).to_a
  end

  def test_missing_rollout_path_is_structured_unknown_instead_of_crashing
    receipt, = run_fixture("rollout-path-missing")

    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
    assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "rollout_path_missing" }
    assert_equal "root-thread", reason.fetch("thread_id")
    assert_empty JSONSchemer.schema(receipt_schema).validate(receipt).to_a
  end

  def test_state_query_is_scoped_to_manifest_roots_and_declared_workers
    fixture = JSON.parse(File.read(File.join(FIXTURES, "replay.json"), encoding: "UTF-8"))
    reporter = BatchUsageReceipt::Reporter.new(
      manifest: fixture.fetch("manifest"),
      database_path: "/unused/state_5.sqlite",
      from_time: Time.iso8601(fixture.dig("window", "from")),
      to_time: Time.iso8601(fixture.dig("window", "to"))
    )

    query = reporter.send(:state_query)

    assert_includes query, "WITH RECURSIVE"
    assert_includes query, "JOIN reachable"
    %w[root-thread child-thread].each do |thread_id|
      assert_includes query, thread_id.unpack1("H*")
    end
  end

  def test_worker_ids_must_be_unique_across_lanes
    fixture = JSON.parse(File.read(File.join(FIXTURES, "descendants.json"), encoding: "UTF-8"))
    manifest = fixture.fetch("manifest")
    duplicate = JSON.parse(JSON.generate(manifest.dig("lanes", 0, "workers", 0)))
    duplicate["thread_id"] = "lane-b"
    manifest.dig("lanes", 1, "workers") << duplicate
    reporter = BatchUsageReceipt::Reporter.new(
      manifest: manifest,
      database_path: "/unused/state_5.sqlite",
      from_time: Time.iso8601(fixture.dig("window", "from")),
      to_time: Time.iso8601(fixture.dig("window", "to"))
    )

    error = assert_raises(BatchUsageReceipt::InputError) { reporter.send(:validate_manifest!) }
    assert_equal "duplicate worker id worker-a", error.message
  end

  def test_optional_credit_equivalents_require_explicit_dated_model_mapping_and_disclaim_billing
    receipt, = run_fixture("descendants", with_rate_card: true)
    credits = receipt.fetch("credit_equivalents")

    assert_equal "available", credits.fetch("status")
    assert_equal "https://example.invalid/rate-card/2026-08-04", credits.fetch("source")
    assert_equal "2026-08-04", credits.fetch("effective_date")
    assert_includes credits.fetch("disclaimer"), "not a bill"
    assert_equal 4, credits.fetch("model_values").length
    schema = receipt_schema
    assert_empty JSONSchemer.schema(schema).validate(receipt).to_a

    empty_value = JSON.parse(JSON.generate(receipt))
    empty_value.dig("credit_equivalents", "model_values").replace([{}])
    refute_empty JSONSchemer.schema(schema).validate(empty_value).to_a

    negative_credits = JSON.parse(JSON.generate(receipt))
    negative_credits.dig("credit_equivalents", "model_values", 0)["credits"] = -1
    refute_empty JSONSchemer.schema(schema).validate(negative_credits).to_a

    unknown_value = JSON.parse(JSON.generate(receipt))
    unknown_value["credit_equivalents"]["status"] = "UNKNOWN"
    unknown_value.dig("credit_equivalents", "model_values").replace(
      [{ "host" => "codex", "model" => "unmapped-model", "status" => "UNKNOWN", "code" => "rate_mapping_missing" }]
    )
    assert_empty JSONSchemer.schema(schema).validate(unknown_value).to_a

    missing_unknown_code = JSON.parse(JSON.generate(unknown_value))
    missing_unknown_code.dig("credit_equivalents", "model_values", 0).delete("code")
    refute_empty JSONSchemer.schema(schema).validate(missing_unknown_code).to_a
  end

  def test_credit_equivalents_only_require_the_priced_input_and_output_counters
    fixture = fixture_copy("partial-counter-unknown")
    fixture["rate_card"] = {
      "schema" => "batch-usage-rate-card-v1",
      "source" => "https://example.invalid/rate-card/2026-08-04",
      "effective_date" => "2026-08-04",
      "model_mappings" => [{
        "host" => "codex", "model" => "gpt-test",
        "input_credits_per_million" => 1, "output_credits_per_million" => 2
      }]
    }

    receipt, = run_fixture(fixture: fixture, with_rate_card: true)

    assert_equal "available", receipt.dig("credit_equivalents", "status")
    assert_equal "available", receipt.dig("credit_equivalents", "model_values", 0, "status")
    assert_equal 0.000012, receipt.dig("credit_equivalents", "model_values", 0, "credits")
  end

  def test_rate_card_effective_date_must_be_a_canonical_full_date
    fixture = fixture_copy("descendants")
    %w[20260804 2026-02-30].each do |effective_date|
      reporter = reporter_for_rate_card(fixture, fixture.fetch("rate_card").merge("effective_date" => effective_date))

      error = assert_raises(BatchUsageReceipt::InputError) { reporter.send(:validate_rate_card!) }
      assert_equal "rate-card.effective_date must be an ISO 8601 date", error.message
    end
  end

  def test_rate_card_rejects_nonfinite_rates_and_finite_rate_overflow
    fixture = fixture_copy("descendants")
    nonfinite = fixture.fetch("rate_card").merge(
      "model_mappings" => fixture.dig("rate_card", "model_mappings").map(&:dup)
    )
    nonfinite.dig("model_mappings", 0)["input_credits_per_million"] = Float::INFINITY
    reporter = reporter_for_rate_card(fixture, nonfinite)

    error = assert_raises(BatchUsageReceipt::InputError) { reporter.send(:validate_rate_card!) }
    assert_includes error.message, "must be finite and nonnegative"

    overflow = fixture_copy("descendants")
    overflow.dig("rate_card", "model_mappings", 0)["input_credits_per_million"] = Float::MAX
    stderr, = run_fixture(fixture: overflow, with_rate_card: true, expect_success: false)
    assert_includes stderr, "rate-card credit calculation must be finite"
  end

  def test_unknown_observed_model_cannot_be_priced_by_an_unknown_rate_mapping
    fixture = fixture_copy("replay")
    fixture.fetch("threads").each { |thread| thread["model"] = nil }
    fixture.fetch("rollouts").each_value do |records|
      records.reject! { |record| record["type"] == "turn_context" }
    end
    fixture["rate_card"] = {
      "schema" => "batch-usage-rate-card-v1",
      "source" => "https://example.invalid/rate-card/2026-08-04",
      "effective_date" => "2026-08-04",
      "model_mappings" => [{
        "host" => "codex", "model" => "UNKNOWN",
        "input_credits_per_million" => 1, "output_credits_per_million" => 2
      }]
    }

    receipt, = run_fixture(fixture: fixture, with_rate_card: true)

    assert_equal "UNKNOWN", receipt.dig("credit_equivalents", "status")
    assert_equal "route_identity_unknown", receipt.dig("credit_equivalents", "model_values", 0, "code")
  end

  def test_output_is_deterministic_across_replays_and_public_contract_is_versioned
    first_receipt, first_output = run_fixture("replay")
    second_receipt, second_output = run_fixture("replay")

    assert_equal first_receipt, second_receipt
    assert_equal first_output, second_output

    root = File.expand_path("../../..", __dir__)
    schema = JSON.parse(File.read(File.join(root, "docs/schemas/batch-usage-receipt-v1.schema.json")))
    assert_equal "Batch Usage Receipt v1", schema.fetch("title")
    assert_equal "batch-usage-receipt-v1", schema.dig("properties", "schema", "const")
    assert schema.dig("$defs", "batchScope")
    assert schema.dig("$defs", "executionScope")
    assert schema.dig("$defs", "laneScope")
    schema_errors = JSONSchemer.schema(schema).validate(first_receipt).to_a
    assert_empty schema_errors, schema_errors.map { |error| error.fetch("error") }.join("\n")

    docs = File.read(File.join(root, "docs/batch-usage-receipt.md"), encoding: "UTF-8")
    assert_includes docs, "`last_token_usage` is never summed."
    assert_includes docs, "complete physical rollout"
    assert_includes docs, "not an invoice"
    assert_includes docs, "supported and attempted metadata source"
    assert_includes docs, "complete physical rollouts used for differencing"
    assert_includes docs, "worker_outside_lane_scope"
    assert_includes docs, "entire affected rollout's counter vector"
    assert_includes docs, "do not normalize `cache_read_tokens`"

    workflow = File.read(File.join(root, "workflows/pr-processing.md"), encoding: "UTF-8")
    skill = File.read(File.join(root, "skills/pr-batch/SKILL.md"), encoding: "UTF-8")
    [workflow, skill].each do |surface|
      assert_includes surface, "`bin/batch-usage-receipt` helper"
      assert_includes surface, "durable artifact reference"
      assert_includes surface, "informational"
    end
  end

  private

  def fixture_copy(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json"), encoding: "UTF-8"))
  end

  def blank_usage_for_test
    {
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cache_read_tokens" => 0,
      "total_tokens" => 0
    }
  end

  def reporter_for_rate_card(fixture, rate_card)
    BatchUsageReceipt::Reporter.new(
      manifest: fixture.fetch("manifest"),
      database_path: "/unused/state_5.sqlite",
      from_time: Time.iso8601(fixture.dig("window", "from")),
      to_time: Time.iso8601(fixture.dig("window", "to")),
      rate_card: rate_card
    )
  end

  def receipt_schema
    root = File.expand_path("../../..", __dir__)
    JSON.parse(File.read(File.join(root, "docs/schemas/batch-usage-receipt-v1.schema.json")))
  end
end
