# Host Adapter Contract

Date: 2026-07-02
Status: accepted

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
trust anchors, launch-confirmation receipts, or human waivers.

## Runtime Prompt Adaptation

Every pasteable batch, goal, or direct pr-batch prompt must declare its runtime
contract before the invocation:

```text
Prompt host: codex|claude|portable
Prompt mode: goal|batch|direct
Preferred route: default|<model-or-class>/<effort>
Route requirement: advisory
```

Codex goal prompts put `/goal` before the header and use `$pr-batch` after it.
Codex direct prompts omit `/goal` and use `$pr-batch`. Claude prompts omit
`/goal` and use `/pr-batch`. Portable prompts use neutral prose such as
`Use the pr-batch skill ...`; every embedded `pr-batch` and `pr-walkthrough`
mechanic remains unsigiled. A target renderer applies the host's sigil to every
supported mechanic, including the Base verification, Resolve, and walkthrough
lines; portable output stays neutral. Portable prompts resolve through this
contract at runtime.
The `Preferred route` value is metadata only. It cannot create a hard route,
weaken a gate, or turn unavailable model/effort data into a blocker.

Before worker launch, repository mutation, or a GitHub write, classify the
complete prompt against an explicitly known active host. Resolve
`PR_BATCH_SKILL_DIR` in the normal installed-skill order: explicit environment
variable, loaded skill base, repo-local `.agents/skills/pr-batch`, then stop if
none is available. Invoke the resolved installed or pinned helper:

```bash
"${PR_BATCH_SKILL_DIR}/bin/prompt-host-adapter" --active-host codex < prompt.txt
"${PR_BATCH_SKILL_DIR}/bin/prompt-host-adapter" --active-host claude < prompt.txt
```

The helper reads prompt text only from standard input and emits a structured
JSON result. It does not launch a worker, execute the prompt, mutate a
repository, or write to GitHub. Callers must honor these classifications:

| Classification | Meaning | Allowed next action |
| --- | --- | --- |
| `compatible` | Complete matching host headers and mechanics, or an unmistakable matching legacy wrapper | Execute only under the ordinary workflow gates; preserve the prompt byte-for-byte. |
| `portable` | Complete portable headers plus this installed contract | Resolve host mechanics through this contract, then execute only under the ordinary workflow gates; preserve the portable prompt byte-for-byte. |
| `conversion-required` | Complete known opposite-host prompt, or unmistakable opposite-host legacy wrapper | Do not execute. Return the converted text as inert relaunch input. Re-run planning when the result reports `replanning_required`, then classify the relaunched prompt again. |
| `ambiguous` | Unknown active host, invalid encoding, partial/duplicate/malformed/contradictory headers, non-advisory routing, unsupported syntax, or semantic-preservation failure | Do not rewrite or execute. Report the stable `reason_code` and stop for user or coordinator resolution. |

An ambiguous result never includes raw prompt text. Its stable `reason_code`
identifies the fail-closed category, such as `invalid-encoding`,
`partial-headers`, `duplicate-headers`, `non-advisory-route`,
`invalid-preferred-route`, `invalid-host-mode-wrapper`,
`contradictory-host-mechanic`, `contradictory-source-mechanic`,
`unsupported-host-mechanic`, or
`unrecognized-prompt`.

Mechanic detection is token-based rather than verb-based: a bare lowercase
`$name` or `/name` token counts as a host mechanic even after words such as
"execute", "trigger", "launch", or "apply", or in a bare list item. URL and
path continuations are not command tokens. The leading Codex `/goal` wrapper
is structural. A whole line of the exact form
`Document $name and /name as literal names only.` is explicitly literal; adding
an invocation or contradictory phrase to that line removes the exemption.
Portable prompts cannot contain any detected host mechanic. Codex and Claude
prompts, including conversion sources, cannot contain a mechanic for the other
host.

Legacy detection is deliberately narrow: only a leading Codex `/goal` wrapper
or a leading Claude `/pr-batch` invocation is unmistakable. Incidental host or
skill names in prose do not qualify. Generic pause/resume-only text is outside
this adapter contract unless it is itself a complete pr-batch prompt.

Conversion translates mechanics only: the header host/mode, `/goal` wrapper,
pr-batch invocation, target-specific batch-size field, exact Base verification
and Resolve mechanics, and exact pr-walkthrough authority invocation.
Objectives, targets, scope, dependencies,
permissions, safety, QA, review, merge authority, advisory route preference,
and all ordinary workflow gates must remain semantically identical. The helper
normalizes those approved mechanical differences and compares the remaining
payload; any difference or untranslated host mechanic fails closed as
`ambiguous`. Conversion never splits or repacks lanes. A converted batch-size
prompt reports `replanning_required` because the target host's capacity may
differ.

The helper reads stdin as deterministic UTF-8 independent of locale. Valid
non-ASCII semantic text is preserved through classification and conversion;
invalid byte sequences return `ambiguous` with `reason_code: invalid-encoding`
instead of raising or echoing input.

This runtime adapter adds no signing keys, trust anchors, launch receipts,
waivers, or new authority. It cannot bypass security preflight, coordination,
stage dependencies, QA, current-head review, merge assurance, or issue #299's
human-approval boundary. A conversion result is always inert; a caller must
relaunch and reclassify it before ordinary execution can begin.

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

The portable completion contract may request one deduplicated, inspectable,
updatable, stoppable 15-minute **current-thread** monitor for a blocker that
can clear without user input. This is not a request for a durable job that
starts a new conversation. A wake is supported only when it returns to the
same task/thread; otherwise preserve the exact manual-resume instruction.

| Portable lifecycle | Codex Desktop | Claude Code (CLI and Desktop) |
| --- | --- | --- |
| Current-thread blocked-goal monitor | Use the current thread's supported recurring wake mechanism only when it can re-enter that same goal/thread. Keep one monitor, refresh evidence at each wake, and stop it when unblocked or complete. | In the current Claude Code session, use `/loop <interval> <prompt>` or the Cron scheduling tools. These tasks are session-scoped: they run only while Claude Code is running and idle, and a new conversation clears them. A resumed CLI session restores only unexpired tasks (`claude --resume` or `claude --continue`); recurring tasks expire after seven days. [Scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks) |
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
