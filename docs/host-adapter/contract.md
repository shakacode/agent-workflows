# Host Adapter Contract

Date: 2026-07-02
Status: accepted

Prompt compatibility protocol: 1

This contract defines how one installed `agent-workflows` pack runs in both
Codex Desktop and Claude Code Desktop without forking shared skills or workflow
text. Shared skill text stays portable. Host-specific behavior lives in this
document, optional host metadata, and the current host's runtime configuration.

Consumer repository policy still comes from `AGENTS.md` under
`## Agent Workflow Configuration`, plus `.agents/bin/` and
`.agents/agent-workflow.yml` when the consumer repo uses the seam model.

## Portable Core

The installed pack has the same portable shape on every supported host:

- `skills/*/SKILL.md` contains host-neutral workflow instructions.
- `workflows/*.md` contains reusable workflow prompts and deeper operating
  models.
- `bin/*` contains helper scripts used by skills and workflows.
- Optional host metadata may sit beside the portable text, but the installer
  must not rewrite the portable Markdown per host.

Portable skills may name host-neutral actions such as "dispatch a worker",
"run without blocking approval prompts", "isolate each file-editing worker in
its own worktree", "record a follow-up", or "run the review gate". The host
adapter maps those verbs to the current host's mechanisms at runtime.

## Host Table

| Area | Codex Desktop | Claude Code Desktop |
| --- | --- | --- |
| Primary repo instructions | `AGENTS.md`, with `agents.md` accepted only when the host explicitly resolves it | `CLAUDE.md`, usually as a thin import or pointer back to `AGENTS.md` |
| Shared skill location | `${CODEX_HOME:-$HOME/.codex}/skills` | `${CLAUDE_HOME:-$HOME/.claude}/skills` |
| Shared workflow location | `${CODEX_HOME:-$HOME/.codex}/workflows` | `${CLAUDE_HOME:-$HOME/.claude}/workflows` |
| Shared helper location | `${CODEX_HOME:-$HOME/.codex}/bin` | `${CLAUDE_HOME:-$HOME/.claude}/bin` |
| Optional metadata | `skills/*/agents/openai.yaml`, `.agents/plugins/marketplace.json`, and `.codex-plugin/plugin.json` (`scw`) | `.claude-plugin/plugin.json` plus marketplace metadata (`scw`) |
| Persistent memory | Codex memory locations exposed by the current runtime, only after availability check | Claude Code persistent workspace or project-root locations exposed by the current runtime, only after availability check |
| Repo policy source | Consumer `AGENTS.md` and `.agents/agent-workflow.yml` | `CLAUDE.md` may route to `AGENTS.md`; consumer `AGENTS.md` and `.agents/agent-workflow.yml` remain the policy source |

If a host cannot load installed shared skills, use a repo-pinned `.agents/`
copy as the fallback. Repo-local copies may carry pinned compatibility changes,
so resolve them before the installed home.

Native plugins add a host namespace without changing the portable skill name:
Codex uses the plugin-qualified `scw:<skill>` surface and Claude Code uses
`/scw:<skill>`. Claude's plugin manifest publishes `ShakaCode Agent Workflows`
as the human-readable `displayName`; `scw` remains the stable install, lookup,
and namespace identifier. The Host Installer Path defaults to flat and
unqualified skills;
its `plugin-companion` delivery mode installs only workflows, docs, helpers, and
metadata. Use exactly one auto-invocable skill delivery route per host/profile.
Native-plus-flat collisions and uncertain migration ownership must fail closed.
Compatibility shims are allowed only when the host proves they are
explicit-invocation-only; never leave two auto-invocable aliases.

## Runtime Host Detection

Runtime host detection is best-effort. An explicit user-requested host, runner,
or paste destination wins over inference. Installed-home auto detection, such as
`agent-workflows-status --host auto` or installer `--host auto`, detects Codex
and Claude homes; it does not prove which runner is executing the current
prompt. When both homes exist, the install/status tools must ask for
`--host codex` or `--host claude` instead of guessing.

