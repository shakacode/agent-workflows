# frozen_string_literal: true

require "minitest/autorun"

# Architecture assertions here stand on their own against current code and
# durable, continuously-maintained documentation (docs/installation-and-upgrades.md).
# They deliberately do not read docs/plans/**: those are point-in-time
# implementation-plan records, not a live source of truth. See #194.
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
    modules = doctor_module_paths
    refute_empty modules
    modules.each do |path|
      assert_operator File.foreach(path).count, :<=, 180, File.basename(path)
    end
  end

  def test_stack_sync_modules_and_suites_are_focused
    # These caps cover the newly split stack-sync modules, not the pre-existing
    # installer and installer-test compatibility surfaces.
    files = stack_sync_module_paths
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

  # The behavioral half of this claim (the delegate's process group is
  # terminated on timeout, and a descendant that escapes it via setsid is not
  # guaranteed to be killed) is exercised directly, against real processes, by
  # test_timeout_terminates_descendant_process_group and
  # test_timeout_stays_bounded_when_descendant_escapes_with_setsid in
  # test/agent_doctor/process_runner_test.rb. This test only bounds what the
  # current user-facing documentation claims.
  def test_doctor_documentation_bounds_process_group_cleanup_claim
    installation = File.read(File.join(ROOT, "docs/installation-and-upgrades.md"))

    assert_includes installation, "Component doctors are trusted local executables."
    assert_includes installation, "does not guarantee termination of descendants that deliberately escape"
  end

  def test_focused_module_caps_exclude_pre_existing_installer_surfaces
    installer = File.join(ROOT, "bin/install-agent-workflows")
    installer_test = File.join(ROOT, "bin/install-agent-workflows-test.bash")

    assert_path_exists installer
    assert_path_exists installer_test

    # The exemption is load-bearing: both pre-existing surfaces exceed the
    # 180-line focused-module cap and would fail it if the cap applied to them.
    assert_operator line_count("bin/install-agent-workflows"), :>, 180
    assert_operator line_count("bin/install-agent-workflows-test.bash"), :>, 180

    # Reuses the exact path sets the cap tests glob, so widening either glob
    # to reach these pre-existing files makes this assertion fail.
    refute_includes doctor_module_paths, installer
    refute_includes stack_sync_module_paths, installer_test
  end

  private

  def doctor_module_paths
    Dir.glob(File.join(ROOT, "bin", "agent_doctor", "*.rb"))
  end

  def stack_sync_module_paths
    Dir.glob(File.join(ROOT, "bin", "agent_stack", "*.bash")) +
      Dir.glob(File.join(ROOT, "test", "agent_stack", "*.bash"))
  end

  def line_count(relative_path)
    File.foreach(File.join(ROOT, relative_path)).count
  end
end
