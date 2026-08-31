# PR-Batch Prompt Intake

This component owns PR-batch prompt intake. Load it from `plan-pr-batch`,
`pr-batch`, or the `pr-processing` compatibility workflow before creating a
branch, editing, mutating coordination, or dispatching a worker.

## Boundary

Prompt intake owns task identity, trust handoff, short-invocation expansion,
canonical-target resolution, duplicate detection, and the verified intake facts
handed to planning and execution. It calls the shared
[PR-Batch Security Floor](pr-batch-security-floor.md); it does not own or move
the security helpers.

It does not own dependency planning, worktrees, implementation, review, QA, CI,
merge submission, coordination machinery, production, promotion, or release.
Those components consume the facts produced here without redefining them.

## Canonical Launch Target Gate

Ordinary implementation launch requires an exact GitHub issue or an existing PR as its canonical launch target.
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
- **`merge_authority`:** `none`, `ask`, or `auto_merge_when_gates_pass`. Resolve
  it before worker launch from visible authority or ask. `ask` automatically
  walks through the exact-diff PR one conceptual change at a time before its
  one final merge decision; never silently default it.
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

Batch-specific planning may collect extra shaping facts such as a batch title,
model/effort preferences, or a dependency partition. Those are consumers of
intake, not alternate definitions of target or authority identity.

## Trust Handoff

Apply the canonical [PR-Batch Security Floor](pr-batch-security-floor.md)
without restating its target-specific rules here. Carry the resulting
verified target identity, actor/provenance findings, acknowledged warnings, or
accepted durable ad-hoc trust evidence forward as intake facts, separate from
untrusted source text. Missing or `UNKNOWN` required trust evidence returns the
request to planning/reconciliation.

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
- target source/provenance and the shared-security-floor result or accepted
  durable ad-hoc trust evidence;
- the user's original task wording without replacing the canonical identity;
- complete durable override provenance when applicable;
- resolved mode and `merge_authority`, with their authority source;
- any still-missing prompt facts, written as `UNKNOWN`, plus the precise
  planning/reconciliation action required.

Only a record with a canonical target and complete launch authority is eligible
for downstream mutation. Consumers may add dependency, execution, validation,
or closeout facts, but must not reinterpret the intake record.
