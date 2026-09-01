# GitHub Task Prompts And Run Records

GitHub is the durable link between a human-readable prompt source, the agent task
that executes it, and any pull request it produces. The `agent-run-record` v1
contract keeps that link compact without copying the workflow into every
prompt or making coordination a prerequisite.

This document applies the human-prompt decisions from issue #476 to the run
record and launch metadata. Changing prompt wording does not change the v1
identity, digest, lifecycle, or history rules below.

## One-line launch

The canonical shortcut is `Fix issue #123 using $pr-batch with merge authority ask.`
when the active repository makes the issue identity unambiguous. The issue-scoped
phrase `Use PR-batch to fix this issue` remains a compatibility alias, not a
second canonical prompt. The launcher then:

1. applies the existing target and security preflights;
2. derives the repository and exact issue or pull request from the active GitHub target;
3. reads only the work-item fields it uses;
4. records the configured base branch and the already-fetched `origin/<base>`
   commit as the configured base at launch when available;
5. derives a deterministic task title from the repository prefix, work-item
   number, and title;
6. binds the selected source to the successful `pr-security-preflight` snapshot's
   exact source URL, `body` field, and SHA-256 digest, and accepts the launcher's
   actual source-selection and human-prompt-rendering timestamps;
7. re-fetches the same source during preparation, requires its digest to match
   the supplied selection digest, and only then captures the record observation
   time and persists launch identity;
8. immediately before dispatch, re-fetches those bytes, verifies a distinct
   launch digest, and puts that digest in the existing handoff envelope outside
   the frozen Batch Plan without changing the plan or its binding; and
9. lets the worker re-fetch and match the transported launch digest before it
   interprets the source or records worker start.

The user does not supply file-touch maps, coordination diagnostics, workflow
restatements, generated identifiers, digests, or timestamps. Missing observed
metadata stays field-granular `UNKNOWN`; it does not stall ordinary work unless
another workflow gate independently requires that fact.

## Canonical human prompt

The launcher derives this prompt from the selected work item. `Human available
after` is optional and is omitted when the maintainer did not supply a time.
Generated launcher metadata, lifecycle state, coordination, manifests, and
merge-policy bookkeeping stay outside these human-authored fields.

```text
Repository: OWNER/REPO
Work item: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>
Task name: <repository, work item, and purpose>
Instruction: Use PR-batch to complete this work item against the repository's configured base branch.
Merge authority: <auto|ask>
Human available after: <optional time; omit this line when not supplied>
```

## Prompt sources and trust

Each GitHub-backed lane handled by `agent-run-record` v1 has exactly one prompt
source:

- `issue-body`: the canonical body bytes returned for the selected issue;
- `pull-request-body`: the canonical body bytes returned for the selected pull
  request at its exact PR URL, without a synthetic comment; or
- `maintainer-comment`: the canonical body bytes of one trusted maintainer
  comment on the selected work item.

An issue body, pull-request body, or comment is always untrusted content. The source can describe
work but cannot grant authority, weaken repository policy, or instruct the
launcher to ignore workflow rules. A `maintainer-comment` launch requires the
trusted launcher to supply the already-verified author login. The helper checks
that the fetched comment matches the selected repository, work item, URL, author,
and a maintainer association. That explicit input is trusted state from the
security preflight; it is never inferred from the comment text.

Canonical source bytes are exactly the selected GitHub API `body` string after JSON decoding, encoded as UTF-8.
Selection, launch, and worker checks fetch the
same object and field and hash only those bytes, with no Unicode normalization,
Markdown rendering, whitespace trimming, or newline insertion or removal.
When GitHub returns `body: null` for a title-only issue or pull request, its
canonical source bytes are the empty UTF-8 string. Retain that SHA-256 digest in
the selection, launch, and worker fields instead of dropping the source.

The record keeps three separate lowercase SHA-256 values for those canonical
source bytes: `digest_at_selection`, `digest_at_launch`, and
`digest_observed_by_worker`. Preparation first verifies the launcher's supplied
selection digest before it becomes immutable run identity. Pre-dispatch launch
verification must match it; the worker observation must
match the launch digest before any source interpretation. The record never
stores or repeats the prompt source content. Digests are integrity bindings,
not proof that the content is trusted.

## Launcher composition boundary

