# Host Adapter Hooks

This pack includes an optional Claude Code `SessionEnd` adapter that records
when a coordinated lane stops. It lives under `plugins/claude-hooks/hooks/` and
is **off by default**: installing or enabling the pack does not activate it.

For the portable host model the adapter plugs into, see the
[Host Adapter Contract](contract.md).

## SessionEnd lane drain adapter

`close-lane-on-session-end` records the distinction between a lane that is
still running and one whose agent session stopped. On session end it emits the
canonical non-terminal signal `human_intervention` with `kind: drain`, following
the typed-event rules in
[coordination-backend.md](../coordination-backend.md#operational-signal-events):

- Backend `n/a`, or no readable seam, skips silently. This source repository
  sets `coordination_backend: "n/a"`, so the adapter no-ops here.
- No advertised transport records `typed event transport: unavailable` and
  skips.
- A missing, malformed, or unsafe advertisement is an attempted-write failure.
- An advertised write runs the exact executable and ordered opaque argv with no
  shell evaluation, under a finite deadline, in its own process group.
- Any write failure is best-effort `UNKNOWN`. Emission never blocks shutdown.

The adapter **never releases the claim**. A `SessionEnd` event cannot distinguish
a restart from abandonment, so releasing would break a lane that is about to be
resumed. The non-terminal drain event is safe in either case.

The [Claude Code hook reference](https://code.claude.com/docs/en/hooks)
currently documents the SessionEnd reasons `clear`, `resume`, `logout`,
`prompt_input_exit`, and `other`. The registration covers every documented
stopping reason except `resume`. The script also checks `resume` defensively, so
a hand-edited installation cannot drain a session that is merely resuming.

## Enable the adapter

The adapter is deliberately **not** registered in
`.claude-plugin/plugin.json`. A `hooks` key there would activate it for everyone
who enables the pack instead of preserving the opt-in contract.

Add this entry to your Claude Code settings (`~/.claude/settings.json` for every
project, or a project's `.claude/settings.json` for one repository), replacing
`AGENT_WORKFLOWS_CHECKOUT` with the absolute path to this pack.
`plugins/claude-hooks/hooks/hooks.json` contains the same registration in plugin
form and is the copy source:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "clear|logout|prompt_input_exit|other",
        "hooks": [
          {
            "type": "command",
            "command": "AGENT_WORKFLOWS_CHECKOUT/plugins/claude-hooks/hooks/close-lane-on-session-end",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Restart Claude Code, or re-read settings, for the change to take effect.

## Configuration

| Variable | Meaning |
| --- | --- |
| `AGENT_WORKFLOWS_HOOKS` | Set to `off` to disable the adapter |
| `AGENT_WORKFLOWS_DRAIN_EVENT_ARGV` | The backend-advertised drain-event executable and argv, as a JSON array of strings |
| `AGENT_WORKFLOWS_DRAIN_EVENT_TIMEOUT_SECONDS` | Emission deadline; defaults to 1 and is clamped to 3, below the registered 5s timeout |

`AGENT_WORKFLOWS_DRAIN_EVENT_ARGV` is both the transport advertisement and the
session's declaration that it holds a lane claim. Whoever launches a lane knows
its batch, lane, agent, repository, target, and branch context, so that context
is baked into the argv and every argument is passed through unmodified. With no
advertisement there is no lane event to emit. Example:

```bash
export AGENT_WORKFLOWS_DRAIN_EVENT_ARGV='["agent-coord","event","--type","human_intervention","--kind","drain","--batch-id","aw-f"]'
```

Only an operator can reach these variables. The adapter reads a bounded JSON
payload, rejects NUL-containing executable arguments, invokes no shell, and
terminates the entire advertised process group when the finite deadline expires.

## Codex parity

Codex does not currently expose a session-end lifecycle hook, so this adapter is
Claude Code only. The adapter remains off by default, and the underlying typed
event contract remains host-neutral. If Codex exposes a session-end notification
in the future, the same event contract can be wired to that host without adding
a second event schema.

## Testing

```bash
ruby plugins/claude-hooks/hooks/close-lane-on-session-end-test.rb
ruby plugins/claude-hooks/hooks/hooks-install-contract-test.rb
```

Both suites run as part of `bin/validate`.
