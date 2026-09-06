## Audit Checks

For each included PR:

- Review completion: find reviews, review comments, issue comments, and review/check runs from Claude, Codex, CodeRabbit, Greptile, Cursor Bugbot, and other configured reviewers.
- Review timing: flag any reviewer check, review, or comment that was still queued/in-progress at merge time or landed after merge.
- Review triage: flag any pre-merge review/comment with `Must Fix`, `MUST-FIX`, `Should Fix`, `DISCUSS`, `Changes Requested`, `blocking`, or similar actionable language when there is no later evidence it was fixed, waived, or explicitly classified.
- Selected CI timing: when the repo or batch selected specific hosted checks for
  replay, resolve `POST_MERGE_AUDIT_SKILL_DIR` with the env-var / loaded-skill /
  repo-local chain, then run
  `"${POST_MERGE_AUDIT_SKILL_DIR}/bin/pr-check-completion-timing" <PR> --repo <OWNER/REPO> --select-name <regex>`
  or `--select-workflow <regex>` and flag selected checks that completed after
  merge or could not be verified.
- Approval semantics: flag any merge that treated an AI reviewer approval, positive issue comment, or "no actionable comments" summary as required maintainer approval or a special approval gate. Also flag any AI finding that was ignored even though it identified a confirmed blocker such as a correctness regression, failing test, security issue, API contract break, data-loss risk, or missing required maintainer approval.
- Adversarial review: flag any requested adversarial review that finished after merge, reviewed an older head SHA, or left untriaged `BLOCKING` or `DISCUSS` findings.
- Changelog: if the diff or PR body indicates a user-visible behavior, API, error message, configuration, performance, security, or breaking change, verify the repo's changelog (see `changelog` in `.agents/agent-workflow.yml`) has a matching entry. When entries are missing, recommend running `/update-changelog`.
- Lockfiles: if the PR changed committed lockfiles, verify the PR evidence satisfies the lockfile content-diff requirement from the Handoff Contract in `.agents/skills/pr-batch/SKILL.md`.
- Closing evidence: for any PR whose body or linked issue uses analysis, benchmark, or investigation
  evidence to support a `close` or `document/work around` disposition, verify the conclusion applies the
  full gate from the "Evaluate the fix plan separately" step in `.agents/skills/evaluate-issue/SKILL.md`:
  reproducible artifact or justified missing-artifact caveat, internal consistency, production-environment
  caveats, and refutable-conclusion handling.
- Validation: compare changed areas with the validation evidence in the PR body or comments.
- QA evidence: verify required QA Evidence exists, records `Tested at` with the
  PR/head SHA or audited range it applies to, is current for that head/range,
  covers the changed surfaces, and does not leave release-blocking findings
  untriaged. For a user-visible UI change, also verify durable reviewer-visible
  before/after URLs, a non-blank paint check, interaction clip or measured
  substitute when applicable, an unfixed negative control for a visual fix, and
  repository performance-seam evidence for rendered-page/asset/bundle impact,
  named with `source=<stable command/report/ref>`.
  Local/file paths and “captured locally” are not durable evidence; a
  GitHub-only handoff stays blocked until an authenticated UI upload or human
  attachment puts the resulting durable GitHub URL in the receipt. Distinguish
  `bundle_hygiene` from a genuinely
  `measured_metric` claim; non-byte hygiene values name a bundle/asset shape
  metric, while the latter must name its runtime/user metric with
  `metric_name=<runtime/user metric>`. Require explicit same-unit
  `baseline_value=<number><unit>` and `candidate_value=<number><unit>` fields
  for either; incidental CI URL IDs do not count. If private coordination claim/heartbeat state is `UNKNOWN`, verify
  the documented fallback evidence is otherwise complete and names a concrete QA
  owner and branch/worktree before treating QA coverage as satisfied. Use the
  resolved `"${POST_MERGE_AUDIT_SKILL_DIR}/bin/closeout-evidence-replay"` helper
  when a PR body, handoff, or issue comment includes replay markers for QA
  Evidence or priority finding dispositions. For current-head audits, pass
  `--expected-head-sha <full-merged-head-SHA>` and replay each PR or per-PR
  evidence file separately; do not feed a combined multi-PR handoff to one
  expected SHA. Add `--require-priority-dispositions` when the audit depends on
  fixed, waived, or deferred priority findings. For every current user-visible
  UI change, run the combined current-head gate
  `--expected-head-sha <full-merged-head-SHA>
  --require-visual-evidence-v2`; the strict v2 flag is invalid without the
  expected head. Under that strict forward gate, explicit v2 presence
  supersedes v1 history, so stale or malformed v2 cannot be rescued by a
  current v1;
  historical `qa-evidence v1` remains replayable when that forward gate is not
  required. Missing or `UNKNOWN` replay is
  a process finding unless a maintainer explicitly waived replay for that
  scope.
