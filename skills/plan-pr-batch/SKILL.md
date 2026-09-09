---
name: plan-pr-batch
description: Use when choosing GitHub issues or PRs for a PR batch, recommending and grouping worker lanes by model/reasoning-effort assignment, preparing a subagent batch plan, or producing a ready goal prompt that invokes pr-batch.
argument-hint: '[issue/PR numbers, labels, milestone, or search query]'
---

# Plan PR Batch

For missing required choices, follow [Skill input](../../docs/skill-input.md)
before starting the dependent work.

For new Codex planning, resolve the advisory `astra-pilot-v1` profile from
[central routing data](references/model-routing-profiles.json) with the plan skill's
`bin/model-routing-profile --role <role>`. Its named preferences supersede the
GPT-5.6 recommendations below for the listed roles; those recommendations and
planning tables remain the established comparison baseline. Keep explicit user
routes, verified host support, portable fallback, and independent evidence rules.
This is an unmeasured pilot, not a measured promotion.
If a partial or pinned installation lacks the resolver or data, continue with
established or portable advisory routes; use the complete pack to access the pilot.

Create verified scope and a goal prompt for `$pr-batch`. Do not implement items here.

If the request is vague feature or bug intent, use `$spec` first to produce requirements, design, and tasks before planning the batch.
If the user asks to continue PR-batch closeout from a pasted handoff,
final-bucket table, PR URLs, or GitHub shorthand refs, route to `$pr-batch`
instead of turning the handoff into broad discovery. When a saved handoff
explicitly requests model-route replacement or identifies workers on a wrong or
too-expensive route, use the canonical
[Model-Routing Recovery Prompt](../../workflows/pr-processing.md#model-routing-recovery-prompt).
`MODEL_REPLACEMENT_HANDOFF` alone does not prove whole-batch route recovery. If
the visible request is to resume that worker or lane, use
[Bounded Status Recovery](../../workflows/pr-processing.md#bounded-status-recovery);
otherwise continue classifying the handoff and use generic closeout when that is
what the request asks for.
Otherwise use the canonical
[Generic PR-Batch Continuation Prompt](../../workflows/pr-processing.md#generic-pr-batch-continuation-prompt)
in the installed `pr-processing.md` workflow.

If the user is asking whether existing PRs are ready to merge, what manual
testing remains, or how to sequence open PR merges, use the target repo's
`AGENTS.md` **Agent Workflow Configuration** pointer to resolve
`.agents/agent-workflow.yml` when present, then read the policy keys the
readiness workflow requires, including `review_gate` and `merge_ledger`. If the
repo documents workflow configuration inline, read the full `AGENTS.md`
**Agent Workflow Configuration** section, including `Review gate` and the other
policy values the readiness workflow asks for. Use the repo-local
`pr-processing.md` readiness workflow when present or the installed/shared
`pr-processing.md` fallback instead of producing an implementation batch plan.
If a required policy value cannot be resolved but `pr-processing.md` can,
continue with that workflow's **Merge Readiness Gate** and report that policy
value as `UNKNOWN`; do not invoke `$pr-batch` as a substitute for reading the
readiness workflow. If the workflow cannot be resolved, report workflow state as
`UNKNOWN` rather than guessing.

If a skill picker only exposes installed/global skills, treat this skill as an
entry point. After fetching, prefer repo-local `.agents/skills/...` and
`.agents/workflows/...` files when they exist; otherwise use the installed
shared files adjacent to this skill.

When helper scripts need a `*_SKILL_DIR`, resolve it in this order: explicit
environment variable; the loaded skill's base directory when the host exposes
it; repo-local `.agents/skills/<skill>`; then stop with a precise blocker if the
helper is still missing.

For a verified Codex GPT-5.6 host, use this recommended exact profile while
keeping provider-neutral classes for other runtimes:

- Default single-target future coordinator: Sol/high
- Affirmatively simple single-target future coordinator: Terra/high
- Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)
- Simple, positively classified worker: Terra/high
- Unknown or uncertain worker: Sol/high
- Sol/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
- Independent adversarial QA: Sol/xhigh
- Routine deterministic QA: Sol/high

For a verified Claude host, use this provisional recommended exact profile
(`claude-profile v1`):

- Default single-target future coordinator: Opus 5/high
- Affirmatively simple single-target future coordinator: Sonnet 5/high
- Routine multi-lane coordinator: balanced/high (`Sonnet 5/high` only when host-verified)
- Simple, positively classified worker: Sonnet 5/high
- Unknown or uncertain worker: Opus 5/high
- Opus 5/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
- Independent adversarial QA: Opus 5/xhigh
- Routine deterministic QA: Opus 5/high

<!-- stage-reference: references/intake-and-routing.md -->
## Planning-Pass Route Assessment

Before shaping lanes, resolve scope, trusted intake and routing observations; unresolved required facts remain UNKNOWN. Read [Intake and routing](references/intake-and-routing.md) for this stage.
<!-- /stage-reference -->

<!-- stage-reference: references/lane-plan.md -->
## Lane Plan

After verified intake, construct lane/dependency/path evidence and run the planning preflight before dispatch. Read [Lane plan](references/lane-plan.md) for this stage.
<!-- /stage-reference -->

<!-- stage-reference: references/handoff.md -->
## Handoff

After the lane plan passes, produce its requested handoff or explicitly authorized launch; planning alone never authorizes implementation. Read [Handoff](references/handoff.md) for this stage.
<!-- /stage-reference -->

<!-- stage-reference: references/prompt-template.md -->
## Goal Prompt for pr-batch

Only when producing a goal prompt, load the exact template and measure the actual filled fence. Read [Goal template](references/prompt-template.md) for this stage.
<!-- /stage-reference -->

## Completion

Deliver the verified plan and requested handoff after preflight, or the exact
unresolved input/dependency with its next owner. Planning alone does not dispatch
implementation. An already authorized launch continues through `$pr-batch`.

## Common Mistakes

- Do not infer PR vs issue from a bare number.
- Do not broaden a continuation handoff into all open PRs, labels, milestones,
  or inferred related work; use only exact visible refs or ask for the target list.
- Do not batch unrelated risky changes just because they are small.
- Do not hide missing GitHub data; say `UNKNOWN`.
- Do not guess file paths; record unverifiable paths as `UNKNOWN` and treat that
  item as serial.
- Do not run full issue path discovery for items that will schedule serially
  anyway; a single-item batch, a user-requested serial run, a host cap of 1, or
  an issue with no explicit paths all go straight to a serial lane as `UNKNOWN`.
- Do not omit links; use GitHub URLs for every item.
- Do not put full audit evidence in the goal prompt; put bulky details in the Batch Plan outside the goal.
- Do not turn file overlap into an inferred dependency; record it as an integration advisory and preserve issue-authored semantic ordering.
- Do not use installed Codex/Claude homes as proof of the current runtime host;
  use an explicit target or fall back to `generic` sizing when detection is
  ambiguous.
- Do not choose a cheaper model from task size alone; ambiguity, risk, blast
  radius, reversibility, and validation difficulty can force a stronger model
  and more effort.
- Do not treat model grouping as lane grouping; collate the plan by exact pair
  without combining ownership or weakening dependencies and active-reservation
  coordination.
- Do not eyeball the goal-prompt length; apply the Output-section size gate and split Codex prompts into smaller goals if they are over budget.

## Self-Check

After editing this skill's goal prompt rules or template, run:

```bash
AGENT_WORKFLOWS_SOURCE_CHECKOUT=1 ruby skills/plan-pr-batch/scripts/check_goal_prompt_size.rb
```
