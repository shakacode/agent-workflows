agent_stack_link_compat() {
  local name="$1"
  local source_path="$source_root/$name"
  local compat_path="$compat_root/$name"
  local backup_path link_target
  mkdir -p "$compat_root"
  case "$compat_path" in "$source_path"|"$source_path"/*) echo "Refusing compatibility path that overlaps source checkout: $compat_path" >&2; exit 1 ;; esac
  case "$source_path" in "$compat_path"|"$compat_path"/*) echo "Refusing compatibility path that parents source checkout: $compat_path" >&2; exit 1 ;; esac

  if [[ -L "$compat_path" ]]; then
    link_target="$(readlink "$compat_path")"
    [[ "$link_target" != "$source_path" ]] || return 0
    if [[ "$replace_compat" != true ]]; then
      echo "Refusing to replace compatibility path: $compat_path (use --replace-compat)" >&2; exit 1
    fi
    backup_path="$compat_path.pre-agent-stack-$(agent_stack_timestamp)"
    mv "$compat_path" "$backup_path"
    echo "archived compatibility path: $backup_path"
  elif [[ -e "$compat_path" ]]; then
    if [[ "$replace_compat" != true ]]; then
      echo "Refusing to replace compatibility path: $compat_path (use --replace-compat)" >&2; exit 1
    fi
    backup_path="$compat_path.pre-agent-stack-$(agent_stack_timestamp)"
    mv "$compat_path" "$backup_path"
    echo "archived compatibility path: $backup_path"
  fi
  ln -s "$source_path" "$compat_path"
}
