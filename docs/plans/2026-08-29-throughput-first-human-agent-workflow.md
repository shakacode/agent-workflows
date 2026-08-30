# Throughput-First Human-Agent Workflow Redesign

> **Status:** Revised after maintainer review on 2026-08-30. This is the
> working specification and execution map. It does not change workflow behavior
> by itself.

## Governing Objective

> Maximize valuable, verified software changes per unit of human attention,
> elapsed time, and tokens—subject to a small explicit safety floor.

This objective is more important than every mechanism proposed below. When two
requirements conflict, choose the path that better serves this objective unless
it would cross the explicit safety floor.

The immediate priority is stabilization and simplification. We already have
enough experience to know the current workflow is too slow and brittle. We will
make changes, use them in real work, record directional telemetry, and refine
from experience. We will not delay stabilization to build an adaptive scheduler
or a controlled comparison with the old workflow.

The explanatory website tracks the objective in
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
- The canonical goal prompt used about 3,630 characters for 38 compressed lines
  before substantial task-specific detail was filled in.
- A documentation-only change ran the repository validation matrix for more
  than 20 minutes locally. One one-second timeout failed under load and passed
  six consecutive isolated reruns; hosted validation later passed.
- A live monitoring routine correctly stayed silent when nothing had changed
  and later caught a stale review against a newer PR head. Silence with a
  durable dedup state can therefore be successful execution.
- One GitHub tool request returned a 672 KB pull-request payload before the
  agent recovered from a spilled file. Compact, field-selected queries should
  be the default.

These observations establish a credible throughput problem. They do not prove
that every safety control is unnecessary.

## Requirement Priorities

- **P0 — Governing:** R1 and R15.
- **P1 — Stabilize now:** R3 through R8 and R10 through R13.
- **P2 — Learn from use:** R9 and R14.
- **Deferred optimization:** automated scheduling in R2.

## Requirements

### R1 — Throughput objective (P0)

The workflow SHALL optimize valuable verified outcomes per unit of human
attention, elapsed time, and tokens. Mechanism count, prompt density, receipt
count, and worker count are not success measures by themselves.

### R15 — Small explicit safety floor (P0)

Every project SHALL preserve:

- untrusted-input handling;
- no direct push to the protected base branch;
- a worktree or equivalent isolated checkout for concurrent implementation;
- an observable validation result appropriate to the changed behavior;
- proof that merge-time reviews and checks apply to the exact PR commit being
  merged;
- explicit authority for destructive, security-sensitive, production, or
  release actions;
- refusal of contradictory live ownership when reliable coordination evidence
  is available.

Bookkeeping, coordination, or telemetry failures SHALL have a simple visible
override so they do not stall all work. An override cannot grant missing merge,
production, release, security, or destructive-action authority and cannot
bypass a failing correctness check.

### R3 — Human attention and unattended work (P1)

Planning SHALL resolve material product, design, and architecture decisions as
early as practical. Agents SHALL not interrupt the human for bookkeeping or
routine implementation choices such as expanding the number of files edited.

When the human is unavailable, an agent SHOULD continue with reversible best
judgment and queue concise questions for later. It SHALL stop only when a
missing answer changes the intended outcome, crosses the safety floor, or would
cause a difficult-to-reverse external action.

The operator SHALL be able to declare an attention interval such as “I am
unavailable for six hours.” Work should be selected and prompted to maximize
independent progress during that interval. A blocked worker records a visible
stopped state. If the host can release or replace its slot, the next ready task
may use it; if it cannot, the run record must say that capacity remains occupied
rather than pretending replacement occurred.

The operator SHOULD be able to request the next highest-priority queued
decision. Code walkthroughs SHOULD prepare all conceptual sections in advance
and present them one at a time, accepting that later prepared sections may be
discarded if an earlier discussion sends the work back to development.

### R4 — Minimal human-readable prompt (P1)

The user-facing term is **prompt**, not `run brief`. For a well-defined issue,
the minimum launch information is:

