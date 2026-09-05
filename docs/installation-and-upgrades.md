# Installation And Upgrades

Use this guide to install `shakacode/agent-workflows` once per agent host and
keep that installed pack current without copying shared workflow files into
every repository.

## Installation Model

The shared pack belongs in the user or agent home. Each consumer repository
keeps command wrappers in `.agents/bin/`, non-command policy in
`.agents/agent-workflow.yml`, durable PR-batch actor trust in
`.agents/trusted-github-actors.yml` when needed, and a short pointer in
`AGENTS.md` under `## Agent Workflow Configuration`. The shared skills read
that contract at runtime, so the same installed pack can work across
repositories with different branches, CI commands, labels, changelog rules,
review gates, and trust policies.

Repository-pinned copies are still allowed when a platform cannot load installed
skills, but they are the exception. The default path is:

1. Clone this repository.
2. Install it into the host that will run the skills.
3. Validate each consumer repo contract.
4. Dry-run one workflow before launching a real batch.

## Host Targets

`bin/install-agent-workflows` supports the same installed layout for Codex and
Claude:

| Host | Default target |
| --- | --- |
| `codex` | `${CODEX_HOME:-$HOME/.codex}` |
| `claude` | `${CLAUDE_HOME:-$HOME/.claude}` |
| `auto` | An existing Codex or Claude home, only when exactly one is detectable |

The installer also supplies `agent-workflow-writing-style`,
[the packaged default guide](writing-style.md), and the opt-in
[`asd-ste100` adapter](writing-style-asd-ste100.md). Shared authoring workflows
run the resolver with the trusted repository root before composing human-facing
prose. Resolution is repo → user-global → portable default, with provenance
reported as `repo`, `user-global`, or `portable-default`.

`writing_style` is either one nonblank relative Markdown path or the exact
closed-registry preset `asd-ste100`. The repository value in
`.agents/agent-workflow.yml` resolves beneath the repository root or selects
the packaged preset, and wins. An optional personal fallback in
`~/.agents/agent-workflow.yml` resolves beneath
`~/.agents` and applies only when the repository does not set the key; that
user-global file contributes no other workflow policy. If neither layer defines
a valid guide, the resolver uses the packaged default.

