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
  "delegation": { "approval_threshold_tokens": 250000 },
  "trusted_verifiers": [{
    "id": "budget-approval-coordinator",
    "algorithm": "rsa-pss-sha256",
    "public_key_pem": "-----BEGIN PUBLIC KEY-----\n<canonical RSA public key, at least 2048 bits>\n-----END PUBLIC KEY-----\n"
  }]
}
```

Persist that exact canonical object separately as the trusted runtime plan and
record its coordinator-selected binding next to `plan.token_budget`:

```json
"token_budget_anchor": {
  "trusted_plan_path": "/absolute/coordinator-owned/batch-399-token-budget-plan.json",
  "trusted_plan_id": "batch-399",
  "trusted_plan_digest": "sha256:<canonical batch-token-budget object digest>"
}
```

The `batch_id` must match the plan id, `state_path` must be the absolute
coordinator-owned path passed to every helper invocation, lane scope ids must
exactly match every planned lane, and coordinator/lane limits cannot exceed the
aggregate limit. The trusted plan and mutable state must be distinct canonical
artifacts; equal expanded paths, resolvable aliases, or ancestor/file identity
collisions fail closed.
Lane ids `aggregate` and `coordinator` are reserved for their parent scopes.
Thresholds must be strictly increasing and `hard_percent` is exactly 100.
`trusted_verifiers` is a nonempty exact allowlist of unique verifier ids and
canonical public keys. Verifier ids and canonical public-key fingerprints must
both be unique. Version 1 supports only `rsa-pss-sha256` with RSA keys of at
least 2048 bits. The matching private key stays outside the plan and durable
state; consumer-specific key custody and signing commands resolve through the
consumer's `AGENTS.md` seams.

The aggregate scope counts coordinator plus every physical lane/descendant
token. The coordinator scope counts root self-use and directly owned
orchestration. Each lane counts worker self-use plus every descendant it owns.
The accounting boundary is an atomic half-open `batch-usage-receipt-v1`
window. The receipt's batch descendant-inclusive total is counted once in the
aggregate view; coordinator self-only plus batch unattributed tokens form the
coordinator view, and each lane's descendant-inclusive total forms that lane's
view. Those views must recompute to the batch total exactly.

## Durable Runtime

Resolve `PR_BATCH_SKILL_DIR` through the usual explicit environment variable,
loaded skill base, or repo-local `.agents/skills/pr-batch` chain. Initialize a
coordinator-owned state file before the first expensive action:

```bash
"${PR_BATCH_SKILL_DIR}/bin/batch-token-budget" \
  --state <exact-plan-state-path> \
  --trusted-plan <exact-token-budget-plan-path> \
  --trusted-plan-id <exact-batch-id> \
  --trusted-plan-digest <sha256:canonical-budget-digest> \
  < initialize-command.json
```

The helper takes one `batch-token-budget-command v1` JSON object on stdin and
emits one deterministic result on stdout. The CLI path must match the plan's
`state_path`; mismatches and invalid envelopes exit nonzero. Every operation,
including initialize, replay, closeout, and read-only result paths, reloads and
validates the same external trusted plan binding before reading or mutating
state. The coordinator-selected `--trusted-plan` path is trusted input outside
the mutable budget state: the helper cannot authenticate an arbitrary path a
caller chooses. Its guarantee is that persisted-state forgery alone cannot
replace the budget or verifier authority because every invocation must match
the separately held path, id, and canonical digest.
Admission denials are valid decisions and exit zero so callers can persist the
receipt and checkpoint safely. State updates use an exclusive adjacent lock,
an fsynced private temporary file, and atomic rename. Replaying an id with a
different payload fails closed. Exact existing-id replay is checked before
telemetry freshness, so an admitted, blocked, or coalesced decision remains
deterministic after its original telemetry ages without allocating twice or
rewriting its outcome. Every valid reservation-id outcome, including a
coalesced or blocked request, is durably fenced by its canonical request digest;
an exact replay returns the recorded decision, while later payload changes
cannot reuse that id after the target or predecessor changes state. Commands and
persisted state reject duplicate JSON object keys at every nesting level.
The external plan's canonical `state_path` is compared unconditionally with the
expanded CLI `--state` before a directory, state, or lock file is created. The
initialization command must also carry an exact budget projection equal to the
trusted plan; null, omitted, or different projections fail closed. The
initialization receipt, immutable base projection, and unique root control event
remain bound to the externally supplied immutable preflighted plan;
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
scoped override, and closeout. Approval and override commands embed a strict
`proven-human-attestation v1`; free-form `approver` or `evidence_ref` strings are
not authorization:

```json
{
  "type": "batch-token-budget-approval",
  "version": 1,
  "id": "approval-1",
  "batch_id": "batch-399",
  "scope_id": "aggregate",
  "decision": "approve-next-admission",
  "reason": "Allow one bounded admission.",
  "attestation": {
    "type": "proven-human-attestation",
    "version": 1,
    "id": "attestation-approval-1",
    "batch_id": "batch-399",
    "budget_digest": "<immutable-plan-budget-sha256>",
    "scope_id": "aggregate",
    "action": {
      "type": "approve-next-admission",
      "decision_id": "approval-1"
    },
    "actor": "<verified-human-identity>",
    "issued_at": "2026-08-12T11:58:00Z",
    "expires_at": "2026-08-12T13:00:00Z",
    "verifier_id": "budget-approval-coordinator",
    "algorithm": "rsa-pss-sha256",
    "receipt_ref": "coordination://human-decisions/approval-1",
    "signature": "<strict-base64 RSA-PSS-SHA256 signature>"
  }
}
```

The signature covers canonical JSON for every attestation field except
`signature`, including the durable receipt reference. The helper resolves the
verifier only from the freshly loaded external trusted plan and verifies
RSA-PSS-SHA256 with the pinned public key before mutation. Persisted or
caller-supplied replacement verifier material has no authority. Override attestations use action type
`increase-budget-limit` and bind their decision id plus the exact old and new
limits. Free-form `status: verified` has no authority. `UNKNOWN`, unsupported,
unlisted, wrong-key, future, expired, malformed, unsigned, mismatched, or
rebound attestations fail closed. An override changes
no sibling or future-batch scope. Persisted approval and hard decisions continue
to block their affected scope until an applicable human approval or sufficient
scoped headroom is followed by admission of the stopped target; an unrelated
smaller action or sibling override cannot clear them.

After each admitted boundary, generate a `batch-usage-receipt-v1` with the
resolved pr-batch `bin/batch-usage-receipt` helper and submit the complete
half-open window to `reconcile`. The command binds the inline receipt to its
canonical `sha256:` digest, a durable non-self-attested URI reference, and the
reservation ids that completed during the window. `file://` artifacts are read
and matched at reconcile time and revalidated on restart. Plain, `UNKNOWN`,
`self-attested://`, and `worker-self-attested://` references have no authority.

