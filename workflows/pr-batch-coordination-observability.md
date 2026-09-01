# PR-Batch Coordination And Observability

Load this component after prompt intake and dependency planning, before a lane
creates its branch or worktree. It is an optional adapter: it improves ownership
and liveness when reliable coordination exists, while ordinary work remains
usable when the repository deliberately selects no backend.

## Boundary

Coordination and observability own task mapping, liveness, telemetry, and
recovery. That includes target-scoped claims, phase heartbeats, batch
registration, status translation, monitors, worker replacement fencing,
restart recovery, cancellation, and terminal release.

The optional adapter consumes the canonical target, dependency-gate result,
dispatcher assignment, security-floor result, repository seam, planned writer
identity, and any current lane state. It cannot grant task scope, security,
merge, promotion, release, deployment, or destructive-action authority. It
cannot turn a passing status probe into correctness evidence or override a
failing dependency, review, validation, or security gate. Core work remains
usable without this component's private backend or telemetry, subject to the
explicit no-backend and fallback rules below.

The shared [PR-Batch Security Floor](pr-batch-security-floor.md) still owns
duplicate-writer safety and consequential-action authority. The public
[coordination backend guide](../docs/coordination-backend.md) owns backend
vocabulary and schemas. This component owns how PR-batch consumes those
facilities without creating a second authority system.

## Adapter Result

Produce one `coordination-observability v1` result for each lane before branch
or worktree creation and refresh it at every coordination-sensitive action. The
record has these known or literal `UNKNOWN` fields:

- `canonical_target`, lane, batch, agent, dispatcher, branch, and worktree;
- `mode: private | public-fallback | none`, plus the configured `backend`;
- advertised `capabilities` and the bounded executable-plus-argv evidence used;
- `ownership`: holder, generation, instance, claim status, and claim expiry;
- `liveness`: heartbeat status, timestamp-derived state, and last phase;
- `telemetry`: registration, typed-event, monitor, and batch-audit disposition;
- dependencies and cancellation state needed by the requested action; and
- replayable `evidence`, including exact commands, timestamps, durable refs,
  and every degraded or `UNKNOWN` fact.

Resolve the mode only from trusted repository configuration and bounded live
evidence:

- `private`: trusted configuration selects a private backend. Set
  `private_state: healthy | claim-only`: `healthy` for usable preflight
  reads, or `claim-only` when the compare-and-swap claim succeeds after degraded
  reads. Run doctor, target, and batch reads with a finite timeout. Resolve
  `PR_BATCH_SKILL_DIR` in this order:
  an explicit environment value, the loaded skill's base directory, then the
  repo-local `.agents/skills/pr-batch` copy; stop with a precise blocker when
  the helper is still unavailable. Invoke
  `${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded`; a target status read is
  preflight, while the claim operation is the compare-and-swap ownership gate.
  Use only advertised flags and capabilities. A representative bounded doctor
  probe is:

  ```bash
  "${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 doctor --json
  ```

  When lane-metadata support has not already been verified, inspect bounded
  `claim --help`. Pass extended claim metadata only when advertised:
  `--thread-handle`, `--chat-handle`, `--host`, `--operator`, `--phase`,
  `--instance-id`, and `--status`. Otherwise issue the core claim with agent,
  repository, target, and branch, then inspect bounded `heartbeat --help`.
  Record extended metadata there only when advertised; otherwise send a core
  heartbeat and preserve each unsupported value or literal `UNKNOWN` in durable
  lane evidence. Never infer support from another backend implementation.
