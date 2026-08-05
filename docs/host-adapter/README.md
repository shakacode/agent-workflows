# Host Adapter Hooks

Optional, opt-in Claude Code hook adapters that turn two advisory rules into
enforced ones. They live under `plugins/claude-hooks/hooks/` and are **off by
default**: installing or enabling this pack does not activate them.

For the portable host model these adapters plug into, see
[Host Adapter Contract](contract.md).

## Why Hooks At All

Every gate this pack ships is advisory. A skill's rules bind only while its text
is in context and only if the agent chooses to follow them. An agent that never
loaded the skill, loaded it 200k tokens ago, or was compacted will run the
dangerous command and nothing stops it.

A hook is the one place a host can make a rule a precondition of the command
rather than a suggestion to the model.

## The Rule Is Not In The Hook

This is the load-bearing constraint. The hook is a delivery adapter, never a
policy source:

- The **rule and its validator stay host-neutral**, in the pack's own
  executables, callable identically from a skill step, a human shell, or a hook.
- The **hook only shells out** to that validator and translates its verdict into
  a host-specific block.
- Delete the hooks and every rule, its tests, and its command-line entry point
  are still here.

`block-merge-without-ci-readiness` shells out to
`skills/pr-batch/bin/pr-ci-readiness`, which already encodes the readiness rule
and has its own unit tests. The adapter adds enforcement, not policy.

## Adapters

| Adapter | Event | What it does | Fails |
| --- | --- | --- | --- |
| `block-merge-without-ci-readiness` | `PreToolUse` (`Bash`) | Refuses `gh pr merge` unless current-head CI readiness is proven | closed |
| `close-lane-on-session-end` | `SessionEnd` | Records that a lane stopped deliberately instead of going quiet | open |

### block-merge-without-ci-readiness

Merging without current-head readiness is the failure with the worst blast
radius, so it is the one gate made binding.

The adapter recognises `gh pr merge` in the proposed Bash command, resolves
which pull request it would merge, runs the readiness validator, and allows the
command only on a parsed `READY` verdict.

Two fail directions, deliberately different:

- **Applicability is fail-open.** An unreadable hook payload, a non-Bash tool,
  or a command with no recognisable `gh pr merge` means the gate has no opinion
  and allows. Blocking on an inconclusive read would make the adapter a global
  breaker for unrelated work.
- **Readiness is fail-closed.** Once a merge is recognised, anything other than
  a parsed `READY` blocks: `NOT_READY`, `UNKNOWN`, a validator that exits
  non-zero, times out, or is missing, and a pull request whose identity cannot
  be resolved. "We could not establish readiness" is precisely the state this
  gate exists to stop, so it is not a reason to let the merge through.

The blocked command's stderr tells the agent which validator to run itself, so
the agent can resolve the blockers rather than guess.

#### It must decide before the host's deadline

The adapter runs up to two subprocesses — resolving which pull request `gh pr
merge` targets, then checking readiness — and they share **one** wall-clock
budget for the whole invocation, not one budget each.

This matters because the hook is registered in `hooks.json` with a `timeout`.
If the stages each took the full per-stage timeout they would stack, and a slow
`gh pr view` followed by a slow readiness check could still be running when the
host's deadline fired. Claude Code does not document what it does with a hook
that exceeds its timeout, and the available indication is that a timed-out hook
is treated as a non-blocking error and the tool call proceeds. A fail-closed
gate cannot rest on that: the gate must reach its own decision first.

So the total budget defaults to 75s against a registered timeout of 90s, and
the per-stage timeout is clamped to the total budget — raising
`AGENT_WORKFLOWS_MERGE_GATE_TIMEOUT_SECONDS` cannot push the invocation past
its deadline. When the budget runs out the gate blocks, because "readiness
could not be established in time" is the state it exists to stop.
`hooks-install-contract-test.rb` asserts the margin, so shrinking it fails the
suite. If you change the `timeout` in `hooks.json`, change the budget with it.

### close-lane-on-session-end

