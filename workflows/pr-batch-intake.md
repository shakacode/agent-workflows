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

## Plan To Goal Handoff

If the user is using `/plan`, or asks to prepare a Codex goal, stop after producing the approved plan and exact Codex goal text. Do not begin implementation just because the plan was approved unless the user explicitly says to launch now.

Keep this goal prompt aligned with `.agents/skills/pr-batch/SKILL.md`. The
human-readable work request lives in exactly one accepted canonical issue or
pull-request body, or one trusted maintainer comment. A later trusted maintainer
comment may define or override the issue or pull-request body; select that exact
comment URL for the new run. A preflight-accepted trusted ad-hoc override with
no GitHub surface uses its existing `plan-state://` or `batch://` durable
authorization reference. Do not synthesize a restatement. `Fix issue #123 using $pr-batch with merge authority
ask.` is a valid one-line shortcut when repository context resolves the target
unambiguously.

Identify the candidate work-item source before the security preflight, then bind
selection to the preflight's exact fetched snapshot. For every GitHub target
lane, accept the source only when the successful preflight output contains the
same source URL, `body` field, and SHA-256 digest that the launcher records as
`Prompt digest at selection`; a missing or different snapshot stops selection
and reruns preflight instead of trusting a later fetch. For a
preflight-accepted non-GitHub override, follow the narrow durable-reference
exception in the Launcher Run Record. Before prompt creation, generate and
persist one immutable unique per-execution `run_id` and one exact canonical
`record_destination` in the Batch Plan. Freeze the exact delivered plan, then
persist `batch_plan_binding` beside it in the run record and handoff envelope;
do not put the digest inside the bytes it hashes. The binding is the SHA-256 of
the exact UTF-8 Batch Plan bytes delivered inline, or an existing immutable
reference plus its exact revision/content digest. A mutable, missing, changed,
or `UNKNOWN` binding stops. Choose a destination
authorized to contain every lane's recorded identity and source. An all-public
GitHub run may use one selected issue or pull-request work-item URL, with a
trusted maintainer-comment source anchored to its parent work item. If any lane
has no public GitHub surface, use an existing durable plan/backend destination
authorized for every lane or split the trust boundaries into separate runs;
never publish a private durable reference in a public run record. Render the
minimal coordinator prompt and directly record `Prompt created at` once for the
run. Immediately before each target dispatch, re-fetch that lane's source,
compare its launch digest with its selection digest, and directly append the
lane's `Launched at` timestamp and launch digest. A mismatch stops only that
dispatch until the changed source is deliberately reselected as a new run and
the security preflight is rerun. Use the existing handoff envelope outside the
frozen Batch Plan to give each worker the exact `record_destination`, `run_id`,
`batch_plan_binding`, lane launch digest, and existing immutable replay identity
(`lane_id`, dispatcher, `instance_id`, and launch token). Bind that envelope to
the same `run_id`, `batch_plan_binding`, and replay identity; do not add the
launch digest to the frozen plan or change its binding. Before a worker
interprets the source, it reverifies the plan binding, resolves the
exactly matching `run_id` and replay identity, and re-fetches
the exact bytes, and verifies its observed digest against that lane's launch
digest; a replay-identity or digest mismatch stops work and records the changed
evidence. The worker returns its bound start observation to the coordinator;
the coordinator is the sole run-record writer and serializes or compare-and-
swaps the append to the matching run after every check. Workers never perform
concurrent GitHub read-modify-write updates. Do not wait for a telemetry
aggregator; these are cheap launcher and worker measurements and do not depend
on telemetry aggregation work.

Host budget changes the number of items in a batch, not prompt language: use
the same readable prompt vocabulary for every host and split oversized batches
into smaller launches. Keep file-touch evidence, workflow-contract details,
Lane Cards, dispatch data, coordination diagnostics, and other derived state in
the Batch Plan, manifest, or coordination backend outside the human-authored
prompt. The durable records continue to separate preferred model/effort from
observed host/model/effort. Do not ask a maintainer to author those fields.
The durable manifest uses this exact machine grammar:
`Manifest:pack_sha=<rev|UNKNOWN>;coordinator_preference=<model>/<effort>;lanes=<lane-id:dispatcher+preferred-route+observed-host/model/effort>,...;UNKNOWN=field;no guesses`
The durable plan, not the prompt, still emits one exact `target` v1 object per
lane.

The fenced prompt is not standalone coordinator state. For `copy-paste` and
`host-native-user-task`, deliver it together with the complete Batch Plan for
that coordinator group or an exact durable plan-state reference, plus the exact
`batch_plan_binding` described above. The new coordinator must reverify that
binding before preflight, every dispatch, and worker start. Do not report a
launch as successful until both pieces are delivered, immutable, and
reverified. A multi-target group
depends on the plan or reference to preserve every target, lane, dependency,
and ownership assignment while the prompt remains readable.