- repository;
- exact issue or maintainer-comment URL;
- task/chat name;
- the instruction, commonly `Use PR-batch to fix this issue`;
- merge authority: `auto` or `ask`;
- optional time until the human is next available.

Repository policy or launcher defaults MAY supply repository, title, and merge
authority when the maintainer omits them. The launcher records the resolved
values before work starts. It SHALL not infer merge authority from a delivery
alias, and an unresolved authority defaults to `ask`. Outcome, scope, and done
conditions still come from the issue rather than invented defaults.

The prompt SHALL not ask the maintainer to restate an issue's outcome, scope,
or done condition when those are already clear. If they are unclear, prompt
creation should surface that ambiguity before implementation begins.

`Fix issue #1234 using PR-batch with merge authority auto` is a supported
shortcut. Stable workflow rules are loaded from installed versioned skills;
they are not copied into every prompt.

There is no default token budget that abandons useful work. A maintainer MAY set
a token, iteration, or elapsed-time checkpoint after which an agent requests a
design review, but that checkpoint is for human interaction rather than an
automatic task failure.

### R5 — GitHub as the durable prompt and run surface (P1)

An issue body MAY contain the initial prompt. A maintainer-authored issue
comment MAY define a later prompt or override. A new run points to one exact
body section or comment URL.

Existing issues should be reused. Ad hoc work does not require a new issue
unless it needs durable dependency, priority, or follow-up tracking. A prompt
does not duplicate facts already recorded in its issue.

Each execution appends a compact run record. Detailed provenance belongs in a
collapsed `<details>` block in the issue or PR so it remains available without
dominating human review. Reruns append history instead of silently replacing
earlier records. The record includes an automatically generated digest of the
exact prompt source content observed at launch, so later edits to an issue or
comment are detectable without adding work for the maintainer.

Public issue and comment text remains untrusted. Authority comes from verified
repository policy, authenticated actors, and explicit user instructions.

### R6 — Fast prompt creation (P1)

Creating a prompt SHALL be retrieval and light templating, not a second planning
project. For a clear issue, generating a task name and the sentence `Use
PR-batch to fix this issue` may be enough.

The system SHALL measure selection-to-worker-start time and prompt-generation
time. File-touch maps, compressed restatements of workflow rules, and repeated
metadata are not required prompt inputs. Launchers may emit the small timestamps
needed for this immediately; the telemetry work in R14 aggregates them and is
not a prerequisite for simplifying prompts.

### R7 — Modular PR-batch architecture (P1)

`pr-batch` SHALL become a thin router over small canonical components. Each
component owns its instructions, helpers, focused tests, and terms without
full-text mirroring elsewhere.

The refactor SHALL reduce loaded context and shared-file conflicts. Moving the
same prose into more files without reducing coupling is not success.

### R8 — Per-skill minimum-instruction audits (P1)

