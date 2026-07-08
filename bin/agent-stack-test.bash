#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_paths=()

make_tmp_dir() {
  local path
  path="$(mktemp -d)"
  tmp_paths+=("$path")
  printf '%s\n' "$path"
}

make_tmp_file() {
  local path
  path="$(mktemp)"
  tmp_paths+=("$path")
  printf '%s\n' "$path"
}

cleanup() {
  if [[ "${#tmp_paths[@]}" -gt 0 ]]; then
    rm -rf "${tmp_paths[@]}"
  fi
}

trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_executable() {
  [[ -x "$1" ]] || fail "expected executable: $1"
}

assert_symlink_to() {
  local link="$1"
  local expected="$2"
  [[ -L "$link" ]] || fail "expected symlink: $link"
  local actual
  actual="$(readlink "$link")"
  [[ "$actual" = "$expected" ]] || fail "expected $link -> $expected, got $actual"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain '$needle', got: $haystack"
}

create_origin() {
  local tmp="$1"
  local name="$2"
  local work="$tmp/work/$name"
  local origin="$tmp/origins/$name.git"
  mkdir -p "$work" "$tmp/origins"
  git -C "$work" init --quiet --initial-branch=main
  git -C "$work" config user.email "agent-stack-test@example.com"
  git -C "$work" config user.name "Agent Stack Test"
  printf '# %s\n' "$name" > "$work/README.md"

  case "$name" in
    agent-workflows)
      mkdir -p "$work/bin"
      cat > "$work/bin/agent-stack" <<'BASH'
#!/usr/bin/env bash
echo synced agent-stack fixture
BASH
      chmod +x "$work/bin/agent-stack"
      cat > "$work/bin/install-agent-workflows" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    --host|--mode) shift 2 ;;
    *) shift ;;
  esac
done
: "${target:?missing --target}"
mkdir -p "$target/bin"
printf 'installed\n' > "$target/bin/agent-workflows-installed"
BASH
      chmod +x "$work/bin/install-agent-workflows"
      ;;
    agent-coordination)
      mkdir -p "$work/bin"
      cat > "$work/bin/agent-coord" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" = "bootstrap" ]]; then
  install_dir="$HOME/.local/bin"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) install_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$install_dir"
  printf '#!/usr/bin/env bash\necho agent-coord test\n' > "$install_dir/agent-coord"
  chmod +x "$install_dir/agent-coord"
  printf '#!/usr/bin/env bash\necho legacy alias\n' > "$install_dir/agent_coord"
  chmod +x "$install_dir/agent_coord"
  exit 0
fi
echo agent-coord fixture
BASH
      chmod +x "$work/bin/agent-coord"
      ;;
  esac

  git -C "$work" add .
  git -C "$work" commit --quiet -m "initial $name"
  git -C "$work" clone --quiet --bare . "$origin"
}

with_origins() {
  local tmp="$1"
  create_origin "$tmp" agent-workflows
  create_origin "$tmp" agent-coordination
  create_origin "$tmp" agent-coordination-dashboard
}

test_sync_clones_installs_and_links_the_stack() {
  local tmp source_root expected_source_root compat_root runtime_root target install_dir
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  mkdir -p "$source_root"
  expected_source_root="$(cd "$source_root" && pwd -P)"
  compat_root="$tmp/codex/agent-repos"
  runtime_root="$tmp/agent-workflows-home"
  target="$tmp/codex-home"
  install_dir="$tmp/local-bin"
  with_origins "$tmp"

  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$compat_root" \
      --runtime-root "$runtime_root" \
      --target "$target" \
      --agent-coord-install-dir "$install_dir"

  assert_file "$source_root/agent-workflows/README.md"
  assert_file "$source_root/agent-coordination/README.md"
  assert_file "$source_root/agent-coordination-dashboard/README.md"
  assert_file "$target/bin/agent-workflows-installed"
  assert_executable "$install_dir/agent-coord"
  assert_executable "$install_dir/agent-stack"
  grep -q "synced agent-stack fixture" "$install_dir/agent-stack" || fail "expected installed agent-stack to come from synced checkout"
  [[ ! -e "$install_dir/agent_coord" ]] || fail "legacy agent_coord alias should be removed"
  assert_symlink_to "$compat_root/agent-workflows" "$expected_source_root/agent-workflows"
  assert_symlink_to "$compat_root/agent-coordination" "$expected_source_root/agent-coordination"
  assert_symlink_to "$compat_root/agent-coordination-dashboard" "$expected_source_root/agent-coordination-dashboard"
  [[ -d "$runtime_root/cache" ]] || fail "expected runtime cache directory"
  [[ -d "$runtime_root/logs" ]] || fail "expected runtime logs directory"
  [[ -d "$runtime_root/state" ]] || fail "expected runtime state directory"
  assert_file "$runtime_root/env"
}

