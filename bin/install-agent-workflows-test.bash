#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_CODEX_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_CODEX_DIR"' EXIT
export AGENT_WORKFLOWS_CODEX_EXECUTABLE="$FAKE_CODEX_DIR/codex"
cat > "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" <<'RUBY'
#!/usr/bin/env ruby
abort "unexpected arguments: #{ARGV.inspect}" unless ARGV == %w[plugin list --marketplace agent-workflows]
case ENV.fetch("QA_CODEX_PLUGIN_STATE", "enabled")
when "enabled"
  puts "PLUGIN STATUS VERSION PATH"
  puts "scw@agent-workflows  installed, enabled  0.1.0  /fake/scw"
when "disabled"
  puts "PLUGIN STATUS VERSION PATH"
  puts "scw@agent-workflows  installed, disabled  0.1.0  /fake/scw"
else
  warn "invalid Codex TOML"
  exit 2
end
RUBY
chmod +x "$AGENT_WORKFLOWS_CODEX_EXECUTABLE"

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

write_native_scw_state() {
  local host="$1"
  local target="$2"
  local plugin_root="$target/plugins/cache/agent-workflows/scw/0.1.0"
  mkdir -p "$plugin_root/skills/example"
  printf 'example\n' > "$plugin_root/skills/example/SKILL.md"
  if [[ "$host" = "codex" ]]; then
    mkdir -p "$plugin_root/.codex-plugin"
    printf '[plugins."scw@agent-workflows"]\nenabled = true\n' > "$target/config.toml"
    printf '{"name":"scw","version":"0.1.0","skills":"./skills/"}\n' > "$plugin_root/.codex-plugin/plugin.json"
  else
    mkdir -p "$target/plugins" "$plugin_root/.claude-plugin"
    printf '{"enabledPlugins":{"scw@agent-workflows":true}}\n' > "$target/settings.json"
    ruby -rjson -e '
      path, plugin_root = ARGV
      File.write(path, JSON.generate({"version" => 2, "plugins" => {"scw@agent-workflows" => [{"scope" => "user", "installPath" => plugin_root, "version" => "0.1.0"}]}}) + "\n")
    ' "$target/plugins/installed_plugins.json" "$plugin_root"
    printf '{"name":"scw","version":"0.1.0","skills":"./skills/"}\n' > "$plugin_root/.claude-plugin/plugin.json"
  fi
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

new_source_repo_with_legacy_model_routing_history() {
  local source_dir="$1"

  new_source_repo "$source_dir"
  install -m 0644 "$source_dir/docs/agent-workflows-model-routing.md" \
    "$source_dir/docs/model-routing.md"
  git -C "$source_dir" add docs/model-routing.md
  git -C "$source_dir" commit --quiet -m "add legacy model-routing guide"
  git -C "$source_dir" rev-parse HEAD
  rm -f "$source_dir/docs/model-routing.md"
  git -C "$source_dir" add -u docs/model-routing.md
  git -C "$source_dir" commit --quiet -m "rename model-routing guide"
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

test_delivery_state_helper_unit_suite() {
  ruby "$ROOT/bin/agent-workflows-delivery-state-test.rb"
}

test_codex_host_install_writes_helpers_and_metadata() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install-agent-workflows-test.out"

  grep -Fq "agent-workflow-seam-doctor --init --root /path/to/consumer/repo --shared \"$ROOT\"" \
    "$tmp/install-agent-workflows-test.out" || fail "expected seam init output to validate the shared root"

  assert_file "$target/LICENSE"
  grep -q "MIT License" "$target/LICENSE" || fail "expected installed LICENSE to contain MIT notice"
  assert_file "$target/skills/pr-batch/SKILL.md"
  cmp -s "$target/skills/pr-batch/SKILL.md" "$ROOT/skills/pr-batch/SKILL.md" || \
    fail "Codex copy install must preserve byte-identical skill Markdown"
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
  [[ ! -e "$target/.agents/plugins/marketplace.json" ]] || fail "Codex marketplace metadata is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.claude-plugin/plugin.json" ]] || fail "Claude native plugin manifest is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.claude-plugin/marketplace.json" ]] || fail "Claude marketplace metadata is source-pack metadata, not installer-managed install metadata"
  ruby -rjson -e 'metadata = JSON.parse(File.read(ARGV.fetch(0))); abort metadata.inspect unless metadata["host"] == "codex" && metadata["mode"] == "copy" && metadata["source_revision"].to_s.match?(/\A[0-9a-f]{40}\z/)' "$target/.agent-workflows-install.json"
}

