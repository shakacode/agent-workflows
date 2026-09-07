## Question And Decision Handling

Classify every unresolved question before continuing:

- **Blocking question**: the implementation, validation, or merge decision would be unsafe without maintainer input. Stop work on that target until answered. Subagents should return the blocking question to the coordinator instead of guessing. For multi-machine batches, post a structured issue or PR comment and, if the repo defines a pending-question marker in `AGENTS.md`, apply that marker. A worker handoff should include the question/comment URL as that target's blocked final state.
- **Non-blocking decision**: a reasonable local decision can be made without increasing merge risk. Continue work, but add a clearly formatted decision note inside the PR description's `Agent details` disclosure so later review across merged PRs can surface these items quickly.

For a private-backend blocking stop, emit `help_requested` alongside the prose
handoff. Choose exactly one `help_requested.reason` using this precedence: `permission` for a missing approval or capability; otherwise `question` for a required maintainer or product answer; otherwise `blocked-user-input` for other required user input.
When a worker verifies a P0/P1 finding, confirmed regression, or required
revert, emit `error` with `severity`, `category`, and `message`. Backend `n/a`
skips these signals. Typed-event transport is optional: when an active private
backend does not advertise it or reports it unsupported, record
`typed event transport: unavailable`, skip the emission, and continue without
marking the event emission `UNKNOWN`. Only after the transport is advertised
does an attempted write that fails, degrades, or is rejected become `UNKNOWN`
handoff evidence. Every attempted advertised typed-event write must resolve the
backend-advertised event executable and ordered opaque argv; a missing,
malformed, or unsafe advertisement is an attempted-write failure. Run that
exact executable and separate argv without shell evaluation, with a finite
deadline in its own process group, preserving each opaque argument; on expiry
terminate the whole group with `TERM`, then `KILL` after a finite grace period.
A deadline expiry, forced termination, or any other advertised-support write
failure records best-effort `UNKNOWN` event evidence; the primary operation
continues immediately without waiting further on the event.

<!-- Keep this hosted-CI uncertainty rule in sync with `.agents/workflows/pr-processing.md`. -->

Hosted-CI uncertainty at the final readiness gate after local validation and the
final push is a non-blocking decision. If the branch needs remote confirmation,
request optimized hosted CI via the repo's hosted-CI trigger (see `hosted_ci_trigger`
in `.agents/agent-workflow.yml`). If the remaining concern is that optimized suite
selection may be insufficient, request force-full hosted CI and record why. Re-fetch
and wait for the newly requested current-head checks, then continue the readiness
flow instead of escalating it as an immediate maintainer question. Check hosted-CI
status first when state is unclear, and do not substitute a direct hosted-CI-ready
label from automation for the trigger command; direct labels are only the human/local
user-token path.

Use the canonical [Human-First PR Description Contract](../../../workflows/pr-processing.md#human-first-pr-description-contract).
Keep the human-visible why, change summary, review path, and genuine maintainer
questions or blockers outside its one `Agent details` disclosure; put the
decision log and all agent evidence inside it. Before merge or final readiness,
scan the decision log and make sure each non-blocking decision is still accurate
after review changes.

## Maintainer Attention Contract

Use `AGENTS.md` and the canonical
[Maintainer Attention Contract](../../../workflows/pr-processing.md#maintainer-attention-contract)
section in `.agents/workflows/pr-processing.md`. Keep this skill as a routing
entry point: worker goals should carry the contract before target assignment,
and the [goal prompt template](prompt-template.md) repeats the key worker-facing rules. The
detailed policy belongs in the canonical workflow.

## Batch Handoff Format

Use the canonical [Batch Handoff Format](../../../workflows/pr-batch-integration-closeout.md#batch-handoff-format) section. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

## Unblock Block

Use the canonical [Unblock Block](../../../workflows/pr-batch-unblock.md#unblock-block) whenever a final batch handoff stops non-clean. This entrypoint is a compatibility route and must not mirror integration or closeout policy.

## Coordination State

Load [PR-Batch Coordination And Observability](../../../workflows/pr-batch-coordination-observability.md)
after prompt intake and dependency planning, before branch or worktree creation.
It is the canonical interface for private, public-fallback, and no-backend
modes; target-scoped claims and heartbeats; liveness; capacity evidence;
status translation; monitoring; telemetry; restart recovery; replacement
fencing; cancellation; and terminal release.

Consume its `coordination-observability v1` result without reconstructing the
backend protocol here. Reliable contradictory ownership refuses duplicate work
only for the affected target. Missing optional telemetry remains
field-granular `UNKNOWN` and never freezes unrelated work. Preserve exact
loaded-pack provenance, requested routes separately from host-observed values,
the canonical coordination declaration, and every action-specific blocker.