The first accepted window binds the batch id, coordinator identity/root, and
every planned lane root. Later windows must preserve those identities and begin
at the prior exclusive cutoff. Exact replay does not recount; a changed receipt
for the same window, gap, overlap, rollback, identity drift, stale/future
cutoff, digest/reference mismatch, or malformed relevant accounting fails
closed. Relevant `UNKNOWN` totals or topology also fail closed. The receipt
helper's structured `UNKNOWN` for route metadata, or a missing non-total usage
counter, may pass only when all raw total-token accounting and reconciliation
equations remain known and balanced.

Each accounting scope has at most one active reservation. Same-scope nested
work coalesces into that reservation while different lanes may run
concurrently. Every accepted window atomically shifts the scope's observed
tokens from reserved to consumed; a completed reservation releases its unused
remainder. Use beyond the reservation is measured as one already-admitted
in-flight overshoot boundary for that interval. Observed use in a scope with no
active reservation is still counted, marked unattributed, and blocks clean
closeout rather than being assigned to a target without evidence.

Cross-task reconciliation can include a `batch-token-charge-back v1` source and
target identity. The resulting causal attribution reports actual self plus
descendant tokens but explicitly does not increment physical aggregate totals
a second time. Restart validation requires a one-to-one reverse link: every
reconciled reservation naming a charge-back resolves to exactly one record with
the same reservation, source, target, and actual tokens, and every charge-back
resolves back to that reservation.

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
decision, any unresolved `approval-required` decision, or exhaustion of any
scope produces `NOT COMPLETE`. Recording an approval alone does not resolve its
stop; an explicit approved admission transition must bind the decision's
resolution before closeout can become complete.
Every state load recomputes accounting from reservation, release,
reconciliation, and accepted usage-window ledgers. Missing ledger entries or
counter mismatches are corrupt state, and `COMPLETE` additionally requires zero
reserved tokens in every scope.
The state also carries an append-only `batch-token-budget-control-event v1`
chain. Each exact typed event binds its sequence, predecessor digest, action,
external plan path/id/digest, canonical command payload, pre-state digest, and
post-state digest. A deterministic reducer starts from the external budget and
replays the unique initialization root plus every subsequent event, then
requires the reconstructed controlled projection to equal persisted state.
Restart validates that replay plus
approval/attestation, override/expiry, threshold/stop, checkpoint resolution,
reservation/fence, usage/reconciliation, charge-back, and receipt
cross-references. Inflated limits, deleted control records, missing, reordered,
rehashed, or edited events, digest changes, unknown event fields/types, replaced
final state, or orphan references fail before any command can mutate state.

Scheduled monitors and same-thread heartbeats use the same reservation command
before loading model context. They do not auto-continue at approval or hard
state. Same-scope work coalesces, and terminal monitor cleanup releases unused
reservations before final closeout.
