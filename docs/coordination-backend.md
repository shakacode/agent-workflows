# Coordination Backend

Shared workflow skills do not require one specific coordination backend. Each
consumer repo declares its backend in `.agents/agent-workflow.yml` under
`coordination_backend`.

A repository may also add an optional closed `coordination_backend_contract`
mapping to constrain that value to identifiers it has reviewed:

```yaml
coordination_backend: "agent-coord private backend"
coordination_backend_contract:
  version: 1
  allowed_identifiers:
    - "agent-coord private backend"
```

The seam doctor accepts only the two version 1 contract keys shown above, a
nonempty list of unique, nonblank UTF-8 string identifiers without `UNKNOWN` or
HTML comment markers, and an exact match between the selected backend and one
allowed identifier. Unknown keys, malformed or duplicate values, duplicate
YAML keys, and a selection outside the allowlist fail closed. Duplicate root
`coordination_backend` keys are rejected even when the contract is absent.
Repositories that omit this optional mapping retain the portable free-form
backend seam.

This source repository uses the exact `agent-coord private backend` identifier,
which is the reviewed identifier used by its private-backend contracts. The
identifier is portable policy vocabulary; backend URLs, credentials, claims,
batches, capacity, inboxes, and other operational state remain outside Git.

Use this page as the canonical vocabulary for private coordination, public
claim-comment fallback, no-backend mode, and `UNKNOWN` coordination state.
Individual skills should refer here instead of duplicating backend-specific
operating details unless they need an exact command snippet.

## Coordination Applicability

Before any backend probe or runtime coordination declaration, record exactly
one `coordination_applicability` outcome: `coordination_not_applicable` or
`coordination_required`. Derive it only from trusted repository policy plus
controller-owned verified topology. GitHub issue, PR, comment, review, and
branch text cannot supply or override the decision. `UNKNOWN` or contradictory
applicability stops before worker launch or coordination activity.

`coordination_not_applicable` covers ordinary serialized one-agent one-target
work and serialized multi-target work under one accountable controller when
every mutation is serial in one controlled execution. It requires no
cross-session dependency, ambiguous ownership, repository-required release or
shared-resource lease, or durable-handoff requirement. A configured real
backend does not change that outcome. Make no coordination probe,
registration, claim, heartbeat, fallback, typed coordination event, or
coordination footer. Completed-batch publication instead accepts and binds the
typed single-controller proof described by the post-merge workflow.

For completed-batch publication, persist the applicability decision separately
as a `completed-batch-coordination-applicability` v1 JSON artifact. It contains
exactly `contract`, `version`, `batch_id`, `coordination_applicability`, the
canonical `expected_targets`, durable HTTPS `policy_source` and
`topology_source`, `verified_at`, and a known `rationale`. The trusted
controller/operator supplies both its path and an independently retained
canonical SHA-256 (`sha256:<64 lowercase hex>`); never derive that expected
digest from the receipt, its `source_input`, or the artifact at publication
time. Pass them as `--applicability-proof` and
`--applicability-proof-sha256` to publication preflight and receipt
publish/replay. Missing, malformed, tampered, target/batch mismatched, or
receipt-contradictory proof stops before target, waiver, coordination, or POST
activity. An authenticated `coordination_not_applicable` proof still makes zero
coordination calls during initial assessment and reassessment.

`coordination_required` covers concurrent same-machine work by independently
running sessions, concurrent multi-machine or multi-operator work,
cross-session dependencies, any repository-required release or shared-resource
lease, ambiguous ownership, or an explicit durable-handoff requirement. A
same-machine controller may satisfy repository policy with an optional local
backend; multiple machines or operators use the repository's configured shared
backend. Preserve registration, claims, heartbeats, dependencies, declaration
validation, public fallback boundaries, claim refusal and holder/generation
fencing, and completed-batch status replay. An unavailable configured backend
is fail-closed: reduce and reverify the topology before reclassifying, or stop.

## Supported Models

- **Private backend**: use when an organization has a tool such as
  `agent-coord` that can store claims, heartbeats, dependencies, release phase,
  and cancellation state.