For a multi-target launch, keep `Work item` singular and set it to the durable
coordination anchor and record destination for this batch. The accompanying
Batch Plan, whether delivered inline or by exact durable reference, is
authoritative for scope and enumerates every target with its exact source and
provenance. Before prompt creation, retain the exact accepted plan and its
`batch_plan_binding` in machine launch state. Replace the normal `Instruction`
line with this exact line:

> Instruction: Use PR-batch to execute every target in the accompanying Batch Plan against the repository's configured base branch; Work item identifies this batch's durable coordination anchor, not its sole target.

Do not enumerate every target URL in the human prompt or add another prompt
field. Keep each target URL and its provenance in the Batch Plan. Single-target
launches use the normal prompt unchanged.

Use this normal human prompt shape. `Human available after` is optional; omit
that line when the maintainer did not supply a time. For Codex, prepend only
`/goal`; other hosts use the same readable prompt vocabulary unchanged. <!-- host-allow: codex-only -->

```text
Repository: OWNER/REPO
Work item: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>
Task name: <repository, work item, and purpose>
Instruction: Use PR-batch to complete this work item against the repository's configured base branch.
Merge authority: <auto|ask>
Human available after: <optional time; omit this line when not supplied>
```

## Launcher Run Record

The launcher, not the maintainer, writes launch provenance and execution state.
Before prompt creation, generate and persist one immutable unique per-execution
`run_id` and one exact canonical `record_destination` in the Batch Plan. Freeze
the exact delivered plan, then persist `batch_plan_binding` beside it in the run
record and handoff envelope; do not put the digest inside the bytes it hashes.
Compute the binding as the SHA-256 of the exact UTF-8 Batch Plan bytes delivered
inline, or use an existing immutable reference plus its exact revision/content
digest. Reverify it before every
dispatch and worker start. Choose a destination authorized to contain every
lane's recorded identity and source. An all-public GitHub run may select one
issue or pull-request work-item URL, with a maintainer-comment source anchored
to its parent work item. When any lane has no public GitHub surface, use an
existing durable plan/backend destination authorized for all lanes or split the
trust boundaries into separate runs. Never put a private `plan-state://` or
`batch://` identity in a public run record. Do not add these fields to the
human-authored prompt.

Each execution appends one compact visible state plus one collapsed `<details>`
record at that exact destination. The narrow non-GitHub trusted-ad-hoc exception
uses the same compact/history record in its existing durable state; do not
create another storage or record schema. The launcher/coordinator is the sole
writer for that record. Serialize or compare-and-swap every update; workers
return bound observation payloads and never race GitHub read-modify-write
updates. That record has one entry for every planned target lane. Bind
each lane entry to the existing immutable replay identity: `lane_id`,
dispatcher, `instance_id`, and launch token. Within a lane entry, write
selection provenance first, then append launch provenance, then append worker
observations without replacing earlier values.
Reruns append a new collapsed record instead of replacing or folding earlier
runs into the newest values. The per-execution `run_id`, not the deterministic
launch token, distinguishes those records. Later workflow observations are
timestamped append-only entries on the run that observed them.

For every GitHub target lane, select exactly one accepted canonical issue or
pull-request body, or one trusted maintainer comment. Bind that selection to the
successful `pr-security-preflight` snapshot with the exact source URL, `body`
field, and SHA-256 digest; do not accept a source digest produced only by a
later fetch. A direct accepted PR
target therefore uses its exact PR URL without requiring a synthetic comment.
The same trusted comment may define multiple lanes, but its URL and digest
sequence are still recorded separately in every affected lane entry. Fetch the
canonical source bytes when selected and write `Selected at` plus `Prompt
digest at selection`. Immediately before that target's dispatch, re-fetch those
bytes and append `Launched at` plus `Prompt digest at launch`. If the selection
and launch digests differ, stop that dispatch until the changed source is
deliberately selected as a new run and security preflight is rerun. Use the
existing handoff envelope outside the frozen Batch Plan to give the exact
`record_destination`, `run_id`, `batch_plan_binding`, lane-keyed launch digest,
and replay identity to its worker. Bind that envelope to the same `run_id`,
`batch_plan_binding`, and replay identity; do not add the launch digest to the
frozen plan or change its binding. The worker reverifies `batch_plan_binding`,
resolves the exactly matching
`run_id` and replay identity, re-fetches the exact source, and verifies both the
replay identity and observed digest before it interprets the source or returns
its `Worker started at` observation to the sole coordinator writer; a mismatch
stops work and is recorded. A
later trusted maintainer comment may become the source for a later run, but a
lane entry never combines the selected target body and comment or synthesizes a
new source.

