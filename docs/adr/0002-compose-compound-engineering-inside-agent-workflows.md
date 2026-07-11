# ADR 0002: Compose Compound Engineering Inside Agent Workflows

Date: 2026-07-10
Status: accepted

## Context

Agent Workflows and Compound Engineering (CE) overlap at planning,
implementation, review, simplification, knowledge capture, and shipping. Both
can edit a working tree, create commits, and drive work toward a pull request.

Running them as peer orchestrators creates ambiguous ownership: two systems may
select scope, mutate the same lane, interpret findings, run different proof,
or attempt the shipping tail. The result is difficult to resume, audit, and
review even when each system is individually useful.

CE also provides narrower capabilities that Agent Workflows does not need to
reimplement, including project-grounded point-of-view research, specialized
review lenses, and durable project learning capture.

## Decision

Agent Workflows is the sole delivery orchestrator whenever the two systems are
used together. It owns:

- target intake, trust preflight, claims, scope, and worktree isolation;
- repository policy and the consumer `AGENTS.md` seam;
- proof selection, finding disposition, and merge-readiness evidence;
- the final commit policy, push, pull request, CI, review follow-up, and
  closeout.

CE may run as an optional inner method inside that lane. The caller must choose
a CE mode that returns control before the shipping tail:

- use `ce-pov` for a bounded external decision;
- use `ce-work mode:return-to-caller <plan-path>` only inside the already-owned
  lane;
- use `ce-code-review mode:agent` when the result must be report-only;
- use at most one mutating simplifier, followed by Agent Workflows validation
  and review;
- use `ce-compound` only where the consumer repository has explicitly chosen
  the destination and knowledge schema.

Do not nest CE `lfg` or `ce-commit-push-pr` inside an Agent Workflows lane.
Those workflows own commits, push, pull-request creation, and possibly CI, so
they conflict with the outer orchestrator.

CE-created local edits or commits are evidence inside the lane, not a transfer
of ownership. Agent Workflows still inspects their scope, applies repository
policy, runs the required proof, and decides what is published.

## Consequences

Benefits:

- One system remains accountable for lane state, mutations, findings, and
  readiness.
- CE capabilities can be evaluated independently without copying them into the
  Agent Workflows source pack.
- A failed or low-value CE experiment can be removed without changing the
  delivery contract.
- Handoffs and audits have one source of truth for scope and gate state.

Trade-offs:

- Some CE end-to-end workflows cannot be used unchanged inside an Agent
  Workflows lane.
- The coordinator must choose non-shipping or report-only CE modes explicitly.
- Any CE mutation requires another Agent Workflows proof and review cycle.
- CE knowledge capture remains consumer-specific until the destination and
  schema are compatible with that repository.

## Rejected Options

### Let CE Own The Entire Lane

This is valid when CE is used alone, but it discards Agent Workflows claims,
repo seams, verification, review triage, CI routing, and closeout contracts. It
is not the coexistence model.

### Run Both Systems As Peer Orchestrators

Peer ownership makes mutation, finding disposition, and shipping authority
ambiguous. Agreement between two agents does not resolve that state conflict.

### Copy CE Workflows Into Agent Workflows

Vendoring CE prompts would create two drifting implementations and erase the
ability to evaluate CE as an independently versioned tool. Agent Workflows may
adopt proven discipline improvements, but it should not clone CE's reviewer or
simplifier fleets.

## Operational Guidance

See [Using Compound Engineering With Agent Workflows](../compound-engineering.md)
for installation, skill selection, sequencing, and pilot evidence.
