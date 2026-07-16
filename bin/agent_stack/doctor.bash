agent_stack_doctor_required_modules=(
  stack_cli contract orchestrator process_runner renderer sanitizer timeout_budget configuration source_checks
)

agent_stack_run_doctor() {
  local bin_dir="$1"
  local ruby_bin doctor_helper doctor_helper_real doctor_module_root doctor_module_name doctor_module
  shift 2
  ruby_bin="${RUBY_BIN:-ruby}"
  doctor_helper="${AGENT_STACK_DOCTOR_BIN:-$bin_dir/agent-stack-doctor}"
  command -v "$ruby_bin" >/dev/null 2>&1 || { echo "agent-stack doctor requires Ruby" >&2; exit 64; }
  [[ -f "$doctor_helper" && -r "$doctor_helper" ]] || { echo "agent-stack doctor helper missing: $doctor_helper" >&2; exit 64; }
  doctor_helper_real="$("$ruby_bin" -e 'puts File.realpath(ARGV.fetch(0))' "$doctor_helper" 2>/dev/null)" || {
    echo "agent-stack doctor helper cannot be resolved: $doctor_helper" >&2
    exit 64
  }
  doctor_module_root="$(dirname "$doctor_helper_real")/agent_doctor"
  for doctor_module_name in "${agent_stack_doctor_required_modules[@]}"; do
    doctor_module="$doctor_module_root/$doctor_module_name.rb"
    [[ -f "$doctor_module" && -r "$doctor_module" ]] || {
      echo "agent-stack doctor module missing or unreadable: $doctor_module" >&2
      exit 64
    }
  done
  exec "$ruby_bin" "$doctor_helper_real" "$@"
}
