---
name: pr-batch
description: Plan and safely run one or more canonical issue, existing PR, or durably overridden ad-hoc work lanes with coordinated subagents, validation, review, and merge-readiness. Unbound direct prompts route through planning/reconciliation before implementation launch.
argument-hint: '[task, exact issue/PR numbers, or filters]'
---

# PR Batch

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
another contract requires, and collapses no closing structure.

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

### Single-Target Launch

When no planner/triage handoff supplies dependency artifacts, synthesize and
persist a verified one-lane `stage-dependency-plan` v1 file with a known plan id
and `edges: []`, plus a `stage-dependency-gate` v1 live replay: use the actual
target/lane id, current full head/base SHAs, and already bound maker/checker
identities. Do not infer or placeholder-fill any fact. Missing or `UNKNOWN`
facts remain fail-closed and stop before mutation.

- **Issue**: use the issue number as the coordination target.
- **PR**: use the PR number, fetch live PR state, and update its verified head
  branch instead of creating a competing branch unless a maintainer requests one
  or the verified head branch cannot be pushed. For an unpushable head, create a
  replacement branch/PR and document the original PR, limitation, and rationale.
- **Trusted overridden ad-hoc task only**: after the Canonical Launch Target
  Gate accepts the durable override, reuse the accepted exact `target.target` value unchanged as the coordination target.
  Never derive, rename, or regenerate it after preflight.
  Use its already accepted repository-qualified stable coordination identity unchanged and preserve the user's original wording plus override provenance
  in the PR body or no-PR evidence.
- **Worker shape**: when the host supports isolated subagents, dispatch one
  worker subagent for the lane and keep the parent as coordinator and closeout
  owner. Do not have the parent silently implement the lane. If the host lacks
  subagents, disclose the inline single-worker fallback and apply every same
  gate; stop instead when the user explicitly required a subagent.
- **Model/effort route**: use the canonical cost-aware staged routing from
  `pr-processing.md`. Start on the fastest or balanced worker route justified by
  ambiguity, risk, blast radius, reversibility, and verification difficulty—not
  merely the cheapest model—and require the canonical evidence before a stronger
  route or replacement.
  Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit.
  Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report.
  Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict.
  Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route.
  A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict.
  Named coordinator and worker models, efforts, and route classes are recommendations; no named route is a prerequisite for planning, launch, coordination, execution, escalation, or fallback.
  When a preferred route is unavailable, different, inherited, or `UNKNOWN`, use the closest available route or runtime default, record requested and host-observed fields honestly, and continue unless an independent risk, scope, evidence, or authority gate blocks.
  Risk classification, execution-envelope requirements, and stop or return conditions depend on lane ambiguity, scope, security, consequence, and verification strength, not on model identity.
  Require an execution envelope when lane risk or bounded delegation requires one; approval is role-based and never requires a named model.
- **Recommended Codex GPT-5.6 profile**: apply only after verifying the exact
  routes on the actual host; portable classes remain the fallback elsewhere.
  - Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)
  - Simple, positively classified worker: Terra/high
  - Unknown or uncertain worker: Sol/high
  - Sol/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
  - Independent adversarial QA: Sol/xhigh
  - Routine deterministic QA: Sol/high
- **Provisional Claude profile** (`claude-profile v1`): apply only after
  verifying the exact routes on the actual host; portable classes remain the
  fallback elsewhere.
  - Routine multi-lane coordinator: balanced/high (`Sonnet 5/high` only when host-verified)
  - Simple, positively classified worker: Sonnet 5/high
  - Unknown or uncertain worker: Opus 5/high
  - Opus 5/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
  - Independent adversarial QA: Opus 5/xhigh
  - Routine deterministic QA: Opus 5/high
