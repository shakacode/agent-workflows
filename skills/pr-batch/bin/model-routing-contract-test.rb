#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
SOURCE_CHECKOUT_ENV = "AGENT_WORKFLOWS_SOURCE_CHECKOUT"
TEXT_FENCE = "```text\n"
COORDINATOR_ROUTE = "Coordinator model/effort: <model/class>/<effort>."
LAUNCH_ASSURANCE = "Launch assurance: parent <exact model>/<effort>@<source>; " \
                   "checker <exact model>/<effort>@<source>; exact-policy UNKNOWN blocks."
WORKER_ROUTE = "Worker model/effort routes: <initial model/class>/<effort> -> <lane ids>; " \
               "escalation <model/class>/<effort> after MODEL_ESCALATION_REQUEST; max <N>."
DISPATCH_RULE = "Bind actors on-host; unbound -> stop; no inheritance/substitution; " \
                "exact-policy parent mismatch/UNKNOWN -> relaunch; checker mismatch/UNKNOWN -> reserve fresh"
DISPATCH_PREFLIGHT_RULE = "Dispatch preflight: JSON-in/JSON-out; select only bound+attested requested tuple or first explicitly authorized ordered fallback; otherwise one dispatch-decision-request v1."
GOAL_DISPATCH_PREFLIGHT_LINE = "- Dispatch: pending->persist/reissue token; active->no launch; input->decision; fence->stop/reconcile."
GOAL_PERSISTED_STATE_LINE = "- Resolve `$pr-batch`; autoload/self-contained: load persisted state before preflight; persist output before resume/launch; preflight issue/PR only."
DISPATCH_PLAN_PROMPT_LINE = "Dispatch <lane_id>: route policy <hard|preferred>; requested <dispatcher>@<route>; fallbacks <dispatcher>@<route>->...|none; auth dispatch/route <y|n>/<y|n>."
PROSPECTIVE_INSTANCE_ID_RULE = "Each viable candidate includes a stable prospective `instance_id` allocated or reserved by its dispatcher before launch, only for replay/fencing; the helper neither launches nor creates a worker."
UNKNOWN_DISPATCH_EVIDENCE_RULE = "Binding, attestation, and prospective `instance_id` evidence whose trimmed case-insensitive value is `UNKNOWN` is unusable and must not select or resume Goal mode."
REPLAY_IDENTITY_RULE = "Replay identity is `lane_id`, route, dispatcher, `instance_id`, and launch token; `candidate_index` is discovery metadata rebuilt from the current candidate order."
REPLACEMENT_FENCING_RULE = "Replacement fencing returns `blocked-replacement-fencing` with required action `stop-and-reconcile-prior-instance`, preserves the active assignment and lane state, and emits no `dispatch-decision-request`; `blocked-user-input` is reserved for missing authorized route/dispatcher choice."
DISPATCH_PERSISTENCE_RULE = "Persist a selected assignment as lifecycle `launch-pending` with its idempotency launch token before worker launch; persist a request plus validated resolution, lifecycle, and replacement-proof consumption before resume or launch."
EVIDENCE_VOCABULARY_RULE = "Accepted binding evidence is `operator-selected` or `dispatcher-bound`; accepted attestation evidence is `instance-bound` or `dispatcher-attested`; `UNKNOWN` or negative evidence fails closed."
REPLACEMENT_PROOF_RULE = "A replacement proof is single-use and identity-bound to exact prior and replacement tuples, and both proof lane ids must equal the current input `lane_id`; cross-lane proof fences."
REPLAY_OUTCOME_RULE = "A matching `launch-pending` assignment reissues the same launch instruction and token; only an identity-bound `launch-confirmation v1` transitions it to `confirmed-active`, which returns `replay-already-active` with no launch instruction."
DECISION_RESOLUTION_RULE = "Persisted request history, choices, revisions, assignments, proof, confirmation, and `decision_resolution` are deep-validated; a valid resolution replays without transient `operator_decision`, while malformed nested state returns structured `invalid-input`."
SELF_CONTAINED_PERSISTENCE_RULE = "Every self-contained or autoload-failure execution path loads persisted dispatch state before preflight and persists its output before any Goal-mode resume or launch."
INDEPENDENT_ADVERSARIAL_QA_ROUTE = "Independent adversarial QA: Sol/xhigh"
ROUTINE_DETERMINISTIC_QA_ROUTE = "Routine deterministic QA: Sol/high"
CODEX_GPT56_RECOMMENDED_ROUTES = [
  "Multi-lane coordinator: Sol/xhigh",
  "Simple, positively classified worker: Terra/high",
  "Unknown or uncertain worker: Sol/high",
  "High-risk or escalated work: Sol/xhigh",
  INDEPENDENT_ADVERSARIAL_QA_ROUTE,
  ROUTINE_DETERMINISTIC_QA_ROUTE
].freeze
CLAUDE_INDEPENDENT_ADVERSARIAL_QA_ROUTE = "Independent adversarial QA: Opus 4.8/xhigh"
CLAUDE_ROUTINE_DETERMINISTIC_QA_ROUTE = "Routine deterministic QA: Opus 4.8/high"
CLAUDE_PROFILE_VERSION_MARKER = "claude-profile v0"
CLAUDE_RECOMMENDED_ROUTES = [
  "Multi-lane coordinator: Opus 4.8/xhigh",
  "Simple, positively classified worker: Sonnet 5/high",
  "Unknown or uncertain worker: Opus 4.8/xhigh",
  "High-risk or escalated work: Opus 4.8/xhigh",
  CLAUDE_INDEPENDENT_ADVERSARIAL_QA_ROUTE,
  CLAUDE_ROUTINE_DETERMINISTIC_QA_ROUTE
].freeze

