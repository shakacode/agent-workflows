#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_CODEX_DIR="$(mktemp -d)"
TEST_SOURCE_ROOT=""
cleanup() {
  rm -rf "$FAKE_CODEX_DIR"
  [[ -z "$TEST_SOURCE_ROOT" ]] || rm -rf "$TEST_SOURCE_ROOT"
}
trap cleanup EXIT
export AGENT_WORKFLOWS_CODEX_EXECUTABLE="$FAKE_CODEX_DIR/codex"
cat > "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" <<'RUBY'
#!/usr/bin/env ruby
abort "unexpected arguments: #{ARGV.inspect}" unless ARGV == %w[plugin list --marketplace agent-workflows]
case ENV.fetch("QA_CODEX_PLUGIN_STATE", "enabled")
when "enabled"
  version = ENV.fetch("QA_CODEX_PLUGIN_VERSION", "0.1.0")
  source = ENV.fetch("QA_CODEX_PLUGIN_SOURCE", "https://github.com/shakacode/agent-workflows.git")
  puts "PLUGIN STATUS VERSION PATH"
  puts "scw@agent-workflows  installed, enabled  #{version}  #{source}"
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

assert_unsigned_launch_helpers() {
  local target="$1"
  local label="$2"
  local dispatch_output batch_output

  assert_file "$target/skills/pr-batch/bin/dispatcher-capability-preflight"
  assert_file "$target/skills/pr-batch/fixtures/unsigned-dispatch-smoke.json"
  assert_file "$target/skills/plan-pr-batch/bin/batch-plan-preflight"
  assert_file "$target/skills/plan-pr-batch/fixtures/unsigned-lifecycle-smoke.json"
  [[ -z "$(find "$target" -type f \( -name 'dispatcher-launch-trust.json' -o -name 'workflow-control-lifecycle-trust.json' \) -print -quit)" ]] || \
    fail "$label clean install generated a launch trust anchor"

  dispatch_output="$("$target/skills/pr-batch/bin/dispatcher-capability-preflight" \
    < "$target/skills/pr-batch/fixtures/unsigned-dispatch-smoke.json")"
  ruby -rjson -e '
    result = JSON.parse(ARGV.fetch(0))
    abort result.inspect unless result["status"] == "selected" &&
                                result.dig("dispatch", "lifecycle") == "launch-pending"
  ' "$dispatch_output" || fail "$label clean install could not select an unsigned assignment"

  batch_output="$("$target/skills/plan-pr-batch/bin/batch-plan-preflight" \
    < "$target/skills/plan-pr-batch/fixtures/unsigned-lifecycle-smoke.json")"
  ruby -rjson -e '
    result = JSON.parse(ARGV.fetch(0))
    abort result.inspect unless result["status"] == "accepted" &&
                                result.dig("launch", "eligible_lane_ids") == ["install-smoke"]
  ' "$batch_output" || fail "$label clean install could not accept unsigned lifecycle state"
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
    printf '{"name":"scw","version":"0.1.0","repository":"https://github.com/shakacode/agent-workflows","skills":"./skills/"}\n' \
      > "$plugin_root/.codex-plugin/plugin.json"
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
  assert_file "$target/docs/execution-provenance-schema.md"
  assert_file "$target/docs/review-finding-schema.md"
  assert_file "$target/docs/agent-workflows-model-routing.md"
  assert_file "$target/docs/user-facing-coordination.md"
  assert_file "$target/docs/solutions/README.md"
  assert_file "$target/bin/agent-workflow-seam-doctor"
  assert_file "$target/bin/validate-execution-provenance"
  "$target/bin/validate-execution-provenance" >"$tmp/validate-execution-provenance.out"
  grep -Fqx 'PASS execution provenance schema' "$tmp/validate-execution-provenance.out" || \
    fail "Codex copy install could not validate its installed provenance schema guide"
  assert_file "$target/bin/agent-workflows-status"
  assert_file "$target/bin/agent-workflows-doctor"
  assert_file "$target/bin/agent_doctor/process_runner.rb"
  assert_file "$target/bin/agent_doctor/timeout_budget.rb"
  assert_file "$target/bin/agent_doctor/workflows_cli.rb"
  grep -Eq '^agent-workflows-doctor-v1:[0-9a-f]{64}$' "$target/bin/agent_doctor/.agent-workflows-managed" || \
    fail "Codex copy install did not mark its doctor directory"
  ruby "$ROOT/bin/agent_doctor/install_ownership.rb" verify \
    "$target/bin/agent_doctor" "$target/bin/agent_doctor/.agent-workflows-managed" || \
    fail "Codex copy install wrote an invalid doctor ownership marker"
  assert_file "$target/bin/agent-workflows-trust-audit"
  [[ ! -e "$target/bin/agent-stack" ]] || fail "generic workflow install should not install stack-specific helper"
  assert_file "$target/bin/upgrade-agent-workflows"
  assert_file "$target/.agent-workflows-install.json"
  assert_unsigned_launch_helpers "$target" "Codex"
  [[ ! -e "$target/.codex-plugin/plugin.json" ]] || fail "Codex native plugin manifest is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.agents/plugins/marketplace.json" ]] || fail "Codex marketplace metadata is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.claude-plugin/plugin.json" ]] || fail "Claude native plugin manifest is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.claude-plugin/marketplace.json" ]] || fail "Claude marketplace metadata is source-pack metadata, not installer-managed install metadata"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    provenance_fingerprint = metadata.fetch("managed_pack_doc_copy_fingerprints")["execution-provenance-schema.md"]
    abort metadata.inspect unless metadata["host"] == "codex" &&
                                  metadata["mode"] == "copy" &&
                                  metadata["delivery_mode"] == "flat" &&
                                  metadata["source_revision"].to_s.match?(/\A[0-9a-f]{40}\z/) &&
                                  provenance_fingerprint.to_s.match?(/\A[0-9a-f]{64}\z/)
  ' "$target/.agent-workflows-install.json"
}

test_copy_mode_refuses_unmanaged_agent_doctor_directory_before_collision() {
  local tmp target output status configuration_before sentinel_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target/bin/agent_doctor"
  printf 'user-owned configuration\n' > "$target/bin/agent_doctor/configuration.rb"
  printf 'unrelated sentinel\n' > "$target/bin/agent_doctor/sentinel"
  configuration_before="$(shasum "$target/bin/agent_doctor/configuration.rb")"
  sentinel_before="$(shasum "$target/bin/agent_doctor/sentinel")"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "copy mode accepted an unmanaged agent_doctor directory"
  assert_contains "$output" "Refusing unmanaged workflow doctor directory"
  [[ "$configuration_before" = "$(shasum "$target/bin/agent_doctor/configuration.rb")" ]] || \
    fail "copy mode changed a colliding unmanaged doctor file"
  [[ "$sentinel_before" = "$(shasum "$target/bin/agent_doctor/sentinel")" ]] || \
    fail "copy mode changed an unrelated unmanaged doctor file"
  [[ ! -e "$target/bin/agent_doctor/.agent-workflows-managed" ]] || \
    fail "copy mode marked an unmanaged doctor directory"
  [[ ! -e "$target/.agent-workflows-install.json" ]] || fail "failed copy mode committed metadata"
}

test_copy_mode_adopts_an_exact_unmarked_agent_doctor_copy() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target/bin"
  rsync -a "$ROOT/bin/agent_doctor" "$target/bin/"
  [[ ! -e "$target/bin/agent_doctor/.agent-workflows-managed" ]] || \
    fail "legacy doctor fixture unexpectedly had an ownership marker"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"

  grep -Eq '^agent-workflows-doctor-v1:[0-9a-f]{64}$' "$target/bin/agent_doctor/.agent-workflows-managed" || \
    fail "copy mode did not adopt an exact legacy doctor copy"
  cmp -s "$ROOT/bin/agent_doctor/configuration.rb" "$target/bin/agent_doctor/configuration.rb" || \
    fail "adopted doctor copy differs from its source"
}

test_copy_mode_removes_stale_files_from_a_signed_doctor_upgrade() {
  local tmp source target
  tmp="$(mktemp -d)"
  source="$tmp/old-source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"
  printf 'obsolete managed module\n' > "$source/bin/agent_doctor/obsolete.rb"
  write_native_scw_state codex "$target"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --delivery-mode plugin-companion >"$tmp/old-install.out"
  assert_file "$target/bin/agent_doctor/obsolete.rb"
  ruby "$source/bin/agent_doctor/install_ownership.rb" verify \
    "$target/bin/agent_doctor" "$target/bin/agent_doctor/.agent-workflows-managed" || \
    fail "old doctor installation was not signed"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" \
    --delivery-mode plugin-companion >"$tmp/upgrade.out"

  [[ ! -e "$target/bin/agent_doctor/obsolete.rb" ]] || fail "doctor upgrade retained a stale managed module"
  ruby "$ROOT/bin/agent_doctor/install_ownership.rb" verify \
    "$target/bin/agent_doctor" "$target/bin/agent_doctor/.agent-workflows-managed" || \
    fail "upgraded doctor installation has an invalid ownership marker"
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
  local tmp target consumer host output

  for host in codex claude; do
    tmp="$(mktemp -d)"
    target="$tmp/$host-home"
    consumer="$tmp/consumer"
    write_native_scw_state "$host" "$target"
    mkdir -p "$target/skills/personal"
    printf 'personal\n' > "$target/skills/personal/SKILL.md"

    "$ROOT/bin/install-agent-workflows" --host "$host" --target "$target" --delivery-mode plugin-companion \
      >"$tmp/install.out"

    [[ ! -e "$target/skills/pr-batch" ]] || fail "$host companion install wrote flat skills"
    grep -qxF 'personal' "$target/skills/personal/SKILL.md" || fail "$host companion install changed an unrelated skill"
    assert_file "$target/LICENSE"
    assert_file "$target/workflows/pr-processing.md"
    assert_file "$target/docs/coordination-backend.md"
    assert_file "$target/bin/agent-workflow-seam-doctor"
    assert_file "$target/bin/agent-workflows-status"
    assert_file "$target/bin/agent-workflows-doctor"
    assert_file "$target/bin/agent_doctor/process_runner.rb"
    assert_file "$target/bin/agent-workflows-delivery-state"
    assert_file "$target/lib/agent-workflows/secure_github_actions_scanner.rb"
    ruby -rjson -e '
      metadata = JSON.parse(File.read(ARGV.fetch(0)))
      abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion" && metadata["mode"] == "copy"
    ' "$target/.agent-workflows-install.json"

    write_consumer_agents "$consumer"
    cat >> "$consumer/.agents/agent-workflow.yml" <<'YAML'
autonomous_merge:
  thresholds:
    max_changed_files: 20
YAML
    output="$("$target/bin/agent-workflow-seam-doctor" --root "$consumer" 2>&1)"
    assert_contains "$output" "PASS agent workflow seam is complete"
  done
}

test_plugin_companion_refuses_unsafe_scanner_ancestors_before_mutation() {
  local tmp target outside output status mode variant unsafe_ancestor outside_scanner

  for mode in copy symlink; do
    for variant in lib-symlink companion-symlink lib-file companion-file; do
      tmp="$(mktemp -d)"
      target="$tmp/claude-home"
      outside="$tmp/outside"
      write_native_scw_state claude "$target"
      mkdir -p "$outside"
      case "$variant" in
        lib-symlink)
          unsafe_ancestor="$target/lib"
          outside_scanner="$outside/agent-workflows/secure_github_actions_scanner.rb"
          ln -s "$outside" "$unsafe_ancestor"
          ;;
        companion-symlink)
          mkdir -p "$target/lib"
          unsafe_ancestor="$target/lib/agent-workflows"
          outside_scanner="$outside/secure_github_actions_scanner.rb"
          ln -s "$outside" "$unsafe_ancestor"
          ;;
        lib-file)
          unsafe_ancestor="$target/lib"
          outside_scanner="$outside/unused"
          printf 'owned file\n' > "$unsafe_ancestor"
          ;;
        companion-file)
          mkdir -p "$target/lib"
          unsafe_ancestor="$target/lib/agent-workflows"
          outside_scanner="$outside/unused"
          printf 'owned file\n' > "$unsafe_ancestor"
          ;;
      esac

      set +e
      output="$("$ROOT/bin/install-agent-workflows" --host claude --target "$target" --mode "$mode" \
        --delivery-mode plugin-companion 2>&1)"
      status=$?
      set -e

      [[ "$status" -ne 0 ]] || fail "$mode companion install accepted unsafe ancestor variant $variant"
      assert_contains "$output" "Refusing unsafe scanner companion ancestor: $unsafe_ancestor"
      [[ -L "$unsafe_ancestor" || -f "$unsafe_ancestor" ]] || \
        fail "$mode companion install replaced unsafe ancestor variant $variant"
      [[ ! -e "$outside_scanner" ]] || \
        fail "$mode companion install wrote the scanner outside the selected agent home"
      [[ ! -e "$target/LICENSE" ]] || fail "$mode companion path preflight ran after install mutation"
      [[ ! -e "$target/.agent-workflows-install.json" ]] || fail "$mode companion path preflight wrote metadata"
    done
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
require "json"

# Force delivery-state JSON beyond a typical shell pipe buffer so the installer
# regression covers its large command-substitution-to-parser pipe transport.
class << JSON
  alias qa_original_pretty_generate pretty_generate

  def pretty_generate(value, *arguments)
    qa_original_pretty_generate(value, *arguments) + (" " * 65_536)
  end
end

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

test_recovery_normalization_failure_releases_install_lock() {
  local tmp target staging receipt injection output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-crash"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/fail-recovery-normalization.rb"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/flat.out"
  mkdir -p "$staging"
  mv "$target/skills/pr-batch" "$staging/"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module FailRecoveredStagingNormalization
  def expand_path(path, *)
    raise "injected recovered-staging normalization failure" if path == ENV["QA_RECOVERED_STAGING"] && ARGV == [path]

    super
  end
end
File.singleton_class.prepend(FailRecoveredStagingNormalization)
RUBY

  set +e
  output="$(QA_RECOVERED_STAGING="$staging" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "recovered-staging normalization failure unexpectedly succeeded"
  assert_contains "$output" "injected recovered-staging normalization failure"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "normalization failure leaked install lock"
  assert_file "$receipt"
  [[ -d "$staging" ]] || fail "normalization failure removed staged recovery data"
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

test_first_install_crash_with_absent_metadata_recovers_as_flat() {
  local tmp target staging receipt output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-first-install-crash"
  receipt="$target/.agent-workflows-migration-staging"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '%s\n' "$staging" > "$receipt"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "absent first-install metadata recovery exited $status: $output"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ ! -e "$receipt" ]] || fail "absent first-install metadata recovery preserved completed receipt"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
  assert_file "$target/.agent-workflows-install.json"
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' \
    "$target/.agent-workflows-install.json"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "absent metadata recovery leaked install lock"
}

test_metadata_appearing_before_lock_is_not_treated_as_absent_recovery() {
  local tmp target staging receipt metadata fake_bin real_mkdir marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-metadata-appeared-before-lock"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  fake_bin="$tmp/fake-bin"
  real_mkdir="$(command -v mkdir)"
  marker="$tmp/metadata-appeared-before-lock"
  mkdir -p "$staging/user-owned-skill" "$fake_bin"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mkdir" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 1 && "$1" = "$QA_INSTALL_LOCK" && ! -e "$QA_RACE_MARKER" ]]; then
  printf '{"delivery_mode":"flat"}\n' > "$QA_INSTALL_METADATA"
  printf 'appeared\n' > "$QA_RACE_MARKER"
fi
exec "$QA_REAL_MKDIR" "$@"
SH
  chmod +x "$fake_bin/mkdir"
  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MKDIR="$real_mkdir" \
    QA_INSTALL_LOCK="$target/.agent-workflows-install.lock" QA_INSTALL_METADATA="$metadata" \
    QA_RACE_MARKER="$marker" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 0 ]] || fail "metadata appearing before lock was not captured under lock: $status: $output"
  [[ ! -e "$receipt" ]] || fail "fresh locked metadata capture left recovery receipt"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
  assert_file "$metadata"
}

test_metadata_disappearing_before_lock_is_not_treated_as_still_present() {
  local tmp target staging receipt metadata fake_bin real_mkdir marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-metadata-disappeared-before-lock"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  fake_bin="$tmp/fake-bin"
  real_mkdir="$(command -v mkdir)"
  marker="$tmp/metadata-disappeared-before-lock"
  mkdir -p "$staging/user-owned-skill" "$fake_bin"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mkdir" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 1 && "$1" = "$QA_INSTALL_LOCK" && ! -e "$QA_RACE_MARKER" ]]; then
  rm -f "$QA_INSTALL_METADATA"
  printf 'disappeared\n' > "$QA_RACE_MARKER"
fi
exec "$QA_REAL_MKDIR" "$@"
SH
  chmod +x "$fake_bin/mkdir"

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MKDIR="$real_mkdir" \
    QA_INSTALL_LOCK="$target/.agent-workflows-install.lock" QA_INSTALL_METADATA="$metadata" \
    QA_RACE_MARKER="$marker" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 0 ]] || fail "fresh locked absent metadata recovery exited $status: $output"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ ! -e "$receipt" ]] || fail "fresh locked absent recovery left receipt"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
  assert_file "$metadata"
}

test_metadata_change_after_locked_preflight_fails_before_managed_file_mutation() {
  local tmp target metadata injection marker output status license_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/corrupt-metadata-after-temp-write.rb"
  marker="$tmp/metadata-corrupted-after-temp-write"
  "$ROOT/bin/install-agent-workflows" --host claude --target "$target" --mode copy \
    --delivery-mode flat >"$tmp/initial-install.out"
  license_before="$(shasum "$target/LICENSE")"

  cat > "$injection" <<'RUBY'
module CorruptMetadataAfterTempWrite
  def open(path, *args, **kwargs, &block)
    result = super
    if path == "#{ENV.fetch("QA_INSTALL_METADATA")}.tmp" && !File.exist?(ENV.fetch("QA_RACE_MARKER"))
      at_exit do
        File.write(ENV.fetch("QA_INSTALL_METADATA"), "{\"delivery_mode\":")
        File.write(ENV.fetch("QA_RACE_MARKER"), "changed\n")
      end
    end
    result
  end
end
File.singleton_class.prepend(CorruptMetadataAfterTempWrite)
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host claude --target "$target" --mode copy \
    --delivery-mode flat 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "post-preflight metadata change exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ "$license_before" = "$(shasum "$target/LICENSE")" ]] || \
    fail "post-preflight metadata change mutated a managed file"
  [[ "$(cat "$metadata")" = '{"delivery_mode":' ]] || \
    fail "post-preflight metadata change was overwritten"
  [[ ! -e "$metadata.tmp" ]] || fail "post-preflight metadata change left prepared metadata"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "post-preflight metadata change leaked install lock"
}

test_bound_metadata_change_cannot_grant_symlink_ownership() {
  local tmp target metadata outside injection marker helper initial_helper_identity output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  metadata="$target/.agent-workflows-install.json"
  outside="$tmp/unmanaged-source"
  injection="$tmp/change-metadata-after-binding-check.rb"
  marker="$tmp/metadata-changed-after-binding-check"
  helper="$target/bin/agent-workflows-status"
  mkdir -p "$outside/bin"
  printf '#!/usr/bin/env bash\necho unmanaged\n' > "$outside/bin/agent_doctor"
  chmod +x "$outside/bin/agent_doctor"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink \
    --delivery-mode flat >"$tmp/initial-install.out"
  rm -f "$target/bin/agent_doctor"
  ln -s "$outside/bin/agent_doctor" "$target/bin/agent_doctor"
  initial_helper_identity="$(ruby -e 'stat = File.lstat(ARGV.fetch(0)); print "#{stat.dev}:#{stat.ino}"' "$helper")"

  cat > "$injection" <<'RUBY'
require "json"
metadata = ENV.fetch("QA_INSTALL_METADATA")
helper = ENV.fetch("QA_MANAGED_HELPER")
initial_helper_identity = ENV.fetch("QA_INITIAL_HELPER_IDENTITY")
if ARGV.length == 1 && ARGV.first == metadata && File.exist?("#{metadata}.tmp") &&
   !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  current_helper_identity = begin
    stat = File.lstat(helper)
    "#{stat.dev}:#{stat.ino}"
  rescue Errno::ENOENT
    "missing"
  end
  if current_helper_identity == initial_helper_identity
    at_exit do
      value = JSON.parse(File.binread(metadata))
      value["mode"] = "symlink"
      value["source"] = ENV.fetch("QA_UNMANAGED_SOURCE")
      File.write(metadata, JSON.generate(value) + "\n")
      File.write(ENV.fetch("QA_RACE_MARKER"), "changed\n")
    end
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" QA_MANAGED_HELPER="$helper" \
    QA_INITIAL_HELPER_IDENTITY="$initial_helper_identity" QA_UNMANAGED_SOURCE="$outside" \
    QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink \
    --delivery-mode flat 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "bound metadata ownership race exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ "$(readlink "$target/bin/agent_doctor")" = "$outside/bin/agent_doctor" ]] || \
    fail "changed live metadata granted ownership of an unmanaged doctor symlink"
  [[ ! -e "$metadata.tmp" ]] || fail "bound metadata ownership race left prepared metadata"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "bound metadata ownership race leaked install lock"
}

