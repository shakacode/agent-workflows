#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "openssl"
require "rbconfig"
require "tempfile"

HELPER = File.expand_path("batch-plan-preflight", __dir__)
STAGE_DEPENDENCY_GATE = File.expand_path("../../pr-batch/bin/stage-dependency-gate", __dir__)
REPLAY_FIXTURE = File.expand_path("../fixtures/ror-wave-a-plan-replay.json", __dir__)
UNSIGNED_LIFECYCLE_FIXTURE = File.expand_path("../fixtures/unsigned-lifecycle-smoke.json", __dir__)

class BatchPlanPreflightTest < Minitest::Test
  TEST_VERIFIER_KEY = OpenSSL::PKey::RSA.generate(2048)
  RISK_SURFACES = %w[
    ci_workflow
    developer_tooling
    security_boundary
    generated_output
    release_behavior
    broad_runtime
  ].freeze

  def test_clean_install_fixture_accepts_without_trust_material
    result, stderr, status = evaluate(JSON.parse(File.read(UNSIGNED_LIFECYCLE_FIXTURE)))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["install-smoke"], result.dig("launch", "eligible_lane_ids")
  end

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

  def lane_lifecycle_state(lane_id: "lane-a", wave: "wave-a", state: "completed",
                           batch_plan_id: "batch-plan-1",
                           stage_dependency_plan_id: "trusted-plan-1")
    {
      "type" => "lane-lifecycle-state",
      "version" => 1,
      "batch_plan_id" => batch_plan_id,
      "stage_dependency_plan_id" => stage_dependency_plan_id,
      "lane_id" => lane_id,
      "wave" => wave,
      "state" => state,
      "state_ref" => "coordination-state://#{batch_plan_id}/lanes/#{lane_id}"
    }
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

  def stage_dependency_plan_binding(plan)
    immutable_edges = plan.fetch("edges").map do |edge|
      edge.slice("id", "from", "to", "type")
    end
    immutable_edges.sort_by! { |edge| edge.values_at("id", "from", "to", "type") }
    payload = {
      "contract" => plan.fetch("contract"),
      "id" => plan.fetch("id"),
      "edges" => immutable_edges
    }

    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))}"
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
                lifecycle_states: [])
    maps ||= lanes.each_with_index.to_h { |record, index| [record.fetch("id"), touch_map(index + 1, ["lib/#{record.fetch('id')}.rb"])] }
    gate_lanes ||= lanes.map { |record| gate_lane(record.fetch("id")) }
    plan_id = "trusted-plan-1"
    input = {
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
      "lane_lifecycle_states" => lifecycle_states,
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
    input.fetch("stage_dependency_gate")["trusted_plan_binding"] =
      stage_dependency_plan_binding(input.fetch("stage_dependency_plan"))
    input
  end

  def token_budget(lane_limits: { "lane-a" => 600 })
    {
      "type" => "batch-token-budget",
      "version" => 1,
      "batch_id" => "batch-plan-1",
      "state_path" => "/var/tmp/batch-plan-1-token-budget.json",
      "scopes" => {
        "aggregate" => { "limit_tokens" => 1_000 },
        "coordinator" => { "limit_tokens" => 300 },
        "lanes" => lane_limits.transform_values { |limit| { "limit_tokens" => limit } }
      },
      "thresholds" => {
        "warning_percent" => 50,
        "approval_percent" => 80,
        "hard_percent" => 100
      },
      "telemetry" => { "max_age_seconds" => 900 },
      "delegation" => { "approval_threshold_tokens" => 250 },
      "trusted_verifiers" => [{
        "id" => "coordinator-399",
        "algorithm" => "rsa-pss-sha256",
        "public_key_pem" => TEST_VERIFIER_KEY.public_key.to_pem
      }]
    }
  end

  def persist_token_budget(budget)
    artifact = Tempfile.new(["batch-token-budget-plan", ".json"])
    artifact.write(JSON.generate(canonicalize(budget)))
    artifact.flush
    (@trusted_plan_artifacts ||= []) << artifact
    artifact.path
  end

  def teardown
    Array(@trusted_plan_artifacts).each(&:close!)
  end

  def token_budget_anchor(budget)
    {
      "trusted_plan_path" => persist_token_budget(budget),
      "trusted_plan_id" => budget.fetch("batch_id"),
      "trusted_plan_digest" => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(budget)))}"
    }
  end

  def enable_token_budget(input, candidate = token_budget)
    input.fetch("plan")["token_budget"] = candidate
    input.fetch("plan")["token_budget_anchor"] = token_budget_anchor(candidate)
  end

  def test_ordinary_durable_lane_state_advances_serialized_work_without_trust_material
    lanes = [lane("lane-b"), lane("lane-a")]
    lanes.each { |record| record["serialization_group"] = "changelog-writers" }
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    input = input_for(
      lanes: lanes,
      maps: maps,
      groups: groups,
      lifecycle_states: [lane_lifecycle_state]
    )

    result, stderr, status = evaluate(input)

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "completed_lane_ids")
    assert_equal ["lane-b"], result.dig("launch", "eligible_lane_ids")
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

  def evaluate_stage_dependency_gate(plan, lanes:, edges:)
    Tempfile.create(["stage-dependency-plan", ".json"]) do |plan_file|
      plan_file.write(JSON.generate(plan))
      plan_file.flush
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        STAGE_DEPENDENCY_GATE,
        "--trusted-plan",
        plan_file.path,
        "--trusted-plan-id",
        plan.fetch("id"),
        stdin_data: JSON.generate(
          "contract" => "stage-dependency-gate",
          "version" => 1,
          "lanes" => lanes,
          "edges" => edges
        )
      )
      assert status.success?, stderr
      return JSON.parse(stdout)
    end
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

  def test_complete_opt_in_hierarchical_token_budget_is_accepted
    input = input_for
    enable_token_budget(input)

    result, stderr, status = evaluate(input)

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_empty result.fetch("violations")
  end

  def test_opt_in_token_budget_requires_an_exact_external_anchor_binding
    missing = input_for
    missing.fetch("plan")["token_budget"] = token_budget

    result, _stderr, status = evaluate(missing)

    refute status.success?
    assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-anchor-invalid"

    orphan = input_for
    orphan.fetch("plan")["token_budget_anchor"] = token_budget_anchor(token_budget)
    orphan_result, _orphan_stderr, orphan_status = evaluate(orphan)
    refute orphan_status.success?
    assert_includes orphan_result.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-anchor-without-budget"

    mismatches = {
      "unknown-path" => proc { |anchor| anchor["trusted_plan_path"] = "UNKNOWN" },
      "relative-path" => proc { |anchor| anchor["trusted_plan_path"] = "tmp/budget-plan.json" },
      "wrong-id" => proc { |anchor| anchor["trusted_plan_id"] = "different-batch" },
      "wrong-digest" => proc { |anchor| anchor["trusted_plan_digest"] = "sha256:#{'0' * 64}" }
    }
    mismatches.each do |name, mutate|
      input = input_for
      enable_token_budget(input)
      mutate.call(input.dig("plan", "token_budget_anchor"))

      result, _stderr, status = evaluate(input)

      refute status.success?, name
      assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                      "token-budget-anchor-invalid", name
    end
  end

  def test_token_budget_requires_a_readable_persisted_trusted_plan
    Dir.mktmpdir("batch-plan-missing-trusted-budget") do |directory|
      input = input_for
      candidate = token_budget
      input.fetch("plan")["token_budget"] = candidate
      input.fetch("plan")["token_budget_anchor"] = token_budget_anchor(candidate).merge(
        "trusted_plan_path" => File.join(directory, "missing.json")
      )

      result, _stderr, status = evaluate(input)

      refute status.success?
      assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                      "token-budget-trusted-plan-unreadable"
    end
  end

  def test_token_budget_rejects_malformed_or_duplicate_key_trusted_plan_artifacts
    candidate = token_budget
    duplicate_key_json = JSON.generate(candidate).sub(
      '"batch_id":"batch-plan-1"',
      '"batch_id":"batch-plan-1","batch_id":"shadow-batch"'
    )
    outcomes = ["{", duplicate_key_json].map do |artifact_json|
      input = input_for
      enable_token_budget(input, candidate)
      File.write(input.dig("plan", "token_budget_anchor", "trusted_plan_path"), artifact_json)

      result, _stderr, status = evaluate(input)
      [status.success?, result.fetch("violations").map { |violation| violation.fetch("code") }]
    end

    assert_equal(
      Array.new(2) { [false, ["token-budget-trusted-plan-malformed"]] },
      outcomes
    )
  end

  def test_token_budget_rejects_a_stale_trusted_plan_artifact
    input = input_for
    candidate = token_budget
    enable_token_budget(input, candidate)
    stale_budget = JSON.parse(JSON.generate(candidate))
    stale_budget.dig("scopes", "aggregate")["limit_tokens"] += 1
    File.write(
      input.dig("plan", "token_budget_anchor", "trusted_plan_path"),
      JSON.generate(canonicalize(stale_budget))
    )

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-trusted-plan-mismatch"
  end

  def test_token_budget_rejects_a_non_object_trusted_plan_artifact
    outcomes = %w[null false].map do |artifact_json|
      input = input_for
      enable_token_budget(input)
      File.write(input.dig("plan", "token_budget_anchor", "trusted_plan_path"), artifact_json)

      result, _stderr, status = evaluate(input)
      [status.success?, result.fetch("violations").map { |violation| violation.fetch("code") }]
    end

    assert_equal(
      Array.new(2) { [false, ["token-budget-trusted-plan-mismatch"]] },
      outcomes
    )
  end

  def test_token_budget_rejects_same_aliased_or_ancestor_trusted_plan_and_state_artifacts
    Dir.mktmpdir("batch-plan-budget-artifacts") do |directory|
      same_path = File.join(directory, "same.json")
      same_budget = token_budget
      same_budget["state_path"] = same_path
      same_input = input_for
      enable_token_budget(same_input, same_budget)
      same_input.dig("plan", "token_budget_anchor")["trusted_plan_path"] = same_path

      same_result, _same_stderr, same_status = evaluate(same_input)
      refute same_status.success?
      assert_includes same_result.fetch("violations").map { |violation| violation.fetch("code") },
                      "token-budget-artifact-collision"

      plan_path = File.join(directory, "trusted-plan.json")
      alias_state_path = File.join(directory, "state-alias.json")
      File.write(plan_path, "trusted-plan-placeholder")
      File.symlink(plan_path, alias_state_path)
      alias_budget = token_budget
      alias_budget["state_path"] = alias_state_path
      alias_input = input_for
      enable_token_budget(alias_input, alias_budget)
      alias_input.dig("plan", "token_budget_anchor")["trusted_plan_path"] = plan_path

      alias_result, _alias_stderr, alias_status = evaluate(alias_input)
      refute alias_status.success?
      assert_includes alias_result.fetch("violations").map { |violation| violation.fetch("code") },
                      "token-budget-artifact-collision"

      ancestor_budget = token_budget
      ancestor_budget["state_path"] = File.join(directory, "budget-artifact", "state.json")
      ancestor_input = input_for
      enable_token_budget(ancestor_input, ancestor_budget)
      ancestor_input.dig("plan", "token_budget_anchor")["trusted_plan_path"] = File.join(directory, "budget-artifact")

      ancestor_result, _ancestor_stderr, ancestor_status = evaluate(ancestor_input)
      refute ancestor_status.success?
      assert_includes ancestor_result.fetch("violations").map { |violation| violation.fetch("code") },
                      "token-budget-artifact-collision"

      actual_parent = File.join(directory, "actual")
      aliased_parent = File.join(directory, "aliased")
      Dir.mkdir(actual_parent)
      File.symlink(actual_parent, aliased_parent)
      parent_alias_budget = token_budget
      parent_alias_budget["state_path"] = File.join(aliased_parent, "trusted-plan.json", "state.json")
      parent_alias_input = input_for
      enable_token_budget(parent_alias_input, parent_alias_budget)
      parent_alias_input.dig("plan", "token_budget_anchor")["trusted_plan_path"] =
        File.join(actual_parent, "trusted-plan.json")

      parent_alias_result, _parent_alias_stderr, parent_alias_status = evaluate(parent_alias_input)
      refute parent_alias_status.success?
      assert_includes parent_alias_result.fetch("violations").map { |violation| violation.fetch("code") },
                      "token-budget-artifact-collision"
    end
  end

  def test_token_budget_rejects_untrusted_or_malformed_verifier_records
    mutations = {
      "unknown-algorithm" => proc { |records| records[0]["algorithm"] = "UNKNOWN" },
      "malformed-key" => proc { |records| records[0]["public_key_pem"] = "not-a-public-key" },
      "private-key" => proc { |records| records[0]["public_key_pem"] = TEST_VERIFIER_KEY.to_pem },
      "duplicate-id" => proc { |records| records << records[0].dup },
      "duplicate-key-different-id" => proc do |records|
        records << records[0].merge("id" => "different-verifier-id")
      end,
      "empty" => proc(&:clear)
    }
    mutations.each do |name, mutate|
      input = input_for
      input.fetch("plan")["token_budget"] = token_budget
      mutate.call(input.dig("plan", "token_budget", "trusted_verifiers"))

      result, _stderr, status = evaluate(input)

      refute status.success?, name
      assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                      "token-budget-trusted-verifiers-invalid", name
    end
  end

  def test_top_level_token_budget_cannot_coexist_with_inline_lane_budget_metadata
    input = input_for
    input.fetch("plan")["token_budget"] = token_budget
    input.dig("plan", "lanes", 0)["token_budget"] = { "limit_tokens" => 100 }

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-placement-invalid"
  end

  def test_partial_or_mismatched_token_budget_fails_closed_without_affecting_legacy_plans
    input = input_for(lanes: [lane("lane-a"), lane("lane-b")])
    input.fetch("plan")["token_budget"] = token_budget

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-lane-scopes-mismatch"

    legacy = input_for
    legacy_result, legacy_stderr, legacy_status = evaluate(legacy)
    assert legacy_status.success?, legacy_stderr
    assert_equal "accepted", legacy_result.fetch("status")
  end

  def test_opt_in_token_budget_requires_an_absolute_durable_state_path
    input = input_for
    input.fetch("plan")["token_budget"] = token_budget
    input.dig("plan", "token_budget").delete("state_path")

    missing, _stderr, missing_status = evaluate(input)

    refute missing_status.success?
    assert_includes missing.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-state-path-invalid"

    input.dig("plan", "token_budget")["state_path"] = "tmp/budget.json"
    relative, _stderr, relative_status = evaluate(input)

    refute relative_status.success?
    assert_includes relative.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-state-path-invalid"
  end

  def test_token_budget_rejects_lane_ids_reserved_for_parent_scopes
    reserved_lane = lane("coordinator")
    input = input_for(lanes: [reserved_lane])
    input.fetch("plan")["token_budget"] = token_budget(lane_limits: { "coordinator" => 200 })

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                    "token-budget-lane-id-reserved"
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

  def test_changed_immutable_edge_tuple_rejects_stale_gate_before_launch
    lanes = [lane("foundation"), lane("consumer")]
    stale_edges = [{
      "id" => "foundation-before-consumer",
      "from" => "foundation",
      "to" => "consumer",
      "type" => "merge_order"
    }]
    stale_plan = {
      "contract" => "stage-dependency-plan",
      "version" => 1,
      "id" => "trusted-plan-1",
      "edges" => stale_edges
    }
    stage_lanes = %w[foundation consumer].map do |id|
      {
        "id" => id,
        "maker" => "maker-#{id}",
        "checker" => "checker-#{id}",
        "head_sha" => "1" * 40,
        "base_sha" => "a" * 40,
        "preparation" => {}
      }
    end
    stale_gate = evaluate_stage_dependency_gate(
      stale_plan,
      lanes: stage_lanes,
      edges: [{ "id" => "foundation-before-consumer", "state" => "pending" }]
    )
    input = input_for(
      lanes: lanes,
      edges: [{
        "id" => "foundation-before-consumer",
        "from" => "foundation",
        "to" => "consumer",
        "type" => "edit"
      }]
    )
    input["stage_dependency_gate"] = stale_gate

    consumer = stale_gate.fetch("lanes").find { |entry| entry["id"] == "consumer" }
    assert_equal true, consumer.dig("permissions", "patch_edit")
    result, stderr, status = evaluate(input)

    refute status.success?, stderr
    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                    "stage-dependency-gate-plan-binding-mismatch"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_stage_gate_plan_binding_is_required_known_and_well_formed
    cases = {
      "missing" => ["stage-dependency-gate-plan-binding-missing", :delete],
      "UNKNOWN" => %w[stage-dependency-gate-plan-binding-unknown UNKNOWN],
      "malformed" => ["stage-dependency-gate-plan-binding-malformed", "sha256:not-a-digest"]
    }

    cases.each do |label, (expected_code, value)|
      input = input_for
      if value == :delete
        input.fetch("stage_dependency_gate").delete("trusted_plan_binding")
      else
        input.fetch("stage_dependency_gate")["trusted_plan_binding"] = value
      end
      result, _stderr, status = evaluate(input)

      refute status.success?, label
      assert_equal "rejected", result.fetch("status"), label
      assert_includes result.fetch("violations").map { |violation| violation.fetch("code") },
                      expected_code,
                      label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
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

  def test_malformed_changed_surfaces_preserves_its_structured_violation
    input = input_for
    input.dig("plan", "lanes", 0)["changed_surfaces"] = nil

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "changed-surfaces-invalid"
    refute_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "invalid-envelope"
    assert_empty result.dig("launch", "eligible_lane_ids")
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

  def test_directory_rename_endpoints_collide_with_descendant_touches
    %w[old new].each do |endpoint|
      lanes = [lane("lane-a"), lane("lane-b")]
      descendant = "lib/#{endpoint}/nested.rb"
      maps = {
        "lane-a" => touch_map(1, %w[lib/old lib/new]).merge(
          "renames" => [{ "old" => "lib/old", "new" => "lib/new" }]
        ),
        "lane-b" => touch_map(2, [descendant])
      }

      result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps))

      refute status.success?, endpoint
      collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
      assert_equal %w[lane-a lane-b], collision.fetch("lane_ids"), endpoint
      assert_includes collision.fetch("message"), descendant, endpoint
    end
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

  def test_max_one_serialization_advances_after_durable_lane_completion
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

    state = lane_lifecycle_state(lane_id: "lane-a")
    second_result, second_stderr, second_status = evaluate(
      input_for(lanes: lanes, maps: maps, groups: groups, lifecycle_states: [state])
    )
    assert second_status.success?, second_stderr
    assert_equal ["lane-b"], second_result.dig("launch", "eligible_lane_ids")
    assert_equal [], second_result.dig("launch", "held_lane_ids")
    assert_equal ["lane-a"], second_result.dig("launch", "completed_lane_ids")
  end

  def test_active_lane_occupies_max_one_group_and_never_reenters_launch_partition
    active_lane = lane("lane-active").merge("serialization_group" => "changelog-writers")
    planned_lane = lane("lane-planned").merge("serialization_group" => "changelog-writers")
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    state = lane_lifecycle_state(lane_id: "lane-active", state: "active")

    [[planned_lane, active_lane], [active_lane, planned_lane], [planned_lane, active_lane]].each do |lanes|
      result, stderr, status = evaluate(
        input_for(lanes: lanes, groups: groups, lifecycle_states: [state])
      )

      assert status.success?, stderr
      assert_equal "accepted", result.fetch("status")
      assert_empty result.dig("launch", "eligible_lane_ids")
      assert_equal ["lane-planned"], result.dig("launch", "held_lane_ids")
      assert_empty result.dig("launch", "completed_lane_ids")
    end
  end

  def test_blocked_lane_is_held_and_never_reenters_launch_partition
    state = lane_lifecycle_state(state: "blocked")

    result, stderr, status = evaluate(input_for(lifecycle_states: [state]))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_equal ["lane-a"], result.dig("launch", "held_lane_ids")
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_blocked_lane_occupies_max_one_group_until_its_state_changes
    blocked_lane = lane("lane-a").merge("serialization_group" => "changelog-writers")
    sibling_lane = lane("lane-b").merge("serialization_group" => "changelog-writers")
    lanes = [sibling_lane, blocked_lane]
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]

    blocked_result, blocked_stderr, blocked_status = evaluate(
      input_for(
        lanes: lanes,
        groups: groups,
        lifecycle_states: [lane_lifecycle_state(lane_id: "lane-a", state: "blocked")]
      )
    )
    assert blocked_status.success?, blocked_stderr
    assert_empty blocked_result.dig("launch", "eligible_lane_ids")
    assert_equal %w[lane-a lane-b], blocked_result.dig("launch", "held_lane_ids")

    completed_result, completed_stderr, completed_status = evaluate(
      input_for(lanes: lanes, groups: groups, lifecycle_states: [lane_lifecycle_state(lane_id: "lane-a")])
    )
    assert completed_status.success?, completed_stderr
    assert_equal ["lane-b"], completed_result.dig("launch", "eligible_lane_ids")
    assert_empty completed_result.dig("launch", "held_lane_ids")
  end

  def test_planned_and_claimed_lanes_remain_launch_eligible
    %w[planned claimed].each do |lifecycle_state|
      result, stderr, status = evaluate(
        input_for(lifecycle_states: [lane_lifecycle_state(state: lifecycle_state)])
      )

      assert status.success?, stderr
      assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids"), lifecycle_state
      assert_empty result.dig("launch", "held_lane_ids"), lifecycle_state
    end
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

  def test_unknown_or_malformed_durable_lifecycle_states_are_rejected
    valid_state = lane_lifecycle_state
    cases = {
      "unknown state" => lambda { |state|
        state["state"] = "UNKNOWN"
      },
      "missing durable reference" => lambda { |state|
        state.delete("state_ref")
      },
      "relative durable reference" => lambda { |state|
        state["state_ref"] = "state/lane-a"
      },
      "foreign batch" => lambda { |state|
        state["batch_plan_id"] = "other-batch"
      },
      "foreign dependency plan" => lambda { |state|
        state["stage_dependency_plan_id"] = "other-plan"
      },
      "unknown lane" => lambda { |state|
        state["lane_id"] = "lane-z"
      },
      "wrong wave" => lambda { |state|
        state["wave"] = "wave-z"
      },
      "obsolete signature field" => lambda { |state|
        state["signature"] = "not-supported"
      }
    }

    cases.each do |label, mutation|
      state = JSON.parse(JSON.generate(valid_state))
      mutation.call(state)
      result, _stderr, status = evaluate(input_for(lifecycle_states: [state]))

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-state-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
      assert_empty result.dig("launch", "completed_lane_ids"), label
    end
  end

  def test_nonterminal_durable_state_is_accepted_but_does_not_mark_a_lane_completed
    result, stderr, status = evaluate(
      input_for(lifecycle_states: [lane_lifecycle_state(state: "active")])
    )

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_completed_lanes_never_relaunch_and_exhausted_group_has_none_eligible
    lanes = [lane("lane-b"), lane("lane-a")]
    lanes.each { |record| record["serialization_group"] = "changelog-writers" }
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    states = [
      lane_lifecycle_state(lane_id: "lane-a"),
      lane_lifecycle_state(lane_id: "lane-b")
    ]

    result, stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, groups: groups, lifecycle_states: states)
    )

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_empty result.dig("launch", "held_lane_ids")
    assert_equal %w[lane-a lane-b], result.dig("launch", "completed_lane_ids")
  end

  def test_lifecycle_state_collection_is_required_and_rejects_duplicate_lane_states
    missing = input_for
    missing.delete("lane_lifecycle_states")
    result, _stderr, status = evaluate(missing)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-states-array-required"

    state = lane_lifecycle_state
    duplicate = input_for(lifecycle_states: [state, state.dup])
    result, _stderr, status = evaluate(duplicate)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-state-duplicate"
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_helper_keeps_lifecycle_unsigned_while_validating_opt_in_budget_verifiers
    source = File.read(HELPER, encoding: "UTF-8")

    refute_includes source, "workflow-control-lifecycle-trust"
    refute_includes source, "lane_lifecycle_receipts"
    assert_includes source, "valid_trusted_verifiers?"
    assert_includes source, "rsa-pss-sha256"
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

  def test_satisfied_edit_edge_does_not_exempt_two_patch_enabled_incomplete_lanes
    lanes = [lane("foundation"), lane("consumer")]
    maps = {
      "foundation" => touch_map(1, ["CHANGELOG.md"]),
      "consumer" => touch_map(2, ["CHANGELOG.md"])
    }
    edges = [{
      "id" => "foundation-before-consumer",
      "from" => "foundation",
      "to" => "consumer",
      "type" => "edit"
    }]
    result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps, edges: edges))

    refute status.success?
    collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
    assert_equal %w[consumer foundation], collision.fetch("lane_ids")
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_edit_edge_overlap_is_safe_after_durable_predecessor_completion
    lanes = [lane("foundation"), lane("consumer")]
    maps = {
      "foundation" => touch_map(1, ["CHANGELOG.md"]),
      "consumer" => touch_map(2, ["CHANGELOG.md"])
    }
    edges = [{
      "id" => "foundation-before-consumer",
      "from" => "foundation",
      "to" => "consumer",
      "type" => "edit"
    }]
    state = lane_lifecycle_state(lane_id: "foundation")
    result, stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, edges: edges, lifecycle_states: [state])
    )

    assert status.success?, stderr
    assert_equal ["consumer"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["foundation"], result.dig("launch", "completed_lane_ids")
    assert_empty result.fetch("violations")
  end

  def test_backend_lane_and_risky_caps_accept_boundary_and_reject_one_over
    caps = {
      "codex" => { lanes: 10, risky: 8 },
      "claude" => { lanes: 5, risky: 3 },
      "generic" => { lanes: 5, risky: 3 }
    }
    caps.each do |backend, cap|
      lane_boundary = Array.new(cap.fetch(:lanes)) { |index| lane("lane-#{index}") }
      _result, stderr, status = evaluate(input_for(lanes: lane_boundary, backend: backend))
      assert status.success?, "#{backend} lane boundary: #{stderr}"

      risky_boundary = Array.new(cap.fetch(:risky)) do |index|
        lane("risky-#{index}", surfaces: ["security_boundary"])
      end
      _result, stderr, status = evaluate(input_for(lanes: risky_boundary, backend: backend))
      assert status.success?, "#{backend} risky boundary: #{stderr}"

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

  def test_backend_lane_cap_counts_only_the_active_launch_wave
    active_lanes = Array.new(5) { |index| lane("active-#{index}", wave: "wave-a") }
    future_lanes = Array.new(5) { |index| lane("future-#{index}", wave: "wave-b") }

    result, stderr, status = evaluate(input_for(lanes: active_lanes + future_lanes, backend: "generic"))

    assert status.success?, stderr
    assert_equal active_lanes.map { |record| record.fetch("id") },
                 result.dig("launch", "eligible_lane_ids")
    assert_equal future_lanes.map { |record| record.fetch("id") },
                 result.dig("launch", "held_lane_ids")
  end

  def test_any_risky_lane_limits_the_entire_active_wave_to_the_reduced_cap
    lanes = Array.new(5) do |index|
      surfaces = index.zero? ? ["security_boundary"] : []
      lane("lane-#{index}", surfaces: surfaces)
    end

    %w[generic claude].each do |backend|
      result, _stderr, status = evaluate(input_for(lanes: lanes, backend: backend))

      refute status.success?, backend
      cap = result.fetch("violations").find { |item| item.fetch("code") == "backend-risky-cap-exceeded" }
      assert_equal lanes.map { |record| record.fetch("id") }, cap.fetch("lane_ids"), backend
    end
  end

  def test_safe_changed_path_collisions_still_count_toward_risky_cap
    lanes = Array.new(4) do |index|
      lane("lane-#{index}").merge("serialization_group" => "shared-path-writers")
    end
    maps = lanes.each_with_index.to_h do |record, index|
      [record.fetch("id"), touch_map(index + 1, ["CHANGELOG.md"])]
    end
    groups = [{ "id" => "shared-path-writers", "max_concurrency" => 1 }]
    result, _stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, groups: groups, backend: "generic")
    )

    refute status.success?
    cap = result.fetch("violations").find { |item| item.fetch("code") == "backend-risky-cap-exceeded" }
    assert_equal lanes.map { |record| record.fetch("id") }, cap.fetch("lane_ids")
  end

  def test_serialized_directory_rename_collision_counts_toward_risky_cap
    lanes = [
      lane("rename").merge("serialization_group" => "directory-writers"),
      lane("descendant").merge("serialization_group" => "directory-writers"),
      lane("ordinary-a"),
      lane("ordinary-b")
    ]
    maps = {
      "rename" => touch_map(1, %w[lib/old lib/new]).merge(
        "renames" => [{ "old" => "lib/old", "new" => "lib/new" }]
      ),
      "descendant" => touch_map(2, ["lib/new/nested.rb"]),
      "ordinary-a" => touch_map(3, ["lib/ordinary-a.rb"]),
      "ordinary-b" => touch_map(4, ["lib/ordinary-b.rb"])
    }
    groups = [{ "id" => "directory-writers", "max_concurrency" => 1 }]

    result, _stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, groups: groups, backend: "generic")
    )

    refute status.success?
    cap = result.fetch("violations").find { |item| item.fetch("code") == "backend-risky-cap-exceeded" }
    assert_equal lanes.map { |record| record.fetch("id") }.sort, cap.fetch("lane_ids")
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
    assert_empty fixture.dig("input", "lane_lifecycle_states")
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

  def test_missing_lane_id_preserves_lane_identity_violations
    input = input_for
    input.dig("plan", "lanes", 0).delete("id")

    result, _stderr, status = evaluate(input)

    refute status.success?
    codes = result.fetch("violations").map { |item| item.fetch("code") }
    assert_includes codes, "lane-id-invalid-or-duplicate"
    assert_includes codes, "lane-record-invalid"
    refute_includes codes, "invalid-envelope"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_multiple_malformed_lane_ids_preserve_the_structured_lane_identity_violation
    input = input_for(lanes: [lane("lane-a"), lane("lane-b")])
    input.dig("plan", "lanes", 0).delete("id")
    input.dig("plan", "lanes", 1)["id"] = []

    result, _stderr, status = evaluate(input)

    refute status.success?
    codes = result.fetch("violations").map { |item| item.fetch("code") }
    assert_includes codes, "lane-id-invalid-or-duplicate"
    refute_includes codes, "invalid-envelope"
    assert_empty result.dig("launch", "eligible_lane_ids")
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

  def test_both_file_touch_shapes_reject_noncanonical_paths_and_rename_endpoints
    invalid_paths = {
      "empty" => "",
      "non-string" => 123,
      "nul" => "lib/\0task.rb",
      "backslash" => 'lib\task.rb',
      "drive" => 'C:\repo\lib\task.rb',
      "drive-forward-separators" => "C:/repo/lib/task.rb",
      "drive-relative" => "C:lib/task.rb",
      "unc" => '\\\\server\share\task.rb',
      "mixed-separators" => 'lib\sub/task.rb',
      "absolute" => "/lib/task.rb",
      "trailing-separator" => "lib/task.rb/",
      "repeated-separator" => "lib//task.rb",
      "leading-dot-component" => "./lib/task.rb",
      "nested-dot-component" => "lib/./task.rb",
      "dot-dot-component" => "lib/../lib/task.rb"
    }
    shapes = {
      "verified" => {
        expected_code: "file-touch-map-shape-invalid",
        build: lambda do |target, invalid_path|
          paths = target == "paths" ? [invalid_path] : ["lib/task.rb"]
          renames = if target == "paths"
                      []
                    else
                      [{ "old" => "lib/task.rb", "new" => "lib/task-renamed.rb" }
                         .merge(target => invalid_path)]
                    end
          touch_map(1, paths).merge("renames" => renames)
        end
      },
      "planned" => {
        expected_code: "planned-path-evidence-invalid",
        build: lambda do |target, invalid_path|
          paths = if target == "paths"
                    [invalid_path]
                  else
                    ["lib/task.rb", "lib/task-renamed.rb", invalid_path].uniq
                  end
          renames = if target == "paths"
                      []
                    else
                      [{ "old" => "lib/task.rb", "new" => "lib/task-renamed.rb" }
                         .merge(target => invalid_path)]
                    end
          planned_path_evidence(paths, renames: renames)
        end
      }
    }

    unexpected_results = []
    shapes.each do |shape, details|
      %w[paths old new].each do |target|
        invalid_paths.each do |label, invalid_path|
          input = input_for(
            maps: { "lane-a" => details.fetch(:build).call(target, invalid_path) }
          )
          result, _stderr, status = evaluate(input)
          assertion = "#{shape} #{target} #{label}"
          codes = result.fetch("violations").map { |item| item.fetch("code") }
          unexpected_results << "#{assertion}: accepted" if status.success?
          unless codes.include?(details.fetch(:expected_code))
            unexpected_results << "#{assertion}: missing #{details.fetch(:expected_code)}"
          end
          unless result.dig("launch", "eligible_lane_ids").empty?
            unexpected_results << "#{assertion}: launch remained eligible"
          end
        end
      end
    end
    assert_empty unexpected_results, unexpected_results.join("\n")
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

  def test_duplicate_json_plan_fields_fail_closed_before_evaluation
    input = input_for
    input.fetch("plan")["token_budget"] = token_budget
    raw = JSON.generate(input).sub(
      '"id":"batch-plan-1"',
      '"id":"batch-plan-1","id":"shadow-plan"'
    )

    result, stderr, status = evaluate_raw(raw)

    refute status.success?
    assert_empty stderr
    assert_equal(["malformed-json"], result.fetch("violations").map { |item| item.fetch("code") })

    duplicate_budget = JSON.generate(input).sub(
      '"batch_id":"batch-plan-1"',
      '"batch_id":"batch-plan-1","batch_id":"shadow-batch"'
    )
    nested_result, nested_stderr, nested_status = evaluate_raw(duplicate_budget)

    refute nested_status.success?
    assert_empty nested_stderr
    assert_equal(["malformed-json"], nested_result.fetch("violations").map { |item| item.fetch("code") })
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
