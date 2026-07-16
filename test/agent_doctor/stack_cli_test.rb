# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../bin/agent_doctor/stack_cli"

class AgentDoctorStackCLITest < Minitest::Test
  def test_empty_stack_root_environment_uses_home_defaults
    home = "/tmp/agent-doctor-home"
    environment = {
      "AGENT_STACK_SOURCE_ROOT" => "",
      "AGENT_STACK_COMPAT_ROOT" => "",
      "AGENT_STACK_RUNTIME_ROOT" => ""
    }

    defaults = AgentDoctor::StackCLI.new(environment: environment, home: home).send(:defaults)

    assert_equal File.join(home, "src"), defaults[:source_root]
    assert_equal File.join(home, "codex", "agent-repos"), defaults[:compat_root]
    assert_equal File.join(home, ".agent-workflows"), defaults[:runtime_root]
  end
end
