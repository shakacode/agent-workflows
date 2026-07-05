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

assert_symlink() {
  [[ -L "$1" ]] || fail "expected symlink: $1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain '$needle', got: $haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain '$needle', got: $haystack"
}

new_source_repo() {
  local source_dir="$1"
  rsync -a --exclude .git "$ROOT/" "$source_dir/"
  git -C "$source_dir" init --quiet
  git -C "$source_dir" config user.email "agent-workflows-test@example.com"
  git -C "$source_dir" config user.name "Agent Workflows Test"
  git -C "$source_dir" add .
  git -C "$source_dir" commit --quiet -m "initial"
}

write_consumer_agents() {
  local root="$1"
  mkdir -p "$root/.agents/bin"
  cat > "$root/AGENTS.md" <<'AGENTS'
# AGENTS.md

## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.
AGENTS
  cat > "$root/.agents/agent-workflow.yml" <<'YAML'
---
base_branch: main
follow_up_prefix: "Follow-up:"
review_gate: "n/a"
approval_exempt: "docs"
coordination_backend: "n/a"
changelog: "n/a"
benchmark_labels: "n/a"
merge_ledger: "n/a"
ci_parity_environment: "n/a"
hosted_ci_trigger: "n/a"
ci_change_detector: "n/a"
YAML
  cat > "$root/.agents/bin/README.md" <<'MARKDOWN'
# Agent Workflow Scripts

| Script | Purpose | This repo runs |
| --- | --- | --- |
| `validate` | Pre-push gate | `.agents/bin/test` |
| `test` | Run tests | `true` |
MARKDOWN
  cat > "$root/.agents/bin/test" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec true
BASH
  cat > "$root/.agents/bin/validate" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
"$root/.agents/bin/test"
BASH
  chmod +x "$root/.agents/bin/test" "$root/.agents/bin/validate"
}

test_codex_host_install_writes_helpers_and_metadata() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >/tmp/install-agent-workflows-test.out

  assert_file "$target/skills/pr-batch/SKILL.md"
  assert_file "$target/skills/pr-batch/agents/openai.yaml"
  assert_file "$target/workflows/pr-processing.md"
  assert_file "$target/docs/review-finding-schema.md"
  assert_file "$target/docs/solutions/README.md"
  assert_file "$target/bin/agent-workflow-seam-doctor"
  assert_file "$target/bin/agent-workflows-status"
  assert_file "$target/bin/agent-workflows-trust-audit"
  assert_file "$target/bin/upgrade-agent-workflows"
  assert_file "$target/.agent-workflows-install.json"
  [[ ! -e "$target/.codex-plugin/plugin.json" ]] || fail "Codex native plugin manifest is source-pack metadata, not installer-managed install metadata"
  ruby -rjson -e 'metadata = JSON.parse(File.read(ARGV.fetch(0))); abort metadata.inspect unless metadata["host"] == "codex" && metadata["mode"] == "copy" && metadata["source_revision"].to_s.match?(/\A[0-9a-f]{40}\z/)' "$target/.agent-workflows-install.json"
}

test_installed_prompt_guard_ignores_unowned_docs() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >/tmp/install-agent-workflows-test.out
  mkdir -p "$target/docs"
  printf 'Unrelated local docs.\n' > "$target/docs/agent-runner-restarts.md"

  set +e
  output="$(ruby "$target/skills/plan-pr-batch/scripts/check_goal_prompt_size.rb" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "expected installed prompt guard to pass, got $status: $output"
  assert_contains "$output" "All checks passed."
}

test_claude_host_install_uses_claude_home_when_target_is_omitted() {
  local tmp
  tmp="$(mktemp -d)"

  CLAUDE_HOME="$tmp/.claude" "$ROOT/bin/install-agent-workflows" --host claude >/tmp/install-agent-workflows-test.out

  assert_file "$tmp/.claude/skills/pr-batch/SKILL.md"
  assert_file "$tmp/.claude/skills/pr-batch/agents/openai.yaml"
  assert_file "$tmp/.claude/workflows/pr-processing.md"
  assert_file "$tmp/.claude/docs/review-finding-schema.md"
  assert_file "$tmp/.claude/docs/solutions/README.md"
  assert_file "$tmp/.claude/bin/agent-workflows-status"
  assert_file "$tmp/.claude/bin/agent-workflows-trust-audit"
  [[ ! -e "$tmp/.claude/.codex-plugin/plugin.json" ]] || fail "Codex native plugin manifest must not be installed into Claude home metadata"
}

test_copy_mode_preserves_unrelated_agent_files() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target/skills/personal" "$target/workflows" "$target/docs" "$target/bin"
  printf 'personal skill\n' > "$target/skills/personal/SKILL.md"
  printf 'personal workflow\n' > "$target/workflows/personal.md"
  printf 'personal docs\n' > "$target/docs/personal.md"
  printf '#!/usr/bin/env bash\n' > "$target/bin/personal-helper"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >/tmp/install-agent-workflows-test.out

  assert_file "$target/skills/personal/SKILL.md"
  assert_file "$target/workflows/personal.md"
  assert_file "$target/docs/personal.md"
  assert_file "$target/docs/review-finding-schema.md"
  assert_file "$target/docs/solutions/README.md"
  assert_file "$target/bin/personal-helper"
  assert_file "$target/skills/pr-batch/SKILL.md"
}

test_copy_mode_does_not_replace_generic_consumer_docs() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target/docs/adr"
  printf 'consumer adoption docs\n' > "$target/docs/adoption.md"
  printf 'consumer architecture decision\n' > "$target/docs/adr/0001-consumer.md"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >/tmp/install-agent-workflows-test.out

  grep -q 'consumer adoption docs' "$target/docs/adoption.md" || fail "copy mode replaced consumer docs/adoption.md"
  grep -q 'consumer architecture decision' "$target/docs/adr/0001-consumer.md" || fail "copy mode replaced consumer docs/adr"
  assert_file "$target/docs/review-finding-schema.md"
  assert_file "$target/docs/solutions/README.md"
}

