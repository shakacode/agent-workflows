# Agent Batch Coordination

Portable language for multi-agent PR-batch workflows: how coordinators, workers, and a coordination backend talk about ownership, liveness, and batch lifecycle. Keep repo-specific policy, backend names, dashboards, and domain vocabulary in each consumer repo's `AGENTS.md` seam or local docs.

## Language

### Ownership

**Claim**:
The exclusive lease one agent instance holds on a target (issue, PR, batch lane, QA lane, or other repo-scoped coordination target) in one repo.
_Avoid_: lock, reservation, assignment

**Takeover**:
A *different* agent acquiring a claim only after the current private-backend holder is dead, or after a public fallback claim's advisory lease has expired.
_Avoid_: steal, reclaim

**Supersede (claim operation)**:
A deliberate operator replacement in which a *new instance of the same lane identity* fences out its live-or-stale predecessor via an explicit flag when the coordination backend supports that operation; never implicit.
_Avoid_: restart-claim, re-claim, takeover (reserved for the different-agent case), superseded check row (CI/review context)

**Lane identity**:
The durable coordination identity for one lane owner: the lane plus its stable agent id or thread handle. It survives an operator-approved restart so a new instance can prove it is continuing the same lane.
_Avoid_: process id, chat id

**Instance**:
One running session (chat/process) for a lane identity; the same lane identity can have successive instances but only one may hold the claim.
_Avoid_: session, chat (in protocol contexts)

**Generation**:
The claim's monotonically increasing fencing counter when the coordination backend supports fenced ownership changes; bumped on every ownership change so a displaced holder is rejected at its next write.
_Avoid_: version, epoch

### Liveness

**Live / Stale / Dead**:
Heartbeat states resolved by the active coordination backend: within TTL; expired but before the configured dead threshold; past that threshold. Use the documented config lookup, backend README, or CLI help for current timing. Stale blocks takeover; dead permits it.
_Avoid_: active/inactive, online/offline

**Wedged**:
A worker whose heartbeat is live but which makes no worker phase transitions — typically stalled on a permission prompt or a long tool call; distinct from dead.
_Avoid_: stuck (ambiguous between wedged and dead), hung

**Worker phase**:
A worker's self-reported position in the lane lifecycle; progress signal, distinct from liveness. Use the active workflow or backend vocabulary for phase names, such as item start, branch or PR update, validation, review pass, blocked, resumed, and done.
_Avoid_: status (overloaded), phase by itself when release phase is in scope

### Batch lifecycle

**Batch**:
A coordinator-scoped unit of work: objective, instructions, targets, and lanes. Depending on repo policy and dependency risk, it may be recorded in the private backend, mirrored through public claim comments, or carried only in the coordinator handoff.
_Avoid_: run, job

**Lane**:
One agent-owned work stream: either a direct single-PR task in the current chat
or one worker's slice of a batch. A lane has a named owner plus its target or
targets and optional dependencies.
_Avoid_: track, slot, worker (the worker is the agent; the lane is the work)

**Coordinator model/effort assignment**:
The parent coordinator's model and supported reasoning effort, selected for
scope, risk, routing, integration, review, and closeout independently of worker
routes.
_Avoid_: batch model (it does not automatically apply to every worker)

**Batch launch assurance**:
The fail-closed pre-dispatch record that the already-running initiating parent
has the exact coordinator model/effort required by operator policy, with a
host/runtime or explicit operator-selected binding source, and that the
independent checker route is reserved. Prompt text, model self-report, installed
rosters, and dispatch-resolved classes do not prove the active parent. A
mismatch or `UNKNOWN` blocks planning or dispatch when the policy requires an
exact parent.
_Avoid_: requested model, prompt model

**Worker model/effort route**:
The staged policy for one lane: its initial assignment, optional escalation
assignment and role, evidence gate, and maximum escalation cycles. Use exact
pairs or host-stable aliases when the roster is known; dispatch-resolved classes
may temporarily stand in when it is not.
_Avoid_: worker model (singular static choice), coordinator assignment

**Worker execution envelope**:
The coordinator-approved bounded contract a lower-capability worker executes:
goal and non-goals, owned paths, supported diagnosis, invariants, acceptance
criteria, verification, and stop conditions. Contradictory evidence, ambiguity,
scope growth, high-risk judgment, or weakened verification returns control to
the coordinator instead of authorizing worker re-planning.
_Avoid_: task prompt, broad plan

**Active model/effort assignment**:
The exact model and supported reasoning effort used by the lane's current worker
instance. A lane has at most one active assignment and instance at a time.
_Avoid_: planned route, inherited model