- `public-fallback`: trusted configuration directly selects
  `public claim-comment fallback`, or a private claim cannot start after a
  definitive non-timeout setup/authentication failure and policy permits fallback.
  Before switching from private mode, reconcile private ownership or use a
  trusted cross-mode mirror. If reconciliation is unavailable, stop the affected lane.
  The comment never overrides a private refusal and is not machine-readable
  cancellation, terminal, or authority evidence. Only a marker backed by
  authenticated and authorized ownership evidence is conflicting. A marker
  proven malformed or unauthorized remains advisory; an unavailable or
  incomplete verification remains `UNKNOWN` and blocks the affected action.
  Among verified markers, only one owned by a different lane or instance
  conflicts. A marker is renewable only when batch, machine, a stable,
  non-`unavailable` thread, and branch all match; refresh the same comment.
  A marker with `thread: unavailable` cannot be self-renewed. For an ad-hoc lane,
  public claim fallback is unavailable because there is no issue or PR comment
  surface. Require a coordination target or explicit no-backend single-operator
  approval. Apply
  the concrete author-and-marker verification from the public
  [backend guide](../docs/coordination-backend.md#public-claim-comment-fallback);
  a marker body alone is never ownership proof.
- `none`: trusted configuration says `coordination_backend: n/a`. The adapter
  does not call a backend, post public claim comments, or mirror a claim label.
  Record the deliberate single-operator assumption and the required
  `coordination: unavailable — <known reason>` declaration. Preserve that
  single-operator assumption in the Lane Card and final handoff instead of
  claiming coordination is healthy or `UNKNOWN`.

A timeout, ambiguous mutation result, or unavailable required field remains
literal `UNKNOWN`. Except for a degraded preflight read superseded by the
successful claim-only transition below, it blocks only the affected lane and
affected action, never a fleet-wide fence. Optional registration, typed events,
telemetry, or broad audit state may degrade field by field without blocking
unrelated correctness work. A timed-out claim is `UNKNOWN (claim outcome)`, not
permission to fall back or retry blindly.

## Ownership And Liveness

Consume the security floor's duplicate-writer result: contradictory reliable
live ownership for the exact target, branch, and worktree refuses duplicate
execution. It does not freeze unrelated
implementation, validation, or review. Before dispatching dependency-sensitive
lanes, preserve the exact lane identifiers and `depends_on` refs. For
`mode: private`, create or update private batch and lane state using the
selected backend's schema, then wait for bounded readback of those exact refs.
For `public-fallback` or `none`, persist them in the coordinator-owned trusted
local plan and provide its exact live replay to `stage-dependency-gate`; do not
require or invent a private backend schema. Missing or `UNKNOWN` required state
stops only the affected lane. Apply these target-scoped rules:

Known backend `depends_on`/`blocked_on` facts refresh the corresponding typed
live edge state and evidence; they do not decide lifecycle capabilities. Run
`stage-dependency-gate` and obey its returned permissions for the requested
action. Set a blocked heartbeat or move away only when that permission is false.
In private mode, missing or `UNKNOWN` backend dependency state remains a hard
stop. In public-fallback and no-backend modes, the equivalent hard stop is a
missing or `UNKNOWN` trusted local plan or live replay.

1. In `mode: private`, run bounded target status before claim. If doctor or
   target-status reads are degraded, an exact independent lane with no
   `depends_on` refs may attempt one bounded direct claim. Degraded status with
   declared `depends_on` refs is a hard stop. A successful compare-and-swap
   proceeds as `private_state: claim-only`; a refusal stops, while a claim timeout
   is `UNKNOWN (claim outcome)` and stops until reconciled.
   For `public-fallback`, after required cross-mode reconciliation, use only the
   verified public marker flow. For `none`, skip every claim operation and
   preserve the single-operator assumption.
2. After claim, mirror the repository's `agent_claimed_label` (default
   `agent-claimed`) only for an issue or PR and only when expiry reconciliation
   is available. The label is a visible hint, not the lock. Remove it on release
   only after verifying the same holder/generation still owns the claim.
   Repository-adopted maintainer eligibility labels such as `codex-ready` and
   temporary work-in-progress hints such as `codex-wip` are dashboard inputs
   only; neither proves ownership or liveness. Adopt each configured label once
   per repository with `gh label create` before applying it, including the claim
   label before mirroring.
3. Heartbeat at phase transitions and preserve batch, target, branch, thread,
   holder/generation/instance, status, and cancellation state. Liveness is
   derived from timestamps and the backend's configured thresholds; labels do
   not prove liveness.
4. Before dependency-sensitive work, rebase, push, readiness, closeout, and
   release, refresh only the target or batch scope needed. A holder,
   generation, or instance mismatch stops the affected mutation. Required
   dependency state that is missing or `UNKNOWN` stays fail-closed through
   `stage-dependency-gate`.