A coordinator may infer the active host only from reliable runtime-exposed
signals, such as Codex `/goal` support or Codex-specific tooling for Codex, and
Claude Code slash commands or subagent runtime support for Claude Code. If those
signals are absent or mixed, use the `generic` prompt target and conservative
batch sizing.

Model and effort selections remain advisory preferences across every host. A
host adapter may report observed host, model, and effort only from runtime state
it actually exposes; every unavailable field is `UNKNOWN`, and absence or
mismatch never alone blocks workflow progress. The host owns any route-exposure
mechanism. Agent Workflows does not provision or require signing keys, fixed
trust anchors, launch-confirmation receipts, or human waivers. Prompt conversion
for incompatible runtime instructions is tracked separately in
[issue #372](https://github.com/shakacode/agent-workflows/issues/372).

## Prompt Compatibility Boundary

Every generated batch, goal, or direct prompt starts with these fields after an
optional Codex `/goal` wrapper: <!-- host-allow: codex-only -->

```text
Prompt host: codex|claude|portable
Prompt mode: goal|direct|batch
Preferred route: default|<model-or-class>/<effort>
Route requirement: advisory
```

Codex `goal` requires the wrapper. Codex and Claude `batch` or `direct` prompts
have no wrapper. Portable prompts have no wrapper and use neutral skill prose.
The preferred route is metadata only: availability or substitution cannot
weaken a gate or block an otherwise valid prompt.

Before worker launch, repository mutation, or a GitHub write, resolve and run
the loaded or repo-pinned `pr-batch/bin/prompt-compatibility` helper with an
explicit `--active-host codex|claude`. Do not infer the active runner from
installed homes, prompt prose, a model name, or the preferred route. The helper
is read-only: it consumes the complete prompt on standard input and emits the
v1 JSON shape in
[`prompt-compatibility-v1.schema.json`](../schemas/prompt-compatibility-v1.schema.json).
It verifies this document's `Prompt compatibility protocol: 1` marker before
returning a portable decision, so a missing or mixed-revision adapter fails
closed.

The only successful decisions are:

| Decision | Execution boundary |
| --- | --- |
| `compatible` | Continue through ordinary gates with the original prompt bytes. |
| `portable` | Resolve neutral verbs through this host adapter, then continue through ordinary gates with the original prompt bytes. |
| `conversion-required` | The returned conversion is inert. Display or copy it and stop; never execute it in this run. |

Unknown or mixed active-host evidence, invalid encoding, incomplete,
duplicated, reordered, contradictory, or non-advisory metadata, unsupported
mechanics, and unrecognized input produce a nonzero error record. Error records
omit a decision and all prompt text. Legacy detection is deliberately bounded
to a leading Codex `/goal` immediately followed by a `$pr-batch` invocation. <!-- host-allow: codex-only -->
Incidental Codex or Claude names do not establish a host and never produce a
conversion.

Known cross-host conversion changes only the header host/mode, the optional
Codex Goal wrapper, `pr-batch` / `pr-walkthrough` invocation sigils, and an
explicit host-specific batch-size target. Codex Goal becomes Claude `batch`;
Claude-to-Codex conversion does not invent Goal mode. Objective, targets,
scope, dependencies, permissions, safety gates, QA, review, merge authority,
and the preferred advisory route remain byte-identical. Any other detected
host-specific mechanism is unsupported input and stops rather than being
guessed.

## Host-Owned Fact Rollout

Before any host-owned fact becomes a portable mandatory gate, the proposal must
name an accountable owner for each producer, verifier, provisioner, and
installer role and define clean-install acceptance for every supported host.
Record that ownership in the design or PR with this minimum matrix:

| Host-owned fact | Producer owner | Verifier owner | Provisioner owner | Installer owner | Clean-install acceptance |
| --- | --- | --- | --- | --- | --- |
| Named fact and schema | Accountable component/person | Accountable component/person | Accountable component/person | Accountable component/person | Commands and expected evidence for Codex and Claude |

Every owner must be named and every role must have an implemented path. The
clean-install acceptance must start from an empty supported host target, install
through the public installer path, exercise the real producer and verifier, and
prove that provisioning makes the evidence available without fixture-generated
keys, receipts, or pre-seeded local state.

If any role or clean-install acceptance is absent, the capability remains
optional and advisory; unavailable host-owned fields use `UNKNOWN` and do not
block otherwise valid workflow progress. Unit-tested verification without its
producer, provisioning, installation, and clean-install path is not rollout
readiness.

## Invocation Syntax

Shared docs may mention the portable skill name, but user-facing prompts must
mark host-specific syntax when a literal invocation is required.

| Meaning | Codex Desktop | Claude Code Desktop | Portability rule |
| --- | --- | --- | --- |
| Invoke a shared skill | `$name` or skill picker selection | `/name` when exposed as a slash command or skill | Use neutral prose unless the branch is marked for one host. |
| Run `pr-batch` | `$pr-batch` | `/pr-batch` if installed for Claude Code | Do not install-time rewrite one form into the other. |
| Start a Codex goal prompt | `/goal` | n/a | `/goal` is Codex-only and must appear only inside a marked Codex branch. |
| Address review comments | `$address-review` | `/address-review` when available | Availability-check the command or skill before use. |
| Simplify a diff | `/simplify` when Codex exposes it through the active workflow | Claude slash command or CLI support when available | Treat `/simplify` as host-specific, never as guaranteed portable syntax. |

When a document needs both forms, write separate marked branches, for example
"Codex: `$pr-batch`" and "Claude Code: `/pr-batch`". Do not write one mixed
command that assumes both hosts parse the same syntax.

## Portable Verbs

Shared skill text should prefer these verbs and let the adapter choose the
mechanism:

| Portable verb | Codex Desktop mechanism | Claude Code Desktop mechanism |
| --- | --- | --- |
| Dispatch a worker per lane | Goal chats, cloud tasks, separate Codex sessions, or separate machines | `Agent` or `Workflow` subagents when available |
| Isolate each file-editing worker in its own worktree | `git worktree add` per worker or lane | `Agent` / `Workflow` subagents with `isolation: 'worktree'` |
| Run without blocking approval prompts | Codex sandbox and approval settings chosen before launch | Claude Code permission mode and `settings.json` allowlists chosen before launch |
| Resolve repo commands and policy | `AGENTS.md`, `.agents/bin/`, and `.agents/agent-workflow.yml` | `CLAUDE.md` routes to `AGENTS.md`; then `.agents/bin/` and `.agents/agent-workflow.yml` |
| Record a follow-up | Use the consumer repo's follow-up prefix and tracking rules from the seam | Same seam; do not invent Claude-specific labels or trackers |
| Run an independent review pass | `codex review` only when the command is present | Claude Code review slash command or CLI only when present |

If a host lacks a mechanism for the requested verb, stop with a precise blocker
instead of silently weakening the workflow.

## Scheduled Monitoring and Planning-Chat Lifecycle

The portable completion contract prefers one deduplicated deterministic
**state-change watcher** for a blocker that can clear without user input. A host
may advertise this capability only when its adapter can collect a sanitized
authoritative observation, resolve `PR_BATCH_SKILL_DIR` through the standard
explicit environment / loaded skill base / repo-pinned fallback chain, and
invoke `"${PR_BATCH_SKILL_DIR}/bin/goal-state-change-monitor" --state <path>`
outside parent task context, before any model continuation. `suppress-unchanged`,
`suppress-stale-probe`, `suppress-replayed-probe`, and
`suppress-acknowledgement-retry` must not re-enter the parent task.
`wake_parent: true` is authoritative: `wake-state-change`, `fallback-model-poll`,
`stop-dependency-terminal`, and `redeliver-pending-wake` re-enter it with the
compact `state_delta` when present and then rerun all mandatory gates. The
adapter must durably
enqueue that continuation before acknowledging its `wake_id`; until then,
`redeliver-pending-wake` remains a waking result so a runner restart cannot lose
the transition. Its returned `acknowledgement_payload` is the exact bounded
payload to submit after durable enqueue; do not rebuild it from a newer live
observation. Acknowledgement is idempotent: retrying the same acknowledged
`wake_id` is a non-waking replay and cannot fail a recovered runner.
The reducer keeps this state bounded and does not persist an
acknowledgement-membership ledger. It validates the current pending or last
decision directly. Delayed acknowledgement retries replay the original
canonical observation and `probe_sequence`; the reducer accepts only a
`wake_id` derived from that fingerprint and a waking action possible for the
submitted capability and statuses, without mutating newer state. Attaching an
old acknowledgement to unrelated newer evidence, or naming an impossible
waking action, fails closed. For bounded migration, legacy
`acknowledged_wake_ids` is dropped on the next state persistence.

`blocker_state` is an object whose arrays are set-valued collections; adapters
must encode ordered sequences as keyed objects. The reducer canonicalizes object
keys and set members before hashing so API result order alone cannot wake the
parent task.

A retry with the same `probe_sequence` must replay a canonical-equivalent observation payload.
For state carrying the current `observation_digest_version`, only `observed_at` and
`acknowledged_wake_id` may differ. Legacy state without `observation_digest_version`
must first replay the exact prior `observed_at` and payload so the reducer can migrate it;
a restamped legacy retry fails closed. A substantive change to
`blocker_state`, `resume_instruction`, limits, polling policy, capability, or task/dependency
status at the same sequence fails closed as `probe-replay-mismatch`; advance the sequence for
new evidence.

Adapters must provide a nonempty `resume_instruction` for every observation so
any terminal or budget handoff remains actionable. A blocked-user-input
`blocker_state` must also carry the exact nonempty `question`; the reducer
persists both values in its non-waking manual handoff.
When an unsupported capability and a budget ceiling coincide, the unsupported
handoff also preserves `budget_reason`, `usage`, and `limits`.

This source pack defines the portable reducer verb and adapter contract; it
does not implement a live host scheduler. Current-thread scheduling alone is
not deterministic-watcher capability. When a host lacks the out-of-context
verb, advertise `model-polling-only` and use one inspectable, updatable,
stoppable bounded fallback, or advertise `unsupported` and preserve the exact
manual-resume instruction.

| Portable lifecycle | Codex Desktop | Claude Code (CLI and Desktop) |
| --- | --- | --- |
| Deterministic state-change watcher | Advertise `deterministic-watcher` only when a configured adapter verb runs the sanitized probe and reducer outside task context, persists one stable monitor identity, and resumes the same task for every `wake_parent: true` decision, including an idempotent `redeliver-pending-wake` after restart. Without that verb, use `model-polling-only` or `unsupported`; a scheduled task that first reloads the parent does not qualify. | Apply the same capability test. Background Bash or Monitor work is not restored on resume, and `/loop`/Cron re-entry is model-mediated rather than proof of an out-of-context reducer verb; use it only as the bounded fallback unless a configured adapter supplies the required verb. [Scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks) |
| Current-thread bounded fallback | Use the current task's recurring wake mechanism only when it can be inspected, updated, and stopped. Keep one monitor identity; use four 15-minute fast-window polls, exponential backoff capped at four hours, finite unchanged-run/call/token ceilings, and stop or pause on clear, done, terminal, user-input, or budget state. | In the current Claude Code session, `/loop <interval> <prompt>` or Cron may provide the same bounded fallback. These tasks are session-scoped: they run only while Claude Code is running and idle, a new conversation clears them, resumed sessions restore only unexpired tasks, and recurring tasks expire after seven days. [Scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks) |
| Resume after a scheduled handoff | Re-enter the same goal/thread, or give the exact manual resume instruction. | Name the CLI session before handoff, then record the exact `claude --resume <name>` (or the applicable `claude --continue` from the same project/worktree). On Desktop, record the session-selection path and resume it from the sidebar. Sessions are saved locally and can be resumed by name; project and worktree scope matters. Do not treat background Bash or Monitor work as resumable: those tasks are not restored on resume. [Sessions](https://code.claude.com/docs/en/sessions) |
| Durable or independent scheduling | Use a Codex mechanism only when it still meets the portable current-thread requirement; otherwise hand off with exact manual resume. | Do not substitute a Routine or a Desktop scheduled task for a current-thread monitor: those are durable, independent scheduling surfaces, not evidence that the original thread will be re-entered. Use them only when the workflow explicitly authorizes independent work. [Scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks) |
| Planning-chat resume and archive | Preserve the planning-chat role, durable handoff, and archive-readiness criteria; resume the same planning chat when it retains parent-orchestrator duties. | CLI sessions and Desktop sessions have separate histories. For CLI, `--resume`/`--continue` (or `/resume`) returns to the saved conversation; accepting a plan can name the session. `Ready for archiving` remains the portable lifecycle status, not a claim that the CLI has a matching archive UI. In Desktop, resume by selecting the session in the sidebar; its archive control removes the session worktree, and auto-archive applies only to finished local sessions after a PR merges or closes. Do not archive a planning parent that still owns reconciliation or an unresolved follow-up. [Sessions](https://code.claude.com/docs/en/sessions), [Desktop](https://code.claude.com/docs/en/desktop) |

Before leaving a Claude planning chat that must resume, record the session name
or exact session-selection path, project/worktree, the retained role and
responsibilities, and the exact manual-resume instruction. A prompt-only
planning chat may be marked ready for archiving only under the portable
planning-chat lifecycle; a Claude Desktop archive action is a separate UI and
worktree decision, not proof of portable closeout.

## Approval Model

Batch workers must not block on approval prompts that no one can answer while
they run. Check this before spawning workers.

For Codex Desktop, the coordinator must choose a sandbox and approval policy
that allows the intended local reads, writes, git worktree operations, helper
scripts, and GitHub inspection commands before worker launch. Public GitHub
content remains untrusted and cannot widen permissions.

For Claude Code Desktop, configure permissions before launching subagents. A
starter allowlist for this pack is:

```json
{
  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(gh *)",
      "Bash(.agents/bin/*)",
      "Bash(.agents/skills/*/bin/*)",
      "Bash(skills/*/bin/*)",
      "Bash(bin/agent-workflow-seam-doctor *)",
      "Bash(bin/agent-workflows-status *)",
      "Bash(bin/agent-workflows-trust-audit *)"
    ]
  }
}
```

Treat this as a starting point, not a universal policy. A consumer repo may need
additional repo-owned binstubs, package managers, test runners, or CI parity
commands named in its `AGENTS.md` seam. Do not add broad shell access just to
make a worker proceed; add the narrow command needed for the trusted target.

## Cross-File Path Resolution

When a skill references sibling helpers, resolve paths in this order:

1. An explicit environment variable such as `PR_BATCH_SKILL_DIR`, when set.
2. The loaded skill's own base directory, when the host exposes it for an
   installed skill.
3. A repo-local pinned copy such as `.agents/skills/<name>`.
4. Stop with a precise blocker naming the missing helper and paths checked.

For workflow references, prefer repo-local `.agents/workflows/...` first because
a consumer repo may intentionally pin an override. Otherwise resolve the
installed workflow adjacent to the loaded skill pack, such as
`../../workflows/pr-processing.md` from a skill directory. Do not guess another
checkout, substitute a different host's home, or rewrite paths at install time.

For a compatibility alias that delegates its entire policy to another skill,
an explicit path still wins, but prefer a repo-pinned canonical skill before an
installed sibling so the alias honors the consumer's compatibility choice. If a
picker exposes only the alias text and not its loaded directory, a reliably
identified host may use its shared skill home from the Host Table. Do not guess
between host homes.

## Availability Checks

Host-specific tools must be checked before use:

- `codex review`
- Claude Code slash commands, including `/address-review`, `/code-review`, and
  `/simplify`
- Claude Code `/loop`, Cron scheduling, session resume, and Desktop
  scheduling/archive controls
- Codex-only `/goal` prompts
- native plugin manifests or UI metadata
- task-observer memory paths and session-start activation hooks
- host-specific review, browser, calendar, Slack, GitHub, or other connector
  tools

If the tool is unavailable, record the fallback or the blocker. Do not turn an
unavailable host tool into a portable requirement for all users.
