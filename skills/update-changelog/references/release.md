# Release and Prerelease Modes

Read only for version stamping or release curation, after [history reconciliation](history.md) and [classification](classification-sweep.md).

## Auto-Computing the Next Version

When stamping a version header (`release`, `rc`, or `beta`), compute the next version as follows. Run this subroutine only after resolving `PR_TARGET_BRANCH` and reconciling history:

1. **Find the latest reachable prior stable version tag** on the resolved PR target using semver sort:

   ```bash
   git tag --merged "origin/${PR_TARGET_BRANCH}" -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1
   ```

   Use this reachable tag as the stable bump baseline even when it belongs to the preceding release series. Constrain only existing `rc`/`beta` tags and their next-index selection to the intended target version series. If target reachability or the intended prerelease series is ambiguous, report `UNKNOWN` before editing.

2. **Determine bump type from changelog content**:
   - If changes include `#### Breaking Changes` or `#### ⚠️ Breaking Changes` -> **major** bump
   - If changes include `#### Added`, `#### New Features`, `#### Features`, or `#### Enhancements` -> **minor** bump
   - If changes only include `#### Fixed`, `#### Security`, `#### Improved`, `#### Changed`, `#### Deprecated`, or `#### Removed` -> **patch** bump

3. **Compute the version**:
   - For `release`: Apply the bump to the latest stable tag (e.g., `16.4.0` + minor -> `16.5.0`)
   - For `rc` or `beta`: Apply the bump to get the stable target core, set `TARGET_VERSION` to that `X.Y.Z` value, and set `PRERELEASE_KIND` from the invocation mode (`rc` or `beta`). Then use the matching fetched tags to find the next index (e.g., if `v16.5.0.rc.0` exists -> `16.5.0.rc.1`). **Do NOT use changelog headers** to determine the next index — a version header in the changelog is a draft that may not have been released yet. Only git tags represent shipped versions.

4. **Verify**: Check that the computed version is newer than all existing tags in the target release series and does not collide with any repository tag. If not, ask the user what to do.

