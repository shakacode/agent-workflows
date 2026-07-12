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
      "Terra/medium",
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
      "Keep the parent coordinator on <coordinator model/class>/<effort>",
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
    assert_includes pr_batch, "Model-Routing Recovery Prompt"
    assert_includes pr_batch, "Worker Model Replacement And Escalation"
    assert_includes pr_batch, "Without that policy, preserve unavailable binding as `UNKNOWN`"

    planner = normalized(read_repo_file("skills/plan-pr-batch/SKILL.md"))
    assert_includes planner, "exact-parent or exact-checker"
    assert_includes planner, "continue portable class-based planning"
    assert_includes planner, "exact policy-required checker route"
    assert_includes planner, "checker reservation"
    assert_includes planner, "freshness, and independence when it starts"
  end

  def test_continuous_checker_is_strong_independent_and_fail_closed
    checker_text = read_repo_file("workflows/continuous-evaluation-loop.md")
    checker = normalized(checker_text)

    [
      "distinct from every maker",
      "exact model/effort",
      "conservative GPT-5.6 profile",
      "Sol/high minimum",
      "Terra may collect mechanical evidence",
      "may not issue the qualifying intent-achievement or final-risk verdict",
      "do not return a clean/`realized` verdict"
    ].each do |phrase|
      assert_includes checker, phrase, "continuous checker contract is missing: #{phrase}"
    end

    loop_prompt = normalized(extract_prompt(checker_text, "## Loop Prompt"))
    [
      "distinct from every maker",
      "exact model/effort",
      "stop short of a clean/realized verdict",
      "If checker identity, model/effort, binding, or independence is unavailable",
      "below policy, or `UNKNOWN`",
      "checker_route_compliance: UNKNOWN|failed"
    ].each do |phrase|
      assert_includes loop_prompt, phrase, "continuous checker Loop Prompt is missing: #{phrase}"
    end
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
