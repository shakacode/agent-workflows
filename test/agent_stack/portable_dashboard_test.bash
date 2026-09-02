test_portable_dashboard_sync_installs_component_command() {
  local temporary install_dir command_source
  temporary="$(make_tmp_dir)"
  install_dir="$temporary/local-bin"
  with_origins "$temporary"

  run_sync "$temporary" --target "$temporary/codex-home" --agent-coord-install-dir "$install_dir"

  command_source="$(cd "$temporary/src/agent-coordination-dashboard" && pwd -P)/bin/agent-coordination-dashboard.js"
  [[ -L "$install_dir/agent-coordination-dashboard" ]] || fail "dashboard command is not a source-owned link"
  [[ "$(readlink "$install_dir/agent-coordination-dashboard")" = "$command_source" ]] ||
    fail "dashboard command does not expose the selected checkout"
  assert_contains "$("$install_dir/agent-coordination-dashboard" --help)" "fixture lifecycle command"

  run_sync "$temporary" --target "$temporary/codex-home" --agent-coord-install-dir "$install_dir" --no-fetch >/dev/null
  [[ "$(readlink "$install_dir/agent-coordination-dashboard")" = "$command_source" ]] ||
    fail "repeat sync changed the dashboard command target"
}

test_portable_dashboard_no_install_keeps_lifecycle_command_out_of_generic_setup() {
  local temporary
  temporary="$(make_tmp_dir)"
  with_origins "$temporary"

  HOME="$temporary/home" run_sync "$temporary" --no-install --no-fetch >/dev/null

  [[ ! -e "$temporary/home/.local/bin/agent-coordination-dashboard" ]] ||
    fail "--no-install exposed the dashboard lifecycle command"
  [[ ! -e "$temporary/runtime/env" ]] || fail "stack setup created a second environment-file authority"
}

test_portable_dashboard_prerequisites_fail_before_install_mutation() {
  local temporary install_dir output status
  temporary="$(make_tmp_dir)"
  install_dir="$temporary/local-bin"
  with_origins "$temporary"

  set +e
  output="$(NODE_BIN=definitely-missing-node run_sync "$temporary" \
    --target "$temporary/codex-home" --agent-coord-install-dir "$install_dir" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "dashboard install succeeded without Node.js"
  assert_contains "$output" "Node.js is required"
  [[ ! -e "$install_dir/agent-stack" && ! -e "$install_dir/agent-coordination-dashboard" ]] ||
    fail "runtime preflight failure partially installed commands"
  [[ ! -e "$temporary/src/agent-coordination-dashboard/node_modules" ]] ||
    fail "runtime preflight failure installed dashboard dependencies"
}

test_portable_dashboard_refuses_unmanaged_command_before_dependency_install() {
  local temporary install_dir output status
  temporary="$(make_tmp_dir)"
  install_dir="$temporary/local-bin"
  with_origins "$temporary"
  mkdir -p "$install_dir"
  printf 'user-owned command\n' > "$install_dir/agent-coordination-dashboard"

  set +e
  output="$(run_sync "$temporary" --target "$temporary/codex-home" \
    --agent-coord-install-dir "$install_dir" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "dashboard install replaced an unmanaged command"
  assert_contains "$output" "Refusing unmanaged dashboard command destination"
  grep -qxF 'user-owned command' "$install_dir/agent-coordination-dashboard" || fail "unmanaged command changed"
  [[ ! -e "$temporary/src/agent-coordination-dashboard/node_modules" ]] ||
    fail "unsafe command destination was detected after dependency install"
}

test_portable_dashboard_documentation_covers_public_lifecycle() {
  local documentation
  documentation="$(cat "$ROOT/docs/installation-and-upgrades.md")"

  assert_contains "$documentation" "The generic \`bin/install-agent-workflows\` command does not install"
  assert_contains "$documentation" ".config/agent-coordination-dashboard/env"
  assert_contains "$documentation" "AGENT_COORD_ENV_FILE=\"\$dashboard_env_file\" agent-coord doctor --deep"
  assert_contains "$documentation" "-u AGENT_COORD_API_TOKEN"
  assert_contains "$documentation" "agent-coordination-dashboard start --config-env-file \"\$dashboard_env_file\""
  assert_contains "$documentation" "agent-coordination-dashboard status"
  assert_contains "$documentation" "agent-coordination-dashboard logs"
  assert_contains "$documentation" "agent-coordination-dashboard restart --config-env-file \"\$dashboard_env_file\""
  assert_contains "$documentation" "agent-coordination-dashboard stop"
  assert_contains "$documentation" "rm \"\$HOME/.local/bin/agent-coordination-dashboard\""
  [[ "$documentation" != *'agent-dashboard'* ]] || fail "documentation still names the private dashboard launcher"
  [[ "$documentation" != *'tmux-based'* ]] || fail "documentation still requires tmux credential handoff"
}
