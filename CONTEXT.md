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

**Stage-typed dependency**:
A directed lane edge evaluated by the portable `stage-dependency-gate` v1 JSON
contract. `edit` protects branch/worktree and edit/commit mutation,
`validation_open` separates safe held-local work from push/PR/final-validation
eligibility, and `merge_order` constrains merge only. Missing, unsupported, or
`UNKNOWN` type/state/evidence fails closed; generic backend `depends_on` state
is a source fact, not a replacement for the typed edge.
_Avoid_: dependency (when its blocked lifecycle stage is unstated), ready flag

**Stage dependency edge binding**:
An immutable pre-launch trusted plan, persisted separately from live replay,
binds every edge's `id`, `from`, `to`, and `type` under a coordinator-pinned
plan identity. Live facts update state/evidence by edge id only; tuple copies in
mutable input are not trusted. The same id cannot be retyped in place;
reclassification is a new edge id plus a trusted coordinator re-plan.
_Avoid_: mutable edge type, inferred reclassification

**Preparation replay**:
A deterministic per-lane record for pending edit or validation/open work:
source-patch inspection, collision-domain mapping, semantic-adaptation notes,
validation/review plan, and evidence templates. Missing or unknown preparation
blocks mutation; validation/open permits held-local work only after replay,
while edit remains read-only and merge-order remains merge-only.
_Avoid_: readiness note, implicit preparation

**Dependency evidence binding**:
A nonempty verified `evidence_ref` plus the type-required full SHA and terminal
facts for a satisfied stage-typed dependency. Validation/open evidence binds
the dependent current head and dependency-bearing base; merge-order evidence
binds the predecessor current head and merged terminal state. Base movement is
replayed from explicit semantic-overlap, required-dependency,
conflict/base-sensitive, and consumer-policy facts. The reference conveys no
cross-PR artifact trust or authority.
_Avoid_: cached green, inherited CI, artifact handoff

**Stage dependency critical path**:
The longest path in the typed lane graph, with equal lengths resolved by the
lexicographically smallest lane-id sequence. Its recorded maker/checker
assignments keep every normalized checker distinct from every batch maker; the
path is allocation evidence, not permission to self-check or bypass a gate.
_Avoid_: priority guess, merge order (only one edge type)

**Coordinator model/effort assignment**:
The parent coordinator's model and supported reasoning effort, selected for
scope, risk, routing, integration, review, and closeout independently of worker
routes.
_Avoid_: batch model (it does not automatically apply to every worker)

**Batch launch assurance**:
The fail-closed pre-dispatch record that the already-running initiating parent
has the exact coordinator model/effort required by operator policy, with a
host/runtime or explicit operator-selected binding source, and that the exact
checker model/effort required by operator policy is reserved with qualifying
binding evidence. Prompt text, model self-report, installed rosters, mutable
default configuration, and dispatch-resolved classes do not prove the active
parent or checker; runtime evidence must be effective and instance-bound. A
mismatch or `UNKNOWN` blocks planning or dispatch when the policy requires an
exact parent or checker. Checker freshness and independence are reverified when
the checker instance starts and before its verdict is accepted.
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

**Dispatcher capability preflight**:
The portable JSON-in/JSON-out decision that records a lane's requested and
actual route/dispatcher only after binding and attestation. It chooses the
requested tuple or the first explicitly authorized ordered fallback, never
inherits the coordinator route or generic subagent authority, preserves lane
state, and emits one durable `dispatch-decision-request v1` when blocked. Use
`dispatcher-capability-preflight` before launch; it never launches or mutates.
Each viable candidate includes a stable prospective `instance_id` allocated or reserved by its dispatcher before launch, only for replay/fencing; the helper neither launches nor creates a worker.
Binding, attestation, and prospective `instance_id` evidence whose trimmed case-insensitive value is `UNKNOWN` is unusable and must not select or resume Goal mode. Replay identity is `lane_id`, route, dispatcher, `instance_id`, and launch token; `candidate_index` is discovery metadata rebuilt from the current candidate order. Replacement fencing returns `blocked-replacement-fencing` with required action `stop-and-reconcile-prior-instance`, preserves the active assignment and lane state, and emits no `dispatch-decision-request`; `blocked-user-input` is reserved for missing authorized route/dispatcher choice.
Persist a selected assignment as lifecycle `launch-pending` with its idempotency launch token before worker launch; persist a request plus validated resolution, lifecycle, and replacement-proof consumption before resume or launch.
Accepted binding evidence is `operator-selected` or `dispatcher-bound`; accepted attestation evidence is `instance-bound` or `dispatcher-attested`; `UNKNOWN` or negative evidence fails closed. A replacement proof is single-use and identity-bound to exact prior and replacement tuples, and both proof lane ids must equal the current input `lane_id`; cross-lane proof fences. A matching `launch-pending` assignment reissues the same launch instruction and token; only an identity-bound `launch-confirmation v1` transitions it to `confirmed-active`, which returns `replay-already-active` with no launch instruction. Persisted request history, choices, revisions, assignments, proof, confirmation, and `decision_resolution` are deep-validated; a valid resolution replays without transient `operator_decision`, while malformed nested state returns structured `invalid-input`. Every self-contained or autoload-failure execution path loads persisted dispatch state before preflight and persists its output before any Goal-mode resume or launch.
_Avoid_: worker launcher, backend mutation

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
- A **Stage-typed dependency** connects predecessor and dependent **Lanes**;
  backend dependency state supplies facts, while `stage-dependency-gate` decides
  which lifecycle actions remain gated. Its **Stage dependency critical path**
  carries maker/checker allocation with each checker independent from every
  batch maker and never replaces downstream exact-head, review/thread,
  merge-readiness, or combined-tip gates.
- A ready **Lane** has one verified **Worker model/effort route** and exactly one
  active **Active model/effort assignment** while its current instance runs; a
  **Model/effort route group** can contain several lanes but creates no
  ownership or scheduling relationship between them.
- A **Dispatcher capability preflight** records at most one active assignment
  and launch token for a **Lane**; replacement requires the prior instance to
  stop and reconcile before a new assignment is recorded.
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
