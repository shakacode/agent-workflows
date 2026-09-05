# Skill Guide

Use this guide to choose a workflow by the job you are trying to do. Invoke a
skill by naming it in your request, for example `$verify`. The linked
`SKILL.md` files are the agent-facing contracts; the descriptions here explain
when a person would choose each one.

## Plan the work

### [`$spec`](../skills/spec/SKILL.md)

Use `$spec` when an implementation request is still ambiguous. It turns rough
intent into requirements, design decisions, and executable tasks before work
is assigned.

### [`$evaluate-issue`](../skills/evaluate-issue/SKILL.md)

Use `$evaluate-issue` before investing in a proposed issue or fix whose value,
scope, or technical premise is uncertain. It checks the report against the
real repository and recommends whether to implement, revise, defer, or close
it.

### [`$plan-review`](../skills/plan-review/SKILL.md)

Use `$plan-review` when you already have an implementation plan but want a
second pass before coding. It looks for scope mistakes, missing validation,
and approaches that do not fit the repository.

### [`$plan-issue-triage`](../skills/plan-issue-triage/SKILL.md)

Use `$plan-issue-triage` to prepare a review-only audit of an issue backlog. It
produces a bounded prompt for classifying issues without authorizing code
changes.

### [`$triage`](../skills/triage/SKILL.md)

Use `$triage` when you need a live map of open issues, PRs, dependencies, and
available capacity. It turns that inventory into a practical split of work
that can run concurrently.

### [`$plan-pr-batch`](../skills/plan-pr-batch/SKILL.md)

Use `$plan-pr-batch` to decide which issues or existing PRs belong in the next
delivery batch. It groups compatible lanes, recommends worker assignments,
and produces the goal that starts `$pr-batch`.

## Build and verify

### [`$tdd`](../skills/tdd/SKILL.md)

Use `$tdd` for a behavior change or bug fix that should be driven by a failing
test. It keeps the work in a red, green, refactor loop and preserves the
failure as regression evidence.

### [`$verify`](../skills/verify/SKILL.md)

Use `$verify` before committing, pushing, or updating a PR. It selects the
repository's relevant local checks from the changed files and loops until they
pass or a precise blocker is known.

### [`$run-ci`](../skills/run-ci/SKILL.md)

Use `$run-ci` when you want to choose and run one or more repository-defined CI
jobs locally. It explains which jobs apply rather than blindly running every
available check.

### [`$replicate-ci`](../skills/replicate-ci/SKILL.md)

Use `$replicate-ci` when hosted CI fails even though local validation is green.
It works toward runner and toolchain parity so the real CI-only failure can be
reproduced and fixed.

### [`$manual-testing`](../skills/manual-testing/SKILL.md)

Use `$manual-testing` when correctness must be demonstrated in a real app,
service, browser, HTTP endpoint, or CLI. It records acceptance criteria plus a
small set of meaningful unhappy-path checks.

### [`$benchmark-verification`](../skills/benchmark-verification/SKILL.md)

Use `$benchmark-verification` for performance-sensitive changes. It compares
repeated baseline and patched runs, accounts for noise, and produces evidence
strong enough to support a performance claim.

### [`$fix-flaky-tests`](../skills/fix-flaky-tests/SKILL.md)

Use `$fix-flaky-tests` when a CI failure is intermittent. It classifies the
source of nondeterminism, fixes the systemic cause, and requires green hosted
evidence rather than treating a lucky local pass as proof.

### [`$verify-pr-fix`](../skills/verify-pr-fix/SKILL.md)

Use `$verify-pr-fix` when a bug-fix PR needs direct proof. It reproduces the
failure before the fix, confirms the same path succeeds afterward, and records
the evidence on the PR when appropriate.

## Review quality and risk

### [`$autoreview`](../skills/autoreview/SKILL.md)

Use `$autoreview` as a structured second-model review before shipping. It
reviews the current diff, verifies each suggestion against the code, and loops
until the actionable findings are resolved.

### [`$adversarial-pr-review`](../skills/adversarial-pr-review/SKILL.md)

Use `$adversarial-pr-review` when a PR deserves a skeptical red-team pass. It
looks for correctness, security, compatibility, validation, changelog, and
cross-change risks that a normal review may miss.

### [`$structural-review`](../skills/structural-review/SKILL.md)

Use `$structural-review` when code may be correct but still make the codebase
harder to change. It focuses on file growth, scattered conditionals, weak
abstractions, layer violations, and accumulating branching debt.

