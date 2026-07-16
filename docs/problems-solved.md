# Problems Agent Workflows Solves

Agent Workflows gives engineering teams a shared operating model for Codex and
Claude Code across many repositories. The Source Pack distributes reusable
process, each repository keeps its own execution and policy seam, and an
optional coordination layer makes concurrent work visible and recoverable.

The layers are separate on purpose:

- **Distribution** gets the same reviewed workflows to the people and agent
  hosts that need them.
- **Repository adaptation** binds those workflows to each repo's commands,
  trust, CI, review, and release rules.
- **Coordination** answers who owns work, what is still alive, and how work is
  handed off or recovered when multiple agent sessions run concurrently.

## Distribute Skills Across A Team And Many Repositories

**Without this:** teams copy skills into personal configuration or vendor a
full workflow tree into every repository. No one can easily answer which copy
is canonical, which version a developer is running, or whether a local edit is
an intentional specialization. Shared improvements arrive unevenly, while
repo-specific policy can leak back into the shared workflow.

**With this:** the `agent-workflows` Source Pack is the canonical shared source.
Each developer installs it once per agent host, either with the host installer
or through that host's native `scw` plugin and marketplace route. Consumer repos
keep only the small seam that the shared workflows resolve at runtime.

Codex and Claude Code are equal delivery targets for the same shared content:

| Distribution layer | Codex | Claude Code |
| --- | --- | --- |
| Shared workflow source | The Source Pack's `skills/` and `workflows/` | The same `skills/` and `workflows/` |
| Host installer | `bin/install-agent-workflows --host codex` | `bin/install-agent-workflows --host claude` |
| Native plugin | `scw` through the Codex marketplace manifest | `scw` through the Claude marketplace manifest |
| Repository contract | The repo-owned `.agents/` seam and `AGENTS.md` pointer | The same repo-owned `.agents/` seam and `AGENTS.md` pointer |
| Status and upgrades | Shared helpers manage installer assets; Codex manages native-plugin updates | The same helpers manage installer assets; Claude Code manages native-plugin updates |

ShakaCode maintainers can roll seam changes across the registered consumer fleet
with one pull request per repository. The
[maintainer sync](downstream-sync.md) updates the contract shape while
preserving repo-owned commands and policy; it never copies the shared skill or
workflow content into consumer repos. That command is ShakaCode-specific today,
so another organization would supply its own registry and presets rather than
inherit ShakaCode policy.

Avoiding copies prevents most drift. When a constrained environment must pin a
local copy, record its Source Pack revision and compare it against that source.
[Issue #23](https://github.com/shakacode/agent-workflows/issues/23) documents
what happens without that safeguard: shared workflow files evolved independently
in the Source Pack and a consumer repo, including security-relevant helpers.
Durable pinned-copy drift detection remains work to complete, not a capability
this project claims today.

## Keep Shared Process Portable Without Flattening Repository Policy

**Without this:** a supposedly reusable skill accumulates hard-coded branch
names, package commands, labels, trusted actors, CI assumptions, and release
rules from whichever repository changed it last. The workflow becomes unsafe in
other repos, or forks into repo-specific variants that cannot be improved as one
system.

**With this:** shared skills describe the process, and each consumer repository
owns the facts needed to run that process:

- `.agents/bin/` exposes the repo's real setup, validation, test, lint, build,
  docs, and CI entry points;
- `.agents/agent-workflow.yml` exposes non-command workflow policy;
- `.agents/trusted-github-actors.yml` records repo-specific trust decisions;
- `AGENTS.md` remains the human-readable authority and points to the seam.

The [seam doctor](adoption.md#seam-validation) validates that the installed
workflows can resolve this contract. Missing required capabilities and ambiguous
or malformed configuration fail closed; absent optional wrappers are treated as
`n/a`.

## Make Agent Work Repeatable And Reviewable

**Without this:** every agent session invents its own path from issue to pull
request. Trust checks, scope boundaries, local verification, hosted CI,
review-thread handling, changelog updates, and post-merge checks become prompt
quality rather than an engineering process.

**With this:** portable skills provide named, reviewable workflows for planning,
batching, implementation, verification, review, CI recovery, and audit. Public
GitHub content remains untrusted after the configured defense-in-depth
preflight, and each repo supplies the commands and policy those workflows must
respect.

This makes the operating model inspectable: teams can review the shared process
once, review each repo's smaller seam locally, and improve either layer without
silently rewriting the other.

## Coordinate Concurrent Work Without Losing Ownership Or Context

**Without this:** multiple agent sessions can start the same issue or branch,
collide after substantial work, disappear without an observable handoff, or
leave operators unable to tell whether a quiet lane is running, blocked, stale,
or dead. Important recovery context can exist only inside a chat that is no
longer available.

**With this:** the optional coordination layer provides a shared answer to five
operational questions:

1. **Ownership:** who currently owns this target?
2. **Collision prevention:** should another session be allowed to start it?
3. **Liveness:** is the owning instance live, stale, or dead, or is its liveness
   unknown?
4. **Handoff:** what must the next operator or agent know to continue safely?
5. **Recovery:** how can work resume after a session, app, or machine disappears?

These are protocol-level responsibilities, independent of the current storage
or service implementation. Repositories that run serially or one agent at a
time can declare coordination unavailable and still use the process skills. See
[Coordination Backend](coordination-backend.md) for the workflow contract.

## What Exists Today And What Is Roadmap

Agent Workflows currently provides:

- one portable Source Pack with equal Codex and Claude Code skill text;
- host installers and native `scw` plugin manifests for both hosts;
- repo-owned seams plus initialization and validation tooling;
- installed-pack status, upgrade, rollback, and trust-audit helpers;
- ShakaCode's one-PR-per-repo maintainer fanout for seam changes;
- trust-gated planning, execution, review, verification, and audit workflows;
- an optional, backend-neutral coordination contract.

Large organizations also need governance above these project-level mechanics.
The following are roadmap and customer-discovery areas, not current claims:

- organization-approved catalogs and accountable workflow owners;
- release channels, canary groups, version pins, and rollback policy;
- fleet inventory showing which hosts, teams, and repos run which versions;
- audit evidence for installation, policy, and workflow execution;
- deprecation, migration, and retirement paths for obsolete skills.

Keeping that boundary explicit lets teams adopt the working layers now without
mistaking a source pack and coordination protocol for a finished enterprise
control plane.

## Adoption Path

1. Choose the shared workflows that belong in the Source Pack and keep domain
   workflows in their owning repos.
2. Install one delivery route on each Codex and Claude Code host that needs the
   pack.
3. Initialize and review each consumer repo's workflow seam.
4. Validate a canary repo, then use ShakaCode's maintainer sync—or your
   organization's equivalent registry/fanout process—for one focused PR per
   additional repo.
5. Add coordination when concurrency, multiple machines, or multiple operators
   create an ownership and recovery problem.
6. Revisit the enterprise-governance roadmap using evidence from the rollout.

Start with [Installation And Upgrades](installation-and-upgrades.md) for host
delivery and the [Agent Workflow Adoption Guide](adoption.md) for consumer repo
setup.
