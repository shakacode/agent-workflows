# Unwinding A Bad Agent Merge

Use this runbook when a merge that an agent lane produced is already on the
base branch and the safest next move may be to take it back out. It covers
scope, order, bookkeeping, and authority. It is a checklist for a human
operator working with an agent, not an automated procedure.

`post-merge-audit` can classify a PR as **Needs revert consideration** and file
a child issue for it. That classification is the entry point to this runbook.
It is not a gate: the audit still completes, still files its issues, and never
blocks on a revert decision. Nothing here changes the audit flow, and v1 adds
no automation, no new coordination states, and no new event kinds.

Reverting a single independent PR is ordinary git. The parts that are not
ordinary are the batch parts: multi-lane batches merge interdependent PRs, the
changelog and the merge ledger already record the merge as landed, and
coordination state already says `done` for work that is about to be unwound.

## Before Anything Else

Establish these facts and write them down. Every later decision depends on
them, and a fact that cannot be verified stays literal `UNKNOWN` rather than
being inferred.

- `REPO`, `BASE` (the repo's `base_branch` seam), and the current base tip SHA.
- The merge commit SHA for the suspect PR.
- The `batch_id` and lane name that produced it, if any.
- The `stage-dependency-plan` v1 path and id used by that batch, if any.
- The failure itself: what broke, where it was observed, and how it is
  reproduced. A revert taken without a stated failure is a guess.

Fetch and inspect from a clean checkout of `BASE`. Do not work on `BASE`
itself; every step below builds a branch.

## 1. Scope Decision

The question is not "is this PR bad" but "what is the smallest set of merges
that must come out together". Answer it from the batch manifest, the
dependency plan, and git — never from recollection of what the lanes were
supposed to do.

### Locate the merge commits

```bash
gh pr view "${PR}" --repo "${REPO}" --json mergeCommit,mergedAt,state
git log --merges --first-parent --format='%h %ad %s' --date=short "${BASE}"
```

Use `git diff <merge>^1 <merge>` to see what a merge actually put on the base
branch. Do not use `git show <merge>` for this: on a merge commit `git show`
defaults to a combined diff, which omits hunks taken cleanly from one parent
and can render as empty for a merge that changed real files. Add `--no-pager`
and `--no-ext-diff` when a global external diff driver is configured, so the
output is the reviewable unified diff rather than a viewer's rendering.

```bash
git --no-pager diff --no-ext-diff --stat "${MERGE}^1" "${MERGE}"
git --no-pager diff --no-ext-diff --name-only "${MERGE}^1" "${MERGE}"
```

### Read the declared dependencies

Two artifacts declare lane dependency, and both are authoritative for scope:

- The registered batch manifest (see
  [Coordination Backend](coordination-backend.md) → _Batch Provenance
  Manifest_) maps `batch_id` to `lanes[].name` and `lanes[].targets`. It tells
  you which lane owns the failing target and which other lanes shipped in the
  same batch.
- The `stage-dependency-plan` v1 file (see
  [pr-processing](../workflows/pr-processing.md#stage-typed-dependency-gate))
  carries `edges[]` with `type: merge_order`. Every lane reachable from the
  failing lane by following `merge_order` edges forward is a candidate for
  joint revert. Take the transitive closure, not just direct successors.

```bash
agent-coord status --batch-id "${BATCH_ID}" --json
jq '.edges[] | select(.type == "merge_order")' "${STAGE_DEPENDENCY_PLAN_PATH}"
```

When the backend is `n/a`, the manifest lives in the durable coordinator
handoff instead of a registration surface; read it there. When neither the
manifest nor the plan file can be read, the dependency fact is `UNKNOWN`.
Record it as `UNKNOWN` and fail closed: treat every same-batch merge that
touches an overlapping path as in scope, or stop for an operator decision. Do
not narrow scope on the strength of an absent artifact — absence of dependency
metadata is not evidence that lanes are independent.

### Confirm the declared scope against git

Declared edges say what the planner intended. Git says what actually landed.
Check both; disagreement is itself a finding worth recording.

```bash
# Merges that landed after the suspect merge, on the base branch's first-parent
# line. These are the merges a revert can collide with.
git log --ancestry-path --merges --first-parent --format='%h %s' "${MERGE}..${BASE}"

# Every merge that touched the same files, in either direction.
git log --merges --first-parent --format='%h %s' "${BASE}" -- ${PATHS}
```

### Decision rule

Revert **one PR** when all of the following hold:

- no `merge_order` edge names its lane as a `from`; and
- its first-parent file set is disjoint from the first-parent file set of every
  later merge on `BASE`; and
- no later merge's content depends on symbols, files, or schema the suspect
  merge introduced.

Otherwise **unwind the closure**: the suspect merge plus every later merge that
depends on it, transitively. If any input to that test is `UNKNOWN`, take the
wider scope or stop for the operator. A too-wide revert is a review problem; a
too-narrow revert leaves the base branch in a state that never existed and
that nothing has ever validated.

## 2. Revert Order

Revert in **reverse merge order**: newest in-scope merge first, oldest last.
Every intermediate commit on the revert branch should be a state the code could
plausibly have been in. Forward order does not merely conflict more — it
produces intermediate trees that git reports as successful and that are
actually broken, because a dependent merge is still present after its
dependency has been removed.

### Build the revert on a branch

```bash
git fetch origin
git checkout -b "revert/${BATCH_ID}" "origin/${BASE}"
```

The revert goes through the repo's normal PR path. It is never pushed straight
to `BASE`, and never merged by an agent (see [4. Authority](#4-authority)).

### Revert each merge

A merge commit has no single parent to diff against, so `git revert` requires
`-m` to name the mainline. `-m 1` is the first parent, which for a merge into
`BASE` is the base-branch side; that is the value you want. Omitting it is a
hard error, not a default:

```text
error: commit <sha> is a merge but no -m option was given.
fatal: revert failed
```

```bash
git revert -m 1 --no-edit "${NEWEST_IN_SCOPE_MERGE}"
# resolve, then
git revert --continue --no-edit
# or, to get back to the pre-revert state
git revert --abort
```

Repeat for each in-scope merge, newest to oldest.

### Conflicts caused by later unrelated merges

A merge that landed after the suspect merge, and touched the same code, makes
the revert conflict. Two classes show up, and they need different handling:

- **Content conflict** (`UU`): the later merge edited lines the reverted merge
  introduced.
- **Modify/delete conflict** (`UD`): the later merge edited a file the reverted
  merge created. Git leaves the working-tree version in place and asks you to
  choose.

Resolve by classifying each surviving hunk from the later merge:

- **Dependent** — the hunk cannot exist without the merge being reverted (it
  edits a function, file, or schema that merge introduced). It dies with the
  revert. That later merge is now *partially reverted*: its lane outcome is no
  longer `realized`, and section 3 applies to it too.
- **Independent** — the hunk edits code that predates the reverted merge. Keep
  it. Losing it would silently revert an out-of-scope PR.

If an independent hunk cannot be preserved — for example the whole file must go
— then the revert collaterally reverts a merge that is not in scope. That is a
scope change, not a conflict resolution. Either widen the scope explicitly with
operator sign-off and re-run section 1, or switch to a forward fix.

Record every resolution decision. A revert branch whose conflict resolutions
are undocumented is not reviewable, and the reviewer cannot tell a deliberate
drop from an accident.

### When a forward fix is safer than a revert

Prefer a **revert** when the defect is not fully understood, the affected
surface is wide, or time-to-safe matters more than preserving the work.

Prefer a **forward fix** when:

- the defect is small and understood, and the fix is smaller than the revert;
- the merge included a migration, data backfill, or other already-applied
  side effect that a code revert does not undo;
- reverting would collaterally revert out-of-scope merges that carry
  independent value; or
- many later merges depend on the reverted code, so the revert closure grows
  past the point where anyone can review it.

State the choice and the reason in the revert (or fix) PR body. "Revert vs
forward fix" is exactly the judgment an operator is being asked to make, and a
PR that does not state it forces the operator to redo the analysis.

### Validate the result

Run the repo's full local validation on the final revert branch, not just on
the last commit. Confirm the tree is what you intended:

```bash
git --no-pager diff --no-ext-diff --exit-code "${PRE_BATCH_SHA}" HEAD
```

An exit of 0 proves the revert closure restored the exact pre-batch tree. A
nonzero exit is not automatically wrong — later independent merges are
supposed to survive — but every remaining difference must be an independent
hunk you deliberately kept.

## 3. Bookkeeping

A revert that fixes the code and leaves the records saying the work shipped is
half a revert. Dashboards, audits, and the next batch all read those records.

### Changelog

The repo's changelog is the `changelog` seam in `.agents/agent-workflow.yml`
(`CHANGELOG.md` here). Which correction applies depends on whether the reverted
entry has shipped:

- **Still under `### [Unreleased]`**: delete the entry. It never reached a
  released version, so there is nothing for a reader to un-learn. Delete only
  that entry; leave neighbouring entries and the category heading alone.
- **Under a released version header**: do not edit the released section. A
  released changelog section is a historical record of what that version
  contained, and it did contain the change. Add a new entry under
  `### [Unreleased]` → `#### Fixed` (or `#### Removed` when a user-visible
  feature is gone) that names the reverted PR and issue and says the change was
  reverted.

`$update-changelog` is the changelog-correction path for *writing* the entry
and for the release-time sweep and version stamping. It does not know that a
merge was unwound: it adds and stamps entries from merged PRs and will happily
re-derive the reverted entry. Make the deletion or the correcting entry
explicitly, in the revert PR, and run `$update-changelog` afterwards for the
sweep rather than instead of the correction.

### Merge ledger

Where the repo defines a `merge_ledger` helper, run it for the revert PR at
merge readiness with an explicit `--changelog-classification`, exactly as for
any other PR. There is no separate "revert" ledger mode and none is being added.

Where the `merge_ledger` seam is `n/a` — as it is in this repo — there is no
ledger to run, and the recorded value is literal `UNKNOWN`, per
[continuous-evaluation-loop](../workflows/continuous-evaluation-loop.md): "if no
helper is available, record `merge_ledger: UNKNOWN`". Do not invent a ledger
surface, and do not soften `UNKNOWN` into a prose "not applicable" — the
fail-closed vocabulary is what downstream audits read. This is worth stating
plainly because "merge-ledger correction" sounds like an available step and,
for an `n/a` seam, is not one.

The original merge's ledger record, where one exists, is not rewritten. It
correctly says that merge passed its gates on its exact head; that remains true
and is part of what the post-incident review needs to see.

### Coordination events and terminal state

Record these against the original lane. Backend `n/a` skips silently; an
advertised typed-event transport that fails records best-effort `UNKNOWN`
evidence and does not block the revert.

```bash
agent-coord record-event --type human_intervention --kind manual-fix \
  --batch-id "${BATCH_ID}" --lane "${LANE}" \
  --repo "${REPO}" --target "${TARGET}" \
  --message "Merge of PR #${PR} reverted by PR #${REVERT_PR}"

agent-coord record-event --type error --severity "${P0_TO_P3}" \
  --category "${CATEGORY}" --message "${OBSERVED_FAILURE}" \
  --batch-id "${BATCH_ID}" --lane "${LANE}" --repo "${REPO}"
```

While the operator decision on the revert is still outstanding, the lane is
blocked on an approval, which is the `permission` branch of the
`help_requested` precedence rule:

```bash
agent-coord record-event --type help_requested --reason permission \
  --batch-id "${BATCH_ID}" --lane "${LANE}" --repo "${REPO}" \
  --message "Revert of PR #${PR} needs an operator merge decision"
```

Do not invent event kinds, reasons, or lane states for this. The typed kinds
are exactly `help_requested`, `escalation_requested`, `error`, and
`human_intervention`; `human_intervention --kind` is exactly `takeover`,
`supersede`, `manual-fix`, or `drain`. Lane lifecycle states are exactly
`planned`, `claimed`, `active`, `blocked`, `completed`, and terminal closeout
values are exactly `done`, `abandoned`, `superseded`. Keep the two apart: the
lifecycle state says where the lane is, the closeout value says how it ended.

**Terminal state depends on whether the lane has already closed.**

*Lane not yet terminal* (`planned`, `claimed`, `active`, `blocked`) — close it
now, choosing between the two non-`done` terminal values:

```bash
agent-coord release --terminal superseded --pr-state "${PR_STATE}" \
  --batch-id "${BATCH_ID}" --repo "${REPO}" --target "${TARGET}" \
  --evidence-url "${REVERT_PR_URL}"
```

- Use `superseded` when a named successor — a new lane, issue, or PR — will
  re-land the intent. The successor must be a genuinely new lane. Per
  [pr-processing](../workflows/pr-processing.md), code-bearing completion after
  a terminal `superseded` on the *same* lane is a protocol violation, so
  `superseded` is never a way to park a lane you intend to resume.
- Use `abandoned` when the intent is being dropped and nothing is scheduled to
  re-land it.
- Rule: `superseded` if and only if a named successor exists at closeout time;
  otherwise `abandoned`.

*Lane already closed `done`* — you cannot rewrite it. **The first terminal
event is immutable.** Later authenticated completion may reconcile an
`abandoned` lane or a `superseded` issue, but there is no reconciliation that
turns a `done` lane into a not-done lane, and attempting one is a protocol
violation rather than a correction. Instead:

1. Record a lane-scoped `human_intervention --kind manual-fix` event on the
   original lane (the command above), so dashboards reading lane history stop
   presenting the outcome as cleanly `done`.
2. Run the revert as a **new lane** with its own claim, its own target, and its
   own terminal closeout — `done` when the revert merges.
3. Reclassify the *worked-issue outcome* as `regressed` in the
   post-merge-audit / continuous-evaluation-loop record. That record, not the
   coordination terminal state, is where outcome truth lives. `regressed` is
   defined as "the merge harmed an outcome that was previously satisfied",
   which is exactly this case, and it is a non-OK outcome that already earns a
   child issue.

The split is deliberate. Coordination terminal state records *what the lane
did*, which was to merge; the audit outcome records *whether the intent holds*,
which it no longer does. Do not paper over an immutable `done` by re-closing
the lane.

### Batch handoff

The original batch's `coordination:` declaration is not rewritten. The revert
carries its own handoff and its own declaration, in the canonical
[Batch Handoff Format](../workflows/pr-processing.md#batch-handoff-format).

## 4. Authority

**A revert always escalates to the operator, including under
`auto_merge_when_gates_pass`.** A supervisor may prepare and validate a revert.
It may not merge one.

The reasoning is specific, not general caution. The gate set that approved the
original merge already passed, on that exact head. The revert exists because
the merge failed in a way those gates did not model. Re-running the same gates
on the revert branch therefore proves nothing about the decision being made:
it can confirm the revert is well-formed, but it cannot re-evaluate the
judgment that the merge was wrong, because that judgment is precisely what the
gates missed. Autonomous merge eligibility is computed from objective
thresholds and path policy; it has no representation for "the previous
evaluation of these same signals was mistaken". A revert is also taken under
degraded information — usually mid-incident, from partial failure evidence —
and its blast radius can extend to out-of-scope merges through conflict
resolution, as the scope rules above show. None of that is expressible in the
eligibility thresholds.

Under `merge_authority: none` or `ask`, the same conclusion follows from the
ordinary rule: the revert needs an explicit operator merge decision.

An agent **may**, without operator sign-off:

- diagnose the failure and reproduce it;
- compute the revert scope per section 1 and report the closure and its
  evidence;
- build the revert branch and resolve conflicts, documenting each resolution;
- open the revert PR **as a draft**;
- run full local validation, CI, and the ordinary readiness gates on it; and
- record the coordination events in section 3 and escalate with
  `help_requested --reason permission`.

An agent **may not**, without an explicit operator decision:

- merge the revert, or mark the draft ready in a way that admits it to an
  autonomous-merge path;
- push a revert directly to `BASE`;
- force-push or rewrite `BASE` history to remove the merge; or
- widen the revert scope past the closure the operator approved.

## Checklist

1. Record `REPO`, `BASE`, base tip, merge SHA, `batch_id`, lane, dependency
   plan path/id, and the observed failure. Unverifiable facts stay `UNKNOWN`.
2. Compute the revert closure from the batch manifest, `merge_order` edges, and
   git. Fail closed to the wider scope on any `UNKNOWN`.
3. Decide revert versus forward fix, and write down why.
4. Branch from `origin/${BASE}`; never work on `BASE`.
5. `git revert -m 1` each in-scope merge, newest first.
6. Classify every conflicting hunk as dependent or independent; stop and
   re-scope if an independent hunk cannot be preserved.
7. Validate the branch, and diff the final tree against the intended state.
8. Correct the changelog: delete an `[Unreleased]` entry, or add a correcting
   entry when the original shipped.
9. Rerun the merge ledger, or record `merge_ledger: UNKNOWN` when the seam is
   `n/a`.
10. Record `human_intervention --kind manual-fix` plus the `error` event; close
    a non-terminal lane `superseded` or `abandoned`; for an already-`done`
    lane, open a new lane and reclassify the worked issue as `regressed`.
11. Open the revert PR as a draft and escalate to the operator for the merge
    decision.