test_metadata_commit_rejects_destination_directory_race() {
  local tmp target metadata preserved injection marker helper initial_helper_identity output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  metadata="$target/.agent-workflows-install.json"
  preserved="$tmp/preserved-install-metadata.json"
  injection="$tmp/replace-metadata-after-final-binding-check.rb"
  marker="$tmp/metadata-replaced-after-final-binding-check"
  helper="$target/bin/agent-workflows-status"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink \
    --delivery-mode flat >"$tmp/initial-install.out"
  initial_helper_identity="$(ruby -e 'stat = File.lstat(ARGV.fetch(0)); print "#{stat.dev}:#{stat.ino}"' "$helper")"

  cat > "$injection" <<'RUBY'
metadata = ENV.fetch("QA_INSTALL_METADATA")
helper = ENV.fetch("QA_MANAGED_HELPER")
initial_helper_identity = ENV.fetch("QA_INITIAL_HELPER_IDENTITY")
if ARGV.length == 1 && ARGV.first == metadata && File.exist?("#{metadata}.tmp") &&
   !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  current_helper_identity = begin
    stat = File.lstat(helper)
    "#{stat.dev}:#{stat.ino}"
  rescue Errno::ENOENT
    "missing"
  end
  if current_helper_identity != initial_helper_identity
    at_exit do
      File.rename(metadata, ENV.fetch("QA_PRESERVED_METADATA"))
      Dir.mkdir(metadata)
      File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
    end
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" QA_PRESERVED_METADATA="$preserved" \
    QA_MANAGED_HELPER="$helper" QA_INITIAL_HELPER_IDENTITY="$initial_helper_identity" \
    QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink \
    --delivery-mode flat 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "metadata destination directory race exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ -d "$metadata" && ! -L "$metadata" ]] || fail "metadata destination directory race replaced the competing directory"
  assert_file "$preserved"
  [[ ! -e "$metadata/.agent-workflows-install.json.tmp" ]] || \
    fail "metadata commit moved prepared metadata inside the competing directory"
  [[ ! -e "$metadata.tmp" ]] || fail "metadata destination directory race left prepared metadata"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "metadata destination directory race leaked install lock"
}

test_metadata_commit_rolls_back_failed_present_compare_and_swap() {
  local tmp target metadata preserved injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  metadata="$target/.agent-workflows-install.json"
  preserved="$tmp/preserved-install-metadata.json"
  injection="$tmp/replace-metadata-inside-present-commit.rb"
  marker="$tmp/metadata-replaced-inside-present-commit"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    --delivery-mode flat >"$tmp/initial-install.out"

  cat > "$injection" <<'RUBY'
if ARGV.length == 5 && ARGV[0] == ENV.fetch("QA_TARGET") &&
   ARGV[1] == ".agent-workflows-install.json" && ARGV[2] == "present"
  module ReplaceMetadataInsidePresentCommit
    def close(*args)
      opened_stat = stat unless closed?
      result = super
      metadata = ENV.fetch("QA_INSTALL_METADATA")
      unless File.exist?(ENV.fetch("QA_RACE_MARKER"))
        named_stat = File.lstat(metadata)
        if opened_stat&.file? && named_stat.file? &&
           opened_stat.dev == named_stat.dev && opened_stat.ino == named_stat.ino
          File.rename(metadata, ENV.fetch("QA_PRESERVED_METADATA"))
          File.write(metadata, "competing metadata\n")
          File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
        end
      end
      result
    end
  end
  IO.prepend(ReplaceMetadataInsidePresentCommit)
end
RUBY

  set +e
  output="$(QA_TARGET="$target" QA_INSTALL_METADATA="$metadata" \
    QA_PRESERVED_METADATA="$preserved" QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    --delivery-mode flat 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "present metadata compare-and-swap race exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ "$(cat "$metadata")" = "competing metadata" ]] || \
    fail "failed metadata compare-and-swap did not restore the competing destination"
  assert_file "$preserved"
  [[ ! -e "$metadata.tmp" ]] || fail "failed metadata compare-and-swap left prepared metadata"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "failed metadata compare-and-swap leaked install lock"
}

test_metadata_commit_rejects_replaced_prepared_file() {
  local tmp target metadata injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/replace-prepared-install-metadata.rb"
  marker="$tmp/prepared-install-metadata-replaced"

  cat > "$injection" <<'RUBY'
metadata = ENV.fetch("QA_INSTALL_METADATA")
if ARGV.first == "#{metadata}.tmp" && !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  at_exit do
    File.write(
      "#{metadata}.tmp",
      "{\"delivery_mode\":\"plugin-companion\",\"mode\":\"symlink\",\"source\":\"/tmp/attacker\"}\n"
    )
    File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    --delivery-mode flat 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "replaced prepared metadata exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ ! -e "$metadata" ]] || fail "replaced prepared metadata was committed"
  assert_file "$target/skills/pr-batch/SKILL.md"
  [[ ! -e "$metadata.tmp" ]] || fail "replaced prepared metadata was not cleaned"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "replaced prepared metadata leaked install lock"
}

test_metadata_commit_capability_failure_stops_before_managed_mutation() {
  local tmp source target injection output status license_before metadata_before
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  injection="$tmp/fail-atomic-metadata-rename-import.rb"
  mkdir -p "$source"
  new_source_repo "$source"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    --delivery-mode flat >"$tmp/initial-install.out"
  license_before="$(shasum "$target/LICENSE")"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"
  printf '\ncapability probe source change\n' >> "$source/LICENSE"

  cat > "$injection" <<'RUBY'
require "fiddle/import"
module FailAtomicMetadataRenameImport
  def extern(signature, *arguments)
    if signature.include?("renameat2") || signature.include?("renameatx_np")
      raise Fiddle::DLError, "atomic rename unavailable"
    end
    super
  end
end
Fiddle::Importer.prepend(FailAtomicMetadataRenameImport)
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" "$source/bin/install-agent-workflows" --host codex \
    --target "$target" --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "missing metadata commit capability unexpectedly succeeded"
  assert_contains "$output" "METADATA_COMMIT_UNAVAILABLE"
  [[ "$license_before" = "$(shasum "$target/LICENSE")" ]] || \
    fail "missing metadata commit capability mutated a managed file"
  [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
    fail "missing metadata commit capability changed install metadata"
  [[ ! -e "$target/.agent-workflows-install.json.tmp" ]] || \
    fail "missing metadata commit capability prepared new metadata"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || \
    fail "missing metadata commit capability leaked install lock"
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

test_recovery_restore_holds_install_lock_against_retry() {
  local tmp target staging receipt metadata injection marker gate primary_pid
  local retry_output retry_status primary_status attempt
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-missing-for-lock-test"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/pause-metadata-restore.rb"
  marker="$tmp/restore-started"
  gate="$tmp/allow-restore"
  mkdir -p "$staging/user-owned-skill" "$target/skills/user-owned-skill"
  printf 'staged\n' > "$staging/user-owned-skill/SKILL.md"
  printf 'collision\n' > "$target/skills/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryRestoreHook
  def self.call(phase)
    if phase == :before_rename
      File.write(ENV.fetch("QA_RESTORE_MARKER"), "started\n")
      1_000.times do
        break if File.exist?(ENV.fetch("QA_RESTORE_GATE"))
        sleep 0.01
      end
      exit 99 unless File.exist?(ENV.fetch("QA_RESTORE_GATE"))
    end
  end
end
RUBY

  QA_INSTALL_METADATA="$metadata" RUBYOPT="-r$injection" \
    QA_RESTORE_MARKER="$marker" QA_RESTORE_GATE="$gate" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/primary.out" 2>&1 &
  primary_pid=$!
  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ -e "$marker" ]] && break
    kill -0 "$primary_pid" 2>/dev/null || break
    sleep 0.01
  done
  if [[ ! -e "$marker" ]]; then
    : > "$gate"
    wait "$primary_pid" || true
    fail "primary recovery did not reach metadata restoration: $(cat "$tmp/primary.out")"
  fi

  set +e
  retry_output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  retry_status=$?
  set -e
  : > "$gate"
  set +e
  wait "$primary_pid"
  primary_status=$?
  set -e

  [[ "$retry_status" -ne 0 ]] || fail "retry acquired the install lock during recovery restoration"
  assert_contains "$retry_output" "another agent-workflows install or migration holds"
  [[ "$primary_status" -ne 0 ]] || fail "rollback-collision recovery unexpectedly succeeded"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "recovery restoration leaked install lock"
  assert_file "$metadata"
  assert_file "$receipt"
}

test_recovery_metadata_change_during_rollback_preserves_staging_and_tree() {
  local tmp target staging receipt metadata fake_bin real_mv injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-binding-race"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  fake_bin="$tmp/fake-bin"
  real_mv="$(command -v mv)"
  injection="$tmp/change-metadata-before-bound-staged-move.rb"
  marker="$tmp/metadata-changed-before-staged-move"
  mkdir -p "$staging/user-owned-skill" "$fake_bin"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" = "$QA_STAGED_SKILL" && "$2" = "$QA_SKILLS_ROOT/" ]]; then
  printf '[]\n' > "$QA_INSTALL_METADATA"
  : > "$QA_RACE_MARKER"
fi
exec "$QA_REAL_MV" "$@"
SH
  chmod +x "$fake_bin/mv"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == ENV.fetch("QA_STAGED_SKILL") &&
   ARGV.fetch(1) == File.join(ENV.fetch("QA_SKILLS_ROOT"), "user-owned-skill")
  File.write(ENV.fetch("QA_INSTALL_METADATA"), "[]\n")
  File.write(ENV.fetch("QA_RACE_MARKER"), "changed\n")
end
RUBY

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MV="$real_mv" \
    QA_STAGED_SKILL="$staging/user-owned-skill" QA_SKILLS_ROOT="$target/skills" \
    QA_INSTALL_METADATA="$metadata" QA_RACE_MARKER="$marker" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "metadata change during rollback exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ "$(grep -c 'CORRUPT_INSTALL_METADATA' <<< "$output")" -eq 1 ]] || \
    fail "corrupt metadata was reported more than once: $output"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "corrupt recovery left a staged skill in the target tree"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "corrupt recovery leaked install lock"
}

test_recovery_metadata_change_during_companion_cleanup_preserves_staging() {
  local tmp target staging receipt metadata fake_bin real_mv injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-binding-race"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  fake_bin="$tmp/fake-bin"
  real_mv="$(command -v mv)"
  injection="$tmp/change-metadata-before-bound-staging-cleanup.rb"
  marker="$tmp/metadata-changed-before-staging-cleanup"
  mkdir -p "$staging/old-flat-skill" "$fake_bin"
  printf 'old flat skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" = "$QA_STAGING" &&
      "$2" = "$QA_TARGET"/.agent-workflows-recovery-cleanup-*/staging ]]; then
  printf '[]\n' > "$QA_INSTALL_METADATA"
  : > "$QA_RACE_MARKER"
fi
exec "$QA_REAL_MV" "$@"
SH
  chmod +x "$fake_bin/mv"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == ENV.fetch("QA_STAGING") &&
   ARGV.fetch(1).match?(%r{/\.agent-workflows-recovery-cleanup-[A-Za-z0-9]+/staging\z})
  File.write(ENV.fetch("QA_INSTALL_METADATA"), "[]\n")
  File.write(ENV.fetch("QA_RACE_MARKER"), "changed\n")
end
RUBY

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MV="$real_mv" QA_STAGING="$staging" \
    QA_TARGET="$target" QA_INSTALL_METADATA="$metadata" QA_RACE_MARKER="$marker" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "metadata change during companion cleanup exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$staging/old-flat-skill/SKILL.md"
  [[ ! -e "$target/skills/old-flat-skill" ]] || fail "corrupt companion cleanup changed the target tree"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "corrupt companion cleanup leaked install lock"
}

test_recovery_staging_replacement_during_rollback_preserves_artifacts() {
  local tmp target staging preserved receipt outside fake_bin real_mv injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-staging-replacement"
  preserved="$target/.agent-workflows-flat-migration-staging-preserved"
  receipt="$target/.agent-workflows-migration-staging"
  outside="$tmp/outside-staging"
  fake_bin="$tmp/fake-bin"
  real_mv="$(command -v mv)"
  injection="$tmp/replace-staging-before-bound-rollback-move.rb"
  marker="$tmp/staging-replaced"
  mkdir -p "$staging/user-owned-skill" "$outside/user-owned-skill" "$fake_bin"
  printf 'original staged skill\n' > "$staging/user-owned-skill/SKILL.md"
  printf 'outside skill\n' > "$outside/user-owned-skill/SKILL.md"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" = "$QA_STAGING/user-owned-skill" && "$2" = "$QA_TARGET/skills/" &&
      ! -e "$QA_RACE_MARKER" ]]; then
  "$QA_REAL_MV" "$QA_STAGING" "$QA_PRESERVED_STAGING"
  ln -s "$QA_OUTSIDE_STAGING" "$QA_STAGING"
  : > "$QA_RACE_MARKER"
fi
exec "$QA_REAL_MV" "$@"
SH
  chmod +x "$fake_bin/mv"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == File.join(ENV.fetch("QA_STAGING"), "user-owned-skill") &&
   ARGV.fetch(2) == ENV.fetch("QA_STAGING") && !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  File.rename(ENV.fetch("QA_STAGING"), ENV.fetch("QA_PRESERVED_STAGING"))
  File.symlink(ENV.fetch("QA_OUTSIDE_STAGING"), ENV.fetch("QA_STAGING"))
  File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
end
RUBY

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MV="$real_mv" QA_TARGET="$target" \
    QA_STAGING="$staging" QA_PRESERVED_STAGING="$preserved" QA_OUTSIDE_STAGING="$outside" \
    QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "rollback staging replacement exited $status: $output"
  assert_contains "$output" "RECOVERY_STAGING_BINDING_CHANGED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$preserved/user-owned-skill/SKILL.md"
  assert_file "$outside/user-owned-skill/SKILL.md"
  assert_file "$outside/SENTINEL"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "rollback staging replacement changed target skills"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "rollback staging replacement leaked install lock"
}

test_recovery_staging_replacement_during_companion_cleanup_preserves_artifacts() {
  local tmp target staging preserved receipt outside fake_bin real_mv injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-replacement"
  preserved="$target/.agent-workflows-flat-migration-cleanup-preserved"
  receipt="$target/.agent-workflows-migration-staging"
  outside="$tmp/outside-staging"
  fake_bin="$tmp/fake-bin"
  real_mv="$(command -v mv)"
  injection="$tmp/replace-staging-before-bound-cleanup-move.rb"
  marker="$tmp/staging-replaced"
  mkdir -p "$staging/old-flat-skill" "$outside" "$fake_bin"
  write_native_scw_state codex "$target"
  printf 'original staged skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" = "$QA_STAGING" &&
      "$2" = "$QA_TARGET"/.agent-workflows-recovery-cleanup-*/staging &&
      ! -e "$QA_RACE_MARKER" ]]; then
  "$QA_REAL_MV" "$QA_STAGING" "$QA_PRESERVED_STAGING"
  ln -s "$QA_OUTSIDE_STAGING" "$QA_STAGING"
  : > "$QA_RACE_MARKER"
fi
exec "$QA_REAL_MV" "$@"
SH
  chmod +x "$fake_bin/mv"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == ENV.fetch("QA_STAGING") &&
   ARGV.fetch(1).match?(%r{/\.agent-workflows-recovery-cleanup-[A-Za-z0-9]+/staging\z}) &&
   !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  File.rename(ENV.fetch("QA_STAGING"), ENV.fetch("QA_PRESERVED_STAGING"))
  File.symlink(ENV.fetch("QA_OUTSIDE_STAGING"), ENV.fetch("QA_STAGING"))
  File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
end
RUBY

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MV="$real_mv" QA_TARGET="$target" \
    QA_STAGING="$staging" QA_PRESERVED_STAGING="$preserved" QA_OUTSIDE_STAGING="$outside" \
    QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "companion cleanup staging replacement exited $status: $output"
  assert_contains "$output" "RECOVERY_STAGING_BINDING_CHANGED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$preserved/old-flat-skill/SKILL.md"
  assert_file "$outside/SENTINEL"
  [[ ! -e "$target/skills/old-flat-skill" ]] || fail "cleanup staging replacement changed target skills"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "cleanup staging replacement leaked install lock"
}

test_recovery_staging_disappearing_after_identity_capture_fails_closed() {
  local tmp target staging preserved receipt injection marker counter output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-identity-disappears"
  preserved="$target/.agent-workflows-flat-migration-identity-preserved"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/remove-staging-after-identity.rb"
  marker="$tmp/staging-replaced"
  counter="$tmp/staging-lstat-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'original staged skill\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
class << File
  alias qa_original_lstat lstat
  def lstat(path)
    result = qa_original_lstat(path)
    if path == ENV.fetch("QA_STAGING")
      counter = ENV.fetch("QA_LSTAT_COUNTER")
      count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
      File.write(counter, count)
      if count == 2 && !File.exist?(ENV.fetch("QA_RACE_MARKER"))
        at_exit do
          File.rename(ENV.fetch("QA_STAGING"), ENV.fetch("QA_PRESERVED_STAGING"))
          File.write(ENV.fetch("QA_STAGING"), "replacement\n")
          File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
        end
      end
    end
    result
  end
end
RUBY

  set +e
  output="$(QA_STAGING="$staging" QA_PRESERVED_STAGING="$preserved" QA_RACE_MARKER="$marker" \
    QA_LSTAT_COUNTER="$counter" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "missing bound staging exited $status: $output"
  assert_contains "$output" "RECOVERY_STAGING_BINDING_CHANGED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$preserved/user-owned-skill/SKILL.md"
  [[ ! -d "$staging" ]] || fail "missing bound staging was silently recreated"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "missing bound staging leaked install lock"
}

test_recovery_skills_root_replacement_during_reversal_preserves_outside_data() {
  local tmp target staging receipt outside preserved_skills injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-skills-reversal"
  receipt="$target/.agent-workflows-migration-staging"
  outside="$tmp/outside-skills"
  preserved_skills="$tmp/preserved-target-skills"
  injection="$tmp/replace-skills-root-after-first-move.rb"
  marker="$tmp/skills-root-replaced"
  mkdir -p "$staging/a-first-skill" "$staging/b-second-skill" "$outside/a-first-skill"
  printf 'original first skill\n' > "$staging/a-first-skill/SKILL.md"
  printf 'original second skill\n' > "$staging/b-second-skill/SKILL.md"
  printf 'outside private data\n' > "$outside/a-first-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == File.join(ENV.fetch("QA_STAGING"), "a-first-skill") &&
   !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  at_exit do
    File.rename(ENV.fetch("QA_SKILLS_ROOT"), ENV.fetch("QA_PRESERVED_SKILLS"))
    File.symlink(ENV.fetch("QA_OUTSIDE_SKILLS"), ENV.fetch("QA_SKILLS_ROOT"))
    File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
  end
end
RUBY

  set +e
  output="$(QA_STAGING="$staging" QA_SKILLS_ROOT="$target/skills" \
    QA_PRESERVED_SKILLS="$preserved_skills" QA_OUTSIDE_SKILLS="$outside" \
    QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "skills root replacement during reversal exited $status: $output"
  assert_contains "$output" "RECOVERY_SKILLS_BINDING_CHANGED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$outside/a-first-skill/SKILL.md"
  assert_contains "$(cat "$outside/a-first-skill/SKILL.md")" "outside private data"
  assert_file "$preserved_skills/a-first-skill/SKILL.md"
  assert_file "$staging/b-second-skill/SKILL.md"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "skills root replacement leaked install lock"
}

