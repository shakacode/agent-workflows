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

A managed/connected rolling provider binds each operation to one verified
snapshot and fails closed when that binding is unavailable. An explicit pinned
or offline snapshot retains its declared provider contract; it does not
silently enter rolling resolution or mix assets with a rolling operation.

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

For Claude Code Desktop, configure permissions before launching subagents.
Replace the absolute-path placeholders below with the active host home and
returned `assets.root` before using this starter allowlist:

```json
{
  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(gh *)",
      "Bash(.agents/bin/*)",
      "Bash(<absolute-provider-root>/skills/*/bin/*)",
      "Bash(<absolute-claude-home>/bin/agent-workflows-resolve *)",
      "Bash(<absolute-claude-home>/bin/agent-workflows-run *)",
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

## Provider-Bound Rolling Operations

A managed/connected rolling provider binds one consequential operation to one
exact canonical commit. Each operation-bound entry skill uses only an operation
that the current invocation created locally and whose exact begin result it
retained. Otherwise it runs the active host home's absolute
`bin/agent-workflows-resolve begin` path before reading deeper shared
instructions or invoking a helper. It never bootstraps through `PATH` or
inherited operation state. The resolver:

1. fetches `refs/heads/main` from the literal
   `https://github.com/shakacode/agent-workflows.git` into a fresh private
   quarantine and explicit private ref;
2. runs Git with system/global configuration, URL rewrites, inherited
   refspecs, hooks, object alternates, replacement objects, and inherited Git
   environment disabled;
3. resolves the fetched ref to one full commit SHA and verifies the extracted
   tree against that exact Git object before atomic publication into a private
   per-SHA store;
4. requires one active native root and one copied plugin-companion install at
   that SHA, including exact active-tree content;
5. additionally requires a clean matching Git HEAD for Codex, or one matching
   Claude `gitCommitSha` plus `installPath` receipt;
6. publishes an opaque operation handle only after the private launcher,
   runtime, capability copies, registry, instruction assets, and provider
   evidence all verify.

The JSON result retains the exact `revision`, operation handle, freshness,
capabilities, and runner and exposes one read binding:

- `assets.root` is the absolute canonical tree already verified for this
  operation. It is informational output, never resolver input.
- `assets.skills` maps validated snake_case names to absolute `SKILL.md` files.
- `assets.skill` and `assets.workflow` remain the primary `pr-batch` and
  PR-processing assets.
- `assets.related_workflows` and `assets.docs` expose validated named
  supporting assets.

Registry loading requires every named skill to be a regular non-symlink
instruction file at its declared location beneath the verified tree. Missing,
malformed, traversing, or symlinked entries fail before operation publication.
The resolver never accepts `assets.root` from the environment, consumer
repository, inherited state, `PATH`, a host cache, or another checkout.

The production fetch URL is not configurable. Tests use a test-defined
resolver subclass and local HTTP transport; neither the CLI nor installed
runtime exposes a remote override. The capability registry rejects absolute or
traversing paths, missing dependencies, symlinks where regular files are
required, and non-executable capability targets. The initial current-only
mutation is `pr-merge-submit`, invoked as:

```bash
"${AGENT_WORKFLOWS_RUNNER}" --operation "$AGENT_WORKFLOWS_OPERATION" pr-merge-submit -- ARGS...
```

The runner revalidates the operation against its private canonical Git store,
the active native and companion providers, and the recorded launcher/runtime/
capability device, inode, size, mode, and content immediately before execution.
It refuses provider movement after begin. `--degraded` may bind a coherent
already-stored snapshot for read-only diagnosis, but cannot authorize a
capability marked `requires_current_provider`.

State roots and operation/store directories are owned by the current uid and
private; staging cleanup proceeds only when the original device/inode/owner
identity still names the resolver-created directory. Publication is a rename
after complete staging and verification. A replaced staging path is preserved
for diagnosis rather than recursively removed.

This is a same-uid integrity boundary, not isolation from another malicious
process running as the same user. Portable Ruby cannot atomically hash and
`exec` a pathname through one immutable file descriptor on every supported
host. Private `0700` directories, non-writable operation copies, repeated
inode/hash checks immediately before `exec`, and provider revalidation narrow
the race; they do not justify a claim that a hostile same-uid process is
cryptographically excluded. Operation metadata hashes are consistency checks,
not authentication. Provenance comes from revalidation against the exact
private canonical Git object.

The machine binds assets and execution. It cannot prove that a language model
actually consumed the returned Markdown. Every operation-bound entry re-reads
its own returned `assets.skills.<name>` path, then reads PR processing through
`assets.workflow` and shared siblings through returned named assets or
`assets.root`. Reading those returned instructions is a mandatory workflow
action. A handle may be reused only inside the current invocation that created
and retained its exact begin result. A replacement invocation starts a new
operation and uses the newly returned snapshot.

## Cross-File Path Resolution

Inside a provider-bound operation, there is no path-precedence chain. Use only
the absolute skill, workflow, related-workflow, and doc paths returned by the
resolver or paths beneath returned `assets.root`. Derive helper directories
only from the applicable returned `assets.skills` entry. Bind
`AGENT_WORKFLOWS_RUNNER` only from the absolute first element of the begin
result's `runner` array. Registered semantic capabilities run only through that
runner; an unavailable registered capability is a hard stop, not permission to
execute its source helper.

Consumer `AGENTS.md`, `.agents/agent-workflow.yml`, and repo command wrappers
remain authoritative local policy. They do not replace bound shared files.

An explicit pinned or offline snapshot that does not opt into a bound rolling
operation retains its declared provider's own resolution contract. It must not
mix its assets with a managed/connected rolling provider operation.

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