test_sync_preserves_preexisting_agent_coord_file() {
  local tmp source_root compat_root runtime_root install_dir
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
  install_dir="$tmp/local-bin"
  mkdir -p "$install_dir"
  printf 'custom command\n' > "$install_dir/agent_coord"
  with_origins "$tmp"

  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$compat_root" \
      --runtime-root "$runtime_root" \
      --target "$tmp/codex-home" \
      --agent-coord-install-dir "$install_dir"

  assert_file "$install_dir/agent_coord"
}

test_sync_updates_running_installed_agent_stack_via_temp_file() {
  local tmp source_root compat_root runtime_root install_dir fake_bin
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
  install_dir="$tmp/local-bin"
  fake_bin="$tmp/fake-bin"
  mkdir -p "$install_dir" "$fake_bin"
  cp "$ROOT/bin/agent-stack" "$install_dir/agent-stack"
  chmod +x "$install_dir/agent-stack"
  cat > "$fake_bin/install" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
last_arg="${@: -1}"
if [[ -n "${AGENT_STACK_TEST_FORBIDDEN_INSTALL_DEST:-}" && "$last_arg" = "$AGENT_STACK_TEST_FORBIDDEN_INSTALL_DEST" ]]; then
  echo "direct install to running agent-stack" >&2
  exit 42
fi
exec /usr/bin/install "$@"
BASH
  chmod +x "$fake_bin/install"
  with_origins "$tmp"

  PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  AGENT_STACK_TEST_FORBIDDEN_INSTALL_DEST="$install_dir/agent-stack" \
  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$install_dir/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$compat_root" \
      --runtime-root "$runtime_root" \
      --target "$tmp/codex-home" \
      --agent-coord-install-dir "$install_dir"

  grep -q "synced agent-stack fixture" "$install_dir/agent-stack" || fail "expected running installed agent-stack to refresh from synced checkout"
}

test_sync_refuses_dirty_repo_without_force_stash() {
  local tmp source_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  with_origins "$tmp"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$source_root/agent-workflows"
  printf 'dirty\n' >> "$source_root/agent-workflows/README.md"

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$tmp/compat" \
        --runtime-root "$tmp/runtime" \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected dirty repo sync to fail"
  assert_contains "$output" "dirty worktree"
}

test_sync_refuses_non_main_repo() {
  local tmp source_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  with_origins "$tmp"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$source_root/agent-workflows"
  git -C "$source_root/agent-workflows" switch --quiet -c feature/local-work

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$tmp/compat" \
        --runtime-root "$tmp/runtime" \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected non-main repo sync to fail"
  assert_contains "$output" "not on main"
}

test_sync_refuses_checkout_without_origin_remote() {
  local tmp source_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  with_origins "$tmp"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$source_root/agent-workflows"
  git -C "$source_root/agent-workflows" remote remove origin

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$tmp/compat" \
        --runtime-root "$tmp/runtime" \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected checkout without origin remote to fail"
  assert_contains "$output" "missing origin remote"
}

test_sync_accepts_git_worktree_checkout() {
  local tmp source_root primary_checkout
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  primary_checkout="$tmp/primary-agent-workflows"
  with_origins "$tmp"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$primary_checkout"
  git -C "$primary_checkout" switch --quiet -c spare-worktree-holder
  git -C "$primary_checkout" worktree add --quiet "$source_root/agent-workflows" main

  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$tmp/compat" \
      --runtime-root "$tmp/runtime" \
      --no-install

  [[ -f "$source_root/agent-workflows/.git" ]] || fail "expected git worktree gitfile"
}

test_sync_clones_main_even_when_remote_head_differs() {
  local tmp source_root branch
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  with_origins "$tmp"

  git -C "$tmp/work/agent-workflows" switch --quiet -c default-branch
  printf 'default branch\n' >> "$tmp/work/agent-workflows/README.md"
  git -C "$tmp/work/agent-workflows" add README.md
  git -C "$tmp/work/agent-workflows" commit --quiet -m "default branch marker"
  git -C "$tmp/origins/agent-workflows.git" fetch --quiet "$tmp/work/agent-workflows" default-branch:default-branch
  git -C "$tmp/origins/agent-workflows.git" symbolic-ref HEAD refs/heads/default-branch

  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$tmp/compat" \
      --runtime-root "$tmp/runtime" \
      --no-install

  branch="$(git -C "$source_root/agent-workflows" branch --show-current)"
  [[ "$branch" = "main" ]] || fail "expected fresh clone on main, got $branch"
}

test_sync_rejects_existing_checkout_when_url_override_disagrees() {
  local tmp source_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  with_origins "$tmp"
  git clone --quiet --bare "$tmp/work/agent-workflows" "$tmp/origins/agent-workflows-fork.git"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$source_root/agent-workflows"
  git -C "$source_root/agent-workflows" remote set-url origin https://github.com/shakacode/agent-workflows.git

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows-fork.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$tmp/compat" \
        --runtime-root "$tmp/runtime" \
        --no-install \
        --no-fetch 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected override origin mismatch to fail"
  assert_contains "$output" "origin mismatch"
}

