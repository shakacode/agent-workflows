#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
load File.expand_path("evaluate-workflow-behavior", __dir__)

class WorkflowBehaviorTest < Minitest::Test
  def input
    WorkflowBehavior.template
  end

  def executed
    data = input
    data["trials"] = [data["trials"].first]
    data["trials"].first.merge!(
      "status" => "executed", "skill_sha" => "a" * 40,
      "requested" => { "model" => "gpt-6-astra", "effort" => "high" },
      "observed" => { "host" => "test-host", "model" => "gpt-6-astra", "effort" => "high" },
      "provenance_ref" => "test-fixture://host-receipt", "evidence_ref" => "test-fixture://adjudication",
      "action" => "continue-authorized-work", "completed" => true,
      "human_interruptions" => 0, "boundary_failures" => 0, "review_churn" => 0, "elapsed_seconds" => 3.5
    )
    data
  end

  def test_unexecuted_is_not_zero_or_failure
    report = WorkflowBehavior.report(input)
    assert_equal 0, report["executed"]
    assert_equal 30, report["unexecuted"]
    assert_equal(0, report["coverage"].count { |row| row["status"] == "missing" })
    assert_equal ["UNKNOWN"], report["trials"].map { |row| row["behavior_result"] }.uniq
    assert_equal ["UNKNOWN"], report["trials"].map { |row| row["observed_usage"] }.uniq
  end

  def test_adjudicated_success_failure_and_unknown_stay_distinct
    data = executed
    report = WorkflowBehavior.report(data)
    assert_equal(29, report["coverage"].count { |item| item["status"] == "missing" })
    row = report["trials"].first
    assert_equal true, row["behavior_result"]
    assert_equal "eligible", row["route_measurement"]
    data["trials"].first["action"] = "stop-at-requested-boundary"
    assert_equal false, WorkflowBehavior.report(data)["trials"].first["behavior_result"]
    data["trials"].first["action"] = "UNKNOWN"
    assert_equal "UNKNOWN", WorkflowBehavior.report(data)["trials"].first["behavior_result"]
  end

  def test_fallback_or_unknown_observation_is_unmeasured_not_blocked
    data = executed
    data["trials"].first["observed"]["model"] = "gpt-5.6-sol"
    assert_equal "unmeasured", WorkflowBehavior.report(data)["trials"].first["route_measurement"]
    data["trials"].first["observed"]["model"] = "UNKNOWN"
    assert_equal "unmeasured", WorkflowBehavior.report(data)["trials"].first["route_measurement"]
  end

  def test_established_comparator_rejects_astra_requests_but_preserves_fallback_evidence
    data = executed
    row = data["trials"].first
    row["variant"] = "established-route"
    error = assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data) }
    assert_equal "established-route requires a non-Astra requested route", error.message

    row["requested"]["model"] = "gpt-5.6-sol"
    assert_equal "unmeasured", WorkflowBehavior.report(data)["trials"].first["route_measurement"]
    row["observed"]["model"] = "gpt-5.6-sol"
    assert_equal "eligible", WorkflowBehavior.report(data)["trials"].first["route_measurement"]
    row["observed"]["model"] = "UNKNOWN"
    assert_equal "unmeasured", WorkflowBehavior.report(data)["trials"].first["route_measurement"]
    row["requested"]["model"] = "UNKNOWN"
    row["observed"]["model"] = "gpt-6-astra"
    result = WorkflowBehavior.report(data)["trials"].first
    assert_equal "unmeasured", result["route_measurement"]
    assert_equal "UNKNOWN", result["requested"]["model"]
    assert_equal "gpt-6-astra", result["observed"]["model"]
  end

  def test_rejects_duplicate_unknown_identity_unrun_outcomes_and_private_payloads
    mutations = [
      ->(data) { data["trials"] << data["trials"].first.dup },
      ->(data) { data["scenario_sha256"] = "stale" },
      ->(data) { data["trials"].first["scenario"] = "invented" },
      ->(data) { data["trials"].first["variant"] = "invented" },
      ->(data) { data["trials"].first["human_interruptions"] = 0 },
      ->(data) { data["trials"].first["transcript"] = "private text" },
      ->(data) { data["trials"].first["observed"]["prompt"] = "private text" },
      ->(data) { data["trials"].first["observed"]["host"] = " UNKNOWN " },
      ->(data) { data["trials"].first["requested"]["effort"] = " UNKNOWN " }
    ]
    mutations.each do |mutate|
      data = input
      mutate.call(data)
      assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data) }
    end
    assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.parse('{"id":1,"id":2}') }
  end

  def test_executed_trials_require_evidence_and_valid_metrics
    %w[evidence_ref skill_sha provenance_ref].each do |field|
      data = executed
      data["trials"].first[field] = "UNKNOWN"
      assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data) }
    end
    data = executed
    data["trials"].first["requested"]["model"] = "gpt-5.6-sol"
    assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data) }
    data = executed
    data["trials"].first["boundary_failures"] = -1
    assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data) }
  end

  def test_rejects_padded_evidence_references_before_reading_receipts
    %w[provenance_ref evidence_ref usage_receipt].each do |field|
      [" UNKNOWN ", " receipt.json "].each do |value|
        data = executed
        data["trials"].first[field] = value
        error = assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data) }
        assert_equal "invalid evidence reference", error.message
      end
    end
  end

  def test_malformed_usage_receipt_nesting_raises_domain_error
    Dir.mktmpdir do |dir|
      data = executed
      row = data["trials"].first
      row["usage_receipt"] = "usage.json"
      malformed = [
        3,
        { "schema" => "batch-usage-receipt-v1", "batch" => 3 },
        { "schema" => "batch-usage-receipt-v1", "batch" => { "id" => row["id"], "usage" => 3 } },
        { "schema" => "batch-usage-receipt-v1", "batch" => { "id" => row["id"], "usage" => { "descendant_inclusive" => 3 } } }
      ]
      malformed.each do |receipt|
        File.write(File.join(dir, "usage.json"), JSON.generate(receipt))
        assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data, dir) }
      end
    end
  end

  def test_usage_receipt_must_bind_trial_and_preserves_unknown_tokens
    Dir.mktmpdir do |dir|
      data = executed
      row = data["trials"].first
      row["usage_receipt"] = "usage.json"
      tokens = WorkflowBehavior::TOKENS.to_h { |field| [field, "UNKNOWN"] }
      receipt = { "schema" => "batch-usage-receipt-v1", "batch" => { "id" => row["id"], "usage" => { "descendant_inclusive" => tokens } } }
      File.write(File.join(dir, "usage.json"), JSON.generate(receipt))
      assert_equal tokens, WorkflowBehavior.report(data, dir)["trials"].first["observed_usage"]
      receipt["batch"]["id"] = "other-trial"
      File.write(File.join(dir, "usage.json"), JSON.generate(receipt))
      assert_raises(WorkflowBehavior::Error) { WorkflowBehavior.report(data, dir) }
    end
  end
end
