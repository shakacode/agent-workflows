# Agent Workflow Scripts

Standard entry points that portable agent-workflow skills call. A script that
is absent means that capability is n/a in this repository.

| Script | Purpose | This repo runs |
| --- | --- | --- |
| `setup` | Install dependencies | n/a |
| `validate` | Pre-push gate | `bin/validate` |
| `test` | Run tests | `bin/validate` (includes helper tests) |
| `lint` | Lint | `bin/lint` (RuboCop, ShellCheck, markdownlint-cli2, yamllint, and actionlint) |
| `build` | Build / type-check | n/a |
| `docs` | Docs checks | `bin/validate` plus manual link/path review |
| `ci-detect` | CI change detector | n/a |

Workflow policy lives in [`../agent-workflow.yml`](../agent-workflow.yml).
Operational policy lives in [`../agent-workflow-operational.yml`](../agent-workflow-operational.yml).
See the [operational compatibility policy](../../AGENTS.md#operational-compatibility-policy)
for how shared gates read the two files.
