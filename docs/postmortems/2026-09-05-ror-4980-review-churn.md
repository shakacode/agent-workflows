**PR #4980: a workflow investment that failed to converge**

Investigated September 5, 2026. Scope: the development and review process for [React on Rails #4980](https://github.com/shakacode/react_on_rails/pull/4980), plus relevant Agent Workflows policy. This is a process retrospective, not a release-readiness or completed-batch certification.

The central failure was allowing a modest evidence-format compatibility problem to become an open-ended attempt to judge the truth of natural-language QA claims. Individual repairs were often valid. The workflow repeatedly optimized for another locally correct repair without reconsidering whether the whole mechanism was worth maintaining. Review delivery and formal review state added further delay.

The original issue was real. [#4939](https://github.com/shakacode/react_on_rails/issues/4939) reported that checkout-only agents emitted v1 evidence while newer auditing expected v2. It also documented a working workaround: use the installed pack's v2 schema and helper. That should have constrained the urgency and justified a much smaller compatibility solution.

| Verified observation | Result |
| --- | --- |
| PR creation → merge | September 2 04:04:01 UTC → September 5 20:48:41 UTC; 88 hours 44 minutes elapsed |
| Commits | 39, including 4 merge commits |
| Final diff | 5 files; 3,342 additions, 22 deletions |
| Main executable | 972 added lines |
| Regression test file | 2,218 added lines |
| Submitted review records | 97: 71 automated and 26 under justin808 |
| Automated reviews | Claude 41; Codex 23; CodeRabbit 6; Greptile 1 |
| Review threads / published inline comments | 92 / 118, including 26 replies |
| PR discussion comments | 87 |
| Published discussion text | 171,400 UTF-8 bytes, excluding inline reviews and the PR description |
| Six identifiable local Codex review sessions | 5,080,640 recorded total tokens |

Sources for counts: paginated GitHub PR, review-comment, review-thread and timeline APIs. Counts describe the snapshot after merge; deleted drafts are excluded. Review records are not necessarily independent full-PR reviews. Workflow run names also do not establish that their test jobs ran.

The local token count was checked against each session's final cumulative token-usage event, rather than summing cumulative snapshots. It contains 5,054,569 input tokens, of which 4,631,936 were cached, and 26,071 output tokens. Thus 422,633 input tokens were uncached. Reasoning tokens are a subset of output, not another amount to add. This is a partial local count for six review sessions in the issue4939 worktree. It excludes implementation/coordinator work, other machines and providers, hosted reviews, and this investigation. It is neither the total PR usage nor an account billing estimate. The 88-hour interval is elapsed calendar time, not active labor.

The public record shows where the loop should have changed direction:

1. On September 3 at 09:38 UTC, a [Claude review](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5523722796) framed the helper as an anti-gaming detector and recommended small regex fixes for intervening adverbs.
2. Subsequent commits added plural negations, reverse negations, contractions, hedges and clause rules. Each change generated new examples for reviewers to challenge.
3. By 11:52 UTC, a [review explicitly identified the non-converging design](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5525300522), describing the 13-commit sequence and recommending structured fields. It placed that recommendation in a possible follow-up while immediate fixes continued.
4. The [September 4 walkthrough](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5534011093) recorded 29 commits and 2,110 additions. Only then did the coordinator recommend [structured redesign or closure](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5534011867), explicitly rejecting another synonym patch.
5. Justin [approved the redesign](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5534518183). V3 replaced verdict-critical prose with typed states, but retained the accumulated historical parsers. Later repairs covered source references, pending attachments, placeholders, units and ambiguous receipt selection.
6. On September 5, [the final agent status](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5550547862) again requested permission for another bounded repair. The maintainer eventually merged.

A valid parser counterexample does not prove that implementing the parser is a good investment. Conversely, once a parser controls acceptance, a demonstrated false acceptance cannot honestly be relabeled a cosmetic nit. The economical intervention belongs at the design and continuation decision: shrink the contract, use the existing workaround, or stop the work.

Several contributing mechanisms made this worse:

- **The contract exceeded what the tool could establish.** Text and URL-shape checks cannot establish that a screenshot was inspected or that a claim is true. Strict parsing can establish format and consistency; actual verification needs observed results and reviewed artifacts.
- **File count concealed complexity.** The narrow backport avoided expanding the managed inventory from 42 to 101 paths, but five existing files still acquired a substantial local implementation. Narrow paths did not mean a small design or maintenance burden.
- **Reviews multiplied without a stopping rule.** Claude and Codex supplied 82 of the 92 root inline comments; CodeRabbit supplied nine. CodeRabbit configuration alone cannot prevent the main recurrence.
- **Repeated final candidates restarted work.** Public status comments requested final hosted validation, then another repair replaced that head. Existing batching and backpressure guidance did not stop the sequence.
- **Status text accumulated instead of stating the delta.** Several cutoff summaries grew from roughly 0.8 KB to 6.6 KB. This increased reading burden. Its exact contribution to token usage is not attributable from the available records.
- **Permission scopes became fragmented.** The record repeatedly separates repair approval, protected-file acknowledgement, review-draft deletion and merge approval. Some distinctions protect meaningful boundaries. Routine repairs within an already-authorized scope should not require repeated approval merely because the SHA changed. The public record does not establish every original task authorization, so this is a contributor to investigate, not proof that every prompt was improper.

The CodeRabbit and reply problems require different remedies.

All nine CodeRabbit inline threads were resolved in the post-merge snapshot, but none has a currently published reply. The record includes an outside-diff finding embedded in a review summary, which a thread-only scan could miss. CodeRabbit's last change request was submitted September 3 at 13:49 UTC and covered an old head. Its summary later said automatic reviews were paused.

At 20:48:10 UTC on September 5, Justin dismissed review 5102746845 with the message “skipping.” Merge followed at 20:48:41. This supports the reported formal-review blocker. It does not prove whether pause state, an outside-diff finding, a pre-merge check or another provider condition prevented CodeRabbit from updating its review.

CodeRabbit documents that its [request-changes workflow](https://docs.coderabbit.ai/reference/configuration) automatically approves when comments are resolved and pre-merge checks are clear. Disabling that behavior is a sensible reduction in formal bot gate friction; the reported global change was not independently inspected. It does not replace comment triage or retroactively prove that an old GitHub change request was cleared.

Separately, [four reply attempts failed with HTTP 422](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5537680764) because the account had pending review drafts. The [later status](https://github.com/shakacode/react_on_rails/pull/4980#issuecomment-5548828870) records two specifically authorized draft deletions after backing up 67 comments and metadata. Those 67 draft comments are not additional public review comments in the counts above. Preserve this distinction when measuring activity.

Agent Workflows already documents the REST review-comment reply endpoint and general-comment fallback for review summaries in `skills/address-review/references/actions.md`. The missing behavior is recovery and readback, not basic knowledge that replies exist. Inspection of that action reference found no pending-review/422 recovery branch.

**Recommended implementation, ordered by expected payoff**

| Change | Smallest useful mechanism | Replay that should demonstrate success | Non-goal |
| --- | --- | --- | --- |
| Stop non-converging repair loops | Enforce the existing scope-decision requirement in the review loop; pilot a two-repair-round trigger or a second finding in the same expanding grammar family. Reassess impact and design before another model review or repair round. Default to recommending the smallest workaround or parking when value is low. | Replay the first 13 commits of #4980; the next synonym repair must be replaced by a design/value decision. The rule must also work when token telemetry is absent. | No new receipt format, dashboard, or hierarchical budget prerequisite; no permission to merge known defects. |
| Recover authorized replies | Wrap the existing reply action with exact-comment readback and bounded handling of the known 422. Preserve drafts; use an available standalone browser reply when it can publish without submitting the draft. If blocked, record one linked disposition and surface the exact draft decision once. | Success, uncertain POST followed by readback, existing human draft, 422, summary-only finding, and unavailable browser. Retry must not duplicate a reply; drafts must not be submitted or deleted without authorization. | No generic GitHub transport framework and no automatic draft destruction. |
| Reconcile three review states | Report substantive finding disposition, thread resolution, and effective formal reviewer state separately. Inspect inline and review-summary findings. Once findings are settled, request one provider refresh if appropriate; report a remaining formal blocker precisely. | Old CodeRabbit change request + resolved threads + paused reviews must produce a formal-review blocker with a concrete recovery action, not “fix code.” | No silent bot-review dismissal and no treating resolved threads as approval. |
| Reduce repeated review work | Batch all available findings for one head; freeze the candidate during final review; review repair deltas while retaining the original full review context. Reopen prior findings only when changed code or new evidence invalidates their disposition. | Several reviewers report the same defect: one repair batch. A new relevant defect still reopens review. Optional polish does not restart final validation. | Do not silently weaken the repository's currently configured review coverage. |
| Make workflow work justify its cost | Reuse the existing issue-evaluation step for the smallest compatibility solution and for continuation decisions. State the affected operator, observed miss, workaround and expected benefit in a short paragraph. Validate structure; let actual evidence establish truth. | #4939's installed-helper workaround is considered before implementing an English classifier. | No general proof-of-honesty engine or new multi-version schema merely to record this lesson. |

The current source pack already requires a scope decision before adding a grammar/protocol/schema category or when a second review wave broadens the mechanism, in the Pre-Push AI Review And Simplify Gate section of `workflows/pr-batch-integration-closeout.md`. The actionable gap is proving that this decision interrupts actual continuation and reaches the consumer workflow; another prose-only rule would duplicate existing guidance. The same rule was already present in [the initial #4980 commit](https://github.com/shakacode/react_on_rails/blob/50b644b36a5cc481ebfdd048886620fbd498a19e/.agents/workflows/pr-processing.md#L1851). This corrects the initial investigation wording that suggested a stopping rule was simply absent. The rule existed in the consumer checkout; its application did not prevent the repeated repair sequence. Which instructions each worker actually loaded remains unverified.

The two-round trigger is a proposed pilot, not an empirically calibrated universal limit. Its action is to stop spending automatically and reassess; it does not waive correctness, security or required CI. A useful initial review setup for internal evidence tooling is one primary reviewer and the configured independent coverage, with additional adversarial work triggered by concrete risk rather than routine repetition. Changing the current repository coverage floor is a separate policy decision.

The existing [#392](https://github.com/shakacode/agent-workflows/issues/392) already proposes bounded repair rounds and scoped re-review. Attach this incident to that issue and deliver the smallest stopping-rule slice before expanding its review-packet machinery. There is also an open [Agent Workflows #399](https://github.com/shakacode/agent-workflows/issues/399) for descendant-inclusive token budgets. Reuse it for metering. A simple per-PR continuation brake should not depend on completing that larger design. Existing [#414](https://github.com/shakacode/agent-workflows/issues/414) covers bounded API-failure classification, but its scope is rate limits rather than the 422 draft conflict. [PR #469](https://github.com/shakacode/agent-workflows/pull/469) addresses configured review settlement; it does not by itself supply a reply-recovery operation. Check these owners before allocating overlapping work.

For durable workflow guidance, update the existing Review Churn Measurement section in `workflows/pr-batch-integration-closeout.md` and the reply operation in `skills/address-review/references/actions.md`, with replay cases beside the mechanism. Avoid another general policy document. Current churn guidance already says metrics are informational and must not become an accounting gate; preserve that intent.

There are two residual helper defects after the forced merge. I independently replayed the exact merged helper at `a1721d4b85cf133fe8184ede2fea43cec2eca150` with four small CLI cases:

| Input | Actual QA verdict |
| --- | --- |
| Valid current v3 control | SATISFIED |
| Headless blocked v3 alone | UNKNOWN |
| Valid current v3 plus that headless blocked v3 | SATISFIED |
| Interaction measurements 100MB / 90Mb / tolerance 1MB | SATISFIED |

These reproduce the two remaining [Codex findings](https://github.com/shakacode/react_on_rails/pull/4980#discussion_r3940091382), [unit finding](https://github.com/shakacode/react_on_rails/pull/4980#discussion_r3940091384). They affect the internal evidence verdict. This investigation found no product-runtime code change. Treat the helper's SATISFIED result as insufficient by itself to establish QA completion. Any later repair should cover these two demonstrated cases without reopening the legacy grammar or unrelated receipt systems.

The lesson to carry forward is specific: **when review repeatedly exposes new exceptions in an internal evidence mechanism, stop patching examples and reconsider the mechanism's value and design. A workflow improvement should earn its ongoing review and maintenance cost.**

This document records the investigation; it does not change workflow behavior or approve the proposed pilot thresholds. The original investigation produced local replay evidence. Follow-up tracking is listed below. Research coverage includes all paginated public PR discussion and inline threads, selected complete review bodies, commit/diff history, six identifiable local review usage records and relevant workflow policy. Full cross-machine implementation usage and the exact historical branch-protection rejection are unavailable.

The recurrence matters for backlog decisions. Closed [issue #367](https://github.com/shakacode/agent-workflows/issues/367) describes an earlier shell-command parser that needed seven successive review repairs. Its closure does not establish that a general stopping rule shipped. In this incident, the same pattern recurred while #392 remained open. The backlog review should distinguish recorded lessons, implemented changes, and observed improvements.

Follow-up ownership and sequencing:

- [#392](https://github.com/shakacode/agent-workflows/issues/392): P1 recommendation; reuse the existing bounded-review-loop issue. First demonstrate that the #4980 sequence triggers a value/design decision before another repair round. Keep the proposed two-round threshold a pilot, and preserve substantive correctness gates.
- [#399](https://github.com/shakacode/agent-workflows/issues/399): existing token-budget work; add the six-session partial usage evidence. The stopping-rule slice should not wait for the full descendant-accounting design.
- [#760](https://github.com/shakacode/agent-workflows/issues/760): P2; one new bundled issue for reply recovery and stale formal-review-state handling.
- Backlog-focused maintainer chat: own the portfolio decision about finishing or closing existing work before admitting new infrastructure. This document does not assign implementation workers or silently change portfolio policy.

For that portfolio review, measure finished useful outcomes and recurring failures, alongside starts and open inventory. Choose one small corrective slice to finish; explicitly park or close lower-value work. Treat new analysis, schemas, dashboards and follow-up issues as costs that need a demonstrated payoff. A local workflow improvement should not be declared effective merely because its PR merged: replay the motivating incident, then check its behavior on subsequent real work.
