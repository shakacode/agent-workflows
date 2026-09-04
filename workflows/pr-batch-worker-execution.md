# PR-Batch Worker Execution

This component owns bounded implementation for an accepted lane.
Load after prompt intake, planning, dependency preflight, and dispatcher
selection, before implementation dispatch, lane-worktree creation, or editing.

## Boundary

Worker execution owns isolated setup, implementation, focused validation,
meaningful stops, the human-attention queue, and implementation-head handoff.

It consumes, without redefining, verified [`pr-batch-intake`](pr-batch-intake.md),
[`stage-dependency-gate`](pr-processing.md#stage-typed-dependency-gate) action,
the approved execution envelope, and optional
[`Coordination State`](pr-processing.md#coordination-state) ownership. It calls
the shared security floor before using public GitHub content; it does not own
security, dependency planning, dispatch, claims, liveness, or telemetry.

It emits a committed implementation head and replayable evidence. It does not
own base integration, conflict resolution, final validation, PR publication,
review convergence, hosted CI, readiness, merge, production, promotion, or
release.

Before implementation dispatch, use the [Task Review Loop](pr-batch-task-review.md)
to create the task brief consumed here. Return after the committed handoff for
its task review and fix rounds.

## Input Contract

Consume one lane record with known values for:

- the exact accepted target and stable coordination identity;
- the accepted task brief with its exact identity and digest as the sole source
  of the task goal and acceptance requirements;
- execution controls for non-goals, supported diagnosis, invariants, required
  verification, stop conditions, and owned paths;
- repository root, accepted base commit, worktree path, and branch name;
- the latest dependency-gate permission for the requested action;
- focused verification commands or their repository discovery seam;
- dispatcher assignment and, when required, the coordinator-approved execution
  envelope; and
- optional coordination ownership evidence, separate from execution correctness.

Never reconstruct missing intake, dependency, authority, or ownership facts
from prompts or worker self-report. Missing or `UNKNOWN` required facts stop
before mutation. File overlap is advisory; only issue-authored semantic
dependencies and active expansion reservations restrict the action. The worker
does not redefine scope or substitute a new diagnosis.

## Isolated Setup

- Assign one target or one semantic lane to the worker.
- Consume the coordinator's accepted dependency and optional ownership results
  before setup. A refused claim, a false action permission, or required
  dependency state that is missing or `UNKNOWN` stops the lane.
- Give every file-editing worker a separate worktree and branch. Codex and
  multi-machine workers use `git worktree add`; in-process Claude Code
  `Agent`/`Workflow` workers use `isolation: 'worktree'`. Never let concurrent
  file-editing workers share a working directory, index, or branch.
- Verify repository root, exact base, branch, and worktree cleanliness before
  editing. For a GitHub issue/PR, re-fetch the live target. For a
  `trusted-ad-hoc-override` lane, instead re-verify its complete accepted
  durable override provenance is exact and non-`UNKNOWN`. Never revert another
  worker's changes.
- When optional coordination is active, refresh its heartbeat at phase changes.
  Before rebase or push, recheck bounded status and the known
  holder/generation/instance; a mismatch stops without mutation. A dependent
  lane whose required private state cannot be checked remains `UNKNOWN` and
  stops rather than falling back to claim-only execution.
- Obey the exact action returned by `stage-dependency-gate`. Pending `edit`
  remains read-only. Pending `validation_open` permits only the held-local
  implementation actions the gate returns. Pending `merge_order` does not
  restrict implementation. Re-run the gate after any dependency, head, base,
  or reservation change relevant to the requested action.

## Implementation Loop

1. Characterize or reproduce the problem, identify the active code path, and
   record assumptions before a non-trivial edit.
2. Make the smallest cohesive change that satisfies the accepted goal. Add or
   update focused tests with the behavior when practical; do not broaden the
   lane for unrelated cleanup.
3. Handle necessary path discovery through **Path Expansion** below before
   editing a newly discovered path.
4. Run the cheapest focused behavioral check, inspect the diff, and correct a
   small explainable failure on the same worker route.
5. Repeat the edit/check/self-review cycle until the focused checks pass or a
   meaningful stop condition applies. Never weaken verification to obtain a
   pass.
   When the canonical escalation threshold is met, stop with a
   `MODEL_ESCALATION_REQUEST` containing lane/claim state,
   branch/worktree/HEAD, current changes, evidence, hypotheses, attempts and
   exact failures, invariants, verification gaps, qualifying trigger, and
   smallest next action. The routing owner decides before replacement.
6. Create cohesive local commits and identify the exact full implementation
   head. A worker may push its assigned implementation branch only when the
   coordinator authorized that action and the current dependency and ownership
   checks still permit it. PR creation and closeout remain coordinator work.

## Path Expansion

Owned paths are coordination controls, not a user-permission boundary. A
necessary in-repository path may be added when repository evidence shows it is
required for the already-authorized goal or verification. Record the path and
reason before editing it, and require an active typed
`expansion-path-reservation` until the verified PR file-touch map reflects the
path or the request is cancelled.

For a sole active editor, the coordinator records the reservation, refreshes file-touch
maps, lifecycle, claims, and collision evidence, then reruns
`batch-plan-preflight`; continue only after acceptance. In a multi-editor wave,
persist the typed request, block the lane, refresh its heartbeat, emit the Lane
Card with path/reason/request reference, and pause before editing. After serial
coordinator processing, resume only when the lane has left `blocked`, fresh
preflight accepts, and it is absent from `launch.held_lane_ids`. When launch or
relaunch is needed, it must also be in `launch.eligible_lane_ids`. Under max-one
serialization, the current holder must release the slot. A collision
or `UNKNOWN` collision result remains stopped.

Directory renames use `expansion-rename-reservation` with canonical distinct
`old` and `new` endpoints; that typed form adds ancestor/descendant collision
checks, while scalar reservations remain exact-path controls. Necessary paths
may include contracts or types, tests or fixtures, offline demo stubs, and build
or generated integration surfaces. An omitted path alone is not material scope
growth and must not produce `blocked-user-input`.

## Focused Validation

Resolve commands through the repository's `AGENTS.md` and `.agents/bin/*`
seams. Run changed-helper tests, targeted unit or contract tests, and cheap
negative cases that directly cover the lane. Record each exact command, exit
status, and concise result; record a required check that cannot run as
`UNKNOWN` with the reason.

Focused success qualifies only the implementation handoff. It is not final
validation, hosted CI, or merge-readiness evidence. The integration/PR-closeout
owner runs the clean committed full validation and all current-head gates.

## Meaningful Stops And Human Attention

Use reversible best judgment for naming, ordinary conflicts, test selection,
changelog deferral, documentation placement, and other non-consequential
choices allowed by repository policy. Record it for integration.

Stop at a safe checkpoint when contradictory evidence appears; the approved
goal, accepted behavior, or acceptance criteria changes; unrelated work;
repository/trust-boundary crossings; destructive or hard-to-reverse actions;
new secrets, permissions, deployments, billing, or external effects;
consequential architecture, performance, compatibility, or product decisions;
material security, privacy, compliance, or release-policy changes; an
uncoordinatable active lane; consequential ambiguity; or verification would be
weakened.

Queue one compact `worker-attention v1` record rather than a transcript:

- target, lane, current branch/worktree/head, and safe working-tree state;
- exactly one reason: `permission`, otherwise `question`, otherwise
  `blocked-user-input`;
- the one exact decision or action required, its evidence reference, and the
  consequence of each materially different choice; and
- the safe resume instruction plus any dependency, claim, or path-expansion
  state that must be replayed.

When an active private backend advertises typed events, emit the corresponding
`help_requested` event through its bounded transport; backend absence or
unadvertised transport does not invent an execution blocker. Do not ask merely
because a dependency is still progressing or optional telemetry is unavailable.

## Worker-To-Coordinator Handoff

Emit a Lane Card after accepted ownership, when blocked or cancelled, and as the
final handoff header. Refresh values rather than relying on task titles:

Record `preferred model/effort` separately from `observed host/model/effort`;
an unavailable observation stays `UNKNOWN` and never becomes inferred evidence.

- `Lane Card`
- `Thread:` `<thread-handle>`
- `Preference:` `<model>/<effort>`; `observed:`
  `<host|UNKNOWN>/<model|UNKNOWN>/<effort|UNKNOWN>`; `envelope:`
  `<coordinator-approved|UNKNOWN>`
- `Batch/lane:` `<batch-id>` / `<lane>`; `dashboard_url`: `<url|UNKNOWN>`
- `Target:` `<verified GitHub issue/PR link>` or exactly
  `n/a — durably overridden ad-hoc; durable_ref=<exact accepted durable_authorization_ref>`
- `Canonical launch:` `<repository-qualified stable identity>`;
  `Ad-hoc override:` `none` or
  `<override_name>; authorizer=<trusted_authorizer>; durable_ref=<durable_authorization_ref>; task_identity=<original_task_identity>`
- `Branch:` `<branch>`; `pr_url`: `<verified GitHub/backend URL|UNKNOWN>`
- `Phase:` `<phase>`; `claim:`
  `<holder|UNKNOWN>/<generation|UNKNOWN>/<instance|UNKNOWN>`;
  `coordinator:` `<coordinator-id|UNKNOWN>`
- `Path expansion:` `<canonical path|none>`; `reason:` `<known reason|n/a>`;
  `request_ref:` `<durable evidence ref|n/a>`

Never infer identity, override provenance, or observed values. Prefer a verified
GitHub PR URL over missing backend metadata; use `UNKNOWN` only when neither is
available.

The `worker-execution-handoff v1` then records exact target/lane, accepted base,
branch/worktree, full implementation head, working-tree state, changed paths and
diff summary, focused validation commands/results, assumptions and decisions,
dependency and optional ownership evidence, attention record or `none`, and
integration notes. Success requires a clean committed implementation head; a blocked handoff
enumerates every staged, unstaged, untracked, and unpushed change without
claiming readiness.

The integration owner verifies this handoff before using it. When that owner
later opens or updates the PR, it emits the PR-open Lane Card and replaces
`pr_url: UNKNOWN` with the verified URL. A lane-level worker handoff never
claims final readiness and never carries the batch archive-readiness status.
