# ADR 0005: Merge Authority Lives In The Control Tower

Date: 2026-09-04
Status: accepted

Scope: where autonomous merge authority runs for repositories that use this
pack, what a CI-triggered agent may do, and what role platform rulesets play.

## Problem

On 2026-09-04 `shakacode/agent-workflows` had 82 open pull requests and
`shakacode/agent-coordination` had 26. Over the previous seven days 125 PRs
opened against 71 merged. Of the 48 ready PRs, 18 were clean with green
checks and nothing blocking, 10 were blocked only by a stale CodeRabbit
changes-requested object, and 11 conflicted with `main`. All 34 drafts were
unclaimed and under two days old.

The cause was structural, not review latency. Merge happened only inside a
lane's integration closeout, so a PR whose lane ended had no merger. The
`main` ruleset required no status checks, so GitHub enforced nothing either.

## Decision

1. The default merge authority for agent-authored PRs in the pack's own
   repositories is `auto_merge_when_gates_pass`, gated by
   [ADR 0003](0003-smarter-autonomous-merge-gates.md) and the thresholds in
   `.agents/agent-workflow.yml`.
2. The per-repository control tower is the standing merger: a persistent
   role served by one bounded task session per attention interval. A session
   publishes terminal state when its interval ends and the next session
   continues the role. A PR belongs to the tower once the lane that opened it
   ends. Each tower tick runs an integration pass over the merge backlog and
   every unclaimed draft: merge what passes the exact-head gates, remediate
   small blockers, give each unclaimed draft an R12 disposition, and label
   only what needs the human.
3. A CI-triggered agent, such as the Claude review Action, keeps
   `contents: read`. It may review, classify, apply labels, and draft the
   semantic assessment the eligibility gate consumes. It never pushes and
   never merges.
4. Platform rulesets are belt and suspenders, not the guard. Require `Lint`
   now and `Validate` once it is change-aware. GitHub Free private
   repositories have no rulesets; there the gate scripts are the only merge
   guard, and a `human-attention:merge` card must state that checks are green
   at the exact head SHA. The human answers with an exact-head approval on the
   PR and the tower submits the merge; the human never presses the merge
   button.

## Considered Options

- **A GitHub Action merges when CI passes.** Rejected. The eligibility gate
  fails closed without an agent-written semantic assessment, and merge from
  CI widens the trust posture for no gain.
- **An Actions-triggered agent may push, for example to rebase, but not
  merge.** Deferred. It needs an app token so CI re-runs after the push, and
  it changes the `contents: read` posture, so it needs its own ADR revision.
  Revisit after the first integration pass has run.
- **Keep every lane alive until its PR merges.** Rejected. One live task per
  PR, and no help for PRs already orphaned.
- **A work-in-progress cap on open PRs.** Rejected for now. Revisit if open
  PRs still exceed sixty on 2026-09-18.

## Consequences

- The tower prompt must carry the authority grant explicitly; it cannot be
  inferred from repository policy.
- `pr-merge-submit` with a fresh merge-assurance receipt stays the only merge
  path, for agent and human decisions alike. A human approval is a PR comment
  bound to the exact head, not a merge click. No GitHub auto-merge toggle and
  no merge queue is enabled.
- The human sees a `human-attention:*` label only when the gate hands a PR
  over, so the label stays rare and meaningful.
- Terms for the merge backlog, control tower, integration pass, disposition,
  labels, and comment kinds live in [CONTEXT.md](../../CONTEXT.md).
