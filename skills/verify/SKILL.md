---
name: verify
description: Run a local verification loop for the current branch before creating or updating a PR, selecting checks from the repo's binstub contract and changed files. Use when asked to verify, test, or prepare PR changes.
---

# Verify Command

Run a local verification loop for the current branch before creating or updating a PR.

Use `/verify` for local pre-PR checks. Use `/run-ci` when you need `.agents/bin/ci-detect` or want to reproduce CI job selection locally.

## Instructions

1. Read `AGENTS.md` first. It is the canonical source for boundaries and repository safety rules. Read `.agents/bin/README.md` and `.agents/agent-workflow.yml` for workflow commands and policy.
2. Resolve `BASE_BRANCH` from `.agents/agent-workflow.yml` key `base_branch`, then inspect the current branch diff
   with `git status --short`, `git diff --name-only "origin/${BASE_BRANCH}...HEAD"`, and
   `git diff --stat "origin/${BASE_BRANCH}...HEAD"`.
3. Decide the required verification set that covers the changed surface area using the **Scope Guide** below. Always
   include `.agents/bin/lint` when present, and always include `.agents/bin/validate` before
   creating a commit, even when the changed surface is documentation-only, because that gate can scan all files of its
   language, not just changed or staged ones, so docs-only commits can still expose pre-existing offenses that CI will
   catch.
4. Run each command in order and stop on the first failure. Report the failing command, the relevant error output, and the next fix to attempt.
5. For formatting failures (auto-fixable formatter or lint offenses), run the repo's documented autofix command or `.agents/bin/lint` mode when it supports fixes; do not manually edit formatting-only changes.
6. After one or more edits for a failure, restart at the failed command and continue forward. Track a loop counter per
   command:
   - Increment the counter when the same command fails on the same first item (test name, lint offense, or formatter
     file) as the previous run.
   - Reset the counter when the first failing item changes or when you advance to a different command.
   - Stop and report after three consecutive cycles on the same item, unless the user asks you to keep going.
   - Stop immediately and report a regression if a later fix causes a command that previously passed to fail again on
     the same file, symbol, or test item. Ask the user how to proceed rather than attempting a blind revert.
   - Do not claim a failure is fixed until the command passes locally.
7. Once the commands above are green, apply the **Coverage-Of-Change Gate** below and record its `COVERAGE` receipt(s). If the gate routes to `tdd` and `tdd` adds or changes files, return to step 4 for those files before recording the receipt — see the Coverage-Of-Change Gate section for why.
8. Apply the **Commit Message Contract** below when drafting or updating the commit message and PR body, and record its `COMMIT-CONTRACT` receipt.
9. Finish with the exact commands run and their pass/fail status, including the `COVERAGE` and `COMMIT-CONTRACT` receipt lines.

## Default Verification Order

Use this order unless the changed files make a narrower or broader set clearly appropriate:

1. Formatting and whitespace:
   - `git diff --check "origin/${BASE_BRANCH}...HEAD"` for committed branch content before creating or updating a PR; detects trailing whitespace and conflict markers, not source formatting
   - `.agents/bin/lint` when present, or the repo's documented formatter check
2. Mandatory pre-commit gate:
   - `.agents/bin/validate` - **mandatory gate before every commit/PR update**; see Instructions step 3 for why this still applies to documentation-only commits
