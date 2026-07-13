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

assert_line_before() {
  local text="$1" first="$2" second="$3" first_line second_line
  first_line="$(printf '%s\n' "$text" | grep -Fn -m1 "$first" | cut -d: -f1 || true)"
  second_line="$(printf '%s\n' "$text" | grep -Fn -m1 "$second" | cut -d: -f1 || true)"
  [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] || \
    fail "expected '$first' before '$second'"
}

make_tmp_dir() {
  local path
  path="$(mktemp -d "${TMPDIR:-/tmp}/agent-stack-doctor-test.XXXXXX")"
  path="$(cd "$path" && pwd -P)"
  tmp_dirs+=("$path")
  printf '%s\n' "$path"
}

create_checkout() {
  local root="$1" name="$2" checkout="$root/src/$name"
  mkdir -p "$checkout" "$root/origins"
  git -C "$checkout" init --quiet -b main
  git -C "$checkout" config user.email doctor@example.com
  git -C "$checkout" config user.name "Doctor Fixture"
  git -C "$checkout" remote add origin "$root/origins/$name.git"
  printf '%s\n' "$name" > "$checkout/README.md"
  git -C "$checkout" add README.md
  git -C "$checkout" commit --quiet -m "doctor fixture $name"
}

write_ruby_delegate() {
  local path="$1" component="$2" check_id="$3"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<RUBY
#!/usr/bin/env ruby
require "json"
mode = "$component" == "agent-workflows" ? ENV.fetch("DOCTOR_WORKFLOW_FIXTURE", "healthy") : ENV.fetch("DOCTOR_COORD_FIXTURE", "healthy")
if "$component" == "agent-coordination" && ENV["DOCTOR_COORD_ARGS_FILE"]
  File.write(ENV["DOCTOR_COORD_ARGS_FILE"], ARGV.join("\n") + "\n")
end
if "$component" == "agent-workflows" && ENV["DOCTOR_WORKFLOW_ARGS_FILE"]
  File.write(ENV["DOCTOR_WORKFLOW_ARGS_FILE"], ARGV.join("\n") + "\n")
end
if mode == "malformed"
  puts "not json"
  exit 0
end
if mode == "oversized"
  STDOUT.write("x" * (1024 * 1024 + 1024))
  exit 0
end
if mode == "stderr_oversized"
  STDERR.write("x" * (64 * 1024 + 1024))
  exit 0
end
STDERR.write("delegate diagnostic noise\n") if mode == "noisy_stderr"
if mode == "timeout"
  child = fork { sleep 60 }
  File.write(ENV.fetch("DOCTOR_CHILD_PID_FILE"), child.to_s)
  sleep 60
end
payload = {
  "schema_version" => 1,
  "component" => "$component",
  "status" => "healthy",
  "checks" => [{"id" => "$check_id", "status" => "healthy", "summary" => "ready", "details" => {}, "guidance" => nil}]
}
payload["checks"][0]["details"] = [] if mode == "invalid_check"
payload["future"] = {"secret" => "discard-me"} if mode == "additive"
payload["checks"][0]["future"] = "discard-me" if mode == "additive"
if ["hostile", "hostile_url"].include?(mode)
  url = ENV.fetch("AGENT_COORD_API_URL")
  suffix = mode == "hostile" ? "\n\e[31mtext" : ""
  payload["status"] = "degraded"
  payload["checks"][0] = {
    "id" => "$check_id", "status" => "degraded", "summary" => "unsafe #{url}#{suffix}",
    "details" => {"url" => url}, "guidance" => "Inspect #{url}"
  }
end
puts JSON.generate(payload)
exit 1 if mode == "mismatch"
exit 1 if ["hostile", "hostile_url"].include?(mode)
RUBY
  chmod +x "$path"
}

write_dashboard_delegate() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'JAVASCRIPT'
#!/usr/bin/env node
const mode = process.env.DOCTOR_DASHBOARD_FIXTURE || "healthy";
const degraded = mode === "stopped";
if (process.env.DOCTOR_DASHBOARD_ARGS_FILE) {
  require("fs").writeFileSync(process.env.DOCTOR_DASHBOARD_ARGS_FILE, process.argv.slice(2).join("\n") + "\n");
}
console.log(JSON.stringify({
  schema_version: 1,
  component: "agent-coordination-dashboard",
  status: degraded ? "degraded" : "healthy",
  checks: [{
    id: "dashboard.health",
    status: degraded ? "degraded" : "healthy",
    summary: degraded ? "dashboard service is not running" : "ready",
    details: {},
    guidance: degraded ? "Start the optional dashboard, then rerun doctor." : null
  }]
}));
if (degraded) process.exitCode = 1;
JAVASCRIPT
  chmod +x "$path"
}

