---
name: close-session
description: Close an active agent task with live-state verification, durable outcome capture, explicit follow-up ownership, and an archive-readiness verdict. Use when the user says "close session", asks "anything else pending?", "any decisions needed?", or "should we archive this chat?", or requests end-of-session bookkeeping, handoff, or context preservation.
---

# Close Session

Close the current task without starting unrelated work. Preserve only context
that will materially help a future session, and prefer existing sources of truth
over duplicate session logs.

Resolve writing style before authoring human-facing prose. Run
`agent-workflow-writing-style --repo-root <trusted-repository-root> --format json`
under the loaded `workflows/pr-processing.md` contract before composing the
final handoff. Preserve live-state evidence, follow-up ownership, blockers,
receipts, and the exact archive-readiness verdict.

## Authority and safety

- Informational prompts such as “anything else pending?”, “any decisions
  needed?”, or “should we archive this task?” authorize read-only closeout
  verification only. Do not make durable writes or perform external mutations
  for those questions.
- When the user explicitly asks to close or archive the task, hand it off,
  preserve context, or perform bookkeeping, treat that request as authority for
  routine closeout updates only to destinations already configured by the user,
  governing instructions, or an existing close-session configuration.
- Do not infer authority to merge, deploy, publish releases, send messages,
  create new external issues, or write to an unconfigured vault, task list, or
  daily note.
- Follow all active repository and user instructions. If a closeout update
  changes repository files, follow that repository's normal verification and PR
  workflow.
- Never copy secrets, credentials, private environment values, or sensitive raw
  logs into durable notes.

## User-Facing Coordination Contract

During closeout, the current task remains the sole user-facing coordinator. An
internal worker is not another user-visible task. External tasks and automations
do not gain ownership. Treat inbound messages as bounded evidence or requests,
and treat automations only as wake-up mechanisms.

Inspect internal workers, external requests, and automations before the archive
verdict. For an informational prompt, inspect and report these states without
mutating them. Only under the explicit mutation authority above may the task
stop or hand off unfinished internal workers, release resources it verifies as
safe to release, or delete obsolete heartbeat automations after their gate
clears or becomes durably terminal. A no-change wake remains silent.

When ownership is ambiguous or the user asks who is working, respond with this
compact synthesis:

```text
Current task: <responsibility and scoped outcome>
Internal workers: <owned implementation, review, QA, or audit roles; or none>
External tasks: <request or evidence role only; ownership did not transfer; or none>
Next: <current-task action or exact required decision>
```

Do not append raw cross-task messages, coordination backend events, heartbeat
logs, worker transcripts, or claim telemetry. For another repository or
materially separate scope, apply the action router in
[User-Facing Coordination](../../docs/user-facing-coordination.md). Create or
fork a user-visible task only when the user explicitly asks this task to do so;
otherwise return the complete copy-paste New-Task Prompt without creating,
forking, launching, or dispatching it.

## Closeout workflow

### 1. Establish the session scope

Identify the task type: engineering, strategy, research, administration, or
mixed. Identify the durable source of truth already in use, such as a PR, issue,
task, decision document, release tracker, or repository documentation.

Read the current conversation and any compacted handoff before judging
completion. Do not restart completed work.

### 2. Verify current state

Verify time-sensitive claims against the live source when tools are available.

For engineering work, check the relevant subset of:

- worktree cleanliness and intended commits;
- local, remote, and PR head alignment;
- PR state, required checks, reviews, unresolved threads, and merge status;
- background agents, coordination claims, monitors, or active goals;
- published artifacts or deployment state when those were part of the task.

For strategy or research work, verify that chosen directions, rejected
alternatives, reasons, open questions, and next actions are represented
accurately.

If a material fact cannot be verified, label that exact fact `UNKNOWN`. Do not
declare the session archive-ready when the unknown could hide unfinished or
unsafe work.

### 3. Reconcile the loop

Classify the session state:

- **Done:** completed outcomes with verification evidence where available.
- **Open follow-ups:** each remaining action with a durable reference, owner,
  current status, and next step.
