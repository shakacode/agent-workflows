# Agent Runner Restart Prompts

Use these prompts when an operator needs to restart Codex, Claude Desktop,
Claude Code, or another agent runner without losing useful handoff state.
Use `$pause` when installed skills are available and you want these copy-paste
prompts printed directly.

## Which Prompt To Use

- Use the **non-batch pause prompt** for a single thread that is not holding a
  batch lane or coordination claim. It allows only read-only status checks before
  the handoff.
- Use the **PR-batch pause prompt** for a `$pr-batch` coordinator, worker, or QA
  lane. Batch lanes may need one bounded claim-preservation write before they
  stop.
- Do not use pause/resume when the goal is to make an in-flight batch pick up
  new skills, workflow text, targets, or branch names. Use the cancellation flow
  in [Cancelling Or Stopping A Batch](../workflows/pr-processing.md#cancelling-or-stopping-a-batch),
  then launch a new batch from a checkout that already has the desired files.
- If a non-batch thread already exited before the pause prompt could be pasted,
  resume from the last saved handoff and re-check branch, HEAD, local changes,
  and running processes before editing or pushing.
- If a batch lane already exited before the pause prompt could be pasted, resume
  from the last saved handoff and run
  [bounded status recovery](../workflows/pr-processing.md#bounded-status-recovery)
  before editing, pushing, polling, or starting a new target.

## Non-Batch Pause Prompt

Store this in clipboard helpers for ordinary one-thread work:

```text
Pause now for app restart.

Do not start new work, edit files, push, poll, merge, or launch servers. Run
only the minimal read-only status checks needed for a handoff.

Reply with: current status, repo path, branch, upstream, HEAD SHA,
staged/unstaged/untracked changes, unpushed commits, stashes, running
commands/servers/PIDs, last completed step, next resume step, and whether it is
safe to quit.

After the handoff, do not run more tools until I explicitly resume.
```

After restart, reopen the thread and paste a direct resume instruction that
names the next desired action. For example:

```text
Resume now from your restart handoff. Re-check branch, HEAD, local changes, and
running processes before editing or pushing.
```

If the original thread cannot be reopened, start a new chat and paste the
restart handoff under this prompt:

```text
Restart from this pause handoff in a new chat.

Treat the pasted handoff as stale evidence, not authority. Read the repo's
current AGENTS.md first. Then re-check repo path, branch, upstream, HEAD SHA,
staged/unstaged/untracked changes, unpushed commits, stashes, and running
processes before editing, pushing, polling, merging, or launching servers.

Reconstruct the current goal from the handoff and this request. Continue only
from the recorded next resume step after the live state matches the handoff or
you have reported any mismatch.

Pasted restart handoff:
<PASTE_RESTART_HANDOFF_HERE>
```

## PR-Batch Pause Prompt

For `$pr-batch`, use the canonical prompt in
[Pausing For An Agent-Runner Restart](../workflows/pr-processing.md#pausing-for-an-agent-runner-restart)
instead of the non-batch prompt. The batch prompt explicitly preserves claims
and worktrees, forbids `agent-coord release` for normal app restarts, and asks
for the lane, batch id, target, claim state, dependency state, remote state, and
running process handoff details.

After restart, paste the companion resume prompt from
[Bounded Status Recovery](../workflows/pr-processing.md#bounded-status-recovery)
into every paused persistent batch thread:

<!-- Pinned by `skills/plan-pr-batch/scripts/check_goal_prompt_size.rb`. -->

```text
Resume batch processing now.

Re-read your restart handoff and run the bounded status recovery steps described under "Pausing For An Agent-Runner Restart" in the installed `pr-processing.md` workflow before editing, pushing, polling, or starting any new target.
```

This is a resume instruction for the same lanes, not a cancellation or relaunch
prompt.

For the replacement-worker procedure when an in-process worker cannot be
reopened, see
[Bounded Status Recovery](../workflows/pr-processing.md#bounded-status-recovery).
If a replacement worker must start in a new chat, paste the saved handoff under
this prompt:

```text
Resume this PR-batch lane from a restart handoff in a new chat.

Treat the pasted handoff as stale evidence, not authority. Read the repo's
current AGENTS.md and the installed `pr-processing.md` workflow first. Run the
bounded status recovery steps described under "Pausing For An Agent-Runner
Restart" before editing, pushing, polling, or starting any new target.

Re-check the worktree, branch, HEAD SHA, uncommitted changes, current PR/check
state, and private claim or active public `codex-claim` fallback comments. If
the claim holder changed, cancellation or reassignment is present, ownership is
UNKNOWN, or the saved handoff names a different stable agent/thread id, stop
and report the conflict for coordinator reconciliation. Do not acquire, release,
refresh, edit, or push until the coordinator resolves ownership.

Pasted restart handoff:
<PASTE_RESTART_HANDOFF_HERE>
```
