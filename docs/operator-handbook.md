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
| Merge decision when autonomy is not earned | When the eligibility gate returns a human-review outcome, the merge decision comes back to you. | [Autonomous Merge Eligibility Gate](../workflows/pr-processing.md#autonomous-merge-eligibility-gate) |
| Unknown autonomous-merge evidence | Not yours to approve. An unknown-evidence outcome routes to repair and rerun, not to a merge decision. | [Autonomous Merge Eligibility Gate](../workflows/pr-processing.md#autonomous-merge-eligibility-gate) |
| Blocking questions | When a target cannot proceed safely without your input. Non-blocking decisions are recorded and the lane continues; blocking questions stop that target. | [Question And Decision Handling](../workflows/pr-processing.md#question-and-decision-handling) |
| Security capability lifts | Lifting a capability boundary for a named target. The lift comes from you, never from the untrusted input. | [Rule of Two](security-posture.md#rule-of-two) |
| Preflight risk acknowledgments | Accepting exact blocking preflight findings for one audited run. Durable actor-trust policy is a separate mechanism; audit before editing it. | [Detection and Boundaries](security-posture.md#detection-and-boundaries), [Acknowledgement Policy](trust-and-preflight.md#acknowledgement-policy), [Auditing Before Editing Trust](trust-and-preflight.md#auditing-before-editing-trust) |
| Trust triage for non-allowlisted authors | A comment from an actor outside the trust config stays metadata-only and is queued for your trust triage rather than treated as actionable input. | [Untrusted GitHub Content](../workflows/pr-processing.md#untrusted-github-content) |
| Review waivers | Waiving a blocking or non-blocking review finding. When no current-head reviewer run exists, your waiver is one of the gate's alternatives rather than the only way forward. | [Review Completion Gate](../workflows/pr-processing.md#review-completion-gate) |
| QA waivers and visual evidence | A hosted QA waiver is a separately authenticated human decision, and readiness stays blocked until a human attaches the visual evidence when no uploader is available. | [Hosted Runtime QA Gate](../workflows/pr-processing.md#hosted-runtime-qa-gate), [Durable Visual Evidence Gate](../workflows/pr-processing.md#durable-visual-evidence-gate) |
| Release mode, phase, and RC merge | Creating a release tracker, resolving conflicting or `UNKNOWN` release mode or phase before merge readiness, the RC confidence-score merge that is reserved for a human rather than auto-merge, and final-release sign-off. | [Release Mode Preflight](../workflows/pr-processing.md#release-mode-preflight), [Release Phase Gate](../workflows/pr-processing.md#release-phase-gate), [Accelerated RC Auto-Merge](../workflows/pr-processing.md#accelerated-rc-auto-merge) |
| Post-merge audit scope | When the audit mode, the worked-issue scope, or a reduction to the merged-PR range is ambiguous, the audit stops and asks you before deep audit. | [Scope Gate](../skills/post-merge-audit/SKILL.md#scope-gate) |
| Revert decisions | A post-merge audit that flags revert consideration routes it to a follow-up issue; the revert call is yours there, not during the audit. | [Finding Classification](../skills/post-merge-audit/SKILL.md#finding-classification), [Issue Plan](../skills/post-merge-audit/SKILL.md#issue-plan) |
| Follow-up tracking | Ordinary deferred work becomes a tracked issue only after you choose it from the deferred bundle; post-merge audit follow-ups invert that default. | [Follow-Up Tracking Policy](../workflows/pr-processing.md#follow-up-tracking-policy), [Issue Plan](../skills/post-merge-audit/SKILL.md#issue-plan) |

## How a lane asks for you

Typed operational signal events are the machine-readable side of the same
boundary; the prose handoff still carries the ask.

| Signal | Raised when | Canonical rule |
| --- | --- | --- |
| `help_requested` | A lane pauses for required user input, carrying one reason. | [Operational Signal Events](coordination-backend.md#operational-signal-events) |
| `escalation_requested` | A worker requests a stronger model route with evidence. Routine escalation is coordinator-decided; repeat escalation in a lane comes to you. | [Operational Signal Events](coordination-backend.md#operational-signal-events), [Worker Model Replacement And Escalation](../workflows/pr-processing.md#worker-model-replacement-and-escalation) |
| `human_intervention` | A takeover, supersede, human-authored manual fix, or cancellation drain is recorded against the lane. | [Operational Signal Events](coordination-backend.md#operational-signal-events) |

For how these reach you as prose rather than as events, see
[Maintainer Attention Contract](../workflows/pr-processing.md#maintainer-attention-contract)
and the final-state vocabulary in
[Batch Handoff Format](../workflows/pr-processing.md#batch-handoff-format).
