# Agent Batch Coordination

Portable language for multi-agent PR-batch workflows: how coordinators, workers, and a coordination backend talk about ownership, liveness, and batch lifecycle. Keep repo-specific policy, backend names, dashboards, and domain vocabulary in each consumer repo's `AGENTS.md` seam or local docs. The companion glossary for source-pack distribution, install-path, seam, readiness, and review terms is [docs/source-pack-glossary.md](docs/source-pack-glossary.md).

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
A coordinator-scoped unit of work: objective, instructions, targets, and lanes.
When wave scheduling is used, a batch organizes its lanes into named waves.
Depending on repo policy and dependency risk, it may be recorded in the private
backend, mirrored through public claim comments, or carried only in the
coordinator handoff.
_Avoid_: run, job

**Lane**:
One durable, agent-owned work stream: either a direct single-PR task in the
current chat or one worker's slice of a batch. A lane has a named owner plus
its target or targets and optional dependencies; an **Instance** executes the
lane but is not the lane.
_Avoid_: track, slot, worker (the worker is the agent; the lane is the work)

**Wave**:
A named scheduling cohort of lanes within a batch.
_Avoid_: dependency group, lane state

**Active wave**:
The one wave currently considered for scheduling. Later waves are deferred
cohorts, not dependency evidence.
_Avoid_: active lane, dependency-ready wave

**Serialization group**:
A named set of lanes whose concurrent execution is limited. The currently
supported limit is `max_concurrency: 1`. A member occupies its slot while its
durable lifecycle state is `active` or `blocked`, including `active` ↔
`blocked` transitions, and releases it only after it leaves both states.
_Avoid_: dependency group, lock

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

**Coordinator model/effort preference**:
The preferred parent-coordinator model and reasoning effort for scope, risk,
routing, integration, review, and closeout, independently of worker preferences.
Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit.
_Avoid_: batch model (it does not automatically apply to every worker)

**Observed host/model/effort**:
Optional runtime metadata exposed by the host for a running assignment. Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report.
Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict.
Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route.
A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict.
Named coordinator and worker models, efforts, and route classes are recommendations; no named route is a prerequisite for planning, launch, coordination, execution, escalation, or fallback.
When a preferred route is unavailable, different, inherited, or `UNKNOWN`, use the closest available route or runtime default, record requested and host-observed fields honestly, and continue unless an independent risk, scope, evidence, or authority gate blocks.
Risk classification, execution-envelope requirements, and stop or return conditions depend on lane ambiguity, scope, security, consequence, and verification strength, not on model identity.
Require an execution envelope when lane risk or bounded delegation requires one; approval is role-based and never requires a named model.
_Avoid_: requested model as observation, prompt model

**Worker model/effort route**:
The staged policy for one lane: its initial assignment, optional escalation
assignment and role, evidence gate, and maximum escalation cycles. Use exact
pairs or host-stable aliases as preferences when the roster is known;
dispatch-resolved classes, the closest available route, or the runtime default
may stand in when it is not. Record any inherited/default route honestly.
_Avoid_: worker model (singular static choice), coordinator assignment

