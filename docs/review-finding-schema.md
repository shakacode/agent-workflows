# Review Finding Schema

Use this shared schema when a review or audit workflow wants machine-readable
findings in addition to its normal human-readable report. The prose report stays
primary. The structured block is optional unless a specific workflow or user
request asks for it.

Review findings are advisory until an agent verifies them against the real code,
the relevant repository policy, and the current PR or branch head state.

## Shape

Emit a structured block as fenced JSON with a top-level `review_findings` array:

````markdown
```json review-findings
{
  "schema": "review-finding-v0",
  "review_findings": [
    {
      "id": "adv-001",
      "source": "adversarial-pr-review",
      "target": {
        "repo": "OWNER/REPO",
        "pr": 123,
        "head_sha": "abc123"
      },
      "severity": "P1",
      "disposition": "must_fix",
      "title": "Current-head check result is stale",
      "body": "The readiness report cites a check run from an older head SHA.",
      "verification": {
        "status": "verified",
        "current_head_state": "stale",
        "checked_at": "2026-07-02T12:34:56Z"
      },
      "location": {
        "file": "workflows/pr-processing.md",
        "line": 650
      },
      "evidence": [
        "PR head SHA: abc123",
        "Check run SHA: def456"
      ]
    }
  ]
}
```
````

## Required Fields

Each finding object must include:

- `id`: stable within the report. Use a short prefix for the source, such as
  `adv-001`.
- `source`: workflow or skill that produced the finding, such as
  `autoreview`, `adversarial-pr-review`, `address-review`, or
  `post-merge-audit`.
- `target`: object naming the reviewed surface. Include the fields known to the
  workflow, such as `repo`, `pr`, `issue`, `branch`, `base_ref`, or `head_sha`.
- `severity`: one of the allowed severities below.
- `disposition`: one of the allowed dispositions below.
- `title`: one-line summary.
- `body`: concise explanation of the risk, decision, or non-actionable result.
- `verification`: object with at least `status` and `current_head_state`.

## Optional Fields

Use optional fields when they help downstream tooling without forcing every
workflow into the same shape:

- `location`: object with `file`, `line`, `end_line`, `symbol`, or `url`.
- `evidence`: array of short strings naming commands, API facts, artifacts, or
  code observations.
- `recommendation`: proposed next action.
- `owner`: person, team, worker, or `UNKNOWN`.
- `links`: array of URLs for PRs, issues, comments, runs, logs, or docs.
- `related_ids`: array of finding ids this finding duplicates, supersedes, or
  depends on.
- `notes`: short extra context for humans. Do not put required facts only here.

## Severities

Use priority severities so review and audit paths can share one vocabulary:

- `P0`: release blocker, security/data-loss risk, or active severe regression.
- `P1`: merge blocker or high-confidence correctness, compatibility, or policy
  issue that should be fixed before readiness.
- `P2`: real issue worth fixing, but not a current merge blocker.
- `P3`: low urgency, speculative, cleanup, or follow-up candidate.
- `INFO`: investigated context, non-actionable note, or useful audit record.

When a skill has its own human-facing labels, map them explicitly in prose. For
example, `BLOCKING` usually maps to `P1` or `P0`; `FOLLOWUP` usually maps to
`P2` or `P3`; `NOISE` usually maps to `INFO`.

## Dispositions

Use one of:

- `must_fix`: accepted blocker that needs a code, docs, policy, or validation
  change before readiness.
- `needs_decision`: maintainer or product decision required.
- `should_fix`: accepted non-blocking improvement.
- `accepted_fixed`: accepted and already fixed in the reviewed head.
- `deferred`: valid follow-up, intentionally left out of this PR or lane.
- `waived_by_maintainer`: explicitly waived by a maintainer; include evidence.
- `rejected_false_positive`: investigated and found incorrect.
- `rejected_not_actionable`: investigated but too speculative, too broad, or not
  useful for this target.
- `unknown`: not enough current evidence to classify.

## Verification

`verification.status` must be one of:

- `unverified`: copied from a reviewer, audit, or issue report but not checked.
- `verified`: checked against local code, trusted docs, current GitHub state, or
  another named evidence source.
- `contradicted`: checked and evidence disproves the finding.
- `unknown`: verification was attempted but could not be completed.

`verification.current_head_state` must be one of:

- `current`: evidence applies to the current PR or branch head SHA.
- `stale`: evidence came from an older head, base, run, comment, or checkout.
- `not_applicable`: the target has no PR/head concept.
- `unknown`: the workflow could not verify whether evidence is current.

Findings with `verification.status` other than `verified`, or
`current_head_state` of `stale` or `unknown`, must not be treated as merge
blockers without a separate current-head verification step.
