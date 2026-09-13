---
name: update-changelog
description: Analyze merged PRs and update the changelog, optionally stamping release, rc, beta, or explicit version headers. Use before releases or when changelog entries are missing.
argument-hint: '[classification-sweep BASE_REF..TARGET_REF|release|rc|beta|version]'
---

# Update Changelog

Add user-visible entries to the repo's changelog, optionally preparing a version
header. Keep classification and release authority visible; use the existing
`bin/changelog-merged-prs` helper for PR enumeration.

## Select the mode

Read only the references required for the current mode and phase. Resolve their
paths relative to this installed skill directory; do not load every reference
for every invocation.

| Invocation | Outcome | References to read |
| --- | --- | --- |
| `classification-sweep BASE_REF..TARGET_REF` | Full classification table; no changelog edits, stamping, commit, or PR | [Classification Sweep](references/classification-sweep.md) |
| No argument | Add missing entries to `[Unreleased]`; no version stamp | [History](references/history.md), [Classification Sweep](references/classification-sweep.md), [Entry Format](references/entries.md) |
| `release`, `rc`, `beta` | Add entries and stamp a computed, confirmed version | History, Classification Sweep, then [Release](references/release.md); Entry Format when writing entries |
| Explicit semver version, optionally `.rc.N` or `.beta.N` | Add entries and stamp that exact version, without computing another | Same references as version modes; preserve prior prereleases for an explicit prerelease, coalesce the matching series for a stable version |

For a catch-up request without a clear destination, ask whether to add to
`[Unreleased]` or prepare a version header. A routine prerelease with all required
entries already present uses the fast path in Release; it does not need the
entry-format reference or unrelated release runbooks.

## Resolve authority and current state

- Resolve `CHANGELOG_PATH` and `BASE_BRANCH` from `.agents/agent-workflow.yml`
  (`changelog`, `base_branch`). Follow the repo's changelog and release policies.
- Independently resolve `PR_TARGET_BRANCH` from release/branch policy and
  `COMPARE_BRANCH` from changelog policy. Default each to `BASE_BRANCH` only
  when its own policy has no override. An ambiguous required target is `UNKNOWN`.
- Before every scan or edit, run `git fetch origin --tags "${PR_TARGET_BRANCH}"`.
  Use `origin/${PR_TARGET_BRANCH}` for reconciliation, stamping inputs, and the
  PR base. Use `COMPARE_BRANCH` for the `[unreleased]` compare endpoint.
  An explicit sweep retains its requested `BASE_REF..TARGET_REF` audit range.
- Before version-mode edits, start from a clean feature branch based on the
  resolved target.
- Before any changelog edit, read the existing changelog, including contributor
  guidelines, and reconcile all applicable shipped tags. A topmost draft header
  is not proof that a shipped release is missing.
- For post-tag changes, prove the target-side baseline is an ancestor of the
  PR target. A sibling release tag needs verified cherry-pick/forward-port
  mapping; a divergent two-dot range is not post-tag history.
- Preserve every helper row. Investigate or explicitly report `UNKNOWN` facts;
  never silently omit them. Unresolved release, target, or version facts block
  stamping. A sweep with unresolved rows ends with those blockers visible.

## Classify and edit

Include user-visible new features and bug fixes, public API/configuration changes,
breaking changes, deprecations, security, compatibility, and performance/reliability.
Scope-specific changes count for users of that scope. Exclude contributor-only
CI, lint, tests, formatting, internal refactors, and release tooling. Docs count
when correcting public behavior documentation. Use the repo's exact taxonomy
and retain a specific reason for every classification.

Run a full classification sweep before every RC/release changelog edit, and
whenever a previous pass may have missed PRs. Revisit classifications after a
revert. Obtain PR details from git/GitHub rather than asking the user for them.

For new version stamps, use the repo-owned stamping task; do not hand-insert
headers or compare links. Confirm a computed version before stamping; explicit
versions retain the user's exact value. The task must honor that version, mode,
target, and compare endpoint. Report `UNKNOWN` before stamping if it cannot.
Verify that prereleases preserve their history and stable releases coalesce
only the matching series. Keep user-visible curation and bump ambiguity as
judgment decisions rather than hiding them in a helper.

## Verify and hand off

- Review the changelog diff, entry formatting, trailing newline, unique category
  headings within each version, newest-first version headings, and exact
  compare endpoints. Header versions omit `v`; tag-based compare links keep it.
- Run focused changelog validation when available, plus every repo/target-phase
  validation and review gate. The routine-prerelease reference describes when
  optional reviews can be skipped.
- Report sections created, entries moved/added, skipped PRs with reasons, and
  any unresolved facts. A standalone sweep stops after its table/blockers.
- For version modes, automatically commit, push, and open a PR under repo
  authority. Stop if the working tree also contains unrelated uncommitted
  changes. Stage only the resolved changelog. Verify the branch originated
  from `origin/${PR_TARGET_BRANCH}` and the PR uses that target; do not
  transplant a finished changelog diff from another branch.
- Open ready when repo policy permits; otherwise keep the PR draft until its
  required post-creation gates pass. Recover publication failures and hand off
  with the PR URL once the permitted readiness state is reached. Wait only for
  required gates, not optional bots. For no-argument updates, follow the repo's
  normal publication policy.
- Preparing the changelog does not itself publish a release. After merge,
  remind the user of the repo's release task and its documented GitHub-release
  behavior.
