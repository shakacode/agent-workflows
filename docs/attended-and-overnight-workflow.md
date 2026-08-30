# Attended And Overnight Workflow

Use this routine to keep authorized agent work moving while spending human
attention only on decisions that need it. It coordinates existing workflow
contracts; it does not replace their safety, review, dependency, or merge
rules.

## Start The Work Window

Record two operator choices before launching or resuming work:

- **Concurrent task target:** the number of ready tasks the operator wants
  running at once. This is a target, not permission to exceed available host or
  service capacity.
- **Next availability:** the next date, time, and time zone when the operator
  expects to review the queue. Use `available now` for an attended window.

Keep both values in the coordinator's durable handoff or run record so a
restart does not erase them. The operator sets and changes them explicitly; the
coordinator does not calculate an adaptive target or silently tune a threshold.

## Operating Loop

| State | Coordinator action | Durable or live result |
| --- | --- | --- |
| Set the window | Record the concurrent task target, next availability, mode (`attended` or `overnight`), and any operator override. Refresh the authorized task list and current dependencies before launch. | One current operator card and a ready-task list. |
| Fill ready slots | Start the highest-priority authorized, dependency-ready tasks until the runnable count reaches the target. Append a compact GitHub run record for each execution; do not replace earlier run history. | Runnable work reaches the target without losing task-to-PR traceability. |
| Attend | Keep ready slots filled while maintaining a queue of meaningful decisions. Present only the next-highest-priority question; routine status, mechanical retries, and safe local choices stay out of the queue. | One exact question for the operator and a durable queue behind it. |
| Run overnight | Before the operator leaves, prefer work with deterministic done checks and no expected human decision. Record the next check or wake for each nonterminal run, and prepare every conceptual section of likely PR walkthroughs in advance. | Independent work can finish or reach an honest blocked state without waiting for routine input. |
| Wait on a dependency | Complete independent preparation, then checkpoint the task and record the exact dependency or blocker. Use one exact-time heartbeat when a safe retry time is known; otherwise use a deterministic state-change watcher or the bounded backed-off fallback. A task waiting for human input gets no monitor. If the slot can be released, fill it with the next ready task; otherwise record that it remains occupied. | Waiting is visible, dependency-aware, bounded, and does not cause noisy polling or fictitious capacity. |
| Return and review | At the availability time, refresh GitHub rather than trusting cached run records. Review current heads, checks, reviews, unresolved threads, dependencies, and merge state across the active PRs; then update each run record and select the next integration or decision. | A live PR view, an ordered decision queue, and a current integration choice. |
| Walk through or retarget | Refresh the exact diff before using the prepared walkthrough map; rebuild stale sections and present one conceptual section at a time. Discard later prepared sections if an earlier discussion sends the work back to development. Apply simple non-safety overrides at the next safe checkpoint. | The operator gets a prepared, current walkthrough or an immediately visible new target, return time, queue order, hold, or priority. |

Each compact run record links the exact prompt source and its launch-time digest,
runner, observed machine, task, branch or PR, current state, meaningful blocker,
and last material update. Put detailed provenance in the existing collapsed
agent-details surface instead of making the operator scan it during live review.

## Keep The Decision Queue Meaningful

Queue a question only when its answer changes whether or how a task may safely
continue. Each entry names the target, one exact question, why it blocks, and
what the answer will unlock. Keep product or architecture choices, missing
authority, and required human review in the queue. Continue through
non-blocking implementation choices and record those decisions in the PR's
agent details instead of interrupting the operator.

The operator owns the queue order. While the operator is available, ask the
first question, apply the answer, refresh the queue, and ask the next one.
During an overnight window, leave the queue durable and work on independent
ready tasks until the recorded availability time.

While the operator is unavailable, continue through routine choices with
reversible best judgment and queue a concise question for later. Stop a task
only when the missing answer changes the intended outcome, crosses the safety
floor, or would cause a difficult-to-reverse external action.

## Make Overrides Easy And Bounded

Plain instructions such as `set the task target to 3`, `I am back at 07:00
HST`, `hold #123`, `review #456 first`, or `continue this run with coordination
state UNKNOWN` take effect at the next safe checkpoint. Record the instruction,
its effective time, and the resulting task or queue change; no configuration
redesign is required.

These routine overrides may change capacity, timing, ordering, holds, or an
optional presentation choice. A named, visible override may also keep
reversible work moving when bookkeeping, coordination, or telemetry is
unavailable, provided the run record preserves the failure as `UNKNOWN` and no
reliable ownership evidence contradicts the run. Overrides do not bypass
repository policy, trust or security checks, dependency gates, validation,
review, merge authority, a failing correctness check, or a required human
decision.

## Use The Canonical Details

- Use [`$batch-status`](../skills/batch-status/SKILL.md) for a read-only view
  that joins run coordination with live GitHub state.
- Use the [question and decision rules](../workflows/pr-processing.md#question-and-decision-handling)
  to distinguish a blocking question from a safe local decision.
- Use the [goal-mode completion contract](../workflows/pr-processing.md#goal-mode-completion-contract)
  for exact-time heartbeats, state-change watching, bounded backoff, and stop
  conditions.
- Use [typed dependency facts](coordination-backend.md#typed-dependency-facts)
  rather than inferring readiness from a terminal task or missing blocker row.
- Use [`$pr-walkthrough`](../skills/pr-walkthrough/SKILL.md) to build the
  conceptual map, refresh its diff identity, and present one section at a time.
- Use the [Operator Handbook](operator-handbook.md) when the queue reaches a
  decision reserved for the human.

This routine does not design adaptive thresholds or require a comparison
pilot. The operator's explicit target and next availability remain the control
inputs.
