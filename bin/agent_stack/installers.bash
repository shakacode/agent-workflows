agent_stack_command_destination_safe() {
  local destination="$1"
  if [[ -d "$destination" || ( -e "$destination" && ! -f "$destination" && ! -L "$destination" ) ]]; then
    echo "Refusing stack command non-file destination: $destination" >&2
    return 1
  fi
}

agent_stack_install_file() {
  local source_file="$1"
  local destination="$2"
  local temporary
  agent_stack_command_destination_safe "$destination" || return 1
  if [[ "$source_file" = "$destination" && ! -L "$destination" ]]; then
    chmod +x "$destination"
    return
  fi
  temporary="$(mktemp "$(dirname "$destination")/.${destination##*/}.XXXXXX")"
  if install -m 0755 "$source_file" "$temporary"; then
    [[ ! -L "$destination" ]] || rm -f "$destination"
    mv -f "$temporary" "$destination"
  else
    rm -f "$temporary"
    return 1
  fi
}

agent_stack_install_module_directory() {
  local module_name="$1"
  local source_directory="$source_root/agent-workflows/bin/$module_name"
  local destination="$agent_coord_install_dir/$module_name"
  local marker temporary_marker
  if [[ "$module_name" = agent_doctor ]] && agent_stack_colocated_doctor_module; then
    agent_stack_colocated_doctor_destination_safe || return 1
  else
    agent_stack_module_destination_safe "$module_name" || return 1
  fi
  if [[ "$source_directory" = "$destination" ]]; then return; fi
  mkdir -p "$destination"
  marker="$destination/.agent-stack-managed"
  rsync -a --delete --exclude='/.agent-stack-managed' "$source_directory/" "$destination/"
  temporary_marker="$(mktemp "$destination/.agent-stack-managed.XXXXXX")"
  printf 'agent-stack-module-v1:%s\n' "$module_name" > "$temporary_marker"
  chmod 0644 "$temporary_marker"
  mv -f "$temporary_marker" "$marker"
}

agent_stack_module_destination_safe() {
  local module_name="$1"
  local source_directory="$source_root/agent-workflows/bin/$module_name"
  local destination="$agent_coord_install_dir/$module_name"
  local marker="$destination/.agent-stack-managed"
  [[ -d "$source_directory" ]] || { echo "Skipping stack command install: missing $source_directory" >&2; return 1; }
  if [[ "$source_directory" = "$destination" ]]; then return; fi
  if [[ -L "$destination" ]]; then
    echo "Refusing stack module symlink destination: $destination" >&2
    return 1
  fi
  if [[ -e "$destination" && ! -d "$destination" ]]; then
    echo "Refusing stack module non-directory destination: $destination" >&2
    return 1
  fi
  if [[ -d "$destination" && -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    if [[ -L "$marker" || ! -f "$marker" ]] || ! grep -qxF "agent-stack-module-v1:$module_name" "$marker"; then
      echo "Refusing unmanaged stack module directory: $destination" >&2
      return 1
    fi
  fi
}

agent_stack_workflow_doctor_symlink() {
  local source_directory="$source_root/agent-workflows/bin/agent_doctor"
  local destination="$agent_coord_install_dir/agent_doctor"
  local resolved_source resolved_destination
  [[ -L "$destination" ]] || return 1
  resolved_source="$(cd "$source_directory" 2>/dev/null && pwd -P)" || return 1
  resolved_destination="$(cd "$destination" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved_source" = "$resolved_destination" ]]
}

agent_stack_recorded_workflow_doctor_symlink() {
  local destination="$agent_coord_install_dir/agent_doctor" metadata="$(dirname "$agent_coord_install_dir")/.agent-workflows-install.json" link_target
  [[ -L "$destination" && -f "$metadata" && ! -L "$metadata" ]] || return 1
  link_target="$(readlink "$destination")" || return 1
  "${RUBY_BIN:-ruby}" -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    source = metadata["source"]; exit 1 unless metadata["mode"] == "symlink"
    exit 1 unless source.is_a?(String) && !source.empty? && File.expand_path(source) == source
    exit 1 unless ARGV.fetch(1) == File.join(source, "bin", "agent_doctor")
  ' "$metadata" "$link_target" 2>/dev/null
}

agent_stack_workflow_doctor_copy_transition_symlink() {
  [[ "$mode" = copy ]] || return 1
  agent_stack_workflow_doctor_symlink || agent_stack_recorded_workflow_doctor_symlink
}

agent_stack_workflow_doctor_copy() {
  local source_directory="$source_root/agent-workflows/bin/agent_doctor"
  local destination="$agent_coord_install_dir/agent_doctor"
  local ownership_helper="$source_directory/install_ownership.rb"
  [[ -d "$destination" && ! -L "$destination" ]] || return 1
  "${RUBY_BIN:-ruby}" "$ownership_helper" compare "$source_directory" "$destination"
}

agent_stack_workflow_doctor_managed_copy() {
  local ownership_helper="$source_root/agent-workflows/bin/agent_doctor/install_ownership.rb"
  local destination="$agent_coord_install_dir/agent_doctor"
  local marker="$agent_coord_install_dir/agent_doctor/.agent-workflows-managed"
  "${RUBY_BIN:-ruby}" "$ownership_helper" verify "$destination" "$marker"
}

agent_stack_colocated_doctor_destination_safe() {
  local destination="$agent_coord_install_dir/agent_doctor"
  if [[ -L "$destination" ]]; then
    if agent_stack_workflow_doctor_symlink; then return; fi
    if agent_stack_workflow_doctor_copy_transition_symlink; then return; fi
    echo "Refusing unmanaged co-located doctor symlink: $destination" >&2
    return 1
  fi
  if [[ "$mode" = symlink && -e "$destination" ]]; then
    echo "Refusing workflow-owned doctor non-symlink destination: $destination" >&2
    return 1
  fi
  if [[ "$mode" = copy ]] && { agent_stack_workflow_doctor_managed_copy || agent_stack_workflow_doctor_copy; }; then return; fi
  agent_stack_module_destination_safe agent_doctor
}

agent_stack_prepare_colocated_doctor_transition() {
  local source_directory="$source_root/agent-workflows/bin/agent_doctor"
  local destination="$agent_coord_install_dir/agent_doctor"
  agent_stack_colocated_doctor_module || return 0
  [[ "$source_directory" != "$destination" ]] || return 0
  if [[ "$mode" = copy && -L "$destination" ]]; then
    agent_stack_workflow_doctor_copy_transition_symlink || return 1
    rm -f "$destination"
  fi
}

agent_stack_install_commands() {
  local helper source_file workflow_owns_doctor=false
  for helper in agent-stack agent-stack-doctor; do
    source_file="$source_root/agent-workflows/bin/$helper"
    [[ -x "$source_file" ]] || { echo "Cannot install stack command: missing $source_file" >&2; return 1; }
    agent_stack_command_destination_safe "$agent_coord_install_dir/$helper" || return 1
  done
  agent_stack_module_destination_safe agent_stack || return 1
  if agent_stack_colocated_doctor_module; then
    agent_stack_colocated_doctor_destination_safe || return 1
    [[ "$mode" != symlink ]] || workflow_owns_doctor=true
  else
    agent_stack_module_destination_safe agent_doctor || return 1
  fi
  mkdir -p "$agent_coord_install_dir"
  [[ "$mode" != copy ]] || agent_stack_prepare_colocated_doctor_transition
  agent_stack_install_module_directory agent_stack
  [[ "$workflow_owns_doctor" = true ]] || agent_stack_install_module_directory agent_doctor
  for helper in agent-stack agent-stack-doctor; do
    agent_stack_install_file "$source_root/agent-workflows/bin/$helper" "$agent_coord_install_dir/$helper"
  done
}

agent_stack_install_coordination() {
  local repo="$source_root/agent-coordination"
  local legacy_alias="$agent_coord_install_dir/agent_coord"
  local had_legacy_alias=false
  [[ -x "$repo/bin/agent-coord" ]] || { echo "Cannot install agent-coord: missing $repo/bin/agent-coord" >&2; return 1; }
  [[ ! -e "$legacy_alias" && ! -L "$legacy_alias" ]] || had_legacy_alias=true
  "$repo/bin/agent-coord" bootstrap --install-dir "$agent_coord_install_dir"
  if [[ "$had_legacy_alias" = false && ( -e "$legacy_alias" || -L "$legacy_alias" ) ]]; then rm -f "$legacy_alias"; fi
}

agent_stack_install_workflows() {
  local repo="$source_root/agent-workflows"
  local args=(--host "$host" --mode "$mode")
  [[ -z "$delivery_mode" ]] || args+=(--delivery-mode "$delivery_mode")
  [[ -z "$target" ]] || args+=(--target "$target")
  [[ -x "$repo/bin/install-agent-workflows" ]] || { echo "Cannot install workflows: missing $repo/bin/install-agent-workflows" >&2; return 1; }
  "$repo/bin/install-agent-workflows" "${args[@]}"
}
