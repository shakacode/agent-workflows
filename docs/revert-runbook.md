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

Commands below use one stable placeholder set:

| Placeholder | Meaning |
| --- | --- |
| `REPO` | `OWNER/REPO_NAME`, as `gh --repo` takes it |
| `OWNER`, `REPO_NAME` | the two halves separately, for `gh api graphql` |
| `BASE` | the repo's `base_branch` seam, e.g. `main` |
| `BASE_TIP` | `origin/${BASE}` as it stood when scope analysis began |
| `PR` | the suspect pull request number |
| `TIP` | the commit on `BASE` that landed `PR` (for a merge PR, the merge commit itself) |
| `N` | how many commits `PR` contains |
| `MERGE_STYLE` | how `PR` landed — literal `merge`, `squash`, or `rebase`, classified per PR |
| `SHA` | whichever single commit a given command is about |
| `PATHS` | bash array of the paths the in-scope landed commits touched, built in [Recover each PR's landed range](#recover-each-prs-landed-range) |
| `PRE_BATCH_SHA` | the base-branch state before the closure landed |
| `OLDEST_IN_SCOPE_SHA` | the oldest landed commit in the closure — the last entry of the oldest in-scope PR's `REVERT_LIST` |
| `BATCH_ID`, `LANE`, `TARGET` | coordination identifiers for the lane that produced `PR` |
| `AGENT_ID` | stable identifier of the agent claiming the repair lane |
| `REPAIR_BATCH_ID`, `REPAIR_LANE` | coordination identifiers for the **repair** lane — always distinct from `BATCH_ID`/`LANE` |
| `REPAIR_TARGET` | the repair lane's canonical target — the audit child issue, never the suspect PR |
| `REPAIR_PR` | the PR that actually repaired the harm — the revert *or* a forward fix |
| `REPAIR_PR_URL` | `REPAIR_PR`'s HTML URL, derived in [checkpoint B](#coordination-events-and-terminal-state); unset until a repair merges |
| `EVIDENCE_URL` | the durable URL a terminal release cites — `REPAIR_PR_URL` on the repair path, the accepted-risk record's URL on the no-repair path, and **unset** when neither exists |

- `REPO`, `BASE` (the repo's `base_branch` seam), and the current base tip SHA,
  recorded as `BASE_TIP`:

  ```bash
  git fetch origin
  BASE_TIP=$(git rev-parse "origin/${BASE}")
  ```

  Fetch first: `origin/${BASE}` is a remote-tracking ref, and without a fetch it
  is as stale as the local branch. Capture `BASE_TIP` *before* scope analysis,
  not after — section 2 re-checks it before creating a branch.

  **`BASE_TIP` is the only base reference scope analysis reads.** Never pass the
  local `${BASE}` to a scope query. A local branch that is clean but simply not
  pulled is behind its remote, so analysis would run against an older tree than
  the one you revert from, omit the commits that landed in between, and produce a
  too-narrow revert with no error anywhere. The re-check in section 2 cannot
  catch that: it compares two `origin/${BASE}` readings and never looks at the
  local ref. One name for one fact is the fix.
- The commit SHA on `BASE` that landed the suspect PR.
- **The repo's merge style.** Establish it; do not assume it. It decides both
  how you enumerate landed work and how you revert it. Check with:

  ```bash
  git --no-pager log --first-parent --format='%h parents=%p | %s' "${BASE_TIP}" | head -20
  ```

  Three styles land a PR three different ways, and the two single-parent styles
  are **not** interchangeable:

  | Style | Parents | Commits per PR |
  | --- | --- | --- |
  | merge commit | two or more | one merge commit |
  | squash merge | one | one commit |
  | rebase merge | one | **N** — the PR's whole series, replayed |

  Parent shape alone cannot tell squash from rebase: both land single-parent
  commits. The difference is how many, and getting it wrong reverts part of a
  PR. A repo can contain all three, so classify per PR rather than once for the
  repo.
- **The landed commit range for the suspect PR** — see
  [Recover each PR's landed range](#recover-each-prs-landed-range). The unit of
  revert is a PR's complete range, not a single SHA.
- The `batch_id` and lane name that produced it, if any.
- The `stage-dependency-plan` v1 path and id used by that batch, if any.
- `PRE_BATCH_SHA`: the state the base branch was in before the closure landed,
  used as the validation target in section 2. It is the first parent of the
  **oldest** in-scope landed commit — the last entry of the oldest PR's
  `REVERT_LIST` — so it is only final once section 1 has fixed the closure:

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
git log --first-parent --format='%H %P%x09%s' "${BASE_TIP}" | head -40
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

This one-liner enumerates and classifies in the same pass. Start the range at
the suspect commit's own parent — that is knowable now, whereas `PRE_BATCH_SHA`
is only fixed once the closure is — and widen it if the closure turns out to
reach further back:

```bash
git log --first-parent --format='%H' "${SHA}^1..${BASE_TIP}" | while read -r sha; do
  if git rev-parse -q --verify "${sha}^2" >/dev/null; then
    printf 'merge-commit   %s  %s\n' "$sha" "$(git show -s --format='%s' "$sha")"
  else
    printf 'single-parent  %s  %s\n' "$sha" "$(git show -s --format='%s' "$sha")"
  fi
done
```

This is a read-only survey: it reports shape, it does not prescribe a command
per commit. The revert is issued per **PR range**, not per commit — see
[Revert each landed commit](#revert-each-landed-commit).

Test for the existence of a second parent (`^2`) rather than counting parents
through `wc`. BSD/macOS `wc -w` left-pads its output, so a `$(… | wc -w)`
comparison against `1` silently fails there while working on GNU coreutils —
and a classifier that misreports shape on one platform is worse than no
classifier, because it reintroduces the too-narrow revert on exactly the repos
that squash-merge.

### Recover each PR's landed range

Parent shape tells you *how* to revert a commit. It does not tell you *how many*
commits a PR landed, and that is a separate way to revert too little. A rebase
merge replays the PR's whole series onto the base, so a three-commit PR lands as
three consecutive single-parent commits. Reverting only the newest of them
leaves the rest of the change applied — the same too-narrow-revert failure as a
`--merges` enumeration, one level down.

**The unit of revert is a PR's complete set of landed commits, not a single
SHA.**

A terminology note, because conflating two senses of "range" caused a real bug
in this document: *landed range* below means **the set of commits a PR put on
`BASE`**, which you carry as an explicit list. It never means git's `A..B` range
**operator**, which this runbook does not use for reverts at all — see the two
bullets after the list construction for why.

Recover the range from GitHub plus git. You need two facts: the landed tip, and
how many commits the PR contains.

```bash
TIP=$(gh pr view "${PR}" --repo "${REPO}" --json mergeCommit --jq '.mergeCommit.oid')
```

**Do not count commits with `gh pr view --json commits`.** That array is
**capped at 100** and truncated *silently* — no error, no warning, no partial
marker. Verified against `rails/rails#16485` (true count 230) and
`rails/rails#34477` (true count 170): both return exactly 100. It fails in the
under-count direction, so `<tip>~<n>..<tip>` yields a **short range**, part of
the PR stays applied, and you get precisely the too-narrow revert this section
exists to prevent — on the largest PRs, which are the ones where it is hardest
to notice. The `UNKNOWN` guard below does not catch it either: a capped count
still walks cleanly for those 100 commits.

Use the authoritative `totalCount` instead:

```bash
N=$(gh api graphql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){commits{totalCount}}}}' \
  -f o="${OWNER}" -f r="${REPO_NAME}" -F n="${PR}" \
  --jq '.data.repository.pullRequest.commits.totalCount')
```

Where GraphQL is unavailable, page the REST endpoint and sum — same answer, one
request per 100 commits:

```bash
N=$(gh api "repos/${REPO}/pulls/${PR}/commits" --paginate --jq 'length' \
  | awk '{s+=$1} END {print s}')
```

Note `-F n=` for the PR number: GraphQL needs a JSON integer for `$n:Int!`, and
`-f n=` would send a string.

With `TIP` and `N` in hand, build the **ordered list of landed commits**,
newest first. How many commits go in it depends on the merge style, and this is
the single most dangerous place to get it wrong:

- **Merge commit**: one commit — `TIP` itself. `-m 1` already brings in the
  whole side branch.
- **Squash merge**: **one** commit — `TIP` itself. `N` counts the PR's
  *pre-squash* commits, and those commits never landed on `BASE`. Using `N`
  here reverts `N-1` unrelated commits that landed *before* this PR.
- **Rebase merge**: `N` commits — the `N` first-parent commits ending at `TIP`.

Select on `MERGE_STYLE`; do not print the two assignments one after another and
rely on the operator running only the intended one. **Two unconditional
assignments are not two alternatives — copy-pasted, both execute, and the rebase
form silently overwrites the squash form.** Verified on a five-commit squash PR
with four unrelated PRs behind it: the pair yields a five-entry `REVERT_LIST`
naming all four of those unrelated PRs, which is a four-PR collateral revert
reached by following the runbook exactly as written. A block that is only
correct when read rather than run is the same defect class as prose that
contradicts its own command.

```bash
# MERGE_STYLE is the per-PR classification from "Before Anything Else":
# literal merge | squash | rebase. Unset or unrecognised is UNKNOWN — stop.
case "${MERGE_STYLE}" in
  merge|squash)
    # exactly one landed commit, whatever N says
    REVERT_LIST="${TIP}"
    ;;
  rebase)
    # the N first-parent commits ending at the tip, newest first
    REVERT_LIST=$(git log --first-parent -n "${N}" --format='%H' "${TIP}")
    ;;
  *)
    echo "MERGE_STYLE=${MERGE_STYLE:-<unset>} is UNKNOWN: classify the PR before building REVERT_LIST" >&2
    exit 1
    ;;
esac
```

The `*)` arm is not decoration. An unset `MERGE_STYLE` is exactly the state an
operator is in before classifying the PR, and failing closed there is what keeps
the block safe as printed rather than safe as intended.

Two deliberate choices in that rebase form, both of which the `A..B` range
operator gets wrong:

- `-n "${N}"` walking back from `TIP`, rather than `${TIP}~${N}..${TIP}`. The
  range operator is evaluated by `git rev-list`, which is **not** first-parent
  limited: if any commit in the span is a merge, the range also selects that
  merge's second-parent commits — commits your first-parent enumeration never
  displayed. On a span containing one merge, `rev-list` returned 4 commits where
  `--first-parent -n 3` returned the intended 3.
- An explicit list rather than a range, so the commits reverted are exactly the
  ones you just reviewed.

Print the list and read it before going near section 2. If it contains anything
you did not expect — a commit from another PR, a merge you did not account for —
stop and re-run recovery.

```bash
printf '%s\n' ${REVERT_LIST} | while read -r c; do git --no-pager log -1 --format='%h %s' "$c"; done
```

**Match on subject and patch-id, not SHA.** A rebase rewrites every commit, so
the landed SHAs never equal the PR's original commit SHAs; comparing them finds
nothing and silently yields an empty range. Compare subjects first, and fall
back to `git patch-id --stable` when subjects were amended:

```bash
git show "${SHA}" | git patch-id --stable | cut -d' ' -f1
```

Verify the recovered range before reverting: its oldest commit's first parent
must be the pre-PR state, and every commit in it must belong to this PR. If the
count and the first-parent walk disagree — force-pushes, a later `main` merged
back in, or a PR whose commits were not contiguous on landing — the range is
`UNKNOWN`. Fail closed: widen to the enclosing batch closure or stop for the
operator rather than reverting a guessed range.

Treat the whole range as one unit in the disjointness test in
[Decision rule](#decision-rule): a later commit that depends on *any* member of
the range depends on the PR.

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

### Build the path set

`PATHS` is never typed by hand. It is the union of every path the in-scope
landed commits touched, read straight out of the range you just recovered:

```bash
# Union of the paths touched by every commit in REVERT_LIST. Read NUL-delimited
# into a bash array so a filename containing a space, tab, or newline stays
# exactly one pathspec.
PATHS=()
while IFS= read -r -d '' p; do PATHS+=("$p"); done < <(
  # shellcheck disable=SC2086
  printf '%s\n' ${REVERT_LIST} | while read -r c; do
    git diff --name-only -z "${c}^1" "${c}"
  done | sort -z -u
)
printf '%s path(s):\n' "${#PATHS[@]}"
printf '  %s\n' "${PATHS[@]}"
```

**Carry it as an array, and always expand it as `"${PATHS[@]}"`.** A
space-separated string expanded unquoted word-splits one filename into several
pathspecs. The fragments usually match nothing, so the query returns no later
commits touching that file — and the disjointness test in
[Decision rule](#decision-rule) reads "no later commit touched these paths" as
evidence of independence. The failure is silent and points the wrong way: it
manufactures the too-narrow revert. `git log` has no
`--pathspec-from-file`, so the array is the portable carrier; do not flatten it
into a variable in between.

When the closure spans several PRs, run the same accumulation for each PR's
`REVERT_LIST` and let `PATHS` grow across all of them — the disjointness test
compares whole closures, not one PR at a time.

### Landed commits that belong to no PR

Everything above builds the closure out of **PR ranges**. Not every commit on a
base branch came from a PR: a consumer repo may permit direct pushes, and an
operator hotfix during an incident is a direct commit by definition.

This matters because the two halves of the procedure can disagree. The
disjointness test in [Decision rule](#decision-rule) works on commits, so it
will correctly report that a later direct commit depends on the suspect change.
If the closure then only admits PR ranges, that commit has nowhere to go: it is
known-dependent and stays applied, and the revert leaves the base branch calling
into code that no longer exists. A too-narrow revert reached by a step that
already found the evidence is worse than one reached by missing it.

**A first-parent commit is a closure unit whether or not a PR produced it.**
Map every in-scope commit before building the closure:

```bash
git log --first-parent --format='%H' "${SHA}^1..${BASE_TIP}" | while read -r c; do
  if ! prs=$(gh api "repos/${REPO}/commits/${c}/pulls" --jq '[.[].number] | join(",")'); then
    printf '%s\tLOOKUP-FAILED — UNKNOWN\n' "$c"
  elif [ -z "${prs}" ]; then
    printf '%s\tno PR — direct commit\n' "$c"
  else
    printf '%s\tPR %s\n' "$c" "${prs}"
  fi
done
```

Three outcomes, three treatments:

- **Maps to a PR** — recover that PR's landed range and treat the whole range as
  the unit, exactly as above.
- **Confirmed direct commit** (the lookup succeeded and returned nothing) — the
  commit is its own closure unit, of exactly one commit. Admit it, and revert it
  in the same reverse-landing order by its parent shape. Nothing is lost by
  admitting it: the range machinery exists to answer "how many commits did this
  PR land", and for a direct commit that answer is one, known exactly. Refusing
  the case would be fail-closed theatre over the easiest unit in the document.
- **Lookup failed** — `UNKNOWN`. Stop, or widen to the enclosing batch closure.
  Do not read "the request errored" as "there is no PR": a network failure, a
  token without the scope, and a genuinely direct commit all produce no PR
  numbers, and only the third is safe to act on. That distinction is why the
  block branches on `gh api`'s exit status rather than on the emptiness of its
  output.

A direct commit in the closure is also a finding in its own right. Record it in
the revert PR body: it means work reached `BASE` outside the PR path, which the
audit trail this runbook depends on cannot otherwise see.

### Read the declared dependencies

Two artifacts declare lane dependency, and both are authoritative for scope:

- The registered batch manifest (see
  [Batch Provenance Manifest](coordination-backend.md#batch-provenance-manifest))
  maps `batch_id` to `lanes[].name` and `lanes[].targets`. It tells you which
  lane owns the failing target and which other lanes shipped in the same batch.
- The `stage-dependency-plan` v1 file (see
  [pr-processing](../workflows/pr-processing.md#stage-typed-dependency-gate))
  carries `edges[]`, each binding `from` (predecessor lane), `to` (dependent
  lane), and `type`. Every lane reachable from the failing lane by following
  edges forward — **of any type** — is a candidate for joint revert. Take the
  transitive closure, not just direct successors.

Read `type` from the **immutable `stage-dependency-plan` file**, which is the
only one of the two artifacts whose edges carry it; the mutable
`stage-dependency-gate` live replay carries `id`, `state`, `evidence`, and
`base_movement` per edge, and is where you check whether an edge is `pending` or
`satisfied` — not what kind of edge it is.

**Bind the plan file to its id before trusting a single edge.** A plan file on
disk is not self-identifying: a stale or mismatched one parses cleanly and
yields plausible edges for the wrong batch, which is a wrong closure arrived at
with full confidence. Verify `contract`, `version`, and `id` first, and only
then read edges:

```bash
jq -e --arg id "${STAGE_DEPENDENCY_PLAN_ID}" \
  '.contract == "stage-dependency-plan" and .version == 1 and .id == $id' \
  "${STAGE_DEPENDENCY_PLAN_PATH}" >/dev/null \
  || { echo "plan id mismatch: UNKNOWN"; exit 1; }

jq '.edges[]' "${STAGE_DEPENDENCY_PLAN_PATH}"
agent-coord status --batch-id "${BATCH_ID}" --json
```

**Do not filter to `merge_order`.** `stage-dependency-plan` v1 has three edge
types — `edit`, `validation_open`, `merge_order` — and per
[pr-processing](../workflows/pr-processing.md#stage-typed-dependency-gate) all
three bind `from` as the predecessor and `to` as the dependent. The types differ
only in how much the dependent lane is *permitted to do* while the edge is
pending: `edit` allows read-only discovery only, `validation_open` allows local
commits but blocks push and PR open, `merge_order` blocks merge alone. That is a
scheduling distinction, not a dependency-direction one. For revert scope all
three mean the same thing — the `to` lane's landed work was produced or
validated in a world where the `from` lane exists — so all three belong in the
closure.

`edit` is the most dangerous type to omit, not the least. A lane blocked on an
`edit` edge could not create a branch until its predecessor was satisfied, so it
is the case where a later PR most likely builds on the suspect PR's *behavior*
without touching the suspect PR's *files* — which means it also passes the
disjoint-file check in [Decision rule](#decision-rule). Filtering the edges and
relying on file overlap therefore misses it twice.

`STAGE_DEPENDENCY_PLAN_PATH` and `STAGE_DEPENDENCY_PLAN_ID` both come from the
trusted coordinator handoff, per
[pr-processing](../workflows/pr-processing.md#stage-typed-dependency-gate) —
never from a file discovered by searching the worktree. A missing, malformed, or
mismatched plan, or one whose id does not tie to `${BATCH_ID}`, is `UNKNOWN`:
widen the scope or stop, exactly as for an absent plan.

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
git log --ancestry-path --first-parent --format='%h %s' "${SHA}..${BASE_TIP}"

# Everything that touched the same files, in either direction.
git log --first-parent --format='%h %s' "${BASE_TIP}" -- "${PATHS[@]}"
```

`"${PATHS[@]}"` is quoted deliberately: see
[Build the path set](#build-the-path-set) for why an unquoted expansion turns a
whitespace filename into a false independence result.

#### Renames defeat a plain pathspec query, and there is no clean fix

`git log -- <path>` matches a path **under the name it has in each commit**.
A later `git mv` plus an edit therefore lands under a name that is not in
`PATHS`, the query omits it, and the disjointness test reads that omission as
independence — the exact "absence of evidence is not evidence of independence"
failure this document exists to prevent, arrived at through the recommended
command.

`--follow` is the obvious answer and only half of one. It accepts **exactly one
pathspec** (`git log --follow -- a b` fails with `fatal: --follow requires
exactly one pathspec`), so it cannot be handed `"${PATHS[@]}"`, and it works by
git's rename *heuristic*: a rename combined with a large enough edit falls below
the similarity threshold, is recorded as a delete plus an add, and is not
followed by anything.

Run both of these and reconcile them by hand. Neither is sufficient alone and
the pair is still not a proof:

```bash
# 1. Rename-aware history, one pathspec per invocation as --follow requires.
for p in "${PATHS[@]}"; do
  printf '=== %s\n' "$p"
  git --no-pager log --follow --format='%h %s' "${BASE_TIP}" -- "$p"
done

# 2. Every rename that landed in the window, at a loosened similarity
#    threshold, whether or not either side is currently in PATHS.
git --no-pager log --first-parent --find-renames=30% --diff-filter=R \
  --name-status --format='%h %s' "${SHA}..${BASE_TIP}"
```

If query 2 shows a rename whose source **or** destination is in `PATHS`, add the
other side to `PATHS` and re-run the whole cross-check — a rename can chain.

What neither query catches is a rewrite-plus-rename that scores below even the
loosened threshold; git has no record linking the two paths, so no pathspec
query can find it. That case is **`UNKNOWN`, not independent.** When the window
is small enough, read its full `--name-status` and judge the adds and deletes
directly; when it is not, fail closed to the enclosing batch closure or stop for
the operator. Do not record "no later commit touched these paths" as a
disjointness result unless the rename cross-check above actually ran.

### Decision rule

Revert **one PR** when all of the following hold:

- no edge of **any** type names its lane as a `from`; and
- the union of the file sets across the PR's **entire landed range** is disjoint
  from the file set of every later landed commit on `BASE`; and
- no later landed commit's content depends on symbols, files, or schema any
  commit in that range introduced.

Compare whole ranges, not individual commits: a later commit that depends on any
one member of a rebased series depends on the PR, and testing member-by-member
can find each individual commit "independent" while the PR as a whole is not.

Otherwise **unwind the closure**: the suspect PR's range plus every later
closure unit that depends on it, transitively — a later PR's whole range, or a
later direct commit on its own, per
[Landed commits that belong to no PR](#landed-commits-that-belong-to-no-pr). If any input to that test is
`UNKNOWN`, take the wider scope or stop for the operator. A too-wide revert is
a review problem; a too-narrow revert leaves the base branch in a state that
never existed and that nothing has ever validated.

Note that a `--merges`-filtered enumeration fails this test in the *unsafe*
direction: it makes the disjointness check trivially true by hiding the later
commits it should compare against.

## 2. Revert Order

Revert in **reverse landing order**: newest in-scope commit first, oldest last.
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

Sanitising the character class is necessary but not sufficient: a `batch_id` is
opaque and may also be *long*, and length is a separate failure. A 300-character
component **passes** `git check-ref-format --branch` and then fails at creation:

```text
fatal: cannot lock ref 'refs/heads/revert/aaa…': Unable to create
'…/.git/refs/heads/revert/aaa….lock': File name too long
```

So bound the length too. Truncate the human-readable slug, append a short digest
of the **full** id so two ids that truncate identically still differ, and add the
suspect short SHA:

`git fetch origin` can move `origin/${BASE}` between the scope analysis and the
branch creation. If it moved, work landed that the closure never considered, and
`PRE_BATCH_SHA` no longer describes the tree you are about to validate against.
Compare the tip you recorded in
[Before Anything Else](#before-anything-else) against the tip after fetching,
and rerun section 1 if they differ:

```bash
git fetch origin
NEW_BASE_TIP=$(git rev-parse "origin/${BASE}")
[ "${NEW_BASE_TIP}" = "${BASE_TIP}" ] || {
  echo "origin/${BASE} moved ${BASE_TIP} -> ${NEW_BASE_TIP}: rerun scope recovery"
  exit 1
}

BATCH_SLUG=$(printf '%s' "${BATCH_ID}" \
  | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40 \
  | sed 's/-\{2,\}/-/g; s/^[-.]*//; s/[-.]*$//')
[ -n "${BATCH_SLUG}" ] || BATCH_SLUG="batch"
BATCH_DIGEST=$(printf '%s' "${BATCH_ID}" | git hash-object --stdin | cut -c1-8)
REVERT_BRANCH="revert/${BATCH_SLUG}-${BATCH_DIGEST}-$(git rev-parse --short "${SHA}")"
git check-ref-format --branch "${REVERT_BRANCH}" || exit 1
```

This block derives and validates the name; it does **not** create the branch.
Creation comes after the claim below.

Order matters in that pipeline. `tr` runs before `cut`, so everything is ASCII
by the time it is truncated and a multibyte character cannot be split in half.
Truncating before the trailing-separator trim means a cut landing on `-` or `.`
cannot leave an invalid ending. The empty-slug fallback covers a `batch_id` with
no usable characters at all (`:::`): without it the name becomes
`revert/-<digest>-…`, which **passes** `check-ref-format` — so the guard does not
catch it — while producing a leading-hyphen component that later `git` commands
parse as an option. `git hash-object --stdin` keeps the digest a pure git
operation — no `shasum`/`sha256sum` portability question. Any `batch_id`,
however long, yields a name under ~65 characters.

Keep the `check-ref-format` guard: it still catches the character class, and it
runs before any checkout because it is the cheap fail-closed check. Where the
batch has no `batch_id` at all, name the branch from the suspect PR number and
short SHA by the same rule.

#### Claim the repair lane

**Claim before the branch exists, not after.** Per the
[PR-Batch Prompt Intake gate](../workflows/pr-batch-intake.md#canonical-launch-target-gate), the
bounded status-then-claim sequence runs *before* branch creation, editing, or
dispatch, and a refused claim must not reach branch creation at all. Deriving
the name first and creating the branch after the claim satisfies both
constraints: the claim can record the branch it will own, and a refusal leaves
the checkout unmutated with no orphaned revert branch to clean up.

**The repair lane needs its own canonical target, not the suspect PR.** The
Canonical Launch Target Gate requires an exact GitHub issue or existing PR per
lane, and refuses a second claim on a target that is already claimed with
`CLAIM_REFUSED` / exit 3. Whenever the original lane is still non-terminal —
`planned`, `claimed`, `active`, or `blocked`, all of which section 3 handles —
it still owns the suspect PR, so a repair claim naming that PR is refused and
the documented path cannot start.

Use the `post-merge-audit` child issue filed for the revert consideration. It is
an exact GitHub issue, it is distinct from the suspect PR, and it is the issue
that authorised this work — so it is the canonical target in the ordinary sense
rather than a synthetic one. Where the revert was initiated without an audit,
follow the gate's own rule for a missing target: search for an existing issue or
PR first, and otherwise create the canonical issue under planning-time
issue-creation authority *before* branch creation. The revert PR cannot serve as
the target, because it does not exist yet at claim time.

The repair lane is **not** the lane that produced the suspect PR. Claim it under
its own `REPAIR_BATCH_ID`, `REPAIR_LANE`, and `REPAIR_TARGET`, distinct from the
`BATCH_ID`, `LANE`, and `TARGET` in the placeholder table, and use those repair
identifiers for the heartbeat and for the repair lane's own closeout. Reusing
the original lane's identifiers cannot produce the "genuinely new lane" the
already-`done` path in section 3 requires — it reopens history against a lane
whose first terminal event is immutable.

The claim carries: the repository, `REPAIR_TARGET` as the canonical target, the
repair batch and lane identifiers, the acting agent identity, and
`REVERT_BRANCH`. Run the bounded status check first, then claim. As with every
coordination command in section 3, this is *this* repo's `coordination_backend`
seam rather than a portable requirement — a consumer repo claims through its own
configured backend, and backend `n/a` skips the claim and records ownership in
the durable handoff instead. No invocation is given here on purpose: it cannot
be exercised by the replay harness, and an unreplayable recipe in this document
has a poor track record.

On `CLAIM_REFUSED` / exit 3, stop. Do not create the branch, and do not retarget
onto a different canonical identity to get around the refusal — a refusal means
someone or something already owns that work, which is a coordination question,
not a scope question.

Only once the claim holds, create the branch:

```bash
git checkout -b "${REVERT_BRANCH}" "${BASE_TIP}"
```

The branch is created from `${BASE_TIP}` — the exact commit scope analysis read
— not from `origin/${BASE}`. Past the equality check the two are the same SHA by
construction, so this changes nothing at runtime; it removes the last place a
base reference could be re-resolved, which is what let a stale ref diverge from
the analysed tree in the first place.

The repair lane is released at
[checkpoint B](#coordination-events-and-terminal-state) — `done` once the repair
merges, or terminally released on the no-repair path. It is never left open.

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
# single-parent (squash commit, or one commit of a rebased series)
git revert --no-edit "${SHA}"
# true merge commit
git revert -m 1 --no-edit "${SHA}"

# resolve, then
git revert --continue --no-edit
# or, to get back to the pre-revert state
git revert --abort
```

Revert every commit in every in-scope PR's landed list, newest to oldest. For a
rebase-merged PR that is N commits; for a squash or merge PR it is exactly one,
regardless of how many commits the PR contained.

**Give each PR's range to a single `git revert` invocation.** Do not loop
one-SHA-at-a-time. `git revert` is a sequencer: handed a range it queues every
commit in `.git/sequencer/todo`, reverts them newest-first on its own, and — the
part that matters — `git revert --continue` resumes at the *next* queued commit
after you resolve a conflict. A per-commit loop passes one SHA per invocation,
so there is no queued state to resume, and rerunning the loop restarts at the
newest commit and tries to re-revert what is already reverted.

Because a PR's landed list is shape-homogeneous — a rebase series is all
single-parent, a squash is one single-parent commit, a merge PR is one merge
commit — `-m` never has to apply to a mixed set:

```bash
# squash PR, or a rebase PR's whole series: the reviewed list, newest first
# shellcheck disable=SC2086
git revert --no-edit ${REVERT_LIST}

# merge-commit PR: one merge commit, -m names the mainline
git revert -m 1 --no-edit "${TIP}"
```

`${REVERT_LIST}` is deliberately unquoted — it must word-split into one argument
per commit. That is the whole mechanism: `git revert` receives every commit at
once, queues them in `.git/sequencer/todo`, and `--continue` resumes through the
queue. It is also why the list is built with `--first-parent`, never with a
`A..B` range.

Run one such invocation per in-scope PR, taking the PRs newest-first. Keep `-m`
scoped to a single merge commit; never hand a mixed-shape set to one invocation
and rely on `-m` applying correctly across it.

Confirm the list's shape rather than assuming it. The classifier in section 1
already labelled every commit; the list handed to the bare form must be
**all single-parent**. If any member is a merge commit, that member is its own
merge PR and takes the `-m 1` form alone — never fold it into the bare
invocation, which would apply one mainline choice to every commit.

**Git does not fail closed here, and an earlier draft of this runbook said it
did.** Handed a set whose *newer* members are single-parent and whose *older*
member is a merge, `git revert` commits the newer reverts first and only then
stops at the merge. The result is a **partially applied revert** — every
single-parent member newer than the merge is already committed, and the rest sit
in `.git/sequencer/todo`. So on this failure you must:

```bash
git revert --abort
```

`--abort` unwinds the whole sequence, including the reverts already committed
(verified: branch returns to zero commits ahead of the base). Then re-run range recovery. Never leave a
partially reverted range on the branch and never try to press on from it.

On a conflict the sequencer stops with the remaining commits still queued.
Resolve, then:

```bash
git add <resolved-paths>      # or git rm for a modify/delete conflict
git revert --continue --no-edit   # resumes at the next queued commit
git revert --abort                # unwind the whole sequence and re-scope
```

**There are exactly two options: resolve and continue, or abort and re-scope.**

`git revert --skip` is not a third one, despite being offered in git's own
conflict hint. It skips the *revert*, not the commit's effect — the original
commit stays applied while the rest of the sequence proceeds. That is a
too-narrow revert reached by following the recovery path, which is the failure
this runbook exists to prevent. If a commit's revert cannot be resolved, the
scope decision was wrong: abort and return to section 1.

#### Abandoning a multi-PR closure

`git revert --abort` cancels **only the invocation it is run from**. A closure
spanning several PRs runs one invocation per PR in series, so aborting the
second one leaves the first PR's revert commits sitting on the branch. This is a
consequence of the one-invocation-per-PR structure, not of `--abort` itself.

Do not try to resume from that state. Re-running the closure newest-first hits
the already-reverted PR and stops with `nothing to commit, working tree clean`
and a nonzero status, before reaching the PRs that still need reverting —
verified. It looks like an inexplicable failure and it hides the remaining work.

Abandon the whole branch and rebuild it, which is safe precisely because the
branch is disposable at this point — it holds nothing but revert commits and has
not been pushed (the draft PR is not opened until the end of the procedure):

```bash
git revert --abort                                  # cancel the current sequencer
git checkout -B "${REVERT_BRANCH}" "${BASE_TIP}"    # discard every revert so far
```

`${BASE_TIP}` is already the commit the branch was created from, so there is no
second start-point to record and nothing to drift. After this the branch is zero
commits ahead; return to section 1, re-derive the closure, and revert it from
the beginning.

What you lose is the conflict resolutions from the PRs that had already
succeeded. If a closure is large enough that redoing them matters, enable
`rerere` **before** the first invocation, so resolutions are replayed
automatically on the rebuild rather than reconstructed by hand.

**Capture the prior setting before you change it, and restore it on every exit
path.** `rerere` is repo-local git configuration with no session scope: once
this procedure turns it on, every later conflict in this checkout — rebases,
merges, work unrelated to the incident — silently reuses recorded resolutions,
and nothing ever turns it back off. A successful repair is not an exemption;
that is the path most likely to be forgotten, because the operator moves on.

```bash
# before the first revert invocation
RERERE_PRIOR=$(git config --local --get rerere.enabled || true)   # empty = unset locally
git config --local rerere.enabled true
```

`--get` exits nonzero when the key is unset, hence the `|| true`; an empty
`RERERE_PRIOR` means "no local value", which is different from an explicit
`false` and must be restored differently. Read and write `--local`
deliberately: a global or system `rerere.enabled` belongs to the operator, and
this procedure must neither read it as its own nor overwrite it.

```bash
# on every exit path: repair merged, revert abandoned, or accepted risk
if [ -n "${RERERE_PRIOR}" ]; then
  git config --local rerere.enabled "${RERERE_PRIOR}"
else
  git config --local --unset rerere.enabled || true
fi
```

`--unset` on an already-absent key exits 5; the `|| true` keeps the restore
idempotent so it can be run at the end of any path without a special case.
[Checkpoint B](#coordination-events-and-terminal-state) names this restore on
both the repair and the no-repair paths.

Do not rerun the range command after a conflict — that restarts it from the
newest commit. `git revert --continue` is the only correct resume, and
`.git/sequencer/todo` shows what is still pending if you need to check.

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
(`CHANGELOG.md` here). Two separate questions: **what** the correction is, and
**who is allowed to write it**. Answer them in that order — the second is repo
policy and overrides any instinct to edit the file from the revert PR.

Which correction applies depends on whether the reverted entry has shipped:

- **Still under `### [Unreleased]`**: delete the entry. It never reached a
  released version, so there is nothing for a reader to un-learn. Delete only
  that entry; leave neighbouring entries and the category heading alone.
- **Under a released version header**: do not edit the released section. A
  released changelog section is a historical record of what that version
  contained, and it did contain the change. Add a new entry under
  `### [Unreleased]` → `#### Fixed` (or `#### Removed` when a user-visible
  feature is gone) that names the reverted PR and issue and says the change was
  reverted.

**Who writes it is the repo's changelog-ownership policy, not this runbook's
call.** Where a repo restricts changelog edits — as this one does, per
`AGENTS.md` → **Changelog Ownership**: only dedicated `/update-changelog` or
release lanes may edit `CHANGELOG.md`, and ordinary PRs record
`deferred_to_update_changelog` — the revert PR is an ordinary PR and **does not
touch the changelog**. It records `deferred_to_update_changelog` like any other
lane, and the correction is carried by a dedicated `$update-changelog` lane.
Where a repo has no such restriction, the revert PR may carry the correction
itself. Read the policy before deciding; a revert PR that edits a
policy-restricted `CHANGELOG.md` is rejected for the edit, not thanked for the
bookkeeping.

Deferring the *edit* is not deferring the *decision*. `$update-changelog` does
the release-time sweep and version stamping, but **it does not know that a merge
was unwound**: it derives entries from merged PRs, and the reverted PR is still
a merged PR, so left to itself it re-derives exactly the entry that must go. So
whichever repo you are in:

- State the exact required correction in the revert PR body — which entry to
  delete, or the precise correcting entry to add and under which heading. That
  body is the input the changelog lane works from.
- Run `$update-changelog` for the sweep **after** the correction is settled,
  never *instead of* it, and confirm the swept result matches what the revert PR
  asked for rather than what derivation produced.

Under a restrictive policy this also means the revert is not fully bookkept when
its PR merges. The changelog lane is outstanding follow-up work; name it in the
durable handoff so it is not lost with the incident.

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

This whole section is `coordination_required` only. A
`coordination_not_applicable` revert is local: record the revert decision, its
evidence, and its terminal state in the controller's own durable record, and run
none of the `agent-coord` event or terminal-state commands below.

For `coordination_required`, record these against the original lane. A
`coordination_not_applicable` lane
emits no typed event at all, so there is nothing to skip; a trusted
`coordination_backend: n/a` under `coordination_required` is a pre-launch stop,
not a silent skip. An
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

**These events happen at two different times, and conflating them writes a
false record.** Nothing has merged when you open the draft PR, and the operator
may reject the revert, replace it with a forward fix, or decline to repair at
all. A `manual-fix` event that already names a merged repair claims something
that has not happened — and since the first terminal event is immutable, a
coordination history that overstates a completed repair cannot be corrected
afterwards. Record only what is true at each checkpoint.

**Checkpoint A — at escalation, before the operator decides.** The observed
failure is a fact now, and so is the proposal. A merged repair is not.

```bash
agent-coord record-event --type error --severity "${P0_TO_P3}" \
  --category "${CATEGORY}" --message "${OBSERVED_FAILURE}" \
  --batch-id "${BATCH_ID}" --lane "${LANE}" --repo "${REPO}"
```

The lane is now blocked on an approval, which is the `permission` branch of the
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

**Checkpoint B — only after a repair has actually merged.** The gate is *a
repair landed*, not *the revert landed*. Section 2 offers a forward fix as a
legitimate alternative and the operator may take it; if checkpoint B fired only
for reverts, a forward-fixed incident would leave the lane with an outstanding
`help_requested`, never closed out, permanently mid-incident even though the
incident was resolved.

So `${REPAIR_PR}` is whichever PR actually merged — the revert **or** the
forward fix. Confirm it merged before emitting anything here:

```bash
gh pr view "${REPAIR_PR}" --repo "${REPO}" --json state,mergedAt
```

A closed-unmerged or still-open repair reaches neither this event nor the
terminal closeout below.

Once it is confirmed merged, derive its URL — `REPAIR_PR` is a number, and the
terminal release wants a URL:

```bash
REPAIR_PR_URL=$(gh pr view "${REPAIR_PR}" --repo "${REPO}" --json url --jq '.url')
EVIDENCE_URL="${REPAIR_PR_URL}"
```

On the no-repair path neither variable is set from a repair; see the
accepted-risk bullets below for what `EVIDENCE_URL` may hold there.

```bash
agent-coord record-event --type human_intervention --kind manual-fix \
  --batch-id "${BATCH_ID}" --lane "${LANE}" \
  --repo "${REPO}" --target "${TARGET}" \
  --message "Harm from PR #${PR} repaired by merged PR #${REPAIR_PR}"
```

Word the message for the repair that actually happened — "reverted by" is wrong
for a forward fix, and the message is the durable record a later audit reads.
`manual-fix` is the correct kind either way: both are a human-directed repair
outside the lane's own workflow.

Everything below — the terminal closeout and the already-`done` path — also
belongs to checkpoint B. A lane is not closed out on the strength of a *proposed*
repair.

Checkpoint B closes **two** lanes, and they are not the same lane: the original
lane that produced the suspect PR (per the terminal-state rules below), and the
repair lane claimed in section 2, released `done` under `REPAIR_BATCH_ID` /
`REPAIR_LANE` now that its PR has merged.

**Restore `rerere.enabled` here too**, using the saved `RERERE_PRIOR` and the
restore block in
[Abandoning a multi-PR closure](#abandoning-a-multi-pr-closure). A merged repair
is the path on which this is most often skipped and the one on which the leftover
setting does the most damage: the incident is over, the checkout stays in use,
and every unrelated conflict from here on silently replays a resolution recorded
during the revert.

**If no repair lands at all** — the operator declines both the revert and a
forward fix and accepts the risk — checkpoint B does not fire, but the lane must
still reach a defensible state rather than dangling with an open
`help_requested`:

- Emit no `manual-fix`. Nothing was fixed, and claiming otherwise is the same
  false record this split exists to prevent.
- The checkpoint A `error` record stands as the durable statement of unrepaired
  harm. Do not retract it.
- Close a non-terminal lane by the same rule as below (`superseded` when a named
  successor will carry the work, otherwise `abandoned`), using the conditional
  `RELEASE_ARGS` block below so the flag is built rather than typed. **Never
  pass `--evidence-url "${REPAIR_PR_URL}"` on this path**. No repair PR exists,
  so that variable is unset and expands to an empty argument, which
  `agent-coord release` rejects outright:

  ```text
  --evidence-url must be an HTTP(S) URL with a host
  ```

  The closeout then fails and the lane stays open — the exact dangling state
  this path is meant to avoid. Set `EVIDENCE_URL` to a real durable URL for the
  accepted-risk decision if one exists (the tracking issue or handoff comment
  recording it), and otherwise leave it unset so the flag is **omitted
  entirely**; an omitted `--evidence-url` is accepted. Never pass an empty
  string.
- An already-`done` lane stays `done` and receives no new event, but the
  worked-issue outcome is still `regressed` — the harm is real and now
  knowingly unrepaired.
- **Terminally release the repair lane too**, under `REPAIR_BATCH_ID` /
  `REPAIR_LANE`, by the same `superseded`-if-a-named-successor-exists rule.
  Section 2 claimed that lane; checkpoint B is the only place that closes it, so
  a no-repair outcome that skips checkpoint B leaves it active or decaying to
  stale, where it obstructs later claims on the same target. The same
  `--evidence-url` rule applies: a real accepted-risk URL, or omit the flag.
- **Close the draft revert PR.** The procedure opened it at checkpoint A and no
  repair is landing, so it is now a permanently open PR proposing a change the
  operator has declined. Close it with a comment naming the accepted-risk
  decision, and delete or leave the unpushed revert branch as the repo's
  convention prefers — it holds only revert commits.
- If you enabled `rerere.enabled` for the closure, restore `RERERE_PRIOR` with
  the block in
  [Abandoning a multi-PR closure](#abandoning-a-multi-pr-closure) — restore the
  prior value, do not blanket-unset. It is repo-local git configuration this
  procedure turned on, and nothing else turns it off.
- Record the accepted-risk decision and the deciding operator in the durable
  handoff. An accepted risk that is written down is a decision; one that is not
  is an unexplained dangling lane.

**Terminal state depends on whether the lane has already closed.**

*Lane not yet terminal* (`planned`, `claimed`, `active`, `blocked`) — close it
now, choosing between the two non-`done` terminal values:

**Build the arguments conditionally.** `--evidence-url` is optional and must be
either a real HTTP(S) URL or absent — an empty string is rejected and the
closeout fails, leaving the lane open. Do not print one command that passes the
flag unconditionally and rely on the reader to drop it: the same block then
serves both the repair and the accepted-risk paths, and it is correct as run.

```bash
RELEASE_ARGS=(--terminal superseded --pr-state "${PR_STATE}"
  --batch-id "${BATCH_ID}" --repo "${REPO}" --target "${TARGET}")
if [ -n "${EVIDENCE_URL:-}" ]; then
  RELEASE_ARGS+=(--evidence-url "${EVIDENCE_URL}")
fi
agent-coord release "${RELEASE_ARGS[@]}"
```

Where an array is not available, the two forms are separate commands, never one
command with an optionally-empty flag:

```bash
# a durable evidence URL exists
agent-coord release --terminal superseded --pr-state "${PR_STATE}" \
  --batch-id "${BATCH_ID}" --repo "${REPO}" --target "${TARGET}" \
  --evidence-url "${EVIDENCE_URL}"

# no durable URL exists — omit the flag entirely
agent-coord release --terminal superseded --pr-state "${PR_STATE}" \
  --batch-id "${BATCH_ID}" --repo "${REPO}" --target "${TARGET}"
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

A terminal release has preconditions, and failing them leaves the lane open —
the dangling state these rules exist to prevent. Verified against this repo's
seam: the release refuses with `terminal release requires a claim with batch_id`
unless the claim carried one, and with `terminal closeout does not match exactly
one lane in batch <id>` unless it resolves to exactly one registered lane. Claim
both lanes under their batch and lane identifiers from the start, and treat a
closeout that cannot resolve as `UNKNOWN`: reconcile the lane and retry rather
than moving on with it open.

*Lane already closed `done`* — you cannot rewrite it. **The first terminal
event is immutable.** Later authenticated completion may reconcile an
`abandoned` lane or a `superseded` issue, but there is no reconciliation that
turns a `done` lane into a not-done lane, and attempting one is a protocol
violation rather than a correction. Instead:

1. Record the checkpoint B lane-scoped `human_intervention --kind manual-fix`
   event on the original lane (the command above) — after the repair merges, not
   when it is proposed — so dashboards reading lane history stop presenting the
   outcome as cleanly `done`. If no repair lands, emit nothing here and follow
   the accepted-risk bullets above instead.
2. The repair runs as a **new lane** under its own `REPAIR_BATCH_ID` /
   `REPAIR_LANE` — but **establish that lane before you build the repair**, not
   here. A lane created after its own work merged cannot claim the target,
   cannot heartbeat while the work happens, and records coordination history
   backwards. Claim it when you start section 2 (see
   [Claim the repair lane](#claim-the-repair-lane)),
   let it own the branch and the PR, and close it `done` here once the repair
   merges. This step is the closeout of a lane that already exists, not the
   creation of one.
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
- record the **checkpoint A** coordination events in section 3 and escalate with
  `help_requested --reason permission`.

An agent **may not**, without an explicit operator decision:

- merge the revert, or mark the draft ready in a way that admits it to an
  autonomous-merge path;
- push a revert directly to `BASE`;
- force-push or rewrite `BASE` history to remove the merge; or
- widen the revert scope past the closure the operator approved; or
- emit any **checkpoint B** event or terminal closeout, which asserts a merged
  repair the operator has not authorized.

## Checklist

1. Record `REPO`, `BASE`, `BASE_TIP` (fetch first; it is the only base ref scope
   analysis reads), the suspect PR and its landing commit,
   **the repo's merge style (merge / squash / rebase)**, `batch_id`, lane,
   dependency plan path/id, and the observed failure. Unverifiable facts stay
   `UNKNOWN`.
2. Enumerate landed commits on the first-parent line **without `--merges`**,
   and classify each one's parent shape.
3. Recover each in-scope PR's **complete landed commit list**, newest first —
   exactly one commit for a merge *or a squash*, `N` first-parent commits for a
   rebase — matching on subject and patch-id, never SHA. Build it with
   `git log --first-parent -n N`, never with an `A..B` range, and **select on
   `MERGE_STYLE` with a `case`** — two unconditional assignments both run and
   the rebase one wins. Read the list before using it. An unverifiable list is
   `UNKNOWN`: widen or stop.
4. Build `PATHS` from the landed range's `--name-only -z` output into a bash
   array, and expand it only as `"${PATHS[@]}"`. Run the `--follow` and
   `--find-renames` cross-check before recording any disjointness result.
5. Compute the revert closure from the batch manifest, dependency-plan edges of
   **every** type, and
   git, comparing whole ranges. Map every in-scope commit to a PR: a confirmed
   direct commit is a closure unit of one, and a failed lookup is `UNKNOWN`.
   Fail closed to the wider scope on any `UNKNOWN`.
   Fix `PRE_BATCH_SHA` as `${OLDEST_IN_SCOPE_SHA}^1`.
6. Decide revert versus forward fix, and write down why.
7. Re-fetch and confirm `origin/${BASE}` still matches `BASE_TIP`; rerun scope
   recovery if it moved. Derive and validate the slug branch name with
   `git check-ref-format --branch` — but do not create the branch yet. Run the
   bounded status check, then claim the repair lane under its own
   `REPAIR_BATCH_ID` / `REPAIR_LANE` / `REPAIR_TARGET`, where `REPAIR_TARGET` is
   the audit child issue and never the suspect PR. Stop on `CLAIM_REFUSED`
   without creating anything. Only once the claim holds, create the branch from
   `${BASE_TIP}`; never work on `BASE`.
8. If you turn on `rerere` for the closure, capture `RERERE_PRIOR` first and
   restore it on **every** exit path — merged repair included, not only
   abandonment.
9. Revert **every commit in every in-scope list**, newest first, by handing the
   whole list to one `git revert` invocation (`-m 1` on a merge commit, alone).
   On conflict: resolve and `--continue`, or `--abort` and re-scope — never
   `--skip`, and never leave a partial sequence. Abandoning a multi-PR closure
   also needs `git checkout -B "${REVERT_BRANCH}" "${BASE_TIP}"`, because
   `--abort` only cancels the invocation it is run from.
10. Classify every conflicting hunk as dependent or independent; stop and
    re-scope if an independent hunk cannot be preserved.
11. Validate the branch, and diff the final tree against `PRE_BATCH_SHA`.
12. Settle the changelog correction — delete an `[Unreleased]` entry, or add a
    correcting entry when the original shipped — and apply it through whoever
    the repo's changelog-ownership policy allows. Under a restrictive policy
    (this repo) the revert PR leaves `CHANGELOG.md` untouched, records
    `deferred_to_update_changelog`, states the exact correction in its body, and
    hands it to an `$update-changelog` lane.
13. Rerun the merge ledger, or record `merge_ledger: UNKNOWN` when the seam is
    `n/a`.
14. **Checkpoint A** — record the `error` event and `help_requested --reason
    permission`. Open the revert PR as a draft and escalate to the operator for
    the merge decision. Record nothing here that claims a repair landed.
15. **Checkpoint B, only after a repair PR actually merges** — the revert *or* a
    forward fix, whichever the operator took — record `human_intervention --kind
    manual-fix` naming that PR; close a non-terminal original lane `superseded`
    or `abandoned`; release the repair lane claimed in step 7 as `done` under
    `REPAIR_BATCH_ID` / `REPAIR_LANE`; restore `RERERE_PRIOR`; reclassify the
    worked issue as `regressed`. Build the release arguments conditionally so
    `--evidence-url` is present only when `EVIDENCE_URL` is set. If no repair
    lands at all, skip checkpoint B but still close **both** lanes terminally
    (omitting `--evidence-url` when no durable URL exists), close the draft
    revert PR, restore `RERERE_PRIOR`, reclassify the worked issue `regressed`,
    and record the accepted-risk decision and its operator in the durable
    handoff.
