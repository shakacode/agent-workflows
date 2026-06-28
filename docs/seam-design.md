# Portable Agent Workflows Via Binstubs And Policy YAML

Date: 2026-06-18
Status: approved direction, updated 2026-06-27

## Problem

The shared `pr-batch` family and related agent workflows should run across
ShakaCode repos without copying repo-specific commands, labels, branches,
release policy, paths, or domain examples into the shared pack. The original
inline `AGENTS.md` key/value seam was readable, but it made scripts parse prose
and encouraged large policy blocks inside every consumer `AGENTS.md`.

## Goal

Make the shared skills portable by installing them once in the user or agent
environment, then make each consumer repo expose a small, validated contract:

- commands are executable repo-owned binstubs under `.agents/bin/`
- non-command policy is structured YAML in `.agents/agent-workflow.yml`
- `AGENTS.md` points humans and agents at those two sources

## Architecture

```text
shakacode/agent-workflows
  skills/... and workflows/...        portable process, installed per user/agent
  bin/...                             install, status, upgrade, validation, sync helpers

consumer repo
  .agents/bin/README.md               command table for this repo
  .agents/bin/setup                   optional dependency setup
  .agents/bin/validate                required pre-push gate
  .agents/bin/test                    required test entry point
  .agents/bin/lint                    optional lint/format entry point
  .agents/bin/build                   optional build/type-check entry point
  .agents/bin/docs                    optional docs check entry point
  .agents/bin/ci-detect               optional CI routing entry point
  .agents/agent-workflow.yml          non-command policy
  AGENTS.md                           human guidance plus pointer section
  CLAUDE.md                           optional thin import of @AGENTS.md
```

The default distribution path remains this repository plus the user's normal
skill installation mechanism. Repository-pinned copies remain an escape hatch
for execution environments that cannot use user-installed shared skills.

## Command Contract

Portable skills call `.agents/bin/<name>` rather than embedding a target repo's
real commands. Each wrapper is a thin Bash script:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
exec bundle exec rspec "$@"
```

Composed scripts compute the root once and call siblings by absolute path:

```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
"$root/.agents/bin/build"
"$root/.agents/bin/test"
```

`validate` is the authoritative comprehensive pre-push gate. `test`, `lint`,
`build`, `docs`, and `ci-detect` are convenience subsets. An absent optional
script means that capability is n/a in that repo.

## Policy Contract

`.agents/agent-workflow.yml` carries non-command values:

- `base_branch`
- `follow_up_prefix`
- `review_gate`
- `approval_exempt`
- `coordination_backend`
- `changelog`
- `benchmark_labels`
- `merge_ledger`
- `ci_parity_environment`
- `hosted_ci_trigger`
- `ci_change_detector`

Repos may add policy keys such as `secret_redaction_patterns` when needed. Use
`n/a` for unavailable policy. Keep values terse and behavior-complete.

## AGENTS Pointer

Each consumer `AGENTS.md` owns a section named
`## Agent Workflow Configuration`, but the section is only a pointer:

```markdown
## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.
```

Consumer repos should keep broader human guidance in `AGENTS.md`, but command
resolution and workflow policy come from the binstubs and YAML.

## Seam Doctor

`agent-workflow-seam-doctor` validates the contract:

- `AGENTS.md` has the pointer section
- `.agents/bin/README.md` exists
- core scripts `validate` and `test` exist, are executable, pass `bash -n`, and
  include the repo-root `cd` preamble
- `.agents/agent-workflow.yml` parses and has all required policy keys with
  resolved values
- repo-local and supplied shared skill/workflow Markdown do not contain
  unresolved executable placeholders such as `<follow-up prefix>`

The doctor intentionally does not execute the wrappers. Before consumer PRs,
also verify that wrapped commands/tasks exist in the target repo.

## Why Not Subtree First

`git subtree` solves "every repo has a pinned copy of shared files," but the
primary problem is resolving repo-specific behavior safely. A subtree also makes
the `.agents/` prefix all-or-nothing, which is awkward when a repo has genuine
local skills. Use pinned copies only when an execution environment cannot depend
on user-installed skills or intentionally wants shared workflow updates reviewed
inside that repo.

## Validation

- `bin/validate`
- `ruby bin/agent-workflow-seam-doctor-test.rb`
- `ruby bin/push-downstream-test.rb`
- `bin/agent-workflow-seam-doctor --root <consumer-repo> --shared <this-repo>`
- Markdown review for edited docs
