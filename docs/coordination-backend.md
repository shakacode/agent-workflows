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

PR-batch consumes those modes through the stable
[Coordination And Observability](../workflows/pr-batch-coordination-observability.md)
adapter. That component owns target-scoped ownership, liveness, capacity,
monitoring, recovery, and telemetry behavior without turning this backend into
an authority system.

## Supported Models

- **Private backend**: use when an organization has a tool such as
  `agent-coord` that can store claims, heartbeats, dependencies, release phase,
  and cancellation state.
- **Public claim-comment fallback**: use GitHub issue/PR comments with the
  structured `codex-claim` marker below when no private backend is available
  and repository policy permits the fallback.
- **No coordination backend**: acceptable for single-agent work; write `n/a` in
  `coordination_backend` and keep batch guidance serial or explicitly low
  concurrency.

## Skill Behavior Summary

- Prefer the private backend when the repo seam selects one and it is available.
- Use public claim comments only when the repo seam explicitly selects or allows
  that fallback.
- In no-backend mode, avoid concurrent workers on the same target and describe
  the run as single-operator or serial.
- Preserve `UNKNOWN` when coordination facts cannot be verified. A missing or
  degraded backend is not evidence that no one owns a target.

## Public Claim Comment Fallback

Use one advisory public claim when trusted configuration selects this fallback,
or after the private claim cannot start or definitively fails with a non-timeout
setup or authentication error and repository policy permits fallback. A timeout
or private claim refusal never permits fallback. Before posting, inspect recent
comments for an unexpired marker on the same target. Before switching from
private mode, reconcile private ownership or use a trusted cross-mode mirror.
If reconciliation is unavailable, stop the affected lane. Only a marker backed
by authenticated and authorized ownership evidence is conflicting. A marker
proven malformed or unauthorized remains advisory; an unavailable or
incomplete verification remains `UNKNOWN` and blocks the affected action. Report the
inspected marker's comment URL and classification as handoff evidence.

Among verified markers, only one owned by a different lane or instance is
conflicting. A marker whose batch, machine, stable, non-`unavailable` thread,
and branch all match is that lane's renewable marker; refresh the same comment.
A marker with `thread: unavailable` cannot be self-renewed because its worker
instance is ambiguous. Any ambiguous identity remains `UNKNOWN` and blocks the
affected lane.

That evidence requires concrete author-and-marker verification from
field-selected GitHub API metadata: the API must return a nonempty author login
that passes the security floor's resolved trust policy under `trusted_users`,
`trusted_bots`, or `trusted_teams`; the comment must contain exactly one
well-formed marker on the target's own issue or PR surface; and every identity
field must be nonempty, `status` must be `in_progress`, and `expires_at` must be
in the future. A comment body alone never qualifies.

The packaged fallback intentionally trusts no users, actionable bots, or teams.
A repository that selects public fallback for mutating work must configure each
claim-authoring human or automation identity under `trusted_users`,
`trusted_bots`, or `trusted_teams` in its repo-local or user-global trust config.
Without that entry, verification is `UNKNOWN`: the lane cannot post or renew an
actionable claim and must not mutate through this mode. Matching marker fields
never bypass author trust.

```markdown
<!-- codex-claim v1
batch: <BATCH_ID>
machine: <MACHINE_ID>
thread: <stable-session-or-thread-id>
branch: <BRANCH_NAME>
status: in_progress
expires_at: <ISO8601_UTC>
-->
```

Use a stable session or thread identifier that distinguishes the active worker
instance. If none exists, use `thread: unavailable`; it may advertise ownership
but cannot prove self-identity for renewal. Use a bounded advisory
expiry, usually 2-4 hours for an active batch and no later than the known batch
window. Refresh the same comment when the lane continues beyond that window.
This comment is a human-visible hint only:
it cannot override a private refusal, express cancellation, prove terminal
state, or grant scope or authority. Ad-hoc targets have no issue or PR comment
surface and therefore cannot use this fallback.

<!-- Keep this rule in sync with `../workflows/pr-processing.md` -> `### Batch Handoff Format`. -->

## Batch Coordination Declaration

Batch Coordination Declaration: every final batch handoff must carry exactly one
`coordination:` line, and no handoff is complete or clean without it. Use
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

| Checkpoint | Typed event | Required fields |
| ---------- | ----------- | --------------- |
| help-needed pause | `help_requested` | `reason` |
| model escalation request | `escalation_requested` | `from_route`, `to_route`, `evidence` |
| human intervention | `human_intervention` | `kind` |
| serious error | `error` | `severity`, `category`, `message` |

Every required event field must contain a nonempty usable value. When one is
unavailable, do not emit an invalid event; record
`UNKNOWN (missing required event field: <field>)` and preserve the prose
handoff.

