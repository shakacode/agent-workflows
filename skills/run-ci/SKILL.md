---
name: run-ci
description: Analyze current branch changes with the repo CI detector and run user-selected local CI jobs. Use when the user asks to run, reproduce, or choose local CI checks.
---

# Run CI Command

Analyze the current branch changes and run appropriate CI checks locally.

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

Apply the [delivery coverage contract](../verify/references/verification-evidence.md#delivery-coverage).
Read selection policy from the trusted base. The repository's wrappers define
integration and complete promotion invocations; omission retains existing
coverage. Missing or invalid routing evidence cannot select reduced checks.

## Instructions

1. First, run `.agents/bin/ci-detect` to inspect what changed when the user asks for routing details and the script exists; otherwise select `.agents/bin/validate` for execution in step 3
2. Preview required checks, omissions, and the selection reason only when the detector has reported them; otherwise obtain them from the wrapper during step 3. Preserve mandatory lint, review, security, and current-head CI requirements.
3. Execute the authorized repository invocation. Resolve a choice with the user only when the request and repository policy leave a material decision open. Promotion requires the documented complete suite; do not invent flags.
4. Report phase, candidate/base identity, selected or full coverage, each required result, and omissions/reason. Selected success does not prove omitted checks passed.
5. Diagnose failed jobs using `/verify`'s existing retry boundary. A stopping or review budget pauses for disposition with failures still blocking; it does not create a successful gate.

## Options

- `.agents/bin/validate` - Run local CI based on the repo wrapper contract
- Other invocations exist only when the repository's command table documents them. Run selected integration checks or complete promotion checks as that table specifies.
