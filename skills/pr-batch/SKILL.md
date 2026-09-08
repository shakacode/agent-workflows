---
name: pr-batch
description: Plan and safely run one or more canonical issue, existing PR, or durably overridden ad-hoc work lanes with coordinated subagents, validation, review, and merge-readiness. Unbound direct prompts route through planning/reconciliation before implementation launch. Use when coordinating one or more implementation lanes.
argument-hint: '[task, exact issue/PR numbers, or filters]'
---

# PR Batch

For new Codex planning, resolve the advisory `astra-pilot-v1` profile from
[central routing data](../plan-pr-batch/references/model-routing-profiles.json) with the plan skill's
`bin/model-routing-profile --role <role>`. Its named preferences supersede the
GPT-5.6 recommendations below for the listed roles; those recommendations and
planning tables remain the established comparison baseline. Keep explicit user
routes, verified host support, portable fallback, and independent evidence rules.
This is an unmeasured pilot, not a measured promotion.
If a partial or pinned installation lacks the resolver or data, continue with
established or portable advisory routes; use the complete pack to access the pilot.

Run one or more PR work lanes through one canonical process. A single target is
a batch of one, not a separate workflow.

Resolve writing style before authoring human-facing prose. Run
`agent-workflow-writing-style --repo-root <trusted-repository-root> --format json`
using the resolution, provenance, warning, trusted-base, and evidence-preserving
contract in `workflows/pr-processing.md` → **Writing Style Resolution**. Apply
the guide to PR descriptions and updates, issue or PR comments, review-facing
explanations, and final handoffs. Never let style remove repository template
sections, required evidence, or machine-readable receipts.

Use `docs/coordination-backend.md` as the canonical vocabulary for private
backend, public fallback, no-backend mode, and `UNKNOWN` coordination state.

If a skill picker only exposes installed/global skills, treat this skill as an
entry point. After fetching, prefer repo-local `.agents/skills/...` and
`.agents/workflows/...` files when they exist; otherwise use the installed
shared files adjacent to this skill, especially `../../workflows/pr-processing.md`.

