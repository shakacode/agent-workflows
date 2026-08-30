# PR Production And Release

This component owns the downstream production and release lifecycle for
PR-batch. Load it only when repository policy, the target branch, or the
explicit task selects production deployment, release-candidate, production
promotion, publishing, or release work.

## Boundary

Production and release are downstream from ordinary PR integration. This
component consumes an integrated or merged change plus repository delivery
policy. It owns release-mode and phase resolution, release trackers, production
promotion, release candidates, publishing, release rollback, and the explicit
authority required for those consequential actions.

It does not own ordinary prompt intake, worker execution, or PR integration.
Ordinary base-branch feature work does not load the downstream component.
Per-task merge authority remains separate: permission to merge never grants
permission to deploy, promote, publish, roll back, or create a release tracker.
Those actions require explicit production or release authority.

## Release Mode Preflight

Before merge readiness or auto-merge decisions, resolve the current release mode
from the live release tracker. The canonical policy is in `AGENTS.md` under
**Release Mode And Auto-Merge Coordination**; this section keeps only the worker
path so release rules do not drift.

If the consumer repo does not define release-mode or release-branching policy in
`AGENTS.md`, do not invent tracker labels, branch patterns, or forward-port
rules. Treat ordinary PRs targeting the configured base branch as `development`.
For release-affecting work, non-base target branches, or any sign that a release
tracker should exist, report release mode or phase as `UNKNOWN` and ask for the
repo policy before merge readiness.

1. Search for open release gate trackers using the tracker labels, title prefix,
   or other search policy from `AGENTS.md`. Also search the repo's configured
   recently closed tracker window before defaulting to `development`.
2. Use the canonical `AGENTS.md` tracker-selection rules to choose the
   applicable tracker, then read that tracker's `Agent Release Mode` block and
   classify the mode as `development`, `accelerated-rc`, `strict-rc`, or
   `final-release`.
3. Apply the canonical `AGENTS.md` decision for no tracker, stale tracker,
   missing release-mode block, duplicate trackers, cross-target trackers,
   accelerated-RC confidence, and final-release handling. When `AGENTS.md`
   requires reporting, post a PR comment with a `Release Mode Block:` header,
   the signal name, relevant tracker URLs, and the current decision.
4. Do not auto-create release trackers. A maintainer creates one when entering
   accelerated RC, strict RC, or final-release coordination.

## Release Phase Gate

The merge-gate strictness is a function of the **target branch's release phase**,
which composes with the mode above. The canonical phase-to-gate table is in
`AGENTS.md` under **Release-Train Branching And Phase Gating**; the full
branching runbook is
[release-branching.md](../docs/release-branching.md).

1. Determine the PR's target branch and resolve its phase. Prefer the published
   phase from bounded targeted `agent-coord` status for that branch (available
   only when bounded `agent-coord doctor --json` and targeted status probes exit
   0). If the backend is up but has no published phase entry for that line,
   derive the phase from the branch rules in `AGENTS.md`; never silently
   downgrade a release-policy branch to ordinary base-branch handling. If the
   backend is `UNKNOWN`, treat the configured base branch as ordinary
   development; derive any other phase only when `AGENTS.md` provides
   deterministic branch-to-phase rules; otherwise keep the phase `UNKNOWN`.
2. Apply that phase's gate from `AGENTS.md`: ordinary base-branch development is
   the lowest gate, release-candidate/stabilization branches add the repo's
   configured review and fix-scope requirements, and final-release work requires
   explicit human sign-off rather than confidence-only auto-merge.
3. When the repo's release policy requires forward-porting from a release branch
   to the base branch, use the exact forward-port method from `AGENTS.md`; do not
   substitute a different branch sync strategy.
4. If the published phase and the tracker disagree, treat it as a
   `release-mode-conflict` per `AGENTS.md`, report it, and do not auto-merge.

## Tracker Update Safety

Tracker issue bodies are shared mutable state. Avoid clobbering another agent's
update:

