# Getting Started

Go from "I cloned this" to "I ran a workflow and saw it work" in four steps:
check the prerequisites, install the pack into one agent host, adopt it in one
repository, and run one workflow end to end.

Two plain-word definitions before you start:

- The **source pack** is this repository: a folder of reusable agent skills
  (step-by-step instructions an agent host can load), workflow prompts, and
  helper scripts. You install it once per agent host instead of copying it into
  every project.
- The **policy seam** is a small set of files each of your repositories owns
  (`.agents/bin/` command wrappers, `.agents/agent-workflow.yml` policy, and a
  pointer section in `AGENTS.md`) that tells the shared skills how that repo
  builds, tests, and merges. The shared pack stays generic; your repo keeps its
  own rules. See the [Source Pack Glossary](source-pack-glossary.md) for the
  full vocabulary.

Every output block below comes from a real run of these commands, with long
local paths shortened to `~`. The one exception is the final agent transcript
in Step 3, which is explicitly marked as an example.

## Prerequisites

| Tool | Version | Used for |
| --- | --- | --- |
| Git | 2.41 or newer recommended; verified with 2.50.1 | Cloning the pack and reading repository state. Any recent Git completes this guide; the optional pinned-copy drift checker needs 2.41+ for full-fidelity checks (see [adoption.md](adoption.md)). |
| Bash | 3.2 or newer; verified with macOS stock bash 3.2.57 | The installer and the shell helper scripts. |
| Ruby | Ruby 3 series; verified with 3.3.6, and this repo's CI pins 3.4 | The seam doctor, status, and upgrade helpers. Plain Ruby only — no gems to install. |
| GitHub CLI (`gh`) | 2.x, authenticated (walkthrough machine: 2.89.0) | Workflows that read GitHub, such as `$pr-batch` and `$address-review`. Not needed for install or adoption. Run `gh auth status` to confirm login. |
| An agent host | A current release of Codex CLI or Claude Code | Actually loads and runs the installed skills. |

Contributing changes back to this pack needs additional pinned lint tools; see
[CONTRIBUTING.md](../CONTRIBUTING.md) and `bin/lint`. None of them are needed
to follow this guide.

## Step 1 — Install The Pack Into One Host

Clone the pack once, then install it into the agent host you use:

```bash
git clone https://github.com/shakacode/agent-workflows "$HOME/src/agent-workflows"
cd "$HOME/src/agent-workflows"
bin/install-agent-workflows --host codex
```

Use `--host claude` for Claude Code instead. The installer copies skills,
workflow prompts, and helper commands into the host's home (`~/.codex` or
`~/.claude`) and prints what to do next:

```text
Installed ShakaCode agent workflows into:
  ~/.codex

Host:
  codex

Add this to PATH if needed:
  export PATH="~/.codex/bin:$PATH"

Initialize a consumer repo with:
  agent-workflow-seam-doctor --init --root /path/to/consumer/repo --shared "~/src/agent-workflows"

Validate a consumer repo with:
  agent-workflow-seam-doctor --shared "~/src/agent-workflows"

Check for updates with:
  agent-workflows-status --host "codex"
```

Do what the output says: add the printed `bin` directory to `PATH` so the
helper commands work as normal commands, for example in `~/.zshrc` or
`~/.bashrc`:

```bash
export PATH="$HOME/.codex/bin:$PATH"
```

Then confirm the install in a new terminal:

```bash
agent-workflows-status --host codex
```

```text
UP_TO_DATE version=0.1.0 revision=c4b87520d9e4 delivery_mode=flat target=~/.codex
```

`UP_TO_DATE` means the installed pack matches your clone. The `revision` value
will match whatever commit you cloned.

That is the whole install. No signing keys, trust anchors, or extra setup are
required; see [Installation And Upgrades](installation-and-upgrades.md) for
custom targets, the native `scw` plugin path, and upgrade behavior.

## Step 2 — Adopt The Pack In One Repo

Adoption means creating the policy seam in one of your repositories so the
installed skills know how to validate and test that repo. From the repository
you want to adopt:

```bash
cd /path/to/your/repo
agent-workflow-seam-doctor --init --shared "$HOME/src/agent-workflows"
```

