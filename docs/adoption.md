# Agent Workflow Adoption Guide

Use this guide to make the shared agent workflows available in another
repository without copying another repo's policy into that repo.

The default model is:

- shared skills are installed in the user or agent environment
- each repo owns command wrappers in `.agents/bin/`
- each repo owns non-command policy in `.agents/agent-workflow.yml`
- each repo owns durable PR-batch actor trust in `.agents/trusted-github-actors.yml`
- `AGENTS.md` points agents to those two sources
- repo-pinned copies are optional and justified case by case

See [seam-design.md](seam-design.md) for the design rationale. See
[installation-and-upgrades.md](installation-and-upgrades.md) for host install
paths, upgrade commands, status states, rollback behavior, and Codex/Claude
notes.

## One-Time Adoption

1. **Inventory the target repo.** Identify base branch, package managers,
   setup/build/lint/format/test/type-check/docs commands, local CI routing,
   hosted-CI trigger, labels, changelog policy, release boundaries, generated
   files, protected-branch requirements, review bots, and which checks are cheap
   locally versus reserved for hosted CI.

2. **Install or enable the shared skills for the user/agent.** Clone
   [`shakacode/agent-workflows`](https://github.com/shakacode/agent-workflows)
   and use `bin/install-agent-workflows --host codex` or
   `bin/install-agent-workflows --host claude`, or use the agent platform's
   normal user-skill installation mechanism.

3. **Add command wrappers.** Create `.agents/bin/README.md` and executable
   wrappers for the repo's standard commands. `validate` is the comprehensive
   pre-push gate; `test` is the narrow test entry point. Optional scripts such
   as `setup`, `lint`, `build`, `docs`, and `ci-detect` are present only when
   the repo supports them.

4. **Add policy YAML.** Create `.agents/agent-workflow.yml` with required
   non-command policy keys: `base_branch`, `follow_up_prefix`, `review_gate`,
   `approval_exempt`, `coordination_backend`, `changelog`, `benchmark_labels`,
   `merge_ledger`, `ci_parity_environment`, `hosted_ci_trigger`, and
   `ci_change_detector`. Use `n/a` for unavailable policy.

5. **Add repo-local trust YAML.** Create `.agents/trusted-github-actors.yml`
   when PR-batch preflight should trust repo-specific maintainers, teams, or
   automation. The preflight resolution order is `--trust-config`, repo-local
   `.agents/trusted-github-actors.yml`, `$AGENT_WORKFLOWS_TRUST_CONFIG`,
   `~/.agents/trusted-github-actors.yml`, then the packaged empty fallback.
   Keep the packaged fallback empty. For `shakacode/react_on_rails`, the
   bootstrap repo-local trust file should list `justin808` under
   `trusted_users` unless maintainers verify and choose a narrower team slug.

6. **Add the AGENTS pointer.** `AGENTS.md` stays canonical for human policy, but
   the workflow configuration section is only:

   ```markdown
   ## Agent Workflow Configuration

   Portable shared skills resolve this repo's commands and policy through:
   - **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
   - **Policy / config** — `.agents/agent-workflow.yml`.
   ```

7. **Keep repo-local skills local, but keep workflow references reachable.** Add
   only repo-specific skills, tiny compatibility launchers, or local validation
   helpers to the repo. Do not copy shared workflow text unless the execution
   environment cannot load user-installed skills.

8. **Validate the contract.** Run `agent-workflow-seam-doctor` from this shared
   pack with `--shared` pointing at the cloned or installed pack root. Then run
   one dry workflow pass without making changes.

9. **Make `AGENTS.md` canonical.** Tool-specific files such as `CLAUDE.md`
   should stay thin and link back to `AGENTS.md`.

## Command Wrappers

Simple wrapper:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec bundle exec rspec "$@"
```

Composed wrapper:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
"$root/.agents/bin/build"
"$root/.agents/bin/test"
```

Before opening a consumer PR, verify every wrapped command/task exists in that
repo. `bash -n` catches syntax errors, not missing package scripts or Rake tasks.

## Seam Validation

```bash
agent-workflow-seam-doctor --shared "${AGENT_WORKFLOWS_ROOT:?set path to shakacode/agent-workflows}"
```

For repos that keep the checker in the checkout:

```bash
.agents/bin/agent-workflow-seam-doctor --shared .agents
```

The checker fails when the pointer section is missing, core scripts are missing
or malformed, policy YAML is incomplete, or executable snippets in repo-local or
installed shared skill Markdown still contain unresolved placeholders such as
`<follow-up prefix>`.

## Keeping The Installed Pack Current

Use `agent-workflows-status` to check the installed pack against the recorded
source clone:

```bash
agent-workflows-status --host codex
```

Use `upgrade-agent-workflows` to update the source clone, reinstall, and run the
seam doctor against one or more consumer repos:

```bash
upgrade-agent-workflows \
  --host codex \
  --consumer-root /path/to/consumer/repo
```

## Shared Vs Repo-Local Skills

Shared portable skills include PR batching, review handling, post-merge audit,
adversarial review, verification, CI routing, and changelog update workflows.
They should avoid repo-specific commands, labels, paths, and domain examples.

Repo-local skills are for domain-heavy or destructive workflows that do not make
sense everywhere.

## Optional Repo-Pinned Copies

A repo-pinned copy is useful only when a specific environment cannot load the
user-installed skill pack or when maintainers intentionally want shared workflow
updates reviewed in that repo. If a repo chooses that route:

- keep the pinned copy separate from repo-specific skills where possible
- document the source and version of the pinned copy
- do not customize shared files in place
- keep repo-specific command/policy values in `.agents/bin/` and
  `.agents/agent-workflow.yml`
- run the seam doctor with `--shared` after every sync or update

## Validation Checklist

- `agent-workflows-status --host <codex|claude>` reports `UP_TO_DATE`, or the
  upgrade decision is recorded.
- `agent-workflow-seam-doctor --shared <path-to-shakacode/agent-workflows>` passes.
- Every generated wrapper's underlying command exists in the target repo.
- `pr-security-preflight --repo OWNER/REPO --trust-config .agents/trusted-github-actors.yml <exact-targets>`
  reports `SECURITY_PREFLIGHT_OK` for maintainer-approved exact targets.
- Markdown formatting and link checks pass for edited docs.
- A dry run of `$pr-batch` stops with an exact target list and goal prompt
  before spawning workers.

## Suggested Adoption PR Summary

```markdown
## Summary

- add standard `.agents/bin/*` wrappers for portable shared agent skills
- add non-command policy in `.agents/agent-workflow.yml`
- point `AGENTS.md` at the command and policy contract

## Validation

- `agent-workflow-seam-doctor --shared <path-to-shakacode/agent-workflows>`
- verified wrapped commands exist
- markdown formatting + link check
```
