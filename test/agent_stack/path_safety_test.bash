test_path_overlap_and_compatibility_guards() {
  local temporary output status
  temporary="$(make_tmp_dir)"
  with_origins "$temporary"

  set +e
  output="$(run_sync "$temporary" --source-root "$temporary/shared" --compat-root "$temporary/shared" --no-install 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "overlapping roots unexpectedly succeeded"
  assert_contains "$output" "compatibility root inside source checkout"

  run_sync "$temporary" --no-install --no-fetch >/dev/null
  rm "$temporary/compat/agent-workflows"
  ln -s "$temporary/src/agent-coordination" "$temporary/compat/agent-workflows"
  set +e
  output="$(run_sync "$temporary" --no-install --no-fetch 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "mismatched compatibility link unexpectedly succeeded"
  assert_contains "$output" "--replace-compat"

  run_sync "$temporary" --no-install --no-fetch --replace-compat >/dev/null
  [[ "$(cd "$temporary/compat/agent-workflows" && pwd -P)" = "$(cd "$temporary/src/agent-workflows" && pwd -P)" ]] || \
    fail "replace-compat did not restore source link"
}

test_runtime_paths_are_private_and_not_symlinks() {
  local kind temporary output status
  for kind in env state; do
    temporary="$(make_tmp_dir)"
    with_origins "$temporary"
    mkdir -p "$temporary/runtime" "$temporary/outside"
    ln -s "$temporary/outside" "$temporary/runtime/$kind"
    set +e
    output="$(run_sync "$temporary" --no-install --no-fetch 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "runtime $kind symlink unexpectedly succeeded"
    assert_contains "$output" "runtime"
    assert_contains "$output" "symlink"
  done

  temporary="$(make_tmp_dir)"
  with_origins "$temporary"
  run_sync "$temporary" --no-install --no-fetch >/dev/null
  assert_mode "$temporary/runtime" 700
  assert_mode "$temporary/runtime/env" 600
}

test_no_install_and_help_contracts() {
  local temporary output
  temporary="$(make_tmp_dir)"
  with_origins "$temporary"
  HOME="$temporary/home" run_sync "$temporary" --no-install --no-fetch >/dev/null
  [[ ! -e "$temporary/home/.local/bin" ]] || fail "--no-install created the install directory"

  output="$("$ROOT/bin/agent-stack" --help)"
  assert_contains "$output" "AGENT_STACK_SOURCE_ROOT"
  assert_contains "$output" "AGENT_STACK_COMPAT_ROOT"
  assert_contains "$output" "AGENT_STACK_RUNTIME_ROOT"
  assert_contains "$output" "not restored automatically"
}