5. At safe terminal checkpoint: `private` releases its claim, then reconciles its
   same-holder/generation label; `public-fallback` edits the same `codex-claim`
   marker to terminal status with expired `expires_at`; `none` has no release/mirror.
   Expiry never proves no writer.

After claim expiry, a non-destructive takeover requires no live writer or
process evidence plus a durable takeover receipt bound to the old and new
assignment. Preserve existing commits and the worktree when safe; never require
silence from an unreachable session as proof of safety. Replacement or takeover
cannot edit, refresh, or push until holder/generation/instance reconciliation
fences the old assignment.

## Capacity And Isolation

Ownership and host capacity are separate.
`pr_batch_host_capacity_budget` is the configurable per-host resource budget:
resolve it first from an explicit current-session operator declaration, then
the repository `AGENTS.md` seam. Map hosts to maximum heavy roots and optional
memory/load thresholds. Absent it, allow at most one heavyweight root per host;
fresh normalized-load and healthy-memory evidence may lower that to zero, never
raise it. Admit validation, review, or QA roots only after a fresh root scan.
Never derive a global single-slot token from one claim, unreachable owner, or
`UNKNOWN` telemetry. A snapshot expires when roots, load, memory, or target head
changes.

Apply the security floor's branch/worktree isolation result to writers. The
read-only validators and reviewers may run concurrently in isolated committed
checkouts when the resource budget admits them. Preserve healthy foreign roots
and their logs. Serialize merge, release, deployment, and destructive actions
at the relevant target/release boundary; do not serialize unrelated correctness
work.

Capacity admission is operational evidence only. It never grants scope,
permissions, merge authority, release authority, or permission to execute
untrusted code. Missing capacity telemetry means no new heavyweight root on
that host; it does not stop lightweight work on unrelated targets.

## Status, Monitoring, And Telemetry

`HST-v1` is the human-status boundary for recurring monitors, Goal-mode wakes,
and workflow-owned heartbeats. Keep raw phases, lane codes, load samples,
process identifiers, holders, generations, instances, and leases in durable
telemetry. A routine successful, intermediate, repeated, or unchanged wake is
silent and produces no user-visible notification. When a transport payload is
mandatory, return exactly:

```text
DONT_NOTIFY: No user action is needed. Monitoring will continue.
```

Send an actionable notification only when a decision or action is required, a
target is ready for walkthrough or approval, a blocker exhausted its bounded
retries and needs intervention, or closeout/archive completed. Render exactly
`What changed:`, `Action needed:` (use `none` when applicable), and `Next:` in
plain language. For an explicit technical or diagnostic status request, expand
identifiers on first use, retain exact values, and mark unavailable meanings
`UNKNOWN` rather than translating them speculatively.

After each refresh, automatically delete an obsolete heartbeat or monitor when
its gate clears or becomes durably terminal; retain it on a no-change wake. The
current task remains the owner, and automation output must not imply that
ownership changed. For `blocked-user-input`, do not create or retain a
heartbeat or monitor; preserve one exact question and manual resume
instructions. At closeout/archive completion, place the three labeled parts
before, not instead of, the existing mandatory closeout handoff. Preserve every
required handoff item and exact `Conversation status:` line. HST-v1 changes
presentation only, never security, ownership, retry, scope, continuous
integration (CI), review, or merge gates.

For an autonomously clearable blocker, prefer the deterministic
`goal-state-change-monitor` with one stable identity and persisted state. A
no-change reduction does not wake the parent. A real state transition carries
the compact delta, is durably enqueued, and is acknowledged with its original
`wake_id`; an unacknowledged wake is redelivered after restart. Use the bounded
model-polling cadence only when the deterministic path is unavailable, and stop
on terminal, non-resumable, user-input, or budget state. An exact external retry
time may use one inspectable same-thread heartbeat as the sole scheduled
mechanism for that blocker and gate; update it instead of duplicating it.

