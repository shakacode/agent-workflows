#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"

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

  def touch_map(pr, paths)
    {
      "pr" => pr,
      "repo" => "owner/repo",
      "source" => "verified",
      "changed_files" => paths.length,
      "paths" => paths,
      "renames" => []
    }
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
                backend: "generic")
    maps ||= lanes.each_with_index.to_h { |record, index| [record.fetch("id"), touch_map(index + 1, ["lib/#{record.fetch('id')}.rb"])] }
    gate_lanes ||= lanes.map { |record| gate_lane(record.fetch("id")) }
    plan_id = "trusted-plan-1"
    {
      "type" => "batch-plan-preflight",
      "version" => 1,
      "plan" => {
        "backend" => backend,
        "lanes" => lanes,
        "serialization_groups" => groups,
        "external_api_premises" => premises
      },
      "file_touch_map" => maps,
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

  def evaluate(input)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER, stdin_data: JSON.generate(input))
    [JSON.parse(stdout), stderr, status]
  end

  def evaluate_raw(input)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER, stdin_data: input)
    [JSON.parse(stdout), stderr, status]
  end

  def test_minimal_valid_plan_is_accepted
    result, stderr, status = evaluate(input_for)

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
    assert_equal ["unsupported-contract-version"], result.fetch("violations").map { |item| item.fetch("code") }
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
  end

  def test_shared_path_is_safe_in_a_max_one_serialization_group
    lanes = [lane("lane-a"), lane("lane-b")]
    lanes.each { |record| record["serialization_group"] = "changelog-writers" }
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    result, stderr, status = evaluate(input_for(lanes: lanes, maps: maps, groups: groups))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
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
    assert_equal ["malformed-json"], result.fetch("violations").map { |item| item.fetch("code") }
  end

  def test_historical_wave_a_replay_is_rejected_before_dispatch
    fixture = JSON.parse(File.read(REPLAY_FIXTURE, encoding: "UTF-8"))
    assert_equal "batch-plan-preflight-replay", fixture.fetch("type")
    assert_equal 1, fixture.fetch("version")
    assert_equal 5, fixture.dig("input", "plan", "lanes").length
    assert_equal "claude", fixture.dig("input", "plan", "backend")
    assert_empty fixture.dig("input", "stage_dependency_plan", "edges")
    assert fixture.dig("input", "plan", "lanes").all? { |record| record["purpose"] == "implementation" }
    assert fixture.dig("input", "plan", "lanes").all? { |record| record.dig("qa", "disposition") == "not-required" }
    assert fixture.dig("input", "file_touch_map").values.all? { |map| map.fetch("paths").include?("CHANGELOG.md") }
    assert_equal "UNKNOWN", fixture.dig("input", "plan", "external_api_premises", 0, "support")
    assert_equal 2, fixture.fetch("batch_evidence_files").length

    result, _stderr, status = evaluate(fixture.fetch("input"))
    dispatches = 0
    dispatches += result.dig("launch", "eligible_lane_ids").length if result.fetch("status") == "accepted"

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_equal 0, dispatches
    assert_includes result.fetch("violations").map { |item| item.fetch("code") }, "unsafe-concurrent-edit"
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "external-api-support-blocks-implementation"
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
    assert_equal ["invalid-envelope"], result.fetch("violations").map { |item| item.fetch("code") }
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
