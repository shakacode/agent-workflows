# Verification evidence reuse

## Delivery coverage

Resolve integration versus promotion from the task and trusted repository
policy. Read `AGENTS.md`, `.agents/bin/README.md`, and existing
`.agents/agent-workflow.yml` notes: wrappers own required checks,
`review_gate` owns review requirements, and `hosted_qa_gate` owns broader
hosted QA. Use the documented complete invocation for promotion; there is no
portable fast/full flag or effort preset. Omission preserves existing behavior.

Only trusted-base policy may select reduced integration coverage. Execute the
trusted-base selector or an equivalently protected repository entry point;
reading trusted policy and then executing a candidate-controlled selector is
insufficient. If no protected selection path exists, use a known, safe complete
invocation or preserve the blocking input. Policy,
selector, tests, security, build/release changes, unknown paths, or uncertain
identity/classification require complete coverage when that command is known
and safe; otherwise preserve the blocking input. Invalid supplied policy
cannot opt into reduced coverage. Keep mandatory lint, independent review,
security, and current integration/CI evidence.

Across verification, review preparation, and closeout, carry the phase,
candidate and relevant base/integration identities, selected/full coverage,
required checks and results, omitted checks, and selection/escalation reason.
This is ordinary reporting, not a new receipt schema. Exit zero establishes
only the checks that ran. Existing retry and review stopping rules keep their
counts and disposition; reaching a budget never waives failed or unresolved
required checks. Selected evidence cannot qualify omitted promotion checks,
and merge authority never grants release or deployment permission.

## Reusing a local result

Use one durable local command result across verification, autoreview preparation,
and PR closeout when its applicability is unchanged. This reduces repeated work;
it does not waive verification or establish merge readiness.

Before reuse, the coordinator verifies the original command/log and current git
state from trusted local evidence. Bind each passing result to the full commit
and base SHAs, clean working tree, exact command argv (including working-directory
context in the environment identity), relevant configuration fingerprint, runtime
and dependency/environment identity, and covered paths. Record an evidence
reference; do not copy raw prompts, secrets, or environment variable values.
A referenced log or caller-supplied fingerprint alone is not proof of applicability.
External service, fixture, or toolchain changes belong in the environment identity;
if they cannot be established, use `UNKNOWN` and rerun.

A changed head or base invalidates reuse, even if someone claims the tree is
identical. Changed inputs, covered paths, command, configuration, dependencies,
environment, or dirty work invalidate affected results. The helper deliberately
requires an exact match rather than inferring independence of changed paths.
Mutable pre-commit results remain useful diagnostic evidence but cannot qualify
for this helper's clean committed reuse. A failed, missing, partial, or unknown
result must not be relabeled as passing.

Run the `bin/verification-evidence-reuse` helper adjacent to this skill with a
JSON object on stdin: `version: 1`, `repeat_required: true|false`, `current`, and
`evidence`. Both contexts contain `head_sha`, `base_sha` (full SHA-1 or SHA-256
object IDs: 40 or 64 lowercase hex digits, with the same format for head and base),
`environment`, `configuration` (nonempty verified identifiers), `command`,
`covered_paths` (nonempty string arrays), and `working_tree: "clean"`. Evidence
also contains `kind: "local-command"`, `outcome: "pass"`, and `evidence_ref`.
The coordinator obtains `repeat_required` from repository policy for the current
stage; unknown policy is not `false`. The helper compares evidence only, performs
no commands or network access, and authenticates neither the log nor its author.
Exit 0 / `reusable` permits consuming that local result; exit 1 / `rerun` requires
a fresh check or resolution of the missing facts. Read its reason before acting.

Always honor repository-required repeats, including pre-commit validation,
clean committed full validation, and combined-tip checks. A focused or partial
run cannot replace a full required run. Hosted CI must qualify for the current
head under the existing CI contract; independent review must separately qualify
under its review contract. Neither is reusable through this helper. Once the
applicable required checks pass, continue the authorized outcome; add tests or
rerun suites only for relevant changes, failures, unresolved concerns, or an
explicit repository requirement.
