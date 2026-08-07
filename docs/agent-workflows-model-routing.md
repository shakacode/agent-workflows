# Cost-Aware Agent Model Routing

Use this guide with `$plan-pr-batch`, `$pr-batch`, and the canonical
[PR Processing Workflow](../workflows/pr-processing.md). It separates the
high-leverage coordinator from the higher-volume worker fleet, starts workers on
the least expensive safe route, and escalates only with evidence.

Shared workflow policy uses portable classes: `fastest-low-cost`, `balanced`,
and `strongest`. Exact model names and supported effort levels come from the
operator or the verified runtime roster. Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit.
Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report.
Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict.
Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route.
A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict.
Named coordinator and worker models, efforts, and route classes are recommendations; no named route is a prerequisite for planning, launch, coordination, execution, escalation, or fallback.
When a preferred route is unavailable, different, inherited, or `UNKNOWN`, use the closest available route or runtime default, record requested and host-observed fields honestly, and continue unless an independent risk, scope, evidence, or authority gate blocks.
Risk classification, execution-envelope requirements, and stop or return conditions depend on lane ambiguity, scope, security, consequence, and verification strength, not on model identity.
Require an execution envelope when lane risk or bounded delegation requires one; approval is role-based and never requires a named model.

## Default Policy

- Use the strongest suitable coordinator for batch initiation, scope,
  diagnosis, architecture, risk, routing, integration, final review, and
  closeout.
- Use balanced workers for most bounded implementation.
- Use fastest-low-cost workers only for tightly specified, deterministic,
  low-risk work with strong verification.
- Use strongest workers for scoped plan review or qualified recovery; return
  bounded implementation to a balanced worker when practical.
- Use an independent model family for comparison or a family-specific failure,
  not as the default implementation route.

The central distinction is simple: use the balanced route when the plan is
already credible; involve the strongest route when deciding, challenging, or
validating the plan is the difficult part.

Model choice never replaces tests, types, linting, review, functional or visual
verification, migration safeguards, least privilege, or human approval.

## Conservative GPT-5.6 Profile

Use this recommended advisory profile for Codex GPT-5.6 batches. It is an
informative preference, not a portable default for runtimes that do not
expose these models. `Sol` means GPT-5.6 Sol, `Terra` means GPT-5.6 Terra, and
`xhigh` is the extra-high reasoning-effort tier above `high`; verify that exact
effort token on the selected runtime before launch:

- Multi-lane coordinator: Sol/xhigh
- Simple, positively classified worker: Terra/high
- Unknown or uncertain worker: Sol/high
- High-risk or escalated work: Sol/xhigh
- Independent adversarial QA: Sol/xhigh
- Routine deterministic QA: Sol/high

The Sol/xhigh choices are deliberate conservative baselines for multi-lane
coordination and independent adversarial QA, where shaping or challenging the
plan is the high-leverage work. They do not imply maximum effort for every
worker or for routine deterministic QA; task-specific routing still follows
ambiguity, consequence, and verification strength.

GPT-5.5 is recommended for an explicitly requested independent comparison or
family-specific fallback. Selecting it elsewhere remains permitted but falls
outside this profile's evidence-backed recommendation.

Prefer Sol at the stated effort for the initiating parent. If the host exposes
the running model or effort, record it as observed metadata; otherwise keep the
field `UNKNOWN` and continue with the same safeguards.

The preferred independent adversarial checker route is a fresh Sol/xhigh
instance, distinct from every maker. The preferred routine deterministic QA
route is Sol/high. Terra may gather mechanical evidence or serve as the
independent checker; either route's verdict qualifies only when the checker
role, independence, scope, current-head evidence, and evidence quality qualify.

Terra/high is recommended after the coordinator positively classifies the work
as simple: explicit acceptance criteria, a known bounded file surface, a strong
deterministic verification oracle, no unresolved design decision, no security,
authorization, concurrency, persistence, lifecycle, routing, or public-contract
change, and easy failure detection and rollback. When lane risk or bounded
delegation requires an execution envelope, the coordinator role supplies the
exact goal and non-goals, owned paths, supported diagnosis, invariants,
acceptance criteria, required verification, and stop conditions regardless of
the selected model. The recommended route is Sol/xhigh for a present or disputed
high-risk boundary and Sol/high for other unknown or uncertainty; if unavailable,
use the closest available route or runtime default and record it honestly. Every
worker stops without editing further and returns to the coordinator when evidence
contradicts the diagnosis, scope or blast radius grows, a high-risk boundary
appears, verification weakens, or consequential judgment is required. Sol/xhigh
is the recommendation for high-risk or qualified escalated work, not a
prerequisite.

