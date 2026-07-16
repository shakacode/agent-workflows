agent_stack_repo_url() {
  case "$1" in
    agent-workflows) printf '%s\n' "${AGENT_STACK_AGENT_WORKFLOWS_URL:-https://github.com/shakacode/agent-workflows.git}" ;;
    agent-coordination) printf '%s\n' "${AGENT_STACK_AGENT_COORDINATION_URL:-https://github.com/shakacode/agent-coordination.git}" ;;
    agent-coordination-dashboard) printf '%s\n' "${AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL:-https://github.com/shakacode/agent-coordination-dashboard.git}" ;;
    *) return 1 ;;
  esac
}

agent_stack_repo_url_overridden() {
  case "$1" in
    agent-workflows) [[ -n "${AGENT_STACK_AGENT_WORKFLOWS_URL:-}" ]] ;;
    agent-coordination) [[ -n "${AGENT_STACK_AGENT_COORDINATION_URL:-}" ]] ;;
    agent-coordination-dashboard) [[ -n "${AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL:-}" ]] ;;
    *) return 1 ;;
  esac
}

agent_stack_origin_allowed() {
  local name="$1"
  local origin="$2"
  local configured
  configured="$(agent_stack_repo_url "$name")"
  [[ "$origin" != "$configured" ]] || return 0
  agent_stack_repo_url_overridden "$name" && return 1
  case "$name:$origin" in
    agent-workflows:https://github.com/shakacode/agent-workflows|agent-workflows:https://github.com/shakacode/agent-workflows.git|agent-workflows:git@github.com:shakacode/agent-workflows.git|agent-coordination:https://github.com/shakacode/agent-coordination|agent-coordination:https://github.com/shakacode/agent-coordination.git|agent-coordination:git@github.com:shakacode/agent-coordination.git|agent-coordination-dashboard:https://github.com/shakacode/agent-coordination-dashboard|agent-coordination-dashboard:https://github.com/shakacode/agent-coordination-dashboard.git|agent-coordination-dashboard:git@github.com:shakacode/agent-coordination-dashboard.git) return 0 ;;
    *) return 1 ;;
  esac
}

agent_stack_sync_repo() {
  local name="$1"
  local checkout="$source_root/$name"
  local url origin branch dirty stash_message
  url="$(agent_stack_repo_url "$name")"
  mkdir -p "$source_root"
  if [[ ! -e "$checkout" ]]; then
    echo "clone $name -> $checkout"
    git clone --branch main "$url" "$checkout"
  elif ! git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Refusing to use non-git path for $name: $checkout" >&2; exit 1
  fi
  if ! origin="$(git -C "$checkout" remote get-url origin 2>/dev/null)"; then
    echo "Refusing to sync $name: missing origin remote at $checkout" >&2; exit 1
  fi
  if ! agent_stack_origin_allowed "$name" "$origin"; then
    echo "Refusing $name origin mismatch at $checkout: $origin" >&2; exit 1
  fi
  branch="$(git -C "$checkout" branch --show-current)"
  if [[ "$branch" != main ]]; then
    echo "Refusing to sync $name: not on main at $checkout (current: ${branch:-detached})" >&2; exit 1
  fi
  dirty="$(git -C "$checkout" status --porcelain)"
  if [[ -n "$dirty" ]]; then
    if [[ "$force_stash" = true ]]; then
      stash_message="agent-stack-sync-$(agent_stack_timestamp)"
      git -C "$checkout" stash push -u -m "$stash_message" >/dev/null
      echo "stashed $name dirty worktree: $stash_message"
    else
      echo "Refusing to sync $name: dirty worktree at $checkout (use --force-stash to stash first)" >&2; exit 1
    fi
  fi
  [[ "$fetch" != true ]] || git -C "$checkout" pull --ff-only --prune origin main
  printf '%-36s %s %s\n' "$name" "$(git -C "$checkout" rev-parse --short HEAD)" "$checkout"
}
