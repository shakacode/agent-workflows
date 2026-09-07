### Single-Target Launch

When no planner/triage handoff supplies dependency artifacts, synthesize and
persist a verified one-lane `stage-dependency-plan` v1 file with a known plan id
and `edges: []`, plus a `stage-dependency-gate` v1 live replay: use the actual
target/lane id, current full head/base SHAs, and already bound maker/checker
identities. Do not infer or placeholder-fill any fact. Missing or `UNKNOWN`
facts remain fail-closed and stop before mutation.

- **Issue**: use the issue number as the coordination target.
- **PR**: use the PR number, fetch live PR state, and update its verified head
  branch instead of creating a competing branch unless a maintainer requests one
  or the verified head branch cannot be pushed. For an unpushable head, create a
  replacement branch/PR and document the original PR, limitation, and rationale.
- **Trusted overridden ad-hoc task only**: after the Canonical Launch Target
  Gate accepts the durable override, reuse the accepted exact `target.target` value unchanged as the coordination target.
  Never derive, rename, or regenerate it after preflight.
  Use its already accepted repository-qualified stable coordination identity unchanged and preserve the user's original wording plus override provenance
  in the PR body or no-PR evidence.
- **Worker shape**: when the host supports isolated subagents, dispatch one
  worker subagent for the lane and keep the parent as coordinator and closeout
  owner. Do not have the parent silently implement the lane. If the host lacks
  subagents, disclose the inline single-worker fallback and apply every same
  gate; stop instead when the user explicitly required a subagent.
- **Model/effort route**: use the canonical cost-aware staged routing from
  `pr-processing.md`. Start on the fastest or balanced worker route justified by
  ambiguity, risk, blast radius, reversibility, and verification difficulty—not
  merely the cheapest model—and require the canonical evidence before a stronger
  route or replacement.
  Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit.
  Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report.
  Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict.
  Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route.
  A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict.
  Named coordinator and worker models, efforts, and route classes are recommendations; no named route is a prerequisite for planning, launch, coordination, execution, escalation, or fallback.
  When a preferred route is unavailable, different, inherited, or `UNKNOWN`, use the closest available route or runtime default, record requested and host-observed fields honestly, and continue unless an independent risk, scope, evidence, or authority gate blocks.
  Risk classification, execution-envelope requirements, and stop or return conditions depend on lane ambiguity, scope, security, consequence, and verification strength, not on model identity.
  Require an execution envelope when lane risk or bounded delegation requires one; approval is role-based and never requires a named model.
- **Recommended Codex GPT-5.6 profile**: apply only after verifying the exact
  routes on the actual host; portable classes remain the fallback elsewhere.
  - Routine multi-lane coordinator: balanced/high (`Terra/high` only when host-verified)
  - Simple, positively classified worker: Terra/high
  - Unknown or uncertain worker: Sol/high
  - Sol/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
  - Independent adversarial QA: Sol/xhigh
  - Routine deterministic QA: Sol/high
- **Provisional Claude profile** (`claude-profile v1`): apply only after
  verifying the exact routes on the actual host; portable classes remain the
  fallback elsewhere.
  - Routine multi-lane coordinator: balanced/high (`Sonnet 5/high` only when host-verified)
  - Simple, positively classified worker: Sonnet 5/high
  - Unknown or uncertain worker: Opus 5/high
  - Opus 5/xhigh exception: pinned high-risk trigger, bounded plan challenge, repeated credible failures, or evidence-backed `MODEL_ESCALATION_REQUEST`
  - Independent adversarial QA: Opus 5/xhigh
  - Routine deterministic QA: Opus 5/high
- **Batch plan preflight**: before dispatcher selection or worker launch, run
  the resolved plan skill's `bin/batch-plan-preflight` with a v1 envelope. It
  owns schema and launch scheduling, including the required active wave and
  max-one serialization. Preserve real PR verified `pr-file-touch-map` results
  unchanged; encode explicit pre-PR paths as typed `planned-path-evidence` v1
  records with durable evidence references. An `issue` source must bind to the
  target's exact repository and number through `issue://OWNER/REPO/N` or an
  exact lowercase-host `https://github.com/OWNER/REPO/issues/N` reference;
  both reject userinfo and query, HTTPS requires port 443, `issue://` requires
  the exact canonical authority/path shape, and fragments remain permitted;
  other source kinds prove durability only and do not invent target identity.
  After an issue or trusted ad-hoc lane opens its implementation PR, keep the original canonical target unchanged and replace planned-path evidence with the lane-keyed verified PR file-touch map; its repository must match the target, while a PR-origin target also requires the exact target PR number.
  Optional additive
  `expansion_path_reservations` entries use exact
  `expansion-path-reservation` v1 records bound to the batch, dependency plan,
  known lane, and wave, with one canonical path, known reason, and durable
  evidence reference. A directory rename instead uses an exact
  `expansion-rename-reservation` v1 record with the same identity, reason, and
  evidence fields and a canonical, distinct `rename` old/new pair in place of
  `path`. Presence means active and omission means cancelled. Reject malformed,
  `UNKNOWN`, noncanonical, duplicate, mismatched, completed-lane, or
  already-reflected reservations. Collision and risky-cap decisions use verified
  paths plus active reservations. Scalar path reservations remain exact-only;
  typed rename reservations add ancestor/descendant collision checks at both
  endpoints. Reservation-derived overlap requires explicit max-one
  serialization. A rejection launches nothing; an acceptance permits only the
  returned eligible lanes.