3. Ruby (or the repo's equivalent backend language):
   - the repo's type/signature validation command when signatures or public APIs changed
   - the repo's targeted unit-test command for the changed backend behavior
4. JavaScript and TypeScript (or the repo's equivalent frontend/package language):
   - the repo's package build command
   - the repo's package lint command
   - the repo's type-check command
   - the repo's targeted package-test command for the changed package, or a targeted single-test-file run scoped to the
     changed package
   - the repo's full package-test command when broad package behavior changed or the touched files are not covered by a narrower package test
   - the repo's end-to-end/browser test command when the branch changes performance- or framework-sensitive areas such
     as SSR rendering, client hydration, or browser-visible integration behavior; on fresh Linux environments, install
     the e2e browser dependencies first per the repo's e2e setup
5. Docs:
   - the repo's docs-sidebar/coverage check when docs under the repo's documented docs directories changed
   - the repo's link checker when Markdown URLs were added or edited; do not substitute an ad hoc link checker unless the
     branch changes the link checker, its config, or the documented link-check workflow itself
6. CI workflows and YAML:
   - `actionlint` when any `.github/workflows/` file changed
   - `yamllint .github/` when any `.github/workflows/` file changed
   - Do not run the repo's source linter on `.yml` files
7. Broad suite — pick the narrowest command that covers the change:
   - the repo's broad-but-fast suite command for broad coverage without the slowest generated/example suites
   - the repo's full suite command when shared runtime behavior, generators, cross-package contracts, or release-critical paths changed
   - the repo's complete lint gate when a branch intentionally needs the full lint pass across all source languages and
     formatting; otherwise keep using the narrower lint commands above

## Scope Guide

- Core library/backend changes: run the repo's targeted unit tests, the mandatory pre-commit lint gate, and type/signature validation when signatures or public APIs changed.
- Integration or test-app changes: run the repo's integration test command or a targeted integration spec scoped to the changed surface. For changes that affect performance- or framework-sensitive areas such as SSR rendering or client-side behavior, also run the repo's end-to-end/browser test command.
- Frontend/package changes: run the repo's package build, package tests, package lint, and type-check commands.
- Generated examples or scripts: run the relevant generator/script command plus formatting and linting.
- Documentation-only changes: run the repo's formatter check, the docs-sidebar/coverage check for the documented docs directories, and the link checker for new or changed URLs. If committing, still run the mandatory pre-commit lint gate; see Instructions step 3 for why this applies even to docs-only commits. The lint gate does not validate Markdown.
- Package-specific frontend changes (for example a separately-packaged area with its own scripts, per `AGENTS.md`): run that package's own local formatter check via its own scripts plus any focused tests for the changed surface.
- Package-specific backend changes: run that package's own lint command (with any package-scoped flags it documents) and any targeted unit tests.
- GitHub Actions workflow changes: run `actionlint` and `yamllint .github/`. Do not run the repo's source linter on `.yml` files.
- Anything not listed above (for example, build-script edits, generator templates, signature-only changes, or build scripts): apply the narrowest set of checks that covers the changed surface and explain the choice in the output.

## Coverage-Of-Change Gate

A green run of the Default Verification Order above proves the existing suite still passes; it does not prove the change under review is covered by any test. Apply this gate whenever the branch diff from Instructions step 2 includes any file not covered by the "Documentation-only changes" classification in the Scope Guide above (that is, the diff touches non-docs source). That classification is scoped to the repo's documented docs directories; it does not cover `skills/**` or `workflows/**` prose. Those files are agent-followed behavior specifications, not documentation, and always count as non-docs source for this gate even when the diff is Markdown-only — a change to this section of this file is itself an example (see the `COVERAGE SKIPPED NO_HARNESS` treatment such a change gets, not a docs-only exemption). Skip the gate entirely only when every changed file is docs-only under the narrower, documented-docs-directory classification.

For each distinct behavior change in the diff, produce exactly one of:

1. **Named failing test — the default.** Identify the test that covers the behavior and demonstrate it fails without the change:
   - Set aside only the production hunk(s) for that behavior (for example `git stash push -- <file>` or a scoped `git apply -R` of that hunk), leaving the test as committed.
   - Run the narrowest test invocation that covers it and confirm it fails for the right reason: the reverted behavior, not a harness or setup problem.
   - Restore the production change (`git stash pop` or reapply the hunk) and rerun the same test to confirm it passes again.
   - This is the same RED/GREEN evidence `tdd` (`skills/tdd/SKILL.md`) requires when work starts test-first; here it is collected after the fact for work that was not.
   - Record the receipt as `COVERAGE <test path/name> fails without change`.
2. **Explicit skip — only from this closed set.** Free-text "no test needed" never satisfies the gate. Choose exactly one reason code:
   - `MECHANICAL` — formatting, renames, or comment-only edits with no behavior change.
   - `GENERATED` — a generated artifact (lockfile, compiled output, snapshot) produced by a documented generator command, not hand-authored logic.
   - `NOT_OBSERVABLE` — the change has no public interface or observable output any test could assert on.
   - `NO_HARNESS` — infrastructure the repo has no test harness for; name the missing harness.
   - Record the receipt as `COVERAGE SKIPPED <reason code>: <one-line factual basis>`.

**Test-only diffs.** When the entire diff is test files — a new regression test with no production change, or a fix to a previously broken or flaky test — there is no separate covering test to name, because the change *is* the test. Use the named-failing-test form on the test itself instead of a skip code: for a new regression test, show it fails against the current (unfixed) production code before any production change lands, and record that pre-fix run as the `COVERAGE <test path/name> fails without change` evidence; for a fixed broken/flaky test, show the old assertion actually catches the behavior it claims to catch (temporarily reintroduce the bug or flake condition and confirm the test now fails), then restore and confirm it passes. A test-only diff is never itself grounds for a skip code.

If no test currently covers the behavior and the gate requires a named-failing-test receipt (no skip code honestly applies, or the repo seam below forbids a skip for this path), stop and invoke `tdd` (`skills/tdd/SKILL.md`) to add one RED test for that behavior, then return here with its test path. Do not reimplement the RED/GREEN loop inline; `tdd` is the mandatory entry point, not a second implementation of it. `tdd` adds or changes files after the Default Verification Order above already ran green, so before recording the `COVERAGE` receipt, return to Instructions step 4 and rerun the relevant commands (formatter/lint, `.agents/bin/validate`, and the targeted test command) against the files `tdd` touched — a freshly added test and any accompanying production fix must pass the same gates as everything else in the diff, not skip them by arriving after the first green run.

**Repo seam (tightening only, prose-level — not machine-enforced):** when `.agents/agent-workflow.yml` defines a `coverage_of_change.never_skip_paths` list (each entry a `pattern` plus `reason`), a changed file matching one of those patterns must use the named-failing-test form; `COVERAGE SKIPPED` is not available for it regardless of reason code. Unlike `autonomous_merge.human_review_paths`, which this pack parses and enforces in code (`bin/agent_doctor/autonomous_merge_policy.rb`, with a `HUMAN_REVIEW_PATH_KEYS`/`HUMAN_REVIEW_REASONS` allowlist), `coverage_of_change.never_skip_paths` has no parser anywhere in this pack — it takes effect only if the agent following this skill reads and honors the prose. Absent the key, all four skip codes above remain available. As written policy, this seam can only add `never_skip_paths` entries — it cannot disable the gate, weaken it to advisory, or add free-text reasons or skip codes beyond the four enumerated above; nothing here stops a non-compliant agent from ignoring it, since there is no code path checking it. A consumer repo that needs machine enforcement would have to add its own parser, the way `human_review_paths` has one.

Carry every `COVERAGE` line into the PR body — see `workflows/commit-messages.md` for where this receipt belongs relative to the commit message and PR description — so it is visible at review and merge time, not only in this verification transcript.

## Commit Message Contract

Before drafting or finalizing the commit message and PR body for this change, apply the concise commit/PR contract in `workflows/commit-messages.md`:

- Match the commit body to the change: concise mode (subject plus a short `Summary`, omitting empty/template sections) for a small, single-behavior, low-risk diff; the full `Summary`/`Why`/issue-linkage contract otherwise.
- Keep decision logs, QA evidence, review dispositions, and this skill's `COVERAGE` receipts in the PR description or coordination backend, per that workflow's ownership map — do not duplicate them into the commit body unless a specific decision is essential to reading the committed code later.
- Before committing, compare the drafted commit message against the current PR description and collapse any section that says the same thing in both places, keeping the canonical copy in its owned location.
- Preserve required provenance trailers (for example issue-closing keywords and co-author trailers) and any release-note content the repo's `changelog` policy requires.

Record the result as a receipt: `COMMIT-CONTRACT <concise|full>: <one-line reason>`.

## Output Format

Use this concise summary. Per Instructions steps 4 and 7, a run stops at the first `FAIL`, before the Coverage-Of-Change Gate or Commit Message Contract are ever reached — so `COVERAGE` and `COMMIT-CONTRACT` receipts belong only in a fully green run's output, never alongside an unresolved `FAIL`.

A failing run (still in progress; no receipts yet):

```text
Verification:
- PASS git diff --check "origin/${BASE_BRANCH}...HEAD"
- FAIL <repo formatter check>

Next fix:
- Run the repo's format/autofix command to fix formatting, then rerun the formatter check.
```

A fully green run (every command passed, so the gate and contract now apply):

```text
Verification:
- PASS git diff --check "origin/${BASE_BRANCH}...HEAD"
- PASS <repo formatter check>
- PASS .agents/bin/validate
- COVERAGE <test path/name> fails without change
- COMMIT-CONTRACT concise: single mechanical fix, nothing in the PR body to collapse
```

If a command is intentionally skipped, explain why in one line. Prefer local verification over waiting for CI. In a green run, a `COVERAGE SKIPPED <reason code>` receipt, or the docs-only exemption from the Coverage-Of-Change Gate, still needs its own line; do not omit the receipt.
