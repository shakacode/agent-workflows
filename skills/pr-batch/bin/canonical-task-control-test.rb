#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "base64"
require "fileutils"
require "minitest/autorun"
require "open3"
require "openssl"
require "tempfile"
require "time"
require "zlib"

HELPER = File.expand_path("canonical-task-control", __dir__)
BUDGET_HELPER = File.expand_path("batch-token-budget", __dir__)
STACKED_BASE_BUDGET_HELPER_FIXTURE = File.expand_path(
  "fixtures/batch-token-budget-a556.gz.b64", __dir__
)
STACKED_BASE_BUDGET_HELPER_SHA256 = "421d4897690d1ff591966f79ce8b07a5b3d112a18d26643b78258de2f947d050"
REPO_ROOT = File.expand_path("../../..", __dir__)
REVIEW_VALIDATOR = File.join(REPO_ROOT, "bin", "validate-review-findings")
WORKFLOW_CONFIG = File.join(REPO_ROOT, ".agents", "agent-workflow.yml")
TEST_TMP_ROOT = File.join(REPO_ROOT, ".tmp", "canonical-task-control-tests")
FileUtils.mkdir_p(TEST_TMP_ROOT)
TEST_BUDGET_VERIFIER_KEY = OpenSSL::PKey::RSA.generate(2048)