Luna is outside this conservative profile.

## Conservative Claude Profile (provisional)

Use this recommended advisory profile for Claude batches. Version marker:
`claude-profile v0`, provisional pending observed route metadata and
comparative evidence tracked in shakacode/agent-workflows#151 (adopted via
shakacode/agent-workflows#171). It is a planning preference, not a
portable default for runtimes that do not expose these models. The roster is
Opus 4.8 (`claude-opus-4-8`), Sonnet 5 (`claude-sonnet-5`), and Fable 5
(`claude-fable-5`), and `xhigh` is the extra-high reasoning-effort tier above
`high`; exact effort-token support on Claude runtimes is unverified, so record
the host-observed effort when exposed and otherwise use `UNKNOWN` without
blocking launch:

- Multi-lane coordinator: Opus 4.8/xhigh
- Simple, positively classified worker: Sonnet 5/high
- Unknown or uncertain worker: Opus 4.8/xhigh
- High-risk or escalated work: Opus 4.8/xhigh
- Independent adversarial QA: Opus 4.8/xhigh
- Routine deterministic QA: Opus 4.8/high

The Opus 4.8/xhigh choices are deliberate conservative baselines for
multi-lane coordination, uncertain work, and independent adversarial QA, where
shaping or challenging the plan is the high-leverage work. Task-specific
routing still follows ambiguity, consequence, and verification strength. A
single-lane, clearly scoped coordinator may use Opus 4.8/high.

Fable 5 is the leading candidate for long-horizon or highest-value
coordination, but it stays experimental until the
shakacode/agent-workflows#151 evidence supports promotion. Never make Fable 5
or `max` effort a default route.

Prefer Opus 4.8 at the recommended effort for the initiating parent. Record
host-observed parent metadata only from runtime state the host exposes; mutable
defaults, prompt text, model self-report, and an installed model list are not
observations. A different or `UNKNOWN` parent route does not alone block target
interpretation, planning, dispatch, review, or audit.

The preferred independent adversarial checker route is a fresh Opus 4.8/xhigh
instance, distinct from every maker. The preferred routine deterministic QA
route is Opus 4.8/high. Sonnet may gather mechanical evidence or serve as the
independent checker; either route's verdict qualifies only when the checker
role, independence, scope, current-head evidence, and evidence quality qualify.

Sonnet 5/high is recommended after the coordinator positively classifies the
work as simple: explicit acceptance criteria, a known bounded file surface, a
strong deterministic verification oracle, no unresolved design decision, no
security, authorization, concurrency, persistence, lifecycle, routing, or
public-contract change, and easy failure detection and rollback. When lane risk
or bounded delegation requires an execution envelope, the coordinator role
supplies the exact goal and non-goals, owned paths, supported diagnosis,
invariants, acceptance criteria, required verification, and stop conditions
regardless of the selected model. Opus 4.8/xhigh is the recommended route for a
present or disputed high-risk boundary or another missing or disputed simplicity
criterion; if unavailable, use the closest available route or runtime default
and record it honestly. Every worker stops without editing further and returns
to the coordinator when evidence contradicts the diagnosis, scope or blast
radius grows, a high-risk boundary appears, verification weakens, or
consequential judgment is required.

Haiku 4.5 is outside this provisional profile.

When shakacode/agent-workflows#151 publishes evidence-backed bindings, bump
the profile version and update the routes across every pinned surface in one
PR; the routing contract test keeps the surfaces moving together.

## Decision Framework

Classify every coordinator and worker route with five questions.

### Is the hard part diagnosis or execution?

- Diagnosis, strategy, architecture, or plan challenge: strongest coordinator
  or scoped strongest reviewer.
- Execution of a credible plan: balanced worker.
- Mechanical execution of explicit rules: fastest-low-cost worker.

### What is the blast radius?

Require strongest involvement for authentication/authorization, billing,
customer data, destructive migrations, security boundaries, production
availability, public APIs, package compatibility, cross-repository changes,
performance-sensitive infrastructure, or SSR/hydration correctness.

