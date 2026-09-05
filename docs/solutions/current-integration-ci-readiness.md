---
title: Gate ask walkthroughs on current-integration CI
date: "2026-08-31"
category: validation
component: pr-batch-integration-closeout
problem_type: stale-integration-walkthrough-start
symptoms:
  - An ask-authority walkthrough starts after exact-head CI even though the target base advanced.
  - A provider-specific status is treated as portable CI success.
  - Final merge assurance catches stale integration evidence only after the walkthrough.
root_cause: The ask walkthrough sequencing gate did not establish current-integration CI readiness before spending maintainer review time.
resolution: Require trusted live head/base integration facts and normalized CI success before the ask walkthrough, then run the separate final machine gate before merge.
related_files:
  - workflows/pr-batch-integration-closeout.md
  - skills/pr-monitoring/SKILL.md
  - skills/pr-walkthrough/SKILL.md
related_issues: []
---

Exact-head CI proves the head that the CI provider tested. It does not by itself
prove that the same head remains valid with the current target base.

The merge path already carries `current-integration-evidence` through merge
assurance and replays the candidate before submission. The `ask` path runs
earlier and must not claim evidence emitted only by that later machine path.
Instead, it uses a trusted live checklist before spending the maintainer's time
on an interactive walkthrough. This early check sequences the workflow; it does
not define another evidence schema or replace final replay.

Resolve the exact head and current base. Require that the head contains that
base and that exact-head CI has the readiness contract's normalized successful
state (`READY` for `pr-ci-readiness` v2). Raw provider conclusions are not
portable success values. Unknown or future values fail closed.

A proven-behind ancestry result routes to `pr-batch-integration-closeout.md`'s
Integration And PR Publication step 3 for base reconciliation instead of
waiting — that state never clears through polling. If CI alone is missing,
stale, non-reusable, mismatched, or not successful, keep the target in
`waiting-on-checks-or-review` and do not start an ask-authority walkthrough,
leading with the current-integration warning instead.
A standalone read-only walkthrough may still explain the diff, but it never
evaluates this checklist itself, so it reports current-integration readiness as
not evaluated (`UNKNOWN`) rather than reusing that warning or any merge
readiness claim.