test_recovery_destination_appearing_at_move_is_not_replaced() {
  local tmp target staging receipt injection marker output status destination
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-destination-race"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/create-destination-before-rename.rb"
  marker="$tmp/destination-created"
  destination="$target/skills/user-owned-skill"
  mkdir -p "$staging/user-owned-skill"
  printf 'staged skill\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryMoveHook
  def self.call(phase, _source_parent, source_name, destination_parent, destination_name)
    return unless phase == :before_rename && source_name == "user-owned-skill"
    marker = ENV.fetch("QA_RACE_MARKER")
    return if File.exist?(marker)
    destination = File.join(destination_parent, destination_name)
    Dir.mkdir(destination)
    File.write(File.join(destination, "SENTINEL"), "appeared destination\n")
    File.write(marker, "created\n")
  end
end
RUBY

  set +e
  output="$(QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "destination appearing at recovery move exited $status: $output"
  assert_contains "$output" "RECOVERY_PATH_BINDING_CHANGED"
  assert_file "$destination/SENTINEL"
  assert_contains "$(cat "$destination/SENTINEL")" "appeared destination"
  assert_file "$staging/user-owned-skill/SKILL.md"
  assert_file "$receipt"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "destination race leaked install lock"
}

test_flat_crash_recovery_restores_staged_symlink_skill() {
  local tmp target staging receipt source_skill output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-symlink-skill"
  receipt="$target/.agent-workflows-migration-staging"
  source_skill="$tmp/source-skill"
  mkdir -p "$staging" "$source_skill"
  printf 'source skill\n' > "$source_skill/SKILL.md"
  ln -s "$source_skill" "$staging/symlink-skill"
  printf '{"delivery_mode":"flat","mode":"symlink","source":"%s"}\n' "$ROOT" \
    > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  mkdir "$target/.agent-workflows-install.json.tmp"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "metadata preflight unexpectedly succeeded after symlink recovery"
  assert_symlink "$target/skills/symlink-skill"
  [[ "$(readlink "$target/skills/symlink-skill")" = "$source_skill" ]] || \
    fail "recovery changed the staged symlink target"
  [[ ! -e "$receipt" ]] || fail "successful symlink recovery preserved receipt"
  [[ ! -e "$staging" ]] || fail "successful symlink recovery preserved staging"
}

test_recovery_source_replacement_after_inventory_is_not_moved() {
  local tmp target staging receipt injection marker preserved output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-source-entry-race"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/replace-source-before-open.rb"
  marker="$tmp/source-replaced"
  preserved="$tmp/preserved-original"
  mkdir -p "$staging/user-owned-skill"
  printf 'original staged skill\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryMoveHook
  def self.call(phase, source_parent, source_name, _destination_parent, _destination_name)
    return unless phase == :before_source_open && source_name == "user-owned-skill"
    marker = ENV.fetch("QA_RACE_MARKER")
    return if File.exist?(marker)
    source = File.join(source_parent, source_name)
    File.rename(source, ENV.fetch("QA_PRESERVED_SOURCE"))
    Dir.mkdir(source)
    File.write(File.join(source, "SKILL.md"), "replacement skill\n")
    File.write(marker, "replaced\n")
  end
end
RUBY

  set +e
  output="$(QA_RACE_MARKER="$marker" QA_PRESERVED_SOURCE="$preserved" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "source replacement after inventory exited $status: $output"
  assert_contains "$output" "RECOVERY_PATH_BINDING_CHANGED"
  assert_file "$marker"
  assert_file "$preserved/SKILL.md"
  assert_contains "$(cat "$preserved/SKILL.md")" "original staged skill"
  assert_file "$staging/user-owned-skill/SKILL.md"
  assert_contains "$(cat "$staging/user-owned-skill/SKILL.md")" "replacement skill"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "replacement source was moved"
  assert_file "$receipt"
}

test_recovery_identity_failure_reverses_earlier_moves() {
  local tmp target staging receipt injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-identity-failure"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/remove-second-before-identity.rb"
  marker="$tmp/second-entry-removed"
  mkdir -p "$staging/a-first-skill" "$staging/b-second-skill"
  printf 'first staged skill\n' > "$staging/a-first-skill/SKILL.md"
  printf 'second staged skill\n' > "$staging/b-second-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RemoveSecondRecoveryEntry
  def lstat(path)
    if ARGV == [path] && path.end_with?("/b-second-skill") && !File.exist?(ENV.fetch("QA_RACE_MARKER"))
      File.rename(path, ENV.fetch("QA_PRESERVED_SOURCE"))
      File.write(ENV.fetch("QA_RACE_MARKER"), "removed\n")
    end
    super
  end
end
File.singleton_class.prepend(RemoveSecondRecoveryEntry)
RUBY

  set +e
  output="$(QA_RACE_MARKER="$marker" QA_PRESERVED_SOURCE="$tmp/preserved-second" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "identity failure after earlier move exited $status: $output"
  assert_file "$marker"
  assert_file "$staging/a-first-skill/SKILL.md"
  [[ ! -e "$target/skills/a-first-skill" ]] || fail "identity failure did not reverse earlier move"
  assert_file "$tmp/preserved-second/SKILL.md"
  assert_file "$receipt"
}

test_recovery_post_move_verification_failure_reverses_committed_move() {
  local tmp target staging receipt injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-post-move-verify"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/fail-after-recovery-move.rb"
  marker="$tmp/post-move-hook-ran"
  mkdir -p "$staging/user-owned-skill"
  printf 'staged skill\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryMoveHook
  def self.call(phase, _source_parent, source_name, _destination_parent, _destination_name)
    return unless phase == :after_rename_before_verify && source_name == "user-owned-skill"
    marker = ENV.fetch("QA_RACE_MARKER")
    return if File.exist?(marker)
    File.write(marker, "reached\n")
    raise "injected post-move verification failure"
  end
end
RUBY

  set +e
  output="$(QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "post-move verification failure exited $status: $output"
  assert_contains "$output" "RECOVERY_PATH_BINDING_CHANGED"
  assert_file "$marker"
  assert_file "$staging/user-owned-skill/SKILL.md"
  assert_contains "$(cat "$staging/user-owned-skill/SKILL.md")" "staged skill"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "committed recovery move was not reversed"
  assert_file "$receipt"
}

test_recovery_post_move_open_failure_reverses_committed_move() {
  local tmp target staging receipt injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-post-move-open"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/fail-post-move-open.rb"
  marker="$tmp/post-move-open-failed"
  mkdir -p "$staging/user-owned-skill"
  printf 'staged skill\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
require "fiddle"
Fiddle::Function.prepend(Module.new do
  def call(*args)
    if Thread.current[:qa_fail_next_recovery_open]
      Thread.current[:qa_fail_next_recovery_open] = false
      Fiddle.last_error = Errno::EIO::Errno
      return -1
    end
    super
  end
end)
module RecoveryMoveHook
  def self.call(phase, _source_parent, source_name, _destination_parent, _destination_name)
    return unless phase == :after_rename_before_verify && source_name == "user-owned-skill"
    return if File.exist?(ENV.fetch("QA_RACE_MARKER"))
    File.write(ENV.fetch("QA_RACE_MARKER"), "reached\n")
    Thread.current[:qa_fail_next_recovery_open] = true
  end
end
RUBY

  set +e
  output="$(QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "post-move open failure exited $status: $output"
  assert_contains "$output" "RECOVERY_PATH_BINDING_CHANGED"
  assert_file "$marker"
  assert_file "$staging/user-owned-skill/SKILL.md"
  assert_contains "$(cat "$staging/user-owned-skill/SKILL.md")" "staged skill"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "committed recovery move was not reversed"
  assert_file "$receipt"
}

test_companion_cleanup_post_move_replacement_has_named_retry_failure() {
  local tmp target staging preserved receipt injection marker output retry_output status retry_status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-post-move"
  preserved="$target/.agent-workflows-flat-migration-cleanup-post-move-preserved"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/replace-cleanup-staging-after-move.rb"
  marker="$tmp/cleanup-staging-replaced"
  mkdir -p "$staging/old-flat-skill"
  write_native_scw_state codex "$target"
  printf 'original staged skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == ENV.fetch("QA_STAGING") &&
   ARGV.fetch(1).match?(%r{/\.agent-workflows-recovery-cleanup-[A-Za-z0-9]+/staging\z})
  at_exit do
    File.rename(ARGV.fetch(1), ENV.fetch("QA_PRESERVED_STAGING"))
    Dir.mkdir(ARGV.fetch(1))
    File.write(File.join(ARGV.fetch(1), "DECOY"), "replacement\n")
    File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
  end
end
RUBY

  set +e
  output="$(QA_STAGING="$staging" QA_PRESERVED_STAGING="$preserved" QA_RACE_MARKER="$marker" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "cleanup post-move replacement exited $status: $output"
  assert_contains "$output" "RECOVERY_STAGING_BINDING_CHANGED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$preserved/old-flat-skill/SKILL.md"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "cleanup post-move replacement leaked install lock"

  set +e
  retry_output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  retry_status=$?
  set -e
  [[ "$retry_status" -eq 1 ]] || fail "cleanup post-move retry exited $retry_status: $retry_output"
  assert_contains "$retry_output" "RECOVERY_FAILED: unsafe migration staging receipt"
  assert_not_contains "$retry_output" "Errno::ENOENT"
  assert_file "$receipt"
}

test_companion_cleanup_post_move_exception_restores_receipted_staging() {
  local tmp target staging receipt injection marker output status cleanup_root
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-post-move-exception"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/fail-cleanup-post-move-verify.rb"
  marker="$tmp/cleanup-post-move-exception"
  mkdir -p "$staging/old-flat-skill"
  write_native_scw_state codex "$target"
  printf 'original staged skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryMoveHook
  def self.call(phase, source_parent, _source_name, destination_parent, _destination_name)
    return unless phase == :after_rename_before_verify
    return unless source_parent == ENV.fetch("QA_TARGET")
    return unless File.basename(destination_parent).start_with?(".agent-workflows-recovery-cleanup-")
    marker = ENV.fetch("QA_RACE_MARKER")
    return if File.exist?(marker)
    File.write(marker, "reached\n")
    raise "injected cleanup post-move verification failure"
  end
end
RUBY

  set +e
  output="$(QA_TARGET="$target" QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "cleanup post-move exception exited $status: $output"
  assert_contains "$output" "RECOVERY_CLEANUP_COMMITTED_UNVERIFIED"
  assert_contains "$output" "$staging"
  assert_contains "$output" "RECOVERY_FAILED: recovery paths changed during the operation"
  assert_file "$marker"
  assert_file "$staging/old-flat-skill/SKILL.md"
  assert_contains "$(cat "$staging/old-flat-skill/SKILL.md")" "original staged skill"
  assert_file "$receipt"
  [[ "$(cat "$receipt")" = "$staging" ]] || fail "cleanup post-move exception left a stale receipt: $(cat "$receipt")"
  cleanup_root="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-recovery-cleanup-*' -print -quit)"
  [[ -z "$cleanup_root" ]] || fail "cleanup post-move exception hid preserved staging under $cleanup_root"
}

test_companion_cleanup_root_replacement_cannot_move_staging_outside_target() {
  local tmp target staging receipt outside preserved_root injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-root-replacement"
  receipt="$target/.agent-workflows-migration-staging"
  outside="$tmp/outside-cleanup"
  preserved_root="$tmp/preserved-cleanup-root"
  injection="$tmp/replace-cleanup-root-before-move.rb"
  marker="$tmp/cleanup-root-replaced"
  mkdir -p "$staging/old-flat-skill" "$outside"
  write_native_scw_state codex "$target"
  printf 'original staged skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == ENV.fetch("QA_STAGING") &&
   ARGV.fetch(1).match?(%r{/\.agent-workflows-recovery-cleanup-[A-Za-z0-9]+/staging\z}) &&
   !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  cleanup_root = File.dirname(ARGV.fetch(1))
  File.rename(cleanup_root, ENV.fetch("QA_PRESERVED_CLEANUP_ROOT"))
  File.symlink(ENV.fetch("QA_OUTSIDE_CLEANUP"), cleanup_root)
  File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
elsif ARGV.length >= 4 && ARGV.fetch(0) == File.join(ENV.fetch("QA_OUTSIDE_CLEANUP"), "staging") &&
      ARGV.fetch(1) == ENV.fetch("QA_STAGING")
  File.write(ENV.fetch("QA_STAGING"), "block unsafe reversal\n") unless File.exist?(ENV.fetch("QA_STAGING"))
end
RUBY

  set +e
  output="$(QA_STAGING="$staging" QA_OUTSIDE_CLEANUP="$outside" \
    QA_PRESERVED_CLEANUP_ROOT="$preserved_root" QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "cleanup root replacement exited $status: $output"
  assert_contains "$output" "RECOVERY_CLEANUP_BINDING_CHANGED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$staging/old-flat-skill/SKILL.md"
  assert_file "$outside/SENTINEL"
  [[ ! -e "$outside/staging" ]] || fail "cleanup root replacement moved staging outside target"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "cleanup root replacement leaked install lock"
}

test_companion_cleanup_root_swap_during_deletion_preserves_all_entries() {
  local tmp target staging receipt preserved_root injection marker output status replacement
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-delete-swap"
  receipt="$target/.agent-workflows-migration-staging"
  preserved_root="$tmp/preserved-cleanup-root"
  injection="$tmp/swap-cleanup-root-during-removal.rb"
  marker="$tmp/cleanup-root-swapped"
  mkdir -p "$staging/old-flat-skill"
  write_native_scw_state codex "$target"
  chmod 0777 "$target"
  printf 'original staged skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
require "fileutils"

swap_cleanup_root = lambda do |cleanup_root|
  next if File.exist?(ENV.fetch("QA_RACE_MARKER"))

  File.rename(cleanup_root, ENV.fetch("QA_PRESERVED_CLEANUP_ROOT"))
  Dir.mkdir(cleanup_root)
  File.write(File.join(cleanup_root, "UNRELATED"), "unrelated replacement\n")
  File.write(ENV.fetch("QA_RACE_MARKER"), "swapped\n")
end

module FileUtils
  class << self
    alias qa_original_remove_entry remove_entry

    define_method(:remove_entry) do |path, force = false|
      if File.dirname(File.expand_path(path)) == ENV.fetch("QA_TARGET") &&
         File.basename(path).match?(/\A\.agent-workflows-recovery-cleanup-/)
        Object.const_get(:QA_SWAP_CLEANUP_ROOT).call(File.expand_path(path))
      end
      qa_original_remove_entry(path, force)
    end
  end
end

QA_SWAP_CLEANUP_ROOT = swap_cleanup_root

class << File
  alias qa_original_cleanup_rename rename

  def rename(source, destination)
    if File.basename(source).match?(/\A\.agent-workflows-recovery-cleanup-/) &&
       File.basename(destination).match?(/\A\.agent-workflows-recovery-delete-/)
      QA_SWAP_CLEANUP_ROOT.call(File.expand_path(source))
    end
    qa_original_cleanup_rename(source, destination)
  end
end
RUBY

  set +e
  output="$(QA_TARGET="$target" QA_PRESERVED_CLEANUP_ROOT="$preserved_root" QA_RACE_MARKER="$marker" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "cleanup deletion path swap exited $status: $output"
  assert_contains "$output" "RECOVERY_CLEANUP_BINDING_CHANGED"
  assert_file "$receipt"
  assert_file "$preserved_root/staging/old-flat-skill/SKILL.md"
  replacement="$(find "$tmp" -name UNRELATED -print -quit)"
  [[ -n "$replacement" ]] || fail "cleanup deletion path swap deleted the unrelated replacement"
  assert_contains "$(cat "$replacement")" "unrelated replacement"
  assert_contains "$output" "$(dirname "$replacement")"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "cleanup deletion path swap leaked install lock"
}

test_missing_metadata_backup_reports_restore_failure_without_corrupt_guidance() {
  local tmp target staging receipt metadata injection counter output status quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-backup-disappears"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/remove-backup-before-restore.rb"
  counter="$tmp/backup-attestation-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
if ARGV.length == 1 && File.basename(ARGV.fetch(0)) == "original-backup"
  counter = ENV.fetch("QA_BACKUP_COUNTER")
  count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
  File.write(counter, count)
  File.unlink(ARGV.fetch(0)) if count == 4 && File.file?(ARGV.fetch(0))
end
RUBY

  set +e
  output="$(QA_BACKUP_COUNTER="$counter" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "missing metadata backup exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_RESTORE_FAILED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ "$(grep -c 'RECOVERY_METADATA_RESTORE_FAILED' <<< "$output")" -eq 1 ]] || \
    fail "metadata restore failure was reported more than once: $output"
  ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "missing backup did not preserve recovery quarantine"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "missing backup leaked install lock"
}

test_transient_metadata_restore_failure_preserves_receipt_after_reversal() {
  local tmp target staging receipt metadata injection counter marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-transient-restore"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/fail-one-backup-attestation.rb"
  counter="$tmp/backup-attestation-count"
  marker="$tmp/transient-restore-failure"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
class << File
  alias qa_transient_original_lstat lstat
  def lstat(path)
    if File.basename(path) == "original-backup"
      counter = ENV.fetch("QA_BACKUP_COUNTER")
      count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
      File.write(counter, count)
      if count == 7
        File.write(ENV.fetch("QA_TRANSIENT_MARKER"), "failed once\n")
        raise Errno::EIO, path
      end
    end
    qa_transient_original_lstat(path)
  end
end
RUBY

  set +e
  output="$(QA_BACKUP_COUNTER="$counter" QA_TRANSIENT_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "transient metadata restore failure exited $status: $output"
  assert_contains "$output" "RECOVERY_FAILED: recovery paths changed during the operation"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "transient restore failure left staged skill in target"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "transient restore failure leaked install lock"
}

test_mid_rollback_backup_change_does_not_blame_intact_metadata() {
  local tmp target staging receipt metadata injection marker output status quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-backup-change"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/change-backup-after-first-move.rb"
  marker="$tmp/backup-changed"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == ENV.fetch("QA_STAGED_SKILL")
  quarantine = Dir.glob(File.join(ENV.fetch("QA_TARGET"), ".agent-workflows-install.json.recovery-*"), File::FNM_DOTMATCH).fetch(0)
  File.write(File.join(quarantine, "original-backup"), "changed backup\n")
  File.write(ENV.fetch("QA_RACE_MARKER"), "changed\n")
end
RUBY

  set +e
  output="$(QA_STAGED_SKILL="$staging/user-owned-skill" QA_TARGET="$target" QA_RACE_MARKER="$marker" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "mid-rollback backup change exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_RESTORE_FAILED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$metadata"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "mid-rollback backup change did not preserve quarantine"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "mid-rollback backup change leaked install lock"
}

test_companion_cleanup_rejects_mktemp_path_outside_target() {
  local tmp target staging receipt outside fake_bin real_mktemp output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-wrong-root"
  receipt="$target/.agent-workflows-migration-staging"
  outside="$tmp/outside-cleanup-root"
  fake_bin="$tmp/fake-bin"
  real_mktemp="$(command -v mktemp)"
  mkdir -p "$staging/old-flat-skill" "$outside" "$fake_bin"
  printf 'old flat skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" = *".agent-workflows-recovery-cleanup-XXXXXX"* ]]; then
  printf '%s\n' "$QA_OUTSIDE_CLEANUP_ROOT"
  exit 0
fi
exec "$QA_REAL_MKTEMP" "$@"
SH
  chmod +x "$fake_bin/mktemp"

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MKTEMP="$real_mktemp" \
    QA_OUTSIDE_CLEANUP_ROOT="$outside" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "companion cleanup accepted an out-of-target cleanup root"
  assert_file "$outside/SENTINEL"
  assert_file "$receipt"
  assert_file "$staging/old-flat-skill/SKILL.md"
  [[ ! -e "$target/skills/old-flat-skill" ]] || fail "unsafe cleanup root changed target tree"
  assert_contains "$output" "CLEANUP_PENDING"
}

