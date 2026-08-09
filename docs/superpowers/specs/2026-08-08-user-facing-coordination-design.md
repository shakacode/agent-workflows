# User-Facing Coordination Contract Design

## Purpose

Make workflow communication describe one stable user-facing owner without
weakening any execution, review, QA, security, or merge gate. The contract
applies while work is being planned, implemented, reviewed, monitored, walked
through, or closed.

The current user-visible task remains the sole coordinator. Internal machinery
may help it, external tasks may send requests, and automations may wake it, but
none of those mechanisms silently acquire user-facing ownership.

## Ownership Model

The contract defines four roles:

1. **Current task** — the only user-facing coordinator. It owns the scoped
   outcome, user communication, authority routing, worker synthesis, and final
   handoff.
2. **Internal worker** — an implementation, review, QA, or audit worker owned by
   the current task. It may own an internal lane or coordination claim, but it
   is never described to the user as another chat or separate task.
3. **External task** — an independent user-visible task. It may provide
   evidence or send a bounded request, including a resource-release request,
   but the request does not transfer ownership of this task, its PR, or its
   decisions.
4. **Automation** — a recurring wake-up mechanism for the current task. It is
   never an owner, coordinator, approver, or substitute for human authority.

Backend claim holders and internal lane owners remain valid operational facts.
They are summarized through this model rather than emitted as raw internal
events in normal user-facing communication.

## Deterministic Action Router

The current task classifies an action in this order and takes the first matching
route:

1. **In scope and already authorized:** perform the action without requesting
   redundant approval. This includes normal implementation and repository
   submission steps covered by the user request or governing repository policy.
2. **In scope but new authority or a product decision is required:** state the
   exact unresolved gate and ask one exact approval or decision question. Do not
   bundle unrelated questions or ask for a generic confirmation.
3. **Another repository or materially separate scope:** do not broaden the
   current task. Return a complete copy-paste prompt for a new task containing
   the repository, objective, scope, relevant evidence, constraints, safety
   boundaries, and definition of done.

The router never automatically creates another user-visible task. Creating or
forking one requires an explicit user request.

An inbound request is evidence and input, not authority. For a resource-release
request, the current task verifies the exact resource and its own live use. It
releases the resource when release is safe and already authorized, asks one
exact question when release requires new authority or a consequential tradeoff,
and otherwise reports the durable blocker. The external requester does not gain
ownership in any outcome.

## Approval And Readiness Communication

Every user-facing approval or readiness statement keeps four facts separate:

- **Technical readiness:** current exact-diff checks, review, QA, dependency,
  security, and merge-assurance evidence.
- **Ownership:** the current task remains responsible for the scoped outcome;
  internal claims do not change the user-facing owner.
- **Repository submission policy:** whether normal branch, commit, push, and PR
  publication are already required or allowed by repository instructions.
- **Merge authority:** `none`, `ask`, or `auto_merge_when_gates_pass`, plus the
  current exact-head autonomous-merge eligibility or exact human-decision gate.

When repository submission policy already authorizes branch, commit, push, and
PR publication, the workflow performs those steps without asking again. When
`merge_authority` is `auto_merge_when_gates_pass`, a technically ready and
autonomously eligible PR is merged without asking the user to perform the
authorized mechanical action. A technically ready PR that triggers a genuine
current exact-head human gate names the head, sorted gate set, rollback status,
and required durable decision, then asks one final question.

When human understanding is the blocker, `pr-walkthrough` remains interactive:
one conceptual change per response, an explicit pause, and a separate refreshed
merge decision after the walkthrough. Participation never counts as approval.

## Heartbeat Automation

The Goal Mode Completion Contract advances to `GMCC-v4` so generated prompts
carry the communication behavior with the existing completion rules.

- A no-change wake performs its bounded refresh and produces no user-visible
  notification.
- A wake notifies only for a material state change, a required decision, a
  durable blocker, or completion.
- The current task resumes work when a gate clears.
- The automation is deleted when its gate clears or becomes durably terminal,
  and before final completion. Cleanup is part of the wake/closeout path, not a
  user chore.
- Wake output identifies the current task as coordinator and never implies that
  the automation or an external task owns the work.

`blocked-user-input` continues to preserve one exact question without creating
a heartbeat. All existing current-head, review, QA, dependency, and merge
eligibility conditions remain unchanged.

