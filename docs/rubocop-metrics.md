# RuboCop Metrics Baseline

The repository carries a large backlog against eight default RuboCop Metrics
cops. The global disables in `.rubocop.yml` remain temporary while maintainers
split the backlog into behavior-preserving PRs. The committed
`test/fixtures/rubocop-metrics-baseline.json` prevents that debt from growing.

`bin/lint` runs the baseline check before the ordinary RuboCop pass. The helper
selects the disabled cops explicitly, uses the version in `.rubocop-version`,
and scans tracked Ruby files. For each file and cop, the baseline stores the
observed values in descending order. A check fails when a file gains an offense
or any ranked value rises, even when the number of offenses stays unchanged.
Moving a method or changing line numbers does not create noise.

## Current Baseline And Priorities

The initial RuboCop 1.87.0 baseline contains 5,702 offenses across 153 files:

| Cop | Offenses |
| --- | ---: |
| `Metrics/AbcSize` | 1,509 |
| `Metrics/BlockLength` | 294 |
| `Metrics/ClassLength` | 99 |
| `Metrics/CyclomaticComplexity` | 489 |
| `Metrics/MethodLength` | 2,779 |
| `Metrics/ModuleLength` | 41 |
| `Metrics/ParameterLists` | 89 |
| `Metrics/PerceivedComplexity` | 402 |

Prioritize production helpers before their test files, using risk and cohesion
rather than offense count alone. The largest initial production surfaces are:

| File | Offenses |
| --- | ---: |
| `bin/agent-workflow-seam-doctor` | 190 |
| `skills/post-merge-audit/bin/completed-batch-audit-receipt` | 158 |
| `skills/pr-batch/bin/merge-assurance` | 156 |
| `bin/push-downstream` | 150 |
| `skills/post-merge-audit/bin/completed-batch-publication-preflight` | 111 |

Refactor one cohesive behavior at a time. Preserve fixed argument lists,
closed environments, fail-closed checks, portable installation, and real
process-boundary tests.

## Check And Refresh

Run the ratchet directly while working:

```bash
bin/rubocop-metrics-baseline check
```

When a reviewed refactor reduces metrics, refresh the committed profile:

```bash
bin/rubocop-metrics-baseline refresh
bin/rubocop-metrics-baseline check
```

Inspect the JSON diff before committing it. A refresh should record the intended
reductions and must not be used to accept unrelated increases. The helper emits
the exact file, cop, rank, old value, and new value when a check fails.

After a cop has no remaining entries, remove its global `Enabled: false` block
from `.rubocop.yml` in the same PR. Continue until every default Metrics cop is
enabled. Do not change upstream thresholds to make the baseline pass.
