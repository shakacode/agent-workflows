agent_stack_prepare_runtime() {
  local directory runtime_directory
  for directory in cache logs state; do
    runtime_directory="$runtime_root/$directory"
    if [[ -L "$runtime_directory" ]]; then
      echo "Refusing to use runtime directory symlink: $runtime_directory" >&2
      exit 1
    elif [[ -e "$runtime_directory" && ! -d "$runtime_directory" ]]; then
      echo "Refusing to use non-directory runtime path: $runtime_directory" >&2
      exit 1
    fi
  done
  (umask 077 && mkdir -p "$runtime_root/cache" "$runtime_root/logs" "$runtime_root/state")
  chmod 700 "$runtime_root" "$runtime_root/cache" "$runtime_root/logs" "$runtime_root/state"
  if [[ -L "$runtime_root/env" ]]; then
    echo "Refusing to use runtime env symlink: $runtime_root/env" >&2
    exit 1
  elif [[ ! -e "$runtime_root/env" ]]; then
    install -m 0600 /dev/null "$runtime_root/env"
  elif [[ ! -f "$runtime_root/env" ]]; then
    echo "Refusing to use non-file runtime env: $runtime_root/env" >&2
    exit 1
  else
    chmod 600 "$runtime_root/env"
  fi
}