- Re-read the tracker immediately before editing the body.
- Prefer append-only tracker comments for concurrent per-PR or per-batch updates.
- Edit the tracker body only when you can preserve the latest body content and
  merge your intended update cleanly.
- If the tracker changed and the update cannot be safely merged, post a comment
  with a `Tracker Update:` header containing the intended update and report the
  conflict to the batch coordinator or, if none, a maintainer such as the
  launch-thread author or the `owner:` field in the batch goal.
- Until the conflict is reconciled, agents must read the latest tracker body and
  latest unresolved `Tracker Update:` conflict comment together before making
  release-mode or auto-merge decisions.

## Promotion, Publishing, And Rollback Authority

Enter this downstream stage only when the task explicitly selects a production
promotion, package/release publication, or release rollback. Resolve the exact
target, artifact or commit SHA, repository-owned command, verification, and
rollback path from the consumer repo's `AGENTS.md` seams. A missing or `UNKNOWN`
fact stops the consequential action without blocking unrelated ordinary PR
integration.

Merge authority never grants this authority. Deploying, promoting, publishing,
and rolling back each require explicit authority for the exact action and
target. Record the terminal outcome and verification where the repository's
release policy requires it; do not infer permission from a failed deployment,
an open release tracker, or prior merge approval.

## Accelerated RC Auto-Merge

In `accelerated-rc` mode, affected areas such as package release, generators,
CI, benchmarks, package/core boundaries, and other performance- or
framework-sensitive areas (per `AGENTS.md`) do not cap the score by themselves.
They choose the validation checklist. Missing validation, real uncertainty,
failed checks, or unresolved findings lower the score.

Final-release mode is stricter than accelerated RC. Do not use confidence-only
auto-merge for final release work; run the post-merge audit, update changelog or
release notes as needed, and get an explicit maintainer release decision before
publishing. Confirm required checks on the **SHA being promoted**: for a final
promotion from a release branch, validate the release-branch or promoted-RC tip,
not the base branch. Once later commits have landed on the base branch, those
checks are green or red independently of the release tip being promoted, so
validating the base branch would prove the wrong SHA.

Before the final configured review pass, declare the accelerated-RC candidate
final. After that pass completes, do not push nit-only, comment-only, optional
wording-only, or evidence-only commits. Batch remaining must-fix changes into
one final push and restart the current-head review/check gate; otherwise record
or waive the optional item instead of spending another review cycle.

Auto-merge requires all of the following:

