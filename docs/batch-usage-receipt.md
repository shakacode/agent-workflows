# Batch Usage Receipt v1

`batch-usage-receipt-v1` is a deterministic, privacy-safe accounting artifact
for a Codex batch. It reports host-observed token metadata for batch,
coordinator/root, lane, and worker scopes without reading those scopes from
conversation prose. The machine-readable schema is
[`batch-usage-receipt-v1.schema.json`](schemas/batch-usage-receipt-v1.schema.json).

The reporter is analytical telemetry, not billing infrastructure. A receipt is
not an invoice, charge, or authoritative provider cost, and token families must
not be compared across hosts without a documented adapter.

## Inputs

Run the helper from the loaded `pr-batch` pack:

```bash
"${PR_BATCH_SKILL_DIR}/bin/batch-usage-receipt" \
  --state-db "$CODEX_STATE_DB" \
  --manifest batch-usage-manifest.json \
  --from 2026-08-01T00:00:00Z \
  --to 2026-08-02T00:00:00Z \
  > batch-usage-receipt.json
```

The half-open window is `from <= timestamp < to`. Both window timestamps must
include `Z` or an explicit numeric UTC offset; zone-less timestamps are rejected
so local process timezone settings cannot change the selected evidence.
`state_5.sqlite` supplies
physical thread rows, rollout paths, observed host metadata, and
`thread_spawn_edges`. The helper invokes the `sqlite3` CLI read-only and selects
only those metadata columns. The JSON manifest supplies only logical batch
scope and requested routes:

```json
{
  "schema": "batch-usage-manifest-v1",
  "batch_id": "aw-example",
  "coordinator": {
    "id": "coordinator",
    "root_thread_id": "root-thread-id",
    "requested_route": {
      "host": "codex",
      "model": "gpt-example-coordinator",
      "effort": "high"
    }
  },
  "lanes": [
    {
      "id": "implementation",
      "root_thread_id": "lane-thread-id",
      "requested_route": {
        "host": "codex",
        "model": "gpt-example-worker",
        "effort": "medium"
      },
      "workers": [
        {
          "id": "maker",
          "thread_id": "lane-thread-id",
          "requested_route": {
            "host": "codex",
            "model": "gpt-example-worker",
            "effort": "medium"
          }
        }
      ]
    }
  ]
}
```

`requested_route` is an instruction and remains separate from
`observed_routes`, which comes only from `state_5.sqlite` and rollout
`turn_context` metadata. Requested host/model/effort never fills an unavailable
observed value. The reporter projects each requested route to exactly
`host`, `model`, and `effort`; extra manifest keys are ignored and never emitted.

## Scope And Reconciliation

Every scope has an explicit `scope` discriminator and stable logical `id`:

- `batch` covers the union of the coordinator tree and all lane trees;
- `coordinator` identifies the root and reports `self_only` plus
  `descendant_inclusive` usage;
- `lane` reports its root's `self_only`, the edge-derived
  `descendant_inclusive` total, named workers, and usage not attributed to a
  named worker;
- `worker` reports its own root plus any nested descendants.

The reporter walks `thread_spawn_edges`; prompt mentions, parent IDs replayed in
JSONL, and name similarity cannot create ancestry. Each physical rollout is
deduplicated by its canonical file before a scope total is computed. A repeated
session ID in a distinct file is not treated as proof that the files are the
same rollout. Its opaque `physical_rollout_id` combines the first session ID
with a deterministic logical database-thread identity for that canonical
reader; it is never derived from an absolute rollout path. Canonical-file
aliases therefore share one ID, while distinct files retain distinct IDs. The
batch reconciliation is:

```text
batch descendant-inclusive
  = coordinator self-only
  + each lane descendant-inclusive
  + batch unattributed
```

Lane `unattributed` is its inclusive usage minus the union of named worker
trees. Thus a lane root can also be its named worker without double counting.
Coordinator `descendant_inclusive` is informative and is not added again in the
batch equation.

Declared worker roots must be descendants of their lane root. If state metadata
contradicts that hierarchy, the reporter leaves evidence-derived numeric values
for the declared coordinator and lane root trees intact, marks the affected
reconciliation and top-level `evidence.status` as `UNKNOWN`, and records a
`worker_outside_lane_scope` reason. Other topology reasons are
`coordinator_root_in_lane_scope`, `lane_scope_overlap`, and
`worker_scope_overlap`. These codes mean the manifest's logical attribution is
incomplete; a numeric root-tree total must not be read as a complete
worker-inclusive batch total while top-level evidence is `UNKNOWN`.
`credit_equivalents.status` is also `UNKNOWN` for any of these topology
failures, even when the observed route counters and rate mappings permit
individual model arithmetic.

## Streaming And Replay Accounting

The helper streams one JSONL line at a time and immediately discards all fields
except whitelisted session identity, timestamp, route, compaction, and token
metadata. A physical rollout is bound to its database thread and the first
`session_meta.id`; later embedded `session_meta` records cannot rebind it. If
multiple state rows reuse one rollout path, that identity is validated against
every row before the cached physical reader is reused.

Supported Codex `event_msg/token_count` records carry cumulative
`info.total_token_usage` and per-event `info.last_token_usage`. The algorithm:

1. walks the complete physical rollout in file order;
2. differences cumulative `total_token_usage` samples;
3. derives the first delta per counter only from the first `last_token_usage`;
   when it differs from `total_token_usage`, the inherited cumulative seed is
   omitted, and a missing first-last counter becomes literal `UNKNOWN` rather
   than importing cumulative history;
4. omits copied fork history, repeated cumulative samples, and detected replay
   samples while recording separate counts;
