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
        "launch_authority" => "not-granted"
      },
      JSON.parse(stdout)
    )
  end
end
