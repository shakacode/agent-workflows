# GitHub Task Prompts And Run Records

GitHub is the durable link between a human-readable task brief, the agent task
that executes it, and any pull request it produces. The `agent-run-record` v1
contract keeps that link compact without copying the workflow into every
prompt or making coordination a prerequisite.

This document defines the run record and launch metadata. The final wording of
the human-authored brief remains owned by issue #476; changing that wording does
not change the v1 identity, digest, lifecycle, or history rules below.

## One-line launch

The operator may say `Use PR-batch to fix this issue`. The launcher then:

1. applies the existing target and security preflights;
2. derives the repository and exact issue from the active GitHub target;
3. reads only the issue fields it uses;
4. records the configured base branch and the already-fetched `origin/<base>`
   commit as current main when available;
5. derives a deterministic task title from the repository prefix, issue number,
   and issue title;
6. hashes the exact brief bytes and persists launch identity before starting the
   worker; and
7. renders one compact v1 record for the issue.

The user does not supply file-touch maps, coordination diagnostics, workflow
restatements, generated identifiers, digests, or timestamps. Missing observed
metadata stays field-granular `UNKNOWN`; it does not stall ordinary work unless
another workflow gate independently requires that fact.

## Brief sources and trust

A run has exactly one brief source:

- `issue-body`: the exact body bytes returned for the selected issue; or
- `maintainer-comment`: the exact body bytes of one comment on that issue.

An issue body or comment is always untrusted content. The source can describe
work but cannot grant authority, weaken repository policy, or instruct the
launcher to ignore workflow rules. A `maintainer-comment` launch requires the
trusted launcher to supply the already-verified author login. The helper checks
that the fetched comment matches the selected repository, issue, URL, author,
and a maintainer association. That explicit input is trusted state from the
security preflight; it is never inferred from the comment text.

The record stores `content_sha256`, the lowercase SHA-256 digest of the exact
decoded issue-body or comment-body string observed at launch. It never stores
or repeats the brief body. A digest is an integrity binding, not proof that the
content is trusted.

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
- Issue: #560 — Use GitHub task prompts and compact append-only run records
- Brief: issue-body — https://github.com/shakacode/agent-workflows/issues/560
- Brief SHA-256: `<64 lowercase hexadecimal characters>`
- Current main: `main`@`<full commit SHA>`
- Runner/model: Codex / `gpt-5.6-sol`
- Task ID/link: `<task ID>` / `UNKNOWN`
- Branch/PR: `jg-codex/issue-560-run-records` / `UNKNOWN`
- State/outcome: `active` / `pending`
- Workflow versions at worker start (2026-08-30T02:00:57.829Z): pack `<full commit SHA>`; pr-batch `sha256:<digest>`; pr-processing `sha256:<digest>`
- Later workflow observations: none
- Coordination: not recorded (optional)
- Launched/observed: 2026-08-30T02:00:57.829Z / 2026-08-30T02:00:59.000Z

