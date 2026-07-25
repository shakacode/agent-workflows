# Agent Runner Restart Prompts

Use these prompts when an operator needs to restart Codex, Claude Desktop,
Claude Code, or another agent runner without losing useful handoff state.
Use the current operation's returned `assets.skills.pause` entry when you want
these copy-paste prompts printed directly.

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
  then start a new provider operation in the replacement invocation and launch
  the new batch only from its newly returned snapshot.
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
commands/servers/PIDs, last completed step, next resume step,
`originating_provider_revision` from the retained operation (when present), and
whether it is safe to quit.

After the handoff, do not run more tools until I explicitly resume.
```

After restart, reopen the thread and paste a direct resume instruction that
names the next desired action. For example:

```text
Resume now from your restart handoff. Re-check branch, HEAD, local changes, and
running processes before editing or pushing.

Read the active-host install metadata and select exactly one branch. If metadata
is unavailable, use the pinned/offline branch. A missing `provider_profile`
means `pinned`; an unknown value stops.

Managed provider branch:
Run the active host home's absolute `bin/agent-workflows-resolve begin` command
exactly once and retain that exact JSON result as `resume_operation`. Do not
begin a second operation. Compare `resume_operation.revision` with the handoff's
`originating_provider_revision` before reading any shared instruction.
On mismatch, stop normal resume and require explicit cancellation/relaunch or
state reconciliation before any work continues. On match, re-read only
`resume_operation.assets.skills.pause` before continuing.

Pinned or offline provider branch:
Do not run the provider resolver. Continue only from the repo's current
AGENTS.md, this already-loaded pause instruction, local policy/command seams,
the verified live state, and the recorded next resume step. If that step needs
another shared instruction or a registered mutation, stop before it and report
the pinned/offline limitation.

After provider branch selection:
Continue only after the applicable branch's checks pass.
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
from the recorded next resume step after the live state matches the handoff.
If live state does not match the handoff, report the mismatch and stop for
operator direction before editing, pushing, polling, merging, or launching
servers.

Read the active-host install metadata and select exactly one branch. If metadata
is unavailable, use the pinned/offline branch. A missing `provider_profile`
means `pinned`; an unknown value stops.

Managed provider branch:
Run the active host home's absolute `bin/agent-workflows-resolve begin` command
exactly once and retain that exact JSON result as `resume_operation`. Do not
begin a second operation. Compare `resume_operation.revision` with the handoff's
`originating_provider_revision` before reading any shared instruction.
On mismatch, stop normal resume and require explicit cancellation/relaunch or
state reconciliation before any work continues. On match, re-read only
`resume_operation.assets.skills.pause` before continuing.

Pinned or offline provider branch:
Do not run the provider resolver. Continue only from the repo's current
AGENTS.md, this already-loaded pause instruction, local policy/command seams,
the verified live state, and the recorded next resume step. If that step needs
another shared instruction or a registered mutation, stop before it and report
the pinned/offline limitation.

After provider branch selection:
Continue only after the applicable branch's checks pass.

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

Read the active-host install metadata and select exactly one branch. If metadata
is unavailable, use the pinned/offline branch. A missing `provider_profile`
means `pinned`; an unknown value stops.

Managed provider branch:
Run the active host home's absolute `bin/agent-workflows-resolve begin` command
exactly once and retain that exact JSON result as `resume_operation`. Do not
begin a second operation. Compare `resume_operation.revision` with the handoff's
`originating_provider_revision` before reading any shared instruction.
On mismatch, stop normal resume and require explicit cancellation/relaunch or
state reconciliation before any work continues. On match, re-read only
`resume_operation.assets.skills.pause` and
`resume_operation.assets.workflow`, then run that workflow's bounded status
recovery steps under "Pausing For An Agent-Runner Restart" before editing,
pushing, polling, or starting a target.

Pinned or offline provider branch:
Do not run the provider resolver. This batch resume requires shared workflow and
claim-recovery instructions, so stop before editing, pushing, polling, changing
a claim, or starting a target. Report the pinned/offline limitation and require
a managed-provider resume or explicit coordinator cancellation.

After provider branch selection:
Continue only after the applicable branch's checks pass.
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
current AGENTS.md first. Read the active-host install metadata and select
exactly one branch. If metadata is unavailable, use the pinned/offline branch.
A missing `provider_profile` means `pinned`; an unknown value stops.

Managed provider branch:
Run the active host home's absolute `bin/agent-workflows-resolve begin` command
exactly once and retain that exact JSON result as `resume_operation`. Do not
begin a second operation. Compare `resume_operation.revision` with the handoff's
`originating_provider_revision` before reading any shared instruction.
On mismatch, stop normal resume and require explicit cancellation/relaunch or
state reconciliation before any work continues. On match, re-read only
`resume_operation.assets.skills.pause` and
`resume_operation.assets.workflow`, then run that workflow's bounded status
recovery steps under "Pausing For An Agent-Runner Restart" before editing,
pushing, polling, or starting a target.

Pinned or offline provider branch:
Do not run the provider resolver. This batch replacement requires shared
workflow and claim-recovery instructions, so stop before editing, pushing,
polling, changing a claim, or starting a target. Report the pinned/offline
limitation and require a managed-provider replacement or explicit coordinator
cancellation.

After provider branch selection:
Continue only after the applicable branch's checks pass.

Re-check the worktree, branch, HEAD SHA, uncommitted changes, current PR/check
state, and private claim or active public `codex-claim` fallback comments. If
the claim holder changed, cancellation or reassignment is present, ownership is
UNKNOWN, or the saved handoff names a different stable agent/thread id, stop
and report the conflict for coordinator reconciliation. Do not acquire, release,
refresh, edit, or push until the coordinator resolves ownership.

Pasted restart handoff:
<PASTE_RESTART_HANDOFF_HERE>
```
