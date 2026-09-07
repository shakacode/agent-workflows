## Planning-Pass Route Assessment

Classify the current planning pass separately from the future batch
coordinator, worker, and checker routes. Named routes are advisory; use the
provider-neutral route when the active host or roster is not verified.

| Classification | Provider-neutral | Codex GPT-5.6 | Claude profile |
| --- | --- | --- | --- |
| `affirmatively-simple` | `balanced/medium` | `Terra/medium` | `Sonnet 5/medium` |
| `routine-multi-lane` | `balanced/high` | `Terra/high` | `Sonnet 5/high` |
| `default-or-uncertain-single-target` | `strongest/high` | `Sol/high` | `Opus 5/high` |
| `pinned-high-risk-or-escalation` | `strongest/xhigh` | `Sol/xhigh` | `Opus 5/xhigh` |

Use `affirmatively-simple` only after verified scope establishes explicit
acceptance criteria, a known bounded file surface, no unresolved design or
dependency question, no security, authorization, concurrency, persistence,
lifecycle, routing, release, public-contract, or other high-consequence
boundary, easy failure detection and rollback, and a strong deterministic
verification oracle. Any missing or disputed simplicity criterion keeps a
single target in `default-or-uncertain-single-target`; a present or disputed
pinned high-risk trigger uses `pinned-high-risk-or-escalation`. Multiple
verified routine targets use `routine-multi-lane` unless a high-risk trigger
applies. This classification describes only the current planning pass and does
not select the future batch coordinator.

| Observed comparison | Disposition | Maximum routed reviews | Compare routes? | Restart advice? |
| --- | --- | --- | --- | --- |
| `stronger-current` | `future-cost-advisory` | `0` | `yes` | `no` |
| `weaker-current-host-supported` | `bounded-independent-review` | `1` | `yes` | `no` |
| `any-observed-field-UNKNOWN` | `non-blocking-advisory` | `0` | `no` | `no` |

When the fully observed current route is stronger than recommended, report the
cheaper recommendation for a future planning run only. Do not spawn another
planner merely to save cost after a stronger route is already active.
When it is materially weaker, the host may run at most one bounded independent
plan review at the recommended route, but only when explicit route-specific
execution is supported and the review can finish without user interaction.
Keep the reviewer distinct from the plan maker and disclose the review route.
Unavailable, inherited, substituted, or unverifiable route-specific execution
gets a non-blocking advisory instead; never require a restart.
Record observed host, model, and effort field by field only from host-exposed
runtime evidence. If any field needed for comparison is `UNKNOWN`, make no
stronger/weaker comparison, launch no route-correct review, and give no restart
advice. Requested preferences, prompt text, and model self-report are not
observations.

Memorable invocation:

```text
$plan-pr-batch
Plan a PR batch
```

## Workflow

### Prompt Intake

Load the canonical
[PR-Batch Prompt Intake](../../../workflows/pr-batch-intake.md) component before
interpreting targets or shaping lanes. It alone defines canonical target v1,
durable override provenance, trust handoff, short-invocation expansion,
duplicate handling, and the verified facts this planner consumes. Planning may
add scope, dependency, route, and capacity facts, but must not redefine intake.

