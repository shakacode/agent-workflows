# PR-Batch Task Review Loop

This component owns the task-local information and review loop for one accepted
`pr-batch` lane. Load its brief phase before implementation dispatch, then
return after the worker emits a committed implementation-head handoff.

## Boundary

This component owns only the task brief, worker report, exact-diff review
package, independent task review, bounded fix/re-review rounds, and cap
adjudication. It emits a small deterministic task decision.

Existing owners remain authoritative for worktrees, coordination claims,
permission lifecycles, commits, validation, push, PR publication, hosted CI,
merge readiness, and closeout. The integration owner still runs final
whole-branch verification and review. A task decision never replaces or
weakens those gates, and this component never becomes a peer orchestrator.

## Contract And Replay

Use the closed
[`task-review-loop-v1` schema](../docs/schemas/task-review-loop-v1.schema.json).
Resolve `PR_BATCH_SKILL_DIR` from an explicit environment variable, the loaded
skill directory, or the repo-local `.agents/skills/pr-batch` copy. Stop with a
precise blocker when the helper is unavailable. Pass one contract on standard
input:

```bash
"${PR_BATCH_SKILL_DIR}/bin/task-review-loop" < task-review-loop-v1.json
```

The helper reads contract artifacts and emits one deterministic JSON decision.
It does not create or update worktrees, claims, files, commits, branches, PRs,
checks, or backend state.

Canonical record digests use UTF-8 JSON with object keys sorted recursively and
array order preserved. Remove the record's own `digest` field before hashing,
then prefix the lowercase SHA-256 value with `sha256:`. Artifact digests cover
the exact raw bytes at `path`; `byte_count` covers the same bytes.

The output status is exactly one of:

- `review_eligible`: the current package is complete and can go to its named
  independent reviewer.
- `fix_required`: open findings remain before the cap.
- `task_complete`: review is clean, or every non-blocking cap finding has a
  permitted evidence-backed adjudication.
- `blocked`: input, evidence, identity, independence, cap, or safety checks
  fail closed.

`dependent_task_permitted` is true only with `task_complete`. `reasons` contains
stable machine reason codes. Completion reasons are `review-clean` and
`cap-adjudicated`; active-loop reasons are `exact-review-package-current`,
`open-findings-require-fix`, and `consequential-new-breakage`. Blocking reasons
name the failed record or invariant and do not contain free-form text.

## Task Brief

Create one `task_brief` before implementation dispatch and pass it to worker
execution as the only task-requirements source. Bind its identity to the exact batch,
lane, plan id and digest, and task id. Put the complete task requirements only
in `requirements`. Add only relevant global constraints, established
interfaces, and resolved ambiguity.

The task brief is the single source of task requirements. Worker and reviewer
prompts point to it. They do not restate exact requirements, paste unrelated
session history, or accumulate prior-task summaries. A changed brief is a new
digest and invalidates reports and packages that reference the old digest.

## Worker Report

The implementer writes one durable `worker_report` bound to the same identity
and brief digest. It records:

- initial and current implementer identities and task status;
- exact base, current head, and commit list;
- changed paths and each verification command, status, and outcome; and
- concerns and open context needs, including explicit empty arrays.

Append fix evidence to the same task-scoped report, then recompute its digest.
The coordinator can show a compact status, but review uses the durable report.
A new implementer never relies on hidden context from the prior worker.
Only `done` and `done_with_concerns` reports can enter review. A
`needs_context` or `blocked` report remains a worker-execution stop.

## Exact-Diff Review Package

Build `review_package` from the accepted brief and current worker report. Bind
their digests, the complete task identity, exact 40-character base and head
SHAs, expected current head, implementer and reviewer identities, commit list,
diff stat, and prior-round digest.

Capture the complete diff in a readable artifact. Set its raw-byte digest and
byte count and set `truncated` to false. For initial review, use `scope: task`,
the task base, the worker report's full ordered commit list, and a null
prior-round digest. For re-review, use `scope: fix`,
the head seen by the preceding review as the diff base, and that preceding
round's digest. Its commit list is the current suffix of the worker report,
which retains every completed round head in order. Never use `HEAD~1` as a
substitute for the accepted task or fix base.

