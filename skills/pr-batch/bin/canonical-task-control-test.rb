#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "minitest/autorun"
require "open3"
require "tempfile"
require "time"

HELPER = File.expand_path("canonical-task-control", __dir__)

class CanonicalTaskControlTest < Minitest::Test
  def test_launch_rejects_a_bare_task_without_composite_gate_evidence
    _result, stderr, status = run_helper(base_input, trusted: false)

    refute status.success?
    assert_includes stderr, "trusted evidence is required"
  end

  def test_stdin_cannot_self_authenticate_without_separate_trusted_evidence
    input = launch_input

    _result, stderr, status = run_helper(input, trusted: false)

    refute status.success?
    assert_includes stderr, "trusted evidence is required"
  end

  def test_trusted_evidence_id_and_task_binding_must_match
    input = launch_input
    bundle = trusted_bundle_for(input)
    bundle["id"] = "different-id"

    _result, stderr, status = run_helper(input, trusted_bundle: bundle)

    refute status.success?
    assert_includes stderr, "trusted evidence id mismatch"

    bundle = trusted_bundle_for(input)
    bundle["task_id"] = "foreign-task"
    _result, stderr, status = run_helper(input, trusted_bundle: bundle)
    refute status.success?
    assert_includes stderr, "trusted evidence task binding mismatch"
  end

  def test_expired_unknown_or_payload_tampered_trusted_evidence_fails_closed
    input = launch_input
    bundle = trusted_bundle_for(input)
    bundle["expires_at"] = (Time.now.utc - 1).iso8601
    _result, stderr, status = run_helper(input, trusted_bundle: bundle)
    refute status.success?
    assert_includes stderr, "not current"

    bundle = trusted_bundle_for(input)
    bundle["actor"] = "UNKNOWN"
    _result, stderr, status = run_helper(input, trusted_bundle: bundle)
    refute status.success?
    assert_includes stderr, "source/actor/role invalid"

    bundle = trusted_bundle_for(input)
    bundle["payload"]["manifest"]["decisions"] = ["tampered after approval"]
    _result, stderr, status = run_helper(input, trusted_bundle: bundle)
    refute status.success?
    assert_includes stderr, "payload digest mismatch"
  end

  def test_ordinary_topology_allows_one_repository_qualified_target_lane_and_pr_limit
    result, stderr, status = run_helper(launch_input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal %w[branch_worktree_create commit patch_edit worker_spawn], result.fetch("allowed_actions")
    assert_empty result.fetch("blockers")
  end

  def test_launch_reconciles_pending_stage_and_only_returns_held_local_permissions
    input = launch_input
    input["manifest"]["gates"]["stage_dependency"] = "pending"
    stage = input["typed_gates"].find { |record| record["gate"] == "stage_dependency" }
    stage["result"] = "pending"
    stage["permissions"] = %w[branch_worktree_create patch_edit commit]

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal %w[branch_worktree_create commit patch_edit], result.fetch("allowed_actions")
    assert_includes result.fetch("blockers"), "stage_dependency_pending_or_worker_spawn_not_permitted"
    refute_includes result.fetch("allowed_actions"), "push"
  end

  def test_launch_rejects_manifest_and_typed_gate_contradictions
    input = launch_input
    input["manifest"]["gates"]["stage_dependency"] = "pending"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "manifest gate result mismatch"
  end

  def test_launch_blocks_worker_spawn_when_399_is_unavailable_but_preserves_held_local_permissions
    input = launch_input
    bundle = trusted_bundle_for(input)
    bundle["capabilities"]["issue_399"] = "unavailable"

    result, stderr, status = run_helper(input, trusted_bundle: bundle)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal %w[branch_worktree_create commit patch_edit], result.fetch("allowed_actions")
    assert_includes result.fetch("unknowns"), "budget_evidence"
  end

  def test_current_helper_rejects_claim_that_398_is_available
    input = delegation_input(
      target_state: "active", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    bundle = trusted_bundle_for(input)
    bundle["capabilities"]["issue_398"] = "available"

    _result, stderr, status = run_helper(input, trusted_bundle: bundle)

    refute status.success?
    assert_includes stderr, "#398 mechanism is unavailable"
  end

  def test_multi_target_mode_requires_and_accepts_a_complete_versioned_exception
    input = launch_input(multi_target_task)

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal "multi_target_exception", result.fetch("topology_mode")
  end

  def test_multi_target_exception_rejects_arbitrary_approval_and_budget_assertions
    task = multi_target_task
    task["exception"]["human_approvals"][0] = "https://example.test/arbitrary-approval"
    input = launch_input(task)

    _result, stderr, status = run_helper(input)

    refute status.success?, "arbitrary URL authority unexpectedly allowed multi-target launch"
    assert_includes stderr, "expected object"

    task = multi_target_task
    task["exception"]["budget_authorities"][0]["evidence_ref"] = "policy:arbitrary"
    _result, stderr, status = run_helper(launch_input(task))

    refute status.success?, "arbitrary string budget evidence unexpectedly allowed multi-target launch"
    assert_includes stderr, "durable HTTPS"
  end

  def test_case_variant_repository_duplicates_fail_closed
    task = multi_target_task
    task["targets"][1]["repository"] = "ShakaCode/Agent-Workflows"
    task["targets"][1]["target"] = "issue:402"
    task["lanes"][1]["repository"] = "ShakaCode/Agent-Workflows"
    task["lanes"][1]["target"] = "issue:402"
    input = launch_input(task)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "canonical targets must be unique case-insensitively"
  end

  def test_ad_hoc_target_requires_a_trusted_task_specific_durable_override
    task = base_input.fetch("task").merge(
      "targets" => [{ "repository" => "shakacode/agent-workflows", "target" => "adhoc:20260812-canonical-fix" }],
      "lanes" => [{ "id" => "adhoc-lane", "repository" => "shakacode/agent-workflows", "target" => "adhoc:20260812-canonical-fix" }]
    )
    task["adhoc_override"] = bound_evidence(
      contract: "adhoc-authority-evidence", task: task,
      action: "authorize_adhoc_task", role: "maintainer"
    )

    result, stderr, status = run_helper(launch_input(task))

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")

    task.delete("adhoc_override")
    _result, stderr, status = run_helper(launch_input(task))
    refute status.success?
    assert_includes stderr, "ad-hoc target requires trusted task-specific override"
  end

  def test_accepting_a_child_receipt_requires_compact_manifest_checkpoint_and_nonresumable_closure
    input = child_receipt_input
    input["lifecycle"]["checkpoints"].unshift(checkpoint("plan_settlement"))

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal ["checker-402"], result.fetch("closed_children")
    assert_equal ["checker-402"], result.fetch("accepted_child_receipts")
    assert_includes result.fetch("unknowns"), "context_threshold"
  end

  def test_child_receipt_rejects_stale_head_and_swapped_role_scope_binding
    input = child_receipt_input
    input["children"]["receipts"].first["head_sha"] = "1111111111111111111111111111111111111111"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "manifest current head"

    input = child_receipt_input
    input["children"]["receipts"].first["role"] = "maker"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "packet/receipt/state bindings must match"
  end

  def test_child_receipt_rejects_swapped_plan_and_changed_findings_without_matching_validation
    input = child_receipt_input
    input["children"]["receipts"].first["plan_id"] = "foreign-plan"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "review result binding mismatch"

    input = child_receipt_input
    input["children"]["receipts"].first["findings"] = [{ "severity" => "blocking", "summary" => "new" }]
    input["children"]["receipts"].first["review_result"]["findings"] =
      input["children"]["receipts"].first["findings"]
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "findings digest mismatch"
  end

  def test_nested_unknown_manifest_and_child_evidence_fail_closed
    input = child_receipt_input
    input["manifest"]["ownership"]["checker"] = "owner-UNKNOWN-later"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "nested UNKNOWN"

    input = child_receipt_input
    input["children"]["receipts"].first["summary"] = "UNKNOWN finding state"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "nested UNKNOWN"
  end

  def test_cross_task_delegation_coalesces_verified_new_evidence_for_active_target
    input = delegation_input(
      target_state: "active", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["delegation"]["queued_messages"] = 2
    input["delegation"]["coalesced"] = true

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    refute result.fetch("wake_target")
    assert_empty result.fetch("allowed_actions")
    assert_includes result.fetch("unknowns"), "execution_provenance"
  end

  def test_idle_delegation_wakes_only_new_evidence_within_policy_or_with_human_approval
    within_policy = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    result, stderr, status = run_helper(within_policy)
    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    refute result.fetch("wake_target")

    unchanged = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "unchanged", human_approval: "UNKNOWN"
    )
    result, stderr, status = run_helper(unchanged)
    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    refute result.fetch("wake_target")

    over_policy = delegation_input(
      target_state: "paused", context: 60_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: delegation_approval
    )
    result, stderr, status = run_helper(over_policy)
    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    refute result.fetch("wake_target")
  end

  def test_cross_task_wake_rejects_the_same_canonical_target_even_with_case_variants
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["delegation"]["source"]["repository"] = "ShakaCode/Agent-Workflows"
    input["delegation"]["source"]["target"] = "issue:402"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "source and target canonical identities must differ"
  end

  def test_unknown_descendant_fanout_blocks_wake_without_structured_approval
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["delegation"]["descendant_fanout"] = "UNKNOWN"

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_includes result.fetch("blockers"), "human_approval_required"
  end

  def test_active_target_suppresses_unchanged_acknowledgement_and_deterministic_handoff_noise
    %w[unchanged acknowledgement deterministic_handoff].each do |message_class|
      input = delegation_input(
        target_state: "active", context: 40_000, threshold: 50_000,
        message_class: message_class, human_approval: "UNKNOWN"
      )

      result, stderr, status = run_helper(input)

      assert status.success?, "#{message_class}: #{stderr}"
      assert_equal "block", result.fetch("verdict")
      assert_includes result.fetch("blockers"), "noise_suppressed"
      refute result.fetch("wake_target")
    end
  end

  def test_available_execution_provenance_rejects_arbitrary_receipt_reference
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["delegation"]["usage"]["receipt_ref"] = "receipt:invented"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "durable verified #398 receipt-result references"
  end

  def test_available_execution_provenance_rejects_no_double_count_arithmetic_mismatch
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["delegation"]["usage"]["aggregate_physical_delta"] = 55

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "aggregate arithmetic mismatch"
  end

  def test_unsupported_execution_provenance_stays_unknown_and_blocks_delegation_mutation
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["delegation"]["usage"] = unsupported_usage

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_includes result.fetch("blockers"), "execution_provenance_unknown"
    assert_includes result.fetch("unknowns"), "execution_provenance"
  end

  def test_cross_task_wake_rejects_an_arbitrary_approval_url
    input = delegation_input(
      target_state: "stale", context: 60_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "https://example.test/arbitrary"
    )

    _result, _stderr, status = run_helper(input)

    refute status.success?
  end

  def test_pilot_requires_ten_matched_pairs_required_metrics_and_gate_safe_promotion
    input = base_input.merge(
      "operation" => "pilot_evaluation",
      "pilot" => pilot_input
    )

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "retain_multi_target_rollback", result.fetch("pilot_verdict")
    assert_includes result.fetch("unknowns"), "execution_provenance"
    assert_equal 10, result.fetch("matched_pair_count")
  end

  def test_pilot_preserves_multi_target_rollback_when_receipts_are_unsupported
    pilot = pilot_input
    pilot["pairs"].first["ordinary"]["execution_evidence"] = unsupported_pilot_evidence
    pilot["pairs"].first["ordinary"]["metrics"]["total_tokens"] = "UNKNOWN"
    pilot["pairs"].first["ordinary"]["metrics"]["credit_equivalents"] = "UNKNOWN"
    input = base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot)

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "retain_multi_target_rollback", result.fetch("pilot_verdict")
    assert_includes result.fetch("unknowns"), "execution_provenance"
  end

  def test_pilot_rejects_repeated_or_relabelled_representative_tasks
    pilot = pilot_input
    pilot["pairs"][1]["ordinary"]["task_identity"] = pilot["pairs"][0]["ordinary"]["task_identity"]
    pilot["pairs"][1]["ordinary"]["execution_evidence"]["task_identity"] = pilot["pairs"][0]["ordinary"]["task_identity"]

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "representative task identities must be globally unique"
  end

  def test_pilot_rejects_arbitrary_or_unpaired_receipt_result_evidence
    pilot = pilot_input
    pilot["pairs"].first["ordinary"]["execution_evidence"]["result_ref"] = "result:invented"

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "durable verified #398 receipt-result"
  end

  def test_pilot_rejects_reused_execution_receipt_or_result_references
    pilot = pilot_input
    first = pilot["pairs"][0]["ordinary"]["execution_evidence"]
    second = pilot["pairs"][1]["ordinary"]["execution_evidence"]
    second["receipt_ref"] = first["receipt_ref"]

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "receipt/result references must be globally unique"
  end

  def test_stdin_cannot_change_pilot_metrics_outside_the_trusted_bundle
    input = base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot_input)
    bundle = trusted_bundle_for(input)
    request = input.slice("contract", "version", "operation", "task").merge(
      "trusted_evidence_refs" => [bundle.fetch("id")],
      "metrics" => { "total_tokens" => 1 }
    )

    _result, stderr, status = run_request_with_bundle(request, bundle)

    refute status.success?
    assert_includes stderr, "keys must be exactly"
  end

  def test_malformed_exception_and_resumable_completed_child_fail_closed
    exception_input = base_input
    exception_input["task"] = {
      "id" => "task-portfolio",
      "topology_mode" => "multi_target_exception",
      "targets" => [
        { "repository" => "shakacode/agent-workflows", "target" => "issue:402" },
        { "repository" => "shakacode/agent-workflows", "target" => "issue:403" }
      ],
      "lanes" => [
        { "id" => "lane-402", "repository" => "shakacode/agent-workflows", "target" => "issue:402" },
        { "id" => "lane-403", "repository" => "shakacode/agent-workflows", "target" => "issue:403" }
      ],
      "implementation_pr_limit" => 1,
      "exception" => { "contract" => "multi-target-supervision-exception", "version" => 1 }
    }
    _result, stderr, status = run_helper(exception_input)
    refute status.success?
    assert_includes stderr, "INVALID_INPUT"

    child_input = child_receipt_input
    child_input["children"]["states"].first["resumable"] = true
    _result, stderr, status = run_helper(child_input)
    refute status.success?
    assert_includes stderr, "non-resumable by default"
  end

  def test_budget_gate_is_required_before_every_context_amplifying_action
    actions = %w[delegation resume worker_spawn retry review_wave]
    actions.each do |action|
      input = base_input.merge(
        "operation" => "budget_action",
        "budget_action" => action,
        "budget_gate" => bound_evidence(
          contract: "budget-evidence", task: base_input.fetch("task"),
          action: action, role: "budget_owner"
        )
      )
      result, stderr, status = run_helper(input)

      assert status.success?, "#{action}: #{stderr}"
      assert_equal [action], result.fetch("allowed_actions")
    end
  end

  def test_budget_action_rejects_arbitrary_string_evidence
    input = base_input.merge(
      "operation" => "budget_action",
      "budget_action" => "retry",
      "budget_gate" => { "source" => "#399", "status" => "passed", "evidence_ref" => "local:budget:retry" }
    )

    _result, _stderr, status = run_helper(input)

    refute status.success?
  end

  def test_malformed_top_level_json_values_fail_stably
    [[], nil, "not-an-object", 42].each do |value|
      _stdout, stderr, status = run_raw(JSON.generate(value))
      refute status.success?
      assert_equal "INVALID_INPUT: trusted evidence is required\n", stderr
    end

    _stdout, stderr, status = run_raw("{")
    refute status.success?
    assert_match(/\AINVALID_INPUT: /, stderr)
  end

  private

  def launch_input(task = base_input.fetch("task"))
    base_input.merge(
      "task" => task,
      "policy" => {
        "contract" => "canonical-task-policy",
        "version" => 1,
        "default_topology" => "ordinary",
        "ad_hoc_default" => "reject",
        "context_threshold" => 50_000,
        "evidence" => task.fetch("targets").map do |target|
          bound_evidence(
            contract: "authority-evidence", task: task, target: target,
            action: "bind_canonical_task_policy", role: "maintainer"
          )
        end
      },
      "manifest" => compact_manifest(task),
      "lifecycle" => {
        "context_threshold" => 50_000,
        "context_threshold_source" => "trusted-policy-v1",
        "checkpoints" => task.fetch("targets").flat_map do |target|
          [checkpoint("plan_settlement", task: task, target: target), checkpoint("dispatch", task: task, target: target)]
        end
      },
      "budget_gate" => task.fetch("targets").map do |target|
        bound_evidence(
          contract: "budget-evidence", task: task, target: target,
          action: "worker_spawn", role: "budget_owner"
        )
      end,
      "typed_gates" => %w[security ownership dispatcher stage_dependency].flat_map do |gate|
        task.fetch("targets").map.with_index do |target, index|
          lane = task.fetch("lanes")[index]
          bound_evidence(
            contract: gate == "stage_dependency" ? "stage-dependency-gate" : "typed-gate-evidence",
            task: task, target: target,
            action: "launch_worker", role: "coordinator"
          ).merge(
            "gate" => gate, "lane_id" => lane.fetch("id"),
            "base_sha" => "7cf266b0c1753797e56aefb1b152a16edd4b5a46",
            "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
            "result_id" => "#{gate}-#{lane.fetch('id')}-result",
            "result" => "passed",
            "permissions" => if gate == "stage_dependency"
                               %w[branch_worktree_create patch_edit commit worker_spawn]
                             else
                               []
                             end
          )
        end
      end
    )
  end

  def base_input
    {
      "contract" => "canonical-task-control",
      "version" => 1,
      "operation" => "launch",
      "task" => {
        "id" => "task-402",
        "topology_mode" => "ordinary",
        "targets" => [
          { "repository" => "shakacode/agent-workflows", "target" => "issue:402" }
        ],
        "lanes" => [
          {
            "id" => "aw-i402",
            "repository" => "shakacode/agent-workflows",
            "target" => "issue:402"
          }
        ],
        "implementation_pr_limit" => 1
      }
    }
  end

  def multi_target_task
    task = {
      "id" => "task-portfolio",
      "topology_mode" => "multi_target_exception",
      "targets" => [
        { "repository" => "shakacode/agent-workflows", "target" => "issue:402" },
        { "repository" => "shakacode/agent-workflows", "target" => "issue:403" }
      ],
      "lanes" => [
        { "id" => "lane-402", "repository" => "shakacode/agent-workflows", "target" => "issue:402" },
        { "id" => "lane-403", "repository" => "shakacode/agent-workflows", "target" => "issue:403" }
      ],
      "implementation_pr_limit" => 1,
      "exception" => {
        "contract" => "multi-target-supervision-exception",
        "version" => 1,
        "reason" => "atomic_cross_issue_migration",
        "justification" => "The shared compatibility boundary must be validated as one wave.",
        "target_count" => 2,
        "concurrency" => 1,
        "aggregate_budget" => { "amount" => 100_000, "unit" => "tokens" },
        "per_lane_budgets" => [
          { "lane_id" => "lane-402", "amount" => 50_000, "unit" => "tokens" },
          { "lane_id" => "lane-403", "amount" => 50_000, "unit" => "tokens" }
        ],
        "shared_context_justification" => "One compatibility matrix is reused by both lanes.",
        "expected_savings" => "Avoid duplicate compatibility setup and combined-tip replay.",
        "rollback" => "Stop the wave and relaunch each target as an ordinary task."
      }
    }
    task["exception"]["human_approvals"] = task.fetch("targets").map do |target|
      bound_evidence(
        contract: "authority-evidence", task: task, target: target,
        action: "authorize_multi_target_supervision", role: "maintainer"
      )
    end
    task["exception"]["budget_authorities"] = task.fetch("targets").map do |target|
      bound_evidence(
        contract: "budget-evidence", task: task, target: target,
        action: "authorize_multi_target_budget", role: "budget_owner"
      )
    end
    task
  end

  def compact_manifest(task = base_input.fetch("task"))
    {
      "contract" => "compact-coordinator-manifest",
      "version" => 1,
      "requirements" => ["one canonical target"],
      "ownership" => { "maker" => "maker-aw-i402", "checker" => "checker-402" },
      "current_heads" => task.fetch("lanes").to_h { |lane| [lane.fetch("id"), "8cf266b0c1753797e56aefb1b152a16edd4b5a46"] },
      "gates" => {
        "security" => "passed", "ownership" => "passed",
        "dispatcher" => "passed", "stage_dependency" => "passed"
      },
      "budgets" => {
        "status" => "passed", "policy_issue" => 399,
        "amount" => 50_000 * task.fetch("targets").length, "unit" => "tokens"
      },
      "decisions" => ["ordinary topology"]
    }
  end

  def checkpoint(boundary, task: base_input.fetch("task"), target: task.fetch("targets").first)
    {
      "contract" => "coordinator-compaction-checkpoint",
      "version" => 1,
      "boundary" => boundary,
      "actor" => "coordinator-1",
      "role" => "coordinator",
      "task_id" => task.fetch("id"),
      "repository" => target.fetch("repository"),
      "target" => target.fetch("target"),
      "action" => "compact_coordinator",
      "scope" => "canonical task control",
      "status" => "satisfied",
      "observed_at" => "2026-08-12T12:00:00Z",
      "evidence_ref" => "https://example.test/checkpoints/#{boundary}"
    }
  end

  def bound_evidence(contract:, task:, action:, role:, target: task.fetch("targets").first)
    evidence = {
      "contract" => contract,
      "version" => 1,
      "actor" => "trusted-actor-1",
      "role" => role,
      "task_id" => task.fetch("id"),
      "repository" => target.fetch("repository"),
      "target" => target.fetch("target"),
      "action" => action,
      "scope" => "canonical task control",
      "status" => "passed",
      "observed_at" => "2026-08-12T12:00:00Z",
      "evidence_ref" => "https://example.test/evidence/#{contract}/#{action}"
    }
    if contract == "budget-evidence"
      evidence["policy_issue"] = 399
      evidence["amount"] = 50_000
      evidence["unit"] = "tokens"
    end
    evidence
  end

  def delegation_input(target_state:, context:, threshold:, message_class:, human_approval:)
    usage = {
      "contract" => "execution-provenance-evidence",
      "version" => 1,
      "support" => "available",
      "producer_issue" => 398,
      "actor" => "telemetry-verifier-1",
      "role" => "telemetry_verifier",
      "source_task_id" => "source-task",
      "target_task_id" => "task-402",
      "repository" => "shakacode/agent-workflows",
      "target" => "issue:402",
      "action" => "delegation",
      "scope" => "source edge and target execution",
      "status" => "verified",
      "observed_at" => "2026-08-12T12:00:00Z",
      "receipt_ref" => "https://example.test/receipts/398/delegation",
      "result_ref" => "https://example.test/results/398/delegation",
      "source_edge_delta" => 10,
      "target_self_delta" => 20,
      "target_descendant_delta" => 5,
      "aggregate_physical_delta" => 35,
      "reconciliation" => "reconciled_no_double_count"
    }
    base_input.merge(
      "operation" => "delegation",
      "manifest" => compact_manifest,
      "lifecycle" => {
        "context_threshold" => threshold,
        "context_threshold_source" => "policy:pilot-a",
        "checkpoints" => [checkpoint("cross_task_handoff")]
      },
      "budget_gate" => bound_evidence(
        contract: "budget-evidence", task: base_input.fetch("task"),
        action: "delegation", role: "budget_owner"
      ),
      "delegation" => {
        "source" => {
          "task_id" => "source-task",
          "repository" => "shakacode/agent-workflows",
          "target" => "issue:401"
        },
        "target" => {
          "task_id" => "task-402",
          "repository" => "shakacode/agent-workflows",
          "target" => "issue:402"
        },
        "target_state" => target_state,
        "estimated_rendered_context" => context,
        "descendant_fanout" => 0,
        "context_policy_threshold" => threshold,
        "message_class" => message_class,
        "queued_messages" => 1,
        "coalesced" => false,
        "deterministic_handoff_available" => false,
        "human_approval" => human_approval,
        "usage" => usage
      }
    )
  end

  def unsupported_usage
    keys = %w[
      producer_issue actor role source_task_id target_task_id repository target
      action scope status observed_at receipt_ref result_ref source_edge_delta
      target_self_delta target_descendant_delta aggregate_physical_delta reconciliation
    ]
    {
      "contract" => "execution-provenance-evidence",
      "version" => 1,
      "support" => "unsupported"
    }.merge(keys.to_h { |key| [key, "UNKNOWN"] })
  end

  def delegation_approval
    bound_evidence(
      contract: "authority-evidence", task: base_input.fetch("task"),
      action: "wake_target_task", role: "maintainer"
    )
  end

  def pilot_input
    metrics = {
      "total_tokens" => 100_000,
      "credit_equivalents" => 10.0,
      "elapsed_seconds" => 600,
      "human_coordination_seconds" => 60,
      "correction_turns" => 1,
      "first_pass_accepted" => true,
      "escaped_p0_p1_defects" => 0,
      "gate_compliance" => "preserved"
    }
    pairs = 10.times.map do |index|
      {
        "pair_id" => "pair-#{index + 1}",
        "task_class" => "implementation-bounded",
        "context_topology" => "one-maker-one-checker",
        "ordinary" => {
          "arm_identity" => "ordinary",
          "task_identity" => "ordinary-task-#{index + 1}",
          "batch_identity" => "ordinary-batch-#{index + 1}",
          "task_class" => "implementation-bounded",
          "context_topology" => "one-maker-one-checker",
          "execution_evidence" => pilot_execution_evidence("ordinary", index + 1),
          "metrics" => metrics.merge("total_tokens" => 70_000, "credit_equivalents" => 7.0)
        },
        "multi_target" => {
          "arm_identity" => "multi_target",
          "task_identity" => "multi-task-#{index + 1}",
          "batch_identity" => "multi-batch-#{index + 1}",
          "task_class" => "implementation-bounded",
          "context_topology" => "one-maker-one-checker",
          "execution_evidence" => pilot_execution_evidence("multi_target", index + 1),
          "metrics" => metrics
        }
      }
    end
    {
      "contract" => "canonical-task-matched-pilot",
      "version" => 1,
      "dependency" => {
        "contract" => "dependency-gate-evidence",
        "version" => 1,
        "issue" => 398,
        "actor" => "dependency-checker-1",
        "role" => "dependency_checker",
        "task_id" => "task-402",
        "repository" => "shakacode/agent-workflows",
        "target" => "issue:402",
        "action" => "evaluate_pilot",
        "scope" => "canonical task matched pilot",
        "status" => "satisfied",
        "observed_at" => "2026-08-12T12:00:00Z",
        "result_ref" => "https://example.test/results/398/dependency"
      },
      "pairs" => pairs,
      "promotion" => {
        "usage_reduction_policy" => "materially_lower",
        "material_reduction_percent" => 20,
        "require_zero_escaped_p0_p1_regression" => true,
        "require_preserved_gate_compliance" => true,
        "evidence" => bound_evidence(
          contract: "pilot-promotion-policy-evidence", task: base_input.fetch("task"),
          action: "bind_pilot_promotion_policy", role: "maintainer"
        )
      },
      "rollback" => "Retain explicit multi-target mode when any criterion fails or is UNKNOWN.",
      "publication" => bound_evidence(
        contract: "pilot-publication-evidence", task: base_input.fetch("task"),
        action: "publish_pilot_result", role: "coordinator"
      )
    }
  end

  def pilot_execution_evidence(arm, index)
    slug = arm == "ordinary" ? "ordinary" : "multi"
    {
      "contract" => "pilot-execution-result-evidence", "version" => 1,
      "support" => "available", "producer_issue" => 398,
      "actor" => "telemetry-verifier-1", "role" => "telemetry_verifier",
      "task_identity" => "#{slug}-task-#{index}",
      "batch_identity" => "#{slug}-batch-#{index}",
      "arm_identity" => arm,
      "task_class" => "implementation-bounded",
      "context_topology" => "one-maker-one-checker",
      "status" => "verified", "observed_at" => "2026-08-12T12:00:00Z",
      "receipt_ref" => "https://example.test/receipts/398/#{slug}/#{index}",
      "result_ref" => "https://example.test/results/398/#{slug}/#{index}"
    }
  end

  def unsupported_pilot_evidence
    keys = %w[
      producer_issue actor role task_identity batch_identity arm_identity task_class
      context_topology status observed_at receipt_ref result_ref
    ]
    {
      "contract" => "pilot-execution-result-evidence", "version" => 1,
      "support" => "unsupported"
    }.merge(keys.to_h { |key| [key, "UNKNOWN"] })
  end

  def child_receipt_input
    review_identity = {
      "batch_id" => "batch-402", "task_id" => "task-402",
      "plan_id" => "plan-402-v1", "spec_id" => "spec-402-v1",
      "diff_identity" => "sha256:#{'a' * 64}"
    }
    findings = []
    base_input.merge(
      "operation" => "accept_child_receipt",
      "manifest" => compact_manifest,
      "lifecycle" => {
        "context_threshold" => "UNKNOWN",
        "context_threshold_source" => "UNKNOWN",
        "checkpoints" => [checkpoint("review_wave")]
      },
      "children" => {
        "packets" => [{
          "contract" => "task-scoped-child-packet", "version" => 1,
          "child_id" => "checker-402", "lane_id" => "aw-i402",
          "repository" => "shakacode/agent-workflows", "target" => "issue:402",
          "role" => "checker", "scope" => "Review one diff.",
          "base_sha" => "7cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "review_round" => 1,
          **review_identity,
          "review_package_ref" => "https://example.test/reviews/packages/checker-402-round-1",
          "acceptance_criteria" => ["No blockers."], "verification" => ["targeted test"],
          "stop_conditions" => ["Stop on scope growth."]
        }],
        "receipts" => [{
          "contract" => "compact-child-receipt", "version" => 1,
          "child_id" => "checker-402", "lane_id" => "aw-i402",
          "repository" => "shakacode/agent-workflows", "target" => "issue:402",
          "role" => "checker", "scope" => "Review one diff.",
          "base_sha" => "7cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "status" => "completed", "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "review_round" => 1,
          **review_identity,
          "review_package_ref" => "https://example.test/reviews/packages/checker-402-round-1",
          "summary" => "No findings.", "findings" => findings,
          "verification" => ["targeted test passed"], "open_decisions" => [],
          "review_result" => {
            "contract" => "exact-diff-review-result", "version" => 1,
            "base_sha" => "7cf266b0c1753797e56aefb1b152a16edd4b5a46",
            "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
            "round" => 1,
            "review_package_ref" => "https://example.test/reviews/packages/checker-402-round-1",
            "status" => "verified", "findings" => findings,
            "findings_evidence_ref" => "https://example.test/reviews/results/checker-402-round-1",
            **review_identity,
            "schema_validation" => {
              "contract" => "review-findings-validation-result", "version" => 1,
              "validator" => "bin/validate-review-findings", "status" => "valid",
              "findings_digest" => findings_digest(findings)
            }
          }
        }],
        "states" => [{
          "child_id" => "checker-402", "lane_id" => "aw-i402",
          "repository" => "shakacode/agent-workflows", "target" => "issue:402",
          "role" => "checker", "scope" => "Review one diff.",
          "base_sha" => "7cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "review_round" => 1,
          **review_identity,
          "review_package_ref" => "https://example.test/reviews/packages/checker-402-round-1",
          "status" => "closed", "resumable" => false
        }]
      }
    )
  end

  def findings_digest(findings)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(findings)))}"
  end

  def canonicalize(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonicalize(value[key])] }
    when Array then value.map { |entry| canonicalize(entry) }
    else value
    end
  end

  def run_helper(input, trusted: true, trusted_bundle: nil)
    return run_helper_without_trusted(input) unless trusted

    bundle = trusted_bundle || trusted_bundle_for(input)
    Tempfile.create(["canonical-task-trusted", ".json"]) do |file|
      file.write(JSON.generate(bundle))
      file.flush
      request = input.slice("contract", "version", "operation", "task").merge(
        "trusted_evidence_refs" => ["trusted-evidence-1"]
      )
      stdout, stderr, status = Open3.capture3(
        "ruby", HELPER, "--trusted-evidence", file.path,
        "--trusted-evidence-id", "trusted-evidence-1",
        stdin_data: JSON.generate(request)
      )
      return [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
    end
  end

  def run_request_with_bundle(request, bundle)
    Tempfile.create(["canonical-task-trusted", ".json"]) do |file|
      file.write(JSON.generate(bundle))
      file.flush
      stdout, stderr, status = Open3.capture3(
        "ruby", HELPER, "--trusted-evidence", file.path,
        "--trusted-evidence-id", bundle.fetch("id"),
        stdin_data: JSON.generate(request)
      )
      return [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
    end
  end

  def run_helper_without_trusted(input)
    stdout, stderr, status = Open3.capture3("ruby", HELPER, stdin_data: JSON.generate(input))
    [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
  end

  def trusted_bundle_for(input)
    payload = input.reject { |key, _value| %w[contract version operation task].include?(key) }
    {
      "contract" => "canonical-task-trusted-evidence",
      "version" => 1,
      "id" => "trusted-evidence-1",
      "source" => "coordinator",
      "actor" => "coordinator-1",
      "role" => "coordinator",
      "operation" => input.fetch("operation"),
      "task_id" => input.fetch("task").fetch("id"),
      "targets" => input.fetch("task").fetch("targets"),
      "action" => input.fetch("operation"),
      "scope" => "canonical task control",
      "issued_at" => (Time.now.utc - 60).iso8601,
      "expires_at" => (Time.now.utc + 3600).iso8601,
      "heads" => input.dig("manifest", "current_heads") ||
        input.fetch("task").fetch("lanes").to_h do |lane|
          [lane.fetch("id"), "8cf266b0c1753797e56aefb1b152a16edd4b5a46"]
        end,
      "capabilities" => { "issue_398" => "unavailable", "issue_399" => "available" },
      "payload_digest" => findings_digest(payload),
      "payload" => payload
    }
  end

  def run_raw(json)
    Open3.capture3("ruby", HELPER, stdin_data: json)
  end
end
