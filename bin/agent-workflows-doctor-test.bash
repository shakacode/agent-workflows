#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dirs=()

cleanup() {
  local path
  for path in "${tmp_dirs[@]:-}"; do
    [[ -n "$path" ]] || continue
    rm -rf "$path"
  done
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_tmp_dir() {
  local output_variable="$1" path
  path="$(mktemp -d "${TMPDIR:-/tmp}/agent-workflows-doctor-test.XXXXXX")"
  tmp_dirs+=("$path")
  printf -v "$output_variable" '%s' "$path"
}

write_status_fixture() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'RUBY'
#!/usr/bin/env ruby
require "json"
def option_value(name)
  ARGV.fetch(ARGV.index(name) + 1)
end
def status_payload(status, installed_version:, available_version:, guidance: nil)
  {
    "status" => status,
    "host" => option_value("--host"),
    "target" => option_value("--target"),
    "source" => option_value("--source"),
    "installed_version" => installed_version,
    "installed_revision" => installed_version && "installed-revision",
    "available_version" => available_version,
    "available_revision" => available_version && "available-revision",
    "checked_remote" => false,
    "reason" => nil,
    "guidance" => guidance,
    "delivery_mode" => "flat",
    "native" => nil,
    "flat" => nil
  }
end
if ENV["WORKFLOW_STATUS_FIXTURE"] == "malformed"
  puts "not json"
  exit 0
end
if ENV["WORKFLOW_STATUS_FIXTURE"] == "wrong_shape"
  puts "[]"
  exit 0
end
if ENV["WORKFLOW_STATUS_FIXTURE"] == "nonzero_healthy"
  puts JSON.generate(status_payload("UP_TO_DATE", installed_version: "1.0.0", available_version: "1.0.0"))
  exit 1
end
if ENV["WORKFLOW_STATUS_FIXTURE"] == "stale"
  puts JSON.generate(status_payload("UPGRADE_AVAILABLE", installed_version: "1.0.0", available_version: "1.1.0",
                                    guidance: "Run the installer."))
  exit 1
end
if ENV["WORKFLOW_STATUS_FIXTURE"] == "stale_without_guidance"
  puts JSON.generate(status_payload("UPGRADE_AVAILABLE", installed_version: "1.0.0", available_version: "1.1.0"))
  exit 1
end
if ENV["WORKFLOW_STATUS_FIXTURE"] == "secret_guidance"
  puts JSON.generate(status_payload("UPGRADE_AVAILABLE", installed_version: "1.0.0", available_version: "1.1.0",
                                    guidance: ENV.fetch("WORKFLOW_SECRET")))
  exit 1
end
puts JSON.generate(status_payload("UP_TO_DATE", installed_version: "1.0.0", available_version: "1.0.0"))
RUBY
  chmod +x "$path"
}

write_seam_fixture() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'RUBY'
#!/usr/bin/env ruby
require "json"
puts JSON.generate("status" => "PASS", "issues" => [])
RUBY
  chmod +x "$path"
}

test_make_tmp_dir_registers_cleanup_in_parent_shell() {
  local before tmp
  before="${#tmp_dirs[@]}"

  make_tmp_dir tmp

  [[ -d "$tmp" ]] || fail "make_tmp_dir did not return a directory"
  [[ "${#tmp_dirs[@]}" -eq $((before + 1)) ]] || fail "make_tmp_dir did not register parent cleanup"
}

test_emits_healthy_stack_contract_through_public_command() {
  local tmp output status
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target"
  write_status_fixture "$tmp/target/bin/agent-workflows-status"

  set +e
  output="$("$ROOT/bin/agent-workflows-doctor" --stack-json \
    --host codex --target "$tmp/target" --source "$tmp/source")"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected healthy exit 0, got $status: $output"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    abort payload.inspect unless payload.keys.sort == %w[checks component schema_version status]
    abort payload.inspect unless payload["schema_version"] == 1
    abort payload.inspect unless payload["component"] == "agent-workflows"
    abort payload.inspect unless payload["status"] == "healthy"
    abort payload.inspect unless payload["checks"].map { |item| item["id"] } == %w[workflows.installation workflows.seam]
    payload["checks"].each do |check|
      abort check.inspect unless check.keys.sort == %w[details guidance id status summary]
    end
  ' <<< "$output"
}

test_maps_upgrade_available_to_degraded_exit() {
  local tmp output status
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target"
  write_status_fixture "$tmp/target/bin/agent-workflows-status"

  set +e
  output="$(WORKFLOW_STATUS_FIXTURE=stale "$ROOT/bin/agent-workflows-doctor" --stack-json \
    --host codex --target "$tmp/target" --source "$tmp/source")"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected degraded exit 1, got $status: $output"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    install = payload.fetch("checks").find { |item| item["id"] == "workflows.installation" }
    abort payload.inspect unless payload["status"] == "degraded"
    abort install.inspect unless install["status"] == "degraded"
    abort install.inspect unless install["guidance"] == "Run the installer."
  ' <<< "$output"
}

