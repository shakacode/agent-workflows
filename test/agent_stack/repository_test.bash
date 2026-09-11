fixture_clone_writer_start() {
  local work="$1"
  local object payload temporary_pack ready
  object="$("$RUBY_BIN" -e 'STDOUT.write(Random.new(823).bytes(2 * 1024 * 1024))' | command git -C "$work" hash-object -w --stdin)"
  payload="$AGENT_STACK_FIXTURE_RACE_ROOT/unreferenced.pack"
  printf '%s\n' "$object" | command git -C "$work" pack-objects --stdout > "$payload"
  temporary_pack="$work/.git/objects/pack/tmp_pack_fixture_race"
  ready="$AGENT_STACK_FIXTURE_RACE_ROOT/writer-ready"

  "$RUBY_BIN" -rtimeout -e '
    source, destination, ready = ARGV
    Timeout.timeout(10) do
      File.open(destination, "wb") do |output|
        File.open(source, "rb") do |input|
          File.write(ready, "ready")
          until (chunk = input.read(4096)).nil?
            output.write(chunk)
            output.flush
            sleep 0.003
          end
        end
      end
    end
  ' "$payload" "$temporary_pack" "$ready" &
  AGENT_STACK_FIXTURE_RACE_WRITER_PID=$!
  AGENT_STACK_FIXTURE_RACE_TEMPORARY_PACK="$temporary_pack"

  local attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -f "$ready" ]] && return
    sleep 0.01
  done
  wait "$AGENT_STACK_FIXTURE_RACE_WRITER_PID" || true
  fail "temporary-pack writer did not start"
}

fixture_clone_writer_finish() {
  local status=0
  if [[ -n "${AGENT_STACK_FIXTURE_RACE_WRITER_PID:-}" ]]; then
    wait "$AGENT_STACK_FIXTURE_RACE_WRITER_PID" || status=$?
  fi
  rm -f -- "${AGENT_STACK_FIXTURE_RACE_TEMPORARY_PACK:-}" \
    "$AGENT_STACK_FIXTURE_RACE_ROOT/unreferenced.pack" \
    "$AGENT_STACK_FIXTURE_RACE_ROOT/writer-ready"
  unset AGENT_STACK_FIXTURE_RACE_WRITER_PID AGENT_STACK_FIXTURE_RACE_TEMPORARY_PACK
  [[ "$status" -eq 0 ]] || fail "temporary-pack writer failed"
}

git() {
  if [[ "${AGENT_STACK_FIXTURE_RACE_WORK:-}" = "${2:-}" && "${1:-}" = -C && "${3:-}" = clone ]]; then
    fixture_clone_writer_start "$2"
  fi
  command git "$@"
}

assert_fixture_origin_identity_and_independence() {
  local source="$1"
  local origin="$2"
  local expected_head expected_tree actual_head actual_tree
  expected_head="$(command git -C "$source" rev-parse HEAD)"
  expected_tree="$(command git -C "$source" rev-parse 'HEAD^{tree}')"
  actual_head="$(command git -C "$origin" rev-parse HEAD)"
  actual_tree="$(command git -C "$origin" rev-parse 'HEAD^{tree}')"
  [[ "$actual_head" = "$expected_head" ]] || fail "fixture origin HEAD differs from source"
  [[ "$actual_tree" = "$expected_tree" ]] || fail "fixture origin tree differs from source"
  command git -C "$origin" cat-file -e "$actual_head^{commit}" || fail "fixture origin cannot read committed HEAD"
  "$RUBY_BIN" -e '
    source, origin = ARGV
    source_inodes = Dir.glob(File.join(source, ".git", "objects", "**", "*")).filter_map do |path|
      next unless File.file?(path)
      stat = File.stat(path)
      [stat.dev, stat.ino]
    end.to_h { |inode| [inode, true] }
    shared = Dir.glob(File.join(origin, "objects", "**", "*")).filter_map do |path|
      next unless File.file?(path)
      stat = File.stat(path)
      [stat.dev, stat.ino]
    end.find { |inode| source_inodes.key?(inode) }
    abort "fixture origin shares an object inode with source" if shared
  ' "$source" "$origin" || fail "fixture origin shares object storage with source"
}

test_fixture_origins_clone_without_local_object_sharing_during_temp_pack_writes() {
  local constructor temporary source origin status
  for constructor in create_origin create_current_workflows_origin; do
    temporary="$(make_tmp_dir)"
    AGENT_STACK_FIXTURE_RACE_ROOT="$temporary/race"
    AGENT_STACK_FIXTURE_RACE_WORK="$temporary/work/agent-workflows"
    mkdir -p "$AGENT_STACK_FIXTURE_RACE_ROOT"

    set +e
    if [[ "$constructor" = create_origin ]]; then
      create_origin "$temporary" agent-workflows
    else
      create_current_workflows_origin "$temporary"
    fi
    status=$?
    set -e
    fixture_clone_writer_finish
    [[ "$status" -eq 0 ]] || fail "$constructor failed while an unreferenced temporary pack was mutable"

    source="$temporary/work/agent-workflows"
    origin="$temporary/origins/agent-workflows.git"
    assert_fixture_origin_identity_and_independence "$source" "$origin"
    unset AGENT_STACK_FIXTURE_RACE_ROOT AGENT_STACK_FIXTURE_RACE_WORK
  done
}

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
