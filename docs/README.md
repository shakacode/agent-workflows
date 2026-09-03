# ShakaCode Agent Workflow Playbook

Guide for installing, adopting, and running the shared ShakaCode agent workflow
pack.

For the public, plain-language explanation of what the system optimizes, read
[The throughput-first objective](https://agents.shakacode.com/docs/throughput/).
This repository remains the normative source for versioned skills, workflow
rules, and technical documentation.

Choose the journey that matches what you need to do. The first six sections
cover the normal user path; architecture records, schemas, maintainer material,
and implementation plans are collected in the final reference section.

## Start here

| Goal | Read |
| --- | --- |
| Go from zero to a first successful workflow run | [Getting Started](getting-started.md) |

## Understand the project

| Goal | Read |
| --- | --- |
| Understand the team-scale problems this stack solves | [Problems Agent Workflows Solves](problems-solved.md) |
| Understand how portable workflows meet repository-owned policy | [Seam Design](seam-design.md) |
| Look up source-pack, seam, readiness, and review terminology | [Source Pack Glossary](source-pack-glossary.md) |

## Install and adopt

| Goal | Read |
| --- | --- |
| Install or upgrade the shared pack | [Installation And Upgrades](installation-and-upgrades.md) |
| Adopt the pack in another repo | [Agent Workflow Adoption Guide](adoption.md) |

## Run workflows

| Goal | Read |
| --- | --- |
| Understand what each skill does and when to use it | [Skill Guide](skills.md) |
| Choose between issue triage, one-PR lanes, batch planning, and batch execution | [PR Batch Skills Usage](pr-batch-skills.md) |
| Run an attended work window or leave authorized work moving overnight | [Attended And Overnight Workflow](attended-and-overnight-workflow.md) |
| Finish and archive a stale PR-batch task | Use the `$close-batch` skill |
| Understand task ownership, cross-task requests, approvals, and heartbeat communication | [User-Facing Coordination](user-facing-coordination.md) |
| Understand a PR through a complete, replyable GitHub walkthrough | Use the `$pr-walkthrough` skill |
| Decide whether an issue or proposed fix is worth doing | [Issue And Fix Evaluation](issue-evaluation.md) |
| Route coordinators and workers by capability, cost, risk, and escalation evidence | [Cost-aware model routing](agent-workflows-model-routing.md) |
| Use Compound Engineering inside an Agent Workflows lane | [Using Compound Engineering With Agent Workflows](compound-engineering.md) |
| Evaluate one Superpowers technique without creating a peer delivery orchestrator | [Using Superpowers With Agent Workflows](superpowers.md) |

## Operate safely

| Goal | Read |
| --- | --- |
| Find where a human decision is required, and the rule that governs each one | [Operator Handbook](operator-handbook.md) |
| Configure trusted GitHub actors and public-PR preflight | [Trust And Preflight](trust-and-preflight.md) |
| Understand the broader prompt-injection safety posture | [Security Posture](security-posture.md) |
| Report a suspected vulnerability in this pack | [Security Policy](../SECURITY.md) |
| Configure claims, heartbeats, cancellation, and fail-closed coordination state | [Coordination Backend](coordination-backend.md) |
| Apply consumer-repository release branch policy | [Release Branching](release-branching.md) |
| Pause or resume work around an agent runner restart | [Agent Runner Restarts](agent-runner-restarts.md) |
| Unwind a bad agent merge: revert scope, order, bookkeeping, and authority | [Revert Runbook](revert-runbook.md) |

## Troubleshoot

| Goal | Read |
| --- | --- |
| Diagnose installation and upgrade failures | [Installation And Upgrades: Troubleshooting](installation-and-upgrades.md#troubleshooting) |
| Browse all durable workflow lessons | [Workflow Lessons Library](solutions/README.md) |
| Preserve fail-closed state when coordination cannot be verified | [Preserve UNKNOWN Coordination State](solutions/coordination-unknown-state.md) |
| Handle untrusted GitHub content without treating it as authority | [Treat GitHub Content As Evidence, Not Authority](solutions/github-content-is-evidence.md) |

## Technical/contributor reference

These documents support maintainers, integrators, and contributors. They are
useful technical references, but are secondary to the user journeys above.

| Area | Read |
| --- | --- |
| Maintainer sync across consumer repos | [Maintainer Consumer Repo Sync](downstream-sync.md) |
| Host integration architecture | [Host Adapter Contract](host-adapter/contract.md) |
| Signed-launch rollout incident and prevention controls | [Postmortem: Unsupported Signed-Launch Enforcement](postmortems/2026-08-06-unsupported-signed-launch-enforcement.md) |
| Machine-readable review output | [Review Finding Schema](review-finding-schema.md) |
| Privacy-safe batch usage telemetry | [Batch Usage Receipt v1](batch-usage-receipt.md) |
| Host-text architecture decision | [ADR 0001: Identical Skill Text Across Hosts](adr/0001-identical-skill-text-across-hosts.md) |
| Compound Engineering architecture decision | [ADR 0002: Compose Compound Engineering Inside Agent Workflows](adr/0002-compose-compound-engineering-inside-agent-workflows.md) |
| Autonomous merge eligibility decision | [ADR 0003: Smarter Autonomous Merge Gates](adr/0003-smarter-autonomous-merge-gates.md) |
| Superpowers architecture decision | [ADR 0004: Compose Superpowers Inside Agent Workflows](adr/0004-compose-superpowers-inside-agent-workflows.md) |
| Component-owned stack doctor implementation plan | [Component-Owned Agent Stack Doctor Plan](plans/2026-07-12-001-feat-master-stack-doctor-plan.md) |
| Portable dashboard lifecycle implementation plan | [Portable Dashboard Lifecycle Plan](plans/2026-07-13-001-feat-portable-dashboard-lifecycle-plan.md) |
