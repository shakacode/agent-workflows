# Issue Evaluation Workflow

Use this workflow before fixing, batching, or assigning a GitHub issue when value is uncertain, especially when the issue was found by AI/code analysis rather than by real users.

The authoritative rubric lives in returned `assets.skills.evaluate_issue`. Read and follow that file first; this workflow exists for agents that prefer workflow-file entry points over skill invocation syntax.

## Sequence

1. Exact issues or PRs:
   - Follow returned `assets.skills.evaluate_issue` directly.
   - Report `UNKNOWN` for any fact that cannot be verified.
2. Filters, labels, milestones, pasted lists, or other unverified batch scopes:
   - Run returned `assets.skills.plan_pr_batch` first to resolve exact candidates.
   - After exact candidates are known, follow returned `assets.skills.evaluate_issue` for targets that are speculative, AI/code-analysis-only, over-scoped, or unclear in value, priority, or fix scope.
3. Batch handoff:
   - Exclude `park / P3`, `close`, and `product decision` items from implementation batches unless the batch is explicitly audit/comment-only.
   - Convert low-value assigned issues into no-PR evidence comments rather than speculative PRs.
   - For investigation or benchmark conclusions, apply the closing-evidence gate from the "Evaluate the fix plan separately" step in returned `assets.skills.evaluate_issue` before carrying a `close` or `document/work around` disposition into `$pr-batch`.
   - If the gate cannot be satisfied, record the caveat explicitly in the evidence comment. Do not carry the target as `close` or `document/work around`; use a no-PR evidence comment with a `park` disposition, or a `product decision` blocker when maintainer input is needed. Concrete corrective implementation PRs remain valid when the issue has a scoped fix independent of a settled close/workaround conclusion.
   - Carry the disposition into `$pr-batch` as the target outcome: implementation PR, no-PR evidence comment, `document/work around`, or product-decision blocker.
   - For recurring process misses, also carry the Process Gap Disposition fields from returned `assets.skills.evaluate_issue`: `Mechanism target`, `Motivating miss`, `Replay evidence or park reason`, and `Non-goal`.
