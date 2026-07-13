test_sync_installs_commands_modules_and_links() {
  local temporary
  local install_dir
  local target
  temporary="$(make_tmp_dir)"
  install_dir="$temporary/local-bin"
  target="$temporary/codex-home"
  with_origins "$temporary"
  mkdir -p "$install_dir"
  printf 'user-owned legacy command\n' > "$install_dir/agent_coord"

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$install_dir"

  assert_executable "$install_dir/agent-stack"
  assert_executable "$install_dir/agent-stack-doctor"
  assert_executable "$install_dir/agent-coord"
  assert_file "$install_dir/agent_stack/fixture.bash"
  assert_file "$install_dir/agent_doctor/fixture.rb"
  assert_file "$target/bin/agent-workflows-installed"
  grep -q "user-owned legacy command" "$install_dir/agent_coord" || fail "pre-existing agent_coord was replaced"
  for name in agent-workflows agent-coordination agent-coordination-dashboard; do
    [[ -L "$temporary/compat/$name" ]] || fail "missing compatibility link for $name"
  done
  [[ -d "$temporary/runtime/state" && -f "$temporary/runtime/env" ]] || fail "missing runtime state"
}

test_colocated_sync_transitions_doctor_ownership_between_modes() {
  local temporary target
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" --mode symlink

  assert_executable "$target/bin/agent-stack"
  assert_executable "$target/bin/agent-stack-doctor"
  [[ -L "$target/bin/agent_doctor" ]] || fail "workflow installer did not own co-located agent_doctor"
  [[ "$(cd "$target/bin/agent_doctor" && pwd -P)" = "$(cd "$temporary/src/agent-workflows/bin/agent_doctor" && pwd -P)" ]] ||
    fail "co-located agent_doctor points at the wrong source"
  [[ ! -e "$target/bin/agent_doctor/.agent-stack-managed" ]] || fail "workflow-owned agent_doctor has a stack marker"
  grep -qxF "agent-stack-module-v1:agent_stack" "$target/bin/agent_stack/.agent-stack-managed" ||
    fail "co-located agent_stack lost stack module ownership"
  "$target/bin/agent-stack" --help >/dev/null
  "$target/bin/agent-stack-doctor" --help >/dev/null
  "$target/bin/agent-stack" doctor --help >/dev/null

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" --mode copy --no-fetch
  [[ -d "$target/bin/agent_doctor" && ! -L "$target/bin/agent_doctor" ]] ||
    fail "copy transition did not install a real agent_doctor directory"
  grep -qxF "agent-stack-module-v1:agent_doctor" "$target/bin/agent_doctor/.agent-stack-managed" ||
    fail "copy transition did not restore stack module ownership"
  "$target/bin/agent-stack" doctor --help >/dev/null
}

test_colocated_sync_uses_implicit_codex_home_target() {
  local temporary target
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"

  CODEX_HOME="$target" run_sync "$temporary" --agent-coord-install-dir "$target/bin" \
    --mode symlink --no-fetch

  [[ -L "$target/bin/agent_doctor" ]] || fail "implicit CODEX_HOME did not establish workflow doctor ownership"
  [[ "$(cd "$target/bin/agent_doctor" && pwd -P)" = "$(cd "$temporary/src/agent-workflows/bin/agent_doctor" && pwd -P)" ]] ||
    fail "implicit CODEX_HOME doctor link points at the wrong source"
  "$target/bin/agent-stack" doctor --help >/dev/null
}

test_colocated_copy_sync_adopts_exact_prior_workflow_doctor() {
  local temporary target
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"

  "$ROOT/bin/install-agent-workflows" --target "$target" >/dev/null
  [[ -d "$target/bin/agent_doctor" && ! -L "$target/bin/agent_doctor" ]] ||
    fail "prior workflow copy install did not create a real agent_doctor directory"
  [[ ! -e "$target/bin/agent_doctor/.agent-stack-managed" ]] ||
    fail "prior workflow copy install unexpectedly wrote a stack marker"

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" --mode copy --no-fetch

  grep -qxF "agent-stack-module-v1:agent_doctor" "$target/bin/agent_doctor/.agent-stack-managed" ||
    fail "stack copy sync did not adopt the equivalent workflow doctor directory"
  "$target/bin/agent-stack" doctor --help >/dev/null
}

