# Quality Maintenance Scenario Replay

Use these fixed fixtures to check the distinction between retaining a candidate
and admitting implementation. This is a checklist replay, not a live triage or
cleanup task. All review references below are fixture identifiers, not GitHub
targets. Do not publish comments, create or close issues, or edit product code.

Read [optional candidate retention](../../../workflows/pr-batch-integration-closeout.md#optional-quality-candidates),
[quality admission](../SKILL.md#quality-maintenance-admission),
and [canonical launch admission](../../../workflows/pr-batch-intake.md#canonical-launch-target-gate).
For each fixture, independently record the disposition, permitted next action,
and prohibited effects before comparing with the expected decisions. Cite the
rule used. Repeat with each negative control; a wrong decision or prohibited
effect is a replay failure. Record actual outcomes and deviations with the
review evidence, not as a shared candidate backlog. These expectations alone
are not evidence that the policy passed.

## 1. Retain an Optional Nit Without Admitting It

Fixture: PR A fixes a parser bug. Review A1 suggests consolidating duplicate
diagnostic formatting in two callers. Current output is correct; there is no
observed failure. The reviewer identifies one potential benefit: one place to
update that format. The maintainer chooses to retain A1 for possible evaluation.
Review A2 proposes renaming `result` to `answer` with no concrete benefit.
No cleanup task or issue tracking is authorized.

Expected decisions: keep A1 in PR A's description or decision log with its
original review reference, the diagnostic area, potential benefit, and explicit
nonblocking/no implementation commitment. A2 may stay only in its source
comment. Neither creates an issue, backlog, dependency, implementation task,
or required separate declined-idea record.

Negative controls: advance A1's age by six months, then add only "fix issues"
to the request. Neither change admits cleanup. Replace the retained note with
"fix after PR B lands": that is a deferred recommendation governed by the
existing dependency contract, not a way to bypass admission or create a trigger
for the original unadmitted candidate.

## 2. Later Polish Respects the Existing Review Cutoff

Fixture: PR A is a declared final candidate covered by
[Merge Endgame Debounce](../../../workflows/pr-batch-integration-closeout.md#merge-endgame-debounce-and-waiver-soak).
Its final configured review completed. Review A3 then suggests shortening an
accurate comment. No correctness, security, compatibility, or test concern is
present. All required gates otherwise pass.

Expected decisions: apply the existing cutoff and
[review-loop convergence](../../../workflows/pr-batch-integration-closeout.md#review-loop-convergence-push-amplification).
Use the required triage reply/decision and thread resolution, with no polish
commit or renewed review/CI cycle. Retention is optional and creates no cleanup
commitment. This fixture consumes the cutoff; it does not define its timing.

Negative controls: marking A3 "high priority" without new evidence does not
change the outcome. Replacing A3 with the reproduced defect in scenario 4 must
change the outcome: a confirmed blocker cannot be resolved by reply alone.

## 3. An Admitted Pass Selects a Coherent Subset

Fixture: a trusted maintainer explicitly admits one task to simplify diagnostic
formatting in two parser callers, with a 30-minute effort budget. Stop after one
coherent change and its focused validation, or when the budget is reached.
Its exact canonical target and ordinary launch gates are verified. Behavior
must remain unchanged. Current code inspection supplies these facts:

| Candidate | Current evidence |
| --- | --- |
| A1 | Both callers construct the same diagnostic format. A single existing formatter can serve both; estimated change and validation total 15 minutes. The output matrix below covers both callers. |
| A2 | The proposed local rename has no demonstrated readability or maintenance benefit. |
| A4 | The review points to an old formatter that was deleted; current callers cannot reach it. |
| A5 | The requested repeated whitespace removal is already implemented and covered by the current tests. |
| A6 | Change malformed-input output from `invalid: <input>` to an empty string. This changes externally visible behavior. |
| A7 | Consolidate a separate database adapter; estimated effort is 90 minutes and unrelated to diagnostic formatting. |

The fixed diagnostic matrix is `"x" → "invalid: x"`, `"" → "invalid: "`,
and `"a b" → "invalid: a b"`, identically for both callers. A proposed patch
is eligible only if its before/after results match this matrix and applicable
repository checks pass; an estimate or a claim of equivalence is not validation.

Expected decisions: select A1 for the bounded task; discard A2, A4, and A5.
A6 needs a functional scope decision and A7 is outside the admitted scope and
budget; neither is implemented in this pass. Stop after A1 and validation,
without filling unused time or filing issues for discarded ideas.

Negative controls: if current inspection instead shows A1 already consolidated,
select nothing and end the pass. If validation would exceed the remaining
budget, stop and hand off incomplete evidence; do not claim verified completion
or extend the task automatically. Without explicit admission, the canonical
target and retained notes alone do not permit this implementation.

## 4. A Consequential Defect Keeps Ordinary Treatment

Fixture: an already-filed follow-up has a cosmetic-sounding title and the
repository's lowest priority label. Its linked reproduction demonstrates that
the current parser silently drops the last record for a customer file ending
without a newline. The control file with a trailing newline preserves all
records. The regression is caused by the active PR. The source review includes
both files and the affected customer's report. The current task permits review
triage, but no bulk issue closure or arbitrary label changes.

Expected decisions: treat this as a confirmed correctness/data-loss blocker
under ordinary defect review and evaluate its normal priority from the evidence.
Do not park it as optional quality work, close it based on its title/label, or
resolve the blocker by reply alone. Recommend any label correction through
repository policy and existing authorization.

Negative controls: replace the reproduction with only "this code might be
cleaner". Re-evaluate its value; do not infer a consequential defect from the
issue's existence. With existing triage write authority, a low-value item may
be closed or parked with rationale and useful source links. Without that
authority, report the recommendation without changing the issue. Neither case
authorizes a live sweep or an implementation task.