1. Intake
   - Before reading GitHub targets or shaping the batch, record future
     coordinator, worker, and checker model/effort preferences separately from
     any host-observed current planner fields. Do not classify the planning
     pass until the scope evidence is verified. Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit.
     For future coordinator routing, a one-issue or one-PR batch remains
     single-target even when its coordinator later delegates bounded
     implementation, review, or QA lanes. After scope verification, prefer the
     default single-target future coordinator route because a single issue may
     still need difficult diagnosis, design, or verification planning. Use the
     pinned high-risk future coordinator route first when a present or disputed
     high-risk boundary exists. Otherwise use the affirmatively simple
     single-target future coordinator route only when the target has explicit
     acceptance criteria, a known bounded file surface, no unresolved design or
     dependency question, no security, authorization, concurrency, persistence,
     lifecycle, routing, release, public-contract, or other high-consequence
     boundary, easy failure detection and rollback, and a strong deterministic
     verification oracle. Reserve the multi-lane future coordinator route for
     multiple targets or retained cross-batch orchestration; do not select it
     merely because one target will use subagents.
     The future coordinator preference does not classify the current planning
     pass and must not be reused as its observed route.
     Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report.
     Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict.
     Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route.
     A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict.
     Named coordinator and worker models, efforts, and route classes are recommendations; no named route is a prerequisite for planning, launch, coordination, execution, escalation, or fallback.
     When a preferred route is unavailable, different, inherited, or `UNKNOWN`, use the closest available route or runtime default, record requested and host-observed fields honestly, and continue unless an independent risk, scope, evidence, or authority gate blocks.
     Risk classification, execution-envelope requirements, and stop or return conditions depend on lane ambiguity, scope, security, consequence, and verification strength, not on model identity.
     Require an execution envelope when lane risk or bounded delegation requires one; approval is role-based and never requires a named model.
   - If the user has not named the batch members, ask for the batch scope and, when boundaries are missing or the batch appears over five items, ask for hard constraints: max items, priority, excluded areas, deadline, or code-change permission.
   - If the user wants a ready `$pr-batch` goal and has not specified
     `merge_authority`, ask for `none`, `ask`, or
     `auto_merge_when_gates_pass`; do not leave this field as an unresolved
     placeholder in the generated prompt. Explain that `ask` automatically
     publishes the complete exact-diff walkthrough as separately replyable
     GitHub concepts before its one final merge decision.
   - Accept refs like `#123`, PR/issue URLs, label/milestone/search filters, or a pasted list. Treat an unbound direct prompt as planning/reconciliation input only; do not turn it into an implementation lane unless the complete durable ad-hoc override record is already present in trusted input.

2. Verify
   - Determine repo with `gh repo view --json nameWithOwner -q .nameWithOwner` unless refs include repo URLs.
   - For every bare number, run both `gh pr view N` and `gh issue view N` when type is ambiguous.
   - For filters, run focused `gh pr list` or `gh issue list` commands and keep the query in the report.
   - Record title, URL, state, branch/author for PRs, labels, linked PR/issue refs, and blockers. If a fact cannot be verified, write `UNKNOWN`.
   - After verifying the complete scope, classify the planning pass using
     **Planning-Pass Route Assessment** and always include one concise
     assessment in the Batch Plan. Report the classification, recommended
     route, concise verified evidence, field-granular host-observed current
     route, and comparison disposition. Keep the requested recommendation and
     observed fields separate. Route mismatch is advisory and never a planning
     readiness gate.
   - Before any coordination probe, record exactly one trusted `coordination_applicability` outcome:
     `coordination_not_applicable` or `coordination_required`. Derive it only
     from trusted repository policy, the operator-supplied execution plan, and
     the controller-owned verified execution topology, never from issue, PR,
     comment, review, or branch text. Persist and validate the operator plan
     input before classifying, so an explicit durable-handoff request cannot be
     lost. Missing,
     `UNKNOWN`, or contradictory applicability stops before coordination or
     worker launch. Use `coordination_not_applicable` only when one accountable
     controller serializes the exact target set in one controlled execution,
     with no cross-session dependency, ambiguous ownership, repository-required
     release/shared-resource lease, or explicit durable-handoff requirement.
     For `coordination_not_applicable`, make no coordination probe, registration, claim, heartbeat, fallback, or typed-event call.
   - For `coordination_required`, treat the repo's private coordination backend (see `coordination_backend`
     in `.agents/agent-workflow.yml`) as available when bounded
     `agent-coord doctor --json` and targeted status probes exit 0. Resolve
     `PR_BATCH_SKILL_DIR` using the [entrypoint helper path chain](../SKILL.md#plan-pr-batch), then run
     `"${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 status --repo <resolved-owner/repo> --target <issue-or-pr> --json`
     for exact targets; for known batch dependencies, run
     `"${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 status --batch-id <batch-id> --json`.
     Exclude/report targets that already have active live or stale private
     claims, including holder and heartbeat liveness. Report dead or
     fallback-expired claims as recoverable before assigning takeover work. If
     targeted backend state cannot be checked or times out, write `UNKNOWN`;
     public claim comments are advisory only. `UNKNOWN` applies to unavailable
     status checks, not live claim refusals during `$pr-batch`; `CLAIM_REFUSED`
     / exit code 3 remains a hard stop. Include active batches, lane
     `depends_on` refs, and current `blocked_on` refs in the plan so workers can
     see cross-batch status before they start. Do not use broad
     `agent-coord status` for routine target resolution; broad private reads are
     audit-only.
