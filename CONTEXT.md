# Agent Batch Coordination

Portable language for multi-agent PR-batch workflows: how coordinators, workers, and a coordination backend talk about ownership, liveness, and batch lifecycle. Keep repo-specific policy, backend names, dashboards, and domain vocabulary in each consumer repo's `AGENTS.md` seam or local docs.

## Language

### Ownership

**Claim**:
The exclusive lease one agent instance holds on a target (issue or PR) in one repo.
_Avoid_: lock, reservation, assignment

**Takeover**:
A *different* agent acquiring a claim only after the current holder is dead.
_Avoid_: steal, reclaim

**Supersede**:
A deliberate operator restart in which a *new instance of the same lane identity* fences out its live-or-stale predecessor via an explicit flag; never implicit.
_Avoid_: restart-claim, re-claim, takeover (that word is reserved for the different-agent case)

**Lane identity**:
The durable coordination identity for one lane owner: the lane plus its stable agent id or thread handle. It survives an operator-approved restart so a new instance can prove it is continuing the same lane.
_Avoid_: process id, chat id

**Instance**:
One running session (chat/process) for a lane identity; the same lane identity can have successive instances but only one may hold the claim.
_Avoid_: session, chat (in protocol contexts)

**Generation**:
The claim's monotonically increasing fencing counter; bumped on every ownership change so a displaced holder is rejected at its next write.
_Avoid_: version, epoch

### Liveness

**Live / Stale / Dead**:
Heartbeat states resolved by the active coordination backend: within TTL; expired but before the configured dead threshold; past that threshold. Use the documented config lookup, backend README, or CLI help for current timing. Stale blocks takeover; dead permits it.
_Avoid_: active/inactive, online/offline

**Wedged**:
A worker whose heartbeat is live but which makes no phase transitions — typically stalled on a permission prompt or a long tool call; distinct from dead.
_Avoid_: stuck (ambiguous between wedged and dead), hung

**Phase**:
A worker's self-reported position in the lane lifecycle (claimed, branching, implementing, validating, pushing, waiting-on-ci, addressing-review, blocked, done); progress signal, distinct from liveness.
_Avoid_: status (overloaded — heartbeat status and lane status already exist)

### Batch lifecycle

**Batch**:
A coordinator-scoped unit of work: objective, instructions, targets, and lanes. Depending on repo policy and dependency risk, it may be recorded in the private backend, mirrored through public claim comments, or carried only in the coordinator handoff.
_Avoid_: run, job

**Lane**:
One worker's slice of a batch: a named owner plus its targets and dependencies.
_Avoid_: track, slot, worker (the worker is the agent; the lane is the work)

**Thread handle**:
The short memorable name that appears both in a chat's auto-generated title (via the goal prompt's first line) and in the backend, so an operator can match dashboard rows to chat-sidebar threads.
_Avoid_: thread name (in prose; `thread_name` stays as the field name), session name

**Drain**:
Coordinator-published cancellation that workers honor at their next safe checkpoint; the preferred stop.
_Avoid_: kill, stop (bare)

**Hard escape hatch**:
Process-level termination plus manual claim/worktree cleanup, for a wedged worker that cannot reach a checkpoint.
_Avoid_: force kill (without the cleanup steps it names)

## Relationships

- A **Batch** has one or more **Lanes**; a **Lane** has exactly one owner identity at a time.
- A **Claim** is held by exactly one **Instance**; **Supersede** replaces the instance for the same **Lane identity**, **Takeover** replaces the owner after the holder is **Dead** — both bump the **Generation**.
- **Phase** answers "is it progressing?"; **Live/Stale/Dead** answers "is it running?"; **Wedged** is live without phase progress.
- **Drain** is observed at phase transitions; the **Hard escape hatch** is for workers that stop reaching them.

## Example dialogue

> **Dev:** "Lane docs shows **live** but has not moved phases — is it **dead**?"
> **Coordinator:** "No, it's **wedged** — the heartbeat sidecar is fine but there's been no **phase** transition since `implementing`. Inspect first; if it cannot reach a checkpoint, use the **hard escape hatch** before starting a replacement. Don't call it a **takeover** — that's only when a *different* agent claims after the holder is **dead**."

## Flagged ambiguities

- "status" was used for three different things — resolved: **Phase** (worker progress), heartbeat status (the raw field), and lane status (batch-file field) are distinct; prefer **Phase** in prose.
- "stuck" was used for both **Wedged** and **Dead** — resolved: they need different operator responses (inspect or hard escape vs dead-threshold takeover or explicit supersede), so the vague word is avoided.
- "restart" previously meant re-pasting a prompt, which silently double-started a lane — resolved: the sanctioned restart is **Supersede**.