setup_fixture() {
  local root="$1" name
  for name in agent-workflows agent-coordination agent-coordination-dashboard; do
    create_checkout "$root" "$name"
  done
  mkdir -p "$root/compat" "$root/target" "$root/install" "$root/runtime/state"
  for name in agent-workflows agent-coordination agent-coordination-dashboard; do
    ln -s "$root/src/$name" "$root/compat/$name"
  done
  write_ruby_delegate "$root/target/bin/agent-workflows-doctor" agent-workflows workflows.installation
  write_ruby_delegate "$root/install/agent-coord" agent-coordination coordination.backend
  write_dashboard_delegate "$root/src/agent-coordination-dashboard/bin/agent-coordination-dashboard.js"
  git -C "$root/src/agent-coordination-dashboard" add bin/agent-coordination-dashboard.js
  git -C "$root/src/agent-coordination-dashboard" commit --quiet -m "add doctor fixture"
}

doctor_command() {
  local root="$1"
  shift
  local variable
  local -a environment command
  environment=(env)
  if [[ "${DOCTOR_BACKEND_MODE:-explicit}" = explicit ]]; then
    environment+=("AGENT_COORD_STATE_ROOT=${DOCTOR_EXPLICIT_STATE_ROOT:-$root/runtime/state}")
  else
    environment+=(-u AGENT_COORD_STATE_ROOT -u AGENT_COORD_BACKEND -u AGENT_COORD_STATUS_STATE_ROOT)
    if [[ "${DOCTOR_BACKEND_MODE:-}" = runtime ]]; then
      environment+=(-u AGENT_COORD_API_URL)
    fi
  fi
  environment+=(
    "AGENT_STACK_AGENT_WORKFLOWS_URL=$root/origins/agent-workflows.git"
    "AGENT_STACK_AGENT_COORDINATION_URL=$root/origins/agent-coordination.git"
    "AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL=$root/origins/agent-coordination-dashboard.git"
  )
  for variable in XDG_STATE_HOME DOCTOR_WORKFLOW_FIXTURE DOCTOR_COORD_FIXTURE DOCTOR_DASHBOARD_FIXTURE \
    DOCTOR_WORKFLOW_ARGS_FILE DOCTOR_COORD_ARGS_FILE DOCTOR_DASHBOARD_ARGS_FILE DOCTOR_CHILD_PID_FILE SENTINEL_API_TOKEN; do
    if [[ -n "${!variable:-}" ]]; then
      environment+=("$variable=${!variable}")
    fi
  done
  if [[ "${DOCTOR_BACKEND_MODE:-}" = api && -n "${AGENT_COORD_API_URL:-}" ]]; then
    environment+=("AGENT_COORD_API_URL=$AGENT_COORD_API_URL")
  fi
  command=(
    "$ROOT/bin/agent-stack" doctor
    --source-root "$root/src"
    --compat-root "$root/compat"
    --runtime-root "$root/runtime"
    --target "$root/target"
    --agent-coord-install-dir "$root/install"
    --dashboard-url "${DOCTOR_DASHBOARD_URL:-http://127.0.0.1:4319}"
    "$@"
  )
  "${environment[@]}" "${command[@]}"
}

test_aggregates_uniform_component_contracts_with_generic_checks() {
  local tmp output status
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  set +e
  output="$(doctor_command "$tmp" --json)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected healthy exit 0, got $status: $output"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    abort payload.inspect unless payload["schema_version"] == 1 && payload["status"] == "healthy"
    expected = %w[agent-workflows agent-coordination agent-coordination-dashboard]
    abort payload.inspect unless payload.fetch("components").map { |item| item["component"] } == expected
    payload.fetch("components").each do |component|
      abort component.inspect unless component.keys.sort == %w[checks component schema_version status]
      generic = component.fetch("checks").map { |check| check["id"] }.grep(/\.(source|compatibility)\z/)
      abort component.inspect unless generic.length == 2
    end
  ' <<< "$output"
}

