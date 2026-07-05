# ShakaCode Agent Workflows

Portable Codex and Claude workflow pack for ShakaCode repositories.

This repository packages reusable agent skills, workflow prompts, and helper
scripts for PR batches, review triage, merge readiness, CI routing, changelog
updates, and audit loops.

The shared pack provides process. Each adopting repository keeps its concrete
commands in `.agents/bin/`, non-command policy in `.agents/agent-workflow.yml`,
and a short `AGENTS.md` pointer section named
`## Agent Workflow Configuration`.

## Why This Exists

Agent workflows get more useful as they become consistent across repos, but
copying a full `.agents/` tree into every checkout creates drift and can carry
repo-specific policy into the wrong place. This pack keeps reusable process in
one install and makes each consumer repo expose a small policy seam.

The default model is:

- install this shared workflow pack once in the user's or agent's normal skill
  home;
- add repo-owned `.agents/bin/` wrappers and `.agents/agent-workflow.yml`;
- validate that installed workflows can resolve the consumer repo's contract;
- keep repo-specific skills and overrides in the consumer repo only when needed.

This is deliberately not a subtree-first model. Repos may pin local copies when
their execution environment cannot load installed skills, but installed skills
plus a validated repo seam are the default.

## What You Get

- Portable Codex and Claude skills for planning, running, reviewing, and
  verifying agent-assisted PR work.
- A repo contract so shared workflows can resolve base branches, validation
  commands, hosted-CI triggers, changelog policy, review gates, and
  coordination backends from `.agents/bin/`, `.agents/agent-workflow.yml`, and
  the `AGENTS.md` pointer.
- Installer, status, upgrade, trust-audit, and seam-doctor helpers under `bin/`.
- Security preflight for public issue and PR batches so untrusted GitHub text
  cannot quietly become agent instructions.
- Site-ready Markdown docs under the
  [ShakaCode Agent Workflow Playbook](docs/README.md).

## Repository Layout

| Path | Purpose |
| --- | --- |
| `.codex-plugin/plugin.json` | Codex native plugin manifest for consuming this source pack through Codex plugin metadata. |
| `skills/` | Agent skill folders. Copy or symlink these under a Codex or Claude skill root. |
| `workflows/` | Longer workflow prompts and shared operating models referenced by skills. |
| `bin/` | Install, status, upgrade, validation, and downstream-sync helpers. |
| `downstream.yml` | Registry of consumer repos for `bin/push-downstream`. |
| `seam-presets.yml` | Seam value adapter: org defaults + archetype presets. |
| `docs/` | Adoption, seam design, and operator guidance. |
| `examples/` | Example consumer-repo configuration snippets. |
| `test/fixtures/consumer-repo/` | Minimal fixture used by `bin/validate`. |

## Quick Start

Clone the workflow pack:

```bash
git clone https://github.com/shakacode/agent-workflows "$HOME/src/agent-workflows"
cd "$HOME/src/agent-workflows"
```

### Host Installer Path

Use the host installer when you need helper binaries on `PATH`, install
metadata, `agent-workflows-status`, `upgrade-agent-workflows`, symlink mode, or
Claude Code support.

Install into the default Codex home:

```bash
bin/install-agent-workflows --host codex
```

Install into the default Claude Code home:

```bash
bin/install-agent-workflows --host claude
```

Install into a different agent home, such as `~/.agents`:

```bash
bin/install-agent-workflows --host codex --target "$HOME/.agents"
```

The installer copies:

- `skills/*` to `<target>/skills/`;
- `workflows/*` to `<target>/workflows/`;
- selected `bin/*` helpers to `<target>/bin/`;
- install metadata to `<target>/.agent-workflows-install.json`.

Add `<target>/bin` to `PATH` if you want `agent-workflow-seam-doctor`,
`agent-workflows-status`, `agent-workflows-trust-audit`, and
`upgrade-agent-workflows` available as normal commands.

See [docs/installation-and-upgrades.md](docs/installation-and-upgrades.md) for
host selection, status states, upgrades, rollback behavior, and Codex/Claude
notes.

