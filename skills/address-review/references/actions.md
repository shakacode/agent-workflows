# Address-Review Action Procedures

Read this reference after choosing an action in `SKILL.md` Step 8. Follow only
the selected action path, plus `### General rules for all actions`.
Keep this file host-neutral: host-adapter marker blocks and available-tool
syntax stay in `SKILL.md` or `workflows/address-review.md`, which are covered by
`bin/validate-host-adapter-syntax`.

<!-- Keep this action-routing section in sync with .agents/workflows/address-review.md Step 8. -->

### Action `a` — Apply, stage, and recommend

Fix all `MUST-FIX` and `OPTIONAL` items inline after the user selects `a`, or automatically when `autopilot` was requested at initiation. Run relevant checks and the self-review gate. Stage only the intended changed files with explicit `git add` paths instead of committing them. Do **not** commit, push, post GitHub replies, resolve review threads, create follow-up issues, or post the PR summary checkpoint. Return a local summary with: fixed `MUST-FIX` items, fixed `OPTIONAL` items, staged files, validation commands/results, unresolved/skipped items, and detailed `DISCUSS` recommendations. Each `DISCUSS` recommendation must include the reviewer/comment link, recommended decision (`fix now`, `defer`, `decline`, or `ask user`), rationale/evidence, risk/tradeoff, and concrete next step. If validation fails after reasonable local repair, still report the staged-file state clearly and mark the PR as not ready for commit/push.

### Action `f` — Fix and merge-ready

The first items below are the **pre-reply subflow**, ending at the
commit/push-before-reply gate. The later items are the post-push
reply/resolve steps.

1. Address all `MUST-FIX` items (make code changes, run checks). If there are no `MUST-FIX` items, continue to autonomous optional handling.
2. Autonomously handle `OPTIONAL` nits that are behavior-preserving, low-risk,
   in scope, and before the final-candidate debounce point. Apply them inline
   when the fix is straightforward; otherwise record them as deferred or
   declined with rationale. Do not ask the user to approve those nits. This
   replaces the old explicit opt-in gate for low-risk optionals; broader
   optional work still requires `a`, `f+o`, `f+i`, `m`, explicit `o <nums>` /
   `all optional`, or direct selection of those optional items. For
   behavior-preserving optional nits found at or after the final-candidate
   debounce point, do not fix them in `f`; record the deferred/declined
   rationale and carry that recorded outcome to the reply/resolve step before
   merge-ready.
3. If an optional item needs judgment, changes behavior, or expands scope,
   promote it to `DISCUSS` instead of prompting separately as an optional item.
   If a behavior-preserving optional nit is only deferred because fixing it would
   restart an expensive review cycle, record the deferred/declined rationale
   instead of promoting it to `DISCUSS`. Route substantive deferred handling
   through the later `DISCUSS` decision path, such as `f+i`, rather than
   inventing a deferred bundle inside plain `f`.
4. If any autonomous nit fix failed local validation or self-review and the
   repair is not mechanical and in scope, drop or revert that nit and record the
   failure rationale before proceeding to commit. Promote the underlying concern
   to `DISCUSS` only when it is a correctness issue, regression risk, or
   explicit reviewer request.
5. **Commit/push-before-reply gate**: if local changes exist, commit after
   validation/self-review, then push the normal PR branch update without a
   separate prompt so CI and online reviews can run on the next head. Ask before
   pushing only under the Git push confirmation rule below. If there are no
   local changes, skip commit/push and continue decision flow.
6. Reply to each addressed `MUST-FIX` or `OPTIONAL` comment explaining the fix or
   recorded outcome. For autonomously deferred/declined optional nits, include
   `[auto-deferred]` on its own line plus a one-line rationale; see the
   thread-resolution rules below.
7. Resolve the corresponding review threads when the issue is handled or explicitly declined.
8. If `SKIPPED` items exist, ask for explicit confirmation before posting rationale replies and resolving those threads (for example: "Reply/resolve 3 skipped items? y/n"). When trusted parent state `COORDINATED_AUTOFIX=1` is set, do not prompt for locally verified duplicate or factually incorrect review threads: post a concise rationale and resolve them. For a skipped review-summary body that contains a reviewer claim, post the concise rationale as a general PR comment because review summaries have no reply endpoint. For pure status posts, acknowledgments, boilerplate summaries, and other non-actionable items without a thread, record a short rationale and explicit no-action outcome in the cutoff-safe summary; that recorded outcome satisfies the cutoff guard without manufacturing a direct reply. Re-present every remaining `SKIPPED` item for explicit confirmation, and do not signal merge-ready or advance the cutoff until each has an explicit outcome.
9. Do **not** auto-resolve `DISCUSS` items in `f`; after must-fix work, re-present discuss items and prompt the user to choose `d` (discuss), `f+i` (prepare a deferred-work bundle), or `r all discuss + resolve`.
10. Tell the user the PR is merge-ready only after `DISCUSS` items are resolved or explicitly deferred.
11. If any `DISCUSS` items remain, explicitly prompt with the next action (for example: "DISCUSS items remain - use `d` to review, `f+i` to prepare a deferred-work bundle, or `r all discuss + resolve` to decline and close.").