test_native_plugin_plus_default_flat_install_fails_before_mutation() {
  local tmp target host output status

  for host in codex claude; do
    tmp="$(mktemp -d)"
    target="$tmp/$host-home"
    write_native_scw_state "$host" "$target"

    set +e
    output="$("$ROOT/bin/install-agent-workflows" --host "$host" --target "$target" 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "$host native+flat install unexpectedly succeeded"
    assert_contains "$output" "DELIVERY_MODE_CONFLICT"
    assert_contains "$output" "--delivery-mode plugin-companion"
    [[ ! -e "$target/skills/pr-batch" ]] || fail "$host collision check mutated flat skills"
    [[ ! -e "$target/.agent-workflows-install.json" ]] || fail "$host collision check wrote metadata"
  done
}

test_plugin_companion_installs_non_skill_assets_and_records_mode() {
  local tmp target host

  for host in codex claude; do
    tmp="$(mktemp -d)"
    target="$tmp/$host-home"
    write_native_scw_state "$host" "$target"

    "$ROOT/bin/install-agent-workflows" --host "$host" --target "$target" --delivery-mode plugin-companion \
      >"$tmp/install.out"

    [[ ! -e "$target/skills/pr-batch" ]] || fail "$host companion install wrote flat skills"
    assert_file "$target/LICENSE"
    assert_file "$target/workflows/pr-processing.md"
    assert_file "$target/docs/coordination-backend.md"
    assert_file "$target/bin/agent-workflow-seam-doctor"
    assert_file "$target/bin/agent-workflows-status"
    assert_file "$target/bin/agent-workflows-delivery-state"
    ruby -rjson -e '
      metadata = JSON.parse(File.read(ARGV.fetch(0)))
      abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion" && metadata["mode"] == "copy"
    ' "$target/.agent-workflows-install.json"
  done
}