### Codex Native Plugin Path

Codex can also consume this source pack through native plugin metadata. The
manifest at `.codex-plugin/plugin.json` is Codex-only and points at the existing
`./skills/` tree; it does not copy helper binaries, write
`.agent-workflows-install.json`, or replace the installer-managed status and
upgrade flow.

Use the Codex native plugin path when a Codex marketplace or plugin source
points at this cloned or released source pack. Use the host installer path for
Claude Code and for Codex installs that need helper binaries or
status/upgrade behavior.

## Consumer Repo Adoption

In each repository that should use these workflows:

1. Add or update `.agents/bin/` command wrappers.
2. Add `.agents/agent-workflow.yml` with the repo's non-command policy.
3. Add the `## Agent Workflow Configuration` pointer section to `AGENTS.md`.
4. Add repo-local skills only for domain-specific workflows or intentional
   overrides.
5. Validate the contract from the consumer repo:

   ```bash
   agent-workflow-seam-doctor --shared "$HOME/src/agent-workflows"
   ```

   If `agent-workflow-seam-doctor` is not on `PATH`, run it from this repo:

   ```bash
   "$HOME/src/agent-workflows/bin/agent-workflow-seam-doctor" \
     --root /path/to/consumer/repo \
     --shared "$HOME/src/agent-workflows"
   ```

6. Dry-run one workflow, such as `$plan-pr-batch` or `$address-review`, without
   making code changes.

See [docs/adoption.md](docs/adoption.md) for the full adoption guide,
[docs/seam-design.md](docs/seam-design.md) for the design rationale, and
[docs/installation-and-upgrades.md](docs/installation-and-upgrades.md) for
ongoing host installs and upgrades.

## Downstream Seam Sync

`bin/push-downstream` rolls the binstub contract into the consumer repos listed
in `downstream.yml`, one PR per repo, while preserving repo-owned scripts and
policy values. Plan first, then apply a canary before fanning out:

```bash
bin/push-downstream                               # plan every enabled repo
bin/push-downstream --only shakapacker --apply    # clone, reconcile, validate, open one PR
bin/push-downstream --apply                       # fan out to all enabled repos
```

See [docs/downstream-sync.md](docs/downstream-sync.md) for the registry schema,
the managed-vs-repo-owned boundary, and `--root`/`--only`/`--all` usage.

## Documentation

The docs for this pack are the
[ShakaCode Agent Workflow Playbook](docs/README.md). Start there when deciding
which workflow to use, how to install the pack, how to adopt it in a consumer
repo, how to validate the agent workflow contract, or what would justify a
separate docs site.

## Skill Inventory

| Skill | Use |
| --- | --- |
| `address-review` | Fetch and triage GitHub PR review comments. |
| `adversarial-pr-review` | Run a skeptical pre-merge or post-merge PR review. |
| `autoreview` | Run a structured second-model local diff review. |
| `benchmark-verification` | Verify performance-sensitive changes with benchmark evidence. |
| `continue` | Resume an in-progress task with a structured checkpoint. |
| `evaluate-issue` | Decide whether an issue or proposed fix is worth doing. |
| `manual-testing` | Verify changed behavior in a real running app or service. |
| `pause` | Print restart-safe pause and resume prompts for copy/paste handoffs. |
| `plan-issue-triage` | Produce a ready prompt for review-only issue triage. |
| `plan-pr-batch` | Shape candidate issues or PRs before launching a batch. |
| `plan-review` | Review implementation plans before coding or launching workers. |
| `post-merge-audit` | Audit merged batch work or release-candidate risk. |
| `pr-batch` | Launch or coordinate multi-issue/multi-PR agent batches. |
| `pr-monitoring` | Monitor opened PRs through checks, comments, conflicts, and handoff. |
| `qa-stress` | Run destructive QA stress campaigns against repo-owned targets. |
| `replicate-ci` | Reproduce hosted-CI/local parity gaps. |
| `run-ci` | Choose and run repo-local CI checks. |
| `spec` | Turn vague implementation intent into requirements, design, and tasks. |
| `status` | Report tight progress (done/in-progress/blocked/next) without starting new work. |
| `task-observer` | Optionally capture sanitized observations for later skill or workflow improvement review. |
| `tdd` | Drive test-first red-green-refactor loops for features and bug fixes. |
| `triage` | Build a whole-surface issue/PR inventory and batch split. |
| `type-design-review` | Review changed type surfaces for representable invalid states. |
| `update-changelog` | Classify merged PRs and update a repo changelog. |
| `verify` | Run local verification before PR updates. |
| `verify-pr-fix` | Reproduce a bug before and after a fix. |