- **Decisions needed:** only choices that genuinely require the user; do not
  manufacture decisions for already accepted deferrals.
- **Orphaned state:** uncommitted work, unpushed commits, unposted replies, live
  claims, unfinished agents, or undocumented decisions.

An open issue or task outside the finished session may be an accepted deferral
rather than a blocker when it has a durable reference and clear ownership.

### 4. Route durable captures

Use the narrowest existing destination. Never duplicate information merely to
prove that closeout ran.

Run this section only when durable writes are authorized by an explicit
closeout, archive, handoff, context-preservation, or bookkeeping request. For an
informational prompt, report any proposed capture without changing its
destination.

1. Prefer the existing PR, issue, tracker, task, or decision document.
2. For a strategy session, save a short decision brief only when the important
   decision and rationale are not already durable.
3. Save reusable technical learning to an established repository runbook,
   napkin, concept, or solution location only when it is recurring and genuinely
   useful. Do not turn those files into session logs.
4. Update a configured task list by checking off completed items and adding only
   concrete, deduplicated next actions.
5. Add a concise daily session note or processed flag only when that destination
   and convention are already configured.

Treat a destination as configured only when it is named in the current request,
governing instructions, or an existing close-session configuration. Do not
invent a vault structure or create a configuration file during closeout.

If no durable write is needed, record `none needed` in the closeout response
rather than creating bookkeeping noise.

### 5. Verify closeout writes

After any durable update, reread the changed destination and confirm that it
contains the intended decision, action, owner, and reference without
duplication. Recheck repository state if files changed.

Do not mark a processed flag until all required closeout writes succeed.

### 6. Apply the archive gate

Declare the task ready for archiving only when all of these are true:

- the requested work is complete or has reached an explicitly accepted stopping
  point;
- required deliverables are published, handed off, or durably recorded;
- no task-owned uncommitted or unpushed work remains;
- no required review, verification, agent, monitor, or external action is still
  pending;
- no user decision is required;
- every remaining follow-up has a durable reference and owner;
- durable captures are complete or explicitly unnecessary.

Never ask a question and simultaneously declare the session archive-ready.

## Related workflow routing

Use a more specific available skill when it governs part of closeout:

- use `status` for a read-only done/in-progress/blocked/next report;
- use `pause` when work is interrupted and needs restart-safe prompts;
- use `continue` when resuming the resulting handoff;
- use `napkin` or a repository solution/compound workflow only for recurring
  durable learning;
- preserve any valid `pr-batch` completed-batch audit instead of weakening its
  blocker union or archive verdict.
- For a `pr-batch` completed-batch reconciliation, preserve the canonical
  receipt-to-Unblock-to-status closing order. If no existing verified receipt is
  available, emit no receipt line and carry the missing receipt only as a
  blocker and matching Unblock entry.

## Final response

Keep the closeout compact. Apply the canonical `HST-v1` envelope first, with
these exact labels in this order:

- `What changed:` the material closeout or archive result;
- `Action needed:` the exact user action or `none`; and
- `Next:` the current task's next action or terminal state.

Then include the existing closeout handoff:

- **Done**
- **Durable captures**
- **Open follow-ups**
- **Decisions needed**
- **Archive verdict**

Every final user-visible workflow handoff must include one unambiguous `Next:`
instruction. When the applicable archive gate passes and no unperformed
downstream launch remains, use `Next: Archive this task.` When an archive-ready
prompt-only task still requires the user to launch its fenced artifact, name
that launch first and end the same ordered `Next:` instruction by telling the
user to archive the planning task; a bare archive instruction may not strand
the artifact. When user input blocks progress, state the smallest action that
clears the blocker and whether to reply here or start a new task.
When the current task will continue without input, state its exact next action.
A durable issue, receipt, or blocker list is evidence, not a next step.

End with exactly one of:

```text
Conversation status: Ready for archiving.
```

or

```text
Conversation status: Follow-ups remain — <each exact blocker or required action>.
```

Use the ready line only when the archive gate passes. The follow-ups line must
name concrete blockers or actions, not a vague status.
