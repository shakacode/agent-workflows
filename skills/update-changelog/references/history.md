# Reconcile History

Read before editing entries or stamping a version. The entrypoint owns target resolution and fetching.

## Reconcile tags with changelog sections

**This step catches missing version sections and is the #1 source of errors when skipped.**

1. Build the applicable release-tag inventory from all fetched tags, using repo release/changelog policy and the intended version series; do not require every candidate to be an ancestor of the PR target because sibling release branches may be cherry-picked or forward-ported. Use target reachability as supporting evidence, not the sole filter. If policy, version, and changelog evidence cannot prove a non-reachable candidate's relevance, carry it as `UNKNOWN` instead of silently omitting it.
2. Get the most recent version header in the changelog (the first `### [VERSION] - DATE` after `### [Unreleased]`)
3. **Compare them.** If the latest git tag (minus the `v` prefix) does NOT appear anywhere in the changelog version headers, there are tagged releases missing from the changelog. **Important**: Don't just compare against the _top_ changelog header — a version header may exist _above_ the latest tag if it was stamped as a draft before tagging. Check whether the tag's version appears in _any_ `### [X.Y.Z]` header. For example:
   - Latest tag: `v16.4.0.rc.4`, and no `### [16.4.0.rc.4]` header exists anywhere in the changelog
   - **Result: `16.4.0.rc.4` is missing and needs its own section**
   - But if `### [16.5.0.rc.0]` is the top header (a draft, not yet tagged) and `### [16.4.0.rc.4]` exists below it, then nothing is missing — the top header is simply a pre-release draft

4. For EACH missing tagged version (there may be multiple):
   a. Find commits in that tag vs the previous tag: `git log --oneline PREV_TAG..MISSING_TAG`
   b. Extract PR numbers and fetch details for user-visible changes
   c. Check which entries currently in `### [Unreleased]` actually belong to this tagged version (compare PR numbers against the commit list)
   d. **Create a new version section** immediately before the previous version section:

   ```markdown
   ### [16.4.0.rc.4] - 2026-02-22
   ```

   e. **Move** matching entries from Unreleased into the new section
   f. **Add** any new entries for PRs in that tag that aren't in the changelog at all
   g. **Update version diff links** at the bottom of the file:
   - Update `[unreleased]:` to compare from the newest tag to `COMPARE_BRANCH`
   - Add a link for each new version section

5. Get the tag date with: `git log -1 --format="%Y-%m-%d" TAG_NAME`

## Add entries after the verified target-side baseline

1. Resolve `POST_TAG_BASE` for the applicable tag from reconciliation above. Use `LATEST_TAG` only when it is an ancestor of `origin/${PR_TARGET_BRANCH}`. For a non-ancestor sibling-branch tag, derive a verified equivalent target commit or range from repo release/changelog policy plus cherry-pick or forward-port evidence; if that mapping is not provable, carry it as `UNKNOWN` and stop before classifying post-tag commits.
2. Verify `POST_TAG_BASE` is an ancestor of `origin/${PR_TARGET_BRANCH}` before using the range. A divergent two-dot range is not post-tag history.
3. Use the existing helper with `BASE_REF=POST_TAG_BASE` and `TARGET_REF=origin/${PR_TARGET_BRANCH}`, following [Classification Sweep](classification-sweep.md). Preserve every row, including `UNKNOWN`; do not replace helper enumeration with a PR-number grep.
4. Revisit affected classifications when a revert lands before stamping.
5. For each PR number, check if it's already in the changelog: `CHANGELOG_PATH="${CHANGELOG_PATH:?set CHANGELOG_PATH from .agents/agent-workflow.yml changelog}"; grep "PR ${PR_NUMBER:?set PR_NUMBER}" "${CHANGELOG_PATH}"`
6. For PRs not yet in the changelog:
   - Get PR details: `gh pr view NUMBER --json title,body,author` (add `--repo OWNER/REPO` when not in the repo)
   - **Never ask the user for PR details** - get them from git history or the GitHub API
   - Validate that the change is user-visible (per the criteria above). Skip CI, lint, refactoring, test-only changes.
   - Add the entry to `### [Unreleased]` under the appropriate category heading