Canonical source bytes are the exact GitHub API `body` string for the selected
issue, pull request, or comment after JSON decoding, encoded as UTF-8 without
Unicode normalization, Markdown rendering, whitespace trimming, or newline
insertion or removal. Selection, launch, and worker checks fetch the same object
and field by stable URL or object identifier and hash only those bytes.
When GitHub returns `body: null` for a title-only issue or pull request, treat
its canonical source bytes as the empty UTF-8 string. Retain that SHA-256 digest
in the selection, launch, and worker fields just like a nonempty body; do not
drop the source because its body is null.

A trusted ad-hoc override whose durable authorization reference is `issue://`
or GitHub HTTPS follows the ordinary GitHub source path: resolve the referenced
issue or pull-request body as the prompt source, preserve the same author and
trust checks, and record actual selection, launch, and worker-observed body
digests instead of `not applicable — trusted-ad-hoc-override`.

The narrow non-GitHub exception is a preflight-accepted
`trusted-ad-hoc-override` backed by an existing `plan-state://` or `batch://`
durable authorization reference. Record that exact reference as `Prompt
source`; do not invent another snapshot, byte encoding, or record schema. The
existing override contract exposes provenance and authority evidence, not
canonical source bytes, so record each source-digest field as exact `not
applicable — trusted-ad-hoc-override`. The existing durable backend reference
must resolve to the same immutable accepted provenance/authority record
revision, or an equivalent existing content binding, at selection, launch, and
worker start. A missing, mutable, changed, or `UNKNOWN` binding or other
override evidence stops at that boundary.

```markdown
<details>
<summary>Run details</summary>

- Run ID: <immutable unique per-execution run_id>
- Record destination: <exact issue or pull-request work-item URL authorized for every lane, or existing durable plan/backend destination authorized for every lane>
- Batch Plan binding: <SHA-256 of exact delivered UTF-8 plan bytes, or immutable reference plus exact revision/content digest>
- Prompt created at: <timestamp>
- Model at prompt creation: <observed value or UNKNOWN>
- Workflow at prompt creation: <version or UNKNOWN>
- Later workflow observations: <timestamped append-only entries or none>
- Target lanes:
  - Lane: <lane id; repeat this entry once per planned target>
    - Target: <exact issue, pull-request, or durable override identity>
    - Replay identity: <existing lane_id, dispatcher, instance_id, and launch token>
    - Prompt source: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>
    - Selected at: <timestamp>
    - Prompt digest at selection: <SHA-256 of the canonical source bytes fetched when selected; or not applicable — trusted-ad-hoc-override>
    - Launched at: <timestamp or pending>
    - Prompt digest at launch: <SHA-256 of the canonical source bytes re-fetched at launch or pending; or not applicable — trusted-ad-hoc-override>
    - Worker started at: <timestamp or pending>
    - Prompt digest observed by worker: <SHA-256 of the canonical source bytes re-fetched by the worker or pending; or not applicable — trusted-ad-hoc-override>
    - Model observed by worker: <observed value or UNKNOWN>
    - Workflow observed at worker start: <version or UNKNOWN>
</details>
```

Record each observation field by field from the launcher or worker that
actually exposes it. Never infer a missing model or workflow version; use exact
`UNKNOWN`, which does not block launch. For GitHub sources, source digests are
integrity fields, not optional telemetry: a missing or mismatched required
digest stops dispatch or worker execution at its boundary. The coordinator
directly appends the cheap lane launch timestamp and digest when dispatch
begins, then serializes or compare-and-swaps the worker-start timestamp and
observations returned for the exactly matching `run_id`, replay identity, and
`batch_plan_binding` at the persisted `record_destination` after the worker
digest matches. Until an event
occurs, its template value remains `pending`; never infer it from telemetry.
Do not wait for a telemetry aggregator.

Human `auto` maps to machine `auto_merge_when_gates_pass`; `ask` maps to machine
`ask`. An explicitly selected machine `merge_authority: none` renders as human
`Merge authority: ask` because the worker has no merge authority and must obtain
explicit human authority before merge. This rendering does not change the
durable machine value from `none` to `ask`. Preserve machine-only
`merge_authority: none` outside the normal human prompt for workflows that
intentionally grant no merge authority.

Use `HST-v1` from the canonical [Human-Status Translation Contract](pr-processing.md#human-status-translation-contract)
for every recurring wake or workflow-owned heartbeat.

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
- any still-missing prompt facts, written as `UNKNOWN`, plus the precise
  planning/reconciliation action required.

Only a record with a canonical target and complete launch authority is eligible
for downstream mutation. Consumers may add dependency, execution, validation,
or closeout facts, but must not reinterpret the intake record.
