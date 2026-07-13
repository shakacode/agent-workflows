agent_stack_parse_options() {
  source_root="${AGENT_STACK_SOURCE_ROOT:-$HOME/src}"
  compat_root="${AGENT_STACK_COMPAT_ROOT:-$HOME/codex/agent-repos}"
  runtime_root="${AGENT_STACK_RUNTIME_ROOT:-$HOME/.agent-workflows}"
  host="codex"
  target=""
  mode="copy"
  delivery_mode=""
  agent_coord_install_dir="$HOME/.local/bin"
  force_stash=false
  replace_compat=false
  fetch=true
  install_tools=true
  repo_names=(agent-workflows agent-coordination agent-coordination-dashboard)

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-root) source_root="${2:?--source-root requires a directory}"; shift 2 ;;
      --compat-root) compat_root="${2:?--compat-root requires a directory}"; shift 2 ;;
      --runtime-root) runtime_root="${2:?--runtime-root requires a directory}"; shift 2 ;;
      --host) host="${2:?--host requires codex, claude, or auto}"; shift 2 ;;
      --target) target="${2:?--target requires a directory}"; shift 2 ;;
      --mode) mode="${2:?--mode requires copy or symlink}"; shift 2 ;;
      --delivery-mode) delivery_mode="${2:?--delivery-mode requires flat or plugin-companion}"; shift 2 ;;
      --agent-coord-install-dir) agent_coord_install_dir="${2:?--agent-coord-install-dir requires a directory}"; shift 2 ;;
      --force-stash) force_stash=true; shift ;;
      --replace-compat) replace_compat=true; shift ;;
      --no-fetch) fetch=false; shift ;;
      --no-install) install_tools=false; shift ;;
      -h|--help) agent_stack_usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; agent_stack_usage >&2; exit 64 ;;
    esac
  done

  case "$host" in codex|claude|auto) ;; *) echo "--host must be codex, claude, or auto, got: $host" >&2; exit 64 ;; esac
  case "$mode" in copy|symlink) ;; *) echo "--mode must be copy or symlink, got: $mode" >&2; exit 64 ;; esac
  case "$delivery_mode" in ""|flat|plugin-companion) ;; *) echo "--delivery-mode must be flat or plugin-companion, got: $delivery_mode" >&2; exit 64 ;; esac
}