test_rejects_invalid_check_contract_and_status_exit_mismatch() {
  local tmp output status mode
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  for mode in invalid_check mismatch; do
    set +e
    output="$(DOCTOR_WORKFLOW_FIXTURE="$mode" doctor_command "$tmp" --json)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]] || fail "$mode contract should fail, got $status: $output"
    ruby -rjson -e '
      payload = JSON.parse(STDIN.read)
      component = payload.fetch("components").find { |item| item["component"] == "agent-workflows" }
      wrapper = component.fetch("checks").find { |item| item["id"] == "agent-workflows.doctor" }
      abort component.inspect unless component["status"] == "failed" && wrapper["status"] == "failed"
    ' <<< "$output"
  done
}

test_wraps_malformed_output_and_discards_additive_fields() {
  local tmp output status
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  set +e
  output="$(DOCTOR_WORKFLOW_FIXTURE=malformed doctor_command "$tmp" --json)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "malformed output should fail, got $status: $output"
  ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"
  [[ "$output" != *"not json"* ]] || fail "raw malformed output escaped the aggregate"

  output="$(DOCTOR_WORKFLOW_FIXTURE=additive doctor_command "$tmp" --json)"
  [[ "$output" != *"discard-me"* && "$output" != *'"future"'* ]] || fail "additive fields escaped contract normalization"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    component = payload.fetch("components").find { |item| item["component"] == "agent-workflows" }
    abort component.inspect unless component["status"] == "healthy"
  ' <<< "$output"
}

test_keeps_delegate_stderr_out_of_json_stdout() {
  local tmp output status
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  set +e
  output="$(DOCTOR_WORKFLOW_FIXTURE=noisy_stderr doctor_command "$tmp" --json 2>"$tmp/stderr")"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "healthy noisy delegate should remain healthy, got $status: $output"
  [[ ! -s "$tmp/stderr" ]] || fail "delegate stderr escaped the master process"
  [[ "$output" != *"delegate diagnostic noise"* ]] || fail "delegate stderr contaminated JSON stdout"
  ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"
}

test_uses_generic_wrapper_checks_when_delegates_are_unavailable() {
  local tmp output status
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"
  rm "$tmp/target/bin/agent-workflows-doctor"

  set +e
  output="$(doctor_command "$tmp" --json)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "missing workflow delegate should fail, got $status: $output"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    component = payload.fetch("components").find { |item| item["component"] == "agent-workflows" }
    ids = component.fetch("checks").map { |item| item["id"] }
    abort ids.inspect unless ids.include?("agent-workflows.doctor")
    abort ids.inspect if ids.include?("workflows.installation") || ids.include?("workflows.seam")
  ' <<< "$output"
}

test_backend_discovery_prefers_runtime_state_and_preserves_missing_explicit_root() {
  local tmp args_file missing output
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"
  mkdir -p "$tmp/xdg/agent-coordination"
  args_file="$tmp/coord-args"

  XDG_STATE_HOME="$tmp/xdg" DOCTOR_BACKEND_MODE=runtime DOCTOR_COORD_ARGS_FILE="$args_file" \
    doctor_command "$tmp" --json >/dev/null
  grep -Fxq -- "$tmp/runtime/state" "$args_file" || \
    fail "runtime state did not win over the implicit XDG default: $(tr '\n' ' ' < "$args_file")"

  missing="$tmp/missing-explicit-state"
  DOCTOR_EXPLICIT_STATE_ROOT="$missing" DOCTOR_COORD_ARGS_FILE="$args_file" doctor_command "$tmp" --json >/dev/null
  grep -Fxq -- "$missing" "$args_file" || fail "missing explicit state root was not passed authoritatively"
  [[ ! -e "$missing" ]] || fail "doctor created the missing explicit state root"
}

test_distinguishes_dangling_links_from_links_to_another_checkout() {
  local tmp output
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"
  rm "$tmp/compat/agent-workflows"
  ln -s "$tmp/missing-checkout" "$tmp/compat/agent-workflows"

  set +e
  output="$(doctor_command "$tmp" --json)"
  set -e
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    component = payload.fetch("components").find { |item| item["component"] == "agent-workflows" }
    link = component.fetch("checks").find { |item| item["id"] == "agent-workflows.compatibility" }
    abort link.inspect unless link["summary"] == "compatibility link is dangling"
  ' <<< "$output"

  rm "$tmp/compat/agent-workflows"
  ln -s "$tmp/src/agent-coordination" "$tmp/compat/agent-workflows"
  set +e
  output="$(doctor_command "$tmp" --json)"
  set -e
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    component = payload.fetch("components").find { |item| item["component"] == "agent-workflows" }
    link = component.fetch("checks").find { |item| item["id"] == "agent-workflows.compatibility" }
    abort link.inspect unless link["summary"] == "compatibility link targets another checkout"
  ' <<< "$output"
}