**Model escalation request**:
A worker's evidence packet asking the coordinator to approve a stronger role;
it records attempts, failures, uncertainty, risk, verification gaps, and the
smallest recommended next action, but grants no authority by itself.
_Avoid_: self-upgrade, automatic retry

**Model replacement handoff**:
The durable checkpoint captured before changing a lane's worker instance or
model/effort assignment: repo/worktree/branch state, changes, claim/fencing
state, evidence, attempts, invariants, validation, running processes, unknowns,
and next action.
_Avoid_: restart prompt, cancellation handoff

**Dispatch-resolved model class**:
A portable roster-unavailable fallback — `fastest-low-cost`, `balanced`, or
`strongest` — paired with an effort level, optionally scoped to a known host,
and bound to an exact supported worker-host pair before any worker starts. The
prompt target identifies the destination host class; it does not prove the
worker roster or authorize inheritance from the coordinator.
_Avoid_: guessed model, default model

**Model/effort route group**:
A planning and dispatch view that collates lanes with the same initial and
escalation route without merging their owners, claims, targets, dependencies,
instances, or file-touch ordering.
_Avoid_: combined lane, shared worker

**Thread handle**:
The short memorable identifier shared by coordination records and handoff notes, so an operator can match a worker session to its lane.
_Avoid_: thread name (ambiguous between chat title and backend field), session name

**Drain**:
Coordinator-published cancellation in backend-supported coordination state that workers honor at their next safe checkpoint; the preferred stop when workers can observe that state. In fallback-only or no-backend batches, use process-stop and reconciliation from the hard escape hatch instead.
_Avoid_: kill, stop (bare)

**Hard escape hatch**:
Coordinator-recorded cancellation when available, then process-level termination plus manual claim/worktree cleanup, for a wedged worker that cannot reach a checkpoint.
_Avoid_: force kill (without the cleanup steps it names)

## Relationships

- A **Batch** has one or more **Lanes**; a direct PR task can also be one
  standalone **Lane** without batch planning or worker split machinery. A
  **Lane** has exactly one owner identity at a time.
- A ready **Lane** has one verified **Worker model/effort route** and exactly one
  active **Active model/effort assignment** while its current instance runs; a
  **Model/effort route group** can contain several lanes but creates no
  ownership or scheduling relationship between them.
- **Model escalation request** approval can replace a lane's assignment and
  instance only after a **Model replacement handoff**; the old and replacement
  worker instances never overlap.
- A **Claim** is held by exactly one **Instance**; **Supersede (claim operation)** replaces the instance for the same **Lane identity**, **Takeover** replaces the owner after the holder is **Dead** or a fallback claim expires — both bump the **Generation** when the backend supports fencing.
- **Worker phase** answers "is it progressing?"; **Live/Stale/Dead** answers "is it running?"; **Wedged** is live without worker-phase progress.
- **Drain** is observed at worker phase transitions; the **Hard escape hatch** is for workers that stop reaching them.

## Example dialogue

> **Dev:** "Lane docs shows **live** but has not moved worker phases — is it **dead**?"
> **Coordinator:** "No, it's **wedged** — the heartbeat sidecar is fine but there's been no **worker phase** transition since `implementing`. Inspect first; if it cannot reach a checkpoint, use the **hard escape hatch** before starting a replacement. Don't call it a **takeover** — that's only when a *different* agent claims after the holder is **dead** or an advisory fallback claim has expired."

## Flagged ambiguities

- "status" was used for three different things — resolved: **Worker phase** (worker progress), heartbeat status (the raw field), and lane status (batch-file field) are distinct; prefer **Worker phase** in prose.
- Some older shared docs still say "heartbeat status" for phase-like values such as blocked, done, or cancelled — treat that as legacy wording. When updating those docs, prefer **Worker phase** for progress and **Live/Stale/Dead** for liveness.
- **Lane identity**, **Instance**, and **Generation** describe optional fenced replacement semantics. When a backend contract omits those fields, do not require them unless that backend advertises explicit **Supersede (claim operation)** or fencing support.
- "stuck" was used for both **Wedged** and **Dead** — resolved: they need different operator responses (inspect or hard escape vs dead-threshold takeover or explicit **Supersede (claim operation)**), so the vague word is avoided.
- "restart" previously mixed ordinary agent-runner resume prompts with backend-fenced replacement — resolved: use restart/resume handoffs for the former, and **Supersede (claim operation)** only for explicit same-lane replacement when the backend supports fencing.
- "supersede" also appears in CI/review triage for superseded workflow rows — resolved: **Supersede (claim operation)** is only the same-lane ownership replacement; use "superseded check row" or similar in CI contexts.
- "phase" also appears in release phase / phase-gating policy — resolved: use **Worker phase** for lane progress and "release phase" for branch or release-train gate context.