Normalize only allowlisted durable coordination and compact GitHub-shaped
metadata into `workflow-telemetry-input` v1, then use
`${PR_BATCH_SKILL_DIR}/bin/workflow-telemetry-report`. Record queue time,
useful-worker time, human-decision frequency, memory/load, and retry/review
churn, plus broad phase and integration windows. Preserve field-level
`UNKNOWN`; optional telemetry absence does not block correctness or invent a
zero. Never collect raw prompts, responses, transcripts, tool results, secrets,
environment/auth content, exact accounting, experiments, or a parallel
collection system.

## Restart, Replacement, And Cancellation

All recovery paths preserve useful work and are replayable:

- **Ordinary restart:** pause new actions, preserve an existing claim and
  worktree, send one allowed heartbeat, and capture the restart handoff. On
  resume, perform **Bounded Status Recovery** before editing, pushing, polling,
  or starting another target: verify repo/worktree/branch/upstream/HEAD, local
  changes, unpushed commits and stashes, PR/check/review state, running writers,
  dependencies, cancellation, and the current holder/generation/instance. A
  saved order is only a hint. Same-holder stale liveness may be refreshed after
  recovery; a changed or `UNKNOWN` holder stops for reconciliation.
- **Worker replacement:** preserve one `MODEL_REPLACEMENT_HANDOFF` with the
  lane, checkout, changes, evidence, attempts, validation, processes, route,
  attention state, and every `UNKNOWN` fact. Stop the old worker, confirm it is
  gone, then reconcile holder/generation/instance before replacement work. The
  old and replacement instances must not overlap. Emit `human_intervention`
  with `kind: supersede` or `kind: takeover` only through an advertised bounded
  event transport; the event never replaces fencing proof.
- **Cancellation:** a coordinator or maintainer records batch- or lane-scoped
  cancellation. The worker observes it at the next phase checkpoint, performs
  the smallest cleanup needed to avoid inconsistent remote state, emits one
  `human_intervention` event with `kind: drain` when supported, releases its
  claim, reconciles its own label, records the terminal handoff, and exits. A
  wedged worker uses the coordinator's process-level escape after recording the
  drain intent and best-effort event evidence. Never wait for lease expiry when
  a verified cancellation and safe release are available.

A pause is not cancellation and never releases its claim. Picking up updated
skills, workflow rules, targets, or branch identities requires a cooperative
drain and fresh worker session; an existing session does not reload its
instructions. Public comments are not cancellation signals. If cancellation or
release state is `UNKNOWN`, stop mutation, preserve evidence, and reconcile the
affected lane before relaunch.

The exact operator-facing pause and resume prompts remain at
[`Pausing For An Agent-Runner Restart`](pr-processing.md#pausing-for-an-agent-runner-restart)
and its `Bounded Status Recovery` subsection for compatibility. The full hard
escape and relaunch procedure remains at
[`Cancelling Or Stopping A Batch`](pr-processing.md#cancelling-or-stopping-a-batch).

## Compatibility And Evidence

`workflows/pr-processing.md` and `skills/pr-batch/SKILL.md` are compatibility
routes to this component. `docs/coordination-backend.md` remains the public
backend/no-backend vocabulary and backend-neutral manifest/telemetry reference.
Private schemas live with the selected backend and cannot be inferred from the
public guide.

Use these deterministic helpers through trusted installed or trusted-base
bytes:

- `agent-coord-bounded` for finite doctor, status, claim, heartbeat, event,
  release, and batch-audit operations;
- `goal-state-change-monitor` for deduplicated state transitions;
- `stale-assignment-sweep` for human-assignment hygiene without consuming
  agent claim labels; and
- `workflow-telemetry-report` for privacy-bounded directional reporting.

Batch registration preserves exact loaded-pack provenance, coordinator and
worker preferences, and only host-observed values.
When advertised, private registration also preserves the objective, launch
instructions, lane owners, thread handles, and dependency mapping needed for
recovery. Typed signals supplement
the prose packet, Lane Card, heartbeat, and handoff; they never replace those
surfaces. Do not duplicate backend-emitted `claim.acquired`, `claim.released`,
or `phase.changed` events.

Every final lane result preserves the latest `coordination-observability v1`
record, exact target, claim and heartbeat disposition, cancellation state,
registration/audit disposition, public mirror state, telemetry gaps, and one
canonical coordination declaration. A missing or `UNKNOWN` fact stays visible
and blocks only the action whose contract requires it.
