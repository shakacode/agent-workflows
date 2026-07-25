---
name: run-ci
description: Analyze current branch changes with the repo CI detector and run user-selected local CI jobs. Use when the user asks to run, reproduce, or choose local CI checks.
argument-hint: ''
---

# Run CI Command

Analyze the current branch changes and run appropriate CI checks locally.

## Bound Provider Operation

The persisted install metadata field `provider_profile` controls resolution. A
missing legacy field is `pinned`. For `managed`, create a current operation with
the absolute resolver below. For `pinned`, never fetch or claim current-provider
mutation availability; use only the declared installed snapshot when the workflow
supports it, otherwise stop. Any unknown profile is invalid and requires a stop.

Use the active host home’s absolute `bin/agent-workflows-resolve begin` path for
managed operations. Never bootstrap through `PATH`; retain only the current invocation's result and reject any inherited operation. Re-read this skill through `assets.skills.run_ci`, use
`assets.workflow` for PR processing and `assets.root` for shared assets, while
Consumer `AGENTS.md`, `.agents/agent-workflow.yml`, and `.agents/bin/*` remain
the local seams; stop when a required asset is unavailable.

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
