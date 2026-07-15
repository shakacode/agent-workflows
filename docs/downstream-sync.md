# Maintainer Consumer Repo Sync

This is maintainer reference material for teams that manage many consumer repos.
It is not required for first-time adoption.

Use `bin/push-downstream` to roll the agent-workflow binstub contract into the
consumer repositories listed in `downstream.yml`, one pull request per repo.
The command never copies shared skill or workflow content into a consumer repo.

## What It Manages

`bin/push-downstream` owns the scaffold shape:

- `.agents/bin/<name>` wrappers for standard commands
- `.agents/bin/README.md`, refreshed on every run
- `.agents/agent-workflow.yml`, with missing policy keys seeded
- `.agents/trusted-github-actors.yml`, when a trust block is configured
- the `## Agent Workflow Configuration` pointer section in `AGENTS.md`
- a thin `CLAUDE.md` importing `@AGENTS.md`, only when `CLAUDE.md` is absent

Repos own the implementation details. Re-running the command preserves existing
script bodies and existing YAML values; it only adds missing scripts and missing
policy keys. Configured trust entries are appended to existing repo-local trust
lists, never to the packaged fallback. Trust layers are additive across
defaults, presets, and per-repo overrides, so `trust: {}` does not clear entries
from earlier layers. Omit `trust` to leave repo-local trust unmanaged; set
`trust: {}` only when no earlier layer contributes trust and you want an empty
fail-closed repo-local allowlist written. When new trust entries are appended,
the YAML is normalized and rewritten; keep durable security rationale in docs or
review notes rather than relying only on comments inside that YAML. A rich
existing `CLAUDE.md` is never clobbered. The PR body/stdout records a follow-up
to consolidate it later.

## Consumer Contract

Each adopting repo exposes commands through executable wrappers:

```text
.agents/bin/setup
.agents/bin/validate
.agents/bin/test
.agents/bin/lint
.agents/bin/build
.agents/bin/docs
.agents/bin/ci-detect
```

`validate` and `test` are core scripts and must exist. Other scripts are
optional; absence means that capability is n/a in that repo. Every wrapper must
be Bash, `set -euo pipefail`, and `cd` to the repo root before running the real
command. Composed wrappers, such as `validate = lint + test`, compute `root`
once and call sibling scripts by absolute path.

Non-command policy lives in `.agents/agent-workflow.yml`. Required keys are:

```yaml
base_branch: main
follow_up_prefix: "Follow-up:"
review_gate: "..."
approval_exempt: "..."
coordination_backend: "..."
changelog: "..."
benchmark_labels: "n/a"
merge_ledger: "n/a"
ci_parity_environment: "n/a"
hosted_ci_trigger: "n/a"
ci_change_detector: "n/a"
```

Use `n/a` for unavailable policy. Add repo-specific keys such as
`secret_redaction_patterns` when they are part of that repo's policy.

Repo-local trust lives in `.agents/trusted-github-actors.yml` and follows the
same resolution order as `pr-security-preflight`: `--trust-config`, repo-local
config, `$AGENT_WORKFLOWS_TRUST_CONFIG`, `~/.agents/trusted-github-actors.yml`,
then the packaged fail-closed fallback (`github-actions[bot]` metadata-only; no
humans or actionable bots). Use `trusted_users` for repo maintainers,
`trusted_bots` for bots whose bodies are trusted input, `trusted_metadata_bots`
for other CI/status comment authors, and repo-owner team slugs in `trusted_teams`.

`AGENTS.md` contains only the pointer:

```markdown
## Agent Workflow Configuration

Portable shared skills resolve this repo's commands and policy through:
- **Commands** — run `.agents/bin/<name>` (`setup`, `validate`, `test`, ...); see `.agents/bin/README.md`. A missing script means that capability is n/a here.
- **Policy / config** — `.agents/agent-workflow.yml`.
```

## Presets And Overrides

`seam-presets.yml` has two top-level sections:

- `defaults.commands` / `defaults.policy` / `defaults.trust`
- `presets.<name>.commands` / `presets.<name>.policy` / `presets.<name>.trust`

`downstream.yml` selects a preset per repo and may override either area:

```yaml
repos:
  - repo: example-repo
    preset: ruby-gem
    overrides:
      commands:
        test: yarn test --runInBand
      policy:
        hosted_ci_trigger: "n/a — CI runs on every PR"
      trust:
        trusted_users:
          - maintainer-login
```

Command values can be strings or composed scripts:

```yaml
validate:
  compose: [build, test]
```

Keep presets conservative. Before opening a consumer PR, verify every generated
wrapper points to a command or task that actually exists in that repo (`rake -T`,
`package.json`, referenced `bin/` files, etc.). `bash -n` is syntax-only.

## Usage

Plan only, with no clones and no network writes:

```bash
bin/push-downstream
bin/push-downstream --only example-repo
```

Apply to a canary first, then fan out:

```bash
bin/push-downstream --only example-repo --apply
bin/push-downstream --apply
```

Reconcile one local checkout without the registry or network:

```bash
bin/push-downstream --root /path/to/consumer/repo
bin/push-downstream --root /path/to/consumer/repo --apply
```

Seed a repo-local trust config locally:

```bash
bin/push-downstream \
  --root /path/to/consumer/repo \
  --apply \
  --base-branch main \
  --trusted-user maintainer-login
```

That command creates or updates `.agents/agent-workflow.yml` with
`base_branch: main` and appends `maintainer-login` to
`.agents/trusted-github-actors.yml`. Configure the generated `.agents/bin/*`
wrappers before relying on them for real validation.

| Flag | Effect |
| --- | --- |
| `--config FILE` | Registry path (default `downstream.yml`). |
| `--presets FILE` | Preset path (default `seam-presets.yml`). |
| `--root DIR` | Reconcile one checkout instead of the registry; no network. |
| `--only a,b` | Restrict to named repos (selects even if `enabled: false`). |
| `--all` | Include repos marked `enabled: false`. |
| `--apply` | Perform writes; in registry mode, push branches and open PRs. |
| `--base-branch NAME` | Base branch for `--root` mode (default `main`). |
| `--trusted-user LOGIN` | Seed a repo-local trusted user in `--root` mode; repeatable. |
| `--trusted-bot LOGIN` | Seed a repo-local trusted bot base login in `--root` mode; repeatable. |
| `--trusted-metadata-bot LOGIN` | Seed a repo-local metadata-only bot base login in `--root` mode; repeatable. |
| `--trusted-team SLUG` | Seed a repo-local trusted team slug in `--root` mode; repeatable. |

## Validation

After generation, run:

```bash
agent-workflow-seam-doctor --root /path/to/consumer/repo --shared /path/to/agent-workflows
```

For a local source-pack change, run:

```bash
bin/validate
```