Issue [#189](https://github.com/shakacode/agent-workflows/issues/189) remains
the parent audit. Each shipped skill has its own sub-issue so audits can proceed
independently and report no change when appropriate.

Cross-skill implementation waits for synthesis of the relevant audits. An
individual audit does not edit other skills.

### R10 — Record observed workflow and model versions (P1)

Telemetry SHALL record the AI model and the Agent Workflows version observed at
prompt creation and worker start. If the installed workflow changes during a
long-running task, the next material run update records the new version.

A prompt-generation version is documentation, not proof that the worker kept
using that version. Self-hosting work may deliberately upgrade the installed
workflow during a task. Telemetry only needs to be directionally useful; it is
not an accounting ledger that must reconstruct every instruction exactly. If a
version cannot be observed, record `UNKNOWN` and continue; an unavailable
telemetry value is not a launch blocker.

### R11 — Parent-created, named, traceable tasks (P1)

When the operator authorizes a run set, a parent Codex task MAY create separate
user-visible tasks, select the saved project and worktree, give each task a
deterministic title, and monitor its state.

A title SHALL identify the repository, issue, and purpose. Runner and observed
machine are recorded separately, using operator-defined aliases such as `M1`
and `M5` when configured.

Each task is traceable from GitHub through a run record containing runner,
observed host, task identifier or link, branch, PR, state, latest material
update, and any meaningful blocking decision. The workflow and model versions
belong in the collapsed details.

Before creating a task, the launcher appends a `launch-pending` record with a
globally unique run ID and idempotency key. A retry reuses that record rather
than creating a duplicate task. After task creation, the launcher attaches the
host task ID and advances the same run. If the durable write path is unavailable,
a visible single-operator or no-backend override may proceed without turning a
bookkeeping failure into a global stall; it must preserve the run ID locally
and report that GitHub reconciliation remains due.

Run state and outcome are separate. State uses a small useful vocabulary such
as `launch-pending`, `active`, `waiting`, `blocked`, `PR-ready`, and `completed`.
Outcome is `pending` until it can be recorded as `merged`, `closed`, `failed`,
or `reverted`. A completed worker that is waiting for integration therefore
does not disappear into an ambiguous terminal state. The normal progression is
`launch-pending` to `active`, optionally through `waiting` or `blocked`, then to
`PR-ready` or `completed`; resumed work returns to `active` and never rewrites
the earlier history.

### R12 — In-flight portfolio control (P1)

The project SHALL periodically inventory open PRs and active tasks, classifying
each as accelerate, continue, hold, replace, close, or integration-ready.

Classification uses current live state, value, explicit semantic dependencies,
conflicts, remaining work, and expected integration cost. Age and sunk tokens
are context, not priority. Every run refreshes current base/head and dependency
state rather than relying on yesterday's artifact.

### R13 — Explicit dependencies; consequence-aware conflicts (P1)

Semantic dependencies and incompatible design choices SHALL be documented in
the related issues. They SHALL not be inferred merely because two tasks may
edit the same file.

File overlap does not block concurrent development. Repeated overlap is a
signal to split monolithic files and interfaces. Integration handles ordinary
text conflicts later.

Conflict care follows consequence:

1. executable, schema, security, or merge-policy conflicts;
2. canonical workflow-contract conflicts;
3. user documentation and examples;
4. generated artifacts and changelog.

This repository's `AGENTS.md` seam makes `CHANGELOG.md` nonblocking for ordinary
work: ordinary PRs keep the current-base changelog and discard branch-local
edits. The portable workflow SHALL expose a repository policy seam for defer,
waive, or dedicated ownership rather than imposing that choice on every
consumer. Repository policy likewise decides whether generated artifacts are
regenerated or require careful review. Ordinary documentation conflicts are
normally resolved during integration unless repository policy marks them as
canonical or executable.

### R9 — Simple delivery policy, detailed design later (P2)

For now, repositories MAY use familiar aliases with plain-language meanings:

- **fast** — package or open-source release work that integrates quickly and
  concentrates broader checks before publishing a package, release candidate,
  or final release;
- **balanced** — a live product-discovery service that moves quickly before
  product-market fit while retaining an explicit production promotion gate;
- **strict** — a production-critical service where failure affects many users
  or business operations.

The repository-level policy accounts for both project type and the number of
collaborators affected by a bad main branch. This belongs in the repository
`AGENTS.md` seam at the same level as other workflow policy.

Merge authority remains the only ordinary per-task authority choice: `auto` or
`ask`. Delivery policy chooses which checks apply; it does not grant permission
to merge, deploy, or release. Production and release actions require their own
explicit authority outside the ordinary task prompt.

The final taxonomy and per-change overrides require more discussion. In the
near term, agent-workflows favors a progress-oriented stabilization setting
while preserving R15.

### R14 — Directional telemetry from real work (P2)

Telemetry SHOULD collect, when available:

- prompt creation and selection-to-start time;
- AI model and observed Agent Workflows versions;
- time to first PR, PR-ready, integration start, and merge;
- human questions, reason, queue time, and response latency;
- uninterrupted worker time and stopped/occupied slots;
- tokens by broad phase;
- review, CI, retry, and rebase amplification;
- integration backlog and conflict-resolution time;
- consequential defects, reverts, and rollbacks.

Telemetry SHALL avoid raw transcripts, prompts, responses, and secrets. Queries
should select compact fields and avoid loading whole pull-request inventories
when a small CLI or API response is sufficient.

The data is for broad directional decisions. We will refine from live work
without requiring controlled experiments or one-variable-at-a-time changes.

### R2 — Simple concurrency now; adaptive scheduling later

The operator chooses a target number of concurrent tasks. The system starts
ready work up to that target and the host's actual capacity. Trial and error
will reveal practical machine limits.

We will not predict decision pressure or task duration before launch, and we
will not build adaptive thresholds yet. First collect telemetry and improve the
workflow without a scheduler. A future scheduler may be proposed only after the
simple model is stable and observed limitations justify it.

## Plain-Language Terminology

**Prompt**

The short human-readable instruction that starts one task. The issue usually
contains the details, so the prompt often points to it.

**Run record**

The durable GitHub record mapping an issue to runner, machine, task, branch,
PR, state, and meaningful blocker.

**Worktree**

A separate Git checkout used so concurrent tasks do not edit the same working
directory.

**Exact-head evidence**

Proof that reviews and checks apply to the exact PR commit being merged. This
does not always mean rebasing onto the latest default branch; base freshness and
conflict policy are separate checks.

**Non-goal**

Something deliberately excluded from a task. It is not a required prompt field
when the issue is already clear.

**Workflow version**

The Agent Workflows revision observed at a particular moment. A recorded prompt
version does not freeze an independently installed runtime.

## Initial Operating Design

### Human-attention queue

Before work starts, ask only about material ambiguity in outcome, design, or
architecture. During work:

1. continue through reversible implementation choices;
2. record meaningful questions without stopping when a safe best guess exists;
3. stop for missing authority, an outcome-changing choice, or an irreversible
   external action;
4. let the human request the next highest-priority question when available.

Question telemetry records the category so recurring inane interruptions can
be removed from the workflow.

### GitHub prompt and run record

For a clear issue, the visible prompt may be:

```text
Repository: shakacode/agent-workflows
Work item: https://github.com/shakacode/agent-workflows/issues/476
Task name: AW #476 — Simplify cross-host prompts
Instruction: Use PR-batch to fix this issue against current main.
Merge authority: ask
Human available after: 6 hours
```

The equivalent shortcut is:

```text
Fix agent-workflows#476 using PR-batch with merge authority ask. Use current
main, title the task `AW #476 — Simplify cross-host prompts`, and continue with
reversible best judgment while I am unavailable for six hours.
```

Each execution appends compact visible state and collapses detail:

```markdown
Agent run: Codex on M5 — active — <task link>

<details>
<summary>Run details</summary>

- Run ID: <ULID or host-generated globally unique ID>
- Idempotency key: <stable key reused by launch retries>
- Prompt: <exact issue or comment URL>
- Prompt digest: <SHA-256 of the exact source content observed at launch>
- Runner and model: <observed values>
- Machine: <configured alias or observed host>
- Workflow at prompt creation: <version or UNKNOWN>
- Workflow observed by worker: <version or UNKNOWN>
- Branch and PR: <values or pending>
- Resolved merge authority: <auto or ask>
- State: <launch-pending, active, waiting, blocked, PR-ready, or completed>
- Outcome: <pending, merged, closed, failed, or reverted>
- Promotion/release authority: <not granted or separately authorized reference>
- Last material update: <timestamp>
- Needs human: <none or one meaningful decision>

</details>
```

### Prompt design for #476

The first implementation should:

- support the one-line `Fix issue … using PR-batch` shortcut;
- derive repository, issue identity, current main, and task title when possible;
- use an issue body or maintainer comment as the detailed prompt;
- use one readable shape across Codex, Claude, and generic hosts;
- remove file-touch maps, abbreviated file-touch inputs, ad hoc coordination
  diagnostics, and compressed workflow
  restatements, token-abandonment budgets, and redundant outcome fields from
  normal human input;
- record the launch source digest and lightweight timing at the launcher without
  waiting for the telemetry aggregation task;
- record both prompt-generation and worker-observed workflow versions;
- preserve append-only rerun history in collapsed details;
- prefer compact `gh` or field-selected API queries;
- resolve current live state at launch. In particular, #476 is now unblocked
  after #479 and #486 merged, and work must use their current-base result rather
  than a pre-cut artifact from before those merges.

Host prompt limits should change batch size, not force telegraphic vocabulary.

### Modular PR-batch components

The target is a thin router plus independently owned components:

1. **Prompt intake** — task identity, trust, shortcut expansion, and duplicate
   detection that never becomes a global stall.
2. **Worker execution** — worktree, implementation loop, focused validation,
   meaningful stop conditions, and human-attention queue.
3. **Integration and PR closeout** — current base/head, conflict handling,
   final validation, review, CI, and merge readiness.
4. **Production and release** — a separate downstream lifecycle for deployment,
   release candidates, publishing, rollback, and high-consequence approval. It
   is not part of ordinary feature implementation.
5. **Optional coordination and observability** — task mapping, liveness,
   telemetry, and recovery. Core work remains usable without this component.
6. **Security floor** — the small shared R15 boundary.

`workflows/pr-processing.md` becomes an index and compatibility shim while
sections move through small behavior-preserving PRs. Later simplification removes
obsolete behavior component by component. Tests verify interfaces and behavior,
not duplicated paragraphs.

### Parent-created tasks

The current Codex desktop host can create, title, list, read, message, and wait
on separately visible tasks. A parent task can therefore launch an authorized
run set. Claude requires its own dispatcher or a copy-paste prompt.

Every task starts by re-reading current GitHub state. A task with an unmet
semantic dependency should use a task heartbeat or bounded, backed-off checks
for up to the operator's unattended interval. It must not busy-poll, hold a
working-tree lock, or ask the human merely because its dependency is still
open.

The parent writes the unique `launch-pending` run record before task creation,
then updates that same record with the created task ID. This small launch fence
prevents a timeout or retry from silently creating duplicate workers while
retaining the explicit no-backend override described in R11.

### Daily and unattended loop

The attended session:

1. review material state changes and ask for the next highest-priority queued
   decision;
2. classify in-flight PRs and choose likely integration order;
3. choose a simple target number of concurrent tasks and the next human
   availability time;
4. authorize a named run set;
5. launch tasks and write their GitHub run records;
6. use easy overrides for broken accounting or coordination;
7. leave durable state rather than a transcript-only handoff.

An unattended run favors clear issues, reversible work, worktrees, and
observable done checks. It normally stops at PR-ready unless merge authority is
`auto`. Production and release actions require separate explicit authority.

### Refinement loop

Use real work immediately. Daily review uses current state; periodic review
looks for prompt latency, recurring low-value questions, stalled capacity,
integration accumulation, review/CI amplification, and consequential defects.
Adjust simple configuration and workflow wording first. Consider automation
only after repeated evidence shows the simple process is insufficient.

## Issue And Prompt Map

All prompts use current live GitHub state and current main. Tasks may start
simultaneously. When a documented semantic dependency is not ready, the task
records `waiting`, uses a task heartbeat or backed-off checks for up to six
hours, and proceeds when the dependency changes without asking the maintainer.

### T1 — Publish the objective and cross-repository docs map

- **Issue:** [agent-workflows-com#22](https://github.com/shakacode/agent-workflows-com/issues/22)
- **Start:** now; no dependency.

```text
Implement shakacode/agent-workflows-com#22. Explain the governing objective in
plain language, define public terms, distinguish principles from current
behavior, and link the website to the normative agent-workflows repository.
```

### T2 — Simplify #476 prompts

- **Issue:** [#476](https://github.com/shakacode/agent-workflows/issues/476)
- **Start:** now; no dependency.

```text
Fix agent-workflows#476 using PR-batch with merge authority ask. Use current
main after #479 and #486, title the task `AW #476 — Simplify cross-host
prompts`, and continue with reversible best judgment for six hours. Make the
issue or maintainer comment the readable prompt, support the one-line shortcut,
remove file-touch maps and compressed restatements, and record actual model and
workflow versions without treating telemetry as exact accounting. Emit the
cheap launch timestamps directly; do not wait for #562's aggregation work.
```

### T3 — Modularize PR-batch

- **Issue:** [#559](https://github.com/shakacode/agent-workflows/issues/559),
  followed by one implementation sub-issue per extracted component.
- **Start:** architecture and coupling inventory now. Extraction PRs wait for
  the architecture issue's component boundaries.

```text
Define and begin the smallest behavior-preserving modularization of PR-batch.
Use the component boundaries in PR #558, inventory current coupling, create one
implementation issue per approved component, and extract only one component in
this task. Keep workflows/pr-processing.md as an index and compatibility shim,
avoid cross-component cleanup, and use focused validation before the full gate.
If PR #558 is not final, poll its current review state with backed-off checks
for up to six hours while completing the read-only coupling inventory.
```

### T4 — Audit every shipped skill under #189

- **Issue:** parent [#189](https://github.com/shakacode/agent-workflows/issues/189)
- **Start:** all skill audits may start now and run independently.

```text
Audit the one skill named by this #189 sub-issue. Identify the minimum material
that must always load, content that can be retrieved only when needed,
deterministic work suited to a helper or schema, necessary visible judgment,
and obsolete or duplicated text. Comment with evidence and a no-change or
smallest-follow-up recommendation. Do not edit files or another skill, and do
not implement a shared mechanism from this audit.
```

### T5 — Clarify #514 without broad implementation

- **Issue:** [#514](https://github.com/shakacode/agent-workflows/issues/514)
- **Start:** now; terminology remains explicitly provisional.

```text
Revise agent-workflows#514 as a short documentation-first design. Explain fast,
balanced, and strict as aliases for package/release work, product discovery,
and production-critical services. Put project type and collaborator impact in
the repository AGENTS.md seam. Keep merge authority as the separate per-task
auto-or-ask choice, preserve explicit production/release authority, and defer
the final taxonomy and broad implementation until stabilization produces more
evidence.
```

### T6 — Adaptive scheduler

- **State:** parked. Do not create or start an implementation issue yet.
- **Resume when:** the simple concurrency setting is stable and telemetry shows
  a repeated problem that automation can solve.

### T7 — GitHub prompts and run records

- **Issue:** [#560](https://github.com/shakacode/agent-workflows/issues/560).
- **Start:** now for schema and examples; implementation waits for the relevant
  #476 prompt decisions.

```text
Design the minimal GitHub prompt and append-only run-record format from PR #558.
Use issue bodies or maintainer comments, the one-line PR-batch shortcut,
deterministic task names, and collapsed details for provenance. Keep visible
state compact and make coordination optional. Include a globally unique run ID,
source-content digest, observed workflow versions, separate state and outcome,
and append-only rerun history. If #476 prompt decisions are not final, poll
GitHub with backed-off checks for up to six hours, then implement only the
agreed format with focused tests.
```

### T8 — Create, title, and supervise Codex tasks

- **Issue:** [#561](https://github.com/shakacode/agent-workflows/issues/561).
- **Start:** capability inventory now; implementation waits for T7's stable run
  record shape.

```text
Implement host-capability-aware launch for an authorized run set. Create one
user-visible Codex task per approved issue in a worktree, use a deterministic
repository/issue/purpose title, and append its task, runner, machine, branch,
and PR state to GitHub. Before task creation, persist a `launch-pending` record
with a globally unique run ID and idempotency key; retries must reuse it. Provide
a visible no-backend override and a copy-paste fallback for unsupported hosts.
If the T7 run-record format is not ready, poll its issue with backed-off checks
for up to six hours while completing the read-only capability inventory.
```

### T9 — Collect directional workflow telemetry

- **Issue:** [#562](https://github.com/shakacode/agent-workflows/issues/562).
- **Start:** now; no scheduler dependency.

```text
Implement the smallest privacy-safe telemetry path that can report prompt and
start latency, model, observed workflow versions, broad phase times, human
questions, stopped slots, review/CI amplification, integration time, and
consequential outcomes. Prefer compact gh or field-selected API queries. Do not
store raw prompts, responses, transcripts, or secrets, and do not build an
adaptive scheduler or controlled-experiment framework.
```

### T10 — Classify current in-flight PRs

- **Issue:** [#563](https://github.com/shakacode/agent-workflows/issues/563).
- **Start:** now; read-only.

```text
Perform a read-only live portfolio audit of every open pull request in
shakacode/agent-workflows. Refresh current base/head, conflicts, explicit issue
dependencies, review and CI state, value, and remaining integration cost.
Classify each PR as accelerate, continue, hold, replace, close, or
integration-ready and recommend an integration order. File overlap alone is
not a dependency. Do not edit, close, merge, or message PRs.
```

### T11 — Simplify conflict and dependency handling

- **Issue:** [#564](https://github.com/shakacode/agent-workflows/issues/564).
- **Start:** now; no dependency.

```text
Implement the PR #558 conflict policy: issue-authored semantic dependencies,
file overlap advisory only, this repository's changelog deferral rule, and
ordinary documentation conflicts deferred to integration. Expose a repository
policy seam for changelog and generated-artifact handling instead of imposing a
universal relaxation. Add a simple override for broken bookkeeping or
coordination without weakening merge, security, production, release, or
correctness gates. Keep the change small and add focused deterministic tests.
```

### T12 — Document the daily and overnight loop

- **Issue:** [#565](https://github.com/shakacode/agent-workflows/issues/565).
- **Start:** now; document the simple process, not a scheduler.

```text
Document the daily attended and overnight unattended loop from PR #558. Cover
the operator-set concurrency target, next human availability time, meaningful
decision queue, dependency-aware task waiting, GitHub task records, live PR
portfolio review, and easy non-safety overrides. Use one compact state table and
plain language. Do not design adaptive thresholds or require a comparison
pilot.
```

## Launch Order

Create and prompt T1, T2, T3, every T4 audit, T5, T7, T8, T9, T10, T11, and
T12 at the same time so every authorized task is visible and traceable. Begin
active execution only up to the operator's target and the host's actual
capacity. A host that queues tasks may create the whole set immediately without
claiming every task is consuming an active worker slot. A host without a
separate queue treats its creation limit as the capacity limit.

Each prompt states what can proceed immediately and what must wait for a
documented GitHub dependency. A dependency-waiting task completes independent
preparation first, then yields or releases its active slot when the host supports
that behavior. T6 is deliberately parked.

No task should use file overlap as a launch blocker. No task should ask the
maintainer for routine scope expansion while the six-hour unattended interval
is active.

## Validation Strategy

Validate the changed behavior through the target repository's `AGENTS.md` seam.
Run focused checks during implementation and the full repository gate before
publication or merge when policy requires it. Record gate time and failures as
telemetry, but do not make every worker wait for unrelated full-suite checks
before useful implementation begins.

We will use the new workflow on real work immediately and refine from observed
outcomes. A separate comparison pilot is not required.

## Deferred Decisions

These do not block the initial execution wave:

1. Final delivery-policy terminology and per-change overrides.
2. Automated concurrency thresholds or slot-replacement scheduling.
3. General host naming beyond configurable aliases; Justin currently uses
   `M1` and `M5`.
4. Whether a run set creates every task immediately or lazily; this should be
   simple configuration optimized for human attention.