test_companion_cleanup_rejects_symlinked_cleanup_root() {
  local tmp target staging receipt outside fake_bin real_mktemp output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-symlink-root"
  receipt="$target/.agent-workflows-migration-staging"
  outside="$tmp/outside-cleanup-root"
  fake_bin="$tmp/fake-bin"
  real_mktemp="$(command -v mktemp)"
  mkdir -p "$staging/old-flat-skill" "$outside/staging" "$fake_bin"
  printf 'old flat skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  printf 'foreign staging\n' > "$outside/staging/FOREIGN.md"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" = *".agent-workflows-recovery-cleanup-XXXXXX"* ]]; then
  cleanup_root="$QA_TARGET/.agent-workflows-recovery-cleanup-Symlink1"
  ln -s "$QA_OUTSIDE_CLEANUP_ROOT" "$cleanup_root"
  printf '%s\n' "$cleanup_root"
  exit 0
fi
exec "$QA_REAL_MKTEMP" "$@"
SH
  chmod +x "$fake_bin/mktemp"

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MKTEMP="$real_mktemp" QA_TARGET="$target" \
    QA_OUTSIDE_CLEANUP_ROOT="$outside" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "companion cleanup accepted a symlinked cleanup root"
  assert_file "$outside/SENTINEL"
  assert_file "$outside/staging/FOREIGN.md"
  assert_symlink "$target/.agent-workflows-recovery-cleanup-Symlink1"
  [[ ! -e "$outside/staging/.agent-workflows-flat-migration-cleanup-symlink-root" ]] || \
    fail "companion cleanup moved staging through a symlinked cleanup root"
  assert_file "$receipt"
  assert_file "$staging/old-flat-skill/SKILL.md"
  [[ ! -e "$target/skills/old-flat-skill" ]] || fail "symlinked cleanup root changed target tree"
  assert_contains "$output" "CLEANUP_PENDING"
  assert_contains "$output" "RECOVERY_CLEANUP_ROOT_REJECTED"
}

test_companion_cleanup_supports_world_writable_target() {
  local tmp target staging receipt output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-world-writable"
  receipt="$target/.agent-workflows-migration-staging"
  mkdir -p "$staging/old-flat-skill"
  write_native_scw_state codex "$target"
  chmod 0777 "$target"
  printf 'old flat skill\n' > "$staging/old-flat-skill/SKILL.md"
  printf '{"delivery_mode":"plugin-companion"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "world-writable target cleanup exited $status: $output"
  assert_not_contains "$output" "CLEANUP_PENDING"
  [[ ! -e "$receipt" ]] || fail "world-writable target left recovery receipt"
  [[ ! -e "$staging" ]] || fail "world-writable target left recovery staging"
  [[ -z "$(find "$target" -maxdepth 1 -name '.agent-workflows-recovery-cleanup-*' -print -quit)" ]] || \
    fail "world-writable target left recovery cleanup root"
  [[ -z "$(find "$target" -maxdepth 1 -name '.agent-workflows-recovery-delete-*' -print -quit)" ]] || \
    fail "world-writable target left captured recovery cleanup root"
}

test_recovery_hardlink_unavailable_is_named_without_blaming_metadata() {
  local tmp target staging receipt metadata injection output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-no-hardlinks"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/fail-recovery-hardlink.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryCaptureHook
  def self.call(phase)
    raise Errno::EOPNOTSUPP if phase == :before_link
  end
end
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 && "$status" -ne 65 ]] || fail "hardlink-unavailable recovery exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_CAPTURE_UNAVAILABLE"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "hardlink-unavailable recovery changed target tree"
}

test_recovery_capture_supports_system_ruby_2_6() {
  local tmp target staging receipt fake_bin marker output status original_path default_ruby system_ruby_version
  original_path="$PATH"
  default_ruby="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
  if [[ ! -x /usr/bin/ruby ]]; then
    return 0
  fi
  system_ruby_version="$(/usr/bin/ruby -e 'print RUBY_VERSION' 2>/dev/null || true)"
  case "$system_ruby_version" in
    2.6.*) ;;
    *) return 0 ;;
  esac
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-system-ruby"
  receipt="$target/.agent-workflows-migration-staging"
  fake_bin="$tmp/system-ruby-bin"
  local PATH="$fake_bin:$original_path"
  marker="$tmp/system-ruby-invocations"
  mkdir -p "$staging/user-owned-skill" "$fake_bin"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
cat > "$fake_bin/ruby" <<'SH'
#!/bin/sh
case "$*" in
  *RecoverySyscalls*|*RecoveryReceiptSyscalls*|*RecoveryRestoreSyscalls*|*RecoveryCleanupSyscalls*|*renameatx_np*)
  /usr/bin/ruby -e 'abort RUBY_VERSION unless RUBY_VERSION.start_with?("2.6.")'
  printf 'system-ruby-2.6\n' >> "$QA_SYSTEM_RUBY_MARKER"
  exec /usr/bin/ruby "$@"
  ;;
esac
exec "$QA_DEFAULT_RUBY" "$@"
SH
  chmod +x "$fake_bin/ruby"
  export PATH
  hash -r

  set +e
  output="$(BASH_ENV=/dev/null QA_SYSTEM_RUBY_MARKER="$marker" QA_DEFAULT_RUBY="$default_ruby" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "system Ruby recovery exited $status: $output"
  assert_file "$marker"
  assert_contains "$(cat "$marker")" "system-ruby-2.6"
  assert_not_contains "$output" "RECOVERY_METADATA_CLEANUP_PENDING"
  [[ ! -e "$receipt" ]] || fail "system Ruby recovery left receipt"
  [[ -z "$(find "$target" -maxdepth 1 -name '.agent-workflows-install.json.recovery-*' -print -quit)" ]] || \
    fail "system Ruby recovery left metadata quarantine"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
}

test_capture_runtime_load_failure_removes_empty_quarantine() {
  local tmp target staging receipt metadata injection output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-capture-load-failure"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/fail-capture-load.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
raise LoadError, "capture helper unavailable" if ARGV.length == 5 &&
                                                 ARGV.fetch(1) == ".agent-workflows-install.json"
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 && "$status" -ne 65 ]] || fail "capture load failure exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_CAPTURE_UNAVAILABLE"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ -z "$(find "$target" -maxdepth 1 -name '.agent-workflows-install.json.recovery-*' -print -quit)" ]] || \
    fail "capture load failure leaked an empty recovery quarantine"
  assert_file "$metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
}

test_capture_failure_after_sentinel_install_restores_original_metadata() {
  local tmp target staging receipt metadata injection output status before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-capture-undo"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/fail-after-sentinel-install.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  before="$(shasum "$metadata")"
  cat > "$injection" <<'RUBY'
module RecoveryCaptureHook
  def self.call(phase)
    raise Errno::EIO if phase == :after_rename
  end
end
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "post-sentinel capture failure unexpectedly succeeded"
  assert_file "$metadata"
  [[ "$before" = "$(shasum "$metadata")" ]] || fail "capture undo did not restore original metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
}

test_recovery_partial_backup_copy_failure_removes_quarantine() {
  local tmp target staging receipt metadata injection output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-partial-copy"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/fail-recovery-backup-copy.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryCaptureHook
  def self.call(phase)
    raise Errno::EIO if phase == :after_backup_copy
  end
end
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 && "$status" -ne 65 ]] || fail "partial backup copy exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_CAPTURE_UNAVAILABLE"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ -z "$(find "$target" -maxdepth 1 -name '.agent-workflows-install.json.recovery-*' -print -quit)" ]] || \
    fail "partial backup copy leaked recovery quarantine"
  assert_file "$metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
}

test_late_capture_failure_reports_corrupt_without_stale_quarantine_guidance() {
  local tmp target staging receipt metadata injection output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-late-capture"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/corrupt-snapshot-after-capture.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryCaptureHook
  def self.call(phase)
    return unless phase == :after_rename
    snapshot = Dir.glob(File.join(ENV.fetch("QA_TARGET"), ".agent-workflows-install.json.recovery-*", "metadata")).fetch(0)
    File.write(snapshot, "changed after capture\n")
  end
end
RUBY

  set +e
  output="$(QA_TARGET="$target" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "late capture corruption exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "Preserved recovery metadata quarantine"
  assert_file "$metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
}

test_late_capture_restore_failure_does_not_blame_intact_metadata() {
  local tmp target staging receipt metadata injection output status quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-late-restore-failure"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/corrupt-recovery-copies-after-capture.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryCaptureHook
  def self.call(phase)
    return unless phase == :after_rename
    quarantine = Dir.glob(File.join(ENV.fetch("QA_TARGET"), ".agent-workflows-install.json.recovery-*")).fetch(0)
    File.write(File.join(quarantine, "metadata"), "snapshot changed\n")
    File.write(File.join(quarantine, "original-backup"), "backup changed\n")
  end
end
RUBY

  set +e
  output="$(QA_TARGET="$target" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "late capture restore failure exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_RESTORE_FAILED"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' "$metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "late capture restore failure did not preserve quarantine"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "late capture restore failure leaked install lock"
}

test_snapshot_only_corruption_restores_before_reporting() {
  local tmp target staging receipt metadata fake_bin real_mv injection output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-snapshot-corrupt"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  fake_bin="$tmp/fake-bin"
  real_mv="$(command -v mv)"
  injection="$tmp/corrupt-snapshot-before-bound-staged-move.rb"
  mkdir -p "$staging/user-owned-skill" "$fake_bin"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 2 && "$1" = "$QA_STAGED_SKILL" && "$2" = "$QA_SKILLS_ROOT/" ]]; then
  snapshot="$(find "$QA_TARGET" -maxdepth 2 -path '*/.agent-workflows-install.json.recovery-*/metadata' -print -quit)"
  printf 'snapshot changed\n' > "$snapshot"
fi
exec "$QA_REAL_MV" "$@"
SH
  chmod +x "$fake_bin/mv"
  cat > "$injection" <<'RUBY'
if ARGV.length >= 4 && ARGV.fetch(0) == ENV.fetch("QA_STAGED_SKILL") &&
   ARGV.fetch(1) == File.join(ENV.fetch("QA_SKILLS_ROOT"), "user-owned-skill")
  snapshot = Dir.glob(File.join(ENV.fetch("QA_TARGET"), ".agent-workflows-install.json.recovery-*", "metadata")).first
  File.write(snapshot, "snapshot changed\n")
end
RUBY

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MV="$real_mv" QA_TARGET="$target" \
    QA_STAGED_SKILL="$staging/user-owned-skill" QA_SKILLS_ROOT="$target/skills" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "snapshot-only corruption exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "Preserved recovery metadata quarantine"
  [[ -z "$(find "$target" -maxdepth 1 -name '.agent-workflows-install.json.recovery-*' -print -quit)" ]] || \
    fail "restorable snapshot-only corruption leaked quarantine"
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' "$metadata"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "snapshot-only corruption changed target tree"
}

test_nul_in_recorded_source_is_corrupt_before_symlink_adoption() {
  local tmp target recorded_source link_source metadata output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  recorded_source="$tmp/recorded-source"
  link_source="$tmp/recordedsource"
  metadata="$target/.agent-workflows-install.json"
  mkdir -p "$target/bin" "$link_source/bin/agent_doctor"
  printf 'unmanaged\n' > "$link_source/bin/agent_doctor/sentinel"
  ln -s "$link_source/bin/agent_doctor" "$target/bin/agent_doctor"
  ruby -rjson -e '
    FileUtils.mkdir_p(File.dirname(ARGV.fetch(0)))
    source = ARGV.fetch(1).sub("recorded-source", "recorded\0source")
    File.write(ARGV.fetch(0), JSON.generate({"mode" => "symlink", "source" => source}) + "\n")
  ' -rfileutils "$metadata" "$recorded_source"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "NUL-coerced recorded source adopted an unmanaged symlink"
  assert_contains "$output" "Refusing unmanaged workflow doctor symlink"
  assert_symlink "$target/bin/agent_doctor"
  assert_file "$link_source/bin/agent_doctor/sentinel"
}

test_repeat_install_replays_recorded_companion_delivery_mode() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  write_native_scw_state codex "$target"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion \
    >"$tmp/first.out"
  mkdir -p "$target/skills/personal"
  printf 'personal\n' > "$target/skills/personal/SKILL.md"
  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/second.out"

  [[ ! -e "$target/skills/pr-batch" ]] || fail "repeat install changed companion delivery mode"
  grep -qxF 'personal' "$target/skills/personal/SKILL.md" || fail "repeat companion install changed an unrelated skill"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion"
  ' "$target/.agent-workflows-install.json"
}

test_repeat_flat_install_accepts_installer_created_uncommitted_skill() {
  local tmp source target mode marker
  tmp="$(mktemp -d)"
  source="$tmp/source"
  mkdir -p "$source"
  new_source_repo "$source"
  mkdir -p "$source/skills/uncommitted-local"
  printf '%s\n' '---' 'name: uncommitted-local' \
    'description: Exercise repeat installs from a dirty development checkout.' \
    '---' '' '# Uncommitted Local' > "$source/skills/uncommitted-local/SKILL.md"

  for mode in copy symlink; do
    target="$tmp/codex-home-$mode"
    "$source/bin/install-agent-workflows" --host codex --target "$target" \
      --mode "$mode" --delivery-mode flat >"$tmp/first-$mode.out"
    marker="source-edit-after-$mode-install"
    printf '\n%s\n' "$marker" >> "$source/skills/uncommitted-local/SKILL.md"
    "$source/bin/install-agent-workflows" --host codex --target "$target" \
      --mode "$mode" --delivery-mode flat >"$tmp/repeat-$mode.out"

    if [[ "$mode" = copy ]]; then
      cmp -s "$source/skills/uncommitted-local/SKILL.md" \
        "$target/skills/uncommitted-local/SKILL.md" || \
        fail "repeat copy install did not update the installer-created uncommitted skill"
    else
      [[ "$(readlink "$target/skills/uncommitted-local")" = \
         "$source/skills/uncommitted-local" ]] || \
        fail "repeat symlink install changed the installer-created uncommitted skill link"
    fi
    grep -qxF "$marker" "$target/skills/uncommitted-local/SKILL.md" || \
      fail "repeat $mode install lost the uncommitted source edit"
  done
}

test_repeat_flat_copy_install_blocks_modified_installer_created_uncommitted_skill() {
  local tmp source target output status metadata_before
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"
  mkdir -p "$source/skills/uncommitted-local"
  printf '%s\n' '---' 'name: uncommitted-local' \
    'description: Exercise target-modification fencing.' \
    '---' '' '# Uncommitted Local' > "$source/skills/uncommitted-local/SKILL.md"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/first.out"
  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"
  printf '\npersonal installed-copy edit\n' >> \
    "$target/skills/uncommitted-local/SKILL.md"
  printf '\nnew source edit\n' >> "$source/skills/uncommitted-local/SKILL.md"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat copy install replaced a modified uncommitted skill target"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  grep -qxF 'personal installed-copy edit' \
    "$target/skills/uncommitted-local/SKILL.md" || \
    fail "repeat copy install changed the modified uncommitted skill target"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "blocked uncommitted skill replay changed install metadata"
}

test_repeat_flat_copy_install_blocks_modified_recorded_targets() {
  local tmp source skill_target empty_target symlink_target doc_target output status metadata_before
  tmp="$(mktemp -d)"
  source="$tmp/source"
  mkdir -p "$source"
  new_source_repo "$source"

  skill_target="$tmp/skill-codex-home"
  "$source/bin/install-agent-workflows" --host codex --target "$skill_target" \
    --mode copy --delivery-mode flat >"$tmp/skill-first.out"
  cp "$skill_target/.agent-workflows-install.json" "$tmp/skill-metadata.before"
  metadata_before="$tmp/skill-metadata.before"
  printf '\npersonal recorded-skill edit\n' >> "$skill_target/skills/pr-batch/SKILL.md"
  printf 'nested personal file\n' > "$skill_target/skills/pr-batch/personal-notes.txt"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$skill_target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat copy install replaced a modified recorded skill"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  grep -qxF 'personal recorded-skill edit' "$skill_target/skills/pr-batch/SKILL.md" || \
    fail "blocked repeat install changed the modified recorded skill"
  grep -qxF 'nested personal file' "$skill_target/skills/pr-batch/personal-notes.txt" || \
    fail "blocked repeat install removed a nested personal skill file"
  cmp -s "$metadata_before" "$skill_target/.agent-workflows-install.json" || \
    fail "blocked recorded-skill replay changed install metadata"

  empty_target="$tmp/empty-directory-codex-home"
  "$source/bin/install-agent-workflows" --host codex --target "$empty_target" \
    --mode copy --delivery-mode flat >"$tmp/empty-first.out"
  cp "$empty_target/.agent-workflows-install.json" "$tmp/empty-metadata.before"
  mkdir -p "$empty_target/skills/pr-batch/personal-empty/nested-empty"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$empty_target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat copy install removed a personal empty skill directory"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  [[ -d "$empty_target/skills/pr-batch/personal-empty/nested-empty" ]] || \
    fail "blocked repeat install removed the personal empty skill directory"
  cmp -s "$tmp/empty-metadata.before" "$empty_target/.agent-workflows-install.json" || \
    fail "blocked empty-directory replay changed install metadata"

  symlink_target="$tmp/symlink-codex-home"
  "$source/bin/install-agent-workflows" --host codex --target "$symlink_target" \
    --mode copy --delivery-mode flat >"$tmp/symlink-first.out"
  mkdir -p "$tmp/personal-pr-batch"
  printf 'personal symlink target\n' > "$tmp/personal-pr-batch/SKILL.md"
  mv "$symlink_target/skills/pr-batch" "$tmp/installed-pr-batch.before-symlink"
  ln -s "$tmp/personal-pr-batch" "$symlink_target/skills/pr-batch"
  cp "$symlink_target/.agent-workflows-install.json" "$tmp/symlink-metadata.before"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$symlink_target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat copy install replaced an arbitrary recorded-skill symlink"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  [[ -L "$symlink_target/skills/pr-batch" && \
     "$(readlink "$symlink_target/skills/pr-batch")" = "$tmp/personal-pr-batch" ]] || \
    fail "blocked repeat install changed the recorded-skill symlink"
  cmp -s "$tmp/symlink-metadata.before" "$symlink_target/.agent-workflows-install.json" || \
    fail "blocked recorded-skill symlink replay changed install metadata"

  doc_target="$tmp/doc-codex-home"
  "$source/bin/install-agent-workflows" --host codex --target "$doc_target" \
    --mode copy --delivery-mode flat >"$tmp/doc-first.out"
  cp "$doc_target/.agent-workflows-install.json" "$tmp/doc-metadata.before"
  printf 'personal recorded-doc edit\n' > "$doc_target/docs/coordination-backend.md"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$doc_target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat copy install replaced a modified recorded pack document"
  assert_contains "$output" "Refusing to replace unowned pack document"
  grep -qxF 'personal recorded-doc edit' "$doc_target/docs/coordination-backend.md" || \
    fail "blocked repeat install changed the modified recorded pack document"
  cmp -s "$tmp/doc-metadata.before" "$doc_target/.agent-workflows-install.json" || \
    fail "blocked recorded-document replay changed install metadata"
}

test_repeat_flat_copy_install_uses_fingerprints_without_git_history() {
  local tmp source target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/first.out"
  mv "$source/.git" "$tmp/source.git"
  printf '\nnon-git managed-v2\n' >> "$source/skills/pr-batch/SKILL.md"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/non-git-upgrade.out"
  grep -qxF 'non-git managed-v2' "$target/skills/pr-batch/SKILL.md" || \
    fail "recorded fingerprint did not authorize an untouched non-git copy upgrade"

  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  printf '\npersonal non-git target edit\n' >> "$target/skills/pr-batch/SKILL.md"
  printf '\nnon-git managed-v3\n' >> "$source/skills/pr-batch/SKILL.md"
  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "non-git copy upgrade replaced a modified installed skill"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  grep -qxF 'personal non-git target edit' "$target/skills/pr-batch/SKILL.md" || \
    fail "blocked non-git upgrade changed the modified installed skill"
  cmp -s "$tmp/metadata.before" "$target/.agent-workflows-install.json" || \
    fail "blocked non-git upgrade changed install metadata"
}

