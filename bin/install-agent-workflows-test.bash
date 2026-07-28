#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK_ROOT="$ROOT"
FAKE_CODEX_DIR="$(mktemp -d)"
TEST_SOURCE_ROOT=""
cleanup() {
  rm -rf "$FAKE_CODEX_DIR"
  [[ -z "$TEST_SOURCE_ROOT" ]] || rm -rf "$TEST_SOURCE_ROOT"
}
trap cleanup EXIT
export AGENT_WORKFLOWS_CODEX_EXECUTABLE="$FAKE_CODEX_DIR/codex"
export PATH="$FAKE_CODEX_DIR:$PATH"
cat > "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" <<'SH'
#!/bin/sh
[ "$*" = "plugin list --marketplace agent-workflows" ] || exit 2
version=0.1.0
[ ! -f "$CODEX_HOME/.qa-codex-version" ] || version="$(cat "$CODEX_HOME/.qa-codex-version")"
printf 'PLUGIN STATUS VERSION PATH\n'
printf 'scw@agent-workflows  installed, enabled  %s  https://github.com/shakacode/agent-workflows.git\n' "$version"
SH
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

assert_dir_empty() {
  local path="$1"
  [[ -z "$(find "$path" -mindepth 1 -print -quit)" ]] || fail "expected empty directory: $path"
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
  git -C "$source_dir" init --quiet --initial-branch=main
  git -C "$source_dir" config user.email "agent-workflows-test@example.com"
  git -C "$source_dir" config user.name "Agent Workflows Test"
  git -C "$source_dir" add .
  git -C "$source_dir" commit --quiet -m "initial"
  git -C "$source_dir" remote add origin https://github.com/shakacode/agent-workflows.git
  git -C "$source_dir" update-ref refs/remotes/origin/main HEAD
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
  assert_file "$target/bin/agent-workflows-doctor"
  assert_file "$target/bin/agent-workflows-lifecycle"
  assert_file "$target/bin/agent-workflows-resolve"
  assert_file "$target/bin/agent-workflows-run"
  assert_file "$target/bin/agent_workflows_operation/resolver.rb"
  assert_file "$target/bin/agent_workflows_operation/runner.rb"
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
  assert_file "$target/.agent-workflows-operation-state/lifecycle.lock"
  [[ ! -e "$target/.codex-plugin/plugin.json" ]] || fail "Codex native plugin manifest is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.agents/plugins/marketplace.json" ]] || fail "Codex marketplace metadata is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.claude-plugin/plugin.json" ]] || fail "Claude native plugin manifest is source-pack metadata, not installer-managed install metadata"
  [[ ! -e "$target/.claude-plugin/marketplace.json" ]] || fail "Claude marketplace metadata is source-pack metadata, not installer-managed install metadata"
  ruby -rjson -e 'metadata = JSON.parse(File.read(ARGV.fetch(0))); abort metadata.inspect unless metadata["host"] == "codex" && metadata["mode"] == "copy" && metadata["provider_profile"] == "pinned" && metadata["source_revision"].to_s.match?(/\A[0-9a-f]{40}\z/)' "$target/.agent-workflows-install.json"
}

test_default_flat_installs_seed_and_resolve_the_exact_committed_snapshot() {
  local tmp source revision target operation mode asset committed_skill committed_version receipt_version
  tmp="$(mktemp -d)"
  source="$tmp/source"
  mkdir -p "$source"
  new_source_repo "$source"
  revision="$(git -C "$source" rev-parse HEAD)"
  committed_skill="$(git -C "$source" show "$revision:skills/pr-batch/SKILL.md")"
  committed_version="$(git -C "$source" show "$revision:VERSION")"

  for mode in copy symlink; do
    target="$tmp/codex-$mode"
    printf 'dirty live source\n' > "$source/skills/pr-batch/SKILL.md"
    printf 'dirty-live-%s\n' "$mode" >"$source/VERSION"
    "$source/bin/install-agent-workflows" --host codex --target "$target" --mode "$mode" >"$tmp/install-$mode.out"

    [[ -d "$target/.agent-workflows-operation-state/store/$revision" ]] ||
      fail "$mode install did not seed its committed revision"
    if [[ "$mode" = "copy" ]]; then
      [[ "$(cat "$target/skills/pr-batch/SKILL.md")" = "$committed_skill" ]] ||
        fail "copy install selected uncommitted launcher content"
    fi
    operation="$("$target/bin/agent-workflows-resolve" begin --host codex --target "$target" --json)"
    asset="$(printf '%s' "$operation" | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("assets", "skills", "pr_batch")')"
    [[ "$(cat "$asset")" != "dirty live source" ]] ||
      fail "$mode pinned operation selected uncommitted live source content"
    receipt_version="$(ruby -rjson -e \
      'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' \
      "$target/.agent-workflows-install.json")"
    [[ "$receipt_version" = "$committed_version" ]] ||
      fail "$mode pinned receipt selected uncommitted VERSION: $receipt_version"
    ruby -rjson -e '
      payload = JSON.parse(STDIN.read)
      revision = ARGV.fetch(0)
      abort payload.inspect unless payload["provider_profile"] == "pinned" &&
                                   payload["freshness"] == "pinned" &&
                                   payload["revision"] == revision &&
                                   payload.dig("assets", "root").include?("/store/#{revision}/tree") &&
                                   payload["runner"].is_a?(Array) &&
                                   payload["release"].is_a?(Array)
    ' "$revision" <<<"$operation"
    git -C "$source" checkout --quiet -- skills/pr-batch/SKILL.md VERSION
  done
}

