#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
SOURCE_CHECKOUT_ENV = "AGENT_WORKFLOWS_SOURCE_CHECKOUT"
TEXT_FENCE = "```text\n"

ADVISORY_ROUTE_RULE =
  "Model and effort selections are advisory preferences: an unavailable or different model or effort never alone blocks launch, replay, review, or audit."
OBSERVED_HOST_RULE =
  "Record host-observed host, model, and effort only when the host exposes them; otherwise record each unavailable field as `UNKNOWN`, and never infer observations from requested preferences, prompts, or model self-report."
ORDINARY_ACTIVATION_RULE =
  "Assignment activation uses ordinary durable lifecycle state; no project signing key, fixed trust anchor, launch-confirmation receipt, or human waiver is required."
REPLAY_IDENTITY_RULE =
  "Replay identity is `lane_id`, dispatcher, `instance_id`, and launch token; route preference, observed host fields, and `candidate_index` are metadata and never trigger replacement."
DISPATCH_PERSISTENCE_RULE =
  "Persist `launch-pending` before worker launch; after spawn, persist ordinary `active` state before Goal-mode resume, and replay the same token while pending or emit no new launch while active."
REPLACEMENT_FENCING_RULE =
  "A dispatcher or instance change still requires stop/reconcile replacement fencing and a single-use proof bound to the exact prior and replacement assignment identities."
CHECKER_RULE =
  "Checker independence and evidence quality remain mandatory; a preferred checker model or effort is advisory and its unavailability alone does not block an otherwise qualifying verdict."
VERDICT_QUALIFICATION_RULE =
  "Named models, efforts, and route classes are recommendations only; an independent review, audit, readiness, or checker verdict qualifies by role separation, scope, current-head evidence, and evidence quality, not by route."
ROUTE_NONDISQUALIFICATION_RULE =
  "A host-observed model, effort, or route mismatch, unavailability, or `UNKNOWN` never alone disqualifies an otherwise independent, evidence-backed review, audit, readiness, or checker verdict."
EXECUTION_ROUTE_ADVISORY_RULE =
  "Named coordinator and worker models, efforts, and route classes are recommendations; no named route is a prerequisite for planning, launch, coordination, execution, escalation, or fallback."
EXECUTION_ROUTE_FALLBACK_RULE =
  "When a preferred route is unavailable, different, inherited, or `UNKNOWN`, use the closest available route or runtime default, record requested and host-observed fields honestly, and continue unless an independent risk, scope, evidence, or authority gate blocks."
MODEL_NEUTRAL_RISK_RULE =
  "Risk classification, execution-envelope requirements, and stop or return conditions depend on lane ambiguity, scope, security, consequence, and verification strength, not on model identity."
MODEL_NEUTRAL_ENVELOPE_RULE =
  "Require an execution envelope when lane risk or bounded delegation requires one; approval is role-based and never requires a named model."
ADVERSARIAL_ADVISORY_RULE =
  "Preferred route, model, and effort are advisory for adversarial review; mismatch or unavailability alone does not disqualify an otherwise independent, evidence-backed adversarial verdict."
ADVERSARIAL_OBSERVATION_RULE =
  "Record observed host, model, and effort only from host-exposed runtime evidence; use literal `UNKNOWN` for every unavailable field, and never infer observations from the preference, prompt text, or model self-report."
ADVERSARIAL_QUALITY_RULE =
  "Reviewer independence and evidence quality remain mandatory regardless of the preferred or observed route."
HOST_ROLLOUT_MATRIX_RULE =
  "Before any host-owned fact becomes a portable mandatory gate, the proposal must name an accountable owner for each producer, verifier, provisioner, and installer role and define clean-install acceptance for every supported host."
HOST_ROLLOUT_OPTIONAL_RULE =
  "If any role or clean-install acceptance is absent, the capability remains optional and advisory; unavailable host-owned fields use `UNKNOWN` and do not block otherwise valid workflow progress."

ROUTING_SURFACES = %w[
  CONTEXT.md
  docs/pr-batch-skills.md
  docs/agent-workflows-model-routing.md
  skills/plan-pr-batch/SKILL.md
  skills/pr-batch/SKILL.md
  skills/triage/SKILL.md
  workflows/pr-processing.md
].freeze