The helper rejects an unreadable, empty, stale, truncated, digest-mismatched,
foreign-task, wrong-scope, or incorrectly chained package. Base and head must
be distinct in the package and every completed round; a nonempty artifact
cannot make an empty Git range reviewable. A pending valid package reduces to
`review_eligible`.

## Review Findings And Independence

Each review writes a separate `review-finding-v0` JSON artifact. The helper
loads it and calls `ValidateReviewFindings.validate_document`; do not define a
second finding format or translate findings into a private severity system.
Set each existing finding `target` to the exact task identity plus the reviewed
head SHA. When a canonical review receipt is present, bind its committed target
to the round's exact base and head too. A foreign identity or range fails closed.
The round record classifies normalized finding ids as addressed, open, or new
consequential breakage. The current `open_findings` artifact must match the
open records in the latest round exactly.
An open finding keeps its source, title, body, and location when carried
forward. Severity may only increase, and consequential classification may only
change from false to true. Once addressed, its id is retired for the task;
reusing that id or downgrading a carried finding fails closed. Consequential
breakage first found in a fix diff remains open until a later fix round.
Reviewer-level `deferred` and `waived_by_maintainer` dispositions remain open
inside this loop. Only the coordinator's evidence-backed cap adjudication can
defer or waive them for task completion.

The reviewer must be distinct from every implementer in the task after Unicode
case folding and whitespace trimming. Implementer self-review is useful but
never satisfies this gate. Every initial review and fix re-review uses an
independent reviewer.

Review initial task compliance and task quality against the brief and exact
task diff. Re-review only the fix diff and the existing open findings. Admit a
new finding to the loop only when the fix diff causes consequential breakage.
Record unrelated observations for the final whole-branch review; they do not
silently expand the task loop.

## Fix And Re-Review Rounds

Round `0` is the initial task review. Fix rounds are numbered `1` through `5`.
One fix round contains one implementation pass, covering verification evidence,
one exact fix-diff package, and one independent re-review. Each record binds its
package, base/head, implementer/reviewer, normalized findings artifact, outcome
ids, prior-round digest, and its own digest.

When the host supports safe same-agent continuation, resume the original
implementer for early fix rounds. When continuation is unavailable or bounded
replacement is justified, dispatch a fresh implementer with only the brief,
durable report, and open findings. Record `replacement_evidence` with the prior
and replacement identities, reason, stopped-prior-instance proof, reconciled
ownership proof, and durable evidence references. No two implementers may own
the task concurrently. Use replacement round `0` when ownership changes before
the initial review package; later replacement records use the fix-round number.

An open finding before round five reduces to `fix_required`. Consequential new
breakage from the fix diff joins the open set and adds
`consequential-new-breakage` to the decision. It does not reset the counter.
A clean review ends the task-local loop; a fix round without findings from the
immediately preceding review is invalid.

## Five-Round Cap

A sixth fix round is invalid input. After round five, every open finding needs
one coordinator adjudication with a nonempty evidence list:

- `disproven`: evidence shows why the finding does not apply.
- `waived`: include the exact trusted `authority_ref`.
- `deferred`: include a durable `tracking_ref` and evidence.
- `blocked`: record the evidence and stop the task.

The `finding_controls` record gives every open finding explicit
`load_bearing` and `cap_piercing` booleans. An open P0, cap-piercing finding,
load-bearing finding, or `blocked` adjudication always reduces to `blocked` and
sets `dependent_task_permitted` to false. Reviewer agreement, a waiver, or a
deferral cannot make those findings safe for dependent work.

Only non-blocking findings with complete evidence-backed `disproven`, `waived`,
or `deferred` adjudications can reduce to `task_complete` at the cap. Missing,
duplicate, foreign, unsupported, or `UNKNOWN` adjudication evidence fails
closed.

## Handoff To Existing Owners

Return the task decision, exact brief/report/package digests, last round digest,
current head, and any blocking reason to the lane coordinator. `task_complete`
permits dependency progression only; it does not claim that the branch or PR is
ready. The existing integration owner still refreshes the base, verifies the
whole branch, runs final independent review and CI, publishes or updates the
PR, resolves review, and applies merge-readiness policy.