### Action `f+i` — Fix, deferred-work bundle, and merge-ready

1. Apply only `f`'s pre-reply subflow, through the named
   commit/push-before-reply gate, for `MUST-FIX`, autonomous optional handling,
   and optional promotion/failure handling. Do not inherit later `f`
   reply/resolve, skipped, or discuss prompts; `f+i` restates those below. If
   there are no
   `MUST-FIX` items, still handle low-risk behavior-preserving optional nits
   before continuing with deferred-item handling. If that phase produces local
   changes, commit and push under the Git push confirmation rule before building
   the deferred bundle, replying, resolving, or signaling readiness. Record each
   autonomous optional outcome before building the deferred bundle: fixed inline,
   declined, failed validation and dropped/reverted, or promoted to `DISCUSS`.
2. Reply to each `MUST-FIX` or autonomous optional thread fixed or recorded
   during the initial `f` gate, citing the pushed commit or recorded outcome,
   and resolve threads when the concern is handled or explicitly
   deferred/declined under the attention contract.
3. Prepare one deferred-work bundle, in distinct sections, for all `DISCUSS`
   items, remaining `OPTIONAL` items worth tracking, and non-trivial `SKIPPED`
   items. Exclude weak "could consider" optional suggestions, trivial duplicates,
   factually incorrect suggestions, status noise, and already handled autonomous
   optional nits. For remaining optional items that were not already replied
   to/resolved during the initial `f` gate and are excluded from the bundle as
   not worth tracking, including weak "could consider" suggestions, record the
   deferred/declined rationale for later reply or summary use, but do not reply
   or resolve until the tracking/drop outcome is chosen. Do not create a GitHub
   issue yet.
4. Present the bundle and ask whether to link an existing issue, create one bundled follow-up issue, post a PR summary comment only, or drop the bundle as not worth tracking. Do not post replies or resolve bundled items until that tracking/drop outcome is chosen. If the bundle is dropped, explicitly confirm that each bundled `DISCUSS` item is declined or not tracked before resolving it or signaling merge-ready; otherwise leave those threads open and report that the PR is not merge-ready.
5. For each deferred item and each remaining excluded optional item that
   was not already handled during the initial `f` gate, post a reply in the
   original location referencing the chosen tracking/drop outcome or recorded
   rationale (use review-comment replies for inline comments and issue comments
   for review summaries/general comments), and resolve the thread when one
   exists and the conversation is complete. For general PR
   comments and review summary bodies (which have no thread), the reply alone is
   sufficient.
6. For trivial `SKIPPED` items that are not included in the bundle (duplicates, factually incorrect suggestions, status noise), still post rationale replies and resolve those threads only when the user confirms.
7. If the bundle is non-empty and any low-risk optional nits were excluded as
   not worth tracking, record the inline/deferred/declined rationale before
   signaling merge-ready.
8. If there are zero deferred items, tell the user if any optional items were
   excluded from the bundle as not worth tracking, and continue with whichever of
   `f`'s remaining prompts still have actionable items. Do not re-prompt for
   low-risk optional nits; apply, defer, or decline them under the attention
   contract. Continue with skipped rationale confirmation (if any `SKIPPED`
   items exist), then discuss decisions (if any `DISCUSS` items remain).
9. After the initial `f` commit/push gate is complete, no additional commit is required unless later steps introduce local changes; if they do, commit and push under the Git push confirmation rule.
10. Tell the user the PR is merge-ready only after the deferred bundle has an explicit tracking/drop decision, any dropped `DISCUSS` items are explicitly declined/resolved, and any optional items excluded from the bundle are handled inline, deferred with rationale/tracking outcome, or declined/resolved; if there were zero deferred items, use the `f` merge-ready rule after `f`'s remaining prompts are complete.

### Action `f+o` — Fix must-fix and optional items inline

Use only `f`'s `MUST-FIX` subflow and commit/push-before-reply ordering; do not
apply `f`'s autonomous optional defer/decline sweep. Before the
commit/push-before-reply gate, handle every current `OPTIONAL` item inline in
the same local change phase as the must-fix work: fix it in the same PR, or stop
and promote it to `DISCUSS` if it turns out to need judgment, change behavior,
or expand scope. If optional fixes require a separate commit to keep the
must-fix commit atomic, commit them separately and push under the Git push
confirmation rule. Then handle `DISCUSS` and `SKIPPED` items using `f`'s prompts
for those tiers. If there are zero `OPTIONAL` items, behave like `f` and note
that `f+o` had nothing additional to do.

