# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../bin/agent_doctor/contract"

class AgentDoctorContractTest < Minitest::Test
  ResultRunner = Struct.new(:result) do
    def capture(_command)
      result
    end
  end

  def test_normalizes_required_fields_and_discards_additive_fields
    payload = healthy_payload.merge("future" => true)
    payload["checks"][0]["future"] = "ignored"

    normalized = AgentDoctor::Contract.normalize(payload, "agent-workflows", 0)

    assert_equal %w[checks component schema_version status], normalized.keys.sort
    assert_equal %w[details guidance id status summary], normalized["checks"][0].keys.sort
  end

  def test_rejects_duplicate_checks_and_status_exit_mismatch
    duplicate = healthy_payload
    duplicate["checks"] << duplicate["checks"].first.dup

    assert_raises(JSON::ParserError) { AgentDoctor::Contract.normalize(duplicate, "agent-workflows", 0) }
    assert_raises(JSON::ParserError) { AgentDoctor::Contract.normalize(healthy_payload, "agent-workflows", 1) }
  end

  def test_delegate_wraps_malformed_output_without_exposing_it
    runner = ResultRunner.new({ stdout: "not json", stderr: "secret", exit: 0, failure: nil })

    component = AgentDoctor::Contract.delegate("agent-workflows", ["doctor"], runner: runner)

    assert_equal "failed", component["status"]
    assert_equal "component doctor returned malformed JSON or violated contract", component.dig("checks", 0, "summary")
    refute_includes component.inspect, "not json"
  end

  def test_unavailable_optional_component_can_degrade
    component = AgentDoctor::Contract.unavailable("agent-coordination-dashboard", "missing", status: "degraded")

    assert_equal "degraded", component["status"]
    assert_equal "degraded", component.dig("checks", 0, "status")
  end

  private

  def healthy_payload
    {
      "schema_version" => 1,
      "component" => "agent-workflows",
      "status" => "healthy",
      "checks" => [{ "id" => "workflows.installation", "status" => "healthy", "summary" => "ready",
                     "details" => {}, "guidance" => nil }]
    }
  end
end