5. **Show the computed version to the user and ask for confirmation** before stamping the header. If the bump type is ambiguous (e.g., changes could reasonably be classified as patch vs minor, or the changelog headings don't clearly signal the bump level), explain your reasoning for the suggested bump and ask the user to confirm or override before proceeding.

## Stamp with the repo task

When this command is invoked with `release`, `rc`, `beta`, or an explicit version (e.g., `16.5.0.rc.10`), **use the repo's changelog version-stamping task** documented by that repo's changelog policy to stamp the version header after adding entries. Prefer an interface that binds the resolved mode or explicit version, exact confirmed version, and `COMPARE_BRANCH` together. A documented one-argument task is also allowed when its target and compare defaults are verified to match `PR_TARGET_BRANCH` and `COMPARE_BRANCH`, and its produced version and output exactly match the confirmed expectations. Otherwise report `UNKNOWN` and stop before stamping.

The version-stamping task handles:

- Auto-computing the next version from git tags (prerelease index is determined solely from tags, not changelog headers)
- Inserting the version header right after `### [Unreleased]`
- Updating version diff links at the bottom of the file
- For `release` mode: collapsing prior `rc`/`beta` sections of the same base version into the new stable section (rc/beta modes leave prior prerelease sections intact so users can see what changed between RCs)

Do NOT manually insert version headers or update diff links -- require the version-stamping task to honor the confirmed version, mode semantics, and compare endpoint, then verify them in its output.

Verify the exact confirmed header, newest-first ordering, and compare endpoints after the task runs. Headers omit the tag's `v` prefix; compare URLs retain it. The top header may be an untagged draft, not the latest shipped release.

## Fast path for routine prerelease stamps

Use this path when `rc`, `beta`, or an explicit prerelease should only generate a version heading and compare links,
the required entries are already under `[Unreleased]`, and the sweep has no missing entry or unresolved `UNKNOWN` row.

- **One pass:** fetch, reconcile, sweep, stamp, focused validation, and PR. Do not inspect broad release runbooks or
  unrelated release mechanics unless explicitly asked.
- **One review:** self-review the diff once. When repo and target-phase policy permit the changelog-only exemption,
  skip optional simplify, adversarial review, review panels, and extra local AI review. Run every review gate required
  by repo or target-phase policy before marking the PR ready, and use normal gates for substantive curation,
  security/migration notes, or other files.
- **Focused validation:** run `git diff --check`; verify trailing newline, unique/newest-first headings, and compare-link
  endpoints; run a focused changelog test or formatter when available. Run the full suite only when repo policy requires it.
- **PR state:** target the branch required by repo policy and open ready when policy permits. When required hosted CI or
  review can run only after PR creation, keep the PR draft until those gates pass, then mark it ready.
- **Stop:** report classifications, validation, and the PR URL, then end. Do not poll optional CI/review bots or enable
  generic PR-helper auto-watch behavior; wait only for post-creation gates required by repo or target-phase policy.

Keep work to the fetch, reconcile, sweep, stamp, focused-validation, and PR steps above. If more is required, stop and
report why instead of silently broadening the task.

## Preserve prerelease history

When the user passes `rc` or `beta` as an argument:

1. **Derive the intended target series first.** Using the reachable stable baseline and bump type from "Auto-Computing the Next Version," apply the bump to get the stable target core and set `TARGET_VERSION` to that `X.Y.Z` value. Set `PRERELEASE_KIND` from the invocation mode (`rc` or `beta`). If either value is ambiguous, report `UNKNOWN` before listing prerelease tags.

2. **Find the latest applicable prerelease tag** from the full fetched tag inventory, constrained to that target version and kind. Use target reachability as supporting evidence, not the sole filter; if a non-reachable tag's relevance is ambiguous, report `UNKNOWN` before computing the next index:

   ```bash
   git tag -l "v${TARGET_VERSION}.${PRERELEASE_KIND}.*" --sort=-v:refname | head -10
   ```

3. **Choose the next prerelease index** from those matching git tags and complete the confirmation process in "Auto-Computing the Next Version" above.

4. **Do NOT collapse prior prereleases.** Each RC/beta is a separately-tagged release that users install — they need to see what changed between, for example, `rc.0` and `rc.1` (especially when diagnosing a regression in a specific RC). Each run of the repo's release task reads only the top-most `### [VERSION]` section, so as long as each RC has its own section, the corresponding GitHub release gets its own focused notes. Instead:
   - Insert the new prerelease version section immediately after `### [Unreleased]`, **above** any prior prerelease sections (preserves newest-first ordering)
   - Any entries already under `### [Unreleased]` belong to this prerelease — the version-stamping task moves them under the new header automatically when it inserts the version line right after `### [Unreleased]`
   - Leave prior prerelease sections (e.g., `### [16.5.0.rc.0]`) untouched — keep their entries and their compare links at the bottom of the file
   - Add any new user-visible changes from commits since the last prerelease tag to the new section only
   - Add a new compare link at the bottom comparing the previous prerelease tag (or the last stable tag if this is the first RC) to the new prerelease tag
   - Update the `[unreleased]:` compare link to point from the new prerelease tag to `COMPARE_BRANCH`

**Resulting structure** after stamping `16.5.0.rc.1` (with `16.5.0.rc.0` already shipped on top of stable `16.4.0`):

```markdown
### [Unreleased]

### [16.5.0.rc.1] - 2026-03-15

#### Fixed

- **Fix regression introduced in rc.0**. [PR 2500](https://github.com/<owner>/<repo>/pull/2500) by [username](https://github.com/username).

### [16.5.0.rc.0] - 2026-03-01

#### Added

- **New feature**. [PR 2490](https://github.com/<owner>/<repo>/pull/2490) by [username](https://github.com/username).

### [16.4.0] - 2026-02-15

...

[unreleased]: https://github.com/<owner>/<repo>/compare/v16.5.0.rc.1...<compare-branch>
[16.5.0.rc.1]: https://github.com/<owner>/<repo>/compare/v16.5.0.rc.0...v16.5.0.rc.1
[16.5.0.rc.0]: https://github.com/<owner>/<repo>/compare/v16.4.0...v16.5.0.rc.0
[16.4.0]: https://github.com/<owner>/<repo>/compare/v16.3.0...v16.4.0
```

Both RC sections remain intact with their own compare links until the stable release coalesces them. **Coalescing happens only at the stable release** — see [Stable release curation](#stable-release-curation) below.

**Note**: The new version header must be inserted **immediately after `### [Unreleased]`** (by the repo stamping task). This ensures correct newest-first ordering of version headers.

## Stable release curation

When releasing from prerelease to a stable version (e.g., `v16.5.0.rc.1` -> `v16.5.0`), this is where the accumulated prerelease sections get coalesced into one stable section. **Curate carefully** — users landing on the stable version don't care about intermediate prerelease state, and noise here makes the upgrade story harder to read.

### Step 1: Coalesce all prerelease sections into one stable section

- Replace `### [16.5.0.rc.0]`, `### [16.5.0.rc.1]`, `### [16.5.0.beta.1]`, etc. (however many exist) with a single `### [16.5.0] - YYYY-MM-DD` section
- **Move any remaining entries from `### [Unreleased]` into the new stable section** — anything still under `[Unreleased]` at stable-release time is shipping in this stable version. Leave `### [Unreleased]` with only its header (no entries).
- Combine entries from all prerelease sections and the moved `[Unreleased]` entries, consolidating duplicate category headings (e.g., merge multiple `#### Fixed` sections into one under the preferred order from [Entry Format](entries.md#categories))
- Remove the orphaned compare links at the bottom of the file for the coalesced prerelease versions
- Add the `[16.5.0]` compare link pointing from the **previous stable tag** (e.g., `v16.4.0`) to `v16.5.0` — **not** from the latest RC tag
- Update the `[unreleased]:` compare link to point from `v16.5.0` to `COMPARE_BRANCH`
- **Before committing**, spot-check the compare-link updates above: orphaned RC compare links removed, the new `[16.5.0]` link anchored at the previous stable tag (e.g., `v16.4.0...v16.5.0`) — not the latest RC tag — and `[unreleased]` pointing from `v16.5.0` to `COMPARE_BRANCH`. When the repo's changelog version-stamping task (`release` mode) does the coalesce, this is handled automatically; still verify the result before pushing.

### Step 2: Curate the entries — REMOVE these

1. **Prerelease-only fixes** — bugs introduced during the prerelease cycle and fixed in a later RC. If the bug never shipped in a stable release, the fix is noise to stable users.
   - Investigate when a bug was introduced: `git log --oneline v<last_stable>..v<rc_containing_the_fix>` — search this range for the commit that introduced the bug. If the range is large and you know which files are relevant, scope it with `-- path/to/file` to cut noise. If you **find it** in this range, the bug was introduced during the RC cycle and never shipped in stable — apply the merge-or-drop rules below. If you **don't find it**, the bug predates the RC cycle and existed in `<last_stable>` — keep the fix as its own entry.
   - Check the PR description for what was broken and when
   - For RC-only regression fixes where the fix **changed user-visible behavior** of the original feature (e.g., extended an option's accepted values, adjusted a default, broadened a path matcher), **merge** the fix into the original PR's entry: credit both PRs and rewrite the description so it reflects the final shipped state. Don't drop these — stable consumers see the merged behavior, not the intermediate regression.
   - **Pure-restore** fixes (the fix only restores prior behavior without changing the original entry's description) can be dropped.

2. **Refinements to prerelease-only features** — if a new feature was introduced in `rc.0` and then iterated in `rc.1`/`rc.2`, keep only the final description and drop the iteration history

3. **Internal/contributor-only tooling** — yalc publish fixes, git dependency support, CI/build script changes, generator handling of prerelease version formats, local-dev tooling fixes. These don't belong in a user-facing changelog.

### Step 3: Curate the entries — KEEP these

1. **User-facing fixes for bugs that existed in the previous stable** — if `rc.2` fixes a bug that was in `16.4.0`, that fix matters to stable users upgrading

2. **Compatibility fixes** — language/framework version support, dependency relaxations, etc.

3. **All breaking changes** — API/CLI changes, removed methods, configuration changes, generator output changes. Even if a breaking change was introduced and refined across multiple prereleases, the final breaking change description belongs in stable.

4. **Performance/security improvements affecting all users**

**Scope-tag tagging:** When the repo's changelog policy defines an inline scope tag (such as `**[Pro]**`), scope-tagged changes stay in the changelog with that inline tag — do NOT drop them just because they only apply to that scope. Apply the same REMOVE/KEEP rules above based on whether they're prerelease-only iteration vs user-facing changes that ship to users of that scope.

### Step 4: Investigation process for each entry

For each entry that doesn't obviously fall into a REMOVE or KEEP category above, ask:

- Was this bug present in the last stable release? If no, apply the merge-or-drop rules above; a behavior-changing refinement still belongs in the final feature description.
- Was this feature introduced in an earlier prerelease and then iterated/refined across later RCs? If yes, keep only the final description and drop the intermediate history.
- Does this matter to someone upgrading from the last stable to this stable? If no, drop.

### Step 5: Final read-through

Read the resulting stable section as if you're a user upgrading from the previous stable. Every entry should be something you'd want to know about. If an entry only makes sense to someone who tracked the RC cycle, drop it.

**Example reference:** If the repo records a worked prerelease-curation example PR, consult it for a complete example of prerelease changelog curation with detailed investigation notes.
