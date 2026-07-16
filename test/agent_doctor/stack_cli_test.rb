# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
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

  def test_empty_explicit_path_options_return_usage
    %w[--source-root --compat-root --runtime-root --target --agent-coord-install-dir].each do |option|
      [["#{option}="], [option, ""]].each do |arguments|
        output = StringIO.new
        error = StringIO.new

        cli = AgentDoctor::StackCLI.new(environment: {}, home: "/tmp/doctor-home")
        exit_code = cli.run(arguments, output: output, error: error)

        assert_equal 64, exit_code, arguments.inspect
        assert_empty output.string, arguments.inspect
        assert_includes error.string, "#{option} must not be empty", arguments.inspect
      end
    end
  end
end
