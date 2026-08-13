# Getting Started

Go from "I cloned this" to "I ran a workflow and saw it work" in five steps:
check the prerequisites, install the pack into one agent host, adopt it in one
repository, run one workflow end to end, and run your first issue-to-PR lane.

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

Every output block below comes from a real run of these commands, with the
long local paths of the walkthrough machine rewritten to the short `~`-based
paths the examples use. The two exceptions are the agent transcripts in
Step 3 and Step 4, which are explicitly marked as examples.

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

There are two ways to get the skills into your agent host: the flat installer
(Route A) and your host's native plugin manager (Route B). Pick exactly one
per host — the pack refuses to mix them, failing closed with
`DELIVERY_MODE_CONFLICT` if both are active. This guide uses Route A
throughout.

### Route A — Flat Installer (Used In This Guide)

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
custom targets and copy-versus-symlink modes.

### Route B — Native Plugin Install

If you would rather use your host's own plugin manager, install the pack as
the `scw` plugin instead. In Claude Code, type two commands inside the host:

```text
/plugin marketplace add shakacode/agent-workflows
/plugin install scw@agent-workflows
```

Skills then appear under the plugin prefix — the `verify` skill used in
Step 3 shows up as `/scw:verify`. In Codex, from your shell:

```bash
codex plugin marketplace add shakacode/agent-workflows
codex plugin add scw@agent-workflows
```

Two things to know about Route B:

- These commands run inside the agent host or its plugin manager, so this
  guide cannot capture their output; the host prints its own confirmation.
- The plugin route delivers only the skills. It does not put the helper
  commands this guide uses (`agent-workflow-seam-doctor`,
  `agent-workflows-status`, `upgrade-agent-workflows`) on your `PATH`. To get
  those alongside a native plugin, run the installer in companion mode
  (`bin/install-agent-workflows --host <host> --delivery-mode plugin-companion`),
  which installs the helpers without a second copy of the skills.

