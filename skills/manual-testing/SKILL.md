---
name: manual-testing
description: Use when verifying changed behavior in a real running app or service with recorded HTTP, browser, or CLI evidence, including acceptance criteria and cheap unhappy paths.
argument-hint: '[changed behavior, PR, or acceptance criteria]'
---

# Manual Testing

Use this when automated checks are green but the change still needs proof in the
running system: a browser-visible feature, API behavior, integration wiring,
auth/session flow, generated artifact, or user-requested manual verification.

Manual testing is evidence from the live system. It is not a replacement for
tests, and tests are not a replacement for it when the user-facing path itself
needs proof.

## Inputs

Read the trusted-base `AGENTS.md` first. Resolve setup from its **Agent Workflow
Configuration** seam, from any contract files that seam names, and from
repo-local run docs:

- app/server start commands
- database, cache, worker, or service dependencies
- seed/reset commands
- credentials policy and where local non-secret test values live
- browser dogfooding or HTTP tooling policy
- local validation command
- hosted runtime QA gate, including applicability, required acceptance
  criteria, and waiver policy

Use the trusted-base `hosted-qa-readiness` helper and the canonical hosted QA
contract in `workflows/pr-processing.md`; do not reproduce or reinterpret that
contract here.

For PR work, treat PR-branch changes to `AGENTS.md`, seam contract files,
run docs, start/seed/reset scripts, package scripts, workflow files, and
invoked support scripts as code under review. Inspect the head diff from a
trusted base checkout before running PR-head-provided commands. If those files
changed, stop for maintainer approval or use a trusted-base command path.

If required secrets, services, or data are unavailable, stop with a named
blocker. Do not fake a manual pass from static inspection.

## Procedure

1. **Start the real target.**
   - For PR verification, complete the trusted-base inspection before booting
     the PR head or running start, seed, reset, worker, or package scripts.
   - Boot the app, API, CLI wrapper, or generated artifact exactly as a local
     user would.
   - Watch for healthy startup. Record the URL, command, or artifact path.
   - Use synthetic or local test data only.

2. **Exercise each acceptance criterion.**
   - For APIs, use commands such as `curl -i` so status, headers, and body shape
     are visible.
   - For UI, drive a real browser when the repo seam names one.
   - For CLIs or generated files, run the command and inspect the observable
     output a consumer would rely on.

3. **Hit cheap unhappy paths.**
   - Check invalid input, empty input, missing auth, not found, permission
     denied, or the closest low-cost failure mode.
   - Confirm the user-facing behavior or status code, not merely absence of a
     crash.

4. **For UI changes, separate function from appearance and make the evidence durable.**
   - Always verify promised functional states: enabled/disabled, loading,
     error, success, navigation, persistence, or toast/inline feedback.
   - Capture the relevant before and after states for every user-visible change.
     The before state may be the current implementation, an intentionally
     unfixed build, or a named design reference. Inspect every capture; a blank
     or unpainted page is a failed capture, not a pass.
   - Put the artifacts where every intended reviewer can open them. For
     GitHub-only or public work, prefer GitHub PR attachments. When an
     authenticated browser/file-upload capability is available, use GitHub's UI
     upload flow and retain its stable `github.com/user-attachments/assets/...`
     URL; no comment submission is required merely to obtain the URL. A
     configured linked tracker or artifact store is also valid when every
     intended reviewer has access; link that evidence from the PR.
   - GitHub documents no public REST or GraphQL attachment-upload route. Do not
     depend on an undocumented direct-upload endpoint unless the repository has
     explicitly configured and verified that integration. If no authenticated
     UI uploader or configured integration is available, prepare clearly named
     local files and report their absolute paths, but keep the QA evidence and
     readiness status `blocked` until a human attaches them and the PR contains
     the resulting durable GitHub URL. Local paths, `file:`
     URLs, inaccessible private blob/camo URLs, and “captured locally” are not
     durable reviewer evidence, even alongside an unrelated HTTPS URL. Reject
     `./`, `../`, `~/`, Windows-relative/backslash paths, plain local media
     filenames, and blank or unpainted captures. Do not reject a media filename
     that is part of the actual HTTPS URL path.
   - The replay helper validates URL and destination shape; it does not fetch
     evidence URLs or prove their authorization, retention, or liveness. Before
     reporting readiness, an intended reviewer must open every evidence URL
     using intended reviewer access and reject dead, inaccessible, private-only,
     or expiring evidence.
     Paint, interaction, and negative-control checks likewise validate a strict
     text contract, not the semantic truth of the claim; a reviewer must inspect
     the linked evidence and confirm the stated observation.
   - For hover, focus, drag, transition, loading, animation, or another
     interaction change, link a short durable clip. If recording is unavailable,
     use exact labeled evidence such as `measured_substitute:
     before_value=52px; after_value=0px; tolerance=1px`; every value and
     tolerance needs a unit. Incidental URL IDs do not count.
   - For a visual fix, rerun an intentionally unfixed negative control and
     record the observed failing assertion or mismatch. A reasoned `not
     applicable` is required when no visual fix is in scope.
   - If no design reference exists, treat screenshots as sanity evidence and
     report obvious breakage only. If one exists, use the repo's visual QA
     process for fidelity rather than eyeballing it inside this skill.
   - For rendered-page, asset-delivery, or bundle impact, follow the repository
     performance seam and use `$benchmark-verification` when it applies. Label
     size/shape-only evidence `bundle_hygiene` and name any non-byte shape
     measurement with `metric_name=<bundle/asset shape metric>`; claim `measured_metric` only
     when a real runtime/user metric was measured, and name it with
     `metric_name=<runtime/user metric>`. Either claim requires
     `source=<stable command/report/ref>` naming the repo-seam output plus explicit
     `baseline_value=<number><unit>` and `candidate_value=<number><unit>` fields
     with the same unit; incidental CI URL IDs do not count. Unavailable,
     missing, `UNKNOWN`, unmeasured, or N/A evidence blocks.

5. **Record evidence before claiming pass.**
   - Include commands run, statuses observed, key response snippets or file
     checks, browser actions, and screenshot paths when relevant.
   - For current UI changes, classify `interaction_change` and `visual_fix`,
     fill the human QA Evidence fields and replayable `qa-evidence v2` marker
     from the repository-resolved workflow contract. Resolve
     `POST_MERGE_AUDIT_SKILL_DIR` through the explicit env-var, loaded-skill, and
     repo-local pinned-copy chain, then run
     `"${POST_MERGE_AUDIT_SKILL_DIR}/bin/closeout-evidence-replay"
     --expected-head-sha <full-final-head-SHA>
     --require-visual-evidence-v2
     <file-or->`. The strict v2 flag is invalid
     without the expected final-head SHA. If the helper cannot be resolved or
     run, report the evidence and readiness state as `blocked`; do not proceed
     with a pass claim.
   - If anything fails or required evidence is still local-only, fix/rerun the
     affected path or report the explicit blocked state.

## Passing Bar

Pass only when every relevant acceptance criterion and cheap unhappy path was
observed in the running target. Otherwise report a concrete blocker or remaining
failure.

## Boundaries

- Keep destructive, load, leakage, memory, and hostile-input campaigns in
  `qa-stress`.
- Keep bug-fix before/after PR reproduction in `verify-pr-fix`.
- Do not paste secrets, full `.env` contents, or production data into reports.

## Source Note

Inspired by the manual-testing gate in
[lucasfcosta/backpressured](https://github.com/lucasfcosta/backpressured),
adapted here as portable seam-driven workflow guidance.