### Action `d` — Discuss items

Present the requested items with full context and ask the user for a decision on each. If the user enters bare `d` with no item numbers, present all `DISCUSS` items. After the user decides, treat approved items as `MUST-FIX` (fix, reply, resolve) and declined items as `SKIPPED` (optionally reply with rationale if the user asks). For approved items that produce local changes, use the same commit/push-before-reply ordering as action `f`. After handling requested `d` items, re-offer the quick-action menu for remaining unaddressed items.

`d` only accepts `DISCUSS` item numbers. If any selected number refers to an `OPTIONAL`, `MUST-FIX`, or `SKIPPED` item, do not proceed. Respond with "Item N is {tier} - use `{o|f|r}` instead" for each mismatched number and ask for a corrected selection.

### Action `o` — Optional items

Present the requested items with full context. If the user enters bare `o`, present all `OPTIONAL` items for selection. For each selected optional item, treat it the same as a must-fix: make the code change, run relevant checks, reply, and resolve the thread. Use action `f`'s commit/push-before-reply ordering only; do not run `f`'s autonomous optional sweep or handle unselected optional items. For optional items the user declines, offer a rationale reply via `r <nums>`.

Use `o` only when the user explicitly wants to inspect or select optional items.
Bare `o` presents items only; do not edit files until the user chooses specific
optional items or `all optional`. After an inspect-only bare `o`, stop before
GitHub replies, thread resolutions, or the summary checkpoint.
The default `f` path should not ask for permission to handle low-risk optional
nits.

`o` only accepts `OPTIONAL` item numbers. If any selected number refers to a `DISCUSS`, `MUST-FIX`, or `SKIPPED` item, do not proceed. Respond with "Item N is {tier} - use `{d|f|r}` instead" for each mismatched number and ask for a corrected selection.

### Action `r` — Reply with rationale

Post rationale replies to the specified items explaining why they are being deferred or skipped. By default, do not resolve threads in `r` unless the user explicitly asks to resolve them (for example, `r3,5 + resolve`). Accept only `SKIPPED`/`OPTIONAL`/`DISCUSS` item numbers, ranges, `r all skipped`, `r all optional`, or `r all discuss`. If the selection includes any `MUST-FIX` item (including `r all must-fix`), do not post replies; direct the user to `f` or explicit deferral (`f+i` / `m`).

- Bare `r` (with no items and no `all` qualifier) is ambiguous. Do not reply to anything. Prompt the user to specify item numbers or ranges, or one of `r all skipped` / `r all optional` / `r all discuss`.
- Bare `r all` (without `skipped`, `optional`, or `discuss`) is also ambiguous. Do not reply to anything. Respond with: `"r all" is ambiguous — use "r all skipped", "r all optional", "r all discuss", or run them one at a time.`

### Action `m` — Merge as-is

1. Prepare one deferred-work bundle for `MUST-FIX`, `DISCUSS`, `OPTIONAL` items worth tracking, and non-trivial `SKIPPED` items. Do not create a GitHub issue yet.
2. Ask whether to link an existing issue, create one bundled follow-up issue, post a PR summary comment only, or drop the bundle.
3. If the bundle is dropped, explicitly confirm that each bundled `DISCUSS` item is declined or not tracked before resolving it or signaling merge-ready; otherwise leave those threads open and report that the PR is not merge-ready.
4. Post replies in the original location for each deferred item only after the user chooses the tracking outcome: use review-comment replies for inline comments and issue comments for review summaries/general comments.
5. Resolve `DISCUSS`, `OPTIONAL`, and `SKIPPED` review threads after replying (resolve only when a thread exists and the conversation is complete).
6. If any `MUST-FIX` items were deferred, keep those review threads open by default unless the user explicitly asks to close them.
7. If any `MUST-FIX` items were deferred, explicitly tell the user the PR is **not merge-ready** without an override decision.
8. Only signal merge-ready with no code changes when there are zero deferred `MUST-FIX` items, the deferred bundle has an explicit tracking/drop decision, and any dropped `DISCUSS` items are explicitly declined/resolved. If there are zero deferred items, skip tracking and use the no-must-fix merge-ready rule.

### Direct item selection (e.g., "1,2", "all must-fix", "all optional", "1,3-5")

Address only the selected items. Direct selections do not trigger autonomous
handling for unselected optional nits. After completing them:

1. If selected items produced local changes, commit and push under the Git push confirmation rule (skip this step when there are no local changes).
2. Reply and resolve threads for addressed items.
3. Ask whether remaining items should receive rationale replies, one deferred-work bundle, or be left as-is.

### Combination actions

Users can chain actions: e.g., `f+i` then `r7-9`. After the first action completes, check if there are remaining un-replied items and offer the next logical action.

