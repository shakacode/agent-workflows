# AGENTS.md

Instructions for agents working on `shakacode/agent-workflows`.

This repo publishes portable agent workflow skills. Keep shared process generic
and push repository-specific policy into each consumer repo's `AGENTS.md` seam.

## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.

## Editing Rules

- Keep `skills/*/SKILL.md` concise and portable.
- Do not hardcode consumer repo commands, labels, branches, release trackers, or
  package paths in shared skills.
- When a workflow needs repo-specific values, name the corresponding
  `AGENTS.md` seam key instead of embedding an example command.
- Keep helper scripts in the skill folder that invokes them, unless the helper is
  repo-wide like `bin/agent-workflow-seam-doctor`.
- Do not add repo-local domain skills here. Domain skills belong in the consumer
  repo.
- Keep root documentation user-facing. Do not add extra README files inside
  individual skill folders.

## Validation

Before committing, run:

```bash
bin/validate
```

For changes to a specific helper, run the relevant helper test directly as well.
Examples:

```bash
ruby skills/pr-batch/bin/pr-security-preflight-test.rb
ruby skills/plan-pr-batch/bin/pr-file-touch-map-test.rb
bash skills/post-merge-audit/bin/post-merge-audit-scope-test.bash
```

## Release And Adoption Notes

This repo is a source pack. Consumers normally install it into an agent home,
then validate each consumer checkout with:

```bash
agent-workflow-seam-doctor --shared /path/to/agent-workflows
```

If a consumer repo pins local copies for compatibility, update those copies from
this repo and rerun the seam doctor with the pinned copy as `--shared`.
Use `agent-workflows-status` and `upgrade-agent-workflows` for installed
Codex/Claude homes; see `docs/installation-and-upgrades.md`.
