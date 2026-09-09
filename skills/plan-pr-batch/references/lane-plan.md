3. Shape
   - Exclude issues labeled `needs-customer-feedback` from implementation batches unless the user explicitly provides customer evidence or maintainer approval for that issue; list them under "Excluded or deferred" with `needs-customer-feedback` as the reason.
   - For any issue that is speculative, AI/code-analysis-only, over-scoped, or unclear in value, priority, or fix scope, route through the installed or repo-local `evaluate-issue` skill before assigning it to implementation work.
   - Exclude closed or merged items unless the user explicitly asked to audit them.
   - Treat a human assignee as a reservation: a human assignee — any assignee
     outside the repo's resolved automation set — marks an issue or PR as
     reserved: owned means skip. Resolve the automation set from the trust
     config's `trusted_bots` via the `pr-security-preflight` resolution chain,
     plus any assignee whose login carries the GitHub `[bot]` suffix;
     `trusted_users` are human actors and stay reservable. When the set cannot
     be resolved, treat any assignee as a human reservation and skip. Fetch the
     full scoped set and classify assignees after fetch — `no:assignee` alone
     omits automation-only-assigned items that stay eligible, so it is only a
     shortcut when the repo uses no automation self-assignment. List each
     excluded item under "Excluded or deferred" as reserved with its assignee
     name; never silently drop reserved work. Items with no assignee, or only an
     automation identity, stay eligible.
   - Also skip any issue or PR labeled with the seam's claim label
     (`agent_claimed_label`, default `agent-claimed`) — an active agent lane
     claim — and list it as reserved; owned means skip for agents as for humans.
   - Separate independent work from dependency-ordered work. Give every planned
     lane a stable agent id and a lane name. For `coordination_required` dependency-ordered work, define explicit
     `depends_on` refs in the form `<batch-id>:<lane-name>` so
     `agent-coord status --batch-id <batch-id> --json` can show whether the
     lane is blocked.
     Only for `coordination_required`, coordinators must create or update the private backend
     `batches/<batch-id>.json` with those lane refs before dependent workers
     start; otherwise targeted batch status cannot report `blocked_on` lanes.
     For `coordination_not_applicable`, preserve dependency order only in the
     typed stage plan/live gate below; do not create or update a private-backend batch.
   - Emit a persisted `stage-dependency-plan` v1 file for the complete planned
     graph plus a separate `stage-dependency-gate` v1 live replay, using the
     exact schemas in `workflows/pr-processing.md` -> **Stage-Typed Dependency
     Gate**. Backend `depends_on` refs are coordination facts, not a substitute
     for typed edges. The immutable pre-launch trusted plan assigns a known plan
     id and records each edge's exact `id`, `from`, `to`, and `type`; retyping
     requires a new edge id and trusted coordinator re-plan. The live edges
     carry only `id`, `state`, `evidence`, and `base_movement`. Classify every
     dependency as `edit`, `validation_open`, or `merge_order`; missing,
     unsupported, or `UNKNOWN` plan/live state remains fail-closed. Include
     stable lane/edge ids, current full head/base SHAs, known maker/checker ids
     with every checker distinct from every batch maker, and only separately
     verified evidence. For pending `edit` or `validation_open`, record nonempty
     known `source_patch_inspection`, `collision_domain_mapping`,
     `semantic_adaptation_notes`, `validation_review_plan`, and
     `evidence_templates`; missing or `UNKNOWN` preparation fails closed.
     Put both complete artifacts in the Batch Plan outside the compact goal
     prompt. Name `STAGE_DEPENDENCY_PLAN_PATH`, `STAGE_DEPENDENCY_PLAN_ID`, and
     the inline live replay or its durable reference in the goal's `Scope` data;
     persist them with stable planning state. Backend storage is optional, and
     backend `n/a` uses a coordinator-owned local plan file. Resolve
     `PR_BATCH_SKILL_DIR` in this order: explicit environment variable; the
     loaded skill's base directory when the host exposes it; repo-local
     `.agents/skills/pr-batch`; then stop with a precise blocker if the helper is
     still missing. Run `"${PR_BATCH_SKILL_DIR}/bin/stage-dependency-gate"`
     `--trusted-plan "${STAGE_DEPENDENCY_PLAN_PATH}"`
     `--trusted-plan-id "${STAGE_DEPENDENCY_PLAN_ID}"` with the live replay on
     stdin before calling the plan ready; report its deterministic critical
     path, tie-break result, maker/checker allocation, gated actions,
     base-refresh decisions, and hosted-CI eligibility. Missing, unreadable,
     malformed, `UNKNOWN`, or mismatched plan path/id/data blocks mutation. A
     verified independent graph still contains every lane and emits `edges: []`
     in both artifacts; the lane array is never empty.
   - Apply `.agents/workflows/pr-processing.md` under **Batch QA Lane**. Record
     whether QA is required, which subset qualifies, the planned owner/lane, and
     final QA Evidence expectations. If QA is omitted for low-risk work, record
     `not required` plus the rationale. For batches that need post-merge replay,
     require the `qa-evidence v2` marker and any needed
     `priority-finding-dispositions v1` marker in the final evidence.
     For every current user-visible UI change, plan the durable before/after
     destination, explicit `interaction_change` and `visual_fix`
     classifications, interaction clip or measured substitute, and visual-fix
     negative control. For rendered-page, asset-delivery, or bundle impact,
     also plan exact repository performance-seam
     `source=<stable command/report/ref>` plus
     `baseline_value=<number><unit>` / `candidate_value=<number><unit>`
     evidence; non-byte `bundle_hygiene` values require
     `metric_name=<bundle/asset shape metric>`, and `measured_metric` requires a
     `metric_name=<runtime/user metric>` label. A GitHub-only plan should use
     GitHub CLI 2.99.0+'s repeatable `--attach` flag with an authenticated
     write-capable OAuth, classic PAT, or fine-grained PAT actor on GitHub.com or
     GitHub Enterprise Cloud; GitHub Actions and App tokens are unsupported. For
     an existing PR, plan a dedicated comment by default; plan `gh pr edit` only
     when preserving the complete current description. Then fall back to an
     authenticated GitHub browser uploader when needed. Otherwise it may prepare
     local artifacts, but must plan an explicit blocked human-attachment handoff
     until durable GitHub URLs exist.
   - Decide whether the batch will schedule any parallel wave before doing path
     discovery. The File-touch map records integration intersections; it does not
     create dependencies or keep same-path items out of a wave. Issue-authored
     semantic dependencies alone become typed stage-dependency edges. If the batch runs serially — a single item, the user asked
     for serial execution, or the resolved host cap is 1 — skip path discovery and
     default every lane to serial. Otherwise build the map only for items that are
     candidates for the same parallel wave. PR path discovery is a cheap
     deterministic helper (below), so run it for every parallel-candidate PR;
     issue path discovery is model work, so defer it under the lazy rule below.
   - Build the File-touch map for those parallel candidates: list the paths each
     item changes or intends to affect, including creates, deletes, and renames.
     Never guess paths.

   - File-touch map, PR path discovery: resolve the paths a PR touches with the
     helper, which does the authoritative local three-dot diff (fetching the
     verified base/head into session-unique temporary refs, never checking out
     untrusted PR code), validates `baseRefName`/`headRefName` as untrusted
     refspec data, falls back to the PR Files API, and cleans up its temp refs.
     **For parallel batch scheduling, always pass `--cross-check`** so the local
     diff and the Files API must independently agree on the path set — a
     fail-safe against a silent under-report scheduling two colliding items into
     the same wave:
     Resolve `PLAN_PR_BATCH_SKILL_DIR` with the explicit env-var, loaded skill
     base, repo-local pinned-copy chain before using the fallback assignment.
     Then run:
     `PLAN_PR_BATCH_SKILL_DIR="${PLAN_PR_BATCH_SKILL_DIR:-.agents/skills/plan-pr-batch}"; "${PLAN_PR_BATCH_SKILL_DIR}/bin/pr-file-touch-map" N --repo OWNER/REPO --cross-check`
     It prints `{pr, repo, source, changed_files, paths, renames}`:
     - `source` is `verified` (cross-check: both sources agreed — the only value
       safe to place in a parallel worktree lane), `local-diff` / `files-api`
       (default mode, single source), or `UNKNOWN`.
     - `paths` covers creates, edits, deletes, and **both** sides of every
       rename/copy; `renames` lists `{old, new}` pairs.
     - **Treat anything other than `verified` as serial** when scheduling parallel
       waves. `UNKNOWN` means no trustworthy path list could be produced (a
       cross-check disagreement, an unfetchable source, a broken/capped Files API
       response, or a rename/copy row missing its previous filename) — never put
       it in a parallel lane.
     - The helper owns the security and portability details (refspec injection
       guards, fork pull-ref vs head-repo vs reachable-SHA fetch, shallow-clone
       deepen-and-retry, Files API `changedFiles` sanity check and ~3000-file
       cap); run `pr-file-touch-map --help` for the full contract.
   - File-touch map, issue path discovery is lazy: an issue with no explicit
     proposed paths in its body or design notes is recorded as `UNKNOWN` and run
     serially immediately — do not grep-and-reason toward a path set that will
     still land in a serial lane. Only when the issue names explicit paths and is
     a live candidate for a wave with open parallel capacity, record those
     proposed new paths from issue/design notes and grep the repo to confirm
     existing paths. If paths still cannot be determined, record `UNKNOWN` and
     treat the item as serial.
   - File-touch map, overlap and wave scheduling: record same-path intersections
     as integration advisories and keep the lanes moving; do not infer or alter a
     semantic dependency from an overlap. Repeated overlap is a modularization
     signal. At integration, apply consequence-aware care to executable, schema,
     security, merge-policy, and canonical-contract intersections. Resolve
     changelog and generated-artifact ownership from the consumer repository's
     `AGENTS.md` artifact-ownership seam (`defer`, `waive`, `dedicated-owner`, or
     required); ordinary documentation is advisory. A directory rename reserves
     descendants under both the old and new directory names, so any create/delete/edit under either tree is reported together. An `UNKNOWN`
     item runs as a serial "discovery lane" — a lane that first determines its
     real paths instead of editing in parallel. Never run discovery lanes
     concurrently with active editor lanes. For items already in the scheduling
     set, complete discovery before the editor wave starts. If the coordinator
     adds items after an editor wave has already started, wait for that wave to
     finish before starting discovery for those new items. A collision
     discovered mid-flight cannot safely redirect an active editor lane; the
     coordinator would have to abort the wave, release claims, and restart it,
     which is worse than waiting.
   - Host-aware batch sizing: choose the prompt target before final lane
     packing. An explicit user-requested paste destination wins over host
     detection; otherwise use the detectable current host, or `generic` when
     detection is ambiguous. Installed Codex/Claude homes prove install state,
     not the active runtime.
     After semantic dependency planning, default to these maximum independent lanes per
     prompt or wave. Items with `UNKNOWN` path evidence remain serial discovery
     lanes and are not counted in parallel wave limits.
     - `codex`: up to 10 independent items, or 8 when any lane touches shared/risky
       files, workflow/build/dependency/release surfaces, needs substantial QA,
       or would exceed the Codex prompt limit.
     - `claude`: up to 5 independent items, or 3 under the same risky/shared
       conditions, because in-process Claude Code subagents share more of the
       current runner's context, permission, and rate budget.
     - `generic`: use the Claude-sized 5/3 limit unless the user explicitly
       names a host with larger verified capacity.
     Prefer a smaller first batch when live coordination, CI, approval, or quota
     health is uncertain; put remaining independent work in later wave
     prompts.
   - Model/effort routing: keep the coordinator model/effort preference
     and independent-checker preference separate from every worker
     model/effort preference. Classify each implementation,
     discovery, review, and QA lane from the verified work it contains. Resolve the lane's worker
     host/provider and its currently available model/effort combinations from
     explicit user constraints or host-exposed runtime/config state; current
     official vendor docs may confirm capabilities but do not prove account
     availability. The prompt target and installed agent homes do not prove the
     worker model roster.
     Start routine workers on the fastest or balanced coding-capable pair that
     fits the lane's risk and deterministic validation. Reserve the strongest available
     pair for evidence-gated plan review or escalation. A small first
     failure stays on the initial route for a focused correction; two materially
     different credible failed attempts, or an earlier high-risk trigger from
     the canonical workflow, require `MODEL_ESCALATION_REQUEST`. Prefer
     stronger-model plan review followed by implementation on the initial tier;
     stronger-led implementation is the exception. When the current roster is available, prefer an exact model
     name or host-stable alias and compatible effort. If the worker host is known but its roster is unavailable,
     or only the `generic` prompt target is known, use a dispatch-resolved model class
     (`fastest-low-cost`, `balanced`, or `strongest`) with the classified
     effort instead of guessing a model. Scope the class to the known host when
     possible. If either the initial or escalation route cannot be named, record
     that route `UNKNOWN`; it remains an advisory preference rather than a launch
     blocker. Group lanes by model/effort preference,
     or dispatch-resolved class/effort route, for review and dispatch,
     but preserve lane ownership, dependencies, serial discovery,
     active-reservation coordination, and wave caps; grouping never combines
     targets into one worker.
     Keep coordinator and worker requested preferences independent. If the
     dispatcher or runtime inherits or defaults to the coordinator route, record
     it honestly and continue unless an independent gate blocks. Prefer a fresh strongest-capability checker
     instance distinct from every maker. A lower-cost route may collect mechanical
     evidence or issue the intent, risk, or readiness verdict when the checker
     role, independence, scope, current-head evidence, and evidence quality qualify.
     Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict.
     Give every lane whose risk or bounded delegation requires an execution
     envelope a coordinator-role-approved envelope containing goal/non-goals,
     owned paths, supported diagnosis, invariants, acceptance criteria,
     verification, and immediate stop conditions regardless of route.
     Necessary in-repository path expansion defaults to allowed when repository
     evidence shows an added path is reasonably necessary to complete the
     already-authorized goal or its required validation. Treat owned paths and
     the execution envelope as coordination and collision controls, not as a
     user-permission boundary. Before editing, record each added path and reason
     in the lane envelope when one is present; otherwise use a durable
     coordinator-owned lane record or Lane Card that the coordinator can read.
     Every added path not yet reflected in its verified file-touch map must have
     an active typed `expansion-path-reservation` before edit. When a lane is the
     sole active editor, the coordinator durably records the reservation,
     refreshes authoritative file-touch maps, lane lifecycle state, and
     active-lane claim and collision checks, and reruns `batch-plan-preflight`;
     the worker continues without user approval or a blocked lifecycle only
     after the preflight accepts.
     Before a worker in a multi-editor wave changes an added path, it persists a
     typed expansion request, marks its durable lane lifecycle blocked, refreshes
     its heartbeat, emits a Lane Card with the path, reason, and request evidence
     reference, and pauses at a safe checkpoint. The coordinator processes
     expansion requests serially, records an active
     `expansion_path_reservations` entry, refreshes authoritative file-touch maps
     and lane lifecycle state, and reruns `batch-plan-preflight`. For every
     multi-editor request, acceptance alone does not authorize resume: the
     requester must durably transition out of `blocked`, a fresh preflight must
     accept, and the requester must be absent from `launch.held_lane_ids`; when
     launch or relaunch is needed, it must also be present in
     `launch.eligible_lane_ids`. Under maximum-concurrency-one serialization, the
     current holder must also release the slot before resume. The reservation persists until the
     verified PR file-touch map contains the path or the request is cancelled,
     and it is removed once reflected or cancelled. A collision or `UNKNOWN`
     collision state remains stopped until then. A missing path alone is not
     material scope growth and must not produce `blocked-user-input`.
     Directory renames use a distinct `expansion-rename-reservation` v1 record
     with canonical, distinct `old` and `new` endpoints; only this typed rename
     form adds ancestor/descendant collision checks, while scalar path
     reservations remain exact-path collision controls.
     Necessary additions can include contract or type files, tests or fixtures,
     offline demo stubs, and build or generated integration surfaces when
     repository evidence makes them necessary.
     Contradictory evidence remains an immediate stop. Stop and return control
     when any of the following applies: the approved goal, accepted behavior, or
     acceptance criteria changes; the work adds unrelated work; it crosses a
     repository or trust boundary; it requires a destructive or
     difficult-to-reverse action; it introduces secrets, permissions,
     deployments, billing, or other external effects; it requires consequential
     architecture, performance, compatibility, or product judgment; it
     materially changes security, privacy, compliance, or release policy; it
     collides with another active lane and cannot be safely coordinated; it
     exposes consequential ambiguity; or it weakens verification. An omitted
     path alone is not such a condition.
     Before any worker launch, resolve `PLAN_PR_BATCH_SKILL_DIR` through the
     explicit env-var / loaded-skill / repo-local pinned-copy chain and pass a
     `batch-plan-preflight` v1 envelope on stdin to
     `"${PLAN_PR_BATCH_SKILL_DIR}/bin/batch-plan-preflight"`. This required gate
     owns schema, advisory-overlap reporting, backend-cap, QA, external-premise, active-wave, and
     max-one serialization scheduling; do not duplicate its matrices here. V1
     requires `plan.id`, `plan.active_wave`, and a top-level
     `lane_lifecycle_states` array. Advance max-one groups only from a separate
     ordinary durable `lane-lifecycle-state` v1 record bound to the batch,
     dependency plan, lane, and wave. Reject duplicates, unknown identities,
     unsupported states, and inline lane completion claims.
     The optional additive top-level `expansion_path_reservations` array uses
     exact `expansion-path-reservation` v1 records bound to the batch,
     dependency plan, known lane, and wave, with one canonical path, known
     reason, and durable evidence reference. A directory rename instead uses an
     exact `expansion-rename-reservation` v1 record with the same identity,
     reason, and evidence fields and a canonical, distinct `rename` old/new
     pair in place of `path`. Presence means active and omission means
     cancelled. Reject malformed, `UNKNOWN`, noncanonical, duplicate,
     mismatched, completed-lane, and already-reflected reservations. Derive
     collisions and risky capacity from verified file-touch paths plus active
     reservations. Scalar path reservations remain exact-only; typed rename
     reservations add ancestor/descendant collision checks at both endpoints.
     Reservation-derived overlap requires a shared max-one serialization group,
     not only a typed edit edge. Remove a reservation after cancellation or once
     the verified PR map reflects its path or exact rename pair.
     Preserve real PR `pr-file-touch-map` verified results unchanged; represent
     explicit pre-PR paths with the helper's typed `planned-path-evidence` v1
     record and durable evidence reference. An `issue` source must bind to the
     target's exact repository and number through `issue://OWNER/REPO/N` or an
     exact lowercase-host `https://github.com/OWNER/REPO/issues/N` reference;
     both reject userinfo and query, HTTPS requires port 443, `issue://`
     requires the exact canonical authority/path shape, and fragments remain
     permitted;
     other source kinds prove durability only and do not invent target identity.
     After an issue or trusted ad-hoc lane opens its implementation PR, keep the original canonical target unchanged and replace planned-path evidence with the lane-keyed verified PR file-touch map; its repository must match the target, while a PR-origin target also requires the exact target PR number.
     A rejected result launches no
     worker; an accepted result permits only its eligible lanes and keeps its
     held lanes unlaunched.
     Before launch, resolve `PR_BATCH_SKILL_DIR` through the explicit env-var /
     loaded-skill / repo-local pinned-copy chain, then send the requested
     route preference, requested dispatcher, dispatch authority, ordered candidates,
     and lane state to `"${PR_BATCH_SKILL_DIR}/bin/dispatcher-capability-preflight"`.
     It prefers the requested dispatcher and requires explicit authority for a
     dispatcher fallback; generic subagent wording grants nothing.
     Each viable candidate includes a stable prospective `instance_id` allocated or reserved by its dispatcher before launch, only for replay/fencing; the helper neither launches nor creates a worker.
     Prospective `instance_id` equal to `UNKNOWN` is unusable. Replay identity is `lane_id`, dispatcher, `instance_id`, and launch token; route preference, observed host fields, and `candidate_index` are metadata and never trigger replacement.
     Persist `launch-pending` before worker launch; after spawn, persist ordinary `active` state before Goal-mode resume, and replay the same token while pending or emit no new launch while active.
     Assignment activation uses ordinary durable lifecycle state; no project signing key, fixed trust anchor, launch-confirmation receipt, or human waiver is required.
     Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report.
     Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit.
     A dispatcher or instance change still requires stop/reconcile replacement fencing and a single-use proof bound to the exact prior and replacement assignment identities.
     Persisted request history, choices, revisions, assignments, replacement proofs, and `decision_resolution` are deep-validated; malformed nested state returns structured `invalid-input`.
     A `selected` result may resume Goal mode; `blocked-user-input` carries one
     `dispatch-decision-request v1` and stops.
   - Build the batch-registration provenance from the pack and actors that will
     actually run the batch. Record `pack_sha` as the verified full git SHA of
     the loaded Agent Workflows checkout, or its verified installed-release
     identifier; a dirty checkout or unverified source is `UNKNOWN`, never the
     consumer repo SHA or a remote guess. Record `coordinator_preference` as a
     preference. For every lane, record the worker route preference and optional
     observed host/model/effort from the host. Keep the worker's requested
     preference distinct; if the runtime inherits or defaults to the coordinator
     route, record that actual host observation honestly and never infer it from
     the preference. When batch
     registration is supported, persist this manifest after dispatcher
     selection and before worker launch. Backend `n/a` keeps the same
     provenance in the durable Batch Plan/handoff; a degraded registration is
     `UNKNOWN` with exact retry evidence. When the host later exposes an
     observation, update each observed host/model/effort field, preserve known
     fields, and use `UNKNOWN` only per unavailable field. Observation absence or
     registration-write failure never blocks assignment activation.
     Before requiring a reconciliation write, detect advertised registration
     update/upsert/reconciliation capability. An unadvertised or unsupported
     create-only backend records each affected field `UNKNOWN`. An
     advertised update uses the bounded safe executable-plus-opaque-argv
     contract; failure records affected fields `UNKNOWN` without wedging.
     Every advertised registration
     invocation resolves a backend-advertised safe executable plus ordered
     opaque argv without shell evaluation and runs with a finite hard deadline
     in its own process group; timeout or whole-group `TERM` then `KILL` records
     best-effort field-granular `UNKNOWN`, names reconciliation, and does not
     block worker launch. Use the
     [canonical Batch Provenance Manifest example](https://github.com/shakacode/agent-workflows/blob/main/docs/coordination-backend.md#batch-provenance-manifest).
     Its raw lane `targets` are not guard input. Use the canonical
     [Cross-Task Target Membership Gate](../../../workflows/pr-processing.md#cross-task-target-membership-gate)
     to derive the exact receiver manifest from trusted provenance/coordinator
     state and require the trusted-base `target-membership-guard` before any
     cross-task control or mutation. Keep its manifest-derivation details in that
     canonical workflow; do not mirror them here. Foreign targets remain
     evidence-only, unresolved identities fail closed as `UNKNOWN`, and control
     transfer requires trusted out-of-band human authority plus exact receiver
     membership.
   - For PRs with review feedback, route the worker to use the repo review workflow before code changes.
   - For issues, define the expected deliverable: fix, investigation, reproduction, docs update, or no-PR audit.
