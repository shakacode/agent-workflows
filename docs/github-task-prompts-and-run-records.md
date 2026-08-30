# GitHub Task Prompts And Run Records

GitHub is the durable link between a human-readable prompt source, the agent task
that executes it, and any pull request it produces. The `agent-run-record` v1
contract keeps that link compact without copying the workflow into every
prompt or making coordination a prerequisite.

This document applies the human-prompt decisions from issue #476 to the run
record and launch metadata. Changing prompt wording does not change the v1
identity, digest, lifecycle, or history rules below.

## One-line launch

The operator may say `Use PR-batch to complete this work item`. For an issue
target, the exact one-line shortcut `Use PR-batch to fix this issue` remains a
supported equivalent. The launcher then:

1. applies the existing target and security preflights;
2. derives the repository and exact issue or pull request from the active GitHub target;
3. reads only the work-item fields it uses;
4. records the configured base branch and the already-fetched `origin/<base>`
   commit as the configured base at launch when available;
5. derives a deterministic task title from the repository prefix, work-item
   number, and title;
6. accepts the launcher's actual source-selection and human-prompt-rendering
   timestamps plus its digest of the canonical bytes fetched at selection;
7. re-fetches the same source during preparation, requires its digest to match
   the supplied selection digest, and only then captures the record observation
   time and persists launch identity;
8. immediately before dispatch, re-fetches those bytes, verifies a distinct
   launch digest, and puts that digest in the complete Batch Plan or its exact
   durable plan-state reference; and
9. lets the worker re-fetch and match the transported launch digest before it
   interprets the source or records worker start.

The user does not supply file-touch maps, coordination diagnostics, workflow
restatements, generated identifiers, digests, or timestamps. Missing observed
metadata stays field-granular `UNKNOWN`; it does not stall ordinary work unless
another workflow gate independently requires that fact.

## Prompt sources and trust

A run has exactly one prompt source:

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

The record keeps three separate lowercase SHA-256 values for those canonical
source bytes: `digest_at_selection`, `digest_at_launch`, and
`digest_observed_by_worker`. Preparation first verifies the launcher's supplied
selection digest before it becomes immutable run identity. Pre-dispatch launch
verification must match it; the worker observation must
match the launch digest before any source interpretation. The record never
stores or repeats the prompt source content. Digests are integrity bindings,
not proof that the content is trusted.

## Compact record

The visible portion contains the runner, machine, state/outcome, task, branch,
PR, latest material update, and no more than one meaningful blocker. Generated
metadata and detailed provenance live in one disclosure:

```markdown
<!-- agent-run-record:v1 -->
Agent run: Codex on M5 — active / pending

Task: `AW #560 — GitHub prompts and run records` · Branch: `jg-codex/issue-560-run-records` · PR: `UNKNOWN`
Latest: 2026-08-30T02:00:57.829Z — worker started
Blocker: none

<details>
<summary>Run details</summary>

- Run ID: `123e4567-e89b-42d3-a456-426614174000`
- Launch retry key: `65d9f4e3-b51d-4a09-ae97-bd8704aa9aac`
- Repository: `shakacode/agent-workflows`
- Work item: issue #560 — Use GitHub task prompts and compact append-only run records
- Prompt source: issue-body — https://github.com/shakacode/agent-workflows/issues/560
- Prompt digest at selection: `<64 lowercase hexadecimal characters>`
- Prompt digest at launch: `<64 lowercase hexadecimal characters>`
- Prompt digest observed by worker: `<64 lowercase hexadecimal characters>`
- Prompt transport: complete-batch-plan — `inline`
- Selected at: 2026-08-30T02:00:55.829Z
- Prompt created at: 2026-08-30T02:00:56.829Z
- Worker prompt digest observed at: 2026-08-30T02:00:57.829Z
- Worker started at: 2026-08-30T02:00:57.829Z
- Configured base at launch: `main`@`<full commit SHA>`
- Runner: Codex
- Model at prompt creation: `gpt-5.6-sol`
- Model observed by worker: `UNKNOWN`
- Task ID/link: `<task ID>` / `UNKNOWN`
- Branch/PR: `jg-codex/issue-560-run-records` / `UNKNOWN`
- State/outcome: `active` / `pending`
- Workflow at prompt creation (2026-08-30T02:00:56.829Z): pack `<full commit SHA>`; pr-batch `sha256:<digest>`; pr-processing `sha256:<digest>`
- Workflow observed at worker start (2026-08-30T02:00:57.829Z): pack `<full commit SHA>`; pr-batch `sha256:<digest>`; pr-processing `sha256:<digest>`
- Later workflow observations: none
- Coordination: not recorded (optional)
- Record observed at: 2026-08-30T02:00:59.000Z

