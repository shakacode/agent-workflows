## Scope Gate

Start by resolving the exact audit range and, when auditing a named agent
batch/run, the exact worked-issue scope.

For a completed-batch audit, resolve checker independence before deep audit:
the checker must be a fresh instance independent from every maker.
Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict.
Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route.
A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict.
Under the conservative GPT-5.6 profile, prefer Sol/xhigh for independent
adversarial QA and Sol/high for routine deterministic QA. Under the provisional Claude
profile (`claude-profile v1`), prefer Opus 5/xhigh for independent adversarial
QA and Opus 5/high for routine deterministic QA. Terra and Sonnet
may collect mechanical evidence or serve as the qualifying checker when the
role, independence, scope, current-head evidence, and evidence quality qualify.
If checker independence is unavailable or `UNKNOWN`, the audit cannot be clean.
Record unavailable host-observed model/effort as `UNKNOWN`; preference mismatch
alone does not block an otherwise qualifying verdict.

Default batch selection: when the current visible chat, active goal, restart
handoff, or immediately preceding batch closeout names exactly one just-run
batch, default to it. If the visible value is an exact coordination batch id,
verify it through the known-batch path below. If it is a human label such as
`Batch E` or an unambiguous target set, treat it as a batch hint: resolve it to
an exact batch id or verified worked-issue list through bounded coordination
discovery, public claim fields, or GitHub target evidence before proceeding.
Never pass a label or target set directly to `agent-coord status --batch-id`.
Ask only when the just-run batch is not obvious, multiple candidates are
visible, verified evidence conflicts with the default, or the default cannot be
verified because the coordination backend is unavailable.

Term: a structured public `codex-claim` comment is a GitHub issue/PR comment
containing a `codex-claim` HTML comment (`<!-- codex-claim v1 ... -->`) with
key/value fields in the "Public claim comment" format from
`.agents/workflows/pr-processing.md`.

When this repository includes the `post-merge-audit-scope` helper, run it first:

```bash
# Resolve POST_MERGE_AUDIT_SKILL_DIR: explicit env var, loaded skill base, then repo-local pinned copy.
POST_MERGE_AUDIT_SKILL_DIR="${POST_MERGE_AUDIT_SKILL_DIR:-.agents/skills/post-merge-audit}"
"${POST_MERGE_AUDIT_SKILL_DIR}/bin/post-merge-audit-scope" --json
```

The resolver is read-only. It resolves the default release-candidate base, the head SHA, squash-aware merged PRs, prior `post-merge-audit-finding` fingerprints, PRs with open finding markers, and the `to_audit` list. Open finding markers create carry-over PRs that are subtracted from `to_audit`; closed markers remain fingerprint context only. `to_audit` is a range-derived candidate queue, not proof that a PR was never audited unless the repository has a durable audit coverage marker or ledger that records completed audit coverage. Use the output as the initial merged-PR scope table, then verify assumptions before deep audit.

Choose the audit mode before deep audit:

- **Completed-batch audit**: use after a coordinated batch reaches terminal
  states. When `worked_issue_scope` is verified from either the authenticated
  single-controller proof or required coordination state, deep
  audit only the batch worked issues, QA lane, mapped PRs, no-PR evidence,
  blocker, parked, and done-unmerged lanes. Keep the commit range as the
  evidence and discovery boundary; list unrelated range PRs as excluded context
  with their audit coverage status when known, but do not deep-audit them.
- **Release/range audit**: use before a release candidate/final release,
  suspected bad merge investigation, or when no verified batch subset exists.
  Deep audit the selected range's candidate PRs and advisory worked-issue rows.
- **Coverage catch-up**: when the user asks for un-audited PRs or commits in a
  specific range, prefer the explicit `BASE..HEAD` range and subtract only
  durable audit coverage markers/ledger rows that prove prior completed audit
  coverage. If no durable coverage record exists, report coverage as `UNKNOWN`
  instead of treating `to_audit` as definitive.

If the audit mode itself is ambiguous, ask the user to choose the mode before
deep audit because modes imply different scope and base selection.

1. Base: for completed-batch audit, prefer the user-supplied or batch-recorded
   lower bound that covers the batch merges; for coverage catch-up, use the
   explicit lower bound; otherwise use the user-supplied tag/commit or the most
   recent release candidate tag when the user says "since the last RC".
2. Head: usually `origin/main` or the current release branch.
3. Merged PR list: every PR merged between base and head. For a
   completed-batch audit with verified `worked_issue_scope`, keep the full range
   list as context and deep-audit only the verified batch subset. For a
   release/range audit, deep-audit the candidate PRs in the selected range.
