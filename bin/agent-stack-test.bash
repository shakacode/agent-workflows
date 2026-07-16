#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/test/agent_stack/support.bash"
source "$ROOT/test/agent_stack/install_test.bash"
source "$ROOT/test/agent_stack/doctor_install_test.bash"
source "$ROOT/test/agent_stack/module_install_test.bash"
source "$ROOT/test/agent_stack/command_install_test.bash"
source "$ROOT/test/agent_stack/upgrade_test.bash"
source "$ROOT/test/agent_stack/repository_test.bash"
source "$ROOT/test/agent_stack/path_safety_test.bash"

tests=(
  test_sync_installs_commands_modules_and_links
  test_colocated_sync_transitions_doctor_ownership_between_modes
  test_colocated_copy_sync_recovers_recorded_dangling_doctor_symlink
  test_colocated_copy_sync_recovers_recorded_live_doctor_symlink_after_source_relocation
  test_colocated_sync_uses_implicit_codex_home_target
  test_colocated_copy_sync_adopts_exact_prior_workflow_doctor
  test_colocated_copy_sync_adopts_prior_workflow_doctor_installed_under_restrictive_umask
  test_colocated_copy_sync_upgrades_a_marked_prior_workflow_doctor
  test_sync_replays_workflow_delivery_mode
  test_running_installed_command_updates_through_temporary_file
  test_sync_fails_when_required_install_executable_is_missing
  test_sync_refuses_command_directory_destinations_before_any_install_mutation
  test_sync_replaces_non_directory_command_symlinks_without_touching_referents
  test_sync_refuses_symlink_module_destinations_without_touching_targets
  test_sync_refuses_unmanaged_module_directories_without_deleting_files
  test_colocated_sync_refuses_unmanaged_doctor_symlinks_without_touching_targets
  test_colocated_copy_sync_refuses_unproven_dangling_doctor_symlinks_without_mutation
  test_colocated_symlink_sync_refuses_workflow_doctor_copy_without_mutation
  test_colocated_copy_sync_refuses_non_equivalent_workflow_doctors_without_touching_them
  test_colocated_copy_sync_refuses_root_mode_mismatch_without_touching_it
  test_prior_monolithic_install_bootstraps_modular_command
  test_launcher_uses_only_complete_module_trees
  test_repository_guards_reject_unsafe_checkouts
  test_worktree_checkout_and_force_stash_are_supported
  test_path_overlap_and_compatibility_guards
  test_runtime_paths_are_private_and_not_symlinks
  test_no_install_and_help_contracts
  test_value_options_return_usage_for_missing_or_empty_operands
)

for test_name in "${tests[@]}"; do
  if [[ -z "${AGENT_STACK_TEST_FILTER:-}" || "$test_name" = *"$AGENT_STACK_TEST_FILTER"* ]]; then
    "$test_name"
  fi
done

echo "PASS agent-stack tests"
