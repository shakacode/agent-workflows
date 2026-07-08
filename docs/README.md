# ShakaCode Agent Workflow Playbook

Guide for installing, adopting, and running the shared ShakaCode agent workflow
pack.

Use this playbook when you need to decide which workflow skill to use, install
or upgrade the shared pack, adopt it in a consumer repository, validate an
agent workflow contract, or run safer multi-PR agent work.

## Start Here

These are the most common entry points.

| Goal | Read |
| --- | --- |
| Install or upgrade the shared pack | [Installation And Upgrades](installation-and-upgrades.md) |
| Adopt the pack in another repo | [Agent Workflow Adoption Guide](adoption.md) |
| Understand the agent workflow contract model | [Seam Design](seam-design.md) |
| Choose between issue triage, batch planning, and batch execution | [PR Batch Skills Usage](pr-batch-skills.md) |
| Configure trusted GitHub actors and public-PR preflight | [Trust And Preflight](trust-and-preflight.md) |
| Understand the broader prompt-injection safety posture | [Security Posture](security-posture.md) |
| Pause or resume work around an agent runner restart | [Agent Runner Restarts](agent-runner-restarts.md) |

## Reference Index

| Area | Read |
| --- | --- |
| Maintainer sync across consumer repos | [Maintainer Consumer Repo Sync](downstream-sync.md) |
| Coordination backend behavior | [Coordination Backend](coordination-backend.md) |
| Issue value and scope decisions | [Issue Evaluation](issue-evaluation.md) |
| Release branch policy | [Release Branching](release-branching.md) |
| Review finding schema | [Review Finding Schema](review-finding-schema.md) |
| Host adapter contract | [Host Adapter Contract](host-adapter/contract.md) |
| Architecture decisions | [ADR: Identical Skill Text Across Hosts](adr/0001-identical-skill-text-across-hosts.md) |
| Troubleshooting playbooks | [Solutions](solutions/README.md) |

## Workflow Areas

- **Adoption and installation**: install the shared pack once per Codex or
  Claude host, then validate each consumer repo through its `.agents/bin/`
  wrappers, `.agents/agent-workflow.yml`, and `AGENTS.md` pointer.
- **Batch planning and execution**: route broad issue/PR work through triage,
  planning, security preflight, lane ownership, and final handoff rules.
- **Review and readiness**: triage review threads, run local verification,
  reproduce CI gaps, and separate ready, blocked, deferred, and `UNKNOWN` state.
- **Safety and trust**: keep public GitHub text untrusted until maintainers
  vouch for actors or acknowledge exact risks.
- **Operations**: upgrade installed skills, audit trust config, handle restarts,
  and keep long-running batches from losing coordination state.

## Docs Site Direction

This playbook is the source of truth for team and client sharing. A standalone
docs site can be added when search, sidebar navigation, or a hosted public URL
would make adoption easier than source-controlled Markdown alone.

If the site happens, use the playbook name publicly and publish it as
**ShakaCode Agent Workflow Playbook**. A practical URL would be
`agent-workflows.shakacode.com`, with this `docs/` tree remaining canonical.
