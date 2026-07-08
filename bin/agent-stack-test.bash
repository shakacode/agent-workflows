#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  local tmp source_root compat_root runtime_root target install_dir
  tmp="$(mktemp -d)"
  source_root="$tmp/src"
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
  [[ ! -e "$install_dir/agent_coord" ]] || fail "legacy agent_coord alias should be removed"
  assert_symlink_to "$compat_root/agent-workflows" "$source_root/agent-workflows"
  assert_symlink_to "$compat_root/agent-coordination" "$source_root/agent-coordination"
  assert_symlink_to "$compat_root/agent-coordination-dashboard" "$source_root/agent-coordination-dashboard"
  [[ -d "$runtime_root/cache" ]] || fail "expected runtime cache directory"
  [[ -d "$runtime_root/logs" ]] || fail "expected runtime logs directory"
  [[ -d "$runtime_root/state" ]] || fail "expected runtime state directory"
  assert_file "$runtime_root/env"
}

test_sync_refuses_dirty_repo_without_force_stash() {
  local tmp source_root output status
  tmp="$(mktemp -d)"
  source_root="$tmp/src"
  with_origins "$tmp"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$source_root/agent-workflows"
  printf 'dirty\n' >> "$source_root/agent-workflows/README.md"

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync --source-root "$source_root" --compat-root "$tmp/compat" --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected dirty repo sync to fail"
  assert_contains "$output" "dirty worktree"
}

test_sync_refuses_non_main_repo() {
  local tmp source_root output status
  tmp="$(mktemp -d)"
  source_root="$tmp/src"
  with_origins "$tmp"

  git clone --quiet "$tmp/origins/agent-workflows.git" "$source_root/agent-workflows"
  git -C "$source_root/agent-workflows" switch --quiet -c feature/local-work

  set +e
  output="$(
    AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" sync --source-root "$source_root" --compat-root "$tmp/compat" --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected non-main repo sync to fail"
  assert_contains "$output" "not on main"
}

test_sync_force_stash_allows_dirty_main_repo() {
  local tmp source_root
  tmp="$(mktemp -d)"
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
      --no-install \
      --force-stash >/tmp/agent-stack-test.out

  git -C "$source_root/agent-workflows" diff --quiet || fail "expected dirty changes to be stashed"
  git -C "$source_root/agent-workflows" stash list | grep -q "agent-stack-sync-" || fail "expected agent-stack stash"
}

test_sync_clones_installs_and_links_the_stack
test_sync_refuses_dirty_repo_without_force_stash
test_sync_refuses_non_main_repo
test_sync_force_stash_allows_dirty_main_repo

echo "PASS agent-stack tests"
