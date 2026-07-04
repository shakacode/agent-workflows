---
name: pause
description: Print restart-safe copy-paste prompts for pausing an agent thread before restarting Codex, Claude, or another runner and for resuming in the same thread or a new chat from the handoff. Use when the user asks for a pause prompt, restart prompt, resume-after-restart prompt, new-chat restart prompt, or operator handoff prompts for non-batch or PR-batch agent work.
---

# Pause

Print operator prompts for safe agent-runner restarts.

## Output Rules

- If the user asks to "print", "show", "give me", or "copy/paste" prompts, do
  not inspect the repo or pause current work. Output the relevant fenced prompt
  blocks.
- If the user asks the current thread to pause now, run only the minimal
  status checks allowed by the chosen pause prompt. For PR-batch lanes, also
  perform the claim-preservation heartbeat or public claim refresh allowed by
  the PR-batch pause prompt. Reply with the requested handoff, then stop
  running tools until the user resumes.
- Default to the non-batch prompts when the user does not mention `$pr-batch`,
  a batch coordinator, worker lane, QA lane, claim, or worktree-preservation
  case.
- Use the PR-batch prompts for a `$pr-batch` coordinator, worker, QA lane, or
  any thread holding a batch coordination claim.
- Include the new-chat restart prompt when the user asks how to restart,
  resume after an app restart, move to a new chat, or preserve copy/paste
  handoff state.

## Non-Batch Pause Prompt

Print this for ordinary one-thread work that is not holding a batch claim:

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

## Non-Batch Same-Thread Resume Prompt

Print this when the paused thread can be reopened:

```text
Resume now from your restart handoff. Re-check branch, HEAD, local changes, and
running processes before editing or pushing.
```

## Non-Batch New-Chat Restart Prompt

Print this when the operator needs to paste the handoff into a new chat:

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

Pasted restart handoff:
<PASTE_RESTART_HANDOFF_HERE>
```

## PR-Batch Pause Prompt

Print this for `$pr-batch` coordinators, workers, and QA lanes:

```text
Pause for agent-runner restart now.

Do not start new targets, spawn workers, create branches or worktrees, push,
request CI, poll reviews, merge, or change repository files. Limit work to the
minimal status checks and claim-preservation write needed for the handoff.
If this lane already owns a private backend claim, send one heartbeat update,
using a paused or operator-restart reason if the backend supports it; otherwise
send a plain heartbeat preserving the current status. If it is using only the
public `codex-claim` fallback, refresh the existing claim comment with
`expires_at` extended by the same lease window already used for that fallback
claim, capped at the repo's configured public fallback lease maximum or 4 hours
from now when no repo-specific cap is configured, leaving `status: in_progress`
so the fallback remains an active advisory lock.
If your repo configures a shorter public fallback lease maximum, use that cap
instead of the 4-hour default.
If the heartbeat or public fallback refresh fails with a transient error, treat
claim state as UNKNOWN in the handoff; do not report the claim as preserved.
If this lane holds no claim of any kind, skip the claim-preservation write and
proceed directly to the handoff reply; do not acquire a new claim during this
pause.
If claim state cannot be checked or refreshed, report it as UNKNOWN in the
handoff. If the failure is a setup or auth error rather than a transient timeout,
also stop after sending the handoff. Do not release the claim unilaterally in
either case.

Preserve any current claim and worktree unless I explicitly say this batch or
lane is cancelled. Do not run `agent-coord release` for a normal app restart.
If this batch or lane is explicitly cancelled, follow the Cancelling Or Stopping
A Batch protocol in the installed `pr-processing.md` workflow instead of this
pause flow.

Reply with a restart handoff:
- Role and lane: coordinator, worker, or QA; batch id; target(s); stable
  agent/thread id.
- Repo state: repo path, worktree path, branch, upstream, HEAD SHA, PR/issue
  URLs.
- Local changes: staged, unstaged, and untracked files; unpushed commits;
  stashes.
- Coordination: claim holder, last heartbeat/status, `blocked_on`/`depends_on`,
  cancellation state, and any UNKNOWN facts.
- Work state: last completed step, current safe checkpoint, in-flight operation,
  and next resume step.
- Remote state: pushed branches/PRs, last-known CI/review state, and hosted
  polling still needed.
- Running processes: commands, servers, PIDs, watchers, or pollers, and whether
  they were stopped or must be restarted after the agent-runner relaunch.
- Safety: whether it is safe to quit the agent runner now, and any cleanup
  needed before resuming or relaunching.

After the claim-preservation step above (or immediately, if this lane held no
claim), send this handoff reply and then do not run more tools or continue work
until I explicitly resume with "Resume batch processing now."
```

## PR-Batch Same-Thread Resume Prompt

Print this when the same paused persistent batch thread can be reopened:

```text
Resume batch processing now.

Re-read your restart handoff and run the bounded status recovery steps described under "Pausing For An Agent-Runner Restart" in the installed `pr-processing.md` workflow before editing, pushing, polling, or starting any new target.
```

## PR-Batch New-Chat Restart Prompt

Print this when a batch lane cannot be reopened and a replacement chat must
resume from the saved handoff:

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
