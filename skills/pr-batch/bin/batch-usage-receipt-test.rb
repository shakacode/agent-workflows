#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

PINNED_JSON_SCHEMER_VERSION = ENV["JSON_SCHEMER_VERSION"]
begin
  gem "json_schemer", PINNED_JSON_SCHEMER_VERSION if PINNED_JSON_SCHEMER_VERSION
  require "json_schemer"
rescue Gem::LoadError => e
  if PINNED_JSON_SCHEMER_VERSION
    warn "Install json_schemer #{PINNED_JSON_SCHEMER_VERSION}: " \
         "gem install json_schemer -v #{PINNED_JSON_SCHEMER_VERSION} --no-document"
  end
  warn e.message
  exit 1
end

HELPER = File.expand_path("batch-usage-receipt", __dir__)
FIXTURES = File.expand_path("../fixtures/batch-usage-receipt", __dir__)
RawRolloutLine = Struct.new(:content, keyword_init: true)
load HELPER

class BatchUsageReceiptTest < Minitest::Test
  def sql_quote(value)
    return "NULL" if value.nil?

    "'#{value.to_s.gsub("'", "''")}'"
  end

  def run_fixture(
    name = nil, with_rate_card: false, fixture: nil, database_available: true, expect_success: true, environment: {}
  )
    fixture ||= JSON.parse(File.read(File.join(FIXTURES, "#{name}.json"), encoding: "UTF-8"))

    Dir.mktmpdir("batch-usage-receipt-test") do |directory|
      fixture.fetch("rollouts").each do |basename, records|
        jsonl = records.map do |record|
          record.is_a?(RawRolloutLine) ? record.content : JSON.generate(record)
        end.join("\n")
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
      stdout, stderr, status = Open3.capture3(environment, *command)
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

    assert_equal "batch-usage-receipt-v2", receipt.fetch("schema")
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

  def test_window_contributing_turn_counts_roll_up_through_nested_scopes
    fixture = fixture_copy("descendants")

    receipt, = run_fixture(fixture: fixture)

    assert_equal 6, receipt.dig("batch", "turns", "descendant_inclusive")
    assert_equal 1, receipt.dig("batch", "turns", "unattributed")
    assert_equal 1, receipt.dig("coordinator", "turns", "self_only")
    assert_equal 6, receipt.dig("coordinator", "turns", "descendant_inclusive")
    assert_equal 3, receipt.dig("lanes", 0, "turns", "descendant_inclusive")
    assert_equal 1, receipt.dig("lanes", 0, "turns", "self_only")
    assert_equal 2, receipt.dig("lanes", 0, "turns", "unattributed")
    assert_equal 1, receipt.dig("lanes", 0, "workers", 0, "turns", "descendant_inclusive")
    assert_equal 1, receipt.dig("lanes", 1, "turns", "descendant_inclusive")
  end

  def test_turn_segment_spanning_window_counts_once_until_the_next_turn_context
    fixture = fixture_copy("descendants")
    fixture["window"]["from"] = "2026-08-04T00:00:01Z"
    root_records = fixture.dig("rollouts", "root.jsonl")
    root_records.fetch(1)["timestamp"] = "2026-08-04T00:00:00.500Z"
    root_records << token_count_record("2026-08-04T00:00:02Z", total: 15, last: 5)
    root_records << token_count_record("2026-08-04T00:00:02.500Z", total: 15, last: 5)
    root_records << turn_context_record("2026-08-04T00:00:03Z")
    root_records << token_count_record("2026-08-04T00:00:04Z", total: 20, last: 5)

    receipt, = run_fixture(fixture: fixture)

    assert_equal 2, receipt.dig("coordinator", "turns", "self_only")
    assert_equal 20, receipt.dig("coordinator", "usage", "self_only", "total_tokens")
    assert_equal 1, receipt.dig("accounting", "duplicate_samples_omitted")
  end

  def test_positive_usage_without_a_turn_context_has_unknown_turn_evidence
    fixture = fixture_copy("descendants")
    fixture.dig("rollouts", "root.jsonl").reject! { |record| record["type"] == "turn_context" }

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("coordinator", "turns", "self_only")
    assert_equal "UNKNOWN", receipt.dig("batch", "turns", "descendant_inclusive")
    assert_equal "UNKNOWN", receipt.dig("batch", "reconciliation", "status")
    assert receipt.dig("evidence", "unknown").any? do |reason|
      reason["code"] == "turn_context_missing_for_usage" && reason["thread_id"] == "root"
    end
  end

  def test_lane_reconciliation_is_unknown_when_both_turn_operands_are_unknown
    fixture = fixture_copy("descendants")
    %w[lane-a.jsonl unnamed-a.jsonl worker-a.jsonl].each do |rollout|
      fixture.dig("rollouts", rollout).reject! { |record| record["type"] == "turn_context" }
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "turns", "descendant_inclusive")
    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "reconciliation", "status")
  end

  def test_positive_usage_after_an_invalid_turn_context_has_unknown_turn_evidence
    fixture = fixture_copy("descendants")
    fixture.dig("rollouts", "root.jsonl", 1)["timestamp"] = "not-a-time"

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("coordinator", "turns", "self_only")
    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
    assert(receipt.dig("evidence", "unknown").any? { |reason| reason["code"] == "invalid_turn_timestamp" })
  end

  def test_malformed_turn_context_cannot_leave_the_prior_turn_segment_authoritative
    fixture = fixture_copy("descendants")
    root_records = fixture.dig("rollouts", "root.jsonl")
    usage_index = root_records.index { |record| record.dig("payload", "type") == "token_count" }
    root_records.insert(
      usage_index,
      { "timestamp" => "2026-08-04T00:00:00.750Z", "type" => "turn_context", "payload" => [] }
    )

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("coordinator", "turns", "self_only")
    assert(receipt.dig("evidence", "unknown").any? { |reason| reason["code"] == "invalid_turn_context" })
  end

  def test_usage_timestamp_before_its_turn_context_is_ambiguous
    fixture = fixture_copy("descendants")
    fixture.dig("rollouts", "root.jsonl").each do |record|
      record["timestamp"] = "2026-08-04T00:00:02Z" if record["type"] == "turn_context"
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("coordinator", "turns", "self_only")
    assert(receipt.dig("evidence", "unknown").any? { |reason| reason["code"] == "ambiguous_turn_timestamp" })
  end

  def test_reused_rollout_path_is_validated_against_every_state_thread
    fixture = fixture_copy("descendants")
    worker_thread = fixture.fetch("threads").find { |thread| thread.fetch("id") == "worker-a" }
    worker_thread["rollout"] = "lane-a.jsonl"

    receipt, = run_fixture(fixture: fixture)

    worker = receipt.dig("lanes", 0, "workers", 0)
    assert_equal "UNKNOWN", worker.dig("usage", "descendant_inclusive", "total_tokens")
    assert_equal "UNKNOWN", worker.dig("evidence", "status")
    reason = receipt.dig("evidence", "unknown").find do |item|
      item["code"] == "state_thread_first_session_mismatch" && item["thread_id"] == "worker-a"
    end
    refute_nil reason
  end

  def test_distinct_rollout_files_with_the_same_session_id_are_not_collapsed
    fixture = fixture_copy("descendants")
    fixture.dig("rollouts", "unattributed-root.jsonl", 0, "payload")["id"] = "root"

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 6, receipt.dig("accounting", "usage_samples")
    physical_ids = receipt.dig("coordinator", "evidence", "physical_rollout_ids")
    assert_equal physical_ids.length, physical_ids.uniq.length
    reason = receipt.dig("evidence", "unknown").find do |item|
      item["code"] == "state_thread_first_session_mismatch" && item["thread_id"] == "unattributed-root"
    end
    refute_nil reason
  end

  def test_state_threads_aliasing_the_same_canonical_rollout_are_processed_once
    fixture = fixture_copy("descendants")
    worker_thread = fixture.fetch("threads").find { |thread| thread.fetch("id") == "worker-a" }
    worker_thread["rollout"] = "lane-a.jsonl"

    receipt, = run_fixture(fixture: fixture)

    assert_equal 5, receipt.dig("accounting", "usage_samples")
    lane_physical_ids = receipt.dig("lanes", 0, "evidence", "physical_rollout_ids")
    worker_physical_ids = receipt.dig("lanes", 0, "workers", 0, "evidence", "physical_rollout_ids")
    assert_equal 2, lane_physical_ids.length
    assert_equal 1, worker_physical_ids.length
    assert_includes lane_physical_ids, worker_physical_ids.fetch(0)
  end

  def test_out_of_lane_rollout_alias_is_validated_before_any_scope_materializes
    fixture = fixture_copy("descendants")
    fixture.dig("manifest", "lanes", 0, "workers", 0)["thread_id"] = "orphan"
    fixture.fetch("threads") << {
      "id" => "orphan",
      "rollout" => "root.jsonl",
      "model_provider" => "openai",
      "model" => "root-model",
      "reasoning_effort" => "high"
    }

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("coordinator", "usage", "self_only", "total_tokens")
    assert_equal "UNKNOWN", receipt.dig("coordinator", "evidence", "status")
    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    reason = receipt.dig("evidence", "unknown").find do |item|
      item["code"] == "state_thread_first_session_mismatch" && item["thread_id"] == "orphan"
    end
    refute_nil reason
  end

  def test_recoverable_missing_total_in_replay_prefix_is_superseded_by_a_later_baseline
    fixture = fixture_copy("replay")
    child_records = fixture.fetch("rollouts").fetch("child.jsonl")
    missing_total = JSON.parse(JSON.generate(child_records.fetch(3)))
    missing_total.dig("payload", "info").delete("total_token_usage")
    child_records.insert(3, missing_total)

    receipt, = run_fixture(fixture: fixture)

    assert_equal 30, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 10, receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal "complete", receipt.dig("evidence", "status")
    assert_equal 3, receipt.dig("accounting", "replay_records_omitted")
    unknown_codes = receipt.dig("evidence", "unknown").map { |item| item.fetch("code") }
    refute_includes unknown_codes, "missing_total_token_usage"
  end

  def test_unrecovered_missing_total_at_replay_boundary_remains_structurally_unknown
    fixture = fixture_copy("replay")
    last_copied_sample = fixture.fetch("rollouts").fetch("child.jsonl").fetch(4)
    last_copied_sample.dig("payload", "info").delete("total_token_usage")

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "missing_total_token_usage" }
    assert_equal 5, reason.fetch("line")
  end

  def test_malformed_copied_record_is_superseded_by_a_later_replay_baseline
    fixture = fixture_copy("replay")
    fixture.fetch("rollouts").fetch("child.jsonl").insert(
      4, RawRolloutLine.new(content: "{malformed copied record")
    )

    receipt, = run_fixture(fixture: fixture)

    assert_equal 30, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 10, receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal "complete", receipt.dig("evidence", "status")
    unknown_codes = receipt.dig("evidence", "unknown").map { |item| item.fetch("code") }
    refute_includes unknown_codes, "malformed_jsonl"
  end

  def test_malformed_copied_record_without_a_later_replay_baseline_remains_unknown
    fixture = fixture_copy("replay")
    fixture.fetch("rollouts").fetch("child.jsonl").insert(
      5, RawRolloutLine.new(content: "{malformed copied record")
    )

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "malformed_jsonl" }
    assert_equal 6, reason.fetch("line")
  end

  def test_invalid_copied_usage_vectors_are_superseded_by_a_later_replay_baseline
    fixture = fixture_copy("replay")
    invalid_info = fixture.dig("rollouts", "child.jsonl", 3, "payload", "info")
    %w[total_token_usage last_token_usage].each do |counter_source|
      usage = invalid_info.fetch(counter_source)
      usage["total_tokens"] = usage.fetch("input_tokens") + usage.fetch("output_tokens") - 1
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal 30, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 10, receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal "complete", receipt.dig("evidence", "status")
    assert_equal 2, receipt.dig("accounting", "replay_records_omitted")
    unknown_codes = receipt.dig("evidence", "unknown").map { |item| item.fetch("code") }
    refute_includes unknown_codes, "invalid_token_usage_vector"
  end

  def test_invalid_copied_usage_vectors_without_a_later_replay_baseline_remain_unknown
    fixture = fixture_copy("replay")
    invalid_info = fixture.dig("rollouts", "child.jsonl", 4, "payload", "info")
    %w[total_token_usage last_token_usage].each do |counter_source|
      usage = invalid_info.fetch(counter_source)
      usage["total_tokens"] = usage.fetch("input_tokens") + usage.fetch("output_tokens") - 1
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal "UNKNOWN",
                 receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    reasons = receipt.dig("evidence", "unknown").select { |item| item["code"] == "invalid_token_usage_vector" }
    assert_equal %w[last_token_usage total_token_usage], reasons.map { |item| item.fetch("counter_source") }.sort
    assert_equal [5], reasons.map { |item| item.fetch("line") }.uniq
    assert_equal 2, receipt.dig("accounting", "replay_records_omitted")
  end

  def test_copied_prefix_compaction_does_not_corroborate_the_first_child_counter_decrease
    fixture = fixture_copy("replay")
    child_records = fixture.fetch("rollouts").fetch("child.jsonl")
    boundary_index = child_records.index { |record| record["type"] == "inter_agent_communication_metadata" }
    child_records.insert(
      boundary_index,
      { "timestamp" => "2026-08-01T01:00:00.500Z", "type" => "compacted", "payload" => {} }
    )
    first_child_usage = child_records.find { |record| record["timestamp"] == "2026-08-01T01:00:03Z" }
    decreased_usage = {
      "input_tokens" => 12,
      "cached_input_tokens" => 5,
      "output_tokens" => 3,
      "reasoning_output_tokens" => 1,
      "total_tokens" => 15
    }
    first_child_usage.dig("payload", "info")["total_token_usage"] = decreased_usage
    first_child_usage.dig("payload", "info")["last_token_usage"] = decreased_usage.dup
    child_records.replace(child_records.take(child_records.index(first_child_usage) + 1))

    receipt, = run_fixture(fixture: fixture)

    assert_equal 0, receipt.dig("accounting", "counter_resets")
    assert_equal 1, receipt.dig("accounting", "compactions")
    assert_equal "UNKNOWN", receipt.dig("evidence", "status")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "ambiguous_counter_decrease" }
    assert_equal 9, reason.fetch("line")
    assert_equal(
      %w[input_tokens output_tokens reasoning_output_tokens cache_read_tokens total_tokens],
      reason.fetch("fields")
    )
  end

  def test_post_boundary_compaction_still_corroborates_a_child_counter_reset
    fixture = fixture_copy("replay")
    child_records = fixture.fetch("rollouts").fetch("child.jsonl")
    first_child_usage = child_records.find { |record| record["timestamp"] == "2026-08-01T01:00:03Z" }
    child_records.insert(
      child_records.index(first_child_usage),
      { "timestamp" => "2026-08-01T01:00:02.500Z", "type" => "compacted", "payload" => {} }
    )
    decreased_usage = {
      "input_tokens" => 12,
      "cached_input_tokens" => 5,
      "output_tokens" => 3,
      "reasoning_output_tokens" => 1,
      "total_tokens" => 15
    }
    first_child_usage.dig("payload", "info")["total_token_usage"] = decreased_usage
    first_child_usage.dig("payload", "info")["last_token_usage"] = decreased_usage.dup
    child_records.replace(child_records.take(child_records.index(first_child_usage) + 1))

    receipt, = run_fixture(fixture: fixture)

    assert_equal 35, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 15, receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens")
    assert_equal 1, receipt.dig("accounting", "counter_resets")
    assert_equal 1, receipt.dig("accounting", "compactions")
    assert_equal "complete", receipt.dig("evidence", "status")
  end

  def test_invalid_utf8_rollout_bytes_emit_structured_unknown_without_a_backtrace
    fixture = fixture_copy("replay")
    raw_session_meta = JSON.generate(fixture.dig("rollouts", "root.jsonl", 0)).b
    raw_session_meta.setbyte(raw_session_meta.index('"root-thread"') + 1, 0xFF)
    fixture.dig("rollouts", "root.jsonl")[0] = RawRolloutLine.new(
      content: raw_session_meta.force_encoding(Encoding::UTF_8)
    )

    receipt, = run_fixture(fixture: fixture)

    assert_equal "UNKNOWN", receipt.dig("coordinator", "usage", "self_only", "total_tokens")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "rollout_read_error" }
    assert_equal 1, reason.fetch("line")
    assert_equal "Encoding::InvalidByteSequenceError", reason.fetch("detail")
  end

  def test_cumulative_differencing_precedes_window_filter_and_accounts_for_seed_reset_and_compaction
    receipt, = run_fixture("reset-seed-compaction-window")

    assert_equal 19, receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal 15, receipt.dig("batch", "usage", "descendant_inclusive", "input_tokens")
    assert_equal 4, receipt.dig("batch", "usage", "descendant_inclusive", "output_tokens")
    assert_equal 1, receipt.dig("accounting", "inherited_seeds_omitted")
    assert_equal 1, receipt.dig("accounting", "counter_resets")
    assert_equal 1, receipt.dig("accounting", "compactions")
    assert_equal 1, receipt.dig("accounting", "duplicate_samples_omitted")
    assert_equal 0, receipt.dig("accounting", "session_rebind_attempts_ignored"),
                 "resume metadata with the same first session identity is not a rebind"
    assert_equal "full_history_before_window_filter", receipt.dig("window", "differencing")
  end

  def test_malformed_token_counts_at_or_after_window_end_do_not_taint_an_earlier_receipt
    control, = run_fixture(fixture: fixture_copy("descendants"))
    fixture = fixture_copy("descendants")
    records = fixture.fetch("rollouts").fetch("root.jsonl")
    [fixture.dig("window", "to"), "2026-08-05T00:00:01Z"].each do |timestamp|
      records << {
        "timestamp" => timestamp,
        "type" => "event_msg",
        "payload" => { "type" => "token_count", "info" => {} }
      }
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal control.dig("batch", "usage"), receipt.dig("batch", "usage")
    assert_equal control.dig("accounting", "usage_samples"), receipt.dig("accounting", "usage_samples")
    assert_equal "complete", receipt.dig("evidence", "status")
    unknown_codes = receipt.dig("evidence", "unknown").map { |item| item.fetch("code") }
    refute_includes unknown_codes, "missing_total_token_usage"
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
    schema_errors = JSONSchemer.schema(receipt_schema).validate(receipt).to_a
    assert_empty schema_errors, schema_errors.map { |error| error.fetch("error") }.join("\n")
  end

  def test_window_rejects_years_that_cannot_remain_four_digits_after_utc_normalization
    cases = [
      ["from", "10000-08-01T00:00:00Z", "--from"],
      ["to", "-000001-08-02T00:00:00Z", "--to"],
      ["from", "0000-01-01T00:00:00+14:00", "--from"],
      ["to", "9999-12-31T23:59:59-14:00", "--to"]
    ]

    cases.each do |key, timestamp, label|
      fixture = fixture_copy("replay")
      fixture.fetch("window")[key] = timestamp

      stderr, status = run_fixture(fixture: fixture, expect_success: false)

      assert_equal 64, status.exitstatus, timestamp
      assert_equal "ERROR: #{label} must use a four-digit year representable after UTC normalization\n", stderr
    end
  end

  def test_window_rejects_non_rfc3339_time_and_offset_shapes
    cases = [
      ["from", "2026-08-01T00:00:00+10", "--from"],
      ["from", "2026-08-01T00:00:00+1000", "--from"],
      ["to", "2026-08-01T24:00:00Z", "--to"],
      ["from", "2026-08-01T00:00:00+10:60", "--from"]
    ]

    cases.each do |key, timestamp, label|
      fixture = fixture_copy("replay")
      fixture.fetch("window")[key] = timestamp

      stderr, status = run_fixture(fixture: fixture, expect_success: false)

      assert_equal 64, status.exitstatus, timestamp
      assert_equal "ERROR: #{label} must be an ISO 8601 timestamp\n", stderr
    end
  end

  def test_window_rejects_calendar_dates_that_do_not_exist
    timestamps = %w[
      2026-02-30T00:00:00Z
      2026-02-29T00:00:00Z
      2026-04-31T00:00:00Z
      2026-00-01T00:00:00Z
      2026-13-01T00:00:00Z
      2026-01-00T00:00:00Z
      2026-01-32T00:00:00Z
    ]

    timestamps.each do |timestamp|
      fixture = fixture_copy("replay")
      fixture.fetch("window")["from"] = timestamp

      stderr, status = run_fixture(fixture: fixture, expect_success: false)

      assert_equal 64, status.exitstatus, timestamp
      assert_equal "ERROR: --from must be an ISO 8601 timestamp\n", stderr
    end
  end

  def test_window_rejects_schema_invalid_leap_seconds
    timestamps = %w[
      2026-08-01T00:00:60Z
      2026-08-01T23:58:60Z
      2026-08-01T01:00:60+01:00
      2026-08-01T18:30:60-05:30
      2026-08-01T23:59:61Z
    ]

    timestamps.each do |timestamp|
      fixture = fixture_copy("replay")
      fixture.fetch("window")["from"] = timestamp

      stderr, status = run_fixture(fixture: fixture, expect_success: false)

      assert_equal 64, status.exitstatus, timestamp
      assert_equal "ERROR: --from must be an ISO 8601 timestamp\n", stderr
    end
  end

  def test_window_parser_matches_schema_across_time_component_and_offset_boundaries
    date_time_schema = receipt_schema.dig("properties", "window", "properties", "from_inclusive")
    schema_validator = JSONSchemer.schema(date_time_schema)
    offsets = %w[Z +01:00 -01:00 +05:30 -05:30 +23:00 -23:00]

    offsets.product((0..23).to_a, (0..59).to_a, [0, 59, 60, 61]).each do |offset, hour, minute, second|
      timestamp = format(
        "2026-08-01T%<hour>02d:%<minute>02d:%<second>02d%<offset>s",
        hour: hour, minute: minute, second: second, offset: offset
      )
      schema_valid = schema_validator.valid?(timestamp)
      parser_valid = begin
        BatchUsageReceipt.parse_time(timestamp, "--from")
        true
      rescue BatchUsageReceipt::InputError
        false
      end

      assert_equal schema_valid, parser_valid, timestamp
    end
  end

  def test_window_accepts_rfc3339_lowercase_leap_and_colon_offset_controls
    cases = [
      ["2026-08-01T05:30:00.123456789+05:30", "2026-08-01T00:00:00.123456789Z"],
      ["2016-12-31T23:59:60Z", "2017-01-01T00:00:00.000000000Z"],
      ["2017-01-01T00:59:60+01:00", "2017-01-01T00:00:00.000000000Z"],
      ["2016-12-31T18:29:60-05:30", "2017-01-01T00:00:00.000000000Z"],
      ["2024-02-29t00:00:00z", "2024-02-29T00:00:00.000000000Z"]
    ]

    cases.each do |timestamp, expected|
      fixture = fixture_copy("replay")
      fixture.fetch("window")["from"] = timestamp

      receipt, = run_fixture(fixture: fixture)

      assert_equal expected, receipt.dig("window", "from_inclusive"), timestamp
      schema_errors = JSONSchemer.schema(receipt_schema).validate(receipt).to_a
      assert_empty schema_errors, schema_errors.map { |error| error.fetch("error") }.join("\n")
    end
  end

  def test_window_requires_an_explicit_offset_in_every_local_timezone
    %w[UTC America/New_York].each do |timezone|
      { "--from" => "from", "--to" => "to" }.each do |label, key|
        fixture = fixture_copy("replay")
        fixture.fetch("window")[key] = "2026-08-01T00:00:00"

        stderr, status = run_fixture(
          fixture: fixture,
          expect_success: false,
          environment: { "TZ" => timezone }
        )

        assert_equal 64, status.exitstatus, timezone
        assert_equal "ERROR: #{label} must include an explicit UTC offset or Z\n", stderr
      end
    end
  end

  def test_window_rejects_fractional_seconds_beyond_nanosecond_precision
    fixture = fixture_copy("replay")
    fixture["window"]["from"] = "2026-08-01T00:00:00.1234567899Z"

    stderr, status = run_fixture(fixture: fixture, expect_success: false)

    assert_equal 64, status.exitstatus
    assert_equal "ERROR: --from must use no more than 9 fractional-second digits\n", stderr
  end

  def test_window_rejects_comma_fraction_with_the_generic_iso8601_error
    fixture = fixture_copy("replay")
    fixture["window"]["from"] = "2026-08-01T00:00:00,123Z"

    stderr, status = run_fixture(fixture: fixture, expect_success: false)

    assert_equal 64, status.exitstatus
    assert_equal "ERROR: --from must be an ISO 8601 timestamp\n", stderr
  end

  def test_non_object_manifests_return_normal_input_error
    [[], nil].each do |manifest|
      fixture = fixture_copy("replay")
      fixture["manifest"] = manifest

      stderr, status = run_fixture(fixture: fixture, expect_success: false)

      assert_equal 64, status.exitstatus
      assert_equal "ERROR: manifest must be an object\n", stderr
    end
  end

  def test_manifest_and_rate_card_read_failures_are_privacy_safe_input_errors
    fixture = fixture_copy("replay")
    Dir.mktmpdir("batch-usage-receipt-input") do |directory|
      manifest_path = File.join(directory, "manifest.json")
      File.write(manifest_path, JSON.generate(fixture.fetch("manifest")))
      input_directory = File.join(directory, "input-directory")
      Dir.mkdir(input_directory)
      missing_path = File.join(directory, "missing.json")

      %w[manifest rate-card].product([input_directory, missing_path]).each do |label, invalid_path|
        command = [
          "ruby", HELPER,
          "--state-db", File.join(directory, "unused.sqlite"),
          "--manifest", label == "manifest" ? invalid_path : manifest_path,
          "--from", fixture.dig("window", "from"),
          "--to", fixture.dig("window", "to")
        ]
        command.concat(["--rate-card", invalid_path]) if label == "rate-card"

        stdout, stderr, status = Open3.capture3(*command)

        assert_empty stdout
        assert_equal 64, status.exitstatus
        assert_equal "ERROR: #{label} could not be read\n", stderr
        refute_includes stderr, invalid_path
        refute_includes stderr, "Errno::"
      end
    end
  end

  def test_contradictory_known_token_vectors_make_the_affected_rollout_structurally_unknown
    %w[total_token_usage last_token_usage].each do |counter_source|
      fixture = fixture_copy("replay")
      first_sample = fixture.fetch("rollouts").fetch("root.jsonl").find do |record|
        record["type"] == "event_msg" && record.dig("payload", "type") == "token_count"
      end
      first_sample.dig("payload", "info", counter_source)["total_tokens"] = 9

      receipt, = run_fixture(fixture: fixture)

      assert_equal "UNKNOWN", receipt.dig("coordinator", "usage", "self_only", "total_tokens")
      assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
      reason = receipt.dig("evidence", "unknown").find do |item|
        item["code"] == "invalid_token_usage_vector" && item["counter_source"] == counter_source
      end
      refute_nil reason
      assert_equal 3, reason.fetch("line")
    end
  end

  def test_reasoning_output_tokens_are_preserved_and_never_inferred
    fixture = fixture_copy("replay")
    reasoning_totals = {
      "root.jsonl" => [[1, 1], [2, 1]],
      "child.jsonl" => [[1, 1], [2, 1], [3, 1], [3, 99], [4, 1]]
    }
    fixture.fetch("rollouts").each do |rollout, records|
      token_records = records.select do |record|
        record["type"] == "event_msg" && record.dig("payload", "type") == "token_count"
      end
      token_records.zip(reasoning_totals.fetch(rollout)).each do |record, (total, last)|
        info = record.dig("payload", "info")
        info.fetch("total_token_usage")["reasoning_output_tokens"] = total
        info.fetch("last_token_usage")["reasoning_output_tokens"] = last
      end
    end

    receipt, = run_fixture(fixture: fixture)

    assert_equal 4, receipt.dig("batch", "usage", "descendant_inclusive", "reasoning_output_tokens")
    assert_empty JSONSchemer.schema(receipt_schema).validate(receipt).to_a

    fixture.fetch("rollouts").each_value do |records|
      records.each do |record|
        info = record.dig("payload", "info")
        next unless info.is_a?(Hash)

        %w[total_token_usage last_token_usage].each do |counter_source|
          info[counter_source]&.delete("reasoning_output_tokens")
        end
      end
    end

    receipt_without_reasoning, = run_fixture(fixture: fixture)

    assert_equal 30, receipt_without_reasoning.dig("batch", "usage", "descendant_inclusive", "total_tokens")
    assert_equal "UNKNOWN",
                 receipt_without_reasoning.dig("batch", "usage", "descendant_inclusive", "reasoning_output_tokens")
  end

  def test_parsed_non_object_rollout_records_are_line_numbered_structural_unknowns
    [[], nil, "unexpected"].each do |record|
      fixture = fixture_copy("replay")
      fixture.fetch("rollouts").fetch("root.jsonl").insert(2, record)

      receipt, = run_fixture(fixture: fixture)

      assert_equal "UNKNOWN", receipt.dig("coordinator", "usage", "self_only", "total_tokens")
      assert_equal 10, receipt.dig("lanes", 0, "usage", "descendant_inclusive", "total_tokens")
      reason = receipt.dig("evidence", "unknown").find do |item|
        item["code"] == "non_object_rollout_record"
      end
      refute_nil reason
      assert_equal 3, reason.fetch("line")
    end
  end

  def test_first_sample_without_last_usage_is_unknown_instead_of_importing_cumulative_history
    receipt, = run_fixture("missing-first-last")

    expected = {
      "input_tokens" => "UNKNOWN",
      "output_tokens" => "UNKNOWN",
      "reasoning_output_tokens" => "UNKNOWN",
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
        "reasoning_output_tokens" => 3,
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

  def test_invalid_usage_timestamp_conservatively_invalidates_the_physical_rollout
    receipt, = run_fixture("invalid-usage-timestamp")

    assert_equal blank_usage_for_test.transform_values { "UNKNOWN" },
                 receipt.dig("batch", "usage", "descendant_inclusive")
    assert_equal "UNKNOWN", receipt.dig("batch", "turns", "descendant_inclusive")
    assert_equal "UNKNOWN", receipt.dig("coordinator", "evidence", "status")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "invalid_usage_timestamp" }
    assert_equal 3, reason.fetch("line")
  end

  def test_zone_less_usage_timestamp_is_unknown_in_every_local_timezone
    fixture = fixture_copy("replay")
    fixture.dig("rollouts", "root.jsonl", 3)["timestamp"] = "2026-08-01T23:30:00"

    %w[UTC America/New_York].each do |timezone|
      receipt, = run_fixture(fixture: fixture, environment: { "TZ" => timezone })

      assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens"), timezone
      assert_equal "UNKNOWN", receipt.dig("coordinator", "evidence", "status"), timezone
      reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "invalid_usage_timestamp" }
      assert_equal 4, reason.fetch("line"), timezone
    end
  end

  def test_zone_less_copied_replay_timestamp_is_unknown_in_every_local_timezone
    fixture = fixture_copy("replay")
    fixture.dig("rollouts", "child.jsonl", 4)["timestamp"] = "2026-08-01T01:00:00.003"
    receipts = %w[UTC Pacific/Honolulu].map do |timezone|
      receipt, = run_fixture(fixture: fixture, environment: { "TZ" => timezone })

      assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens"), timezone
      assert_equal "UNKNOWN",
                   receipt.dig("lanes", 0, "workers", 0, "usage", "descendant_inclusive", "total_tokens"),
                   timezone
      assert_equal "UNKNOWN", receipt.dig("lanes", 0, "workers", 0, "evidence", "status"), timezone
      reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "invalid_usage_timestamp" }
      assert_equal 5, reason.fetch("line"), timezone
      receipt
    end

    assert_equal receipts.first, receipts.last
  end

  def test_invalid_replay_boundary_timestamps_are_line_numbered_private_and_fail_safe
    [nil, "not-a-timestamp-/private/secret-rollout.jsonl"].each do |timestamp|
      fixture = fixture_copy("replay")
      boundary = fixture.fetch("rollouts").fetch("child.jsonl").find do |record|
        record["type"] == "inter_agent_communication_metadata"
      end
      timestamp ? boundary["timestamp"] = timestamp : boundary.delete("timestamp")

      receipt, output = run_fixture(fixture: fixture)

      assert_equal "UNKNOWN", receipt.dig("batch", "usage", "descendant_inclusive", "total_tokens")
      unknown = receipt.dig("evidence", "unknown")
      codes = unknown.map { |item| item.fetch("code") }
      assert_includes codes, "invalid_boundary_timestamp"
      assert_includes codes, "copied_history_boundary_missing"
      reason = unknown.find { |item| item["code"] == "invalid_boundary_timestamp" }
      assert_equal 6, reason.fetch("line")
      assert_equal %w[code line physical_rollout_id status thread_id], reason.keys.sort
      refute_includes output, timestamp if timestamp
    end
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
        "reasoning_output_tokens" => 1,
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
    token_info = first_token_info(fixture, "lane-b.jsonl")
    token_info.each_value { |usage| usage.transform_values! { 0 } }

    receipt, = run_fixture(fixture: fixture, with_rate_card: true)

    assert_equal "UNKNOWN", receipt.dig("lanes", 0, "reconciliation", "status")
    assert_equal "UNKNOWN", receipt.dig("credit_equivalents", "status")
    reason = receipt.dig("evidence", "unknown").find { |item| item["code"] == "worker_outside_lane_scope" }
    assert_equal "lane-a", reason.fetch("lane_id")
  end

  def test_overlapping_lane_topology_forces_batch_reconciliation_unknown_when_zero_usage_balances
    fixture = fixture_copy("descendants")
    root_to_lane_b = fixture.fetch("edges").find { |edge| edge[1] == "lane-b" }
    root_to_lane_b[0] = "lane-a"
    token_info = first_token_info(fixture, "lane-b.jsonl")
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
      token_info = first_token_info(fixture, rollout)
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

  def test_unexpected_state_loader_no_method_error_is_not_swallowed
    fixture = fixture_copy("replay")
    Dir.mktmpdir("batch-usage-receipt-state") do |directory|
      database_path = File.join(directory, "state_5.sqlite")
      File.write(database_path, "")
      reporter = BatchUsageReceipt::Reporter.new(
        manifest: fixture.fetch("manifest"),
        database_path: database_path,
        from_time: Time.iso8601(fixture.dig("window", "from")),
        to_time: Time.iso8601(fixture.dig("window", "to"))
      )
      reporter.define_singleton_method(:state_query) { nil.unexpected_state_query_bug }

      error = assert_raises(NoMethodError) { reporter.send(:load_state) }

      assert_includes error.message, "unexpected_state_query_bug"
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

  def test_non_object_rate_cards_return_normal_input_error
    [[], nil, "unexpected", 7].each do |rate_card|
      fixture = fixture_copy("descendants")
      fixture["rate_card"] = rate_card

      stderr, status = run_fixture(fixture: fixture, with_rate_card: true, expect_success: false)

      assert_equal 64, status.exitstatus
      assert_equal "ERROR: rate-card must be an object\n", stderr
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

  def test_published_v1_schema_remains_compatible_and_rejects_v2_turns
    receipt_with_turns, = run_fixture("replay")
    v1_with_turns = JSON.parse(JSON.generate(receipt_with_turns))
    v1_with_turns["schema"] = "batch-usage-receipt-v1"
    main_era_v1 = JSON.parse(JSON.generate(v1_with_turns))
    main_era_v1.fetch("batch").delete("turns")
    main_era_v1.fetch("coordinator").delete("turns")
    main_era_v1.fetch("lanes").each do |lane|
      lane.delete("turns")
      lane.fetch("workers").each { |worker| worker.delete("turns") }
    end
    schema = receipt_schema(1)

    assert_equal "batch-usage-receipt-v1", main_era_v1.fetch("schema")
    assert_empty JSONSchemer.schema(schema).validate(main_era_v1).to_a
    refute_empty JSONSchemer.schema(schema).validate(v1_with_turns).to_a
  end

  def test_v2_schema_requires_turns_and_validates_current_producer_output
    receipt, = run_fixture("replay")
    schema = receipt_schema(2)

    assert_equal "batch-usage-receipt-v2", receipt.fetch("schema")
    assert_equal "Batch Usage Receipt v2", schema.fetch("title")
    assert_equal "batch-usage-receipt-v2", schema.dig("properties", "schema", "const")
    assert_empty JSONSchemer.schema(schema).validate(receipt).to_a

    missing_turns = JSON.parse(JSON.generate(receipt))
    missing_turns.fetch("coordinator").delete("turns")
    refute_empty JSONSchemer.schema(schema).validate(missing_turns).to_a
  end

  def test_v2_schema_conditionally_requires_complete_scope_evidence_identities
    receipt, = run_fixture("replay")
    schema = JSONSchemer.schema(receipt_schema(2))
    scopes = [receipt.fetch("coordinator")] + receipt.fetch("lanes") +
             receipt.fetch("lanes").flat_map { |lane| lane.fetch("workers") }

    scopes.each do |scope|
      evidence = scope.fetch("evidence")
      assert_equal "complete", evidence.fetch("status"), scope.fetch("id")
      refute_empty evidence.fetch("physical_rollout_ids"), scope.fetch("id")
      refute_empty evidence.fetch("first_session_ids"), scope.fetch("id")
      assert_equal evidence.fetch("physical_rollout_ids").length,
                   evidence.fetch("first_session_ids").length,
                   scope.fetch("id")
      if evidence.fetch("first_session_ids").one?
        assert_equal evidence.fetch("first_session_ids").first, evidence.fetch("first_session_id"), scope.fetch("id")
      else
        refute evidence.key?("first_session_id"), scope.fetch("id")
      end
    end

    empty_complete = JSON.parse(JSON.generate(receipt))
    empty_complete_evidence = empty_complete.dig("coordinator", "evidence")
    empty_complete_evidence["physical_rollout_ids"] = []
    empty_complete_evidence["first_session_ids"] = []
    empty_complete_evidence.delete("first_session_id")
    refute_empty schema.validate(empty_complete).to_a

    missing_singleton_alias = JSON.parse(JSON.generate(receipt))
    missing_singleton_alias.dig("lanes", 0, "workers", 0, "evidence").delete("first_session_id")
    refute_empty schema.validate(missing_singleton_alias).to_a

    multiple_with_singleton_alias = JSON.parse(JSON.generate(receipt))
    multiple_evidence = multiple_with_singleton_alias.dig("lanes", 0, "workers", 0, "evidence")
    multiple_evidence.fetch("first_session_ids") << "second-session"
    multiple_evidence.fetch("physical_rollout_ids") << "sha256:#{'f' * 64}"
    refute_empty schema.validate(multiple_with_singleton_alias).to_a

    empty_unknown = JSON.parse(JSON.generate(empty_complete))
    empty_unknown.dig("coordinator", "evidence")["status"] = "UNKNOWN"
    assert_empty schema.validate(empty_unknown).to_a
  end

  def test_v2_schema_requires_top_level_unknown_evidence_to_name_at_least_one_exact_reason
    receipt, = run_fixture("replay")
    receipt.fetch("evidence").merge!("status" => "UNKNOWN", "unknown" => [])

    refute_empty JSONSchemer.schema(receipt_schema(2)).validate(receipt).to_a
  end

  def test_v2_schema_rejects_accounting_extensions_the_budget_evaluator_does_not_accept
    receipt, = run_fixture("replay")
    receipt.fetch("accounting")["future_counter"] = 0

    refute_empty JSONSchemer.schema(receipt_schema(2)).validate(receipt).to_a
  end

  def test_v2_schema_accepts_only_producer_defined_unknown_reason_metadata
    receipt, = run_fixture("replay")
    schema = JSONSchemer.schema(receipt_schema(2))
    thread_id = receipt.dig("coordinator", "root_thread_id")
    physical_rollout_id = receipt.dig("coordinator", "evidence", "physical_rollout_ids").first
    rollout_identity = {
      "thread_id" => thread_id,
      "physical_rollout_id" => physical_rollout_id
    }
    valid_reasons = [
      { "status" => "UNKNOWN", "code" => "state_database_missing" },
      {
        "status" => "UNKNOWN", "code" => "coordinator_root_in_lane_scope",
        "lane_id" => "lane-a", "thread_id" => thread_id
      },
      {
        "status" => "UNKNOWN", "code" => "lane_scope_overlap",
        "lane_ids" => %w[lane-a lane-b], "thread_ids" => [thread_id]
      },
      {
        "status" => "UNKNOWN", "code" => "worker_outside_lane_scope",
        "lane_id" => "lane-a", "worker_id" => "worker-a"
      },
      {
        "status" => "UNKNOWN", "code" => "worker_scope_overlap",
        "lane_id" => "lane-a", "worker_ids" => %w[worker-a worker-b]
      },
      { "status" => "UNKNOWN", "code" => "thread_missing", "thread_id" => thread_id },
      { "status" => "UNKNOWN", "code" => "rollout_missing" }.merge(rollout_identity),
      { "status" => "UNKNOWN", "code" => "malformed_jsonl", "line" => 2 }.merge(rollout_identity),
      {
        "status" => "UNKNOWN", "code" => "rollout_read_error", "detail" => "Errno::EACCES"
      }.merge(rollout_identity),
      {
        "status" => "UNKNOWN", "code" => "rollout_read_error", "line" => 2,
        "detail" => "Encoding::InvalidByteSequenceError"
      }.merge(rollout_identity),
      {
        "status" => "UNKNOWN", "code" => "invalid_token_usage_vector", "line" => 2,
        "counter_source" => "total_token_usage"
      }.merge(rollout_identity),
      {
        "status" => "UNKNOWN", "code" => "usage_counter_missing", "line" => 2,
        "fields" => ["cache_read_tokens"]
      }.merge(rollout_identity),
      {
        "status" => "UNKNOWN", "code" => "route_metadata_missing", "line" => 2,
        "fields" => ["model"]
      }.merge(rollout_identity)
    ]
    valid_reasons.concat(
      %w[state_database_unsupported sqlite3_cli_unavailable].map do |code|
        { "status" => "UNKNOWN", "code" => code }
      end
    )
    valid_reasons << { "status" => "UNKNOWN", "code" => "rollout_path_missing", "thread_id" => thread_id }
    valid_reasons.concat(
      %w[
        missing_first_session_id state_thread_first_session_mismatch copied_history_boundary_missing
        missing_first_session_meta missing_usage_evidence
      ].map { |code| { "status" => "UNKNOWN", "code" => code }.merge(rollout_identity) }
    )
    valid_reasons.concat(
      %w[
        non_object_rollout_record invalid_boundary_timestamp invalid_turn_context invalid_turn_timestamp
        invalid_usage_timestamp missing_total_token_usage ambiguous_turn_usage ambiguous_turn_timestamp
        turn_context_missing_for_usage
      ].map do |code|
        { "status" => "UNKNOWN", "code" => code, "line" => 2 }.merge(rollout_identity)
      end
    )
    valid_reasons.concat(
      %w[missing_first_last_token_usage ambiguous_counter_decrease].map do |code|
        {
          "status" => "UNKNOWN", "code" => code, "line" => 2,
          "fields" => ["total_tokens"]
        }.merge(rollout_identity)
      end
    )

    producer_source = File.read(HELPER, encoding: "UTF-8").split("\n    def credit_equivalents", 2).first
    producer_codes = producer_source.scan(/\bunknown(?:_turn)?\(\s*"([a-z0-9_]+)"/m).flatten
    producer_codes.concat(producer_source.scan(/"code"\s*=>\s*"([a-z0-9_]+)"/).flatten)
    schema_codes = receipt_schema(2).dig("$defs", "unknownReason", "oneOf").flat_map do |variant|
      code_contract = variant.dig("properties", "code")
      code_contract["enum"] || [code_contract.fetch("const")]
    end
    asserted_codes = valid_reasons.map { |reason| reason.fetch("code") }.uniq
    assert_equal producer_codes.uniq.sort, asserted_codes.sort
    assert_equal producer_codes.uniq.sort, schema_codes.uniq.sort

    valid_reasons.each do |reason|
      candidate = JSON.parse(JSON.generate(receipt))
      candidate.fetch("evidence").merge!("status" => "UNKNOWN", "unknown" => [reason])
      assert_empty schema.validate(candidate).to_a, reason.fetch("code")
    end

    canonical_route_reason = valid_reasons.last
    invalid_reasons = {
      "nested-sentinel" => canonical_route_reason.merge(
        "unexpected_content" => { "nested" => ["secret-payload"] }
      ),
      "extra-scalar" => canonical_route_reason.merge("unexpected_scalar" => "secret-payload"),
      "extra-object" => canonical_route_reason.merge("unexpected_object" => { "payload" => "secret-payload" }),
      "extra-array" => canonical_route_reason.merge("unexpected_array" => ["secret-payload"]),
      "wrong-code-metadata" => canonical_route_reason.merge("detail" => "ArgumentError"),
      "unknown-code" => { "status" => "UNKNOWN", "code" => "future_reason" }
    }
    invalid_reasons.each do |name, reason|
      candidate = JSON.parse(JSON.generate(receipt))
      candidate.fetch("evidence").merge!("status" => "UNKNOWN", "unknown" => [reason])
      refute_empty schema.validate(candidate).to_a, name
    end
  end

  def test_output_is_deterministic_across_replays_and_public_contract_is_versioned
    first_receipt, first_output = run_fixture("replay")
    second_receipt, second_output = run_fixture("replay")

    assert_equal first_receipt, second_receipt
    assert_equal first_output, second_output

    root = File.expand_path("../../..", __dir__)
    schema = receipt_schema(2)
    assert_equal "Batch Usage Receipt v2", schema.fetch("title")
    assert_equal "batch-usage-receipt-v2", schema.dig("properties", "schema", "const")
    assert schema.dig("$defs", "batchScope")
    assert schema.dig("$defs", "executionScope")
    assert schema.dig("$defs", "coordinatorScope")
    assert schema.dig("$defs", "workerScope")
    assert schema.dig("$defs", "laneScope")
    schema_errors = JSONSchemer.schema(schema).validate(first_receipt).to_a
    assert_empty schema_errors, schema_errors.map { |error| error.fetch("error") }.join("\n")

    missing_turns = JSON.parse(JSON.generate(first_receipt))
    missing_turns.fetch("coordinator").delete("turns")
    refute_empty JSONSchemer.schema(schema).validate(missing_turns).to_a

    invalid_turn_count = JSON.parse(JSON.generate(first_receipt))
    invalid_turn_count.dig("batch", "turns")["descendant_inclusive"] = -1
    refute_empty JSONSchemer.schema(schema).validate(invalid_turn_count).to_a

    unknown_turn_count = JSON.parse(JSON.generate(first_receipt))
    unknown_turn_count.dig("batch", "turns")["descendant_inclusive"] = "UNKNOWN"
    assert_empty JSONSchemer.schema(schema).validate(unknown_turn_count).to_a

    role_swapped_coordinator = JSON.parse(JSON.generate(first_receipt))
    role_swapped_coordinator.fetch("coordinator")["scope"] = "worker"
    refute_empty JSONSchemer.schema(schema).validate(role_swapped_coordinator).to_a

    role_swapped_worker = JSON.parse(JSON.generate(first_receipt))
    role_swapped_worker.dig("lanes", 0, "workers", 0)["scope"] = "coordinator"
    refute_empty JSONSchemer.schema(schema).validate(role_swapped_worker).to_a

    duplicate_physical_id = JSON.parse(JSON.generate(first_receipt))
    physical_ids = duplicate_physical_id.dig("coordinator", "evidence", "physical_rollout_ids")
    physical_ids << physical_ids.fetch(0)
    refute_empty JSONSchemer.schema(schema).validate(duplicate_physical_id).to_a

    docs = File.read(File.join(root, "docs/batch-usage-receipt.md"), encoding: "UTF-8")
    assert_includes docs, "`last_token_usage` is never summed."
    assert_includes docs, "complete physical rollout"
    assert_includes docs, "not an invoice"
    assert_includes docs, "supported and attempted metadata source"
    assert_includes docs, "complete physical rollouts used for differencing"
    assert_includes docs, "worker_outside_lane_scope"
    assert_includes docs, "entire affected rollout's counter vector"
    assert_includes docs, "do not normalize `cache_read_tokens`"
    assert_includes docs, "`reasoning_output_tokens`"
    assert_includes docs, "invalid_token_usage_vector"
    assert_includes docs, "non_object_rollout_record"
    assert_includes docs, "invalid_usage_timestamp"
    assert_includes docs, "distinct rollout `turn_context` segments"
    assert_includes docs, "`usage_samples` is diagnostic only"
    assert_includes docs, "ambiguous_turn_timestamp"

    workflow = File.read(File.join(root, "workflows/pr-processing.md"), encoding: "UTF-8")
    skill = File.read(File.join(root, "skills/pr-batch/SKILL.md"), encoding: "UTF-8")
    [workflow, skill].each do |surface|
      assert_includes surface, "`bin/batch-usage-receipt` helper"
      assert_includes surface, "durable artifact reference"
      assert_includes surface, "informational"
      assert_match(/contributing-turn\s+counts/, surface)
    end
  end

  def test_repo_validation_pins_json_schemer_in_the_receipt_test_process
    root = File.expand_path("../../..", __dir__)
    validate = File.read(File.join(root, "bin/validate"), encoding: "UTF-8")
    invocation = validate.lines.find { |line| line.include?("batch-usage-receipt-test.rb") }
    test_source = File.read(__FILE__, encoding: "UTF-8")

    refute_nil invocation
    assert_includes invocation, 'JSON_SCHEMER_VERSION="${JSON_SCHEMER_VERSION}"'
    assert_includes test_source, 'gem "json_schemer", PINNED_JSON_SCHEMER_VERSION'
  end

  private

  def first_token_info(fixture, rollout)
    record = fixture.dig("rollouts", rollout).find do |candidate|
      candidate.dig("payload", "type") == "token_count"
    end
    record.dig("payload", "info")
  end

  def turn_context_record(timestamp)
    {
      "timestamp" => timestamp,
      "type" => "turn_context",
      "payload" => { "model" => "turn-model", "effort" => "high" }
    }
  end

  def token_count_record(timestamp, total:, last:)
    usage = {
      "input_tokens" => total,
      "cached_input_tokens" => 0,
      "output_tokens" => 0,
      "reasoning_output_tokens" => 0,
      "total_tokens" => total
    }
    last_usage = usage.merge("input_tokens" => last, "total_tokens" => last)
    {
      "timestamp" => timestamp,
      "type" => "event_msg",
      "payload" => {
        "type" => "token_count",
        "info" => { "total_token_usage" => usage, "last_token_usage" => last_usage }
      }
    }
  end

  def fixture_copy(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json"), encoding: "UTF-8"))
  end

  def blank_usage_for_test
    {
      "input_tokens" => 0,
      "output_tokens" => 0,
      "reasoning_output_tokens" => 0,
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

  def receipt_schema(version = 2)
    root = File.expand_path("../../..", __dir__)
    JSON.parse(File.read(File.join(root, "docs/schemas/batch-usage-receipt-v#{version}.schema.json")))
  end
end