CHECKER_SURFACES = %w[
  CONTEXT.md
  docs/agent-workflows-model-routing.md
  docs/pr-batch-skills.md
  skills/adversarial-pr-review/SKILL.md
  skills/plan-pr-batch/SKILL.md
  skills/post-merge-audit/SKILL.md
  skills/pr-batch/SKILL.md
  skills/triage/SKILL.md
  workflows/adversarial-pr-review.md
  workflows/continuous-evaluation-loop.md
  workflows/post-merge-audit.md
  workflows/pr-processing.md
].freeze

ROUTE_DISQUALIFICATION_PATTERNS = {
  "named route forbidden from qualifying verdict" =>
    /\b(?:Sol|Terra|Opus|Sonnet)\b.{0,160}(?:may not|must not|does not) issue.{0,80}qualifying/im,
  "qualifying verdict assigned to a named route" =>
    /qualifying.{0,120}\b(?:uses|is)\b.{0,80}\b(?:Sol|Terra|Opus|Sonnet)\b/im,
  "named route limited below qualifying review" =>
    /\b(?:Sol|Terra|Opus|Sonnet)\b.{0,80}limited to routine deterministic QA/im,
  "cheaper route forbidden from qualifying verdict" =>
    /cheaper route.{0,120}(?:may not|must not|does not).{0,80}qualifying/im,
  "route compliance used as checker qualification" => /checker_route_compliance/i,
  "route classified below policy" => /below-policy/i,
  "route mismatch used to downgrade a verdict" => /do not downgrade/i,
  "launch assurance used to qualify a checker" => /launch-assured policy-compliant run/i
}.freeze

NAMED_EXECUTION_ENFORCEMENT_PATTERNS = {
  "named model denied coordinator or initiator work" =>
    /\b(?:Sol|Terra|Opus|Sonnet|Fable|Luna|Haiku|GPT-5\.5)\b.{0,100}may not initiate or coordinate/im,
  "named model allowed only for a worker class" =>
    /\b(?:Sol|Terra|Opus|Sonnet|Fable|Luna|Haiku|GPT-5\.5)\b.{0,40}(?:is |remains )?(?:allowed|available) only/im,
  "named model required to stop editing" =>
    /\b(?:Sol|Terra|Opus|Sonnet|Fable|Luna|Haiku|GPT-5\.5)\b.{0,40}stops without editing/im,
  "execution envelope approved by a named model" =>
    /\b(?:Sol|Opus)-approved execution envelope/im,
  "named worker route requires simple classification" =>
    %r{\b(?:Terra|Sonnet)(?: 5)?/high requires\b}im,
  "named route forced by risk classification" =>
    /(?:boundary|criterion|uncertainty) routes? to \b(?:Sol|Opus|Terra|Sonnet)\b/im,
  "runtime fallback prohibited from inheriting a route" =>
    /workers must not inherit the coordinator preference/im,
  "exact supported pair required before execution" =>
    /(?:needs?|requires?|until dispatch binds).{0,80}exact supported pair|exact supported pair.{0,80}(?:required|prerequisite)/im,
  "exact model identity required for routing" => /require an exact model/im
}.freeze

ROUTE_AUTHORITY_ENFORCEMENT_PATTERNS = {
  "route preference described as requiring authority" =>
    /\b(?:(?:explicit\s+)?route(?:\s+and\s+dispatch)?\s+authority|explicit authority for (?:the )?route)\b/im
}.freeze

CODEX_RECOMMENDATIONS = [
  "Multi-lane coordinator: Sol/xhigh",
  "Simple, positively classified worker: Terra/high",
  "Unknown or uncertain worker: Sol/high",
  "High-risk or escalated work: Sol/xhigh",
  "Independent adversarial QA: Sol/xhigh",
  "Routine deterministic QA: Sol/high"
].freeze

CLAUDE_RECOMMENDATIONS = [
  "Multi-lane coordinator: Opus 4.8/xhigh",
  "Simple, positively classified worker: Sonnet 5/high",
  "Unknown or uncertain worker: Opus 4.8/xhigh",
  "High-risk or escalated work: Opus 4.8/xhigh",
  "Independent adversarial QA: Opus 4.8/xhigh",
  "Routine deterministic QA: Opus 4.8/high"
].freeze

