# Downstream Seam Sync

Use `bin/push-downstream` to roll the managed `## Agent Workflow Configuration`
seam into the consumer repositories listed in `downstream.yml`, one pull request
per repo. This is the repeatable, version-controlled form of consumer adoption
(see [adoption.md](adoption.md)); it never copies skill or workflow content into
a repo.

## What It Manages

The command owns the seam's *structure* and leaves the *values* to each repo:

| `bin/push-downstream` owns (rewrites) | The repo owns (preserved) |
| --- | --- |
| The section preamble and pointer to this pack | Every key's value |
| Which required keys are present, and their order | Extra optional keys the repo added |

The required keys come straight from `AgentWorkflowSeamDoctor::REQUIRED_KEYS`, so
the command and `agent-workflow-seam-doctor` can never drift. On first adoption a
key with no repo value is seeded as `n/a` (which the seam doctor accepts); the
base branch is seeded from the registry. Re-running only refreshes the managed
preamble and fills newly added keys — existing values, including multi-line
ones, are kept verbatim. Reconcile is idempotent: an already-current repo is a
no-op.

When a repo has no `AGENTS.md` at all, the command creates a minimal one (a
title plus the managed seam) so the portable skills have a seam to resolve. A
repo that keeps its agent policy in `CLAUDE.md` should still treat `AGENTS.md` as
canonical over time; consolidating the two is follow-up work, not something this
command does.

## The Registry

`downstream.yml` lists targets and light metadata only:

```yaml
defaults:
  owner: shakacode
  base_branch: main
  pr_branch: agent-workflows/seam-sync
  enabled: true
repos:
  - { repo: shakapacker, preset: ruby-gem }
  - { repo: react-webpack-rails-tutorial, preset: ror-demo, base_branch: master }
```

`shakacode/react_on_rails` is intentionally absent — it is the hand-authored
reference seam. Private and archived repos are out of scope.

## Seam Value Adapter

Each seam value is resolved through three layers, last wins, then seeded into a
fresh seam (existing repo-owned values still win on re-runs):

1. **`defaults`** in `seam-presets.yml` — org-uniform values (coordination
   backend, follow-up prefix, review gate, `n/a` keys) applied to every repo.
2. **`presets[<name>]`** — archetype command defaults, chosen per repo via
   `preset:` (`ts-package`, `ruby-gem`, `ror-demo`, `site`).
3. **per-repo `overrides:`** in `downstream.yml` — the idiosyncrasies a preset
   can't know, e.g. RSC's `NODE_CONDITIONS=react-server` test note.

```yaml
# downstream.yml
- repo: react_on_rails_rsc
  preset: ts-package
  overrides:
    Tests: "`yarn test`; single file `yarn jest <path>`, prefix NODE_CONDITIONS=react-server for *.rsc.test.*."
```

Keep presets conservative — assert only what is genuinely common to the
archetype, and prefer `n/a` over a guessed command, since a wrong preset value
propagates to every repo using it. The seam doctor and PR review remain the
gates. A future `--reseed` mode could re-assert changed preset values onto keys
a repo has not customized.

## Usage

Plan only (default; no clones, no network writes):

```bash
bin/push-downstream                      # plan every enabled repo
bin/push-downstream --only shakapacker   # plan one repo
```

Apply (clone the base branch, reconcile, validate with the seam doctor, push
`agent-workflows/seam-sync`, and open one PR per repo):

```bash
bin/push-downstream --only shakapacker --apply   # canary one repo first
bin/push-downstream --apply                       # fan out to all enabled repos
```

Reconcile a single local checkout without the registry or network:

```bash
bin/push-downstream --root /path/to/consumer/repo            # show planned change
bin/push-downstream --root /path/to/consumer/repo --apply    # write AGENTS.md
```

| Flag | Effect |
| --- | --- |
| `--config FILE` | Registry path (default `downstream.yml`). |
| `--root DIR` | Reconcile one checkout instead of the registry; no network. |
| `--only a,b` | Restrict to named repos (selects even if `enabled: false`). |
| `--all` | Include repos marked `enabled: false`. |
| `--apply` | Perform writes; in registry mode, push branches and open PRs. |
| `--base-branch NAME` | Base branch for `--root` mode (default `main`). |

## Values Still Need Authoring

The command guarantees a valid, current, seam-doctor-passing section, but it
cannot infer a repo's real test, lint, or CI commands. After the scaffold PR is
open, replace the remaining `n/a` entries with that repo's real values — by hand
or with an inspection pass — and the seam doctor will confirm completeness.
