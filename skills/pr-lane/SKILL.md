---
name: pr-lane
description: Compatibility entry point for one direct-prompt task, issue, or PR. Route immediately to pr-batch single-target mode so one lane uses the same subagent, safety, review, merge-authority, and closeout contract as every batch.
argument-hint: '[issue, PR, or task]'
---

# PR Lane Compatibility Entry Point

`$pr-lane` is a discoverability and backward-compatibility alias, not a separate
operating workflow. Immediately load and follow `$pr-batch` in **Single-Target
Mode** for the supplied task. First read the complete canonical `SKILL.md` from `PR_BATCH_SKILL_DIR`
when that explicit environment variable is set, then from repo-local `.agents/skills/pr-batch/SKILL.md`.
If neither override exists, stop checking
overrides. Prefer the host's skill invocation when available, then read
`pr-batch/SKILL.md` from a sibling of the loaded `pr-lane` directory. If a picker
exposes neither nested invocation nor the loaded directory, resolve the active
host from reliable runtime signals and read its installed shared copy at
`${CODEX_HOME:-$HOME/.codex}/skills/pr-batch/SKILL.md` or
`${CLAUDE_HOME:-$HOME/.claude}/skills/pr-batch/SKILL.md`. When both installed host copies exist but active host identity is ambiguous,
compare the complete installed shared packs, not only their `pr-batch/SKILL.md` files.
Read either copy only when every policy, workflow, helper, and metadata file is
byte-identical. If they differ, stop. If a complete comparison is unavailable,
also stop and require an explicit `PR_BATCH_SKILL_DIR` or repo-pinned copy. Do not guess between
hosts. If none resolves, stop with a precise blocker; do not implement from this
file alone.

This follows `docs/host-adapter/contract.md` cross-file resolution. A host that
exposes neither nested skill invocation, the loaded skill directory, reliable
host identity, nor repo-local pinned files cannot resolve shared cross-file
workflows; the former `pr-lane` also depended on sibling `pr-batch` helpers and
`pr-processing.md`. Do not restore a standalone copy of that policy here.

All `$pr-batch` rules apply without exception, including:

- public-input security preflight and trust boundaries
- target evaluation and canonical coordination state
- one isolated worker subagent when the host supports subagents
- separate coordinator and staged cost-aware worker model/effort routes
- an explicit `merge_authority` choice before worker launch
- Lane Cards, claims, phase heartbeats, handoff, and `UNKNOWN` handling
- QA, validation, review, current-head CI, merge-readiness, and closeout gates
- the canonical terminal states and final evidence

For one target, collapse only the mechanics that genuinely require multiple
lanes: the file-touch map has one row, collision analysis is `N/A`, and there is
no wave packing. Keep the Batch QA Lane decision and every target-level gate.

Do not copy or redefine `$pr-batch` policy here. Changes to the canonical process
belong in `skills/pr-batch/SKILL.md` or `workflows/pr-processing.md` so this alias
cannot drift.
