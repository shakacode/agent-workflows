#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

HELPER = File.expand_path("canonical-task-control", __dir__)

class CanonicalTaskControlTest < Minitest::Test
  def test_ordinary_topology_allows_one_repository_qualified_target_lane_and_pr_limit
    result, stderr, status = run_helper(base_input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["launch"], result.fetch("allowed_actions")
    assert_empty result.fetch("blockers")
  end

  def test_multi_target_mode_requires_and_accepts_a_complete_versioned_exception
    input = base_input
    input["task"] = {
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
        "aggregate_budget" => { "amount" => 100_000, "unit" => "tokens", "source" => "policy:pilot-a" },
        "per_lane_budgets" => [
          { "lane_id" => "lane-402", "amount" => 50_000, "unit" => "tokens" },
          { "lane_id" => "lane-403", "amount" => 50_000, "unit" => "tokens" }
        ],
        "shared_context_justification" => "One compatibility matrix is reused by both lanes.",
        "expected_savings" => "Avoid duplicate compatibility setup and combined-tip replay.",
        "rollback" => "Stop the wave and relaunch each target as an ordinary task.",
        "human_approval" => "https://github.com/shakacode/agent-workflows/issues/402#issuecomment-1"
      }
    }

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal "multi_target_exception", result.fetch("topology_mode")
  end

  def test_accepting_a_child_receipt_requires_compact_manifest_checkpoint_and_nonresumable_closure
    input = base_input.merge(
      "operation" => "accept_child_receipt",
      "manifest" => compact_manifest,
      "lifecycle" => {
        "context_threshold" => "UNKNOWN",
        "context_threshold_source" => "UNKNOWN",
        "checkpoints" => [
          checkpoint("plan_settlement"),
          checkpoint("review_wave")
        ]
      },
      "children" => {
        "packets" => [
          {
            "contract" => "task-scoped-child-packet",
            "version" => 1,
            "child_id" => "checker-402",
            "lane_id" => "aw-i402",
            "repository" => "shakacode/agent-workflows",
            "target" => "issue:402",
            "role" => "checker",
            "scope" => "Review the canonical-task helper diff only.",
            "acceptance_criteria" => ["Find correctness or contract gaps."],
            "verification" => ["ruby skills/pr-batch/bin/canonical-task-control-test.rb"],
            "stop_conditions" => ["Return on scope growth."]
          }
        ],
        "receipts" => [
          {
            "contract" => "compact-child-receipt",
            "version" => 1,
            "child_id" => "checker-402",
            "lane_id" => "aw-i402",
            "repository" => "shakacode/agent-workflows",
            "target" => "issue:402",
            "status" => "completed",
            "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
            "summary" => "No findings.",
            "findings" => [],
            "verification" => ["targeted test passed"],
            "open_decisions" => []
          }
        ],
        "states" => [
          { "child_id" => "checker-402", "status" => "closed", "resumable" => false }
        ]
      }
    )

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal ["checker-402"], result.fetch("closed_children")
    assert_equal ["checker-402"], result.fetch("accepted_child_receipts")
    assert_includes result.fetch("unknowns"), "context_threshold"
  end

  def test_cross_task_delegation_coalesces_for_active_target_and_preserves_unsupported_usage_as_unknown
    input = base_input.merge(
      "operation" => "delegation",
      "manifest" => compact_manifest,
      "lifecycle" => {
        "context_threshold" => "UNKNOWN",
        "context_threshold_source" => "UNKNOWN",
        "checkpoints" => [checkpoint("cross_task_handoff")]
      },
      "budget_gate" => {
        "source" => "#399",
        "status" => "passed",
        "evidence_ref" => "local:budget:delegation"
      },
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
        "target_state" => "active",
        "estimated_rendered_context" => "UNKNOWN",
        "descendant_fanout" => "UNKNOWN",
        "context_policy_threshold" => "UNKNOWN",
        "message_class" => "new_evidence",
        "queued_messages" => 2,
        "coalesced" => true,
        "deterministic_handoff_available" => false,
        "human_approval" => "UNKNOWN",
        "usage" => {
          "contract" => "execution-provenance-evidence",
          "version" => 1,
          "support" => "unsupported",
          "receipt_ref" => "UNKNOWN",
          "source_edge_delta" => "UNKNOWN",
          "target_self_delta" => "UNKNOWN",
          "target_descendant_delta" => "UNKNOWN",
          "aggregate_physical_delta" => "UNKNOWN",
          "reconciliation" => "UNKNOWN"
        }
      }
    )

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "coalesce", result.fetch("verdict")
    refute result.fetch("wake_target")
    assert_equal ["queue_coalesced_message"], result.fetch("allowed_actions")
    assert_includes result.fetch("unknowns"), "execution_provenance"
    assert_includes result.fetch("unknowns"), "target_context_estimate"
  end

  def test_idle_delegation_wakes_only_new_evidence_within_policy_or_with_human_approval
    within_policy = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    result, stderr, status = run_helper(within_policy)
    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert result.fetch("wake_target")

    unchanged = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "unchanged", human_approval: "https://example.test/approval/1"
    )
    result, stderr, status = run_helper(unchanged)
    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    refute result.fetch("wake_target")

    over_policy = delegation_input(
      target_state: "paused", context: 60_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "https://example.test/approval/2"
    )
    result, stderr, status = run_helper(over_policy)
    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert result.fetch("wake_target")
  end

  def test_pilot_requires_ten_matched_pairs_required_metrics_and_gate_safe_promotion
    input = base_input.merge(
      "operation" => "pilot_evaluation",
      "pilot" => pilot_input
    )

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "promote_ordinary_default", result.fetch("pilot_verdict")
    assert_equal 10, result.fetch("matched_pair_count")
  end

  def test_pilot_preserves_multi_target_rollback_when_receipts_are_unsupported
    pilot = pilot_input
    pilot["pairs"].first["ordinary"]["execution_receipt_ref"] = "UNKNOWN"
    pilot["pairs"].first["ordinary"]["metrics"]["total_tokens"] = "UNKNOWN"
    pilot["pairs"].first["ordinary"]["metrics"]["credit_equivalents"] = "UNKNOWN"
    input = base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot)

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "retain_multi_target_rollback", result.fetch("pilot_verdict")
    assert_includes result.fetch("unknowns"), "execution_provenance"
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
        "budget_gate" => {
          "source" => "#399",
          "status" => "passed",
          "evidence_ref" => "local:budget:#{action}"
        }
      )
      result, stderr, status = run_helper(input)

      assert status.success?, "#{action}: #{stderr}"
      assert_equal [action], result.fetch("allowed_actions")
    end
  end

  private

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

  def compact_manifest
    {
      "contract" => "compact-coordinator-manifest",
      "version" => 1,
      "requirements" => ["one canonical target"],
      "ownership" => { "maker" => "maker-aw-i402", "checker" => "checker-402" },
      "current_heads" => { "aw-i402" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46" },
      "gates" => { "security" => "passed", "dependency" => "pending" },
      "budgets" => { "status" => "UNKNOWN", "source" => "#399" },
      "decisions" => ["ordinary topology"]
    }
  end

  def checkpoint(boundary)
    {
      "contract" => "coordinator-compaction-checkpoint",
      "version" => 1,
      "boundary" => boundary,
      "status" => "satisfied",
      "evidence_ref" => "local:checkpoint:#{boundary}"
    }
  end

  def delegation_input(target_state:, context:, threshold:, message_class:, human_approval:)
    usage = {
      "contract" => "execution-provenance-evidence",
      "version" => 1,
      "support" => "unsupported",
      "receipt_ref" => "UNKNOWN",
      "source_edge_delta" => "UNKNOWN",
      "target_self_delta" => "UNKNOWN",
      "target_descendant_delta" => "UNKNOWN",
      "aggregate_physical_delta" => "UNKNOWN",
      "reconciliation" => "UNKNOWN"
    }
    base_input.merge(
      "operation" => "delegation",
      "manifest" => compact_manifest,
      "lifecycle" => {
        "context_threshold" => threshold,
        "context_threshold_source" => "policy:pilot-a",
        "checkpoints" => [checkpoint("cross_task_handoff")]
      },
      "budget_gate" => {
        "source" => "#399",
        "status" => "passed",
        "evidence_ref" => "local:budget:delegation"
      },
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
          "execution_receipt_ref" => "receipt:ordinary:#{index + 1}",
          "metrics" => metrics.merge("total_tokens" => 70_000)
        },
        "multi_target" => {
          "execution_receipt_ref" => "receipt:multi:#{index + 1}",
          "metrics" => metrics
        }
      }
    end
    {
      "contract" => "canonical-task-matched-pilot",
      "version" => 1,
      "dependency" => {
        "issue" => 398,
        "status" => "satisfied",
        "evidence_ref" => "https://example.test/receipts/398"
      },
      "pairs" => pairs,
      "promotion" => {
        "usage_reduction_policy" => "materially_lower",
        "material_reduction_percent" => 20,
        "require_zero_escaped_p0_p1_regression" => true,
        "require_preserved_gate_compliance" => true
      },
      "rollback" => "Retain explicit multi-target mode when any criterion fails or is UNKNOWN.",
      "publication_ref" => "https://example.test/pilots/402"
    }
  end

  def child_receipt_input
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
          "acceptance_criteria" => ["No blockers."], "verification" => ["targeted test"],
          "stop_conditions" => ["Stop on scope growth."]
        }],
        "receipts" => [{
          "contract" => "compact-child-receipt", "version" => 1,
          "child_id" => "checker-402", "lane_id" => "aw-i402",
          "repository" => "shakacode/agent-workflows", "target" => "issue:402",
          "status" => "completed", "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "summary" => "No findings.", "findings" => [],
          "verification" => ["targeted test passed"], "open_decisions" => []
        }],
        "states" => [{ "child_id" => "checker-402", "status" => "closed", "resumable" => false }]
      }
    )
  end

  def run_helper(input)
    stdout, stderr, status = Open3.capture3("ruby", HELPER, stdin_data: JSON.generate(input))
    [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
  end
end
