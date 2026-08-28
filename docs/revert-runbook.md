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
- The commit SHA on `BASE` that landed the suspect PR.
- **The repo's merge style.** Establish it; do not assume it. A repo that
  squash-merges or rebase-merges lands each PR as an ordinary single-parent
  commit, not a merge commit, and that changes both how you enumerate landed
  work and how you revert it. Check with:

  ```bash
  git --no-pager log --first-parent --format='%h parents=%p | %s' "${BASE}" | head -20
  ```

  One parent hash per line means squash/rebase merges; two means true merge
  commits. A repo can contain both, so classify per commit rather than once for
  the repo.
- The `batch_id` and lane name that produced it, if any.
- The `stage-dependency-plan` v1 path and id used by that batch, if any.
- `PRE_BATCH_SHA`: the state the base branch was in before the closure landed,
  used as the validation target in section 2. It is the first parent of the
  **oldest** in-scope landed commit, so it is only final once section 1 has
  fixed the closure:

  ```bash
  PRE_BATCH_SHA=$(git rev-parse "${OLDEST_IN_SCOPE_SHA}^1")
  ```

  `^1` is correct for both commit shapes: it is the first parent of a merge and
  the only parent of a single-parent commit.
- The failure itself: what broke, where it was observed, and how it is
  reproduced. A revert taken without a stated failure is a guess.

Fetch and inspect from a clean checkout of `BASE`. Do not work on `BASE`
itself; every step below builds a branch.

## 1. Scope Decision

The question is not "is this PR bad" but "what is the smallest set of landed
commits that must come out together". Answer it from the batch manifest, the
dependency plan, and git — never from recollection of what the lanes were
supposed to do.

### Enumerate the landed commits

```bash
gh pr view "${PR}" --repo "${REPO}" --json mergeCommit,mergedAt,state
```

Enumerate landed work along the base branch's first-parent line **without a
`--merges` filter**, and classify each commit's parent shape:

```bash
git log --first-parent --format='%H %P%x09%s' "${BASE}" | head -40
```

`%P` lists the parents: one hash is a squash/rebase commit, two or more is a
true merge commit. Both land a PR; only the second is a merge commit.

Do **not** enumerate with `git log --merges`. `--merges` means
`--min-parents=2`, so on a squash-merging repo it returns only the handful of
historical true merges and silently omits every recent PR. The disjointness
test below would then see no later landed work, classify the suspect change as
independent, and produce exactly the too-narrow revert this runbook exists to
prevent. On this repo, `git log --merges --first-parent origin/main` returns
8 commits, none from the last several hundred PRs.

This one-liner enumerates and classifies in the same pass, and prints the
revert invocation each commit needs:

Start the range at the suspect commit's own parent — that is knowable now,
whereas `PRE_BATCH_SHA` is only fixed once the closure is, and widen the range
if the closure turns out to reach further back:

```bash
git log --first-parent --format='%H' "${SHA}^1..${BASE}" | while read -r sha; do
  if git rev-parse -q --verify "${sha}^2" >/dev/null; then
    printf 'merge-commit   %s  git revert -m 1 %s\n' "$sha" "$sha"
  else
    printf 'single-parent  %s  git revert %s\n' "$sha" "$sha"
  fi
done
```

Test for the existence of a second parent (`^2`) rather than counting parents
through `wc`. BSD/macOS `wc -w` left-pads its output, so a `$(… | wc -w)`
comparison against `1` silently fails there while working on GNU coreutils —
and a classifier that misreports shape on one platform is worse than no
classifier, because it reintroduces the too-narrow revert on exactly the repos
that squash-merge.

Use `git diff <sha>^1 <sha>` to see what a commit actually put on the base
branch. This single form is correct for both shapes — `^1` is the first parent
of a merge and the only parent of a single-parent commit — so the diff needs no
branching even though the revert invocation does. Do not use `git show <sha>`
on a merge commit: `git show` defaults to a combined diff there, which omits
hunks taken cleanly from one parent and can render as empty for a merge that
changed real files. Add `--no-pager` and `--no-ext-diff` when a global external
diff driver is configured, so the output is the reviewable unified diff rather
than a viewer's rendering.

```bash
git --no-pager diff --no-ext-diff --stat "${SHA}^1" "${SHA}"
git --no-pager diff --no-ext-diff --name-only "${SHA}^1" "${SHA}"
```

### Read the declared dependencies

Two artifacts declare lane dependency, and both are authoritative for scope:

- The registered batch manifest (see
  [Batch Provenance Manifest](coordination-backend.md#batch-provenance-manifest))
  maps `batch_id` to `lanes[].name` and `lanes[].targets`. It tells you which
  lane owns the failing target and which other lanes shipped in the same batch.
- The `stage-dependency-plan` v1 file (see
  [pr-processing](../workflows/pr-processing.md#stage-typed-dependency-gate))
  carries `edges[]` with `type: merge_order`. Every lane reachable from the
  failing lane by following `merge_order` edges forward is a candidate for
  joint revert. Take the transitive closure, not just direct successors.

Read `type` from the **immutable `stage-dependency-plan` file**, which is the
only one of the two artifacts whose edges carry it; the mutable
`stage-dependency-gate` live replay carries `id`, `state`, `evidence`, and
`base_movement` per edge, and is where you check whether an edge is `pending` or
`satisfied` — not what kind of edge it is.

```bash
agent-coord status --batch-id "${BATCH_ID}" --json
jq '.edges[] | select(.type == "merge_order")' "${STAGE_DEPENDENCY_PLAN_PATH}"
```

When the backend is `n/a`, the manifest lives in the durable coordinator
handoff instead of a registration surface; read it there. When neither the
manifest nor the plan file can be read, the dependency fact is `UNKNOWN`.
Record it as `UNKNOWN` and fail closed: treat every same-batch landed commit
that touches an overlapping path as in scope, or stop for an operator decision. Do
not narrow scope on the strength of an absent artifact — absence of dependency
metadata is not evidence that lanes are independent.

### Confirm the declared scope against git

Declared edges say what the planner intended. Git says what actually landed.
Check both; disagreement is itself a finding worth recording.

Neither query filters on `--merges`, for the reason above.

```bash
# Everything that landed after the suspect commit, on the base branch's
# first-parent line. These are the commits a revert can collide with.
git log --ancestry-path --first-parent --format='%h %s' "${SHA}..${BASE}"

# Everything that touched the same files, in either direction.
git log --first-parent --format='%h %s' "${BASE}" -- ${PATHS}
```

### Decision rule

Revert **one PR** when all of the following hold:

- no `merge_order` edge names its lane as a `from`; and
- its first-parent file set is disjoint from the first-parent file set of every
  later landed commit on `BASE`; and
- no later landed commit's content depends on symbols, files, or schema the
  suspect commit introduced.

Otherwise **unwind the closure**: the suspect commit plus every later landed
commit that depends on it, transitively. If any input to that test is
`UNKNOWN`, take the wider scope or stop for the operator. A too-wide revert is
a review problem; a too-narrow revert leaves the base branch in a state that
never existed and that nothing has ever validated.

Note that a `--merges`-filtered enumeration fails this test in the *unsafe*
direction: it makes the disjointness check trivially true by hiding the later
commits it should compare against.

## 2. Revert Order

Revert in **reverse merge order**: newest in-scope merge first, oldest last.
Every intermediate commit on the revert branch should be a state the code could
plausibly have been in. Forward order does not merely conflict more — it
produces intermediate trees that git reports as successful and that are
actually broken, because a dependent merge is still present after its
dependency has been removed.

### Build the revert on a branch

Do not embed a raw `batch_id` in the branch name. A coordination-backed
`batch_id` is an opaque nonempty single-line string and may contain `:` or `;`.
`:` is rejected outright as a ref component — `git check-ref-format --branch
'revert/aw-b:466'` fails with `not a valid branch name` and exit 128, aborting
the revert at its first step, mid-incident. `;` is accepted by git as a ref
character but is a shell metacharacter, so an unquoted use is its own hazard.
Slugging removes both classes of problem at once.

Derive a validated slug instead, and keep it collision-resistant by appending
the suspect commit's short SHA:

```bash
git fetch origin
BATCH_SLUG=$(printf '%s' "${BATCH_ID}" \
  | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^[-.]*//; s/[-.]*$//')
REVERT_BRANCH="revert/${BATCH_SLUG}-$(git rev-parse --short "${SHA}")"
git check-ref-format --branch "${REVERT_BRANCH}" || exit 1
git checkout -b "${REVERT_BRANCH}" "origin/${BASE}"
```

Validate with `git check-ref-format --branch` before `git checkout -b` rather
than after: it is the cheap fail-closed check, and it costs nothing. Where the
batch has no `batch_id` at all, name the branch from the suspect PR number and
short SHA by the same rule.

The revert goes through the repo's normal PR path. It is never pushed straight
to `BASE`, and never merged by an agent (see [4. Authority](#4-authority)).

### Revert each landed commit

**The invocation depends on the commit's parent shape**, which is why section 1
classifies every commit rather than assuming one style:

| Parent shape | Landed by | Revert with |
| --- | --- | --- |
| one parent | squash or rebase merge | `git revert <sha>` |
| two or more | true merge commit | `git revert -m 1 <sha>` |

A merge commit has no single parent to diff against, so `git revert` needs `-m`
to name the mainline. `-m 1` is the first parent, which for a merge into `BASE`
is the base-branch side. Omitting it on a true merge is a hard error, not a
default:

```text
error: commit <sha> is a merge but no -m option was given.
fatal: revert failed
```

Git does **not** give you the symmetric warning. On current git, `-m 1` against
a single-parent commit succeeds silently rather than erroring (verified on
2.50.1 and 2.54.0), because parent 1 is that commit's only parent; only `-m 2`
or higher fails, with `does not have parent 2`. So `-m 1` is harmless-but-
unsignalled on a squash commit, while older git versions reject `-m` on a
non-merge outright. Neither behaviour is something to depend on: determine the
parent shape from the commit and use the matching form, rather than letting git
tell you when you guessed wrong.

```bash
# single-parent (squash/rebase)
git revert --no-edit "${SHA}"
# true merge commit
git revert -m 1 --no-edit "${SHA}"

# resolve, then
git revert --continue --no-edit
# or, to get back to the pre-revert state
git revert --abort
```

Repeat for each in-scope commit, newest to oldest.

### Conflicts caused by later unrelated merges

A commit that landed after the suspect commit, and touched the same code,
makes the revert conflict. Two classes show up, and they need different
handling:

- **Content conflict** (`UU`): the later commit edited lines the reverted
  commit introduced.
- **Modify/delete conflict** (`UD`): the later commit edited a file the
  reverted commit created. Git leaves the working-tree version in place and
  asks you to choose.

Resolve by classifying each surviving hunk from the later commit:

- **Dependent** — the hunk cannot exist without the commit being reverted (it
  edits a function, file, or schema that commit introduced). It dies with the
  revert. That later commit is now *partially reverted*: its lane outcome is no
  longer `realized`, and section 3 applies to it too.
- **Independent** — the hunk edits code that predates the reverted commit. Keep
  it. Losing it would silently revert an out-of-scope PR.

If an independent hunk cannot be preserved — for example the whole file must go
— then the revert collaterally reverts a commit that is not in scope. That is a
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
- reverting would collaterally revert out-of-scope commits that carry
  independent value; or
- many later commits depend on the reverted code, so the revert closure grows
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
nonzero exit is not automatically wrong — later independent commits are
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
evidence and does not block the revert. Extending that same rule: a transport
the backend does not advertise, or reports unsupported, means skip the emission
and record `typed event transport: unavailable` — not `UNKNOWN`, and not an
assumption that a CLI is there to call.

`agent-coord` below is *this* repo's `coordination_backend` seam, and the
command lines are illustrative of that seam rather than portable requirements.
A consumer repo resolves its own configured backend and its own invocation; do
not assume the `agent-coord` binary exists, is on `PATH`, or is responsive. The
events and terminal values are the portable part.

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

1. Record `REPO`, `BASE`, base tip, the suspect commit SHA, **the repo's merge
   style**, `batch_id`, lane, dependency plan path/id, and the observed
   failure. Unverifiable facts stay `UNKNOWN`.
2. Enumerate landed commits on the first-parent line **without `--merges`**,
   and classify each one's parent shape.
3. Compute the revert closure from the batch manifest, `merge_order` edges, and
   git. Fail closed to the wider scope on any `UNKNOWN`. Fix `PRE_BATCH_SHA` as
   `<oldest-in-scope-sha>^1`.
4. Decide revert versus forward fix, and write down why.
5. Derive a slug branch from the batch id, check it with
   `git check-ref-format --branch`, and create it from `origin/${BASE}`; never
   work on `BASE`.
6. Revert each in-scope commit newest first, using the form its parent shape
   requires: `git revert <sha>` for single-parent, `git revert -m 1 <sha>` for a
   true merge commit.
7. Classify every conflicting hunk as dependent or independent; stop and
   re-scope if an independent hunk cannot be preserved.
8. Validate the branch, and diff the final tree against `PRE_BATCH_SHA`.
9. Correct the changelog: delete an `[Unreleased]` entry, or add a correcting
   entry when the original shipped.
10. Rerun the merge ledger, or record `merge_ledger: UNKNOWN` when the seam is
    `n/a`.
11. Record `human_intervention --kind manual-fix` plus the `error` event; close
    a non-terminal lane `superseded` or `abandoned`; for an already-`done`
    lane, open a new lane and reclassify the worked issue as `regressed`.
12. Open the revert PR as a draft and escalate to the operator for the merge
    decision.
