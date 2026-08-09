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
3. **What is next** - List the remaining steps to reach done, refresh their live dependencies, then
   pick the next coherent objective. Treat a saved next-step ordering as a stale hypothesis, not an
   instruction to block on its first item.
4. **Definition of done** - Restate the overall success criteria in one line, plus the command or
   test that will verify it. If there is no runnable check, state how completion will be confirmed.
5. Continue working on **that one next coherent objective only**. The objective may include other
   independent in-scope steps while an external command, check, review, or agent is pending. Stop
   after completing the objective.

For a resumed PR-batch lane, complete bounded ownership recovery before any
write. If a new actor takes over abandoned ownership, emit private-backend
`human_intervention` with `kind: takeover`; if a fenced replacement supersedes
the prior actor, use `kind: supersede`. A routine same-thread resume with the
same verified holder is neither a takeover nor a supersede and emits no event.
Backend `n/a` skips silently. Typed-event transport is optional: when an active
private backend does not advertise it or reports it
unsupported, record `typed event transport: unavailable`, skip the emission,
and continue without marking the event emission `UNKNOWN`. Only after the
transport is advertised does an attempted write that fails, degrades, or is
rejected become `UNKNOWN` handoff evidence. Every attempted advertised
typed-event write must resolve the backend-advertised event executable and
ordered opaque argv; a missing, malformed, or unsafe advertisement is an
attempted-write failure. Run that exact executable and separate argv without
shell evaluation, with a finite deadline in its own process group, preserving
each opaque argument; on expiry terminate the whole group with `TERM`, then
`KILL` after a finite grace period. A deadline expiry, forced termination, or
any other advertised-support write failure records best-effort `UNKNOWN` event
evidence; the primary operation continues immediately without waiting further
on the event.

If the user supplied focus text or arguments, treat it as additional direction or a narrowed scope
for what to continue.

- Do not re-do completed work, and do not ask the user to repeat context you can reconstruct from
  the conversation, open files, or git state.
- Before another bounded poll or sleep, finish every runnable in-scope closeout task; wait only when no such work remains.
- When continuation is driven by a Goal monitor, require a material state-change
  delta or a typed terminal action with `wake_parent: true` before rebuilding
  task context. An unchanged deterministic probe is a persisted heartbeat, not
  a reason to continue. On a changed fingerprint or typed terminal action,
  accept only the compact decision, refresh live dependencies, and rerun the
  task's security, origin, coordination, overlap, review, readiness, and
  exact-head gates before acting. A stale or duplicate probe remains suppressed;
  a terminal, non-resumable, user-input, or budget outcome stays stopped or
  paused with its restart-safe handoff.
- Honor `AGENTS.md` boundaries and safety rules while resuming; never push or take irreversible
  actions unless the task already authorized them.
- End with a `$status` report when that companion skill is installed; otherwise use the same four
  sections directly: Done, In progress, Blocked / needs input, and Next. Treat this closing summary
  as a report of the resumed work, not as a separate trigger to start additional work beyond step 5.
