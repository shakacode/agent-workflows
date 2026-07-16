agent_stack_install_module_directory() {
  local module_name="$1"
  local source_directory="$source_root/agent-workflows/bin/$module_name"
  local destination="$agent_coord_install_dir/$module_name"
  local marker temporary_marker workflow_marker workflow_marker_value temporary_workflow_marker
  local preserve_workflow_ownership=false
  if [[ "$module_name" = agent_doctor ]] && agent_stack_colocated_doctor_module; then
    agent_stack_colocated_doctor_destination_safe || return 1
    if agent_stack_workflow_doctor_managed_copy; then preserve_workflow_ownership=true; fi
  else
    agent_stack_module_destination_safe "$module_name" || return 1
  fi
  if [[ "$source_directory" = "$destination" ]]; then return; fi
  mkdir -p "$destination"
  marker="$destination/.agent-stack-managed"
  workflow_marker="$destination/.agent-workflows-managed"
  rsync -a --delete --exclude='/.agent-stack-managed' --exclude='/.agent-workflows-managed' \
    "$source_directory/" "$destination/"
  if [[ "$preserve_workflow_ownership" = true ]]; then
    if ! workflow_marker_value="$("${RUBY_BIN:-ruby}" "$source_directory/install_ownership.rb" marker "$destination")"; then
      return 1
    fi
    temporary_workflow_marker="$(mktemp "$destination/.agent-workflows-managed.XXXXXX")"
    printf '%s\n' "$workflow_marker_value" > "$temporary_workflow_marker"
    chmod 0644 "$temporary_workflow_marker"
    mv -f "$temporary_workflow_marker" "$workflow_marker"
  elif [[ "$module_name" = agent_doctor ]]; then
    rm -f -- "$workflow_marker"
  fi
  temporary_marker="$(mktemp "$destination/.agent-stack-managed.XXXXXX")"
  printf 'agent-stack-module-v1:%s\n' "$module_name" > "$temporary_marker"
  chmod 0644 "$temporary_marker"
  mv -f "$temporary_marker" "$marker"
}
