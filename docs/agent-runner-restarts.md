# Agent Runner Restart Prompts

Use these prompts when an operator needs to restart Codex, Claude Desktop,
Claude Code, or another agent runner without losing useful handoff state.

## Which Prompt To Use

- Use the **non-batch pause prompt** for a single thread that is not holding a
  batch lane or coordination claim. It allows only read-only status checks before
  the handoff.
- Use the **PR-batch pause prompt** for a `$pr-batch` coordinator, worker, or QA
  lane. Batch lanes may need one bounded claim-preservation write before they
  stop.
- Do not use pause/resume when the goal is to make an in-flight batch pick up
  new skills, workflow text, targets, or branch names. Use the cancellation flow
  in [workflows/pr-processing.md](../workflows/pr-processing.md#cancelling-or-stopping-a-batch),
  then launch a new batch from a checkout that already has the desired files.
- If a thread already exited before the pause prompt could be pasted, treat it
  as a dead-thread case. Resume from the last saved handoff and run bounded
  status recovery before editing, pushing, polling, or starting a new target.

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

## PR-Batch Pause Prompt

For `$pr-batch`, use the canonical prompt in
[Pausing For An Agent-Runner Restart](../workflows/pr-processing.md#pausing-for-an-agent-runner-restart)
instead of the non-batch prompt. The batch prompt explicitly preserves claims
and worktrees, forbids `agent-coord release` for normal app restarts, and asks
for the lane, batch id, target, claim state, dependency state, remote state, and
running process handoff details.

After restart, paste the companion resume prompt from
[Bounded Status Recovery](../workflows/pr-processing.md#bounded-status-recovery)
into every paused persistent batch thread. Copy the exact prompt text from that
section to keep a single authoritative source.

For an in-process worker or subagent that cannot be reopened after its host
process exits, the coordinator starts a replacement worker from the saved
handoff instead of assuming the old worker can resume.
