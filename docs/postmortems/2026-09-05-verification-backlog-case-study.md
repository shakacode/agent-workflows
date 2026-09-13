# Case-study evidence: when verification creates more work

Working title: “When every review suggestion became a requirement.” This is an evidence notebook, not a published article or a settled causal claim.

Companion: [recovery plan and current status](../plans/2026-09-05-backlog-recovery-plan.md). Related incident: [ROR #4980 review churn](2026-09-05-ror-4980-review-churn.md). This notebook records evidence and hypotheses; the latest maintainer dispositions on #392 control scheduling.

## Status update: September 6, 2026, 05:34 UTC

[PR #695 merged](https://github.com/shakacode/agent-workflows/pull/695) at 04:48 UTC. The [subsequent archive closeout](https://github.com/shakacode/agent-workflows/issues/392#issuecomment-5557218968) records preserved unpublished work and parked follow-ups, with no active implementation owner or automatic continuation assigned. It supersedes the pending-owner handoff recorded below. The two-round continuation brake and five-PR observation pilot were not shipped by this merge; they remain separately prioritized by the maintainer and AW Portfolio Control Tower. A merged review contract is not evidence that the proposed brake or its adoption experiment succeeded.

## Product question

How can an agent workflow direct verification and human attention toward valuable delivery without recursively generating more process work than it completes?

## Observations

- First read-only scan on 2026-09-05 around 21:10–21:19 UTC: 82 open PRs, 50 non-drafts, 32 drafts; 61 PRs had 257 unresolved review threads. All thread pages were retrieved. These aggregate counts come from the originating task’s saved GitHub API snapshot; the full inventory and diagnostic remain local supplemental artifacts. They are not current queue counts.
- Follow-up planning scan: 84 open PRs and 131 open issues. New PRs #761 and #762 explain the two additions relative to the first PR snapshot. This is a later snapshot, not a correction of the first one.
- Of the first 50 non-drafts, 36 had successful named Validate/Lint/Claude-review rows. Only seven passed the coarse check/thread screen; none was certified merge-ready by that diagnostic.
- A median of 33.3 minutes across 49 successful Validate rows in the first snapshot makes repeated validation consequential. These are job durations, not queue time or total task time.
- 35 open PRs touched workflows/pr-processing.md; 28 touched skills/pr-batch/SKILL.md and bin/validate. Shared paths indicate integration pressure, not automatic semantic dependencies.
- PR #622: 188 changed lines, 38 commits, 179 GitHub review submissions. GitHub submissions are not independent review rounds. Its remaining Enterprise-host finding was concrete.
- PR #754: 23 changed lines and one unresolved comment explicitly described as a nonblocking nit.
- Issue #645: the proposal says the current behavior is safe and concerns a potential future maintainability mistake; it nevertheless became an issue spanning roughly fifteen signatures.
- Issue #583: the source explicitly says the deferred findings are not verified correctness or security defects; multiple follow-up hardening ideas accumulated in its scope.
- Issue #482 already had a park/P3 recommendation but no corresponding scheduling labels. That is a direct example of a decision failing to reach the queue state.
- Issue #632 describes six rounds of adding acceptable natural-language label forms; issue #631 records real regressions caused while patching the same parser. These suggest an abstraction worth challenging, not just a reviewer to silence.
- Issue #742 already defined integration before new admissions. Its recorded first control-tower pass merged four PRs. Work was slowed and recurrently blocked; it had not literally ceased everywhere.

## Intervention in this task

1. Separate follow-up origin from priority.
2. Add the missing follow-up label to the identified source set.
3. Park eight confirmed optional items with P3, review-nit, and the existing needs-customer-feedback exclusion. Their source links, reasons, and promotion triggers are retained in the companion plan.
4. Retain reproduced or mixed failures for separate evaluation instead of calling all follow-ups nits.
5. Preserve a single optional-review register in the companion plan without making it an implementation task or creating another public umbrella issue.
6. Preserve discussion guidance on context resets, branch replacement, integration rehearsals, and component extraction. No such operation was executed by this planning task; integration and refactoring admission are deferred under the later #392 decision.

The label pass verified 48 follow-up-origin issues by final API readback: 47 newly labeled and #760 already labeled. Eight were also parked as optional; the others were not automatically demoted. Exact before/after API responses remain in the originating task’s local audit. The companion plan preserves the eight public source links and rationales. No PR was closed, replaced, merged, rebased, or refactored by this task. Existing claims and branches were preserved. No workflow policy was weakened.

## Approved follow-through, September 5 at 22:34 UTC (historical)

The [decision on #392](https://github.com/shakacode/agent-workflows/issues/392#issuecomment-5555246299) narrows the first intervention to the existing #695 owner's smallest stopping-rule slice. The pilot stops after two repair rounds, or earlier when a new grammar/protocol/schema category is proposed, and retains counts across pushes and resumes. The next automatic repair/re-review requires explicit impact/design adjudication; substantive defects and required gates remain intact.

The required replay is the first 13 commits of ROR #4980, demonstrating that the next synonym repair is interrupted without token telemetry and across resume. Adoption is then observed on five consecutive eligible PRs against five preceding comparable PRs. This is the current experiment. The earlier direct-landing versus integration comparison is deferred, not another concurrent workstream.

At this point, the tower owned admission and sequencing and the existing #695 owner retained implementation responsibility pending reconciliation. Handoffs were reported queued, but acknowledgement was not verified in the original documentation pass. #760 was queued at P2 through the pilot, #399 replacement implementation was parked, and #426 retirement awaited reconciliation of successor/live work. The September 6 status update supersedes the pending-owner direction; these records do not launch further work.

## Hypotheses to test

- Optional review observations were re-admitted as implementation work because issue existence was mistaken for priority approval.
- Repeated full validation and broad base refreshes amplified integration delay.
- Highly coupled canonical text and tests made isolated changes expensive to reconcile.
- Stable finishing ownership and explicit terminal dispositions improve throughput without reducing substantive review quality.

Do not treat these hypotheses as established solely because the backlog is large. Work complexity, host load, transient API failures, permissions, real defects, and parallel activity may contribute.

## Evidence still needed

For each recovery cohort record: selection timestamp; source heads; owner; accepted scope; review findings accepted/declined; code-changing review rounds; CI attempts; conflict-resolution minutes; human-decision minutes; terminal result; new work admitted; and later confirmed regressions/reverts. Separate waiting from execution and source PRs from replacement PRs. Do not claim token savings without attributable usage records.

For the approved pilot, record workflow revision, trigger, adjudication, later rounds, useful outcome, and escaped defects on the next five consecutive eligible PRs and five preceding comparable PRs. Define eligibility before observing the outcomes and document differences in risk and size. This is a directional comparison, not a randomized causal experiment. Record unsuccessful trials and retained safety benefits too. A direct-landing versus integration comparison can be reconsidered later if the tower admits that experiment.

## Candidate narrative

We built a workflow to make AI work safer and more useful. Some verification rules caught real mistakes. But review observations also became durable issues, and generic issue-fixing instructions promoted them back into work. Each repair could expand the protocol, validation burden, and conflict surface. The corrective move is to make admission and acceptance explicit, keep review proportional to demonstrated risk, and evaluate process changes by their delivery and attention outcomes.

Public storytelling should use repository-linked facts and aggregate metrics. Private coordination identifiers, host paths, credentials, and task transcripts are not public evidence and should not be copied into an article.

## Primary source links

- https://github.com/shakacode/agent-workflows/issues/392#issuecomment-5557218968
- https://github.com/shakacode/agent-workflows/issues/392#issuecomment-5555246299
- https://github.com/shakacode/agent-workflows/pull/761
- https://github.com/shakacode/agent-workflows/pull/762
- https://github.com/shakacode/agent-workflows/pull/695
- https://github.com/shakacode/agent-workflows/issues/742
- https://github.com/shakacode/agent-workflows/issues/645
- https://github.com/shakacode/agent-workflows/issues/583
- https://github.com/shakacode/agent-workflows/issues/482#issuecomment-5517762144
- https://github.com/shakacode/agent-workflows/issues/631
- https://github.com/shakacode/agent-workflows/issues/632
- https://github.com/shakacode/agent-workflows/pull/622
- https://github.com/shakacode/agent-workflows/pull/754#discussion_r3939976217
- https://github.com/shakacode/agent-workflows/pull/673#issuecomment-5549628269