### [`$type-design-review`](../skills/type-design-review/SKILL.md)

Use `$type-design-review` for data models, signatures, parsers, casts, and state
machines. It asks whether invalid states are easy to represent and whether the
types communicate the real domain rules.

### [`$address-review`](../skills/address-review/SKILL.md)

Use `$address-review` after reviewers have commented on a PR. It fetches every
thread, classifies the feedback, fixes or discusses the valid findings, and
records a complete disposition instead of silently skipping comments.

### [`$secure-github-actions`](../skills/secure-github-actions/SKILL.md)

Use `$secure-github-actions` to audit repository workflows and composite
actions. It checks expression injection, secret inheritance, mutable external
references, and dependencies outside the trusted action allowlist.

### [`$untrusted-contributor-intake`](../skills/untrusted-contributor-intake/SKILL.md)

Use `$untrusted-contributor-intake` for a PR from an outside contributor whose
branch cannot yet be trusted. It inspects metadata and diff evidence without
executing the contributor's code, then gives the maintainer a clear intake
decision.

### [`$qa-stress`](../skills/qa-stress/SKILL.md)

Use `$qa-stress` only for explicitly authorized destructive testing of a
repo-owned target. It is designed for fault injection, hostile inputs,
resource leakage, degradation, and other stress campaigns that need strict
safety boundaries.

## Deliver and close pull requests

### [`$pr-batch`](../skills/pr-batch/SKILL.md)

Use `$pr-batch` to run one or more issue or PR lanes through implementation,
validation, review, and merge readiness with coordinated workers. It is the
execution workflow after the targets and authority are clear.

### [`$pr-monitoring`](../skills/pr-monitoring/SKILL.md)

Use `$pr-monitoring` after a PR is open and needs active supervision. It tracks
current-head checks, new comments, conflicts, review state, and the final
handoff without starting a separate implementation lane.

### [`$batch-status`](../skills/batch-status/SKILL.md)

Use `$batch-status` for a read-only snapshot of a dispatched batch. It reports
each lane in the shared readiness vocabulary so you can see what is done,
running, blocked, or awaiting a decision.

### [`$pr-walkthrough`](../skills/pr-walkthrough/SKILL.md)

Use `$pr-walkthrough` when a human wants to understand a PR before deciding on
it. A direct chat request uses live, read-only, one-concept-at-a-time exploration.
The agent prepares the complete exact-diff map first. When a recorded `ask`
workflow selects publication, or the user explicitly requests published-review
mode with comment authority, it publishes separately replyable GitHub threads
for asynchronous discussion under the skill's publication contract.

### [`$close-batch`](../skills/close-batch/SKILL.md)

Use `$close-batch` when a batch has become stale or its lifecycle is unclear.
It recovers ownership, resumes canonical closeout, routes any needed human
decision, and archives tasks only when their work is durably handed off.

### [`$post-merge-audit`](../skills/post-merge-audit/SKILL.md)

Use `$post-merge-audit` after concurrent PRs merge or before a release
candidate. It checks cross-PR interactions, missed reviews, unresolved
follow-ups, changelog coverage, and release risk.

### [`$update-changelog`](../skills/update-changelog/SKILL.md)

Use `$update-changelog` in the dedicated changelog or release lane. It
classifies merged PRs, updates the changelog, and can stamp an explicitly
requested release, RC, beta, or version heading.

## Manage a work session

### [`$continue`](../skills/continue/SKILL.md)

Use `$continue` after an interruption or handoff. It reconstructs what is done,
what remains, and how completion will be verified before resuming work.

### [`$status`](../skills/status/SKILL.md)

Use `$status` when you want a concise progress report without starting new
work. It answers what is done, in progress, blocked, and next.

### [`$pause`](../skills/pause/SKILL.md)

Use `$pause` before restarting Codex, Claude, or another agent runner. It
produces restart-safe pause and resume prompts that preserve the current work
and recovery steps.

### [`$close-session`](../skills/close-session/SKILL.md)

Use `$close-session` when a task may be finished and you want to know whether
it is safe to archive. It verifies live state, records the outcome and
follow-up owner, and gives an explicit archive-readiness verdict.

### [`$task-observer`](../skills/task-observer/SKILL.md)

Use `$task-observer` only when you explicitly want to capture sanitized lessons
for improving skills or workflows later. It is optional meta-maintenance, not
a gate for ordinary software delivery.