test_flat_copy_migrates_to_companion_with_fingerprints_without_git_history() {
  local tmp source target modified_target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"
  mv "$source/.git" "$tmp/source.git"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/flat.out"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    fingerprints = metadata.fetch("managed_skill_copy_fingerprints")
    abort metadata.inspect unless metadata["source_revision"] == "unknown" && !fingerprints.empty?
  ' "$target/.agent-workflows-install.json"
  write_native_scw_state codex "$target"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode plugin-companion >"$tmp/companion.out"

  [[ ! -e "$target/skills/pr-batch" ]] || \
    fail "fingerprint-authorized companion migration retained a managed flat skill"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion"
  ' "$target/.agent-workflows-install.json"

  modified_target="$tmp/modified-codex-home"
  "$source/bin/install-agent-workflows" --host codex --target "$modified_target" \
    --mode copy --delivery-mode flat >"$tmp/modified-flat.out"
  printf '\npersonal non-git migration edit\n' >> "$modified_target/skills/pr-batch/SKILL.md"
  write_native_scw_state codex "$modified_target"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$modified_target" \
    --mode copy --delivery-mode plugin-companion 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "fingerprints authorized migration of a modified flat skill"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  grep -qxF 'personal non-git migration edit' "$modified_target/skills/pr-batch/SKILL.md" || \
    fail "blocked fingerprint migration changed the modified flat skill"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "flat"
  ' "$modified_target/.agent-workflows-install.json"
}

test_copy_metadata_fingerprint_matches_delivery_state_verifier() {
  local tmp source target recorded_fingerprint verified_fingerprint
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  mkdir -p "$source/skills/fingerprint-fixture/bin"
  mkdir -p "$source/skills/fingerprint-fixture/empty/nested"
  printf '%s\n' '---' 'name: fingerprint-fixture' 'description: Fingerprint fixture.' '---' > \
    "$source/skills/fingerprint-fixture/SKILL.md"
  printf '#!/bin/sh\nexit 0\n' > "$source/skills/fingerprint-fixture/bin/run"
  chmod +x "$source/skills/fingerprint-fixture/bin/run"
  ln -s SKILL.md "$source/skills/fingerprint-fixture/skill-link"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/install.out"

  recorded_fingerprint="$(jq -r '.managed_skill_copy_fingerprints["fingerprint-fixture"]' \
    "$target/.agent-workflows-install.json")"
  verified_fingerprint="$(ruby -e \
    'load ARGV.shift; puts AgentWorkflowsDeliveryState.directory_fingerprint(ARGV.fetch(0))' \
    "$source/bin/agent-workflows-delivery-state" "$target/skills/fingerprint-fixture")"

  [[ "$recorded_fingerprint" != "null" && -n "$recorded_fingerprint" ]] || \
    fail "installer metadata omitted the fixture skill fingerprint"
  [[ "$recorded_fingerprint" = "$verified_fingerprint" ]] || \
    fail "installer and delivery-state directory fingerprints drifted"
}

test_installation_docs_describe_managed_coordination_doc_fingerprints() {
  local docs changelog
  docs="$(cat "$ROOT/docs/installation-and-upgrades.md")"
  changelog="$(cat "$ROOT/CHANGELOG.md")"

  assert_contains "$docs" '<target>/docs/user-facing-coordination.md'
  assert_contains "$docs" '<target>/docs/execution-provenance-schema.md'
  assert_contains "$docs" '<target>/bin/validate-execution-provenance'
  assert_contains "$docs" 'managed_skill_copy_fingerprints'
  assert_contains "$docs" 'managed_pack_doc_copy_fingerprints'
  assert_contains "$docs" 'including every installed'
  assert_contains "$docs" '<target>/docs/solutions/*'
  assert_contains "$docs" 'installer refuses to'
  assert_contains "$docs" 'replace a modified'
  assert_contains "$changelog" 'Copy-install fingerprints'
}

test_repeat_copy_install_accepts_edited_installer_created_uncommitted_pack_doc() {
  local tmp source target personal_target output status metadata_before doc_name
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  personal_target="$tmp/personal-codex-home"
  doc_name="uncommitted-pack-doc.md"
  mkdir -p "$source"
  new_source_repo "$source"
  ruby -e '
    path = ARGV.fetch(0)
    text = File.read(path)
    insertion = "  user-facing-coordination.md\n  uncommitted-pack-doc.md\n)"
    abort "missing pack_docs insertion point" unless text.sub!("  user-facing-coordination.md\n)", insertion)
    File.write(path, text)
  ' "$source/bin/install-agent-workflows"
  printf 'managed-v1\n' > "$source/docs/$doc_name"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/first.out"
  printf 'managed-v2\n' > "$source/docs/$doc_name"
  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/repeat.out"
  grep -qxF 'managed-v2' "$target/docs/$doc_name" || \
    fail "repeat copy install did not update the installer-created uncommitted pack document"

  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"
  printf 'personal installed-doc edit\n' > "$target/docs/$doc_name"
  printf 'managed-v3\n' > "$source/docs/$doc_name"
  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "repeat copy install replaced a modified uncommitted pack document"
  assert_contains "$output" "Refusing to replace unowned pack document"
  grep -qxF 'personal installed-doc edit' "$target/docs/$doc_name" || \
    fail "repeat copy install changed the modified uncommitted pack document"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "blocked uncommitted document replay changed install metadata"

  mkdir -p "$personal_target/docs"
  printf 'personal-predating-first-install\n' > "$personal_target/docs/$doc_name"
  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$personal_target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "first copy install replaced a personal uncommitted pack document collision"
  assert_contains "$output" "Refusing to replace unowned pack document"
  grep -qxF 'personal-predating-first-install' "$personal_target/docs/$doc_name" || \
    fail "first copy install changed the personal uncommitted pack document"
  [[ ! -e "$personal_target/.agent-workflows-install.json" ]] || \
    fail "blocked first install committed metadata"
}

test_repeat_copy_install_blocks_modified_solution_document() {
  local tmp source target output status metadata_before solution_name
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  solution_name="coordination-unknown-state.md"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat >"$tmp/first.out"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    fingerprints = metadata.fetch("managed_pack_doc_copy_fingerprints")
    abort fingerprints.inspect unless fingerprints.key?(ARGV.fetch(1))
  ' "$target/.agent-workflows-install.json" "solutions/$solution_name"

  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"
  printf 'personal installed-solution edit\n' > "$target/docs/solutions/$solution_name"
  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" \
    --mode copy --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat copy install replaced a modified solution document"
  assert_contains "$output" "Refusing to replace unowned pack document"
  assert_contains "$output" "$target/docs/solutions/$solution_name"
  grep -qxF 'personal installed-solution edit' "$target/docs/solutions/$solution_name" || \
    fail "repeat copy install changed the modified solution document"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "blocked solution document replay changed install metadata"
}

test_flat_upgrade_refuses_newly_packaged_skill_collision() {
  local tmp source target output status metadata_before
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  git -C "$source" rm -r --quiet skills/close-session
  git -C "$source" commit --quiet -m "simulate source before close-session"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat \
    >"$tmp/legacy-install.out"

  mkdir -p "$target/skills/close-session"
  printf 'personal close-session sentinel\n' > "$target/skills/close-session/SKILL.md"
  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"

  rsync -a "$ROOT/skills/close-session" "$source/skills/"
  git -C "$source" add skills/close-session
  git -C "$source" commit --quiet -m "add packaged close-session"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "flat upgrade replaced a newly colliding personal skill"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  assert_contains "$output" "$target/skills/close-session"
  grep -qxF 'personal close-session sentinel' "$target/skills/close-session/SKILL.md" || \
    fail "flat upgrade changed the personal close-session skill"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "flat collision changed install metadata"
}

test_flat_upgrade_late_preflight_failure_does_not_strand_new_skill() {
  local tmp source target output status metadata_before
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  git -C "$source" rm -r --quiet skills/close-session
  git -C "$source" commit --quiet -m "simulate source before close-session"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat \
    >"$tmp/legacy-install.out"
  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"

  rsync -a "$ROOT/skills/close-session" "$source/skills/"
  git -C "$source" add skills/close-session
  git -C "$source" commit --quiet -m "add packaged close-session"
  mv "$target/bin/agent-workflows-status" "$tmp/agent-workflows-status"
  mkdir "$target/bin/agent-workflows-status"
  printf 'personal helper collision\n' > "$target/bin/agent-workflows-status/sentinel"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "flat upgrade accepted a late helper collision"
  assert_contains "$output" "Refusing to replace non-file path"
  [[ ! -e "$target/skills/close-session" ]] || \
    fail "failed flat upgrade stranded a newly packaged skill"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "failed flat upgrade changed install metadata"

  mv "$target/bin/agent-workflows-status" "$tmp/personal-helper-collision"
  mv "$tmp/agent-workflows-status" "$target/bin/agent-workflows-status"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat \
    >"$tmp/retry.out"
  assert_file "$target/skills/close-session/SKILL.md"
}

test_flat_copy_upgrade_refuses_newly_packaged_doc_collision() {
  local tmp source target output status metadata_before
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  git -C "$source" rm --quiet docs/user-facing-coordination.md
  ruby -e '
    path = ARGV.fetch(0)
    text = File.read(path)
    abort "missing pack doc entry" unless text.sub!("  user-facing-coordination.md\n", "")
    File.write(path, text)
  ' "$source/bin/install-agent-workflows"
  git -C "$source" add bin/install-agent-workflows
  git -C "$source" commit --quiet -m "simulate source before coordination doc"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat \
    >"$tmp/legacy-install.out"

  printf 'personal coordination sentinel\n' > "$target/docs/user-facing-coordination.md"
  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"

  install -m 0644 "$ROOT/docs/user-facing-coordination.md" "$source/docs/user-facing-coordination.md"
  install -m 0755 "$ROOT/bin/install-agent-workflows" "$source/bin/install-agent-workflows"
  printf '\nupgrade-managed-doc-marker\n' >> "$source/docs/coordination-backend.md"
  git -C "$source" add docs/user-facing-coordination.md docs/coordination-backend.md bin/install-agent-workflows
  git -C "$source" commit --quiet -m "add coordination doc"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "flat copy upgrade replaced a newly colliding personal document"
  assert_contains "$output" "Refusing to replace unowned pack document"
  assert_contains "$output" "$target/docs/user-facing-coordination.md"
  grep -qxF 'personal coordination sentinel' "$target/docs/user-facing-coordination.md" || \
    fail "flat copy upgrade changed the personal coordination document"
  assert_not_contains "$(cat "$target/docs/coordination-backend.md")" "upgrade-managed-doc-marker"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "flat document collision changed install metadata"

  mv "$target/docs/user-facing-coordination.md" "$tmp/personal-coordination.md"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat \
    >"$tmp/successful-upgrade.out"
  cmp -s "$target/docs/user-facing-coordination.md" "$source/docs/user-facing-coordination.md" || \
    fail "flat copy upgrade did not install an absent coordination document"
  cmp -s "$target/docs/coordination-backend.md" "$source/docs/coordination-backend.md" || \
    fail "flat copy upgrade did not update a previously managed document"
}

test_flat_copy_upgrade_refuses_pack_doc_directory_before_mutation() {
  local tmp source target output status metadata_before
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat \
    >"$tmp/initial-install.out"
  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"

  mv "$target/docs/coordination-backend.md" "$tmp/coordination-backend.md"
  mkdir "$target/docs/coordination-backend.md"
  printf 'personal directory sentinel\n' > "$target/docs/coordination-backend.md/sentinel"
  printf '\nlate-preflight-workflow-marker\n' >> "$source/workflows/pr-processing.md"
  git -C "$source" add workflows/pr-processing.md
  git -C "$source" commit --quiet -m "update managed workflow"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "flat upgrade replaced a pack document directory"
  assert_contains "$output" "Refusing to replace non-file path"
  assert_contains "$output" "$target/docs/coordination-backend.md"
  assert_not_contains "$(cat "$target/workflows/pr-processing.md")" "late-preflight-workflow-marker"
  assert_file "$target/docs/coordination-backend.md/sentinel"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "pack document directory collision changed install metadata"

  mv "$target/docs/coordination-backend.md" "$tmp/personal-coordination-directory"
  mv "$tmp/coordination-backend.md" "$target/docs/coordination-backend.md"
  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat \
    >"$tmp/retry.out"
  assert_contains "$(cat "$target/workflows/pr-processing.md")" "late-preflight-workflow-marker"
}

test_symlink_upgrade_refuses_newly_packaged_doc_collisions_before_mutation() {
  local tmp source legacy_source target destination output status metadata_before
  local workflow_before license_before skill_before coordination_before variant
  tmp="$(mktemp -d)"
  source="$tmp/source"
  legacy_source="$tmp/legacy-source"
  mkdir -p "$source" "$legacy_source"
  new_source_repo "$source"
  new_source_repo "$legacy_source"

  git -C "$legacy_source" rm --quiet docs/user-facing-coordination.md
  ruby -e '
    path = ARGV.fetch(0)
    text = File.read(path)
    abort "missing pack doc entry" unless text.sub!("  user-facing-coordination.md\n", "")
    File.write(path, text)
  ' "$legacy_source/bin/install-agent-workflows"
  git -C "$legacy_source" add bin/install-agent-workflows
  git -C "$legacy_source" commit --quiet -m "simulate source before coordination doc"

  for variant in symlink file; do
    target="$tmp/codex-home-$variant"
    "$legacy_source/bin/install-agent-workflows" --host codex --target "$target" \
      --mode symlink --delivery-mode flat >"$tmp/legacy-$variant.out"
    destination="$target/docs/user-facing-coordination.md"
    if [[ "$variant" = symlink ]]; then
      printf 'personal coordination sentinel\n' > "$tmp/personal-coordination.md"
      ln -s "$tmp/personal-coordination.md" "$destination"
    else
      printf 'personal coordination sentinel\n' > "$destination"
    fi

    workflow_before="$(readlink "$target/workflows")"
    license_before="$(readlink "$target/LICENSE")"
    skill_before="$(readlink "$target/skills/pr-batch")"
    coordination_before="$(readlink "$target/docs/coordination-backend.md")"
    metadata_before="$tmp/metadata-$variant.before"
    cp "$target/.agent-workflows-install.json" "$metadata_before"

    set +e
    output="$("$source/bin/install-agent-workflows" --host codex --target "$target" \
      --mode symlink --delivery-mode flat 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "symlink upgrade replaced a newly colliding personal $variant"
    assert_contains "$output" "Refusing to replace unowned pack document"
    assert_contains "$output" "$destination"
    if [[ "$variant" = symlink ]]; then
      [[ "$(readlink "$destination")" = "$tmp/personal-coordination.md" ]] || \
        fail "symlink upgrade changed the personal coordination symlink"
    else
      grep -qxF 'personal coordination sentinel' "$destination" || \
        fail "symlink upgrade changed the personal coordination file"
    fi
    [[ "$(readlink "$target/workflows")" = "$workflow_before" ]] || \
      fail "symlink document collision partially changed workflows"
    [[ "$(readlink "$target/LICENSE")" = "$license_before" ]] || \
      fail "symlink document collision partially changed LICENSE"
    [[ "$(readlink "$target/skills/pr-batch")" = "$skill_before" ]] || \
      fail "symlink document collision partially changed skills"
    [[ "$(readlink "$target/docs/coordination-backend.md")" = "$coordination_before" ]] || \
      fail "symlink document collision partially changed an earlier pack document"
    cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
      fail "symlink document collision changed install metadata"
  done
}

test_repeat_companion_install_blocks_new_current_native_skill_collision() {
  local tmp source target plugin_root metadata_before output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  plugin_root="$target/plugins/cache/agent-workflows/scw/0.1.0"
  mkdir -p "$source"
  new_source_repo "$source"
  write_native_scw_state codex "$target"

  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion \
    >"$tmp/first.out"
  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"

  mkdir -p "$source/skills/current-only" "$plugin_root/skills/current-only" "$target/skills/current-only"
  printf 'current source\n' > "$source/skills/current-only/SKILL.md"
  git -C "$source" add skills/current-only
  git -C "$source" commit --quiet -m "add current skill"
  printf 'current native\n' > "$plugin_root/skills/current-only/SKILL.md"
  printf 'personal collision\n' > "$target/skills/current-only/SKILL.md"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat companion install replaced a newly colliding skill"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  assert_contains "$output" "$target/skills/current-only"
  grep -qxF 'personal collision' "$target/skills/current-only/SKILL.md" || \
    fail "repeat companion collision changed the flat path"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "repeat companion collision changed install metadata"
}

test_repeat_companion_install_blocks_native_skill_removed_from_current_source() {
  local tmp source target plugin_root metadata_before skill_to_remove output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  plugin_root="$target/plugins/cache/agent-workflows/scw/0.1.0"
  mkdir -p "$source"
  new_source_repo "$source"
  write_native_scw_state codex "$target"

  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode plugin-companion \
    >"$tmp/first.out"
  cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
  metadata_before="$tmp/metadata.before"

  mkdir -p "$plugin_root/skills/address-review" "$target/skills/address-review"
  cp "$source/skills/address-review/SKILL.md" "$plugin_root/skills/address-review/SKILL.md"
  skill_to_remove="$source/skills/address-review"
  [[ "$skill_to_remove" = "$tmp/source/skills/address-review" && -d "$skill_to_remove" && ! -L "$skill_to_remove" ]] || \
    fail "refusing to remove unexpected test skill path: $skill_to_remove"
  rm -r -- "$skill_to_remove"
  git -C "$source" add -u skills/address-review
  git -C "$source" commit --quiet -m "remove address-review skill"
  printf 'flat duplicate\n' > "$target/skills/address-review/SKILL.md"

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "repeat companion install ignored a native skill removed from current source"
  assert_contains "$output" "DELIVERY_MODE_CONFLICT"
  assert_contains "$output" "$target/skills/address-review"
  grep -qxF 'flat duplicate' "$target/skills/address-review/SKILL.md" || \
    fail "removed-source collision changed the flat path"
  cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
    fail "removed-source collision changed install metadata"
}

test_companion_install_rejects_mixed_valid_and_invalid_candidate_native_roots() {
  local tmp source target stale_root candidate_root manifest_dir metadata_before output status host

  for host in codex claude; do
    tmp="$(mktemp -d)"
    source="$tmp/source"
    target="$tmp/$host-home"
    stale_root="$target/plugins/cache/agent-workflows/scw/0.1.0"
    candidate_root="$target/plugins/cache/agent-workflows/scw/0.2.0"
    mkdir -p "$source"
    new_source_repo "$source"
    write_native_scw_state "$host" "$target"

    "$source/bin/install-agent-workflows" --host "$host" --target "$target" --delivery-mode plugin-companion \
      >"$tmp/first.out"
    cp "$target/.agent-workflows-install.json" "$tmp/metadata.before"
    metadata_before="$tmp/metadata.before"

    mkdir -p "$source/skills/mixed-root" "$candidate_root/skills/mixed-root" "$target/skills/mixed-root"
    printf 'current source\n' > "$source/skills/mixed-root/SKILL.md"
    git -C "$source" add skills/mixed-root
    git -C "$source" commit --quiet -m "add mixed-root skill"
    printf 'candidate native\n' > "$candidate_root/skills/mixed-root/SKILL.md"
    manifest_dir="$candidate_root/$([[ "$host" = codex ]] && printf .codex-plugin || printf .claude-plugin)"
    mkdir -p "$manifest_dir"
    printf '{malformed\n' > "$manifest_dir/plugin.json"
    printf 'personal collision\n' > "$target/skills/mixed-root/SKILL.md"

    if [[ "$host" = claude ]]; then
      ruby -rjson -e '
        path, stale_root, candidate_root = ARGV
        receipts = [
          {"scope" => "user", "installPath" => stale_root, "version" => "0.1.0"},
          {"scope" => "user", "installPath" => candidate_root, "version" => "0.2.0"}
        ]
        File.write(path, JSON.generate({"version" => 2, "plugins" => {"scw@agent-workflows" => receipts}}) + "\n")
      ' "$target/plugins/installed_plugins.json" "$stale_root" "$candidate_root"
    fi

    set +e
    if [[ "$host" = codex ]]; then
      output="$(QA_CODEX_PLUGIN_VERSION="0.2.0" \
        "$source/bin/install-agent-workflows" --host "$host" --target "$target" 2>&1)"
      status=$?
    else
      output="$("$source/bin/install-agent-workflows" --host "$host" --target "$target" 2>&1)"
      status=$?
    fi
    set -e

    [[ "$status" -ne 0 ]] || fail "$host companion install ignored an invalid candidate native root"
    assert_contains "$output" "DELIVERY_MODE_CONFLICT"
    grep -qxF 'personal collision' "$target/skills/mixed-root/SKILL.md" || \
      fail "$host mixed-root failure changed the flat path"
    cmp -s "$metadata_before" "$target/.agent-workflows-install.json" || \
      fail "$host mixed-root failure changed install metadata"
  done
}

