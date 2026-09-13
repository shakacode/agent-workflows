# Delivery Policy: Integration And Promotion

Status: supported wrapper and reporting contract. Verification, CI selection,
review preparation, and closeout consume repository-owned commands and their
coverage reports. Adoption does not enable a preset or change existing
repositories' validation behavior automatically.

A repository can give contributors quick integration feedback while reserving
its complete suite for release or deployment promotion. The choice depends on
what the project does, who a defect affects, and the changed behavior. A short
runtime or a small diff alone does not establish low risk.

## Start With The Existing Command Seam

Read the repository's `AGENTS.md`, `.agents/bin/README.md`, and
`.agents/agent-workflow.yml`. The executable `.agents/bin/validate` wrapper
already owns the pre-commit/pre-push gate. Customize that wrapper and its
documented checks before adding configuration. An optional
`.agents/bin/ci-detect` can explain selection; its absence does not require a
new detector. Commands stay in wrappers, and shared skills use the documented
entry points.

Record the project's type, collaborator impact, integration checks, complete
promotion checks, and repair owner in the repository's policy documentation.
Use the existing `ci_change_detector` policy notes and `AGENTS.md` seam to point
to the routing contract. Do not infer behavior from a project label. The
repository's command table must identify the exact invocation for the complete
suite; flags such as `--all` exist only when that wrapper documents them.

No new shared YAML key, resolver, universal budget, or executable profile is
introduced. `fast`, `balanced`, and `strict` are provisional
explanatory aliases for a discussion about checks. They confer no selection or
merge authority.

## Select Coverage For The Change

The default remains the repository's existing validation behavior. A trusted
repository policy may allow a selected integration suite for a recognized
change. Keep mandatory lint, trust, independent review, and current integration
identity checks. A selector must explain what ran and what it omitted.

Use the trusted base's policy and selector to assess a candidate. Changes to
that policy, the selector, tests, build or release machinery, security-sensitive
behavior, or other repository-declared broad surfaces require complete
coverage. Unknown files, missing base/head identity, malformed supplied policy,
or an uncertain classification cannot opt into reduced coverage. Run the
complete gate when it is known and safe; otherwise report the blocking input
instead of claiming success.

Ordinary prose can qualify for a repository's documentation checks. Markdown
containing changed executable examples, inline commands, routing instructions,
or other operational contracts is not ordinary prose merely because of its
extension. Each repository owns the narrow allowlist and escalation rules.

| Project and collaborator impact | Recognized integration change | Broader change or promotion |
| --- | --- | --- |
| Shared development tool with a small internal audience and easy rollback | Ordinary user-guide prose may run mandatory lint and documentation checks, with omitted runtime suites named. | Installer, ownership, security, or policy changes run the complete suite. A distributed release requires complete candidate evidence. |
| Production-critical service whose failures affect customers or durable data | Even the same user-guide edit may require the complete integration suite under the repository's policy. | Runtime, access, data, and deployment changes retain complete checks and the configured runtime gate. Promotion requires complete candidate evidence. |
| Discovery service used by a limited experiment group | Isolated presentation or prose work may use focused checks while recording the limited audience and tested boundaries. | Shared data, credentials, external side effects, or expanding access require broader coverage. Promotion to a supported service requires the complete configured suite. |

These are examples of different repository decisions, not portable thresholds.
The same change can select different checks in two repositories without
weakening either repository's required gate.

## Report Evidence Without Upgrading Its Meaning

The minimal portable interface keeps execution in `.agents/bin/validate` and
optional routing inspection in `.agents/bin/ci-detect`. The command table names
the complete promotion invocation. Verification, review, and closeout report:

- phase: integration or promotion;
- candidate head and any base/integration identity relevant to the selection;
- coverage: selected or full, relative to the configured complete suite;
- required checks and each result;
- omitted checks and the selection reason, or none when coverage is full.

This is a reporting contract, not a new receipt format or command-line API.
Exit zero from a selected command means its selected checks passed. It never
establishes complete coverage. An interrupted run, a dirty-tree skip, or a
resource budget cannot convert missing checks into a successful complete gate.
Every failed required check stays failed until it passes; reclassification,
escalation, or a smaller budget cannot remove that failure.

Reuse unchanged, applicable evidence under the existing
[verification evidence rules](../skills/verify/references/verification-evidence.md).
A lifecycle transition alone does not invalidate evidence. Changes to the
candidate, relevant base, policy, command, dependencies, or environment may do
so. Selected evidence cannot stand in for the unexecuted parts of a complete
promotion gate.

## Complete Feedback And Promotion

Repositories that select integration checks must provide complete feedback on
the integrated mainline and name who repairs failures. When that full run
fails, identify the affected revision and check, assign a repair or authorized
revert, and keep the candidate unqualified for promotion until the required
checks pass. Do not leave repair ownership implicit in a green selected PR.

Before publishing a release, promoting a candidate, or deploying under a
configured promotion gate, require the complete configured suite for the exact
candidate. Preserve independent review and any configured hosted runtime gate.
If the candidate changes after validation, re-evaluate evidence applicability;
a green ancestor or different merged tree is not proof for the new candidate.

Task merge authority is separate from release and deployment permission.
An `auto` task may merge when its current gates and existing authority permit;
an `ask` task requests the required merge decision. Preserve existing `none`
authority where configured. These descriptions do not introduce new authority
values. None of them grants permission to tag, publish, promote, or deploy.
Resolve those actions from the repository's separate
[release policy](release-branching.md) and the user's authorization.

A fork can synchronize to a verified upstream release tag under its own sync
policy. Verify the tag's source and exact commit and the upstream release
qualification required by that policy. Upstream evidence applies to that
upstream candidate: additional fork modifications need the fork's own checks,
and fork promotion still requires complete evidence for the modified candidate.

## Adoption Proof

The [executable repository examples](../examples/delivery-policy/README.md)
replay the same ordinary documentation change through a low-impact tool's
selected checks and a critical service's complete suite. Their focused replay
also covers risky and unknown changes, trusted-base policy edits, promotion,
legacy behavior without opt-in, and required failures at the existing retry
boundary. Checks execute actual sample commands; no cost saving or production
adoption is claimed. Keep repository commands and selection logic in those
wrappers rather than a second shared routing framework.
