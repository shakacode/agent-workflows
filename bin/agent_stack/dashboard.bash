# Shared globals are populated by options.bash after all modules are sourced.
declare source_root agent_coord_install_dir

agent_stack_version_at_least() {
  local actual="$1" required="$2" actual_major actual_minor actual_patch required_major required_minor required_patch
  [[ "$actual" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  actual_major="${BASH_REMATCH[1]}"; actual_minor="${BASH_REMATCH[2]}"; actual_patch="${BASH_REMATCH[3]}"
  [[ "$required" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  required_major="${BASH_REMATCH[1]}"; required_minor="${BASH_REMATCH[2]}"; required_patch="${BASH_REMATCH[3]}"
  (( actual_major > required_major )) ||
    (( actual_major == required_major && actual_minor > required_minor )) ||
    (( actual_major == required_major && actual_minor == required_minor && actual_patch >= required_patch ))
}

agent_stack_dashboard_contract() {
  local package_json="$1"
  "${RUBY_BIN:-ruby}" -rjson -e '
    package = JSON.parse(File.read(ARGV.fetch(0)))
    floor = package.dig("engines", "node").to_s
    command = package.dig("bin", "agent-coordination-dashboard").to_s
    abort "dashboard package must declare engines.node as >=MAJOR.MINOR.PATCH" unless floor.match?(/\A>=[0-9]+\.[0-9]+\.[0-9]+\z/)
    abort "dashboard package must expose bin/agent-coordination-dashboard.js" unless command == "bin/agent-coordination-dashboard.js"
    puts floor.delete_prefix(">=")
  ' "$package_json"
}

agent_stack_preflight_dashboard_install() {
  local repo="$source_root/agent-coordination-dashboard"
  local command_source="$repo/bin/agent-coordination-dashboard.js"
  local destination="$agent_coord_install_dir/agent-coordination-dashboard"
  local node_bin="${NODE_BIN:-node}" npm_bin="${NPM_BIN:-npm}" node_floor node_version npm_version
  [[ -f "$repo/package.json" && -f "$repo/package-lock.json" ]] || {
    echo "Cannot install agent-coordination-dashboard: package.json and package-lock.json are required" >&2
    return 1
  }
  [[ -x "$command_source" ]] || {
    echo "Cannot install agent-coordination-dashboard: missing executable bin/agent-coordination-dashboard.js" >&2
    return 1
  }
  if [[ -L "$destination" ]]; then
    [[ "$(readlink "$destination")" = "$command_source" ]] || {
      echo "Refusing unmanaged dashboard command symlink: $destination" >&2
      return 1
    }
  elif [[ -e "$destination" ]]; then
    echo "Refusing unmanaged dashboard command destination: $destination" >&2
    return 1
  fi
  command -v "$node_bin" >/dev/null 2>&1 || {
    echo "Cannot install agent-coordination-dashboard: Node.js is required (install Node.js >=22.12.0, then rerun agent-stack sync)" >&2
    return 1
  }
  command -v "$npm_bin" >/dev/null 2>&1 || {
    echo "Cannot install agent-coordination-dashboard: npm is required (install npm >=10, then rerun agent-stack sync)" >&2
    return 1
  }
  node_floor="$(agent_stack_dashboard_contract "$repo/package.json")" || return 1
  node_version="$("$node_bin" --version)" || return 1
  agent_stack_version_at_least "$node_version" "$node_floor" || {
    echo "Cannot install agent-coordination-dashboard: Node.js $node_floor or newer is required (found $node_version)" >&2
    return 1
  }
  npm_version="$("$npm_bin" --version)" || return 1
  agent_stack_version_at_least "$npm_version" "10.0.0" || {
    echo "Cannot install agent-coordination-dashboard: npm 10 or newer is required (found $npm_version)" >&2
    return 1
  }
}

agent_stack_install_dashboard() {
  local repo="$source_root/agent-coordination-dashboard"
  local command_source="$repo/bin/agent-coordination-dashboard.js"
  local destination="$agent_coord_install_dir/agent-coordination-dashboard"
  local npm_bin="${NPM_BIN:-npm}" locked_esbuild installed_esbuild temporary
  (
    cd "$repo" || exit
    env -u NODE_ENV -u NPM_CONFIG_PRODUCTION -u npm_config_production \
      -u NPM_CONFIG_OMIT -u npm_config_omit -u NPM_CONFIG_IGNORE_SCRIPTS -u npm_config_ignore_scripts \
      "$npm_bin" ci --ignore-scripts --include=dev
  )
  locked_esbuild="$("${RUBY_BIN:-ruby}" -rjson -e '
    lock = JSON.parse(File.read(ARGV.fetch(0)))
    puts lock.dig("packages", "node_modules/esbuild", "version").to_s
  ' "$repo/package-lock.json")" || return 1
  if [[ -n "$locked_esbuild" ]]; then
    installed_esbuild="$("${RUBY_BIN:-ruby}" -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' \
      "$repo/node_modules/esbuild/package.json")" || return 1
    [[ "$installed_esbuild" = "$locked_esbuild" ]] || {
      echo "Cannot install agent-coordination-dashboard: locked esbuild $locked_esbuild does not match installed $installed_esbuild" >&2
      return 1
    }
    (cd "$repo" || exit; "$npm_bin" rebuild esbuild --ignore-scripts=false)
  fi
  (cd "$repo" || exit; "$npm_bin" run build --ignore-scripts)

  if [[ -L "$destination" ]]; then
    [[ "$(readlink "$destination")" = "$command_source" ]] || {
      echo "Refusing unmanaged dashboard command symlink: $destination" >&2
      return 1
    }
    return
  elif [[ -e "$destination" ]]; then
    echo "Refusing unmanaged dashboard command destination: $destination" >&2
    return 1
  fi
  temporary="$(mktemp "$agent_coord_install_dir/.agent-coordination-dashboard.XXXXXX")"
  rm -f "$temporary"
  ln -s "$command_source" "$temporary"
  mv "$temporary" "$destination"
}