The initializer looks for an executable `bin/validate` plus `bin/test` at the
repo root, or exact `validate` and `test` package scripts when exactly one npm,
pnpm, or Yarn lockfile identifies the runner. When it finds them, it wires the
seam and validates it in one pass:

```text
PASS agent workflow seam is complete
```

If detection is ambiguous, the command instead writes clearly marked
fail-closed placeholder wrappers and returns `FAIL` with the next step. In that
case, rerun it and name your repo's real check commands explicitly:

```bash
agent-workflow-seam-doctor --init \
  --validate-command 'bin/validate' \
  --test-command 'bin/test' \
  --shared "$HOME/src/agent-workflows"
```

This walkthrough adopted a small demo repo called `my-app` whose `bin/validate`
and `bin/test` scripts just print one line each; point the commands above at
your real repository and its real checks instead.

The initializer created these files in the demo repo:

```text
.agents/agent-workflow.yml
.agents/bin/README.md
.agents/bin/test
.agents/bin/validate
.agents/trusted-github-actors.yml
```

In plain words:

- `.agents/bin/validate` and `.agents/bin/test` are thin wrappers that forward
  to your repo's real commands. Shared skills always call these wrapper names,
  so the pack never hardcodes your commands.
- `.agents/agent-workflow.yml` holds non-command policy: base branch, changelog
  rules, review gates, and similar. Generated values default to `main` and
  `n/a`; fill in real values as you need them.
- `.agents/trusted-github-actors.yml` starts fail-closed: the trusted user,
  bot, and team lists are empty, and only `trusted_metadata_bots` is
  pre-populated (with `github-actions`, whose comments count as CI status
  evidence, never as instructions). Add only maintainers and bots this
  repository deliberately trusts.
- `AGENTS.md` gains a short `## Agent Workflow Configuration` section pointing
  agents at the two sources above.

Sanity-check the seam by running a wrapper yourself:

```bash
.agents/bin/validate
```

```text
my-app validate: ok
```

In your repository this runs your real validation command. See the
[Agent Workflow Adoption Guide](adoption.md) for policy YAML details, trust
configuration, and optional pinned copies.

## Step 3 — Run One Workflow End To End

Now use your agent host to run one installed workflow in the adopted
repository. The simplest first workflow is `verify`, which runs the repo's
local checks through the seam before a PR is created or updated.

Open your agent host in the adopted repository and invoke the skill: in Codex,
type `$verify`; in Claude Code, ask for the `verify` skill (with the native
`scw` plugin it appears as `/scw:verify`).

This step needs a live agent session, so the transcript below is an example
rather than a captured run — your output will look similar to this, with exact
wording depending on your host, model, and repository:

```text
> $verify

Reading AGENTS.md, .agents/bin/README.md, and .agents/agent-workflow.yml.
base_branch is main. Inspecting the branch diff:
  git status --short
  git diff --name-only origin/main...HEAD   -> 2 files changed, docs only

Running the required checks in order:

Verification:
- PASS git diff --check "origin/main...HEAD"
- PASS .agents/bin/validate

All selected checks passed. The branch is ready for a PR update.
```

The shape is what matters: the agent reads the seam first, picks checks that
cover the changed files, runs them in order, and reports each command with a
PASS or FAIL line, stopping on the first failure. That reporting contract is
defined in `skills/verify/SKILL.md`.

If the agent cannot find the skill, re-check Step 1 (`agent-workflows-status`
should say `UP_TO_DATE`) and restart the agent host so it reloads its skill
directory.

## Where To Go Next

- Choose between triage, single-PR lanes, and batches:
  [PR Batch Skills Usage](pr-batch-skills.md).
- Before your first `$pr-batch` on a public repo, configure trust:
  [Trust And Preflight](trust-and-preflight.md).
- Keep the installed pack current: [Installation And
  Upgrades](installation-and-upgrades.md).
- Look up terms: [Source Pack Glossary](source-pack-glossary.md) for
  distribution and seam vocabulary, and the root
  [CONTEXT.md](../CONTEXT.md) for batch coordination vocabulary.