Use balanced workers for localized, reversible changes with credible coverage.

### How strong is verification?

Strong verification includes focused tests, type checks, linting, builds,
integration/end-to-end checks, visual regression, functional regression,
repeatable performance comparisons, migration/schema validation, and a clear
failing-to-passing reproduction.

Weak verification increases coordinator/reviewer capability and human review.

### Are the acceptance criteria precise?

The worker must be able to restate success before editing. Vague goals such as
“make it faster,” “clean this up,” “fix the flaky behavior,” “modernize this,”
or “make it production ready” need constraints and measurable outcomes first.

### Has the initial worker actually failed?

A small, understandable first error stays on the initial route for focused
correction. Escalate after two materially different credible attempts fail, or
earlier when diagnosis confidence is lost, unrelated scope appears, the patch
grows materially, verification becomes weak, safeguards would be suppressed, or
the worker reaches for an unjustified rewrite.

## Operating Modes

### Balanced-only

Use for ordinary bounded work: inspect, state the plan and acceptance criteria,
implement, run focused and broader checks, and review the diff for scope.

### Sol diagnosis and envelope → Terra implementation → Sol check

This is the conservative GPT-5.6 pattern:

1. Sol investigates or validates the diagnosis and approves the execution
   envelope.
2. Terra implements only that bounded envelope and returns evidence plus every
   uncertainty.
3. A fresh Sol checker challenges intent achievement, the diff, evidence,
   invariants, and residual risk.
4. The Sol coordinator integrates the result and owns readiness and closeout.

In portable terms: strongest diagnosis/plan → balanced implementation →
independent strongest check.

### Strongest-led

Use only when difficult diagnosis remains coupled to implementation, blast
radius is high, verification is weak, credible attempts failed, the task crosses
multiple systems, or another handoff would create material risk. The strongest
worker still makes the smallest durable change and proves it.

### Independent-model review

Use a different model when independent thinking is valuable: implementation
versus adversarial review, plan versus challenge, tests versus code, or a current
family versus GPT-5.5 as a comparison. Give the reviewer the original objective,
constraints/non-goals, plan or diff, test results, and known uncertainty; ask it
to falsify correctness rather than merely summarize.

## Risk And Effort

| Risk | Examples | Default route |
| --- | --- | --- |
| Low | docs, naming, tests, local refactors with strong coverage | fastest-low-cost or balanced |
| Medium | user-facing behavior, dependencies, jobs, caching, queries, CI, package behavior | balanced; strongest review when uncertainty is material |
| High | auth, billing, customer data, destructive migrations, security, cross-service contracts, incidents, architecture, behavior-preserving performance with weak coverage | strongest coordinator/review; strongest-led only when required |

Reasoning effort follows ambiguity and consequence, not file count:

- Low/medium: routine implementation, clear fixes, repetitive changes, narrow
  exploration, or strong tests.
- High: non-obvious bugs, competing approaches, dependency interactions,
  performance, cross-boundary changes, or incomplete coverage.
- Highest supported: the hardest investigations, high-consequence decisions,
  repeated failures, or exceptionally subtle final review.

Do not assume that maximum reasoning always improves outcomes. Measure whether
the added exploration produces a quality gain instead of unnecessary complexity.

## Agent Guardrails

Before non-trivial edits, require the worker to characterize or reproduce the
problem, identify the code path, cite evidence, state assumptions, define the
smallest change, list acceptance criteria, and explain verification.

Constrain scope:

- Do not modify unrelated files or public APIs without approval.
- Do not disable tests, types, linting, warnings, assertions, or security
  controls.
- Do not replace failures with ignored errors.
- Do not add broad abstractions without demonstrated need.
- Do not rewrite a subsystem while a local fix remains viable.
- Stop and report before materially expanding scope.

Name applicable invariants: visual appearance, functional behavior,
accessibility, API/database compatibility, security boundaries, browser support,
SSR/hydration, performance floors, errors, logs, and observability.

Use least privilege. Capability is not a substitute for sandboxing, branch
protection, review, or deployment controls.

## Verification Matrix