### General rules for all actions

Except for action `a`, when addressing items, after completing each selected item (whether `MUST-FIX`, `DISCUSS`, or `OPTIONAL`), reply to the original review comment explaining how it was addressed.
For actions other than `a`, if the user selects `DISCUSS` or `OPTIONAL` items to address, treat them the same as `MUST-FIX`: make the code change, reply, and resolve the thread.
If the user selects skipped/declined items for rationale replies, post those replies too.

Before committing or making a push-confirmation decision, run the self-review gate: review the combined fix diff for correctness bugs, style violations, and inconsistencies introduced by the fixes themselves. Fix critical issues immediately.

**Git push confirmation**: For ordinary PR/review iteration, push a validated
commit without a separate prompt so CI and online reviews can run on the next
head. Ask before running `git push` only when the user requested local-only or
inspect-before-push work, branch or remote ownership is unclear, the push is
destructive or risky under `AGENTS.md` git safety boundaries, hosted-CI/review
churn policy requires a maintainer decision, or the next push would be
optional/nit-only after the final-candidate gate. Action `a` must not push; it
stops after staging files and returning the local summary. A rejected
non-fast-forward push is a hard stop: fetch the remote branch, report the local
and remote heads plus likely concurrent ownership conflict, and do not
force-push, rebase-and-push over, or otherwise replace another agent's commits
without explicit maintainer or coordinator direction. If a maintainer or
coordinator directs the run to continue after reconciling the remote head, rerun
Step 4 review-data fetch, Step 5 filtering, and Step 6 triage from that new head
before any further push, reply, thread resolution, or summary checkpoint.

Converge the review loop, don't chase it: every push re-triggers the configured review bots on the new head and produces a fresh batch of comments. Batch all code fixes into a single push; resolve purely advisory threads (style, dead-code, "consider…", informational, positive) in-thread with a reply — **without a new commit**, since resolving a thread does not re-trigger reviews while a push does. Never resolve a confirmed blocker by reply alone. See [Review-Loop Convergence](../../../workflows/pr-processing.md#review-loop-convergence-push-amplification).

When 2+ selected fixes touch different files with no logical dependency, process them in parallel if the environment supports it. Instruct parallel helpers not to commit; keep all changes unstaged until the combined diff passes the self-review gate.
After parallel fixes complete, verify no conflicts exist between the changes by checking whether any helpers touched the same files (`git diff --name-only`).

**For issue comments (general PR comments):**

```bash
gh api repos/${REPO}/issues/${PR_NUMBER}/comments -X POST -f body="<response>"
```

**For PR review comments (file-specific, replying to a thread):**

```bash
gh api repos/${REPO}/pulls/${PR_NUMBER}/comments/${REVIEW_COMMENT_ID}/replies -X POST -f body="<response>"
```

Use the selected item's review comment `id` as `REVIEW_COMMENT_ID`; do not use the parsed input `COMMENT_ID` except for the specific-comment fetch path. Use the `/replies` endpoint for all existing review comments, including standalone top-level comments.

**For review summary bodies (from `/pulls/{PR_NUMBER}/reviews/{REVIEW_ID}`):**

Review summary bodies do not have a `comment_id` and cannot be replied to via the `/replies` endpoint. Instead, post a general PR comment referencing the review:

```bash
gh api repos/${REPO}/issues/${PR_NUMBER}/comments -X POST -f body="<response>"
```

The response should briefly explain:

- What was changed
- Which commit(s) contain the fix
- Any relevant details or decisions made

After posting the reply, resolve the review thread when all of the following are true:

- The comment belongs to a review thread and you have the thread ID
- The concern was actually addressed in code, tests, or documentation; explicitly
  declined with a clear explanation approved by the user; or autonomously
  deferred/declined as a low-risk behavior-preserving `OPTIONAL` item under the
  Maintainer Attention Contract with the rationale recorded in the reply or
  summary. Autonomous deferred/declined optional replies must use the
  `AGENTS.md` tag format: include
  `[auto-deferred]` on its own line plus a one-line rationale before the thread
  is resolved. An auto-resolved optional thread that lacks that tag is a spec
  violation; do not resolve the thread if you cannot post the tag and rationale
  first.
- The thread is not already resolved

Use GitHub GraphQL to resolve the thread:

```bash
gh api graphql -f query='mutation($threadId:ID!) { resolveReviewThread(input:{threadId:$threadId}) { thread { id isResolved } } }' -f threadId="<THREAD_ID>"
```

Do not resolve a thread if the fix is still pending, if you are unsure whether the reviewer concern is satisfied, or if the user asked to leave the thread open.

If the user explicitly asks to close out a `DISCUSS`, `OPTIONAL`, or `SKIPPED` item, reply with the rationale and resolve the thread only when the conversation is actually complete.