test_invalid_recorded_delivery_mode_fails_before_mutation() {
  local tmp target output status metadata_before sentinel_before target_paths_before variant
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target"
  printf 'preserve me\n' > "$target/sentinel.txt"
  ruby -rjson -e '
    path, source = ARGV
    metadata = {
      "host" => "codex",
      "mode" => "copy",
      "delivery_mode" => "hybrid",
      "source" => source,
      "source_revision" => "0000000000000000000000000000000000000000"
    }
    File.write(path, JSON.pretty_generate(metadata) + "\n")
  ' "$target/.agent-workflows-install.json" "$ROOT"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"
  sentinel_before="$(shasum "$target/sentinel.txt")"
  target_paths_before="$(find "$target" -print | LC_ALL=C sort)"

  for variant in omitted explicit; do
    set +e
    if [[ "$variant" = omitted ]]; then
      output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
    else
      output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
    fi
    status=$?
    set -e

    [[ "$status" -eq 64 ]] || fail "invalid recorded delivery mode exited $status on $variant path: $output"
    assert_contains "$output" "Installed metadata delivery_mode must be flat or plugin-companion."
    assert_contains "$output" "Restore a valid backup"
    assert_not_contains "$output" "JSON::ParserError"
    assert_not_contains "$output" "common.rb"
    [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
      fail "invalid recorded delivery mode mutated metadata on $variant path"
    [[ "$sentinel_before" = "$(shasum "$target/sentinel.txt")" ]] || \
      fail "invalid recorded delivery mode mutated sentinel on $variant path"
    [[ "$target_paths_before" = "$(find "$target" -print | LC_ALL=C sort)" ]] || \
      fail "invalid recorded delivery mode changed the target tree on $variant path"
    [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "invalid recorded delivery mode created install lock"
    [[ ! -e "$target/.agent-workflows-migration-staging" ]] || fail "invalid recorded delivery mode created staging receipt"
    [[ ! -e "$target/skills" ]] || fail "invalid recorded delivery mode created a flat skill layout"
  done
}

test_newline_recorded_delivery_modes_fail_before_mutation() {
  local value variant tmp target output status metadata_before target_paths_before
  for value in '"\n"' '"flat\n"'; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    mkdir -p "$target"
    printf '{"delivery_mode":%s}\n' "$value" > "$target/.agent-workflows-install.json"
    metadata_before="$(shasum "$target/.agent-workflows-install.json")"
    target_paths_before="$(find "$target" -print | LC_ALL=C sort)"

    for variant in omitted explicit; do
      set +e
      if [[ "$variant" = omitted ]]; then
        output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
      else
        output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
      fi
      status=$?
      set -e

      [[ "$status" -eq 64 ]] || fail "newline recorded delivery mode exited $status on $variant path: $output"
      assert_contains "$output" "Installed metadata delivery_mode must be flat or plugin-companion"
      assert_contains "$output" "Restore a valid backup"
      assert_not_contains "$output" "JSON::ParserError"
      [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
        fail "newline recorded mode changed metadata on $variant path"
      [[ "$target_paths_before" = "$(find "$target" -print | LC_ALL=C sort)" ]] || \
        fail "newline recorded mode changed target tree on $variant path"
      [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "newline recorded mode created install lock"
      [[ ! -e "$target/skills" ]] || fail "newline recorded mode created flat skills"
    done
  done
}

test_corrupt_install_metadata_fails_closed_with_recovery_guidance() {
  local tmp target output status metadata_before target_paths_before variant
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target"
  printf '{"delivery_mode":' > "$target/.agent-workflows-install.json"
  printf 'preserve me\n' > "$target/sentinel.txt"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"
  target_paths_before="$(find "$target" -print | LC_ALL=C sort)"

  for variant in omitted explicit; do
    set +e
    if [[ "$variant" = omitted ]]; then
      output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
    else
      output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat 2>&1)"
    fi
    status=$?
    set -e

    [[ "$status" -eq 65 ]] || fail "corrupt install metadata exited $status on the $variant delivery-mode path: $output"
    assert_contains "$output" "CORRUPT_INSTALL_METADATA"
    assert_contains "$output" "$target/.agent-workflows-install.json"
    assert_contains "$output" "Restore a valid backup"
    assert_contains "$output" "new empty target"
    assert_contains "$output" "--delivery-mode flat|plugin-companion"
    assert_not_contains "$output" "or remove"
    [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
      fail "corrupt metadata failure changed install metadata"
    [[ "$target_paths_before" = "$(find "$target" -print | LC_ALL=C sort)" ]] || \
      fail "corrupt metadata failure changed the target tree"
    [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "corrupt metadata failure created install lock"
    [[ ! -e "$target/skills" ]] || fail "corrupt metadata failure created a flat skill layout"
  done
}

test_non_object_install_metadata_is_corrupt() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target"
  printf '[]\n' > "$target/.agent-workflows-install.json"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "non-object install metadata exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "non-object metadata created install lock"
  [[ ! -e "$target/skills" ]] || fail "non-object metadata created flat skills"
}

test_schema_invalid_delivery_mode_fails_before_pending_recovery_mutation() {
  local variant value tmp target staging receipt output status metadata_before receipt_before target_paths_before
  for variant in array null empty; do
    case "$variant" in
      array) value='["flat"]' ;;
      null) value=null ;;
      empty) value='""' ;;
    esac
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    staging="$target/.agent-workflows-flat-migration-repro"
    receipt="$target/.agent-workflows-migration-staging"
    mkdir -p "$staging/$variant-owned-skill"
    printf '%s-owned\n' "$variant" > "$staging/$variant-owned-skill/SKILL.md"
    printf '{"delivery_mode":%s}\n' "$value" > "$target/.agent-workflows-install.json"
    printf '%s\n' "$staging" > "$receipt"
    metadata_before="$(shasum "$target/.agent-workflows-install.json")"
    receipt_before="$(shasum "$receipt")"
    target_paths_before="$(find "$target" -print | LC_ALL=C sort)"

    set +e
    output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
    status=$?
    set -e

    [[ "$status" -eq 65 ]] || fail "schema-invalid $variant delivery mode exited $status: $output"
    assert_file "$receipt"
    [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "schema-invalid $variant metadata changed pending receipt"
    assert_file "$staging/$variant-owned-skill/SKILL.md"
    [[ ! -e "$target/skills/$variant-owned-skill" ]] || fail "schema-invalid $variant metadata restored staged skill"
    [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
      fail "schema-invalid $variant metadata changed install metadata"
    [[ "$target_paths_before" = "$(find "$target" -print | LC_ALL=C sort)" ]] || \
      fail "schema-invalid $variant metadata changed the target tree"
    [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "schema-invalid $variant metadata created install lock"
    assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  done
}

test_recovery_metadata_race_fails_before_pending_recovery_mutation() {
  local tmp target staging receipt injection counter output status receipt_before target_paths_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-race"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/corrupt-after-first-metadata-read.rb"
  counter="$tmp/metadata-read"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  target_paths_before="$(find "$target" -print | LC_ALL=C sort)"
  cat > "$injection" <<'RUBY'
require "json"
module CorruptAfterFirstMetadataRead
  def parse(source, *args)
    value = super
    counter = ENV.fetch("QA_METADATA_READ_COUNTER")
    unless File.exist?(counter)
      File.write(counter, "read\n")
      File.write(ENV.fetch("QA_INSTALL_METADATA"), "{\"delivery_mode\":[\"flat\"]}\n")
    end
    value
  end
end
JSON.singleton_class.prepend(CorruptAfterFirstMetadataRead)
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$target/.agent-workflows-install.json" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "recovery-time corruption changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "recovery-time corruption restored staged skill"
  [[ "$target_paths_before" = "$(find "$target" -print | LC_ALL=C sort)" ]] || \
    fail "recovery-time corruption changed the target tree"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "recovery-time corruption leaked install lock"
  [[ "$status" -eq 65 ]] || fail "recovery-time corrupt metadata exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "Preserved pending recovery receipt"
}

test_recovery_metadata_path_race_fails_before_pending_recovery_mutation() {
  local tmp target staging receipt outside injection counter output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-path-race"
  receipt="$target/.agent-workflows-migration-staging"
  outside="$tmp/outside-metadata.json"
  injection="$tmp/replace-metadata-with-symlink.rb"
  counter="$tmp/metadata-read"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '{"delivery_mode":"flat"}\n' > "$outside"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  cat > "$injection" <<'RUBY'
require "json"
module ReplaceMetadataWithSymlinkAfterFirstRead
  def parse(source, *args)
    value = super
    counter = ENV.fetch("QA_METADATA_READ_COUNTER")
    unless File.exist?(counter)
      File.write(counter, "read\n")
      metadata = ENV.fetch("QA_INSTALL_METADATA")
      File.unlink(metadata)
      File.symlink(ENV.fetch("QA_OUTSIDE_METADATA"), metadata)
    end
    value
  end
end
JSON.singleton_class.prepend(ReplaceMetadataWithSymlinkAfterFirstRead)
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$target/.agent-workflows-install.json" \
    QA_OUTSIDE_METADATA="$outside" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "path-race corruption changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "path-race corruption restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "path-race corruption leaked install lock"
  [[ "$status" -eq 65 ]] || fail "recovery-time metadata path race exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "Preserved pending recovery receipt"
}

test_metadata_parser_runtime_failure_is_corrupt() {
  local tmp target staging receipt injection output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-parser-failure"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/parser-runtime-failure.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  cat > "$injection" <<'RUBY'
require "json"
module FailMetadataParser
  def parse(*)
    raise "injected metadata parser failure"
  end
end
JSON.singleton_class.prepend(FailMetadataParser)
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "parser failure changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "parser failure restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "parser failure leaked install lock"
  [[ "$status" -eq 65 ]] || fail "metadata parser runtime failure exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
}

test_metadata_decode_runtime_failure_is_corrupt_without_shell_exit() {
  local tmp target injection marker output status metadata_before target_paths_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  injection="$tmp/decode-runtime-failure.rb"
  marker="$tmp/decode-branch-reached"
  mkdir -p "$target/bin" "$tmp/unmanaged-doctor"
  ln -s "$tmp/unmanaged-doctor" "$target/bin/agent_doctor"
  printf '{"delivery_mode":"flat","mode":"symlink","source":"%s"}\n' "$ROOT" > "$target/.agent-workflows-install.json"
  printf 'preserve me\n' > "$target/sentinel.txt"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"
  target_paths_before="$(find "$target" -print | LC_ALL=C sort)"
  cat > "$injection" <<'RUBY'
module FailMetadataDecoder
  def unpack1(format, *)
    if format == "m0"
      File.write(ENV.fetch("QA_DECODE_MARKER"), "reached\n")
      raise "injected metadata decode failure"
    end

    super
  end
end
String.prepend(FailMetadataDecoder)
RUBY

  set +e
  output="$(QA_DECODE_MARKER="$marker" RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" \
    --host codex --target "$target" --mode symlink 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "metadata decode runtime failure exited $status: $output"
  assert_contains "$output" "Refusing unmanaged workflow doctor symlink"
  assert_not_contains "$output" "injected metadata decode failure"
  assert_file "$marker"
  [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
    fail "decode runtime failure changed install metadata"
  [[ "$target_paths_before" = "$(find "$target" -print | LC_ALL=C sort)" ]] || \
    fail "decode runtime failure changed the target tree"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "decode runtime failure leaked install lock"
}

test_metadata_attestation_hashes_opened_inode_without_reopening_path() {
  local tmp target staging receipt metadata replacement injection marker fake_bin real_mktemp
  local quarantine_attempt output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-attestation-path-race"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  replacement="$tmp/replacement.json"
  injection="$tmp/replace-path-after-lstat.rb"
  marker="$tmp/path-replaced-after-lstat"
  fake_bin="$tmp/fake-bin"
  real_mktemp="$(command -v mktemp)"
  quarantine_attempt="$tmp/quarantine-attempted"
  mkdir -p "$staging/user-owned-skill" "$fake_bin"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '[]\n' > "$replacement"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
require "digest"
class << File
  alias_method :qa_original_lstat, :lstat
  def lstat(path)
    stat = qa_original_lstat(path)
    if path == ENV.fetch("QA_METADATA_PATH") && !File.exist?(ENV.fetch("QA_RACE_MARKER"))
      File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
      File.rename(ENV.fetch("QA_REPLACEMENT_PATH"), path)
    end
    stat
  end
end
RUBY
  cat > "$fake_bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *".agent-workflows-install.json.recovery-"* ]]; then
  : > "$QA_QUARANTINE_ATTEMPT"
fi
exec "$QA_REAL_MKTEMP" "$@"
SH
  chmod +x "$fake_bin/mktemp"

  set +e
  output="$(PATH="$fake_bin:$PATH" QA_REAL_MKTEMP="$real_mktemp" QA_QUARANTINE_ATTEMPT="$quarantine_attempt" \
    QA_METADATA_PATH="$metadata" QA_REPLACEMENT_PATH="$replacement" QA_RACE_MARKER="$marker" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "metadata pathname replacement exited $status: $output"
  assert_file "$marker"
  [[ ! -e "$quarantine_attempt" ]] || fail "mixed-inode attestation advanced to recovery quarantine creation"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "mixed-inode attestation mutated recovery staging"
}

test_quarantine_replacement_before_backup_copy_does_not_write_outside_target() {
  local tmp target staging receipt metadata outside injection marker output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-quarantine-symlink-race"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  outside="$tmp/outside"
  injection="$tmp/replace-quarantine-before-copy.rb"
  marker="$tmp/quarantine-replaced"
  mkdir -p "$staging/user-owned-skill" "$outside"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  cat > "$injection" <<'RUBY'
module RecoveryCaptureHook
  def self.call(phase)
    return unless phase == :after_backup_copy
    return if File.exist?(ENV.fetch("QA_RACE_MARKER"))
    quarantine = Dir.glob(File.join(ENV.fetch("QA_TARGET"), ".agent-workflows-install.json.recovery-*")).fetch(0)
    File.rename(quarantine, quarantine + ".preserved")
    File.symlink(ENV.fetch("QA_OUTSIDE"), quarantine)
    File.write(ENV.fetch("QA_RACE_MARKER"), "replaced\n")
  end
end
RUBY

  set +e
  output="$(QA_TARGET="$target" QA_OUTSIDE="$outside" QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$marker"
  [[ "$status" -eq 65 ]] || fail "quarantine replacement exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_file "$outside/SENTINEL"
  [[ -z "$(find "$outside" -mindepth 1 ! -name SENTINEL -print -quit)" ]] || \
    fail "quarantine capture wrote outside target"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ -n "$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*.preserved' -print -quit)" ]] || \
    fail "quarantine replacement lost captured recovery directory"
}

test_recovery_invalid_string_race_fails_before_pending_recovery_mutation() {
  local tmp target staging receipt injection counter output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-invalid-string-race"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/write-invalid-string-after-first-read.rb"
  counter="$tmp/metadata-read"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  cat > "$injection" <<'RUBY'
require "json"
module WriteInvalidStringAfterFirstMetadataRead
  def parse(source, *args)
    value = super
    counter = ENV.fetch("QA_METADATA_READ_COUNTER")
    unless File.exist?(counter)
      File.write(counter, "read\n")
      File.write(ENV.fetch("QA_INSTALL_METADATA"), "{\"delivery_mode\":\"\\n\"}\n")
    end
    value
  end
end
JSON.singleton_class.prepend(WriteInvalidStringAfterFirstMetadataRead)
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$target/.agent-workflows-install.json" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "invalid-string race changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "invalid-string race restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "invalid-string race leaked install lock"
  [[ "$status" -eq 65 ]] || fail "recovery-time invalid string race exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "Preserved pending recovery receipt"
}

test_recovery_metadata_delete_race_is_corrupt() {
  local tmp target staging receipt injection counter output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-delete-race"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/delete-metadata-after-first-read.rb"
  counter="$tmp/metadata-read"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  cat > "$injection" <<'RUBY'
require "json"
module DeleteMetadataAfterFirstRead
  def parse(source, *args)
    value = super
    counter = ENV.fetch("QA_METADATA_READ_COUNTER")
    unless File.exist?(counter)
      File.write(counter, "read\n")
      File.unlink(ENV.fetch("QA_INSTALL_METADATA"))
    end
    value
  end
end
JSON.singleton_class.prepend(DeleteMetadataAfterFirstRead)
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$target/.agent-workflows-install.json" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "metadata delete race changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "metadata delete race restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "metadata delete race leaked install lock"
  [[ "$status" -eq 65 ]] || fail "recovery-time metadata delete race exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "Preserved pending recovery receipt"
}

test_recovery_second_read_overwrite_is_corrupt_before_mutation() {
  local tmp target staging receipt injection counter output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-second-read-overwrite"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/overwrite-metadata-after-second-read.rb"
  counter="$tmp/metadata-read-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  cat > "$injection" <<'RUBY'
require "json"
module OverwriteMetadataAfterSecondRead
  def parse(source, *args)
    value = super
    counter = ENV.fetch("QA_METADATA_READ_COUNTER")
    count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
    File.write(counter, count)
    if count == 2
      File.write(ENV.fetch("QA_INSTALL_METADATA"), "{\"delivery_mode\":[\"flat\"]}\n")
    end
    value
  end
end
JSON.singleton_class.prepend(OverwriteMetadataAfterSecondRead)
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$target/.agent-workflows-install.json" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "second-read overwrite changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "second-read overwrite restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "second-read overwrite leaked install lock"
  [[ "$status" -eq 65 ]] || fail "second-read overwrite exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_contains "$output" "Preserved pending recovery receipt"
}

test_recovery_second_read_delete_is_corrupt_before_mutation() {
  local tmp target staging receipt injection counter output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-second-read-delete"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/delete-metadata-after-second-read.rb"
  counter="$tmp/metadata-read-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  cat > "$injection" <<'RUBY'
require "json"
module DeleteMetadataAfterSecondRead
  def parse(source, *args)
    value = super
    counter = ENV.fetch("QA_METADATA_READ_COUNTER")
    count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
    File.write(counter, count)
    File.unlink(ENV.fetch("QA_INSTALL_METADATA")) if count == 2
    value
  end
end
JSON.singleton_class.prepend(DeleteMetadataAfterSecondRead)
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$target/.agent-workflows-install.json" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "second-read delete changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "second-read delete restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "second-read delete leaked install lock"
  [[ "$status" -eq 65 ]] || fail "second-read delete exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_contains "$output" "Preserved pending recovery receipt"
}

test_recovery_post_reader_exit_overwrite_is_corrupt_before_mutation() {
  local tmp target staging receipt metadata injection counter decoy output status receipt_before metadata_before quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-post-reader-overwrite"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/overwrite-metadata-after-second-reader-exits.rb"
  counter="$tmp/metadata-reader-count"
  decoy="$tmp/replacement-metadata.json"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '{"delivery_mode":["flat"]}\n' > "$decoy"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  metadata_before="$(shasum "$metadata")"
  cat > "$injection" <<'RUBY'
if ARGV.length == 2 && ARGV.fetch(1) == "delivery_mode"
  counter = ENV.fetch("QA_METADATA_READ_COUNTER")
  count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
  File.write(counter, count)
  if count == 2
    snapshot = ARGV.fetch(0)
    at_exit do
      File.rename(ENV.fetch("QA_REPLACEMENT_METADATA"), snapshot)
    end
  end
end
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_REPLACEMENT_METADATA="$decoy" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "post-reader overwrite changed pending receipt"
  assert_file "$metadata"
  [[ "$metadata_before" = "$(shasum "$metadata")" ]] || fail "post-reader overwrite changed install metadata"
  [[ ! -e "$decoy" ]] || fail "post-reader overwrite did not execute snapshot replacement"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "post-reader overwrite did not preserve metadata quarantine"
  assert_contains "$output" "RECOVERY_METADATA_CLEANUP_PENDING: preserved recovery state at $quarantine"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "post-reader overwrite restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "post-reader overwrite leaked install lock"
  [[ "$status" -eq 65 ]] || fail "post-reader overwrite exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_contains "$output" "Preserved pending recovery receipt"
}

test_recovery_post_reader_exit_delete_is_corrupt_before_mutation() {
  local tmp target staging receipt metadata injection counter output status receipt_before metadata_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-post-reader-delete"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/delete-metadata-after-second-reader-exits.rb"
  counter="$tmp/metadata-reader-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  metadata_before="$(shasum "$metadata")"
  cat > "$injection" <<'RUBY'
if ARGV.length == 2 && ARGV.fetch(1) == "delivery_mode"
  counter = ENV.fetch("QA_METADATA_READ_COUNTER")
  count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
  File.write(counter, count)
  if count == 2
    snapshot = ARGV.fetch(0)
    at_exit { File.unlink(snapshot) }
  end
end
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "post-reader delete changed pending receipt"
  assert_file "$metadata"
  [[ "$metadata_before" = "$(shasum "$metadata")" ]] || fail "post-reader delete changed install metadata"
  [[ -z "$(find "$target" -maxdepth 1 -name '.agent-workflows-install.json.recovery-*' -print -quit)" ]] || \
    fail "post-reader delete leaked metadata quarantine"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "post-reader delete restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "post-reader delete leaked install lock"
  [[ "$status" -eq 65 ]] || fail "post-reader delete exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_contains "$output" "Preserved pending recovery receipt"
}

test_cleanup_receipt_replacement_is_preserved_and_named() {
  local tmp target staging receipt metadata injection replacement output status quarantine cleanup_receipt
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-receipt-binding"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/replace-cleanup-receipt.rb"
  replacement="$tmp/replacement-receipt"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  printf 'replacement receipt\n' > "$replacement"
  cat > "$injection" <<'RUBY'
module RecoveryCleanupHook
  def self.call(phase, receipt_name)
    return unless phase == :before_receipt_move
    receipt = File.join(ENV.fetch("QA_TARGET"), receipt_name)
    File.rename(receipt, receipt + ".original")
    File.rename(ENV.fetch("QA_REPLACEMENT_RECEIPT"), receipt)
  end
end
RUBY

  set +e
  output="$(QA_TARGET="$target" QA_REPLACEMENT_RECEIPT="$replacement" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "cleanup receipt replacement exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_CLEANUP_PENDING: preserved recovery state at"
  assert_file "$target/.agent-workflows-install.json.cleanup-complete-"*.original
  [[ ! -e "$receipt" ]] || fail "completed recovery left migration receipt"
  cleanup_receipt="$(find "$target" -maxdepth 2 -type f -name 'cleanup-receipt' -print -quit)"
  [[ -n "$cleanup_receipt" ]] || fail "cleanup receipt replacement did not preserve replacement"
  assert_contains "$(cat "$cleanup_receipt")" "replacement receipt"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "cleanup receipt replacement did not preserve holder"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
}

test_recovery_placeholder_replacement_names_preserved_quarantine() {
  local tmp target staging receipt metadata injection counter output status receipt_before metadata_digest quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-placeholder-replacement"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/replace-metadata-placeholder-after-reader-exits.rb"
  counter="$tmp/metadata-reader-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  metadata_digest="$(shasum "$metadata" | awk '{print $1}')"
  cat > "$injection" <<'RUBY'
if ARGV.length == 2 && ARGV.fetch(1) == "delivery_mode"
  counter = ENV.fetch("QA_METADATA_READ_COUNTER")
  count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
  File.write(counter, count)
  if count == 2
    at_exit do
      original = ENV.fetch("QA_INSTALL_METADATA")
      File.unlink(original)
      File.write(original, "attacker replacement\n")
    end
  end
end
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$metadata" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "placeholder replacement did not preserve metadata quarantine: $output"
  assert_file "$quarantine/metadata"
  assert_file "$quarantine/original-backup"
  [[ "$metadata_digest" = "$(shasum "$quarantine/metadata" | awk '{print $1}')" ]] || fail "quarantined metadata changed"
  [[ "$metadata_digest" = "$(shasum "$quarantine/original-backup" | awk '{print $1}')" ]] || fail "backup metadata changed"
  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "placeholder replacement changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "placeholder replacement restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "placeholder replacement leaked install lock"
  [[ "$status" -eq 65 ]] || fail "placeholder replacement exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_contains "$output" "Preserved recovery metadata quarantine $quarantine"
  assert_contains "$output" "Preserved pending recovery receipt"
}

test_crashed_recovery_quarantine_is_named_on_next_run() {
  local tmp target staging receipt metadata quarantine output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-crash-residue"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  quarantine="$metadata.recovery-A1b2C3"
  mkdir -p "$staging/user-owned-skill" "$quarantine"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '{"delivery_mode":"flat"}\n' > "$quarantine/metadata"
  printf '{"delivery_mode":"flat"}\n' > "$quarantine/original-backup"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "crashed recovery residue exited $status: $output"
  assert_not_contains "$output" "cannot read valid install metadata"
  assert_contains "$output" "Preserved recovery metadata quarantine $quarantine"
  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "crash residue changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "crash residue restored staged skill"
  assert_file "$quarantine/metadata"
  assert_file "$quarantine/original-backup"
}

test_unexpected_recovery_residue_is_named_without_blaming_metadata() {
  local tmp target staging receipt metadata residue output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-unexpected-residue"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  residue="$metadata.recovery-unexpected"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf 'unknown residue\n' > "$residue"
  printf '%s\n' "$staging" > "$receipt"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "unexpected recovery residue exited $status: $output"
  assert_contains "$output" "Unexpected recovery residue $residue blocks recovery"
  assert_not_contains "$output" "cannot read valid install metadata"
  assert_file "$metadata"
  assert_file "$residue"
  assert_file "$receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
}

test_corrupt_metadata_with_residue_reports_both_problems() {
  local tmp target metadata residue output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  metadata="$target/.agent-workflows-install.json"
  residue="$metadata.recovery-archived"
  mkdir -p "$target"
  printf 'not json\n' > "$metadata"
  printf 'archived residue\n' > "$residue"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "corrupt metadata with residue exited $status: $output"
  assert_contains "$output" "Unexpected recovery residue $residue blocks recovery"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_contains "$output" "Restore a valid backup"
  assert_file "$metadata"
  assert_file "$residue"
}

test_recovery_cleanup_residue_does_not_wedge_completed_recovery() {
  local tmp target staging later_staging receipt metadata injection counter output status quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-residue"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/add-quarantine-residue-after-reader-exits.rb"
  counter="$tmp/metadata-reader-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
if ARGV.length == 2 && ARGV.fetch(1) == "delivery_mode"
  counter = ENV.fetch("QA_METADATA_READ_COUNTER")
  count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
  File.write(counter, count)
  File.write(File.join(File.dirname(ARGV.fetch(0)), "cleanup-residue"), "preserve me\n") if count == 2
end
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "cleanup-only residue exited $status: $output"
  [[ ! -e "$receipt" ]] || fail "cleanup-only residue preserved a completed recovery receipt"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
  assert_file "$metadata"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "cleanup-only residue was not preserved"
  assert_file "$quarantine/cleanup-residue"
  assert_contains "$output" "RECOVERY_METADATA_CLEANUP_PENDING: preserved $quarantine"

  later_staging="$target/.agent-workflows-flat-migration-after-cleanup-residue"
  mkdir -p "$later_staging/later-owned-skill"
  printf 'later user-owned\n' > "$later_staging/later-owned-skill/SKILL.md"
  printf '%s\n' "$later_staging" > "$receipt"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "cleanup-only residue blocked later recovery with status $status: $output"
  [[ ! -e "$receipt" ]] || fail "later recovery left its completed receipt"
  [[ ! -e "$later_staging" ]] || fail "later recovery left its staging directory"
  assert_file "$target/skills/later-owned-skill/SKILL.md"
  assert_file "$quarantine/cleanup-residue"
}

test_recovery_restore_atomically_replaces_placeholder() {
  local tmp target staging receipt metadata injection observer output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-atomic-restore"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/observe-metadata-rename.rb"
  observer="$tmp/restore-observer.log"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryRestoreHook
  def self.call(phase)
    if phase == :before_rename
      File.write(ENV.fetch("QA_OBSERVER_LOG"), "restore-intercepted\n")
    end
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" QA_OBSERVER_LOG="$observer" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "atomic metadata restore exited $status: $output"
  assert_contains "$(cat "$observer")" "restore-intercepted"
  [[ ! -e "$receipt" ]] || fail "atomic metadata restore preserved completed receipt"
  assert_file "$metadata"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
}

test_recovery_restore_directory_race_preserves_backup() {
  local tmp target staging receipt metadata injection observer output status quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-restore-directory-race"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/replace-metadata-with-directory.rb"
  observer="$tmp/restore-directory-race.log"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryRestoreHook
  def self.call(phase)
    if phase == :before_rename
      destination = ENV.fetch("QA_INSTALL_METADATA")
      File.unlink(destination)
      Dir.mkdir(destination)
      File.write(File.join(destination, "metadata"), "replacement directory\n")
      File.write(ENV.fetch("QA_OBSERVER_LOG"), "restore-directory-race\n")
    end
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" QA_OBSERVER_LOG="$observer" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "restore directory race exited $status: $output"
  assert_contains "$(cat "$observer")" "restore-directory-race"
  assert_contains "$output" "RECOVERY_FAILED"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "restore directory race did not preserve quarantine: $output"
  assert_file "$quarantine/original-backup"
  assert_file "$metadata/metadata"
}

test_partial_restore_undo_restores_guard_to_target() {
  local tmp target staging receipt metadata injection output status quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-partial-restore-undo"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/fail-restore-guard-undo.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
module RecoveryRestoreHook
  def self.call(phase)
    return unless phase == :after_rename
    File.write(ENV.fetch("QA_INSTALL_METADATA"), "changed after restore\n")
    RecoveryRestoreSyscalls.singleton_class.prepend(Module.new do
      def renameat(*args)
        @qa_rename_count = (@qa_rename_count || 0) + 1
        return -1 if @qa_rename_count == 2
        super
      end
    end)
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "partial restore undo exited $status: $output"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "partial restore undo did not preserve quarantine"
  assert_file "$metadata"
  ruby -rjson -e 'abort unless JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode") == "flat"' "$metadata"
  [[ ! -e "$quarantine/restore-guard" ]] || fail "partial restore undo left an unneeded guard link"
  assert_file "$receipt"
}

test_cleanup_receipt_write_failure_is_pending_without_corrupt_guidance() {
  local tmp target staging receipt metadata injection output status quarantine
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-receipt-write-failure"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/fail-cleanup-receipt-write.rb"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
cleanup_receipt = ARGV.find do |argument|
  File.basename(argument).start_with?(".agent-workflows-install.json.cleanup-complete-")
end
raise Errno::EIO, cleanup_receipt if cleanup_receipt
RUBY

  set +e
  output="$(RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "cleanup receipt write failure exited $status: $output"
  assert_contains "$output" "RECOVERY_METADATA_CLEANUP_PENDING"
  assert_not_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "RECOVERY_FAILED"
  assert_file "$metadata"
  ruby -rjson -e 'abort unless %w[flat plugin-companion].include?(JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode"))' "$metadata"
  [[ ! -e "$receipt" ]] || fail "cleanup receipt write failure left migration receipt"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
  quarantine="$(find "$target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "cleanup receipt write failure did not preserve recovery evidence"
  assert_file "$quarantine/original-backup"
}

test_cleanup_receipt_ancestor_rebind_does_not_write_outside_target() {
  local tmp parent preserved_parent outside_parent target preserved_target outside_target staging receipt metadata
  local injection marker output status quarantine outside_receipt
  tmp="$(mktemp -d)"
  parent="$tmp/home-parent"
  preserved_parent="$tmp/home-parent-preserved"
  outside_parent="$tmp/outside-parent"
  target="$parent/codex-home"
  preserved_target="$preserved_parent/codex-home"
  outside_target="$outside_parent/codex-home"
  staging="$target/.agent-workflows-flat-migration-cleanup-receipt-ancestor-rebind"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/rebind-target-ancestor-before-cleanup-receipt.rb"
  marker="$tmp/cleanup-receipt-ancestor-rebound"
  mkdir -p "$staging/user-owned-skill" "$outside_target"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
receipt_argument = ARGV.find do |argument|
  File.basename(argument).start_with?(".agent-workflows-install.json.cleanup-complete-")
end
if receipt_argument && !File.exist?(ENV.fetch("QA_RACE_MARKER"))
  File.rename(ENV.fetch("QA_TARGET_PARENT"), ENV.fetch("QA_PRESERVED_PARENT"))
  File.symlink(ENV.fetch("QA_OUTSIDE_PARENT"), ENV.fetch("QA_TARGET_PARENT"))
  File.write(ENV.fetch("QA_RACE_MARKER"), "rebound\n")
end
RUBY

  set +e
  output="$(QA_TARGET_PARENT="$parent" QA_PRESERVED_PARENT="$preserved_parent" \
    QA_OUTSIDE_PARENT="$outside_parent" QA_RACE_MARKER="$marker" RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "cleanup receipt ancestor rebind exited $status: $output"
  assert_file "$marker"
  assert_contains "$output" "RECOVERY_METADATA_CLEANUP_PENDING"
  outside_receipt="$(find "$outside_target" -maxdepth 1 -type f -name '.agent-workflows-install.json.cleanup-complete-*' -print -quit)"
  [[ -z "$outside_receipt" ]] || fail "cleanup receipt ancestor rebind wrote outside target: $outside_receipt"
  quarantine="$(find "$preserved_target" -maxdepth 1 -type d -name '.agent-workflows-install.json.recovery-*' -print -quit)"
  [[ -n "$quarantine" ]] || fail "cleanup receipt ancestor rebind did not preserve recovery evidence: $output"
  assert_file "$quarantine/original-backup"
  assert_file "$preserved_target/.agent-workflows-install.json"
}

test_recovery_restore_destination_symlink_does_not_write_outside_target() {
  local tmp target staging receipt metadata outside injection observer output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-restore-symlink-race"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  outside="$tmp/outside"
  injection="$tmp/replace-metadata-before-rename.rb"
  observer="$tmp/restore-symlink-race.log"
  mkdir -p "$staging/user-owned-skill" "$outside"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  printf 'outside sentinel\n' > "$outside/SENTINEL"
  cat > "$injection" <<'RUBY'
module RecoveryRestoreHook
  def self.call(phase)
    if phase == :before_rename && !File.exist?(ENV.fetch("QA_OBSERVER_LOG"))
      destination = ENV.fetch("QA_INSTALL_METADATA")
      File.unlink(destination)
      File.symlink(ENV.fetch("QA_OUTSIDE"), destination)
      File.write(ENV.fetch("QA_OBSERVER_LOG"), "restore-symlink-race\n")
    end
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" QA_OUTSIDE="$outside" QA_OBSERVER_LOG="$observer" \
    RUBYOPT="-r$injection" \
    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_contains "$(cat "$observer")" "restore-symlink-race"
  [[ "$status" -eq 0 ]] || fail "bound metadata restore exited $status: $output"
  assert_file "$outside/SENTINEL"
  [[ -z "$(find "$outside" -mindepth 1 ! -name SENTINEL -print -quit)" ]] || \
    fail "metadata restoration wrote outside target"
  assert_file "$metadata"
  [[ ! -L "$metadata" ]] || fail "bound metadata restore left replacement symlink"
  [[ ! -e "$receipt" ]] || fail "bound metadata restore left completed receipt"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
}

test_recovery_keeps_parseable_metadata_visible_during_capture() {
  local tmp target staging receipt metadata injection observer output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-visible-capture"
  receipt="$target/.agent-workflows-migration-staging"
  metadata="$target/.agent-workflows-install.json"
  injection="$tmp/observe-captured-metadata.rb"
  observer="$tmp/observer.log"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$metadata"
  printf '%s\n' "$staging" > "$receipt"
  cat > "$injection" <<'RUBY'
require "json"
module RecoveryCaptureHook
  def self.call(phase)
    return unless phase == :after_rename
    JSON.parse(File.read(ENV.fetch("QA_INSTALL_METADATA")))
    File.write(ENV.fetch("QA_OBSERVER_LOG"), "capture-visible\n")
  end
end
RUBY

  set +e
  output="$(QA_INSTALL_METADATA="$metadata" RUBYOPT="-r$injection" \
    QA_OBSERVER_LOG="$observer" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "visible capture exited $status: $output"
  assert_file "$observer"
  assert_contains "$(cat "$observer")" "capture-visible"
  assert_file "$metadata"
  [[ ! -e "$receipt" ]] || fail "visible capture preserved completed receipt"
  assert_file "$target/skills/user-owned-skill/SKILL.md"
}

test_recovery_unsupported_string_between_reads_preserves_receipt() {
  local tmp target staging receipt injection counter output status receipt_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-invalid-between-reads"
  receipt="$target/.agent-workflows-migration-staging"
  injection="$tmp/write-invalid-metadata-after-first-reader-exits.rb"
  counter="$tmp/metadata-reader-count"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '{"delivery_mode":"flat"}\n' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  cat > "$injection" <<'RUBY'
require "json"
if ARGV.length == 2 && ARGV.fetch(0) == ENV["QA_INSTALL_METADATA"] && ARGV.fetch(1) == "delivery_mode"
  counter = ENV.fetch("QA_METADATA_READ_COUNTER")
  count = File.exist?(counter) ? File.read(counter).to_i + 1 : 1
  File.write(counter, count)
  if count == 1
    at_exit do
      File.write(ENV.fetch("QA_INSTALL_METADATA"), "{\"delivery_mode\":\"hybrid\"}\n")
    end
  end
end
RUBY

  set +e
  output="$(QA_METADATA_READ_COUNTER="$counter" QA_INSTALL_METADATA="$target/.agent-workflows-install.json" \
    RUBYOPT="-r$injection" "$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "unsupported recovery mode changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "unsupported recovery mode restored staged skill"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "unsupported recovery mode leaked install lock"
  [[ "$status" -eq 64 ]] || fail "unsupported recovery mode exited $status: $output"
  assert_contains "$output" "Installed metadata delivery_mode must be flat or plugin-companion."
  assert_contains "$output" "Preserved pending recovery receipt"
}

test_nul_recorded_delivery_mode_fails_before_pending_recovery_mutation() {
  local tmp target staging receipt output status receipt_before metadata_before
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  staging="$target/.agent-workflows-flat-migration-nul-mode"
  receipt="$target/.agent-workflows-migration-staging"
  mkdir -p "$staging/user-owned-skill"
  printf 'user-owned\n' > "$staging/user-owned-skill/SKILL.md"
  printf '%s\n' '{"delivery_mode":"flat\u0000"}' > "$target/.agent-workflows-install.json"
  printf '%s\n' "$staging" > "$receipt"
  receipt_before="$(shasum "$receipt")"
  metadata_before="$(shasum "$target/.agent-workflows-install.json")"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  assert_file "$receipt"
  [[ "$receipt_before" = "$(shasum "$receipt")" ]] || fail "NUL delivery mode changed pending receipt"
  assert_file "$staging/user-owned-skill/SKILL.md"
  [[ ! -e "$target/skills/user-owned-skill" ]] || fail "NUL delivery mode restored staged skill"
  [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
    fail "NUL delivery mode changed install metadata"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "NUL delivery mode leaked install lock"
  [[ "$status" -eq 65 ]] || fail "NUL delivery mode exited $status: $output"
  assert_contains "$output" "CORRUPT_INSTALL_METADATA"
  assert_not_contains "$output" "Preserved pending recovery receipt"
}

test_legacy_install_metadata_without_delivery_mode_remains_flat() {
  local tmp target
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target"
  ruby -rjson -e '
    path, source = ARGV
    File.write(path, JSON.pretty_generate({
      "host" => "codex",
      "mode" => "copy",
      "source" => source,
      "source_revision" => "0000000000000000000000000000000000000000"
    }) + "\n")
  ' "$target/.agent-workflows-install.json" "$ROOT"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"

  assert_file "$target/skills/pr-batch/SKILL.md"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "flat"
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
  assert_file "$tmp/.claude/bin/agent-workflows-doctor"
  assert_file "$tmp/.claude/bin/agent-workflows-trust-audit"
  assert_unsigned_launch_helpers "$tmp/.claude" "Claude"
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
  assert_symlink "$target/docs/execution-provenance-schema.md"
  assert_symlink "$target/docs/review-finding-schema.md"
  assert_symlink "$target/docs/agent-workflows-model-routing.md"
  assert_symlink "$target/docs/user-facing-coordination.md"
  [[ -d "$target/docs/solutions" && ! -L "$target/docs/solutions" ]] || fail "expected real docs/solutions directory"
  assert_symlink "$target/docs/solutions/README.md"
  assert_symlink "$target/bin/agent-workflow-seam-doctor"
  assert_symlink "$target/bin/validate-execution-provenance"
  assert_symlink "$target/bin/agent_doctor"
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

test_install_replaces_docs_directory_symlink_without_following_pack_named_children() {
  local tmp target external_docs mode
  tmp="$(mktemp -d)"

  for mode in copy symlink; do
    target="$tmp/codex-home-$mode"
    external_docs="$tmp/external-docs-$mode"
    mkdir -p "$target" "$external_docs"
    printf 'personal external coordination sentinel\n' > \
      "$external_docs/user-facing-coordination.md"
    ln -s "$external_docs" "$target/docs"

    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" \
      --mode "$mode" >"$tmp/install-$mode.out"

    [[ -d "$target/docs" && ! -L "$target/docs" ]] || \
      fail "$mode install did not replace the docs parent symlink"
    grep -qxF 'personal external coordination sentinel' \
      "$external_docs/user-facing-coordination.md" || \
      fail "$mode install changed the external pack-named document"
    if [[ "$mode" = copy ]]; then
      [[ -f "$target/docs/user-facing-coordination.md" && \
         ! -L "$target/docs/user-facing-coordination.md" ]] || \
        fail "copy install did not create a real coordination document"
    else
      assert_symlink "$target/docs/user-facing-coordination.md"
    fi
  done
}

test_install_replaces_solutions_directory_symlink_without_following_pack_named_children() {
  local tmp target external_solutions solution_name mode
  tmp="$(mktemp -d)"
  solution_name="coordination-unknown-state.md"

  for mode in copy symlink; do
    target="$tmp/codex-home-$mode"
    external_solutions="$tmp/external-solutions-$mode"
    mkdir -p "$target/docs" "$external_solutions"
    printf 'personal external solution sentinel\n' > "$external_solutions/$solution_name"
    ln -s "$external_solutions" "$target/docs/solutions"

    "$ROOT/bin/install-agent-workflows" --host codex --target "$target" \
      --mode "$mode" >"$tmp/install-$mode.out"

    [[ -d "$target/docs/solutions" && ! -L "$target/docs/solutions" ]] || \
      fail "$mode install did not replace the solutions directory symlink"
    grep -qxF 'personal external solution sentinel' "$external_solutions/$solution_name" || \
      fail "$mode install changed the external solution document"
    if [[ "$mode" = copy ]]; then
      cmp -s "$target/docs/solutions/$solution_name" "$ROOT/docs/solutions/$solution_name" || \
        fail "copy install did not install the managed solution document"
    else
      assert_symlink "$target/docs/solutions/$solution_name"
    fi
  done
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

test_symlink_mode_refuses_unmanaged_live_and_dangling_doctor_links_before_mutation() {
  local variant tmp target link_target output status
  for variant in live dangling; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    link_target="$tmp/unmanaged/agent_doctor"
    mkdir -p "$target/bin"
    if [[ "$variant" = live ]]; then
      mkdir -p "$link_target"
      printf 'preserve\n' > "$link_target/sentinel"
    fi
    ln -s "$link_target" "$target/bin/agent_doctor"

    set +e
    output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "symlink mode accepted an unmanaged $variant doctor link"
    assert_contains "$output" "Refusing unmanaged workflow doctor symlink"
    [[ "$(readlink "$target/bin/agent_doctor")" = "$link_target" ]] || fail "$variant doctor link changed"
    [[ ! -e "$target/LICENSE" && ! -e "$target/workflows" ]] || fail "$variant refusal mutated pack assets"
    [[ ! -e "$target/.agent-workflows-install.json" ]] || fail "$variant refusal committed metadata"
    if [[ "$variant" = live ]]; then
      grep -qxF preserve "$link_target/sentinel" || fail "live doctor referent changed"
    else
      [[ ! -e "$link_target" ]] || fail "dangling doctor referent was created"
    fi
  done
}

test_symlink_mode_replaces_recorded_prior_source_doctor_link() {
  local tmp source target
  tmp="$(mktemp -d)"
  source="$tmp/prior-source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >"$tmp/prior.out"
  [[ "$(readlink "$target/bin/agent_doctor")" = "$source/bin/agent_doctor" ]] ||
    fail "prior source did not own the doctor link"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode symlink >"$tmp/current.out"

  [[ "$(readlink "$target/bin/agent_doctor")" = "$ROOT/bin/agent_doctor" ]] ||
    fail "current source did not replace the recorded prior doctor link"
}

test_copy_mode_migrates_dangling_recorded_doctor_symlink_from_deleted_source() {
  local tmp source target
  tmp="$(mktemp -d)"
  source="$tmp/prior-source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" --mode symlink \
    >"$tmp/symlink-install.out"
  [[ "$(readlink "$target/bin/agent_doctor")" = "$source/bin/agent_doctor" ]] ||
    fail "prior symlink install did not record its source doctor"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["mode"] == "symlink" && metadata["source"] == File.expand_path(ARGV.fetch(1))
  ' "$target/.agent-workflows-install.json" "$source"

  rm -rf "$source"
  [[ -L "$target/bin/agent_doctor" && ! -e "$target/bin/agent_doctor" ]] ||
    fail "expected prior installer-owned doctor link to be dangling"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    >"$tmp/copy-install.out"

  [[ -d "$target/bin/agent_doctor" && ! -L "$target/bin/agent_doctor" ]] ||
    fail "copy migration did not replace the dangling owned doctor link"
  assert_file "$target/bin/agent_doctor/process_runner.rb"
  ruby "$ROOT/bin/agent_doctor/install_ownership.rb" verify \
    "$target/bin/agent_doctor" "$target/bin/agent_doctor/.agent-workflows-managed" ||
    fail "copy migration did not establish current doctor ownership"
}

test_copy_mode_migrates_recorded_doctor_symlink_from_live_prior_source() {
  local tmp source target
  tmp="$(mktemp -d)"
  source="$tmp/prior-source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" --mode symlink \
    >"$tmp/symlink-install.out"
  [[ "$(readlink "$target/bin/agent_doctor")" = "$source/bin/agent_doctor" ]] ||
    fail "prior symlink install did not record its source doctor"
  [[ -d "$source/bin/agent_doctor" && -d "$target/bin/agent_doctor" ]] ||
    fail "expected the prior installer-owned doctor link to remain live"

  "$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode copy \
    >"$tmp/copy-install.out"

  [[ -d "$target/bin/agent_doctor" && ! -L "$target/bin/agent_doctor" ]] ||
    fail "copy migration did not replace the live recorded doctor link"
  assert_file "$source/bin/agent_doctor/process_runner.rb"
  assert_file "$target/bin/agent_doctor/process_runner.rb"
  ruby "$ROOT/bin/agent_doctor/install_ownership.rb" verify \
    "$target/bin/agent_doctor" "$target/bin/agent_doctor/.agent-workflows-managed" ||
    fail "copy migration did not establish current doctor ownership"
}

test_copy_mode_refuses_unproven_live_doctor_symlinks_without_mutation() {
  local variant tmp target recorded_source other_source link_target output status metadata_before external_metadata
  local external_metadata_before
  for variant in missing_metadata malformed_metadata unrelated wrong_mode wrong_target symlinked_metadata; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    recorded_source="$tmp/prior-source"
    other_source="$tmp/unrelated-source"
    mkdir -p "$target/bin" "$recorded_source/bin/agent_doctor" "$other_source/bin/agent_doctor"
    printf 'preserve\n' > "$recorded_source/bin/agent_doctor/sentinel"
    printf 'unrelated\n' > "$other_source/bin/agent_doctor/sentinel"
    link_target="$recorded_source/bin/agent_doctor"
    case "$variant" in
      missing_metadata)
        metadata_before=absent
        ;;
      malformed_metadata)
        printf '{malformed\n' > "$target/.agent-workflows-install.json"
        metadata_before="$(shasum "$target/.agent-workflows-install.json")"
        ;;
      unrelated)
        link_target="$other_source/bin/agent_doctor"
        metadata_before=absent
        ;;
      wrong_mode)
        ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"mode" => "copy", "source" => ARGV[1]}) + "\n")' \
          "$target/.agent-workflows-install.json" "$recorded_source"
        metadata_before="$(shasum "$target/.agent-workflows-install.json")"
        ;;
      wrong_target)
        link_target="$other_source/bin/agent_doctor"
        ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"mode" => "symlink", "source" => ARGV[1]}) + "\n")' \
          "$target/.agent-workflows-install.json" "$recorded_source"
        metadata_before="$(shasum "$target/.agent-workflows-install.json")"
        ;;
      symlinked_metadata)
        external_metadata="$tmp/external-metadata.json"
        ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"mode" => "symlink", "source" => ARGV[1]}) + "\n")' \
          "$external_metadata" "$recorded_source"
        ln -s "$external_metadata" "$target/.agent-workflows-install.json"
        metadata_before="$(shasum "$target/.agent-workflows-install.json")"
        external_metadata_before="$(shasum "$external_metadata")"
        ;;
    esac
    ln -s "$link_target" "$target/bin/agent_doctor"

    set +e
    output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" --mode copy 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "$variant live doctor link unexpectedly installed"
    [[ "$(readlink "$target/bin/agent_doctor")" = "$link_target" ]] ||
      fail "$variant live doctor link changed"
    [[ -L "$target/bin/agent_doctor" && -e "$target/bin/agent_doctor" ]] ||
      fail "$variant live doctor link was replaced"
    if [[ "$metadata_before" = absent ]]; then
      [[ ! -e "$target/.agent-workflows-install.json" ]] || fail "$variant install created metadata"
    else
      [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] ||
        fail "$variant install changed metadata"
    fi
    if [[ "$variant" = symlinked_metadata ]]; then
      [[ -L "$target/.agent-workflows-install.json" &&
         "$(readlink "$target/.agent-workflows-install.json")" = "$external_metadata" ]] ||
        fail "$variant install replaced metadata symlink"
      [[ "$external_metadata_before" = "$(shasum "$external_metadata")" ]] ||
        fail "$variant install changed external metadata"
    fi
  done
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

