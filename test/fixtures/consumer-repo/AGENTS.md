# Fixture Consumer Repo

This fixture exists so `bin/validate` can prove that the shared workflow pack
resolves a consumer repo binstub contract when scanned as an installed shared
root.

## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.
