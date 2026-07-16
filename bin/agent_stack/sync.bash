agent_stack_sync() {
  local repo_name
  agent_stack_parse_options "$@"
  agent_stack_prepare_paths

  echo "agent-stack sync"
  echo "source_root=$source_root"
  echo "compat_root=$compat_root"
  echo "runtime_root=$runtime_root"

  agent_stack_prepare_runtime
  for repo_name in "${repo_names[@]}"; do agent_stack_sync_repo "$repo_name"; done
  for repo_name in "${repo_names[@]}"; do agent_stack_link_compat "$repo_name"; done

  if [[ "$install_tools" = true ]]; then
    agent_stack_install_commands
    agent_stack_install_coordination
    agent_stack_install_workflows
  else
    echo "tool installs skipped (--no-install)"
  fi
  echo "agent-stack sync complete"
}
