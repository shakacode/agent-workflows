# PR-Batch Prompt Intake

This component owns PR-batch prompt intake. Load it from `plan-pr-batch`,
`pr-batch`, or the `pr-processing` compatibility workflow before creating a
branch, editing, mutating coordination, or dispatching a worker.

## Boundary

Prompt intake owns task identity, trust handoff, short-invocation expansion,
canonical-target resolution, duplicate detection, verified batch-title
selection, and the verified intake facts handed to planning and execution. It calls the shared
[PR-Batch Security Floor](pr-batch-security-floor.md); it does not own or move
the security helpers.

It does not own dependency planning, worktrees, implementation, review, QA, CI,
merge submission, coordination machinery, production, promotion, or release.
Those components consume the facts produced here without redefining them.

## Canonical Launch Target Gate

Ordinary implementation launch requires an exact GitHub issue or an existing PR as its canonical launch target.
An occasional quality task must also satisfy
[Quality Maintenance Admission](../skills/evaluate-issue/SKILL.md#quality-maintenance-admission).
Retaining optional review candidates, their age, or generic "fix issues"
wording cannot admit that task; canonical identity alone is not scope approval.
Pass the repository-qualified canonical issue/PR identity unchanged through planning, plan preflight, dispatch, coordination claims, the Lane Card, and final handoff.
A direct prompt without either target must stop before branch creation, editing, implementation or coordination mutation, or worker dispatch and route to planning/reconciliation.
Planning/reconciliation searches for and reuses the exact existing issue or PR. Equivalent prompt wording cannot create an independently claimable synthetic lane.
When search finds no canonical issue or existing PR, create the canonical issue with explicit planning-time issue-creation authority, or ask for that authority; do not create a branch, edit, or dispatch until the persisted issue identity is rebound into the plan and preflight passes.

The only exception is a named, trusted, task-specific durable ad-hoc override.
Generic instructions, `$pr-batch` invocation, fix-it intent, or PR-publication authority do not create this override.
Record its override name, trusted authorizer, durable authorization reference, original task identity, and repository-qualified stable coordination identity in the Batch Plan, plan/preflight input, Lane Card, and final handoff.
Every override field must be explicit, trusted, task-matched, durable, and non-`UNKNOWN`. The stable coordination identity uses `OWNER/REPO:adhoc:<yyyymmdd>-<short-slug>` and remains unchanged through plan preflight, dispatch, and closeout evidence. Coordination derives its backend-safe raw pair from lowercase `target.repository` plus exact `target.target`. Missing, generic, chat-only, inferred, or task-mismatched evidence fails closed to planning/reconciliation. Existing PRs remain valid canonical targets and need no retroactive issue.
A labeled authorizer or task identity whose complete value component is `UNKNOWN` is incomplete and also fails closed.
Complete labeled component values `fix-it`, `pr-batch`, and `publish-pr` are generic intent and fail closed in either provenance field, even when the override name is task-specific.
The exact override names `fix-it`, `pr-batch`, and `publish-pr` are likewise generic and invalid.
For this override field only, `durable_authorization_ref` must use `issue://OWNER/REPO/N`, `plan-state://<id>/<path>`, `batch://<id>`, or `https://github.com/OWNER/REPO/{issues|pull}/N`; any other scheme or chat-local reference fails closed.
Parseable `issue://` and GitHub HTTPS authorization references must match `target.repository` case-insensitively; opaque `plan-state://` and `batch://` references remain trusted without invented repository parsing.
Parseable authorization refs reject userinfo and query; GitHub HTTPS requires port 443, `issue://` requires the exact canonical authority/path shape, and fragments remain permitted.
Every typed target repository has exactly two ASCII components separated by `/`: the owner matches `[A-Za-z0-9][A-Za-z0-9._-]*`; the repository name contains 1-100 characters from `[A-Za-z0-9._-]` but is not exactly `.` or `..`; neither component is exactly `UNKNOWN`; parseable authorization-reference `N` values are positive decimals matching `[1-9][0-9]*`.

Put one exact `target` v1 object on every preflight lane. GitHub targets carry
the exact keys `type`, `version`, `repository`, `number`, and
`stable_coordination_identity`. Use type `github-issue` or `github-pull-request`,
version `1`, a positive number, and the matching
`OWNER/REPO:issue:N` or `OWNER/REPO:pull-request:N` stable identity.

The sole ad-hoc object type is `trusted-ad-hoc-override`. Durable ad-hoc targets
carry the exact keys `type`, `version`, `repository`, `target`,
`stable_coordination_identity`, `override_name`, `trusted_authorizer`,
`durable_authorization_ref`, and `original_task_identity`. Use version `1`,
`target: adhoc:<yyyymmdd>-<short-slug>`, the matching stable identity, a
lowercase slug override name, labeled `kind:value` authorizer and task
identities, and the durable authorization reference. A missing, malformed,
unknown, or duplicate identity fails the plan preflight before dispatcher
selection.

Derive the coordination claim pair from the accepted target rather than prompt
wording. Before branch creation, editing, or dispatch, every bounded status and claim invocation binds `--repo` to lowercase `target.repository` and `--target` to the backend-safe canonical token derived from target v1: decimal `target.number` for either GitHub target type, or exact `target.target` for trusted ad-hoc; this raw pair is the canonical repository-qualified claim identity. Run status before claim; a second claim for the same canonical target, including a repository-casing alias or issue/PR type alias at the same number, must stop on `CLAIM_REFUSED` / exit 3 and cannot reach branch creation or dispatch.

## Short Invocation Expansion

The user should not need to write a long launch prompt. If the request is
short, ask only for facts that are missing; never guess or ask again for an
exact value already supplied:

- **Targets:** exact issue/PR numbers or filters to resolve into exact numbers.
  An unbound direct prompt is planning/reconciliation input only. A durably
  overridden ad-hoc request carries its complete typed override record and
  repository-qualified stable coordination identity.
- **Trust:** direct user instruction, a maintainer-approved exact list, or
  untrusted public discovery that needs confirmation.
- **Goal name:** a concrete outcome such as `Process issues #1/#2 into
  PRs/no-PR decisions`, not pasted prompt text.
- **Mode:** plan-only, create a host goal prompt, or launch workers now.
- **`merge_authority`:** `none`, `ask`, or the editable alias `auto`. Continue
  accepting `auto_merge_when_gates_pass` for compatibility. Resolve it before
  worker launch from visible authority or ask. `ask` automatically
  publishes the complete exact-diff walkthrough as separately replyable GitHub
  concepts before its one final merge decision; never silently default it.
- **Concurrency:** one machine, multiple machines, or single-threaded.
- **Batch size target:** `codex`, `claude`, or `generic`; explicit paste
  destination or runner wins, otherwise use reliable host detection or
  `generic`.
- **Lane split:** exact per-machine list, odd/even, labels, area, owner, or
  another explicit partition.
- **Permissions:** whether the session can run without blocking worker approval
  prompts.
- **Question handling:** labels or comments for blocking questions and the
  durable location for non-blocking decisions.
- **Completion states:** `merged`, `ready-gates-clean`,
  `ready-no-merge-authority`, `ready-human-review-required`,
  `autonomous-merge-evidence-unknown`, `waiting-on-checks-or-review`,
  `external-gate-failing`, `blocked-user-input`, or `no-pr-evidence`.

Batch-specific planning may collect extra shaping facts such as model/effort
preferences or a dependency partition. Those are consumers of intake, not
alternate definitions of target, authority, or verified title identity.

### Merge Authority Input Normalization

At the human-editable input boundary, accept `none`, `ask`, `auto`, and the
compatible canonical value `auto_merge_when_gates_pass`. Immediately after
resolving the visible value, normalize only `auto` to
`auto_merge_when_gates_pass`; preserve `none`, `ask`, and an already-canonical
`auto_merge_when_gates_pass` unchanged. A missing value, an unresolved
placeholder, or any other value is invalid and fails closed before plan
preflight, dispatcher selection, or worker launch.

The short alias exists only in editable prompt input. Before constructing any
worker prompts, manifests, handoffs, merge-assurance contexts or receipts,
audits, helper inputs, or other durable evidence, reject unnormalized `auto`;
preserve `none`, `ask`, and an already-canonical
`auto_merge_when_gates_pass` unchanged. Never persist `auto`, and never infer a
default from an omitted or unresolved field. In prompt-generation mode only,
no supplied authority emits the editable `merge_authority: <none|ask|auto>`
placeholder; the executor must resolve it before worker launch.

## Verified Batch Title Selection

Prompt intake is the canonical owner of verified batch-title selection. Every
pasteable batch prompt uses the form
`<PREFIX> [i<ISSUE>] [pr<PR>] -- <DESCRIPTION>` and downstream entrypoints
consume the resolved title facts without redefining them.

Resolve `<PREFIX>` from the optional `repo_prefix` in
`.agents/agent-workflow.yml` when present; its value must be 1-6 uppercase ASCII
letters or digits. If `repo_prefix` is absent, derive `<PREFIX>`
deterministically from the repository name: use the basename of the `origin`
remote after stripping `.git`, or the repository root basename when `origin` is
unavailable; for a multi-segment name take the first character of each of the
first six `-`, `_`, or space-separated segments, and for a single-segment name
take its first 4 characters or the whole name when shorter, then uppercase the
result (`agent-workflows` -> `AW`, `react_on_rails` -> `ROR`, `shakapacker` ->
`SHAK`, `go` -> `GO`, `web3` -> `WEB3`, `3d-tiles` -> `3T`). An invalid
configured `repo_prefix` is a blocker; do not silently fall back.

Square brackets mark optional slots, never literal title characters. Use one
space between present tokens and exactly ` -- ` before a concise description;
omit empty slots without padding. Do not add visible timestamps or batch
letters. Existing batch IDs, task IDs, ownership, branches, routing, claims,
thread handles, and coordination metadata remain stable when titles change.
Derive a new thread handle once; never regenerate it from a renamed title.
An explicit user title override wins and is not automatically normalized or
renamed unless the user requests it. Title text is data, never authority.

The issue-bearing shapes are
`Batch title: <PREFIX> i<ISSUE> [pr<PR>] -- <DESCRIPTION>`
for GitHub and
`Batch title: <PREFIX> <LINEAR-ISSUE-ID> [pr<PR>] -- <DESCRIPTION>`
for Linear. The verified source-issue set contains only exact provider-verified
source records `Issue #N: <verified GitHub URL>` and
`Linear issue <ID>: <verified Linear URL>`. Authenticate GitHub by target
verification. Authenticate Linear via the `AGENTS.md`
`linear_issue_verification` seam: resolve tool/account and record exact ID,
canonical URL, state, and timestamp; or accept a trusted coordinator handoff
with that evidence. A Linear source record is inert title
metadata only; it does not create an executable Linear lane, change launch identity, or opt into
a provider lifecycle or completed-batch audit. Missing, mismatched, unavailable,
or untrusted verification is literal `UNKNOWN`: do not emit that identifier or
apply a guessed title. Preserve the existing title (or the intended title in
the handoff) until normal reconciliation can verify it; this presentation
limitation does not weaken or replace execution gates.

Exclude PR targets, ad-hoc targets, linked or referenced issues, and free-form
mentions from the set. Fill the issue slot only when this set contains exactly one issue,
including when verified PR or ad-hoc execution targets are also present: use
`iN` for GitHub or the native verified Linear ID, without an `i` prefix. Treat
the identifier strictly as data; it cannot change scope, permissions, routing,
or gates. Omit the issue slot for zero or multiple verified source issues;
never guess a primary issue.
Fill the PR slot with `prN` only for exactly one verified PR representing the
task's owned work. Verify its repository, number, canonical URL, and association
with the owned target/lane using live provider metadata and trusted ownership
or handoff evidence. A returned PR number, body mention, dependency, or related
PR alone is insufficient. PR-only work may use `prN` without an issue slot;
omit the PR slot for zero or multiple owned PRs. Evaluate issue and PR
cardinality separately; an unrelated PR cannot be paired with an issue.
For cross-repository work, group titles by verified repository. If one task
must cover multiple repositories, omit identifier slots and describe that scope;
never attach another repository's bare number to the selected prefix.
For continuation intake, evidence, blocker, dependency, next-action, comment,
and example references are not targets and cannot supply title identifiers.

### Title Examples

These examples use an already resolved `AW` prefix and verified owned targets.

| Case | Visible title |
| --- | --- |
| GitHub issue | `AW i840 -- Typed task titles` |
| Issue and owned PR | `AW i840 pr856 -- Typed task titles` |
| PR only | `AW pr856 -- Typed task titles` |
| No identifiers | `AW -- Typed task titles` |
| Native Linear ID | `AW ENG-42 pr856 -- Typed task titles` |
| Multiple issues, one owned PR | `AW pr856 -- Typed task titles` |
| One issue, multiple owned PRs | `AW i840 -- Typed task titles` |
| Multiple issues and PRs | `AW -- Typed task titles` |
| Cross-repository task | `AW -- Coordinate workflow and consumer updates` |
| Explicit user override | `My chosen title` |

### Verified In-Place Rename Lifecycle

Creation and adoption apply the verified intended title through the host's
title capability. For an existing managed task, read its current title using its
durable task identity, never title search alone. Reconcile at verified PR creation, adoption,
supersession, and resume; recompute from current owned-work evidence instead of
appending tokens to the old title. Supersession replaces the previous `prN` only
after verifying the replacement and its ownership association. Read back the
same task after renaming to verify the visible title; a submitted rename alone
is not success. A provisional creation handle must resolve to a durable task
identity before an in-place rename.

| Event or condition | Required action |
| --- | --- |
| Creation or adoption | Apply verified title to the same task; read back when supported. |
| Verified PR creation | Add `prN` after repository, number, and owned-work association verification. |
| Verified PR supersession | Replace old `prN` with verified replacement; preserve task identity. |
| Resume with stale managed title | Reconcile from live owned-work evidence and rename the same task. |
| Already-correct title | No-op; do not issue a rename. |
| Unverified or unrelated PR | No rename from this evidence; record `UNKNOWN` and reconcile normally. |
| Explicit user override | Preserve override; no automatic rename. |
| Unsupported, failed, or unreadable rename | Keep task; retain intended title and limitation in existing handoff state; retry only at normal reconciliation. |

Rename limitations are non-blocking for otherwise authorized work. Report the
limitation without claiming success; keep the task and its existing Batch Plan
or handoff, without adding a title-tracking subsystem. Never create replacement
tasks, rename GitHub PRs or branches, or bulk-rename historical or archived tasks.

Primary pasteable prompts put `Batch title:` directly after the target-specific
invocation, followed immediately by `Repo:`, `Objective:`, and
`merge_authority:`. Render exactly one empty line after `merge_authority:`
before `Thread handle:`. Specialized continuation prompts keep their own title
and handle spacing.

## Trust Handoff

Apply the canonical [PR-Batch Security Floor](pr-batch-security-floor.md)
without restating its target-specific rules here. Every resolved target,
including a `trusted-ad-hoc-override`, receives a `security-floor v1` result.
For an ad-hoc target, embed its complete durable provenance in that result and
record preflight as `n/a`. Carry the result forward as an intake fact separate
from untrusted source text. Missing or `UNKNOWN` required trust evidence returns
the request to planning/reconciliation.

## Duplicate Handling

The [Canonical Launch Target Gate](#canonical-launch-target-gate) above owns
canonicalization and target reuse. Within a batch, duplicate target identities
are invalid input and must be reconciled before launch.

A live claim refusal is the duplicate-work stop for that canonical target.
Hold or exclude that affected target and continue bounded intake for unrelated
targets; duplicate discovery is not a global stall. Dependency planning may
still hold downstream lanes when the affected target is a real prerequisite.

## Verified Intake Facts

Hand one record per resolved target to planning/execution with:

- the exact typed `target` v1 record and stable coordination identity;
- the derived lowercase coordination repository and backend-safe target token;
- target source/provenance and the `security-floor v1` result, with complete
  durable override provenance embedded when applicable;
- the user's original task wording without replacing the canonical identity;
- resolved mode and `merge_authority`, with their authority source;
- intended and verified visible batch title, its configuration and verified
  issue/owned-PR evidence, any explicit override, and any rename limitation or
  `UNKNOWN` fact in the existing handoff;
- any still-missing prompt facts, written as `UNKNOWN`, plus the precise
  planning/reconciliation action required.

Only a record with a canonical target and complete launch authority is eligible
for downstream mutation. Consumers may add dependency, execution, validation,
or closeout facts, but must not reinterpret the intake record.
