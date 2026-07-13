agent_stack_timestamp() {
  date -u '+%Y%m%dT%H%M%SZ'
}

agent_stack_physical_dir() {
  local directory="$1"
  mkdir -p "$directory"
  (cd "$directory" && pwd -P)
}

agent_stack_absolute_path() {
  local input_path="$1"
  local segment joined
  local parts=()
  local normalized=()
  [[ "$input_path" = /* ]] || input_path="$PWD/$input_path"
  IFS='/' read -r -a parts <<< "$input_path"
  for segment in "${parts[@]}"; do
    case "$segment" in
      ""|.) ;;
      ..) [[ "${#normalized[@]}" -eq 0 ]] || unset 'normalized[${#normalized[@]}-1]' ;;
      *) normalized+=("$segment") ;;
    esac
  done
  if [[ "${#normalized[@]}" -eq 0 ]]; then
    printf '/\n'
  else
    joined="$(IFS=/; printf '%s' "${normalized[*]}")"
    printf '/%s\n' "$joined"
  fi
}

agent_stack_effective_workflow_target() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local claude_home="${CLAUDE_HOME:-$HOME/.claude}"
  [[ -z "$target" ]] || { printf '%s\n' "$target"; return; }
  case "$host" in
    codex) printf '%s\n' "$codex_home" ;;
    claude) printf '%s\n' "$claude_home" ;;
    auto)
      if [[ ( -n "${CODEX_HOME:-}" || -d "$codex_home" ) && ( -n "${CLAUDE_HOME:-}" || -d "$claude_home" ) ]]; then
        return 1
      elif [[ -n "${CLAUDE_HOME:-}" || -d "$claude_home" ]]; then
        printf '%s\n' "$claude_home"
      else
        printf '%s\n' "$codex_home"
      fi
      ;;
  esac
}

agent_stack_colocated_doctor_module() {
  local workflow_target
  workflow_target="$(agent_stack_effective_workflow_target)" || return 1
  workflow_target="$(agent_stack_absolute_path "$workflow_target")"
  [[ ! -d "$workflow_target" ]] || workflow_target="$(cd "$workflow_target" && pwd -P)"
  [[ "$agent_coord_install_dir" = "$workflow_target/bin" ]]
}

agent_stack_reject_compat_inside_source() {
  local root="$1"
  local repo_name checkout_path
  for repo_name in "${repo_names[@]}"; do
    checkout_path="$source_root/$repo_name"
    case "$root" in "$checkout_path"|"$checkout_path"/*) echo "Refusing compatibility root inside source checkout: $root" >&2; exit 1 ;; esac
  done
}

agent_stack_reject_source_inside_compat() {
  local root="$1"
  local repo_name alias_path
  for repo_name in "${repo_names[@]}"; do
    alias_path="$compat_root/$repo_name"
    case "$root" in "$alias_path"|"$alias_path"/*) echo "Refusing source root inside compatibility alias path: $root" >&2; exit 1 ;; esac
  done
}

agent_stack_prepare_paths() {
  source_root="$(agent_stack_absolute_path "$source_root")"
  compat_root="$(agent_stack_absolute_path "$compat_root")"
  if [[ "$source_root" = "$compat_root" ]]; then
    echo "Refusing compatibility root inside source checkout: $compat_root" >&2
    exit 1
  fi
  agent_stack_reject_compat_inside_source "$compat_root"
  agent_stack_reject_source_inside_compat "$source_root"
  source_root="$(agent_stack_physical_dir "$source_root")"
  agent_stack_reject_compat_inside_source "$compat_root"
  agent_stack_reject_source_inside_compat "$source_root"
  compat_root="$(agent_stack_physical_dir "$compat_root")"
  agent_stack_reject_compat_inside_source "$compat_root"
  agent_stack_reject_source_inside_compat "$source_root"
  runtime_root="$(agent_stack_physical_dir "$runtime_root")"
  if [[ "$install_tools" = true ]]; then agent_coord_install_dir="$(agent_stack_physical_dir "$agent_coord_install_dir")"; fi
  if [[ "$install_tools" = true && -n "$target" ]]; then target="$(agent_stack_physical_dir "$target")"; fi
}
