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

Use [.agents/workflows/pr-processing.md](../../../workflows/pr-processing.md) as the
canonical source for coordination state and worker rules. Keep this skill as a
routing entry point; do not duplicate the full protocol here.

In short: exact lane assignments beat labels; a selected private backend is the
source of truth when bounded health and target-scoped status probes pass; claim
refusals hard-stop machine agents; workers heartbeat at phase transitions;
dependency-sensitive lanes re-check coordination before rebase, push, readiness,
and closeout; broad status reads are audit-only; exact independent lanes may
proceed in claim-only mode only after the canonical workflow allows it; and
structured public claim comments are advisory fallback state only when the repo
seam allows that fallback. Timed-out claims stop as `UNKNOWN (claim outcome)`
for backend reconciliation. An issue/PR lane claim also mirrors to the seam's
claim label (`agent_claimed_label`, default `agent-claimed`; apply on claim,
remove on release for this lane's own claim; hint not lock; skip when backend
n/a), and selection/triage skip claimed items — see the canonical rule in
`pr-processing.md`.

The same canonical section defines provenance and operational telemetry. Batch
registration carries `pack_sha`, `coordinator_preference`, and per-lane
`worker_preference` plus optional `observed_host`. Workers emit `help_requested`,
`escalation_requested`, `error`, and `human_intervention` at the existing
checkpoints without replacing prose packets. Do not duplicate auto lifecycle
events `claim.acquired`, `claim.released`, or `phase.changed`.

For a compact directional throughput view, normalize only allowlisted durable
coordination and field-selected GitHub-shaped metadata into
`workflow-telemetry-input` v1, then run the sibling
`bin/workflow-telemetry-report`. Use its replay fixture and contract documented
in `docs/coordination-backend.md`; preserve literal `UNKNOWN` for unavailable
measures. Its phase, human-question queue, and slot totals are cumulative across
lanes rather than elapsed critical-path time; its separate batch-level
`integration_seconds` window is not `phase_seconds.integration`. Never add raw prompts, responses, transcripts, tool results, secrets,
environment/auth content, exact accounting, adaptive scheduling, experiments,
or a parallel collection system.
