---
name: post-merge-audit
description: Use when auditing merged PRs after concurrent agent work, before a release candidate, after a suspected bad merge, or when checking for missed reviews, missing changelog entries, cross-PR interactions, or release risk.
argument-hint: '[base tag/commit or range]'
---

# Post-Merge Audit

For missing required choices, follow [Skill input](../../docs/skill-input.md)
before starting the dependent work.

For Codex route preferences, consult the unmeasured `astra-pilot-v1`
[central profile](../plan-pr-batch/references/model-routing-profiles.json) through the plan skill's
`bin/model-routing-profile --role <role>`. It supersedes named GPT-5.6
recommendations below for listed roles; retain those as comparison baselines.
Routes remain advisory and never qualify a verdict or replace host evidence.
If a partial or pinned installation lacks the resolver or data, continue with
established or portable advisory routes; use the complete pack to access the pilot.

Audit merged PRs as a batch after batch work or before the next release step.
Use visible chat only to choose the obvious just-run batch default; use git,
GitHub, and coordination ground truth for every audit fact.

Keep inspection read-only until scope and authority are verified. Apply the
trusted-base [security floor](../../workflows/pr-batch-security-floor.md) before
executing branch code or taking a consequential action; an audit does not grant
implementation, publication or merge authority.

Resolve writing style before authoring human-facing prose. Run
`agent-workflow-writing-style --repo-root <trusted-repository-root> --format json`
under the canonical rules in the loaded `workflows/pr-processing.md`. Apply the
guide to audit issue bodies, GitHub comments, PR-description prose, and final
handoffs. Do not alter required audit markers, receipt fields, exact protocol
blocks, issue accounting, or evidence.

Memorable invocation:

```text
$post-merge-audit
Audit merged PRs since the last release candidate
```

Use `.agents/workflows/post-merge-audit.md` for reusable copy-paste prompts, including independent Codex/Claude audits, comparison, default issue creation, and Claude PR review handoff prompts.

The completed-batch closeout validation contract requires `pr-batch` and
`post-merge-audit` from the same Agent Workflows pack revision. This skill owns
the production receipt parser loaded by the sibling `pr-batch` contract test;
an isolated pinned copy must include both companions or stop with a precise
missing-companion blocker.

For a verified Codex GPT-5.6 batch, record the originating preferences and use
this recommended advisory route profile:

- Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)
- Simple, positively classified worker: Terra/high
- Unknown or uncertain worker: Sol/high
- Sol/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
- Independent adversarial QA: Sol/xhigh
- Routine deterministic QA: Sol/high

For a verified Claude batch, record the originating preferences and use this
provisional recommended advisory route profile (`claude-profile v1`):

- Routine multi-lane coordinator: balanced/high (`Sonnet 5/high` only when host-verified)
- Simple, positively classified worker: Sonnet 5/high
- Unknown or uncertain worker: Opus 5/high
- Opus 5/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
- Independent adversarial QA: Opus 5/xhigh
- Routine deterministic QA: Opus 5/high

When emitting a structured `review-findings` block, set `review_receipt.source`
to `post-merge-audit` and follow `docs/review-finding-schema.md`.
Populate optional receipt `provenance.model`, `provenance.effort`, and `provenance.usage` only from host-reported evidence for the actual review run.
Use literal `UNKNOWN` for unavailable values; never infer them or treat prompt text or model self-report as binding evidence.
Copy usage counters without guessing or recalculation, and do not store raw
prompt, response, or transcript data in the receipt.

<!-- stage-reference: references/scope.md -->
## Scope Gate

Before deep audit, bind the exact range, worked scope and genuinely independent checker; unknown scope or independence cannot produce a clean verdict. Read [Scope](references/scope.md) for this stage.
<!-- /stage-reference -->

<!-- stage-reference: references/checks.md -->
## Audit Checks

For the verified range, run relevant audit checks and classify findings; preserve explicit range-level structural review scope. Read [Checks](references/checks.md) for this stage.
<!-- /stage-reference -->

<!-- stage-reference: references/issues.md -->
## Issue Plan

When non-OK findings need follow-up, build a deduped issue plan; independent auditors draft and the coordinator owns authorized creation. Read [Issues](references/issues.md) for this stage.
<!-- /stage-reference -->

<!-- stage-reference: references/output.md -->
## Output

At audit handoff, load the receipt/output contract; only the coordinator publishes completed-batch receipts, and clean status needs current complete evidence. Read [Output](references/output.md) for this stage.
<!-- /stage-reference -->