def read_repo_file(path)
  File.read(File.join(ROOT, path), encoding: "UTF-8")
end

def extract_prompt(text, heading)
  heading_index = text.index(heading)
  raise "missing #{heading}" unless heading_index

  fence_start = text.index(TEXT_FENCE, heading_index)
  raise "missing text fence after #{heading}" unless fence_start

  body_start = fence_start + TEXT_FENCE.length
  body_end = text.index(/^```\s*$/, body_start)
  raise "missing closing fence after #{heading}" unless body_end

  text[body_start...body_end]
end

def extract_markdown_section(text, heading)
  heading_index = text.index(heading)
  raise "missing #{heading}" unless heading_index

  body_start = heading_index + heading.length
  next_heading = text.match(/^###\s+/, body_start)
  body_end = next_heading ? next_heading.begin(0) : text.length
  text[body_start...body_end]
end

def normalized(text)
  text.gsub(/\s+/, " ").strip
end

def source_checkout?
  ENV[SOURCE_CHECKOUT_ENV] == "1"
end

class ModelRoutingContractTest < Minitest::Test
  def test_goal_prompts_separate_coordinator_assignment_from_worker_routes
    prompts = {
      "workflow" => extract_prompt(read_repo_file("workflows/pr-processing.md"), "### Plan To Goal Handoff"),
      "pr-batch" => extract_prompt(read_repo_file("skills/pr-batch/SKILL.md"), "## Goal Prompt Template"),
      "plan-pr-batch" => extract_prompt(read_repo_file("skills/plan-pr-batch/SKILL.md"), "## Goal Prompt for pr-batch")
    }

    prompts.each do |label, prompt|
      assert_includes prompt, COORDINATOR_ROUTE, "#{label} prompt must pin the parent separately"
      assert_includes prompt, LAUNCH_ASSURANCE, "#{label} prompt must carry fail-closed launch assurance"
      assert_includes prompt, WORKER_ROUTE, "#{label} prompt must carry an initial and escalation route"
      assert_includes prompt, DISPATCH_RULE, "#{label} prompt must separate worker binding from exact-parent relaunch"
      assert_includes prompt, GOAL_DISPATCH_PREFLIGHT_LINE,
                      "#{label} prompt must gate automatic Goal-mode resume on dispatcher preflight"
      assert_includes prompt, GOAL_PERSISTED_STATE_LINE,
                      "#{label} prompt must persist dispatch state on every autoload fallback path"
      assert_includes prompt, DISPATCH_PLAN_PROMPT_LINE,
                      "#{label} prompt must carry lane-keyed dispatcher, fallback, and authority input"
      refute_includes prompt, "Model/effort groups:", "#{label} prompt must not use the static assignment field"
    end
  end

  def test_canonical_workflow_defines_cost_aware_staged_routing
    routing = normalized(
      extract_markdown_section(read_repo_file("workflows/pr-processing.md"), "### Model And Effort Routing")
    )

    [
      "Coordinator assignment",
      "Launch assurance",
      "before target interpretation, planning, or dispatch",
      "When operator policy requires an exact parent or checker",
      "effective instance-bound runtime state",
      "mutable default configuration alone",
      "A prompt cannot upgrade its parent",
      "fresh qualifying checker is reserved",
      "Without an exact-parent or exact-checker policy",
      "Independent checker assignment",
      "Sol/high",
      "Terra/high",
      "coordinator-approved execution envelope",
      "workers must not inherit the coordinator assignment",
      "A small, explainable first failure stays on the initial route",
      "two materially different, credible attempts",
      "`MODEL_ESCALATION_REQUEST`",
      "Plan review is the preferred escalation",
      "return bounded implementation to the initial worker tier",
      "strongest-led implementation"
    ].each do |phrase|
      assert_includes routing, phrase, "canonical workflow is missing staged-routing rule: #{phrase}"
    end

    assert_includes routing, "preserve unavailable binding as `UNKNOWN` and continue portable class-based planning"
    assert_includes routing, DISPATCH_PREFLIGHT_RULE
  end

  def test_dispatcher_capability_preflight_is_portable_and_documented
    helper = File.join(ROOT, "skills/pr-batch/bin/dispatcher-capability-preflight")
    assert File.executable?(helper), "dispatcher capability preflight must be executable"

    guide = read_repo_file("docs/agent-workflows-model-routing.md")
    docs = read_repo_file("docs/pr-batch-skills.md")
    context = read_repo_file("CONTEXT.md")
    [guide, docs, context, read_repo_file("skills/plan-pr-batch/SKILL.md"), read_repo_file("skills/pr-batch/SKILL.md"),
     read_repo_file("skills/triage/SKILL.md"), read_repo_file("workflows/pr-processing.md")].each do |text|
      assert_includes text, "dispatch-decision-request v1"
      assert_includes text, "dispatcher-capability-preflight"
      assert_includes text, PROSPECTIVE_INSTANCE_ID_RULE
      assert_includes text, UNKNOWN_DISPATCH_EVIDENCE_RULE
      assert_includes text, REPLAY_IDENTITY_RULE
      assert_includes text, REPLACEMENT_FENCING_RULE
      assert_includes text, DISPATCH_PERSISTENCE_RULE
      assert_includes text, EVIDENCE_VOCABULARY_RULE
      assert_includes text, REPLACEMENT_PROOF_RULE
      assert_includes text, REPLAY_OUTCOME_RULE
      assert_includes text, DECISION_RESOLUTION_RULE
      assert_includes text, SELF_CONTAINED_PERSISTENCE_RULE
    end

    portable_call = '"${PR_BATCH_SKILL_DIR}/bin/dispatcher-capability-preflight"'
    [guide, docs, read_repo_file("skills/plan-pr-batch/SKILL.md"), read_repo_file("workflows/pr-processing.md")].each do |text|
      assert_includes text, "PR_BATCH_SKILL_DIR"
      assert_includes text, portable_call
      refute_includes text, "skills/pr-batch/bin/dispatcher-capability-preflight"
    end
  end

  def test_worker_replacement_is_checkpointed_fenced_and_non_overlapping
    replacement = normalized(
      extract_markdown_section(
        read_repo_file("workflows/pr-processing.md"),
        "### Worker Model Replacement And Escalation"
      )
    )

    [
      "`MODEL_REPLACEMENT_HANDOFF`",
      "preserve the lane identity, worktree, branch, and useful changes",
      "confirm the old instance has stopped",
      "old and replacement instances must not overlap",
      "Reconcile the claim holder, generation, and instance",
      "initial and final model/effort",
      "credible attempt count",
      "escalation disposition"
    ].each do |phrase|
      assert_includes replacement, phrase, "replacement protocol is missing: #{phrase}"
    end
  end

  def test_ready_routes_require_both_tiers_and_group_by_complete_policy
    planner = normalized(read_repo_file("skills/plan-pr-batch/SKILL.md"))
    workflow = normalized(
      extract_markdown_section(read_repo_file("workflows/pr-processing.md"), "### Model And Effort Routing")
    )

    assert_includes planner, "If either the initial or escalation route cannot be named"
    assert_includes planner, "Do not call the prompt ready"
    assert_includes workflow, "Collate lanes with matching complete worker model/effort routes"
    assert_includes workflow, "initial assignment, escalation assignment, evidence gate, and maximum escalation count"
    refute_includes workflow, "matching initial routes only"
  end

  def test_recovery_prompt_preserves_parent_and_replaces_nonconforming_workers
    section = extract_markdown_section(
      read_repo_file("workflows/pr-processing.md"),
      "### Model-Routing Recovery Prompt"
    )
    prompt = normalized(extract_prompt(section, "Use this prompt"))

    [
      "Continue the existing goal; do not clear it or start a new batch",
      "After launch assurance passes, keep the compliant parent coordinator on",
      LAUNCH_ASSURANCE,
      "When the existing goal requires an exact checker",
      "On mismatch or UNKNOWN, stop until a fresh qualifying checker is reserved",
      "Only when neither an exact-parent nor exact-checker policy applies",
      "Inventory every active worker",
      "`MODEL_REPLACEMENT_HANDOFF`",
      "Confirm the old instance has stopped",
      WORKER_ROUTE,
      "Preserve each lane's route mapping",
      "Do not allow a worker to inherit the coordinator assignment",
      "`MODEL_ESCALATION_REQUEST`",
      "Plan review is preferred",
      "merge_authority"
    ].each do |phrase|
      assert_includes prompt, phrase, "recovery prompt is missing: #{phrase}"
    end

    refute_includes prompt, "Worker initial route: <model/class>/<effort>",
                    "recovery prompt must not collapse per-lane routes into one batch-wide pair"
    refute_includes prompt, "Do not stop, replace, or downgrade the parent",
                    "recovery prompt must not preserve a parent before launch assurance passes"
  end

  def test_continuation_entry_points_distinguish_batch_recovery_from_worker_restart
    %w[
      skills/plan-pr-batch/SKILL.md
      skills/pr-batch/SKILL.md
    ].each do |path|
      entry = normalized(read_repo_file(path))

      assert_includes entry,
                      "saved handoff explicitly requests model-route replacement or identifies workers on a wrong or too-expensive route",
                      "#{path} must detect model-routing recovery handoffs"
      assert_includes entry, "`MODEL_REPLACEMENT_HANDOFF` alone does not prove whole-batch route recovery",
                      "#{path} must not confuse a worker restart handoff with batch recovery"
      assert_includes entry, "Model-Routing Recovery Prompt",
                      "#{path} must route model handoffs through fenced recovery"
      assert_includes entry, "Bounded Status Recovery",
                      "#{path} must route standalone worker restart handoffs through live-state recovery"
      assert_includes entry, "Otherwise use the",
                      "#{path} must reserve generic continuation for non-model handoffs"
    end
  end

  def test_user_guide_carries_the_cost_aware_model_playbook
    guide = read_repo_file("docs/agent-workflows-model-routing.md")

    [
      "GPT-5.6 Sol",
      "GPT-5.6 Terra",
      "GPT-5.5",
      "Conservative GPT-5.6 Profile",
      "Sol diagnosis and envelope → Terra implementation → Sol check",
      "Luna is outside this conservative profile",
      "## Verification Matrix",
      "First-pass acceptance rate",
      "Percentage of tasks escalated",
      "Do not assume that maximum reasoning always improves outcomes"
    ].each do |phrase|
      assert_includes guide, phrase, "model-routing guide is missing playbook content: #{phrase}"
    end

    return unless source_checkout?

    assert_includes read_repo_file("docs/README.md"), "[Cost-aware model routing](agent-workflows-model-routing.md)"
  end

  def test_codex_gpt56_recommendation_is_memorialized_across_routing_surfaces
    paths = %w[
      docs/agent-workflows-model-routing.md
      docs/pr-batch-skills.md
      skills/plan-pr-batch/SKILL.md
      skills/post-merge-audit/SKILL.md
      skills/pr-batch/SKILL.md
      skills/triage/SKILL.md
      workflows/post-merge-audit.md
      workflows/pr-processing.md
    ]

    paths.each do |path|
      text = normalized(read_repo_file(path))

      CODEX_GPT56_RECOMMENDED_ROUTES.each do |route|
        assert_includes text, route, "#{path} is missing the recommended Codex route: #{route}"
      end

      refute_includes text, "Terra/medium", "#{path} must not restore Terra/medium to the Codex profile"
    end

    checker = normalized(read_repo_file("workflows/continuous-evaluation-loop.md"))
    assert_includes checker, INDEPENDENT_ADVERSARIAL_QA_ROUTE
    assert_includes checker, ROUTINE_DETERMINISTIC_QA_ROUTE

    %w[
      skills/adversarial-pr-review/SKILL.md
      workflows/adversarial-pr-review.md
    ].each do |path|
      assert_includes normalized(read_repo_file(path)), INDEPENDENT_ADVERSARIAL_QA_ROUTE
    end

    triage = normalized(read_repo_file("skills/triage/SKILL.md"))
    assert_includes triage, "Do not encode unverified exact model or tool names as portable defaults"
    refute_includes triage, "Do not encode model or tool names in the skill"

    guide = normalized(read_repo_file("docs/agent-workflows-model-routing.md"))
    assert_includes guide, "Routine deterministic QA uses Sol/high"
    refute_includes guide, "Routine deterministic QA may use Sol/high"
    assert_includes guide, "`xhigh` is the extra-high reasoning-effort tier above `high`"
    assert_includes guide, "deliberate conservative baselines for multi-lane coordination and independent adversarial QA"

    {
      "docs/agent-workflows-model-routing.md" => "Other unknown or uncertainty routes to Sol/high",
      "workflows/pr-processing.md" => "Any other missing or disputed simplicity criterion routes to Sol/high"
    }.each do |path, uncertainty_fallback|
      text = normalized(read_repo_file(path))
      assert_includes text, "explicit acceptance criteria"
      assert_includes text, "known bounded file surface"
      assert_includes text, "strong deterministic verification oracle"
      assert_includes text, "no unresolved design decision"
      assert_includes text, "no security, authorization, concurrency, persistence, lifecycle, routing, or public-contract change"
      assert_includes text, "easy failure detection and rollback"
      assert_includes text, "Any present or disputed high-risk boundary routes to Sol/xhigh"
      assert_includes text, uncertainty_fallback
    end
  end

  def test_claude_recommendation_is_memorialized_across_routing_surfaces
    paths = %w[
      docs/agent-workflows-model-routing.md
      docs/pr-batch-skills.md
      skills/plan-pr-batch/SKILL.md
      skills/post-merge-audit/SKILL.md
      skills/pr-batch/SKILL.md
      skills/triage/SKILL.md
      workflows/post-merge-audit.md
      workflows/pr-processing.md
    ]

    paths.each do |path|
      text = normalized(read_repo_file(path))

      CLAUDE_RECOMMENDED_ROUTES.each do |route|
        assert_includes text, route, "#{path} is missing the recommended Claude route: #{route}"
      end

      assert_includes text, CLAUDE_PROFILE_VERSION_MARKER,
                      "#{path} must mark the Claude profile as versioned and provisional"
      refute_includes text, "Sonnet 5/medium", "#{path} must not introduce Sonnet 5/medium into the Claude profile"
    end

    checker = normalized(read_repo_file("workflows/continuous-evaluation-loop.md"))
    assert_includes checker, CLAUDE_INDEPENDENT_ADVERSARIAL_QA_ROUTE
    assert_includes checker, CLAUDE_ROUTINE_DETERMINISTIC_QA_ROUTE

    %w[
      skills/adversarial-pr-review/SKILL.md
      workflows/adversarial-pr-review.md
    ].each do |path|
      assert_includes normalized(read_repo_file(path)), CLAUDE_INDEPENDENT_ADVERSARIAL_QA_ROUTE
    end

    guide = normalized(read_repo_file("docs/agent-workflows-model-routing.md"))
    assert_includes guide, "## Conservative Claude Profile (provisional)"
    assert_includes guide, "provisional pending the observed route receipts and comparative evidence"
    assert_includes guide, "Routine deterministic QA uses Opus 4.8/high"
    refute_includes guide, "Routine deterministic QA may use Opus 4.8/high"
    assert_includes guide, "Never make Fable 5 or `max` effort a default route"
    assert_includes guide, "Haiku 4.5 is outside this provisional profile"
    assert_includes guide,
                    "deliberate conservative baselines for multi-lane coordination, uncertain work, and independent adversarial QA"

    %w[
      docs/agent-workflows-model-routing.md
      workflows/pr-processing.md
    ].each do |path|
      text = normalized(read_repo_file(path))
      assert_includes text, "Any present or disputed high-risk boundary routes to Opus 4.8/xhigh"
      assert_includes text, "Any other missing or disputed simplicity criterion routes to Opus 4.8/xhigh"
    end
  end

  def test_glossary_models_staged_routes_and_replacement_evidence
    skip "source-pack glossary is not installed" unless source_checkout?

    context = normalized(read_repo_file("CONTEXT.md"))

    [
      "**Coordinator model/effort assignment**",
      "**Batch launch assurance**",
      "exact checker model/effort required by operator policy",
      "exact parent or checker",
      "**Worker execution envelope**",
      "**Worker model/effort route**",
      "**Active model/effort assignment**",
      "**Model escalation request**",
      "**Model replacement handoff**",
      "**Model/effort route group**",
      "exactly one active **Active model/effort assignment**",
      "old and replacement worker instances never overlap"
    ].each do |phrase|
      assert_includes context, phrase, "CONTEXT.md is missing staged-routing vocabulary: #{phrase}"
    end

    refute_includes context, "**Model/effort group**"
  end

  def test_source_docs_gate_launch_assurance_before_target_verification
    skip "source-pack docs are not installed" unless source_checkout?

    docs = read_repo_file("docs/pr-batch-skills.md")
    launch_gate = docs.index("4. Record `Launch assurance`")
    target_verification = docs.index("5. Verify every candidate through GitHub")

    refute_nil launch_gate
    refute_nil target_verification
    assert_operator launch_gate, :<, target_verification
    [DISPATCH_PERSISTENCE_RULE, EVIDENCE_VOCABULARY_RULE].each do |rule|
      assert_match(/^   #{Regexp.escape(rule)}/, docs, "item 4 continuation must retain exactly three spaces")
    end
  end

  def test_planning_and_dispatch_surfaces_propagate_routes
    paths = %w[
      skills/plan-pr-batch/SKILL.md
      skills/pr-batch/SKILL.md
      skills/triage/SKILL.md
    ]
    paths << "docs/pr-batch-skills.md" if source_checkout?

    paths.each do |path|
      text = read_repo_file(path)
      assert_includes text, "Coordinator model/effort", "#{path} must separate the parent assignment"
      assert_includes text, "Launch assurance", "#{path} must preserve the launch gate"
      assert_includes text, "Worker model/effort route", "#{path} must plan staged worker routes"
      assert_includes text, "MODEL_ESCALATION_REQUEST", "#{path} must carry the escalation gate"
      refute_includes text, "Model/effort groups:", "#{path} must not retain the static prompt field"
    end

    pr_batch = read_repo_file("skills/pr-batch/SKILL.md")
    pr_batch_normalized = normalized(pr_batch)
    assert_includes pr_batch, "Model-Routing Recovery Prompt"
    assert_includes pr_batch, "Worker Model Replacement And Escalation"
    assert_includes pr_batch_normalized, "independent-checker model/effort plus its qualifying binding source"
    assert_includes pr_batch_normalized, "parent mismatch or `UNKNOWN`"
    assert_includes pr_batch_normalized, "correctly bound coordinator relaunch"
    assert_includes pr_batch_normalized,
                    "checker mismatch or `UNKNOWN` requires reserving a fresh qualifying checker"
    assert_includes pr_batch_normalized, "Without an exact-parent or exact-checker policy"

    planner = normalized(read_repo_file("skills/plan-pr-batch/SKILL.md"))
    assert_includes planner, "exact-parent or exact-checker"
    assert_includes planner, "continue portable class-based planning"
    assert_includes planner, "exact policy-required checker route"
    assert_includes planner, "checker reservation"
    assert_includes planner, "freshness, and independence when it starts"
  end

  def test_triage_launch_assurance_precedes_inventory
    triage = read_repo_file("skills/triage/SKILL.md")
    launch_gate = triage.index("2. **Launch assurance**")
    inventory = triage.index("## Phase 1: Inventory And Graph")

    refute_nil launch_gate
    refute_nil inventory
    assert_operator launch_gate, :<, inventory

    preconditions = normalized(triage[launch_gate...inventory])
    [
      "before repository or target interpretation",
      "Under an exact-parent policy, a parent mismatch or `UNKNOWN` requires a correctly bound coordinator relaunch",
      "Under an exact-checker policy, a checker mismatch or `UNKNOWN` requires reserving a fresh qualifying checker",
      "For either actor without an exact policy, preserve that actor's unavailable binding as `UNKNOWN`",
      "continue portable class-based triage"
    ].each do |phrase|
      assert_includes preconditions, phrase, "triage launch precondition is missing: #{phrase}"
    end
  end

  def test_continuous_checker_is_strong_independent_and_fail_closed
    checker_text = read_repo_file("workflows/continuous-evaluation-loop.md")
    checker = normalized(checker_text)

    [
      "distinct from every maker",
      "exact model/effort",
      "conservative GPT-5.6 profile",
      "Independent adversarial QA: Sol/xhigh",
      "Routine deterministic QA: Sol/high",
      "Terra may collect mechanical evidence",
      "may not issue the qualifying intent-achievement or final-risk verdict",
      "do not return a clean/`realized` verdict",
      "Without an exact-checker policy",
      "continue portable class-based evaluation",
      "missing binding alone does not block an otherwise evidence-backed `realized` classification"
    ].each do |phrase|
      assert_includes checker, phrase, "continuous checker contract is missing: #{phrase}"
    end

    loop_prompt = normalized(extract_prompt(checker_text, "## Loop Prompt"))
    [
      "distinct from every maker",
      "exact model/effort",
      "Checker policy: <exact model>/<effort> via <binding source> | no exact-checker policy",
      "If independence is unavailable or UNKNOWN, stop short of a clean/realized verdict",
      "When an exact checker is required",
      "mismatched, unavailable, below-policy, or UNKNOWN exact model/effort or binding also blocks",
      "Without an exact-checker policy",
      "continue portable class-based evaluation",
      "do not block an otherwise evidence-backed clean/realized verdict solely for that reason",
      "checker_route_compliance: UNKNOWN|failed"
    ].each do |phrase|
      assert_includes loop_prompt, phrase, "continuous checker Loop Prompt is missing: #{phrase}"
    end
  end

  def test_post_merge_independent_audit_prompt_is_fail_closed
    audit_text = read_repo_file("workflows/post-merge-audit.md")
    audit_prompt = normalized(extract_prompt(audit_text, "## Independent Audit Prompt"))
    audit_skill = normalized(read_repo_file("skills/post-merge-audit/SKILL.md"))

    assert_includes normalized(audit_text),
                    "one launch-assured policy-compliant run as the qualifying checker"
    refute_includes normalized(audit_text), "one launch-assured Sol run as the qualifying checker"
    assert_includes audit_skill, "exact fresh qualifying-checker reservation needed"
    refute_includes audit_skill, "the relaunch needed"
    [normalized(audit_text), audit_skill].each do |text|
      assert_includes text, "Sonnet may collect mechanical evidence but does not issue the qualifying verdict"
    end

    [
      "Audit role: <qualifying-checker | advisory-auditor>",
      "For completed-batch audit with `Audit role: qualifying-checker`",
      "fresh instance independent from every maker",
      "identity, exact model/effort, binding source",
      "Host session metadata, effective instance-bound runtime state, or explicit operator-selected launch configuration",
      "mutable default configuration, installed rosters, dispatch-resolved classes, prompt text, and model self-report do not",
      "Terra may collect mechanical evidence but must not issue the qualifying audit verdict",
      "Opus 4.8/high is limited to routine deterministic QA",
      "Sonnet may collect mechanical evidence but must not issue the qualifying audit verdict",
      "If checker identity, exact model/effort, binding source, or independence is unavailable",
      "below policy, or `UNKNOWN`",
      "do not return a clean verdict",
      "checker_route_compliance: UNKNOWN|failed",
      "exact fresh qualifying-checker reservation needed",
      "For `Audit role: advisory-auditor`",
      "checker_route_compliance: not_applicable (advisory)",
      "do not issue the qualifying clean/ready verdict",
      "Concrete advisory findings still require coordinator triage",
      "If `Audit role` is missing, unresolved, invalid, or `UNKNOWN`, record `checker_route_compliance: UNKNOWN`; collect and report evidence only, and do not issue the qualifying clean/ready verdict"
    ].each do |phrase|
      assert_includes audit_prompt, phrase, "post-merge Independent Audit Prompt is missing: #{phrase}"
    end

    refute_includes audit_prompt, "checker reservation or relaunch needed"
  end

  def test_worker_assignment_evidence_is_carried_in_lane_cards
    %w[
      workflows/pr-processing.md
      skills/pr-batch/SKILL.md
      skills/plan-pr-batch/SKILL.md
      skills/triage/SKILL.md
    ].each do |path|
      assert_includes read_repo_file(path), "exact model/effort+binding",
                      "#{path} Lane Card must expose worker assignment evidence"
    end

    worker_rules = normalized(
      extract_markdown_section(read_repo_file("workflows/pr-processing.md"), "### Worker Rules")
    )
    assert_includes worker_rules, "`Assignment:` `<exact-model>/<effort>`"
    assert_includes worker_rules, "`binding:` `<host/session/runtime/operator source|UNKNOWN>`"
    assert_includes worker_rules, "Prompt text or worker self-report alone is not binding evidence"
  end

  def test_planners_preserve_checker_independence_and_worker_stop_conditions
    %w[
      skills/plan-pr-batch/SKILL.md
      skills/triage/SKILL.md
    ].each do |path|
      planner = normalized(read_repo_file(path)).downcase
      [
        "fresh strongest-capability instance distinct from every maker",
        "may collect mechanical evidence but may not issue the qualifying intent, risk, or readiness verdict",
        "contradictory evidence",
        "ambiguous criteria",
        "scope or risk growth",
        "weakened verification",
        "consequential judgment"
      ].each do |phrase|
        assert_includes planner, phrase, "#{path} is missing checker/envelope rule: #{phrase}"
      end
    end
  end
end