test_upgrade_dry_run_checks_requested_delivery_mode() {
  local tmp source target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" --delivery-mode flat >"$tmp/install.out"
  write_native_scw_state codex "$target"

  output="$("$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --delivery-mode plugin-companion --dry-run --no-fetch 2>&1)"
  assert_contains "$output" "delivery_mode=plugin-companion"

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --delivery-mode flat --dry-run --no-fetch 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || fail "incompatible requested flat mode did not return CHECK_FAILED: $output"
  assert_contains "$output" "CHECK_FAILED"
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
  TEST_SOURCE_ROOT="$(mktemp -d)"
  new_source_repo "$TEST_SOURCE_ROOT"
  ROOT="$TEST_SOURCE_ROOT"

  local tests=(
    test_delivery_state_helper_unit_suite
    test_native_plugin_plus_default_flat_install_fails_before_mutation
    test_plugin_companion_installs_non_skill_assets_and_records_mode
    test_plugin_companion_refuses_unsafe_scanner_ancestors_before_mutation
    test_plugin_companion_refuses_unknown_direct_skill_and_preserves_all_skills
    test_direct_migration_does_not_remove_skills_before_other_install_checks_pass
    test_metadata_temp_failure_preserves_flat_tree_and_prior_mode
    test_staging_race_blocks_installer_and_preserves_flat_tree
    test_final_verification_race_rolls_back_before_metadata_commit
    test_staging_json_extraction_failure_uses_receipt_to_roll_back
    test_failed_partial_rollback_preserves_receipt_for_retry
    test_recovery_normalization_failure_releases_install_lock
    test_crash_receipt_recovers_flat_staging_before_new_install
    test_first_install_crash_with_absent_metadata_recovers_as_flat
    test_metadata_appearing_before_lock_is_not_treated_as_absent_recovery
    test_metadata_disappearing_before_lock_is_not_treated_as_still_present
    test_metadata_change_after_locked_preflight_fails_before_managed_file_mutation
    test_bound_metadata_change_cannot_grant_symlink_ownership
    test_metadata_commit_rejects_destination_directory_race
    test_metadata_commit_rolls_back_failed_present_compare_and_swap
    test_metadata_commit_rejects_replaced_prepared_file
    test_metadata_commit_capability_failure_stops_before_managed_mutation
    test_crash_receipt_cleans_committed_companion_quarantine_without_restoring_flat
    test_flat_crash_recovery_rejects_symlink_staging_without_touching_outside_data
    test_flat_crash_recovery_rejects_symlink_skills_root_before_move
    test_companion_crash_cleanup_rejects_symlink_staging_without_touching_outside_data
    test_install_lock_blocks_concurrent_migration_before_mutation
    test_recovery_restore_holds_install_lock_against_retry
    test_recovery_metadata_change_during_rollback_preserves_staging_and_tree
    test_recovery_metadata_change_during_companion_cleanup_preserves_staging
    test_recovery_staging_replacement_during_rollback_preserves_artifacts
    test_recovery_staging_replacement_during_companion_cleanup_preserves_artifacts
    test_recovery_staging_disappearing_after_identity_capture_fails_closed
    test_recovery_skills_root_replacement_during_reversal_preserves_outside_data
    test_recovery_destination_appearing_at_move_is_not_replaced
    test_flat_crash_recovery_restores_staged_symlink_skill
    test_recovery_source_replacement_after_inventory_is_not_moved
    test_recovery_identity_failure_reverses_earlier_moves
    test_recovery_post_move_verification_failure_reverses_committed_move
    test_recovery_post_move_open_failure_reverses_committed_move
    test_companion_cleanup_post_move_replacement_has_named_retry_failure
    test_companion_cleanup_post_move_exception_restores_receipted_staging
    test_companion_cleanup_root_replacement_cannot_move_staging_outside_target
    test_companion_cleanup_root_swap_during_deletion_preserves_all_entries
    test_missing_metadata_backup_reports_restore_failure_without_corrupt_guidance
    test_transient_metadata_restore_failure_preserves_receipt_after_reversal
    test_mid_rollback_backup_change_does_not_blame_intact_metadata
    test_companion_cleanup_rejects_mktemp_path_outside_target
    test_companion_cleanup_rejects_symlinked_cleanup_root
    test_companion_cleanup_supports_world_writable_target
    test_recovery_hardlink_unavailable_is_named_without_blaming_metadata
    test_recovery_capture_supports_system_ruby_2_6
    test_capture_runtime_load_failure_removes_empty_quarantine
    test_capture_failure_after_sentinel_install_restores_original_metadata
    test_recovery_partial_backup_copy_failure_removes_quarantine
    test_late_capture_failure_reports_corrupt_without_stale_quarantine_guidance
    test_late_capture_restore_failure_does_not_blame_intact_metadata
    test_snapshot_only_corruption_restores_before_reporting
    test_nul_in_recorded_source_is_corrupt_before_symlink_adoption
    test_repeat_install_replays_recorded_companion_delivery_mode
    test_repeat_flat_install_accepts_installer_created_uncommitted_skill
    test_repeat_flat_copy_install_blocks_modified_installer_created_uncommitted_skill
    test_repeat_flat_copy_install_blocks_modified_recorded_targets
    test_repeat_flat_copy_install_uses_fingerprints_without_git_history
    test_flat_copy_migrates_to_companion_with_fingerprints_without_git_history
    test_copy_metadata_fingerprint_matches_delivery_state_verifier
    test_repeat_copy_install_accepts_edited_installer_created_uncommitted_pack_doc
    test_repeat_copy_install_blocks_modified_solution_document
    test_installation_docs_describe_managed_coordination_doc_fingerprints
    test_flat_upgrade_refuses_newly_packaged_skill_collision
    test_flat_upgrade_late_preflight_failure_does_not_strand_new_skill
    test_flat_copy_upgrade_refuses_newly_packaged_doc_collision
    test_flat_copy_upgrade_refuses_pack_doc_directory_before_mutation
    test_symlink_upgrade_refuses_newly_packaged_doc_collisions_before_mutation
    test_repeat_companion_install_blocks_new_current_native_skill_collision
    test_repeat_companion_install_blocks_native_skill_removed_from_current_source
    test_companion_install_rejects_mixed_valid_and_invalid_candidate_native_roots
    test_invalid_recorded_delivery_mode_fails_before_mutation
    test_newline_recorded_delivery_modes_fail_before_mutation
    test_corrupt_install_metadata_fails_closed_with_recovery_guidance
    test_non_object_install_metadata_is_corrupt
    test_schema_invalid_delivery_mode_fails_before_pending_recovery_mutation
    test_recovery_metadata_race_fails_before_pending_recovery_mutation
    test_recovery_metadata_path_race_fails_before_pending_recovery_mutation
    test_metadata_parser_runtime_failure_is_corrupt
    test_metadata_decode_runtime_failure_is_corrupt_without_shell_exit
    test_metadata_attestation_hashes_opened_inode_without_reopening_path
    test_quarantine_replacement_before_backup_copy_does_not_write_outside_target
    test_recovery_invalid_string_race_fails_before_pending_recovery_mutation
    test_recovery_metadata_delete_race_is_corrupt
    test_recovery_second_read_overwrite_is_corrupt_before_mutation
    test_recovery_second_read_delete_is_corrupt_before_mutation
    test_recovery_post_reader_exit_overwrite_is_corrupt_before_mutation
    test_recovery_post_reader_exit_delete_is_corrupt_before_mutation
    test_cleanup_receipt_replacement_is_preserved_and_named
    test_recovery_placeholder_replacement_names_preserved_quarantine
    test_crashed_recovery_quarantine_is_named_on_next_run
    test_unexpected_recovery_residue_is_named_without_blaming_metadata
    test_corrupt_metadata_with_residue_reports_both_problems
    test_recovery_cleanup_residue_does_not_wedge_completed_recovery
    test_recovery_restore_atomically_replaces_placeholder
    test_recovery_restore_directory_race_preserves_backup
    test_partial_restore_undo_restores_guard_to_target
    test_cleanup_receipt_write_failure_is_pending_without_corrupt_guidance
    test_cleanup_receipt_ancestor_rebind_does_not_write_outside_target
    test_recovery_restore_destination_symlink_does_not_write_outside_target
    test_recovery_keeps_parseable_metadata_visible_during_capture
    test_recovery_unsupported_string_between_reads_preserves_receipt
    test_nul_recorded_delivery_mode_fails_before_pending_recovery_mutation
    test_legacy_install_metadata_without_delivery_mode_remains_flat
    test_companion_to_flat_refuses_unowned_same_named_skill
    test_auto_host_with_explicit_target_resolves_the_detected_host
    test_codex_host_install_writes_helpers_and_metadata
    test_copy_mode_refuses_unmanaged_agent_doctor_directory_before_collision
    test_copy_mode_adopts_an_exact_unmarked_agent_doctor_copy
    test_copy_mode_removes_stale_files_from_a_signed_doctor_upgrade
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
    test_install_replaces_docs_directory_symlink_without_following_pack_named_children
    test_install_replaces_solutions_directory_symlink_without_following_pack_named_children
    test_copy_mode_after_symlink_mode_does_not_delete_source_docs
    test_symlink_mode_refuses_unmanaged_live_and_dangling_doctor_links_before_mutation
    test_symlink_mode_replaces_recorded_prior_source_doctor_link
    test_copy_mode_migrates_dangling_recorded_doctor_symlink_from_deleted_source
    test_copy_mode_migrates_recorded_doctor_symlink_from_live_prior_source
    test_copy_mode_refuses_unproven_live_doctor_symlinks_without_mutation
    test_status_reports_not_installed_and_check_failed_explicitly
    test_status_reports_upgrade_available_between_source_commits
    test_upgrade_reinstalls_new_source_revision
    test_upgrade_can_select_and_then_replay_companion_delivery_mode
    test_upgrade_dry_run_checks_requested_delivery_mode
    test_upgrade_without_consumer_roots_succeeds
    test_upgrade_reports_missing_source_as_check_failed
    test_upgrade_rolls_back_when_consumer_seam_fails
    test_failed_upgrade_restores_companion_delivery_mode_and_layout
    test_upgrade_validates_consumer_root_after_install
  )

  local test_name
  for test_name in "${tests[@]}"; do
    if [[ -z "${INSTALL_AGENT_WORKFLOWS_TEST_FILTER:-}" || "$test_name" = *"$INSTALL_AGENT_WORKFLOWS_TEST_FILTER"* ]]; then
      "$test_name"
      echo "PASS $test_name"
    fi
  done
}

main "$@"
