# Recovery plan: balance verification with useful delivery

Date: 2026-09-05. Scope: shakacode/agent-workflows. This record preserves the backlog investigation and discussion options. It does not change executable workflow policy or allocate implementation work.

Companion: [case-study evidence notebook](../postmortems/2026-09-05-verification-backlog-case-study.md). Related investigation: [ROR #4980 review churn](../postmortems/2026-09-05-ror-4980-review-churn.md).

## Status update: September 6, 2026, 05:34 UTC

[PR #695 merged](https://github.com/shakacode/agent-workflows/pull/695) at 04:48 UTC. Its [archive closeout on #392](https://github.com/shakacode/agent-workflows/issues/392#issuecomment-5557218968) supersedes the pending-owner handoff below: the existing work and unpublished changes were preserved, the PR's claim was released, and no active implementation owner or automatic continuation is assigned to its follow-ups. The document-size assertion, valid-`UNKNOWN` filename limitation, and malformed-encoding reporting are parked observations, to revisit only on concrete impact or explicit reprioritization.

The two-round continuation brake and five-PR adoption pilot were not shipped by #695. They remain separately prioritized on #392. The next portfolio decision belongs to the maintainer and **AW Portfolio Control Tower**; do not wait for or automatically restart the former #695 owner. The earlier integration/refactoring options and other parked or queued work below are not new admissions. This document preserves the original investigation as history; the linked later disposition controls current ownership and continuation.

## September 5 decision and original handoff (historical)

The [maintainer-approved #392 decision, recorded September 5 at 22:34 UTC](https://github.com/shakacode/agent-workflows/issues/392#issuecomment-5555246299), governs scheduling. It supersedes this investigation's earlier sequence of integration and refactoring experiments. Those ideas remain discussion options below; they are not newly admitted work.

- **AW Portfolio Control Tower** owns admission, ownership reconciliation, and cross-lane sequencing. **AW Closeout — PR #695** is the named existing task for the implementation checkpoint; the existing owner retains implementation responsibility pending reconciliation. Handoffs to both tasks were reported queued. Acknowledgement was not verified in this documentation pass.
- Keep [#392](https://github.com/shakacode/agent-workflows/issues/392) P1. At the next safe checkpoint, preserve [#695](https://github.com/shakacode/agent-workflows/pull/695)'s branch and unpublished work, and hold broader review-packet/canonical-diff expansion. Return the smallest continuation-check implementation plan using existing state at the actual repair/re-review boundary.
- Pilot a stop after two repair rounds, or earlier when another grammar/protocol/schema category is proposed. Retain counts across pushes and resumes. Require explicit impact/design adjudication before further automatic repair or review. Unresolved substantive defects and required review, CI, and security gates remain in force.
- Prove the interruption by replaying the first 13 commits of [ROR #4980](https://github.com/shakacode/react_on_rails/pull/4980), including without token telemetry and across resume. The existing owner and tower then observe the next five consecutive eligible PRs and compare them with five preceding comparable PRs. Record workflow revision, trigger, decision, later rounds, useful outcome, and escaped defects. A merged rule alone is not success.
- Keep [#760](https://github.com/shakacode/agent-workflows/issues/760) queued at P2 until that pilot, limited to reply readback/422 recovery and stale formal review state. Park [#399](https://github.com/shakacode/agent-workflows/issues/399) replacement implementation through the pilot. Preserve its requirements and [#426](https://github.com/shakacode/agent-workflows/pull/426) evidence; retire #426 as superseded only after the tower reconciles any successor/live work. Keep [#367](https://github.com/shakacode/agent-workflows/issues/367) closed.
- No new workers, duplicate issues, full packet machinery, receipt schema, dashboard, or #399 prerequisite. Existing unrelated agents checkpoint within their scope. New infrastructure waits for existing work to finish or receive an explicit park/close disposition, except a demonstrated security, production, release, or active-work blocker with one owner, bounded scope, and named displaced work.

**Original next step, superseded by the status update above:** obtain the existing #695 owner's checkpoint and smallest stopping-rule plan, then let the tower reconcile scheduling before implementation resumes. The checkpoint was to identify the preserved head/unpublished work, the repair-loop boundary and existing state to reuse, the minimum intended change, and the replay that proves interruption. This document does not reassign the lane or grant merge, deletion, security-bypass, or foreign-claim takeover authority.

## Recovery principle

Stop converting every review observation into implementation demand. Separate discovery, admission, implementation, and acceptance. Preserve a small safety floor and make the remaining process earn its cost in measured results. Use the existing finishing owner. Consider selective context/branch resets, small coherent integration groups, and component extraction only when the tower admits them under the governing decision.

Recovery does not require a new scheduler, dashboard, review engine, evidence schema, or repository-wide rewrite before work can resume. Current admission follows the status update above.

## First-principles model

A review comment is an observation. An issue preserves an observation or proposal. Neither is automatically an approved requirement. Implementation admission needs a separate judgment about real impact, evidence, scope, and opportunity cost.

The costly loop is: review suggestion → deferred issue → generic “fix issues” instruction → implementation → new review suggestions → more deferred issues. Refactoring, repeated base refreshes, and full validation amplify the work each turn creates. If a completed unit continually generates at least as much new work as it retires, adding agents does not make that queue converge.

The objective is valuable improvements successfully used by consumer repositories per unit of human attention and elapsed time, with an explicit safety floor. PR count is a supporting metric, not the objective. Closing valid work solely to improve the count is not success.

Several current rules already say the right thing: evaluate-issue treats AI findings as leads; ordinary follow-up tracking defaults to no new issue; coordinated address-review creates no new follow-up issue; final-candidate policy rejects nit-only pushes. The implementation gap is that durable scheduling state does not consistently reflect those decisions. Post-merge audits also have a separate default-create rule; their intake must still distinguish an issue-worthy finding from optional polish.

## Completed in this planning pass

Verified 48 issues with the follow-up origin label (47 newly labeled; #760 already labeled). Parked #283, #356, #359, #459, #482, #583, #645, and #750 with review-nit, P3, and needs-customer-feedback. Before/after API readbacks were retained in the originating task’s local audit; the public source links and per-item parking reasons are preserved below. The local audit is supplemental evidence, not a dependency for using this document. Three missing label definitions were created; the existing follow-up label was reused. This label pass made no code or repository workflow changes.

## 1. Stop optional work from re-entering the queue

Use the existing `follow-up` label for origin only. Preserve reproduced regression, security, installation, and operational blockers as separate work. For verified optional items use `review-nit`, `P3`, and `needs-customer-feedback`. The last label is recognized by the current triage skill as parked until customer evidence or explicit maintainer approval exists.

“Fix issues” should mean: fix the exact items admitted after an impact evaluation. It must not select all open issues, all AI findings, or everything without an assignee. Existing implementation PRs and active claims must be reconciled before starting another lane. A parking label does not stop an already-running process, revoke a claim, or close its PR.

New optional suggestions normally end as a declined/accepted-limitation disposition in the source PR. Record a separate issue only for independently valuable, actionable work that is actually worth scheduling. Repeated occurrences may justify one root-cause issue when they demonstrate material cost; repetition of bot wording alone is not impact evidence.

### Parked optional items from this pass

These were the eight confirmed optional items at the September 5 snapshot. Each received `follow-up`, `review-nit`, `P3`, and `needs-customer-feedback`; labels can subsequently change under a new maintainer decision.

| Source | Reason for parking | Promotion trigger |
| --- | --- | --- |
| [#283](https://github.com/shakacode/agent-workflows/issues/283) | Example-marker choice; potentially already superseded. | Demonstrated current example failure after checking supersession. |
| [#356](https://github.com/shakacode/agent-workflows/issues/356) | Optional coverage-gate refinements awaiting usage evidence. | Observed coverage miss affecting a real workflow. |
| [#359](https://github.com/shakacode/agent-workflows/issues/359) | Redundant prose assertion without a demonstrated behavior defect. | Concrete behavior gap the proposed test would detect. |
| [#459](https://github.com/shakacode/agent-workflows/issues/459) | Generic fixture-identifier cleanup; replay already works. | Reproduced fixture collision or operator confusion. |
| [#482](https://github.com/shakacode/agent-workflows/issues/482) | Speculative review-tier RFC with an existing park/P3 recommendation. | Usage evidence or an explicit decision to schedule the design. |
| [#583](https://github.com/shakacode/agent-workflows/issues/583) | Explicitly nonblocking hardening ideas from #575. | Verified correctness, security, or operational failure. |
| [#645](https://github.com/shakacode/agent-workflows/issues/645) | Paired proof/digest value-object proposal; current behavior described as safe. | Observed misuse or a specific approved maintenance need. |
| [#750](https://github.com/shakacode/agent-workflows/issues/750) | Optional OC-text test-assertion hardening. | A demonstrated regression missed by existing checks. |

This table is the shared parking register for this pass. It is reference material, not a task to implement all rows. No umbrella issue was created and no source issue was closed.

### Handling future optional observations

Reuse this register or an existing maintenance record for optional observations with source links, one-sentence dispositions, and a promotion trigger. It is reference material, not an executable backlog. Do not assign an agent to “implement everything in the register.” A compact issue or existing maintenance record can link the register, but must carry the same parked labels.

For the existing separate issues, labels provide immediate containment. Consolidation and closure should follow a checked mapping: original issue → retained note → parked/not-planned or superseded disposition. Preserve URLs, history, and branch references. Check for active PRs before closing their source issues. This plan does not mass-close existing issues or create another public tracker merely to index them.

Promotion requires new evidence of a real problem or an explicit decision to schedule the particular item. It does not happen merely because the main queue is empty or a model thinks the fix looks easy.

## 2. Discussion option: reset context before replacing a PR

A long conversation is a signal to inspect convergence, not a numerical closure threshold. GitHub review-submission counts are not counts of independent review rounds.

| Situation | Default action |
| --- | --- |
| Implementation is sound and scope is stable; chat is noisy | Fresh agent context with a compact handoff; retain PR, branch, and applicable evidence. |
| Branch is behind but the intended diff is still coherent | Reconcile the branch once near its landing slot; retain PR. |
| Current implementation embodies superseded requirements or competing approaches; recovery costs more than reconstruction | Fresh branch from current main and a replacement PR containing the smallest accepted implementation. |
| Idea is already delivered, duplicate, low-value, or no longer wanted | Close with an evidence-backed disposition; do not rewrite it. |

### Handoff contents

Use a short entry document plus links to the source evidence:

- canonical issue and current acceptance criteria;
- current source PR/head/base and any unpublished candidate commit;
- behavior worth retaining and deliberately excluded behavior;
- confirmed unresolved findings, dispositions of resolved/declined findings, and linked source threads;
- current validation and review evidence with its exact applicability and gaps;
- ownership, dependencies, authority decisions, and next action.

The new worker validates the handoff against GitHub and the diff. It need not reread every historical exchange. Missing or contradictory material facts are investigated rather than silently omitted.

### Replacement sequence

1. Reconcile the original writer and preserve its branch, exact head, and unpublished work. Do not race another owner.
2. Decide which accepted behavior and tests survive. Salvage coherent changes; a replacement need not be a rewrite from memory.
3. Prepare the new current-main branch and complete source-finding carryover before opening the replacement.
4. Link source and replacement both ways with the reason, retained scope, excluded scope, and unresolved obligations.
5. Make the replacement the single active implementation path; close the source as superseded once the successor and ownership are durable. Keep the original branch/history.
6. Review and validate the new current diff, including new adaptation code and the combined behavior. Prior evidence may be reused only under its applicability rules.

Replacement must not reset the accounting of risk or conceal adverse review. A fresh PR number does not cancel unresolved security/correctness findings or manufacture human approval. If count-based policy now gives a different result, disclose the lineage and reassess it under trusted policy instead of treating the reset as a loophole.

Study #446 → #737 as an existing replacement example. Assess #269 and #622 for a context reset first; their large histories alone do not justify discarding completed work.

## 3. Deferred option: bounded integration branches

Admission is deferred to the tower under the governing decision. The candidates and states below describe the September 5 investigation snapshot; recheck them before any later scheduling.

An integration branch localizes conflict resolution and combined testing. It cannot eliminate semantic disagreement. Automatically mergeable text can still implement incompatible rules.

Start with a coherent group of two or three PRs, selected by shared behavior and dependencies. This is an experimental batch size, not a new global WIP cap or a capacity allocation. Keep a single integrator for the selected group. Independent review can run alongside useful preparation; there must be one mutation owner per branch.

Do not merge all 84 PRs into a long-lived branch. That would create a new oversized review surface, hide which component caused a regression, and make rollback harder.

### Earlier candidate experiment, not scheduled

If admitted later, coordinate through existing #742 integration work and #559 modularization work; neither is a new owner assignment. The earlier proposal was to first finish the small direct-landing candidates from the inventory to establish that the finishing path works. For a shared-file rehearsal, inspect #707 and #708 together: they both change small-batch closeout/review behavior and overlap four paths. At that snapshot both were drafts with unresolved findings; none is admitted merely because it belongs to this proposed group. Validate their compatibility and value before any merge.

The previously selected Astra pair #758/#759 was another potential group, but the September 5 path inventory showed only two shared paths. Do not aggregate them just for the sake of batching. #757 already depends on those two behavior/routing changes and owns later stage-loading work.

### Rehearsal and publication rules

- Create an isolated integration branch/worktree from a recorded current main SHA; freeze source heads for the experiment after owner handoff.
- Integrate selected accepted diffs in dependency order. Record each source head and each conflict resolution; separate semantic adaptation from mechanical resolution.
- Use Git's recorded conflict-resolution facility (`rerere`) within that integration checkout when useful. Inspect reused resolutions and keep automatic index staging disabled. Reuse of a resolution is not evidence that the behavior is still right.
- Run focused behavioral checks on each incorporated change, then the required full checks and independent review on the final combined candidate. Do not claim every intermediate source head passed the aggregate test.
- Decide one publication route. Default: keep source PRs as the landing units and use the rehearsal to prepare the agreed sequence. Update only the next source candidate and verify its actual current-base state before landing. Rehearsal evidence must not be presented as that source PR's own current-head CI.
- If preserving individual PRs would repeat most of the integration effort, explicitly choose one replacement integration PR for the bounded group. Its source mapping, complete combined diff, review, current-head checks, trusted-base eligibility, and rollback must be reviewable. It will often need human review because aggregation increases scope. Source PRs are closed as superseded after the accepted combined result is landed; they are not merged again.
- Main may advance. Reassess the actual delta before publication and refresh affected evidence. A temporary branch is not permission to ignore main movement or branch protection.
- If the rehearsal does not reduce conflict/validation time, drop the extra branch and continue serial direct landing. Preserve measured results either way.

Git references: https://git-scm.com/docs/git-rerere and https://git-scm.com/docs/git-merge.

## 4. Deferred option: extract conflict hotspots after reconciliation

No refactoring lane is launched by this plan. The following design guidance is retained for a later tower decision after the pilot and ownership reconciliation.

The refreshed September 5 snapshot of 84 PRs had 35 PRs touching `workflows/pr-processing.md`, 28 touching `skills/pr-batch/SKILL.md`, 28 touching `bin/validate`, and 24 touching `workflows/pr-batch-integration-closeout.md`. These are overlap counts, not semantic dependency edges or proof of actual textual conflicts.

Do not wait for the entire backlog to merge, and do not relocate all shared files first. Pick one cohesive component, reconcile its accepted in-flight changes, then extract it once. Give the remaining PR owners a path/contract migration map so they adapt to the new canonical location instead of recreating old mirrors.

Use #559's existing component boundaries: intake, worker execution, integration/closeout, optional coordination/observability, and security floor; production/release is a separate downstream lifecycle. Use #757 for stage-specific loading and preserve its explicit dependencies. Do not open a competing architecture effort.

The old entrypoint becomes a short index/compatibility route. Each rule has one canonical source, and skills load only the relevant stage. Moving paragraphs while keeping full copies in all callers is not a successful extraction. Tests should exercise behavior, reference reachability, and required interfaces; exact strings remain appropriate for real machine markers, not as a substitute for semantic correctness.

Keep pure extraction separate from behavior/policy changes. Verify source and installed reference resolution. Measure a representative next change: how many shared files must it touch, how much context must be loaded, and how much validation is needed? That is the acceptance evidence for modularization, not a target line count alone.

### A representation issue worth investigating

[#632](https://github.com/shakacode/agent-workflows/issues/632) records repeated false negatives caused by enumerating acceptable natural-language `HTTPS:` labels in an evidence parser. #631 records regressions while changing the same parser. This is evidence to challenge the abstraction: human explanation and machine-authoritative evidence should have a clear boundary. Investigate whether a smaller explicit reference representation can remove the need to recognize arbitrary prose. Do not start another broad schema rewrite during backlog recovery, and do not weaken existing evidence validation while investigating.

## 5. Sequence proposed at the initial investigation (historical)

This table records the original proposal. The September 6 status update supersedes its pending #695 checkpoint and implementation-owner assignments; later steps are not automatically admitted.

| Step | Existing owner | Done when |
| --- | --- | --- |
| Preserve the investigation | Originating documentation task | This plan and the evidence notebook have versioned, shared links. |
| Obtain the checkpoint | Existing #695 owner | Current and unpublished work is preserved; the smallest stopping-rule plan and replay are identified; acknowledgement is recorded. |
| Reconcile scheduling | AW Portfolio Control Tower | The current owner is confirmed, holds are recorded, and the narrow next action is reconciled without duplicate workers. |
| Implement and replay the admitted slice | Existing #695 owner | The continuation check interrupts the #4980 repair sequence without telemetry and across resume, while required safety gates remain intact. |
| Observe adoption | Existing owner and tower | Five consecutive eligible PRs are recorded and compared with five preceding comparable PRs for useful outcomes and escaped defects. |
| Revisit deferred work | Tower after pilot evidence | #760, #399, integration experiments, refactoring, and optional-issue consolidation receive explicit dispositions rather than automatic admission. |

Preserve current security, authority, branch protection, meaningful verification, current-head review, and rollback requirements. Repair a confirmed blocker; dispose of a nonblocking suggestion without a code change. End an unproductive bounded experiment with a decision to narrow, replace, park, or abandon; do not convert “time ran out” into a passing gate.

Measure time from candidate selection to merged/accepted result, human decision minutes, CI/validation attempts, minutes spent resolving conflicts, new follow-up work admitted, and confirmed defects/reverts after landing. Separate active work from waiting. Count review submissions separately from independent rounds. Track valuable merged work, superseded/obsolete closures, and parked work separately so backlog reduction cannot hide abandonment.

Do not collect an elaborate telemetry system first. A small timestamped ledger with source URLs is enough to evaluate the first pass. Cost/token attribution and escaped-defect rates remain UNKNOWN until recorded; do not infer them from review or commit counts.

## Status and unresolved questions

This publication preserves analysis and the already-approved #392 direction. It does not approve the deferred experiments, certify merge readiness, or create another workflow gate.

The earlier plan review retained these constraints: reset context before replacing sound work; preserve findings and authority across replacement; distinguish an integration rehearsal from its publication route; separate follow-up origin from priority; reconcile live ownership before takeovers or consolidation; and avoid making another process platform a recovery prerequisite.

Acknowledgements and active processes were unverified in the original investigation. The September 6 closeout resolves the former #695 owner's disposition without assigning a successor. Any later integration or extraction experiment still needs fresh source-head, ownership, compatibility, and value checks.
