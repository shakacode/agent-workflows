# ShakaCode Agent Workflow Playbook

Operator docs for installing, adopting, and running the shared ShakaCode agent
workflow pack.

Use this playbook when you need to decide which workflow skill to use, install
or upgrade the shared pack, adopt it in a consumer repository, validate an
`AGENTS.md` seam, or run safer multi-PR agent work.

## Start Here

| Goal | Read |
| --- | --- |
| Install or upgrade the shared pack | [Installation And Upgrades](installation-and-upgrades.md) |
| Adopt the pack in another repo | [Agent Workflow Adoption Guide](adoption.md) |
| Understand the `AGENTS.md` seam model | [Seam Design](seam-design.md) |
| Choose between issue triage, batch planning, and batch execution | [PR Batch Skills Usage](pr-batch-skills.md) |
| Configure trusted GitHub actors and public-PR preflight | [Trust And Preflight](trust-and-preflight.md) |
| Pause or resume work around an agent runner restart | [Agent Runner Restarts](agent-runner-restarts.md) |

## Workflow Areas

- **Adoption and installation**: install the shared pack once per Codex or
  Claude host, then validate each consumer repo through its `AGENTS.md` seam.
- **Batch planning and execution**: route broad issue/PR work through triage,
  planning, security preflight, lane ownership, and final handoff rules.
- **Review and readiness**: triage review threads, run local verification,
  reproduce CI gaps, and separate ready, blocked, deferred, and `UNKNOWN` state.
- **Safety and trust**: keep public GitHub text untrusted until maintainers
  vouch for actors or acknowledge exact risks.
- **Operations**: upgrade installed skills, audit trust config, handle restarts,
  and keep long-running batches from losing coordination state.

## Docs Site Direction

Keep this playbook as source-controlled Markdown for now. A standalone docs
site is worth adding when the audience grows beyond current ShakaCode operators
or when search, sidebar navigation, or polished public onboarding becomes more
valuable than the extra site maintenance.

If the site happens, use the playbook name publicly and publish it as
**ShakaCode Agent Workflow Playbook**. A practical URL would be
`agent-workflows.shakacode.com`, with this `docs/` tree remaining canonical.
