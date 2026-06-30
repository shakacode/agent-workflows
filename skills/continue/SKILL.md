---
name: continue
description: Resume an in-progress task with a structured checkpoint instead of a bare "continue", re-establishing what is done, what is next, and how done is verified. Use when resuming work after an interruption, handoff, or a vague "keep going".
argument-hint: '[focus text or scope]'
---

# Continue

Resume the current task. Before doing any new work, re-establish context so work does not drift or
repeat:

1. **Repo rules** - Read `AGENTS.md` first so repo-specific commands, formatting, boundaries, and
   safety rules are current before acting.
2. **Where we are** - Summarize in 2-4 lines what is already done (cite files, commits, PRs, issues,
   or linked planning docs) and the current goal. If there is no task currently in progress (no prior
   conversation, no staged work, no recent commits on this branch, and no open PR or issue context),
   say so and ask the user what to continue instead of inferring a goal. If the goal is unclear but
   prior work exists, state your best inference and proceed only when confidence is reasonable; for
   low-confidence inference, state the hypothesis and ask the user to confirm before acting.
3. **What is next** - List the remaining steps to reach done, then pick the next concrete one.
4. **Definition of done** - Restate the overall success criteria in one line, plus the command or
   test that will verify it. If there is no runnable check, state how completion will be confirmed.
5. Continue working on **that one next step only**. Stop after completing it.

If the user supplied focus text or arguments, treat it as additional direction or a narrowed scope
for what to continue.

- Do not re-do completed work, and do not ask the user to repeat context you can reconstruct from
  the conversation, open files, or git state.
- Honor `AGENTS.md` boundaries and safety rules while resuming; never push or take irreversible
  actions unless the task already authorized them.
- End with a `$status` report. Treat this closing summary as a report of the resumed work, not as a
  separate trigger to start additional work beyond step 5.