test_redacts_malformed_percent_encoded_urls_in_json_and_human_output() {
  local tmp rendering output status url
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"
  url='http://user:credential-material@127.0.0.1:9/path?token=%73entinel-secret-value%ZZ&next=visible'

  for rendering in json human; do
    set +e
    if [[ "$rendering" = json ]]; then
      output="$(DOCTOR_BACKEND_MODE=api DOCTOR_COORD_FIXTURE=hostile AGENT_COORD_API_URL="$url" \
        SENTINEL_API_TOKEN=sentinel-secret-value doctor_command "$tmp" --json 2>&1)"
    else
      output="$(DOCTOR_BACKEND_MODE=api DOCTOR_COORD_FIXTURE=hostile AGENT_COORD_API_URL="$url" \
        SENTINEL_API_TOKEN=sentinel-secret-value doctor_command "$tmp" 2>&1)"
    fi
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "hostile contract should degrade, got $status: $output"
    [[ "$output" != *"credential-material"* ]] || fail "URL credential leaked in $rendering output"
    [[ "$output" != *"sentinel-secret-value"* && "$output" != *"%73entinel"* && "$output" != *"%ZZ"* ]] || \
      fail "malformed token-bearing query leaked in $rendering output"
    [[ "$output" == *"[REDACTED]"* ]] || fail "redaction marker missing from $rendering output"
    [[ "$output" != *$'\e'* ]] || fail "ANSI escape leaked in $rendering output"
    if [[ "$rendering" = json ]]; then ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"; fi
  done
}

test_redacts_encoded_url_userinfo_in_json_and_human_output() {
  local tmp rendering output status url
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"
  url='http://user%3Acredential-material%40localhost:4319/path'

  for rendering in json human; do
    set +e
    if [[ "$rendering" = json ]]; then
      output="$(DOCTOR_BACKEND_MODE=api DOCTOR_COORD_FIXTURE=hostile_url AGENT_COORD_API_URL="$url" \
        SENTINEL_API_TOKEN=sentinel-secret-value doctor_command "$tmp" --json 2>&1)"
    else
      output="$(DOCTOR_BACKEND_MODE=api DOCTOR_COORD_FIXTURE=hostile_url AGENT_COORD_API_URL="$url" \
        SENTINEL_API_TOKEN=sentinel-secret-value doctor_command "$tmp" 2>&1)"
    fi
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "hostile contract should degrade, got $status: $output"
    [[ "$output" != *"credential-material"* && "$output" != *"user%3A"* ]] || \
      fail "encoded URL credential leaked in $rendering output"
    [[ "$output" == *"localhost:4319/path"* ]] || fail "safe URL structure was lost from $rendering output"
    [[ "$output" == *"[REDACTED]"* ]] || fail "redaction marker missing from $rendering output"
    if [[ "$rendering" = json ]]; then ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"; fi
  done
}

test_redacts_encoded_url_userinfo_with_malformed_query_in_json_and_human_output() {
  local tmp rendering output status url
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"
  url='http://user%3acredential-material%40localhost:4319/path?token=%73entinel-secret-value%ZZ&next=visible'

  for rendering in json human; do
    set +e
    if [[ "$rendering" = json ]]; then
      output="$(DOCTOR_BACKEND_MODE=api DOCTOR_COORD_FIXTURE=hostile_url AGENT_COORD_API_URL="$url" \
        SENTINEL_API_TOKEN=sentinel-secret-value doctor_command "$tmp" --json 2>&1)"
    else
      output="$(DOCTOR_BACKEND_MODE=api DOCTOR_COORD_FIXTURE=hostile_url AGENT_COORD_API_URL="$url" \
        SENTINEL_API_TOKEN=sentinel-secret-value doctor_command "$tmp" 2>&1)"
    fi
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "hostile contract should degrade, got $status: $output"
    [[ "$output" != *"credential-material"* && "$output" != *"user%3a"* ]] || \
      fail "encoded URL credential leaked through malformed $rendering output"
    [[ "$output" != *"sentinel-secret-value"* && "$output" != *"%73entinel"* && "$output" != *"%ZZ"* ]] || \
      fail "malformed token-bearing query leaked in $rendering output"
    [[ "$output" == *"localhost:4319/path"* ]] || fail "safe URL structure was lost from $rendering output"
    [[ "$output" == *"[REDACTED]"* ]] || fail "redaction marker missing from $rendering output"
    if [[ "$rendering" = json ]]; then ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"; fi
  done
}

