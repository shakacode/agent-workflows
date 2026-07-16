agent_stack_test_inventory() {
  find "$1" -mindepth 1 -print | LC_ALL=C sort
}

test_sync_fails_when_required_install_executable_is_missing() {
  local kind temporary repo missing output status
  for kind in stack coordination workflows; do
    temporary="$(make_tmp_dir)"
    with_origins "$temporary"
    case "$kind" in
      stack) repo=agent-workflows; missing=bin/agent-stack-doctor ;;
      coordination) repo=agent-coordination; missing=bin/agent-coord ;;
      workflows) repo=agent-workflows; missing=bin/install-agent-workflows ;;
    esac
    git -C "$temporary/work/$repo" rm --quiet "$missing"
    git -C "$temporary/work/$repo" commit --quiet -m "remove required $kind executable"
    git -C "$temporary/work/$repo" push --quiet "$temporary/origins/$repo.git" main:main

    set +e
    output="$(run_sync "$temporary" --target "$temporary/codex-home" \
      --agent-coord-install-dir "$temporary/local-bin" 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "$kind install unexpectedly succeeded without $missing"
    assert_contains "$output" "Cannot install"
    [[ "$output" != *"agent-stack sync complete"* ]] || fail "$kind failure reported sync completion"
  done
}

test_sync_refuses_command_directory_destinations_before_any_install_mutation() {
  local helper kind temporary install_dir outside target other before_inside before_outside output status
  for helper in agent-stack agent-stack-doctor; do
    for kind in directory external_symlink; do
      temporary="$(make_tmp_dir)"
      install_dir="$temporary/local-bin"
      outside="$temporary/outside"
      target="$temporary/codex-home"
      other=agent-stack
      [[ "$helper" = agent-stack ]] && other=agent-stack-doctor
      with_origins "$temporary"
      mkdir -p "$install_dir" "$outside"
      if [[ "$kind" = directory ]]; then
        mkdir -p "$install_dir/$helper"
        printf 'inside-sentinel\n' > "$install_dir/$helper/sentinel"
      else
        printf 'outside-sentinel\n' > "$outside/sentinel"
        ln -s "$outside" "$install_dir/$helper"
      fi
      before_inside="$(agent_stack_test_inventory "$install_dir")"
      before_outside="$(agent_stack_test_inventory "$outside")"

      set +e
      output="$(run_sync "$temporary" --target "$target" --agent-coord-install-dir "$install_dir" 2>&1)"
      status=$?
      set -e

      [[ "$status" -ne 0 ]] || fail "$helper $kind destination unexpectedly installed"
      assert_contains "$output" "Refusing stack command"
      [[ "$(agent_stack_test_inventory "$install_dir")" = "$before_inside" ]] ||
        fail "$helper $kind failure changed the install inventory"
      [[ "$(agent_stack_test_inventory "$outside")" = "$before_outside" ]] ||
        fail "$helper $kind failure changed the outside inventory"
      [[ ! -e "$install_dir/$other" && ! -L "$install_dir/$other" ]] || fail "$helper failure installed $other"
      [[ ! -e "$install_dir/agent_stack" && ! -e "$install_dir/agent_doctor" ]] ||
        fail "$helper $kind failure partially installed modules"
      if [[ "$kind" = directory ]]; then
        grep -qx 'inside-sentinel' "$install_dir/$helper/sentinel" || fail "$helper directory sentinel changed"
      else
        grep -qx 'outside-sentinel' "$outside/sentinel" || fail "$helper outside sentinel changed"
      fi
    done
  done
}

test_sync_replaces_non_directory_command_symlinks_without_touching_referents() {
  local helper kind temporary install_dir outside referent
  for helper in agent-stack agent-stack-doctor; do
    for kind in file dangling; do
      temporary="$(make_tmp_dir)"
      install_dir="$temporary/local-bin"
      outside="$temporary/outside"
      with_origins "$temporary"
      mkdir -p "$install_dir" "$outside"
      referent="$outside/$kind-referent"
      if [[ "$kind" = file ]]; then printf 'preserve-referent\n' > "$referent"; fi
      ln -s "$referent" "$install_dir/$helper"

      run_sync "$temporary" --target "$temporary/codex-home" --agent-coord-install-dir "$install_dir"

      assert_executable "$install_dir/$helper"
      [[ ! -L "$install_dir/$helper" ]] || fail "$helper $kind symlink was not replaced"
      if [[ "$kind" = file ]]; then
        grep -qx 'preserve-referent' "$referent" || fail "$helper file referent changed"
      else
        [[ ! -e "$referent" && ! -L "$referent" ]] || fail "$helper dangling referent was created"
      fi
    done
  done
}
