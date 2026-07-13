# frozen_string_literal: true

require "minitest/autorun"

class AgentDoctorArchitectureTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_public_entrypoints_and_shell_integration_stay_thin
    assert_operator line_count("bin/agent-stack"), :<=, 50
    assert_operator line_count("bin/agent-stack-doctor"), :<=, 30
    assert_operator line_count("bin/agent-workflows-doctor"), :<=, 30
    assert_operator line_count("bin/agent-stack-test.bash"), :<=, 60
    assert_operator line_count("bin/agent-stack-doctor-test.bash"), :<=, 200
  end

  def test_doctor_modules_are_focused
    modules = Dir.glob(File.join(ROOT, "bin", "agent_doctor", "*.rb"))
    refute_empty modules
    modules.each do |path|
      assert_operator File.foreach(path).count, :<=, 180, File.basename(path)
    end
  end

  def test_stack_sync_modules_and_suites_are_focused
    files = Dir.glob(File.join(ROOT, "bin", "agent_stack", "*.bash")) +
            Dir.glob(File.join(ROOT, "test", "agent_stack", "*.bash"))
    refute_empty files
    files.each do |path|
      assert_operator File.foreach(path).count, :<=, 180, File.basename(path)
    end
  end

  def test_component_doctor_documentation_includes_required_paths
    documentation = File.read(File.join(ROOT, "docs/installation-and-upgrades.md"))

    refute_includes documentation, "`agent-workflows-doctor --stack-json`"
    assert_includes documentation, '"$HOME/.codex/bin/agent-workflows-doctor" --stack-json'
    assert_includes documentation, '--host codex --target "$HOME/.codex"'
    assert_includes documentation, '--source "$HOME/src/agent-workflows"'
  end

  private

  def line_count(relative_path)
    File.foreach(File.join(ROOT, relative_path)).count
  end
end
