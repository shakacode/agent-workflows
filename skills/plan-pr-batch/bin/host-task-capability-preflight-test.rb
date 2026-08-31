#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"

HELPER = File.expand_path("host-task-capability-preflight", __dir__)
CASES = File.expand_path("../fixtures/host-task-capability-preflight-cases.json", __dir__)

class HostTaskCapabilityPreflightTest < Minitest::Test
  def test_capability_cases
    JSON.parse(File.read(CASES)).each do |test_case|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        HELPER,
        stdin_data: JSON.generate(test_case.fetch("input"))
      )

      assert status.success?, "#{test_case.fetch('name')}: #{stderr}"
      assert_equal test_case.fetch("expected"), JSON.parse(stdout), test_case.fetch("name")
    end
  end

  def test_malformed_json_is_a_successful_structured_invalid_input
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER, stdin_data: "not json")

    assert status.success?, stderr
    assert_equal(
      {
        "type" => "host-task-capability-preflight-result",
        "version" => 1,
        "status" => "invalid-input",
        "launch_mode" => "copy-paste",
        "reasons" => ["invalid-input"],
        "launch_safety" => {
          "task_creation_idempotency" => "unavailable",
          "reconciliation_by_outer_run_id" => "unavailable"
        },
        "launch_authority" => "not-granted"
      },
      JSON.parse(stdout)
    )
  end

  def test_launch_safety_is_always_present_and_fails_closed
    input = JSON.parse(File.read(CASES)).first.fetch("input")
    assert_equal unavailable_launch_safety, invoke(input).fetch("launch_safety")

    available = Marshal.load(Marshal.dump(input))
    available["host_capabilities"]["task_creation_idempotency"] = true
    available["host_capabilities"]["reconciliation_by_outer_run_id"] = true
    assert_equal({ "task_creation_idempotency" => "available", "reconciliation_by_outer_run_id" => "available" },
                 invoke(available).fetch("launch_safety"))

    unavailable = Marshal.load(Marshal.dump(input))
    unavailable["host_capabilities"]["task_creation_idempotency"] = false
    unavailable["host_capabilities"]["reconciliation_by_outer_run_id"] = "UNKNOWN"
    assert_equal unavailable_launch_safety, invoke(unavailable).fetch("launch_safety")
  end

  private

  def invoke(input)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER, stdin_data: JSON.generate(input))

    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def unavailable_launch_safety
    { "task_creation_idempotency" => "unavailable", "reconciliation_by_outer_run_id" => "unavailable" }
  end
end
