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
- add repo-owned `.agents/bin/` wrappers, `.agents/agent-workflow.yml`, and
  `.agents/trusted-github-actors.yml` when PR-batch trust is needed;
- validate that installed workflows can resolve the consumer repo's contract;
- keep repo-specific skills and overrides in the consumer repo only when needed.

Repos may pin local copies when their execution environment cannot load
installed skills, but installed skills plus a validated repo seam are the
default.

## What You Get

- Portable Codex and Claude skills for planning, running, reviewing, and
  verifying agent-assisted PR work, from one coordinated PR lane through
  multi-lane batches.
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
| `.agents/plugins/marketplace.json` | Codex marketplace catalog that publishes the root plugin as `scw`. |
| `.codex-plugin/plugin.json` | Codex native plugin manifest for the `scw` plugin namespace. |
| `.claude-plugin/` | Claude Code `scw` plugin manifest and `agent-workflows` marketplace catalog. |
| `skills/` | Agent skill folders. Copy or symlink these under a Codex or Claude skill root. |
| `workflows/` | Longer workflow prompts and shared operating models referenced by skills. |
| `bin/` | Install, status, upgrade, validation, and maintainer sync helpers. |
| `downstream.yml` | Registry of consumer repos for `bin/push-downstream`. |
| `seam-presets.yml` | Seam value adapter: org defaults + archetype presets. |
| `docs/` | Adoption, seam design, and workflow guidance. |
| `CONTEXT.md` | Canonical glossary for batch coordination and lane lifecycle terms. |
| `examples/` | Example consumer-repo configuration snippets. |
| `test/fixtures/consumer-repo/` | Minimal fixture used by `bin/validate`. |

## Quick Start

Clone the workflow pack and install it into the agent host you use:

```bash
git clone https://github.com/shakacode/agent-workflows "$HOME/src/agent-workflows"
cd "$HOME/src/agent-workflows"
bin/install-agent-workflows --host codex
```

Use `--host claude` for Claude Code, or `--target "$HOME/.agents"` for an
explicit shared agent home.

