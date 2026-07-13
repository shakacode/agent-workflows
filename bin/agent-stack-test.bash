#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RUBY_BIN="${RUBY_BIN:-$(command -v ruby)}"
tmp_registry="$(mktemp)"

make_tmp_dir() {
  local path
  path="$(mktemp -d)"
  printf '%s\n' "$path" >> "$tmp_registry"
  printf '%s\n' "$path"
}

make_tmp_file() {
  local path
  path="$(mktemp)"
  printf '%s\n' "$path" >> "$tmp_registry"
  printf '%s\n' "$path"
}

cleanup() {
  local item
  while IFS= read -r item; do
    [[ "$item" = process:* ]] || continue
    kill "${item#process:}" 2>/dev/null || true
    wait "${item#process:}" 2>/dev/null || true
  done < "$tmp_registry"
  while IFS= read -r item; do
    [[ "$item" = process:* ]] && continue
    if [[ -d "$item" ]]; then
      rm -r -- "$item"
    else
      rm -f -- "$item"
    fi
  done < "$tmp_registry"
  rm -f "$tmp_registry"
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain '$needle', got: $haystack"
}

assert_line_before() {
  local haystack="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  first_line="$(printf '%s\n' "$haystack" | grep -n -F -m1 "$first" | cut -d: -f1)"
  second_line="$(printf '%s\n' "$haystack" | grep -n -F -m1 "$second" | cut -d: -f1)"
  [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] || \
    fail "expected '$first' before '$second', got: $haystack"
}

doctor_json_value() {
  local document="$1"
  local query="$2"
  "$RUBY_BIN" -rjson -e '
    document, query = ARGV
    payload = JSON.parse(document)
    checks = payload.fetch("components").flat_map { |component| component.fetch("checks") }
    coordination = payload.fetch("components").find { |component| component.fetch("id") == "agent-coordination" }
    dashboard = payload.fetch("components").last
    workflow = payload.fetch("components").first
    value = case query
            when "status" then payload.fetch("status")
            when "schema_version" then payload.fetch("schema_version")
            when "component_ids" then payload.fetch("components").map { |component| component.fetch("id") }.join(",")
            when "check_ids" then checks.map { |check| check.fetch("id") }.join(",")
            when "skipped_count" then checks.count { |check| check.fetch("status") == "skipped" }
            when "component_count" then payload.fetch("components").length
            when "stable_check_keys" then payload.fetch("components").all? { |component| component.fetch("checks").all? { |check| check.key?("id") && check.key?("status") && check.key?("summary") } }
            when "coordination_status" then coordination.fetch("status")
            when "coordination_backend_status" then coordination.fetch("checks").find { |check| check.fetch("id") == "coordination.backend" }.fetch("status")
            when "coordination_resources_status" then coordination.fetch("checks").find { |check| check.fetch("id") == "coordination.resources" }.fetch("status")
            when "workflow_installation_status" then workflow.fetch("checks").find { |check| check.fetch("id") == "workflows.installation" }.fetch("status")
            when "workflow_installation_guidance" then workflow.fetch("checks").find { |check| check.fetch("id") == "workflows.installation" }.fetch("guidance")
            when "workflow_host" then workflow.fetch("checks").find { |check| check.fetch("id") == "workflows.installation" }.fetch("details").fetch("host")
            when "dashboard_health_status" then dashboard.fetch("checks").find { |check| check.fetch("id") == "dashboard.health" }.fetch("status")
            when "dashboard_resources_status" then dashboard.fetch("checks").find { |check| check.fetch("id") == "dashboard.resources" }.fetch("status")
            else abort "unknown doctor JSON query: #{query}"
            end
    puts value
  ' "$document" "$query"
}

create_doctor_checkout() {
  local root="$1"
  local name="$2"
  local checkout="$root/src/$name"
  local origin="$root/origins/$name.git"
  mkdir -p "$checkout" "$root/origins"
  git -C "$checkout" init --quiet --initial-branch=main
  git -C "$checkout" config user.email "agent-stack-test@example.com"
  git -C "$checkout" config user.name "Agent Stack Test"
  printf '# %s\n' "$name" > "$checkout/README.md"
  case "$name" in
    agent-workflows)
      mkdir -p "$checkout/bin"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$checkout/bin/agent-stack"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$checkout/bin/install-agent-workflows"
      chmod +x "$checkout/bin/agent-stack" "$checkout/bin/install-agent-workflows"
      ;;
    agent-coordination)
      mkdir -p "$checkout/bin"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$checkout/bin/agent-coord"
      chmod +x "$checkout/bin/agent-coord"
      ;;
    agent-coordination-dashboard)
      printf '{"name":"agent-coordination-dashboard","version":"0.1.0"}\n' > "$checkout/package.json"
      ;;
  esac
  git -C "$checkout" add .
  git -C "$checkout" commit --quiet -m "doctor fixture $name"
  git -C "$checkout" remote add origin "$origin"
}