- Cross-PR interactions: compare changed files, shared behavior, assumptions, and release-sensitive areas across the batch.
- Decision log: inspect the canonical `### Decision log` subsection inside the PR description's `Agent details` disclosure first; also discover legacy `## Codex Decision Log` and consumer-equivalent sections, then verify their decisions still hold after the merge.

For each worked issue, QA lane, or advisory `codex-claim` recovery row from
coordination state, including no-PR, blocked, parked, done-unmerged, or
still-open lanes:

- Intent coverage: compare the issue or QA-lane intent with the PR diff, no-PR
  evidence comment, QA evidence, branch state, or blocker note.
- Final state: verify whether the issue was merged, closed, parked, blocked,
  left open intentionally, or remains `UNKNOWN`; for QA lanes, verify whether
  the QA coverage status is `satisfied`, `blocked`, `waived`, healthy
  `in_progress`, `not_applicable` when QA was not required, or `unknown`.
- Handoff expectations: check validation evidence, decision-point count,
  confidence notes, QA evidence, review/comment triage, and any Process Gap
  Disposition fields required by `.agents/workflows/pr-processing.md`.
- Classification: reuse the intent-achievement classes from
  `.agents/workflows/continuous-evaluation-loop.md` (`in_progress`,
  `realized`, `partial`, `missed`, `regressed`, `stalled`, or `unknown`) and
  explain any `UNKNOWN` evidence needed to resolve the issue outcome. For QA
  lanes, use the QA-coverage result `satisfied`, `blocked`, `waived`,
  `in_progress`, `not_applicable`, or `unknown` from
  `.agents/workflows/pr-processing.md`.
- Post-merge intake: record healthy `in_progress` worked-issue lanes,
  evidenced `realized` worked-issue outcomes, evidenced `satisfied` or `waived`
  QA lanes, and evidenced `not_applicable` QA omissions in the coverage table as
  no-action items; treat required QA lanes still `in_progress` during readiness
  or release audits as QA coverage findings; route
  `stalled` lanes back to the batch coordinator as resume/reassign/drop
  decisions unless the user explicitly approves tracking the stalled lane as an
  issue; route every other non-OK worked-issue class (`partial`, `missed`,
  `regressed`, or `unknown`), merged or not, and every non-OK QA coverage
  outcome (`blocked`, `unknown`, or release-audit `in_progress`) into the issue
  plan or an explicit coordinator action that names the missing evidence or
  decision.

### Range-Level Structural Review

If the audited range also needs a codebase-health lens, run `$structural-review`
explicitly on that same range, including release/range audits without worked
issues or QA lanes. This audit does not auto-invoke sibling axes.

## Codex And Claude Coordination

When using both Codex and Claude:

1. Give each agent the same audit id, base, head, and independent audit prompt.
2. Do not share one agent's report with the other until both reports are complete.
3. Instruct both agents to draft issue entries only. They must not create issues, comments, labels, branches, fixes, reverts, or PRs during the independent audit.
4. Use one coordinator to compare both reports, verify disagreements against git/GitHub evidence, dedupe findings, and finalize the issue plan.
5. Create follow-up issues by default unless the user explicitly asks for report-only or no issue creation. The coordinator creates those issues after deduping the plan, subject to the ledger, duplicate-search, and label rules below.

## Finding Classification

Classify each PR:

- **OK**: no credible release risk found.
- **Needs maintainer question**: a decision cannot be made safely from evidence.
- **Needs changelog update**: user-visible change is missing from the repo's changelog; recommend `/update-changelog`.
- **Needs follow-up issue**: non-blocking work remains valuable and is actionable after release.
- **Needs fix PR**: a real defect, missing test, missing compatibility note, or bad interaction should be fixed before release.
- **Needs revert consideration**: the merge appears risky enough that reverting may be safer than patching. The downstream procedure is [Unwinding A Bad Agent Merge](https://github.com/shakacode/agent-workflows/blob/main/docs/revert-runbook.md), which covers revert scope, order, bookkeeping, and the operator-authority rule. Reference it in the child issue; it is a runbook for the operator, not a gate on this audit, and it never blocks or alters audit completion.

Classify each worked issue separately so the audit can prove every coordinated
lane was evaluated, even when the issue produced no merged PR:

- `in_progress`: the lane is healthy active/live work with recent heartbeat,
  commits, or review activity and no stalled, regressed, partial, missed, or
  unknown signal; record it as a no-action item.
- `realized`: the issue intent was satisfied and the final state is supported
  by evidence.
- `partial`: the issue intent was incompletely addressed; some acceptance
  criteria landed and others did not.
- `missed`: the issue intent was not addressed; no meaningful implementation
  or evidence comment exists.
- `regressed`: the merge harmed an outcome that was previously satisfied.
- `stalled`: the lane needs a coordinator decision to resume, reassign, or
  drop. Includes `stale` and `dead` lost-heartbeat operational states; see
  `continuous-evaluation-loop.md` for the operational-to-intent mapping.
- `unknown`: the auditor cannot verify the issue outcome from available
  coordination, GitHub, and git evidence.