class CanonicalTaskControlTest < Minitest::Test
  def setup
    @trusted_plan_paths = []
    @usage_receipt_paths = []
    @temporary_roots = []
    @trusted_plan_sequence = 0
    @usage_receipt_sequence = 0
    @budget_state_paths = []
  end

  def teardown
    @trusted_plan_paths.each { |path| FileUtils.rm_f(path) }
    @usage_receipt_paths.each { |path| FileUtils.rm_f(path) }
    @temporary_roots.each { |path| FileUtils.rm_rf(path) }
    @budget_state_paths.each do |path|
      FileUtils.rm_f(path)
      FileUtils.rm_f("#{path}.lock")
    end
  end

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

  def test_trusted_evidence_binds_the_complete_task_authorization
    input = launch_input(multi_target_task)
    bundle = trusted_bundle_for(input)
    request = input.slice("contract", "version", "operation", "task").merge(
      "trusted_evidence_refs" => [bundle.fetch("id")]
    )
    request["task"]["exception"]["concurrency"] = 2

    _result, stderr, status = run_request_with_bundle(request, bundle)

    refute status.success?
    assert_includes stderr, "trusted evidence task digest mismatch"
  end

  def test_trusted_payload_cannot_override_envelope_operation_or_task_authorization
    input = usage_reconciliation_input
    bundle = trusted_bundle_for(input)
    bundle["payload"]["operation"] = "launch"
    bundle["payload_digest"] = findings_digest(bundle.fetch("payload"))

    _result, stderr, status = run_helper(input, trusted_bundle: bundle)

    refute status.success?
    assert_includes stderr, "trusted evidence payload may not override envelope fields"

    input = usage_reconciliation_input
    bundle = trusted_bundle_for(input)
    bundle["payload"]["task"] = multi_target_task
    bundle["payload_digest"] = findings_digest(bundle.fetch("payload"))

    _result, stderr, status = run_helper(input, trusted_bundle: bundle)

    refute status.success?
    assert_includes stderr, "trusted evidence payload may not override envelope fields"
  end

  def test_malformed_task_lane_entries_fail_as_deterministic_invalid_input
    input = launch_input
    bundle = trusted_bundle_for(input)
    request = input.slice("contract", "version", "operation", "task").merge(
      "trusted_evidence_refs" => [bundle.fetch("id")]
    )
    request["task"]["lanes"] = [nil]
    bundle["task_digest"] = findings_digest(request.fetch("task"))

    _result, stderr, status = run_request_with_bundle(request, bundle)

    refute status.success?
    assert_match(/\AINVALID_INPUT: /, stderr)
    refute_includes stderr, "NoMethodError"
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

  def test_group_or_world_writable_trusted_evidence_fails_closed
    input = launch_input
    bundle = trusted_bundle_for(input)
    Tempfile.create(["canonical-task-insecure", ".json"], TEST_TMP_ROOT) do |file|
      file.write(JSON.generate(bundle))
      file.flush
      File.chmod(0o666, file.path)
      request = input.slice("contract", "version", "operation", "task").merge(
        "trusted_evidence_refs" => [bundle.fetch("id")]
      )
      _stdout, stderr, status = Open3.capture3(
        "ruby", HELPER, "--trusted-evidence", file.path,
        "--trusted-evidence-id", bundle.fetch("id"),
        "--trusted-evidence-root", REPO_ROOT,
        "--trust-config", File.join(REPO_ROOT, ".agents", "trusted-github-actors.yml"),
        "--repo-workflow-config", WORKFLOW_CONFIG,
        "--review-findings-validator", REVIEW_VALIDATOR,
        stdin_data: JSON.generate(request)
      )

      refute status.success?
      assert_includes stderr, "trusted evidence file permissions are insecure"
    end
  end

  def test_symlinked_or_outside_root_trusted_evidence_fails_closed
    input = launch_input
    bundle = trusted_bundle_for(input)
    request = input.slice("contract", "version", "operation", "task").merge(
      "trusted_evidence_refs" => [bundle.fetch("id")]
    )
    Tempfile.create(["canonical-task-outside", ".json"]) do |outside|
      outside.write(JSON.generate(bundle))
      outside.flush
      Tempfile.create(["canonical-task-trust", ".yml"], TEST_TMP_ROOT) do |trust|
        trust.write("trusted_users:\n  - trusted-actor-1\n")
        trust.flush
        _stdout, stderr, status = capture_helper(request, bundle.fetch("id"), outside.path, trust.path)
        refute status.success?
        assert_includes stderr, "inside trusted evidence root"
      end
    end

    Tempfile.create(["canonical-task-real", ".json"], TEST_TMP_ROOT) do |real|
      real.write(JSON.generate(bundle))
      real.flush
      link = File.join(TEST_TMP_ROOT, ".canonical-task-symlink-#{Process.pid}")
      File.symlink(real.path, link)
      Tempfile.create(["canonical-task-trust", ".yml"], TEST_TMP_ROOT) do |trust|
        trust.write("trusted_users:\n  - trusted-actor-1\n")
        trust.flush
        _stdout, stderr, status = capture_helper(request, bundle.fetch("id"), link, trust.path)
        refute status.success?
        assert_includes stderr, "may not be a symlink"
      end
    ensure
      File.unlink(link) if link && File.exist?(link)
    end
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

  def test_launch_blocks_when_any_non_stage_typed_gate_is_not_passed
    %w[security ownership dispatcher].each do |gate|
      input = launch_input
      input["manifest"]["gates"][gate] = "pending"
      input["typed_gates"].find { |record| record["gate"] == gate }["result"] = "pending"

      result, stderr, status = run_helper(input)

      assert status.success?, "#{gate}: #{stderr}"
      assert_equal "block", result.fetch("verdict"), gate
      refute_includes result.fetch("allowed_actions"), "worker_spawn", gate
      assert_includes result.fetch("blockers"), "typed_gate_pending_or_blocked", gate
    end
  end

  def test_launch_blocks_worker_spawn_when_hierarchical_token_budgets_are_unavailable_but_preserves_held_local_permissions
    input = launch_input
    bundle = trusted_bundle_for(input)
    bundle["capabilities"]["hierarchical_token_budgets"] = "unavailable"

    result, stderr, status = run_helper(input, trusted_bundle: bundle)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal %w[branch_worktree_create commit patch_edit], result.fetch("allowed_actions")
    assert_includes result.fetch("unknowns"), "budget_evidence"
  end

  def test_replay_safe_usage_receipt_capability_allows_budget_admitted_delegation_preflight
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    bundle = trusted_bundle_for(input)
    bundle["capabilities"]["replay_safe_usage_receipts"] = "available"

    result, stderr, status = run_helper(input, trusted_bundle: bundle)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["wake_target_task"], result.fetch("allowed_actions")
    assert result.fetch("wake_target")
  end

  def test_delegation_blocks_wake_when_hierarchical_token_budgets_are_unavailable
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    bundle = trusted_bundle_for(input)
    bundle["capabilities"]["hierarchical_token_budgets"] = "unavailable"

    result, stderr, status = run_helper(input, trusted_bundle: bundle)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_empty result.fetch("allowed_actions")
    refute result.fetch("wake_target")
    assert_includes result.fetch("blockers"), "hierarchical_token_budget_evidence_UNKNOWN"
    assert_includes result.fetch("unknowns"), "budget_evidence"

    coalesced = delegation_input(
      target_state: "active", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    coalesced["delegation"]["queued_messages"] = 2
    coalesced["delegation"]["coalesced"] = true
    bundle = trusted_bundle_for(coalesced)
    bundle["capabilities"]["hierarchical_token_budgets"] = "unavailable"

    result, stderr, status = run_helper(coalesced, trusted_bundle: bundle)

    assert status.success?, stderr
    assert_equal "coalesce", result.fetch("verdict")
    assert_equal ["queue_coalesced_message"], result.fetch("allowed_actions")
    refute result.fetch("wake_target")
  end

  def test_old_nested_evidence_fails_even_inside_a_current_trusted_bundle
    input = launch_input
    evidence = input["policy"]["evidence"].first
    evidence["issued_at"] = "2000-01-01T00:00:00Z"
    evidence["observed_at"] = "2000-01-01T00:00:01Z"
    evidence["expires_at"] = "2000-01-01T00:10:00Z"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "nested evidence is not current"
  end

  def test_untrusted_human_actor_cannot_authorize
    input = launch_input
    input["policy"]["evidence"].first["actor"] = "not-in-trusted-users"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "human authority actor is not trusted"
  end

  def test_multi_target_mode_requires_and_accepts_a_complete_versioned_exception
    input = launch_input(multi_target_task)
    input["task"]["exception"]["concurrency"] = 2

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal "multi_target_exception", result.fetch("topology_mode")
    receipt = result.fetch("exception_receipt")
    assert_equal "multi-target-supervision-exception-receipt", receipt.fetch("contract")
    assert_equal input.dig("task", "exception", "budget_plan_anchor", "trusted_plan_digest"),
                 receipt.fetch("budget_plan_digest")
  end

  def test_multi_target_exception_rejects_arbitrary_approval_and_budget_assertions
    task = multi_target_task
    task["exception"]["human_approvals"][0] = "https://example.test/arbitrary-approval"
    input = launch_input(task, real_budget_state: false)

    _result, stderr, status = run_helper(input)

    refute status.success?, "arbitrary URL authority unexpectedly allowed multi-target launch"
    assert_includes stderr, "expected object"

    task = multi_target_task
    task["exception"]["budget_plan_anchor"]["trusted_plan_digest"] = "sha256:#{'0' * 64}"
    _result, stderr, status = run_helper(launch_input(task, real_budget_state: false))

    refute status.success?, "mismatched hierarchical budget digest unexpectedly allowed multi-target launch"
    assert_includes stderr, "trusted-plan-digest-mismatch"
  end

  def test_multi_target_exception_requires_the_external_coordinator_budget_plan
    task = multi_target_task
    FileUtils.rm_f(task.dig("exception", "budget_plan_anchor", "trusted_plan_path"))

    _result, stderr, status = run_helper(launch_input(task, real_budget_state: false))

    refute status.success?, "nonexistent external budget plan unexpectedly allowed multi-target launch"
    assert_includes stderr, "trusted budget plan unreadable"

    task = multi_target_task
    task["exception"]["budget_plan"]["scopes"]["aggregate"]["limit_tokens"] += 1
    task["exception"]["budget_plan_anchor"]["trusted_plan_digest"] = findings_digest(
      task["exception"]["budget_plan"]
    )

    _result, stderr, status = run_helper(launch_input(task, real_budget_state: false))

    refute status.success?, "caller-substituted embedded budget plan unexpectedly allowed multi-target launch"
    assert_includes stderr, "trusted budget plan rejected"

    task = multi_target_task
    Tempfile.create(["substituted-budget-plan", ".json"]) do |outside|
      outside.write(JSON.generate(canonicalize(task.dig("exception", "budget_plan"))))
      outside.flush
      task["exception"]["budget_plan_anchor"]["trusted_plan_path"] = outside.path

      _result, stderr, status = run_helper(launch_input(task, real_budget_state: false))

      refute status.success?, "outside-root substituted plan path unexpectedly allowed multi-target launch"
      assert_includes stderr, "inside trusted evidence root"
    end

    task = multi_target_task
    trusted_path = task.dig("exception", "budget_plan_anchor", "trusted_plan_path")
    symlink_path = File.join(TEST_TMP_ROOT, "budget-plan-#{Process.pid}-symlink.json")
    File.symlink(trusted_path, symlink_path)
    @trusted_plan_paths << symlink_path
    task["exception"]["budget_plan_anchor"]["trusted_plan_path"] = symlink_path

    _result, stderr, status = run_helper(launch_input(task, real_budget_state: false))

    refute status.success?, "symlink-substituted plan path unexpectedly allowed multi-target launch"
    assert_includes stderr, "may not be a symlink"
  end

  def test_multi_target_exception_rejects_a_plan_whose_state_path_contains_the_plan
    task = multi_target_task
    plan = task.dig("exception", "budget_plan")
    plan_path = task.dig("exception", "budget_plan_anchor", "trusted_plan_path")
    plan["state_path"] = File.dirname(plan_path)
    File.write(plan_path, JSON.generate(canonicalize(plan)))
    task["exception"]["budget_plan_anchor"]["trusted_plan_digest"] = findings_digest(plan)

    _result, stderr, status = run_helper(launch_input(task, real_budget_state: false))

    refute status.success?
    assert_includes stderr, "trusted-plan-state-path-collision"
  end

  def test_multi_target_exception_rejects_invalid_external_verifier_contracts
    mutations = {
      "malformed-key" => proc { |records| records[0]["public_key_pem"] = "not-a-public-key" },
      "undersized-key" => proc do |records|
        records[0]["public_key_pem"] = OpenSSL::PKey::RSA.generate(1024).public_key.to_pem
      end,
      "noncanonical-key" => proc { |records| records[0]["public_key_pem"] += "\n" },
      "duplicate-id" => proc { |records| records << records[0].dup },
      "duplicate-key" => proc { |records| records << records[0].merge("id" => "other-budget-verifier") },
      "signature-field" => proc { |records| records[0]["signature"] = "caller-asserted-signature" }
    }

    mutations.each do |name, mutate|
      task = multi_target_task
      plan = task.dig("exception", "budget_plan")
      mutate.call(plan.fetch("trusted_verifiers"))
      path = install_budget_plan(plan, label: name)
      task["exception"]["budget_plan_anchor"] = {
        "trusted_plan_path" => path,
        "trusted_plan_id" => plan.fetch("batch_id"),
        "trusted_plan_digest" => findings_digest(plan)
      }

      _result, stderr, status = run_helper(launch_input(task, real_budget_state: false))

      refute status.success?, "#{name} external verifier contract unexpectedly allowed multi-target launch"
      assert_includes stderr, "trusted budget plan rejected", name
    end
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

  def test_operational_ids_reject_non_ascii_casefold_ambiguity
    input = launch_input
    input["task"]["id"] = "task-Straße"
    input["policy"]["evidence"].each { |record| record["task_id"] = "task-Straße" }
    input["lifecycle"]["checkpoints"].each { |record| record["task_id"] = "task-Straße" }
    input["budget_gate"].each { |record| record["task_id"] = "task-Straße" }
    input["typed_gates"].each { |record| record["task_id"] = "task-Straße" }

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "portable ASCII id"
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

    input = base_input.merge(
      "operation" => "foreign_target_packet", "task" => task,
      "foreign_target_packet" => {
        "contract" => "canonical-task-foreign-target-packet", "version" => 1,
        "source" => {
          "task_id" => "source-task", "repository" => "shakacode/agent-workflows", "target" => "issue:401"
        },
        "recipient" => {
          "task_id" => task.fetch("id"), "repository" => "shakacode/agent-workflows",
          "target" => "adhoc:20260812-canonical-fix"
        },
        "evidence_kind" => "status_update", "summary" => "Trusted ad-hoc topology probe.",
        "evidence_ref" => "https://example.test/evidence/adhoc-topology",
        "evidence_digest" => "sha256:#{'c' * 64}", "disposition" => "evidence_only"
      }
    )
    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")

    task.delete("adhoc_override")
    input = input.merge("task" => task)
    _result, stderr, status = run_helper(input)
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
    closure = result.fetch("child_closure_receipts").first
    assert_equal "canonical-task-child-closure-receipt", closure.fetch("contract")
    assert_equal "checker", closure.fetch("child_kind")
    assert_includes result.fetch("unknowns"), "context_threshold"
  end

  def test_compact_manifest_and_child_receipts_are_bounded
    input = child_receipt_input
    input["manifest"]["requirements"] = Array.new(33, "bounded requirement")

    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "manifest requirements exceeds 32 items"

    input = child_receipt_input
    input["children"]["receipts"].first["summary"] = "x" * 513
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "child receipt string exceeds 512 bytes"
  end

  def test_manifest_requires_one_active_maker_and_closed_independent_roles
    input = child_receipt_input
    input["manifest"]["ownership"] = { "makers" => %w[maker-a maker-b], "checker" => "checker-402" }

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "manifest ownership requires exactly one maker"

    input = child_receipt_input
    input["manifest"]["ownership"] = { "maker" => "Maker-A", "checker" => " maker-a " }
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "distinct checker/reviewer/qa actors"

    [["Straße", "STRASSE"], ["Ｍａｋｅｒ－Ａ", "maker-a"]].each do |maker, checker|
      input = child_receipt_input
      input["manifest"]["ownership"] = { "maker" => maker, "checker" => checker }
      _result, stderr, status = run_helper(input)
      refute status.success?, "#{maker.inspect} and #{checker.inspect} bypassed actor independence"
      assert_includes stderr, "distinct checker/reviewer/qa actors"
    end
  end

  def test_review_findings_validator_can_be_resolved_from_a_portable_repo_seam
    input = child_receipt_input
    input["children"]["receipts"].first["review_result"]["schema_validation"]["validator"] =
      "tools/review-validator.rb"
    input["children"]["states"].first["closure"]["receipt_digest"] =
      findings_digest(input["children"]["receipts"].first)
    portable_root = File.join(TEST_TMP_ROOT, "portable-repo-#{Process.pid}")
    @temporary_roots << portable_root
    FileUtils.mkdir_p(File.join(portable_root, ".agents"))
    alternate = File.join(portable_root, "tools", "review-validator.rb")
    FileUtils.mkdir_p(File.dirname(alternate))
    FileUtils.cp(REVIEW_VALIDATOR, alternate)
    File.chmod(0o600, alternate)
    workflow_config = File.join(portable_root, ".agents", "agent-workflow.yml")
    File.write(workflow_config, "review_findings_validator: tools/review-validator.rb\n", mode: "w", perm: 0o600)

    bundle = trusted_bundle_for(input)
    Tempfile.create(["canonical-task-trusted", ".json"], portable_root) do |file|
      file.write(JSON.generate(bundle))
      file.flush
      Tempfile.create(["canonical-task-trust", ".yml"], portable_root) do |trust|
        trust.write("trusted_users:\n  - trusted-actor-1\n")
        trust.flush
        request = input.slice("contract", "version", "operation", "task").merge(
          "trusted_evidence_refs" => [bundle.fetch("id")]
        )
        stdout, stderr, status = capture_helper(request, bundle.fetch("id"), file.path, trust.path,
                                                validator_path: alternate, workflow_config_path: workflow_config,
                                                trusted_root: portable_root)
        assert status.success?, stderr
        assert_equal "allow", JSON.parse(stdout).fetch("verdict")
      end
    end
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
    assert_includes stderr, "child receipt must select checker, reviewer, or qa kind"
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

  def test_recomputed_digest_cannot_bypass_repository_review_findings_validator
    input = child_receipt_input
    invalid_findings = ["not-a-review-finding-object"]
    receipt = input["children"]["receipts"].first
    receipt["findings"] = invalid_findings
    receipt["review_result"]["findings"] = invalid_findings
    receipt["review_result"]["schema_validation"]["findings_digest"] = findings_digest(invalid_findings)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "repository review findings validation failed"
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
    assert_equal "coalesce", result.fetch("verdict")
    refute result.fetch("wake_target")
    assert_equal ["queue_coalesced_message"], result.fetch("allowed_actions")
    assert_empty result.fetch("unknowns")
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
    assert_includes result.fetch("blockers"), "budget_admission_blocked"
  end

  def test_idle_delegation_rejects_fresh_admission_without_persisted_budget_state
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    plan = JSON.parse(File.read(input.dig("budget_gate", "decision_receipt", "trusted_plan_path")))
    FileUtils.rm_f(plan.fetch("state_path"))

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "trusted budget state rejected: state-required"
  end

  def test_multi_target_delegation_binds_the_matching_target_lane
    task = multi_target_task
    lane = task.fetch("lanes").last
    target = task.fetch("targets").last
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["task"] = task
    input["manifest"] = compact_manifest(task)
    input["lifecycle"]["checkpoints"] = task.fetch("targets").map do |candidate|
      checkpoint("cross_task_handoff", task: task, target: candidate)
    end
    input["budget_gate"] = budget_result(action: "delegation", task: task, lane: lane)
    input["delegation"]["target"] = {
      "task_id" => task.fetch("id"), "repository" => target.fetch("repository"), "target" => target.fetch("target")
    }

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal ["wake_target_task"], result.fetch("allowed_actions")
  end

  def test_multi_target_wake_approval_binds_the_exact_selected_target
    task = multi_target_task
    lane = task.fetch("lanes").last
    target = task.fetch("targets").last
    input = delegation_input(
      target_state: "stale", context: 60_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: bound_evidence(
        contract: "authority-evidence", task: task, action: "wake_target_task", role: "maintainer",
        target: task.fetch("targets").first
      )
    )
    input["task"] = task
    input["manifest"] = compact_manifest(task)
    input["lifecycle"]["checkpoints"] = task.fetch("targets").map do |candidate|
      checkpoint("cross_task_handoff", task: task, target: candidate)
    end
    input["budget_gate"] = budget_result(action: "delegation", task: task, lane: lane)
    input["delegation"]["target"] = {
      "task_id" => task.fetch("id"), "repository" => target.fetch("repository"), "target" => target.fetch("target")
    }

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "approval target binding mismatch"
  end

  def test_approved_stale_delegation_maps_to_idle_production_reservation
    input = delegation_input(
      target_state: "stale", context: 60_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: delegation_approval
    )

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["wake_target_task"], result.fetch("allowed_actions")
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

  def test_replayed_over_threshold_delegation_preserves_original_block_reason
    input = delegation_input(
      target_state: "idle", context: 60_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    gate = input.fetch("budget_gate")
    gate["status"] = "replayed"
    gate["decision_status"] = "admitted"
    gate["state_revision"] += 1
    replay_plan = JSON.parse(File.read(gate.dig("decision_receipt", "trusted_plan_path")))
    FileUtils.rm_f(replay_plan.fetch("state_path"))

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal ["record_budget_replay"], result.fetch("allowed_actions")
    assert_includes result.fetch("blockers"), "human_approval_required"
    refute result.fetch("wake_target")
  end

  def test_replayed_blocked_delegation_preserves_budget_denial_verdict
    input = delegation_input(
      target_state: "idle", context: 40_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    gate = input.fetch("budget_gate")
    gate["status"] = "replayed"
    gate["decision_status"] = "blocked"
    gate["state_revision"] += 1
    gate["decision_receipt"]["status"] = "blocked"
    gate["decision_receipt"]["reason"] = "aggregate-budget-exceeded"
    gate["reason"] = "aggregate-budget-exceeded"
    gate.delete("receipt")
    gate.delete("checkpoint")

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal ["record_budget_replay"], result.fetch("allowed_actions")
    assert_includes result.fetch("blockers"), "budget_admission_blocked"
    refute result.fetch("wake_target")
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

  def test_usage_reconciliation_consumes_v2_receipt_and_budget_result_without_caller_deltas
    input = usage_reconciliation_input

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["record_usage_reconciliation"], result.fetch("allowed_actions")
    assert_equal 35, result.fetch("usage_reconciliation").fetch("physical_tokens")
    assert_equal 3, result.fetch("usage_reconciliation").fetch("contributing_turns")
  end

  def test_usage_reconciliation_accepts_batch_usage_producer_fractional_utc_window
    input = usage_reconciliation_input(fractional_window: true)

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal ["record_usage_reconciliation"], result.fetch("allowed_actions")
  end

  def test_usage_reconciliation_rejects_empty_fraction_or_utc_offset
    ["2026-08-12T00:00:00.Z", "2026-08-12T00:00:00+00:00"].each do |invalid_time|
      input = usage_reconciliation_input
      reconciliation = input.fetch("usage_reconciliation")
      reconciliation.dig("usage_receipt", "window")["from_inclusive"] = invalid_time
      reconciliation.dig("budget_result", "receipts").each do |record|
        record["from_inclusive"] = invalid_time
      end
      refresh_usage_artifact!(reconciliation)

      _result, _stderr, status = run_helper(input)

      refute status.success?, "invalid UTC timestamp passed: #{invalid_time}"
    end
  end

  def test_usage_reconciliation_rejects_digest_or_balancing_mismatch
    input = usage_reconciliation_input
    input["usage_reconciliation"]["usage_receipt_digest"] = "sha256:#{'0' * 64}"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "usage receipt digest mismatch"

    input = usage_reconciliation_input
    input["usage_reconciliation"]["usage_receipt"]["batch"]["usage"]["descendant_inclusive"]["total_tokens"] = 55
    input["usage_reconciliation"]["usage_receipt_digest"] =
      findings_digest(input["usage_reconciliation"]["usage_receipt"])
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "usage receipt token equation mismatch"
  end

  def test_usage_reconciliation_rejects_invalid_production_counters_completion_revision_and_window
    mutations = {
      "negative interval" => proc { |record, _result| record["interval_tokens"] = -999 },
      "incomplete reservation" => proc { |record, _result| record["completed"] = false },
      "impossible released tokens" => proc { |record, _result| record["released_tokens"] = 1 },
      "future receipt revision" => proc { |record, result| record["state_revision"] = result["state_revision"] + 1 },
      "mismatched usage window" => proc { |record, _result| record["from_inclusive"] = "2026-08-11T00:00:00Z" },
      "malformed receipt record" => proc { |_record, result| result["receipts"] = [nil] }
    }
    mutations.each do |label, mutate|
      input = usage_reconciliation_input
      result = input.dig("usage_reconciliation", "budget_result")
      mutate.call(result.fetch("receipts").first, result)

      _decision, stderr, status = run_helper(input)

      refute status.success?, label
      assert_includes stderr, "reconciliation receipts", label
    end
  end

  def test_usage_reconciliation_rejects_per_scope_release_above_allocation
    input = usage_reconciliation_input
    totals = input.dig("usage_reconciliation", "budget_result", "totals")
    totals.fetch("coordinator")["released_tokens"] = 1
    totals.fetch("lanes").fetch("aw-i402")["released_tokens"] -= 1

    _decision, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "reconciliation receipts"
  end

  def test_usage_reconciliation_requires_the_referenced_trusted_artifact
    input = usage_reconciliation_input
    FileUtils.rm_f(input.dig("usage_reconciliation", "usage_receipt_path")) if input.dig("usage_reconciliation", "usage_receipt_path")
    FileUtils.rm_f(input.dig("usage_reconciliation", "usage_receipt_ref").delete_prefix("file://"))

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "usage receipt artifact unreadable"

    input = usage_reconciliation_input
    artifact_path = input.dig("usage_reconciliation", "usage_receipt_ref").delete_prefix("file://")
    File.write(artifact_path, JSON.generate({ "schema" => "batch-usage-receipt-v2", "substituted" => true }))
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "usage receipt artifact content mismatch"

    input = usage_reconciliation_input
    artifact_path = input.dig("usage_reconciliation", "usage_receipt_ref").delete_prefix("file://")
    File.write(artifact_path, " " * 1_048_577)
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "usage receipt artifact exceeds 1048576 bytes"
  end

  def test_usage_receipt_privacy_contract_is_fail_closed
    input = usage_reconciliation_input
    receipt = input.dig("usage_reconciliation", "usage_receipt")
    receipt["privacy"]["emitted_or_persisted_content"] = true
    refresh_usage_artifact!(input.fetch("usage_reconciliation"))

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "usage receipt privacy contract invalid"
  end

  def test_usage_receipt_rejects_evidence_sources_the_production_contract_rejects
    input = usage_reconciliation_input
    reconciliation = input.fetch("usage_reconciliation")
    reconciliation.fetch("usage_receipt").fetch("evidence")["sources"] = ["caller_asserted_source"]
    refresh_usage_artifact!(reconciliation)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "production usage v2 contract"
  end

  def test_usage_receipt_enforces_production_window_accounting_and_lane_equations
    mutations = {
      "window" => proc { |receipt| receipt.fetch("window")["differencing"] = "caller_asserted" },
      "accounting" => proc { |receipt| receipt.fetch("accounting")["usage_samples"] = -1 },
      "lane hierarchy" => proc { |receipt| receipt.fetch("lanes").first["workers"] = [] }
    }
    mutations.each do |label, mutate|
      input = usage_reconciliation_input
      reconciliation = input.fetch("usage_reconciliation")
      mutate.call(reconciliation.fetch("usage_receipt"))
      refresh_usage_artifact!(reconciliation)

      _result, stderr, status = run_helper(input)

      refute status.success?, label
      assert_includes stderr, "production usage v2 contract", label
    end
  end

  def test_pilot_rejects_usage_evidence_sources_the_production_contract_rejects
    pilot = pilot_input
    arm = pilot.fetch("pairs").first.fetch("ordinary")
    arm.fetch("usage_receipt").fetch("evidence")["sources"] = ["caller_asserted_source"]
    refresh_usage_artifact!(arm)

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "production usage v2 contract"
  end

  def test_usage_reconciliation_rejects_double_counting_or_foreign_charge_back
    input = usage_reconciliation_input
    input["usage_reconciliation"]["budget_result"]["charge_backs"].first["physical_total_incremented"] = true

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "complete persisted reconciliation set mismatch"
  end

  def test_usage_reconciliation_binds_each_charge_back_amount_to_a_reservation_receipt
    input = usage_reconciliation_input
    charge_back = input.dig("usage_reconciliation", "budget_result", "charge_backs").first
    receipt = input.dig("usage_reconciliation", "budget_result", "receipts").first
    assert_equal receipt.fetch("actual_tokens"), charge_back.fetch("tokens")
    charge_back["tokens"] = 1

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "complete persisted reconciliation set mismatch"
  end

  def test_usage_reconciliation_rejects_a_truncated_persisted_receipt_and_charge_back_set
    input = real_multi_source_usage_reconciliation_input(shared_source: true)
    budget_result = input.dig("usage_reconciliation", "budget_result")
    omitted_reservation_id = budget_result.fetch("receipts").first.fetch("reservation_id")
    budget_result.fetch("receipts").shift
    budget_result.fetch("charge_backs").reject! do |charge_back|
      charge_back.fetch("reservation_id") == omitted_reservation_id
    end

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "complete persisted reconciliation set mismatch"
  end

  def test_usage_reconciliation_accepts_genuine_production_charge_backs_from_multiple_sources
    input = real_multi_source_usage_reconciliation_input

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal %w[source-task-a source-task-b],
                 result.dig("usage_reconciliation", "charge_backs").map { |record| record.dig("source", "task_id") }.sort
  end

  def test_usage_reconciliation_binds_task_batch_and_exact_lane_hierarchy
    input = usage_reconciliation_input
    reconciliation = input.fetch("usage_reconciliation")
    reconciliation.fetch("budget_result")["batch_id"] = "foreign-batch"
    reconciliation.fetch("budget_result").fetch("receipts").each { |record| record["batch_id"] = "foreign-batch" }
    reconciliation.fetch("budget_result").fetch("charge_backs").each do |charge_back|
      charge_back.fetch("target")["batch_id"] = "foreign-batch"
    end

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "task batch binding mismatch"

    input = usage_reconciliation_input
    input.dig("usage_reconciliation", "budget_result", "receipts").first["batch_id"] = "foreign-batch"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "reconciliation receipts"

    input = usage_reconciliation_input
    input.dig("usage_reconciliation", "budget_result", "charge_backs").first.fetch("target")["batch_id"] =
      "foreign-batch"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "complete persisted reconciliation set mismatch"

    input = usage_reconciliation_input
    reconciliation = input.fetch("usage_reconciliation")
    reconciliation.fetch("usage_receipt").fetch("lanes").first["id"] = "forged-lane"
    refresh_usage_artifact!(reconciliation)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "lane hierarchy mismatch"
  end

  def test_usage_reconciliation_rejects_nonportable_ids_and_inconsistent_overshoot_turns
    %w[UNKNOWN UNKNΟWN].each do |reservation_id|
      input = usage_reconciliation_input
      input.dig("usage_reconciliation", "budget_result", "receipts").first["reservation_id"] = reservation_id

      _result, stderr, status = run_helper(input)

      refute status.success?
      assert_includes stderr, "portable ASCII"
    end

    input = usage_reconciliation_input
    record = input.dig("usage_reconciliation", "budget_result", "receipts").first
    record["overshoot_turn_count"] = 1

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "overshoot turn equation"
  end

  def test_cross_task_wake_rejects_an_arbitrary_approval_url
    input = delegation_input(
      target_state: "stale", context: 60_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "https://example.test/arbitrary"
    )

    _result, _stderr, status = run_helper(input)

    refute status.success?
  end

  def test_foreign_target_packet_is_evidence_only_and_cannot_authorize_mutation
    packet = {
      "contract" => "canonical-task-foreign-target-packet", "version" => 1,
      "source" => { "task_id" => "task-401", "repository" => "shakacode/agent-workflows", "target" => "issue:401" },
      "recipient" => { "task_id" => "task-402", "repository" => "shakacode/agent-workflows", "target" => "issue:402" },
      "evidence_kind" => "dependency_result", "summary" => "Dependency head moved after validation.",
      "evidence_ref" => "https://example.test/evidence/foreign/401",
      "evidence_digest" => "sha256:#{'b' * 64}", "disposition" => "evidence_only"
    }
    input = base_input.merge("operation" => "foreign_target_packet", "foreign_target_packet" => packet)

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["record_foreign_target_evidence"], result.fetch("allowed_actions")
    assert_equal "foreign-target-evidence-receipt", result.dig("foreign_target_receipt", "contract")

    packet["disposition"] = "patch_edit"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "foreign target packets are evidence-only"
  end

  def test_pilot_requires_ten_matched_pairs_required_metrics_and_gate_safe_promotion
    input = base_input.merge(
      "operation" => "pilot_evaluation",
      "pilot" => pilot_input
    )

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "promote_ordinary_default", result.fetch("pilot_verdict")
    assert_equal "allow", result.fetch("verdict")
    assert_empty result.fetch("unknowns")
    assert_equal 10, result.fetch("matched_pair_count")
  end

  def test_pilot_accepts_batch_usage_producer_fractional_utc_windows
    pilot = pilot_input
    pilot.fetch("pairs").each do |pair|
      %w[ordinary multi_target].each do |arm_name|
        apply_producer_fractional_window!(pair.fetch(arm_name))
      end
    end

    result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    assert status.success?, stderr
    assert_equal "promote_ordinary_default", result.fetch("pilot_verdict")
  end

  def test_pilot_requires_satisfied_bound_execution_capabilities_before_promotion
    %w[execution_provenance evaluation_runner].each do |capability|
      pilot = pilot_input
      dependency = pilot.fetch("dependencies").find { |record| record["capability"] == capability }
      dependency["status"] = "pending"
      dependency["result_ref"] = "UNKNOWN"

      result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

      assert status.success?, "#{capability}: #{stderr}"
      assert_equal "retain_multi_target_rollback", result.fetch("pilot_verdict"), capability
      assert_includes result.fetch("unknowns"), "promotion_dependency_#{capability}", capability
    end
  end

  def test_pilot_preserves_multi_target_rollback_when_receipts_are_unsupported
    pilot = pilot_input
    pilot["pairs"].first["ordinary"]["usage_receipt"]["evidence"] = {
      "status" => "UNKNOWN", "sources" => ["codex_rollout_jsonl", "state_5.sqlite"],
      "unknown" => [{ "status" => "UNKNOWN", "code" => "usage_counter_missing", "fields" => ["cache_read_tokens"] }]
    }
    arm = pilot["pairs"].first["ordinary"]
    refresh_usage_artifact!(arm)
    input = base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot)

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "retain_multi_target_rollback", result.fetch("pilot_verdict")
    assert_equal "allow", result.fetch("verdict")
    assert_equal "UNKNOWN", result.fetch("token_reduction_percent")
    assert_includes result.fetch("unknowns"), "usage_telemetry"
  end

  def test_pilot_reports_token_reduction_when_optional_credit_equivalents_are_omitted
    pilot = pilot_input
    pilot.fetch("pairs").each do |pair|
      %w[ordinary multi_target].each do |arm_name|
        arm = pair.fetch(arm_name)
        arm.fetch("usage_receipt").delete("credit_equivalents")
        refresh_usage_artifact!(arm)
      end
    end

    result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    assert status.success?, stderr
    assert_equal 30.0, result.fetch("token_reduction_percent")
    assert_equal "UNKNOWN", result.fetch("credit_reduction_percent")
    assert_equal "retain_multi_target_rollback", result.fetch("pilot_verdict")
    assert_includes result.fetch("unknowns"), "credit_equivalents"
  end

  def test_pilot_rejects_credit_equivalents_without_production_metadata
    pilot = pilot_input
    arm = pilot.fetch("pairs").first.fetch("ordinary")
    values = arm.dig("usage_receipt", "credit_equivalents", "model_values")
    arm.fetch("usage_receipt")["credit_equivalents"] = {
      "status" => "available", "model_values" => values
    }
    refresh_usage_artifact!(arm)

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "credit equivalents"
  end

  def test_pilot_rejects_nonproduction_credit_equivalent_metadata_and_routes
    mutations = {
      "duplicate-route" => lambda do |credits|
        credits.fetch("model_values") << canonicalize(credits.fetch("model_values").first)
      end,
      "invented-route" => lambda do |credits|
        credits.dig("model_values", 0)["model"] = "invented-model"
      end,
      "empty-source" => ->(credits) { credits["source"] = " " },
      "invalid-effective-date" => ->(credits) { credits["effective_date"] = "2026-02-30" },
      "nonproduction-disclaimer" => ->(credits) { credits["disclaimer"] = "Estimated equivalent; not a bill." },
      "extra-field" => ->(credits) { credits["caller_note"] = "trusted" }
    }

    mutations.each do |name, mutate|
      pilot = pilot_input
      arm = pilot.fetch("pairs").first.fetch("ordinary")
      mutate.call(arm.dig("usage_receipt", "credit_equivalents"))
      refresh_usage_artifact!(arm)

      _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

      refute status.success?, "#{name} credit equivalents unexpectedly passed"
      assert_includes stderr, "credit equivalents", name
    end
  end

  def test_pilot_with_unavailable_replay_safe_usage_receipts_is_publishable_unknown_not_false_promotion
    input = base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot_input)
    bundle = trusted_bundle_for(input)
    bundle["capabilities"]["replay_safe_usage_receipts"] = "unavailable"

    result, stderr, status = run_helper(input, trusted_bundle: bundle)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["publish_pilot_result"], result.fetch("allowed_actions")
    assert_equal "retain_multi_target_rollback", result.fetch("pilot_verdict")
    assert_includes result.fetch("unknowns"), "usage_telemetry"
  end

  def test_pilot_rejects_repeated_or_relabelled_representative_tasks
    pilot = pilot_input
    pilot["pairs"][1]["ordinary"]["task_identity"] = pilot["pairs"][0]["ordinary"]["task_identity"]

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "representative task identities must be globally unique"
  end

  def test_pilot_rejects_arbitrary_usage_receipt_reference
    pilot = pilot_input
    pilot["pairs"].first["ordinary"]["usage_receipt_ref"] = "receipt:invented"

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "usage receipt reference"
  end

  def test_pilot_rejects_reused_usage_receipt_references
    pilot = pilot_input
    first = pilot["pairs"][0]["ordinary"]
    second = pilot["pairs"][1]["ordinary"]
    second["usage_receipt_ref"] = first["usage_receipt_ref"]
    second["budget_result"]["receipt_ref"] = first["usage_receipt_ref"]
    second["budget_result"]["receipts"].each { |receipt| receipt["receipt_ref"] = first["usage_receipt_ref"] }

    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    refute status.success?
    assert_includes stderr, "usage receipt references must be globally unique"
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
        "budget_lane_id" => "aw-i402",
        "budget_gate" => budget_result(action: action)
      )
      result, stderr, status = run_helper(input)

      assert status.success?, "#{action}: #{stderr}"
      assert_equal [action], result.fetch("allowed_actions")
    end
  end

  def test_fresh_budget_action_rejects_admission_without_persisted_budget_state
    input = budget_action_input("retry")
    plan = JSON.parse(File.read(input.dig("budget_gate", "decision_receipt", "trusted_plan_path")))
    FileUtils.rm_f(plan.fetch("state_path"))

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "trusted budget state rejected: state-required"
  end

  def test_fresh_delegation_and_budget_action_reject_admissions_absent_from_persisted_state
    input_builders = {
      "delegation" => lambda do
        delegation_input(
          target_state: "idle", context: 40_000, threshold: 50_000,
          message_class: "new_evidence", human_approval: "UNKNOWN"
        )
      end,
      "budget action" => -> { budget_action_input("retry") }
    }
    input_builders.each do |label, build_input|
      input = build_input.call
      gate = input.fetch("budget_gate")
      forged_id = "#{gate.dig('decision_receipt', 'reservation_id')}-forged"
      request = canonicalize(gate.dig("decision_receipt", "request"))
      request["id"] = forged_id
      gate.fetch("decision_receipt")["reservation_id"] = forged_id
      gate.fetch("receipt")["reservation_id"] = forged_id
      replace_budget_request!(gate, request)

      _result, stderr, status = run_helper(input)

      refute status.success?, label
      assert_includes stderr, "budget decision is absent from trusted state", label
    end
  end

  def test_budget_action_requires_and_honors_an_explicit_multi_target_lane
    task = multi_target_task
    lane = task.fetch("lanes").last
    input = base_input.merge(
      "operation" => "budget_action", "task" => task,
      "budget_action" => "retry", "budget_lane_id" => lane.fetch("id"),
      "budget_gate" => budget_result(action: "retry", task: task, lane: lane)
    )

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal ["retry"], result.fetch("allowed_actions")
  end

  def test_budget_result_rejects_unbound_nested_unknowns_and_identifiers
    mutations = {
      "request digest" => proc { |result| result["decision_receipt"]["request_digest"] = "UNKNOWN" },
      "evaluated at" => proc { |result| result["decision_receipt"]["evaluated_at"] = "UNKNOWN" },
      "reservation id" => proc { |result| result["receipt"]["reservation_id"] = "UNKNOWN" },
      "checkpoint" => proc { |result| result["checkpoint"] = { "status" => "UNKNOWN" } }
    }
    mutations.each do |label, mutate|
      gate = budget_result(action: "retry")
      mutate.call(gate)
      input = base_input.merge(
        "operation" => "budget_action", "budget_action" => "retry",
        "budget_lane_id" => "aw-i402", "budget_gate" => gate
      )

      _result, stderr, status = run_helper(input)
      refute status.success?, label
      assert_includes stderr, "budget result", label
    end
  end

  def test_budget_result_rejects_unicode_disguised_unknown
    gate = budget_result(action: "retry")
    gate["receipt"]["reservation_id"] = "ＵＮＫＮＯＷＮ"
    gate["decision_receipt"]["reservation_id"] = "ＵＮＫＮＯＷＮ"
    input = base_input.merge(
      "operation" => "budget_action", "budget_action" => "retry",
      "budget_lane_id" => "aw-i402", "budget_gate" => gate
    )

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "nested UNKNOWN"
  end

  def test_budget_result_rejects_nonportable_confusable_operational_ids
    gate = budget_result(action: "retry")
    gate["receipt"]["reservation_id"] = "UNKN\u039fWN"
    gate["receipt"]["request"]["id"] = "UNKN\u039fWN"
    gate["decision_receipt"]["reservation_id"] = "UNKN\u039fWN"
    gate["decision_receipt"]["request_digest"] = budget_request_digest(gate.dig("receipt", "request"))
    gate["receipt"]["request_digest"] = gate.dig("decision_receipt", "request_digest")
    input = budget_action_input("retry")
    input["budget_gate"] = gate

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "portable ASCII"
  end

  def test_budget_decision_evaluation_time_must_be_current_and_inside_the_trusted_bundle
    ["2000-01-01T00:00:00Z", "2099-01-01T00:00:00Z"].each do |evaluated_at|
      input = budget_action_input("retry")
      input["budget_gate"]["decision_receipt"]["evaluated_at"] = evaluated_at

      _result, stderr, status = run_helper(input)

      refute status.success?, evaluated_at
      assert_includes stderr, "budget decision evaluated_at must be current and inside trusted bundle validity"
    end

    input = budget_action_input("retry")
    input["budget_gate"]["decision_receipt"]["evaluated_at"] = (Time.now.utc - 120).iso8601
    bundle = trusted_bundle_for(input)
    bundle["issued_at"] = (Time.now.utc - 60).iso8601
    _result, stderr, status = run_helper(input, trusted_bundle: bundle)
    refute status.success?
    assert_includes stderr, "budget decision evaluated_at must be current and inside trusted bundle validity"
  end

  def test_replayed_admitted_budget_result_is_an_explicit_noop_and_preserves_original_checkpoint_semantics
    input = budget_action_input("retry")
    gate = input.fetch("budget_gate")
    gate["status"] = "replayed"
    gate["decision_status"] = "admitted"
    gate["state_revision"] += 1
    replay_plan = JSON.parse(File.read(gate.dig("decision_receipt", "trusted_plan_path")))
    FileUtils.rm_f(replay_plan.fetch("state_path"))

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal ["record_budget_replay"], result.fetch("allowed_actions")
    assert_equal false, result.fetch("wake_target")

    gate["decision_status"] = "admitted-with-warning"
    gate["decision_receipt"]["status"] = "admitted-with-warning"
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_includes stderr, "expected object"
  end

  def test_replayed_admitted_launch_does_not_authorize_worker_spawn
    input = launch_input
    gate = input.fetch("budget_gate").first
    decision = gate.fetch("decision_receipt")
    plan = JSON.parse(File.read(decision.fetch("trusted_plan_path")))
    anchor = {
      "path" => decision.fetch("trusted_plan_path"),
      "id" => decision.fetch("trusted_plan_id"),
      "digest" => decision.fetch("trusted_plan_digest")
    }
    replayed, replay_stderr, replay_status = run_budget_helper(
      BUDGET_HELPER, plan.fetch("state_path"), anchor,
      budget_command(
        "reserve", plan, { "reservation" => gate.dig("receipt", "request") },
        evaluated_at: (Time.now.utc - 5).iso8601
      )
    )
    assert replay_status.success?, replay_stderr
    assert_equal "replayed", replayed.fetch("status")
    input["budget_gate"] = [replayed]
    input["manifest"]["budgets"] = budget_manifest_binding(input.fetch("task"), results: input.fetch("budget_gate"))

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal ["record_budget_replay"], result.fetch("allowed_actions")
    assert_includes result.fetch("blockers"), "budget_admission_replayed_noop"
  end

  def test_real_stacked_base_budget_replay_is_accepted_as_record_only_by_canonical_control
    task = base_input.fetch("task")
    lane = task.fetch("lanes").first
    root = Dir.mktmpdir("canonical-a556-replay", TEST_TMP_ROOT)
    @temporary_roots << root
    state_path = File.join(root, "budget-state.json")
    plan = budget_plan(task).merge("state_path" => state_path)
    plan_path = install_budget_plan(plan, label: "a556-replay")
    anchor = {
      "path" => plan_path,
      "id" => plan.fetch("batch_id"),
      "digest" => findings_digest(plan)
    }
    legacy_helper = install_stacked_base_budget_helper(root)
    now = Time.at(Time.now.to_i).utc
    initialize_command = budget_command(
      "initialize", plan,
      { "budget" => plan },
      evaluated_at: (now - 120).iso8601
    )
    initialized, initialize_stderr, initialize_status = run_budget_helper(
      legacy_helper, state_path, anchor, initialize_command
    )
    assert initialize_status.success?, initialize_stderr
    assert_equal "initialized", initialized.fetch("status")

    request = budget_request(action: "worker_spawn", task: task, lane: lane)
    request.fetch("telemetry")["observed_at"] = (now - 30).iso8601
    reserve_command = budget_command(
      "reserve", plan,
      { "reservation" => request },
      evaluated_at: (now - 20).iso8601
    )
    admitted, reserve_stderr, reserve_status = run_budget_helper(
      legacy_helper, state_path, anchor, reserve_command
    )
    assert reserve_status.success?, reserve_stderr
    assert_equal "admitted", admitted.fetch("status")

    replay_command = reserve_command.merge("evaluated_at" => (now - 10).iso8601)
    replayed, replay_stderr, replay_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor, replay_command
    )
    assert replay_status.success?, replay_stderr
    assert_equal "replayed", replayed.fetch("status")
    assert_equal canonicalize(request), replayed.dig("decision_receipt", "request")
    assert_equal canonicalize(request), replayed.dig("receipt", "request")

    input = launch_input(task)
    input["budget_gate"] = [replayed]
    input["manifest"]["budgets"] = budget_manifest_binding(task, results: [replayed])
    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal ["record_budget_replay"], result.fetch("allowed_actions")
    assert_includes result.fetch("blockers"), "budget_admission_replayed_noop"
  end

  def test_replayed_budget_result_rejects_forged_decision_provenance
    mutations = {
      "future decision revision" => proc do |gate|
        gate["decision_receipt"]["state_revision"] = gate["state_revision"] + 1
      end,
      "unbound replay request digest" => proc do |gate|
        gate["decision_receipt"]["request_digest"] = "c" * 64
      end
    }
    mutations.each do |label, mutate|
      input = budget_action_input("retry")
      gate = input.fetch("budget_gate")
      gate["status"] = "replayed"
      gate["decision_status"] = "admitted"
      gate["state_revision"] += 1
      mutate.call(gate)

      _result, stderr, status = run_helper(input)

      refute status.success?, label
      assert_includes stderr, "budget", label
    end
  end

  def test_budget_result_rejects_forged_request_digest_and_revision_provenance
    mutations = {
      "request digest" => proc { |gate| gate["decision_receipt"]["request_digest"] = "b" * 64 },
      "receipt request digest" => proc { |gate| gate["receipt"]["request_digest"] = "b" * 64 },
      "request content" => proc { |gate| gate["receipt"]["request"]["tokens"] += 1 },
      "request evaluated ordering" => proc do |gate|
        gate["decision_receipt"]["request"]["telemetry"]["observed_at"] = (Time.now.utc + 60).iso8601
        request = gate["decision_receipt"]["request"]
        gate["decision_receipt"]["request_digest"] = budget_request_digest(request)
        gate["receipt"]["request"] = request
        gate["receipt"]["request_digest"] = gate["decision_receipt"]["request_digest"]
      end,
      "receipt revision" => proc { |gate| gate["receipt"]["state_revision"] = gate["decision_receipt"]["state_revision"] },
      "decision revision" => proc { |gate| gate["decision_receipt"]["state_revision"] = gate["receipt"]["state_revision"] }
    }
    mutations.each do |label, mutate|
      input = budget_action_input("retry")
      mutate.call(input.fetch("budget_gate"))

      _result, stderr, status = run_helper(input)

      refute status.success?, label
      assert_includes stderr, "budget", label
    end
  end

  def test_budget_result_rejects_stale_request_telemetry_even_with_recomputed_digests
    input = budget_action_input("retry")
    gate = input.fetch("budget_gate")
    request = canonicalize(gate.dig("decision_receipt", "request"))
    request["telemetry"]["observed_at"] = "2000-01-01T00:00:00Z"
    replace_budget_request!(gate, request)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "telemetry"
  end

  def test_budget_decision_telemetry_age_is_bound_to_the_verified_plan
    input = budget_action_input("retry")
    input.dig("budget_gate", "decision_receipt")["telemetry_max_age_seconds"] = 86_400

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "telemetry max age"
  end

  def test_budget_totals_enforce_hierarchical_counter_equations
    input = budget_action_input("retry")
    input.dig("budget_gate", "totals", "aggregate")["allocated_tokens"] += 1

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "hierarchical totals"

    input = budget_action_input("retry")
    input.dig("budget_gate", "totals", "aggregate")["limit_tokens"] += 1

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "trusted plan limits"
  end

  def test_admission_totals_reject_per_scope_reservation_above_allocation
    task = multi_target_task
    lane = task.fetch("lanes").first
    input = budget_action_input("retry", task: task, lane: lane)
    totals = input.dig("budget_gate", "totals")
    selected = totals.fetch("lanes").fetch(lane.fetch("id"))
    other = totals.fetch("lanes").fetch(task.fetch("lanes").last.fetch("id"))
    selected["allocated_tokens"] += 2
    other["reserved_tokens"] = 2
    totals.fetch("aggregate")["allocated_tokens"] += 2
    totals.fetch("aggregate")["reserved_tokens"] += 2

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "hierarchical totals"
  end

  def test_budget_result_rejects_receipt_token_and_admitted_totals_mismatches
    input = budget_action_input("retry")
    input["budget_gate"]["receipt"]["tokens"] = 1

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "reservation receipt binding mismatch"

    input = budget_action_input("retry")
    gate = input.fetch("budget_gate")
    [gate.dig("totals", "aggregate"), gate.dig("totals", "lanes", "aw-i402")].each do |totals|
      totals["allocated_tokens"] = 0
      totals["reserved_tokens"] = 0
    end

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "admitted totals"
  end

  def test_budget_result_overshoot_envelope_exactly_binds_descendant_targets
    input = budget_action_input("retry")
    gate = input.fetch("budget_gate")
    request = canonicalize(gate.dig("decision_receipt", "request"))
    request["telemetry"]["self_estimate_tokens"] = 9_000
    request["telemetry"]["descendant_estimate_tokens"] = 1_000
    request["telemetry"]["descendant_target_ids"] = ["child-task"]
    replace_budget_request!(gate, request)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "overshoot envelope"
  end

  def test_delegation_budget_request_binds_payload_source_and_target_state
    input = delegation_input(
      target_state: "idle", context: 10_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    gate = input.fetch("budget_gate")
    request = canonicalize(gate.dig("decision_receipt", "request"))
    request["source"]["task_id"] = "forged-source"
    request["source"]["work_item"]["number"] = 400
    replace_budget_request!(gate, request)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "delegation source"

    input = delegation_input(
      target_state: "idle", context: 10_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    gate = input.fetch("budget_gate")
    request = canonicalize(gate.dig("decision_receipt", "request"))
    request["target_state"] = "paused"
    replace_budget_request!(gate, request)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "delegation target state"
  end

  def test_budget_action_rejects_arbitrary_string_evidence
    input = base_input.merge(
      "operation" => "budget_action",
      "budget_action" => "retry",
      "budget_lane_id" => "aw-i402",
      "budget_gate" => { "source" => "caller-asserted-budget", "status" => "passed", "evidence_ref" => "local:budget:retry" }
    )

    _result, _stderr, status = run_helper(input)

    refute status.success?
  end

  def test_launch_budget_results_bind_by_lane_identity_not_array_position
    input = launch_input(multi_target_task)
    input["task"]["exception"]["concurrency"] = 2
    input["budget_gate"].reverse!
    input["manifest"]["budgets"] = budget_manifest_binding(input.fetch("task"), results: input.fetch("budget_gate"))

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_includes result.fetch("allowed_actions"), "worker_spawn"
  end

  def test_launch_requires_worker_spawn_permission_for_every_fresh_lane
    input = launch_input(multi_target_task)
    input["task"]["exception"]["concurrency"] = 2
    stage = input.fetch("typed_gates").find do |record|
      record["gate"] == "stage_dependency" && record["lane_id"] == "lane-402"
    end
    stage["permissions"] = %w[branch_worktree_create patch_edit commit]

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    refute_includes result.fetch("allowed_actions"), "worker_spawn"
    assert_includes result.fetch("blockers"), "stage_dependency_pending_or_worker_spawn_not_permitted"
  end

  def test_launch_enforces_multi_target_exception_concurrency
    input = launch_input(multi_target_task)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "launch lane count exceeds approved exception concurrency"
  end

  def test_launch_counts_active_reservations_from_prior_decisions_against_exception_concurrency
    input = launch_input(multi_target_task)
    result = input.fetch("budget_gate").last
    input["budget_gate"] = [result]
    input["manifest"]["budgets"] = budget_manifest_binding(input.fetch("task"), results: [result])

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "active launch lane count exceeds approved exception concurrency"
  end

  def test_launch_rejects_caller_erasure_of_prior_active_lane_from_submitted_totals
    task = multi_target_task
    input = launch_input(task)
    erased = canonicalize(input.fetch("budget_gate").last)
    prior_lane = erased.dig("totals", "lanes", "lane-402")
    %w[allocated_tokens consumed_tokens reserved_tokens released_tokens unattributed_tokens].each do |counter|
      erased.dig("totals", "aggregate")[counter] -= prior_lane[counter]
      prior_lane[counter] = 0
    end
    input["budget_gate"] = [erased]
    input["manifest"]["budgets"] = budget_manifest_binding(task, results: [erased])

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "active launch lane count exceeds approved exception concurrency"
  end

  def test_launch_fails_closed_when_trusted_budget_state_is_missing_corrupt_or_stale
    input = launch_input
    decision = input.dig("budget_gate", 0, "decision_receipt")
    state_path = JSON.parse(File.read(decision.fetch("trusted_plan_path"))).fetch("state_path")
    FileUtils.rm_f(state_path)

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "trusted budget state rejected: state-required"

    input = launch_input
    decision = input.dig("budget_gate", 0, "decision_receipt")
    state_path = JSON.parse(File.read(decision.fetch("trusted_plan_path"))).fetch("state_path")
    File.write(state_path, "{")

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "trusted budget state rejected: corrupt-persisted-state"

    input = launch_input
    gate = input.fetch("budget_gate").first
    gate["state_revision"] += 1
    gate.fetch("decision_receipt")["state_revision"] += 1
    input["manifest"]["budgets"] = budget_manifest_binding(input.fetch("task"), results: [gate])

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "trusted budget state snapshot is stale"
  end

  def test_launch_rejects_a_submitted_decision_absent_from_trusted_state
    input = launch_input
    gate = input.fetch("budget_gate").first
    forged_id = "forged-worker-spawn-reservation"
    gate.fetch("receipt")["reservation_id"] = forged_id
    gate.fetch("decision_receipt")["reservation_id"] = forged_id
    request = canonicalize(gate.dig("receipt", "request"))
    request["id"] = forged_id
    replace_budget_request!(gate, request)
    input["manifest"]["budgets"] = budget_manifest_binding(input.fetch("task"), results: [gate])

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "budget decision is absent from trusted state"
  end

  def test_launch_accepts_verified_active_reservation_after_partial_reconciliation
    input = launch_input
    gate = input.fetch("budget_gate").first
    decision = gate.fetch("decision_receipt")
    plan = JSON.parse(File.read(decision.fetch("trusted_plan_path")))
    anchor = {
      "path" => decision.fetch("trusted_plan_path"),
      "id" => decision.fetch("trusted_plan_id"),
      "digest" => decision.fetch("trusted_plan_digest")
    }
    state_path = plan.fetch("state_path")
    state = JSON.parse(File.read(state_path))
    now = Time.now.utc
    receipt = usage_receipt(
      batch_id: input.dig("task", "id"), lane_id: input.dig("task", "lanes", 0, "id"),
      total_tokens: 6_000, coordinator_tokens: 0, lane_tokens: 6_000,
      total_turns: 1, coordinator_turns: 0, lane_turns: 1, credits: 0.6
    )
    receipt.fetch("window")["from_inclusive"] = state.fetch("usage_initial_cutoff")
    receipt.fetch("window")["to_exclusive"] = (now - 5).iso8601
    receipt_ref = install_usage_receipt(receipt, label: "partial-launch")
    receipt_digest = findings_digest(receipt)
    reconciled, reconcile_stderr, reconcile_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command(
        "reconcile", plan,
        {
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => []
        },
        evaluated_at: now.iso8601
      )
    )
    assert reconcile_status.success?, reconcile_stderr
    assert_equal "reconciled", reconciled.fetch("status")
    assert_equal 4_000, reconciled.dig("totals", "lanes", "aw-i402", "reserved_tokens")

    snapshot, snapshot_stderr, snapshot_status = run_budget_state_snapshot(anchor)
    assert snapshot_status.success?, snapshot_stderr
    assert_equal 10_000, snapshot.dig("active_reservations", 0, "tokens")
    assert_equal 4_000, snapshot.dig("lane_reserved_tokens", "aw-i402")

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
  end

  def test_launch_accepts_a_production_coordinator_reservation_without_counting_it_as_a_lane
    input = launch_input
    gate = input.fetch("budget_gate").first
    decision = gate.fetch("decision_receipt")
    plan = JSON.parse(File.read(decision.fetch("trusted_plan_path")))
    anchor = {
      "path" => decision.fetch("trusted_plan_path"),
      "id" => decision.fetch("trusted_plan_id"),
      "digest" => decision.fetch("trusted_plan_digest")
    }
    coordinator_request = canonicalize(gate.dig("receipt", "request"))
    coordinator_request.merge!(
      "id" => "coordinator-model-turn-reservation",
      "scope_id" => "coordinator",
      "admission_kind" => "model-turn",
      "tokens" => 1_000,
      "message_fingerprint" => "coordinator-model-turn"
    )
    coordinator_request.fetch("target")["lane_id"] = "coordinator"
    coordinator_request.fetch("telemetry").merge!(
      "observed_at" => (Time.now.utc - 10).iso8601,
      "self_estimate_tokens" => 1_000
    )
    admitted, admission_stderr, admission_status = run_budget_helper(
      BUDGET_HELPER, plan.fetch("state_path"), anchor,
      budget_command(
        "reserve", plan, { "reservation" => coordinator_request },
        evaluated_at: (Time.now.utc - 5).iso8601
      )
    )
    assert admission_status.success?, admission_stderr
    assert_equal "admitted", admitted.fetch("status")
    snapshot, snapshot_stderr, snapshot_status = run_budget_state_snapshot(anchor)
    assert snapshot_status.success?, snapshot_stderr
    assert_equal %w[aw-i402 coordinator],
                 snapshot.fetch("active_reservations").map { |record| record.fetch("scope_id") }.sort

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["aw-i402"], result.fetch("launch_lane_ids")
  end

  def test_launch_allows_one_lane_under_serial_multi_target_exception
    task = multi_target_task
    input = launch_input(task, launch_lanes: [task.fetch("lanes").first])

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal ["lane-402"], result.fetch("launch_lane_ids")
    assert_empty result.fetch("replayed_lane_ids")
  end

  def test_launch_handles_fresh_and_replayed_budget_admissions_per_lane
    input = launch_input(multi_target_task)
    input["task"]["exception"]["concurrency"] = 2
    replayed = input.fetch("budget_gate").first
    replayed["status"] = "replayed"
    replayed["decision_status"] = "admitted"
    replayed["state_revision"] += 1
    input["manifest"]["budgets"] = budget_manifest_binding(input.fetch("task"), results: input.fetch("budget_gate"))

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")
    assert_equal [], result.fetch("allowed_actions")
    assert_equal ["record_budget_replay"], result.dig("allowed_actions_by_lane", "lane-402")
    assert_includes result.dig("allowed_actions_by_lane", "lane-403"), "worker_spawn"
    assert_equal ["lane-403"], result.fetch("launch_lane_ids")
    assert_equal ["lane-402"], result.fetch("replayed_lane_ids")
  end

  def test_trusted_bundle_uses_portable_capability_names
    input = launch_input
    bundle = trusted_bundle_for(input)
    bundle["capabilities"] = {
      "hierarchical_token_budgets" => "available",
      "replay_safe_usage_receipts" => "available"
    }

    result, stderr, status = run_helper(input, trusted_bundle: bundle)

    assert status.success?, stderr
    assert_equal "allow", result.fetch("verdict")

    bundle["capabilities"] = { "issue_398" => "available", "issue_399" => "available" }
    _result, stderr, status = run_helper(input, trusted_bundle: bundle)
    refute status.success?
    assert_includes stderr, "hierarchical_token_budgets"
  end

  def test_pilot_dependencies_use_portable_capability_names
    pilot = pilot_input

    result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))

    assert status.success?, stderr
    assert_equal "promote_ordinary_default", result.fetch("pilot_verdict")

    dependency = pilot.fetch("dependencies").first
    dependency.delete("capability")
    dependency["issue"] = 398
    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))
    refute status.success?
    assert_includes stderr, "portable capabilities"
  end

  def test_budget_action_rejects_caller_asserted_legacy_budget_evidence
    input = base_input.merge(
      "operation" => "budget_action",
      "budget_action" => "retry",
      "budget_lane_id" => "aw-i402",
      "budget_gate" => bound_evidence(
        contract: "budget-evidence", task: base_input.fetch("task"),
        action: "retry", role: "budget_owner"
      )
    )

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "batch-token-budget-result"
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

  def test_malformed_target_and_pilot_dependency_shapes_fail_without_backtraces
    input = launch_input
    input["task"]["targets"] = [5]
    _result, stderr, status = run_helper(input)
    refute status.success?
    assert_match(/\AINVALID_INPUT: /, stderr)
    refute_includes stderr, "canonical-task-control:"

    pilot = pilot_input
    pilot["dependencies"][1] = "bogus"
    _result, stderr, status = run_helper(base_input.merge("operation" => "pilot_evaluation", "pilot" => pilot))
    refute status.success?
    assert_match(/\AINVALID_INPUT: /, stderr)
    refute_includes stderr, "canonical-task-control:"
  end

  def test_child_actor_must_match_manifest_owner_for_declared_role
    input = child_receipt_input
    input.fetch("children").fetch("receipts").first["actor"] = "maker-aw-i402"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "child actor must match manifest ownership"
  end

  def test_terminal_delegation_returns_deterministic_block_before_budget_validation
    input = delegation_input(
      target_state: "terminal", context: 10_000, threshold: 50_000,
      message_class: "new_evidence", human_approval: "UNKNOWN"
    )
    input["budget_gate"] = { "malformed" => true }

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal ["target_terminal"], result.fetch("blockers")
    assert_empty result.fetch("allowed_actions")
  end

  def test_typed_gate_permission_and_cardinality_guards_reject_directly
    mutations = {
      "permissions must be an array" => lambda do |input|
        input.fetch("typed_gates").find { |gate| gate["gate"] == "stage_dependency" }["permissions"] = "worker_spawn"
      end,
      "permissions are invalid" => lambda do |input|
        input.fetch("typed_gates").find { |gate| gate["gate"] == "stage_dependency" }["permissions"] = ["push"]
      end,
      "only stage dependency result may carry permissions" => lambda do |input|
        input.fetch("typed_gates").find { |gate| gate["gate"] == "security" }["permissions"] = ["worker_spawn"]
      end,
      "typed gates must contain exactly one required gate per target" => lambda do |input|
        input.fetch("typed_gates").pop
      end
    }

    mutations.each do |message, mutate|
      input = launch_input
      mutate.call(input)
      _result, stderr, status = run_helper(input)
      refute status.success?, message
      assert_includes stderr, message
    end
  end

  def test_disagreeing_stage_results_fail_closed_directly
    input = launch_input(multi_target_task)
    input["task"]["exception"]["concurrency"] = 2
    input.fetch("typed_gates").select { |gate| gate["gate"] == "stage_dependency" }.last["result"] = "pending"

    _result, stderr, status = run_helper(input)

    refute status.success?
    assert_includes stderr, "stage dependency results must agree"
  end

  def test_multi_target_launch_intersects_flat_permissions_and_exposes_lane_scoped_permissions
    task = multi_target_task
    task.fetch("exception")["concurrency"] = 2
    input = launch_input(task)
    input.fetch("manifest").fetch("gates")["stage_dependency"] = "pending"
    stage_records = input.fetch("typed_gates").select { |record| record["gate"] == "stage_dependency" }
    stage_records.each { |record| record["result"] = "pending" }
    stage_records.fetch(0)["permissions"] = %w[branch_worktree_create patch_edit]
    stage_records.fetch(1)["permissions"] = ["commit"]

    result, stderr, status = run_helper(input)

    assert status.success?, stderr
    assert_equal "block", result.fetch("verdict")
    assert_equal [], result.fetch("allowed_actions")
    assert_equal(
      { "lane-402" => %w[branch_worktree_create patch_edit], "lane-403" => ["commit"] },
      result.fetch("allowed_actions_by_lane")
    )
  end

  private

  def launch_input(task = base_input.fetch("task"), launch_lanes: nil, real_budget_state: true)
    lanes = launch_lanes || task.fetch("lanes")
    budget_results = if real_budget_state
                       real_launch_budget_results(task, lanes: lanes)
                     else
                       lanes.map.with_index do |lane, index|
                         budget_result(
                           action: "worker_spawn", task: task, lane: lane, revision: index + 2,
                           persisted_state: false
                         )
                       end
                     end
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
      "manifest" => compact_manifest(task).merge("budgets" => budget_manifest_binding(task, results: budget_results)),
      "lifecycle" => {
        "context_threshold" => 50_000,
        "context_threshold_source" => "trusted-policy-v1",
        "checkpoints" => task.fetch("targets").flat_map do |target|
          [checkpoint("plan_settlement", task: task, target: target), checkpoint("dispatch", task: task, target: target)]
        end
      },
      "budget_gate" => budget_results,
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

  def real_launch_budget_results(task, lanes:)
    if task.dig("exception", "budget_plan_anchor")
      plan = task.dig("exception", "budget_plan")
      plan_anchor = task.dig("exception", "budget_plan_anchor")
      anchor = {
        "path" => plan_anchor.fetch("trusted_plan_path"),
        "id" => plan_anchor.fetch("trusted_plan_id"),
        "digest" => plan_anchor.fetch("trusted_plan_digest")
      }
    else
      plan = budget_plan(task)
      path = install_budget_plan(plan, label: "launch-state")
      anchor = { "path" => path, "id" => plan.fetch("batch_id"), "digest" => findings_digest(plan) }
    end
    state_path = plan.fetch("state_path")
    @budget_state_paths << state_path unless @budget_state_paths.include?(state_path)
    FileUtils.rm_f(state_path)
    FileUtils.rm_f("#{state_path}.lock")
    now = Time.now.utc
    _initialized, stderr, status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command("initialize", plan, { "budget" => plan }, evaluated_at: (now - 60).iso8601)
    )
    raise "launch budget initialization failed: #{stderr}" unless status.success?

    lanes.map.with_index do |lane, index|
      request = budget_request(action: "worker_spawn", task: task, lane: lane)
      request.fetch("telemetry")["observed_at"] = (now - 30 + index).iso8601
      result, reserve_stderr, reserve_status = run_budget_helper(
        BUDGET_HELPER, state_path, anchor,
        budget_command("reserve", plan, { "reservation" => request }, evaluated_at: (now - 20 + index).iso8601)
      )
      raise "launch budget reservation failed: #{reserve_stderr}" unless reserve_status.success?

      result
    end
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
    task["exception"]["budget_plan"] = budget_plan(task)
    trusted_plan_path = install_budget_plan(task["exception"]["budget_plan"])
    task["exception"]["budget_plan_anchor"] = {
      "trusted_plan_path" => trusted_plan_path,
      "trusted_plan_id" => task.fetch("id"),
      "trusted_plan_digest" => findings_digest(task["exception"]["budget_plan"])
    }
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
      "budgets" => budget_manifest_binding(task),
      "decisions" => ["ordinary topology"],
      "receipt_refs" => ["https://example.test/receipts/#{task.fetch('id')}/manifest"]
    }
  end

  def budget_plan(task = base_input.fetch("task"))
    lanes = task.fetch("lanes").to_h { |lane| [lane.fetch("id"), { "limit_tokens" => 50_000 }] }
    {
      "type" => "batch-token-budget", "version" => 1, "batch_id" => task.fetch("id"),
      "state_path" => File.join(TEST_TMP_ROOT, "#{task.fetch('id')}-budget-state.json"),
      "scopes" => {
        "aggregate" => { "limit_tokens" => 50_000 * lanes.length },
        "coordinator" => { "limit_tokens" => 10_000 }, "lanes" => lanes
      },
      "thresholds" => { "warning_percent" => 50, "approval_percent" => 80, "hard_percent" => 100 },
      "telemetry" => { "max_age_seconds" => 900 },
      "delegation" => { "approval_threshold_tokens" => 25_000 },
      "trusted_verifiers" => [{
        "id" => "budget-verifier", "algorithm" => "rsa-pss-sha256",
        "public_key_pem" => TEST_BUDGET_VERIFIER_KEY.public_key.to_pem
      }]
    }
  end

  def install_budget_plan(plan, label: "trusted")
    @trusted_plan_sequence += 1
    path = File.join(TEST_TMP_ROOT, "budget-plan-#{Process.pid}-#{@trusted_plan_sequence}-#{label}.json")
    File.write(path, JSON.generate(canonicalize(plan)), mode: "w", perm: 0o600)
    @trusted_plan_paths << path
    path
  end

  def budget_manifest_binding(task = base_input.fetch("task"), results: nil)
    results ||= task.fetch("lanes").map.with_index do |lane, index|
      budget_result(
        action: "worker_spawn", task: task, lane: lane, revision: index + 2, persisted_state: false
      )
    end
    {
      "contract" => "batch-token-budget-result-set", "version" => 1,
      "batch_id" => task.fetch("id"),
      "result_digests" => results.to_h do |result|
        [result.dig("receipt", "scope_id"), findings_digest(result)]
      end
    }
  end

  def budget_result(action:, task: base_input.fetch("task"), lane: task.fetch("lanes").first, revision: 2,
                    status: "admitted", persisted_state: true)
    if persisted_state && status == "admitted" && !lane.fetch("target").start_with?("adhoc:")
      return real_budget_action_result(action: action, task: task, lane: lane)
    end

    admission_kind = {
      "worker_spawn" => "spawn", "delegation" => "cross-task-delegation",
      "resume" => "resume", "retry" => "retry", "review_wave" => "review-wave"
    }.fetch(action)
    request = budget_request(action: action, task: task, lane: lane)
    request["target_state"] = "active" if status == "coalesced"
    request["target_state"] = "paused" if status == "blocked"
    request_digest = budget_request_digest(request)
    plan = budget_plan(task)
    trusted_plan_path = install_budget_plan(plan, label: "admission")
    receipt = {
      "type" => "batch-token-budget-reservation-receipt", "version" => 1,
      "batch_id" => task.fetch("id"), "state_revision" => revision - 1,
      "preserved_gates" => %w[security review qa exact-head ownership merge],
      "reservation_id" => "#{lane.fetch('id')}-#{action}-reservation",
      "scope_id" => lane.fetch("id"), "tokens" => 10_000,
      "admission_kind" => admission_kind, "target_id" => task.fetch("id"),
      "request" => request, "request_digest" => request_digest,
      "threshold_state" => "ok",
      "overshoot_envelope" => { "max_in_flight_turns" => 1, "target_ids" => [task.fetch("id")] }
    }
    decision_receipt = {
      "type" => "batch-token-budget-reservation-decision-receipt", "version" => 1,
      "batch_id" => task.fetch("id"), "state_revision" => revision,
      "preserved_gates" => %w[security review qa exact-head ownership merge],
      "reservation_id" => receipt.fetch("reservation_id"),
      "request" => request, "request_digest" => request_digest, "status" => status,
      "telemetry_max_age_seconds" => 900,
      "trusted_plan_path" => trusted_plan_path,
      "trusted_plan_id" => plan.fetch("batch_id"),
      "trusted_plan_digest" => findings_digest(plan),
      "reason" => if status == "blocked"
                    "paused-target-requires-resume-approval"
                  else
                    (status == "coalesced" ? "target-already-active" : nil)
                  end,
      "evaluated_at" => Time.now.utc.iso8601
    }
    result = {
      "type" => "batch-token-budget-result", "version" => 1, "status" => status,
      "batch_id" => task.fetch("id"), "state_revision" => revision,
      "totals" => {
        "aggregate" => budget_scope_totals(status, limit_tokens: plan.dig("scopes", "aggregate", "limit_tokens")),
        "coordinator" => budget_scope_totals("idle", limit_tokens: plan.dig("scopes", "coordinator", "limit_tokens")),
        "lanes" => task.fetch("lanes").to_h do |task_lane|
          [task_lane.fetch("id"), budget_scope_totals(
            task_lane.fetch("id") == lane.fetch("id") ? status : "idle",
            limit_tokens: plan.dig("scopes", "lanes", task_lane.fetch("id"), "limit_tokens")
          )]
        end
      },
      "preserved_gates" => %w[security review qa exact-head ownership merge],
      "decision_receipt" => decision_receipt
    }
    if %w[admitted admitted-with-warning].include?(status)
      result.merge!("receipt" => receipt, "checkpoint" => nil)
    elsif status == "coalesced"
      result.merge!("reason" => "target-already-active", "coalesced_reservation_id" => nil)
    elsif status == "blocked"
      result["reason"] = "paused-target-requires-resume-approval"
    end
    result
  end

  def real_budget_action_result(action:, task:, lane:)
    plan = budget_plan(task)
    trusted_plan_path = install_budget_plan(plan, label: "#{action}-state")
    anchor = { "path" => trusted_plan_path, "id" => plan.fetch("batch_id"), "digest" => findings_digest(plan) }
    state_path = plan.fetch("state_path")
    @budget_state_paths << state_path unless @budget_state_paths.include?(state_path)
    FileUtils.rm_f(state_path)
    FileUtils.rm_f("#{state_path}.lock")
    now = Time.at(Time.now.to_i).utc
    _initialized, initialize_stderr, initialize_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command("initialize", plan, { "budget" => plan }, evaluated_at: (now - 60).iso8601)
    )
    raise "budget action initialization failed: #{initialize_stderr}" unless initialize_status.success?

    request = budget_request(action: action, task: task, lane: lane)
    request.fetch("telemetry")["observed_at"] = (now - 30).iso8601
    result, reserve_stderr, reserve_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command("reserve", plan, { "reservation" => request }, evaluated_at: (now - 20).iso8601)
    )
    raise "budget action reservation failed: #{reserve_stderr}" unless reserve_status.success?
    raise "budget action reservation was not admitted: #{result['status']}" unless result["status"] == "admitted"

    result
  end

  def budget_request(action:, task:, lane:)
    admission_kind = {
      "worker_spawn" => "spawn", "delegation" => "cross-task-delegation",
      "resume" => "resume", "retry" => "retry", "review_wave" => "review-wave"
    }.fetch(action)
    request = {
      "type" => "batch-token-reservation", "version" => 1,
      "id" => "#{lane.fetch('id')}-#{action}-reservation",
      "scope_id" => lane.fetch("id"), "tokens" => 10_000,
      "admission_kind" => admission_kind,
      "target" => {
        "task_id" => task.fetch("id"), "batch_id" => task.fetch("id"), "lane_id" => lane.fetch("id"),
        "root_id" => "root-#{task.fetch('id')}",
        "work_item" => {
          "repo" => lane.fetch("repository"),
          "type" => lane.fetch("target").split(":", 2).first,
          "number" => lane.fetch("target").split(":", 2).last.to_i
        }
      },
      "target_state" => "idle", "message_fingerprint" => "message-#{lane.fetch('id')}-#{action}",
      "telemetry" => {
        "status" => "fresh", "observed_at" => Time.now.utc.iso8601, "context_status" => "ready",
        "self_estimate_tokens" => 10_000, "descendant_estimate_tokens" => 0,
        "descendant_target_ids" => []
      }
    }
    if action == "delegation"
      request["source"] = {
        "task_id" => "source-task", "batch_id" => "source-batch", "lane_id" => "source-lane",
        "root_id" => "root-source-task",
        "work_item" => { "repo" => lane.fetch("repository"), "type" => "issue", "number" => 401 }
      }
    end
    request
  end

  def budget_request_digest(request)
    Digest::SHA256.hexdigest(JSON.generate(canonicalize(request)))
  end

  def replace_budget_request!(gate, request)
    digest = budget_request_digest(request)
    gate.fetch("decision_receipt")["request"] = canonicalize(request)
    gate.fetch("decision_receipt")["request_digest"] = digest
    return unless gate["receipt"]

    gate.fetch("receipt")["request"] = canonicalize(request)
    gate.fetch("receipt")["request_digest"] = digest
  end

  def budget_scope_totals(status, limit_tokens: 50_000)
    allocated = %w[admitted admitted-with-warning].include?(status) ? 10_000 : 0
    {
      "limit_tokens" => limit_tokens, "allocated_tokens" => allocated,
      "consumed_tokens" => 0, "reserved_tokens" => allocated,
      "released_tokens" => 0, "unattributed_tokens" => 0
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
      **evidence_times,
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
      **evidence_times,
      "evidence_ref" => "https://example.test/evidence/#{contract}/#{action}"
    }
    if contract == "budget-evidence"
      evidence["policy_issue"] = 399
      evidence["amount"] = 50_000
      evidence["unit"] = "tokens"
    end
    evidence
  end

  def evidence_times
    now = Time.now.utc
    {
      "issued_at" => (now - 30).iso8601,
      "observed_at" => (now - 20).iso8601,
      "expires_at" => (now + 300).iso8601
    }
  end

  def delegation_input(target_state:, context:, threshold:, message_class:, human_approval:)
    base_input.merge(
      "operation" => "delegation",
      "manifest" => compact_manifest,
      "lifecycle" => {
        "context_threshold" => threshold,
        "context_threshold_source" => "policy:pilot-a",
        "checkpoints" => [checkpoint("cross_task_handoff")]
      },
      "budget_gate" => budget_result(
        action: "delegation",
        status: if target_state == "active"
                  "coalesced"
                else
                  (target_state == "paused" ? "blocked" : "admitted")
                end
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
        "human_approval" => human_approval
      }
    )
  end

  def budget_action_input(action, task: base_input.fetch("task"), lane: task.fetch("lanes").first)
    base_input.merge(
      "operation" => "budget_action", "task" => task,
      "budget_action" => action, "budget_lane_id" => lane.fetch("id"),
      "budget_gate" => budget_result(action: action, task: task, lane: lane)
    )
  end

  def usage_reconciliation_input(fractional_window: false)
    task = base_input.fetch("task")
    plan = budget_plan(task)
    trusted_plan_path = install_budget_plan(plan, label: "reconciliation")
    anchor = { "path" => trusted_plan_path, "id" => plan.fetch("batch_id"), "digest" => findings_digest(plan) }
    state_path = plan.fetch("state_path")
    @budget_state_paths << state_path unless @budget_state_paths.include?(state_path)
    FileUtils.rm_f(state_path)
    FileUtils.rm_f("#{state_path}.lock")
    now = Time.at(Time.now.to_i).utc
    initialized_at = now - 120
    _initialized, initialize_stderr, initialize_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command("initialize", plan, { "budget" => plan }, evaluated_at: initialized_at.iso8601)
    )
    raise "reconciliation budget initialization failed: #{initialize_stderr}" unless initialize_status.success?

    request = budget_request(action: "delegation", task: task, lane: task.fetch("lanes").first)
    request.fetch("telemetry")["observed_at"] = (now - 100).iso8601
    admitted, admission_stderr, admission_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command("reserve", plan, { "reservation" => request }, evaluated_at: (now - 90).iso8601)
    )
    raise "reconciliation reservation failed: #{admission_stderr}" unless admission_status.success?
    raise "reconciliation reservation was not admitted" unless admitted["status"] == "admitted"

    receipt = usage_receipt(batch_id: "task-402", lane_id: "aw-i402", total_tokens: 35,
                            coordinator_tokens: 10, lane_tokens: 25, total_turns: 3,
                            coordinator_turns: 1, lane_turns: 2, credits: 3.5)
    from_inclusive = initialized_at.iso8601
    to_exclusive = (now - 10).iso8601
    if fractional_window
      from_inclusive = initialized_at.iso8601(9)
      to_exclusive = (now - 10).iso8601(9)
    end
    receipt.fetch("window").merge!("from_inclusive" => from_inclusive, "to_exclusive" => to_exclusive)
    digest = findings_digest(receipt)
    reference = install_usage_receipt(receipt, label: "task-402")
    result, reconcile_stderr, reconcile_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command(
        "reconcile", plan,
        {
          "usage_receipt" => receipt, "usage_receipt_ref" => reference, "usage_receipt_digest" => digest,
          "completed_reservation_ids" => [request.fetch("id")],
          "charge_backs" => [{
            "reservation_id" => request.fetch("id"),
            "charge_back" => {
              "type" => "batch-token-charge-back", "version" => 1, "id" => "charge-back-402",
              "source" => request.fetch("source"), "target" => request.fetch("target")
            }
          }]
        },
        evaluated_at: now.iso8601
      )
    )
    raise "usage reconciliation failed: #{reconcile_stderr}" unless reconcile_status.success?
    unless result["status"] == "reconciled"
      raise "usage reconciliation was not admitted: #{result['status']}: #{result['reason']}"
    end

    base_input.merge(
      "operation" => "usage_reconciliation",
      "usage_reconciliation" => {
        "source" => { "task_id" => "source-task", "repository" => "shakacode/agent-workflows", "target" => "issue:401" },
        "target" => { "task_id" => "task-402", "repository" => "shakacode/agent-workflows", "target" => "issue:402" },
        "usage_receipt" => receipt,
        "usage_receipt_ref" => reference,
        "usage_receipt_digest" => digest,
        "budget_result" => result
      }
    )
  end

  def real_multi_source_usage_reconciliation_input(shared_source: false)
    task = multi_target_task
    plan = task.dig("exception", "budget_plan")
    plan_anchor = task.dig("exception", "budget_plan_anchor")
    anchor = {
      "path" => plan_anchor.fetch("trusted_plan_path"),
      "id" => plan_anchor.fetch("trusted_plan_id"),
      "digest" => plan_anchor.fetch("trusted_plan_digest")
    }
    state_path = plan.fetch("state_path")
    @budget_state_paths << state_path unless @budget_state_paths.include?(state_path)
    FileUtils.rm_f(state_path)
    FileUtils.rm_f("#{state_path}.lock")
    now = Time.now.utc
    initialized_at = now - 120
    _initialized, initialize_stderr, initialize_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command("initialize", plan, { "budget" => plan }, evaluated_at: initialized_at.iso8601)
    )
    raise "reconciliation budget initialization failed: #{initialize_stderr}" unless initialize_status.success?

    reservation_rows = task.fetch("lanes").map.with_index do |lane, index|
      request = budget_request(action: "delegation", task: task, lane: lane)
      source_number = shared_source ? 401 : 401 + index
      source_task_id = shared_source ? "source-task-a" : "source-task-#{('a'.ord + index).chr}"
      request["source"] = task_identity(
        source_task_id, "source-batch-#{index + 1}", "source-lane-#{index + 1}", "issue", source_number
      )
      request.fetch("telemetry")["observed_at"] = (now - 100 + index).iso8601
      admitted, admission_stderr, admission_status = run_budget_helper(
        BUDGET_HELPER, state_path, anchor,
        budget_command(
          "reserve", plan, { "reservation" => request }, evaluated_at: (now - 90 + index).iso8601
        )
      )
      raise "reconciliation reservation failed: #{admission_stderr}" unless admission_status.success?
      raise "reconciliation reservation was not admitted" unless admitted["status"] == "admitted"

      [request, lane, index]
    end

    receipt = usage_receipt(
      batch_id: task.fetch("id"), lane_id: "lane-402", total_tokens: 35,
      coordinator_tokens: 0, lane_tokens: 15, total_turns: 2,
      coordinator_turns: 0, lane_turns: 1, credits: 3.5
    )
    second_lane = usage_receipt(
      batch_id: task.fetch("id"), lane_id: "lane-403", total_tokens: 20,
      coordinator_tokens: 0, lane_tokens: 20, total_turns: 1,
      coordinator_turns: 0, lane_turns: 1, credits: 2.0
    ).fetch("lanes").first
    receipt.fetch("lanes") << second_lane
    receipt.fetch("window").merge!(
      "from_inclusive" => initialized_at.iso8601,
      "to_exclusive" => (now - 10).iso8601
    )
    receipt_ref = install_usage_receipt(receipt, label: "multi-source-production")
    receipt_digest = findings_digest(receipt)
    charge_backs = reservation_rows.map do |request, _lane, index|
      {
        "reservation_id" => request.fetch("id"),
        "charge_back" => {
          "type" => "batch-token-charge-back", "version" => 1,
          "id" => "multi-source-charge-back-#{index + 1}",
          "source" => request.fetch("source"), "target" => request.fetch("target")
        }
      }
    end
    reconciled, reconcile_stderr, reconcile_status = run_budget_helper(
      BUDGET_HELPER, state_path, anchor,
      budget_command(
        "reconcile", plan,
        {
          "usage_receipt" => receipt,
          "usage_receipt_ref" => receipt_ref,
          "usage_receipt_digest" => receipt_digest,
          "completed_reservation_ids" => reservation_rows.map { |request, _lane, _index| request.fetch("id") },
          "charge_backs" => charge_backs
        },
        evaluated_at: now.iso8601
      )
    )
    raise "usage reconciliation failed: #{reconcile_stderr}" unless reconcile_status.success?
    raise "usage reconciliation was not admitted" unless reconciled["status"] == "reconciled"

    base_input.merge(
      "operation" => "usage_reconciliation", "task" => task,
      "usage_reconciliation" => {
        "source" => {
          "task_id" => "source-task-a", "repository" => "shakacode/agent-workflows", "target" => "issue:401"
        },
        "target" => {
          "task_id" => task.fetch("id"), "repository" => "shakacode/agent-workflows",
          "target" => shared_source ? "issue:403" : "issue:402"
        },
        "usage_receipt" => receipt, "usage_receipt_ref" => receipt_ref,
        "usage_receipt_digest" => receipt_digest, "budget_result" => reconciled
      }
    )
  end

  def install_usage_receipt(receipt, label: "usage")
    @usage_receipt_sequence += 1
    path = File.join(TEST_TMP_ROOT, "usage-receipt-#{Process.pid}-#{@usage_receipt_sequence}-#{label}.json")
    File.write(path, JSON.generate(canonicalize(receipt)), mode: "w", perm: 0o600)
    @usage_receipt_paths << path
    "file://#{path}"
  end

  def refresh_usage_artifact!(container)
    receipt = container.fetch("usage_receipt")
    reference = install_usage_receipt(receipt, label: "refreshed")
    digest = findings_digest(receipt)
    container["usage_receipt_ref"] = reference
    container["usage_receipt_digest"] = digest
    result = container.fetch("budget_result")
    result["usage_receipt_digest"] = digest
    result["receipt_ref"] = reference
    result.fetch("receipts").each do |record|
      record["usage_receipt_digest"] = digest
      record["receipt_ref"] = reference
    end
  end

  def apply_producer_fractional_window!(container)
    window = container.fetch("usage_receipt").fetch("window")
    %w[from_inclusive to_exclusive].each do |field|
      window[field] = Time.iso8601(window.fetch(field)).utc.iso8601(9)
    end
    container.fetch("budget_result").fetch("receipts").each do |record|
      record["from_inclusive"] = window.fetch("from_inclusive")
      record["to_exclusive"] = window.fetch("to_exclusive")
    end
    refresh_usage_artifact!(container)
  end

  def delegation_approval
    bound_evidence(
      contract: "authority-evidence", task: base_input.fetch("task"),
      action: "wake_target_task", role: "maintainer"
    )
  end

  def usage_vector(total)
    {
      "input_tokens" => total, "output_tokens" => 0,
      "reasoning_output_tokens" => 0, "cache_read_tokens" => 0,
      "total_tokens" => total
    }
  end

  def route(host: "codex", model: "gpt-5.6-sol", effort: "high")
    { "host" => host, "model" => model, "effort" => effort }
  end

  def observed_route(total, host: "codex", model: "gpt-5.6-sol", effort: "high")
    route(host: host, model: model, effort: effort).merge(
      "provider" => "openai", "usage" => usage_vector(total)
    )
  end

  def scope_evidence(id)
    {
      "status" => "complete", "physical_rollout_ids" => ["sha256:#{Digest::SHA256.hexdigest(id)}"],
      "first_session_ids" => [id], "first_session_id" => id
    }
  end

  def usage_receipt(batch_id:, lane_id:, total_tokens:, coordinator_tokens:, lane_tokens:,
                    total_turns:, coordinator_turns:, lane_turns:, credits:)
    zero = usage_vector(0)
    {
      "schema" => "batch-usage-receipt-v2",
      "batch" => {
        "scope" => "batch", "id" => batch_id,
        "usage" => { "descendant_inclusive" => usage_vector(total_tokens), "unattributed" => zero },
        "turns" => { "descendant_inclusive" => total_turns, "unattributed" => 0 },
        "reconciliation" => { "status" => "balanced", "equation" => "coordinator + lanes" }
      },
      "coordinator" => {
        "scope" => "coordinator", "id" => "coordinator-#{batch_id}", "root_thread_id" => "root-#{batch_id}",
        "requested_route" => route, "observed_routes" => [observed_route(coordinator_tokens)],
        "usage" => { "self_only" => usage_vector(coordinator_tokens),
                     "descendant_inclusive" => usage_vector(coordinator_tokens) },
        "turns" => { "self_only" => coordinator_turns, "descendant_inclusive" => coordinator_turns },
        "evidence" => scope_evidence("coordinator-#{batch_id}")
      },
      "lanes" => [{
        "scope" => "lane", "id" => lane_id, "root_thread_id" => "root-#{lane_id}",
        "requested_route" => route, "observed_routes" => [observed_route(lane_tokens)],
        "usage" => { "self_only" => usage_vector(lane_tokens),
                     "descendant_inclusive" => usage_vector(lane_tokens), "unattributed" => zero },
        "turns" => { "self_only" => lane_turns, "descendant_inclusive" => lane_turns, "unattributed" => 0 },
        "evidence" => scope_evidence(lane_id),
        "workers" => [{
          "scope" => "worker", "id" => "worker-#{lane_id}", "root_thread_id" => "root-worker-#{lane_id}",
          "requested_route" => route, "observed_routes" => [observed_route(lane_tokens)],
          "usage" => { "self_only" => usage_vector(lane_tokens),
                       "descendant_inclusive" => usage_vector(lane_tokens) },
          "turns" => { "self_only" => lane_turns, "descendant_inclusive" => lane_turns },
          "evidence" => scope_evidence("worker-#{lane_id}")
        }],
        "reconciliation" => { "status" => "balanced", "equation" => "lane self + workers" }
      }],
      "window" => {
        "from_inclusive" => "2026-08-12T00:00:00Z", "to_exclusive" => "2026-08-12T01:00:00Z",
        "differencing" => "full_history_before_window_filter"
      },
      "accounting" => {
        "compactions" => 0, "counter_resets" => 0, "duplicate_samples_omitted" => 0,
        "inherited_seeds_omitted" => 0, "replay_records_omitted" => 0,
        "session_rebind_attempts_ignored" => 0, "usage_samples" => total_turns
      },
      "evidence" => { "status" => "complete", "sources" => ["codex_rollout_jsonl", "state_5.sqlite"], "unknown" => [] },
      "privacy" => { "mode" => "metadata_only", "emitted_or_persisted_content" => false,
                     "excluded" => %w[prompts responses secrets] },
      "credit_equivalents" => {
        "status" => "available", "source" => "https://example.test/rates/2026-08-01",
        "effective_date" => "2026-08-01",
        "model_values" => [{ "host" => "codex", "model" => "gpt-5.6-sol", "status" => "available", "credits" => credits }],
        "disclaimer" =>
          "Analytical credit equivalents only; this is not a bill, invoice, charge, or authoritative provider cost."
      }
    }
  end

  def budget_reconciliation_result(receipt_digest:, batch_id: "task-402",
                                   receipt_ref: "file:///coordinator/receipts/task-402-usage-v2.json", tokens: 35,
                                   lane_id: "aw-i402", coordinator_tokens: 10, lane_tokens: 25)
    predicted_tokens = [10_000, tokens].max
    released_tokens = predicted_tokens - tokens
    scope = lambda do |limit:, allocated:, consumed:, released:|
      {
        "limit_tokens" => limit, "allocated_tokens" => allocated,
        "consumed_tokens" => consumed, "reserved_tokens" => 0,
        "released_tokens" => released, "unattributed_tokens" => 0
      }
    end
    {
      "type" => "batch-token-budget-result", "version" => 1, "status" => "reconciled",
      "batch_id" => batch_id, "state_revision" => 3,
      "totals" => {
        "aggregate" => scope.call(limit: [50_000, predicted_tokens].max, allocated: predicted_tokens,
                                  consumed: tokens, released: released_tokens),
        "coordinator" => scope.call(limit: 10_000, allocated: 0, consumed: coordinator_tokens, released: 0),
        "lanes" => {
          lane_id => scope.call(limit: [50_000, predicted_tokens].max, allocated: predicted_tokens,
                                consumed: lane_tokens, released: released_tokens)
        }
      },
      "preserved_gates" => %w[security review qa exact-head ownership merge],
      "usage_receipt_digest" => receipt_digest, "receipt_ref" => receipt_ref,
      "trusted_plan_path" => File.join(TEST_TMP_ROOT, "synthetic-reconciliation-plan.json"),
      "trusted_plan_id" => batch_id,
      "trusted_plan_digest" => "sha256:#{'0' * 64}",
      "receipts" => [{
        "type" => "batch-token-budget-reconciliation-receipt", "version" => 1,
        "batch_id" => batch_id, "state_revision" => 3,
        "preserved_gates" => %w[security review qa exact-head ownership merge],
        "reservation_id" => "aw-i402-delegation-reservation", "usage_receipt_digest" => receipt_digest,
        "receipt_ref" => receipt_ref, "from_inclusive" => "2026-08-12T00:00:00Z",
        "to_exclusive" => "2026-08-12T01:00:00Z", "predicted_tokens" => predicted_tokens,
        "interval_tokens" => tokens, "actual_tokens" => tokens, "released_tokens" => released_tokens,
        "overshoot_tokens" => 0, "overshoot_turn_count" => 0, "completed" => true
      }],
      "charge_backs" => [{
        "id" => "charge-back-402", "source" => task_identity("source-task", "batch-source", "source-lane", "issue", 401),
        "target" => task_identity("task-402", batch_id, "aw-i402", "issue", 402),
        "reservation_id" => "aw-i402-delegation-reservation",
        "tokens" => 35, "physical_total_incremented" => false
      }]
    }
  end

  def task_identity(task_id, batch_id, lane_id, type, number)
    {
      "task_id" => task_id, "batch_id" => batch_id, "lane_id" => lane_id,
      "root_id" => "root-#{task_id}",
      "work_item" => { "repo" => "shakacode/agent-workflows", "type" => type, "number" => number }
    }
  end

  def pilot_input
    metrics = {
      "elapsed_seconds" => 600,
      "human_coordination_seconds" => 60,
      "correction_turns" => 1,
      "first_pass_accepted" => true,
      "escaped_p0_p1_defects" => 0,
      "gate_compliance" => "preserved"
    }
    pairs = 10.times.map do |index|
      ordinal = index + 1
      ordinary_batch = "ordinary-batch-#{ordinal}"
      multi_batch = "multi-batch-#{ordinal}"
      ordinary_receipt = usage_receipt(
        batch_id: ordinary_batch, lane_id: "ordinary-lane-#{ordinal}", total_tokens: 70_000,
        coordinator_tokens: 10_000, lane_tokens: 60_000, total_turns: 7,
        coordinator_turns: 1, lane_turns: 6, credits: 7.0
      )
      multi_receipt = usage_receipt(
        batch_id: multi_batch, lane_id: "multi-lane-#{ordinal}", total_tokens: 100_000,
        coordinator_tokens: 20_000, lane_tokens: 80_000, total_turns: 10,
        coordinator_turns: 2, lane_turns: 8, credits: 10.0
      )
      ordinary_ref = install_usage_receipt(ordinary_receipt, label: "pilot-ordinary-#{ordinal}")
      multi_ref = install_usage_receipt(multi_receipt, label: "pilot-multi-#{ordinal}")
      {
        "pair_id" => "pair-#{ordinal}",
        "task_class" => "implementation-bounded",
        "context_topology" => "one-maker-one-checker",
        "ordinary" => {
          "arm_identity" => "ordinary",
          "task_identity" => "ordinary-task-#{ordinal}",
          "batch_identity" => ordinary_batch,
          "task_class" => "implementation-bounded",
          "context_topology" => "one-maker-one-checker",
          "usage_receipt" => ordinary_receipt, "usage_receipt_ref" => ordinary_ref,
          "usage_receipt_digest" => findings_digest(ordinary_receipt),
          "budget_result" => budget_reconciliation_result(
            receipt_digest: findings_digest(ordinary_receipt), batch_id: ordinary_batch, receipt_ref: ordinary_ref,
            tokens: 70_000, lane_id: "ordinary-lane-#{ordinal}", coordinator_tokens: 10_000,
            lane_tokens: 60_000
          ),
          "metrics" => metrics
        },
        "multi_target" => {
          "arm_identity" => "multi_target",
          "task_identity" => "multi-task-#{ordinal}",
          "batch_identity" => multi_batch,
          "task_class" => "implementation-bounded",
          "context_topology" => "one-maker-one-checker",
          "usage_receipt" => multi_receipt, "usage_receipt_ref" => multi_ref,
          "usage_receipt_digest" => findings_digest(multi_receipt),
          "budget_result" => budget_reconciliation_result(
            receipt_digest: findings_digest(multi_receipt), batch_id: multi_batch, receipt_ref: multi_ref,
            tokens: 100_000, lane_id: "multi-lane-#{ordinal}", coordinator_tokens: 20_000,
            lane_tokens: 80_000
          ),
          "metrics" => metrics
        }
      }
    end
    {
      "contract" => "canonical-task-matched-pilot",
      "version" => 1,
      "dependencies" => %w[replay_safe_usage_receipts execution_provenance evaluation_runner].map do |capability|
        {
          "contract" => "dependency-gate-evidence", "version" => 1, "capability" => capability,
          "actor" => "dependency-checker-1", "role" => "dependency_checker",
          "task_id" => "task-402", "repository" => "shakacode/agent-workflows", "target" => "issue:402",
          "action" => "evaluate_pilot", "scope" => "canonical task matched pilot", "status" => "satisfied",
          **evidence_times, "result_ref" => "https://example.test/results/#{capability}/dependency"
        }
      end,
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

  def child_receipt_input
    review_identity = {
      "batch_id" => "batch-402", "task_id" => "task-402",
      "plan_id" => "plan-402-v1", "spec_id" => "spec-402-v1",
      "diff_identity" => "sha256:#{'a' * 64}"
    }
    findings = []
    input = base_input.merge(
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
          "child_kind" => "checker",
          "actor" => "checker-402",
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
          "child_kind" => "checker",
          "actor" => "checker-402",
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
            **evidence_times,
            "findings_evidence_ref" => "https://example.test/reviews/results/checker-402-round-1",
            **review_identity,
            "schema_validation" => {
              "contract" => "review-findings-validation-result", "version" => 1,
              "validator" => "bin/validate-review-findings", "status" => "valid",
              "findings_digest" => findings_digest(findings),
              **evidence_times
            }
          }
        }],
        "states" => [{
          "child_kind" => "checker",
          "actor" => "checker-402",
          "child_id" => "checker-402", "lane_id" => "aw-i402",
          "repository" => "shakacode/agent-workflows", "target" => "issue:402",
          "role" => "checker", "scope" => "Review one diff.",
          "base_sha" => "7cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "head_sha" => "8cf266b0c1753797e56aefb1b152a16edd4b5a46",
          "review_round" => 1,
          **review_identity,
          "review_package_ref" => "https://example.test/reviews/packages/checker-402-round-1",
          "status" => "closed", "resumable" => false,
          "closure" => {
            "contract" => "canonical-task-child-closure-receipt", "version" => 1,
            "child_kind" => "checker", "child_id" => "checker-402", "lane_id" => "aw-i402",
            "task_id" => "task-402", "status" => "closed", "resumable" => false,
            "receipt_digest" => "PENDING"
          }
        }]
      }
    )
    input["children"]["states"].first["closure"]["receipt_digest"] =
      findings_digest(input["children"]["receipts"].first)
    input
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

  def install_stacked_base_budget_helper(root)
    helper = File.join(root, "batch-token-budget-a556")
    compressed = Base64.strict_decode64(File.read(STACKED_BASE_BUDGET_HELPER_FIXTURE).gsub(/\s+/, ""))
    source = Zlib.gunzip(compressed)
    source_digest = Digest::SHA256.hexdigest(source)
    raise "stacked base budget helper fixture digest mismatch" unless source_digest == STACKED_BASE_BUDGET_HELPER_SHA256

    File.binwrite(helper, source, mode: "wb", perm: 0o700)
    helper
  end

  def budget_command(action, plan, fields = {}, evaluated_at:)
    {
      "type" => "batch-token-budget-command",
      "version" => 1,
      "action" => action,
      "batch_id" => plan.fetch("batch_id"),
      "evaluated_at" => evaluated_at
    }.merge(fields)
  end

  def run_budget_helper(helper, state_path, anchor, command)
    stdout, stderr, status = Open3.capture3(
      helper,
      "--state", state_path,
      "--trusted-plan", anchor.fetch("path"),
      "--trusted-plan-id", anchor.fetch("id"),
      "--trusted-plan-digest", anchor.fetch("digest"),
      stdin_data: JSON.generate(command)
    )
    [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
  end

  def run_budget_state_snapshot(anchor)
    stdout, stderr, status = Open3.capture3(
      BUDGET_HELPER,
      "--state-snapshot",
      "--trusted-plan", anchor.fetch("path"),
      "--trusted-plan-id", anchor.fetch("id"),
      "--trusted-plan-digest", anchor.fetch("digest")
    )
    [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
  end

  def run_helper(input, trusted: true, trusted_bundle: nil)
    return run_helper_without_trusted(input) unless trusted

    bundle = trusted_bundle || trusted_bundle_for(input)
    Tempfile.create(["canonical-task-trusted", ".json"], TEST_TMP_ROOT) do |file|
      file.write(JSON.generate(bundle))
      file.flush
      Tempfile.create(["canonical-task-trust", ".yml"], TEST_TMP_ROOT) do |trust|
        trust.write("trusted_users:\n  - trusted-actor-1\n")
        trust.flush
        request = input.slice("contract", "version", "operation", "task").merge(
          "trusted_evidence_refs" => ["trusted-evidence-1"]
        )
        stdout, stderr, status = capture_helper(request, "trusted-evidence-1", file.path, trust.path)
        return [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
      end
    end
  end

  def run_request_with_bundle(request, bundle)
    Tempfile.create(["canonical-task-trusted", ".json"], TEST_TMP_ROOT) do |file|
      file.write(JSON.generate(bundle))
      file.flush
      Tempfile.create(["canonical-task-trust", ".yml"], TEST_TMP_ROOT) do |trust|
        trust.write("trusted_users:\n  - trusted-actor-1\n")
        trust.flush
        stdout, stderr, status = capture_helper(request, bundle.fetch("id"), file.path, trust.path)
        return [stdout.empty? ? {} : JSON.parse(stdout), stderr, status]
      end
    end
  end

  def capture_helper(request, id, evidence_path, trust_path, validator_path: REVIEW_VALIDATOR,
                     workflow_config_path: WORKFLOW_CONFIG, trusted_root: REPO_ROOT)
    Open3.capture3(
      "ruby", HELPER, "--trusted-evidence", evidence_path,
      "--trusted-evidence-id", id,
      "--trusted-evidence-root", trusted_root,
      "--trust-config", trust_path,
      "--repo-workflow-config", workflow_config_path,
      "--review-findings-validator", validator_path,
      stdin_data: JSON.generate(request)
    )
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
      "task_digest" => findings_digest(input.fetch("task")),
      "action" => input.fetch("operation"),
      "scope" => "canonical task control",
      "issued_at" => (Time.now.utc - 60).iso8601,
      "expires_at" => (Time.now.utc + 3000).iso8601,
      "heads" => input.dig("manifest", "current_heads") ||
        input.fetch("task").fetch("lanes").to_h do |lane|
          [lane.fetch("id"), "8cf266b0c1753797e56aefb1b152a16edd4b5a46"]
        end,
      "capabilities" => {
        "hierarchical_token_budgets" => "available",
        "replay_safe_usage_receipts" => "available"
      },
      "payload_digest" => findings_digest(payload),
      "payload" => payload
    }
  end

  def run_raw(json)
    Open3.capture3("ruby", HELPER, stdin_data: json)
  end
end