A lane goes quiet for two very different reasons — it finished, or its agent
stopped — and an expired heartbeat looks identical either way. This adapter
records the difference at the only moment it is cheap to observe.

On session end it emits the canonical non-terminal signal `human_intervention`
with `kind: drain`, following the typed-event rules in
[coordination-backend.md](../coordination-backend.md#operational-signal-events)
exactly:

- Backend `n/a`, or no readable seam, skips silently. This source repository
  sets `coordination_backend: "n/a"`, so the adapter no-ops here.
- No advertised transport records `typed event transport: unavailable` and skips.
- A missing, malformed, or unsafe advertisement is an attempted-write failure.
- An advertised write runs the exact executable and ordered opaque argv with no
  shell evaluation, under a finite deadline, in its own process group.
- Any write failure is best-effort `UNKNOWN`. Emission never blocks shutdown.

**It never releases the claim.** `pr-processing.md` forbids `agent-coord
release` for a normal agent-runner restart, and a `SessionEnd` cannot tell a
restart from an abandonment. Releasing here would break a lane that is about to
be resumed; recording a non-terminal event is safe in both cases.

The `resume` reason is excluded by the matcher and re-checked inside the script,
so a hand-edited install cannot drain a session that is merely resuming.

## Enabling Them

The adapters are deliberately **not** registered in `.claude-plugin/plugin.json`.
A `hooks` key there activates automatically for everyone who enables the pack,
which is the opposite of opt-in. Enabling is an explicit operator action.

Add the entries below to your own Claude Code settings (`~/.claude/settings.json`
for every project, or a project's `.claude/settings.json` for one repository),
replacing `AGENT_WORKFLOWS_CHECKOUT` with the absolute path to this pack.
`plugins/claude-hooks/hooks/hooks.json` holds the same registration in
plugin form and is the copy source:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "AGENT_WORKFLOWS_CHECKOUT/plugins/claude-hooks/hooks/block-merge-without-ci-readiness",
            "timeout": 90
          }
        ]
      }
    ],
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

Enable only one adapter by copying only its block. Restart Claude Code, or
re-read settings, for the change to take effect.

## Configuration

| Variable | Applies to | Meaning |
| --- | --- | --- |
| `AGENT_WORKFLOWS_HOOKS` | both | Set to `off` to disable every adapter |
| `AGENT_WORKFLOWS_PR_CI_READINESS` | merge gate | Absolute path to the readiness validator, for unusual installs |
| `AGENT_WORKFLOWS_MERGE_GATE_TIMEOUT_SECONDS` | merge gate | Per-stage subprocess deadline; defaults to 60, clamped to the total budget |
| `AGENT_WORKFLOWS_MERGE_GATE_TOTAL_BUDGET_SECONDS` | merge gate | Wall-clock budget shared by every stage of one invocation; defaults to 75 and must stay below the `timeout` registered in `hooks.json` |
| `AGENT_WORKFLOWS_DRAIN_EVENT_ARGV` | lane closeout | The backend-advertised drain-event executable and argv, as a JSON array of strings |
| `AGENT_WORKFLOWS_DRAIN_EVENT_TIMEOUT_SECONDS` | lane closeout | Emission deadline; defaults to 1, because Claude Code budgets `SessionEnd` tightly |

`AGENT_WORKFLOWS_DRAIN_EVENT_ARGV` is both the transport advertisement and the
session's declaration that it holds a lane claim. Whoever launches a lane knows
that lane's batch, lane, agent, repository, target, and branch context, so that
context is baked into the argv and every argument is passed through unmodified.
With nothing advertised there is no lane to close out. Example:

```bash
export AGENT_WORKFLOWS_DRAIN_EVENT_ARGV='["agent-coord","event","--type","human_intervention","--kind","drain","--batch-id","aw-f"]'
```

Only an operator can reach these variables. A hook process inherits the agent
runner's environment, not the inspected command's inline `VAR=value` prefix, so
a model cannot switch the gate off from inside a tool call. There is
deliberately no in-command override: a bypass the agent can type is not a gate.

