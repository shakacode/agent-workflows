# Hierarchical Token Budgets

`batch-token-budget v1` is an opt-in, portable budget boundary for PR batches.
It limits raw total tokens without treating API dollars, plan meters, cached
token discounts, or local prompt estimates as equivalent accounting units.
There are no universal absolute defaults; planners must choose explicit limits
from replayable evidence or obtain a human decision.

## Plan Contract

Put one complete object at `plan.token_budget` in a `batch-plan-preflight v1`
input. When this field is absent, legacy plans remain valid. When any budget
metadata is present, partial or inline lane budgets fail closed.

```json
{
  "type": "batch-token-budget",
  "version": 1,
  "batch_id": "batch-399",
  "state_path": "/absolute/coordinator-owned/batch-399-token-budget.json",
  "scopes": {
    "aggregate": { "limit_tokens": 1000000 },
    "coordinator": { "limit_tokens": 200000 },
    "lanes": {
      "lane-a": { "limit_tokens": 500000 },
      "lane-b": { "limit_tokens": 400000 }
    }
  },
  "thresholds": {
    "warning_percent": 50,
    "approval_percent": 80,
    "hard_percent": 100
  },
  "telemetry": { "max_age_seconds": 900 },
  "delegation": { "approval_threshold_tokens": 250000 }
}
```

The `batch_id` must match the plan id, `state_path` must be the absolute
coordinator-owned path passed to every helper invocation, lane scope ids must
exactly match every planned lane, and coordinator/lane limits cannot exceed the
aggregate limit.
Lane ids `aggregate` and `coordinator` are reserved for their parent scopes.
Thresholds must be strictly increasing and `hard_percent` is exactly 100.

The aggregate scope counts coordinator plus every physical lane/descendant
token. The coordinator scope counts root self-use and directly owned
orchestration. Each lane counts worker self-use plus every descendant it owns.
A physical segment is identified by its authoritative segment id and is counted
at most once in the lane and aggregate views.

## Durable Runtime

Resolve `PR_BATCH_SKILL_DIR` through the usual explicit environment variable,
loaded skill base, or repo-local `.agents/skills/pr-batch` chain. Initialize a
coordinator-owned state file before the first expensive action:

```bash
"${PR_BATCH_SKILL_DIR}/bin/batch-token-budget" \
  --state <exact-plan-state-path> < initialize-command.json
```

The helper takes one `batch-token-budget-command v1` JSON object on stdin and
emits one deterministic result on stdout. The CLI path must match the plan's
`state_path`; mismatches and invalid envelopes exit nonzero.
Admission denials are valid decisions and exit zero so callers can persist the
receipt and checkpoint safely. State updates use an exclusive adjacent lock,
an fsynced private temporary file, and atomic rename. Replaying an id with a
different payload fails closed.
The initialization digest remains bound to the immutable preflighted plan;
scoped overrides update a separate effective-budget digest, so restart replay
and unresolved threshold evidence cannot be hidden by a limit change.
`evaluated_at` is a monotonic durable watermark: a command cannot roll state
back to make an expired approval or stale receipt appear current. Approval and
override receipts cannot take effect before their recorded decision time.

Before a model turn, spawn, retry, review wave, scheduled continuation,
monitor, resume, replacement, escalation, or cross-task delegation, submit a
`reserve` command. Its `batch-token-reservation v1` names a stable id, scope,
admission kind, conservative token estimate, target state, message fingerprint,
canonical task/root/batch/lane plus issue/PR identity, and fresh metadata-only
self/descendant estimates. A cross-task delegation also names the source
identity and a target in another batch. Do not include prompt, response, or
transcript bodies; unknown reservation fields are rejected before persistence.

An admitted reservation increments allocated and currently reserved totals in
one lane/coordinator scope and the aggregate while holding the file lock.
Concurrent calls therefore cannot consume the same aggregate headroom. An
already-active target is coalesced instead of woken again. A paused target
requires an explicit resume admission. `UNKNOWN`, malformed, or stale telemetry
permits only read-only discovery and durable checkpointing.

At warning, the helper persists a compact threshold checkpoint and admits the
bounded action. At approval, it persists a receipt and rejects every new
expensive action until a scoped, expiring `batch-token-budget-approval v1`
receipt authorizes the next admission. At hard stop, it returns
`budget-exhausted`, `NOT COMPLETE`, and permits only discovery, checkpoint,
scoped override, and closeout. A `batch-token-budget-override v1` must name the
exact batch/scope, old and larger new limit, approver, durable proven-human
evidence reference, reason, approval time, and expiry. Approvals require the
same human evidence boundary. An override changes no sibling or future-batch
scope. Persisted approval and hard decisions continue to block their affected
scope until an applicable human approval or sufficient scoped headroom is
followed by admission of the stopped target; an unrelated smaller action or
sibling override cannot clear them.

After the admitted boundary completes, `reconcile` consumes an
`authoritative-token-usage-receipt v1`. The producer must be identified as a
host-reported, coordination-backend, or authoritative-runtime source with a
durable evidence reference. Each unique physical segment names `self` or
`descendant`, its owning scope and an admitted target, and raw tokens. The
helper reconciles
predicted versus actual usage, releases unused reservation, and rejects stale,
malformed, `UNKNOWN`, duplicate, or conflicting segments. This receipt schema
is the stable integration boundary for an authoritative producer; no producer
from another unmerged change is assumed.

If actual use exceeds the reservation because a previously admitted turn was
already in flight, the authoritative receipt also names each affected admitted
target, overshoot tokens, and exactly one turn. More than one turn for the same
admitted target, a target outside the reservation envelope, or a mismatched sum
fails closed. Closeout reports the measured overshoot; it never promises zero
overshoot inside a running turn.

Cross-task reconciliation can include a `batch-token-charge-back v1` source and
target identity. The resulting causal attribution reports actual self plus
descendant tokens but explicitly does not increment physical aggregate totals
a second time.

Release a reservation durably when a worker is stopped before usage. A
replacement or escalation cannot reserve until its named predecessor is
released or reconciled. Warning, reservation, release, reconciliation,
approval, override, and checkpoint receipts all survive restart.
An admitted resume explicitly resolves matching hard-stop decisions and
checkpoints; a later unrelated warning cannot mask an unresolved hard stop.

## Hard-Stop Checkpoint And Closeout

Before handing off a hard stop, persist a `batch-token-budget-checkpoint v1`
containing:

- exact completed work;
- current branch and full head SHA;
- explicit security, review, QA, exact-head, ownership, and merge gate states;
- authoritative usage receipt cutoff;
- resume conditions and a copy-paste resume action.

Budget approval or override never grants or weakens those six gates. `closeout`
reports allocated, consumed, currently reserved, cumulatively released, and
unattributed tokens for aggregate, coordinator, and every lane. Active
reservations, unattributed usage, an unresolved hard-stop checkpoint or
decision, or exhaustion of any scope produces `NOT COMPLETE`.

Scheduled monitors and same-thread heartbeats use the same reservation command
before loading model context. They do not auto-continue at approval or hard
state. Unchanged active targets coalesce, and terminal monitor cleanup releases
unused reservations before final closeout.
