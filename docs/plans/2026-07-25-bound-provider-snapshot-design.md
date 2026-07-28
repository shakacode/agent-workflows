# Bound Provider Snapshot Design

Date: 2026-07-25
Status: accepted

## Goal

Keep every shared instruction read for one operation inside one verified,
immutable provider snapshot. Provider modes distinguish a
managed provider, which resolves its current canonical
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

## Explicit Provider Operation Lifecycle

Managed operation state is bounded by explicit references, not age or process
heuristics. The resolver exposes
`release --host HOST --target TARGET --operation HANDLE --json` and
`list --host HOST --target TARGET --json`. `begin --json` returns the complete
absolute release argv for its target and opaque handle. Release it only after
the invocation's final shared-instruction read and helper/capability use; the
release invalidates all returned asset paths even when files remain. Recover a
crashed or orphaned handle by inspecting `list` and naming that exact handle in
`release`, never by TTL or PID inference.

The fixed admission limits are 32 live operation records and 8 retained
revision snapshots. Reference-derived GC never evicts a live operation or the
installed managed revision. Thus the honest bound is 32 published operations
and 8 retained revisions in healthy quiescent state, not a strict byte quota.
Malformed operation, store, or installation state blocks deletion rather than
broadening cleanup.

Resolver begin/release, capability runners, installation, upgrade, rollback,
and GC share one bounded POSIX `flock` lifecycle lease at a stable private inode.
Runners hold a shared lease through capability process completion. Mutations and
GC hold the exclusive lease. Installer migration locking remains an inner,
secondary defense.

### Pre-require serialization

The installed resolver and runner contain the complete minimal lease bootstrap,
and the lifecycle wrapper is self-contained through acquisition, reentry
validation, and child supervision. The installer publishes those files and the
install and upgrade shell entries by same-directory rename before replacing the
runtime module tree. A starting process therefore reads one complete entry
inode, and its lifecycle wrapper opens and acquires the stable lock before any
file that the installer mutates can be loaded.

### Nested exclusive-reentry proof

An inherited descriptor alone is not evidence that the originating wrapper is
still active. `fork` and `exec` preserve references to the same lock, and a
later `flock` on that inherited descriptor could modify or reacquire it.
Reentry therefore never locks the inherited descriptor. It requires all of:

1. the exact target-bound descriptor and stable lock inode;
2. a matching active token in an atomically published mode-`0600` record;
3. a wrapper-only pipe writer whose inherited read end has not reached EOF;
4. an independent probe process that closes its inherited descriptor, opens
   the exact lock path as a new reference, and observes that nonblocking
   exclusive acquisition is denied.

The wrapper publishes the active token only while holding the exclusive lease
and marks it inactive before unlock. On `SIGKILL`, callbacks cannot invalidate
the file, but the kernel closes the wrapper-only pipe writer; EOF makes the
active-looking crash record unusable. A detached child can retain the lock and
read descriptors but cannot retain that writer.

The preceding wrapper version has no liveness writer. Its active invocation and
detached crash residue expose the same portable evidence, so the new validator
does not accept either. It returns `LIFECYCLE_RESTART_REQUIRED`; once the legacy
command exits and releases its lock, a fresh source-side upgrade can enter
through the new wrapper. This one-time two-phase transition preserves the
fail-closed invariant instead of weakening reentry validation.

This proof uses the common Linux/BSD inheritance model rather than
platform-specific PID inference. Linux documents that duplicated descriptors
share one open-file-description lock while a separate `open` is independent:
[Linux `flock(2)`](https://man7.org/linux/man-pages/man2/flock.2.html). Apple's
BSD manual likewise documents `fork`/`dup` references as one lock and
nonblocking denial while an exclusive lock exists:
[Apple `flock(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html).