- **Batch plan preflight**: before dispatcher selection or worker launch, run
  the resolved plan skill's `bin/batch-plan-preflight` with a v1 envelope. It
  owns schema and launch scheduling, including the required active wave and
  max-one serialization. Preserve real PR verified `pr-file-touch-map` results
  unchanged; encode explicit pre-PR paths as typed `planned-path-evidence` v1
  records with durable evidence references. An `issue` source must bind to the
  target's exact repository and number through `issue://OWNER/REPO/N` or an
  exact lowercase-host `https://github.com/OWNER/REPO/issues/N` reference;
  both reject userinfo and query, HTTPS requires port 443, `issue://` requires
  the exact canonical authority/path shape, and fragments remain permitted;
  other source kinds prove durability only and do not invent target identity.
  After an issue or trusted ad-hoc lane opens its implementation PR, keep the original canonical target unchanged and replace planned-path evidence with the lane-keyed verified PR file-touch map; its repository must match the target, while a PR-origin target also requires the exact target PR number.
  Optional additive
  `expansion_path_reservations` entries use exact
  `expansion-path-reservation` v1 records bound to the batch, dependency plan,
  known lane, and wave, with one canonical path, known reason, and durable
  evidence reference. A directory rename instead uses an exact
  `expansion-rename-reservation` v1 record with the same identity, reason, and
  evidence fields and a canonical, distinct `rename` old/new pair in place of
  `path`. Presence means active and omission means cancelled. Reject malformed,
  `UNKNOWN`, noncanonical, duplicate, mismatched, completed-lane, or
  already-reflected reservations. Collision and risky-cap decisions use verified
  paths plus active reservations. Scalar path reservations remain exact-only;
  typed rename reservations add ancestor/descendant collision checks at both
  endpoints. Reservation-derived overlap requires explicit max-one
  serialization. A rejection launches nothing; an acceptance permits only the
  returned eligible lanes.
- **Dispatcher capability preflight**: before launch, pass the requested
  route preference/dispatcher, explicit dispatch authority, ordered candidates,
  and preserved lane state to `bin/dispatcher-capability-preflight`. It records
  the preferred dispatcher or first explicitly authorized dispatcher fallback; it never launches or
  mutates coordination. Each viable candidate includes a stable prospective `instance_id` allocated or reserved by its dispatcher before launch, only for replay/fencing; the helper neither launches nor creates a worker. An `UNKNOWN` prospective instance is unusable. `selected` resumes Goal mode; `blocked-user-input`
  carries one `dispatch-decision-request v1` with canonical viable fallback choices and stops.
  Replay identity is `lane_id`, dispatcher, `instance_id`, and launch token; route preference, observed host fields, and `candidate_index` are metadata and never trigger replacement.
  Persist `launch-pending` before worker launch; after spawn, persist ordinary `active` state before Goal-mode resume, and replay the same token while pending or emit no new launch while active.
  Assignment activation uses ordinary durable lifecycle state; no project signing key, fixed trust anchor, launch-confirmation receipt, or human waiver is required.
  A dispatcher or instance change still requires stop/reconcile replacement fencing and a single-use proof bound to the exact prior and replacement assignment identities.
  Same-lane worker/model replacement is a nonterminal claim reassignment or supersession operation; it must never emit a terminal lane closeout. Before consuming replacement proof, preserve and verify known `status`, `terminal`, `closed_at`, and `pr_state`; missing or `UNKNOWN` terminal facts fail closed, and a truly terminal lane requires reconciliation or explicit replanning instead of replacement. The first terminal event remains immutable: later authenticated completion may reconcile an `abandoned` lane or a `superseded` issue with typed no-PR evidence, but code-bearing completion after terminal `superseded` is a premature terminal supersession / replacement protocol violation.
