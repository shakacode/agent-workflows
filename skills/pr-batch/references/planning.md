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

After any target-specific invocation line, each pasteable batch prompt keeps
the canonical `Batch title: <PROJECT> <A?> <ID?> <MM-DD HH:MM> - <title>` block
near the top. Resolve it through
[Verified Batch Title Selection](../../../workflows/pr-batch-intake.md#verified-batch-title-selection)
without reinterpreting its verified intake facts.
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