test_human_output_is_problems_first_with_json_status_and_guidance_parity() {
  local tmp text json text_status json_status guidance status
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  set +e
  text="$(DOCTOR_DASHBOARD_FIXTURE=stopped doctor_command "$tmp")"
  status=$?
  json="$(DOCTOR_DASHBOARD_FIXTURE=stopped doctor_command "$tmp" --json)"
  set -e
  [[ "$status" -eq 1 ]] || fail "stopped optional dashboard should degrade, got $status: $text"
  text_status="$(printf '%s\n' "$text" | sed -n '1s/^Agent Stack Doctor: //p' | tr '[:upper:]' '[:lower:]')"
  json_status="$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("status")' <<< "$json")"
  [[ "$text_status" = "$json_status" && "$json_status" = degraded ]] || fail "human/JSON status parity failed"
  assert_line_before "$text" "[DEGRADED] agent-coordination-dashboard" "[HEALTHY] agent-workflows"
  assert_line_before "$text" "[DEGRADED] Health" "[HEALTHY] Source"
  guidance="$(ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    dashboard = payload.fetch("components").find { |item| item["component"] == "agent-coordination-dashboard" }
    puts dashboard.fetch("checks").find { |item| item["id"] == "dashboard.health" }.fetch("guidance")
  ' <<< "$json")"
  [[ "$text" == *"Next         $guidance"* ]] || fail "human guidance differs from JSON contract"
}

test_bounds_delegate_output_and_cleans_timed_out_process_groups() {
  local tmp mode output status child_pid attempts
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  for mode in oversized stderr_oversized; do
    set +e
    output="$(DOCTOR_WORKFLOW_FIXTURE="$mode" doctor_command "$tmp" --json 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]] || fail "$mode delegate should fail, got $status"
    [[ "$output" == *"output exceeded diagnostic size limit"* ]] || fail "$mode limit failure was not normalized"
    [[ "${#output}" -lt 200000 ]] || fail "$mode output escaped the bounded aggregate"
  done

  set +e
  output="$(DOCTOR_WORKFLOW_FIXTURE=timeout DOCTOR_CHILD_PID_FILE="$tmp/child-pid" \
    doctor_command "$tmp" --json)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "timed-out delegate should fail, got $status: $output"
  [[ "$output" == *"diagnostic timed out"* ]] || fail "timeout was not normalized"
  [[ -s "$tmp/child-pid" ]] || fail "timeout fixture did not record its descendant"
  child_pid="$(<"$tmp/child-pid")"
  attempts=0
  while kill -0 "$child_pid" 2>/dev/null && [[ "$attempts" -lt 50 ]]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  ! kill -0 "$child_pid" 2>/dev/null || fail "timed-out delegate descendant survived process-group cleanup"
}

test_missing_roots_are_read_only_and_master_prerequisites_exit_64() {
  local tmp output status helper
  tmp="$(make_tmp_dir)"

  set +e
  output="$(env -u AGENT_COORD_STATE_ROOT -u AGENT_COORD_API_URL -u AGENT_COORD_BACKEND \
    "$ROOT/bin/agent-stack" doctor --json \
      --source-root "$tmp/missing-source" --compat-root "$tmp/missing-compat" \
      --runtime-root "$tmp/missing-runtime" --target "$tmp/missing-target" \
      --agent-coord-install-dir "$tmp/missing-install" --dashboard-url http://127.0.0.1:9)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "missing stack should return health exit 2, got $status: $output"
  ruby -rjson -e 'JSON.parse(STDIN.read)' <<< "$output"
  [[ ! -e "$tmp/missing-source" && ! -e "$tmp/missing-compat" && ! -e "$tmp/missing-runtime" && \
     ! -e "$tmp/missing-target" && ! -e "$tmp/missing-install" ]] || fail "doctor created a selected root"

  set +e
  output="$(RUBY_BIN=definitely-missing-ruby "$ROOT/bin/agent-stack" doctor --json 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 64 && "$output" == *"requires Ruby"* ]] || fail "missing Ruby should return usage/unable exit 64"

  helper="$tmp/missing-helper"
  set +e
  output="$(AGENT_STACK_DOCTOR_BIN="$helper" "$ROOT/bin/agent-stack" doctor --json 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 64 && "$output" == *"helper missing"* ]] || fail "missing master helper should return exit 64"
}

