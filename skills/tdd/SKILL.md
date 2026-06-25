---
name: tdd
description: Drive a portable red-green-refactor workflow for features and bug fixes. Use when implementing behavior with test-driven development, reproducing a bug as a failing test before fixing it, or when the user asks for TDD, test-first, or red-green-refactor discipline.
---

# Test-Driven Development

Memorable invocation: `$tdd`

Use this skill to move in small, verified behavior slices:

```text
RED -> GREEN -> REFACTOR -> repeat
```

## Core Loop

1. Choose one observable behavior.
   - For a bug fix, first express the reported failure as one failing regression test.
   - For a feature, start with the smallest user-visible or public-interface behavior.
   - Prefer tests through public interfaces and real code paths over tests coupled to private implementation details.
2. RED: write one failing test.
   - Run the repo's relevant test command (see `AGENTS.md` → **Agent Workflow Configuration**, **Tests** key).
   - Confirm the test fails for the right reason: the missing behavior or reproduced bug.
   - If it fails because of a typo, missing import, bad fixture, or harness problem, fix the test setup before touching production code.
   - If it passes immediately, stop. The test describes existing behavior; tighten or replace it until you have watched the intended failure.
3. GREEN: write the smallest production change that makes that test pass.
   - Do not add production code before a failing test exists.
   - Do not add speculative behavior for future tests.
   - Rerun the same targeted test and confirm it passes.
4. REFACTOR: improve while green.
   - Remove duplication, clarify names, and simplify structure only with tests passing.
   - Rerun the targeted test after each meaningful refactor step.
5. Repeat with the next behavior.
   - Add one new failing test at a time.
   - Keep each cycle narrow enough that a failure clearly points to the current behavior.

## Guardrails

- Never refactor while RED.
- Never batch-write all tests before implementation; use vertical slices.
- Never claim a bug is fixed without evidence: prefer a regression test that failed before the fix and passes after it.
- Only when a direct automated regression test is not practical, document why, then use the closest useful local verification (see `AGENTS.md` → **Agent Workflow Configuration**, **Tests** key) to capture before and after behavior.
- Before handoff or PR creation, run the repo's pre-push local validation (see `AGENTS.md` → **Agent Workflow Configuration**, **Pre-push local validation** key) in addition to the targeted tests used during the loop.

## Done

The loop is complete when all observable behaviors specified in the task or issue are covered by passing tests and the pre-push validation passes clean. Report the behaviors implemented, the tests added, and the result of the pre-push validation.
