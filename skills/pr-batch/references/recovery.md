## Pausing Or Stopping A Batch

### Model-Only Worker Replacement

When the goal, targets, scope, and lane identity stay stable but a worker needs
a different model/effort role, use
[Worker Model Replacement And Escalation](../../../workflows/pr-processing.md#worker-model-replacement-and-escalation)
instead of cancelling the batch. Stop the old worker and capture or reconstruct
its `MODEL_REPLACEMENT_HANDOFF`. For `coordination_required`, reconcile the
claim holder/generation/instance, and start the replacement only after fencing
prevents overlap. For `coordination_not_applicable`, the one controller stops
the prior worker and starts the replacement with no claim reconciliation, no
typed event, and no backend call. For already-running
batches that need the staged route policy, use the canonical
[Model-Routing Recovery Prompt](../../../workflows/pr-processing.md#model-routing-recovery-prompt).
After the prior instance is stopped and ownership is reconciled, a
`coordination_required` lane emits `human_intervention` with `kind: supersede`
(or `kind: takeover` for abandoned ownership) when a private backend is active.

### Normal Agent-Runner Restart

For an ordinary agent-runner restart where the same lanes should resume
afterward, use the canonical
[Pausing For An Agent-Runner Restart](../../../workflows/pr-processing.md#pausing-for-an-agent-runner-restart)
prompt and its companion
[Bounded Status Recovery](../../../workflows/pr-processing.md#bounded-status-recovery)
resume steps. Preserve claims and worktrees, and do not release or cancel a lane
unless the coordinator explicitly cancels it.

### Cancellation Or Relaunch

To stop an in-flight batch — for example to relaunch it with updated skills,
workflow rules, or targets — follow the canonical
[Cancelling Or Stopping A Batch](../../../workflows/pr-processing.md#cancelling-or-stopping-a-batch)
protocol instead of waiting out claim leases. For `coordination_not_applicable`,
the one controller stops its own workers from controller-local state and records
the stopped lanes in the durable local batch record, with no cancellation
publish, `agent-coord status` poll, claim release, typed event, or backend
reconciliation before relaunch. For `coordination_required`: a coordinator or
maintainer
marks the batch or specific lanes cancelled in the selected private backend (see
[coordination-backend.md](https://github.com/shakacode/agent-workflows/blob/main/docs/coordination-backend.md)
→ **Cancellation**); workers drain at their next safe checkpoint, finishing an
in-flight target only when abandoning would leave remote state inconsistent,
then release the coordination claim and exit; wedged workers are stopped at the
process level. Restarting with updated skills requires launching fresh workers
from a checkout that already has the updated `.agents/skills/...` and
`.agents/workflows/...` files — a still-running worker keeps its old skill text.
When a worker first observes cancellation at its cooperative drain checkpoint,
that worker emits one lane-scoped typed `human_intervention` event with
`kind: drain` when the lane is `coordination_required` and the active private
coordination backend advertises typed-event support. The coordinator/operator
must not emit a duplicate for
that cooperative path. The cooperative worker path remains worker-owned at
that checkpoint; the coordinator/operator neither re-emits nor duplicates it.
Immediately before terminating a worker that cannot
reach that checkpoint, the coordinator/operator instead emits one lane-scoped
typed `human_intervention` event with `kind: drain` when the lane is
`coordination_required` and the active private coordination backend advertises
typed-event support. A `coordination_required` lane never legitimately reaches a
drain checkpoint under a trusted `coordination_backend: n/a`, because that is a
pre-launch stop; treat it as a classification violation to report, not an
emission to skip. For either drain path, an unreachable, degraded, unadvertised,
or unsupported typed-event capability records
`typed event transport: unavailable` and remains
nonblocking. For either drain path with advertised support, resolve the active
backend's advertised drain-event executable and ordered opaque argv;
reject a missing, malformed, or unsafe advertisement as an emission failure.
Run that exact executable and separate argv without shell evaluation, with a
finite deadline in its own process group, preserving each opaque argument; on
expiry terminate the whole group with `TERM`, then `KILL` after a finite grace
period. No `agent-coord` compatibility or generic private typed-event transport
is required. A deadline expiry, forced termination, or any other
advertised-support emission failure records best-effort `UNKNOWN` evidence; the
worker continues its cooperative drain and claim release, while the
coordinator/operator hard-escape path proceeds immediately to worker process
termination and claim release, without waiting further on the drain event.
