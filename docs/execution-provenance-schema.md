# Execution Provenance Schema

Execution-provenance receipts record what executed in one lane and which
commits that execution influenced. The versioned schema string is
`execution-provenance-v0`.

The receipt is deliberately narrow. It records route, host, identity, timing,
and commit-attribution facts; it does not evaluate model quality, recommend a
route, or define aggregation semantics.

## Example

````markdown
```json execution-provenance
{
  "schema": "execution-provenance-v0",
  "execution_provenance": {
    "batch": "aw-20260811-i333-plan-v1",
    "lane": "aw-i333",
    "target": "https://github.com/shakacode/agent-workflows/issues/333",
    "scenario_class": "schema-and-validator",
    "role": "implementation",
    "route_policy": "exact-route",
    "requested": {
      "model": "gpt-5.6-sol",
      "effort": "high"
    },
    "observed": {
      "model": "gpt-5.6-sol",
      "effort": "high"
    },
    "dispatcher": "codex",
    "binding_source": "host-session-metadata",
    "host": {
      "executable": "codex",
      "version": "1.2.3"
    },
    "session_id": "019ff563-3cb2-76a1-ae51-101c843deaa2",
    "thread_id": "UNKNOWN",
    "started_at": "2026-08-11T10:00:00-10:00",
    "ended_at": "2026-08-11T10:30:00-10:00",
    "influenced_commits": [
      "0123456789abcdef0123456789abcdef01234567"
    ],
    "attribution_confidence": "exact",
    "mismatch_reason": "UNKNOWN",
    "recorded_authority": "UNKNOWN",
    "disposition": "bound-exact-match"
  }
}
```
````

## Receipt Contract

Every field in `execution_provenance` is required:

- `batch`, `lane`, and `target` identify the execution lane and its canonical
  target. `scenario_class` names the caller's stable task class without adding
  evaluator or recommendation semantics.
- `role` is `implementation`, `review`, `QA`, or `integration`.
- `route_policy` is `exact-route`. This version encodes the exact-route table;
  it does not invent behavior for advisory requests.
- `requested.model` and `requested.effort` name the exact requested tuple.
  They are instructions, not evidence.
- `observed.model` and `observed.effort` are separate host-observed facts. Each
  component must be present. When host evidence is unavailable, both are
  literal `UNKNOWN`; they are never copied or defaulted from `requested`.
- `dispatcher` records the dispatcher, while `binding_source` is
  `host-session-metadata`, `structured-command-result`,
  `structured-api-result`, or `UNKNOWN`. A known observed tuple requires one of
  the three host/structured sources; an `UNKNOWN` tuple requires an `UNKNOWN`
  binding source. Prompt text and model self-report never establish binding
  observed evidence.
- `host.executable` and `host.version` record the executing host program.
  `session_id` and `thread_id` separately preserve either host identifier; use
  literal `UNKNOWN` when a host does not expose one.
- `started_at` and `ended_at` are RFC 3339 timestamps. The end cannot precede
  the start.
- `influenced_commits` is an array of full 40- or 64-character hexadecimal Git
  object IDs. `attribution_confidence` is `exact`, `timeline-derived`, `mixed`,
  or literal `UNKNOWN`. Known confidence requires at least one commit; unknown
  confidence requires an empty list.
- `mismatch_reason` records why an exact request was not satisfied, or literal
  `UNKNOWN` for `bound-exact-match`. `recorded_authority` names the authority
  recorded before an authorized fallback, or literal `UNKNOWN` otherwise.
- `disposition` is one exact case from the model-routing disposition table:
  `bound-exact-match`, `unbound-exact-route`, `silent-substitution`,
  `coordinator-pair-inheritance`, or `authorized-fallback`.

## Fail-Closed Rules

Literal uppercase `UNKNOWN` is the only unavailable sentinel. Lowercase,
mixed-case, surrounding-whitespace, and Unicode NFKC look-alikes are rejected;
do not normalize them into validity.

Under `exact-route`, an `UNKNOWN` observed tuple is valid only as
`unbound-exact-route`, never as a satisfied disposition. A bound exact match
requires the observed tuple to equal the requested tuple. Substitution,
coordinator-pair inheritance, and authorized fallback require a different,
known observed tuple and a non-`UNKNOWN` mismatch reason.

`authorized-fallback` additionally requires non-`UNKNOWN` recorded authority.
Without recorded authority, a different observed tuple is
`silent-substitution`; it must not be presented as an authorized fallback.

Validate a JSON receipt or this document's example with:

```bash
bin/validate-execution-provenance path/to/receipt.json
bin/validate-execution-provenance
```