| Change | Minimum verification |
| --- | --- |
| Local bug fix | Failing reproduction plus relevant unit/integration suite |
| UI behavior | Component/integration checks plus visual confirmation |
| Performance | Repeatable baseline/candidate comparison plus functional and visual regression |
| Database migration | Forward migration, rollback/mitigation, data validation, compatibility window |
| Dependency upgrade | Relevant full suite, build, compatibility and changelog review |
| Authentication/authorization | Positive and negative permission tests |
| Public API | Contract tests and backward-compatibility review |
| SSR/hydration | Server output, client hydration, browser checks, mismatch detection |
| Refactor | Existing behavior tests plus unintended-API diff review |
| CI/tooling | Representative local and hosted workflow execution |

Performance acceptance requires the target metric to improve while functional
and visual behavior remain correct. A faster result that removes behavior is a
regression, not a success.

## Dispatcher Capability Preflight

Before dispatch, resolve `PR_BATCH_SKILL_DIR` through the explicit env-var,
loaded-skill, and repo-local pinned-copy chain, then call
`"${PR_BATCH_SKILL_DIR}/bin/dispatcher-capability-preflight"` with one JSON
object on standard input. It writes one JSON result to standard output and does
not launch a worker or mutate a coordination backend. The caller supplies the
lane state, requested route preference and dispatcher, explicit dispatch
authority, and ordered dispatcher candidates with stable instance identities.

Each viable candidate includes a stable prospective `instance_id` allocated or reserved by its dispatcher before launch, only for replay/fencing; the helper neither launches nor creates a worker.

Prospective `instance_id` equal to `UNKNOWN` is unusable. Replay identity is `lane_id`, dispatcher, `instance_id`, and launch token; route preference, observed host fields, and `candidate_index` are metadata and never trigger replacement.

Persist `launch-pending` before worker launch; after spawn, persist ordinary `active` state before Goal-mode resume, and replay the same token while pending or emit no new launch while active.
Assignment activation uses ordinary durable lifecycle state; no project signing key, fixed trust anchor, launch-confirmation receipt, or human waiver is required.
A dispatcher or instance change still requires stop/reconcile replacement fencing and a single-use proof bound to the exact prior and replacement assignment identities.

The helper prefers the requested route and dispatcher, but route is advisory;
only a dispatcher substitution requires explicit dispatch authority. It never
derives authority from generic subagent wording or inherits the coordinator
preference. It records preferred and selected route metadata, selected dispatcher,
reason, authority, optional observed host fields, and one active assignment/launch
token. An existing different dispatcher or instance requires a stopped,
reconciled replacement. If none is authorized, it returns `blocked-user-input`
with one stable `dispatch-decision-request v1`, including canonical viable
fallback choices; replay does not create blocker churn. A selected result permits
Goal-mode automatic resume only after the required persistence record is durable.

## Replacement And Escalation

Replacing a lane's worker instance, including an actual runtime model change,
uses the
canonical workflow’s **Worker Model Replacement And Escalation** protocol:

1. Reach a safe checkpoint.
2. Produce a durable `MODEL_REPLACEMENT_HANDOFF`.
3. Preserve the lane identity, worktree, branch, useful changes, and claim.
4. Stop the old instance.
5. Reconcile or fence ownership.
6. Record the replacement's advisory route preference and stable instance.
7. Start the replacement without overlap.

A `MODEL_ESCALATION_REQUEST` is evidence for the coordinator, not permission to
self-upgrade. Plan review is preferred; strongest-led implementation is the
exception. Pending CI/review, permissions, outages, coordination conflicts,
quota exhaustion, task size, importance, or elapsed time do not independently
prove a capability problem.

## Human Decision Gates

Require explicit human approval before destructive data operations, production
deployment, permission or security-control changes, public API breaks, major
dependency or architectural changes, broad automated rewrites, or changes whose
correctness cannot be convincingly verified.

## Measure Outcomes

Record enough final evidence to compare routing against real repository results:

- First-pass acceptance rate.
- Corrective turns and credible attempts.
- Human review minutes.
- Test failures and escaped regressions.
- Unrelated diff size and reverted changes.
- Total tokens/credits and elapsed time.
- Percentage of tasks escalated.
- Initial-diagnosis accuracy.
- Test quality and final outcome.
- Model, effort, repository, language/framework, risk, task category, and
  verification strength.

Review these results periodically. A cheaper call can cost more overall when it
causes rework, while the strongest model can be wasteful when a balanced worker
produces the same accepted result.
