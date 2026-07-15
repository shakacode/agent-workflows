# frozen_string_literal: true

require "json"
require "open3"

ROOT = File.expand_path("../../..", __dir__)

def read_repo_file(path)
  File.read(File.join(ROOT, path), encoding: "UTF-8")
end

def assert(condition, message)
  abort("FAIL: #{message}") unless condition
end

def extract_source_checkpoint_filter(text)
  marker = 'if SOURCE_VALID_CHECKPOINTS="$(jq -c --arg actor'
  marker_offset = text.index(marker)
  abort("FAIL: source checkpoint jq filter start missing") unless marker_offset

  filter_offset = text.index("'\n", marker_offset)
  abort("FAIL: source checkpoint jq filter body missing") unless filter_offset

  filter_tail = text[(filter_offset + 2)..]
  terminator = filter_tail.match(/\n\s+' source-review-data\.json\)/)
  abort("FAIL: source checkpoint jq filter terminator missing") unless terminator

  filter_tail[0...terminator.begin(0)]
end

batch = read_repo_file("skills/pr-batch/SKILL.md")
guide = read_repo_file("docs/pr-batch-skills.md")
workflow = read_repo_file("workflows/pr-processing.md")
batch_metadata = read_repo_file("skills/pr-batch/agents/openai.yaml")
address_review = read_repo_file("skills/address-review/SKILL.md")
address_review_workflow = read_repo_file("workflows/address-review.md")
address_review_actions = read_repo_file("skills/address-review/references/actions.md")
address_review_templates = read_repo_file("skills/address-review/references/templates.md")

assert(batch.include?("A single target is\na batch of one"), "pr-batch must own single-target mode")
assert(batch.include?("dispatch one\n  worker subagent"), "single-target mode must default to a worker subagent")
assert(batch.include?("Do not silently default it"), "single-target mode must require explicit merge authority")
assert(batch.include?("an explicit `AGENTS.md` rule, or a resolved batch-plan instruction"), "single-target merge authority must use concrete authorization sources")
assert(batch.include?("fastest or balanced worker route"), "single-target mode must use cost-aware staged routing")
assert(batch.include?("verified head branch cannot be pushed"), "single-target PR mode must preserve the unpushable-head fallback")
assert(batch.include?("replacement branch/PR"), "single-target PR mode must explain the replacement path")
assert(batch.include?("for one direct-prompt task, the derived `adhoc:<yyyymmdd>-<short-slug>`"), "the required interview must accept ad-hoc targets")
assert(batch.include?("direct user instruction, a maintainer-approved exact list"), "the required interview must classify direct-prompt trust")
assert(batch.include?("when present, otherwise from the `AGENTS.md`"), "canonical base-branch resolution must support inline AGENTS configuration")

legacy_skill = %w[pr lane].join("-")
legacy_display_name = %w[PR Lane].join(" ")
assert(!File.exist?(File.join(ROOT, "skills", legacy_skill, "SKILL.md")), "the legacy single-lane skill must be removed")

public_paths = ["README.md", "CHANGELOG.md"] +
               Dir.glob(File.join(ROOT, "{docs,skills,workflows}", "**", "*.md")).map { |path| path.delete_prefix("#{ROOT}/") }
public_paths.each do |path|
  text = read_repo_file(path)
  assert(!text.include?(legacy_skill), "#{path} must not reference the removed legacy skill")
  assert(!text.include?(legacy_display_name), "#{path} must not reference the removed legacy display name")
end

assert(guide.include?("one worker subagent"), "guide must document the single-target worker shape")
assert(batch_metadata.include?("one or more"), "canonical picker metadata must advertise single- and multi-target work")
assert(batch_metadata.include?("ad-hoc"), "canonical picker metadata must advertise direct ad-hoc tasks")

assert(workflow.include?("claim --help"), "canonical coordination must preserve claim capability detection")
assert(workflow.include?("heartbeat --help"), "canonical coordination must preserve heartbeat capability detection")
assert(workflow.include?("--thread-handle"), "canonical coordination must preserve extended lane metadata")
assert(workflow.include?("`coordination_backend: n/a`"), "canonical coordination must define no-backend single-target behavior")
assert(workflow.include?("single-operator assumption in the Lane Card and final handoff"), "no-backend mode must preserve its assumption in evidence")
assert(workflow.include?("a derived `adhoc:<yyyymmdd>-<short-slug>` target"), "canonical intake must accept direct-prompt task targets")
assert(workflow.include?("Do not pass `adhoc:` targets to `pr-security-preflight`"), "ad-hoc targets must not be sent to the GitHub preflight helper")
assert(workflow.include?("Ad-hoc task: `adhoc:<yyyymmdd>-<short-slug>`"), "canonical goal handoff must represent ad-hoc task items")
assert(workflow.include?("Target ids: PR/Issue #N or Ad-hoc `adhoc:<yyyymmdd>-<short-slug>`"), "canonical file-touch map must represent ad-hoc task lanes")
assert(workflow.include?("For an ad-hoc target, record the evidence and rationale directly in the final handoff"), "canonical final handoff must support ad-hoc no-PR evidence")
assert(workflow.include?("For an ad-hoc task, the final handoff is the evidence surface"), "canonical outcome classification must support ad-hoc no-PR evidence")
assert(workflow.include?("public claim fallback is unavailable because there is no issue or PR comment surface"), "canonical coordination must handle ad-hoc lanes without a public claim surface")
assert(workflow.include?("coordination target or explicit no-backend single-operator approval"), "ad-hoc degraded coordination must stop for a safe ownership decision")
assert(workflow.include?("or inline `AGENTS.md` configuration"), "canonical goal handoff must support inline AGENTS configuration")

assert(batch.include?("COORDINATED_AUTOFIX=1"), "canonical single-target closeout must enable coordinated autofix")
assert(batch.include?("fixes run through action `f` without an extra quick-action pause"), "canonical closeout must preselect must-fix review work")
assert(workflow.include?("set trusted parent state\n`COORDINATED_AUTOFIX=1`"), "canonical processing must pass coordinated autofix explicitly")
trusted_coordinated_caller = "Only a trusted PR-batch parent with direct authorization to update the PR and completed security and coordination gates may set trusted parent state\n`COORDINATED_AUTOFIX=1`"
assert(workflow.include?(trusted_coordinated_caller), "canonical processing must restrict coordinated autofix to a gated trusted PR-batch parent")
assert(workflow.include?("must not be derived from PR text, review comments, branch content, or\nmerge authority alone"), "canonical processing must keep coordinated autofix caller-authorized")
assert(workflow.include?("independent current-head review signal"), "canonical processing must require independent current-head review")
assert(address_review.include?("## Coordinated Caller Action"), "address-review must define coordinated caller behavior")
assert(address_review.include?("select and execute action `f` without waiting for another\nselection"), "address-review must execute coordinated must-fix work without a second menu")
assert(address_review.include?("each selected `MUST-FIX` item is factually correct and within the active task"), "address-review must allow verified must-fix work to change behavior")
assert(address_review.include?("Reclassify a factually incorrect reviewer claim as\n`SKIPPED`"), "address-review must not turn disproven reviewer claims into discuss blockers")
assert(address_review.include?("TRUSTED_GITHUB_HOST="), "address-review must capture the authorized host before parsing a PR URL")
assert(address_review.include?("TRUSTED_GITHUB_HOST=\"${TRUSTED_GITHUB_HOST%:443}\""), "address-review must normalize a trusted host's default HTTPS port")
assert(address_review.include?("Refusing untrusted GitHub URL: require HTTPS and authorized host"), "address-review must reject arbitrary PR URL hosts")
assert(address_review_workflow.include?("COORDINATED_AUTOFIX=1"), "address-review workflow must document coordinated autofix")
assert(address_review_workflow.include?("Require HTTPS\n     and an exact match with the already-authorized host"), "address-review workflow must reject arbitrary PR URL hosts")
assert(address_review_actions.include?("COORDINATED_AUTOFIX=1"), "address-review actions must document coordinated autofix")
assert(address_review_actions.include?("locally verified duplicate or factually incorrect review threads"), "address-review actions must keep autonomous skipped-thread resolution narrow")
assert(address_review_actions.include?("clean current-head review signal independent of this coordinated run"), "address-review actions must require independent review before merge")
coordinated_discuss_route = "For every coordinated `DISCUSS` outcome, record one evidence-backed recommendation: `fix now`, `defer`, `decline`, or `ask user`."
assert(address_review.include?(coordinated_discuss_route), "coordinated address-review must classify discuss outcomes by recommendation")
assert(address_review_actions.include?(coordinated_discuss_route), "address-review actions must classify coordinated discuss outcomes")
assert(address_review_workflow.include?(coordinated_discuss_route), "address-review workflow mirror must classify coordinated discuss outcomes")
coordinated_skipped_default = "A coordinated `SKIPPED` item gets an evidence-backed `decline`/no-action outcome by default."
assert(address_review.include?(coordinated_skipped_default), "coordinated skipped items must remain non-actionable")
assert(address_review_actions.include?(coordinated_skipped_default), "address-review actions must decline coordinated skipped items by default")
assert(address_review_workflow.include?(coordinated_skipped_default), "address-review workflow mirror must decline coordinated skipped items by default")
skipped_reclassification = "If inspection shows a `SKIPPED` item merits a fix, defer, or maintainer choice, reclassify it to `MUST-FIX`, `DISCUSS`, or `OPTIONAL` as appropriate before assigning or executing a recommendation."
assert(address_review.include?(skipped_reclassification), "address-review must reclassify actionable skipped items")
assert(address_review_actions.include?(skipped_reclassification), "address-review actions must reclassify actionable skipped items")
assert(address_review_workflow.include?(skipped_reclassification), "address-review workflow mirror must reclassify actionable skipped items")
assert(workflow.include?(skipped_reclassification), "canonical PR processing must preserve skipped tier semantics")
assert(batch.include?(skipped_reclassification), "pr-batch must preserve skipped tier semantics")
assert(address_review.include?("Execute `fix now`, `defer`, or `decline` without prompting; stop for maintainer input only when the recommendation is `ask user`"), "coordinated address-review must stop only when a safe recommendation requires maintainer help")
assert(address_review_actions.include?("Execute `fix now`, `defer`, or `decline` without prompting; stop for maintainer input only when the recommendation is `ask user`"), "address-review actions must carry coordinated recommendation autonomy")
assert(address_review_workflow.include?("Execute `fix now`, `defer`, or `decline` without prompting; stop for maintainer input only when the recommendation is `ask user`"), "address-review workflow mirror must carry coordinated recommendation autonomy")
assert(workflow.include?("Execute `fix now`, `defer`, or `decline` without prompting; stop for maintainer input only when the recommendation is `ask user`"), "canonical PR processing must carry coordinated recommendation autonomy")
assert(batch.include?("Execute `fix now`, `defer`, or `decline` without prompting; stop for maintainer input only when the recommendation is `ask user`"), "pr-batch entry point must carry coordinated recommendation autonomy")
assert(address_review.include?("A non-blocking `defer` defaults to durable PR summary or decision-log evidence unless existing repository policy selects a tracker."), "coordinated address-review must not create expansive follow-up tracking by default")
merge_authority_separation = "Coordinated review-decision authority comes from direct authorization to update the PR and is independent of `merge_authority`; merge authority governs merge only."
assert(address_review.include?(merge_authority_separation), "address-review coordinated decisions must not require auto-merge authority")
assert(address_review_workflow.include?(merge_authority_separation), "address-review workflow mirror must separate review decisions from merge authority")
assert(workflow.include?(merge_authority_separation), "canonical PR processing must separate review decisions from merge authority")
assert(batch.include?(merge_authority_separation), "pr-batch must use coordinated review decisions for every merge-authority mode")
coordinated_fix_tracking = "Before action `f`, add every coordinated actionable outcome recommended as `fix now` to the executable work list; normal interactive TodoWrite remains `MUST-FIX`-only."
assert(address_review.include?(coordinated_fix_tracking), "coordinated fix-now outcomes must become tracked executable work")
assert(address_review_actions.include?(coordinated_fix_tracking), "address-review actions must execute tracked coordinated fix-now work")
assert(address_review_workflow.include?(coordinated_fix_tracking), "address-review workflow mirror must track coordinated fix-now work")
resolved_tracker_route = "If repository policy requires tracking and provides an already-resolved tracker destination and contract, record the defer there without prompting."
assert(address_review.include?(resolved_tracker_route), "coordinated defer must use a resolved required tracker deterministically")
assert(address_review_actions.include?(resolved_tracker_route), "address-review actions must use a resolved required tracker deterministically")
assert(address_review_workflow.include?(resolved_tracker_route), "address-review workflow mirror must use a resolved required tracker deterministically")
incomplete_tracker_route = "If tracking is required but the destination or contract is missing or ambiguous, change the recommendation to `ask user`."
assert(address_review.include?(incomplete_tracker_route), "coordinated defer must ask only when required tracker configuration is incomplete")
assert(address_review_actions.include?(incomplete_tracker_route), "address-review actions must ask only when required tracker configuration is incomplete")
assert(address_review_workflow.include?(incomplete_tracker_route), "address-review workflow mirror must ask only when required tracker configuration is incomplete")
no_coordinated_issue = "Coordinated mode must not create a new follow-up issue."
assert(address_review.include?(no_coordinated_issue), "coordinated address-review must not invent follow-up issues")
assert(address_review_actions.include?(no_coordinated_issue), "coordinated defer must not invent follow-up issues")
assert(address_review_workflow.include?(no_coordinated_issue), "address-review workflow mirror must not invent follow-up issues")
standalone_tracking = "This deterministic route applies only to coordinated `f`; standalone `f+i` and `m` keep their interactive tracking choice."
assert(address_review_actions.include?(standalone_tracking), "standalone deferred-bundle actions must remain interactive")
assert(address_review_workflow.include?(standalone_tracking), "address-review workflow mirror must preserve interactive deferred bundles")
coordinated_fix_closeout = "Reply to each coordinated `fix now` work item after the pushed fix and resolve its thread when complete."
assert(address_review_actions.include?(coordinated_fix_closeout), "coordinated fix-now work must complete its reply and resolution gates")
assert(address_review_workflow.include?(coordinated_fix_closeout), "address-review workflow mirror must close out coordinated fix-now work")
coordinated_decline_resolution = "autonomously declined under a trusted `COORDINATED_AUTOFIX=1` evidence-backed recommendation"
assert(address_review_actions.include?(coordinated_decline_resolution), "coordinated decline outcomes must be resolvable with evidence")
assert(address_review_workflow.include?(coordinated_decline_resolution), "address-review workflow mirror must resolve coordinated evidence-backed declines")
coordinated_menu = "When `COORDINATED_AUTOFIX=1`, present triage for transparency but do not display the quick-action menu; immediately execute coordinated action `f` after the verification checkpoint."
assert(address_review.include?(coordinated_menu), "coordinated address-review must not display an interactive menu")
assert(address_review_workflow.include?(coordinated_menu), "address-review workflow mirror must not display an interactive menu")
interactive_menu = "For normal interactive runs, present the quick-action menu after the triage list."
assert(address_review.include?(interactive_menu), "normal address-review must retain its interactive quick-action menu")
assert(address_review_workflow.include?(interactive_menu), "address-review workflow mirror must retain its interactive quick-action menu")
checkpoint_order = "Complete the coordinated verification checkpoint before final triage display, TodoWrite construction, coordinated executable-work construction, or action `f`."
assert(address_review.include?(checkpoint_order), "address-review must verify coordinated classifications before display or work construction")
assert(address_review_workflow.include?(checkpoint_order), "address-review workflow mirror must verify before display or work construction")
assert(workflow.include?(checkpoint_order), "canonical PR processing must verify before coordinated triage execution")
assert(batch.include?(checkpoint_order), "pr-batch must verify before coordinated triage execution")
verified_rebuild = "If verification changes any tier or recommendation, rebuild and re-number the triage, rebuild the TodoWrite `MUST-FIX` list and coordinated executable-work list from verified classifications, and remove stale work items."
assert(address_review.include?(verified_rebuild), "address-review must rebuild coordinated state after verification changes")
assert(address_review_workflow.include?(verified_rebuild), "address-review workflow mirror must rebuild coordinated state after verification changes")
assert(workflow.include?(verified_rebuild), "canonical PR processing must rebuild coordinated state after verification changes")
assert(batch.include?(verified_rebuild), "pr-batch must rebuild coordinated state after verification changes")
coordinated_bot_exception = "Only a trusted `COORDINATED_AUTOFIX=1` invocation that passed security and coordination gates and verified the item as in-scope and safe at the checkpoint may execute an evidence-backed `DISCUSS` recommendation of `fix now`; bot priority or severity alone never qualifies."
assert(address_review.scan(coordinated_bot_exception).length >= 2, "both address-review bot-severity rules must carry the narrow coordinated exception")
assert(address_review_workflow.scan(coordinated_bot_exception).length >= 2, "both workflow mirror bot-severity rules must carry the narrow coordinated exception")
unsafe_discuss_route = "Anything outside the active task or behavior, security, scope, or release-policy boundaries, or still requiring material judgment, must be `ask user`, `defer`, or `decline` as appropriate, never auto-fixed."
assert(address_review.scan(unsafe_discuss_route).length >= 2, "address-review must keep unsafe or material discuss outcomes non-automatic")
assert(address_review_workflow.scan(unsafe_discuss_route).length >= 2, "address-review workflow mirror must keep unsafe or material discuss outcomes non-automatic")
pushable_coordinated_target = "Do not invoke coordinated `address-review` on an original PR whose verified head cannot be pushed; first use the replacement branch/PR fallback, then invoke it only for the PR whose verified head is pushable and owned."
assert(batch.include?(pushable_coordinated_target), "pr-batch must not run coordinated closeout against an unpushable original PR")
assert(workflow.include?(pushable_coordinated_target), "canonical PR processing must route unpushable heads through replacement closeout")
remaining_discuss_phase = "During the remaining-decision phase, coordinated `fix now` items are already fixed, replied to, and resolved; process only `defer` or `decline`, stop on `ask user`, and never execute `fix now` again."
assert(address_review_actions.include?(remaining_discuss_phase), "address-review must not replay coordinated fix-now items in step 9")
assert(address_review_workflow.include?(remaining_discuss_phase), "address-review workflow mirror must not replay coordinated fix-now items")
replacement_review_carryover = "Replacement-PR review carryover: do not run action `f` or push against the unpushable original head; fetch and triage its review data, carry every actionable original item into the replacement PR executable/decision worklist, apply it on the pushable owned replacement, and post the replacement link plus evidence-backed handled/deferred/declined outcome back on the original item or thread where possible."
assert(batch.include?(replacement_review_carryover), "pr-batch replacement fallback must preserve original review obligations")
assert(workflow.include?(replacement_review_carryover), "canonical replacement fallback must preserve original review obligations")
replacement_review_gate = "Resolve original threads only when the conversation is complete, and require original review-inventory closeout plus replacement-PR current-head review and readiness before signaling ready."
assert(batch.include?(replacement_review_gate), "pr-batch replacement fallback must close both review surfaces")
assert(workflow.include?(replacement_review_gate), "canonical replacement fallback must close both review surfaces")
coordinated_defer_resolution = "Under coordinated `f`, a `defer` is complete for thread resolution only after its evidence-backed rationale and required durable PR summary, decision log, or existing-policy tracker record are posted and the conversation is complete."
assert(address_review.include?(coordinated_defer_resolution), "address-review must require durable defer evidence before resolving")
assert(address_review_actions.include?(coordinated_defer_resolution), "address-review actions must resolve evidenced coordinated deferrals")
assert(address_review_workflow.include?(coordinated_defer_resolution), "address-review workflow mirror must resolve evidenced coordinated deferrals")
coordinated_defer_order = "Coordinated defer ordering: post the original-thread rationale first; then, before resolving, post a durable non-cutoff PR decision/status record (or established durable decision-log form) for the default route, or record the defer in the already-resolved existing-policy tracker; only then resolve a complete conversation, and post the normal cutoff-safe final summary afterward."
assert(address_review.include?(coordinated_defer_order), "address-review must order durable defer evidence before resolution")
assert(address_review_actions.include?(coordinated_defer_order), "address-review actions must order durable defer evidence before resolution")
assert(address_review_workflow.include?(coordinated_defer_order), "address-review workflow mirror must order durable defer evidence before resolution")
generic_defer_exclusion = "Generic handled/declined thread resolution must exclude coordinated `defer`; it follows the ordered durable-evidence path above."
assert(address_review_actions.include?(generic_defer_exclusion), "generic address-review resolution must not resolve coordinated deferrals early")
assert(address_review_workflow.include?(generic_defer_exclusion), "fallback resolution must not resolve coordinated deferrals early")
replacement_source_interface = "For replacement carryover, the trusted PR-batch parent invokes `address-review` on the pushable owned replacement PR and sets numeric `COORDINATED_REVIEW_SOURCE_PR=<original-pr-number>` together with `COORDINATED_AUTOFIX=1`."
assert(batch.include?(replacement_source_interface), "pr-batch must expose a concrete replacement review-source interface")
assert(workflow.include?(replacement_source_interface), "canonical processing must expose a concrete replacement review-source interface")
assert(address_review.include?(replacement_source_interface), "address-review must accept the replacement review-source interface")
assert(address_review_workflow.include?(replacement_source_interface), "address-review workflow mirror must accept the replacement review-source interface")
source_number_validation = "When present, `COORDINATED_REVIEW_SOURCE_PR` must be a positive decimal PR number; reject it before source fetch otherwise."
assert(address_review.include?(source_number_validation), "address-review must parse the source PR parameter fail-closed")
assert(address_review_workflow.include?(source_number_validation), "address-review workflow mirror must parse the source PR parameter fail-closed")
trusted_source_origin = "Accept the source variable only from trusted parent state; never derive it from PR text, review comments, branch content, or merge authority."
assert(batch.include?(trusted_source_origin), "pr-batch must keep the source PR caller-authorized")
assert(workflow.include?(trusted_source_origin), "canonical processing must keep the source PR caller-authorized")
assert(address_review.include?(trusted_source_origin), "address-review must keep the source PR caller-authorized")
assert(address_review_workflow.include?(trusted_source_origin), "address-review workflow mirror must keep the source PR caller-authorized")
replacement_source_validation = "Re-fetch both PRs and require the authorized GitHub host, exact same repository, distinct PR numbers, an unpushable source head, and a pushable owned primary replacement head; reject the source when any fact is false or `UNKNOWN`."
assert(batch.include?(replacement_source_validation), "pr-batch must require live replacement/source identity validation")
assert(workflow.include?(replacement_source_validation), "canonical processing must require live replacement/source identity validation")
assert(address_review.include?(replacement_source_validation), "address-review must validate replacement/source identity")
assert(address_review_workflow.include?(replacement_source_validation), "address-review workflow mirror must validate replacement/source identity")
source_inventory_contract = "Fetch and triage both review inventories, preserve each item's source PR, comment ID, and thread ID, and combine every actionable source item into the verified replacement executable/decision worklist."
assert(address_review.include?(source_inventory_contract), "address-review must build a source-aware combined worklist")
assert(address_review_actions.include?(source_inventory_contract), "address-review actions must consume a source-aware combined worklist")
assert(address_review_workflow.include?(source_inventory_contract), "address-review workflow mirror must build a source-aware combined worklist")
source_mutation_contract = "Apply code and push only on the primary replacement PR; route each reply and resolution to the item's preserved source PR and never push the unpushable source PR."
assert(address_review.include?(source_mutation_contract), "address-review must keep replacement mutations on the primary PR")
assert(address_review_actions.include?(source_mutation_contract), "address-review actions must route source replies without pushing the source")
assert(address_review_workflow.include?(source_mutation_contract), "address-review workflow mirror must route source replies without pushing the source")
dual_pr_readiness = "Unavailable or `UNKNOWN` source review data blocks readiness; require source review-inventory closeout plus replacement current-head review/readiness, with durable carryover summaries on both PRs as appropriate."
assert(batch.include?(dual_pr_readiness), "pr-batch must require dual-PR replacement readiness evidence")
assert(workflow.include?(dual_pr_readiness), "canonical processing must require dual-PR replacement readiness evidence")
assert(address_review.include?(dual_pr_readiness), "address-review must require dual-PR replacement readiness evidence")
assert(address_review_workflow.include?(dual_pr_readiness), "address-review workflow mirror must require dual-PR replacement readiness evidence")
standalone_source_absence = "When `COORDINATED_REVIEW_SOURCE_PR` is absent, keep normal single-PR and standalone behavior unchanged."
assert(address_review.include?(standalone_source_absence), "address-review must preserve normal single-PR behavior")
assert(address_review_workflow.include?(standalone_source_absence), "address-review workflow mirror must preserve normal single-PR behavior")
assert(address_review.include?("PRIMARY_PR_NUMBER=\"${PR_NUMBER}\""), "address-review must bind the primary replacement PR explicitly")
assert(address_review.include?("SOURCE_PR_NUMBER=\"${COORDINATED_REVIEW_SOURCE_PR:-}\""), "address-review must parse the coordinated source PR variable")
replacement_source_invocation = 'COORDINATED_AUTOFIX=1 COORDINATED_REVIEW_SOURCE_PR="${ORIGINAL_PR_NUMBER}" address-review "${REPLACEMENT_PR_NUMBER}"'
assert(batch.include?(replacement_source_invocation), "pr-batch must show the executable replacement-source invocation")
assert(workflow.include?(replacement_source_invocation), "canonical processing must show the executable replacement-source invocation")
assert(address_review.include?("source-review-data.json"), "address-review must fetch a separate source review inventory")
assert(address_review_workflow.include?("source-review-data.json"), "address-review workflow mirror must fetch a separate source review inventory")
assert(address_review_actions.include?("ITEM_SOURCE_PR"), "address-review actions must route replies through preserved source identity")
assert(address_review_workflow.include?("ITEM_SOURCE_PR"), "address-review workflow mirror must route replies through preserved source identity")
dual_summary_route = "In replacement carryover, post a summary/status checkpoint on the primary replacement PR and a separate carryover checkpoint on `SOURCE_PR_NUMBER`; each checkpoint is cutoff-safe only when its own inventory guard passes, otherwise post a non-cutoff status."
assert(address_review.include?(dual_summary_route), "address-review must define durable summaries for both replacement and source PRs")
assert(address_review_actions.include?(dual_summary_route), "address-review actions must post durable summaries for both PRs")
assert(address_review_workflow.include?(dual_summary_route), "address-review workflow mirror must post durable summaries for both PRs")
unconditional_dual_summary = "post the normal cutoff-safe summary on the primary replacement PR and a separate cutoff-safe carryover summary"
assert(!address_review.include?(unconditional_dual_summary), "address-review must not call both replacement checkpoints cutoff-safe unconditionally")
assert(!address_review_actions.include?(unconditional_dual_summary), "address-review actions must not call both replacement checkpoints cutoff-safe unconditionally")
assert(!address_review_workflow.include?(unconditional_dual_summary), "address-review workflow mirror must not call both replacement checkpoints cutoff-safe unconditionally")
source_cutoff_contract = "On source-aware reruns, keep the complete source inventory for context and readiness, apply `SOURCE_REVIEW_CUTOFF_AT` from the latest valid source summary as the only global cutoff, then consume the latest summary/status checkpoint's per-item state for remaining candidates."
assert(address_review.include?(source_cutoff_contract), "address-review must apply the source summary cutoff on replacement reruns")
assert(address_review_actions.include?(source_cutoff_contract), "address-review actions must preserve source cutoff semantics")
assert(address_review_workflow.include?(source_cutoff_contract), "address-review workflow mirror must apply the source summary cutoff")
source_cutoff_binding = 'SOURCE_REVIEW_CUTOFF_AT="$(printf \'%s\' "${SOURCE_VALID_CHECKPOINTS}" | jq -r'
assert(address_review.include?(source_cutoff_binding), "address-review must bind source cutoff from validated checkpoints")
assert(address_review_workflow.include?(source_cutoff_binding), "address-review workflow mirror must bind source cutoff from validated checkpoints")
source_status_exclusion = "Only a source issue comment authored by `SOURCE_REVIEW_ACTOR`, with a complete valid `address-review-source-state:v1` block, whose body starts with `<!-- address-review-summary -->` on its first line may advance this cutoff; `<!-- address-review-status -->` never advances it."
assert(address_review.include?(source_status_exclusion), "address-review must reject source status markers as cutoffs")
assert(address_review_actions.include?(source_status_exclusion), "address-review actions must reject source status markers as cutoffs")
assert(address_review_workflow.include?(source_status_exclusion), "address-review workflow mirror must reject source status markers as cutoffs")
authenticated_source_state = "Use `SOURCE_STATE_CHECKPOINT_BODY` only from the newest authenticated, schema-valid summary/status checkpoint. A marker-only, wrong-author, malformed, duplicate, or incomplete checkpoint supplies neither restart state nor a cutoff."
assert(address_review.include?(authenticated_source_state), "address-review must consume only authenticated valid source state")
assert(address_review_actions.include?(authenticated_source_state), "address-review actions must consume only authenticated valid source state")
assert(address_review_workflow.include?(authenticated_source_state), "address-review workflow mirror must consume only authenticated valid source state")
source_review_wait = "On every non-specific run, apply the bounded, graceful review-check wait to `PRIMARY_PR_NUMBER`; wait on `SOURCE_PR_NUMBER` only for its first harvest, when no prior source summary or status checkpoint exists."
assert(address_review.include?(source_review_wait), "address-review must limit the source review wait to first harvest")
assert(address_review_workflow.include?(source_review_wait), "address-review workflow mirror must limit the source review wait to first harvest")
assert(address_review.include?("SOURCE_HAS_CHECKPOINT"), "address-review must probe prior source checkpoint state before the wait")
assert(address_review_workflow.include?("SOURCE_HAS_CHECKPOINT"), "address-review workflow mirror must probe prior source checkpoint state before the wait")
assert(address_review.scan("def valid_body:").length >= 2, "address-review must schema-validate both source wait and cutoff checkpoints")
assert(address_review_workflow.scan("def valid_body:").length >= 2, "address-review workflow mirror must schema-validate both source wait and cutoff checkpoints")
assert(address_review.include?('select(((.user.login // "") | ascii_downcase) == ($actor | ascii_downcase))'), "source wait must authenticate the checkpoint author")
assert(address_review_workflow.include?('select(((.user.login // "") | ascii_downcase) == ($actor | ascii_downcase))'), "workflow source wait must authenticate the checkpoint author")
assert(address_review.include?("for REVIEW_WAIT_PR in ${REVIEW_WAIT_PRS}; do"), "address-review must implement the dual-PR review wait")
assert(address_review_workflow.include?("for REVIEW_WAIT_PR in ${REVIEW_WAIT_PRS}; do"), "address-review workflow mirror must implement the dual-PR review wait")
specific_source_rejection = "A specific review/comment target remains immediate; reject its combination with `SOURCE_PR_NUMBER` and require a full replacement-PR invocation instead of starting broad source carryover."
assert(address_review.include?(specific_source_rejection), "address-review must keep specific-target behavior narrow")
assert(address_review_workflow.include?(specific_source_rejection), "address-review workflow mirror must keep specific-target behavior narrow")
source_terminal_guard = "A source checkpoint is cutoff-safe only when every source item has a terminal handled, deferred, declined, or other explicitly safe-to-skip outcome; any pending, `ask user`, or user-pending source item requires a non-cutoff status and remains eligible for the next source scan."
assert(address_review.include?(source_terminal_guard), "address-review must keep pending source items outside the cutoff")
assert(address_review_actions.include?(source_terminal_guard), "address-review actions must keep pending source items outside the cutoff")
assert(address_review_workflow.include?(source_terminal_guard), "address-review workflow mirror must keep pending source items outside the cutoff")
assert(address_review_templates.include?(source_terminal_guard), "address-review templates must keep pending source items outside the cutoff")
assert(address_review_templates.include?('source_summary_body_file=""'), "address-review templates must preserve normal single-PR cleanup state")
assert(address_review_templates.include?('source_summary_body_file="$(mktemp)"'), "address-review templates must construct the source checkpoint file")
assert(address_review_templates.include?('SOURCE_CUTOFF_SAFE="${SOURCE_CUTOFF_SAFE:-0}"'), "address-review templates must use a separate source cutoff guard")
assert(address_review_templates.include?("SOURCE_OUTCOMES"), "address-review templates must render explicit source outcomes")
assert(address_review_templates.include?("REPLACEMENT_PR_URL"), "address-review templates must render the replacement link")
assert(address_review_templates.include?('[ -n "${source_summary_body_file:-}" ] && rm -f "${source_summary_body_file}"'), "address-review templates must clean the source checkpoint file")
source_template_post = 'gh api repos/${REPO}/issues/${SOURCE_PR_NUMBER}/comments -X POST -F body=@"${source_summary_body_file}"'
assert(address_review_templates.include?(source_template_post), "address-review templates must post the source checkpoint before cleanup")
assert(!address_review_actions.include?(source_template_post), "address-review actions must not duplicate the template source post")
assert(!address_review_workflow.include?(source_template_post), "address-review workflow mirror must not duplicate the template source post")
source_post_ownership = "The Step 10 template constructs and posts the primary checkpoint and, when source carryover is active, the source checkpoint exactly once before its cleanup trap runs."
assert(address_review_templates.include?(source_post_ownership), "address-review templates must own both checkpoint posts")
assert(address_review_actions.include?(source_post_ownership), "address-review actions must delegate both checkpoint posts to the template")
assert(address_review_workflow.include?(source_post_ownership), "address-review workflow mirror must delegate both checkpoint posts to the template")
source_state_format = "Each source-state row is exactly `item<TAB><source-pr><kind><item-id><thread-id-or-><latest-activity-rfc3339><outcome>` under `<!-- address-review-source-state:v1`; kinds are `issue-comment`, `inline-comment`, or `review-summary`, and outcomes are `handled`, `deferred`, `declined`, `safe-to-skip`, `pending`, or `ask-user`."
assert(address_review.include?(source_state_format), "address-review must define deterministic source restart state")
assert(address_review_actions.include?(source_state_format), "address-review actions must preserve deterministic source restart state")
assert(address_review_workflow.include?(source_state_format), "address-review workflow mirror must define deterministic source restart state")
assert(address_review_templates.include?(source_state_format), "address-review templates must document deterministic source restart state")
source_state_validation = "Validate the source PR and item ID as positive decimals, the thread ID as a GitHub node ID or `-`, the activity timestamp as RFC3339, the enum fields, stable-identity uniqueness, and snapshot completeness before consuming or posting state."
assert(address_review.include?(source_state_validation), "address-review must define source state validation")
assert(address_review_actions.include?(source_state_validation), "address-review actions must define source state validation")
assert(address_review_workflow.include?(source_state_validation), "address-review workflow mirror must define source state validation")
assert(address_review_templates.include?(source_state_validation), "address-review templates must define source state validation")
source_state_filter = "On rerun, suppress a source item only when its exact source PR, kind, immutable item ID, and preserved thread ID match a terminal state row and its current latest activity is not newer than the recorded activity timestamp; `pending` and `ask-user` rows always remain eligible."
assert(address_review.include?(source_state_filter), "address-review must consume source state per item")
assert(address_review_actions.include?(source_state_filter), "address-review actions must consume source state per item")
assert(address_review_workflow.include?(source_state_filter), "address-review workflow mirror must consume source state per item")
source_state_failure = "Missing, duplicate, malformed, identity-mismatched, or incomplete source state suppresses no item and makes source readiness `UNKNOWN` until corrected; a status checkpoint never acts as a global cutoff."
assert(address_review.include?(source_state_failure), "address-review must fail closed on invalid source state")
assert(address_review_actions.include?(source_state_failure), "address-review actions must fail closed on invalid source state")
assert(address_review_workflow.include?(source_state_failure), "address-review workflow mirror must fail closed on invalid source state")
assert(address_review_templates.include?(source_state_failure), "address-review templates must fail closed on invalid source state")
assert(address_review_templates.include?("SOURCE_STATE_ROWS"), "address-review templates must accept source state rows")
assert(address_review_templates.include?("SOURCE_STATE_EXPECTED_COUNT"), "address-review templates must verify source state completeness")
assert(address_review_templates.include?("SOURCE_STATE_HAS_PENDING"), "address-review templates must derive the source cutoff guard from pending state")
assert(address_review_templates.include?("printf '<!-- address-review-source-state:v1\\n'"), "address-review templates must render the v1 source-state marker")
assert(address_review_templates.include?("source-state rows are malformed or duplicate"), "address-review templates must validate source state rows")
assert(address_review_templates.include?("/^$/ { next }"), "source state validation must tolerate blank records")
assert(address_review_templates.include?('^[A-Za-z0-9_=+\\/-]+$'), "source state validation must accept Base64 and Base64URL node IDs")
source_state_cumulative = "Every new source checkpoint carries forward unchanged valid rows and records every source candidate since `SOURCE_REVIEW_CUTOFF_AT`, including pending rows, so the latest checkpoint is a complete restart snapshot rather than a delta."
assert(address_review.include?(source_state_cumulative), "address-review must make source restart state cumulative")
assert(address_review_actions.include?(source_state_cumulative), "address-review actions must make source restart state cumulative")
assert(address_review_workflow.include?(source_state_cumulative), "address-review workflow mirror must make source restart state cumulative")
assert(address_review_templates.include?(source_state_cumulative), "address-review templates must render cumulative source restart state")

skill_checkpoint_filter = extract_source_checkpoint_filter(address_review)
workflow_checkpoint_filter = extract_source_checkpoint_filter(address_review_workflow)
assert(
  skill_checkpoint_filter.lines.map(&:strip) == workflow_checkpoint_filter.lines.map(&:strip),
  "address-review source checkpoint validators must stay mirrored"
)

valid_summary_body = <<~BODY.chomp
  <!-- address-review-summary -->
  ## Address-review replacement carryover
  <!-- address-review-source-state:v1
  item\t160\tinline-comment\t101\tPRRT_kwD==/+\t2026-07-15T00:00:00Z\thandled
  -->
BODY
valid_status_body = <<~BODY.chomp
  <!-- address-review-status -->
  ## Address-review replacement carryover
  <!-- address-review-source-state:v1
  item\t160\tissue-comment\t102\t-\t2026-07-15T00:01:00Z\tpending
  -->
BODY
invalid_duplicate_body = <<~BODY.chomp
  <!-- address-review-summary -->
  <!-- address-review-source-state:v1
  item\t160\tinline-comment\t103\tPRRT_one\t2026-07-15T00:02:00Z\thandled
  item\t160\tinline-comment\t103\tPRRT_two\t2026-07-15T00:03:00Z\thandled
  -->
BODY
checkpoint_fixture = {
  "issue_comments" => [
    { "user" => "trusted-reviewer", "created_at" => "2026-07-15T00:00:00Z", "body" => valid_summary_body },
    { "user" => "trusted-reviewer", "created_at" => "2026-07-15T00:01:00Z", "body" => valid_status_body },
    { "user" => "trusted-reviewer", "created_at" => "2026-07-15T00:02:00Z", "body" => "<!-- address-review-summary -->" },
    { "user" => "other-reviewer", "created_at" => "2026-07-15T00:03:00Z", "body" => valid_summary_body },
    { "user" => "trusted-reviewer", "created_at" => "2026-07-15T00:04:00Z", "body" => invalid_duplicate_body }
  ]
}
stdout, stderr, status = Open3.capture3(
  "jq", "-c", "--arg", "actor", "TRUSTED-REVIEWER", "--arg", "source", "160", skill_checkpoint_filter,
  stdin_data: JSON.generate(checkpoint_fixture)
)
assert(status.success?, "source checkpoint jq validator must execute: #{stderr}")
valid_checkpoints = JSON.parse(stdout)
assert(valid_checkpoints.length == 2, "source checkpoint validator must reject marker-only, wrong-author, and duplicate state")
assert(valid_checkpoints[0]["body"] == valid_status_body, "source checkpoint validator must return newest valid checkpoint first")
assert(valid_checkpoints[1]["body"] == valid_summary_body, "source checkpoint validator must accept padded Base64 node IDs")

puts "PASS pr-batch single-target entry point contract"