test_symlink_mode_links_skills_workflows_and_helpers() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target/docs"
  printf 'personal docs\n' > "$target/docs/personal.md"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >/tmp/install-agent-workflows-test.out

  assert_symlink "$target/skills/pr-batch"
  assert_symlink "$target/workflows"
  assert_file "$target/docs/personal.md"
  assert_symlink "$target/docs/review-finding-schema.md"
  [[ -d "$target/docs/solutions" && ! -L "$target/docs/solutions" ]] || fail "expected real docs/solutions directory"
  assert_symlink "$target/docs/solutions/README.md"
  assert_symlink "$target/bin/agent-workflow-seam-doctor"
  assert_symlink "$target/bin/agent-workflows-trust-audit"
  assert_file "$target/.agent-workflows-install.json"
}

test_copy_mode_after_symlink_mode_does_not_delete_source_docs() {
  local tmp target source_doc
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  source_doc="$ROOT/docs/solutions/README.md"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >/tmp/install-agent-workflows-test.out
  assert_symlink "$target/docs/solutions/README.md"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >/tmp/install-agent-workflows-test.out

  assert_file "$source_doc"
  assert_file "$target/docs/solutions/README.md"
  [[ ! -L "$target/docs/solutions/README.md" ]] || fail "copy mode should replace pack doc symlink with a real copy"
}

test_status_reports_not_installed_and_check_failed_explicitly() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/missing-home"

  set +e
  output="$("$ROOT/bin/agent-workflows-status" --target "$target" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "expected status exit 2, got $status: $output"
  assert_contains "$output" "NOT_INSTALLED"

  mkdir -p "$target"
  printf '{"source":"/definitely/missing","source_revision":"abc","version":"0"}\n' > "$target/.agent-workflows-install.json"
  set +e
  output="$("$ROOT/bin/agent-workflows-status" --target "$target" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || fail "expected status exit 3, got $status: $output"
  assert_contains "$output" "CHECK_FAILED"
  assert_not_contains "$output" "UP_TO_DATE"
}

test_status_reports_upgrade_available_between_source_commits() {
  local tmp source target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >/tmp/install-agent-workflows-test.out
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"

  set +e
  output="$("$source/bin/agent-workflows-status" --target "$target" --source "$source" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "expected status exit 1, got $status: $output"
  assert_contains "$output" "UPGRADE_AVAILABLE"
}

test_upgrade_reinstalls_new_source_revision() {
  local tmp source target output
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >/tmp/install-agent-workflows-test.out
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"

  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --no-fetch 2>&1)"

  assert_contains "$output" "UPGRADE_COMPLETE"
  output="$("$target/bin/agent-workflows-status" --target "$target" --source "$source" 2>&1)"
  assert_contains "$output" "UP_TO_DATE"
}

test_upgrade_without_consumer_roots_succeeds() {
  local tmp source target output
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >/tmp/install-agent-workflows-test.out
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"

  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --no-fetch 2>&1)"

  assert_contains "$output" "UPGRADE_COMPLETE"
  assert_not_contains "$output" "unbound variable"
}

test_upgrade_reports_missing_source_as_check_failed() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"

  set +e
  output="$("$ROOT/bin/upgrade-agent-workflows" --target "$target" --source "$tmp/missing-source" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 3 ]] || fail "expected upgrade exit 3, got $status: $output"
  assert_contains "$output" "CHECK_FAILED"
}

test_upgrade_rolls_back_when_consumer_seam_fails() {
  local tmp source target consumer before after output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  consumer="$tmp/consumer"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >/tmp/install-agent-workflows-test.out
  before="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' "$target/.agent-workflows-install.json")"
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"
  mkdir -p "$consumer"
  printf '# AGENTS.md\n\n## Commands\n' > "$consumer/AGENTS.md"

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --consumer-root "$consumer" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected upgrade failure"
  assert_contains "$output" "ROLLBACK_COMPLETE"
  after="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' "$target/.agent-workflows-install.json")"
  [[ "$before" == "$after" ]] || fail "expected rollback to $before, got $after"
}

test_upgrade_validates_consumer_root_after_install() {
  local tmp source target consumer output
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  consumer="$tmp/consumer"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >/tmp/install-agent-workflows-test.out
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"
  write_consumer_agents "$consumer"

  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --consumer-root "$consumer" --no-fetch 2>&1)"

  assert_contains "$output" "PASS agent workflow seam is complete"
  assert_contains "$output" "UPGRADE_COMPLETE"
}

main() {
  local tests=(
    test_codex_host_install_writes_helpers_and_metadata
    test_installed_prompt_guard_ignores_unowned_docs
    test_claude_host_install_uses_claude_home_when_target_is_omitted
    test_copy_mode_preserves_unrelated_agent_files
    test_copy_mode_does_not_replace_generic_consumer_docs
    test_symlink_mode_links_skills_workflows_and_helpers
    test_copy_mode_after_symlink_mode_does_not_delete_source_docs
    test_status_reports_not_installed_and_check_failed_explicitly
    test_status_reports_upgrade_available_between_source_commits
    test_upgrade_reinstalls_new_source_revision
    test_upgrade_without_consumer_roots_succeeds
    test_upgrade_reports_missing_source_as_check_failed
    test_upgrade_rolls_back_when_consumer_seam_fails
    test_upgrade_validates_consumer_root_after_install
  )

  local test_name
  for test_name in "${tests[@]}"; do
    "$test_name"
    echo "PASS $test_name"
  done
}

main "$@"