test_adds_fallback_guidance_for_upgrade_without_remediation() {
  local tmp output status
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target"
  write_status_fixture "$tmp/target/bin/agent-workflows-status"

  set +e
  output="$(WORKFLOW_STATUS_FIXTURE=stale_without_guidance "$ROOT/bin/agent-workflows-doctor" --stack-json \
    --host codex --target "$tmp/target" --source "$tmp/source")"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "upgrade without guidance returned $status instead of 1"

  ruby -rjson -e '
    install = JSON.parse(STDIN.read).fetch("checks").find { |item| item["id"] == "workflows.installation" }
    abort install.inspect unless install["guidance"] == "Upgrade workflows with `agent-stack sync`."
  ' <<< "$output"
}

test_sanitizes_component_output_and_parse_errors() {
  local tmp output status secret
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target"
  write_status_fixture "$tmp/target/bin/agent-workflows-status"
  secret="workflow-secret-value"

  set +e
  output="$(SENTINEL_API_TOKEN="$secret" WORKFLOW_SECRET="$secret" WORKFLOW_STATUS_FIXTURE=secret_guidance \
    "$ROOT/bin/agent-workflows-doctor" --stack-json --host codex --target "$tmp/target" --source "$tmp/source")"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "secret guidance fixture returned $status instead of 1"
  [[ "$output" != *"$secret"* && "$output" == *"[REDACTED]"* ]] || fail "component output exposed a secret: $output"

  set +e
  output="$(SENTINEL_API_TOKEN="$secret" "$ROOT/bin/agent-workflows-doctor" --invalid="$secret" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 64 ]] || fail "invalid option returned $status instead of 64"
  [[ "$output" != *"$secret"* && "$output" == *"[REDACTED]"* ]] || fail "parse error exposed a secret: $output"
}

test_wraps_malformed_status_output_in_failed_contract() {
  local tmp output status
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target"
  write_status_fixture "$tmp/target/bin/agent-workflows-status"

  set +e
  output="$(WORKFLOW_STATUS_FIXTURE=malformed "$ROOT/bin/agent-workflows-doctor" --stack-json \
    --host codex --target "$tmp/target" --source "$tmp/source" 2>/dev/null)"
  status=$?
  set -e

  [[ "$status" -eq 2 ]] || fail "expected failed exit 2, got $status: $output"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    install = payload.fetch("checks").find { |item| item["id"] == "workflows.installation" }
    abort payload.inspect unless payload["status"] == "failed"
    abort install.inspect unless install["status"] == "failed"
    abort install.inspect unless install["summary"].include?("malformed JSON")
  ' <<< "$output"
}

test_deep_mode_runs_workflow_seam_check() {
  local tmp output
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target"
  write_status_fixture "$tmp/target/bin/agent-workflows-status"
  write_seam_fixture "$tmp/target/bin/agent-workflow-seam-doctor"

  output="$("$ROOT/bin/agent-workflows-doctor" --stack-json --deep \
    --host codex --target "$tmp/target" --source "$tmp/source")"

  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    seam = payload.fetch("checks").find { |item| item["id"] == "workflows.seam" }
    abort seam.inspect unless seam["status"] == "healthy"
    abort seam.inspect unless seam["summary"] == "workflow seam contract passes"
  ' <<< "$output"
}

test_missing_or_mismatched_status_helper_returns_failed_contract() {
  local tmp output status mode
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target/bin"

  set +e
  output="$("$ROOT/bin/agent-workflows-doctor" --stack-json \
    --host codex --target "$tmp/target" --source "$tmp/source")"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "missing status helper should fail, got $status: $output"
  ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"

  write_status_fixture "$tmp/target/bin/agent-workflows-status"
  set +e
  output="$(WORKFLOW_STATUS_FIXTURE=nonzero_healthy "$ROOT/bin/agent-workflows-doctor" --stack-json \
    --host codex --target "$tmp/target" --source "$tmp/source")"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "status/exit mismatch should fail, got $status: $output"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    install = payload.fetch("checks").find { |item| item["id"] == "workflows.installation" }
    abort install.inspect unless install["status"] == "failed"
  ' <<< "$output"
}

test_wraps_non_object_status_payload_in_failed_contract() {
  local tmp output status
  make_tmp_dir tmp
  mkdir -p "$tmp/source" "$tmp/target"
  write_status_fixture "$tmp/target/bin/agent-workflows-status"

  set +e
  output="$(WORKFLOW_STATUS_FIXTURE=wrong_shape "$ROOT/bin/agent-workflows-doctor" --stack-json \
    --host codex --target "$tmp/target" --source "$tmp/source" 2>/dev/null)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "non-object status payload should fail, got $status: $output"
  ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"
}

test_make_tmp_dir_registers_cleanup_in_parent_shell
test_emits_healthy_stack_contract_through_public_command
test_maps_upgrade_available_to_degraded_exit
test_adds_fallback_guidance_for_upgrade_without_remediation
test_sanitizes_component_output_and_parse_errors
test_wraps_malformed_status_output_in_failed_contract
test_deep_mode_runs_workflow_seam_check
test_missing_or_mismatched_status_helper_returns_failed_contract
test_wraps_non_object_status_payload_in_failed_contract

echo "PASS agent-workflows doctor tests"