**Worker execution envelope**:
The coordinator-role-approved bounded contract used when lane risk or bounded
delegation requires it, regardless of the worker route:
goal and non-goals, owned paths, supported diagnosis, invariants, acceptance
criteria, verification, and stop conditions. Contradictory evidence, ambiguity,
material semantic scope growth, high-risk judgment, or weakened verification
returns control to the coordinator instead of authorizing worker re-planning.
Evidence-backed discovery of a necessary in-repository path alone is not such
growth; follow the [path-expansion
contract](docs/pr-batch-skills.md#implementation-batch-planning-flow).
_Avoid_: task prompt, broad plan

**Active worker assignment**:
The lane, dispatcher, stable instance, launch token, ordinary lifecycle, route
preference, and optional host-observed metadata for one current worker. A lane
has at most one active assignment and instance at a time.
_Avoid_: planned route, inherited model

**Dispatcher capability preflight**:
The portable JSON-in/JSON-out decision that records a lane's route preference
and dispatcher selection. It prefers the requested dispatcher, uses another
dispatcher only with explicit dispatch authority, preserves lane state, and
emits one durable `dispatch-decision-request v1` when dispatcher choice is
blocked. Use
`dispatcher-capability-preflight` before launch; it never launches or mutates.
Each viable candidate includes a stable prospective `instance_id` allocated or reserved by its dispatcher before launch, only for replay/fencing; the helper neither launches nor creates a worker.
Prospective `instance_id` equal to `UNKNOWN` is unusable. Replay identity is `lane_id`, dispatcher, `instance_id`, and launch token; route preference, observed host fields, and `candidate_index` are metadata and never trigger replacement.
Persist `launch-pending` before worker launch; after spawn, persist ordinary `active` state before Goal-mode resume, and replay the same token while pending or emit no new launch while active.
Assignment activation uses ordinary durable lifecycle state; no project signing key, fixed trust anchor, launch-confirmation receipt, or human waiver is required.
Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report.
Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit.
A dispatcher or instance change still requires stop/reconcile replacement fencing and a single-use proof bound to the exact prior and replacement assignment identities.
Persisted request history, choices, revisions, assignments, replacement proofs, and `decision_resolution` are deep-validated; malformed nested state returns structured `invalid-input`. Every self-contained or autoload-failure execution path loads persisted dispatch state before preflight and persists its output before any Goal-mode resume or launch.
_Avoid_: worker launcher, backend mutation

**Model escalation request**:
A worker's evidence packet asking the coordinator to approve a stronger role;
it records attempts, failures, uncertainty, risk, verification gaps, and the
smallest recommended next action, but grants no authority by itself.
_Avoid_: self-upgrade, automatic retry

**Model replacement handoff**:
The durable checkpoint captured before replacing a lane's worker instance,
including an actual runtime model/effort change: repo/worktree/branch state, changes, claim/fencing
state, evidence, attempts, invariants, validation, running processes, unknowns,
and next action.
_Avoid_: restart prompt, cancellation handoff

**Dispatch-resolved model class**:
A portable roster-unavailable fallback — `fastest-low-cost`, `balanced`, or
`strongest` — paired with an effort level, optionally scoped to a known host,
and carried as an advisory preference before any worker starts. A host may
resolve it to an available pair when the runtime exposes one; the prompt target
does not prove the worker roster. If the dispatcher or runtime inherits or
defaults to the coordinator route, record the actual route honestly and
continue unless an independent gate blocks.
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

### Integration

These terms define the intended integration contract. Label automation and
comment-envelope enforcement are follow-up work, not implemented by this ADR.

**Merge backlog**:
The open PRs, drafts included, whose remaining step is a merge decision or a
mechanical unblock such as a rebase or a stale bot-review dismissal, not
implementation.
_Avoid_: stuck PRs, open PR count

**Control tower**:
The persistent per-repository role, served by one bounded task session per
attention interval, that integrates ready work under the merge authority it
was granted, remediates small blockers, and routes only outcome-changing
decisions to the human.
_Avoid_: sweeper, merge bot, the batch (a batch ends; the role outlives its
sessions)

**Human-attention label**:
A GitHub label stating that the next action on a PR belongs to the human:
`human-attention:walkthrough` (read the published walkthrough first) or
`human-attention:merge` (agents recommend merge; the human's exact-head
approval on the PR is the remaining step, after which the **Control tower**
submits the merge through the guarded path).
_Avoid_: ready to merge, needs review, approved, merge click

**Needs-rebase**:
The `needs-rebase` label a planned GitHub Action will apply while a PR conflicts
with its base and remove when it no longer does; it queues mechanical work for the
**Control tower** and is never a human signal.
_Avoid_: conflicting (the raw GitHub field), blocked

**Disposition**:
The **Control tower**'s per-PR classification: exactly one of the throughput
plan's R12 names `accelerate`, `continue`, `hold`, `replace`, `close`, or
`integration-ready`, where the control-tower prompts add that `close` requires
evidence of duplicate, superseded, or invalid work and keeps the branch.
_Avoid_: triage state, verdict, status

**Comment kind**:
The required audience class in every agent-posted GitHub comment envelope:
`bookkeeping` (agent-to-agent, fully collapsed under one summary line),
`info` (human-readable, `Action needed: none`, detail collapsed), or
`decision` (the four desk-card fields visible, detail collapsed).
_Avoid_: comment type, severity, priority (a decision's priority is a card field)

**Integration pass**:
One **Control tower** tick's sweep of the **Merge backlog** plus every
unclaimed draft: merge what passes the exact-head gates, remediate small
blockers, give each unclaimed draft a **Disposition**, and label what needs the
human, in that order.
_Avoid_: drain (reserved for cancellation), cleanup, sweep

## Relationships

- **Batch → Wave → Lane → Instance**: when wave scheduling is used, a
  batch contains named scheduling waves; a wave contains lanes; an **Instance**
  executes one lane. For example,
  `docs-batch → wave-1 → lane-glossary → instance A`. A direct
  PR task can also be one standalone **Lane** without batch planning or worker
  split machinery. A **Lane** has exactly one owner identity at a time.
- An **Active wave** is the scheduling cohort considered now. Lanes in later
  **Waves** are deferred, and that deferral does not establish a dependency.
  A **Serialization group** with `max_concurrency: 1` admits one member at a
  time; a member retains its slot through `active` ↔ `blocked` transitions and
  releases it only after leaving both states. Neither wave nor serialization-
  group membership supplies dependency evidence; use a **Stage-typed
  dependency** for ordering.
- A **Stage-typed dependency** connects predecessor and dependent **Lanes**;
  backend dependency state supplies facts, while `stage-dependency-gate` decides
  which lifecycle actions remain gated. Its **Stage dependency critical path**
  carries maker/checker allocation with each checker independent from every
  batch maker and never replaces downstream exact-head, review/thread,
  merge-readiness, or combined-tip gates.
- A ready **Lane** has one advisory **Worker model/effort route** and exactly one
  active **Active worker assignment** while its current instance runs; a
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
- A **Merge backlog** item belongs to the repository **Control tower** once
  the **Lane** that opened it ends; a lane never keeps a PR alive to merge it.
- A **Human-attention label** is applied by the **Control tower** after the
  autonomous-merge eligibility gate hands a PR to the human, and stripped by
  the planned CI automation when the head changes. Until that automation exists,
  the tower must recheck the head and remove stale labels before human handoff.
  A CI-triggered agent may read, review, label, and
  draft an assessment; it never pushes or merges.
- Every agent-posted GitHub comment carries exactly one **Comment kind**; a
  `decision` comment is the same card the Human Attention Desk mirrors, and
  only a `decision` may accompany a **Human-attention label**.
- A `bookkeeping` comment is one per agent task per PR and is edited in place;
  a `decision` comment is never edited after a human could have replied; an
  `info` comment appends so each walkthrough section stays separately
  replyable.
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
- "stuck" was also used for the PR portfolio — resolved: **Merge backlog**
  names the PRs; **Wedged** and dead stay reserved for workers.
- "drain the backlog" collided with **Drain** — resolved: **Drain** stays the
  cancellation signal; backlog reduction is an **Integration pass**.