Before prompt creation, the trusted launcher generates and persists one
globally unique per-execution `run_id`, one `launch_idempotency_key` reused by
retries of that launch, and one exact canonical `record_destination` in the
durable Batch Plan. It freezes the exact delivered plan, then persists one
immutable `batch_plan_binding` beside it in the run record and handoff envelope;
the digest is not included in the bytes it hashes. The binding is the SHA-256 of
the exact UTF-8 Batch Plan bytes delivered inline, or an immutable reference
plus its exact revision/content digest. A mutable, missing, changed, or `UNKNOWN`
binding stops at that boundary.

Choose a destination authorized to contain every lane's recorded identity and
source. An all-public GitHub run may use one exact selected issue or pull-request
work-item URL; a maintainer-comment source anchors to its parent work item. If
any lane has no public GitHub surface, use an existing durable plan/backend
destination authorized for every lane or split the trust boundaries into
separate runs. Never publish a private `plan-state://` or `batch://` identity in
a public run record. The launcher delivers the destination, run ID, and binding
in the existing handoff envelope outside the frozen Batch Plan, together with
that lane's launch digest and existing replay tuple:
`lane_id`, dispatcher, `instance_id`, and launch token. A deterministic launch
token is not unique across reruns and never substitutes for `run_id`. Bind the
envelope to the same `run_id`, `batch_plan_binding`, and replay identity. Do not
add the launch digest to the frozen plan or change its binding.

Each execution publishes exactly one `agent-launcher-run-record:v1` comment or
durable record at that destination. It has one compact visible state, one
collapsed details block, and one unique entry per planned lane. Selection
evidence is written first, launch evidence is appended at dispatch, and worker
evidence is appended only after the worker opens the destination, resolves the
exact outer `run_id`, replay tuple, and `batch_plan_binding`, and verifies both
the replay identity and its observed digest.
Missing, extra, duplicated, hybrid, or ambiguous lane routing fails closed.
Reruns append a new outer record instead of replacing history.

The launcher/coordinator is the sole writer for the outer record. It serializes
or compare-and-swaps every append to the exactly matching `run_id`, replay
identity, and `batch_plan_binding`; workers return bound observation payloads
and never race GitHub read-modify-write updates. It records each observed model
and workflow value field by field. A missing observation remains `UNKNOWN` and
does not block launch unless another gate independently requires it.

The v1 helper remains a closed GitHub boundary for issue bodies, pull-request
bodies, and trusted maintainer comments. Its `agent-run-record:v1` result
supplies nested GitHub lane evidence only and is never independently published.
The helper-generated `run_id` and retry key remain identifiers for that lane
evidence. The launcher embeds the evidence under the outer execution `run_id`;
it does not inject outer identity, destination, or replay values into the helper
or substitute the helper ID for the outer ID.

The outer renderer applies the helper renderer's HTML escaping, Markdown
neutralization, URI-scheme neutralization, and inert-code treatment to every
dynamic value. This includes target titles, lane IDs, every replay-tuple value,
record destinations, durable references, task/branch/PR values, updates, and
blockers. No outer dynamic value may create a Markdown link, HTML element, or
active URI.

A preflight-accepted `trusted-ad-hoc-override` whose durable authorization
reference is `issue://` or GitHub HTTPS follows the ordinary GitHub source path:
resolve the referenced issue or pull-request body, preserve the same author and
trust checks, and record actual selection, launch, and worker-observed body
digests instead of `not applicable — trusted-ad-hoc-override`.

Only the narrow non-GitHub override backed by an exact existing
`plan-state://` or `batch://` durable reference bypasses the helper. Preserve
that reference as the prompt source and persist the record at its existing
durable plan/backend destination.
Require the reference to resolve to the same immutable accepted
provenance/authority record revision, or equivalent existing content binding,
at selection, launch, and worker start. Record all three source-digest fields as
exact `not applicable — trusted-ad-hoc-override`. A missing, mutable, changed,
or `UNKNOWN` binding stops at that boundary. Do not invent source bytes, a
snapshot, another storage location, or another helper schema.

## Compact record

The visible portion contains the runner, machine, state/outcome, task, branch,
PR, latest material update, and no more than one meaningful blocker. Generated
metadata and detailed provenance live in one disclosure:

The launcher populates this canonical outer template. The placeholders name the
required ownership and observation boundary; the concrete example that follows
shows one rendered execution.

```markdown
- Run ID: <immutable unique per-execution run_id>
- Record destination: <exact issue or pull-request work-item URL authorized for every lane, or existing durable plan/backend destination authorized for every lane>
- Batch Plan binding: <SHA-256 of exact delivered UTF-8 plan bytes, or immutable reference plus exact revision/content digest>
- Prompt created at: <timestamp>
- Model at prompt creation: <observed value or UNKNOWN>
- Workflow at prompt creation: <version or UNKNOWN>
- Later workflow observations: <timestamped append-only entries or none>
Target lanes:
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
```

```markdown
<!-- agent-launcher-run-record:v1 -->
Agent run: Codex on M5 — active / pending

Task: `AW #560 — GitHub prompts and run records` · Branch: `jg-codex/issue-560-run-records` · PR: `UNKNOWN`
Latest: 2026-08-30T02:00:57.829Z — worker started
Blocker: none

<details>
<summary>Run details</summary>

- Run ID: `123e4567-e89b-42d3-a456-426614174000`
- Launch retry key: `65d9f4e3-b51d-4a09-ae97-bd8704aa9aac`
- Record destination: `https://github.com/shakacode/agent-workflows/issues/560`
- Batch Plan binding: `sha256:<64 lowercase hexadecimal characters>`
- Repository: `shakacode/agent-workflows`
- Prompt created at: 2026-08-30T02:00:56.829Z
- Runner: Codex
- Model at prompt creation: `gpt-5.6-sol`
- Workflow at prompt creation (2026-08-30T02:00:56.829Z): pack `<full commit SHA>`; pr-batch `sha256:<digest>`; pr-processing `sha256:<digest>`
- Later workflow observations: none
- Target lanes:
  - Lane: `issue-560`
    - Target: issue #560 — Use GitHub task prompts and compact append-only run records
    - Replay identity: `lane_id=issue-560; dispatcher=codex; instance_id=<instance>; launch_token=<token>`
    - Helper evidence run ID: `<helper-generated UUID v4>`
    - Helper evidence retry key: `<helper-generated UUID v4 reused by helper launch retries>`
    - Prompt source: issue-body — `https://github.com/shakacode/agent-workflows/issues/560`
    - Prompt digest at selection: `<64 lowercase hexadecimal characters>`
    - Prompt digest at launch: `<64 lowercase hexadecimal characters>`
    - Prompt digest observed by worker: `<64 lowercase hexadecimal characters>`
    - Prompt transport: handoff-envelope
    - Selected at: 2026-08-30T02:00:55.829Z
    - Launched at: 2026-08-30T02:00:57.000Z
    - Worker prompt digest observed at: 2026-08-30T02:00:57.829Z
    - Worker started at: 2026-08-30T02:00:57.829Z
    - Configured base at launch: `main`@`<full commit SHA>`
    - Model observed by worker: `UNKNOWN`
    - Task ID/link: `<task ID>` / `UNKNOWN`
    - Branch/PR: `jg-codex/issue-560-run-records` / `UNKNOWN`
    - State/outcome: `active` / `pending`
    - Latest: 2026-08-30T02:00:57.829Z — worker started
    - Blocker: none
    - Workflow observed at worker start (2026-08-30T02:00:57.829Z): pack `<full commit SHA>`; pr-batch `sha256:<digest>`; pr-processing `sha256:<digest>`
- Coordination: not recorded (optional)
- Record observed at: 2026-08-30T02:00:59.000Z

