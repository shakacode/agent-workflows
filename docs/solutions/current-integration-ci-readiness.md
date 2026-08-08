---
title: Bind merge readiness to current-integration CI
date: "2026-07-31"
category: validation
component: pr-processing
problem_type: stale-base-ci-described-as-clean
symptoms:
  - A PR is described as gate-clean because its head checks passed even though the target base advanced.
  - GitHub reports a PR as CLEAN or MERGEABLE while the current merge result was never tested.
  - A read-only PR walkthrough repeats an optimistic readiness label inherited from its caller.
root_cause: Exact-head CI and GitHub conflict status were mistaken for proof that hosted CI tested the current head together with the current target base.
resolution: Bind hosted-CI evidence to the current head and base or provider-produced merge result, fail closed when that evidence is missing or stale, and reserve clean or ready language for a fully passed readiness workflow.
related_files:
  - workflows/pr-processing.md
  - skills/pr-batch/SKILL.md
  - skills/pr-monitoring/SKILL.md
  - skills/pr-walkthrough/SKILL.md
related_issues: []
---

A passing check proves only the identity that the CI provider actually tested.
If the target branch advances afterward, an exact-head check may still be
valuable evidence about the PR branch, but it does not prove the current
integration candidate.

GitHub's `CLEAN` merge state is also narrower than it sounds: it reports that
GitHub can compute a merge without a detected conflict. It does not establish
that hosted CI ran, that the merge result passed, or that every readiness gate
is satisfied.

Before using reassuring readiness language, record the exact current head, the
current target-base SHA, and the tested identity. The tested identity must be
either a head that incorporates the current base or a provider-produced merge
result bound to both. A run tied to an older head or an earlier base is stale.

When the required run is absent, lead with:

> **HOSTED CI NOT RUN FOR CURRENT INTEGRATION CANDIDATE — NOT MERGE-READY.**

Use equally direct wording for pending, failed, stale, or `UNKNOWN` evidence and
keep the target in `waiting-on-checks-or-review`. Do not improvise labels such
as `gate-clean`.

The walkthrough remains read-only. It may explain an untested diff while
displaying the warning, but it must not run CI or turn explanation into
readiness. A merge-authority caller owns requesting CI and must not enter the
walkthrough gate until current-integration CI passes.
