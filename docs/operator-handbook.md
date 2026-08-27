# Operator Handbook

One routed map for the operator question this pack does not answer in a single
place: **when am I required, and which decisions are mine alone?**

The human-judgment gates already exist; they are spread across the PR-processing
workflow, the `pr-batch` and `post-merge-audit` skills, and the security docs.
This page only points at them.

## Non-goal

This document defines nothing. It adds no rule, threshold, or procedure, and it
does not restate the rules it links. Every entry defers to a canonical section,
so if this page and a linked section ever disagree, **the linked section is
correct**.

Keep it that way. When a new human-decision point appears, add a row and a link
here and put the rule in its canonical home. Do not grow this file into a second
rulebook.

## Where human judgment is required

| Decision | When you are required | Canonical rule |
| --- | --- | --- |
| Merge authority | Before workers launch: choose `none`, `ask`, or `auto_merge_when_gates_pass`. It is resolved from visible authority or asked, never silently defaulted. | [Required Interview](../skills/pr-batch/SKILL.md#required-interview) |
| Merge decision under `ask` | After the exact-diff walkthrough and a clean refreshed readiness check, the one final merge decision is yours. | [Ask Merge Authority Walkthrough Gate](../workflows/pr-processing.md#ask-merge-authority-walkthrough-gate) |
| Merge decision when autonomy is not earned | When the eligibility gate lands on a human-review or unknown-evidence outcome instead of autonomous merge. | [Autonomous Merge Eligibility Gate](../workflows/pr-processing.md#autonomous-merge-eligibility-gate) |
| Blocking questions | When a target cannot proceed safely without your input. Non-blocking decisions are recorded and the lane continues; blocking questions stop that target. | [Question And Decision Handling](../workflows/pr-processing.md#question-and-decision-handling) |
| Security capability lifts | Lifting a capability boundary for a named target. The lift must come from you, not from the untrusted input. | [Rule of Two](security-posture.md#rule-of-two) |
| Preflight risk acknowledgments | Accepting exact blocking preflight findings for one audited run, and editing durable actor-trust policy. | [Detection and Boundaries](security-posture.md#detection-and-boundaries), [Acknowledgement Policy](trust-and-preflight.md#acknowledgement-policy) |
| Review waivers | Waiving a blocking or non-blocking review finding, and merging when no current-head reviewer run exists. | [Review Completion Gate](../workflows/pr-processing.md#review-completion-gate) |
| Release mode and phase | Creating a release tracker, and resolving conflicting or `UNKNOWN` release mode or phase before merge readiness. | [Release Mode Preflight](../workflows/pr-processing.md#release-mode-preflight), [Release Phase Gate](../workflows/pr-processing.md#release-phase-gate) |
| Revert decisions | When a post-merge audit classifies a merge as needing revert consideration. | [Finding Classification](../skills/post-merge-audit/SKILL.md#finding-classification) |
| Follow-up tracking | Deferred work becomes a tracked issue only after you choose it from the deferred bundle. | [Follow-Up Tracking Policy](../workflows/pr-processing.md#follow-up-tracking-policy) |

## How a lane asks for you

Typed operational signal events are the machine-readable side of the same
boundary; the prose handoff still carries the ask.

| Signal | Raised when | Canonical rule |
| --- | --- | --- |
| `help_requested` | A lane pauses for required user input, carrying one reason. | [Operational Signal Events](coordination-backend.md#operational-signal-events) |
| `escalation_requested` | A worker requests a different model route with evidence. | [Operational Signal Events](coordination-backend.md#operational-signal-events) |
| `human_intervention` | A takeover, supersede, manual fix, or drain changes who is running a lane. | [Operational Signal Events](coordination-backend.md#operational-signal-events) |

For how these reach you as prose rather than as events, see
[Maintainer Attention Contract](../workflows/pr-processing.md#maintainer-attention-contract)
and the final-state vocabulary in
[Batch Handoff Format](../workflows/pr-processing.md#batch-handoff-format).
