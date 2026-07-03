# Agent Batch Coordination

The shared language for ShakaCode's multi-agent PR-batch workflows: how coordinators, workers, and the coordination backend talk about ownership, liveness, and batch lifecycle. Spans shakacode/agent-workflows (process), shakacode/agent-coordination (backend), and agent-coordination-dashboard (observability).

## Language

### Ownership

**Claim**:
The exclusive lease one agent instance holds on a target (issue or PR) in one repo.
_Avoid_: lock, reservation, assignment

**Takeover**:
A *different* agent acquiring a claim after the current holder is dead or its lease expired.
_Avoid_: steal, reclaim

**Supersede**:
A deliberate operator restart in which a *new instance of the same lane identity* fences out its live-or-stale predecessor via an explicit flag; never implicit.
_Avoid_: restart-claim, re-claim, takeover (that word is reserved for the different-agent case)

**Instance**:
One running session (chat/process) of an agent identity; the same lane identity can have successive instances but only one may hold the claim.
_Avoid_: session, chat (in protocol contexts)

**Generation**:
The claim's monotonically increasing fencing counter; bumped on every ownership change so a displaced holder is rejected at its next write.
_Avoid_: version, epoch

### Liveness

**Live / Stale / Dead**:
Heartbeat states: within TTL; expired but under 4× TTL; past 4× TTL. Stale blocks takeover; dead permits it.
_Avoid_: active/inactive, online/offline

**Wedged**:
A worker whose heartbeat is live but which makes no phase transitions — typically stalled on a permission prompt or a long tool call; distinct from dead.
_Avoid_: stuck (ambiguous between wedged and dead), hung

**Phase**:
A worker's self-reported position in the lane lifecycle (claimed, branching, implementing, validating, pushing, waiting-on-ci, addressing-review, blocked, done); progress signal, distinct from liveness.
_Avoid_: status (overloaded — heartbeat status and lane status already exist)

### Batch lifecycle

**Batch**:
A coordinator-registered unit of work: objective, instructions, targets, and lanes — registered in the backend *before* any worker starts.
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
- A **Claim** is held by exactly one **Instance**; **Supersede** replaces the instance, **Takeover** replaces the agent — both bump the **Generation**.
- **Phase** answers "is it progressing?"; **Live/Stale/Dead** answers "is it running?"; **Wedged** is live without phase progress.
- **Drain** is observed at phase transitions; the **Hard escape hatch** is for workers that stop reaching them.

## Example dialogue

> **Dev:** "Lane docs shows **live** but hasn't moved in 40 minutes — is it **dead**?"
> **Coordinator:** "No, it's **wedged** — the heartbeat sidecar is fine but there's been no **phase** transition since `implementing`. If you restart the chat, use **supersede** so the old **instance** gets fenced by the **generation** bump; don't just re-paste the prompt, and don't call it a **takeover** — that's only when a *different* agent claims after the holder is **dead**."

## Flagged ambiguities

- "status" was used for three different things — resolved: **Phase** (worker progress), heartbeat status (the raw field), and lane status (batch-file field) are distinct; prefer **Phase** in prose.
- "stuck" was used for both **Wedged** and **Dead** — resolved: they need different operator responses (wait/inspect vs supersede), so the vague word is avoided.
- "restart" previously meant re-pasting a prompt, which silently double-started a lane — resolved: the sanctioned restart is **Supersede**.
