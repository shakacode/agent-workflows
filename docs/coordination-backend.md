# Coordination Backend

Shared workflow skills do not require one specific coordination backend. Each
consumer repo declares its backend in `.agents/agent-workflow.yml` under
`coordination_backend`.

Use this page as the canonical vocabulary for private coordination, public
claim-comment fallback, no-backend mode, and `UNKNOWN` coordination state.
Individual skills should refer here instead of duplicating backend-specific
operating details unless they need an exact command snippet.

## Supported Models

- **Private backend**: use when an organization has a tool such as
  `agent-coord` that can store claims, heartbeats, dependencies, release phase,
  and cancellation state.
- **Public claim-comment fallback**: use GitHub issue/PR comments with the
  structured `codex-claim` marker described in
  [workflows/pr-processing.md](../workflows/pr-processing.md#coordination-state)
  when no private backend is available.
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

<!-- Keep this rule in sync with `../workflows/pr-processing.md` -> `### Batch Handoff Format`. -->

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
  "coordinator_route": {
    "model": "gpt-5.6-sol",
    "effort": "xhigh",
    "binding_source": "instance-bound-runtime-metadata"
  },
  "lanes": [
    {
      "name": "implementation",
      "owner": "batch-a-implementation",
      "targets": ["issue:123"],
      "host": "codex",
      "worker_route": {
        "model": "gpt-5.6-terra",
        "effort": "high",
        "binding_source": "dispatcher-bound"
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

`coordinator_route` and each lane's `worker_route` carry `model`, `effort`, and
`binding_source`. Each lane also carries its actual host (`codex`, `claude`, or
another verified host identifier). Take route and binding values from launch
assurance and the persisted dispatcher selection; do not infer them from prompt
text, mutable defaults, or the coordinator's route. Any unverifiable scalar is
literal `UNKNOWN`. Register this manifest after dispatcher selection is
persisted and before the worker launch so downstream consumers can group batch
outcomes by `pack_sha`, coordinator route, worker route, and host.

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
writes are best-effort for the primary operation: backend `n/a` skips silently,
while degraded, unavailable, or rejected writes become `UNKNOWN` handoff
evidence. Public claim comments are not a typed event transport.

Backends that auto-emit `claim.acquired`, `claim.released`, and `phase.changed`
own those lifecycle events; workers do not duplicate them. After terminal
releases, the coordinator runs the backend's read-only telemetry-completeness
check. An `agent-coord` compatible backend exposes this as
`agent-coord batch-audit --batch-id <id> --json`; incomplete or `UNKNOWN`
coverage blocks telemetry
closeout, while backend `n/a` skips the check.

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