setup_doctor_fixture() {
  local root="$1"
  local name
  mkdir -p "$root/src" "$root/compat" "$root/target/bin" "$root/install" "$root/state"
  for name in agent-workflows agent-coordination agent-coordination-dashboard; do
    create_doctor_checkout "$root" "$name"
    ln -s "$root/src/$name" "$root/compat/$name"
  done

  cat > "$root/target/bin/agent-workflows-status" <<'RUBY'
#!/usr/bin/env ruby
require "json"
case ENV.fetch("DOCTOR_WORKFLOW_FIXTURE", "healthy")
when "healthy"
  puts JSON.generate("status" => "UP_TO_DATE", "installed_version" => "0.1.0", "available_version" => "0.1.0", "delivery_mode" => "flat")
  exit 0
when "stale"
  puts JSON.generate("status" => "UPGRADE_AVAILABLE", "installed_version" => "0.0.9", "available_version" => "0.1.0", "delivery_mode" => "flat")
  exit 1
when "nonzero_healthy"
  puts JSON.generate("status" => "UP_TO_DATE", "installed_version" => "0.1.0", "available_version" => "0.1.0", "delivery_mode" => "flat")
  exit 3
when "malformed"
  puts "not json"
  exit 0
when "oversized"
  $stdout.write("x" * (1024 * 1024 + 10))
  exit 0
when "timeout"
  fork do
    File.write(ENV["DOCTOR_CHILD_PID_FILE"], Process.pid.to_s) if ENV["DOCTOR_CHILD_PID_FILE"]
    sleep 30
  end
  sleep 30
when "stderr_oversized"
  warn "e" * (64 * 1024 + 10)
  puts JSON.generate("status" => "UP_TO_DATE")
when "noisy"
  warn "child-stderr-must-not-escape"
  puts JSON.generate("status" => "UP_TO_DATE", "installed_version" => "0.1.0", "available_version" => "0.1.0", "delivery_mode" => "flat")
when "hostile"
  puts JSON.generate(
    "status" => "UPGRADE_AVAILABLE",
    "installed_version" => "\e[31m0.0.9\e[0m\r\nsecret=#{ENV.fetch("SENTINEL_API_TOKEN")}",
    "available_version" => "0.1.0",
    "delivery_mode" => "flat",
    "guidance" => "upgrade\nnow\e[2J #{ENV.fetch("SENTINEL_API_TOKEN")}",
    "future_additive_field" => { "ignored" => true }
  )
  exit 1
end
RUBY
  chmod +x "$root/target/bin/agent-workflows-status"

  cat > "$root/target/bin/agent-workflow-seam-doctor" <<'RUBY'
#!/usr/bin/env ruby
require "json"
puts JSON.generate("status" => "PASS", "issues" => [])
RUBY
  chmod +x "$root/target/bin/agent-workflow-seam-doctor"

  cat > "$root/install/agent-coord" <<'RUBY'
#!/usr/bin/env ruby
require "json"
command = ARGV.shift
case command
when "version"
  puts JSON.generate("version" => "0.1.0", "schema_version" => 1)
when "doctor"
  marker = ENV["DOCTOR_COORD_ARGS_FILE"]
  File.write(marker, ARGV.join("\n")) if marker
  state_root_index = ARGV.index("--state-root")
  payload = {
    "version" => "0.1.0",
    "backend" => "local",
    "state_root" => state_root_index ? ARGV[state_root_index + 1] : nil,
    "deep" => ARGV.include?("--deep"),
    "status" => "ok",
    "future_additive_field" => { "ignored" => true }
  }
  if ARGV.include?("--deep")
    payload["resource_checks"] = { "claims" => "ok", "heartbeats" => "ok", "batches" => "ok", "events" => "ok" }
  end
  if ENV["DOCTOR_COORD_FIXTURE"] == "degraded"
    payload["resource_checks"] = { "claims" => "ok", "archive" => "unsupported" }
    payload["degraded"] = ["archive state not supported by backend"]
  elsif ENV["DOCTOR_COORD_FIXTURE"] == "wrong_type"
    payload["resource_checks"] = "not-a-resource-map"
  end
  puts JSON.generate(payload)
  exit 3 if ENV["DOCTOR_COORD_FIXTURE"] == "nonzero_healthy"
else
  abort "unexpected command"
end
RUBY
  chmod +x "$root/install/agent-coord"
}

