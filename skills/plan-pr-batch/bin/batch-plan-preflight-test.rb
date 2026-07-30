#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "openssl"
require "rbconfig"
require "tmpdir"

HELPER = File.expand_path("batch-plan-preflight", __dir__)
REPLAY_FIXTURE = File.expand_path("../fixtures/ror-wave-a-plan-replay.json", __dir__)

class BatchPlanPreflightTest < Minitest::Test
  RISK_SURFACES = %w[
    ci_workflow
    developer_tooling
    security_boundary
    generated_output
    release_behavior
    broad_runtime
  ].freeze

  def lane(id = "lane-a", wave: "wave-a", purpose: "implementation", surfaces: [])
    {
      "id" => id,
      "wave" => wave,
      "purpose" => purpose,
      "changed_surfaces" => surfaces,
      "qa" => if surfaces.empty?
                { "disposition" => "not-required", "rationale" => "No risky changed surface." }
              else
                { "disposition" => "required" }
              end
    }
  end

  def touch_map(pr_number, paths)
    {
      "pr" => pr_number,
      "repo" => "owner/repo",
      "source" => "verified",
      "changed_files" => paths.length,
      "paths" => paths,
      "renames" => []
    }
  end

  def planned_path_evidence(paths, evidence_ref: "plan-state://batch-1/plan#lane-a",
                            source_kind: "durable-plan", renames: [])
    {
      "type" => "planned-path-evidence",
      "version" => 1,
      "source_kind" => source_kind,
      "evidence_ref" => evidence_ref,
      "paths" => paths,
      "renames" => renames
    }
  end

  def lane_lifecycle_receipt(lane_id: "lane-a", wave: "wave-a",
                             batch_plan_id: "batch-plan-1",
                             stage_dependency_plan_id: "trusted-plan-1",
                             completed_at: "2026-07-30T00:00:00Z",
                             recorded_at: "2026-07-30T00:00:01Z",
                             key_id: "test-workflow-control-key",
                             signing_key: workflow_control_signing_key)
    receipt = {
      "type" => "workflow-control-lane-lifecycle-receipt",
      "version" => 1,
      "producer" => "pr-batch-workflow-control",
      "receipt_ref" => "workflow-control-state://#{batch_plan_id}/stage-dependency-plans/" \
                       "#{stage_dependency_plan_id}/waves/#{wave}/lanes/#{lane_id}/completed",
      "batch_plan_id" => batch_plan_id,
      "stage_dependency_plan_id" => stage_dependency_plan_id,
      "lane_id" => lane_id,
      "wave" => wave,
      "state" => "completed",
      "completed_at" => completed_at,
      "recorded_at" => recorded_at,
      "key_id" => key_id
    }
    payload = JSON.generate(canonicalize(receipt))
    signature = signing_key.sign(OpenSSL::Digest.new("SHA256"), payload)
    receipt.merge("signature" => Base64.strict_encode64(signature))
  end

  def workflow_control_signing_key
    @workflow_control_signing_key ||= OpenSSL::PKey::RSA.generate(1024)
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) do |key, canonical|
        canonical[key] = canonicalize(value[key])
      end
    when Array
      value.map { |entry| canonicalize(entry) }
    else
      value
    end
  end

  def installed_workflow_control_helper(key_id: "test-workflow-control-key",
                                        key: workflow_control_signing_key,
                                        config_mode: 0o600, agents_mode: 0o700,
                                        root_mode: 0o700, config_symlink: false,
                                        agents_symlink: false)
    root = Dir.mktmpdir("workflow-control-trust-install")
    File.chmod(root_mode, root)
    (@workflow_control_install_roots ||= []) << root
    helper = File.join(root, "skills/plan-pr-batch/bin/batch-plan-preflight")
    agents_dir = File.join(root, ".agents")
    config_path = File.join(agents_dir, "workflow-control-lifecycle-trust.json")
    FileUtils.mkdir_p(File.dirname(helper))
    FileUtils.cp(HELPER, helper)
    File.chmod(0o755, helper)
    if agents_symlink
      actual_agents_dir = File.join(root, "caller-substitutable-agents")
      FileUtils.mkdir_p(actual_agents_dir)
      File.chmod(agents_mode, actual_agents_dir)
      File.symlink(actual_agents_dir, agents_dir)
    else
      FileUtils.mkdir_p(agents_dir)
      File.chmod(agents_mode, agents_dir)
    end
    trust_record = {
      "type" => "agent-workflow-control-lifecycle-trust-anchor",
      "version" => 1,
      "agent_workflow_control_lifecycle_trusted_key_id" => key_id,
      "agent_workflow_control_lifecycle_trusted_public_key_pem" => key.public_to_pem
    }
    if config_symlink
      target = File.join(root, "caller-substitutable-workflow-control-trust.json")
      File.write(target, JSON.generate(trust_record))
      File.symlink(target, config_path)
    else
      File.write(config_path, JSON.generate(trust_record))
      File.chmod(config_mode, config_path)
    end
    [helper, config_path]
  end

  def workflow_control_helper
    @workflow_control_helper ||= installed_workflow_control_helper.first
  end

  def teardown
    Array(@workflow_control_install_roots).each do |root|
      FileUtils.remove_entry(root) if File.exist?(root)
    end
  end

  def gate_lane(id, patch_edit: true)
    permissions = {
      "read_only_discovery" => true,
      "branch_worktree_create" => patch_edit,
      "patch_edit" => patch_edit,
      "commit" => patch_edit,
      "push" => patch_edit,
      "pr_open" => patch_edit,
      "final_validation" => patch_edit,
      "merge" => patch_edit
    }
    {
      "id" => id,
      "permissions" => permissions,
      "hosted_ci" => patch_edit ? "eligible-via-repo-seam" : "not-yet-eligible",
      "blockers" => [],
      "base_refresh" => []
    }
  end

  def input_for(lanes: [lane], maps: nil, edges: [], groups: [], premises: [], gate_lanes: nil,
                backend: "generic", active_wave: "wave-a", batch_plan_id: "batch-plan-1",
                lifecycle_receipts: [])
    maps ||= lanes.each_with_index.to_h { |record, index| [record.fetch("id"), touch_map(index + 1, ["lib/#{record.fetch('id')}.rb"])] }
    gate_lanes ||= lanes.map { |record| gate_lane(record.fetch("id")) }
    plan_id = "trusted-plan-1"
    {
      "type" => "batch-plan-preflight",
      "version" => 1,
      "plan" => {
        "id" => batch_plan_id,
        "backend" => backend,
        "active_wave" => active_wave,
        "lanes" => lanes,
        "serialization_groups" => groups,
        "external_api_premises" => premises
      },
      "file_touch_map" => maps,
      "lane_lifecycle_receipts" => lifecycle_receipts,
      "stage_dependency_plan" => {
        "contract" => "stage-dependency-plan",
        "version" => 1,
        "id" => plan_id,
        "edges" => edges
      },
      "stage_dependency_gate" => {
        "contract" => "stage-dependency-gate",
        "version" => 1,
        "status" => "eligible",
        "trusted_plan_id" => plan_id,
        "lanes" => gate_lanes,
        "checker_verdict" => { "status" => "eligible", "blockers" => [] },
        "critical_path" => {
          "lane_ids" => lanes.map { |record| record.fetch("id") },
          "edge_count" => edges.length,
          "tie_breaker" => "maximum-dependency-hops-then-lexicographic-lane-id-sequence",
          "assignments" => []
        },
        "downstream_requirements" => {
          "final_combined_tip_validation" => "required-via-repo-seam",
          "preserved_gates" => %w[exact_head_ci independent_review unresolved_threads merge_readiness]
        }
      }
    }
  end

  def external_premise(lane_ids:, support: "supported")
    {
      "id" => "post-tool-use-hook-schema",
      "lane_ids" => lane_ids,
      "support" => support,
      "primary_sources" => ["https://docs.anthropic.com/en/docs/claude-code/hooks"],
      "retrieved_date" => "2026-07-29",
      "version_chronology" => [{
        "version" => "Claude Code 2.1",
        "applicability" => "applicable",
        "source_url" => "https://docs.anthropic.com/en/docs/claude-code/hooks",
        "release_date" => "UNKNOWN"
      }]
    }
  end

  def evaluate(input, helper: HELPER, env: {})
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, helper, stdin_data: JSON.generate(input))
    [JSON.parse(stdout), stderr, status]
  end

  def evaluate_raw(input)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER, stdin_data: input)
    [JSON.parse(stdout), stderr, status]
  end

  def test_unchanged_verified_pr_file_touch_map_result_is_accepted
    input = input_for
    assert_equal %w[changed_files paths pr renames repo source],
                 input.dig("file_touch_map", "lane-a").keys.sort
    result, stderr, status = evaluate(input)

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    assert_empty result.fetch("violations")
  end

  def test_unsupported_contract_fails_closed_with_structured_violation
    input = input_for.merge("version" => 2)
    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_equal(["unsupported-contract-version"], result.fetch("violations").map { |item| item.fetch("code") })
    assert_equal "$", result.dig("violations", 0, "path")
  end

  def test_unknown_file_touch_map_result_fails_closed
    input = input_for
    input.fetch("file_touch_map").fetch("lane-a")["source"] = "UNKNOWN"
    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("violations").map { |item| item.fetch("code") }, "file-touch-map-unverified"
    assert_equal [], result.dig("launch", "eligible_lane_ids")
  end

  def test_stage_gate_must_be_a_completed_result_for_the_trusted_plan
    input = input_for
    input.fetch("stage_dependency_gate")["trusted_plan_id"] = "different-plan"
    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "stage-dependency-gate-plan-mismatch"
  end

  def test_batch_and_stage_dependency_plan_ids_must_be_known
    unknown_stage = input_for
    unknown_stage.fetch("stage_dependency_plan")["id"] = "UNKNOWN"
    unknown_stage.fetch("stage_dependency_gate")["trusted_plan_id"] = "UNKNOWN"
    result, _stderr, status = evaluate(unknown_stage)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "stage-dependency-plan-invalid"

    unknown_batch = input_for(batch_plan_id: "UNKNOWN")
    result, _stderr, status = evaluate(unknown_batch)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "batch-plan-id-invalid"
  end

  def test_each_risky_changed_surface_requires_qa
    RISK_SURFACES.each do |surface|
      risky_lane = lane(surfaces: [surface])
      risky_lane["qa"] = { "disposition" => "not-required", "rationale" => "Waived." }
      result, _stderr, status = evaluate(input_for(lanes: [risky_lane]))

      refute status.success?, surface
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "qa-required-for-risky-surface", surface
    end
  end

  def test_no_qa_disposition_requires_no_risky_surface_and_nonempty_rationale
    no_qa_lane = lane
    no_qa_lane["qa"] = { "disposition" => "not-required", "rationale" => "  " }
    result, _stderr, status = evaluate(input_for(lanes: [no_qa_lane]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "qa-not-required-rationale-missing"
  end

  def test_same_wave_shared_path_without_edit_serialization_is_rejected
    lanes = [lane("lane-a"), lane("lane-b")]
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps))

    refute status.success?
    collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
    assert_equal %w[lane-a lane-b], collision.fetch("lane_ids")
    assert_includes collision.fetch("message"), "CHANGELOG.md"
  end

  def test_shared_path_is_safe_in_different_waves
    lanes = [lane("lane-a", wave: "wave-a"), lane("lane-b", wave: "wave-b")]
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    result, stderr, status = evaluate(input_for(lanes: lanes, maps: maps))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["lane-b"], result.dig("launch", "held_lane_ids")
  end

  def test_shared_path_is_safe_in_a_max_one_serialization_group
    lanes = [lane("lane-b"), lane("lane-a")]
    lanes.each { |record| record["serialization_group"] = "changelog-writers" }
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    result, stderr, status = evaluate(input_for(lanes: lanes, maps: maps, groups: groups))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["lane-b"], result.dig("launch", "held_lane_ids")
  end

  def test_max_one_serialization_advances_after_trusted_lane_completion
    lanes = [lane("lane-b"), lane("lane-a")]
    lanes.each { |record| record["serialization_group"] = "changelog-writers" }
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]

    first_result, first_stderr, first_status = evaluate(
      input_for(lanes: lanes, maps: maps, groups: groups)
    )
    assert first_status.success?, first_stderr
    assert_equal ["lane-a"], first_result.dig("launch", "eligible_lane_ids")

    receipt = lane_lifecycle_receipt(lane_id: "lane-a")
    second_result, second_stderr, second_status = evaluate(
      input_for(lanes: lanes, maps: maps, groups: groups, lifecycle_receipts: [receipt]),
      helper: workflow_control_helper
    )
    assert second_status.success?, second_stderr
    assert_equal ["lane-b"], second_result.dig("launch", "eligible_lane_ids")
    assert_equal [], second_result.dig("launch", "held_lane_ids")
    assert_equal ["lane-a"], second_result.dig("launch", "completed_lane_ids")
  end

  def test_inline_lane_completion_claim_is_rejected
    input = input_for
    planned_lane = input.dig("plan", "lanes", 0)
    planned_lane["completed"] = true
    planned_lane["completion_source_kind"] = "durable-coordinator"

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "inline-lane-lifecycle-forbidden"
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_untrusted_unknown_or_malformed_lifecycle_receipts_are_rejected
    valid_receipt = lane_lifecycle_receipt
    cases = {
      "unidentified producer" => lambda { |receipt|
        receipt["producer"] = "caller-authored"
      },
      "unknown state" => lambda { |receipt|
        receipt["state"] = "UNKNOWN"
      },
      "missing durable reference" => lambda { |receipt|
        receipt.delete("receipt_ref")
      },
      "foreign batch" => lambda { |receipt|
        receipt["batch_plan_id"] = "other-batch"
      },
      "foreign dependency plan" => lambda { |receipt|
        receipt["stage_dependency_plan_id"] = "other-plan"
      },
      "unknown lane" => lambda { |receipt|
        receipt["lane_id"] = "lane-z"
      },
      "wrong wave" => lambda { |receipt|
        receipt["wave"] = "wave-z"
      },
      "impossible chronology" => lambda { |receipt|
        receipt["completed_at"] = "2026-07-30T00:00:02Z"
      },
      "noncanonical reference" => lambda { |receipt|
        receipt["receipt_ref"] = "https://example.test/completed"
      },
      "caller source label" => lambda { |receipt|
        receipt["source_kind"] = "durable-coordinator"
      }
    }

    cases.each do |label, mutation|
      receipt = JSON.parse(JSON.generate(valid_receipt))
      mutation.call(receipt)
      result, _stderr, status = evaluate(
        input_for(lifecycle_receipts: [receipt]),
        helper: workflow_control_helper
      )

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-receipt-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
      assert_empty result.dig("launch", "completed_lane_ids"), label
    end
  end

  def test_future_dated_lifecycle_receipt_is_rejected
    receipt = lane_lifecycle_receipt(
      completed_at: "2099-01-01T00:00:00Z",
      recorded_at: "2099-01-01T00:00:01Z"
    )

    result, _stderr, status = evaluate(
      input_for(lifecycle_receipts: [receipt]),
      helper: workflow_control_helper
    )

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-receipt-invalid"
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_caller_forged_producer_and_uri_cannot_advance_with_caller_trust
    attacker_key = OpenSSL::PKey::RSA.generate(1024)
    forged_receipt = lane_lifecycle_receipt(signing_key: attacker_key)
    caller_trust = {
      "AGENT_WORKFLOW_CONTROL_LIFECYCLE_TRUSTED_KEY_ID" => "test-workflow-control-key",
      "AGENT_WORKFLOW_CONTROL_LIFECYCLE_TRUSTED_PUBLIC_KEY_PEM" => attacker_key.public_to_pem
    }
    assert_equal "pr-batch-workflow-control", forged_receipt.fetch("producer")
    assert_equal(
      "workflow-control-state://batch-plan-1/stage-dependency-plans/" \
      "trusted-plan-1/waves/wave-a/lanes/lane-a/completed",
      forged_receipt.fetch("receipt_ref")
    )

    result, _stderr, status = evaluate(
      input_for(lifecycle_receipts: [forged_receipt]),
      helper: workflow_control_helper,
      env: caller_trust
    )

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-receipt-invalid"
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_lifecycle_signature_covers_timestamp_and_requires_known_key_identity
    tampered = lane_lifecycle_receipt
    tampered["recorded_at"] = "2026-07-30T00:00:02Z"
    result, _stderr, status = evaluate(
      input_for(lifecycle_receipts: [tampered]),
      helper: workflow_control_helper
    )

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-receipt-invalid"

    unknown_key = lane_lifecycle_receipt(key_id: "UNKNOWN")
    result, _stderr, status = evaluate(
      input_for(lifecycle_receipts: [unknown_key]),
      helper: workflow_control_helper
    )

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-receipt-invalid"
  end

  def test_lifecycle_receipt_rejects_missing_or_unsafe_fixed_trust
    receipt = lane_lifecycle_receipt
    input = input_for(lifecycle_receipts: [receipt])
    missing_helper, missing_config = installed_workflow_control_helper
    File.unlink(missing_config)
    wrong_namespace_helper, wrong_namespace_config = installed_workflow_control_helper
    wrong_namespace_record = JSON.parse(File.read(wrong_namespace_config, encoding: "UTF-8"))
    wrong_namespace_record["type"] = "agent-workflow-dispatcher-trust-anchor"
    File.write(wrong_namespace_config, JSON.generate(wrong_namespace_record))
    File.chmod(0o600, wrong_namespace_config)
    unsafe_helpers = {
      "missing trust config" => missing_helper,
      "wrong trust namespace" => wrong_namespace_helper,
      "symlinked trust config" => installed_workflow_control_helper(config_symlink: true).first,
      "symlinked trust directory" => installed_workflow_control_helper(agents_symlink: true).first,
      "writable trust config" => installed_workflow_control_helper(config_mode: 0o666).first,
      "writable trust directory" => installed_workflow_control_helper(agents_mode: 0o777).first,
      "writable installation root" => installed_workflow_control_helper(root_mode: 0o777).first
    }

    unsafe_helpers.each do |label, helper|
      result, _stderr, status = evaluate(input, helper: helper)

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-receipt-invalid", label
      assert_empty result.dig("launch", "completed_lane_ids"), label
    end
  end

  def test_completed_lanes_never_relaunch_and_exhausted_group_has_none_eligible
    lanes = [lane("lane-b"), lane("lane-a")]
    lanes.each { |record| record["serialization_group"] = "changelog-writers" }
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    receipts = [
      lane_lifecycle_receipt(lane_id: "lane-a"),
      lane_lifecycle_receipt(lane_id: "lane-b")
    ]

    result, stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, groups: groups, lifecycle_receipts: receipts),
      helper: workflow_control_helper
    )

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_empty result.dig("launch", "held_lane_ids")
    assert_equal %w[lane-a lane-b], result.dig("launch", "completed_lane_ids")
  end

  def test_lifecycle_receipt_collection_is_required_and_rejects_duplicate_lane_receipts
    missing = input_for
    missing.delete("lane_lifecycle_receipts")
    result, _stderr, status = evaluate(missing)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-receipts-array-required"

    receipt = lane_lifecycle_receipt
    duplicate = input_for(lifecycle_receipts: [receipt, receipt.dup])
    result, _stderr, status = evaluate(duplicate, helper: workflow_control_helper)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-receipt-duplicate"
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_typed_edit_edge_serializes_shared_path_and_gate_holds_consumer
    lanes = [lane("foundation"), lane("consumer")]
    maps = {
      "foundation" => touch_map(1, ["CHANGELOG.md"]),
      "consumer" => touch_map(2, ["CHANGELOG.md"])
    }
    edges = [{ "id" => "foundation-before-consumer", "from" => "foundation", "to" => "consumer", "type" => "edit" }]
    gate_lanes = [gate_lane("foundation"), gate_lane("consumer", patch_edit: false)]
    input = input_for(lanes: lanes, maps: maps, edges: edges, gate_lanes: gate_lanes)
    input.fetch("stage_dependency_gate")["status"] = "gated"
    result, stderr, status = evaluate(input)

    assert status.success?, stderr
    assert_equal ["foundation"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["consumer"], result.dig("launch", "held_lane_ids")
  end

  def test_backend_lane_and_risky_caps_accept_boundary_and_reject_one_over
    caps = {
      "codex" => { lanes: 10, risky: 8 },
      "claude" => { lanes: 5, risky: 3 },
      "generic" => { lanes: 5, risky: 3 }
    }
    caps.each do |backend, cap|
      boundary = Array.new(cap.fetch(:lanes)) do |index|
        surfaces = index < cap.fetch(:risky) ? ["security_boundary"] : []
        lane("lane-#{index}", surfaces: surfaces)
      end
      _result, stderr, status = evaluate(input_for(lanes: boundary, backend: backend))
      assert status.success?, "#{backend} boundary: #{stderr}"

      one_too_many = Array.new(cap.fetch(:lanes) + 1) { |index| lane("lane-#{index}") }
      result, _stderr, status = evaluate(input_for(lanes: one_too_many, backend: backend))
      refute status.success?, "#{backend} lane cap"
      assert_includes result.fetch("violations").map { |item| item.fetch("code") }, "backend-lane-cap-exceeded"

      too_risky = Array.new(cap.fetch(:risky) + 1) do |index|
        lane("risky-#{index}", surfaces: ["developer_tooling"])
      end
      result, _stderr, status = evaluate(input_for(lanes: too_risky, backend: backend))
      refute status.success?, "#{backend} risky cap"
      assert_includes result.fetch("violations").map { |item| item.fetch("code") }, "backend-risky-cap-exceeded"
    end
  end

  def test_safe_changed_path_collisions_still_count_toward_risky_cap
    lanes = Array.new(4) { |index| lane("lane-#{index}", wave: "wave-#{index}") }
    maps = lanes.each_with_index.to_h do |record, index|
      [record.fetch("id"), touch_map(index + 1, ["CHANGELOG.md"])]
    end
    result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps, backend: "generic"))

    refute status.success?
    cap = result.fetch("violations").find { |item| item.fetch("code") == "backend-risky-cap-exceeded" }
    assert_equal lanes.map { |record| record.fetch("id") }, cap.fetch("lane_ids")
  end

  def test_unknown_external_api_support_blocks_implementation_but_allows_investigation
    implementation = lane("implementation")
    premise = external_premise(lane_ids: ["implementation"], support: "UNKNOWN")
    result, _stderr, status = evaluate(input_for(lanes: [implementation], premises: [premise]))
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "external-api-support-blocks-implementation"

    investigation = lane("investigation", purpose: "investigation")
    premise = external_premise(lane_ids: ["investigation"], support: "UNKNOWN")
    result, stderr, status = evaluate(input_for(lanes: [investigation], premises: [premise]))
    assert status.success?, stderr
    assert_equal ["investigation"], result.dig("launch", "eligible_lane_ids")
  end

  def test_external_api_premise_requires_pinned_support_and_primary_source_chronology
    premise = external_premise(lane_ids: ["lane-a"])
    premise["support"] = "maybe"
    premise["primary_sources"] = ["not-a-url"]
    premise["retrieved_date"] = "2026-02-30"
    premise["version_chronology"] = [{
      "version" => "",
      "applicability" => "UNKNOWN",
      "source_url" => "ftp://example.test/schema",
      "release_date" => "tomorrow"
    }]
    result, _stderr, status = evaluate(input_for(premises: [premise]))

    refute status.success?
    codes = result.fetch("violations").map { |item| item.fetch("code") }
    %w[
      external-api-support-invalid
      external-api-primary-sources-invalid
      external-api-retrieved-date-invalid
      external-api-chronology-row-invalid
    ].each { |code| assert_includes codes, code }
  end

  def test_literal_unknown_is_rejected_in_nested_plan_decisions
    unknown_lane = lane
    unknown_lane["purpose"] = "UNKNOWN"
    unknown_lane["qa"]["rationale"] = { "decision" => "UNKNOWN" }
    result, _stderr, status = evaluate(input_for(lanes: [unknown_lane]))

    refute status.success?
    unknown_paths = result.fetch("violations")
                          .select { |item| item.fetch("code") == "unknown-decision" }
                          .map { |item| item.fetch("path") }
    assert_includes unknown_paths, "$.plan.lanes[0].purpose"
    assert_includes unknown_paths, "$.plan.lanes[0].qa.rationale.decision"
  end

  def test_malformed_json_returns_a_structured_rejection
    result, _stderr, status = evaluate_raw("{not-json")

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_equal(["malformed-json"], result.fetch("violations").map { |item| item.fetch("code") })
  end

  def test_historical_wave_a_replay_is_rejected_before_dispatch
    fixture_json = File.read(REPLAY_FIXTURE, encoding: "UTF-8")
    fixture = JSON.parse(fixture_json)
    assert_equal "batch-plan-preflight-replay", fixture.fetch("type")
    assert_equal 1, fixture.fetch("version")
    assert_equal "batch://ror-a-17-1-wave-a-20260729", fixture.fetch("batch_ref")
    assert(fixture.fetch("plan_state_refs").all? { |ref| ref.start_with?("plan-state://") })
    assert(fixture.fetch("comment_refs").all? { |ref| ref.start_with?("https://github.com/") })
    refute_includes fixture_json, "/Users/justin"
    assert_equal 5, fixture.dig("input", "plan", "lanes").length
    assert_equal "batch-ror-a-17-1-wave-a-20260729", fixture.dig("input", "plan", "id")
    assert_equal "claude", fixture.dig("input", "plan", "backend")
    assert_equal "wave-a", fixture.dig("input", "plan", "active_wave")
    assert_empty fixture.dig("input", "lane_lifecycle_receipts")
    assert_empty fixture.dig("input", "stage_dependency_plan", "edges")
    assert(fixture.dig("input", "plan", "lanes").all? { |record| record["purpose"] == "implementation" })
    assert(fixture.dig("input", "plan", "lanes").all? { |record| record.dig("qa", "disposition") == "not-required" })
    path_evidence = fixture.dig("input", "file_touch_map").values
    assert(path_evidence.all? { |record| record["type"] == "planned-path-evidence" })
    assert(path_evidence.all? { |record| record["source_kind"] == "durable-plan" })
    assert(path_evidence.none? { |record| record.key?("pr") || record.key?("source") })
    assert(path_evidence.all? { |record| record.fetch("paths").include?("CHANGELOG.md") })
    assert_equal "UNKNOWN", fixture.dig("input", "plan", "external_api_premises", 0, "support")

    result, _stderr, status = evaluate(fixture.fetch("input"))
    dispatches = 0
    dispatches += result.dig("launch", "eligible_lane_ids").length if result.fetch("status") == "accepted"

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_equal 0, dispatches
    assert_equal(
      {
        "qa-required-for-risky-surface" => 5,
        "unsafe-concurrent-edit" => 10,
        "backend-risky-cap-exceeded" => 1,
        "external-api-support-blocks-implementation" => 1
      },
      result.fetch("violations").map { |item| item.fetch("code") }.tally
    )
  end

  def test_dependency_edge_type_is_pinned
    lanes = [lane("lane-a"), lane("lane-b")]
    edges = [{ "id" => "unknown-edge", "from" => "lane-a", "to" => "lane-b", "type" => "UNKNOWN" }]
    result, _stderr, status = evaluate(input_for(lanes: lanes, edges: edges))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "stage-dependency-plan-edge-invalid"
  end

  def test_lane_identity_wave_and_purpose_are_required_and_pinned
    invalid_lane = lane
    invalid_lane["wave"] = ""
    invalid_lane["purpose"] = "delivery"
    result, _stderr, status = evaluate(input_for(lanes: [invalid_lane]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") }, "lane-record-invalid"
  end

  def test_active_wave_is_required_known_and_matches_a_planned_wave
    cases = {
      "missing" => :delete,
      "empty" => "",
      "unknown" => "UNKNOWN",
      "not-planned" => "wave-z"
    }
    cases.each do |label, active_wave|
      input = input_for
      if active_wave == :delete
        input.fetch("plan").delete("active_wave")
      else
        input.fetch("plan")["active_wave"] = active_wave
      end
      result, _stderr, status = evaluate(input)

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "active-wave-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_typed_planned_path_evidence_is_accepted
    planned = planned_path_evidence(
      %w[lib/new.rb lib/old.rb],
      renames: [{ "old" => "lib/old.rb", "new" => "lib/new.rb" }]
    )
    result, stderr, status = evaluate(input_for(maps: { "lane-a" => planned }))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
  end

  def test_planned_path_evidence_cannot_masquerade_or_omit_provenance
    masquerading = planned_path_evidence(["lib/a.rb"]).merge(
      "source" => "verified",
      "pr" => 123
    )
    incomplete = planned_path_evidence(["lib/a.rb"]).tap { |record| record.delete("evidence_ref") }
    mismatched = planned_path_evidence(
      ["lib/a.rb"],
      source_kind: "issue",
      evidence_ref: "plan-state://batch-1/plan#lane-a"
    )

    {
      "masquerading" => masquerading,
      "incomplete" => incomplete,
      "mismatched" => mismatched
    }.each do |label, record|
      result, _stderr, status = evaluate(input_for(maps: { "lane-a" => record }))

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "planned-path-evidence-invalid", label
    end
  end

  def test_file_touch_map_preserves_the_exact_existing_result_shape
    input = input_for
    input.fetch("file_touch_map").fetch("lane-a").delete("paths")
    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "file-touch-map-shape-invalid"
  end

  def test_validation_open_and_merge_order_edges_do_not_make_concurrent_edits_safe
    %w[validation_open merge_order].each do |edge_type|
      lanes = [lane("lane-a"), lane("lane-b")]
      maps = {
        "lane-a" => touch_map(1, ["CHANGELOG.md"]),
        "lane-b" => touch_map(2, ["CHANGELOG.md"])
      }
      edges = [{ "id" => "#{edge_type}-edge", "from" => "lane-a", "to" => "lane-b", "type" => edge_type }]
      result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps, edges: edges))

      refute status.success?, edge_type
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "unsafe-concurrent-edit", edge_type
    end
  end

  def test_incomplete_v1_envelope_fails_closed_without_a_stack_trace
    result, stderr, status = evaluate_raw(JSON.generate(
                                            "type" => "batch-plan-preflight",
                                            "version" => 1
                                          ))

    refute status.success?
    assert_empty stderr
    assert_equal(["invalid-envelope"], result.fetch("violations").map { |item| item.fetch("code") })
  end

  def test_completed_stage_gate_preserves_boolean_permission_decisions
    input = input_for
    input.dig("stage_dependency_gate", "lanes", 0, "permissions").delete("patch_edit")
    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "stage-dependency-gate-lane-invalid"
  end
end
