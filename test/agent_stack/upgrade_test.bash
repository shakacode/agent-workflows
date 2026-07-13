test_prior_monolithic_install_bootstraps_modular_command() {
  local temporary install_dir source_root work output
  temporary="$(make_tmp_dir)"
  install_dir="$temporary/local-bin"
  source_root="$temporary/src"
  work="$temporary/work/agent-workflows"
  with_origins "$temporary"

  rm -rf "$work/bin/agent_stack" "$work/bin/agent_doctor"
  cp "$ROOT/bin/agent-stack" "$work/bin/agent-stack"
  cp -R "$ROOT/bin/agent_stack" "$work/bin/agent_stack"
  cp -R "$ROOT/bin/agent_doctor" "$work/bin/agent_doctor"
  chmod +x "$work/bin/agent-stack"
  git -C "$work" add bin/agent-stack bin/agent_stack bin/agent_doctor
  git -C "$work" commit --quiet -m "publish modular stack command"
  git -C "$work" remote add origin "$temporary/origins/agent-workflows.git"
  git -C "$work" push --quiet origin main

  mkdir -p "$install_dir"
  cat > "$install_dir/agent-stack" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" = sync ]] || exit 64
shift
source_root=""
install_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root) source_root="$2"; shift 2 ;;
    --agent-coord-install-dir) install_dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
for name in agent-workflows agent-coordination agent-coordination-dashboard; do
  case "$name" in
    agent-workflows) url="$AGENT_STACK_AGENT_WORKFLOWS_URL" ;;
    agent-coordination) url="$AGENT_STACK_AGENT_COORDINATION_URL" ;;
    agent-coordination-dashboard) url="$AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL" ;;
  esac
  git clone --quiet --branch main "$url" "$source_root/$name"
done
temporary_command="$(mktemp "$install_dir/.agent-stack.XXXXXX")"
install -m 0755 "$source_root/agent-workflows/bin/agent-stack" "$temporary_command"
mv -f "$temporary_command" "$install_dir/agent-stack"
BASH
  chmod +x "$install_dir/agent-stack"

  AGENT_STACK_AGENT_WORKFLOWS_URL="$temporary/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$temporary/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$temporary/origins/agent-coordination-dashboard.git" \
    "$install_dir/agent-stack" sync --source-root "$source_root" \
      --agent-coord-install-dir "$install_dir"

  [[ ! -e "$install_dir/agent_stack" ]] || fail "prior command unexpectedly installed new modules"
  output="$(AGENT_STACK_AGENT_WORKFLOWS_URL="$temporary/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$temporary/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$temporary/origins/agent-coordination-dashboard.git" \
    "$install_dir/agent-stack" sync --source-root "$source_root" \
      --compat-root "$temporary/compat" --runtime-root "$temporary/runtime" \
      --target "$temporary/codex-home" --agent-coord-install-dir "$install_dir" --no-fetch 2>&1)"

  assert_contains "$output" "agent-stack sync complete"
  assert_file "$install_dir/agent_stack/usage.bash"
  assert_file "$install_dir/agent_doctor/stack_cli.rb"
  "$install_dir/agent-stack" --help >/dev/null
}

test_launcher_uses_only_complete_module_trees() {
  local temporary install_dir source_root output status module_name broken
  temporary="$(make_tmp_dir)"
  install_dir="$temporary/local-bin"
  source_root="$temporary/src"
  with_current_workflows_origin "$temporary"
  for module_name in agent-workflows agent-coordination agent-coordination-dashboard; do
    git clone --quiet "$temporary/origins/$module_name.git" "$source_root/$module_name"
  done
  mkdir -p "$install_dir/agent_stack"
  cp "$ROOT/bin/agent-stack" "$install_dir/agent-stack"
  cp "$ROOT/bin/agent_stack/usage.bash" "$install_dir/agent_stack/usage.bash"
  printf 'agent-stack-module-v1:agent_stack\n' > "$install_dir/agent_stack/.agent-stack-managed"
  chmod +x "$install_dir/agent-stack"

  set +e
  output="$(AGENT_STACK_AGENT_WORKFLOWS_URL="$temporary/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$temporary/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$temporary/origins/agent-coordination-dashboard.git" \
    "$install_dir/agent-stack" sync --source-root "$source_root" --compat-root "$temporary/compat" \
      --runtime-root "$temporary/runtime" --target "$temporary/codex-home" \
      --agent-coord-install-dir "$install_dir" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "partial local module tree did not fall back to source: $output"
  assert_contains "$output" "agent-stack sync complete"
  for module_name in usage doctor options paths runtime repositories compatibility installers sync; do
    assert_file "$install_dir/agent_stack/$module_name.bash"
  done

  broken="$temporary/broken"
  mkdir -p "$broken/bin/agent_stack" "$broken/source/agent-workflows/bin/agent_stack"
  cp "$ROOT/bin/agent-stack" "$broken/bin/agent-stack"
  cp "$ROOT/bin/agent_stack/usage.bash" "$broken/bin/agent_stack/usage.bash"
  cp "$ROOT/bin/agent_stack/usage.bash" "$broken/source/agent-workflows/bin/agent_stack/usage.bash"
  chmod +x "$broken/bin/agent-stack"
  set +e
  output="$("$broken/bin/agent-stack" sync --source-root "$broken/source" --no-install 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 64 ]] || fail "incomplete module trees exited $status: $output"
  assert_contains "$output" "agent-stack module trees incomplete"
  [[ "$output" != *"No such file or directory"* ]] || fail "incomplete module trees emitted a raw source error"
}
