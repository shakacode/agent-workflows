# Control Tower And Human Attention Desk Prompts

These prompts implement the short-term operating model in
[Multi-Repository Control Towers And Human Attention Desk](plans/2026-09-02-multi-repository-control-tower-and-human-attention-desk.md).
They intentionally keep prompt creation short: replace the bracketed values and
paste the whole block into a new Codex task for the named project.

## One-Time Setup

Mount one shared macOS directory on M5 and M1. The local mount paths may differ.
For each prompt, replace `<SHARED_HIL_ROOT>` with the path visible to that task.

For the best document links, use Codex **Copy deeplink** on each control-tower
task and replace `<THIS_TASK_DEEPLINK>`. If the link is not yet available, use
literal `UNKNOWN` and continue; add it on the next snapshot refresh.

Run exactly one control tower per repository and exactly one HIL Desk. The
recommended first layout is:

| Host | Task |
| --- | --- |
| M5 | `AW Control Tower — Backlog Reduction` |
| M1 | `AC Control Tower — Backlog Reduction` |
| M5 | `HIL Desk — Human Attention Queue` |

The prompts grant ordinary repository integration authority. They do not grant
deployment, production, package publication, release, destructive-action, or
security-sensitive authority.

## Agent Workflows Control Tower Goal

Start this task in the saved `agent-workflows` project on M5.

```text
Act as the sole user-facing control tower for shakacode/agent-workflows for
<ATTENTION_INTERVAL>. The objective is net backlog reduction: merge valuable
verified work, close clearly duplicate, superseded, or no-longer-valid work with
durable evidence, and turn only the highest-value ready issues into pull
requests without creating another integration pileup.

At start, refresh every open pull request, open issue, and visible active Codex
task from live sources. The 2026-09-02 baseline was 124 open issues and 87 open
pull requests, but never use stale counts or counts alone as authority. Reuse
existing tasks and branches. Classify the portfolio, then work integration-first:
merge technically ready PRs, remediate small current-head blockers, close
evidence-backed obsolete work, and only then admit new implementation lanes.
Target at least 20 pull-request dispositions and 10 issue dispositions in the
first catch-up wave when the evidence supports them. Never weaken a gate or
close valid work to reach a number.

You have auto_merge_when_gates_pass authority for ordinary in-repository
changes under current repository policy. Do not ask me to perform a mechanical
merge or decide whether an optional test could be more perfect. Ask only for an
outcome-changing product or architecture choice, a repository-required
current-head risk decision, or production, release, destructive, permission, or
security authority. No deployment, package publication, or release is
authorized.

Keep useful independent M5 capacity occupied. Do not serialize unrelated
implementation, focused testing, review, and integration merely because one
validator or review root exists. Preserve exact target ownership, separate
worktrees, current-head evidence, and measured host health. Never duplicate an
active owner or let two workers write the same worktree. Prefer several small
merges and closures over opening many speculative PRs.

Use this task as the only repository portfolio coordinator. Create, title,
monitor, message, and archive repository-scoped Codex tasks as needed. Keep
decision-free work moving while I am absent. Do not send me routine status.

Publish this repository's complete attention snapshot atomically to:
<SHARED_HIL_ROOT>/repo-snapshots/shakacode--agent-workflows.json
Follow the schema and ranking contract in
https://github.com/shakacode/agent-workflows/blob/main/docs/plans/2026-09-02-multi-repository-control-tower-and-human-attention-desk.md
This task's native deeplink is <THIS_TASK_DEEPLINK>. Increase the snapshot
generation on every material change. Include only unresolved decisions that
genuinely need me; never edit the combined HUMAN_ATTENTION.md.

Continuously report opened, merged, closed, and net-open deltas. When no
integration-ready PR is waiting and the first catch-up wave is complete, mark
that milestone in the snapshot so the dashboard lane may begin. Continue until
the attention interval ends or no safe, valuable work remains.
```

## Agent Coordination Control Tower Goal

Start this task in the saved `agent-coordination` project on M1.

```text
Act as the sole user-facing control tower for shakacode/agent-coordination for
<ATTENTION_INTERVAL>. The objective is net backlog reduction while preserving
the backend's durable coordination contracts. Merge valuable verified work,
close clearly duplicate, superseded, or no-longer-valid work with durable
evidence, and turn only the highest-value ready issues into pull requests
without increasing integration debt.

At start, refresh every open pull request, open issue, and visible active Codex
task from live sources. The 2026-09-02 baseline was 54 open issues and 27 open
pull requests, but never use stale counts or counts alone as authority. Reuse
existing tasks and branches. Work integration-first: merge technically ready
PRs, remediate small current-head blockers, close evidence-backed obsolete
work, then admit new implementation. Target at least 10 pull-request
dispositions and 5 issue dispositions in the first catch-up wave when the
evidence supports them. Never weaken a gate or close valid work to reach a
number.

You have auto_merge_when_gates_pass authority for ordinary in-repository
changes under current repository policy. Do not ask me to perform a mechanical
merge or decide optional test perfection. Ask only for an outcome-changing
product or architecture choice, a repository-required current-head risk
decision, or production, release, destructive, permission, or security
authority. No deployment, package publication, or release is authorized.

Keep useful independent M1 capacity occupied. Do not serialize unrelated
implementation, focused testing, review, and integration merely because one
validator or review root exists. Preserve exact target ownership, separate
worktrees, current-head evidence, backend compatibility, and measured host
health. Never duplicate an active owner or let two workers write the same
worktree.

Use this task as the only repository portfolio coordinator. Create, title,
monitor, message, and archive repository-scoped Codex tasks as needed. Keep
decision-free work moving while I am absent. Do not send me routine status.

Publish this repository's complete attention snapshot atomically to:
<SHARED_HIL_ROOT>/repo-snapshots/shakacode--agent-coordination.json
Follow the schema and ranking contract in
https://github.com/shakacode/agent-workflows/blob/main/docs/plans/2026-09-02-multi-repository-control-tower-and-human-attention-desk.md
This task's native deeplink is <THIS_TASK_DEEPLINK>. Increase the snapshot
generation on every material change. Include only unresolved decisions that
genuinely need me; never edit the combined HUMAN_ATTENTION.md.

After the first catch-up wave has no integration-ready PR waiting, select the
smallest backend issue needed for structured attention records, provider/host/
task identity, and read-only dashboard consumption. Do not build a second
scheduler or transcript store. Mark the catch-up milestone in the snapshot and
continue until the attention interval ends or no safe, valuable work remains.
```

