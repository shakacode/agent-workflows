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

agent_stack_dashboard_esbuild_contract() {
  local package_lock="$1"
  "${RUBY_BIN:-ruby}" -rjson -e '
    lock = JSON.parse(File.read(ARGV.fetch(0)))
    matches = lock.fetch("packages", {}).filter_map do |path, package|
      parts = path.split("/")
      next unless parts.last(2) == %w[node_modules esbuild]
      unsafe = path.start_with?("/") || parts.any? { |part| part.empty? || part == "." || part == ".." }
      abort "dashboard package-lock.json contains an unsafe esbuild path: #{path}" if unsafe
      version = package.is_a?(Hash) ? package["version"].to_s : ""
      abort "dashboard package-lock.json omits the esbuild version at #{path}" if version.empty?
      [path, version]
    end
    abort "dashboard package-lock.json contains multiple esbuild installations" if matches.length > 1
    puts matches.first.join("\t") unless matches.empty?
  ' "$package_lock"
}

agent_stack_dashboard_destination_safe() {
  local command_source="$1" destination="$2"
  if [[ -L "$destination" ]]; then
    [[ "$(readlink "$destination")" = "$command_source" ]] || {
      echo "Refusing unmanaged dashboard command symlink: $destination" >&2
      return 1
    }
  elif [[ -e "$destination" ]]; then
    echo "Refusing unmanaged dashboard command destination: $destination" >&2
    return 1
  fi
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
  agent_stack_dashboard_destination_safe "$command_source" "$destination" || return 1
  command -v "$node_bin" >/dev/null 2>&1 || {
    echo "Cannot install agent-coordination-dashboard: Node.js is required (install Node.js >=22.12.0, then rerun agent-stack sync)" >&2
    return 1
  }
  command -v "$npm_bin" >/dev/null 2>&1 || {
    echo "Cannot install agent-coordination-dashboard: npm is required (install npm >=10, then rerun agent-stack sync)" >&2
    return 1
  }
  node_bin="$(command -v "$node_bin")"
  npm_bin="$(command -v "$npm_bin")"
  node_floor="$(agent_stack_dashboard_contract "$repo/package.json")" || return 1
  node_version="$("$node_bin" --version)" || return 1
  agent_stack_version_at_least "$node_version" "$node_floor" || {
    echo "Cannot install agent-coordination-dashboard: Node.js $node_floor or newer is required (found $node_version)" >&2
    return 1
  }
  npm_version="$(env PATH="$(dirname "$node_bin"):$PATH" "$npm_bin" --version)" || return 1
  agent_stack_version_at_least "$npm_version" "10.0.0" || {
    echo "Cannot install agent-coordination-dashboard: npm 10 or newer is required (found $npm_version)" >&2
    return 1
  }
}

agent_stack_install_dashboard() {
  local repo="$source_root/agent-coordination-dashboard"
  local command_source="$repo/bin/agent-coordination-dashboard.js"
  local destination="$agent_coord_install_dir/agent-coordination-dashboard"
  local node_bin="${NODE_BIN:-node}" npm_bin="${NPM_BIN:-npm}"
  local esbuild_record esbuild_path locked_esbuild installed_esbuild temporary
  node_bin="$(command -v "$node_bin")" || return 1
  npm_bin="$(command -v "$npm_bin")" || return 1
  (
    cd "$repo" || exit
    env -u NODE_ENV -u NPM_CONFIG_PRODUCTION -u npm_config_production \
      -u NPM_CONFIG_OMIT -u npm_config_omit -u NPM_CONFIG_IGNORE_SCRIPTS -u npm_config_ignore_scripts \
      PATH="$(dirname "$node_bin"):$PATH" \
      "$npm_bin" ci --ignore-scripts --include=dev
  )
  esbuild_record="$(agent_stack_dashboard_esbuild_contract "$repo/package-lock.json")" || return 1
  if [[ -n "$esbuild_record" ]]; then
    IFS=$'\t' read -r esbuild_path locked_esbuild <<< "$esbuild_record"
    installed_esbuild="$("${RUBY_BIN:-ruby}" -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' \
      "$repo/$esbuild_path/package.json")" || return 1
    [[ "$installed_esbuild" = "$locked_esbuild" ]] || {
      echo "Cannot install agent-coordination-dashboard: locked esbuild $locked_esbuild does not match installed $installed_esbuild" >&2
      return 1
    }
    (cd "$repo" || exit; env PATH="$(dirname "$node_bin"):$PATH" "$npm_bin" rebuild esbuild --ignore-scripts=false)
  fi
  (cd "$repo" || exit; env PATH="$(dirname "$node_bin"):$PATH" "$npm_bin" run build --ignore-scripts)

  agent_stack_dashboard_destination_safe "$command_source" "$destination" || return 1
  if [[ -L "$destination" ]]; then
    return
  fi
  temporary="$(mktemp "$agent_coord_install_dir/.agent-coordination-dashboard.XXXXXX")"
  rm -f "$temporary"
  ln -s "$command_source" "$temporary"
  mv "$temporary" "$destination"
}