start_doctor_http_fixture() {
  local root="$1"
  local mode="${2:-healthy}"
  local port_file="$root/http-port"
  rm -f "$port_file"
  "$RUBY_BIN" -rsocket -rjson -e '
    port_file, mode = ARGV
    server = TCPServer.new("127.0.0.1", 0)
    File.write(port_file, server.addr[1].to_s)
    trap("TERM") { exit! }
    loop do
      socket = server.accept
      request = socket.gets.to_s
      while (line = socket.gets) && line != "\r\n"; end
      path = request.split[1]
      status, body, headers = case mode
      when "redirect"
        [302, "", { "Location" => "http://127.0.0.1:9/remote" }]
      when "oversized"
        [200, "x" * (1024 * 1024 + 10), {}]
      else
        if path == "/api/doctor" && mode == "forbidden-doctor"
          [403, JSON.generate({ "error" => "forbidden" }), {}]
        elsif path == "/api/doctor" && mode == "malformed-doctor"
          [200, "not json", {}]
        elsif path == "/api/doctor" && mode == "empty-doctor"
          [200, JSON.generate({ "perResource" => [] }), {}]
        else
        payload = if path == "/api/health"
          { "ok" => true }
        else
          { "apiUrl" => nil, "tokenEnvVar" => nil, "stateRoot" => "/tmp/state", "perResource" => [
            { "resource" => "claims", "mode" => "api", "status" => "ok", "httpStatus" => 200, "checkedAt" => "2026-07-12T00:00:00Z" },
            { "resource" => "heartbeats", "mode" => "api", "status" => "ok", "httpStatus" => 200, "checkedAt" => "2026-07-12T00:00:00Z" },
            { "resource" => "batches", "mode" => "api", "status" => "ok", "httpStatus" => 200, "checkedAt" => "2026-07-12T00:00:00Z" },
            { "resource" => "events", "mode" => "api", "status" => "ok", "httpStatus" => 200, "checkedAt" => "2026-07-12T00:00:00Z" }
          ], "futureAdditiveField" => { "ignored" => true } }
        end
        if path == "/api/doctor" && mode == "hostile-doctor"
          payload["perResource"][0]["futureSecret"] = "nested-unregistered-secret"
        end
        [200, JSON.generate(payload), {}]
        end
      end
      reason = { 200 => "OK", 302 => "Found", 403 => "Forbidden" }.fetch(status)
      socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n")
      headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
      socket.write("\r\n")
      if mode == "slow-drip"
        body.each_byte do |byte|
          socket.write(byte.chr)
          sleep 1.2
        end
      else
        socket.write(body)
      end
      socket.close
    rescue Errno::EPIPE, Errno::ECONNRESET
      socket.close rescue nil
    end
  ' "$port_file" "$mode" </dev/null >"$root/http-server.log" 2>&1 &
  local pid=$!
  printf 'process:%s\n' "$pid" >> "$tmp_registry"
  local attempts=0
  while [[ ! -f "$port_file" && "$attempts" -lt 100 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  [[ -f "$port_file" ]] || fail "HTTP fixture failed to start: $(<"$root/http-server.log")"
  printf 'http://127.0.0.1:%s\n' "$(<"$port_file")"
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
delivery_mode="${delivery_mode:-flat}"
"$RUBY_BIN" -rjson -e '
  path, delivery_mode = ARGV
  File.write(path, JSON.generate({"delivery_mode" => delivery_mode}) + "\n")
' "$target/.agent-workflows-install.json" "$delivery_mode"
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

test_sync_selects_and_replays_workflow_delivery_mode() {
  local tmp source_root compat_root runtime_root target install_dir mode
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
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
      --agent-coord-install-dir "$install_dir" \
      --delivery-mode plugin-companion

  AGENT_STACK_AGENT_WORKFLOWS_URL="$tmp/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$tmp/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$tmp/origins/agent-coordination-dashboard.git" \
    "$ROOT/bin/agent-stack" sync \
      --source-root "$source_root" \
      --compat-root "$compat_root" \
      --runtime-root "$runtime_root" \
      --target "$target" \
      --agent-coord-install-dir "$install_dir" \
      --no-fetch

  mode="$("$RUBY_BIN" -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("delivery_mode")' "$target/.agent-workflows-install.json")"
  [[ "$mode" = "plugin-companion" ]] || fail "agent-stack changed delivery mode to $mode"
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

test_sync_normalizes_dot_dot_before_compat_root_guard() {
  local tmp source_root compat_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/missing/../src/agent-workflows/compat"
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

  [[ "$status" -ne 0 ]] || fail "expected dot-dot nested compatibility root to fail"
  assert_contains "$output" "Refusing compatibility root inside source checkout"
  [[ ! -e "$source_root/agent-workflows" ]] || fail "dot-dot compatibility root should be rejected before creating the checkout path"
}

test_sync_refuses_source_root_inside_compat_alias_before_creating_it() {
  local tmp source_root compat_root output status
  tmp="$(make_tmp_dir)"
  compat_root="$tmp/compat"
  source_root="$compat_root/agent-workflows"
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
        --replace-compat \
        --no-install 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected source root inside compatibility alias to fail"
  assert_contains "$output" "Refusing source root inside compatibility alias path"
  [[ ! -e "$source_root" ]] || fail "source root inside compatibility alias should be rejected before creating it"
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

test_sync_refuses_runtime_directory_symlink() {
  local tmp source_root compat_root runtime_root cache_target output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/src"
  compat_root="$tmp/compat"
  runtime_root="$tmp/runtime"
  cache_target="$tmp/external-cache"
  mkdir -p "$runtime_root" "$cache_target"
  ln -s "$cache_target" "$runtime_root/cache"
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

  [[ "$status" -ne 0 ]] || fail "expected runtime directory symlink to fail"
  assert_contains "$output" "Refusing to use runtime directory symlink"
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

test_doctor_reports_fixed_model_without_creating_missing_paths() {
  local tmp source_root compat_root target install_dir state_root output status
  tmp="$(make_tmp_dir)"
  source_root="$tmp/missing-source"
  compat_root="$tmp/missing-compat"
  target="$tmp/missing-target"
  install_dir="$tmp/missing-install"
  state_root="$tmp/missing-state"

  set +e
  output="$(
    env -u AGENT_COORD_API_URL -u AGENT_COORD_API_TOKEN -u AGENT_COORD_BACKEND \
      -u AGENT_COORD_STATE_ROOT -u AGENT_COORD_STATUS_STATE_ROOT \
      XDG_STATE_HOME="$tmp/xdg" HOME="$tmp/home" \
      "$ROOT/bin/agent-stack" doctor --json \
        --source-root "$source_root" \
        --compat-root "$compat_root" \
        --host codex \
        --target "$target" \
        --agent-coord-install-dir "$install_dir" \
        --dashboard-url http://127.0.0.1:9
  )"
  status=$?
  set -e

  [[ "$status" -eq 2 ]] || fail "expected failed doctor exit 2, got $status: $output"
  [[ "$(doctor_json_value "$output" status)" = "failed" ]] || fail "expected failed aggregate"
  [[ "$(doctor_json_value "$output" component_ids)" = "agent-workflows,agent-coordination,agent-coordination-dashboard" ]] || fail "expected fixed components"
  [[ "$(doctor_json_value "$output" check_ids)" = "agent-workflows.source,agent-workflows.compatibility,workflows.installation,workflows.seam,agent-coordination.source,agent-coordination.compatibility,coordination.cli,coordination.backend,coordination.resources,agent-coordination-dashboard.source,agent-coordination-dashboard.compatibility,dashboard.package,dashboard.health,dashboard.resources" ]] || fail "expected all 14 stable checks"
  [[ "$(doctor_json_value "$output" skipped_count)" -eq 3 ]] || fail "expected three neutral deep-only skipped checks"
  [[ ! -e "$source_root" && ! -e "$compat_root" && ! -e "$target" && ! -e "$install_dir" && ! -e "$state_root" && ! -e "$tmp/xdg" ]] || fail "doctor created a missing selector or implicit state path"
}

test_doctor_normalizes_exit_zero_coordination_degradation() {
  local tmp dashboard_url args_file output status
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"
  args_file="$tmp/coord-args"

  set +e
  output="$(DOCTOR_COORD_ARGS_FILE="$args_file" DOCTOR_COORD_FIXTURE=degraded doctor_fixture_command "$tmp" "$dashboard_url" --deep --json)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected degraded doctor exit 1, got $status: $output"
  [[ "$(doctor_json_value "$output" status)" = "degraded" ]] || fail "expected degraded aggregate"
  [[ "$(doctor_json_value "$output" coordination_status)" = "degraded" ]] || fail "expected degraded coordination component"
  [[ "$(doctor_json_value "$output" coordination_resources_status)" = "degraded" ]] || fail "expected degraded resource check"
  assert_contains "$(<"$args_file")" "--state-root"
  assert_contains "$(<"$args_file")" "$tmp/state"
}

test_doctor_keeps_malformed_child_output_in_valid_failed_aggregate() {
  local tmp dashboard_url output status
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"

  set +e
  output="$(DOCTOR_WORKFLOW_FIXTURE=malformed doctor_fixture_command "$tmp" "$dashboard_url" --json)"
  status=$?
  set -e

  [[ "$status" -eq 2 ]] || fail "expected malformed child to fail, got $status: $output"
  [[ "$(doctor_json_value "$output" status)" = "failed" ]] || fail "expected valid failed aggregate"
  [[ "$(doctor_json_value "$output" workflow_installation_status)" = "failed" ]] || fail "expected workflow installation failure"
  assert_not_contains "$output" "not json"
}

test_doctor_rejects_mismatched_child_exits_and_coordination_shapes() {
  local tmp dashboard_url output status fixture
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"

  set +e
  output="$(DOCTOR_WORKFLOW_FIXTURE=nonzero_healthy doctor_fixture_command "$tmp" "$dashboard_url" --json)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "unexpected workflow exit should fail, got $status: $output"
  [[ "$(doctor_json_value "$output" workflow_installation_status)" = "failed" ]] || fail "workflow exit mismatch was accepted"

  for fixture in nonzero_healthy wrong_type; do
    set +e
    output="$(DOCTOR_COORD_FIXTURE="$fixture" doctor_fixture_command "$tmp" "$dashboard_url" --deep --json)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]] || fail "$fixture coordination payload should fail, got $status: $output"
    doctor_json_value "$output" schema_version >/dev/null
    [[ "$(doctor_json_value "$output" coordination_backend_status)" = "failed" ]] || fail "$fixture coordination backend was accepted"
  done
}

test_doctor_rejects_unsafe_dashboard_urls_as_usage_errors() {
  local tmp url output status
  tmp="$(make_tmp_dir)"
  for url in "https://127.0.0.1:4319" "http://example.com:4319" "http://user:sentinel-password@127.0.0.1:4319"; do
    set +e
    output="$("$ROOT/bin/agent-stack" doctor --json --source-root "$tmp/source" --dashboard-url "$url" 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq 64 ]] || fail "expected unsafe dashboard URL usage exit for $url, got $status: $output"
    assert_not_contains "$output" "sentinel-password"
  done
  [[ ! -e "$tmp/source" ]] || fail "unsafe URL was not rejected before source probing"
}

doctor_fixture_command() {
  local root="$1"
  local dashboard_url="$2"
  shift 2
  if [[ "${DOCTOR_USE_HTTP_BACKEND:-0}" = 1 ]]; then
    env -u AGENT_COORD_STATE_ROOT \
    AGENT_STACK_AGENT_WORKFLOWS_URL="$root/origins/agent-workflows.git" \
    AGENT_STACK_AGENT_COORDINATION_URL="$root/origins/agent-coordination.git" \
    AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$root/origins/agent-coordination-dashboard.git" \
      "$ROOT/bin/agent-stack" doctor \
        --source-root "$root/src" \
        --compat-root "$root/compat" \
        --target "$root/target" \
        --agent-coord-install-dir "$root/install" \
        --dashboard-url "$dashboard_url" "$@"
    return
  fi
  AGENT_STACK_AGENT_WORKFLOWS_URL="$root/origins/agent-workflows.git" \
  AGENT_STACK_AGENT_COORDINATION_URL="$root/origins/agent-coordination.git" \
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL="$root/origins/agent-coordination-dashboard.git" \
  AGENT_COORD_STATE_ROOT="$root/state" \
    "$ROOT/bin/agent-stack" doctor \
      --source-root "$root/src" \
      --compat-root "$root/compat" \
      --target "$root/target" \
      --agent-coord-install-dir "$root/install" \
      --dashboard-url "$dashboard_url" "$@"
}

test_doctor_renderer_has_informative_hierarchy_and_json_parity() {
  local tmp dashboard_url text json text_status json_status section_count status failed_text failed_json
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"

  set +e
  text="$(doctor_fixture_command "$tmp" "$dashboard_url" --deep)"
  status=$?
  json="$(doctor_fixture_command "$tmp" "$dashboard_url" --deep --json)"
  set -e
  [[ "$status" -eq 0 ]] || fail "healthy deep text fixture exited $status: $text"
  text_status="$(printf '%s\n' "$text" | sed -n '1s/^Agent Stack Doctor: //p' | tr '[:upper:]' '[:lower:]')"
  json_status="$(doctor_json_value "$json" status)"

  [[ "$text_status" = "$json_status" ]] || fail "text/JSON overall status mismatch"
  assert_contains "$text" "Agent Stack Doctor: HEALTHY"
  assert_contains "$text" "3 components: 3 healthy, 0 degraded, 0 failed"
  section_count="$(printf '%s\n' "$text" | grep -Ec '^\[(HEALTHY|DEGRADED|FAILED)\] agent-(workflows|coordination|coordination-dashboard)$')"
  [[ "$section_count" -eq 3 ]] || fail "expected exactly three component sections, got $section_count: $text"
  assert_contains "$text" "Source"
  assert_contains "$text" "Install"
  assert_contains "$text" "CLI"
  assert_contains "$text" "Backend"
  assert_contains "$text" "Service"
  [[ "$(doctor_json_value "$json" component_count)" -eq 3 ]] || fail "expected exactly three JSON components"
  [[ "$(doctor_json_value "$json" stable_check_keys)" = "true" ]] || fail "expected stable normalized JSON check keys"

  rm "$tmp/target/bin/agent-workflows-status"
  set +e
  failed_text="$(doctor_fixture_command "$tmp" "$dashboard_url" --deep)"
  status=$?
  failed_json="$(doctor_fixture_command "$tmp" "$dashboard_url" --deep --json)"
  set -e
  [[ "$status" -eq 2 ]] || fail "failed text fixture exited $status: $failed_text"
  assert_contains "$failed_text" "Agent Stack Doctor: FAILED"
  [[ "$(doctor_json_value "$failed_json" status)" = "failed" ]] || fail "failed text/JSON status mismatch"
}

test_doctor_renderer_orders_problems_first_with_matching_guidance() {
  local tmp dashboard_url text json status expected_guidance
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"
  printf 'dirty\n' >> "$tmp/src/agent-workflows/README.md"

  set +e
  text="$(DOCTOR_WORKFLOW_FIXTURE=stale doctor_fixture_command "$tmp" "$dashboard_url")"
  status=$?
  json="$(DOCTOR_WORKFLOW_FIXTURE=stale doctor_fixture_command "$tmp" "$dashboard_url" --json)"
  set -e
  [[ "$status" -eq 1 ]] || fail "expected degraded text exit 1, got $status"
  assert_contains "$text" "Agent Stack Doctor: DEGRADED"
  assert_line_before "$text" "[DEGRADED] Install" "[HEALTHY] Compatibility link"
  assert_contains "$text" "Next"
  [[ "$(doctor_json_value "$json" status)" = "degraded" ]] || fail "expected degraded JSON parity"
  expected_guidance="$(doctor_json_value "$json" workflow_installation_guidance)"
  assert_contains "$text" "Next       $expected_guidance"
}

test_doctor_default_renderer_preserves_fixed_skips_and_textual_cues() {
  local tmp dashboard_url text json skip_count cue_count
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"

  text="$(NO_COLOR=1 doctor_fixture_command "$tmp" "$dashboard_url")"
  json="$(doctor_fixture_command "$tmp" "$dashboard_url" --json)"
  assert_contains "$text" "[SKIPPED]"
  assert_contains "$text" 'Rerun with `--deep`.'
  skip_count="$(doctor_json_value "$json" skipped_count)"
  cue_count="$(printf '%s\n' "$text" | grep -c '^  \[SKIPPED\]')"
  [[ "$skip_count" -eq 3 && "$cue_count" -eq 3 ]] || fail "expected three stable skip records/cues"
  [[ "$text" != *$'\033'* ]] || fail "NO_COLOR/non-TTY output contained ANSI"
}

test_doctor_json_contains_child_streams_and_accepts_additive_fields() {
  local tmp dashboard_url stdout_file stderr_file status output
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"
  stdout_file="$tmp/stdout"
  stderr_file="$tmp/stderr"

  set +e
  DOCTOR_WORKFLOW_FIXTURE=noisy doctor_fixture_command "$tmp" "$dashboard_url" --json >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "additive/noisy child fixture should remain healthy"
  output="$(<"$stdout_file")"
  doctor_json_value "$output" schema_version >/dev/null
  assert_not_contains "$output" "child-stderr-must-not-escape"
  assert_not_contains "$(<"$stderr_file")" "child-stderr-must-not-escape"
  [[ "$(doctor_json_value "$output" component_count)" -eq 3 ]] || fail "additive child fields changed aggregate shape"
}

test_doctor_bounds_output_and_cleans_timed_out_process_groups() {
  local tmp dashboard_url mode output status child_pid attempts http_tmp oversized_url
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"
  for mode in oversized stderr_oversized; do
    set +e
    output="$(DOCTOR_WORKFLOW_FIXTURE="$mode" doctor_fixture_command "$tmp" "$dashboard_url" --json 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]] || fail "expected $mode child to fail with exit 2, got $status"
    assert_contains "$output" "output exceeded diagnostic size limit"
    [[ "${#output}" -lt 200000 ]] || fail "aggregate exposed oversized child payload"
  done

  http_tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$http_tmp"
  oversized_url="$(start_doctor_http_fixture "$http_tmp" oversized)"
  set +e
  output="$(doctor_fixture_command "$http_tmp" "$oversized_url" --json)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "expected oversized HTTP body to fail"
  assert_contains "$output" "response exceeded diagnostic size limit"

  set +e
  output="$(DOCTOR_WORKFLOW_FIXTURE=timeout DOCTOR_CHILD_PID_FILE="$tmp/child-pid" doctor_fixture_command "$tmp" "$dashboard_url" --json)"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "expected timed-out child to fail"
  assert_contains "$output" "diagnostic timed out"
  [[ -s "$tmp/child-pid" ]] || fail "timeout fixture did not record descendant pid"
  child_pid="$(<"$tmp/child-pid")"
  attempts=0
  while kill -0 "$child_pid" 2>/dev/null && [[ "$attempts" -lt 50 ]]; do sleep 0.02; attempts=$((attempts + 1)); done
  ! kill -0 "$child_pid" 2>/dev/null || fail "timed-out diagnostic descendant survived process-group cleanup"
}

test_doctor_redacts_and_sanitizes_all_rendered_external_strings() {
  local tmp dashboard_url rendering status output
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp")"
  for rendering in text json; do
    set +e
    if [[ "$rendering" = json ]]; then
      output="$(SENTINEL_API_TOKEN='sentinel-secret-value' AGENT_COORD_API_URL='http://user:sentinel-secret-value@127.0.0.1:9/path?token=sentinel-secret-value' DOCTOR_USE_HTTP_BACKEND=1 DOCTOR_WORKFLOW_FIXTURE=hostile doctor_fixture_command "$tmp" "$dashboard_url" --json 2>&1)"
    else
      output="$(SENTINEL_API_TOKEN='sentinel-secret-value' AGENT_COORD_API_URL='http://user:sentinel-secret-value@127.0.0.1:9/path?token=sentinel-secret-value' DOCTOR_USE_HTTP_BACKEND=1 DOCTOR_WORKFLOW_FIXTURE=hostile doctor_fixture_command "$tmp" "$dashboard_url" 2>&1)"
    fi
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "hostile additive fixture should degrade, got $status: $output"
    assert_not_contains "$output" "sentinel-secret-value"
    [[ "$output" != *$'\033'* && "$output" != *$'\r'* ]] || fail "rendered output retained ANSI/control characters"
    assert_contains "$output" "[REDACTED]"
    assert_contains "$output" "\\x0A"
    if [[ "$rendering" = json ]]; then doctor_json_value "$output" status >/dev/null; fi
  done
}

test_doctor_deep_dashboard_failure_keeps_health_and_confidence_separate() {
  local tmp dashboard_url json status
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"
  dashboard_url="$(start_doctor_http_fixture "$tmp" forbidden-doctor)"
  set +e
  json="$(doctor_fixture_command "$tmp" "$dashboard_url" --deep --json)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "forbidden dashboard doctor should degrade, got $status"
  [[ "$(doctor_json_value "$json" dashboard_health_status)" = "healthy" ]] || fail "dashboard health evidence was lost"
  [[ "$(doctor_json_value "$json" dashboard_resources_status)" = "degraded" ]] || fail "dashboard diagnostic confidence was not degraded"
}

test_doctor_normalizes_dashboard_boundaries_and_total_deadline() {
  local tmp dashboard_url json status mode slow_tmp slow_url started elapsed ipv6_output
  tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$tmp"

  printf '{}\n' > "$tmp/target/settings.json"
  set +e
  json="$(doctor_fixture_command "$tmp" "http://127.0.0.1:9" --host auto --json)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "auto host fixture should only degrade for the stopped dashboard, got $status"
  [[ "$(doctor_json_value "$json" workflow_host)" = "claude" ]] || fail "doctor auto host resolution drifted from workflow status semantics"
  rm -f "$tmp/target/settings.json"

  set +e
  json="$(doctor_fixture_command "$tmp" "http://127.0.0.1:9" --json)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "stopped optional dashboard should degrade, got $status: $json"
  [[ "$(doctor_json_value "$json" dashboard_health_status)" = "degraded" ]] || fail "stopped dashboard did not degrade health"

  for mode in empty-doctor malformed-doctor redirect hostile-doctor; do
    dashboard_url="$(start_doctor_http_fixture "$tmp" "$mode")"
    set +e
    json="$(doctor_fixture_command "$tmp" "$dashboard_url" --deep --json)"
    status=$?
    set -e
    doctor_json_value "$json" schema_version >/dev/null
    case "$mode" in
      empty-doctor|malformed-doctor)
        [[ "$status" -eq 1 ]] || fail "$mode should preserve health and degrade deep evidence, got $status"
        [[ "$(doctor_json_value "$json" dashboard_resources_status)" = "degraded" ]] || fail "$mode was rounded up"
        ;;
      redirect)
        [[ "$status" -eq 2 ]] || fail "redirected dashboard probes should fail, got $status"
        ;;
      hostile-doctor)
        [[ "$status" -eq 0 ]] || fail "additive dashboard fields should remain compatible, got $status"
        assert_not_contains "$json" "nested-unregistered-secret"
        assert_not_contains "$json" "futureSecret"
        ;;
    esac
  done

  set +e
  ipv6_output="$(env -u AGENT_COORD_API_URL -u AGENT_COORD_BACKEND -u AGENT_COORD_STATE_ROOT "$ROOT/bin/agent-stack" doctor --json --source-root "$tmp/missing" --compat-root "$tmp/missing-compat" --target "$tmp/missing-target" --agent-coord-install-dir "$tmp/missing-install" --dashboard-url 'http://[::1]:9')"
  status=$?
  set -e
  [[ "$status" -eq 2 ]] || fail "IPv6 loopback URL should be accepted then report component failures, got $status: $ipv6_output"
  doctor_json_value "$ipv6_output" schema_version >/dev/null

  slow_tmp="$(make_tmp_dir)"
  setup_doctor_fixture "$slow_tmp"
  slow_url="$(start_doctor_http_fixture "$slow_tmp" slow-drip)"
  started=$SECONDS
  set +e
  json="$(doctor_fixture_command "$slow_tmp" "$slow_url" --json)"
  status=$?
  set -e
  elapsed=$((SECONDS - started))
  [[ "$status" -eq 1 ]] || fail "slow dashboard should degrade, got $status: $json"
  [[ "$elapsed" -ge 9 && "$elapsed" -le 12 ]] || fail "dashboard deadline should be total and bounded near 10s, took ${elapsed}s"
}

test_help_documents_path_overrides_and_force_stash_behavior() {
  local output
  output="$("$ROOT/bin/agent-stack" --help)"

  assert_contains "$output" "AGENT_STACK_SOURCE_ROOT"
  assert_contains "$output" "AGENT_STACK_COMPAT_ROOT"
  assert_contains "$output" "AGENT_STACK_RUNTIME_ROOT"
  assert_contains "$output" "not restored automatically"
}

run_test() {
  local name="$1"
  if [[ -z "${AGENT_STACK_TEST_FILTER:-}" || "$name" = *"$AGENT_STACK_TEST_FILTER"* ]]; then
    "$name"
  fi
}

run_test test_sync_clones_installs_and_links_the_stack
run_test test_sync_selects_and_replays_workflow_delivery_mode
run_test test_sync_preserves_preexisting_agent_coord_file
run_test test_sync_updates_running_installed_agent_stack_via_temp_file
run_test test_sync_refuses_dirty_repo_without_force_stash
run_test test_sync_refuses_non_main_repo
run_test test_sync_refuses_checkout_without_origin_remote
run_test test_sync_accepts_git_worktree_checkout
run_test test_sync_clones_main_even_when_remote_head_differs
run_test test_sync_rejects_existing_checkout_when_url_override_disagrees
run_test test_sync_refuses_mismatched_compat_symlink_without_replace
run_test test_sync_refuses_overlapping_source_and_compat_roots
run_test test_sync_refuses_compat_root_inside_source_checkout_before_creating_it
run_test test_sync_normalizes_dot_dot_before_compat_root_guard
run_test test_sync_refuses_source_root_inside_compat_alias_before_creating_it
run_test test_sync_links_compat_to_physical_source_root
run_test test_sync_refuses_runtime_env_symlink
run_test test_sync_refuses_runtime_directory_symlink
run_test test_no_install_does_not_create_default_install_dir
run_test test_sync_force_stash_allows_dirty_main_repo
run_test test_doctor_reports_fixed_model_without_creating_missing_paths
run_test test_doctor_normalizes_exit_zero_coordination_degradation
run_test test_doctor_keeps_malformed_child_output_in_valid_failed_aggregate
run_test test_doctor_rejects_mismatched_child_exits_and_coordination_shapes
run_test test_doctor_rejects_unsafe_dashboard_urls_as_usage_errors
run_test test_doctor_renderer_has_informative_hierarchy_and_json_parity
run_test test_doctor_renderer_orders_problems_first_with_matching_guidance
run_test test_doctor_default_renderer_preserves_fixed_skips_and_textual_cues
run_test test_doctor_json_contains_child_streams_and_accepts_additive_fields
run_test test_doctor_bounds_output_and_cleans_timed_out_process_groups
run_test test_doctor_redacts_and_sanitizes_all_rendered_external_strings
run_test test_doctor_deep_dashboard_failure_keeps_health_and_confidence_separate
run_test test_doctor_normalizes_dashboard_boundaries_and_total_deadline
run_test test_help_documents_path_overrides_and_force_stash_behavior

echo "PASS agent-stack tests"