test_plugin_companion_refuses_unknown_direct_skill_and_preserves_all_skills() {
  local tmp target revision skill output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  revision="$(git -C "$ROOT" rev-parse HEAD)"
  write_native_scw_state codex "$target"
  mkdir -p "$target/skills/personal"
  printf 'personal\n' > "$target/skills/personal/SKILL.md"
  for skill in "$ROOT"/skills/*; do
    [[ -d "$skill" ]] || continue
    ln -s "$skill" "$target/skills/$(basename "$skill")"
  done
  ruby -rjson -e '
    path, source, revision = ARGV
    File.write(path, JSON.pretty_generate({"host" => "codex", "mode" => "symlink", "source" => source, "source_revision" => revision}) + "\n")
  ' "$target/.agent-workflows-install.json" "$ROOT" "$revision"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "unknown direct skill unexpectedly allowed migration"
  assert_contains "$output" "$target/skills/personal"
  for skill in "$ROOT"/skills/*; do
    [[ -d "$skill" ]] || continue
    assert_symlink "$target/skills/$(basename "$skill")"
  done
  assert_file "$target/skills/personal/SKILL.md"
}

test_direct_migration_does_not_remove_skills_before_other_install_checks_pass() {
  local tmp target revision
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  revision="$(git -C "$ROOT" rev-parse HEAD)"
  write_native_scw_state codex "$target"
  mkdir -p "$target/skills" "$target/bin/agent-workflow-seam-doctor"
  ln -s "$ROOT/skills/pr-batch" "$target/skills/pr-batch"
  ruby -rjson -e '
    path, source, revision = ARGV
    File.write(path, JSON.pretty_generate({"host" => "codex", "mode" => "symlink", "source" => source, "source_revision" => revision}) + "\n")
  ' "$target/.agent-workflows-install.json" "$ROOT" "$revision"

  set +e
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion \
    >"$tmp/install.out" 2>&1
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected non-skill collision to fail direct migration"
  assert_symlink "$target/skills/pr-batch"
}

test_metadata_temp_failure_preserves_flat_tree_and_prior_mode() {
  local tmp target output status skill
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  mkdir "$target/.agent-workflows-install.json.tmp"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "metadata temp collision unexpectedly allowed companion migration"
  for skill in "$ROOT"/skills/*; do
    [[ -d "$skill" ]] || continue
    assert_file "$target/skills/$(basename "$skill")/SKILL.md"
  done
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' \
    "$target/.agent-workflows-install.json"
}

test_staging_race_blocks_installer_and_preserves_flat_tree() {
  local tmp target injection output status skill
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  injection="$tmp/staging-race.rb"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  cat > "$injection" <<'RUBY'
require "fileutils"
class << File
  alias qa_original_rename rename
  def rename(source, destination)
    result = qa_original_rename(source, destination)
    unless defined?(@qa_race_injected) && @qa_race_injected
      @qa_race_injected = true
      raced = File.join(File.dirname(source), "raced-child")
      FileUtils.mkdir_p(raced)
      File.write(File.join(raced, "SKILL.md"), "raced\n")
    end
    result
  end
end
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "staging race unexpectedly allowed installer migration"
  assert_contains "$output" "raced-child"
  assert_file "$target/skills/raced-child/SKILL.md"
  for skill in "$ROOT"/skills/*; do
    [[ -d "$skill" ]] || continue
    assert_file "$target/skills/$(basename "$skill")/SKILL.md"
  done
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' \
    "$target/.agent-workflows-install.json"
}

test_final_verification_race_rolls_back_before_metadata_commit() {
  local tmp target injection counter output status skill
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  injection="$tmp/final-check-race.rb"
  counter="$tmp/check-count"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  cat > "$injection" <<'RUBY'
require "fileutils"
if ARGV.first == "check" && ENV["QA_CHECK_COUNTER"]
  counter = ENV.fetch("QA_CHECK_COUNTER")
  count = File.file?(counter) ? File.read(counter).to_i + 1 : 1
  File.write(counter, count.to_s)
  if count == 3
    target = ARGV[ARGV.index("--target") + 1]
    raced = File.join(target, "skills/final-raced-child")
    FileUtils.mkdir_p(raced)
    File.write(File.join(raced, "SKILL.md"), "raced\n")
  end
end
RUBY

  set +e
  output="$(QA_CHECK_COUNTER="$counter" RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "final-check race unexpectedly committed migration"
  assert_contains "$output" "final delivery verification failed"
  assert_file "$target/skills/final-raced-child/SKILL.md"
  for skill in "$ROOT"/skills/*; do
    [[ -d "$skill" ]] || continue
    assert_file "$target/skills/$(basename "$skill")/SKILL.md"
  done
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' \
    "$target/.agent-workflows-install.json"
}

test_staging_json_extraction_failure_uses_receipt_to_roll_back() {
  local tmp target injection output status skill
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  injection="$tmp/json-extraction-failure.rb"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  cat > "$injection" <<'RUBY'
require "json"
module FailStagingJsonExtraction
  def parse(source, *args)
    exit 86 if source.is_a?(String) && source.include?('"staging"')
    super
  end
end
JSON.singleton_class.prepend(FailStagingJsonExtraction)
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "staging JSON extraction failure unexpectedly committed migration"
  for skill in "$ROOT"/skills/*; do
    [[ -d "$skill" ]] || continue
    assert_file "$target/skills/$(basename "$skill")/SKILL.md"
  done
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' \
    "$target/.agent-workflows-install.json"
  [[ ! -e "$target/.agent-workflows-migration-staging" ]] || fail "staging receipt was not removed"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "install lock was not removed"
  if compgen -G "$target/.agent-workflows-flat-migration-*" >/dev/null; then
    fail "orphaned migration quarantine"
  fi
}

test_failed_partial_rollback_preserves_receipt_for_retry() {
  local tmp target injection output status receipt staging retry_output retry_status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  injection="$tmp/rollback-collision.rb"
  receipt="$target/.agent-workflows-migration-staging"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  cat > "$injection" <<'RUBY'
require "fileutils"
require "json"
module InjectRollbackCollision
  def parse(source, *args)
    payload = super
    if source.is_a?(String) && payload.is_a?(Hash) && payload.dig("flat", "staging")
      collision = payload.dig("flat", "removed").sort.first
      FileUtils.mkdir_p(collision)
      File.write(File.join(collision, "SKILL.md"), "concurrent collision\n")
      exit 86
    end
    payload
  end
end
JSON.singleton_class.prepend(InjectRollbackCollision)
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "rollback collision unexpectedly committed migration"
  assert_file "$receipt"
  staging="$(head -1 "$receipt")"
  [[ -d "$staging" ]] || fail "remaining quarantine is not referenced by receipt"
  assert_contains "$output" "ROLLBACK_FAILED"

  set +e
  retry_output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  retry_status=$?
  set -e
  [[ "$retry_status" -ne 0 ]] || fail "retry ignored unresolved rollback collision"
  assert_contains "$retry_output" "RECOVERY_FAILED"
  assert_file "$receipt"
  [[ -d "$staging" ]] || fail "retry lost remaining quarantine"
}

test_crash_receipt_recovers_flat_staging_before_new_install() {
  local tmp target staging output status skill
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-crash"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  mkdir -p "$staging"
  for skill in "$target"/skills/*; do mv "$skill" "$staging/"; done
  printf '%s\n' "$staging" > "$target/.agent-workflows-migration-staging"
  mkdir "$target/.agent-workflows-install.json.tmp"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "metadata preflight unexpectedly succeeded"
  for skill in "$ROOT"/skills/*; do
    [[ -d "$skill" ]] || continue
    assert_file "$target/skills/$(basename "$skill")/SKILL.md"
  done
  [[ ! -e "$staging" ]] || fail "recovered flat staging remains"
  [[ ! -e "$target/.agent-workflows-migration-staging" ]] || fail "recovered receipt remains"
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' \
    "$target/.agent-workflows-install.json"
}

test_crash_receipt_cleans_committed_companion_quarantine_without_restoring_flat() {
  local tmp target staging
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-crash"
  write_native_scw_state codex "$target"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion >"$tmp/companion.out"
  mkdir -p "$staging/pr-batch"
  printf 'quarantined\n' > "$staging/pr-batch/SKILL.md"
  printf '%s\n' "$staging" > "$target/.agent-workflows-migration-staging"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion >"$tmp/recover.out"

  [[ ! -e "$staging" ]] || fail "committed quarantine was not cleaned"
  [[ ! -e "$target/.agent-workflows-migration-staging" ]] || fail "committed receipt remains"
  [[ ! -e "$target/skills/pr-batch" ]] || fail "committed companion recovery restored flat skills"
}

test_flat_crash_recovery_rejects_symlink_staging_without_touching_outside_data() {
  local tmp target outside staging metadata_before output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  outside="$tmp/outside"
  staging="$target/.agent-workflows-flat-migration-evil"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  mkdir -p "$outside"
  printf 'outside sentinel\n' > "$outside/SKILL.md"
  ln -s "$outside" "$staging"
  printf '%s\n' "$staging" > "$target/.agent-workflows-migration-staging"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "flat recovery followed a symlink staging receipt"
  assert_contains "$output" "unsafe migration staging receipt"
  assert_file "$outside/SKILL.md"
  assert_symlink "$staging"
  assert_file "$target/.agent-workflows-migration-staging"
  [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || fail "unsafe recovery mutated metadata"
  assert_file "$target/skills/pr-batch/SKILL.md"
}

test_flat_crash_recovery_rejects_symlink_skills_root_before_move() {
  local tmp target outside staging output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  outside="$tmp/outside"
  staging="$target/.agent-workflows-flat-migration-crash"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  mkdir -p "$staging" "$outside"
  for skill in "$target"/skills/*; do mv "$skill" "$staging/"; done
  rmdir "$target/skills"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  ln -s "$outside" "$target/skills"
  printf '%s\n' "$staging" > "$target/.agent-workflows-migration-staging"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "recovery followed symlinked skills root"
  assert_contains "$output" "ROLLBACK_FAILED"
  assert_file "$outside/SENTINEL"
  [[ ! -e "$outside/pr-batch" ]] || fail "recovery moved a skill through outside symlink"
  assert_symlink "$target/skills"
  assert_file "$target/.agent-workflows-migration-staging"
  [[ -d "$staging" ]] || fail "unsafe rollback lost quarantine"
}

test_companion_crash_cleanup_rejects_symlink_staging_without_touching_outside_data() {
  local tmp target outside staging metadata_before output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  outside="$tmp/outside"
  staging="$target/.agent-workflows-flat-migration-evil"
  write_native_scw_state codex "$target"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion >"$tmp/companion.out"
  mkdir -p "$outside"
  printf 'outside sentinel\n' > "$outside/SKILL.md"
  ln -s "$outside" "$staging"
  printf '%s\n' "$staging" > "$target/.agent-workflows-migration-staging"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "companion cleanup accepted a symlink staging receipt"
  assert_contains "$output" "unsafe migration staging receipt"
  assert_file "$outside/SKILL.md"
  assert_symlink "$staging"
  assert_file "$target/.agent-workflows-migration-staging"
  [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || fail "unsafe cleanup mutated metadata"
  [[ ! -e "$target/skills/pr-batch" ]] || fail "unsafe cleanup introduced flat skills"
}

test_install_lock_blocks_concurrent_migration_before_mutation() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  write_native_scw_state codex "$target"
  mkdir "$target/.agent-workflows-install.lock"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "held install lock unexpectedly allowed migration"
  assert_contains "$output" "another agent-workflows install or migration holds"
  assert_file "$target/skills/pr-batch/SKILL.md"
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' \
    "$target/.agent-workflows-install.json"
}

test_repeat_install_replays_recorded_companion_delivery_mode() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  write_native_scw_state codex "$target"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion \
    >"$tmp/first.out"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/second.out"

  [[ ! -e "$target/skills/pr-batch" ]] || fail "repeat install changed companion delivery mode"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion"
  ' "$target/.agent-workflows-install.json"
}

test_companion_to_flat_refuses_unowned_same_named_skill() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  write_native_scw_state codex "$target"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion \
    >"$tmp/companion.out"
  printf '[plugins."scw@agent-workflows"]\nenabled = false\n' > "$target/config.toml"
  mkdir -p "$target/skills/pr-batch"
  printf 'user-owned replacement\n' > "$target/skills/pr-batch/SKILL.md"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "companion-to-flat transition replaced an unowned same-named skill"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  grep -q 'user-owned replacement' "$target/skills/pr-batch/SKILL.md" || fail "unowned same-named skill was not preserved"
}

test_auto_host_with_explicit_target_resolves_the_detected_host() {
  local tmp target claude_target ruby_dir
  tmp="$(mktemp -d)"
  target="$tmp/unrelated-empty-target"
  claude_target="$tmp/claude-home"
  ruby_dir="$(ruby -rrbconfig -e 'puts File.dirname(RbConfig.ruby)')"
  mkdir -p "$tmp/codex-home" "$claude_target"

  HOME="$tmp/home" CODEX_HOME="$tmp/codex-home" CLAUDE_HOME="$claude_target" PATH="$ruby_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/install-agent-workflows" --host auto --target "$target" >"$tmp/install.out"

  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["host"] == "codex"
  ' "$target/.agent-workflows-install.json"

  HOME="$tmp/home" CODEX_HOME="$tmp/codex-home" CLAUDE_HOME="$claude_target" PATH="$ruby_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/agent-workflows-status" --host auto --target "$target" --source "$ROOT" >/dev/null
  HOME="$tmp/home" CODEX_HOME="$tmp/codex-home" CLAUDE_HOME="$claude_target" PATH="$ruby_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/upgrade-agent-workflows" --host auto --target "$target" --source "$ROOT" --dry-run --no-fetch >/dev/null

  HOME="$tmp/home" CODEX_HOME="$tmp/codex-home" CLAUDE_HOME="$claude_target" PATH="$ruby_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/install-agent-workflows" --host auto --target "$claude_target/" >"$tmp/install-claude.out"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["host"] == "claude"
  ' "$claude_target/.agent-workflows-install.json"
  HOME="$tmp/home" CODEX_HOME="$tmp/codex-home" CLAUDE_HOME="$claude_target" PATH="$ruby_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/agent-workflows-status" --host auto --target "$claude_target/" --source "$ROOT" >/dev/null
  HOME="$tmp/home" CODEX_HOME="$tmp/codex-home" CLAUDE_HOME="$claude_target" PATH="$ruby_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/upgrade-agent-workflows" --host auto --target "$claude_target/" --source "$ROOT" --dry-run --no-fetch >/dev/null
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

test_install_preserves_exact_content_generic_collision_without_source_evidence() {
  local tmp target mode missing_source

  for mode in copy symlink; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    missing_source="$tmp/missing-source"
    mkdir -p "$target/docs"
    install -m 0644 "$ROOT/docs/agent-workflows-model-routing.md" "$target/docs/model-routing.md"
    ruby -rjson -e '
      path, source = ARGV
      File.write(path, JSON.pretty_generate({"mode" => "copy", "source" => source, "source_revision" => "unknown"}) + "\n")
    ' "$target/.agent-workflows-install.json" "$missing_source"

    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode "$mode" \
      >/tmp/install-agent-workflows-test.out

    cmp -s "$target/docs/model-routing.md" "$ROOT/docs/agent-workflows-model-routing.md" || \
      fail "$mode mode removed an exact-content generic collision without prior-source evidence"
  done
}

test_install_removes_legacy_managed_model_routing_path() {
  local tmp target mode source revision

  for mode in copy symlink; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    source="$tmp/source"
    mkdir -p "$source" "$target/docs"
    revision="$(new_source_repo_with_legacy_model_routing_history "$source")"
    if [[ "$mode" = "copy" ]]; then
      git -C "$source" show "$revision:docs/model-routing.md" > "$target/docs/model-routing.md"
    else
      ln -s "$source/docs/model-routing.md" "$target/docs/model-routing.md"
    fi
    ruby -rjson -e '
      path, mode, source, revision = ARGV
      File.write(path, JSON.pretty_generate({"mode" => mode, "source" => source, "source_revision" => revision}) + "\n")
    ' "$target/.agent-workflows-install.json" "$mode" "$source" "$revision"

    "$source/bin/install-agent-workflows" --host codex --target "$target" --mode "$mode" \
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
  local tmp source worktree_root target revision

  tmp="$(mktemp -d)"
  source="$tmp/source"
  worktree_root="$tmp/worktree"
  target="$tmp/codex-home"
  mkdir -p "$source"
  revision="$(new_source_repo_with_legacy_model_routing_history "$source")"
  git -C "$source" worktree add --quiet --detach "$worktree_root" HEAD
  [[ -f "$worktree_root/.git" ]] || fail "expected linked worktree .git file"

  mkdir -p "$target/docs"
  git -C "$source" show "$revision:docs/model-routing.md" > "$target/docs/model-routing.md"
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
  local tmp current_source previous_source target

  tmp="$(mktemp -d)"
  current_source="$tmp/current-source"
  previous_source="$tmp/previous-source"
  target="$tmp/codex-home"
  mkdir -p "$current_source" "$previous_source/docs" "$target/docs"
  rsync -a --exclude .git "$ROOT/" "$current_source/"
  printf 'legacy unpacked model-routing guide\n' > "$previous_source/docs/model-routing.md"
  install -m 0644 "$previous_source/docs/model-routing.md" "$target/docs/model-routing.md"
  ruby -rjson -e '
    path, source = ARGV
    File.write(path, JSON.pretty_generate({"mode" => "copy", "source" => source, "source_revision" => "unknown"}) + "\n")
  ' "$target/.agent-workflows-install.json" "$previous_source"

  "$current_source/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    >/tmp/install-agent-workflows-test.out

  [[ ! -e "$target/docs/model-routing.md" ]] || \
    fail "copy mode retained a matching legacy model-routing file from a non-git source"
  assert_file "$target/docs/agent-workflows-model-routing.md"
}

test_installed_prompt_guard_ignores_unowned_docs() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install-agent-workflows-test.out"
  mkdir -p "$target/docs"
  printf 'Unrelated local docs.\n' > "$target/docs/agent-runner-restarts.md"

  set +e
  output="$(ruby "$target/skills/plan-pr-batch/scripts/check_goal_prompt_size.rb" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "expected installed prompt guard to pass, got $status: $output"
  assert_contains "$output" "All checks passed."
}

test_installed_doctor_initializes_consumer_repo() {
  local tmp target consumer output
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  consumer="$tmp/consumer"
  mkdir -p "$consumer"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install-agent-workflows-test.out"
  output="$("$target/bin/agent-workflow-seam-doctor" \
    --init \
    --root "$consumer" \
    --validate-command true \
    --test-command true 2>&1)"

  assert_contains "$output" "PASS agent workflow seam is complete"
  assert_file "$consumer/.agents/bin/validate"
  assert_file "$consumer/.agents/bin/test"
  assert_file "$consumer/.agents/agent-workflow.yml"
  assert_file "$consumer/.agents/trusted-github-actors.yml"
  assert_file "$consumer/AGENTS.md"
}

test_claude_host_install_uses_claude_home_when_target_is_omitted() {
  local tmp
  tmp="$(mktemp -d)"

  CLAUDE_HOME="$tmp/.claude" "$ROOT/bin/install-agent-workflows" --host claude >"$tmp/install-agent-workflows-test.out"

  assert_file "$tmp/.claude/LICENSE"
  grep -q "MIT License" "$tmp/.claude/LICENSE" || fail "expected installed LICENSE to contain MIT notice"
  assert_file "$tmp/.claude/skills/pr-batch/SKILL.md"
  cmp -s "$tmp/.claude/skills/pr-batch/SKILL.md" "$ROOT/skills/pr-batch/SKILL.md" || \
    fail "Claude copy install must preserve byte-identical skill Markdown"
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
  [[ ! -e "$tmp/.claude/.agents/plugins/marketplace.json" ]] || fail "Codex marketplace metadata must not be installed into Claude home metadata"
  [[ ! -e "$tmp/.claude/.claude-plugin/plugin.json" ]] || fail "Claude native plugin manifest must not be copied into the flat Claude home"
  [[ ! -e "$tmp/.claude/.claude-plugin/marketplace.json" ]] || fail "Claude marketplace metadata must not be copied into the flat Claude home"
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

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install-agent-workflows-test.out"

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

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install-agent-workflows-test.out"

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

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >"$tmp/install-agent-workflows-test.out"

  assert_symlink "$target/LICENSE"
  assert_symlink "$target/skills/pr-batch"
  cmp -s "$target/skills/pr-batch/SKILL.md" "$ROOT/skills/pr-batch/SKILL.md" || \
    fail "symlink install must preserve byte-identical skill Markdown"
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

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >"$tmp/install-agent-workflows-test.out"

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

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >"$tmp/install-agent-workflows-test.out"
  assert_symlink "$target/docs/coordination-backend.md"
  assert_symlink "$target/docs/solutions/README.md"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install-agent-workflows-test.out"

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

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install-agent-workflows-test.out"
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"

  set +e
  output="$("$source/bin/agent-workflows-status" --target "$target" --source "$source" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "expected status exit 1, got $status: $output"
  assert_contains "$output" "UPGRADE_AVAILABLE"
  assert_contains "$output" "delivery_mode=flat"
}

test_upgrade_reinstalls_new_source_revision() {
  local tmp source target output
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install-agent-workflows-test.out"
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"

  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --no-fetch 2>&1)"

  assert_contains "$output" "UPGRADE_COMPLETE"
  output="$("$target/bin/agent-workflows-status" --target "$target" --source "$source" 2>&1)"
  assert_contains "$output" "UP_TO_DATE"
}

test_upgrade_can_select_and_then_replay_companion_delivery_mode() {
  local tmp source target
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"
  write_native_scw_state codex "$target"
  "$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --delivery-mode plugin-companion --no-fetch >"$tmp/upgrade-one.out"
  "$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --no-fetch >"$tmp/upgrade-two.out"

  [[ ! -e "$target/skills/pr-batch" ]] || fail "upgrade did not preserve companion delivery mode"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion"
  ' "$target/.agent-workflows-install.json"
}

test_upgrade_without_consumer_roots_succeeds() {
  local tmp source target output
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install-agent-workflows-test.out"
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

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install-agent-workflows-test.out"
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

test_failed_upgrade_restores_companion_delivery_mode_and_layout() {
  local tmp source target consumer output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  consumer="$tmp/consumer"
  mkdir -p "$source" "$consumer"
  new_source_repo "$source"
  write_native_scw_state codex "$target"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion \
    >"$tmp/install.out"
  printf '0.1.1\n' > "$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"
  printf '# incomplete seam\n' > "$consumer/AGENTS.md"

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --consumer-root "$consumer" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected companion upgrade failure"
  assert_contains "$output" "ROLLBACK_COMPLETE"
  [[ ! -e "$target/skills/pr-batch" ]] || fail "rollback introduced flat skills into companion layout"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion"
  ' "$target/.agent-workflows-install.json"
}

test_upgrade_validates_consumer_root_after_install() {
  local tmp source target consumer output
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  consumer="$tmp/consumer"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install-agent-workflows-test.out"
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
    test_delivery_state_helper_unit_suite
    test_native_plugin_plus_default_flat_install_fails_before_mutation
    test_plugin_companion_installs_non_skill_assets_and_records_mode
    test_plugin_companion_refuses_unknown_direct_skill_and_preserves_all_skills
    test_direct_migration_does_not_remove_skills_before_other_install_checks_pass
    test_metadata_temp_failure_preserves_flat_tree_and_prior_mode
    test_staging_race_blocks_installer_and_preserves_flat_tree
    test_final_verification_race_rolls_back_before_metadata_commit
    test_staging_json_extraction_failure_uses_receipt_to_roll_back
    test_failed_partial_rollback_preserves_receipt_for_retry
    test_crash_receipt_recovers_flat_staging_before_new_install
    test_crash_receipt_cleans_committed_companion_quarantine_without_restoring_flat
    test_flat_crash_recovery_rejects_symlink_staging_without_touching_outside_data
    test_flat_crash_recovery_rejects_symlink_skills_root_before_move
    test_companion_crash_cleanup_rejects_symlink_staging_without_touching_outside_data
    test_install_lock_blocks_concurrent_migration_before_mutation
    test_repeat_install_replays_recorded_companion_delivery_mode
    test_companion_to_flat_refuses_unowned_same_named_skill
    test_auto_host_with_explicit_target_resolves_the_detected_host
    test_codex_host_install_writes_helpers_and_metadata
    test_install_namespaces_model_routing_doc_and_preserves_generic_collision
    test_install_preserves_exact_content_generic_collision_without_source_evidence
    test_install_removes_legacy_managed_model_routing_path
    test_install_removes_legacy_copy_from_git_worktree_source
    test_install_removes_matching_legacy_copy_from_non_git_source
    test_installed_prompt_guard_ignores_unowned_docs
    test_installed_doctor_initializes_consumer_repo
    test_claude_host_install_uses_claude_home_when_target_is_omitted
    test_copy_mode_preserves_unrelated_agent_files
    test_copy_mode_does_not_replace_generic_consumer_docs
    test_symlink_mode_links_skills_workflows_and_helpers
    test_symlink_mode_replaces_docs_directory_symlink
    test_copy_mode_after_symlink_mode_does_not_delete_source_docs
    test_status_reports_not_installed_and_check_failed_explicitly
    test_status_reports_upgrade_available_between_source_commits
    test_upgrade_reinstalls_new_source_revision
    test_upgrade_can_select_and_then_replay_companion_delivery_mode
    test_upgrade_without_consumer_roots_succeeds
    test_upgrade_reports_missing_source_as_check_failed
    test_upgrade_rolls_back_when_consumer_seam_fails
    test_failed_upgrade_restores_companion_delivery_mode_and_layout
    test_upgrade_validates_consumer_root_after_install
  )

  local test_name
  for test_name in "${tests[@]}"; do
    "$test_name"
    echo "PASS $test_name"
  done
}

main "$@"