## Trust Configuration

The `pr-batch` security preflight resolves its GitHub actor allowlist in this
order:

1. `--trust-config PATH`;
2. repo-local `.agents/trusted-github-actors.yml`;
3. `$AGENT_WORKFLOWS_TRUST_CONFIG`;
4. user-global `~/.agents/trusted-github-actors.yml`;
5. packaged `skills/pr-batch/trusted-github-actors.yml`.

A present empty file is honored as an intentional local policy; an absent file
falls through to the next layer, except a missing
`$AGENT_WORKFLOWS_TRUST_CONFIG` path aborts fail-closed instead of falling
through. Start from
[examples/trusted-github-actors.yml](examples/trusted-github-actors.yml), keep
the list deliberately small, and treat non-allowlisted GitHub text as
metadata-only until a maintainer vouches for it. By default, exact-target
preflight reports non-allowlisted or hidden actors without blocking; add
`--strict-trust` when those trust findings should stop worker launch. The
packaged fallback is empty by default; put human maintainers and trusted
automation in a repo-local or user-global trust config. Workflow commenters such as
`github-actions[bot]` are repo-specific trust decisions: add them to
`trusted_metadata_bots` when their comments should count as CI/status metadata
but not as actionable agent instructions. Use `trusted_bots` only for bots whose
review/comment bodies are safe to process as trusted input. In repo-local
configs, `trusted_teams` entries are slugs under that repo owner; in env or
`~/.agents` configs, use owner-qualified entries such as `OWNER/team-slug`.

For a one-off maintainer waiver of a blocking finding, rerun the exact target with
`--acknowledge-risk NUMBER:risk-id[,risk-id]` instead of broadening the trust
config. Valid risk ids are `github-api-coverage`, `high-risk-files`,
`suspicious-text`, `untrusted-interactions`, and `untrusted-participants`.

To audit a repo's current trust config against recently merged PRs:

```bash
agent-workflows-trust-audit --repo OWNER/REPO --limit 10 \
  --trust-config /path/to/trusted-github-actors.yml
```

The audit reports candidate repo-local `trusted_users` and `trusted_bots` from
the sample, but it does not write trust config. Historical merged PRs are
evidence for maintainer review, not automatic authority.

See [docs/trust-and-preflight.md](docs/trust-and-preflight.md) for the
recommended trust-config split, audit workflow, acknowledgement policy, and
security tradeoffs.

## Validation

Run the full local validation gate before publishing changes:

```bash
bin/validate
```

The gate checks skill frontmatter, helper script tests, prompt-size invariants,
and the seam doctor against a fixture consumer repo while scanning this shared
repo as an installed pack. Validate the Codex native plugin surface directly
with:

```bash
ruby bin/codex-plugin-manifest-check
```

## Upgrades

Check the installed pack:

```bash
agent-workflows-status --host codex
```

Upgrade and validate a consumer repo seam:

```bash
upgrade-agent-workflows --host codex --consumer-root /path/to/consumer/repo
```

Long-running agents keep whatever skill text they already loaded. Let active
batches finish unless they are blocked by old workflow instructions; use the new
pack for new batches or a small canary run first. For restart handoff prompts,
see [docs/agent-runner-restarts.md](docs/agent-runner-restarts.md); for
`UP_TO_DATE`, `UPGRADE_AVAILABLE`, `NOT_INSTALLED`, and `CHECK_FAILED` status
semantics and network-use notes, see
[docs/installation-and-upgrades.md](docs/installation-and-upgrades.md).
