# Postmortem: Unsupported Signed-Launch Enforcement

Status: corrective implementation for [issue #299](https://github.com/shakacode/agent-workflows/issues/299)

## Summary

Agent Workflows made signed dispatcher launch confirmations and signed lane
lifecycle receipts mandatory before either supported host had a producer or a
provisioning path for the fixed trust anchors. The verifier and its generated
cryptographic fixtures worked in isolation, but a clean Codex or Claude install
could not satisfy the new evidence contract. This made an unsupported host
capability a prerequisite for otherwise valid coordinated batches.

The corrective decision is to keep model and effort as advisory preferences,
record optional host-observed metadata honestly, and use ordinary durable
pending/active and lane lifecycle state. Duplicate-launch prevention,
single-assignment ownership, idempotent replay, replacement fencing, dependency
and serialization validation, exact-head CI, merge assurance, and guarded merge
submission remain mandatory.

## Confirmed timeline

- 2026-07-30: [PR #279](https://github.com/shakacode/agent-workflows/pull/279)
  opened with multiple fail-closed batch controls. It merged on 2026-07-31 with
  9,316 additions across 23 files, including the signed-launch verifier and the
  mandatory signed lifecycle contract.
- 2026-07-31: [PR #290](https://github.com/shakacode/agent-workflows/pull/290)
  opened to add coordination telemetry and provenance. It merged on 2026-08-03
  with 1,993 additions across 18 files and carried signed host-route evidence
  into registration and activation guidance.
- 2026-08-02: [issue #299](https://github.com/shakacode/agent-workflows/issues/299)
  recorded that clean supported installs had no signer or trust-anchor
  provisioning path.
- 2026-08-02: [PR #306](https://github.com/shakacode/agent-workflows/pull/306)
  opened with an unsupported-readiness and human-waiver path. It closed without
  merge on 2026-08-07 and none of its waiver implementation is part of this
  correction.
- 2026-08-06: maintainers chose removal rather than a waiver or synthetic trust
  mechanism. Prompt compatibility moved to separate
  [issue #372](https://github.com/shakacode/agent-workflows/issues/372).

Issue #273 resumes separately after #299 removes the unsupported launch gate;
#299 does not implement or redefine #273. Track that resumed work only in
[issue #273](https://github.com/shakacode/agent-workflows/issues/273).

## Impact

- A clean Codex or Claude installation could evaluate the verifier but could
  not produce the evidence needed to activate a worker or advance serialized
  lanes.
- Ordinary coordination facts such as an explicit dispatcher selection,
  stable instance, lane owner, and durable state were insufficient even though
  no supported host could provide the additional signature.
- Operators reached a fail-closed launch blocker with no supported remediation.
  Locally generated keys, invented trust roots, and a human waiver would have
  weakened rather than repaired the host/repository boundary.
- Security, dependency, QA, CI, review, and merge controls not tied to the
  unsupported signature remained useful and are retained.

## Root cause

Confirmed root cause: a verifier became mandatory before the producer,
provisioner, and installer acceptance path existed. Agent Workflows owns a
portable workflow source pack; it does not own the Codex or Claude runtime and
therefore could not truthfully manufacture host identity evidence. The design
treated a desired host fact as if this repository could require and provision
it.

The rollout also lacked capability negotiation. Absence of signed evidence was
classified as unsafe execution instead of unsupported optional telemetry, so
the control moved directly from unit-tested schema to mandatory activation.

## Contributing factors

Confirmed:

- Unit tests generated signing keys and receipts inside fixtures. They proved
  signing and verification code agreed, not that a supported host could produce
  or provision the evidence.
- Installer tests checked copied files and metadata but did not execute a clean
  installed dispatcher and batch-plan lifecycle from end to end.
- No producer/verifier/provisioner/installer matrix was required before new
  evidence became a portable hard gate.

Inferred from the change shape:

- PR #279 combined many independent controls in a 23-file, 9,316-addition
  change. Review attention was distributed across valid security, dependency,
  QA, CI, and merge gates, making the missing producer seam less visible.
- PR #290 added another broad telemetry layer before a supported-host acceptance
  test existed, reinforcing the verifier-shaped contract instead of challenging
  its ownership boundary.
- Generated cryptographic fixtures looked stronger than ordinary state tests,
  which likely made verifier completeness appear equivalent to rollout
  completeness.

## Why review and tests missed it

The review question was effectively “does the verifier reject invalid
evidence?” The missing question was “which supported component produces this
evidence after a clean install?” Tests started downstream of the absent
producer, and review did not require a trace from producer through provisioning,
installation, activation, and replay. A green isolated verifier therefore hid
an unusable integrated workflow.

## Corrective and prevention actions

| Action | Owner | Verification |
| --- | --- | --- |
| Remove signed launch/lifecycle activation, fixed anchors, hard route binding, and waiver logic. | Agent Workflows maintainers | Dispatcher and batch-plan contract tests contain no signing dependency. |
| Preserve one active assignment, stable replay tokens, replacement fencing, single-use proofs, serialization, dependency, QA, CI, review, and merge gates. | Agent Workflows maintainers | Focused helper suites plus `bin/validate`. |
| Run unsigned lifecycle acceptance from clean Codex and Claude install trees. | Installer maintainers | `bin/install-agent-workflows-test.bash` executes both installed helpers and asserts no anchor files. |
| Require a producer/verifier/provisioner/installer matrix before any future portable evidence becomes mandatory. | Agent Workflows maintainers | The active host-adapter contract requires named ownership for all four roles and clean-install acceptance on every supported host. |
| Stage host-owned evidence as optional capability-negotiated telemetry until every supported host produces it. | Host-adapter owners | Unsupported or absent observation is field-granular `UNKNOWN` and never alone blocks execution. |
| Keep model/effort recommendations advisory while retaining independent checker and evidence-quality requirements. | Routing and audit workflow owners | Routing contract tests cover unavailable preferences and observed metadata separately. |
| Convert incompatible Codex/Claude prompts without executing task work. | [justin808](https://github.com/justin808); tracking: [issue #372](https://github.com/shakacode/agent-workflows/issues/372) | Host-prompt conversion acceptance tests, independent of route enforcement. |
| Use observed routing evidence to refine recommendations rather than gate launches. | [justin808](https://github.com/justin808); tracking: [issue #151](https://github.com/shakacode/agent-workflows/issues/151) | Calibration data distinguishes requested preferences from host-observed fields. |

## Rollout rule

A portable hard gate may depend only on facts that the source pack owns or that
every supported host can produce through a documented, installed, end-to-end
tested capability. Host-owned facts without that coverage remain optional
observations. A verifier alone is never rollout readiness.