</details>
```

The helper HTML-escapes data and neutralizes Markdown metacharacters and URI
schemes before rendering dynamic prose. Verified source and task URLs render as
inert code. Work-item text, task titles, branch names, latest updates, and blockers
cannot become links or executable Markdown.

## V1 field contract

| Field | Contract |
| --- | --- |
| `contract`, `version` | Exactly `agent-run-record`, version `1`. |
| `run_id` | One generated UUID v4 for the logical run; immutable and globally unique. |
| `launch_idempotency_key` | One generated UUID v4 reused for retries of that same launch. |
| `repository`, `work_item` | Repository-qualified issue or pull-request kind, identity, title, and exact URL fetched from GitHub. |
| `prompt_source` | One exact `issue-body`, `pull-request-body`, or trusted `maintainer-comment` source URL plus distinct selection, launch, and worker-observed digests; comment sources also record author and association. |
| `prompt_transport` | `null` before launch verification, then the launch digest bound to the complete Batch Plan or an exact durable `plan-state://<id>/<path>` reference. |
| `current_main` | Machine provenance for the configured base branch and observed `origin/<base>` commit, or field-granular `UNKNOWN`. |
| `runner` | Runner name and machine plus separately observed model at prompt creation and worker start; each unavailable value is `UNKNOWN`. |
| `workflow_versions.prompt_creation` | Timestamped loaded-pack `HEAD` plus PR-batch and workflow digests observed at prompt creation; each unavailable value is `UNKNOWN`. |
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

Event times are nondecreasing: selection, prompt creation, worker digest
observation and worker start when present, then the latest record observation.
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

## Workflow version history

`workflow_versions.prompt_creation` records the prompt-creation observation.
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

The launcher writes an `agent-run-launch-identity` v1 file with mode `0600`
before worker launch. The file binds the run ID and
`launch_idempotency_key` to repository, work item, prompt source and selection digest,
runner, machine, prompt-creation model, configured base, prompt-creation workflow,
and the direct selection and prompt-creation timestamps.

- A launch retry uses the same identity file. It reuses the run ID,
  `launch_idempotency_key`, original selection/prompt-creation times, and original configured-base
  binding even if `main` moved while the launch channel retried.
- Same-launch retries preserve the original source and selection digest. If the
  canonical source bytes differ at launch verification, the helper refuses
  dispatch and requires a deliberate new run, source reselection, and rerun of
  the security preflight.
- A rerun uses a new identity file, receives a new run ID and idempotency key,
  and appends a new v1 GitHub comment. It never replaces the earlier run.

The GitHub history is append-only at the run boundary. A live run may refresh
its own comment's mutable state, task, branch, PR, latest update, and blocker,
but its run ID, launch retry key, prompt source/selection digest, selection and
prompt-creation times, launch base, and recorded worker-start observation remain
immutable. Every rerun is a new comment.

## Optional coordination

Coordination is optional for this record. When a backend is active, the caller
may add one concise coordination summary. When no backend is configured or its
metadata is unavailable, omit the field; the renderer says `not recorded
(optional)`. The record still binds the GitHub work item, run, task, branch, and result PR.
This does not weaken any separate coordination requirement selected by the
repository or active PR-batch plan.

## Helper

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

Immediately before dispatch, create the distinct launch digest and its required
plan transport. Use exactly one transport form:

```bash
skills/pr-batch/bin/agent-run-record verify-launch \
  --complete-batch-plan < selected-run-record.json > launch-verified-record.json

skills/pr-batch/bin/agent-run-record verify-launch \
  --plan-state-ref plan-state://BATCH_ID/run-record \
  < selected-run-record.json > launch-verified-record.json
```

A selection/launch mismatch makes no launch or worker-start mutation. It
requires a deliberate new run, source reselection, and rerun security preflight.
The verified record, including `Prompt digest at launch`, travels with the
complete Batch Plan or through the exact resolvable plan-state reference. For
copy-paste and host-native multi-target launches, send the readable human prompt
and this complete plan or reference together; keep the plan bookkeeping outside
the human prompt.

Before interpreting any source content, the worker consumes that transported
record, re-fetches the exact source, and records the worker observation and
start boundary (supplying an observed model only when exposed):

```bash
skills/pr-batch/bin/agent-run-record mark-worker-started \
  --repo-root /path/to/repository \
  --pack-root /path/to/loaded/agent-workflows \
  < launch-verified-record.json > started-run-record.json
```

`mark-worker-started` re-fetches only the selected issue-body, pull-request-body,
or comment fields and compares `Prompt digest observed by worker` with the transported launch
digest. A missing plan transport stops without mutation. A mismatch exits
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
  < started-run-record.json > updated-run-record.json
```

The helper uses field-selected GitHub reads: repository `nameWithOwner`; issue
or pull request `number,title,body,url` for a direct body source; or work item
`number,title,url` plus the selected comment fields for a maintainer-comment
source. It emits Markdown or JSON only; posting or updating the GitHub comment remains the trusted
launcher/coordinator's responsibility.

## Historical v0 record

Existing `<!-- agent-run-record:v0 -->` comments are historical evidence. Do
not edit, reinterpret, or migrate them in place. New runs emit v1. A v0 comment
does not supply a v1 run ID, idempotency key, three-boundary digest chain, or
split state/outcome, so
it cannot be used as a launch-retry identity file.