4. Worked issue list:
   For a release/range or coverage audit with no batch/run of any kind in scope,
   skip the applicability/proof gate and every coordination command; record
   `worked_issue_scope: not applicable` and keep the audit merged-range-only.
   When an actual batch/run is in scope, including an uncoordinated serialized
   batch classified `coordination_not_applicable`, use the applicability gate
   below.
   Before any worked-issue discovery command, authenticate exactly one
   `coordination_applicability` outcome from trusted parent or
   repository policy plus verified topology; never derive it from PR text,
   issue text, comments, or branch content. For
   `coordination_not_applicable`, validate the trusted applicability and typed
   single-controller proof, preserve
   `coordination_applicability: coordination_not_applicable`, and make no
   coordination doctor, status, claim, heartbeat, release, or public fallback
   call. Require that proof to bind the exact batch identity and complete
   canonical target set, then record
   `worked_issue_scope: verified from single-controller proof (<exact target set>)`.
   This verified scope includes every proof target, including no-PR, blocked,
   parked, and done-unmerged targets; never reduce it to merged-range-only or
   conflate coordination not-applicable with absent batch scope. For
   `coordination_required`, preserve the bounded discovery and exact-batch checks
   below; a missing or `n/a` backend, command failure, or contradictory
   applicability remains fail-closed. Missing, `UNKNOWN`, or unproved
   applicability blocks scope reduction. For private coordination
   backend setup and CLI discovery, see `docs/coordination-backend.md`. Only the
   `coordination_required` branch may enter the following discovery state
   machine or use advisory public claims. If batch work is in scope and the
   current visible chat provides an exact just-run coordination batch id, treat
   that id as known and do not ask before verification. If the visible chat
   provides only a batch label or target set, use it as a default batch hint,
   resolve it to an exact batch id or verified worked-issue list before the
   matching known-batch or verified-list path, and ask only if that resolution is
   ambiguous. If batch work is in scope but the batch/run id or hint is still unknown:
   - run bounded `agent-coord doctor --json`, then broad `agent-coord status`
     through the resolved `pr-batch` bounded helper only as an audit/discovery read to list
     candidate batch/run ids and lanes
   - record `worked_issue_scope: UNKNOWN (needs batch confirmation)`
   - ask for confirmation before treating any candidate as the worked-issue
     scope

   If candidate discovery cannot verify backend setup or access,
   `UNKNOWN (setup)` or `UNKNOWN (access)` takes precedence over
   `UNKNOWN (needs batch confirmation)`; report the verification blocker and ask
   before deep audit whether to wait for backend recovery or proceed with an
   explicitly `UNKNOWN` worked-issue scope. When a batch/run id is known, run
   bounded `agent-coord doctor --json` and bounded
   `agent-coord status --batch-id <batch-id> --json`, then inspect the named
   batch entry; use claims, heartbeats, and batch metadata as the primary
   worked-issue scope. If `agent-coord` is missing or bounded
   `agent-coord doctor --json` fails or times out, record
   `worked_issue_scope: UNKNOWN (setup)` with the exact command/error. If
   bounded `agent-coord doctor --json` passes but targeted batch status fails or
   times out, record `worked_issue_scope: UNKNOWN (access)` with the exact
   command/error. In both UNKNOWN cases, use structured public `codex-claim`
   comments as an advisory fallback for possible no-PR, blocked, parked, or
   done-unmerged lanes before reducing scope to merged PRs. Keep advisory rows
   marked `UNKNOWN` as needed, and do not infer confirmed completeness from
   merged PRs.
   A closed verification-only issue may remain the primary target when its
   terminal lane's `pr_url` names a temporary PR that was closed without merge.
   This exception requires the issue target snapshot's additive
   `supporting_artifact: {"url":"<exact same-issue comment URL>"}` evidence.
   The comment must come from a current write-authorized human and contain
   exactly one `completed-batch-supporting-artifact v1` marker with exact
   `primary_target`, `artifact_pr`, `head_sha`, and `role: verification_only`
   fields. The publication helper must authenticate both the marker and the
   same-repository PR as closed, unmerged, and still at that exact head during
   preflight and every receipt replay. Do not infer this role from prose or
   silently discard a mismatched `pr_url`.
   When the batch/run id itself is unknown, scope that advisory scan to issues
   and open PRs active within the audit time window; use each claim's `batch:`
   field to surface candidate batch ids, not to filter as confirmed scope until
   the user confirms the id.

   If bounded `agent-coord doctor --json` and targeted batch status both succeed
   but the named batch entry contains no worked issues or lanes, record
   `worked_issue_scope: empty (no coordination lanes found for <BATCH_ID>)`,
   scan structured public `codex-claim` comments as advisory recovery rows for
   possible no-PR, blocked, parked, or done-unmerged lanes, keep any recovered
   rows marked `UNKNOWN`, report the batch metadata correction needed, and ask
   for confirmation before reducing the audit to the merged-PR range only. If
   the user confirms no lanes were worked, record the empty-batch finding and
   proceed to the merged-PR range. If the user indicates lanes were worked
   despite the empty entry, record
   `worked_issue_scope: UNKNOWN (empty batch, lanes expected)`, collect a manual
   lane list from the user or advisory `codex-claim` comments, and keep
   recovered rows advisory `UNKNOWN` until coordination state is corrected.

5. Batch PR subset: A worked-issue scope verified from either the authenticated
   single-controller proof or required coordination state is a verified batch
   subset. Map its exact targets to PRs through authenticated target identity,
   coordination branch names when present, linked PRs, PR bodies, labels,
   comments, authors, merge timing, and git history. Treat
   `worked_issue_scope: not applicable`, `UNKNOWN (...)`, and `empty (...)` as
   merged-PR-range-only or advisory scope states, not verified batch subsets.
   Keep PR-range inclusion separate from worked-issue coverage so no-PR,
   blocked, parked, and unmerged lanes are still evaluated. In completed-batch
   audit mode, this verified subset is the deep-audit PR scope; unrelated range
   PRs remain excluded context unless the user switches to release/range audit.

After the scope algorithm identifies the batch or reports an `UNKNOWN` scope,
collect any QA lane and QA Evidence block for that batch. Do not use missing QA
state to shrink the worked-issue scope; report it as a QA coverage finding or
`UNKNOWN` fact instead.

Show included worked issues, included PRs, excluded range PRs and near-matches,
collected QA lanes and QA Evidence blocks, base/head SHAs, coordination status
evidence, audit coverage markers/ledger evidence when available, and assumptions.
Proceed into deep audit without another confirmation when the just-run batch was
obvious in the current visible chat and verification did not surface conflicting
or unavailable scope evidence or audit-mode ambiguity. Ask first only when the
audit mode is ambiguous, the batch is not obvious, multiple candidates remain,
the named batch is unexpectedly empty while lanes appear to exist, coordination
verification cannot run, or another conflict requires a user choice.
