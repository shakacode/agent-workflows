# ADR 0004: Compose Superpowers Inside Agent Workflows

Date: 2026-08-24
Status: accepted

## Context

Agent Workflows and Superpowers are both complete software-delivery
methodologies. They overlap at skill routing, requirements and planning,
test-driven implementation, subagent execution, worktree management, review,
verification, commits, and pull-request closeout.

Running both complete packs as peers creates ambiguous authority:

- two planners can produce incompatible scope and artifact requirements;
- two executors can dispatch workers against the same task or lane;
- two worktree owners can create, mutate, or clean the same workspace;
- two review and verification loops can duplicate work or disagree about proof;
  and
- two shipping tails can commit, push, open pull requests, or declare completion
  under different policies.

Superpowers also contains individual techniques that may be useful inside an
already-owned Agent Workflows lane. Evaluating one technique does not require
transferring delivery ownership to the complete Superpowers methodology.

## Decision

Agent Workflows is the sole delivery orchestrator whenever both packs are
present in one host profile or task. It owns:

- repository policy and the consumer `AGENTS.md` seam;
- target intake, trust preflight, scope, claims, dependencies, and worktree
  isolation;
- worker and reviewer dispatch, proof selection, finding disposition, and
  merge-readiness evidence; and
- commit policy, push, pull-request creation or update, CI, review follow-up,
  merge sequencing, and closeout.

Superpowers may be used only as a bounded inner technique selected by the Agent
Workflows coordinator. The invocation must name the selected technique, input,
expected return artifact, allowed mutations, verification, and stop point. It
must return control before worktree creation, task ownership, subagent dispatch,
commit, push, pull-request, merge, cleanup, or closeout unless the outer Agent
Workflows lane explicitly performs that action itself.

The normal Agent Workflows profile keeps the complete Superpowers plugin
disabled. Experiments use a disposable Codex home and disposable repository
copy pinned to immutable revisions. A successful experiment may justify
adapting a technique into Agent Workflows with repository-owned tests and
attribution; it does not justify running two peer orchestrators.

`agent-workflows-status` reports the observed Codex Superpowers catalog state as
one of `active`, `installed-disabled`, `available-not-installed`, or `UNKNOWN`.
The diagnostic is advisory. It reads host state but never installs, enables,
disables, removes, upgrades, or rewrites plugin configuration. An `active`
result warns about the ownership boundary without changing the command's Agent
Workflows status or exit code.

Marketplace/catalog version and upstream version are separate facts. A
host-managed marketplace refresh advances its own snapshot; it does not prove
that the catalog package matches the newest upstream release. Upstream version
claims require independent immutable tag and commit evidence.

## Consequences

Benefits:

- One orchestrator remains accountable for every mutation and readiness claim.
- Individual Superpowers techniques can be compared without changing the
  normal profile or delivery contract.
- The diagnostic makes accidental peer-orchestrator activation visible without
  mutating user configuration.
- Promotion decisions have reproducible evidence and explicit provenance.

Trade-offs:

- Superpowers end-to-end workflows cannot run unchanged inside an Agent
  Workflows lane.
- Pilot setup is intentionally disposable and requires exact revision and
  evidence capture.
- Marketplace and upstream versions may differ and must be investigated as two
  independent supply paths.
- Useful techniques require adaptation, attribution, and new Agent Workflows
  tests before they become repository-owned behavior.

## Rejected Options

### Run Both Complete Packs As Peer Orchestrators

Peer ownership leaves planning, mutation, proof, and shipping authority
ambiguous. Agreement between two agents does not resolve conflicting lifecycle
state or make the result resumable.

### Let Superpowers Take Over An Agent Workflows Lane

This discards the lane's repository seam, scope, claims, dependencies,
verification, review disposition, and closeout contract. Superpowers can be the
sole orchestrator when used independently, but that is not coexistence inside
an Agent Workflows lane.

### Enable Superpowers In The Normal Profile For Evaluation

This makes experimental routing global and can affect unrelated tasks. A
disposable home and repository copy provide the same evaluation surface with a
clear cleanup boundary.

### Treat Marketplace Refresh As Upstream Synchronization

Marketplace snapshots and upstream releases have different owners, revision
identities, and refresh timing. Conflating them hides provenance drift.

## Operational Guidance

See [Using Superpowers With Agent Workflows](../superpowers.md) for the pinned
Codex pilot, diagnostic states, evidence rubric, and attribution.
