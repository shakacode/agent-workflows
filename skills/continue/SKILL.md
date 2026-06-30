---
name: continue
description: Resume an in-progress task with a structured checkpoint instead of a bare "continue", re-establishing what is done, what is next, and how done is verified. Use when resuming work after an interruption, handoff, or a vague "keep going".
---

# Continue

Resume the current task. Before doing any new work, re-establish context so work does not drift or
repeat:

1. **Where we are** - Summarize in 2-4 lines what is already done (cite files, commits, or PRs) and
   the current goal. If the goal is unclear, state your best inference and proceed; do not stop to
   ask unless you are genuinely blocked.
2. **What is next** - List the remaining steps to reach done, then pick the next concrete one.
3. **Definition of done** - Restate the overall success criteria in one line, plus the command or
   test that will verify it.
4. Continue working on the next step.

If the user supplied focus text or arguments, treat it as additional direction or a narrowed scope
for what to continue.

- Do not re-do completed work, and do not ask the user to repeat context you can reconstruct from
  the conversation, open files, or git state.
- Honor `AGENTS.md` boundaries and safety rules while resuming; never push or take irreversible
  actions unless the task already authorized them.
- End with a short status line: what changed, how it was verified, and what is left -- without
  starting new work.