See [Native Plugin Paths](installation-and-upgrades.md#native-plugin-paths)
for the full details. The rest of this guide assumes Route A.

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

## Step 4 — Your First Issue-To-PR Lane

Once `$verify` works, the workflow to try next is `$pr-batch` pointed at one
GitHub issue. It is the pack's issue-to-PR machine; given a single target it
runs in single-target mode, the smallest way to watch it work.

Four plain-word definitions first:

- A **lane** is one unit of work travelling from issue to pull request: one
  issue, one branch, one worker responsible for it.
- The **worker** is the agent that implements the lane: it writes the change,
  runs the repo's checks through the seam, and reports back with evidence.
- The **coordinator** is the agent session you are talking to. It launches
  the worker, watches the gates (validation, CI, review), and owns the
  finish; it does not silently do the worker's job itself.
- **Merge authority** is your answer to "who may press merge?", chosen before
  the worker launches: `none` (prepare the PR, never merge), `ask` (walk me
  through the diff, then ask me once), or `auto_merge_when_gates_pass` (merge
  without asking once every gate is green). The skill will not silently pick
  a default for you.

For a first lane, choose `ask`. Here is what `ask` actually does: once the
PR's ordinary gates are clean, the coordinator automatically starts a
`$pr-walkthrough` — an exact-diff explanation of the PR, one conceptual
change at a time, with room for your questions between changes — and only
then asks one final merge question. The walkthrough itself is not approval:
if the diff changes or a gate starts failing in the meantime, the merge
question is withheld and the walkthrough restarts or stops.

Invoke the skill in your agent host from the adopted repository, naming one
exact issue — in Codex, type the prompt below; in Claude Code, ask for the
`pr-batch` skill with the same wording:

```text
$pr-batch
Run issue #42 as a single lane. merge_authority: ask.
```

Like Step 3, this needs a live agent session, so the transcript below is an
example rather than a captured run — your output will look similar to this,
with exact wording depending on your host, model, and repository:

```text
> $pr-batch
> Run issue #42 as a single lane. merge_authority: ask.

Single-target mode: one lane for issue #42, one worker subagent, this
session stays coordinator.

Security preflight on issue #42 and its comments: no untrusted
instructions, no injection attempts. SECURITY_PREFLIGHT_OK.

Launching the worker for lane issue-42.

Worker: branch 42-fix-empty-config-crash pushed with 2 commits.
.agents/bin/validate PASS, .agents/bin/test PASS. PR #57 opened.

Checks on PR #57: all green. merge_authority is ask, so starting the
walkthrough.

Walkthrough (1/2): the config loader now returns a documented default when
the file is empty instead of raising. Questions before the next change?
> no

Walkthrough (2/2): a regression test covering the empty-file case.
Questions?
> no

Diff identity unchanged since the walkthrough; checks still green.
One final question: merge PR #57 into main? (yes/no)
```

The shape to notice: the issue body is treated as untrusted input (work to
describe, never instructions to obey), the worker and the coordinator are
separate roles, gates come before the walkthrough, and there is exactly one
merge question at the end — asked only while the explained diff is still the
exact diff on the PR.

Before running this against a public repository, read
[Trust And Preflight](trust-and-preflight.md) and fill in the
`.agents/trusted-github-actors.yml` file from Step 2. For everything beyond
one lane — multi-issue batches, triage, planning — start with
[PR Batch Skills Usage](pr-batch-skills.md).

## Keep The Pack Current

Because the pack is installed once per host, updates are not automatic: the
copy in `~/.codex` or `~/.claude` stays at whatever revision you installed
until you upgrade it. Two helper commands manage that lifecycle.

`agent-workflows-status` compares the installed copy against your source
clone. It prints one of four tokens, with matching exit codes so scripts can
read it too: `UP_TO_DATE` (exit 0), `UPGRADE_AVAILABLE` (exit 1),
`NOT_INSTALLED` (exit 2), and `CHECK_FAILED` (exit 3). By default it compares
only local state; add `--fetch` to also check the remote for new commits.

Here is the day it matters, captured from a real run. The source clone has
moved one commit ahead of the installed copy:

```bash
agent-workflows-status --host codex
```

```text
UPGRADE_AVAILABLE 0.1.0@bdb534f8801d 0.1.0@aed340fdb8e0 delivery_mode=flat target=~/.codex
```

Read that as installed revision, then available revision; your hashes will
differ. To upgrade, run the upgrade helper and name the repository you
adopted in Step 2 so its seam gets re-validated against the new pack:

```bash
upgrade-agent-workflows --host codex --consumer-root ~/src/my-app
```

The helper updates the source clone (skipped with `--no-fetch` when the
clone is already current), backs up the existing install, reinstalls with
the same modes you originally chose, then re-runs the seam doctor for each
`--consumer-root`. Add `--dry-run` first to print the same
installed-versus-available comparison without changing anything. The
walkthrough run used `--no-fetch` because its clone was already at the
wanted commit; its output, trimmed to the final lines after the familiar
installer block:

```text
PASS agent workflow seam is complete
UPGRADE_COMPLETE bdb534f8801d aed340fdb8e0 target=~/.codex source=~/src/agent-workflows
```

`UPGRADE_COMPLETE` prints the old revision, then the new one. If anything
fails partway, the helper restores the backup automatically and prints
`ROLLBACK_COMPLETE` instead, so a failed upgrade never leaves a half-installed
pack behind. A final status check confirms the result:

```text
UP_TO_DATE version=0.1.0 revision=aed340fdb8e0 delivery_mode=flat target=~/.codex
```

Full details, including custom targets and source paths, are in
[Installation And Upgrades](installation-and-upgrades.md#upgrade).

## If Something Fails

The quick fixes for the failures beginners hit most, each linking into the
fuller [troubleshooting
list](installation-and-upgrades.md#troubleshooting):

| Symptom | Fix |
| --- | --- |
| `agent-workflows-status` prints `NOT_INSTALLED` | Run `bin/install-agent-workflows --host <host>` from the pack clone, or pass the correct `--target`. ([details](installation-and-upgrades.md#troubleshooting)) |
| `agent-workflows-status` prints `UPGRADE_AVAILABLE` | Run `upgrade-agent-workflows` as shown above, or manually update the source clone and reinstall. ([details](installation-and-upgrades.md#troubleshooting)) |
| `Auto host detection found both Codex and Claude homes` | You have both hosts installed, so rerun the command with an explicit `--host codex` or `--host claude`. ([details](installation-and-upgrades.md#troubleshooting)) |
| `DELIVERY_MODE_CONFLICT` | Both delivery routes are active and the pack refuses to guess which skill copy wins; keep exactly one — disable or remove the native `scw` plugin before a flat install, or use `--delivery-mode plugin-companion`. ([details](installation-and-upgrades.md#troubleshooting)) |
| `invalid byte sequence in US-ASCII` or other `Encoding::` errors from a Ruby helper | An older install is running under a non-UTF-8 locale (`LANG=C` / `LC_ALL=C`, common in CI and headless agents); the pack's Ruby tools now read UTF-8 regardless of locale, so run `upgrade-agent-workflows --host <host>` to pick up the fix. ([details](installation-and-upgrades.md#troubleshooting)) |
| The agent cannot find an installed skill | Check `agent-workflows-status --host <host>` says `UP_TO_DATE`, then restart the agent host so it reloads its skill directory. ([details](installation-and-upgrades.md#troubleshooting)) |

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