- **Dispatcher capability preflight**: before launch, pass the requested
  route preference/dispatcher, explicit dispatch authority, ordered candidates,
  and preserved lane state to `bin/dispatcher-capability-preflight`. It records
  the preferred dispatcher or first explicitly authorized dispatcher fallback; it never launches or
  mutates coordination. Each viable candidate includes a stable prospective `instance_id` allocated or reserved by its dispatcher before launch, only for replay/fencing; the helper neither launches nor creates a worker. An `UNKNOWN` prospective instance is unusable. `selected` resumes Goal mode; `blocked-user-input`
  carries one `dispatch-decision-request v1` with canonical viable fallback choices and stops.
  Replay identity is `lane_id`, dispatcher, `instance_id`, and launch token; route preference, observed host fields, and `candidate_index` are metadata and never trigger replacement.
  Persist `launch-pending` before worker launch; after spawn, persist ordinary `active` state before Goal-mode resume, and replay the same token while pending or emit no new launch while active.
  Assignment activation uses ordinary durable lifecycle state; no project signing key, fixed trust anchor, launch-confirmation receipt, or human waiver is required.
  A dispatcher or instance change still requires stop/reconcile replacement fencing and a single-use proof bound to the exact prior and replacement assignment identities.
  Same-lane worker/model replacement is a nonterminal claim reassignment or supersession operation; it must never emit a terminal lane closeout. Before consuming replacement proof, preserve and verify known `status`, `terminal`, `closed_at`, and `pr_state`; missing or `UNKNOWN` terminal facts fail closed, and a truly terminal lane requires reconciliation or explicit replanning instead of replacement. The first terminal event remains immutable: later authenticated completion may reconcile an `abandoned` lane or a `superseded` issue with typed no-PR evidence, but code-bearing completion after terminal `superseded` is a premature terminal supersession / replacement protocol violation.
- **Merge authority**: resolve `merge_authority` before worker launch. Use a
  visible user instruction, an explicit `AGENTS.md` rule, or a resolved batch-plan instruction; otherwise ask
  for `none`, `ask`, or `auto_merge_when_gates_pass`. `ask` includes an
  [automatic GitHub-native exact-diff walkthrough](../../../workflows/pr-batch-integration-closeout.md#ask-merge-authority-walkthrough-gate)
  before the one final merge decision. Do not silently default it.

The single lane still gets a Lane Card, claim/heartbeat behavior when configured,
a one-row file-touch map, a Batch QA Lane decision, current-head review and CI
checks, and the canonical terminal state and handoff evidence.

Resolve the target repo's `base_branch` from `.agents/agent-workflow.yml` when present, otherwise from the `AGENTS.md`
**Agent Workflow Configuration** seam. If neither declares it, report
`base_branch: UNKNOWN` and stop before branching. Run
`git fetch --prune origin <base-branch>`, then use the
repo-local `.agents/workflows/pr-processing.md` when present or the installed
`../../workflows/pr-processing.md` as the deeper operating model for each issue,
PR, review-fix pass, or merge-readiness item. If the target scope is not
verified yet, use the installed or repo-local `plan-pr-batch` skill first.
When invoking this skill's helper scripts, resolve `PR_BATCH_SKILL_DIR` in this
order: explicit environment variable; the loaded skill's base directory when the
host exposes it; repo-local `.agents/skills/pr-batch`; then stop with a precise
blocker if the helper is still missing.
For release-mode coordination, auto-merge confidence, shared release trackers,
production deployment or promotion, publishing, release rollback, or other
explicit release work, load the resolved
`pr-production-release.md`: prefer the repo-local
`.agents/workflows/pr-production-release.md` when present; otherwise use the
installed workflow from the same Agent Workflows pack as the loaded `pr-batch`
skill, not relative to a potentially repo-pinned processing override. Follow the
consumer repo's `AGENTS.md` release policy. Do
not restate the component's tracker, phase, promotion, or release rules here.
Ordinary base-branch feature work does not load that downstream component unless
repository policy or the live release tracker selects release handling for that
PR. Before skipping it, perform a bounded tracker-discovery check using only the
consumer repo's `AGENTS.md` tracker labels, title prefix, or other search policy.
Load the component when an existing applicable tracker unambiguously selects the
PR; if the repo defines no tracker discovery policy, do not invent one. If any
target's value, priority, or proposed fix scope is unclear, use the
installed or repo-local `evaluate-issue` skill before assigning implementation
workers.
Skip issues labeled `needs-customer-feedback` unless the user explicitly provides customer evidence or maintainer approval for that issue; report each skipped target with `needs-customer-feedback` as the reason.
