# Cost-Aware Agent Model Routing

Use this guide with `$plan-pr-batch`, `$pr-batch`, and the canonical
[PR Processing Workflow](../workflows/pr-processing.md). It separates the
high-leverage coordinator from the higher-volume worker fleet, starts workers on
the least expensive safe route, and escalates only with evidence.

Shared workflow policy uses portable classes: `fastest-low-cost`, `balanced`,
and `strongest`. Exact model names and supported effort levels come from the
operator or the verified runtime roster. An operator-required exact model is a
launch invariant, not a preference that a dispatcher may silently substitute.

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

Use this fail-closed profile when an operator requires GPT-5.6 Sol control of a
batch. It is an exact operator binding, not a portable default for runtimes that
do not expose these models:

| Role | Example binding |
| --- | --- |
| Batch initiator and coordinator | GPT-5.6 Sol, high minimum |
| Independent checker, plan challenge, and consequential review | GPT-5.6 Sol, high minimum |
| High-risk or exceptionally ambiguous coordinator/checker work | GPT-5.6 Sol, highest supported effort |
| Bounded implementation and evidence gathering | GPT-5.6 Terra, medium minimum |
| Difficult but already-bounded implementation | GPT-5.6 Terra, high |
| Independent comparison or family-specific fallback | GPT-5.5 |

The initiating parent must already be bound to Sol at the required effort before
it interprets targets, approves the plan, or dispatches workers. Record the
binding source from host session metadata, runtime configuration, or explicit
operator-selected launch configuration. Prompt text, a model's self-report, an
installed model list, or a dispatch-resolved `strongest` class does not prove the
active parent assignment. A mismatch or `UNKNOWN` stops the batch for relaunch
on the required parent.

The independent checker is a fresh Sol instance, distinct from every maker, at
high effort or the highest supported effort for high-risk work. Terra may gather
mechanical evidence for the checker, but Terra does not issue the qualifying
intent-achievement, risk, or final-readiness verdict.

Terra workers start at medium effort and receive a Sol-approved execution
envelope: exact goal and non-goals, owned paths, supported diagnosis, invariants,
acceptance criteria, required verification, and stop conditions. Terra/high is
for execution complexity inside that envelope, not a substitute for Sol
diagnosis. Terra stops without editing further and returns to Sol when evidence
contradicts the diagnosis, acceptance criteria are ambiguous, scope or blast
radius grows, a high-risk boundary appears, verification weakens, or the change
requires architecture, security, performance, compatibility, or product
judgment. Luna is outside this conservative profile.

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

## Replacement And Escalation

Changing a lane’s model means replacing its worker instance. Follow the
canonical workflow’s **Worker Model Replacement And Escalation** protocol:

1. Reach a safe checkpoint.
2. Produce a durable `MODEL_REPLACEMENT_HANDOFF`.
3. Preserve the lane identity, worktree, branch, useful changes, and claim.
4. Stop the old instance.
5. Reconcile or fence ownership.
6. Bind the replacement’s exact pair.
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