Choose exactly one `help_requested.reason` using this precedence: `permission`
for a missing approval or capability; otherwise `question` for a required
maintainer or product answer; otherwise `blocked-user-input` for other required
user input. `severity` is `P0`, `P1`, `P2`, or `P3`; intervention `kind` is
`takeover`, `supersede`, `manual-fix`, or `drain`.

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
equivalent shell-evaluation paths are forbidden. Run that exact child contract
through the resolved pr-batch `bin/agent-coord-bounded` process-control seam
with a positive hard deadline; the helper must preserve the exact child
executable and separate argument vector, launch it in its own process group,
and terminate the whole process group when the deadline expires. A timeout or
forced termination is a command failure: record best-effort `UNKNOWN`
telemetry-audit evidence and continue closeout through the remaining steps with
that blocker; the audit subprocess must never wedge merge closeout. When that
compatible capability is advertised, an incomplete result, command failure,
or `UNKNOWN` readback blocks telemetry closeout. This blocks only a clean
telemetry-audit disposition until the coordinator repairs or explicitly carries
the gap; it does not stop the surrounding merge-closeout steps. If the active
backend does not advertise that compatible capability or its advertisement is `UNKNOWN`, record
`telemetry audit: unavailable` in the durable handoff and continue; backend
`n/a` skips the check.

## Directional Workflow Telemetry Report

Use `skills/pr-batch/bin/workflow-telemetry-report` for the smallest replayable
throughput view built from existing durable coordination and GitHub-shaped
metadata. It is a reducer, not a collector or accounting ledger: callers first
normalize field-selected timestamps, identifiers, counts, and durable source
references into `workflow-telemetry-input` v1. The helper does not invoke GitHub,
read rollout/session content, inspect the environment, or create backend state.

The replay fixture at
`skills/pr-batch/fixtures/workflow-telemetry-report-replay.json` is the canonical
input example. It covers:

- prompt-to-worker-start latency and the model/workflow version observed at each
  boundary;
- broad `planning`, `discovery`, `implementation`, `validation`, `review`, and
  `integration` phase time;
- human-question count, answered count, and queue time;
- `occupied` and `stopped` slot time;
- review, CI, and retry attempts;
- integration time; and
- consequential defects, reverts, and rollbacks.

Phase, human-question queue, and slot totals are cumulative across the supplied
lane intervals, not elapsed critical-path time. Concurrent work can therefore
make these totals exceed wall-clock duration. In particular,
`phase_seconds.integration` is cumulative time that lanes spent in the broad
integration phase. The separate `integration_seconds` measure is the elapsed
time across the single batch-level `integration.started_at` to
`integration.ended_at` window selected by the normalizer; callers must not
treat the two measures as interchangeable.

Every unavailable timestamp, identifier, or count in the normalized input is
literal `UNKNOWN`. Derived duration totals also become literal `UNKNOWN` when
any contributing boundary is unavailable; a known partial total is never
presented as the complete measure. Absent phase or slot rows likewise report
`UNKNOWN`, while a present zero-length phase or slot interval reports known
zero. Use literal `UNKNOWN` for an unavailable human-question collection; an
explicitly empty question list instead reports a known count and queue time of
zero. Fixed-shape amplification, integration, and outcome objects remain
present; mark unavailable leaves `UNKNOWN` so known siblings remain reportable.
The JSON report lists every propagated unknown in `unknown_fields`, including
unavailable top-level identifiers such as `batch_id` or `source_ref`.

The input is closed and metadata-only. Unknown fields are rejected, identifier
and source-reference values use constrained grammars, and opaque batch IDs use
a closed no-whitespace grammar that retains coordination delimiters such as `;`
and `=` while rejecting whitespace and unapproved punctuation. Common
token-shaped content is rejected even inside an allowlisted identifier. There
is no field for a raw
prompt, response, transcript, tool result, secret, environment value, auth
content, or arbitrary prose. The structural grammars are defense in depth, not
semantic declassification: callers must never derive identifier values from
raw prose. Do not add a prose field; retain durable evidence by reference and
query only the exact upstream fields needed for normalization.
The reducer reads at most one MiB of input and accepts at most 4,096 entries in
each interval or question array. Timestamps require a known explicit RFC 3339
offset and accept at most nine fractional-second digits; `-00:00` is rejected
because it denotes an unknown local offset.

Replay JSON or a compact twelve-line text view without copying the source
events into the result:

```bash
skills/pr-batch/bin/workflow-telemetry-report \
  --input skills/pr-batch/fixtures/workflow-telemetry-report-replay.json \
  --format json

skills/pr-batch/bin/workflow-telemetry-report \
  --input skills/pr-batch/fixtures/workflow-telemetry-report-replay.json \
  --format text
```

Use the report directionally to find latency, queueing, slot pressure, and
amplification worth investigating. It does not authorize exact token/cost
accounting, adaptive scheduling, experiments, or an exhaustive collection
layer, and it never replaces readiness, QA, review, CI, or closeout evidence.

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
