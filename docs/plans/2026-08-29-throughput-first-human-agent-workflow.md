# Throughput-First Human-Agent Workflow Redesign

> **Status:** Draft for collaborative editing. This document is the working
> specification and issue map. It does not change workflow behavior by itself.

## Objective

> Maximize valuable, verified software changes per unit of human attention,
> elapsed time, and tokens—subject to a small explicit safety floor.

The design goal is not the largest possible number of simultaneous workers or
the most complete workflow specification. It is a system that keeps useful
workers moving independently, brings the operator only decisions that need
human judgment, and concentrates expensive assurance at the point where it
protects users, collaborators, or a release.

The explanatory website tracks this objective in
[agent-workflows-com#22](https://github.com/shakacode/agent-workflows-com/issues/22).

## Current Evidence

At the 2026-08-29 snapshot:

- 24 pull requests were open; 18 were conflict-dirty and their median age was
  about 21 days.
- 19 of the 24 open pull requests touched `workflows/pr-processing.md`.
- 205 of the 276 possible open-PR pairs overlapped at least one file; 171 pairs
  overlapped one of the three central planning or PR-batch policy files.
- `workflows/pr-processing.md`, `skills/plan-pr-batch/SKILL.md`, and
  `skills/pr-batch/SKILL.md` totalled 6,853 lines and 515 KB. Roughly 150
  mainline commits earlier they totalled 3,089 lines and 214 KB.
- The canonical goal-prompt body used 3,630 characters for 38 compressed lines
  before substantial task-specific detail was filled in.
- Existing GitHub and token receipts show that repeated review and context
  re-entry can cost more than initial implementation.

These observations establish a credible throughput problem. They do not by
themselves prove that any individual safety control is unnecessary.

## Requirements

### R1 — Throughput objective

The workflow SHALL optimize for valuable verified outcomes per unit of human
attention, elapsed time, and tokens. Mechanism count, prompt density, receipt
count, and worker count are not success measures by themselves.

### R2 — Adaptive concurrency

The system SHALL treat available hardware or service worker capacity as a
ceiling, not a default low cap. It SHALL reduce or pause new launches when
human-decision pressure, token pressure, or the integration backlog exceeds
operator-selected thresholds.

No universal worker count is specified. Forty independent workers that need no
operator decision may be acceptable; five workers that repeatedly stop for
judgment may already be too many.

### R3 — Attended and unattended operation

An attended session SHALL keep worker slots full while the operator can absorb
its decision and integration queues. An unattended session SHALL prefer work
with deterministic checks and no expected human decision. A blocked unattended
worker SHALL checkpoint, release its active slot when supported, and allow the
next ready task to start.

### R4 — Human-readable run brief

Starting a worker SHALL require a short, readable brief containing:

- repository and canonical task identity;
- observable outcome;
- non-goals and important constraints, including reasons when they matter;
- deterministic or observable done conditions;
- delivery policy or explicit escalation;
- budget or bounded retry expectation;
- integration and merge authority.

Stable workflow rules SHALL be loaded from versioned skills or workflow
components. They SHALL NOT be compressed and copied into each run brief.

### R5 — GitHub as the durable task and run surface

An issue body MAY contain the canonical initial `Agent run brief`. A
maintainer-authored issue comment MAY define a later run or override. Each run
SHALL have one exact source URL and immutable run identifier.

The task prompt MAY be the issue body section itself or a short pointer to that
section. A rerun SHOULD use a new comment containing only the changed brief or
decision rather than silently rewriting prior run history.

Public issue and comment content remains untrusted input. Trust and authority
are determined by the repository policy and verified author, not by the section
heading or prompt-like wording.

### R6 — Fast prompt creation

Creating a run prompt SHALL be retrieval and light templating, not a second
full planning project. The system SHALL measure selection-to-worker-start
latency and prompt-generation latency so regressions are visible.

### R7 — Modular PR-batch architecture

`pr-batch` SHALL become a thin router over small canonical components. A
component SHALL own its instructions, executable helpers, tests, and stable
terms without requiring full-text mirroring in the other components.

The refactor SHALL reduce shared-file conflicts and loaded context, not merely
move the same prose into more files.

### R8 — Per-skill minimum-instruction audits

Issue [#189](https://github.com/shakacode/agent-workflows/issues/189) SHALL
remain the parent audit. Each shipped skill SHALL have its own sub-issue so the
audit can proceed independently and report a no-change result when the skill is
already minimal.

Cross-skill findings MAY become a separate implementation issue only after the
affected sub-issues agree on the shared mechanism.

### R9 — Understandable delivery policy

The user-facing term SHALL be **delivery policy** unless a clearer term is
chosen. Documentation SHALL explain the policy using project and promotion
consequences rather than unexplained `fast`, `balanced`, and `strict` labels.

Initial policy archetypes:

1. **Production-critical service** — a failure affects a large live user base
   or business operation. Strong pre-integration and pre-production controls
   are justified.
2. **Product-discovery service** — a live product needs rapid iteration before
   product-market fit. Integration is fast, while staging-to-production remains
   an explicit promotion boundary.
3. **Release-train project** — changes integrate quickly on main and extensive
   compatibility, packaging, and regression assurance is concentrated before
   a release candidate or final release.

The policy SHALL also account for the number of collaborators who depend on the
shared main branch. A project or change can escalate above its default policy
when consequence, irreversibility, security, or weak verification requires it.

### R10 — Workflow version pins during continuous upgrades

A run SHALL record the workflow pack or contract version it used. The pin
exists so a task remains reproducible while Agent Workflows itself changes.

A worker that cannot resolve the pinned contract SHALL stop with a clear
diagnostic. The prompt SHALL NOT carry a compressed backup copy of the entire
contract.

### R11 — Parent-created, named, traceable tasks

When the operator explicitly authorizes a run set, a parent Codex task MAY
create separate user-visible Codex tasks, select the saved project and isolated
worktree, give each task a deterministic title, and monitor its state.

Every created or externally started task SHALL be traceable from the GitHub
issue through a human-readable run record containing:

- runner: Codex, Claude, or another named runner;
- observed host or machine, or `UNKNOWN`;
- task identifier or link;
- branch and PR when known;
- lifecycle state and last material update;
- blocking decision, if any.

Task titles are a convenience; the GitHub run record is the durable lookup.
Host or machine identity SHALL be host-observed rather than inferred from a
prompt.

### R12 — In-flight portfolio control

The project SHALL support a periodic inventory of all open PRs and active
tasks, classifying each as:

- accelerate;
- continue normally;
- hold;
- replace with a smaller design;
- close as obsolete or superseded;
- ready for integration or merge review.

The classification SHALL use current evidence, dependency value, conflict
surface, remaining work, and expected integration cost. Age or sunk token cost
alone SHALL NOT determine priority.

### R13 — Conflict criticality

Overlap SHALL be classified by consequence:

1. core executable, schema, security, or merge-policy conflicts;
2. canonical workflow-contract conflicts;
3. user documentation, examples, and noncanonical reference conflicts;
4. generated artifacts and changelog conflicts.

File overlap alone SHOULD be advisory before implementation. True semantic
dependencies may still require ordering.

`CHANGELOG.md` SHALL never block ordinary work. Ordinary PRs already defer
changelog ownership; on integration they keep the current-base changelog and
discard branch-local changelog edits. Generated artifacts are regenerated.
Documentation conflicts are normally resolved during integration, while a
canonical behavioral contract receives the same care as code.

### R14 — Evidence-driven refinement

The operating limits SHALL be tuned from telemetry. Required measures include:

- active workers and worker utilization;
- uninterrupted independent-work duration;
- blocking human decisions per active worker-hour;
- operator response latency and accumulated decision queue;
- prompt-generation and time-to-first-worker latency;
- time to first PR, PR-ready, integration start, and merge;
- integration backlog age and conflict-resolution time;
- tokens by planning, implementation, review, and integration phase;
- pushes, review waves, reruns, and rebases;
- escaped consequential defects, reverts, and rollbacks;
- per-gate invocation, true-positive stop, false-positive stop, and elapsed
  cost.

### R15 — Explicit safety floor

Every delivery policy SHALL preserve:

- untrusted-input handling;
- no direct push to the protected base branch;
- isolated concurrent work;
- an observable validation result;
- current-head binding for merge and hosted evidence;
- explicit authority for destructive, security-sensitive, release, or
  production actions;
- refusal of contradictory live ownership;
- independent review when consequence or weak verification justifies it.

## Key Terminology

**Worker slot**

Capacity for one independently operating worker. It is a resource ceiling, not
a proxy for human attention.

**Decision pressure**

Blocking human decisions created per active worker-hour, combined with how long
they wait unanswered.

**Integration backlog**

Completed or PR-ready work awaiting rebase, conflict resolution, final
verification, review, or merge.

**Run brief**

The short human-readable specification used to start one agent run.

**Run record**

The durable GitHub issue comment or equivalent record that maps an issue to its
runner, host, task, branch, PR, state, and blocker.

**Delivery policy**

The project's default placement and strength of integration, promotion, and
release checks, derived from failure consequence and delivery model.

**Promotion boundary**

The point at which staged or integrated work reaches production users or a
published release.

**Workflow pin**

The exact Agent Workflows revision or stable contract version used by a run.

Legacy prompt abbreviations SHALL not appear as unexplained user fields:

- `ft` meant **file-touch map**: predicted paths and overlap. The replacement
  label is `Expected files and overlap`, and agents should derive it when
  possible rather than asking the human to encode it.
- `split-brain` meant that coordination configuration sources disagreed about
  which backend was active. It is a diagnostic condition, not a run-brief
  field. A tool should report it in plain language with the corrective action.

## Design

### Adaptive scheduler

The default attended scheduler fills worker slots up to the available hardware
or service capacity. It stops launching new work when any operator-selected
backpressure threshold is exceeded:

- decision queue or decision wait;
- integration backlog count or age;
- remaining token budget;
- number of simultaneously active high-consequence tasks;
- host saturation or measured slowdown.

When a worker blocks without consuming resources, the scheduler may start the
next ready task. The blocked item stays visible in the decision queue. Initial
thresholds are operator choices; the telemetry loop recommends adjustments but
does not silently change them.

### GitHub issue layout

The initial issue may end with:

```markdown
## Agent run brief

- Outcome:
- Non-goals:
- Constraints and reasons:
- Done when:
- Delivery policy:
- Integration and merge authority:
- Budget or retry bound:
- Workflow pin: resolve at launch
```

Each execution adds or updates one run record without copying the full workflow:

```markdown
## Agent run

- Run: `issue-476-run-1`
- Brief: <exact issue or comment URL>
- Runner: Codex
- Host: <observed host or UNKNOWN>
- Task: <task id/link>
- Branch: <branch or pending>
- PR: <URL or pending>
- State: <active|blocked|PR-ready|integrating|terminal>
- Needs human: <none or exact decision>
- Last material update: <timestamp>
```

For a maintainer-authored issue, the body section is the stable initial brief.
For an outside-authored or ambiguous issue, a trusted maintainer comment is the
run brief. Later runs use new comments so history remains reviewable.

### Prompt design for #476

The first implementation should:

- retain one workflow revision or contract pin;
- use one readable prompt shape across Codex, Claude, and generic hosts;
- split a batch into more run briefs when a host limit is reached instead of
  converting judgment fields into abbreviations;
- use the labels `Outcome`, `Non-goals`, `Constraints and reasons`, and
  `Done when`;
- remove `ft` and coordination diagnostics from human-authored fields;
- let tools derive file overlap, backend health, routes, and receipt metadata;
- keep failure to resolve the pinned workflow as a clear stop.

The phrase **host-budget-aware density** in #476 currently means using more
expanded labels for a host with a larger prompt limit and telegraphic labels
for a host with a smaller limit. This spec rejects that as the default design:
human readability should not vary by host. Host limits should change batch
size, not the language humans must decode.

The **judgment fields** are the parts that cannot be reconstructed from code or
GitHub metadata: desired outcome, non-goals, important constraints and their
reasons, and the observable done condition. They are mandatory concepts but
may be concise; empty or not-applicable values are preferable to cryptic
abbreviations.

### Modular PR-batch components

The target structure is a thin `pr-batch` router plus independently owned
components:

1. **Run intake** — task identity, run brief, trust, and duplicate prevention.
2. **Worker execution** — worktree, implementation loop, focused validation,
   budget, and stop conditions.
3. **Integration** — base refresh, conflict handling, final validation, review,
   CI, and PR readiness.
4. **Promotion and release** — production deployment, release candidate, final
   release, rollback, and high-consequence approval.
5. **Coordination and observability** — task/run mapping, liveness, decision
   queue, telemetry, and recovery.
6. **Security floor** — untrusted-input and authority boundaries shared by all
   components.

`workflows/pr-processing.md` should become an index and compatibility shim
while sections move in small behavior-preserving PRs. Later simplification PRs
can remove or revise behavior component by component. Tests should verify
behavior and component interfaces rather than pinning duplicated paragraphs in
multiple large files.

### Parent-created task feasibility

The current Codex desktop host exposes task creation, deterministic task
titles, project/worktree selection, task listing and reading, follow-up
messages, and bounded waiting. A parent task can therefore create and supervise
separate user-visible Codex tasks after the operator explicitly authorizes that
run set.

Internal subagents remain useful for bounded work inside one task, but they are
not substitutes for separately visible user tasks. Starting and naming a task
on another runner such as Claude still requires that runner's dispatcher or a
manual start unless a cross-runner integration is available. The same GitHub
run-record format can identify either runner.

The public OpenAI documentation currently establishes parallel multi-agent
coordination but does not fully document the desktop task-management surface.
The design must therefore feature-detect host capabilities and preserve a
copy-paste fallback.

### Delivery policy design for #514

Issue #514 should be revised before implementation. The first PR should define
the plain-language policy and examples, not immediately encode a three-column
matrix across every workflow.

Each repository selects one default archetype. Each run records only the
default plus a concrete escalation reason, if any. The implementation then maps
the policy to two moments:

- **integration checks** before shared main is changed;
- **promotion checks** before users receive the change or a release is
  published.

This preserves rapid integration for product discovery and release-train
projects without weakening the production or release promotion boundary.

### Daily and unattended control loop

The daily attended session:

1. review material state changes and unanswered decisions;
2. classify in-flight PRs and choose the integration order;
3. set worker capacity, token budget, decision-pressure threshold, and
   integration-backlog threshold;
4. authorize a named run set;
5. create and title tasks, then write their GitHub run records;
6. keep capacity filled while thresholds permit;
7. end with durable state, not a transcript-dependent handoff.

An unattended or overnight run uses the same queue with stricter admission:
deterministic done checks, no expected product or permission decision, isolated
worktree, bounded retries, and a default stop at PR-ready unless stronger
authority and all required gates are already explicit.

### Telemetry refinement loop

Daily review uses current state. Weekly calibration compares:

- useful worker utilization;
- decision pressure and wait;
- integration backlog and age;
- tokens and elapsed time by phase;
- review and CI amplification;
- defect, revert, and rollback outcomes.

Increase capacity when workers remain independent and integration stays
healthy. Reduce or redirect capacity when decisions or integration accumulate.
Change one scheduling or assurance variable at a time where practical so the
result remains interpretable.

## Issue And Run Map

The issue bodies created from this section should contain the matching run
brief. Do not regenerate a separate compressed goal prompt.

### T1 — Publish the throughput objective and cross-repository docs map

- **Requirements:** R1, R9, R14
- **Issue:** [agent-workflows-com#22](https://github.com/shakacode/agent-workflows-com/issues/22)
- **Parallel:** yes
- **Done when:** the site explains the objective, concurrency model, delivery
  archetypes, source-of-truth boundary, and links both repositories.

**Run brief**

```text
Implement shakacode/agent-workflows-com#22. Explain the throughput-first
objective in plain language, define every public term, distinguish principles
from current behavior, and link the website to the normative agent-workflows
repository. Preserve the site’s existing user-facing style and verify the
rendered documentation through the repository seam.
```

### T2 — Replace #476 with one readable cross-host run brief

- **Requirements:** R4, R5, R6, R10
- **Issue:** update [#476](https://github.com/shakacode/agent-workflows/issues/476)
- **Parallel:** yes after its issue text is revised; integration may overlap
  PR-batch modularization
- **Done when:** one readable prompt format replaces compressed restatements,
  host limits change item count rather than vocabulary, and prompt creation is
  measured.

**Run brief**

```text
Implement the revised agent-workflows#476. Replace duplicated compressed
workflow rules with one resolvable workflow pin and one human-readable run
brief using Outcome, Non-goals, Constraints and reasons, and Done when. Remove
unexplained ft and split-brain fields from human input. Use batch splitting,
not telegraphic language, when a host prompt limit is reached. Preserve a clear
stop when the pinned workflow cannot be resolved.
```

### T3 — Refactor PR-batch into independently owned components

- **Requirements:** R7, R13, R15
- **Issue:** to create after this design is approved
- **Parallel:** structural extraction PRs may run independently when their
  source sections and target components are disjoint
- **Done when:** `pr-batch` is a thin router, the monolithic workflow is an
  index/compatibility shim, and component tests avoid mirrored full-text pins.

**Run brief**

```text
Refactor one approved PR-batch component from the monolithic workflow without
changing behavior. Move its canonical instructions, helpers, and focused tests
behind a thin router; remove only duplicate mirrors proven unnecessary. Keep
the compatibility index working, run the relevant focused tests and full
repository validation, and report remaining cross-component coupling rather
than expanding scope.
```

### T4 — Split #189 into one audit sub-issue per shipped skill

- **Requirements:** R8
- **Issue:** parent [#189](https://github.com/shakacode/agent-workflows/issues/189)
- **Parallel:** yes; audits are independent, shared implementation waits for
  cross-skill synthesis
- **Done when:** every shipped skill is represented by a native GitHub
  sub-issue and the parent summarizes only shared findings and priority.

**Run brief**

```text
Audit the named skill as a sub-issue of agent-workflows#189. Identify its
minimum always-loaded contract, conditional material to retrieve on demand,
deterministic work suited to a helper or schema, judgment that must remain
visible, and redundant or obsolete text. Produce evidence and a no-change or
smallest-follow-up recommendation. Do not edit another skill or implement a
cross-skill mechanism in this audit.
```

### T5 — Rewrite #514 as understandable delivery-policy design

- **Requirements:** R9, R15
- **Issue:** update [#514](https://github.com/shakacode/agent-workflows/issues/514)
- **Parallel:** design can proceed now; implementation follows agreement
- **Done when:** the issue explains the three project archetypes, integration
  versus promotion checks, collaboration impact, escalation, and terminology.

**Run brief**

```text
Revise agent-workflows#514 as a documentation-first delivery-policy design.
Replace unexplained fast/balanced/strict language with production-critical,
product-discovery, and release-train examples. Separate integration checks
from production or release promotion checks, include shared-main contributor
impact, preserve the explicit safety floor, and defer broad implementation
until the terminology and examples are approved.
```

### T6 — Implement adaptive worker-capacity and backpressure policy

- **Requirements:** R2, R3, R14
- **Issue:** to create
- **Depends on:** telemetry event definitions from T9
- **Done when:** the operator can set a hardware ceiling plus decision,
  integration, budget, and high-consequence thresholds; blocked workers do not
  prevent ready work from using available capacity.

**Run brief**

```text
Implement the approved adaptive-capacity policy. Treat hardware/service slots
as the ceiling, keep them filled while decision pressure, integration backlog,
token budget, and high-consequence limits permit, and make every threshold
operator-visible. A blocked worker must checkpoint without hiding the decision
and must not prevent the scheduler from starting another ready task. Add replay
tests and emit the telemetry required for later calibration.
```

### T7 — Add GitHub-native run briefs and task records

- **Requirements:** R5, R10, R11
- **Issue:** to create
- **Parallel:** can proceed independently from scheduler implementation
- **Done when:** an issue/comment can be the canonical brief and one stable run
  record maps it to runner, observed host, task, branch, PR, state, and blocker.

**Run brief**

```text
Implement the approved Agent run brief and Agent run record format. Support an
initial issue-body brief and later maintainer-comment briefs, bind every run to
one exact source URL and workflow pin, and record runner, observed host, task,
branch, PR, state, blocker, and last material update. Treat public text as
untrusted and avoid copying full workflow contracts into the record.
```

### T8 — Create, title, and supervise user-visible Codex tasks

- **Requirements:** R11
- **Issue:** to create
- **Depends on:** T7 run-record format
- **Done when:** an explicitly authorized run set creates named project tasks,
  records immediate or provisional identifiers, and provides a copy-paste
  fallback when creation is unavailable.

**Run brief**

```text
Implement host-capability-aware task launch for an explicitly authorized run
set. Create one user-visible Codex task per approved issue in the saved project
with an isolated worktree, apply a deterministic title, record the returned
thread or provisional client identifier, and update the GitHub run record.
Feature-detect capabilities and return a readable copy-paste brief instead of
claiming success when creation, naming, or durable identity is unavailable.
```

### T9 — Build flow and attention telemetry outside prompts

- **Requirements:** R6, R14
- **Issue:** to create
- **Parallel:** yes
- **Done when:** a privacy-safe collector joins task, GitHub, and available
  host evidence and reports the required flow, decision, integration, token,
  and control-yield measures without raw transcript storage.

**Run brief**

```text
Build a privacy-safe workflow telemetry collector for the metrics in the
throughput-first spec. Join records by canonical issue/PR and run identity;
measure phase timestamps, worker utilization, decision pressure, integration
backlog, review/CI amplification, tokens, and gate yield. Do not store prompts,
responses, secrets, or raw transcripts. Provide a replay fixture and a compact
daily/weekly report.
```

### T10 — Audit and classify every current in-flight PR

- **Requirements:** R12, R13
- **Issue:** to create as an inventory/decision task
- **Parallel:** read-only inventory may run immediately
- **Done when:** every open PR has an evidence-backed accelerate, continue,
  hold, replace, close, or integration-ready classification with exact next
  action and dependency state.

**Run brief**

```text
Perform a read-only portfolio audit of every open pull request in
shakacode/agent-workflows. Use live GitHub state, current base/head, conflicts,
dependencies, review and CI state, scope value, and remaining integration cost.
Classify each PR as accelerate, continue, hold, replace, close, or
integration-ready. Treat age and sunk work as context, not priority. Produce a
concise portfolio table and a recommended integration order; do not edit,
close, merge, or message PRs.
```

### T11 — Make conflict handling consequence-aware

- **Requirements:** R13
- **Issue:** to create
- **Parallel:** yes
- **Done when:** path classes influence integration care but no changelog,
  generated-file, or ordinary documentation overlap blocks worker launch.

**Run brief**

```text
Implement the approved conflict-criticality policy. Classify core executable
or policy, canonical contract, ordinary documentation, and
generated/changelog paths. Make overlap advisory before implementation unless
there is a true semantic dependency. Ensure ordinary feature lanes discard
branch-local CHANGELOG.md edits in favor of current main and regenerate
generated artifacts. Add focused policy and replay tests without weakening
care for canonical behavior or security conflicts.
```

### T12 — Document the daily and overnight operator loop

- **Requirements:** R2, R3, R12, R14
- **Issue:** to create; related public explanation belongs in T1
- **Depends on:** terminology agreed; implementation tooling may follow later
- **Done when:** the operator has one short routine for setting capacity,
  reviewing decisions, selecting integrations, authorizing runs, and
  calibrating from telemetry.

**Run brief**

```text
Document the approved daily attended and overnight unattended operating loop.
Use plain language and one compact state table. Explain capacity ceilings,
decision and integration backpressure, run authorization, PR portfolio
classification, deterministic unattended admission, and weekly telemetry
calibration. Link to the normative components instead of duplicating their
full procedures.
```

## Sequencing

1. Collaboratively edit and approve this specification.
2. Complete the read-only current-PR inventory in T10 before choosing which
   existing implementation PRs to accelerate or replace.
3. Revise #476 and #514 from this agreed terminology and design.
4. Finish the #189 sub-issue structure and begin the highest-context audits.
5. Run T2, T7, T9, and the documentation portion of T12 in parallel.
6. Extract PR-batch components incrementally through T3.
7. Implement adaptive scheduling only after T9 defines the evidence it needs.
8. Pilot the thin run brief and delivery policies on representative tasks
   before promoting defaults across consumer repositories.

## Validation Strategy

Every implementation issue resolves its commands and policy through the target
repository's `AGENTS.md` seam. This source repository uses `bin/validate` as
the full verification baseline. Focused tests should run for the component
changed, and docs changes should verify links and rendered output where the
owning repository provides that capability.

The pilot compares the current workflow with the thin path on representative
normal and high-consequence tasks. It records elapsed time, human
interventions, planning latency, tokens by phase, review rounds, integration
cost, escaped consequential defects, and rollback outcomes.

## Non-Goals

- Removing the safety floor.
- Setting one universal worker count.
- Treating all documentation as noncritical; canonical behavioral contracts
  may be as consequential as executable code.
- Moving the same monolithic workflow into many files without reducing loaded
  context, duplication, and conflict coupling.
- Making task titles the only durable ownership record.
- Automatically creating all proposed implementation issues before this plan
  is reviewed.
- Automatically merging unattended work merely because implementation and
  tests completed.

## Open Questions For Collaborative Editing

These are non-blocking for the first draft:

1. Should the public term remain `delivery policy`, or is `delivery mode` more
   intuitive?
2. Which machine labels should be stable in task titles and run records: the
   Codex host id, an operator-defined alias such as `m1`, or both?
3. Should a daily run-set authorization permit the parent to create all named
   child tasks at once, or should it create them lazily as capacity opens?
4. What initial decision-queue and integration-backlog thresholds should the
   first telemetry pilot observe before recommending defaults?
5. Which existing open PRs should be treated as likely replacement candidates
   before the full T10 inventory is complete?