test_pinned_install_refuses_capacity_without_changing_the_receipt() {
  local tmp source target installed operation handle operation_root label revision candidate output status
  local index new_handle
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"
  "$source/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/initial.out"
  installed="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' \
    "$target/.agent-workflows-install.json")"
  operation="$("$target/bin/agent-workflows-resolve" begin --host codex --target "$target" --json)"
  handle="$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("operation")' <<<"$operation")"
  operation_root="$target/.agent-workflows-operation-state/operations/$handle"

  for label in b c d e f g h; do
    printf '%s\n' "$label" >"$source/VERSION"
    git -C "$source" add VERSION
    git -C "$source" commit --quiet -m "revision $label"
    revision="$(git -C "$source" rev-parse HEAD)"
    ruby -I"$source/bin" -ragent_workflows_operation/state -ragent_workflows_operation/store -e '
      target, source, revision = ARGV
      state = AgentWorkflowsOperation::State.new(target: target)
      AgentWorkflowsOperation::Store.new(state_root: state.root).import_local!(source, revision)
    ' "$target" "$source" "$revision"
    new_handle="$(printf '%s' "$label" | sha256sum | cut -d' ' -f1)"
    cp -a "$operation_root" "$target/.agent-workflows-operation-state/operations/$new_handle"
    rm "$target/.agent-workflows-operation-state/operations/$new_handle/operation.json"
    ruby -rjson -rdigest -e '
      source, destination, handle, revision = ARGV
      payload = JSON.parse(File.read(source))
      payload["operation"] = handle
      payload["revision"] = revision
      root = File.dirname(destination)
      refresh = lambda do |recorded, path|
        stat = File.stat(path)
        recorded.update("device" => stat.dev, "inode" => stat.ino, "size" => stat.size,
                        "sha256" => Digest::SHA256.file(path).hexdigest)
      end
      payload.fetch("runtime").each { |name, recorded| refresh.call(recorded, File.join(root, "runtime", name)) }
      payload.fetch("capabilities").each do |name, binding|
        binding.fetch("runtime").each_value do |recorded|
          refresh.call(recorded, File.join(root, "capabilities", name, recorded.fetch("path")))
        end
      end
      refresh.call(payload.fetch("launcher"), File.join(root, "launcher"))
      File.write(destination, JSON.pretty_generate(payload) + "\n")
      File.chmod(0o600, destination)
    ' "$operation_root/operation.json" \
      "$target/.agent-workflows-operation-state/operations/$new_handle/operation.json" \
      "$new_handle" "$revision"
  done

  printf 'i\n' >"$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "revision i"
  candidate="$(git -C "$source" rev-parse HEAD)"
  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "pinned install admitted a ninth protected revision"
  assert_contains "$output" "STATE_CAPACITY_REACHED"
  [[ "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' \
    "$target/.agent-workflows-install.json")" = "$installed" ]] ||
    fail "capacity refusal changed the installed receipt"
  [[ ! -e "$target/.agent-workflows-operation-state/store/$candidate" ]] ||
    fail "capacity refusal retained its unreferenced candidate"
  operation="$("$target/bin/agent-workflows-resolve" begin --host codex --target "$target" --json)"
  [[ "$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("revision")' <<<"$operation")" = "$installed" ]] ||
    fail "capacity refusal made the prior receipt unusable"

  for index in $(seq 1 23); do
    new_handle="$(printf 'operation-%s' "$index" | sha256sum | cut -d' ' -f1)"
    cp -a "$operation_root" "$target/.agent-workflows-operation-state/operations/$new_handle"
    rm "$target/.agent-workflows-operation-state/operations/$new_handle/operation.json"
    ruby -rjson -rdigest -e '
      source, destination, handle = ARGV
      payload = JSON.parse(File.read(source))
      payload["operation"] = handle
      root = File.dirname(destination)
      refresh = lambda do |recorded, path|
        stat = File.stat(path)
        recorded.update("device" => stat.dev, "inode" => stat.ino, "size" => stat.size,
                        "sha256" => Digest::SHA256.file(path).hexdigest)
      end
      payload.fetch("runtime").each { |name, recorded| refresh.call(recorded, File.join(root, "runtime", name)) }
      payload.fetch("capabilities").each do |name, binding|
        binding.fetch("runtime").each_value do |recorded|
          refresh.call(recorded, File.join(root, "capabilities", name, recorded.fetch("path")))
        end
      end
      refresh.call(payload.fetch("launcher"), File.join(root, "launcher"))
      File.write(destination, JSON.pretty_generate(payload) + "\n")
      File.chmod(0o600, destination)
    ' "$operation_root/operation.json" \
      "$target/.agent-workflows-operation-state/operations/$new_handle/operation.json" \
      "$new_handle"
  done

  set +e
  output="$("$source/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "pinned install admitted a candidate with 32 live operations"
  assert_contains "$output" "32/32 live operations"
  [[ "$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' \
    "$target/.agent-workflows-install.json")" = "$installed" ]] ||
    fail "operation-capacity refusal changed the installed receipt"
  [[ ! -e "$target/.agent-workflows-operation-state/store/$candidate" ]] ||
    fail "operation-capacity refusal retained its unreferenced candidate"

  "$target/bin/agent-workflows-resolve" release --host codex --target "$target" \
    --operation "$new_handle" --json >/dev/null
  operation="$("$target/bin/agent-workflows-resolve" begin --host codex --target "$target" --json)"
  [[ "$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("revision")' <<<"$operation")" = "$installed" ]] ||
    fail "operation-capacity refusal made the prior receipt unusable after a named release"
}

