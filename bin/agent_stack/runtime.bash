# Shared globals are populated by options.bash after all modules are sourced.
declare runtime_root
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
}