Malformed repository config, unknown presets, unsafe or missing paths, and
invalid guide files block. The same user-global failures are nonblocking: the
resolver prints an actionable warning and uses the packaged default. Install
and upgrade deliver
the default and preset adapter in copy, symlink, and plugin-companion layouts,
but never write the user-global config or enable a repository override. See the
[project writing-style setup](adoption.md#configure-project-writing-style) for
the configuration instructions.

Use `--target DIR` for custom homes such as `~/.agents`. The host name controls
the default target and metadata; it does not change the shared workflow text.

## Skill Delivery Modes

Use exactly one auto-invocable Agent Workflows skill delivery route per
host/profile:

| Delivery mode | Auto-invocable skills | Installer-managed companion assets |
| --- | --- | --- |
| `flat` | `<target>/skills/*` | License, workflows, docs, helpers, metadata, status, and upgrades |
| `plugin-companion` | Native `scw` plugin only | License, workflows, docs, helpers, metadata, status, and upgrades |

`--mode copy|symlink` controls how installer-managed assets are materialized.
It is separate from `--delivery-mode flat|plugin-companion`.

### Fresh-Install Delivery Default

**Decision (issue #248): the generic installer keeps `flat` as its fresh-install
default. This is an explicit product decision, not an inherited side effect of
the legacy-metadata compatibility rule.**

Rationale:

- Companion mode cannot bootstrap itself. It requires an already enabled native
  `scw` plugin, and the installer deliberately leaves host plugin installation
  and updates to the host plugin flow. Defaulting a clean home to
  `plugin-companion` would make the historical no-flag command fail on every
  clean host.
- Detecting an active plugin and silently selecting companion would make the
  no-flag result depend on ambient machine state and would change what the
  documented unattended command does on hosts that already have the plugin.
- `flat` is the only mode that works on a clean home with no host plugin
  support, no marketplace access, and no network, such as Codex IDE and
  offline or restricted hosts.
- The case for native delivery is real but is a documentation and
  opinionated-setup concern rather than an unattended-default concern. Plugin
  namespaces avoid collisions with unrelated personal skills, and native
  delivery gives the host ownership of provider identity and updates. Prefer
  the native `scw` plugin plus `--delivery-mode plugin-companion` on
  plugin-capable Codex CLI/Desktop and Claude Code, and choose it explicitly
  rather than having the installer infer it.

Unchanged by this decision:

- Deliberate `--delivery-mode flat` installation stays supported.
- Metadata predating `delivery_mode` continues to resolve as `flat`.
- Exactly one auto-invocable Agent Workflows surface stays enforced: `flat`
  requires native `scw` to be inactive, `plugin-companion` requires it to be
  active, and unknown native state fails closed.
- Unrelated personal skills under `<target>/skills` are preserved in both modes.

Revisit this decision when the installer can bootstrap and prove native `scw`
from its own host contract, when partial-failure ownership between host plugin
installation and companion installation is defined, and when
`agent-workflows-status`, `upgrade-agent-workflows`, and `agent-stack` can
report and replay an adaptive default consistently. A native-plugin-first
default belongs to the opinionated ShakaCode `agent-stack` profile and is
tracked separately from this generic installer default.

## Native Plugin Paths

This repository ships native plugin metadata for Codex at
`.codex-plugin/plugin.json` and for Claude Code under `.claude-plugin/`. Both
paths expose the source pack's existing semantic `./skills/` tree through the
plugin identifier `scw`; the skill directories and frontmatter names remain
unprefixed. Claude Code therefore exposes `skills/verify/SKILL.md` as
`/scw:verify`. Claude's plugin manifest publishes `ShakaCode Agent Workflows`
as the UI display name without changing the `scw` install or namespace
identifier.

Install the Claude Code plugin from the repository marketplace:

```text
/plugin marketplace add shakacode/agent-workflows
/plugin install scw@agent-workflows
```

For Codex, point the current marketplace or plugin-source flow at this cloned or
released source pack and select `scw`:

```bash
codex plugin marketplace add shakacode/agent-workflows
codex plugin add scw@agent-workflows
```

The Codex catalog lives at `.agents/plugins/marketplace.json`. Its URL source
lets Codex cache the repository root as the plugin root without duplicating or
relocating `skills/`.

Existing Codex native-plugin users must first remove the old `agent-workflows`
plugin entry, refresh its marketplace, and reinstall it as `scw`. Do not keep
both identifiers enabled: they refer to the same semantic skill tree and would
create a shadow surface.

Only the native plugin identifier changes. The repository, source-pack name,
helper commands, Claude marketplace name, and `.agent-workflows-install.json`
identity remain `agent-workflows`.

Native manifests are deliberately source-pack metadata: consumer repository
commands, labels, branches, changelog rules, CI policy, and review gates still
come from that repository's `AGENTS.md` seam and `.agents/` contract.

## Native Plugin And Host Installer Boundaries

The native paths do not replace installer-managed companion assets. With the
native `scw` plugin enabled, install those assets without flat skills:

```bash
bin/install-agent-workflows --host claude --delivery-mode plugin-companion
bin/install-agent-workflows --host codex --delivery-mode plugin-companion
```

Native plugin installation does not install helper binaries on `PATH`, write
`<target>/.agent-workflows-install.json`, or participate in status and upgrade
behavior by itself. Companion mode supplies those pieces while leaving native
plugin installation and updates under the host plugin flow.

The installer and status helper detect enabled native `scw` state separately
from cached-but-disabled plugin files. They fail closed when native state is
enabled but its install receipt/cache cannot be verified, or when native and
installer-managed flat skills would coexist.

Validate both native manifests, the Claude marketplace, and the complete shared
skill tree from the source pack root with:

```bash
ruby bin/codex-plugin-manifest-check
```

## Install

Clone the source pack once:

```bash
git clone https://github.com/shakacode/agent-workflows "$HOME/src/agent-workflows"
cd "$HOME/src/agent-workflows"
```

Install for Codex:

```bash
bin/install-agent-workflows --host codex
```

Install for Claude Code:

```bash
bin/install-agent-workflows --host claude
```

Install into an explicit shared agent home:

```bash
bin/install-agent-workflows --host codex --target "$HOME/.agents"
```

A clean Codex or Claude installation can plan and launch ordinary batches as
installed. Do not generate project signing keys or provision fixed launch trust
anchors: assignment activation and lane progression use ordinary durable
lifecycle state. Model/effort values are advisory preferences, while any
host/model/effort observations are optional, host-exposed metadata with
field-granular `UNKNOWN` for unavailable values.

Install companion assets for an already-enabled native plugin:

```bash
bin/install-agent-workflows \
  --host codex \
  --delivery-mode plugin-companion
```

When migrating a previous flat install, the installer inventories every known
pack skill before deleting anything. It removes only managed symlinks that still
match the metadata-recorded source revision or copies that match their recorded
fingerprints (with the recorded revision as the backward-compatible fallback).
Modified, mismatched, ambiguous, and unowned paths are preserved; the migration
stops with exact manual cleanup guidance. Unrelated skill names are never
removed.

Then initialize and validate the seam from a consumer repository:

```bash
cd /path/to/consumer/repo
agent-workflow-seam-doctor --init --shared "$HOME/src/agent-workflows"
```

The initializer detects only unambiguous root binstubs or exact JavaScript
scripts with one recognized package-manager lockfile. If it reports
fail-closed wrapper guidance, configure the generated wrappers or rerun with
both `--validate-command` and `--test-command`.

For local development on this pack, symlink mode keeps the installed skills
pointing at the clone:

```bash
bin/install-agent-workflows --host codex --mode symlink
```

## Full Stack Contributor Setup

For a hackable ShakaCode full-stack local setup, run the stack sync helper from
the source checkout:

```bash
bin/agent-stack sync
```

`agent-stack` is ShakaCode-specific stack tooling, not part of the generic
workflow-pack install path for consumer repositories.

Install Node.js 22.12.0 or newer and npm 10 or newer before the first sync.
The checked-out dashboard package can declare a newer Node.js floor.
`agent-stack sync` checks both tools before it installs dependencies or
commands. If the check fails, install the reported version and run the sync
again.

It keeps editable source checkouts in `~/src`, private stack runtime state
under `~/.agent-workflows`, dashboard configuration under
`~/.config/agent-coordination-dashboard`, compatibility symlinks under
`~/codex/agent-repos`, and installs the shorter `agent-stack` command for
future runs:

```text
~/src/agent-workflows
~/src/agent-coordination
~/src/agent-coordination-dashboard

~/.agent-workflows/
  cache/
  logs/
  state/
```

After the first sync, update the stack with `agent-stack sync`. Select companion
mode once with `agent-stack sync --delivery-mode plugin-companion`; later syncs
replay the install metadata when the option is omitted.

The sync uses the dashboard checkout's committed `package-lock.json`, builds
that checkout, and exposes `agent-coordination-dashboard` beside `agent-stack`
and `agent-coord`. It does not copy dashboard lifecycle behavior into this
repository. The generic `bin/install-agent-workflows` command does not install
the dashboard or other optional ShakaCode stack tools.

### Configure And Start The Dashboard

`agent-stack sync` updates the source checkouts and installed tools. It does not
restart the coordination dashboard or active agent runners.

The dashboard's default protected environment file is
`~/.config/agent-coordination-dashboard/env`. Set `AGENT_COORD_ENV_FILE` when
you want the coordination CLI to use another file, then pass that same path to
the dashboard with `--config-env-file`. The dashboard does not read
`AGENT_COORD_ENV_FILE` implicitly. Pass the same path to both commands as shown
below.

Create the file without putting secrets in the repository or shell history:

```bash
dashboard_env_file="${AGENT_COORD_ENV_FILE:-$HOME/.config/agent-coordination-dashboard/env}"
mkdir -p "$(dirname "$dashboard_env_file")"
umask 077
touch "$dashboard_env_file"
chmod 600 "$dashboard_env_file"
```

Edit the file in a private editor. Use plain `KEY=value` assignments from the
dashboard and coordination documentation. For the HTTP backend, the file
normally includes these keys:

```text
AGENT_COORD_API_URL=https://coord.example.test
AGENT_COORD_API_TOKEN=replace-with-machine-token
```

The file must be a regular file that the current user owns, with mode `0600`.
The dashboard rejects unsafe files and shell syntax. On each `start` or
`restart`, it clears managed coordination API values before it applies the
selected file. If you remove the API URL and token from the file, the new
dashboard process cannot inherit the old values and returns to filesystem mode.

Verify the coordination backend from the exact selected file before the first
start. Then start and inspect the dashboard:

```bash
agent-stack sync
env -u AGENT_COORD_API_URL -u AGENT_COORD_API_TOKEN \
  -u AGENT_COORD_MACHINE_ID -u AGENT_COORD_BACKEND -u AGENT_COORD_REF \
  -u AGENT_COORD_STATE_ROOT -u AGENT_COORD_STATUS_STATE_ROOT \
  -u AGENT_COORD_LOCAL -u AGENT_COORD_POLICY \
  AGENT_COORD_ENV_FILE="$dashboard_env_file" agent-coord doctor --deep
agent-coordination-dashboard start --config-env-file "$dashboard_env_file"
agent-coordination-dashboard status
agent-coordination-dashboard logs
agent-stack doctor --deep
```

Use `agent-coordination-dashboard open` to open the managed URL. `start` is
idempotent. If the dashboard is already running after its environment file
changes, use `restart`; a repeated `start` does not reload configuration.

### Diagnose Dashboard Problems

Use the component-owned commands before changing process state:

```bash
agent-coordination-dashboard status
agent-coordination-dashboard logs
agent-coordination-dashboard doctor --stack-json --deep
env -u AGENT_COORD_API_URL -u AGENT_COORD_API_TOKEN \
  -u AGENT_COORD_MACHINE_ID -u AGENT_COORD_BACKEND -u AGENT_COORD_REF \
  -u AGENT_COORD_STATE_ROOT -u AGENT_COORD_STATUS_STATE_ROOT \
  -u AGENT_COORD_LOCAL -u AGENT_COORD_POLICY \
  AGENT_COORD_ENV_FILE="$dashboard_env_file" agent-coord doctor --deep
agent-stack doctor --deep
```

The dashboard command owns lifecycle state, process ownership, health, and
logs. The coordination CLI owns backend diagnosis. `agent-stack doctor`
aggregates those component contracts; it does not recreate their checks or
restart a process.

### Rotate A Coordination Token

Write the replacement token to the protected file, keep its mode `0600`, and
use this order:

```bash
chmod 600 "$dashboard_env_file"
env -u AGENT_COORD_API_URL -u AGENT_COORD_API_TOKEN \
  -u AGENT_COORD_MACHINE_ID -u AGENT_COORD_BACKEND -u AGENT_COORD_REF \
  -u AGENT_COORD_STATE_ROOT -u AGENT_COORD_STATUS_STATE_ROOT \
  -u AGENT_COORD_LOCAL -u AGENT_COORD_POLICY \
  AGENT_COORD_ENV_FILE="$dashboard_env_file" agent-coord doctor --deep
agent-coordination-dashboard restart --config-env-file "$dashboard_env_file"
agent-coordination-dashboard status
agent-stack doctor --deep
```

Do not restart the dashboard until the coordination doctor succeeds. The
restart loads the selected file into a new managed process. It does not depend
on a terminal multiplexer or a long-lived shell environment, so no terminal or
agent-runner restart is required. A `401` after the restart means that the
dashboard and CLI diagnostics need further backend or scope investigation; use
`logs` and the deep component doctors above.

### Stop Or Remove The Dashboard

Stop the owned process without removing the stack:

```bash
agent-coordination-dashboard stop
```

For the default full-stack layout, remove the installed command and dashboard
source checkout only after `stop` succeeds:

```bash
rm "$HOME/.local/bin/agent-coordination-dashboard"
rm -rf "$HOME/src/agent-coordination-dashboard"
```

This leaves the protected environment file, lifecycle logs, and lifecycle
state for recovery or audit. Remove
`~/.config/agent-coordination-dashboard/` and
`~/.local/state/agent-coordination-dashboard/` separately only when you no
longer need those private files. A later `agent-stack sync` restores the public
checkout and command. Removing a personal alias or private launcher does not
remove this lifecycle functionality.

The public dashboard defaults to port `4319`. A process from an older launcher
on another port is not owned by this command. Stop it through its original
owner before starting the public lifecycle command; `agent-stack` never signals
an unverified process.

Existing agent tasks do not need to restart merely because the stack was
synced. Follow [Active Batches](#active-batches) when a task genuinely needs
newly installed workflow instructions.

### Full Stack Doctor

Use `agent-stack doctor` as the master health check for the complete local
ShakaCode stack:

```bash
agent-stack doctor
agent-stack doctor --deep
```

The master inspects only generic source-checkout and compatibility-link state.
It then invokes one bounded, read-only doctor owned by each component
repository. The workflow component owns install and seam checks, coordination
owns its CLI/backend/resource checks, and the dashboard owns package, service,
and runtime checks. `--deep` is forwarded to all three delegates; the component
contracts decide which extra checks appear or become `skipped`. There is no
fixed 14-check master contract and component check IDs may evolve with their
own schema-compatible releases.

The required component interfaces are:

```text
<target>/bin/agent-workflows-doctor --stack-json [--deep] --host HOST --target DIR --source DIR
<agent-coord-install-dir>/agent-coord doctor --stack-json [--deep] --state-root ~/.agent-workflows/state
node <dashboard-source>/bin/agent-coordination-dashboard.js doctor --stack-json [--deep] --url URL
```

Component doctors are trusted local executables. The master bounds their
output and runtime and terminates the delegate process group on timeout, but it
does not guarantee termination of descendants that deliberately escape that
group with `setsid` or a double fork. Install and run only reviewed component
versions; the master report itself remains time-bounded when an escaped
descendant closes or retains the delegated output streams.

`install-agent-workflows` installs `agent-workflows-doctor` and its focused
Ruby modules in every delivery mode. `agent-stack sync` installs `agent-stack`,
its focused shell modules, `agent-stack-doctor`, and the shared doctor modules.
The coordination and dashboard commands must
come from component versions that implement the interfaces above; until then,
the master reports a generic `<component>.doctor` wrapper check instead of
inventing that component's internal checks.

The human report is intended for interactive diagnosis: it starts with the
overall verdict and component counts, then shows exactly one section for each
repository with unhealthy checks first and a `Next` action for every degraded
or failed check. Use JSON for automation:

```bash
agent-stack doctor --json
agent-stack doctor --deep --json
```

`--json` writes only the aggregate JSON document to standard output. Schema
version `1` includes `schema_version`, aggregate `status`, `deep`, `checked_at`,
and `components`. Every component entry uses the uniform component contract:

```json
{"schema_version":1,"component":"<id>","status":"healthy|degraded|failed","checks":[]}
```

Every check always has string `id`, `status` in
`healthy|degraded|failed|skipped`, string `summary`, object `details`, and
`guidance` as a string or `null`. Unknown additive delegate fields are ignored.
Malformed contracts, component/status/exit mismatches, missing delegates, and
delegate exit `64` become generic wrapper checks. Delegates exit `0` for
healthy, `1` for degraded, `2` for failed, and `64` for usage or inability to
run; the master independently verifies that status/exit parity before merging
generic checks and deriving the aggregate verdict.

Aggregate and component statuses use these meanings:

| Status | Exit | Meaning |
| --- | ---: | --- |
| `healthy` | 0 | All required evidence is known-good and no advisory check is degraded. |
| `degraded` | 1 | The stack is usable, but optional evidence is unavailable or an advisory limitation needs attention. A stopped dashboard is the common example because the dashboard is an optional runtime. |
| `failed` | 2 | Required evidence is missing, unusable, unknown, timed out, or malformed. |

Invalid options, missing Ruby, or a missing master `agent-stack-doctor` helper
are usage/unable-to-run errors and exit `64`. A component delegate that cannot
run does not abort the aggregate: its wrapper check records the failure or, for
the optional dashboard, degradation. Check records use neutral `skipped` for
component work omitted by the default mode.

Location selectors let the doctor inspect a non-default installation without
creating any missing directory:

| Selector | Default |
| --- | --- |
| `--source-root DIR` | `~/src` |
| `--compat-root DIR` | `~/codex/agent-repos` |
| `--runtime-root DIR` | `${AGENT_STACK_RUNTIME_ROOT:-~/.agent-workflows}` |
| `--host codex\|claude\|auto` | `codex` |
| `--target DIR` | The selected host's normal home (`$CODEX_HOME`, `$CLAUDE_HOME`, or its standard fallback) |
| `--agent-coord-install-dir DIR` | `~/.local/bin` |
| `--dashboard-url URL` | `http://127.0.0.1:${PORT:-4319}` |

For safety, `--dashboard-url` accepts only plain HTTP loopback URLs using
`localhost`, `127.0.0.1`, or `[::1]`, without credentials, a query, an endpoint
path, or redirects. The doctor performs only component-owned, validated,
bounded loopback HTTP probes; it does not fetch external resources or mutate
state. It does not sync, install, start the dashboard, create backend state, or
repair anything. Run `agent-stack sync` or the report's specific `Next` action
separately after reviewing the evidence.

Coordination backend selection is read-only and deterministic. Explicit
`AGENT_COORD_STATE_ROOT` (even when the path is missing),
`AGENT_COORD_API_URL`, `AGENT_COORD_BACKEND`, and
`AGENT_COORD_STATUS_STATE_ROOT` take precedence. The master then uses an
existing `<runtime-root>/state`, followed by an existing XDG/default
coordination state root. It never creates a selected root. In particular, a
missing explicit `AGENT_COORD_STATE_ROOT` remains authoritative and is passed
to the component doctor so coordination can return its own failed contract.

The component diagnostics remain useful primitives when you need their native,
component-specific detail. Start with `agent-stack doctor`; when its report
points at workflows, run the workflow component with every required selector:

```bash
"$HOME/.codex/bin/agent-workflows-doctor" --stack-json \
  --host codex --target "$HOME/.codex" \
  --source "$HOME/src/agent-workflows"
```

Run `agent-coord doctor --stack-json --state-root ~/.agent-workflows/state` or
the dashboard CLI directly when the master report points at those components.
`agent-workflows-status` and
`agent-workflow-seam-doctor` remain lower-level workflow helpers used by the
workflow-owned doctor.

The installer writes:

- `<target>/skills/*` in `flat` delivery mode only
- `<target>/LICENSE`
- `<target>/THIRD_PARTY-NOTICES.md`
- `<target>/workflows/*`
- `<target>/docs/coordination-backend.md`
- `<target>/docs/execution-provenance-schema.md`
- `<target>/docs/review-finding-schema.md`
- `<target>/docs/agent-workflows-model-routing.md`
- `<target>/docs/user-facing-coordination.md`
- `<target>/docs/writing-style.md`
- `<target>/docs/writing-style-asd-ste100.md`
- `<target>/docs/solutions/*`
- `<target>/bin/agent-workflow-seam-doctor`
- `<target>/bin/agent-workflow-writing-style`
- `<target>/bin/validate-execution-provenance`
- `<target>/bin/agent_doctor/*` (focused runtime modules shared by the workflow and master doctors)
- `<target>/bin/agent-workflows-delivery-state`
- `<target>/bin/agent-workflows-doctor`
- `<target>/bin/agent-workflows-status`
- `<target>/bin/agent-workflows-trust-audit`
- `<target>/bin/install-agent-workflows`
- `<target>/bin/upgrade-agent-workflows`
- `<target>/.agent-workflows-install.json`

Copy mode replaces this pack's license and third-party notice files, skill and
workflow names, plus the pack-owned docs listed above; it preserves unrelated
files already present in the target agent home, including generic
consumer-owned docs under `<target>/docs`.

The metadata file records host, artifact mode, skill delivery mode, source
clone, pack version, source revision, branch, remote, and install time. Copy
installs also record `managed_skill_copy_fingerprints`,
`managed_pack_doc_copy_fingerprints`, and `managed_pack_root_copy_fingerprints`,
including every installed `<target>/docs/solutions/*` document and the
third-party notice. On repeat installation, these fingerprints
prove that an installed managed copy has not been edited even when the recorded
Git object is unavailable; an exact recorded-revision or current-source match is
the backward-compatible fallback for older metadata. The installer refuses to
replace a modified, symlinked-to-an-unowned-target, or otherwise ambiguous
managed copy, including unexpected files nested inside a managed skill. Restore
the original installed content or move personal content to a distinct path
before retrying. The status and upgrade helpers use the metadata so they can run
from either the source clone or the installed host.

## Status Checks

For the full three-repository contributor stack, start with
`agent-stack doctor`. The status helper below is the narrower primitive for the
installed `agent-workflows` pack only.

Check the installed pack against the source clone recorded at install time:

```bash
agent-workflows-status --host codex
```

Check a specific install and source:

```bash
agent-workflows-status \
  --target "$HOME/.codex" \
  --source "$HOME/src/agent-workflows"
```

Stable status tokens:

| Token | Exit | Meaning |
| --- | ---: | --- |
| `UP_TO_DATE` | 0 | Installed revision matches the available source revision. |
| `UPGRADE_AVAILABLE` | 1 | Source has a different revision than the installed metadata. |
| `NOT_INSTALLED` | 2 | Target has no `.agent-workflows-install.json`. |
| `CHECK_FAILED` | 3 | The check could not safely determine status. |

Use `--json` for machine-readable output. Use `--fetch` only when you want a
network check against `origin`; without `--fetch`, status compares against the
current local source clone. Status also reports `delivery_mode`, native plugin
evidence, and flat-skill inventory. A collision, ambiguous native state, or an
invalid companion layout returns `CHECK_FAILED` with cleanup guidance.

## Upgrade

Upgrade the source clone, reinstall the pack, and validate a consumer repo seam:

```bash
upgrade-agent-workflows \
  --host codex \
  --consumer-root /path/to/consumer/repo
```

For an already-updated local source clone, skip the network step:

```bash
upgrade-agent-workflows \
  --host codex \
  --source "$HOME/src/agent-workflows" \
  --consumer-root /path/to/consumer/repo \
  --no-fetch
```

Preview without mutating the install:

```bash
upgrade-agent-workflows --host codex --dry-run
```

Upgrade behavior:

1. Resolve target and source from arguments or install metadata.
2. Fetch and fast-forward the source clone unless `--no-fetch` is set.
3. Back up the target install.
4. Reinstall with the recorded or requested artifact and delivery modes.
5. Run `agent-workflow-seam-doctor --root <consumer> --shared <source>` for
   every `--consumer-root`.
6. Restore the previous install if reinstall or seam validation fails.

The command prints `UPGRADE_COMPLETE` on success and `ROLLBACK_COMPLETE` when it
restores the prior install after a failed upgrade. Rollback restores the prior
delivery mode and skill layout. `upgrade-agent-workflows` never installs or
updates the native plugin itself.

## Verification After Upgrade

For the shared pack itself:

```bash
cd "$HOME/src/agent-workflows"
bin/validate
```

For each active consumer repo:

```bash
cd /path/to/consumer/repo
agent-workflow-seam-doctor --shared "$HOME/src/agent-workflows"
```

The autonomous-merge gate takes effect from the installed workflow pack even
when a consumer has no `autonomous_merge` mapping; omission uses portable
defaults rather than a permissive grace period. Preset-based downstream sync
may seed `autonomous_merge: {}` but must preserve any repo-owned mapping.
Before rollout, run the seam doctor in every consumer. To collect a
checkpointed, decision-free shadow dataset for threshold review:

```bash
# First use an explicit PR_BATCH_SKILL_DIR, then the host's loaded-skill base;
# use a repo-pinned copy only when neither is available.
if [[ -z "${PR_BATCH_SKILL_DIR:-}" ]]; then
  if [[ -x .agents/skills/pr-batch/bin/autonomous-merge-calibrate ]]; then
    PR_BATCH_SKILL_DIR=.agents/skills/pr-batch
  else
    echo "Cannot resolve PR_BATCH_SKILL_DIR" >&2
    exit 1
  fi
fi
"${PR_BATCH_SKILL_DIR}/bin/autonomous-merge-calibrate" \
  --collect .agents/cache/autonomous-merge-calibration-dataset.json \
  --repo OWNER/REPO \
  --since YYYY-MM-DD
```

The collection mode is GitHub-read-only and resumes the explicit checkpoint
without refetching completed PR detail. Because closed-PR update order is
mutable, incomplete discovery restarts at page 1. Before marking discovery
complete, collection repeats the entire ordered traversal and requires the
second `[number, merged_at]` snapshot to match the first exactly. A mismatch or
verification API, pagination, or rate-limit failure checkpoints a page-1
restart. Use repeated `--repo` flags and exactly one of `--since YYYY-MM-DD` or
`--pr-count N`. API, pagination, and rate-limit stops leave the checkpoint
incomplete with failure evidence; rerun the same command to resume. Once
`scope.complete` is true, analyze it separately:

```bash
"${PR_BATCH_SKILL_DIR}/bin/autonomous-merge-calibrate" \
  --input .agents/cache/autonomous-merge-calibration-dataset.json \
  --repo OWNER/REPO \
  --since YYYY-MM-DD \
  > .agents/cache/autonomous-merge-calibration-report.json
```

Do not graduate `max_reviewed_heads` from shadow reporting until the cached
dataset covers submitted-review history, the distribution and sampled near
misses have been reviewed, and a threshold decision is recorded. The
calibration helper emits no merge decisions.

Then dry-run one installed workflow, such as `$plan-pr-batch` or
`$address-review`, until it resolves base branch, validation, hosted CI,
review-gate, changelog, and follow-up values from the repo seam without making
code changes.

## Codex And Claude

The skill Markdown is host-neutral. Codex and Claude both use the same
`skills/`, `workflows/`, `docs/`, and `bin/` layout after installation. Files under
`skills/*/agents/openai.yaml` are optional Codex UI metadata and are ignored by
Claude.

Some workflow steps name host-specific tools, such as `codex review`, Claude
Code slash commands, or `/simplify`. Treat those as available-tool branches:
use them only when the current host actually provides them, and record the
fallback when it does not. The repo seam still controls repository policy.

## Active Batches

Do not stop healthy in-flight batches just because the shared pack changed.
Long-running agents usually keep the skill text they already loaded. Use the new
pack for new batches and canary runs. Restart only lanes that are blocked by
stale workflow instructions or that explicitly need the new process.

## Network And Privacy

`agent-workflows-status` does not contact the network unless `--fetch` is
provided. `upgrade-agent-workflows` fetches and fast-forwards the source clone by
default. Use `--no-fetch` when the source clone has already been updated or when
the session must avoid network access.

## Troubleshooting

- `NOT_INSTALLED`: run `bin/install-agent-workflows --host <host>` or pass the
  correct `--target`.
- `CHECK_FAILED missing source root`: reinstall from a valid clone, or pass
  `--source /path/to/agent-workflows`.
- `UPGRADE_AVAILABLE`: run `upgrade-agent-workflows` or manually update the
  source clone and reinstall.
- `Auto host detection found both Codex and Claude homes`: rerun with
  `--host codex` or `--host claude`.
- `Refusing to replace non-symlink path`: symlink mode will not overwrite a real
  file or directory. Use copy mode or remove the conflicting path deliberately.
- `DELIVERY_MODE_CONFLICT`: keep one skill delivery route. Disable/remove the
  native `scw` plugin before a flat install, or use
  `--delivery-mode plugin-companion`. If exact paths are listed, they were
  preserved because ownership or content could not be proved; inspect and move,
  restore, or remove them manually before retrying.
- `invalid byte sequence in US-ASCII` or other `Encoding::` errors from a Ruby
  helper: an older install is running under a non-UTF-8 locale (`LANG=C` /
  `LC_ALL=C`, common in CI and headless agents). The pack Ruby tools now read
  text as UTF-8 regardless of locale; run `upgrade-agent-workflows --host <host>`
  to pick up the fix.
