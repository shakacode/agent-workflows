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
review_gate: "n/a"
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

`review_gate` is either the exact string `n/a` or a closed executable version 1
mapping. Legacy prose is not a gate and is not migrated from `AGENTS.md`.
Configured reviewers name their exact current-head check and every GitHub login
and artifact kind that can attest the review:

```yaml
review_gate:
  version: 1
  reviewers:
    - id: claude
      check_name: claude-review
      producer:
        app_slug: github-actions
        workflow_path: .github/workflows/claude-code-review.yml
        event: pull_request
      artifact:
        actors: [claude, "claude[bot]"]
        kinds: [pull_request_review, review_thread]
        completion:
          mode: producer_check
  require_current_head: true
  artifact_settlement:
    required: true
    quiet_period_seconds: 30
  thread_disposition:
    required: true
    marker: "configured-review-disposition:"
  failure_policy: block
  fallback:
    mode: disabled
```

Only pull-request reviews and review-thread roots carry exact-head attribution;
issue comments never qualify. For each configured actor, only its latest
current-head pull-request review qualifies, and only in `APPROVED` or
`COMMENTED` state. `CHANGES_REQUESTED`, `DISMISSED`, pending, or unknown states
hard-block alternate artifact kinds until a later acceptable formal review
supersedes them. The configured check must come from the named producer: the
check-run app and exact workflow run must match, the run must bind to the
expected head and event, and the workflow file at that head must be
byte-identical to its exact trusted-base version. Optional
`completion.mode: producer_check` treats that verified producer check as the
completion artifact; unrelated reviews from its workflow bot never qualify.
The gate blocks missing,
stale, pending,
failed, unsettled, or unknown evidence and unresolved current-head review
threads. A fallback must instead use
`mode: named_attested_check` with explicit `triggers` and a complete `reviewer`
mapping; provider failure alone never implies readiness.

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

### Policy-Only Fleets

`policy_fleets` in `downstream.yml` is an organized registry for a narrowly
selected policy rollout. Unlike the normal registry, a policy fleet never
creates command wrappers, pointers, trust files, or `CLAUDE.md`; it requires
the consumer's existing seam to pass the seam doctor before it can update the
existing `.agents/agent-workflow.yml` file. Every fleet declares its complete
set of allowed policy keys, and every member must provide exactly those values.
Unknown fleet names, unknown `--only` selections, malformed registry entries,
missing policy configs, or invalid seams fail closed.

The registered repo-prefix fleet covers the confirmed consumer inventory. Plan
it first, then apply it to create one dedicated `agent-workflows/repo-prefix`
branch and PR per consumer:

```bash
bin/push-downstream --policy-fleet repo-prefix
bin/push-downstream --policy-fleet repo-prefix --apply
```

To make a single consumer PR after reviewing the fleet plan:

```bash
bin/push-downstream --policy-fleet repo-prefix --only hichee --apply
```

Policy-fleet mode stages only `.agents/agent-workflow.yml`, and only changes
the key(s) explicitly declared by the selected fleet. It does not use presets
or the broad scaffold reconciliation path.

### Read-Only GitHub Actions Audit Fleets

`security_audit_fleets` is a separate, read-only inventory. It clones only the
registered base branch into a temporary directory, runs the
`secure-github-actions` parser-backed gate, and emits a head-bound JSON report.
After cloning, it requires `refs/remotes/origin/<base>` to exist and match
`HEAD`; a same-named tag or any ref mismatch is `UNKNOWN`, never clean evidence.
It never changes a consumer checkout, pushes a branch, opens a PR, chooses a
`trusted_actions` entry, or enables Dependabot. `UNKNOWN` clone, head, or scan
state is non-clean and exits nonzero.

The initial narrow fleet contains Shakapacker so maintainers can replay the
known rollout blockers without widening rollout authority:

```bash
bin/push-downstream \
  --security-audit-fleet secure-github-actions \
  --only shakapacker
```

`--apply` is rejected in this mode. A missing `trusted_actions` key is the
closed empty allowlist; it trusts no external GitHub action. Omitting or
deleting the key is not an opt-out. Generic sync and direct seam-doctor checks
stop on an unremediated consumer before mutation.

Each report records the intended next boundary. `gate_activation` describes the
ordered adoption boundary: land the source-pack gate atomically with targeted
remediation and validation for the selected consumer, then activate that
consumer's normal validation. It is not a runtime switch that makes missing
policy permissive. Maintainer review for each allowlisted action and an explicit
repository decision about Dependabot remain part of the targeted remediation.
Expanding the fleet or mutating any consumer remains a separate coordinator
decision.

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
| `--policy-fleet NAME` | Run a named policy-only fleet; updates only that fleet's explicitly registered policy keys. |
| `--security-audit-fleet NAME` | Run a named read-only GitHub Actions audit fleet; never accepts `--apply`. |
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
