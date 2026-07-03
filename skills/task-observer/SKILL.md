---
name: task-observer
description: Optional meta-maintenance skill for recording sanitized observations that may improve shared skills or durable workflow lessons. Use only when the user explicitly asks for task observation, skill improvement capture, or observation review; do not activate it as a required gate for ordinary workflows.
argument-hint: '[observe this session, append observation, review observations]'
---

# Task Observer

Capture sanitized, reviewable observations from real work so shared skills and
portable workflow lessons can improve without turning every task into a
mandatory observation run.

This skill is inspired by Eoghan Henn / rebelytics.com's
`one-skill-to-rule-them-all` task-observer methodology and the Codex-native
adaptation by AllstarGER. The upstream project is licensed under Creative
Commons Attribution 4.0 International (CC BY 4.0). Preserve attribution when
copying or adapting this skill:

- Original methodology: https://github.com/rebelytics/one-skill-to-rule-them-all
- Codex adaptation evidence: https://github.com/AllstarGER/one-skill-to-rule-them-all

## Activation

Use `$task-observer` only when the user requests observation, asks whether a
session produced reusable workflow lessons, or asks to review/apply open
observations.

Do not:

- inject this skill into every workflow or batch-worker prompt by default;
- treat this skill as a prerequisite for `$pr-batch`, `$verify`, `$autoreview`,
  or any other shared workflow;
- rely on this skill to load or trigger other skills; or
- continue observing after the user asks to stop.

Host-sensitive behavior must be availability-checked. Prefer the helper in this
skill when it exists. If a host cannot write files or expose a persistent memory
path, produce a short handoff summary instead of inventing a platform-specific
storage location.

## What To Capture

Capture only compact, sanitized observations that point to reusable process
improvement:

- user corrections that reveal missing or unclear skill rules;
- repeated manual steps that could become a portable helper or checklist;
- workflow gaps where `UNKNOWN`, degraded coordination, validation, or review
  state needed clearer handling;
- simplification opportunities where a skill can remove ceremony or reduce
  false positives;
- self-improvement notes about this observer skill's own activation, privacy, or
  staging behavior; and
- cross-cutting principles that belong in shared pack guidance.

Prefer the smallest observation that can drive later review. Do not copy raw
files, private issue text, customer examples, logs, stack traces, or proprietary
content into observation memory.

## Privacy Rules

Never store:

- secrets, tokens, passwords, private keys, session cookies, or credentials;
- customer, patient, payment, cardholder, health, diagnosis, prescription, or
  other regulated data;
- private URLs that include sensitive query parameters;
- proprietary file contents, private prompt text, or non-public source snippets;
- full GitHub issue, PR, review, or comment bodies; or
- anything the user marked confidential or temporary.

When a useful signal is mixed with sensitive material, discard the sensitive
material and write only a generic pattern, such as "review helper should treat
missing private coordination status as UNKNOWN."

## Memory Helper

The optional helper writes under a safe observation path, defaulting to:

```bash
${CODEX_HOME:-$HOME/.codex}/memories/task-observer
```

Use it for local runs:

```bash
TASK_OBSERVER_SKILL_DIR="${TASK_OBSERVER_SKILL_DIR:-.agents/skills/task-observer}"
if [ ! -x "$TASK_OBSERVER_SKILL_DIR/bin/task-observer" ]; then
  TASK_OBSERVER_SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/task-observer"
fi

"$TASK_OBSERVER_SKILL_DIR/bin/task-observer" init
"$TASK_OBSERVER_SKILL_DIR/bin/task-observer" status --json
"$TASK_OBSERVER_SKILL_DIR/bin/task-observer" append \
  --kind skill-improvement \
  --skill pr-batch \
  --summary "Worker handoffs should preserve degraded private state as UNKNOWN." \
  --source "session-note"
"$TASK_OBSERVER_SKILL_DIR/bin/task-observer" list
```

The helper appends observation stubs only. It does not edit live skills,
workflows, documentation, or memory registries outside its own observation
directory.

## Staged Update Behavior

Observations are recommendations, not applied changes. When reviewing open
observations:

1. Re-read the target skill, workflow, helper, or docs page from the current
   checkout before proposing edits.
2. Group observations by target and discard stale, duplicate, repo-specific, or
   low-value notes.
3. Convert durable, portable workflow lessons into `docs/solutions/` entries
   only when they satisfy that library's criteria.
4. Stage any skill or workflow edits as normal repo changes and wait for the
   user's explicit request before overwriting live installed skills or personal
   memory.
5. Run the relevant helper tests and `bin/validate` before publishing changes.

Never overwrite installed skills, user-global skills, or live personal memory
as a side effect of observation review. A direct user request is required before
applying staged recommendations outside the current repo worktree.

## Relationship To `docs/solutions/`

Task-observer memory is short-lived working evidence. `docs/solutions/` is the
durable shared lessons library. Promote an observation into `docs/solutions/`
only when the lesson is portable across consumer repositories, supported by
repeatable evidence, and stable enough to outlive a single session.

Repo-specific command choices, release tracker state, customer context, and
one-off memory notes stay out of `docs/solutions/`.

## Closeout Checklist

- Observation memory contains only sanitized summaries.
- Any proposed edits remain staged in the current worktree until explicitly
  approved.
- Host-sensitive paths, metadata, and helper availability are reported as
  `UNKNOWN` when not verified.
- Validation evidence names the exact helper tests and repo gate that ran.
