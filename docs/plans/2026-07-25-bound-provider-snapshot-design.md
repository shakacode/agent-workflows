# Bound Provider Snapshot Design

Date: 2026-07-25
Status: accepted

## Goal

Keep every shared instruction read for one operation inside one verified,
immutable provider snapshot. Provider modes distinguish a
managed/connected rolling provider, which resolves its current canonical
revision before work, from an explicit pinned or offline snapshot, which keeps
its own declared contract and never mixes assets with a rolling operation.

Consumer repository policy remains local. `AGENTS.md`,
`.agents/agent-workflow.yml`, and `.agents/bin/*` continue to supply repository
rules and command seams; they are not shared-provider substitutes.

## Operation Result

`agent-workflows-resolve begin --json` returns the operation handle, exact Git
revision, freshness, capabilities, runner, and these assets:

- `assets.root`: absolute canonical snapshot tree for this operation;
- `assets.skills`: validated snake_case skill name to absolute `SKILL.md` map;
- `assets.skill`: primary `pr-batch` instruction file;
- `assets.workflow`: canonical PR-processing workflow;
- `assets.related_workflows`: validated named supporting workflows;
- `assets.docs`: validated named supporting documents.

`assets.root` reports already verified read-binding state. It is never accepted
as input from an environment variable, consumer repository, inherited
operation state, `PATH`, live host cache, or another checkout.

## Registry Boundary

The capability registry declares every shared skill that canonical PR
processing or its direct operation-bound entries may route into. Each named
skill must:

1. use a snake_case registry name;
2. resolve to that skill's declared `SKILL.md` path beneath `assets.root`;
3. be a regular non-symlink file;
4. contain no traversal or malformed path component.

Missing, malformed, traversing, and symlinked skill assets fail closed before
operation publication. Workflow and document assets retain the same regular
file and containment checks.

## Entry Bootstrap

Every operation-bound entry skill starts with one common contract:

1. Reuse an operation only when the current invocation created it locally and
   retained that exact begin result.
2. Otherwise run the active host home's absolute
   `bin/agent-workflows-resolve begin` path.
3. Never bootstrap through `PATH` or inherited operation variables.
4. Re-read the entry at `assets.skills.<name>`.
5. Read canonical PR processing only through `assets.workflow`.
6. Resolve sibling skills, workflows, and docs through returned named assets or
   beneath `assets.root`.
7. Stop when a required named asset is absent.

An agent-runner restart creates a new invocation. The replacement starts a new
operation and uses the newly returned snapshot. A same-invocation continuation
may reuse only its locally retained exact result.

## Execution Boundary

Read-only helpers may run from directories derived from returned
`assets.skills` entries. Registered provider mutations run only through the
absolute operation runner with the retained handle. If a registered capability
is unavailable, the operation stops; it never executes the capability's source
helper path.

The operation result binds machine-readable paths and execution state. It
cannot prove that a model consumed Markdown, so re-reading the returned entry
and workflow remains an explicit instruction-contract step.

## Non-Goals

- Replacing consumer repository policy with provider policy.
- Creating precedence between operation assets and local/shared copies.
- Turning pinned or offline providers into rolling providers implicitly.
- Claiming isolation from a malicious same-user process.