</details>
```

The helper HTML-escapes data and neutralizes Markdown metacharacters and URI
schemes before rendering dynamic prose. Verified source and task URLs render as
inert code. Work-item text, task titles, branch names, latest updates, and blockers
cannot become links or executable Markdown.

## V1 field contract

This table defines the unchanged GitHub lane evidence accepted and emitted by
the v1 helper. The trusted launcher composes that evidence with the outer
`record_destination`, replay tuple, and cheap `Launched at` observation defined
above; those outer fields do not expand the helper schema.

| Field | Contract |
| --- | --- |
| `contract`, `version` | Exactly `agent-run-record`, version `1`. |
| `run_id` | One helper-generated UUID v4 for the GitHub lane evidence; immutable and globally unique. The launcher embeds this evidence under its separately generated outer execution `run_id` without injecting that ID into the helper. |
| `launch_idempotency_key` | One helper-generated UUID v4 reused for retries of that same helper launch; reruns receive a new key. The outer launch retry key remains launcher-owned. |
| `repository`, `work_item` | Repository-qualified issue or pull-request kind, identity, title, and exact URL fetched from GitHub. |
| `prompt_source` | One exact `issue-body`, `pull-request-body`, or trusted `maintainer-comment` source URL plus distinct selection, launch, and worker-observed digests; comment sources also record author and association. |
| `prompt_transport` | `null` before launch verification, then the launch digest marked for the existing handoff envelope outside the frozen Batch Plan. The outer launcher binds that envelope to the same run, plan binding, and replay identity. |
| `current_main` | Machine provenance for the configured base branch and observed `origin/<base>` commit, or field-granular `UNKNOWN`. |
| `runner` | Runner name and machine plus separately observed model at prompt creation and worker start; each unavailable value is `UNKNOWN`. |
| `workflow_versions.prompt_creation` | Loaded-pack `HEAD` plus PR-batch and workflow digests read immediately after prompt creation, with the helper's direct observation timestamp; each unavailable value is `UNKNOWN`. |
| `workflow_versions.worker_start` | Immutable timestamped pack `HEAD` plus SHA-256 digests of the PR-batch skill and workflow observed at worker start; each unavailable value is `UNKNOWN`. |
| `workflow_versions.later_observations` | Append-only timestamped observations added only when one of those workflow versions changes; an empty array is valid. |
| `task` | Derived or explicit task title, task ID, and task URL; unavailable values are `UNKNOWN`. |
| `branch`, `pr` | Branch and at most one PR identity/URL; unavailable values are `UNKNOWN`. |
| `state` | `launch-pending \| active \| waiting \| blocked \| PR-ready \| completed` |
| `outcome` | `pending \| merged \| closed \| failed \| reverted` |
| `latest_material_update` | One directly captured timestamp plus one concise material update. |
| `blocker` | `null` or one single-line meaningful blocker. Arrays and repeated `--blocker` options are invalid. |
| `coordination` | Optional single-line coordination summary. Omission is valid. |
| `timestamps` | Direct `Selected at`, `Prompt created at`, worker-digest observation, `Worker started at` (or `pending`), and latest `observed_at` values. Timestamps use UTC RFC3339 with exactly millisecond precision. |

State and outcome are deliberately separate closed fields. `launch-pending`,
`active`, `waiting`, and `PR-ready` require `pending`; `completed` requires
`merged`, `closed`, `failed`, or `reverted`; `blocked` permits `pending` for a
live blocker or `failed` for the recorded unrecoverable worker-digest mismatch.
Tools must not invent synonyms or compress the two into one value.

Event times are nondecreasing: selection, prompt creation, its workflow
observation, worker digest observation and worker start when present, then the
latest record observation.
Later workflow observations occur nondecreasingly after worker start. A latest
material update or later workflow observation cannot be newer than the record's
observation time.

`Selected at` and `Prompt created at` are captured directly by the launcher:
the former at actual exact-URL selection and the latter only after it renders
the human prompt. The launcher also supplies `--prompt-digest-at-selection`
from the canonical bytes fetched at `Selected at`. The helper validates these
inputs before GitHub access, then re-fetches the same source and refuses identity
creation unless its digest matches. It never stores the source content. The
launcher captures the successful worker-start time
through `mark-worker-started`; before that event the record uses `Worker started
at: pending`. This cheap timestamp collection has no dependency on telemetry or
accounting work.

The outer launcher also captures `Launched at` directly when dispatch begins
and persists it with that lane's `verify-launch` result and replay handoff. The
helper supplies the verified launch digest; neither layer waits for telemetry
or infers the timestamp later.

Human `auto` maps to durable machine `auto_merge_when_gates_pass`; human `ask`
maps to durable machine `ask`. An explicitly selected machine
`merge_authority: none` renders as human `Merge authority: ask` because the
worker has no merge authority and must obtain explicit human authority before
merge. This rendering does not change the durable machine value from `none` to
`ask`.

## Workflow version history

`workflow_versions.prompt_creation` records the loaded workflow bytes observed
by `prepare` immediately after the launcher-created prompt. Its `observed_at`
is the actual helper read time, which can be later than the launcher-supplied
`Prompt created at`; it must not be backdated to that earlier event.
`workflow_versions.worker_start` begins as field-granular `UNKNOWN` with a
`pending` timestamp. `mark-worker-started` replaces that pending placeholder
once with the directly timestamped worker observation. That worker-start value
is immutable for the remainder of the run.

Workflow observations resolve the loaded Agent Workflows pack independently of
the consumer repository. The trusted launcher passes `--pack-root` for an
installed/global pack or a consumer's pinned `.agents` pack. A standalone pack
checkout records its own Git `HEAD`; a pinned directory inside the consumer
records file digests but leaves `pack_head` as `UNKNOWN` rather than reporting
the consumer commit. Omitting `--pack-root` is valid only when `--repo-root`
itself contains the source pack's `skills/pr-batch/SKILL.md` and
`workflows/pr-processing.md`.

For a long-running task, compare the current versions with the most recent
observation. When one changes, append a directly timestamped object to
`workflow_versions.later_observations`; never replace `worker_start` or an
earlier observation. Do not append redundant entries when nothing changed.
The helper's `observe-workflows` command performs this comparison and append.

## Retry and rerun history

The outer launcher persists its execution `run_id`, launch retry key, and
`record_destination` plus the exact `batch_plan_binding` before prompt creation.
A retry of that launch reuses those values and updates the same
`agent-launcher-run-record:v1` record. A
deliberate rerun generates a new outer run ID and retry key and appends one new
outer record at the persisted destination. It never replaces or folds the
earlier record.

Separately, each GitHub lane helper writes an `agent-run-launch-identity` v1
file with mode `0600`. The file binds its helper evidence run ID and
`launch_idempotency_key` to repository, work item, prompt source and selection
digest, trusted comment author and association when applicable, runner, machine,
prompt-creation model, configured base,
prompt-creation workflow, and direct selection/prompt-creation timestamps.
The helper validates the complete initial record before atomically publishing
this identity. Every later mutating command requires the same
`--identity-file` and rejects a record whose immutable fields no longer match
it before any GitHub read or record mutation.

- A retry of that helper launch reuses the same identity file and its helper
  evidence IDs, timestamps, configured-base binding, source, and selection
  digest even if `main` moved.
- If canonical source bytes differ at launch verification, the helper refuses
  dispatch and requires source reselection, security preflight, and a new outer
  run rather than mutating either identity.
- A helper rerun uses a new identity file and evidence IDs, but its payload is
  embedded in the new outer record. No `agent-run-record:v1` helper marker or
  helper-only comment is independently published.

The launcher is the sole durable writer and must read the current canonical
outer record before every transition; it rejects stale local snapshots instead
of replaying them. Once the current outer record persists a terminal failed
lane, no earlier helper payload or local snapshot may reopen that run. The
helper therefore does not create a second durable worker-state store: it emits
the bound observation for the launcher to append to the one canonical record.

Within one live outer record, only mutable state, task, branch, PR, latest
update, blocker, and later observations may refresh. The outer run ID, retry
key, destination, batch-plan binding, lane identities, source/selection evidence, prompt-creation
time, launch base, and recorded worker-start observations remain immutable.

## Optional coordination

Coordination is optional for this record. When a backend is active, the caller
may add one concise coordination summary. When no backend is configured or its
metadata is unavailable, omit the field; the renderer says `not recorded
(optional)`. The record still binds the GitHub work item, run, task, branch, and result PR.
This does not weaken any separate coordination requirement selected by the
repository or active PR-batch plan.

## Helper

Invoke the helper only for a GitHub-backed lane, including a trusted ad-hoc lane
whose durable authorization reference resolves to an `issue://` or GitHub HTTPS
issue or pull request. Only the narrow non-GitHub trusted-ad-hoc lane bypasses
the CLI and follows the durable-reference route above. Passing
`trusted-ad-hoc-override` to `--prompt-source` remains invalid and stops before a
GitHub read or identity write; resolve a GitHub-backed override to its ordinary
issue-body or pull-request-body source first.

