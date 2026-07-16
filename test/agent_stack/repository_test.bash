test_repository_guards_reject_unsafe_checkouts() {
  local scenario temporary output status checkout
  for scenario in dirty wrong_branch missing_origin wrong_origin; do
    temporary="$(make_tmp_dir)"
    with_origins "$temporary"
    run_sync "$temporary" --no-install --no-fetch >/dev/null
    checkout="$temporary/src/agent-workflows"
    case "$scenario" in
      dirty) printf 'dirty\n' >> "$checkout/README.md" ;;
      wrong_branch) git -C "$checkout" switch -q -c feature ;;
      missing_origin) git -C "$checkout" remote remove origin ;;
      wrong_origin) git -C "$checkout" remote set-url origin "$temporary/origins/agent-coordination.git" ;;
    esac
    set +e
    output="$(run_sync "$temporary" --no-install --no-fetch 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "$scenario checkout unexpectedly synced"
    case "$scenario" in
      dirty) assert_contains "$output" "dirty worktree" ;;
      wrong_branch) assert_contains "$output" "not on main" ;;
      missing_origin) assert_contains "$output" "missing origin" ;;
      wrong_origin) assert_contains "$output" "origin mismatch" ;;
    esac
  done
}

test_worktree_checkout_and_force_stash_are_supported() {
  local temporary primary source_root branch
  temporary="$(make_tmp_dir)"
  with_origins "$temporary"
  run_sync "$temporary" --no-install --no-fetch >/dev/null
  printf 'dirty\n' >> "$temporary/src/agent-workflows/README.md"

  run_sync "$temporary" --no-install --no-fetch --force-stash >/dev/null
  git -C "$temporary/src/agent-workflows" diff --quiet || fail "force stash left dirty changes"
  git -C "$temporary/src/agent-workflows" stash list | grep -q agent-stack-sync || fail "force stash was not recorded"

  temporary="$(make_tmp_dir)"
  with_origins "$temporary"
  primary="$temporary/primary-agent-workflows"
  source_root="$temporary/src"
  git clone --quiet "$temporary/origins/agent-workflows.git" "$primary"
  git -C "$primary" switch --quiet -c spare-worktree-holder
  git -C "$primary" worktree add --quiet "$source_root/agent-workflows" main
  run_sync "$temporary" --no-install --no-fetch >/dev/null
  [[ -f "$source_root/agent-workflows/.git" ]] || fail "git worktree checkout was not accepted"

  temporary="$(make_tmp_dir)"
  with_origins "$temporary"
  git -C "$temporary/work/agent-workflows" switch --quiet -c default-branch
  printf 'default branch\n' >> "$temporary/work/agent-workflows/README.md"
  git -C "$temporary/work/agent-workflows" add README.md
  git -C "$temporary/work/agent-workflows" commit --quiet -m "default branch marker"
  git -C "$temporary/origins/agent-workflows.git" fetch --quiet "$temporary/work/agent-workflows" default-branch:default-branch
  git -C "$temporary/origins/agent-workflows.git" symbolic-ref HEAD refs/heads/default-branch
  run_sync "$temporary" --no-install --no-fetch >/dev/null
  branch="$(git -C "$temporary/src/agent-workflows" branch --show-current)"
  [[ "$branch" = main ]] || fail "fresh clone followed remote HEAD instead of main"
}