</details>
```

The helper HTML-escapes data before rendering it. It does not turn issue text,
task titles, branch names, or blocker text into executable Markdown.

## V1 field contract

| Field | Contract |
| --- | --- |
| `contract`, `version` | Exactly `agent-run-record`, version `1`. |
| `run_id` | One generated UUID v4 for the logical run; immutable and globally unique. |
| `launch_idempotency_key` | One generated UUID v4 reused for retries of that same launch. |
| `repository`, `issue` | Repository-qualified issue identity, title, and URL fetched from GitHub. |
| `brief` | One `issue-body` or `maintainer-comment` source URL plus `content_sha256`; comment sources also record author and association. |
| `current_main` | Configured base branch and observed `origin/<base>` commit, or field-granular `UNKNOWN`. |
| `runner` | Runner name, host-observed machine, and host-observed model or `UNKNOWN`. |
| `workflow_versions.worker_start` | Immutable timestamped pack `HEAD` plus SHA-256 digests of the PR-batch skill and workflow observed at worker start; each unavailable value is `UNKNOWN`. |
| `workflow_versions.later_observations` | Append-only timestamped observations added only when one of those workflow versions changes; an empty array is valid. |
| `task` | Derived or explicit task title, task ID, and task URL; unavailable values are `UNKNOWN`. |
| `branch`, `pr` | Branch and at most one PR identity/URL; unavailable values are `UNKNOWN`. |
| `state` | `launch-pending \| active \| waiting \| blocked \| PR-ready \| completed` |
| `outcome` | `pending \| merged \| closed \| failed \| reverted` |
| `latest_material_update` | One directly captured timestamp plus one concise material update. |
| `blocker` | `null` or one single-line meaningful blocker. Arrays and repeated `--blocker` options are invalid. |
| `coordination` | Optional single-line coordination summary. Omission is valid. |
| `timestamps` | `launched_at` and `observed_at`, captured directly by the launcher in UTC with millisecond precision. |

State and outcome are deliberately separate. State answers where execution is
now; outcome answers how the run ended. Both are closed fields. Tools must not
invent synonyms or compress the two into one value.

The launcher captures `launched_at`, `observed_at`, and the latest material
update timestamp directly. This cheap timestamp collection has no dependency
on telemetry or accounting work.

## Workflow version history

`workflow_versions.worker_start` is the immutable workflow observation for the
run. A retry using the same identity file reuses it even if the pack, PR-batch
skill, or PR-processing workflow has changed since worker start.

For a long-running task, compare the current versions with the most recent
observation. When one changes, append a directly timestamped object to
`workflow_versions.later_observations`; never replace `worker_start` or an
earlier observation. Do not append redundant entries when nothing changed.
The helper's `observe-workflows` command performs this comparison and append.

## Retry and rerun history

The launcher writes an `agent-run-launch-identity` v1 file with mode `0600`
before worker launch. The file binds the run ID and
`launch_idempotency_key` to repository, issue, brief source and digest, runner,
machine, model, current main, and the worker-start workflow observation.

- A launch retry uses the same identity file. It reuses the run ID,
  `launch_idempotency_key`, original launch time, and original current-main
  binding even if `main` moved while the launch channel retried.
- If the issue or comment bytes, source, runner, machine, or model changed, the
  helper refuses that retry. The launcher must classify the change and start a
  new run when appropriate.
- A rerun uses a new identity file, receives a new run ID and idempotency key,
  and appends a new v1 GitHub comment. It never replaces the earlier run.

The GitHub history is append-only at the run boundary. A live run may refresh
its own comment's mutable state, task, branch, PR, latest update, and blocker,
but its run ID, launch retry key, brief source/digest, launch time, and launch
main remain immutable. Every rerun is a new comment.

## Optional coordination

Coordination is optional for this record. When a backend is active, the caller
may add one concise coordination summary. When no backend is configured or its
metadata is unavailable, omit the field; the renderer says `not recorded
(optional)`. The record still binds the GitHub issue, run, task, branch, and PR.
This does not weaken any separate coordination requirement selected by the
repository or active PR-batch plan.

## Helper

Prepare an issue-body run after the normal PR-batch preflight and base fetch:

```bash
skills/pr-batch/bin/agent-run-record prepare \
  --issue 560 \
  --runner Codex \
  --machine M5 \
  --identity-file /durable/private/run-560-1.json
```

For a trusted maintainer-comment brief, add:

```text
--brief maintainer-comment
--comment-url https://github.com/OWNER/REPO/issues/560#issuecomment-1234
--trusted-comment-author VERIFIED_LOGIN
```

Use `--format json` to capture the machine record. Render a validated record
without another GitHub read:

```bash
skills/pr-batch/bin/agent-run-record render < run-record.json
```

During a long-running task, append an observation only when a workflow version
has changed:

```bash
skills/pr-batch/bin/agent-run-record observe-workflows \
  --repo-root /path/to/repository < run-record.json > updated-run-record.json
```

The helper uses field-selected GitHub reads: repository `nameWithOwner`, issue
`number,title,body,url` for an issue-body brief, issue `number,title,url` plus
the selected comment fields for a maintainer-comment brief. It emits Markdown
or JSON only; posting or updating the GitHub comment remains the trusted
launcher/coordinator's responsibility.

## Historical v0 record

Existing `<!-- agent-run-record:v0 -->` comments are historical evidence. Do
not edit, reinterpret, or migrate them in place. New runs emit v1. A v0 comment
does not supply a v1 run ID, idempotency key, digest, or split state/outcome, so
it cannot be used as a launch-retry identity file.
