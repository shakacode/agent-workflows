agent_stack_usage() {
  cat <<'USAGE'
Usage: agent-stack <sync|doctor> [options]

Keeps the ShakaCode agent stack in a hacker-friendly local layout.
This is ShakaCode stack tooling, not the generic workflow-pack installer.

Default source checkouts:
  ~/src/agent-workflows
  ~/src/agent-coordination
  ~/src/agent-coordination-dashboard

Default compatibility aliases:
  ~/codex/agent-repos/<repo> -> ~/src/<repo>

Options:
  --source-root DIR              source checkout root (default: ~/src)
  --compat-root DIR              compatibility symlink root (default: ~/codex/agent-repos)
  --runtime-root DIR             private runtime/config root (default: ~/.agent-workflows)
  --host codex|claude|auto       workflow install host (default: codex)
  --target DIR                   workflow install target
  --mode copy|symlink            workflow install mode (default: copy)
  --delivery-mode MODE           flat or plugin-companion (replays install metadata when omitted)
  --agent-coord-install-dir DIR  agent-coord install dir (default: ~/.local/bin)
  --force-stash                  stash dirty main checkouts before syncing; not restored automatically
  --replace-compat               archive existing compatibility paths before symlinking
  --no-fetch                     skip fetch/pull for existing checkouts
  --no-install                   clone/update/link only; skip tool installs
  -h, --help                     show help

Doctor-only options:
  --dashboard-url URL            loopback dashboard URL (default: http://127.0.0.1:${PORT:-4319})
  --deep                         run component deep checks
  --json                         emit the versioned aggregate JSON document

Environment path overrides:
  AGENT_STACK_SOURCE_ROOT
  AGENT_STACK_COMPAT_ROOT
  AGENT_STACK_RUNTIME_ROOT

Environment URL overrides:
  AGENT_STACK_AGENT_WORKFLOWS_URL
  AGENT_STACK_AGENT_COORDINATION_URL
  AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL
USAGE
}