Prepare an issue-body run after the normal PR-batch preflight and base fetch:

```bash
skills/pr-batch/bin/agent-run-record prepare \
  --issue 560 \
  --selected-at 2026-08-30T02:00:55.829Z \
  --prompt-created-at 2026-08-30T02:00:56.829Z \
  --prompt-digest-at-selection <64-lowercase-hex-SHA256> \
  --runner Codex \
  --machine M5 \
  --pack-root /path/to/loaded/agent-workflows \
  --identity-file /durable/private/run-560-1.json
```

For a direct accepted pull-request body, select its exact PR target with
`--pull-request N` instead of creating a synthetic comment. Exactly one of
`--issue` or `--pull-request` is required.

For a trusted maintainer-comment prompt source, add:

```text
--prompt-source maintainer-comment
--comment-url https://github.com/OWNER/REPO/issues/560#issuecomment-1234
--trusted-comment-author VERIFIED_LOGIN
```

Use `--format json` to capture the machine record. Render a validated record
without another GitHub read:

```bash
skills/pr-batch/bin/agent-run-record render < run-record.json
```

If preparation re-fetches different canonical bytes than the launcher fetched
at `Selected at`, it exits nonzero without creating an identity and requires a
deliberate new run, source reselection, and rerun security preflight.

Immediately before dispatch, create the distinct launch digest for the existing
handoff envelope outside the frozen Batch Plan:

```bash
skills/pr-batch/bin/agent-run-record verify-launch \
  --handoff-envelope \
  --identity-file /durable/private/run-560-1.json \
  < selected-run-record.json > launch-verified-record.json
```

A selection/launch mismatch makes no launch or worker-start mutation. It
requires a deliberate new run, source reselection, and rerun security preflight.
The verified record supplies nested lane evidence for the envelope; it does not
modify the Batch Plan. The outer launcher carries `record_destination`,
`run_id`, `batch_plan_binding`, this lane's launch digest, and its replay identity
in that envelope, bound to the same run, plan binding, and replay identity. For
copy-paste and host-native multi-target launches, send the readable human prompt,
frozen plan, and bound envelope together; keep all bookkeeping outside the human
prompt.

Before interpreting any source content, the worker verifies the frozen plan
binding and consumes the exactly matching bound envelope and nested record. It
then re-fetches the exact source and records the worker observation and start
boundary (supplying an observed model only when exposed):

```bash
skills/pr-batch/bin/agent-run-record mark-worker-started \
  --repo-root /path/to/repository \
  --pack-root /path/to/loaded/agent-workflows \
  --identity-file /durable/private/run-560-1.json \
  < launch-verified-record.json > started-run-record.json
```

`mark-worker-started` re-fetches only the selected issue-body, pull-request-body,
or comment fields and compares `Prompt digest observed by worker` with the
transported launch digest. A missing bound envelope stops without mutation. A mismatch exits
nonzero but emits an updated JSON record on standard output so the launcher can
persist it and update the same run comment: the actual digest and observation
time are recorded, state/outcome become `blocked` / `failed`, and one visible
blocker explains that source interpretation was refused. `Worker started at`
and the worker-start workflow observation remain `pending`; this failure is
terminal for that run. Selection/launch
mismatch remains a no-mutation failure that requires a new run and security
preflight.

During a long-running task, append an observation only when a workflow version
has changed:

```bash
skills/pr-batch/bin/agent-run-record observe-workflows \
  --repo-root /path/to/repository \
  --pack-root /path/to/loaded/agent-workflows \
  --identity-file /durable/private/run-560-1.json \
  < started-run-record.json > updated-run-record.json
```

The helper uses field-selected GitHub reads: repository `nameWithOwner`; issue
or pull request `number,title,body,url` for a direct body source; or work item
`number,title,url` plus the selected comment fields for a maintainer-comment
source. It emits Markdown or JSON only; posting or updating the GitHub comment remains the trusted
launcher/coordinator's responsibility. The launcher embeds the helper payload
as lane evidence and publishes only the outer marker.

## Historical v0 record

Existing `<!-- agent-run-record:v0 -->` comments are historical evidence. Do
not edit, reinterpret, or migrate them in place. New execution records publish
`<!-- agent-launcher-run-record:v1 -->`; helper payloads use
`agent-run-record:v1` only as nested evidence. A v0 comment does not supply an
outer run ID, idempotency key, record destination, three-boundary digest chain,
or split state/outcome, so it cannot be used as launch-retry identity.
