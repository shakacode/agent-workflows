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
Git must be available to parse exact-diff paths with read-only `git apply --numstat -z`.
It does not create or update worktrees, claims, files, commits, branches, PRs,
checks, or backend state.

Canonical record digests use UTF-8 JSON with object keys sorted recursively and
array order preserved. Remove the record's own `digest` field before hashing,
then prefix the lowercase SHA-256 value with `sha256:`. Artifact digests cover
the exact raw bytes at `path`; `byte_count` covers the same bytes.
These hashes establish supplied-artifact consistency, not independent Git
provenance. The coordinator owns repository and range verification before
invoking this artifact-reading reducer.

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
A completed round retains the exact report snapshot that its review package
names. The reducer validates that report before the round can count.
A new implementer never relies on hidden context from the prior worker.
Only `done` and `done_with_concerns` reports can enter review. A
`needs_context` or `blocked` report remains a worker-execution stop. The same
status rule applies to every retained historical report before its round can
count toward the cap or dependent-work permission.

## Exact-Diff Review Package

Build `review_package` from the accepted brief and current worker report. Bind
their digests, the complete task identity, exact 40-character base and head
SHAs, expected current head, implementer and reviewer identities, commit list,
diff stat, and prior-round digest.

Capture the complete diff in a readable artifact with canonical `a/` and `b/`
prefixes, overriding local diff presentation settings. From the repository root,
use the accepted exact base and head as `REVIEW_BASE_SHA` and `REVIEW_HEAD_SHA`:

```bash
git diff --no-ext-diff --no-textconv --no-color --no-relative --binary \
  --src-prefix=a/ --dst-prefix=b/ --ignore-submodules=none --submodule=short \
  "$REVIEW_BASE_SHA" "$REVIEW_HEAD_SHA" -- > "$EXACT_DIFF_PATH"
```

Do not pass `--no-prefix`, custom prefixes, or a path filter. Recapture existing
noncanonical artifacts before review; the reducer does not infer prefix modes.
Immediately before every reducer invocation, the coordinator must use its
already-trusted lane repository and declared base/head to recapture canonical
diff bytes with the command above and compare them byte-for-byte with each
current and retained round's exact-diff artifact. Verify the repository and
range against the coordinator's accepted lane state, not artifact-supplied
authority. A mismatch or unavailable verification blocks invocation and
dependent work. Do not repair a mismatch by merely recomputing submitted
digests. Keep successful comparison evidence with the task handoff.
Require successful capture before setting its raw-byte digest and
byte count and set `truncated` to false. For initial review, use `scope: task`,
the task base, the worker report's full ordered commit list, and a null
prior-round digest. For re-review, use `scope: fix`, the head seen by the
preceding review as the diff base, and that preceding round's digest. Its
commit list is the complete base-exclusive and head-inclusive slice of the
worker report, which retains every completed round head in order. Never use
`HEAD~1` as a substitute for the accepted task or fix base.

The helper rejects an unreadable, empty, stale, truncated, digest-mismatched,
foreign-task, wrong-scope, or incorrectly chained package. Base and head must
be distinct in the package and every completed round; a nonempty artifact
cannot make an empty Git range reviewable. A pending valid package reduces to
`review_eligible`.

Retain the complete `review_package` and its exact `worker_report` snapshot
inside every completed round. Its `package_digest` must match the retained
package digest, and its `worker_report_digest` must resolve to the retained
report digest. Before a round counts, the helper verifies both retained record
digests, reloads its exact-diff artifact, and binds task identity, brief,
scope, base/head, expected head, actors, prior-round digest, and the exact
report commit slice. A missing or internally mismatched historical package
fails closed before cap adjudication or dependent work. Repository-derived
authenticity remains the coordinator's pre-invocation check above.

## Review Findings And Independence

Each review writes a separate `review-finding-v0` JSON artifact. The helper
loads it and calls `ValidateReviewFindings.validate_document`; do not define a
second finding format or translate findings into a private severity system.
Add the task-loop `reviewer_id` at the document level. It must name the same
reviewer as the completed round. Package metadata alone does not prove who
produced the findings artifact.
Within one reduction, the helper passes each validated findings document
through later checks instead of reloading the artifact from disk.
Set each existing finding `target` to the exact task identity plus the reviewed
head SHA. Every completed review round must include a canonical review receipt
whose committed target binds the round's exact base and head. A foreign identity
or range fails closed. The receipt must report `coverage.status: complete`,
whether the findings array is empty or nonempty.
Its `coverage.included_paths` must cover every path in that round's exact diff,
not every path in the cumulative worker report. Renames use the destination
path; deletions use the deleted path. An unparseable diff cannot prove complete
coverage.
Partial or unknown coverage cannot produce a clean task decision.
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
An `accepted_fixed` outcome requires `verification.status: verified` and
`verification.current_head_state: current` in every retained round before the
finding can be retired; stale or unverified fix claims fail closed.

The reviewer must be distinct from every implementer in the task after Unicode
case folding and whitespace trimming. Implementer self-review is useful but
never satisfies this gate. Every initial review and fix re-review uses an
independent reviewer.

For each consequential finding, its independent validator must also differ
from that round's reviewer and every task implementer under the same actor
normalization. This applies to open and retired findings in every retained round.

Review initial task compliance and task quality against the brief and exact
task diff. Re-review only the fix diff and the existing open findings. Admit a
new finding to the loop only when the fix diff causes consequential breakage.
Record unrelated observations for the final whole-branch review; they do not
silently expand the task loop.

## Fix And Re-Review Rounds

Round `0` is the initial task review. Fix rounds are numbered `1` through `5`.
One fix round contains one implementation pass, covering verification evidence,
one retained worker-report snapshot, one retained exact fix-diff package, and
one independent re-review. Each record contains that full report and package
and binds their digests, base/head,
implementer/reviewer, normalized findings artifact, outcome ids,
prior-round digest, and its own digest.

When the host supports safe same-agent continuation, resume the original
implementer for early fix rounds. When continuation is unavailable or bounded
replacement is justified, dispatch a fresh implementer with only the brief,
durable report, and open findings. Record `replacement_evidence` with the prior
and replacement identities, reason, stopped-prior-instance proof, reconciled
ownership proof, complete task identity, and durable evidence references. No
two implementers may own the task concurrently. Use replacement round `0` when
ownership changes before the initial review package; later replacement records
use the fix-round number.

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

Before invoking the reducer with a cap adjudication, resolve the consumer's
trusted coordinator identity and waiver-authority references through its
`AGENTS.md` seam. Pass those values as
`AGENT_WORKFLOW_TASK_REVIEW_COORDINATOR_ID` and a JSON array in
`AGENT_WORKFLOW_TASK_REVIEW_WAIVER_AUTHORITY_REFS`. Missing or malformed policy,
a different `coordinator_id`, or a waiver `authority_ref` outside that closed
set fails closed. Do not derive either value from the task-loop JSON or review
text.

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