- The PR body contains the latest finalized `Agent Merge Confidence` block for the current head SHA; do not rely on a PR comment for the final state.
- Once `Finalized by:` is populated, any later confidence-block edit also has a PR comment with a `Confidence Block Updated:` header, the previous score/finalizer, and the reason for the edit.
- The authoring agent did not finalize its own `8/10` or higher score. The `Finalized by` value names a different GitHub account or named GitHub check/app identity, verifiable from the git log or GitHub review/check record. Two sessions running under the same GitHub account, including separate invocations of the same GitHub App bot, do not satisfy this requirement.
- Score is at least `8/10`; `7/10` permits human merge after review, but not auto-merge.
- Before triggering auto-merge, the merge actor verifies `Finalized by` against the GitHub review record, checks, or git log, not only the PR body text.
- All GitHub checks for the current head SHA are complete. An empty full `gh pr checks <PR>` list is `UNKNOWN` / not ready. Skipped checks count as complete only when CI selector output explains them or a maintainer explicitly waives them.
- The configured Claude review check for the current head SHA completed with an acceptable conclusion, or a qualifying fallback review completed with the same blocker-triage bar. The portable default check name is `claude-review`; consumer repos that use a differently named review check must define that name under their `AGENTS.md` `Review gate` policy and keep every helper or workflow that polls review status aligned with it before relying on that override. Other repo-configured reviewers, including Cursor Bugbot or Codex review, qualify only when visible as a current-head GitHub check/app result or when they satisfy the linked ordinary fallback reviewer-identity and attestation rules. Acceptable conclusions are `success`, or `skipped` / `neutral` only when CI selector output or a maintainer waiver explains why the run did not review code. A `failure`, `cancelled`, `timed_out`, or unknown conclusion does not satisfy this gate and must route through the fallback/error-evidence rules. An `action_required` conclusion is an external approval gate; it blocks auto-merge until the approval is satisfied or a maintainer leaves an explicit waiver, and it is not a fallback trigger by itself.
- **Fallback safety and attestation.** Apply every trigger, final re-poll,
  exact-diff invocation, isolation, budget, reviewer-identity, and attestation
  requirement in
  [Ordinary Review Fallback](pr-processing.md#ordinary-review-fallback). For
  accelerated-RC auto-merge only, the fallback path may also open when the only
  configured reviewer result is for an older head SHA, no current-head run is
  queued or running after the same two queries at least 180 seconds apart, and
  trusted evidence records the stale run's head SHA and URL. This release-only
  extension still requires the ordinary final Checks API re-poll and every
  distinct-attester restriction.
- Claude failures not caused by capacity limits are understood before merge.
- CodeRabbit approval is not required, but concrete CodeRabbit findings still need normal blocker triage.
- Reviewer verdicts in the confidence block are classified as current-head or stale/advisory with the head SHA each verdict covers. Stale approvals, positive comments, and summaries cannot be cited as merge gates.
- The merge actor fetches unresolved review threads with `gh` or GraphQL immediately before auto-merge. Auto-merge is refused when any unresolved thread lacks an explicit triage reply, maintainer waiver, or linked fix.
- The merge actor applies the default 10-minute waiver-soak window after the latest final waiver or triage reply, unless a distinct finalizer or maintainer leaves an explicit auditable acknowledgement of the final waiver set and immediate-merge decision.
- Any non-trivial advisory concern that is not obviously wrong is fixed, disproven with evidence, or explicitly waived. A non-trivial concern is one that would be a correctness bug, security issue, behavioral regression, API contract break, data-loss risk, release-process break, or credible CI/test coverage gap if correct.

The default accelerated-RC waiver-soak window is 10 minutes after the latest
final waiver or triage reply. A distinct finalizer or maintainer may override it
only with an explicit auditable acknowledgement that names the final waiver set
and immediate-merge decision and satisfies the independent-finalizer rule in
`AGENTS.md`. If a must-fix finding arrives during the window, fix it or obtain an
explicit maintainer waiver, then restart local validation, the current-head
review/check gate, and the window from the latest fix, waiver, or triage reply.

Use the `Agent Merge Confidence` template defined in `AGENTS.md` under
**Release Mode And Auto-Merge Coordination**. Do not maintain a separate
template copy here.

## Release Closeout Extension

When this component is loaded, extend the ordinary coordinator closeout lane:

1. Refresh stale release-mode classification from the release tracker when
   needed. For accelerated-RC merge readiness, refresh the latest finalized
   PR-body `Agent Merge Confidence` block required by `AGENTS.md`; keep it
   distinct from tracker mode/classification updates.
2. Apply the resolved release phase, accelerated-RC waiver-soak, and final-release
   sign-off rules before any ready or merge action.
3. After a release-mode auto-merge, do a lightweight post-merge check: confirm
   the PR landed on the expected target branch, resolve target and base branch
   names from PR metadata and `.agents/agent-workflow.yml`, check their live
   GitHub/CI status, inspect late review/check comments or bot findings that
   arrived around or after merge, and update the active release tracker if one
   exists. If the merged PR touched workflow configuration, include the repo's
   lint/docs evidence from `AGENTS.md` in the post-merge summary before marking
   it clean. Use coverage catch-up mode for user-requested un-audited PR/commit
   ranges. Reserve release/range post-merge audit for final-release readiness,
   suspected bad merges, missing or unverified batch scope, or a lightweight
   sweep that finds a blocker, failed post-merge check, or credible
   release-readiness risk. For a completed coordinated batch with verified
   scope, use completed-batch audit mode so unrelated range PRs remain excluded
   context.
