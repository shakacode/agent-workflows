# Astra routing and behavior pilot

The `astra-pilot-v1` profile is an advisory starting point, not a measured winner.
The [routing data](../skills/plan-pr-batch/references/model-routing-profiles.json)
is the source of its role preferences. Resolve it before choosing workers:

```sh
skills/plan-pr-batch/bin/model-routing-profile --role diagnosis
```

Roles include `architecture`, `integration`, `difficult-review`,
`uncertain-worker`, `difficult-recovery`, `adversarial-review`,
`bounded-implementation`, `routine-coordination`, and `deterministic-work`.
The resolver produces a requested preference and separate unknown observations;
it does not inspect a host, launch agents, or approve an action. Keep proven
bounded routes and use deterministic helpers for mechanical work. An unavailable
preferred route alone never blocks a lane. Independence, scope, authority and
current-head evidence still qualify reviews.

If a partial or pinned installation lacks the resolver or central data, continue
with established or portable advisory routes and record the unavailable pilot.
Missing optional profile assets do not block ordinary work or invalidate an
independent review. Use the [complete pack installation](installation-and-upgrades.md)
to access the pilot; do not duplicate its data into an isolated skill.

The central file also owns the established planning table used for comparison.
Legacy Sol/Terra and Claude prose and historical replay fixtures remain baseline
evidence. The pilot supersedes their named Codex preferences for its listed roles.
The prompt-size checker consumes that data for table consistency, but no longer
owns named planning preferences or checks named coordinator prose as a size rule.

Astra API efforts currently include `low`, `medium`, `high`, `xhigh`, and `max`.
A host may expose different choices, including `ultra`; that does not establish
API support. Check the actual runtime roster before requesting a pair. Optional
host metadata remains field-granular `UNKNOWN` when unavailable. These distinctions
follow the [Astra model reference](https://developers.openai.com/api/docs/models/gpt-6-astra)
and [prompting guidance](https://developers.openai.com/api/docs/guides/latest-model).

## Run a comparison

The helper is an offline adjudication and reporting path. It does not execute
models or judge free-form transcripts. A human or independent reviewer runs the
same scenarios on the chosen host, records evidence, and classifies behavior.
Unit tests prove input/report behavior only; they provide no model-quality result.
The short scenarios are decision probes, not end-to-end task evidence. Hide
`expected_action` from the trial agent. Supply the baseline or revised skill text
and identical task/tool state; have an independent reviewer inspect actual actions
and trace evidence before choosing a label. Label agreement alone cannot prove
persistence, fewer tool calls, or reduced interruptions in real repository work.
Use representative end-to-end tasks as additional evidence before promotion.

```sh
skills/plan-pr-batch/bin/evaluate-workflow-behavior --template > trials.json
# Run scenarios on the host and fill the applicable trial metadata and outcomes.
skills/plan-pr-batch/bin/evaluate-workflow-behavior trials.json > report.json
```

The generated template contains each scenario in three comparison variants:
`astra-current`, `astra-revised`, and `established-route`. Keep the current and
revised skill commits explicit, use the same scenario digest, task class, initial
context and tool availability, and repeat trials with unique IDs. Record context
and host setup in the adjudication evidence referenced by `evidence_ref`. Keep
private transcripts outside this metadata file and outside workflow telemetry.
If a scenario is not run, leave `status: unexecuted` and outcome fields `UNKNOWN`.
If a run has missing observations, retain exact `UNKNOWN`; never substitute zero.
The report counts submitted trials and separately marks missing scenario/variant
combinations in `coverage`. Partial comparisons are allowed and remain visible.

For each executed trial supply the actual skill commit, independent adjudication
reference, classified `action`, completion, human interruptions, boundary failures,
review-fix cycles (`review_churn`) and elapsed wall-clock seconds. Valid action
labels are in the [scenario set](../skills/plan-pr-batch/fixtures/astra-behavior-scenarios.json).
`behavior_result` checks the classified action against the expected action; it
cannot establish that a reviewer classified the actual run correctly. A wrong
action produces `false`, while unadjudicated behavior produces `UNKNOWN`.

Keep `requested` and `observed` routes separate. Known observations require a
`provenance_ref` pointing to host evidence under the existing
[execution-provenance contract](../workflows/pr-processing.md). Route mismatches
and missing observations remain unmeasured; they do not become failed workflows.
An eligible route row establishes metadata comparability only, not causal evidence
that the model or skill change improved performance.

For observed usage, generate the existing `batch-usage-receipt-v1` receipt using
`skills/pr-batch/bin/batch-usage-receipt` and its documented manifest. Use the trial
ID as its batch ID, scope the receipt to that trial, then set `usage_receipt` to its
path relative to the input file. The report copies only allowlisted descendant
usage counters, preserving unknown counters, and rejects a mismatched batch ID.
The reporter does not authenticate receipts; retain their original provenance for
independent review. Unavailable receipt support leaves usage `UNKNOWN`. Reuse
existing workflow telemetry for phase/queue analysis instead of collecting private
model content or adding another telemetry pipeline.

Compare rows with matched conditions before aggregating; inspect boundary failures
and completion before costs or time. The report deliberately supplies no automatic
winner or promotion decision. This bounded pilot does not replace the broader
evaluation-runner work tracked in #335. Token counts or API pricing do not imply
equivalent Codex subscription savings; see [Codex usage guidance](https://learn.chatgpt.com/docs/pricing).
