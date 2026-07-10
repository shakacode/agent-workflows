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

  assert_file "$target/LICENSE"
  grep -q "MIT License" "$target/LICENSE" || fail "expected installed LICENSE to contain MIT notice"
  assert_file "$target/skills/pr-batch/SKILL.md"
  assert_file "$target/skills/pr-batch/agents/openai.yaml"
  assert_file "$target/workflows/pr-processing.md"
  assert_file "$target/docs/coordination-backend.md"
  assert_file "$target/docs/review-finding-schema.md"
  assert_file "$target/docs/agent-workflows-model-routing.md"
  assert_file "$target/docs/solutions/README.md"
  assert_file "$target/bin/agent-workflow-seam-doctor"
  assert_file "$target/bin/agent-workflows-status"
  assert_file "$target/bin/agent-workflows-trust-audit"
  [[ ! -e "$target/bin/agent-stack" ]] || fail "generic workflow install should not install stack-specific helper"
  assert_file "$target/bin/upgrade-agent-workflows"
  assert_file "$target/.agent-workflows-install.json"
  [[ ! -e "$target/.codex-plugin/plugin.json" ]] || fail "Codex native plugin manifest is source-pack metadata, not installer-managed install metadata"
  ruby -rjson -e 'metadata = JSON.parse(File.read(ARGV.fetch(0))); abort metadata.inspect unless metadata["host"] == "codex" && metadata["mode"] == "copy" && metadata["source_revision"].to_s.match?(/\A[0-9a-f]{40}\z/)' "$target/.agent-workflows-install.json"
}

test_install_namespaces_model_routing_doc_and_preserves_generic_collision() {
  local tmp target mode

  for mode in copy symlink; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    mkdir -p "$target/docs"
    printf 'personal model-routing notes\n' > "$target/docs/model-routing.md"

    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode "$mode" \
      >/tmp/install-agent-workflows-test.out

    grep -q 'personal model-routing notes' "$target/docs/model-routing.md" || \
      fail "$mode mode replaced unrelated docs/model-routing.md"
    if [[ "$mode" = "copy" ]]; then
      assert_file "$target/docs/agent-workflows-model-routing.md"
      [[ ! -L "$target/docs/agent-workflows-model-routing.md" ]] || \
        fail "copy mode should install the namespaced model-routing doc as a real file"
    else
      assert_symlink "$target/docs/agent-workflows-model-routing.md"
    fi
  done
}

test_install_removes_legacy_managed_model_routing_path() {
  local tmp target mode old_source revision

  revision="$(
    git -C "$ROOT" rev-list HEAD | while read -r candidate; do
      if git -C "$ROOT" cat-file -e "$candidate:docs/model-routing.md" 2>/dev/null; then
        printf '%s\n' "$candidate"
        break
      fi
    done
  )"
  [[ -n "$revision" ]] || fail "expected a historical docs/model-routing.md revision"

  for mode in copy symlink; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    old_source="$tmp/old-source"
    mkdir -p "$target/docs" "$old_source/docs"
    if [[ "$mode" = "copy" ]]; then
      git -C "$ROOT" show "$revision:docs/model-routing.md" > "$target/docs/model-routing.md"
    else
      ln -s "$old_source/docs/model-routing.md" "$target/docs/model-routing.md"
    fi
    ruby -rjson -e '
      path, mode, source, revision = ARGV
      File.write(path, JSON.pretty_generate({"mode" => mode, "source" => source, "source_revision" => revision}) + "\n")
    ' "$target/.agent-workflows-install.json" "$mode" "$old_source" "$revision"

    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode "$mode" \
      >/tmp/install-agent-workflows-test.out

    [[ ! -L "$target/docs/model-routing.md" ]] || \
      fail "$mode mode retained the legacy managed model-routing symlink"
    [[ ! -e "$target/docs/model-routing.md" ]] || \
      fail "$mode mode retained the legacy managed model-routing path"
    if [[ "$mode" = "copy" ]]; then
      assert_file "$target/docs/agent-workflows-model-routing.md"
    else
      assert_symlink "$target/docs/agent-workflows-model-routing.md"
    fi
  done
}

test_install_removes_legacy_copy_from_git_worktree_source() {
  local tmp clone_root worktree_root target revision

  revision="$(
    git -C "$ROOT" rev-list HEAD | while read -r candidate; do
      if git -C "$ROOT" cat-file -e "$candidate:docs/model-routing.md" 2>/dev/null; then
        printf '%s\n' "$candidate"
        break
      fi
    done
  )"
  [[ -n "$revision" ]] || fail "expected a historical docs/model-routing.md revision"

  tmp="$(mktemp -d)"
  clone_root="$tmp/source"
  worktree_root="$tmp/worktree"
  target="$tmp/codex-home"
  git clone --quiet "$ROOT" "$clone_root"
  install -m 0755 "$ROOT/bin/install-agent-workflows" "$clone_root/bin/install-agent-workflows"
  git -C "$clone_root" config user.email "agent-workflows-test@example.com"
  git -C "$clone_root" config user.name "Agent Workflows Test"
  if ! git -C "$clone_root" diff --quiet -- bin/install-agent-workflows; then
    git -C "$clone_root" add bin/install-agent-workflows
    git -C "$clone_root" commit --quiet -m "test worktree installer"
  fi
  git -C "$clone_root" worktree add --quiet --detach "$worktree_root" HEAD
  [[ -f "$worktree_root/.git" ]] || fail "expected linked worktree .git file"

  mkdir -p "$target/docs"
  git -C "$clone_root" show "$revision:docs/model-routing.md" > "$target/docs/model-routing.md"
  ruby -rjson -e '
    path, source, revision = ARGV
    File.write(path, JSON.pretty_generate({"mode" => "copy", "source" => source, "source_revision" => revision}) + "\n")
  ' "$target/.agent-workflows-install.json" "$worktree_root" "$revision"

  "$worktree_root/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    >/tmp/install-agent-workflows-test.out

  [[ ! -e "$target/docs/model-routing.md" ]] || \
    fail "copy mode retained the legacy managed model-routing path when installed from a git worktree"
  assert_file "$target/docs/agent-workflows-model-routing.md"
}

