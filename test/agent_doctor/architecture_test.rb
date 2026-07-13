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
    # These caps cover the newly split stack-sync modules, not the pre-existing
    # installer and installer-test compatibility surfaces.
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

  def test_doctor_documentation_bounds_process_group_cleanup_claim
    installation = File.read(File.join(ROOT, "docs/installation-and-upgrades.md"))
    plan = File.read(File.join(ROOT, "docs/plans/2026-07-12-001-feat-master-stack-doctor-plan.md"))

    assert_includes installation, "Component doctors are trusted local executables."
    assert_includes installation, "does not guarantee termination of descendants that deliberately escape"
    assert_includes plan, "the delegate's process group"
    refute_includes plan, "timeout cleanup terminates the entire process group"
  end

  def test_focused_architecture_claim_excludes_pre_existing_installer_surfaces
    plan = File.read(File.join(ROOT, "docs/plans/2026-07-12-001-feat-master-stack-doctor-plan.md"))

    assert_includes plan, "The focused-module claim applies only to the new doctor and stack-sync modules"
    assert_includes plan, "`bin/install-agent-workflows`"
    assert_includes plan, "`bin/install-agent-workflows-test.bash`"
    assert_match(/pre-existing compatibility surfaces\s+outside that claim/, plan)
  end

  private

  def line_count(relative_path)
    File.foreach(File.join(ROOT, relative_path)).count
  end
end
