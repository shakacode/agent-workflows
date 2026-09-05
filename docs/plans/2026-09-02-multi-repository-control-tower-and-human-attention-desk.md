# Multi-Repository Control Towers And Human Attention Desk

> **Status:** Working specification approved in principle by the maintainer on
> 2026-09-02. This document records the operating decisions and follow-up work;
> it does not by itself add a daemon, dashboard feature, or coordination API.
> It is a point-in-time record. The live file layout, snapshot schema, writer
> state, and desk rules are the
> [Snapshot And Desk Contract](../control-tower-prompts.md#snapshot-and-desk-contract).

## Objective

Reduce large issue and pull-request backlogs quickly without making the human
poll many Codex tasks. Keep repositories independently productive, concentrate
human attention on the highest-value unresolved decision, and preserve the
small safety floor in the
[throughput-first workflow](2026-08-29-throughput-first-human-agent-workflow.md).

At the 2026-09-02 planning snapshot, GitHub reported:

| Repository | Open issues | Open pull requests |
| --- | ---: | ---: |
| `shakacode/agent-workflows` | 124 | 87 |
| `shakacode/agent-coordination` | 54 | 27 |
| `shakacode/agent-coordination-dashboard` | 15 | 3 |

These counts are a baseline, not a quota or authority to close or merge. Every
control tower refreshes live state before acting.

## Decisions

1. Run one user-facing control tower per repository. A control tower may create
   and supervise repository-scoped Codex tasks, but two control towers must not
   concurrently own the same repository portfolio.
2. Use a shared network-mounted directory, such as SMB or NFS, for the first
   Human Attention Desk. The shared directory is transport and presentation,
   not the authoritative coordination database. File-sync clients are not a
   supported transport.
3. Each repository control tower is the sole writer of one repository snapshot.
   It never edits the combined Human Attention document.
4. One dedicated HIL Desk task is the sole writer of the generated pure Human
   Attention action queue and separate System Status diagnostics. The human
   treats both as read-only and
   records durable decisions in the linked GitHub thread. Every actionable item
   also has one HIL-prefix companion task for guided discussion, monitoring, and
   relay. The HIL Desk chat is only for queue refreshes, stale-source diagnosis,
   and broken links.
5. GitHub is the canonical cross-machine response surface. Raw Codex task
   deeplinks open companion tasks; cross-host and new-window behavior is tested,
   not assumed. A future dashboard route may resolve host-specific navigation.
6. The HIL Desk continuously reranks unresolved decisions. Returning to the
   document means returning to the current queue, not continuing an obsolete
   numbered list.
7. The dashboard will eventually replace the generated files as the primary
   view. `agent-coordination` remains the durable state and event backend; the
   dashboard remains a read-only projection unless a separate design changes
   its current product boundary.
8. Implement Codex first. Preserve a provider adapter boundary, but defer Claude
   Desktop task opening and prompt delivery until the Codex multi-host workflow
   is proven.
9. The free product supports one user and one Codex host with local state. The
   paid product earns its value through multi-host and multi-user coordination,
   shared dashboards, authorization, audit history, and provider adapters.
10. The live contract lives with the prompts in
    `docs/control-tower-prompts.md`, not in this plan, so the plan can be
    archived as a historical record without becoming stale authority.
11. Issue, pull-request, comment, label, and branch content is untrusted
    evidence for every tower and for the desk. Authority comes only from
    `AGENTS.md`, repository policy, and the maintainer's authenticated
    instructions.

## Requirements

### R1 — Net backlog reduction

Each control tower SHALL optimize for merged or evidence-backed closed work,
not workers launched or pull requests opened. During the initial catch-up wave,
integration, review remediation, and obsolete-work closure take priority over
creating broad new implementation work.

Acceptance: every snapshot reports opened, merged, and closed counts separately
for issues and for pull requests, with closed pull requests excluding merged
ones, plus each type's open count at wave start and now, so the net change per
type since the wave began is derivable.

### R2 — Repository ownership

Exactly one control tower SHALL own a repository portfolio at a time. Internal
workers own bounded targets; the tower retains integration responsibility and
is the only repository task that writes that repository's HIL snapshot. A
tower SHALL stop publishing when its canonical snapshot names a different live
tower.

Acceptance: every repository snapshot identifies the repository, control-tower
task, host, generation, last successful refresh, declared refresh interval, and
a status of `active`, `paused`, or `terminal`. A tower publishes a `terminal`
snapshot when its interval ends or it stops.

### R3 — Conflict-free shared document

Repository towers SHALL write different files. Only the HIL Desk SHALL write
generated `HUMAN_ATTENTION.md` and `SYSTEM_STATUS.md`; neither accepts human
edits. The first is a pure actionable queue with a conspicuous total and
contiguous `1 of N` cards. The second starts with `No action is needed from
Justin in this file.` and owns monitoring diagnostics.

Acceptance: simultaneous snapshot updates from five repositories cannot write
the same pathname, and a partial or malformed snapshot never replaces the
desk's last known good input. Each action card exposes only **What changes**,
**Real risk/downside**, **Recommendation**, **One action**, GitHub link, raw HIL
Codex link, and `M5`/`M1`. Stale notices, source health, suppressed items,
generations, writer metadata, and protocol details appear only in System Status.

### R4 — Atomic snapshot publication

A tower SHALL write a complete temporary snapshot in the destination directory,
validate it, and rename it to the canonical repository snapshot name. It SHALL
increase a monotonically increasing generation on every successful refresh,
including one without content changes, so a quiet healthy source does not
appear stale. A replacement tower SHALL
continue from the higher of the existing canonical snapshot's generation and
the desk's accepted copy rather than restarting the counter. The HIL Desk SHALL reject a lower generation and
preserve the last known good snapshot when a new file is invalid or incomplete.

Acceptance: interruption before rename leaves either the previous valid
snapshot or no snapshot, never a half-written canonical file, and a restarted
tower's first snapshot is accepted.

### R5 — One aggregate writer

The short-term operating model SHALL designate one HIL Desk task and host as
the aggregate writer. A replacement SHALL first establish that the prior task
is terminal, then increment the writer epoch. Takeover of a live writer and
automatic multi-writer failover are out of scope for the file MVP.

Acceptance: `state/hil-writer.json` identifies the current writer task, host,
epoch, heartbeat, and each repository's last accepted generation. A writer is
live while its heartbeat is fresher than the contract's threshold. A different
live writer or a newer epoch stops publication without stopping repository
work. A replacement claims the file, re-reads it after one heartbeat interval
before publishing, and recovers accepted generations from that file and from
the desk's durable copy of each accepted snapshot; the desk rebuilds the
document from those copies on every refresh so an interrupted publication is
repaired.

### R6 — Durable PR-comment decisions

Every Human Attention item SHALL be backed by a pull request and use
authenticated GitHub PR comments as
the canonical durable, cross-machine decision channel for exact-head approvals,
gate acknowledgments, requested changes, complete choices, and the literal
`walkthrough requested`. Every actionable item SHALL also have exactly one
companion task titled `HIL — <repo> PR #<n> — <decision>`. That task, not the
busy execution-only tower, SHALL monitor and reply on GitHub, verify author and
applicable exact head, relay outcomes, notify the tower, and auto-archive when
terminal. The tower SHALL execute the relayed outcome and clear the item only
by publishing a newer snapshot. The aggregate HIL Desk SHALL NOT answer,
reinterpret, or clear the question.

Issue-only work SHALL remain repository backlog until decision-free scoping
produces a pull request. It SHALL NOT enter `attention` or create an issue-named
HIL companion directly.

When risk or complexity gates require a walkthrough, the HIL task SHALL use
`pr-walkthrough` to prepare the complete exact-head walkthrough up front and
publish all conceptual sections in one COMMENT-only GitHub review, one per
honest separately replyable inline thread. It SHALL NOT wait for `next` turns
before publishing later sections. `walkthrough requested` overrides
non-selection; live interactive Codex delivery occurs only when Justin asks.
The schema SHALL distinguish `decision_channel: github_comment`, required HIL
task identity/deeplink, `walkthrough_mode`, and live-request state. The HAD SHALL render each Codex
deeplink as a raw unformatted `codex://threads/...` URL, never Markdown or code.
No verified mechanism forces a deeplink into a new Codex window; the user keeps
the HIL view in a separately opened app window when desired. Every displayed
host is normalized at the producer/aggregation boundary to `M5` or `M1`, never
the runner-local identity `local`.

Acceptance: an item remains until its snapshot clears it and shows complete
choices, **Respond on GitHub**, a PR target, the HIL-prefix companion identity,
and raw Codex URL. Walkthrough completion is not approval.

Task archival is terminal housekeeping, not Human Attention. A task final SHALL
state `Archive state: ready` or the concrete reason it is not ready. Once
durable outcome evidence exists, task-owned work is committed, pushed, or
durably handed off, ownership is released, and no human decision remains, the
owning tower atomically appends an idempotent record to its per-repository
archive ledger, waits for durable acknowledgment, then removes the source
attention record and archives the Codex task. The HIL Desk may deterministically
aggregate those ledgers; repository towers never share one writable ledger.
Ambiguous cases remain unarchived in one aggregate pending-archive review list.
Archiving alone SHALL NOT create an attention item or notification, and clear
terminal tasks SHALL be archived rather than renamed merely to mark them.

### R7 — Dynamic priority

The HIL Desk SHALL rerank from current inputs on every refresh. Priority SHALL
be explained in plain language, not hidden behind an opaque score. Each item
SHALL carry one of the four allowed `priority_class` machine classifications in
the [contract](../control-tower-prompts.md#snapshot-and-desk-contract). The desk
SHALL rank imminent irreversible harm first; otherwise it ranks by work
unblocked, not a readiness-state label.

Routine implementation, bookkeeping, test-hardening preferences, unchanged
state, optional telemetry, and routine owner cleanup SHALL NOT enter the queue.
Close-only, invalid, superseded, assignment, known-bot allowlist, and board-
clutter work remains repository backlog even when a tool or strict preflight
uses a security label. `irreversible` security is limited to imminent credible
harm that requires the human's authority. An unknown priority class is invalid
and suppressed rather than guessed into the queue, while the source is shown as
degraded. Private-repository cleanup is grouped by owner into one normal team-
channel nudge with links and close/revive/on-hold choices. Known integration
bots are configured through the repository trust seam, and close-only work does
not inherit merge-oriented security urgency. A snapshot older than twice its
declared refresh interval is stale;
the desk SHALL show it as stale and SHALL NOT clear its items. Only fresh valid
sources contribute to `HUMAN_ATTENTION.md`. Preserved unresolved items from
stale or degraded sources appear only in `SYSTEM_STATUS.md`, never in the human
action queue.

Acceptance: a new higher-value item moves ahead on refresh and explains the
human-attention value. After genuine irreversible harm, the desk orders all
remaining classes by required non-negative `unlocks_count`, then `created_at`,
then stable item `id`, so readiness labels do not control order.

### R8 — Native links with honest host state

An actionable item SHALL carry its HIL-prefix companion's native Codex deeplink,
stable task identifier, title, provider, display host, and last-seen time. A
known Codex URI SHALL render raw and unformatted, never Markdown or inline code.
Display host is `M5` or `M1`, never `local`; producer-local identities are
normalized at the source/aggregation boundary. Unknown or untested cross-host
and new-window behavior stays explicit and does not block repository execution.

Acceptance: the M1-to-M5, M5-to-M1, and source-host-offline cases are recorded
before a cross-host link resolver is treated as implemented.

### R9 — High utilization without integration debt

Control towers SHOULD fill useful independent capacity on M5 and M1. They SHALL
not impose a global one-validator or one-review fence across unrelated
repositories merely because another root exists. They SHALL avoid duplicate
work on the same target, concurrent writers in one worktree, and resource use
that measurably harms healthy work.

Acceptance: each tower distinguishes implementation, integration, validation,
and review activity and records the concrete reason and idle share in its
snapshot whenever any usable capacity is intentionally idle, including during
partial utilization.

### R10 — Autonomous ordinary integration

When the goal prompt grants automatic merge authority, a control tower SHALL
merge an ordinary change after the repository's exact-head gates pass. It SHALL
not ask about optional test perfection, routine implementation choices, or
mechanical merge actions. It SHALL queue only a genuinely required risk,
product, architecture, production, release, destructive-action, or security
decision.

Acceptance: technically ready, autonomously eligible pull requests do not wait
for an additional conversational approval.

### R11 — Dashboard migration

The dashboard SHALL eventually render the same attention items and priorities
from `agent-coordination`. The file MVP SHALL not become a second permanent
database or force dashboard code to parse Markdown as authority.

Acceptance: the backend contract uses provider, host, task, repository, target,
status, priority class and reason, deep link, and timestamps as structured
fields; the Markdown document is generated output.

### R12 — Product boundary

The single-user, single-Codex-host workflow SHALL remain useful without a paid
service. Multi-host routing, multi-user permissions, shared audit history,
team-level scheduling, hosted notifications, and additional provider adapters
MAY be paid capabilities.

Acceptance: disabling the hosted backend leaves a functional local attention
document for one user and one host.

## File MVP

Each machine may mount the shared directory at a different local path. The
control-tower prompts call that local path `<SHARED_HIL_ROOT>`. The file
layout, snapshot schema, writer state, generated-document fields, and transport
rules are defined once, in the
[Snapshot And Desk Contract](../control-tower-prompts.md#snapshot-and-desk-contract),
so that towers, the desk, the later renderer, and the dashboard read one
source. This plan does not duplicate them.

## Cross-Host And Transport Tests

Before building a resolver:

1. copy an M1 Codex task deep link and open it from M5;
2. copy an M5 link and open it from M1;
3. repeat while the source Codex app is stopped;
4. record whether the link opens, routes, fails, or selects an ambiguous local
   task; and
5. preserve the stable task ID and host even when the link is unusable.

Before trusting the desk, from each host:

1. rename a complete temporary file over an existing snapshot and confirm the
   other host sees either the old or the new file, never a partial one;
2. record how long the other host takes to observe the new file;
3. write different files from both hosts at the same time; and
4. drop the mount during a rename and confirm the canonical file is intact.

If native links are host-local, the dashboard later provides a stable attention
URL that names the source host and offers the available host-specific open or
prompt-forwarding action. SSH transport is an implementation option, not a
reason to transfer ownership or infer that a remote task is alive.

## Dashboard And Backend Direction

`agent-coordination` should own durable attention records, host presence,
provider capabilities, task identity, lifecycle events, and access control.
`agent-coordination-dashboard` should render Attention, Activity, Work, and
Capacity views. Its current repository contract is read-only for coordination
state and forbids launching agents or mutating coordination records; preserve
that boundary during the first dashboard work.

The file MVP is intentionally a projection that can be discarded after the
dashboard is trusted. Claude support should implement the same conceptual
adapter only after Codex proves the contract:

```text
provider · host_id · task_id · open_uri · status · send_prompt · capabilities
```

An unavailable capability remains unavailable; it is not simulated by parsing
transcripts.

## Executable Tasks

### T1 — Publish the operating prompts

- **Requirements:** R1-R10.
- **Repository:** `agent-workflows`.
- **Files:** `docs/control-tower-prompts.md` (prompts and contract) and the
  documentation index.
- **Done:** concise paste-ready prompts exist for the two control towers, HIL
  Desk, later dashboard lane, and another repository, and each links to the
  contract.
- **Parallelism:** independent of T2-T5.

### T2 — Prove the shared-file MVP manually

- **Requirements:** R2-R8.
- **Repository:** operational run; no product code required.
- **Scope:** one M5 HIL Desk, one M5 `agent-workflows` tower, and one M1
  `agent-coordination` tower.
- **Done:** both snapshots update without conflict, the generated human file
  contains only contiguous actionable cards while diagnostics stay in System
  Status, a resolved item disappears, a
  restarted tower's next snapshot is accepted, and the transport tests above
  are recorded. Writer lifecycle cases are also recorded: a desk with a stale
  epoch stops publishing, a replacement's claim is verified after one heartbeat
  interval, a crash between the document and writer-state renames is repaired
  on restart, a malformed or rolled-back canonical snapshot leaves the
  accepted copy and its items intact, a second tower started for the same
  repository stops itself, and the producer roster survives a desk replacement.
  Concurrent archives in different repositories retain both idempotent records,
  and a failure between ledger acknowledgment and source clearing resumes
  without losing or duplicating the record.
- **Parallelism:** starts after T1; dashboard work does not block it.

### T3 — Add a deterministic snapshot renderer

- **Requirements:** R3-R7, R11-R12.
- **Repository:** resolve during issue planning between `agent-workflows` for a
  portable renderer and `agent-coordination` for backend-owned state. Do not
  duplicate the implementation.
- **Done:** fixtures prove atomic generation, generation rollback rejection,
  malformed-input preservation, staleness labeling, deterministic ranking by
  priority class, bounded output, and that an adversarial snapshot whose text
  contains instructions is rendered as data. They also prove the human file has
  only a conspicuous total and contiguous actionable cards while every
  diagnostic moves to System Status. A policy-violating `safe_resume` is
  rejected before source-task execution.
- **Parallelism:** after T2 reveals the smallest stable contract.

### T4 — Add structured attention state to Agent Coordination

- **Requirements:** R6-R8, R11-R12.
- **Repository:** `agent-coordination`.
- **Done:** attention records, canonical GitHub-comment decision channel, tower
  identity, required HIL companion identity and last-seen time, and walkthrough
  mode are durable and queryable. A freshness test proves that a stale companion
  is suppressed to System Status until repaired. Display hosts are normalized
  to `M5` or `M1`, never `local`.
- **Parallelism:** after T2; can overlap T3 once ownership is resolved.

### T5 — Render the HIL queue in the dashboard

- **Requirements:** R6-R8, R11-R12.
- **Repository:** `agent-coordination-dashboard`.
- **Done:** a read-only Attention view continuously reranks backend records,
  links to the GitHub comment channel and required HIL companion, shows
  walkthrough mode, and explains priority. A separate System Status view owns
  stale hosts, suppressed items, generations, and writer diagnostics.
- **Parallelism:** starts after T4's structured attention records exist and
  after the first backlog-integration wave in both `agent-workflows` and
  `agent-coordination`, when neither tower has a waiting integration-ready
  pull request.

## Non-Goals For The File MVP

- Editing or resolving decisions in the generated files.
- Multiple HIL Desk writers or automatic writer failover.
- Treating a shared network filesystem as the coordination database.
- Launching agents, merging, or mutating coordination state from the dashboard.
- Claude Desktop task navigation.
- Billing, hosted multi-tenant infrastructure, SSO, or team permissions.
- Closing valid work merely to improve backlog counts.

## Spec Summary

- **Intent:** dramatically reduce repository backlogs while giving the human
  one live, prioritized, deep-linked attention surface.
- **Requirements:** R1-R12 above.
- **Design:** per-repository atomic snapshots, one aggregate writer, source-task
  decisions, native Codex links, and later backend/dashboard projection.
- **Tasks:** T1-T5 above.
- **File-touch map or discovery scope:** documentation now, with the live
  contract in `docs/control-tower-prompts.md`; renderer ownership remains a
  bounded T3 planning decision.
- **Validation expectations:** repository-owned focused checks and full gates;
  T2 additionally proves M5/M1 file, transport, and deep-link behavior.
- **Expected readiness or unresolved `UNKNOWN` facts:** cross-host native Codex
  deep-link behavior and the final mounted paths remain `UNKNOWN` until T2.
- **Blocking questions:** none for publishing prompts or running the manual MVP.
- **Non-blocking assumptions:** the same shared directory is mounted read/write
  on M5 and M1 over SMB or NFS, possibly at different local paths.
- **Recommended `$plan-pr-batch` scope:** after the manual MVP, plan T3 and T4
  as separate issues; plan T5 only after its backlog gate clears.
