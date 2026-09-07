# Classification Sweep

Use `classification-sweep` before every RC/release changelog edit, and whenever a prior changelog pass might have missed a merged PR. This is a mechanical coverage pass: it classifies every merged PR in the selected range, then humans review the classifications before entries are written. For ordinary entry updates, use the same enumeration and classification rules; the full table is required for an explicit sweep or RC/release pass.

### Exact PR-Listing Command

Set `BASE_REF` to the previous release tag or lower bound and `TARGET_REF` to the release tag, the configured base branch from `.agents/agent-workflow.yml`, or another upper bound being audited. Then run the committed `changelog-merged-prs` helper to list merged PRs in first-parent order. It extracts PR numbers from squash titles (the `(#NNNN)` suffix) and `Merge pull request #NNNN` subjects, falls back to GitHub's commit-to-PR API for commits that lack an inline PR number, dedups by PR number, and emits an explicit `UNKNOWN` row for any commit that still cannot be mapped.

```bash
BASE_REF="${BASE_REF:?set BASE_REF, e.g. v17.0.0.rc.1}"
BASE_BRANCH="${BASE_BRANCH:?set BASE_BRANCH from .agents/agent-workflow.yml base_branch}"
TARGET_REF="${TARGET_REF:?set TARGET_REF, e.g. v17.0.0.rc.2 or origin/${BASE_BRANCH}}"
PR_TARGET_BRANCH="${PR_TARGET_BRANCH:-${BASE_BRANCH}}"
# Resolve UPDATE_CHANGELOG_SKILL_DIR: explicit env var, loaded skill base, then repo-local pinned copy before using this fallback.
UPDATE_CHANGELOG_SKILL_DIR="${UPDATE_CHANGELOG_SKILL_DIR:-.agents/skills/update-changelog}"

# JSON array of {pr, sha, subject}; pr is an integer, or the string "UNKNOWN".
"${UPDATE_CHANGELOG_SKILL_DIR}/bin/changelog-merged-prs" "${BASE_REF}..${TARGET_REF}" --target-branch "${PR_TARGET_BRANCH}"

# Or --text for pr<TAB>sha<TAB>subject rows (UNKNOWN in the pr column):
"${UPDATE_CHANGELOG_SKILL_DIR}/bin/changelog-merged-prs" "${BASE_REF}..${TARGET_REF}" --target-branch "${PR_TARGET_BRANCH}" --text
```

The helper defaults the repo to `gh repo view`; pass `--repo OWNER/REPO` to override. Pass the resolved PR target with `--target-branch`; omitting it preserves the default-branch fallback. Run `changelog-merged-prs --help` for the full output contract and `--self-check` to validate the parser and a read-only `gh` smoke test. Each row is a merged PR for the range; rows with `"pr": "UNKNOWN"` are commits that could not be mapped to a merged PR on the selected target branch.

If any commit in the range cannot be mapped to a PR, the helper prints an explicit `UNKNOWN` row for that commit. Carry that row into the full table with `Result` set to `UNKNOWN`, investigate it, and do not finish the sweep until the row is resolved to a merged PR classification or explicitly reported as a blocker. Do not silently drop it.

A sudden spike of `UNKNOWN` rows can indicate stale GitHub authentication, API rate limits, or a temporary API failure rather than genuinely unmapped commits. Run `gh auth status` and rerun the helper when the UNKNOWN count looks suspicious.

The fallback makes one GitHub API call per commit whose subject lacks `(#NNNN)`. Typical RC ranges complete quickly, but large ranges with many direct commits can hit rate limits. Direct version-bump commits, bot commits, and release-automation commits may be expected `UNKNOWN` rows; keep them in the table with `Result` set to `UNKNOWN`, choose `internal` or `release-process`, and explain that no PR-backed changelog entry exists.

### Required Sweep Output

Print the full Markdown table. No silent caps, no "top N", and no filtering to only likely changelog entries. Every row from the helper must appear, including `no-entry` rows.

```markdown
| PR    | Title                                  | Result       | Category         | Reason                                                                                         |
| ----- | -------------------------------------- | ------------ | ---------------- | ---------------------------------------------------------------------------------------------- |
| #3595 | Async manifest signature verification  | entry-needed | perf-reliability | Moves manifest signature checks async, removing blocking filesystem work from the render path. |
| #3597 | Document release-gate tracker workflow | no-entry     | release-process  | Defines release-gate tracking docs; no product behavior changes.                               |
```

Allowed `Result` values for mapped PRs are exactly:

- `entry-needed`
- `no-entry`

Use `UNKNOWN` only for unmapped commit rows emitted by the helper; resolve or report those rows before finishing.

Allowed `Category` values are repo-specific: use exactly those defined in the repo's
changelog classification taxonomy (see the `changelog` policy in `.agents/agent-workflow.yml` and the existing changelog). Copy them exactly as
listed there, including spaces, hyphens, and casing.

Each row needs a one-line reason specific enough for review. Avoid generic reasons like "not user-visible" unless the row also says why.

### Classification Rubric

- Use `entry-needed` for user-visible product behavior: public API/config/generator changes, runtime bug fixes, compatibility changes, breaking changes, security fixes, and performance or reliability changes users would care about.
- Use `entry-needed` for scope-specific runtime changes (for example a commercial/Pro tier) that affect users of that scope — observable runtime behavior, compatibility, generated config, or logging/error changes. A scope-only change is still user-visible to users of that scope.
- Use `entry-needed` for `perf-reliability` when the PR changes runtime performance, removes blocking work, improves production recovery, or makes user-visible failures diagnosable. For example, a PR that moves manifest signature checks from synchronous filesystem calls to async checks is `entry-needed`.
- Use `no-entry` for docs-only, tests-only, formatting, lint, internal refactors, CI, benchmark harnesses, release automation, agent/process docs, and other contributor-only changes. Keep docs-only PRs as `entry-needed` when they correct incorrect public behavior documentation; classify those by the public surface they document, per the repo's taxonomy.
- Categorize by the primary surface changed, not by the changelog section it might eventually use, using the category definitions in the repo's changelog policy and existing changelog. A performance/reliability category, where the repo defines one, applies regardless of result: use `entry-needed` when the change directly benefits users at runtime (such as removing blocking work from the render path) and `no-entry` for internal benchmark harnesses or regression tooling.

### Reverts and Re-Runs

When a revert lands in the selected RC/release window, re-run the sweep or revisit affected classifications and changelog entries before stamping. Reverts can invalidate earlier `entry-needed` rows or require the original entry to be rewritten. For example, if a revert like #3860 lands after #3587, revisit the #3587 classification and changelog entry instead of carrying the original entry forward unchanged.