def read_repo_file(path)
  File.read(File.join(ROOT, path), encoding: "UTF-8")
end

def normalized(text)
  text.gsub(/\s+/, " ").strip
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

class ModelRoutingContractTest < Minitest::Test
  def test_active_routing_surfaces_share_the_advisory_unsigned_lifecycle_contract
    ROUTING_SURFACES.each do |path|
      text = normalized(read_repo_file(path))

      [
        ADVISORY_ROUTE_RULE,
        OBSERVED_HOST_RULE,
        ORDINARY_ACTIVATION_RULE,
        REPLAY_IDENTITY_RULE,
        DISPATCH_PERSISTENCE_RULE,
        REPLACEMENT_FENCING_RULE
      ].each do |rule|
        assert_includes text, rule, "#{path} is missing: #{rule}"
      end
    end
  end

  def test_active_routing_surfaces_do_not_restore_project_signing_or_hard_route_gates
    ROUTING_SURFACES.each do |path|
      text = read_repo_file(path)

      refute_includes text, ".agents/dispatcher-launch-trust.json", path
      refute_includes text, "RSA-SHA256", path
      refute_includes text, "exact-policy UNKNOWN blocks", path
      refute_includes text, "hard route", path
    end
  end

  def test_goal_prompts_describe_preferences_observations_and_ordinary_activation
    prompts = {
      "workflow" => extract_prompt(read_repo_file("workflows/pr-processing.md"), "### Plan To Goal Handoff"),
      "pr-batch" => extract_prompt(read_repo_file("skills/pr-batch/SKILL.md"), "## Goal Prompt Template"),
      "plan-pr-batch" => extract_prompt(read_repo_file("skills/plan-pr-batch/SKILL.md"), "## Goal Prompt for pr-batch")
    }

    prompts.each do |label, prompt|
      assert_includes prompt, "Coordinator model/effort preference:", label
      assert_includes prompt, "Worker model/effort preferences:", label
      assert_includes prompt, "Observed host/model/effort:", label
      assert_includes prompt, "ordinary pending/active lifecycle", label
      refute_includes prompt, "Launch assurance:", label
      refute_includes prompt, "exact-policy", label
    end
  end

  def test_dispatcher_helper_is_portable_unsigned_and_preserves_dispatcher_fencing
    helper_path = File.join(ROOT, "skills/pr-batch/bin/dispatcher-capability-preflight")
    source = File.read(helper_path, encoding: "UTF-8")

    assert File.executable?(helper_path)
    assert_includes source, "blocked-replacement-fencing"
    assert_includes source, "stop-and-reconcile-prior-instance"
    assert_includes source, "replacement-proof"
    assert_includes source, "launch-pending"
    assert_includes source, '"active"'
    refute_includes source, "OpenSSL"
    refute_includes source, "dispatcher-launch-trust"
    refute_includes source, "launch_confirmation"
  end

  def test_checker_surfaces_preserve_independence_and_quality_without_route_blocking
    CHECKER_SURFACES.each do |path|
      text = normalized(read_repo_file(path))

      assert_includes text, CHECKER_RULE, path
      assert_includes text.downcase, "independent", path
    end
  end

  def test_review_audit_and_planning_surfaces_never_qualify_verdicts_by_route
    CHECKER_SURFACES.each do |path|
      text = normalized(read_repo_file(path))

      assert_includes text, VERDICT_QUALIFICATION_RULE, path
      assert_includes text, ROUTE_NONDISQUALIFICATION_RULE, path
      ROUTE_DISQUALIFICATION_PATTERNS.each do |label, pattern|
        refute_match pattern, text, "#{path}: #{label}"
      end
    end
  end

  def test_active_execution_surfaces_never_enforce_named_model_routes
    ROUTING_SURFACES.each do |path|
      text = normalized(read_repo_file(path))

      [
        EXECUTION_ROUTE_ADVISORY_RULE,
        EXECUTION_ROUTE_FALLBACK_RULE,
        MODEL_NEUTRAL_RISK_RULE,
        MODEL_NEUTRAL_ENVELOPE_RULE
      ].each do |rule|
        assert_includes text, rule, "#{path} is missing: #{rule}"
      end
      NAMED_EXECUTION_ENFORCEMENT_PATTERNS.each do |label, pattern|
        refute_match pattern, text, "#{path}: #{label}"
      end
      ROUTE_AUTHORITY_ENFORCEMENT_PATTERNS.each do |label, pattern|
        refute_match pattern, text, "#{path}: #{label}"
      end
    end
  end

  def test_adversarial_review_surfaces_keep_route_advisory_without_weakening_the_verdict
    %w[
      skills/adversarial-pr-review/SKILL.md
      workflows/adversarial-pr-review.md
    ].each do |path|
      text = normalized(read_repo_file(path))

      assert_includes text, ADVERSARIAL_ADVISORY_RULE, path
      assert_includes text, ADVERSARIAL_OBSERVATION_RULE, path
      assert_includes text, ADVERSARIAL_QUALITY_RULE, path
      refute_includes text, "Do not downgrade this qualifying adversarial verdict", path
      refute_includes text,
                      "remains the route for routine deterministic QA, not this qualifying adversarial verdict",
                      path
    end
  end

  def test_host_owned_hard_gates_require_an_owned_end_to_end_rollout
    contract = normalized(read_repo_file("docs/host-adapter/contract.md"))

    assert_includes contract, HOST_ROLLOUT_MATRIX_RULE
    assert_includes contract, HOST_ROLLOUT_OPTIONAL_RULE
  end

  def test_signed_launch_postmortem_has_accountable_followup_owners_and_resumption_boundary
    postmortem = normalized(
      read_repo_file("docs/postmortems/2026-08-06-unsupported-signed-launch-enforcement.md")
    )

    assert_match %r{Convert incompatible Codex/Claude prompts.*\[justin808\]\(https://github\.com/justin808\).*\[issue #372\]\(https://github\.com/shakacode/agent-workflows/issues/372\)}, postmortem
    assert_match %r{Use observed routing evidence.*\[justin808\]\(https://github\.com/justin808\).*\[issue #151\]\(https://github\.com/shakacode/agent-workflows/issues/151\)}, postmortem
    assert_includes postmortem,
                    "Issue #273 resumes separately after #299 removes the unsupported launch gate; #299 does not implement or redefine #273."
    assert_includes postmortem, "https://github.com/shakacode/agent-workflows/issues/273"
  end

  def test_recommended_profiles_remain_advisory_across_routing_surfaces
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
      (CODEX_RECOMMENDATIONS + CLAUDE_RECOMMENDATIONS).each do |recommendation|
        assert_includes text, recommendation, "#{path} is missing #{recommendation}"
      end
      assert_includes text, "advisory", path
    end
  end

  def test_cost_aware_playbook_and_escalation_controls_remain
    guide = read_repo_file("docs/agent-workflows-model-routing.md")
    workflow = normalized(read_repo_file("workflows/pr-processing.md"))

    [
      "GPT-5.6 Sol",
      "GPT-5.6 Terra",
      "Conservative GPT-5.6 Profile",
      "Sol diagnosis and envelope → Terra implementation → Sol check",
      "First-pass acceptance rate",
      "Percentage of tasks escalated",
      "Do not assume that maximum reasoning always improves outcomes"
    ].each { |phrase| assert_includes guide, phrase }
    assert_includes workflow, "MODEL_ESCALATION_REQUEST"
    assert_includes workflow, "old and replacement instances must not overlap"
    assert_includes workflow, "stop and reconcile"
  end

  def test_lane_cards_separate_preference_from_optional_observation
    %w[
      workflows/pr-processing.md
      skills/pr-batch/SKILL.md
      skills/plan-pr-batch/SKILL.md
      skills/triage/SKILL.md
    ].each do |path|
      text = read_repo_file(path)
      assert_includes text, "preferred model/effort", path
      assert_includes text, "observed host/model/effort", path
      assert_includes text, "UNKNOWN", path
    end
  end

  def test_docs_index_keeps_model_routing_guide
    skip "source-pack docs are not installed" unless ENV[SOURCE_CHECKOUT_ENV] == "1"

    assert_includes read_repo_file("docs/README.md"),
                    "[Cost-aware model routing](agent-workflows-model-routing.md)"
  end
end
