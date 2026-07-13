test_sync_refuses_symlink_module_destinations_without_touching_targets() {
  local module_name temporary install_dir outside output status
  for module_name in agent_stack agent_doctor; do
    temporary="$(make_tmp_dir)"
    install_dir="$temporary/local-bin"
    outside="$temporary/outside-$module_name"
    with_origins "$temporary"
    mkdir -p "$install_dir" "$outside"
    printf 'preserve\n' > "$outside/sentinel"
    ln -s "$outside" "$install_dir/$module_name"

    set +e
    output="$(run_sync "$temporary" --target "$temporary/codex-home" \
      --agent-coord-install-dir "$install_dir" --no-fetch 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "$module_name symlink destination unexpectedly installed"
    assert_contains "$output" "Refusing stack module symlink destination"
    assert_file "$outside/sentinel"
    [[ -L "$install_dir/$module_name" ]] || fail "$module_name symlink was replaced"
  done
}

test_sync_refuses_unmanaged_module_directories_without_deleting_files() {
  local module_name temporary install_dir output status
  for module_name in agent_stack agent_doctor; do
    temporary="$(make_tmp_dir)"
    install_dir="$temporary/local-bin"
    with_origins "$temporary"
    mkdir -p "$install_dir/$module_name"
    printf 'user-owned\n' > "$install_dir/$module_name/sentinel"

    set +e
    output="$(run_sync "$temporary" --target "$temporary/codex-home" \
      --agent-coord-install-dir "$install_dir" --no-fetch 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "$module_name unmanaged destination unexpectedly installed"
    assert_contains "$output" "Refusing unmanaged stack module directory"
    grep -qx "user-owned" "$install_dir/$module_name/sentinel" || fail "$module_name unrelated file was changed"
  done
}

test_colocated_sync_refuses_unmanaged_doctor_symlinks_without_touching_targets() {
  local mode temporary target outside output status
  for mode in copy symlink; do
    temporary="$(make_tmp_dir)"
    target="$temporary/codex-home"
    outside="$temporary/outside-agent-doctor"
    with_origins "$temporary"
    mkdir -p "$target/bin" "$outside"
    printf 'preserve\n' > "$outside/sentinel"
    ln -s "$outside" "$target/bin/agent_doctor"

    set +e
    output="$(run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" \
      --mode "$mode" --no-fetch 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "$mode mode accepted an unmanaged co-located doctor symlink"
    assert_contains "$output" "Refusing"
    assert_file "$outside/sentinel"
    [[ -L "$target/bin/agent_doctor" ]] || fail "$mode mode replaced the unmanaged doctor symlink"
  done
}

test_colocated_copy_sync_refuses_non_equivalent_workflow_doctors_without_touching_them() {
  local variant temporary target protected output status
  for variant in file_mode modified extra arbitrary; do
    temporary="$(make_tmp_dir)"
    target="$temporary/codex-home"
    with_current_workflows_origin "$temporary"
    "$ROOT/bin/install-agent-workflows" --target "$target" >/dev/null

    case "$variant" in
      file_mode)
        protected="$target/bin/agent_doctor/configuration.rb"
        chmod 0600 "$protected"
        ;;
      modified)
        protected="$target/bin/agent_doctor/configuration.rb"
        printf 'user-modified\n' > "$protected"
        ;;
      extra)
        protected="$target/bin/agent_doctor/user-extra"
        printf 'user-extra\n' > "$protected"
        ;;
      arbitrary)
        rm -rf "$target/bin/agent_doctor"
        mkdir -p "$target/bin/agent_doctor"
        protected="$target/bin/agent_doctor/user-arbitrary"
        printf 'user-arbitrary\n' > "$protected"
        ;;
    esac

    set +e
    output="$(run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" \
      --mode copy --no-fetch 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "copy mode adopted a $variant workflow doctor directory"
    assert_contains "$output" "Refusing unmanaged stack module directory"
    if [[ "$variant" = file_mode ]]; then
      assert_mode "$protected" 600
    else
      grep -qx "user-$variant" "$protected" || fail "copy mode changed the $variant doctor directory"
    fi
    [[ ! -e "$target/bin/agent_doctor/.agent-stack-managed" ]] || fail "copy mode marked the $variant doctor directory"
  done
}

test_colocated_copy_sync_refuses_root_mode_mismatch_without_touching_it() {
  local temporary target output status
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"
  "$ROOT/bin/install-agent-workflows" --target "$target" >/dev/null
  chmod 0700 "$target/bin/agent_doctor"

  set +e
  output="$(run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" \
    --mode copy --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "copy mode adopted a workflow doctor with a modified root mode"
  assert_contains "$output" "Refusing unmanaged stack module directory"
  assert_mode "$target/bin/agent_doctor" 700
  [[ ! -e "$target/bin/agent_doctor/.agent-stack-managed" ]] || fail "copy mode marked the root-mode mismatch"
}
