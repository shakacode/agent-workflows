---
name: plan-review
description: Use when reviewing an implementation plan before coding or launching workers to check approach, scope, and repo-convention fit.
argument-hint: '[implementation plan or batch plan]'
---

# Plan Review

Use this when a plan should be checked before implementation, especially before
multi-agent work, high-risk changes, broad refactors, migration work, or any
plan whose wrong approach would be expensive to unwind.

This is a review of the approach, not a code review and not line-level design
polish. The goal is to catch unsound foundations before they become a diff.

## What To Review

1. **Goal fit.**
   - Does the plan satisfy the requested outcome and acceptance criteria?
   - Does it handle the important unhappy paths, not just the happy path?

2. **Fit with existing code and workflow.**
   - Has the plan checked actual repo conventions, helpers, `AGENTS.md` seam
     values, contract files named by the seam, and tests?
   - Does it reuse existing infrastructure instead of inventing parallel
     machinery?

3. **Simplicity.**
   - Is the approach the smallest thing that solves the real problem?
   - Does it avoid speculative options, new services, or abstractions without a
     clear present need?

4. **Load-bearing decisions.**
   - Are architecture-determining choices named now?
   - Are only reversible implementation details deferred?
   - If "where/how/which" would change whether the approach works, it is not a
     detail; require the plan to pin it down.

5. **Risks and unknowns.**
   - Are integration points, migration risk, compatibility concerns, security
     impact, performance impact, and review gates named when relevant?
   - Are blocking questions separated from non-blocking assumptions?

## Output

Return one of:

- `APPROVE`: the approach is sound and load-bearing decisions are pinned.
- `SEND BACK`: one or more approach-level issues must be resolved before work
  starts.

For each finding, include:

- severity: `BLOCKER`, `SHOULD`, or `NIT`
- the plan location or section
- the specific failure mode or missing decision
- a concrete safer alternative when one is apparent

Do not block a plan for reversible file names, variable names, or local
implementation details. Do block a plan that is too vague to prove it can work.

## Boundaries

- Use `spec` to turn fuzzy intent into requirements and tasks.
- Use `plan-pr-batch` or `pr-batch` to assign exact GitHub targets and lanes.
- Use `autoreview` or `adversarial-pr-review` once code exists.

## Source Note

Inspired by the plan-review gate in
[lucasfcosta/backpressured](https://github.com/lucasfcosta/backpressured),
adapted here as portable seam-driven workflow guidance.
