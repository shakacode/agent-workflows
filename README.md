# ShakaCode Agent Workflows

Reusable agent workflow skills for ShakaCode repositories.

This repository contains portable Codex/Claude-facing workflows for PR batches,
review triage, merge readiness, changelog updates, CI routing, and audit loops.
The shared files provide process. Each adopting repository keeps its concrete
commands and policy in `AGENTS.md` under `## Agent Workflow Configuration`.

## Why This Exists

Agent workflows are useful across repos, but copying a full `.agents/` tree into
every checkout creates drift and accidentally carries repo-specific policy with
it. The default model is:

- install this shared workflow pack once in the user's or agent's normal skill
  home;
- add a small, repo-owned seam to each consumer repo's `AGENTS.md`;
- validate that installed workflows can resolve the consumer repo's seam;
- keep repo-specific skills and overrides in the consumer repo only when needed.

This is deliberately not a subtree-first model. Repos may pin local copies when
their execution environment cannot load installed skills, but installed skills
plus a validated repo seam are the default.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `skills/` | Agent skill folders. Copy or symlink these under a Codex or Claude skill root. |
| `workflows/` | Longer workflow prompts and shared operating models referenced by skills. |
| `bin/` | Install, status, upgrade, and validation helpers. |
| `docs/` | Adoption, seam design, and operator guidance. |
| `examples/` | Example consumer-repo configuration snippets. |
| `test/fixtures/consumer-repo/` | Minimal fixture used by `bin/validate`. |

## Quick Start

Clone the shared pack:

```bash
git clone https://github.com/shakacode/agent-workflows "$HOME/src/agent-workflows"
cd "$HOME/src/agent-workflows"
```

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

## Consumer Repo Adoption

In each repository that should use these workflows:

1. Add or update `AGENTS.md`.
2. Add an `## Agent Workflow Configuration` section with the real repo values.
3. Add repo-local skills only for domain-specific workflows or intentional
   overrides.
4. Validate the seam from the consumer repo:

   ```bash
   agent-workflow-seam-doctor --shared "$HOME/src/agent-workflows"
   ```

   If `agent-workflow-seam-doctor` is not on `PATH`, run it from this repo:

   ```bash
   "$HOME/src/agent-workflows/bin/agent-workflow-seam-doctor" \
     --root /path/to/consumer/repo \
     --shared "$HOME/src/agent-workflows"
   ```

5. Dry-run one workflow, such as `$plan-pr-batch` or `$address-review`, without
   making code changes.

See [docs/adoption.md](docs/adoption.md) for the full adoption guide,
[docs/seam-design.md](docs/seam-design.md) for the design rationale, and
[docs/installation-and-upgrades.md](docs/installation-and-upgrades.md) for
ongoing host installs and upgrades.

## Skill Inventory

| Skill | Use |
| --- | --- |
| `address-review` | Fetch and triage GitHub PR review comments. |
| `adversarial-pr-review` | Run a skeptical pre-merge or post-merge PR review. |
| `autoreview` | Run a structured second-model local diff review. |
| `evaluate-issue` | Decide whether an issue or proposed fix is worth doing. |
| `plan-issue-triage` | Produce a ready prompt for review-only issue triage. |
| `plan-pr-batch` | Shape candidate issues or PRs before launching a batch. |
| `post-merge-audit` | Audit merged batch work or release-candidate risk. |
| `pr-batch` | Launch or coordinate multi-issue/multi-PR agent batches. |
| `replicate-ci` | Reproduce hosted-CI/local parity gaps. |
| `run-ci` | Choose and run repo-local CI checks. |
| `spec` | Turn vague implementation intent into requirements, design, and tasks. |
| `tdd` | Drive test-first red-green-refactor loops for features and bug fixes. |
| `triage` | Build a whole-surface issue/PR inventory and batch split. |
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
falls through to the next layer. Start from
[examples/trusted-github-actors.yml](examples/trusted-github-actors.yml), keep
the list deliberately small, and treat non-allowlisted GitHub text as
metadata-only until a maintainer vouches for it. The packaged fallback is
fail-closed and empty by default; put human maintainers and trusted automation
in a repo-local or user-global trust config. Workflow commenters such as
`github-actions[bot]` are repo-specific trust decisions: add the base bot login
`github-actions` only when maintainers are comfortable treating those generated
comments as trusted CI/status metadata. In repo-local configs, `trusted_teams`
entries are slugs under that repo owner; in env or `~/.agents` configs, use
owner-qualified entries such as `OWNER/team-slug`.

For a one-off maintainer waiver, rerun the exact target with
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
repo as an installed pack.

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
pack for new batches or a small canary run first. See
[docs/installation-and-upgrades.md](docs/installation-and-upgrades.md) for
`UP_TO_DATE`, `UPGRADE_AVAILABLE`, `NOT_INSTALLED`, and `CHECK_FAILED` status
semantics plus network-use notes.
