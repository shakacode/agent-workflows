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

- Backend `n/a`, or no readable seam, skips silently.
- An active backend continues only when it advertises one conditional drain
  operation. If it does not, the adapter records
  `conditional drain transport: unavailable` and skips.
- That single operation atomically verifies the expected holder, generation or instance, and live lease or heartbeat before appending the drain event.
- A missing, malformed, or unsafe conditional advertisement is an
  attempted-write failure. Plain append-only event transport is unsupported.
- An advertised conditional operation runs the exact executable and ordered
  opaque argv with no shell evaluation, under a finite deadline, in its own
  process group.
- Exit 0 means the event was appended. Exit 3 means no current live claim, so
  the adapter skips. Any other failure is best-effort `UNKNOWN`.

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
            "args": ["--project-dir", "${CLAUDE_PROJECT_DIR}"],
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Restart Claude Code, or re-read settings, for the change to take effect.
The explicit `args` array selects the host's exec form, so spaces or shell
metacharacters in either path are not parsed as shell syntax. Claude Code
substitutes its stable session-start project root for `${CLAUDE_PROJECT_DIR}`.

## Configuration

| Variable | Meaning |
| --- | --- |
| `AGENT_WORKFLOWS_HOOKS` | Set to `off` to disable the adapter |
| `AGENT_WORKFLOWS_CONDITIONAL_DRAIN_ARGV` | The backend-advertised conditional drain executable and opaque argv, as a JSON array of strings |
| `AGENT_WORKFLOWS_DRAIN_EVENT_TIMEOUT_SECONDS` | Emission deadline; defaults to 1 and is clamped to 3, below the registered 5s timeout |

`AGENT_WORKFLOWS_CONDITIONAL_DRAIN_ARGV` is a capability advertisement, not a
plain event command. The launcher bakes the expected batch, lane, holder,
generation or instance, repository, target, and branch into its opaque argv.
In one backend transaction, the advertised operation must compare that expected
identity with the current active claim, verify its live lease or heartbeat, and
append `human_intervention` with `kind: drain` only when all checks still match.
A pre-read followed by an append is not equivalent because takeover can occur
between those operations.

The currently available append-only `agent-coord record-event` is unsupported
and must not be advertised in this variable. Until a backend ships and
advertises the conditional capability, the adapter skips without writing. The
adapter also rejects an advertised `agent-coord record-event` command directly.

Illustrative launcher state after a backend provides that capability:

```bash
export AGENT_WORKFLOWS_CONDITIONAL_DRAIN_ARGV='["/absolute/path/to/conditional-drain","--batch-id","aw-f","--lane","implementation","--expected-holder","worker-a","--expected-generation","3","--expected-instance","session-7"]'
```

The hook payload's `cwd` is not trusted for repository selection because it
follows in-session directory changes. The adapter instead validates the
host-substituted `${CLAUDE_PROJECT_DIR}` as a canonical absolute directory and
uses it for both seam lookup and the conditional operation's working directory.
Only an operator can reach the capability variable. The adapter reads a bounded
JSON payload under a short finite read deadline, rejects NUL-containing
executable arguments, invokes no shell, and terminates the entire advertised
process group when the finite deadline expires. Emitter stdout is discarded;
stderr is drained continuously while only its first 4 KiB is retained for a
useful failure detail.

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
