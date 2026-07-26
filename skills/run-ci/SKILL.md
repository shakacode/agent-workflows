---
name: run-ci
description: Analyze current branch changes with the repo CI detector and run user-selected local CI jobs. Use when the user asks to run, reproduce, or choose local CI checks.
argument-hint: ''
---

# Run CI Command

Analyze the current branch changes and run appropriate CI checks locally.

## Bound Provider Operation

The persisted install metadata field `provider_profile` controls resolution. A
missing legacy field is `pinned`; any unknown profile is invalid and requires a
stop.

**Pinned profile:** never fetch or run the current-provider resolver. Do not
expect `assets.*`. Continue only from Consumer `AGENTS.md`, this already-loaded
entry, `.agents/agent-workflow.yml`, and `.agents/bin/*` policy/command seams. Do
not load a shared sibling skill, workflow, or doc, and do not run a registered
mutation. If the remaining task requires any of those shared assets,
stop with a precise pinned-provider limitation. This preserves the declared
installed snapshot without fetching or mixing another provider.

**Managed profile only:** for `managed`, use only a provider operation that the
current invocation created locally and whose exact `begin --json` result it
retained. Otherwise identify the active host and use the active host home's
absolute `bin/agent-workflows-resolve begin` path:
`${CODEX_HOME:-$HOME/.codex}/bin/agent-workflows-resolve begin --host codex
--json` or `${CLAUDE_HOME:-$HOME/.claude}/bin/agent-workflows-resolve begin
--host claude --json`. Never bootstrap through `PATH`, and never trust an
inherited operation handle, runner command, or asset variable.

Re-read this entry at returned `assets.skills.run_ci`. Read canonical PR
processing only through `assets.workflow`. Resolve shared sibling skills,
workflows, and docs through returned named assets or beneath `assets.root`; stop
if a required asset is absent. Reuse a handle only when this current invocation
created and retained that exact result. Run registered mutations only through
the complete returned `runner` command; stop if the capability is unavailable.

## Explicit Operation Closeout

Retain the complete returned `release` argv. Invoke it only after this
invocation's final shared-instruction read and final helper/capability use.
Release invalidates every returned `assets.*` path, even if files happen to
remain. A restart or follow-up must begin a new operation and release the old operation
once it is safely finished. Recover crashed or orphaned handles only
through the active host resolver's `list --json` plus a named `release`;
never TTL or PID inference.

## Base Handling

The repo's pre-push local validation command is `.agents/bin/validate`. It should
auto-detect the current PR base branch when the repo supports optimized routing.
Do not pass a base-ref argument to it unless that wrapper documents one. Use
`.agents/bin/ci-detect` only when you need to inspect the routing decision
directly and the script exists.

Before running commands, inspect:

- `.agents/bin/validate`
- `.agents/bin/ci-detect` when present
- `.agents/agent-workflow.yml` for `base_branch` and CI policy notes

## Instructions

1. First, run `.agents/bin/ci-detect` to inspect what changed when the user asks for routing details and the script exists; otherwise use `.agents/bin/validate` directly
2. Show the user what the detector recommends
3. Ask the user if they want to:
   - Run the recommended CI jobs (`.agents/bin/validate` in its default mode)
   - Run all CI jobs (`.agents/bin/validate --all` or the wrapper's documented broad mode)
   - Run a fast subset (`.agents/bin/validate --fast` or the wrapper's documented fast mode)
   - Run specific jobs manually
4. Execute the chosen option and report results
5. If any jobs fail, offer to help fix the issues

## Options

- `.agents/bin/validate` - Run local CI based on the repo wrapper contract
- `.agents/bin/validate --changed` or equivalent - Explicit optimized changed-files mode when supported
- `.agents/bin/validate --all` or equivalent - Run broad local CI where practical
- `.agents/bin/validate --fast` or equivalent - Run only fast checks when supported