5. records a counter reset and starts a new cumulative epoch for the entire
   counter vector when any counter decrease follows a compaction boundary; a
   copied fork boundary corroborates replay, while an uncorroborated decrease
   becomes structured `UNKNOWN`;
6. only then applies the half-open time window to each computed delta.

`last_token_usage` is never summed. Compaction markers are counted but do not by
themselves add usage or change identity. Fork, resume, copied history, and
compaction therefore remain replay-safe, while boundary-straddling windows do
not import pre-window cumulative history.

A malformed copied replay-prefix record, one without `total_token_usage`, or
one with a structurally invalid known token vector is deferred rather than
immediately invalidating the child. A later valid copied cumulative snapshot
before the fork boundary supersedes that defect and provides the needed child
baseline. If no such snapshot arrives before the boundary, the line-numbered
`malformed_jsonl`, `missing_total_token_usage`, or
`invalid_token_usage_vector` reason remains structural `UNKNOWN`.

Invalid UTF-8 rollout bytes emit a line-numbered `rollout_read_error` and make
the affected rollout structural `UNKNOWN`; they never escape as a raw parser or
JSON generator backtrace. This byte-level defect is not replay-deferrable
because it can obscure identity, boundary, or timestamp evidence.

A known token vector is structurally invalid when its reported `total_tokens`
is less than `input_tokens + output_tokens`. Either an invalid
`total_token_usage` or `last_token_usage` emits
`invalid_token_usage_vector` and makes the entire affected rollout's counter
vector `UNKNOWN`; contradictory evidence is never emitted as a known total.
Likewise, a syntactically valid JSONL value that is not an object emits the
line-numbered `non_object_rollout_record` code and conservatively invalidates
that rollout instead of being skipped.

The `accounting` object reports `usage_samples`,
`duplicate_samples_omitted`, `replay_records_omitted`, `counter_resets`,
`inherited_seeds_omitted`, `compactions`, and
`session_rebind_attempts_ignored` explicitly. These diagnostic counts cover the
complete physical rollouts used for differencing; unlike emitted usage deltas,
they are not restricted to the requested `[from, to)` window.

## Usage Counters And UNKNOWN

The five stable fields intentionally reuse the review-receipt semantics from
the [Review Finding Schema](review-finding-schema.md) where compatible:

- `input_tokens` maps the host's `input_tokens` without cache normalization;
- `output_tokens` maps `output_tokens`;
- `reasoning_output_tokens` maps the host's `reasoning_output_tokens` as its
  own counter; it is never inferred from `output_tokens` or another field;
- `cache_read_tokens` maps Codex `cached_input_tokens`;
- `total_tokens` maps the host's reported `total_tokens` and does not add cache
  reads again.

The helper does not infer absent counters. Per-sample field gaps propagate
independently per counter, so known input/output/total values remain known when
only the cache counter is missing. Structural or session-level evidence problems
conservatively make the entire affected rollout's counter vector `UNKNOWN`.
Unsupported or missing evidence produces literal `UNKNOWN` counter values plus
structured entries in
`evidence.unknown`, each with `status: "UNKNOWN"` and a stable `code`. Examples
include `state_database_unsupported`, `thread_missing`, `rollout_missing`,
`malformed_jsonl`, `non_object_rollout_record`, `missing_total_token_usage`,
`invalid_token_usage_vector`, and
`state_thread_first_session_mismatch`. Known sibling scopes remain present;
missing evidence is never silently treated as zero.

Every usage timestamp must include `Z` or an explicit numeric UTC offset.
Zone-less or otherwise invalid values emit `invalid_usage_timestamp` and
deliberately make the entire physical rollout's counter vector `UNKNOWN`. The
cumulative baseline must advance even when that sample cannot be placed before,
inside, or after the requested window; assigning or dropping only its delta
could therefore undercount or overcount every scope that reuses the rollout.

Top-level `evidence.sources` lists supported and attempted metadata source
types; it does not claim that each source was available. Source failures and
partial availability are represented by top-level `evidence.status: "UNKNOWN"`
and the corresponding structured entries in `evidence.unknown`.

## Optional Credit Equivalents

No currency or credits are inferred by default. `--rate-card PATH` accepts only
an explicit `batch-usage-rate-card-v1` document with a nonempty source, ISO date,
and exact host/model mappings:

```json
{
  "schema": "batch-usage-rate-card-v1",
  "source": "https://provider.example/rates/2026-08-01",
  "effective_date": "2026-08-01",
  "model_mappings": [
    {
      "host": "codex",
      "model": "gpt-example",
      "input_credits_per_million": 1.0,
      "output_credits_per_million": 2.0
    }
  ]
}
```

An unmapped observed model stays structured `UNKNOWN`. Every emitted
`credit_equivalents` object repeats the source/date and the non-billing
disclaimer. Credit equivalents rate `input_tokens` and `output_tokens` only;
they do not normalize `cache_read_tokens` or model provider-specific cache
pricing tiers.

## Privacy Boundary

Receipts never emit or persist prompts, responses, reasoning, tool arguments,
tool results, authentication data, secrets, environment values, working
directories, or rollout paths. The artifact contains only bounded identifiers,
route metadata, counters, window bounds, accounting counts, evidence codes, and
optional rate-card metadata. Do not attach raw rollout JSONL or `state_5.sqlite`
to a PR or durable handoff.

At batch closeout, save the JSON in the repository's ordinary durable artifact
store when one exists and put a compact total plus its durable artifact
reference in the final handoff. When usage evidence is unavailable, preserve
the receipt with structured `UNKNOWN`; usage telemetry does not override CI,
review, QA, merge, or audit gates.