test_rejects_unsafe_dashboard_urls_before_delegation() {
  local tmp output status
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  set +e
  output="$(DOCTOR_DASHBOARD_URL='http://example.com:4319' doctor_command "$tmp" --json 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 64 ]] || fail "unsafe dashboard URL should return usage exit 64, got $status: $output"
  [[ "$output" == *"must use loopback HTTP"* ]] || fail "unsafe dashboard URL guidance missing: $output"
}

test_invokes_each_owned_component_interface_with_deep_selectors() {
  local tmp workflow_args coord_args dashboard_args
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"
  workflow_args="$tmp/workflow-args"
  coord_args="$tmp/coord-args"
  dashboard_args="$tmp/dashboard-args"

  DOCTOR_WORKFLOW_ARGS_FILE="$workflow_args" DOCTOR_COORD_ARGS_FILE="$coord_args" \
    DOCTOR_DASHBOARD_ARGS_FILE="$dashboard_args" doctor_command "$tmp" --deep --json >/dev/null

  [[ "$(tr '\n' ' ' < "$workflow_args")" == \
    "--stack-json --host codex --target $tmp/target --source $tmp/src/agent-workflows --deep " ]] || \
    fail "workflow component interface arguments drifted"
  [[ "$(tr '\n' ' ' < "$coord_args")" == \
    "doctor --stack-json --deep --state-root $tmp/runtime/state " ]] || fail "coordination component interface arguments drifted"
  [[ "$(tr '\n' ' ' < "$dashboard_args")" == \
    "doctor --stack-json --deep --url http://127.0.0.1:4319 " ]] || fail "dashboard component interface arguments drifted"
}

test_secret_values_cannot_corrupt_trusted_status_tokens() {
  local tmp output status
  tmp="$(make_tmp_dir)"
  setup_fixture "$tmp"

  set +e
  output="$(SENTINEL_API_TOKEN=healthy doctor_command "$tmp" --json)"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "secret matching a status token corrupted exit parity: $status $output"
  ruby -rjson -e '
    payload = JSON.parse(STDIN.read)
    abort payload.inspect unless payload["status"] == "healthy"
    abort payload.inspect unless payload.fetch("components").all? { |item| item["status"] == "healthy" }
  ' <<< "$output"
}

run_test() {
  local name="$1"
  if [[ -z "${AGENT_STACK_DOCTOR_TEST_FILTER:-}" || "$name" = *"$AGENT_STACK_DOCTOR_TEST_FILTER"* ]]; then
    "$name"
  fi
}

run_test test_aggregates_uniform_component_contracts_with_generic_checks
run_test test_rejects_invalid_check_contract_and_status_exit_mismatch
run_test test_wraps_malformed_output_and_discards_additive_fields
run_test test_keeps_delegate_stderr_out_of_json_stdout
run_test test_uses_generic_wrapper_checks_when_delegates_are_unavailable
run_test test_backend_discovery_prefers_runtime_state_and_preserves_missing_explicit_root
run_test test_distinguishes_dangling_links_from_links_to_another_checkout
run_test test_redacts_malformed_percent_encoded_urls_in_json_and_human_output
run_test test_redacts_encoded_url_userinfo_in_json_and_human_output
run_test test_redacts_encoded_url_userinfo_with_malformed_query_in_json_and_human_output
run_test test_human_output_is_problems_first_with_json_status_and_guidance_parity
run_test test_bounds_delegate_output_and_cleans_timed_out_process_groups
run_test test_missing_roots_are_read_only_and_master_prerequisites_exit_64
run_test test_rejects_unsafe_dashboard_urls_before_delegation
run_test test_invokes_each_owned_component_interface_with_deep_selectors
run_test test_secret_values_cannot_corrupt_trusted_status_tokens

echo "PASS agent-stack doctor tests"