test_copy_mode_refuses_unsafe_bootstrap_directories() {
  local tmp target output status unsafe

  for unsafe in bin runtime; do
    tmp="$(mktemp -d)"
    target="$tmp/codex-home"
    mkdir -p "$target/bin/agent_workflows_operation"
    printf 'sentinel\n' > "$target/bin/agent_workflows_operation/sentinel"
    if [[ "$unsafe" = "bin" ]]; then
      chmod 0777 "$target/bin"
    else
      chmod 0777 "$target/bin/agent_workflows_operation"
    fi

    set +e
    output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "copy mode accepted unsafe $unsafe bootstrap directory"
    assert_contains "$output" "Refusing unsafe trusted directory"
    assert_file "$target/bin/agent_workflows_operation/sentinel"
    [[ ! -e "$target/.agent-workflows-install.json" ]] || \
      fail "unsafe $unsafe bootstrap directory committed metadata"
  done
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

test_copy_mode_refuses_an_exact_unmarked_doctor_copy_with_unsafe_modes() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  mkdir -p "$target/bin"
  rsync -a "$ROOT/bin/agent_doctor" "$target/bin/"
  chmod 0777 "$target/bin/agent_doctor"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "copy mode adopted an unsafe unmarked doctor copy"
  assert_contains "$output" "Refusing unmanaged workflow doctor directory"
  [[ ! -e "$target/bin/agent_doctor/.agent-workflows-managed" ]] ||
    fail "copy mode marked an unsafe doctor directory"
}

test_new_installer_control_helper_can_read_an_older_committed_snapshot() {
  local tmp source target
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source" "$target/bin"
  new_source_repo "$source"
  ruby -e '
    path = ARGV.fetch(0)
    text = File.binread(path)
    text.sub!(/\n    def compare_portable.*?^    end\n/m, "\n")
    text.sub!(/\n  when "compare-portable"\n    .*\n/, "\n")
    text.sub!(" | compare-portable LEFT RIGHT", "")
    File.binwrite(path, text)
  ' "$source/bin/agent_doctor/install_ownership.rb"
  git -C "$source" add bin/agent_doctor/install_ownership.rb
  git -C "$source" commit --quiet -m "simulate older committed ownership helper"
  rsync -a "$source/bin/agent_doctor" "$target/bin/"
  install -m 0755 "$PACK_ROOT/bin/agent_doctor/install_ownership.rb" \
    "$source/bin/agent_doctor/install_ownership.rb"

  "$source/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"

  grep -Eq '^agent-workflows-doctor-v1:[0-9a-f]{64}$' "$target/bin/agent_doctor/.agent-workflows-managed" ||
    fail "new installer control helper could not adopt content from an older committed snapshot"
}