test_install_removes_matching_legacy_copy_from_non_git_source() {
  local tmp source target

  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source" "$target/docs"
  rsync -a --exclude .git "$ROOT/" "$source/"
  install -m 0644 "$source/docs/agent-workflows-model-routing.md" "$target/docs/model-routing.md"
  ruby -rjson -e '
    path, source = ARGV
    File.write(path, JSON.pretty_generate({"mode" => "copy", "source" => source, "source_revision" => "unknown"}) + "\n")
  ' "$target/.agent-workflows-install.json" "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    >/tmp/install-agent-workflows-test.out

  [[ ! -e "$target/docs/model-routing.md" ]] || \
    fail "copy mode retained a matching legacy model-routing file from a non-git source"
  assert_file "$target/docs/agent-workflows-model-routing.md"
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

  assert_file "$tmp/.claude/LICENSE"
  grep -q "MIT License" "$tmp/.claude/LICENSE" || fail "expected installed LICENSE to contain MIT notice"
  assert_file "$tmp/.claude/skills/pr-batch/SKILL.md"
  assert_file "$tmp/.claude/skills/pr-batch/agents/openai.yaml"
  assert_file "$tmp/.claude/workflows/pr-processing.md"
  assert_file "$tmp/.claude/docs/coordination-backend.md"
  assert_file "$tmp/.claude/docs/review-finding-schema.md"
  assert_file "$tmp/.claude/docs/agent-workflows-model-routing.md"
  assert_file "$tmp/.claude/docs/solutions/README.md"
  assert_file "$tmp/.claude/bin/agent-workflows-status"
  assert_file "$tmp/.claude/bin/agent-workflows-trust-audit"
  [[ ! -e "$tmp/.claude/bin/agent-stack" ]] || fail "generic workflow install should not install stack-specific helper"
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
  assert_file "$target/docs/coordination-backend.md"
  assert_file "$target/docs/review-finding-schema.md"
  assert_file "$target/docs/agent-workflows-model-routing.md"
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
  assert_file "$target/docs/coordination-backend.md"
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

  assert_symlink "$target/LICENSE"
  assert_symlink "$target/skills/pr-batch"
  assert_symlink "$target/workflows"
  assert_file "$target/docs/personal.md"
  assert_symlink "$target/docs/coordination-backend.md"
  assert_symlink "$target/docs/review-finding-schema.md"
  assert_symlink "$target/docs/agent-workflows-model-routing.md"
  [[ -d "$target/docs/solutions" && ! -L "$target/docs/solutions" ]] || fail "expected real docs/solutions directory"
  assert_symlink "$target/docs/solutions/README.md"
  assert_symlink "$target/bin/agent-workflow-seam-doctor"
  assert_symlink "$target/bin/agent-workflows-trust-audit"
  [[ ! -e "$target/bin/agent-stack" ]] || fail "generic workflow install should not symlink stack-specific helper"
  assert_file "$target/.agent-workflows-install.json"
}

test_symlink_mode_replaces_docs_directory_symlink() {
  local tmp target external_docs
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  external_docs="$tmp/external-docs"
  mkdir -p "$target" "$external_docs"
  ln -s "$external_docs" "$target/docs"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >/tmp/install-agent-workflows-test.out

  [[ -d "$target/docs" && ! -L "$target/docs" ]] || fail "expected real docs directory"
  assert_symlink "$target/docs/coordination-backend.md"
  assert_symlink "$target/docs/review-finding-schema.md"
  assert_symlink "$target/docs/agent-workflows-model-routing.md"
  [[ ! -e "$external_docs/coordination-backend.md" ]] || fail "should not write through pre-existing docs symlink"
  [[ ! -e "$external_docs/review-finding-schema.md" ]] || fail "should not write through pre-existing docs symlink"
  [[ ! -e "$external_docs/agent-workflows-model-routing.md" ]] || fail "should not write through pre-existing docs symlink"
}

test_copy_mode_after_symlink_mode_does_not_delete_source_docs() {
  local tmp target source_doc
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  source_doc="$ROOT/docs/solutions/README.md"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >/tmp/install-agent-workflows-test.out
  assert_symlink "$target/docs/coordination-backend.md"
  assert_symlink "$target/docs/solutions/README.md"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >/tmp/install-agent-workflows-test.out

  assert_file "$target/LICENSE"
  [[ ! -L "$target/LICENSE" ]] || fail "copy mode should replace pack LICENSE symlink with a real copy"
  assert_file "$source_doc"
  assert_file "$target/docs/coordination-backend.md"
  [[ ! -L "$target/docs/coordination-backend.md" ]] || fail "copy mode should replace pack doc symlink with a real copy"
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
    test_install_namespaces_model_routing_doc_and_preserves_generic_collision
    test_install_removes_legacy_managed_model_routing_path
    test_install_removes_legacy_copy_from_git_worktree_source
    test_install_removes_matching_legacy_copy_from_non_git_source
    test_installed_prompt_guard_ignores_unowned_docs
    test_claude_host_install_uses_claude_home_when_target_is_omitted
    test_copy_mode_preserves_unrelated_agent_files
    test_copy_mode_does_not_replace_generic_consumer_docs
    test_symlink_mode_links_skills_workflows_and_helpers
    test_symlink_mode_replaces_docs_directory_symlink
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
