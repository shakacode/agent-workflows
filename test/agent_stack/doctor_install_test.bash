test_colocated_copy_sync_recovers_recorded_dangling_doctor_symlink() {
  local temporary target prior_source
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"
  prior_source="$temporary/work/agent-workflows"

  "$prior_source/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >/dev/null
  [[ "$(readlink "$target/bin/agent_doctor")" = "$prior_source/bin/agent_doctor" ]] ||
    fail "prior standalone install did not link the recorded doctor source"
  rm -rf "$prior_source"
  [[ -L "$target/bin/agent_doctor" && ! -e "$target/bin/agent_doctor" ]] ||
    fail "prior standalone doctor link did not become dangling"

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" \
    --mode copy --no-fetch

  [[ -d "$target/bin/agent_doctor" && ! -L "$target/bin/agent_doctor" ]] ||
    fail "stack copy sync did not replace the recorded dangling doctor link"
  grep -qxF "agent-stack-module-v1:agent_doctor" "$target/bin/agent_doctor/.agent-stack-managed" ||
    fail "recovered doctor copy is missing stack ownership"
  ruby "$temporary/src/agent-workflows/bin/agent_doctor/install_ownership.rb" verify \
    "$target/bin/agent_doctor" "$target/bin/agent_doctor/.agent-workflows-managed" ||
    fail "recovered doctor copy is missing workflow ownership"
}

test_colocated_copy_sync_recovers_recorded_live_doctor_symlink_after_source_relocation() {
  local temporary target prior_source
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"
  prior_source="$temporary/work/agent-workflows"

  "$prior_source/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >/dev/null
  [[ "$(readlink "$target/bin/agent_doctor")" = "$prior_source/bin/agent_doctor" ]] ||
    fail "prior standalone install did not link the recorded doctor source"
  [[ -d "$prior_source/bin/agent_doctor" && -d "$target/bin/agent_doctor" ]] ||
    fail "expected the prior installer-owned doctor link to remain live"

  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" \
    --mode copy --no-fetch

  [[ -d "$prior_source/bin/agent_doctor" ]] || fail "stack sync removed the prior live source doctor"
  [[ -d "$target/bin/agent_doctor" && ! -L "$target/bin/agent_doctor" ]] ||
    fail "stack copy sync did not replace the live recorded doctor link"
  grep -qxF "agent-stack-module-v1:agent_doctor" "$target/bin/agent_doctor/.agent-stack-managed" ||
    fail "recovered doctor copy is missing stack ownership"
  ruby "$temporary/src/agent-workflows/bin/agent_doctor/install_ownership.rb" verify \
    "$target/bin/agent_doctor" "$target/bin/agent_doctor/.agent-workflows-managed" ||
    fail "recovered doctor copy is missing workflow ownership"
}

test_colocated_copy_sync_refuses_unproven_dangling_doctor_symlinks_without_mutation() {
  local variant temporary target recorded_source link_target output status metadata_before
  for variant in unrelated malformed_metadata wrong_mode wrong_target; do
    temporary="$(make_tmp_dir)"
    target="$temporary/codex-home"
    recorded_source="$temporary/deleted-recorded-source"
    with_current_workflows_origin "$temporary"
    mkdir -p "$target/bin"
    case "$variant" in
      unrelated)
        link_target="$temporary/unrelated-source/bin/agent_doctor"
        metadata_before=absent
        ;;
      malformed_metadata)
        link_target="$recorded_source/bin/agent_doctor"
        printf '{malformed\n' > "$target/.agent-workflows-install.json"
        metadata_before="$(shasum "$target/.agent-workflows-install.json")"
        ;;
      wrong_mode)
        link_target="$recorded_source/bin/agent_doctor"
        ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"mode" => "copy", "source" => ARGV[1]}) + "\n")' \
          "$target/.agent-workflows-install.json" "$recorded_source"
        metadata_before="$(shasum "$target/.agent-workflows-install.json")"
        ;;
      wrong_target)
        link_target="$temporary/other-deleted-source/bin/agent_doctor"
        ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"mode" => "symlink", "source" => ARGV[1]}) + "\n")' \
          "$target/.agent-workflows-install.json" "$recorded_source"
        metadata_before="$(shasum "$target/.agent-workflows-install.json")"
        ;;
    esac
    ln -s "$link_target" "$target/bin/agent_doctor"

    set +e
    output="$(run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" \
      --mode copy --no-fetch 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "$variant dangling doctor link unexpectedly installed"
    assert_contains "$output" "Refusing unmanaged co-located doctor symlink"
    [[ "$(readlink "$target/bin/agent_doctor")" = "$link_target" ]] ||
      fail "$variant dangling doctor link changed"
    [[ -L "$target/bin/agent_doctor" && ! -e "$target/bin/agent_doctor" ]] ||
      fail "$variant dangling doctor link was replaced"
    if [[ "$metadata_before" = absent ]]; then
      [[ ! -e "$target/.agent-workflows-install.json" ]] || fail "$variant sync created metadata"
    else
      [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] ||
        fail "$variant sync changed metadata"
    fi
  done
}

test_colocated_symlink_sync_refuses_workflow_doctor_copy_without_mutation() {
  local temporary target doctor_before metadata_before output status
  temporary="$(make_tmp_dir)"
  target="$temporary/codex-home"
  with_current_workflows_origin "$temporary"
  run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" --mode copy --no-fetch >/dev/null
  doctor_before="$(ruby "$temporary/src/agent-workflows/bin/agent_doctor/install_ownership.rb" marker \
    "$target/bin/agent_doctor")"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"

  set +e
  output="$(run_sync "$temporary" --target "$target" --agent-coord-install-dir "$target/bin" \
    --mode symlink --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "symlink mode replaced a workflow doctor copy"
  assert_contains "$output" "Refusing workflow-owned doctor non-symlink destination"
  [[ -d "$target/bin/agent_doctor" && ! -L "$target/bin/agent_doctor" ]] ||
    fail "symlink mode changed the workflow doctor copy type"
  [[ "$doctor_before" = "$(ruby "$temporary/src/agent-workflows/bin/agent_doctor/install_ownership.rb" marker \
    "$target/bin/agent_doctor")" ]] || fail "symlink mode changed the workflow doctor copy"
  [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] ||
    fail "symlink mode changed workflow install metadata"
}