test_copy_mode_removes_stale_files_from_a_signed_doctor_upgrade() {
  local tmp source target
  tmp="$(mktemp -d)"
  source="$tmp/old-source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"
  printf 'obsolete managed module\n' > "$source/bin/agent_doctor/obsolete.rb"
  git -C "$source" add bin/agent_doctor/obsolete.rb
  git -C "$source" commit --quiet -m "add obsolete managed module"
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
  local tmp target consumer host output gh
  local -a codex_args

  for host in codex claude; do
    tmp="$(mktemp -d)"
    target="$tmp/$host-home"
    consumer="$tmp/consumer"
    gh="$tmp/gh"
    printf '#!/bin/sh\nexit 0\n' >"$gh"
    chmod 0755 "$gh"
    write_native_scw_state "$host" "$target"
    mkdir -p "$target/skills/personal"
    printf 'personal\n' > "$target/skills/personal/SKILL.md"

    codex_args=()
    [[ "$host" != "codex" ]] || codex_args=(--codex-executable "$AGENT_WORKFLOWS_CODEX_EXECUTABLE")
    "$ROOT/bin/install-agent-workflows" --host "$host" --target "$target" --delivery-mode plugin-companion \
      --provider-profile managed --gh-executable "$gh" "${codex_args[@]}" --no-fetch \
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
    ruby -rjson -e '
      metadata = JSON.parse(File.read(ARGV.fetch(0)))
      abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion" &&
                                    metadata["mode"] == "copy" && metadata["provider_profile"] == "managed" &&
                                    metadata["gh_executable"] == ARGV.fetch(1)
    ' "$target/.agent-workflows-install.json" "$gh"

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

test_managed_profile_requires_explicit_absolute_gh_binding() {
  local tmp target output status
  tmp="$(mktemp -d)"
  target="$tmp/codex-home"
  write_native_scw_state codex "$target"

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" \
    --delivery-mode plugin-companion --provider-profile managed 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 64 ]] || fail "managed install without explicit gh returned $status: $output"
  assert_contains "$output" "requires --gh-executable with an explicit absolute path"
  [[ ! -e "$target/.agent-workflows-install.json" ]] || fail "failed managed install wrote metadata"
}

test_managed_install_copies_the_validated_commit_when_the_worktree_changes_after_validation() {
  local tmp source target gh enable mutated document committed_content committed_version receipt_version
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  gh="$tmp/gh"
  enable="$tmp/enable-mutation"
  mutated="$tmp/mutation-complete"
  document="docs/coordination-backend.md"
  printf '#!/bin/sh\nexit 0\n' >"$gh"
  chmod 0755 "$gh"
  mkdir -p "$source"
  new_source_repo "$source"
  committed_content="$(cat "$source/$document")"
  committed_version="$(cat "$source/VERSION")"

  ruby -e '
    path, enable, mutated, document, version = ARGV
    source = File.read(path)
    marker = "require_relative \"agent_doctor/timeout_budget\"\n"
    injection = <<~RUBY

      if ENV["AGENT_WORKFLOWS_LIFECYCLE_FD"] && File.exist?(#{enable.dump}) && !File.exist?(#{mutated.dump})
        File.write(#{document.dump}, "MUTATED WORKTREE CONTENT\\n")
        File.write(#{version.dump}, "MUTATED WORKTREE VERSION\\n")
        File.write(#{mutated.dump}, "done\\n")
      end
    RUBY
    abort "delivery-state marker missing" unless source.sub!(marker, marker + injection)
    File.write(path, source)
  ' "$source/bin/agent-workflows-delivery-state" "$enable" "$mutated" "$source/$document" "$source/VERSION"
  git -C "$source" add bin/agent-workflows-delivery-state
  git -C "$source" commit --quiet -m "instrument post-validation mutation"
  git -C "$source" update-ref refs/remotes/origin/main HEAD

  "$source/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"
  write_native_scw_state codex "$target"
  touch "$enable"
  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --delivery-mode plugin-companion --provider-profile managed --gh-executable "$gh" \
    --codex-executable "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" --no-fetch >"$tmp/managed.out"

  assert_file "$mutated"
  grep -qxF "MUTATED WORKTREE CONTENT" "$source/$document" ||
    fail "race fixture did not mutate the source worktree"
  [[ "$(cat "$target/$document")" = "$committed_content" ]] ||
    fail "managed install copied mutable worktree content instead of the validated commit"
  receipt_version="$(ruby -rjson -e \
    'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' \
    "$target/.agent-workflows-install.json")"
  [[ "$receipt_version" = "$committed_version" ]] ||
    fail "managed receipt selected post-validation VERSION: $receipt_version"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    expected = `git -C #{ARGV.fetch(1).dump} rev-parse HEAD`.strip
    abort metadata.inspect unless metadata["source_revision"] == expected
  ' "$target/.agent-workflows-install.json" "$source"
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

  mkdir -p "$plugin_root/skills/address-review" "$target/skills/address-review"
  cp "$source/skills/address-review/SKILL.md" "$plugin_root/skills/address-review/SKILL.md"
  rm -rf "$source/skills/address-review"
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
      printf '0.2.0\n' > "$target/.qa-codex-version"
      output="$("$source/bin/install-agent-workflows" --host "$host" --target "$target" 2>&1)"
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
  local tmp target output status metadata_before sentinel_before target_paths_before
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

  set +e
  output="$("$ROOT/bin/install-agent-workflows" --host codex --target "$target" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 64 ]] || fail "invalid recorded delivery mode exited $status: $output"
  assert_contains "$output" "Installed metadata delivery_mode must be flat or plugin-companion, got: hybrid"
  assert_not_contains "$output" "JSON::ParserError"
  assert_not_contains "$output" "common.rb"
  [[ "$metadata_before" = "$(shasum "$target/.agent-workflows-install.json")" ]] || \
    fail "invalid recorded delivery mode mutated metadata"
  [[ "$sentinel_before" = "$(shasum "$target/sentinel.txt")" ]] || \
    fail "invalid recorded delivery mode mutated sentinel"
  [[ "$target_paths_before" = "$(find "$target" -print | LC_ALL=C sort)" ]] || \
    fail "invalid recorded delivery mode changed the target tree"
  [[ ! -e "$target/.agent-workflows-install.lock" ]] || fail "invalid recorded delivery mode created install lock"
  [[ ! -e "$target/.agent-workflows-migration-staging" ]] || fail "invalid recorded delivery mode created staging receipt"
  [[ ! -e "$target/skills" ]] || fail "invalid recorded delivery mode created a flat skill layout"
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

test_pinned_install_rejects_non_git_source_before_legacy_cleanup() {
  local tmp current_source previous_source target output status

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

  set +e
  output="$("$current_source/bin/install-agent-workflows" --host codex --target "$target" --mode copy 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "pinned install accepted a source without committed Git HEAD"
  assert_contains "$output" "PINNED_PROVIDER_SOURCE_INVALID"
  assert_file "$target/docs/model-routing.md"
  [[ ! -e "$target/docs/agent-workflows-model-routing.md" ]] ||
    fail "failed pinned install mutated docs before source validation"
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

test_successful_upgrade_removes_transaction_backup() {
  local tmp source target backup_parent output
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  backup_parent="$tmp/upgrade backups"
  mkdir -p "$source" "$backup_parent"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install.out"
  printf '0.1.1\n' >"$source/VERSION"
  git -C "$source" add VERSION
  git -C "$source" commit --quiet -m "bump version"

  output="$(TMPDIR="$backup_parent" "$source/bin/upgrade-agent-workflows" \
    --target "$target" --source "$source" --no-fetch 2>&1)"

  assert_contains "$output" "UPGRADE_COMPLETE"
  assert_dir_empty "$backup_parent"
}

test_upgrade_fetches_linked_worktree_source() {
  local tmp source source_git publisher origin target output expected_revision installed_revision
  tmp="$(mktemp -d)"
  source="$tmp/source"
  source_git="$tmp/source.git"
  publisher="$tmp/publisher"
  origin="$tmp/origin.git"
  target="$tmp/codex-home"
  mkdir -p "$source" "$publisher"
  rsync -a --exclude .git "$ROOT/" "$source/"
  git init --quiet --bare --initial-branch=main "$origin"
  git -C "$source" init --quiet --initial-branch=main --separate-git-dir "$source_git"
  git -C "$source" config user.email "agent-workflows-test@example.com"
  git -C "$source" config user.name "Agent Workflows Test"
  git -C "$source" add .
  git -C "$source" commit --quiet -m "initial"
  git -C "$source" remote add origin "$origin"
  git -C "$source" push --quiet --set-upstream origin main

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install.out"
  git clone --quiet "$origin" "$publisher"
  git -C "$publisher" config user.email "agent-workflows-test@example.com"
  git -C "$publisher" config user.name "Agent Workflows Test"
  printf '0.1.1\n' > "$publisher/VERSION"
  git -C "$publisher" add VERSION
  git -C "$publisher" commit --quiet -m "bump version"
  git -C "$publisher" push --quiet
  expected_revision="$(git -C "$publisher" rev-parse HEAD)"

  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" 2>&1)"
  installed_revision="$(ruby -rjson -e '
    puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")
  ' "$target/.agent-workflows-install.json")"

  assert_contains "$output" "UPGRADE_COMPLETE"
  [[ "$(git -C "$source" rev-parse HEAD)" = "$expected_revision" ]] ||
    fail "linked source did not fast-forward"
  [[ "$installed_revision" = "$expected_revision" ]] ||
    fail "linked source upgrade installed $installed_revision instead of $expected_revision"
}

test_upgrade_rejects_a_declared_broken_git_checkout() {
  local tmp source target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  rsync -a --exclude .git "$ROOT/" "$source/"
  printf 'gitdir: /definitely/missing\n' > "$source/.git"

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 3 ]] || fail "broken declared Git source returned $status: $output"
  assert_contains "$output" "CHECK_FAILED declared Git source is invalid"
  assert_not_contains "$output" "UPGRADE_COMPLETE"
  [[ ! -e "$target/.agent-workflows-install.json" ]] ||
    fail "broken declared Git source installed workflow metadata"
}

test_upgrade_without_fetch_rejects_a_declared_broken_git_checkout() {
  local tmp source target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  rsync -a --exclude .git "$ROOT/" "$source/"
  printf 'gitdir: /definitely/missing\n' > "$source/.git"

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 3 ]] || fail "broken declared Git source without fetch returned $status: $output"
  assert_contains "$output" "CHECK_FAILED declared Git source is invalid"
  assert_not_contains "$output" "UPGRADE_COMPLETE"
  [[ ! -e "$target/.agent-workflows-install.json" ]] ||
    fail "broken declared Git source without fetch installed workflow metadata"
}

test_upgrade_rejects_plain_standalone_pinned_source() {
  local tmp source target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  rsync -a --exclude .git "$ROOT/" "$source/"

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "upgrade accepted a plain pinned source"
  assert_contains "$output" "PINNED_PROVIDER_SOURCE_INVALID"
  [[ ! -e "$target/.agent-workflows-install.json" ]] ||
    fail "failed plain-source upgrade installed workflow metadata"
}

test_upgrade_rejects_plain_pinned_source_nested_in_a_git_checkout() {
  local tmp parent source target output status
  tmp="$(mktemp -d)"
  parent="$tmp/parent"
  source="$parent/plain-pack"
  target="$tmp/codex-home"
  mkdir -p "$source"
  rsync -a --exclude .git "$ROOT/" "$source/"
  git -C "$parent" init --quiet

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "upgrade accepted nested plain pinned source"
  assert_contains "$output" "PINNED_PROVIDER_SOURCE_INVALID"
  [[ ! -e "$target/.agent-workflows-install.json" ]] ||
    fail "failed nested plain-source upgrade installed workflow metadata"
}

test_upgrade_rejects_a_declared_git_checkout_without_a_resolved_head() {
  local tmp source target output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  mkdir -p "$source"
  new_source_repo "$source"
  git -C "$source" update-ref -d HEAD

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 3 ]] || fail "declared Git source without HEAD returned $status: $output"
  assert_contains "$output" "CHECK_FAILED declared Git source commit check failed"
  assert_not_contains "$output" "UPGRADE_COMPLETE"
  [[ ! -e "$target/.agent-workflows-install.json" ]] ||
    fail "declared Git source without HEAD installed workflow metadata"
}

test_upgrade_can_select_and_then_replay_companion_delivery_mode() {
  local tmp source target gh
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  gh="$tmp/gh"
  printf '#!/bin/sh\nexit 0\n' >"$gh"
  chmod 0755 "$gh"
  mkdir -p "$source"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"
  write_native_scw_state codex "$target"
  "$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --delivery-mode plugin-companion --provider-profile managed --gh-executable "$gh" \
    --codex-executable "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" --no-fetch >"$tmp/upgrade-one.out"
  "$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --no-fetch >"$tmp/upgrade-two.out"

  [[ ! -e "$target/skills/pr-batch" ]] || fail "upgrade did not preserve companion delivery mode"
  ruby -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    abort metadata.inspect unless metadata["delivery_mode"] == "plugin-companion" &&
                                  metadata["provider_profile"] == "managed" &&
                                  metadata["gh_executable"] == ARGV.fetch(1)
  ' "$target/.agent-workflows-install.json" "$gh"
}

test_managed_upgrade_fetches_once_before_reinstalling_the_established_revision() {
  local tmp source target gh fetch_log
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  gh="$tmp/gh"
  fetch_log="$tmp/fetch.log"
  printf '#!/bin/sh\nexit 0\n' >"$gh"
  chmod 0755 "$gh"
  mkdir -p "$source"
  new_source_repo "$source"

  ruby -e '
    path = ARGV.fetch(0)
    source = File.read(path)
    marker = "  def fetch!(source)\n"
    replacement = <<~RUBY
      def fetch!(source)
        File.open(ENV.fetch("AGENT_WORKFLOWS_TEST_FETCH_LOG"), "a") { |file| file.puts("fetch") }
        return cached_revision!(source)
    RUBY
    abort "fetch marker missing" unless source.sub!(marker, replacement.lines.map { |line| "  #{line}" }.join.sub(/\A  /, ""))
    File.write(path, source)
  ' "$source/bin/agent_workflows_operation/source_contract.rb"
  git -C "$source" add bin/agent_workflows_operation/source_contract.rb
  git -C "$source" commit --quiet -m "instrument managed fetch"
  git -C "$source" update-ref refs/remotes/origin/main HEAD

  "$source/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"
  write_native_scw_state codex "$target"
  AGENT_WORKFLOWS_TEST_FETCH_LOG="$fetch_log" \
    "$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
      --delivery-mode plugin-companion --provider-profile managed --gh-executable "$gh" \
      --codex-executable "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" >"$tmp/upgrade.out"

  [[ "$(wc -l <"$fetch_log" | tr -d ' ')" = "1" ]] ||
    fail "managed upgrade fetched more than once: $(cat "$fetch_log")"
}

test_upgrade_rejects_a_changed_recorded_codex_resolution() {
  local tmp source target gh invocation first second output status recorded
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  gh="$tmp/gh"
  invocation="$tmp/bin/codex"
  first="$tmp/first/codex"
  second="$tmp/second/codex"
  printf '#!/bin/sh\nexit 0\n' >"$gh"
  chmod 0755 "$gh"
  mkdir -p "$source" "$(dirname "$invocation")" "$(dirname "$first")" "$(dirname "$second")"
  new_source_repo "$source"
  cp "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" "$first"
  cp "$AGENT_WORKFLOWS_CODEX_EXECUTABLE" "$second"
  chmod 0755 "$first" "$second"
  ln -s "$first" "$invocation"

  "$source/bin/install-agent-workflows" --host codex --target "$target" >"$tmp/install.out"
  write_native_scw_state codex "$target"
  "$source/bin/install-agent-workflows" --host codex --target "$target" \
    --delivery-mode plugin-companion --provider-profile managed --gh-executable "$gh" \
    --codex-executable "$invocation" --no-fetch >"$tmp/managed.out"
  recorded="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("codex_executable_resolved")' \
    "$target/.agent-workflows-install.json")"
  [[ "$recorded" = "$first" ]] || fail "managed install did not record the first Codex target"
  unlink "$invocation"
  ln -s "$second" "$invocation"

  set +e
  output="$("$source/bin/upgrade-agent-workflows" --host codex --target "$target" --source "$source" \
    --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "upgrade silently rebound the recorded Codex executable"
  assert_contains "$output" "resolution changed"
  assert_contains "$output" "reinstall"
  recorded="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("codex_executable_resolved")' \
    "$target/.agent-workflows-install.json")"
  [[ "$recorded" = "$first" ]] || fail "failed upgrade rewrote the recorded Codex target"
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
  local tmp source target consumer before after output status operation
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
  operation="$("$target/bin/agent-workflows-resolve" begin --host codex --target "$target" --json)"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    abort payload.inspect unless payload["provider_profile"] == "pinned" &&
                                 payload["freshness"] == "pinned" &&
                                 payload["revision"] == ARGV.fetch(0)
  ' "$before" <<<"$operation"
}

test_failed_upgrade_preserves_operation_state_and_removes_transaction_backup() {
  local tmp source target consumer backup_parent state before after output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  consumer="$tmp/consumer"
  backup_parent="$tmp/upgrade backups"
  state="$target/.agent-workflows-operation-state"
  mkdir -p "$source" "$consumer" "$backup_parent"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install.out"
  before="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' \
    "$target/.agent-workflows-install.json")"
  mkdir -p "$state"
  printf 'preserve-before\n' >"$state/preserve-before"
  printf 'removed-before\n' >"$state/removed-before"
  cat >"$source/bin/agent-workflow-seam-doctor" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
state="${QA_OPERATION_STATE:?}"
rm "$state/removed-before"
printf 'created-after\n' >"$state/created-after"
exit 19
BASH
  chmod +x "$source/bin/agent-workflow-seam-doctor"
  git -C "$source" add bin/agent-workflow-seam-doctor
  git -C "$source" commit --quiet -m "inject seam failure"

  set +e
  output="$(QA_OPERATION_STATE="$state" TMPDIR="$backup_parent" \
    "$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" \
    --consumer-root "$consumer" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 19 ]] || fail "expected seam failure exit 19, got $status: $output"
  assert_contains "$output" "ROLLBACK_COMPLETE"
  after="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("source_revision")' \
    "$target/.agent-workflows-install.json")"
  [[ "$before" = "$after" ]] || fail "rollback did not restore ordinary installer-owned state"
  [[ "$(cat "$state/preserve-before")" = "preserve-before" ]] ||
    fail "rollback changed operation state that predated the backup"
  [[ ! -e "$state/removed-before" ]] ||
    fail "rollback restored operation state removed after the backup"
  [[ "$(cat "$state/created-after")" = "created-after" ]] ||
    fail "rollback removed operation state created after the backup"
  assert_dir_empty "$backup_parent"
}

test_failed_restore_preserves_transaction_backup_for_manual_recovery() {
  local tmp source target consumer backup_parent fake_bin real_rsync output status backup
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  consumer="$tmp/consumer"
  backup_parent="$tmp/upgrade backups"
  fake_bin="$tmp/fake bin"
  real_rsync="$(command -v rsync)"
  mkdir -p "$source" "$consumer" "$backup_parent" "$fake_bin"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install.out"
  cat >"$source/bin/agent-workflow-seam-doctor" <<'BASH'
#!/usr/bin/env bash
exit 19
BASH
  chmod +x "$source/bin/agent-workflow-seam-doctor"
  git -C "$source" add bin/agent-workflow-seam-doctor
  git -C "$source" commit --quiet -m "inject seam failure"
  cat >"$fake_bin/rsync" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
if [[ "$source_path" = "${QA_BACKUP_PARENT:?}/"*"/target/" ]]; then
  printf 'partial restore\n' >"${QA_TARGET:?}/partial-restore-sentinel"
  echo "injected restore failure" >&2
  exit 41
fi
exec "${QA_REAL_RSYNC:?}" "$@"
BASH
  chmod +x "$fake_bin/rsync"

  set +e
  output="$(QA_BACKUP_PARENT="$backup_parent" QA_TARGET="$target" QA_REAL_RSYNC="$real_rsync" \
    TMPDIR="$backup_parent" PATH="$fake_bin:$PATH" \
    "$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" \
    --consumer-root "$consumer" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 19 ]] || fail "restore failure replaced original exit 19 with $status: $output"
  backup="$(find "$backup_parent" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -n "$backup" ]] || fail "failed restore deleted its only recovery backup: $output"
  assert_contains "$output" "ROLLBACK_FAILED restore_status=41 recovery_path=$backup"
  [[ -f "$backup/target/.agent-workflows-install.json" ]] ||
    fail "preserved recovery path does not contain the original installed target"
  [[ -f "$target/partial-restore-sentinel" ]] ||
    fail "restore failure fixture did not prove a partial restore"
}

test_upgrade_refuses_substituted_backup_identity_without_deleting_it() {
  local tmp source target backup_parent output status replacement original
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  backup_parent="$tmp/upgrade backups"
  mkdir -p "$source" "$backup_parent"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install.out"
  mv "$source/bin/install-agent-workflows" "$source/bin/install-agent-workflows.real"
  cat >"$source/bin/install-agent-workflows" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
backup="$(find "${QA_BACKUP_PARENT:?}" -mindepth 1 -maxdepth 1 -type d \
  -exec test -d '{}/target' ';' -print -quit)"
[[ -n "$backup" ]]
mv "$backup" "$backup.original"
mkdir "$backup"
printf 'replacement\n' >"$backup/replacement-sentinel"
exit 23
BASH
  chmod +x "$source/bin/install-agent-workflows"

  set +e
  output="$(QA_BACKUP_PARENT="$backup_parent" TMPDIR="$backup_parent" \
    "$source/bin/upgrade-agent-workflows" --target "$target" --source "$source" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 23 ]] || fail "expected injected installer exit 23, got $status: $output"
  assert_contains "$output" "ROLLBACK_FAILED backup identity changed"
  replacement="$(find "$backup_parent" -mindepth 1 -maxdepth 1 -type d ! -name '*.original' -print -quit)"
  original="$(find "$backup_parent" -mindepth 1 -maxdepth 1 -type d -name '*.original' -print -quit)"
  [[ -f "$replacement/replacement-sentinel" ]] ||
    fail "cleanup deleted the substituted backup directory"
  [[ -d "$original/target" ]] || fail "cleanup deleted the original backup after substitution"
}

test_upgrade_signal_after_backup_creation_cleans_transaction_backup() {
  local tmp source target backup_parent output status
  tmp="$(mktemp -d)"
  source="$tmp/source"
  target="$tmp/codex-home"
  backup_parent="$tmp/upgrade backups"
  mkdir -p "$source" "$backup_parent"
  new_source_repo "$source"

  "$source/bin/install-agent-workflows" --target "$target" >"$tmp/install.out"
  cat >"$source/bin/install-agent-workflows" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
kill -TERM "$PPID"
exit 0
BASH
  chmod +x "$source/bin/install-agent-workflows"

  set +e
  output="$(TMPDIR="$backup_parent" "$source/bin/upgrade-agent-workflows" \
    --target "$target" --source "$source" --no-fetch 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 143 ]] || fail "expected TERM exit 143, got $status: $output"
  assert_contains "$output" "ROLLBACK_COMPLETE"
  assert_dir_empty "$backup_parent"
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
    test_managed_profile_requires_explicit_absolute_gh_binding
    test_managed_install_copies_the_validated_commit_when_the_worktree_changes_after_validation
    test_plugin_companion_refuses_unknown_direct_skill_and_preserves_all_skills
    test_direct_migration_does_not_remove_skills_before_other_install_checks_pass
    test_metadata_temp_failure_preserves_flat_tree_and_prior_mode
    test_staging_race_blocks_installer_and_preserves_flat_tree
    test_final_verification_race_rolls_back_before_metadata_commit
    test_staging_json_extraction_failure_uses_receipt_to_roll_back
    test_failed_partial_rollback_preserves_receipt_for_retry
    test_recovery_normalization_failure_releases_install_lock
    test_crash_receipt_recovers_flat_staging_before_new_install
    test_crash_receipt_cleans_committed_companion_quarantine_without_restoring_flat
    test_flat_crash_recovery_rejects_symlink_staging_without_touching_outside_data
    test_flat_crash_recovery_rejects_symlink_skills_root_before_move
    test_companion_crash_cleanup_rejects_symlink_staging_without_touching_outside_data
    test_install_lock_blocks_concurrent_migration_before_mutation
    test_repeat_install_replays_recorded_companion_delivery_mode
    test_repeat_companion_install_blocks_new_current_native_skill_collision
    test_repeat_companion_install_blocks_native_skill_removed_from_current_source
    test_companion_install_rejects_mixed_valid_and_invalid_candidate_native_roots
    test_invalid_recorded_delivery_mode_fails_before_mutation
    test_companion_to_flat_refuses_unowned_same_named_skill
    test_auto_host_with_explicit_target_resolves_the_detected_host
    test_codex_host_install_writes_helpers_and_metadata
    test_default_flat_installs_seed_and_resolve_the_exact_committed_snapshot
    test_pinned_install_refuses_capacity_without_changing_the_receipt
    test_copy_mode_refuses_unsafe_bootstrap_directories
    test_copy_mode_refuses_unmanaged_agent_doctor_directory_before_collision
    test_copy_mode_adopts_an_exact_unmarked_agent_doctor_copy
    test_copy_mode_refuses_an_exact_unmarked_doctor_copy_with_unsafe_modes
    test_new_installer_control_helper_can_read_an_older_committed_snapshot
    test_copy_mode_removes_stale_files_from_a_signed_doctor_upgrade
    test_install_namespaces_model_routing_doc_and_preserves_generic_collision
    test_install_preserves_exact_content_generic_collision_without_source_evidence
    test_install_removes_legacy_managed_model_routing_path
    test_install_removes_legacy_copy_from_git_worktree_source
    test_pinned_install_rejects_non_git_source_before_legacy_cleanup
    test_installed_prompt_guard_ignores_unowned_docs
    test_installed_doctor_initializes_consumer_repo
    test_claude_host_install_uses_claude_home_when_target_is_omitted
    test_copy_mode_preserves_unrelated_agent_files
    test_copy_mode_does_not_replace_generic_consumer_docs
    test_symlink_mode_links_skills_workflows_and_helpers
    test_symlink_mode_replaces_docs_directory_symlink
    test_copy_mode_after_symlink_mode_does_not_delete_source_docs
    test_symlink_mode_refuses_unmanaged_live_and_dangling_doctor_links_before_mutation
    test_symlink_mode_replaces_recorded_prior_source_doctor_link
    test_copy_mode_migrates_dangling_recorded_doctor_symlink_from_deleted_source
    test_copy_mode_migrates_recorded_doctor_symlink_from_live_prior_source
    test_copy_mode_refuses_unproven_live_doctor_symlinks_without_mutation
    test_status_reports_not_installed_and_check_failed_explicitly
    test_status_reports_upgrade_available_between_source_commits
    test_upgrade_reinstalls_new_source_revision
    test_successful_upgrade_removes_transaction_backup
    test_upgrade_fetches_linked_worktree_source
    test_upgrade_rejects_a_declared_broken_git_checkout
    test_upgrade_without_fetch_rejects_a_declared_broken_git_checkout
    test_upgrade_rejects_plain_standalone_pinned_source
    test_upgrade_rejects_plain_pinned_source_nested_in_a_git_checkout
    test_upgrade_rejects_a_declared_git_checkout_without_a_resolved_head
    test_upgrade_can_select_and_then_replay_companion_delivery_mode
    test_managed_upgrade_fetches_once_before_reinstalling_the_established_revision
    test_upgrade_rejects_a_changed_recorded_codex_resolution
    test_upgrade_dry_run_checks_requested_delivery_mode
    test_upgrade_without_consumer_roots_succeeds
    test_upgrade_reports_missing_source_as_check_failed
    test_upgrade_rolls_back_when_consumer_seam_fails
    test_failed_upgrade_preserves_operation_state_and_removes_transaction_backup
    test_failed_restore_preserves_transaction_backup_for_manual_recovery
    test_upgrade_refuses_substituted_backup_identity_without_deleting_it
    test_upgrade_signal_after_backup_creation_cleans_transaction_backup
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