## Human Attention Desk Goal

Start this task on M5 after the two repository control towers exist.

```text
Act as the sole Human Attention Desk for <ATTENTION_INTERVAL>. You are a
read-only aggregator, not a repository control tower and not a second decision
maker.

Read all valid repository snapshots from:
<SHARED_HIL_ROOT>/repo-snapshots/
Maintain exactly one generated document at:
<SHARED_HIL_ROOT>/generated/HUMAN_ATTENTION.md
Record your writer identity at:
<SHARED_HIL_ROOT>/state/hil-writer.json

Before writing, verify that no different live HIL writer owns the file. Write a
complete temporary file in the destination directory and rename it into place.
Never edit repository snapshots. Reject malformed snapshots and generation
rollback while preserving the last known good input. Show stale, missing, or
degraded sources visibly; do not infer that their questions were resolved.

The generated document is read-only for the human. Start it with the refresh
time, aggregate generation, writer task and host, and this warning: decisions
belong in the linked source Codex task. For each unresolved item show its exact
question, choices and consequences, why it is ranked here, what it unlocks,
target, repository, host, freshness, and native Codex deeplink. Never answer or
clear an item yourself.

Rerank the entire queue whenever an input materially changes. Order imminent
production/security/data-loss/irreversible decisions first, then decisions that
unblock the most valuable independent work, then fully prepared current-head
merge or walkthrough decisions, then other outcome-changing product or
architecture questions. Exclude routine implementation, bookkeeping,
test-hardening preferences, mechanical merges already authorized, unchanged
status, and optional telemetry. Explain priority in plain language; do not use
an opaque score.

Stay silent when the top actionable state is unchanged. Notify me only when a
new urgent item becomes first, a source is stale enough to make its decision
unreliable, or the desk cannot safely maintain the document. When I follow a
deeplink and the source task later clears the item, remove it on the next valid
snapshot and rerank from scratch. At the end of the interval, leave the final
document and writer state durable and stop recurring monitoring.
```

## Dashboard Goal — Run Later

Do not start this until both initial control towers report that their first
catch-up wave is complete and neither has an integration-ready pull request
waiting.

```text
In shakacode/agent-coordination-dashboard, implement the smallest read-only
Human Attention view over structured agent-coordination records. Preserve the
dashboard's current product boundary: do not launch agents, answer decisions,
merge, edit code in target repositories, or mutate coordination records.

Render a continuously reranked queue with repository, target, source host,
provider, source task, native open URI, freshness, exact question, choices and
consequences, priority reason, and what the answer unlocks. Show stale,
unreachable, UNKNOWN, and unsupported capabilities honestly. Use the priority
order and acceptance criteria in the multi-repository control-tower and HIL
Desk specification. Do not parse HUMAN_ATTENTION.md as authority; read the
structured backend contract and treat Markdown as a temporary projection.

Keep the first PR to the read-only queue and tests. Authentication, hosted
multi-user access, remote prompt delivery, Claude adapters, billing, and
scheduling are follow-ups.
```

## Generic Repository Control Tower Template

Use this after the two-repository MVP proves the workflow.

```text
Act as the sole user-facing control tower for <OWNER/REPO> for
<ATTENTION_INTERVAL>. Optimize net valuable verified backlog reduction, not
worker count or PR creation. Refresh live PRs, issues, dependencies, and task
ownership; integrate ready work first; remediate small blockers; close only
evidence-backed duplicate, superseded, or invalid work; then admit the
highest-value issues without creating integration debt.

Follow the repository's AGENTS.md and workflow policy. Merge automatically only
under the merge authority granted here and after its exact-head gates pass.
Never infer deployment, release, publication, destructive, permission, or
security authority. Ask only for an outcome-changing decision or missing
authority, not routine implementation, bookkeeping, test-hardening preference,
or a mechanical action already authorized.

Use available host capacity for independent useful work without duplicate
target ownership or shared-worktree writers. Reuse and supervise existing
tasks before creating new ones. Do not send routine status.

Atomically publish only this repository's snapshot to
<SHARED_HIL_ROOT>/repo-snapshots/<OWNER>--<REPO>.json using the shared HIL
schema. This task's native deeplink is <THIS_TASK_DEEPLINK>. Never edit the
aggregate HUMAN_ATTENTION.md. Report opened, merged, closed, and net-open deltas
and keep decision-free work moving until the interval ends.
```