test_sync_refuses_mismatched_compat_symlink_without_replace() {
  local tmp source_root compat_root runtime_root output status wrong_target
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
  wrong_target="$tmp/custom-agent-workflows"
  mkdir -p "$compat_root" "$wrong_target"
  ln -s "$wrong_target" "$compat_root/agent-workflows"
  with_origins "$tmp"

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$compat_root" \
        --runtime-root "$runtime_root" \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected mismatched compatibility symlink to fail"
  assert_contains "$output" "Refusing to replace compatibility path"
  assert_symlink_to "$compat_root/agent-workflows" "$wrong_target"
}

test_sync_refuses_overlapping_source_and_compat_roots() {
  local tmp source_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  with_origins "$tmp"

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$source_root" \
        --runtime-root "$tmp/runtime" \
        --replace-compat \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected overlapping source/compat roots to fail"
  assert_contains "$output" "Refusing compatibility path that overlaps source checkout"
  [[ -d "$source_root/agent-workflows/.git" || -f "$source_root/agent-workflows/.git" ]] || fail "expected source checkout to remain intact"
}

test_sync_refuses_compat_root_inside_source_checkout_before_creating_it() {
  local tmp source_root compat_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$source_root/agent-workflows/compat"
  with_origins "$tmp"

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$compat_root" \
        --runtime-root "$tmp/runtime" \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected nested compatibility root to fail"
  assert_contains "$output" "Refusing compatibility root inside source checkout"
  [[ ! -e "$source_root/agent-workflows" ]] || fail "nested compatibility root should be rejected before creating the checkout path"
}

test_sync_links_compat_to_physical_source_root() {
  local tmp real_source_root source_root compat_root runtime_root
  tmp="$(make_tmp_dir)"
  real_source_root="$tmp/real-src"
  source_root="$tmp/src-link"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
  mkdir -p "$real_source_root"
  real_source_root="$(cd "$real_source_root" && pwd -P)"
  ln -s "$real_source_root" "$source_root"
  with_origins "$tmp"

  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$compat_root" \
      --runtime-root "$runtime_root" \
      --no-install

  assert_symlink_to "$compat_root/agent-workflows" "$real_source_root/agent-workflows"
  assert_symlink_to "$compat_root/agent-coordination" "$real_source_root/agent-coordination"
  assert_symlink_to "$compat_root/agent-coordination-dashboard" "$real_source_root/agent-coordination-dashboard"
}

test_sync_refuses_runtime_env_symlink() {
  local tmp source_root compat_root runtime_root env_target output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
  env_target="$tmp/external-env"
  mkdir -p "$runtime_root"
  printf 'SECRET=1\n' > "$env_target"
  ln -s "$env_target" "$runtime_root/env"
  with_origins "$tmp"

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync \
        --source-root "$source_root" \
        --compat-root "$compat_root" \
        --runtime-root "$runtime_root" \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected runtime env symlink to fail"
  assert_contains "$output" "Refusing to use runtime env symlink"
}

test_no_install_does_not_create_default_install_dir() {
  local tmp source_root compat_root runtime_root home
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
  home="$tmp/home"
  mkdir -p "$home"
  with_origins "$tmp"

  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$home" \
  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$compat_root" \
      --runtime-root "$runtime_root" \
      --no-install

  [[ ! -e "$home/.local/bin" ]] || fail "--no-install should not create the default install dir"
}

test_sync_force_stash_allows_dirty_main_repo() {
  local tmp source_root output_file
  tmp="$(make_tmp_dir)"
  output_file="$(make_tmp_file)"
  source_root="$tmp/src"
  with_origins "$tmp"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$source_root/agent-workflows"
  printf 'dirty\n' >> "$source_root/agent-workflows/README.md"

  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$tmp/compat" \
      --runtime-root "$tmp/runtime" \
      --no-install \
      --force-stash >"$output_file"

  git -C "$source_root/agent-workflows" diff --quiet || fail "expected dirty changes to be stashed"
  git -C "$source_root/agent-workflows" stash list | grep -q "agent-stack-sync-" || fail "expected agent-stack stash"
}

test_sync_clones_installs_and_links_the_stack
test_sync_preserves_preexisting_agent_coord_file
test_sync_updates_running_installed_agent_stack_via_temp_file
test_sync_refuses_dirty_repo_without_force_stash
test_sync_refuses_non_main_repo
test_sync_refuses_checkout_without_origin_remote
test_sync_accepts_git_worktree_checkout
test_sync_clones_main_even_when_remote_head_differs
test_sync_rejects_existing_checkout_when_url_override_disagrees
test_sync_refuses_mismatched_compat_symlink_without_replace
test_sync_refuses_overlapping_source_and_compat_roots
test_sync_refuses_compat_root_inside_source_checkout_before_creating_it
test_sync_links_compat_to_physical_source_root
test_sync_refuses_runtime_env_symlink
test_no_install_does_not_create_default_install_dir
test_sync_force_stash_allows_dirty_main_repo

echo "PASS agent-stack tests"