The completed-batch closeout validation contract requires `pr-batch` and
`post-merge-audit` from the same Agent Workflows pack revision. Its contract
test intentionally loads the production receipt parser from the sibling
`post-merge-audit` skill; an isolated pinned copy must include that companion
or stop with a precise missing-companion blocker.
Execute the receipt and archive replay through the canonical
[Completed-Batch Audit Receipt And Archive Replay](../../workflows/pr-batch-integration-closeout.md#completed-batch-audit-receipt-and-archive-replay)
component; do not mirror that policy here.

Use the trusted-base `hosted-qa-readiness` helper and the canonical hosted QA
contract in `workflows/pr-batch-integration-closeout.md`; do not reproduce or reinterpret that
contract here.

Memorable invocation:

```text
$pr-batch
Run this task as one PR lane
Run an agent batch
Run a Codex batch
Run a Claude batch
```

## User-Facing Coordination Contract

The current task is the sole user-facing coordinator. Subagents, lane workers,
reviewers, and QA agents are internal workers owned by the current task, never
separate chats whose mechanics the user must coordinate. External tasks may
send evidence or requests without gaining ownership, and automations only wake
the current task. Apply authority decisions and separate-scope routing through
the shared
[user-facing coordination contract](../../docs/user-facing-coordination.md).

For a heartbeat or monitor, a no-change wake produces no user-visible
notification. Notify only for an HST-v1 actionable material state change: a
decision or action is required, a target is ready for walkthrough or approval,
a blocker exhausted its bounded retries and needs intervention, or
closeout/archive completed; delete the heartbeat when its gate clears or
becomes durably terminal. The automation never owns the task or next action.

## Coordinator Output Contract

<!-- Keep this summary in sync with `.agents/workflows/pr-processing.md` -> `### Coordinator Output Contract`. -->

`OC-v1` bounds coordinator narration volume. Use the canonical
[Coordinator Output Contract](../../workflows/pr-processing.md#coordinator-output-contract)
instead of restating its rules here. In short: bound coordinator narration to
the five typed checkpoints `dispatch`, `pr-open`, `decision-required`,
`merge-decision`, and `final-handoff`; keep recaps delta-only, findings
single-surface, and corrections proportional; and report the shadow-only
`coordinator-narration-volume v1` marker in FYI / decisions made at closeout.
Four message kinds stay allowed outside those checkpoints and count in the
marker's `always_allowed` bucket: a direct answer, an explicitly requested
status report, a turn another contract requires the coordinator to show, and a
required safety stop.

`OC-v1` is presentation only. It relaxes no evidence, verification, or
`UNKNOWN`-honesty rule, drops no required exact string, deletes no durable copy
another contract requires, and collapses no closing structure except for the
compact terminal structure allowed for single-repo batches at or below
`compact_terminal_structure_max_lanes`; the required receipt and final
`Conversation status:` line still stay intact.

## Single-Target Mode

Use this mode for one GitHub issue, existing pull request, or durably overridden
direct-prompt task after the Canonical Launch Target Gate passes. It keeps
the same security, coordination, validation, review, QA, readiness, handoff, and
closeout gates as a multi-target batch; only batch packing and collision analysis
collapse to one lane.

### Prompt Intake

Load the canonical
[PR-Batch Prompt Intake](../../workflows/pr-batch-intake.md) component before
any branch creation, editing, coordination mutation, or worker dispatch. It is
the sole owner of canonical target v1, durable override provenance, trust
handoff, short-invocation expansion, duplicate handling, and the verified
intake facts consumed below. Do not restate or reinterpret that contract here.

<!-- stage-reference: references/launch.md -->
### Single-Target Launch

Before launching an accepted lane, bind dispatch, routes, authority and preflight evidence. Read [Launch](references/launch.md) for this stage.
<!-- /stage-reference -->

## Shared Security Floor

Load the canonical
[PR-Batch Security Floor](../../workflows/pr-batch-security-floor.md) before
planning mutations, worker launch, execution from a PR branch, integration, or
any consequential action. It is the sole owner of the untrusted-input,
least-privilege, protected-base, isolated-writer, exact-head evidence,
authority, live-ownership, and independent-review invariants, plus the
`pr-security-preflight` and trust-config adapter. Preserve its
`security-floor v1` result; do not restate or reinterpret the rules here.

Repository-specific commands and policy still resolve through `AGENTS.md` and
`.agents/agent-workflow.yml`. A security-floor pass permits only the requested
stage and never grants merge, deployment, release, destructive-action, secret,
permission, or security-boundary authority.

## Required Interview

Complete the canonical [prompt-intake interview](../../workflows/pr-batch-intake.md#short-invocation-expansion)
first. Ask only for missing data and consume its verified target, trust, mode,
authority, and completion facts unchanged.

This execution skill adds only batch-shaping details that intake does not own:

1. **Batch title**: consume canonical
   [Verified Batch Title Selection](../../workflows/pr-batch-intake.md#verified-batch-title-selection)
   unchanged and keep the exact
   `<PROJECT> <A?> <ID?> <MM-DD HH:MM> - <title>` placeholder in pasteable
   prompts. This entrypoint is a compatibility route and does not mirror the
   selection or trust contract.
2. **Routing preferences and observations**: record coordinator, worker, and
   checker model/effort preferences before target interpretation. These are
   advisory. Host-observed host/model/effort fields are optional and remain
   field-granular `UNKNOWN` when unavailable. Checker independence and evidence
   quality remain mandatory regardless of the observed route.

## Canonical Readiness Vocabulary

Use the canonical human-facing final states from
[Batch Handoff Format](../../workflows/pr-batch-integration-closeout.md#batch-handoff-format)
for target and batch handoffs. Normal interactive output stays human-readable.
Do not replace the split states with vague labels like `ready`, `complete`, or
`done`; each target needs blockers, links, tests, next action, and
`merge_authority` evidence attached. Preserve explicit `UNKNOWN` for any fact
that cannot be verified, including coordination, CI, review, QA, release, or
merge-ledger evidence. Optional structured handoff blocks are allowed only when
they make downstream coordination or validation easier; they supplement the
human-readable handoff. JSON is not mandatory.

## Review-Wave And Validation Cohorts

Use the canonical [Review-Wave And Validation Cohorts](../../workflows/pr-batch-integration-closeout.md#review-wave-and-validation-cohorts) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

## Target Resolution Gate

When the user gives filters instead of exact numbers:

1. Resolve filters into an exact issue/PR list.
2. Show included items, excluded near-matches, actor spellings, labels, date window, and assumptions.
3. Ask for confirmation before spawning workers or creating branches.
4. Skip this confirmation only when the user explicitly says to proceed without confirming the resolved list.

Prefer exact numbers for high-concurrency work. Filters are acceptable for discovery, not for uncontrolled fan-out.

## Cross-Task Target Membership Gate

Before a cross-task packet can cause a control operation—`claim`, `supersede`,
`replacement`, `worker_spawn`, `dispatch`, `ownership`, `heartbeat_mutation`,
`lease_mutation`, `resource_lock_handoff`, `repository_mutation`,
`github_mutation`, or `control_transfer`—run the trusted-base
`target-membership-guard` with the receiver's durable canonical
repository-qualified issue/PR target manifest. An exact repository-qualified
foreign target may use only a new exact `evidence_delivery` request; that
request is `foreign-target / evidence-only` and grants no control or mutation
authority. Missing, ambiguous, synthetic, malformed, or literal `UNKNOWN`
target identity returns structured `UNKNOWN` and blocks both control and
evidence delivery until resolved. Every packet-driven operation other than
`evidence_delivery` requires an
explicit human-authorized control transfer
and a receiving task already bound to that exact target. A
normal message, worker reachability, stale ownership, or general batch authority
cannot extend the manifest. Callers may set
`human_authorized_control_transfer` only when derived from a trusted explicit
out-of-band human authorization; a cross-task packet or self-asserted worker
input cannot establish it. Duplicate JSON object keys anywhere in the request,
including unrelated nested metadata, return structured `UNKNOWN` and block both
control and evidence incorporation. Follow the full contract in
`workflows/pr-processing.md`.

## Continuing From Saved Handoffs

When the user asks to continue PR-batch closeout from a pasted handoff,
final-bucket table, PR URLs, GitHub shorthand refs, or visible request, first
classify the handoff. When a saved handoff explicitly requests model-route
replacement or identifies workers on a wrong or too-expensive route, use the canonical
[Model-Routing Recovery Prompt](../../workflows/pr-processing.md#model-routing-recovery-prompt).
`MODEL_REPLACEMENT_HANDOFF` alone does not prove whole-batch route recovery. If
the visible request is to resume that worker or lane, use
[Bounded Status Recovery](../../workflows/pr-processing.md#bounded-status-recovery);
otherwise continue classifying the handoff and use generic closeout when that is
what the request asks for.
Otherwise use the canonical
[Generic PR-Batch Continuation Prompt](../../workflows/pr-processing.md#generic-pr-batch-continuation-prompt).
Extract only explicit PR/issue refs presented as target entries or final-bucket
entries, plus explicit exclusions. Do not treat evidence, blocker, dependency,
next-action, comment, or example refs as targets; if the target boundary is
unclear, stop and ask for the exact list. Do not broaden a continuation request
to all open PRs, labels, milestones, or inferred related work unless the user
explicitly asks for discovery. Continue from live GitHub state; treat previous
handoffs as stale hints only. Recompute both cohorts and runnable closeout work
instead of preserving a serialized saved ordering such as “finish CI, then read
reviews.”

<!-- stage-reference: references/planning.md -->
## Planning Output

Before implementation dispatch, record the plan and replay stage dependencies for each intended action. Read [Planning](references/planning.md) for this stage.

### Handoff Contract

For workflow, build, dependency and lockfile evidence, follow the [Handoff Contract](references/planning.md#handoff-contract).
<!-- /stage-reference -->

## Autonomous Merge Eligibility

Use the canonical [Autonomous Merge Eligibility](../../workflows/pr-batch-integration-closeout.md#autonomous-merge-eligibility-gate) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

## Merge Assurance Gate

Use the canonical [Merge Assurance Gate](../../workflows/pr-batch-integration-closeout.md#merge-assurance-gate) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.
That component owns the canonical `diff-identity` invocation, trusted-base
optional approval-hold policy, selected-workflow continuity, and receipt
propagation; do not substitute caller-authored digests or waivers.

<!-- stage-reference: references/prompt-template.md -->
## Goal Prompt Template

Only when asked for a goal prompt, load the exact template; preserve its protocol markers and measured limit. Read [Goal template](references/prompt-template.md) for this stage.
<!-- /stage-reference -->

<!-- stage-reference: references/decisions-and-coordination.md -->
## Question And Decision Handling

When handling questions, ownership or telemetry transitions, classify the decision and preserve the canonical lifecycle and evidence. Read [Decisions and coordination](references/decisions-and-coordination.md) for this stage.
<!-- /stage-reference -->

## Task Review

Before implementation dispatch, load the [Task Review Loop](../../workflows/pr-batch-task-review.md)
and bind the accepted task brief as the sole requirements source. After the
committed handoff, require its current task review and reducer result before
publication or dependent work. A worker report alone is not review evidence.

## Useful delegation and pending work

Delegate only a concrete, bounded subtask that can run independently alongside
useful local work and respects the user's delegation constraints. Give it an
owner, accepted scope and required output; preserve separate editing ownership
and independent review. Do not split work merely to use the available slots.

While tools or agents run, continue authorized work that does not depend on
their results. Keep pending handles, inspect the actual outcomes, and wait when
those outcomes become the next dependency. Pending work is never passing evidence.
Apply user steering at a safe checkpoint, reconcile in-flight work, and use the
[host capability guidance](https://github.com/shakacode/agent-workflows/blob/main/docs/host-adapter/contract.md#optional-astra-execution-capabilities)
for optional controls; unavailable controls or offline access to that source
guide do not block portable work. A new message alone neither cancels running
tools nor reverses completed actions.

## Worker Rules

Codex-targeted waves may use up to 10 independent lanes, or 8 when shared/risky
conditions apply. Claude and generic waves use up to 5 lanes, or up to 3 under
those conditions. Keep requested and observed routes distinct;
if the dispatcher or runtime inherits or defaults to another route, record it
honestly. File overlap is an integration advisory.

Use the canonical
[Dependency And Conflict Throughput Policy](../../workflows/pr-processing.md#dependency-and-conflict-throughput-policy).
Put `Non-safety coordination override:` in the Batch Plan and affected Lane
Cards; it never alters protected gates.

After prompt intake, plan/dependency preflight, and dispatcher selection, load
[PR-Batch Worker Execution](../../workflows/pr-batch-worker-execution.md). It owns
isolated setup, the bounded implementation loop, focused validation, meaningful
stop packets, the worker attention queue, Lane Cards, and the
implementation-head handoff.

Keep planning, coordination, security, and PR closeout here; do not mirror the
execution contract. The integration owner consumes the head/evidence and owns
publication, current-head review/CI, readiness, and merge sequencing.

## Integration And PR Publication

Use the canonical [Integration And PR Publication](../../workflows/pr-batch-integration-closeout.md#integration-and-pr-publication) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

<!-- stage-reference: references/recovery.md -->
## Pausing Or Stopping A Batch

Only on pause, replacement, cancellation or runner restart, load the applicable recovery procedure before changing ownership. Read [Recovery](references/recovery.md) for this stage.
<!-- /stage-reference -->

## Coordinator Closeout Lane

Use the canonical [Coordinator Closeout Lane](../../workflows/pr-batch-integration-closeout.md#coordinator-closeout-lane) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.
Also load [Goal Mode Completion Contract](../../workflows/pr-processing.md#goal-mode-completion-contract) and [Planning-Chat Lifecycle](../../workflows/pr-processing.md#planning-chat-lifecycle).