## Codex Parity Is A Known Gap

**Stated, not silently tolerated.** Hooks are Claude Code only:

- Claude Code exposes `PreToolUse`, which can block a tool call before it runs.
  Codex has no equivalent pre-tool interception point.
- Codex's `notify` supports only `agent-turn-complete`. There is no session-end
  or pre-tool event to attach either adapter to.

So with these adapters enabled, the same repository is enforced under Claude
Code and advisory-only under Codex. That asymmetry is contained rather than
accepted:

- Both rules are written down host-neutrally and are enforceable by hand on
  either host. The Codex gap is one of automatic enforcement, not of policy.
- The adapters are off by default, so the default posture of the pack is
  identical on both hosts.
- If Codex grows a pre-tool interception point or a session-end notification,
  the same validator and the same emission contract are already here to wire up.

Codex must not become the degraded host. Do not move a rule into a hook, and do
not delete its host-neutral entry point because a hook now calls it.

## Command Matching, And What It Cannot Catch

Before matching, quoted spans and heredoc bodies are stripped so a phrase that
only appears inside a quoted flag, a commit message, or a heredoc is never
mistaken for a real invocation.

Flags are then classified against an **allowlist of flags known to take no
value**, plus the flags known to consume the next token. That direction is
deliberate. A denylist of value-taking flags fails open by construction: any
value-taking flag missing from it lets its value be read as the pull request
selector, so `gh pr merge --match-head-commit <sha> 8` would check readiness for
`<sha>` rather than for PR 8 — and allow the merge if that lookup happened to
come back READY. `gh` can also add a flag tomorrow.

So an unrecognised flag makes the invocation **ambiguous, and ambiguity blocks**
with a message naming the flag. "I am not sure which pull request this targets"
must never resolve to allow. Recognition also over-approximates: the command is
parsed both as though unknown flags take a value and as though they do not, and
a merge matching under *either* reading is treated as a merge, so an unknown
flag cannot hide the subcommand from the gate either.

If `gh` gains a flag and the gate starts blocking, add it to `MERGE_BOOLEAN_FLAGS`
or `MERGE_VALUE_FLAGS` in the adapter. Naming the pull request explicitly as the
first argument also resolves it.

The accepted trade-off, the same one the reference implementation makes, is that
a quoted subcommand token (`gh pr "merge" 7`) stops matching and is allowed.
A missed match is fail-open, which is the correct bias for deciding whether the
gate *applies*, and is not the bias used for deciding whether the merge is safe.
Command matching is a best-effort recogniser, not a sandbox: it raises the cost
of an unverified merge, and does not claim to make one impossible.

## Attribution

The hook-as-precondition pattern, the quoted-and-heredoc stripping step, and the
discipline of failing open when the adapter's own state is inconclusive are
adapted from the MIT-licensed [`intercom/2x-skills`](https://github.com/intercom/2x-skills)
pack (`plugins/pr-tools/hooks/`). The implementation here is a Ruby rewrite with
no code copied and no runtime dependency on that pack.

One deliberate divergence: the reference gates a command on whether a skill was
activated, tracked through marker files, which forces it to re-validate markers
against the transcript because `/rewind` fires no hook. This adapter gates on
the readiness verdict itself, so there is no marker, no `PreCompact` cleanup,
and no rewind-inconclusive state to fail open on. Removing the proxy removes the
whole failure mode.

## Testing

```bash
ruby plugins/claude-hooks/hooks/block-merge-without-ci-readiness-test.rb
ruby plugins/claude-hooks/hooks/close-lane-on-session-end-test.rb
ruby plugins/claude-hooks/hooks/hooks-install-contract-test.rb
```

All three run as part of `bin/validate`. The merge-gate suite proves an actual
block — a stubbed validator reporting `NOT_READY` makes the hook exit `2` — and
covers every fail-closed path, the quoted and heredoc false-positive cases, and
the operator kill switch.