For the full ShakaCode agent stack setup (`agent-workflows`,
`agent-coordination`, and `agent-coordination-dashboard`), see
[Full Stack Contributor Setup](docs/installation-and-upgrades.md#full-stack-contributor-setup).
`agent-stack` is ShakaCode-specific stack tooling, not part of the generic
workflow-pack install path for consumer repositories.

### Host Installer Path

Use the host installer when you need helper binaries on `PATH`, install
metadata, `agent-workflows-status`, `upgrade-agent-workflows`, symlink mode, or
Claude Code support. Each host/profile must use exactly one auto-invocable skill
delivery route: ordinary flat skills or the native `scw` plugin.

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

The default `--delivery-mode flat` installs those skills directly. When the
native `scw` plugin is enabled, retain the installer-managed companion assets
without a second flat skill tree:

```bash
bin/install-agent-workflows \
  --host codex \
  --delivery-mode plugin-companion
```

The selected delivery mode is durable install state. Repeated installs,
`upgrade-agent-workflows`, rollback, and `agent-stack sync` replay it unless an
explicit `--delivery-mode` changes it.

Add `<target>/bin` to `PATH` if you want `agent-workflow-seam-doctor`,
`agent-workflows-status`, `agent-workflows-trust-audit`, and
`upgrade-agent-workflows` available as normal commands.

See [docs/installation-and-upgrades.md](docs/installation-and-upgrades.md) for
host selection, status states, upgrades, rollback behavior, and Codex/Claude
notes.

### Native Plugin Paths

Codex and Claude Code can also consume this source pack through native plugin
metadata. Both native paths publish the semantic skills under the short `scw`
plugin namespace without renaming anything under `skills/`. For example, Claude
Code exposes `skills/verify/SKILL.md` as `/scw:verify`.

Add and install the Claude Code marketplace plugin with:

```text
/plugin marketplace add shakacode/agent-workflows
/plugin install scw@agent-workflows
```

Add and install the Codex marketplace plugin with:

```bash
codex plugin marketplace add shakacode/agent-workflows
codex plugin add scw@agent-workflows
```

The manifests point at the existing `./skills/` tree; native installation does
not copy helper binaries, write
`.agent-workflows-install.json`, or replace the installer-managed status and
upgrade flow.

The Codex plugin identifier changed from `agent-workflows` to `scw`. Existing
Codex native-plugin users must remove the old `agent-workflows` entry, refresh
the marketplace, and reinstall it as `scw`; keeping both would
create two names for the same skill tree. The repository, source pack, helper
commands, marketplace name, and install metadata remain `agent-workflows`.

Use a native plugin path for a host-qualified skill surface. Pair it with
`--delivery-mode plugin-companion` when you also need installer-managed helper
binaries, workflows, docs, metadata, status, or upgrades. The installer fails
closed instead of creating native-plus-flat duplicates. Native plugin updates
remain owned by the host plugin flow, not `upgrade-agent-workflows`.

## Consumer Repo Adoption

From each repository that should use these workflows, initialize and validate a
starter seam in one command:

```bash
agent-workflow-seam-doctor --init --shared "$HOME/src/agent-workflows"
```

The initializer preserves existing repo-owned seam content. It detects executable
root `bin/validate` plus `bin/test`, or exact `validate` and `test` scripts for a
single detected npm, pnpm, or Yarn lockfile. When detection is not unambiguous,
it writes fail-closed wrappers and reports the commands that still need
configuration. Supply both commands explicitly to complete the seam in one run:

```bash
agent-workflow-seam-doctor --init \
  --validate-command 'bin/validate' \
  --test-command 'bin/test' \
  --shared "$HOME/src/agent-workflows"
```

Simple explicit commands forward wrapper arguments automatically. Explicit
`npm run` commands add npm's `--` separator; `pnpm run` and `yarn run` pass the
arguments directly. Compound shell expressions are preserved verbatim; include
`"$@"` in the expression when it should receive wrapper arguments. `env -S`
and `env --split-string` commands are also preserved verbatim because their
split payload owns argument placement.

Files carrying the generated init marker are tool-owned. Supplying explicit
commands again rewrites both managed wrappers, so keep hand-written logic in the
target commands. To own a wrapper directly, replace it without the marker and
rerun initialization without explicit commands; later explicit replacement then
fails closed instead of overwriting it.

The generated `.agents/trusted-github-actors.yml` is intentionally empty and
fail-closed. Add only repo-specific maintainers, trusted bots, metadata-only
bots, or teams that the repository has deliberately approved. Add repo-local
skills only for domain-specific workflows or intentional overrides.

Finally, dry-run one workflow, such as `$plan-pr-batch` or `$address-review`,
without making code changes.

See [docs/adoption.md](docs/adoption.md) for the full adoption guide,
[docs/seam-design.md](docs/seam-design.md) for the design rationale, and
[docs/installation-and-upgrades.md](docs/installation-and-upgrades.md) for
ongoing host installs and upgrades.

Use [docs/source-pack-glossary.md](docs/source-pack-glossary.md) for canonical
vocabulary around source-pack distribution, install paths, seams, readiness
states, review findings, and state-machine fixtures.

## Maintainer Sync Reference

Most teams can adopt the source pack with the Quick Start and Consumer Repo
Adoption steps above. `bin/push-downstream` is ShakaCode-specific maintainer
tooling, not part of the generic workflow-pack adoption path for consumer
repositories. It rolls the binstub contract into the repos listed in
`downstream.yml`, one PR per repo, while preserving repo-owned scripts and
policy values. Plan first, then apply a canary before fanning out:

```bash
bin/push-downstream                               # plan every enabled repo
bin/push-downstream --only <repo-key> --apply       # clone, reconcile, validate, open one PR
bin/push-downstream --apply                       # fan out to all enabled repos
```

See [docs/downstream-sync.md](docs/downstream-sync.md) for the registry schema,
the managed-vs-repo-owned boundary, trust seeding, and
`--root`/`--only`/`--all` usage.

## Documentation

The docs for this pack are the
[ShakaCode Agent Workflow Playbook](docs/README.md). Start there when deciding
which workflow to use, how to install the pack, how to adopt it in a consumer
repo, or how to validate the agent workflow contract.

## License

This project is available under the MIT License.

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
| `pr-batch` | Run one or more issue, PR, or ad-hoc lanes through the canonical coordinated subagent workflow. |
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
repo as an installed pack. Validate both native plugin surfaces directly
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
batches finish unless they are blocked by superseded workflow instructions; use
the new pack for new batches or a small canary run first. For restart handoff prompts,
see [docs/agent-runner-restarts.md](docs/agent-runner-restarts.md); for
`UP_TO_DATE`, `UPGRADE_AVAILABLE`, `NOT_INSTALLED`, and `CHECK_FAILED` status
semantics and network-use notes, see
[docs/installation-and-upgrades.md](docs/installation-and-upgrades.md).