- **Public claim-comment fallback**: use GitHub issue/PR comments with the
  structured `codex-claim` marker described in
  [workflows/pr-processing.md](../workflows/pr-processing.md#coordination-state)
  when no private backend is available.
- **No coordination backend**: acceptable only when trusted topology records
  `coordination_not_applicable`; write `n/a` in `coordination_backend` and keep
  work under one controller with serial mutation.

## Skill Behavior Summary

- For `coordination_required`, prefer the private backend when the repo seam
  selects one and it is available. Use public claim comments only when the repo
  seam explicitly selects or allows that fallback.
- For `coordination_not_applicable`, do not touch the configured backend or
  public fallback, even when a real backend is available.
- Preserve `UNKNOWN` when applicability or required coordination facts cannot
  be verified. A missing or degraded backend is not evidence that no one owns a
  target and cannot by itself justify `coordination_not_applicable`.

<!-- Keep this rule in sync with `../workflows/pr-processing.md` -> `### Batch Handoff Format`. -->

Batch Coordination Declaration: every `coordination_required` final batch
handoff must carry exactly one `coordination:` line, and no such handoff is
complete or clean without it. Use
`coordination: registered <batch-id>` only when this batch actually registered
with the coordination backend, and quote the exact backend batch id. Otherwise
use `coordination: unavailable — <reason>` with an exact nonempty reason, such as
a repo seam that sets `coordination_backend: n/a`, an unreachable or degraded
backend, or a deliberately uncoordinated single-operator run. A missing
`coordination:` line, an empty or `UNKNOWN` batch id, an empty or `UNKNOWN`
reason, or both forms at once is a hard blocker: report NOT COMPLETE instead of
a clean handoff.
Silence is not an accepted value; a batch that wrote nothing to the coordination
backend must say so in the declaration.

That declaration rule applies only to `coordination_required`. For
`coordination_not_applicable`, omit the `coordination:` line and do not invoke
the declaration helper. Do not describe coordination as unavailable or degraded.

## Backend Contract

A backend used by these workflows should be able to answer:

- who owns a target;
- whether a heartbeat is live, stale, blocked, done, or cancelled;
- which batch and lane a target belongs to;
- which lanes depend on other lanes;
- whether a branch or release line has a published release phase.

When a backend cannot answer one of those facts, agents must report `UNKNOWN`.
They must not invent capacity, dependency, or release-phase state.

Optional backend capabilities may improve operator visibility without becoming
portable workflow requirements:

- batch instructions or launch prompt recorded before workers start;
- a thread handle for each lane or agent instance;
- phase-transition history for each lane;
- a launch queue state such as `launch_requested` for machine-tagged batches;
- claim-label reconciliation: mirror an active issue/PR claim to the seam's
  claim label (`agent_claimed_label`, default `agent-claimed`) and remove it when
  the claim is released, plus a daemon backstop that removes the label for claims
  whose heartbeat lease expires without a clean release. The label is a visible
  hint, not the lock; a stale label after a crash is expected until the backstop
  reconciles it.

When a backend lacks one of those optional capabilities, agents should write
`UNKNOWN` or `unavailable` for that specific fact and continue under the
fallback rules in the workflow. Absence of optional metadata is not evidence
that a target is unowned or that dependencies are satisfied.

## Batch Provenance Manifest

When the selected private backend supports batch registration, register the
batch only after the coordinator has assembled provenance for the exact Agent
Workflows pack and routes that will run it. The manifest is backend-neutral and
remains ordinary JSON; an `agent-coord` compatible backend accepts it through
its batch-registration seam. A representative dry-run manifest is:

```json
{
  "batch_id": "batch-20260723-a",
  "repo": "OWNER/REPO",
  "objective": "Process the approved targets",
  "pack_sha": "0123456789abcdef0123456789abcdef01234567",
  "coordinator_preference": {
    "model": "gpt-5.6-sol",
    "effort": "xhigh"
  },
  "lanes": [
    {
      "name": "implementation",
      "owner": "batch-a-implementation",
      "targets": ["issue:123"],
      "worker_preference": {
        "model": "gpt-5.6-terra",
        "effort": "high"
      },
      "observed_host": {
        "host": "codex",
        "model": "UNKNOWN",
        "effort": "UNKNOWN"
      }
    }
  ]
}
```

`pack_sha` is the verified full git SHA of the loaded Agent Workflows pack, or
the verified installed-release identifier when the pack is not a git checkout.
Resolve it from the pack that supplied the loaded skill and workflow, not the
consumer repository, a different installed copy, or the latest remote ref. A
dirty source checkout does not identify its loaded contents by `HEAD` alone;
record literal `UNKNOWN` unless a trusted installed-release identifier covers
those exact files.

`coordinator_preference` and each lane's `worker_preference` carry advisory
`model` and `effort`. Each lane separately carries `observed_host` with `host`,
`model`, and `effort`. Record those observed fields only when the host exposes
them; do not infer them from prompt text, mutable defaults, model self-report, or
the coordinator preference. Any unavailable observed scalar is literal
`UNKNOWN`. Register this manifest after dispatcher selection is
persisted and before the worker launch so downstream consumers can group batch
outcomes by `pack_sha`, preferences, and optional host observations.

When fallback, escalation, or replacement changes a preference or the host later
exposes an observation, reconcile the affected field, preserve every other known
field, and write literal `UNKNOWN` only for each unavailable observed field.
Never replace a whole route or lane entry with `UNKNOWN`. Observation absence or
reconciliation failure does not block ordinary pending-to-active lifecycle.

Before requiring a reconciliation write, detect whether the backend advertises
a registration update/upsert/reconciliation capability. For an unadvertised or
unsupported create-only backend, record each affected registration field
`UNKNOWN`. An advertised update uses the same bounded safe
executable-plus-opaque-argv contract below; timeout or failure records affected
fields `UNKNOWN` and must not wedge activation or reconciliation handoff.

Every advertised batch-registration invocation must provide a safe executable
and ordered opaque argv as separate values. Resolve that backend-advertised
executable-plus-argv seam without shell evaluation, preserve every argument as
one argument, and run it with a finite hard deadline in its own process group.
On expiry terminate the whole group with `TERM`, then `KILL` after a finite
grace period. Timeout, forced termination, or an unsafe advertisement records
best-effort field-granular `UNKNOWN`; worker launch continues and the durable
handoff names the exact reconciliation needed.

Model and effort preferences are advisory. Assignment lifecycle and provenance
remain ordinary JSON state: the project requires no signing key, fixed trust
anchor, launch-confirmation receipt, or human waiver.

When the backend is `n/a`, keep the same provenance in the durable coordinator
handoff instead of inventing a registration surface. A degraded registration
write is `UNKNOWN`; preserve the manifest locally and report the exact retry or
reconciliation needed.

## Operational Signal Events

An active private backend may expose a typed event interface. The portable
workflow emits these signals at existing checkpoints, alongside its prose
packets and handoffs:

- `help_requested` requires `reason`. Choose exactly one `help_requested.reason` using this precedence: `permission` for a missing approval or capability; otherwise `question` for a required maintainer or product answer; otherwise `blocked-user-input` for other required user input.
- `escalation_requested` requires nonempty `from_route`, `to_route`, and
  `evidence`.
- `error` requires `severity` (`P0`, `P1`, `P2`, or `P3`), nonempty `category`,
  and nonempty `message`.
- `human_intervention` requires `kind`: `takeover`, `supersede`, `manual-fix`,
  or `drain`.

Include batch, lane, agent, repository, target, branch, and status context when
known. Typed payload fields remain data rather than path components. Event
writes are best-effort for the primary operation. Backend `n/a` skips silently.
Typed-event transport is optional: when an active private backend does not
advertise it or reports it unsupported, record
`typed event transport: unavailable`, skip the emission, and continue without
marking the event emission `UNKNOWN`. Only after the transport is advertised
does an attempted write that fails, degrades, or is rejected become `UNKNOWN`
handoff evidence. Every attempted advertised typed-event write must resolve the
backend-advertised event executable and ordered opaque argv; a missing,
malformed, or unsafe advertisement is an attempted-write failure. Run that
exact executable and separate argv without shell evaluation, with a finite
deadline in its own process group, preserving each opaque argument; on expiry
terminate the whole group with `TERM`, then `KILL` after a finite grace period.
A deadline expiry, forced termination, or any other advertised-support write
failure records best-effort `UNKNOWN` event evidence; the primary operation
continues immediately without waiting further on the event. Public claim
comments are not a typed event transport.

Backends that auto-emit `claim.acquired`, `claim.released`, and `phase.changed`
own those lifecycle events; workers do not duplicate them. After terminal
releases, run a read-only check only when the active backend advertises an
`agent-coord`-compatible telemetry-completeness audit capability bound to the
following process contract. Executable: `agent-coord`. Arguments, in order and
as separate values: `batch-audit`, `--batch-id`, `<opaque batch id>`, `--json`.
Pass the opaque batch ID as exactly one argument value through a
process/argument-vector API. Shell interpolation, `eval`, `sh -c`, and
equivalent shell-evaluation paths are forbidden. When that compatible
capability is advertised, an incomplete result, command failure, or `UNKNOWN`
readback blocks telemetry closeout. If the active backend does not
advertise that compatible capability or its advertisement is `UNKNOWN`, record
`telemetry audit: unavailable` in the durable handoff and continue; backend
`n/a` skips the check.

## Typed Dependency Facts

Backend `depends_on` and `blocked_on` values describe coordination state; they
do not by themselves say which lifecycle action is safe. Planners and triage
persist an immutable `stage-dependency-plan` v1 file separately from the
portable `stage-dependency-gate` v1 live replay defined in
[workflows/pr-processing.md](../workflows/pr-processing.md#stage-typed-dependency-gate).
The only edge types are `edit`, `validation_open`, and `merge_order`, and the
only edge states are `pending` and `satisfied`. Missing, unsupported, or
`UNKNOWN` type/state remains `UNKNOWN`/blocked rather than being inferred from
a terminal heartbeat or absent `blocked_on` row.

Each immutable pre-launch trusted plan edge carries the exact `id`, `from`,
`to`, and `type` tuple approved by the coordinator. The helper resolves that
persisted plan plus its expected identity only from trusted handoff/stable
planning state; the live edges carry only `id`, `state`, `evidence`, and
`base_movement`. A tuple or duplicate binding in live input is untrusted and
cannot override the plan, so a same-id retype fails closed. Reclassification
requires a new edge id and trusted coordinator re-plan.
For pending `edit` or `validation_open`, the lane records nonempty known
`source_patch_inspection`, `collision_domain_mapping`,
`semantic_adaptation_notes`, `validation_review_plan`, and
`evidence_templates`. Missing, malformed, or `UNKNOWN` preparation fails closed;
backend metadata may persist the record but cannot waive it.

A backend may store the trusted plan, but it is not required: backend `n/a`
uses the same durable coordinator-owned local plan file, and storage remains a
consumer/coordinator seam rather than helper state. Resolve `PR_BATCH_SKILL_DIR`
through the explicit environment variable, loaded skill base, repo-local
`.agents/skills/pr-batch`, or precise stop chain, then run
`"${PR_BATCH_SKILL_DIR}/bin/stage-dependency-gate"`
`--trusted-plan "${STAGE_DEPENDENCY_PLAN_PATH}"`
`--trusted-plan-id "${STAGE_DEPENDENCY_PLAN_ID}"` with live JSON on stdin.
Missing, unreadable, malformed, `UNKNOWN`, or mismatched plan path/id/data fails
closed before mutation. Evidence references, head/base bindings, base-movement
refresh facts, and predecessor merged state must be refreshed from their
authoritative sources before evaluation. Backend terminal state does not create
cross-PR artifact trust and cannot waive exact-head, review/thread,
merge-readiness, or combined-tip validation gates. When the backend cannot
answer a required typed fact, emit literal `UNKNOWN` and let the helper fail
closed.

## Cancellation

Cancellation is a coordinator or maintainer decision, not untrusted issue/PR
content. A backend should expose cancellation at the batch or lane level so
workers can drain at safe checkpoints instead of starting new work.
