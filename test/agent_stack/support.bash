RUBY_BIN="${RUBY_BIN:-$(command -v ruby)}"
export RUBY_BIN
agent_stack_tmp_registry="$(mktemp)"

agent_stack_test_cleanup() {
  local temporary
  while IFS= read -r temporary; do
    [[ -z "$temporary" || ! -d "$temporary" ]] || rm -rf -- "$temporary"
  done < "$agent_stack_tmp_registry"
  rm -f "$agent_stack_tmp_registry"
}
trap agent_stack_test_cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "expected file: $1"; }
assert_executable() { [[ -x "$1" ]] || fail "expected executable: $1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain '$2', got: $1"; }
assert_mode() {
  "$RUBY_BIN" -e 'actual = File.stat(ARGV[0]).mode & 0o777; abort "expected mode #{ARGV[1]}, got #{actual.to_s(8)}" unless actual == ARGV[1].to_i(8)' "$1" "$2" || fail "unexpected mode: $1"
}

make_tmp_dir() {
  local temporary
  temporary="$(mktemp -d)"
  printf '%s\n' "$temporary" >> "$agent_stack_tmp_registry"
  printf '%s\n' "$temporary"
}

create_origin() {
  local temporary="$1"
  local name="$2"
  local work
  local origin
  work="$temporary/work/$name"
  origin="$temporary/origins/$name.git"
  mkdir -p "$work" "$temporary/origins"
  git -C "$work" init --quiet --initial-branch=main
  git -C "$work" config user.email agent-stack-test@example.com
  git -C "$work" config user.name "Agent Stack Test"
  printf '# %s\n' "$name" > "$work/README.md"

  if [[ "$name" = agent-workflows ]]; then
    mkdir -p "$work/bin/agent_stack" "$work/bin/agent_doctor"
    printf 'fixture\n' > "$work/bin/agent_stack/fixture.bash"
    printf '# fixture\n' > "$work/bin/agent_doctor/fixture.rb"
    printf '#!/usr/bin/env bash\necho synced agent-stack fixture\n' > "$work/bin/agent-stack"
    printf '#!/usr/bin/env ruby\nputs "synced doctor fixture"\n' > "$work/bin/agent-stack-doctor"
    cat > "$work/bin/install-agent-workflows" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
target=""
delivery_mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    --delivery-mode) delivery_mode="$2"; shift 2 ;;
    --host|--mode) shift 2 ;;
    *) shift ;;
  esac
done
: "${target:?missing --target}"
mkdir -p "$target/bin"
printf 'installed\n' > "$target/bin/agent-workflows-installed"
if [[ -z "$delivery_mode" && -f "$target/.agent-workflows-install.json" ]]; then
  delivery_mode="$("$RUBY_BIN" -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode", "flat")' "$target/.agent-workflows-install.json")"
fi
"$RUBY_BIN" -rjson -e 'File.write(ARGV[0], JSON.generate({"delivery_mode" => ARGV[1]}) + "\n")' \
  "$target/.agent-workflows-install.json" "${delivery_mode:-flat}"
BASH
    chmod +x "$work/bin/agent-stack" "$work/bin/agent-stack-doctor" "$work/bin/install-agent-workflows"
  elif [[ "$name" = agent-coordination ]]; then
    mkdir -p "$work/bin"
    cat > "$work/bin/agent-coord" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
install_dir="$HOME/.local/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in --install-dir) install_dir="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$install_dir"
printf '#!/usr/bin/env bash\necho agent-coord fixture\n' > "$install_dir/agent-coord"
chmod +x "$install_dir/agent-coord"
BASH
    chmod +x "$work/bin/agent-coord"
  fi
  git -C "$work" add .
  git -C "$work" commit --quiet -m "initial $name"
  git -C "$work" clone --quiet --bare . "$origin"
}

create_current_workflows_origin() {
  local temporary="$1"
  local work="$temporary/work/agent-workflows"
  local origin="$temporary/origins/agent-workflows.git"
  mkdir -p "$work" "$temporary/origins"
  git -C "$ROOT" ls-files -z | rsync -a --from0 --files-from=- "$ROOT/" "$work/"
  git -C "$work" init --quiet --initial-branch=main
  git -C "$work" config user.email agent-stack-test@example.com
  git -C "$work" config user.name "Agent Stack Test"
  git -C "$work" add .
  git -C "$work" commit --quiet -m "current agent-workflows"
  git -C "$work" clone --quiet --bare . "$origin"
}

with_origins() {
  local temporary="$1"
  create_origin "$temporary" agent-workflows
  create_origin "$temporary" agent-coordination
  create_origin "$temporary" agent-coordination-dashboard
}

with_current_workflows_origin() {
  local temporary="$1"
  create_current_workflows_origin "$temporary"
  create_origin "$temporary" agent-coordination
  create_origin "$temporary" agent-coordination-dashboard
}

run_sync() {
  local temporary="$1"
  shift
  AGENT_STACK_AGENT_WORKFLOWS_URL="$temporary/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$temporary/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$temporary/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync --source-root "$temporary/src" --compat-root "$temporary/compat" \
      --runtime-root "$temporary/runtime" "$@"
}
