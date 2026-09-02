## Why

Small workflow diffs can leave noisy Git history when squash messages copy the
same agent evidence that already lives in the pull request.

## What changed

- Check the PR evidence and commit-message ownership boundary.

## How to review and verify

1. Replay the evidence marker from this PR body.
2. Confirm the commit message keeps rationale and provenance without agent logs.

<details>
<summary>Agent details</summary>

### Commands and results

- `ruby skills/pr-batch/bin/concise-history-check-test.rb` — passed.

### Exact-head and replay evidence

- Tested head: `1111111111111111111111111111111111111111`.

### QA Evidence

- QA lane: fixture-agent; required.
- Scope checked: concise-history small-diff fixture.
- Tested at: PR fixture head 1111111111111111111111111111111111111111.
- Automated checks: concise-history-check.
- Manual checks: not applicable: deterministic text contract.
- User-visible UI change: no.
- Visual evidence: not applicable: no UI change.
- Interaction change: no; not applicable: no interaction change.
- Interaction evidence: not applicable: no interaction change.
- Visual fix: no; not applicable: no visual fix.
- Negative control: not applicable: no visual fix.
- Performance evidence: not applicable: no runtime change.
- Findings: none.
- QA required: yes.
- QA required rationale: the executable contract must replay the PR evidence.
- QA lane status: satisfied.
- Release-blocking status: clear.
- Process-gap disposition: checklist+replay.

<!-- qa-evidence v2
required: yes
status: satisfied
head_sha: 1111111111111111111111111111111111111111
tested_at: PR fixture head 1111111111111111111111111111111111111111
scope: concise-history small-diff fixture
automated_checks: ruby skills/pr-batch/bin/concise-history-check-test.rb
manual_checks: not applicable: deterministic text contract
user_visible_ui_change: no
visual_evidence_destination: not_applicable
visual_evidence: not applicable: no UI change
paint_check: not applicable: no UI change
interaction_change: no
interaction_evidence: not applicable: no interaction change
visual_fix: no
negative_control: not applicable: no visual fix
performance_impact: not_applicable
performance_evidence: not applicable: no runtime change
findings: none
release_blocking: clear
process_gap_disposition: checklist+replay
-->

### Coordination and reviewer telemetry

- Review finding `fixture-review-1` was fixed at the tested head.

<!-- priority-finding-dispositions v1
head_sha: 1111111111111111111111111111111111111111
finding: url=https://github.com/shakacode/agent-workflows/pull/1#discussion_r1 | severity=P2 | disposition=fixed | evidence=https://github.com/shakacode/agent-workflows/commit/1111111111111111111111111111111111111111
-->

### Decision log

- **Non-blocking:** Should the checker impose a fixed message-length limit?
  - **Decision:** No. Review proportionality against the change and its risk.
  - **Why:** Consequential changes can require more durable rationale.
  - **Review later:** None.

### Audit receipts

- Replay source: this canonical disclosure.

</details>