test_colocated_copy_sync_adopts_prior_workflow_doctor_installed_under_restrictive_umask() {
  local temporary target source_mode
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"
  source_mode="$("$RUBY_BIN" -e 'printf "%o", File.stat(ARGV.fetch(0)).mode & 0o7777' "$ROOT/bin/agent_doctor")"

  (umask 077; "$ROOT/bin/install-agent-workflows" --target "$target" >/dev/null)

  assert_mode "$target/bin/agent_doctor" "$source_mode"
  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" --mode copy --no-fetch
  grep -qxF "agent-stack-module-v1:agent_doctor" "$target/bin/agent_doctor/.agent-stack-managed" ||
    fail "stack copy sync did not adopt the restrictive-umask workflow doctor directory"
}

test_colocated_copy_sync_upgrades_a_marked_prior_workflow_doctor() {
  local temporary target
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"

  "$ROOT/bin/install-agent-workflows" --target "$target" >/dev/null
  grep -Eq '^agent-workflows-doctor-v1:[0-9a-f]{64}$' "$target/bin/agent_doctor/.agent-workflows-managed" || \
    fail "prior workflow doctor copy is missing its ownership marker"
  printf 'older managed implementation\n' > "$target/bin/agent_doctor/configuration.rb"
  ruby "$ROOT/bin/agent_doctor/install_ownership.rb" marker "$target/bin/agent_doctor" \
    > "$target/bin/agent_doctor/.agent-workflows-managed"

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" --mode copy --no-fetch

  cmp -s "$temporary/src/agent-workflows/bin/agent_doctor/configuration.rb" \
    "$target/bin/agent_doctor/configuration.rb" || fail "stack sync did not upgrade the marked workflow doctor"
  grep -qxF "agent-stack-module-v1:agent_doctor" "$target/bin/agent_doctor/.agent-stack-managed" || \
    fail "stack sync did not take ownership of the upgraded workflow doctor"
}

test_sync_replays_workflow_delivery_mode() {
  local temporary target module_name mode
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_origins "$temporary"

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$temporary/local-bin" \
    --delivery-mode plugin-companion
  for module_name in agent_stack agent_doctor; do
    grep -qxF "agent-stack-module-v1:$module_name" \
      "$temporary/local-bin/$module_name/.agent-stack-managed" || fail "missing $module_name managed marker"
  done
  printf 'stale managed content\n' > "$temporary/local-bin/agent_stack/stale"
  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$temporary/local-bin" --no-fetch

  mode="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("delivery_mode")' "$target/.agent-workflows-install.json")"
  [[ "$mode" = plugin-companion ]] || fail "delivery mode was not replayed: $mode"
  [[ ! -e "$temporary/local-bin/agent_stack/stale" ]] || fail "managed module upgrade did not remove stale content"
}

test_running_installed_command_updates_through_temporary_file() {
  local temporary
  local install_dir
  local fake_bin
  temporary="$(make_tmp_dir)"
  install_dir="$temporary/local-bin"
  fake_bin="$temporary/fake-bin"
  mkdir -p "$install_dir" "$fake_bin"
  cp "$ROOT/bin/agent-stack" "$install_dir/agent-stack"
  cp -R "$ROOT/bin/agent_stack" "$install_dir/agent_stack"
  printf 'agent-stack-module-v1:agent_stack\n' > "$install_dir/agent_stack/.agent-stack-managed"
  chmod +x "$install_dir/agent-stack"
  cat > "$fake_bin/install" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${@: -1}" = "${AGENT_STACK_TEST_FORBIDDEN_INSTALL_DEST:-}" ]]; then exit 42; fi
exec /usr/bin/install "$@"
BASH
  chmod +x "$fake_bin/install"
  with_origins "$temporary"

  PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  AGENT_STACK_TEST_FORBIDDEN_INSTALL_DEST="$install_dir/agent-stack" \
  AGENT_STACK_AGENT_WORKFLOWS_URL="$temporary/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$temporary/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$temporary/origins/agent-coordination-dashboard.git" \
    "$install_dir/agent-stack" sync --source-root "$temporary/src" --compat-root "$temporary/compat" \
      --runtime-root "$temporary/runtime" --target "$temporary/codex-home" --agent-coord-install-dir "$install_dir"

  grep -q "synced agent-stack fixture" "$install_dir/agent-stack" || fail "running command did not update safely"
}
