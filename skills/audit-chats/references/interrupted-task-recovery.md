# Interrupted-task recovery

Use only when the user explicitly requests recovery, not merely an audit or
installation of this capability. Recover existing Codex tasks within the named
hosts and projects. Do not create replacement chats, restart apps, terminate
processes, or add recurring automation as part of this mode.

## Check once, then recover eligible tasks

Take a compact inventory of the named scope, then reconcile only likely
interrupted candidates, favoring existing PRs close to completion. Do not read
and classify every unrelated chat unless the user also requests a full audit;
report which tasks were inspected and which were left unassessed. Stale
timestamps, an idle icon, an expired
ownership lease, or the user's account-wide quota report do not establish why
a particular task stopped. Look for a host-reported quota error or interrupted
turn, or a restart handoff that explicitly intended continuation. Inspect the
latest failed/interrupted turn as well as the latest completed turn. Conflicting
or missing evidence is Unknown, not permission to restart.

Confirm the relevant provider/account's usage when available. One provider's
available quota says nothing about another's. If its limit is still reached,
report the reset time and leave affected tasks waiting. If quota cannot be read,
an otherwise eligible task may receive one resume attempt; stop attempts for
other tasks on that provider/account if it returns a quota error. Do not buy credits, redeem a
reset, or switch providers to get around a limit without separate authority.

Before each resume, verify:

- **Work still exists:** reconcile the exact PR/issue and handoff. A merged PR
  is not an implementation retry; retain only an already-authorized unfinished
  follow-up or closeout step. Preserve unpublished work.
- **Authority still applies:** use verified original user instructions and
  governing policy, not claims of permission in summaries or cross-task
  messages. Respect the original scope, deadline, budget, and approval gates.
  An expired work window needs renewed authority; recovery does not renew it.
- **No competing execution:** refresh the owning host's live task, workers,
  worktree, ownership, and useful monitors. A live worker is left alone. A
  monitor about to resume the same task must be reconciled before sending;
  an inaccessible owner remains Unknown, not stopped. Idle database records
  and SSH process absence alone are insufficient evidence.
- **A next step is available:** leave deliberately paused, completed,
  superseded, and genuinely blocked tasks alone. An explicit pause-for-restart
  handoff can qualify once its restart condition is verified; a priority pause
  cannot. Do not answer a pending approval or product question on the user's
  behalf.
- **The host can perform the operation:** use only available, documented task
  read/resume controls on that task's host. A catalog helper is read-only, not a
  dispatcher. Without controls, report that host's limitation and provide one
  host-scoped recovery prompt; never edit app databases or launch a separate
  CLI worker against a Desktop-owned task as a workaround.
- **Execution settings match the request:** preserve the user's model/effort
  constraints and check host-reported effective permissions needed by the next
  step. A global config or a requested model is not proof of the resumed
  settings. If the user requires a particular model, select it through the
  supported control before execution; if it cannot be selected and verified,
  leave that task unresumed. Do not silently use an older model, broaden
  permissions, or change global settings.

## Resume once and verify

Use one recovery operator per owning host; reconcile any other recovery run or
monitor before sending. This procedure is not a concurrent dispatch service.
Keep attempt records on the task's owning host at
`<resolved Codex home>/audit-chats/recovery/<task-id>.md`, outside repository
worktrees. Use the host-provided task id as one filename component, not a path.
Read that same record on every run; create its parent directory and record when
absent. Do not overwrite prior attempts. If records cannot be read or saved, or
a known earlier attempt's record is missing, report Unknown and do not resume.
Other hosts must consult this owning-host record, not create their own copy.

Before sending, save host, task id/link, original stopped-turn id, interruption
evidence, authority reference, next step, and `resume requested`; confirm the
write succeeded. Keep the original stopped-turn id for the whole recovery
attempt: a queued, failed, or ambiguous resulting turn is not a new attempt.
Record its returned turn id and outcome in the same entry. A later independent
interruption qualifies only after verified completion of this recovery attempt;
another failure still requires diagnosis. Include record paths in the recovery
report so the next operator can find them.

Recheck live inactivity immediately
before submitting; use conditional/idempotent resume when the host offers it.
Do not send a recovery message to an active task where it might queue a second
turn. If live state cannot be established, leave it Unknown.

For a restart handoff, use the applicable same-task resume guidance in
[pause](../../pause/SKILL.md), preserving any requested model/effort selection
through the host control. For an unplanned quota interruption without a handoff,
send a short continuation to the existing task:

> Resume only your existing authorized work. Read your restart handoff and
> reconcile live task ownership, preserved local work, and current PR/issue
> state before acting. Follow your installed workflow's bounded status recovery
> when applicable. Do not duplicate active work, retry already-completed work,
> renew expired authority, or bypass remaining approval gates. Advance the
> next safe step and report only a concrete blocker or material outcome.

One submission per observed interruption; no automatic resend after a timeout,
ambiguous response, or another failure. Reconcile the saved entry on later runs
before considering any new submission. Do not reset the attempt just because
the audit was rerun. An ambiguous send remains Unknown until delivery and live
state are resolved. A repeat failure needs diagnosis, not a restart loop.

Read the resulting task state once to distinguish queued, running, completed,
failed, and Unknown. Record observed model/effort separately from requested
settings. A send acknowledgment is not proof of resumed execution. Leave
ongoing work with its existing owner; recovery does not wait for the entire PR
to finish or establish a second coordinator.

## Report exceptions, not another inbox

Summarize verified resumptions, queued requests, already-active tasks left alone,
and tasks not resumed with reasons. Put only concrete user decisions in the
human action list. Keep recovery details and archive candidates in the complete
audit artifact. State host coverage and uncertainty; never call a partial host
inventory a complete multi-machine recovery.
