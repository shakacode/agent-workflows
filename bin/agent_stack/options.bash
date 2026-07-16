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
      --source-root) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--source-root requires a directory" >&2; exit 64; }; source_root="$2"; shift 2 ;;
      --compat-root) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--compat-root requires a directory" >&2; exit 64; }; compat_root="$2"; shift 2 ;;
      --runtime-root) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--runtime-root requires a directory" >&2; exit 64; }; runtime_root="$2"; shift 2 ;;
      --host) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--host requires codex, claude, or auto" >&2; exit 64; }; host="$2"; shift 2 ;;
      --target) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--target requires a directory" >&2; exit 64; }; target="$2"; shift 2 ;;
      --mode) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--mode requires copy or symlink" >&2; exit 64; }; mode="$2"; shift 2 ;;
      --delivery-mode) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--delivery-mode requires flat or plugin-companion" >&2; exit 64; }; delivery_mode="$2"; shift 2 ;;
      --agent-coord-install-dir) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "--agent-coord-install-dir requires a directory" >&2; exit 64; }; agent_coord_install_dir="$2"; shift 2 ;;
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