- **Merge authority**: resolve `merge_authority` before worker launch. Use a
  visible user instruction, an explicit `AGENTS.md` rule, or a resolved batch-plan instruction; otherwise ask
  for `none`, `ask`, or `auto_merge_when_gates_pass`. `ask` includes an
  [automatic interactive exact-diff walkthrough](../../workflows/pr-batch-integration-closeout.md#ask-merge-authority-walkthrough-gate)
  before the one final merge decision. Do not silently default it.

The single lane still gets a Lane Card, claim/heartbeat behavior when configured,
a one-row file-touch map, a Batch QA Lane decision, current-head review and CI
checks, and the canonical terminal state and handoff evidence.

Resolve the target repo's `base_branch` from `.agents/agent-workflow.yml` when present, otherwise from the `AGENTS.md`
**Agent Workflow Configuration** seam. If neither declares it, report
`base_branch: UNKNOWN` and stop before branching. Run
`git fetch --prune origin <base-branch>`, then use the
repo-local `.agents/workflows/pr-processing.md` when present or the installed
`../../workflows/pr-processing.md` as the deeper operating model for each issue,
PR, review-fix pass, or merge-readiness item. If the target scope is not
verified yet, use the installed or repo-local `plan-pr-batch` skill first.
When invoking this skill's helper scripts, resolve `PR_BATCH_SKILL_DIR` in this
order: explicit environment variable; the loaded skill's base directory when the
host exposes it; repo-local `.agents/skills/pr-batch`; then stop with a precise
blocker if the helper is still missing.
For release-mode coordination, auto-merge confidence, shared release trackers,
production deployment or promotion, publishing, release rollback, or other
explicit release work, load the resolved
`pr-production-release.md`: prefer the repo-local
`.agents/workflows/pr-production-release.md` when present; otherwise use the
installed workflow from the same Agent Workflows pack as the loaded `pr-batch`
skill, not relative to a potentially repo-pinned processing override. Follow the
consumer repo's `AGENTS.md` release policy. Do
not restate the component's tracker, phase, promotion, or release rules here.
Ordinary base-branch feature work does not load that downstream component unless
repository policy or the live release tracker selects release handling for that
PR. Before skipping it, perform a bounded tracker-discovery check using only the
consumer repo's `AGENTS.md` tracker labels, title prefix, or other search policy.
Load the component when an existing applicable tracker unambiguously selects the
PR; if the repo defines no tracker discovery policy, do not invent one. If any
target's value, priority, or proposed fix scope is unclear, use the
installed or repo-local `evaluate-issue` skill before assigning implementation
workers.
Skip issues labeled `needs-customer-feedback` unless the user explicitly provides customer evidence or maintainer approval for that issue; report each skipped target with `needs-customer-feedback` as the reason.

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

1. **Batch title**: for pasteable batch prompts, derive a short title in the form
   `<PROJECT> <A?> <MM-DD HH:MM> - <short title>`.
   Resolve `<PROJECT>` from the optional `repo_prefix` in
   `.agents/agent-workflow.yml` when present; its value must be 1-6 uppercase
   ASCII letters or digits. If `repo_prefix` is absent, derive `<PROJECT>`
   deterministically from the repository name: use the basename of the `origin`
   remote after stripping `.git`, or the repository root basename when `origin`
   is unavailable; for a multi-segment name take the first character of each of
   the first six `-`, `_`, or space-separated segments, and for a single-segment
   name take its first 4 characters or the whole name when shorter, then
   uppercase the result (`agent-workflows` -> `AW`, `react_on_rails` -> `ROR`,
   `shakapacker` -> `SHAK`, `go` -> `GO`, `web3` -> `WEB3`, `3d-tiles` -> `3T`).
   An invalid configured `repo_prefix` is a blocker; do not silently fall back.
   Fill the optional `A?` slot with A,
   B, C, etc. only when creating multiple batch prompts; omit it for a single
   batch prompt. Run `date +'%m-%d %H:%M'` in the local shell when creating the
   prompt, and use that output for `MM-DD HH:MM`.
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

## Planning Output

Before implementation or worker launch, produce:

1. A concrete goal name.
2. A disposition summary for speculative, AI/code-analysis-only, over-scoped, or unclear candidates, or `N/A - all targets pre-approved`.
   - Include any `needs-customer-feedback` targets skipped from implementation, with that label as the reason.
3. A repo preflight: resolve the base branch from `AGENTS.md`, run `git fetch --prune origin <base-branch>`, confirm the expected repository root, verify resolved workflow files, and verify nested repo paths before assigning work.
4. The preserved, stage-specific `security-floor v1` result for every lane.
   Report its target/stage binding and `PASS`, `BLOCKED`, or `UNKNOWN` outcome;
   for public issue/PR targets, include the result's preflight outcome, exact
   invocation, trust-config provenance, findings, acknowledgements, and queues.
   Stop unless the result permits the planned stage. Do not reconstruct the
   helper invocation or select preflight flags here; the canonical floor owns
   that adapter policy.
5. A short batch table:
   - target number and title
   - branch name
   - expected file area
   - validation
   - risk
   - likely outcome: implementation PR, combined investigation PR, no-PR evidence comment, or product-decision blocker
   - assigned machine or worker
6. The selected `merge_authority` value and how it affects final closeout.
7. The Batch QA Lane decision from `.agents/workflows/pr-processing.md`:
   required lane/owner/scope or `not required` with rationale, plus final QA
   Evidence expectations.
8. A permission and trust preflight result, including canonical launch
   provenance: the repository-qualified issue/PR identity, or every accepted
   durable ad-hoc override field and its repository-qualified stable
   coordination identity. Put the same values in the plan/preflight input and
   reject a missing, changed, duplicate, or `UNKNOWN` identity before dispatch.
9. An integration-advisory check for overlapping files plus the authoritative
   issue-authored dependency check for dependent PRs.
10. The selected batch-size target and wave split: `codex` up to 10/8,
    `claude` up to 5/3, or `generic` up to 5/3, with spillover assigned to
    later waves instead of overfilling the current one.
11. A coordinator model/effort preference, independent-checker preference,
    plus a separate staged worker model/effort preference for every lane,
    grouped by initial/escalation pair with
    the planner's rationale. Require `MODEL_ESCALATION_REQUEST` before a worker
    uses the stronger route. Revalidate every supplied exact pair on the actual
    host; carry any dispatch-resolved class as an advisory preference before work starts. Keep worker
    requested preferences distinct from the coordinator preference; if the
    dispatcher or runtime inherits or defaults to that route, record it honestly
    and continue unless an independent gate blocks. Every lane whose risk or
    bounded delegation requires an execution envelope gets one from the
    coordinator role under the canonical workflow, regardless of route. If a
    route preference is unavailable, preserve it as `UNKNOWN` and continue with
    the same ownership, verification, and review gates.
12. Batch-registration provenance: verified loaded-pack `pack_sha` (or verified
    installed-release identifier), coordinator and worker route preferences,
    and each lane's optional observed host/model/effort. A dirty or unverifiable pack and every
    unverifiable scalar stay literal `UNKNOWN`. Persist the manifest after
    dispatcher selection and before worker launch when registration is
    supported; backend `n/a` keeps it in durable coordinator state. Follow the
    canonical example and resolution rules in `docs/coordination-backend.md`.
    When host-observed metadata becomes available, reconcile each observed
    host/model/effort field changed by fallback, escalation, or replacement,
    preserve known fields, and use `UNKNOWN` only per unavailable field.
    Missing observation never blocks ordinary active lifecycle. Before
    reconciliation, detect advertised registration
    update/upsert/reconciliation capability. An unadvertised or unsupported
    create-only backend records each affected field `UNKNOWN`. An advertised update
    uses the bounded safe executable-plus-opaque-argv contract; failure records
    affected fields `UNKNOWN` without wedging. Every advertised registration invocation resolves a
    backend-advertised safe executable plus ordered opaque argv without shell
    evaluation and runs with a finite hard deadline in its own process group;
    timeout or whole-group `TERM` then `KILL` records best-effort
    field-granular `UNKNOWN`, names reconciliation, and does not block worker
    launch.
<!-- host-branch: codex-only start -->
13. A final `/goal` prompt when the user asked for Goal mode.
<!-- host-branch: codex-only end -->

After any target-specific invocation line, each pasteable batch prompt must put
`Batch title: <PROJECT> <A?> <MM-DD HH:MM> - <short title>` near the top.
Derive `<PROJECT>` with the abbreviation rule in **Required Interview** above,
and get `MM-DD HH:MM` by running `date +'%m-%d %H:%M'` in the
local shell when creating the prompt.
Use `Thread handle:` as the first worker-specific line: derive `<batch-short>`
from the lowercased resolved batch title `<PROJECT>` plus its lowercased optional A/B/C suffix, `<lane>` from the
lane id or owner slug in the file-touch map, and `<word>` from a short
coordinator-chosen session word. Record the handle before dispatch so workers
copy it unchanged.

If the user is in `/plan` or asks for a plan-to-goal handoff, stop after the Codex goal prompt. Do not begin implementation from plan approval unless the user explicitly says to launch now.

## Handoff Contract

For workflow/build/dependency/lockfile gate changes, include the `AGENTS.md` /
resolved `pr-processing.md` audit evidence for new-gate stale-base
controls. For lockfile changes, include Dependabot ecosystem and
directory/directories compatibility plus the lockfile content-diff note:

- changed dependencies
- rationale
- sibling-lock comparison
- any platform-precompiled / source-build or build-time dependency change

This per-PR requirement also applies to each individual target PR in the batch
whose committed lockfiles change.

## Stage-Typed Dependencies

For every batch, consume the planner/triage `stage-dependency-plan` v1 file and
separate `stage-dependency-gate` v1 live replay defined in the resolved
`pr-processing.md` **Stage-Typed Dependency Gate** section. Do not reduce typed
edges to generic `depends_on` readiness. Take `STAGE_DEPENDENCY_PLAN_PATH` and
`STAGE_DEPENDENCY_PLAN_ID` only from trusted coordinator handoff/stable planning
state, then refresh lane heads/bases, live edge states, verified evidence, and
base-movement facts. The live edges carry only `id`, `state`, `evidence`, and
`base_movement`; ignore tuple copies in mutable input. Resolve
`PR_BATCH_SKILL_DIR` in this order: explicit environment variable; the loaded
skill's base directory when the host exposes it; repo-local
`.agents/skills/pr-batch`; then stop with a precise blocker if the helper is
still missing. Run `"${PR_BATCH_SKILL_DIR}/bin/stage-dependency-gate"`
`--trusted-plan "${STAGE_DEPENDENCY_PLAN_PATH}"`
`--trusted-plan-id "${STAGE_DEPENDENCY_PLAN_ID}"` before any lane creates a
branch/worktree, patches/edits, commits, pushes, opens a PR, starts final
validation or hosted CI, or merges. Re-run after any dependency, head, or base
movement and at the dependency-sensitive coordination checkpoints. Missing,
unreadable, malformed, `UNKNOWN`, or mismatched plan path/id/data blocks every
mutation; backend `n/a` uses a durable coordinator-owned local plan file.

Every immutable pre-launch trusted plan edge binds `id`, `from`, `to`, and
`type` outside the mutable live replay. Its coordinator-pinned plan identity is
the trust boundary; another tuple or binding in stdin cannot override it.
Legitimate reclassification requires a new edge id and a trusted coordinator
re-plan.

For pending `edit` or `validation_open`, replay the lane's deterministic
preparation record: nonempty known `source_patch_inspection`,
`collision_domain_mapping`, `semantic_adaptation_notes`,
`validation_review_plan`, and `evidence_templates`. Missing, malformed, or
`UNKNOWN` preparation fails closed. Pending `validation_open` permits local
branch/edit/commit only after preparation passes; pending `edit` remains
read-only, and pending `merge_order` remains merge-only.

Obey each returned permission literally. Unknown/malformed contract data fails
closed; pending `edit` permits read-only discovery only; pending
`validation_open` permits held-local changes only after edit and preparation
gates clear; pending `merge_order` constrains merge only. Use only the returned
`not-yet-eligible` or `eligible-via-repo-seam` hosted-CI decision, and resolve
the latter through the consumer repo seam. A base-refresh result requires
refresh/current-head replay before push/open/final validation where reported;
`independent-behind-base` does not invent a refresh requirement.

A lane may perform helper-permitted intermediate work while dependencies are
pending, but it cannot be reported ready or closed out until every required
dependency edge is terminally satisfied.

The manifest assigns known maker/checker identities to every lane and the helper
replays them on its deterministic critical path. After trimming and Unicode case
folding, every checker must be distinct from every maker in the batch; a
collision or `UNKNOWN` blocks that lane's merge and the checker verdict. Shared
makers and genuinely independent shared checkers remain valid. Keep final
combined-tip validation downstream through the consumer seam, in addition to
exact-head CI, independent review, unresolved-thread, and merge-readiness gates.
An `evidence_ref` is only a verified reference; never treat it as cross-PR
artifact trust or authority.

Missing, empty, or `UNKNOWN` maker/checker identity permits read-only discovery
only and blocks hosted CI and every mutation.

Every manifest contains at least one verified lane; only `edges` may be empty.

## Autonomous Merge Eligibility

Use the canonical [Autonomous Merge Eligibility](../../workflows/pr-batch-integration-closeout.md#autonomous-merge-eligibility-gate) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

## Merge Assurance Gate

Use the canonical [Merge Assurance Gate](../../workflows/pr-batch-integration-closeout.md#merge-assurance-gate) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

## Goal Prompt Template

Keep this template aligned with the matching plan-to-goal prompt in the
resolved `pr-processing.md`, including the review/audit gate
paragraphs. The `Coordination:` line below intentionally points at the canonical
workflow rules instead of duplicating them.
`GMCC-v5` is a version key that pins drift, not an external-only pointer; its inline semantics remain normative when the workflow reference is missing or cannot autoload.
Use `HST-v1` from the canonical [Human-Status Translation Contract](../../workflows/pr-processing.md#human-status-translation-contract) for every recurring wake or workflow-owned heartbeat.

Use this template when creating Codex goal text:

```text
Use $pr-batch to complete this batch with subagents.
Batch title: <PROJECT> <A?> <MM-DD HH:MM> - <short title>.
Thread handle: <batch-short>-<lane>-<word>
Lane Card:claim/PR-open/block/cancel/final;route;holder/branch/PR/phase/URLs/UNKNOWN
Launch:<repo:<issue|pull-request>:N|repo:adhoc:date-slug>;ovr:n/a|name/auth/ref/task;none:reuse/create issue(auth/ask)+bind;invalid|dup|UNKNOWN:stop
PF:issue/PR=security;adhoc=trusted+task-bound+durable,no-target-security
Repo:OWNER/REPO
Objective:...
merge_authority:<none|ask|auto_merge_when_gates_pass>
Batch size target: <codex|claude|generic>;wave: <cap/items>
Coordinator model/effort preference: <model/class>/<effort>.
Observed host/model/effort: <host|UNKNOWN>/<model|UNKNOWN>/<effort|UNKNOWN>; host-only, no inference.
Manifest:pack_sha=<rev|UNKNOWN>;coordinator_preference=<model>/<effort>;lanes=<lane-id:dispatcher+preferred-route+observed-host/model/effort>,...;UNKNOWN=field;no guesses
Worker model/effort preferences: <initial model/class>/<effort> -> <lane ids>; escalation <model/class>/<effort> after MODEL_ESCALATION_REQUEST; max <N>.
Dispatch <lane>:<dispatcher>@<route>;fallback <dispatcher>@<route>->...|none;auth <y|n>;ordinary pending/active lifecycle
- Stage deps: v1 edit|validation_open|merge_order; missing/UNKNOWN/stale=>closed; combined-tip@repo-seam
GMCC-v5:CI@head/configured-reviewers pending|missing|untriaged|failed|threads open|UNKNOWN=>waiting-on-checks-or-review/NOT COMPLETE;poll/fix;auto-clear=>watch(same:0wake,delta:gates);fallback:4x15m+exp/4h|manual;stop clear/done/term/budget/user;noauth=>ready-no-merge-authority;ask=>own:walk|ext:user(merge|auth:add);blocked-user-input=>0retry/watch;auto=>exact verdict/head/sorted-gates/rollback;merge iff autonomous-merge-eligible OR human-approved-for-current-head+durable(proven-human+merge-authority);else ready-human-review-required|autonomous-merge-evidence-unknown;merge+close PR/target/issue.
HST-v1
Batch QA Lane:<owner/scope+evidence|none+rationale>
Scope:titles/deps/exclusions/owners;STAGE_DEPENDENCY_PLAN_PATH=<p>,STAGE_DEPENDENCY_PLAN_ID=<id>,live=<replay/ref>;ft=refs/paths/create/delete/rename/collisions/owner/serial/UNKNOWN
Items:
- Target:<repo:<issue|pull-request>:N URL|repo:adhoc:date-slug>
  Orig:<prompt|n/a>;ovr:<n/a|name/auth/ref/task>
  Goal:outcome
  Notes:scope/deps
  Done:req auth+PR/no-PR evidence|no-fix rationale
Execution rules:
Base:repo/AGENTS;fetch/prune origin;verify $pr-batch+workflow;unresolved=>UNKNOWN
- Resolve `$pr-batch`; autoload/self-contained: load persisted state before preflight; persist output before resume/launch; preflight issue/PR only.
- Routes advisory; observed host/model/effort host-only or UNKNOWN; checker independence/evidence mandatory.
- Dispatch: pending->persist/reissue token; active->no launch; input->decision; fence->stop/reconcile.
Current wave:each target/lane exactly once;one target/lane/worker;overlap=>integration advisory;deps/resv/UNKNOWN=>coord
Workers:paths=coord!=perm;path+resv;multi=>coord;stop:contradiction/ambig/scope-risk/verify-down;Verify live GitHub before edits;unverifiable=>UNKNOWN
- For coordination, respect coordination claims and dependencies: stable ids+heartbeats; register before launch when supported; claim refusal=>stop; push holder/generation check; known deps=>gate permissions; missing/UNKNOWN deps=>stop.
Apply Batch QA Lane;include QA Evidence
merge iff `merge_authority` is `auto_merge_when_gates_pass`|explicit merge approval;release+gates pass;record PR confidence
- ask=>$pr-walkthrough;large/complex full;refresh;chg=>redo/stop;gate fail=>stop;ask iff same clean
Final:canonical closeout;links/tests/blockers/next/confidence/UNKNOWN/authority/QA/state

```

## Question And Decision Handling

Classify every unresolved question before continuing:

- **Blocking question**: the implementation, validation, or merge decision would be unsafe without maintainer input. Stop work on that target until answered. Subagents should return the blocking question to the coordinator instead of guessing. For multi-machine batches, post a structured issue or PR comment and, if the repo defines a pending-question marker in `AGENTS.md`, apply that marker. A worker handoff should include the question/comment URL as that target's blocked final state.
- **Non-blocking decision**: a reasonable local decision can be made without increasing merge risk. Continue work, but add a clearly formatted decision note inside the PR description's `Agent details` disclosure so later review across merged PRs can surface these items quickly.

For a private-backend blocking stop, emit `help_requested` alongside the prose
handoff. Choose exactly one `help_requested.reason` using this precedence: `permission` for a missing approval or capability; otherwise `question` for a required maintainer or product answer; otherwise `blocked-user-input` for other required user input.
When a worker verifies a P0/P1 finding, confirmed regression, or required
revert, emit `error` with `severity`, `category`, and `message`. Backend `n/a`
skips these signals. Typed-event transport is optional: when an active private
backend does not advertise it or reports it unsupported, record
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
continues immediately without waiting further on the event.

<!-- Keep this hosted-CI uncertainty rule in sync with `.agents/workflows/pr-processing.md`. -->

Hosted-CI uncertainty at the final readiness gate after local validation and the
final push is a non-blocking decision. If the branch needs remote confirmation,
request optimized hosted CI via the repo's hosted-CI trigger (see `hosted_ci_trigger`
in `.agents/agent-workflow.yml`). If the remaining concern is that optimized suite
selection may be insufficient, request force-full hosted CI and record why. Re-fetch
and wait for the newly requested current-head checks, then continue the readiness
flow instead of escalating it as an immediate maintainer question. Check hosted-CI
status first when state is unclear, and do not substitute a direct hosted-CI-ready
label from automation for the trigger command; direct labels are only the human/local
user-token path.

Use the canonical [Human-First PR Description Contract](../../workflows/pr-processing.md#human-first-pr-description-contract).
Keep the human-visible why, change summary, review path, and genuine maintainer
questions or blockers outside its one `Agent details` disclosure; put the
decision log and all agent evidence inside it. Before merge or final readiness,
scan the decision log and make sure each non-blocking decision is still accurate
after review changes.

## Maintainer Attention Contract

Use `AGENTS.md` and the canonical
[Maintainer Attention Contract](../../workflows/pr-processing.md#maintainer-attention-contract)
section in `.agents/workflows/pr-processing.md`. Keep this skill as a routing
entry point: worker goals should carry the contract before target assignment,
and the goal prompt template above repeats the key worker-facing rules. The
detailed policy belongs in the canonical workflow.

## Batch Handoff Format

Use the canonical [Batch Handoff Format](../../workflows/pr-batch-integration-closeout.md#batch-handoff-format) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

## Coordination State

Use [.agents/workflows/pr-processing.md](../../workflows/pr-processing.md) as the
canonical source for coordination state and worker rules. Keep this skill as a
routing entry point; do not duplicate the full protocol here.

In short: exact lane assignments beat labels; a selected private backend is the
source of truth when bounded health and target-scoped status probes pass; claim
refusals hard-stop machine agents; workers heartbeat at phase transitions;
dependency-sensitive lanes re-check coordination before rebase, push, readiness,
and closeout; broad status reads are audit-only; exact independent lanes may
proceed in claim-only mode only after the canonical workflow allows it; and
structured public claim comments are advisory fallback state only when the repo
seam allows that fallback. Timed-out claims stop as `UNKNOWN (claim outcome)`
for backend reconciliation. An issue/PR lane claim also mirrors to the seam's
claim label (`agent_claimed_label`, default `agent-claimed`; apply on claim,
remove on release for this lane's own claim; hint not lock; skip when backend
n/a), and selection/triage skip claimed items — see the canonical rule in
`pr-processing.md`.

The same canonical section defines provenance and operational telemetry. Batch
registration carries `pack_sha`, `coordinator_preference`, and per-lane
`worker_preference` plus optional `observed_host`. Workers emit `help_requested`,
`escalation_requested`, `error`, and `human_intervention` at the existing
checkpoints without replacing prose packets. Do not duplicate auto lifecycle
events `claim.acquired`, `claim.released`, or `phase.changed`.

For a compact directional throughput view, normalize only allowlisted durable
coordination and field-selected GitHub-shaped metadata into
`workflow-telemetry-input` v1, then run the sibling
`bin/workflow-telemetry-report`. Use its replay fixture and contract documented
in `docs/coordination-backend.md`; preserve literal `UNKNOWN` for unavailable
measures. Its phase, human-question queue, and slot totals are cumulative across
lanes rather than elapsed critical-path time; its separate batch-level
`integration_seconds` window is not `phase_seconds.integration`. Never add raw prompts, responses, transcripts, tool results, secrets,
environment/auth content, exact accounting, adaptive scheduling, experiments,
or a parallel collection system.

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

## Pausing Or Stopping A Batch

### Model-Only Worker Replacement

When the goal, targets, scope, and lane identity stay stable but a worker needs
a different model/effort role, use
[Worker Model Replacement And Escalation](../../workflows/pr-processing.md#worker-model-replacement-and-escalation)
instead of cancelling the batch. Stop the old worker, capture or reconstruct its
`MODEL_REPLACEMENT_HANDOFF`, reconcile the claim holder/generation/instance, and
start the replacement only after fencing prevents overlap. For already-running
batches that need the staged route policy, use the canonical
[Model-Routing Recovery Prompt](../../workflows/pr-processing.md#model-routing-recovery-prompt).
After the prior instance is stopped and ownership is reconciled, emit
`human_intervention` with `kind: supersede` (or `kind: takeover` for abandoned
ownership) when a private backend is active.

### Normal Agent-Runner Restart

For an ordinary agent-runner restart where the same lanes should resume
afterward, use the canonical
[Pausing For An Agent-Runner Restart](../../workflows/pr-processing.md#pausing-for-an-agent-runner-restart)
prompt and its companion
[Bounded Status Recovery](../../workflows/pr-processing.md#bounded-status-recovery)
resume steps. Preserve claims and worktrees, and do not release or cancel a lane
unless the coordinator explicitly cancels it.

### Cancellation Or Relaunch

To stop an in-flight batch — for example to relaunch it with updated skills,
workflow rules, or targets — follow the canonical
[Cancelling Or Stopping A Batch](../../workflows/pr-processing.md#cancelling-or-stopping-a-batch)
protocol instead of waiting out claim leases. In short: a coordinator or maintainer
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
`kind: drain` when the active private coordination backend advertises
typed-event support. The coordinator/operator must not emit a duplicate for
that cooperative path. The cooperative worker path remains worker-owned at
that checkpoint; the coordinator/operator neither re-emits nor duplicates it.
Immediately before terminating a worker that cannot
reach that checkpoint, the coordinator/operator instead emits one lane-scoped
typed `human_intervention` event with `kind: drain` when the active private
coordination backend advertises typed-event support. For either drain path,
backend `n/a` skips the emission; unadvertised or unsupported typed-event
capability records `typed event transport: unavailable` and remains
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

## Coordinator Closeout Lane

Use the canonical [Coordinator Closeout Lane](../../workflows/pr-batch-integration-closeout.md#coordinator-closeout-lane) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.
Also load [Goal Mode Completion Contract](../../workflows/pr-processing.md#goal-mode-completion-contract) and [Planning-Chat Lifecycle](../../workflows/pr-processing.md#planning-chat-lifecycle).