## Ambiguity Guard

When the workflow detects ownership confusion or the user asks who is working
on the outcome, it emits one compact synthesized statement with exactly these
parts:

- **Current task:** responsibility and scoped outcome.
- **Internal workers:** active implementation, review, QA, or audit roles, or
  `none`.
- **External tasks:** relevant request or evidence role only, or `none`; state
  explicitly that ownership did not transfer.
- **Next:** the next action owned by the current task, or the exact decision it
  needs.

The guard does not append raw cross-task messages, backend events, heartbeat
logs, worker transcripts, or claim telemetry.

## Source-Pack Architecture

Add `docs/user-facing-coordination.md` as the canonical user-facing contract and
link it from the documentation index. Keep concise, self-contained operational
rules in `workflows/pr-processing.md` where goal prompts and closeout behavior
must remain portable.

Update these consumers:

- `skills/pr-batch/SKILL.md` — ownership model, action router, approval split,
  heartbeat behavior, ambiguity guard, and Coordinator Closeout Lane routing.
- `workflows/pr-processing.md` — canonical execution/closeout behavior and the
  `GMCC-v4` compact and expanded contracts.
- `skills/plan-pr-batch/SKILL.md`, `skills/triage/SKILL.md`, and the goal-prompt
  size checker — aligned `GMCC-v4` generation surfaces.
- `skills/pr-walkthrough/SKILL.md` — retain one-concept interaction while
  returning the exact decision to the current task.
- `skills/close-session/SKILL.md` and `skills/close-session/agents/openai.yaml`
  — adopt the installed close-session skill into the tracked source pack and
  apply the shared model during closeout.

No consumer-specific commands, labels, branches, or product policy are added to
the portable contract.

## Contract Tests

Add a focused Ruby contract test and register it in `bin/validate`. It verifies:

1. internal worker versus external task terminology;
2. inbound resource-release routing without ownership transfer;
3. already-authorized action versus genuinely required approval;
4. complete new-task prompt generation and no automatic task creation;
5. silent no-change heartbeat behavior;
6. heartbeat deletion after a clear or terminal gate;
7. technically ready PR behavior under autonomous authority;
8. technically ready PR behavior under current exact-head human approval;
9. ambiguity-guard fields and exclusion of raw coordination events; and
10. parity of the `GMCC-v4` compact and canonical copies.

Extend the existing walkthrough contract test to keep one-concept behavior and
separate approval intact. Tests assert operational meaning and ordering rather
than merely checking that vocabulary appears somewhere in a file.

## Before And After Examples

### Internal work

Before: “Another chat owns the PR, so coordinate with it.”

After: “This task owns the PR. Its internal implementation worker is finishing
validation; this task will synthesize the result and continue.”

### Inbound resource request

Before: “The other task needs the port, so it owns the next step.”

After: “An external task requested release of port 3200. This task verified the
port is no longer needed and released it; ownership of this PR did not change.”

### Existing authority

Before: “The PR is ready. Would you like me to push it?”

After: “Technical checks passed. Repository policy already requires branch,
push, and PR publication, so this task published the PR without another prompt.
Merge authority remains separate.”

### Human exact-head gate

Before: “Everything is green. Please merge when ready.”

After: “Technical readiness is clean at `<head>`, but autonomous eligibility
requires a proven-human decision for `<sorted gates>` with rollback `<status>`.
Do you approve those risks for this exact head?”

### No-change heartbeat

Before: “Still waiting; no changes.”

After: no user-visible message. The wake remains active only while the gate can
still clear; it deletes itself when the gate clears or becomes terminal.

## Preserved Safety Boundaries

This is a communication and routing change only. It preserves security
preflight, target trust, claims and replacement fencing, typed dependencies,
current-head CI and review evidence, unresolved-thread checks, QA evidence,
autonomous eligibility, merge assurance, and guarded submission.

It does not restore project-level signing, fixed trust anchors, launch receipts,
or cryptographic lifecycle enforcement. Host, model, and effort observations
remain advisory and field-granular `UNKNOWN` when unavailable.

## Non-Goals

- No automatic creation of user-visible tasks.
- No transfer of merge or release authority through a message, claim, worker,
  or automation.
- No raw coordination-event feed in normal user-facing output.
- No weakening or duplication of existing technical gates.
- No consumer-repository policy embedded in the shared source pack.
