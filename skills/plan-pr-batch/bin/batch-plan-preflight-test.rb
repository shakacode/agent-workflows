#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"

HELPER = File.expand_path("batch-plan-preflight", __dir__)
STAGE_DEPENDENCY_GATE = File.expand_path("../../pr-batch/bin/stage-dependency-gate", __dir__)
REPLAY_FIXTURE = File.expand_path("../fixtures/ror-wave-a-plan-replay.json", __dir__)
UNSIGNED_LIFECYCLE_FIXTURE = File.expand_path("../fixtures/unsigned-lifecycle-smoke.json", __dir__)
UNEQUAL_HOST_CAPACITY_FIXTURE = File.expand_path("../fixtures/unequal-host-capacity-replay.json", __dir__)
READY_SLOT_REFILL_FIXTURE = File.expand_path("../fixtures/ready-slot-refill-replay.json", __dir__)

class BatchPlanPreflightTest < Minitest::Test
  RISK_SURFACES = %w[
    ci_workflow
    developer_tooling
    security_boundary
    generated_output
    release_behavior
    broad_runtime
  ].freeze
  BACKENDS_UNDER_TEST = %w[codex claude generic].freeze

  def test_clean_install_fixture_accepts_without_trust_material
    result, stderr, status = evaluate(JSON.parse(File.read(UNSIGNED_LIFECYCLE_FIXTURE)))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["install-smoke"], result.dig("launch", "eligible_lane_ids")
  end

  def issue_target(number = 397, repository: "owner/repo")
    {
      "type" => "github-issue",
      "version" => 1,
      "repository" => repository,
      "number" => number,
      "stable_coordination_identity" => "#{repository}:issue:#{number}"
    }
  end

  def pull_request_target(number = 88, repository: "owner/repo")
    {
      "type" => "github-pull-request",
      "version" => 1,
      "repository" => repository,
      "number" => number,
      "stable_coordination_identity" => "#{repository}:pull-request:#{number}"
    }
  end

  def durable_ad_hoc_target(repository: "owner/repo")
    target = "adhoc:20260824-canonical-launch-tests"
    {
      "type" => "trusted-ad-hoc-override",
      "version" => 1,
      "repository" => repository,
      "target" => target,
      "stable_coordination_identity" => "#{repository}:#{target}",
      "override_name" => "issue-397-canonical-launch-fixture",
      "trusted_authorizer" => "maintainer:justin",
      "durable_authorization_ref" => "issue://owner/repo/397#adhoc-fixture",
      "original_task_identity" => "task:issue-397-fixture"
    }
  end

  def lane(id = "lane-a", wave: "wave-a", purpose: "implementation", surfaces: [],
           target: :default, host_id: "test-host", uses_external_quota: false)
    record = {
      "id" => id,
      "wave" => wave,
      "purpose" => purpose,
      "host_id" => host_id,
      "uses_external_quota" => uses_external_quota,
      "changed_surfaces" => surfaces,
      "qa" => if surfaces.empty?
                { "disposition" => "not-required", "rationale" => "No risky changed surface." }
              else
                { "disposition" => "required" }
              end
    }
    record["target"] = target unless target == :default
    record
  end

  def host_capacity(id: "test-host", worker_limit: 1, worker_occupied: 0,
                    heavy_root_limit: 1, external_quota_limit: 1,
                    external_quota_occupied: 0, source: "verified")
    {
      "id" => id,
      "source" => source,
      "worker" => { "limit" => worker_limit, "occupied" => worker_occupied },
      "heavy_root" => {
        "limit" => heavy_root_limit,
        "admission" => "heavy-root-admission/v1"
      },
      "external_quota" => {
        "limit" => external_quota_limit,
        "occupied" => external_quota_occupied
      }
    }
  end

  def capacity_envelope(*hosts)
    {
      "type" => "per-host-capacity-envelope",
      "version" => 1,
      "hosts" => hosts
    }
  end

  def touch_map(pr_number, paths, repository: "owner/repo")
    {
      "pr" => pr_number,
      "repo" => repository,
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

  def expansion_path_reservation(lane_id: "lane-a", wave: "wave-a", path: "lib/expanded.rb",
                                 reason: "Required by the authorized implementation.",
                                 batch_plan_id: "batch-plan-1",
                                 stage_dependency_plan_id: "trusted-plan-1")
    {
      "type" => "expansion-path-reservation",
      "version" => 1,
      "batch_plan_id" => batch_plan_id,
      "stage_dependency_plan_id" => stage_dependency_plan_id,
      "lane_id" => lane_id,
      "wave" => wave,
      "path" => path,
      "reason" => reason,
      "evidence_ref" => "coordination-state://#{batch_plan_id}/lanes/#{lane_id}/path-expansions/1"
    }
  end

  def expansion_rename_reservation(lane_id: "lane-a", wave: "wave-a", old_path: "lib/old",
                                   new_path: "lib/new", batch_plan_id: "batch-plan-1",
                                   stage_dependency_plan_id: "trusted-plan-1")
    {
      "type" => "expansion-rename-reservation",
      "version" => 1,
      "batch_plan_id" => batch_plan_id,
      "stage_dependency_plan_id" => stage_dependency_plan_id,
      "lane_id" => lane_id,
      "wave" => wave,
      "rename" => { "old" => old_path, "new" => new_path },
      "reason" => "A directory rename is required by the authorized implementation.",
      "evidence_ref" => "coordination-state://#{batch_plan_id}/lanes/#{lane_id}/rename-expansions/1"
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
                lifecycle_states: [], reservations: nil, capacity: :default)
    if maps.nil?
      maps = lanes.each_with_index.to_h do |record, index|
        target = record["target"]
        if target.nil?
          target = pull_request_target(index + 1)
          record["target"] = target
        end
        map = if target["type"] == "github-pull-request"
                touch_map(target.fetch("number"), ["lib/#{record.fetch('id')}.rb"],
                          repository: target.fetch("repository"))
              else
                planned_path_evidence(["lib/#{record.fetch('id')}.rb"])
              end
        [record.fetch("id"), map]
      end
    else
      lanes.each_with_index do |record, index|
        next if record.key?("target")

        map = maps.fetch(record.fetch("id"))
        record["target"] = if map["type"] == "planned-path-evidence"
                             issue_target(index + 1)
                           else
                             pull_request_target(map.fetch("pr"), repository: map.fetch("repo"))
                           end
      end
    end
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
    input["host_capacity"] = if capacity == :default
                               capacity_envelope(
                                 host_capacity(worker_limit: [lanes.length, 1].max,
                                               external_quota_limit: [lanes.length, 1].max)
                               )
                             else
                               capacity
                             end
    input["expansion_path_reservations"] = reservations unless reservations.nil?
    input
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

  def test_lane_without_a_canonical_launch_target_fails_closed
    input = input_for
    input.dig("plan", "lanes", 0).delete("target")

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "canonical-launch-target-required"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_synthetic_ad_hoc_lane_without_a_durable_override_fails_closed
    input = input_for
    input.dig("plan", "lanes", 0)["target"] = "adhoc:20260824-similar-direct-prompt"

    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "canonical-launch-target-invalid"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_canonical_issue_and_existing_pull_request_targets_are_accepted
    [issue_target, pull_request_target].each do |target|
      result, stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      assert status.success?, "#{target.fetch('type')}: #{stderr}"
      assert_equal "accepted", result.fetch("status")
      assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    end
  end

  def test_launch_target_repository_accepts_github_repository_name_grammar
    [".github", "_", "-", "a" * 100].each do |repository_name|
      result, stderr, status = evaluate(
        input_for(lanes: [lane(target: issue_target(1, repository: "OWNER/#{repository_name}"))])
      )

      assert status.success?, "#{repository_name.inspect}: #{stderr}"
      assert_equal "accepted", result.fetch("status")
      assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    end
  end

  def test_launch_target_repository_rejects_invalid_or_unknown_components
    repositories = %w[owner:bad/repo owner/repo! UNKNOWN/repo owner/UNKNOWN owner/. owner/..]
    repositories << "owner/#{'a' * 101}"

    repositories.each do |repository|
      result, _stderr, status = evaluate(
        input_for(lanes: [lane(target: issue_target(1, repository: repository))])
      )

      refute status.success?, repository
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "canonical-launch-target-invalid"
    end
  end

  def test_verified_pr_map_for_issue_or_ad_hoc_origin_preserves_target_and_matches_repository
    [issue_target(1), durable_ad_hoc_target].each do |target|
      maps = { "lane-a" => touch_map(88, ["lib/lane-a.rb"]) }

      result, stderr, status = evaluate(input_for(lanes: [lane(target: target)], maps: maps))

      assert status.success?, "#{target.fetch('type')}: #{stderr}"
      assert_equal "accepted", result.fetch("status")
      assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    end
  end

  def test_verified_pr_map_for_issue_or_ad_hoc_origin_rejects_another_repository
    [issue_target(1), durable_ad_hoc_target].each do |target|
      maps = { "lane-a" => touch_map(88, ["lib/lane-a.rb"], repository: "elsewhere/project") }

      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)], maps: maps))

      refute status.success?, target.fetch("type")
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "launch-target-file-touch-provenance-mismatch"
    end
  end

  def test_existing_pr_target_requires_its_exact_verified_pr_map
    target = pull_request_target(88)
    maps = { "lane-a" => touch_map(89, ["lib/lane-a.rb"]) }

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)], maps: maps))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "launch-target-file-touch-provenance-mismatch"
  end

  def test_launch_target_must_match_its_file_touch_provenance_repository
    target = issue_target(1, repository: "elsewhere/project")
    maps = { "lane-a" => touch_map(1, ["lib/lane-a.rb"]) }

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)], maps: maps))

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "launch-target-file-touch-provenance-mismatch"
  end

  def test_issue_planned_path_evidence_must_match_target_repository_and_number
    target = issue_target(1)
    maps = {
      "lane-a" => planned_path_evidence(
        ["lib/lane-a.rb"],
        source_kind: "issue",
        evidence_ref: "issue://elsewhere/project/999#planned-paths"
      )
    }

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)], maps: maps))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "launch-target-file-touch-provenance-mismatch"
  end

  def test_issue_planned_path_evidence_accepts_matching_issue_references
    refs = [
      "issue://OWNER/REPO/1#planned-paths",
      "https://github.com/OWNER/REPO/issues/1"
    ]

    refs.each do |evidence_ref|
      maps = {
        "lane-a" => planned_path_evidence(
          ["lib/lane-a.rb"], source_kind: "issue", evidence_ref: evidence_ref
        )
      }
      result, stderr, status = evaluate(input_for(lanes: [lane(target: issue_target(1))], maps: maps))

      assert status.success?, "#{evidence_ref}: #{stderr} #{result.inspect}"
    end
  end

  def test_issue_planned_path_evidence_requires_the_exact_lowercase_github_host
    maps = {
      "lane-a" => planned_path_evidence(
        ["lib/lane-a.rb"],
        source_kind: "issue",
        evidence_ref: "https://GITHUB.COM/owner/repo/issues/1"
      )
    }

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: issue_target(1))], maps: maps))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "planned-path-evidence-invalid"
  end

  def test_issue_planned_path_evidence_rejects_noncanonical_authority_and_query
    refs = [
      "https://github.com:444/owner/repo/issues/1#planned-paths",
      "https://evil@github.com/owner/repo/issues/1#planned-paths",
      "https://github.com/owner/repo/issues/1?view=bad#planned-paths",
      "issue://evil@owner/repo/1#planned-paths",
      "issue://owner:444/repo/1#planned-paths",
      "issue://owner/repo/1?view=bad#planned-paths",
      "issue://owner/repo/1/extra#planned-paths",
      "issue://owner//repo/1#planned-paths",
      "issue://owner/repo//1#planned-paths",
      "issue://owner/repo/1/#planned-paths",
      "https://github.com/owner//repo/issues/1#planned-paths",
      "https://github.com/owner/repo/issues//1#planned-paths",
      "https://github.com/owner/repo/issues/1/#planned-paths"
    ]

    refs.each do |evidence_ref|
      maps = {
        "lane-a" => planned_path_evidence(
          ["lib/lane-a.rb"], source_kind: "issue", evidence_ref: evidence_ref
        )
      }
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: issue_target(1))], maps: maps))

      refute status.success?, evidence_ref
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "planned-path-evidence-invalid"
    end
  end

  def test_incomplete_durable_ad_hoc_override_fails_closed
    incomplete_target = durable_ad_hoc_target
    incomplete_target.delete("durable_authorization_ref")

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: incomplete_target)]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "durable-ad-hoc-override-invalid"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_complete_trusted_task_specific_durable_ad_hoc_override_is_accepted
    result, stderr, status = evaluate(input_for(lanes: [lane(target: durable_ad_hoc_target)]))

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
  end

  def test_durable_ad_hoc_override_requires_a_date_prefixed_descriptive_slug
    target = durable_ad_hoc_target.merge(
      "target" => "adhoc:x",
      "stable_coordination_identity" => "owner/repo:adhoc:x"
    )

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "durable-ad-hoc-override-invalid"
  end

  def test_unknown_ad_hoc_target_slug_is_not_task_specific
    target = durable_ad_hoc_target.merge(
      "target" => "adhoc:20260824-unknown",
      "stable_coordination_identity" => "owner/repo:adhoc:20260824-unknown"
    )

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "durable-ad-hoc-override-invalid"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_generic_intent_cannot_fill_durable_ad_hoc_override_provenance
    generic_target = durable_ad_hoc_target.merge(
      "override_name" => "$pr-batch",
      "trusted_authorizer" => "fix it",
      "original_task_identity" => "publish a PR"
    )

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: generic_target)]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "durable-ad-hoc-override-invalid"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_exact_generic_override_names_are_not_task_specific
    %w[pr-batch fix-it publish-pr].each do |override_name|
      generic_target = durable_ad_hoc_target.merge("override_name" => override_name)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: generic_target)]))

      refute status.success?, override_name
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_unknown_override_names_are_not_task_specific
    %w[UNKNOWN unknown UnKnOwN].each do |override_name|
      target = durable_ad_hoc_target.merge("override_name" => override_name)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, override_name
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
      assert_empty result.dig("launch", "eligible_lane_ids")
    end
  end

  def test_ad_hoc_provenance_rejects_unknown_labeled_components
    {
      "trusted_authorizer" => "maintainer:UNKNOWN",
      "original_task_identity" => "task:UNKNOWN"
    }.each do |field, hostile_value|
      target = durable_ad_hoc_target.merge(field => hostile_value)

      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, field
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_ad_hoc_provenance_rejects_generic_intent_hidden_in_any_labeled_field
    %w[fix-it pr-batch publish-pr].product(%w[trusted_authorizer original_task_identity]).each do |value, field|
      target = durable_ad_hoc_target.merge(field => "intent:#{value}")

      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, "#{field}=intent:#{value}"
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_chat_local_reference_is_not_durable_ad_hoc_authorization
    chat_local_target = durable_ad_hoc_target.merge(
      "durable_authorization_ref" => "chat://current/session"
    )

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: chat_local_target)]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "durable-ad-hoc-override-invalid"
  end

  def test_arbitrary_uri_scheme_is_not_durable_ad_hoc_authorization
    arbitrary_target = durable_ad_hoc_target.merge(
      "durable_authorization_ref" => "foo://bar/looks-durable"
    )

    result, _stderr, status = evaluate(input_for(lanes: [lane(target: arbitrary_target)]))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "durable-ad-hoc-override-invalid"
  end

  def test_durable_ad_hoc_authorization_accepts_only_supported_persisted_reference_shapes
    refs = [
      "https://github.com/owner/repo/issues/397#issuecomment-123",
      "https://github.com:443/owner/repo/pull/397#issuecomment-456",
      "issue://owner/repo/397#adhoc-authorization",
      "plan-state://batch-397/goal-prompt#lane-a",
      "plan-state://unknown-batch/unknown-task#lane-a",
      "batch://batch-397#lane-a"
    ]

    refs.each do |durable_ref|
      target = durable_ad_hoc_target.merge("durable_authorization_ref" => durable_ref)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      assert status.success?, "expected supported durable ref #{durable_ref.inspect}: #{result.inspect}"
    end
  end

  def test_plan_state_and_batch_authorization_reject_ports_and_unknown_components
    refs = [
      "plan-state://batch-397:444/goal-prompt#lane-a",
      "batch://batch-397:444#lane-a",
      "plan-state://evil@batch-397/goal-prompt#lane-a",
      "plan-state://batch-397/goal-prompt?view=bad#lane-a",
      "batch://evil@batch-397#lane-a",
      "batch://batch-397?view=bad#lane-a",
      "plan-state://UNKNOWN/goal-prompt#lane-a",
      "plan-state://unknown/goal-prompt#lane-a",
      "plan-state://batch-397/UNKNOWN#lane-a",
      "plan-state://batch-397/goal-prompt/unknown#lane-a",
      "batch://UNKNOWN#lane-a",
      "batch://unknown#lane-a"
    ]

    refs.each do |durable_ref|
      target = durable_ad_hoc_target.merge("durable_authorization_ref" => durable_ref)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, durable_ref
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_plan_state_authorization_rejects_traversal_ambiguous_paths
    refs = [
      "plan-state://fabricated/../other#lane-a",
      "plan-state://fabricated/./other#lane-a",
      "plan-state://fabricated/%2e%2e/other#lane-a",
      "plan-state://fabricated/goal%2Fprompt#lane-a",
      "plan-state://fabricated/goal%5cprompt#lane-a"
    ]

    refs.each do |durable_ref|
      target = durable_ad_hoc_target.merge("durable_authorization_ref" => durable_ref)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, durable_ref
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_parseable_durable_ad_hoc_authorization_must_match_target_repository
    refs = [
      "issue://elsewhere/project/1#adhoc-authorization",
      "https://github.com/elsewhere/project/issues/1#issuecomment-123",
      "https://github.com/elsewhere/project/pull/1#issuecomment-123"
    ]

    refs.each do |durable_ref|
      target = durable_ad_hoc_target.merge("durable_authorization_ref" => durable_ref)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, durable_ref
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_parseable_durable_ad_hoc_authorization_requires_a_positive_number
    refs = [
      "issue://owner/repo/0#adhoc-authorization",
      "https://github.com/owner/repo/issues/0#issuecomment-123",
      "https://github.com/owner/repo/pull/0#issuecomment-123"
    ]

    refs.each do |durable_ref|
      target = durable_ad_hoc_target.merge("durable_authorization_ref" => durable_ref)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, durable_ref
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_parseable_durable_ad_hoc_authorization_rejects_noncanonical_authority_and_query
    refs = [
      "issue://owner:444/repo/397#adhoc-authorization",
      "issue://evil@owner/repo/397#adhoc-authorization",
      "issue://owner/repo/397?view=bad#adhoc-authorization",
      "issue://owner/repo/397/extra#adhoc-authorization",
      "issue://owner//repo/397#adhoc-authorization",
      "issue://owner/repo//397#adhoc-authorization",
      "issue://owner/repo/397/#adhoc-authorization",
      "https://github.com:444/owner/repo/issues/397#issuecomment-123",
      "https://evil@github.com/owner/repo/issues/397#issuecomment-123",
      "https://github.com/owner/repo/issues/397?view=bad#issuecomment-123",
      "https://github.com/owner//repo/issues/397#issuecomment-123",
      "https://github.com/owner/repo/issues//397#issuecomment-123",
      "https://github.com/owner/repo/issues/397/#issuecomment-123",
      "https://github.com/owner/repo/pull//397#issuecomment-123",
      "https://github.com/owner/repo/pull/397/#issuecomment-123"
    ]

    refs.each do |durable_ref|
      target = durable_ad_hoc_target.merge("durable_authorization_ref" => durable_ref)
      result, _stderr, status = evaluate(input_for(lanes: [lane(target: target)]))

      refute status.success?, durable_ref
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "durable-ad-hoc-override-invalid"
    end
  end

  def test_duplicate_canonical_target_identity_is_rejected
    target = issue_target
    lanes = [lane("lane-a", target: target), lane("lane-b", target: target)]

    result, _stderr, status = evaluate(input_for(lanes: lanes))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "canonical-launch-target-duplicate"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_github_target_duplicates_are_case_insensitive
    lanes = [
      lane("lane-a", target: pull_request_target(88, repository: "owner/repo")),
      lane("lane-b", target: pull_request_target(88, repository: "OWNER/REPO"))
    ]

    result, _stderr, status = evaluate(input_for(lanes: lanes))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "canonical-launch-target-duplicate"
  end

  def test_ad_hoc_target_duplicates_are_repository_case_insensitive
    lanes = [
      lane("lane-a", target: durable_ad_hoc_target(repository: "owner/repo")),
      lane("lane-b", target: durable_ad_hoc_target(repository: "OWNER/REPO"))
    ]

    result, _stderr, status = evaluate(input_for(lanes: lanes))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "canonical-launch-target-duplicate"
  end

  def test_github_issue_and_pull_request_share_the_repository_number_namespace
    lanes = [
      lane("lane-a", target: issue_target(88)),
      lane("lane-b", target: pull_request_target(88))
    ]

    result, _stderr, status = evaluate(input_for(lanes: lanes))

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "canonical-launch-target-duplicate"
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

  def test_same_wave_shared_path_is_accepted_with_an_integration_advisory
    lanes = [lane("lane-a"), lane("lane-b")]
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps))

    assert status.success?
    assert_empty result.fetch("violations")
    advisory = result.fetch("advisories").find { |item| item.fetch("code") == "file-overlap-advisory" }
    assert_equal %w[lane-a lane-b], advisory.fetch("lane_ids")
    assert_includes advisory.fetch("message"), "CHANGELOG.md"
  end

  def test_expansion_path_reservations_are_optional_and_disjoint_reservations_are_accepted
    without_reservations = input_for
    refute_includes without_reservations.keys, "expansion_path_reservations"
    result, stderr, status = evaluate(without_reservations)
    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")

    result, stderr, status = evaluate(input_for(reservations: [expansion_path_reservation]))
    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
  end

  def test_same_wave_reservation_overlap_collides_unless_explicitly_serialized_at_max_one
    lanes = [lane("lane-a"), lane("lane-b")]
    reservations = [
      expansion_path_reservation(lane_id: "lane-a"),
      expansion_path_reservation(lane_id: "lane-b")
    ]

    result, _stderr, status = evaluate(input_for(lanes: lanes, reservations: reservations))
    refute status.success?
    collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
    assert_equal %w[lane-a lane-b], collision.fetch("lane_ids")
    assert_includes collision.fetch("message"), "lib/expanded.rb"
    advisory = result.fetch("advisories").find { |item| item.fetch("code") == "file-overlap-advisory" }
    assert_equal %w[lane-a lane-b], advisory.fetch("lane_ids")
    assert_includes advisory.fetch("message"), "lib/expanded.rb"

    lanes.each { |record| record["serialization_group"] = "expanded-path-writers" }
    groups = [{ "id" => "expanded-path-writers", "max_concurrency" => 1 }]
    result, stderr, status = evaluate(input_for(lanes: lanes, groups: groups, reservations: reservations))
    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    advisory = result.fetch("advisories").find { |item| item.fetch("code") == "file-overlap-advisory" }
    assert_equal %w[lane-a lane-b], advisory.fetch("lane_ids")
    assert_includes advisory.fetch("message"), "lib/expanded.rb"
  end

  def test_typed_edit_edge_does_not_replace_max_one_serialization_for_reserved_paths
    lanes = [lane("lane-a"), lane("lane-b")]
    reservations = [
      expansion_path_reservation(lane_id: "lane-a"),
      expansion_path_reservation(lane_id: "lane-b")
    ]
    edges = [{ "id" => "lane-a-before-lane-b", "from" => "lane-a", "to" => "lane-b", "type" => "edit" }]
    gate_lanes = [gate_lane("lane-a"), gate_lane("lane-b", patch_edit: false)]
    input = input_for(lanes: lanes, reservations: reservations, edges: edges, gate_lanes: gate_lanes)
    input.fetch("stage_dependency_gate")["status"] = "gated"

    result, _stderr, status = evaluate(input)

    refute status.success?
    collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
    assert_equal %w[lane-a lane-b], collision.fetch("lane_ids")
  end

  def test_mixed_verified_and_reserved_overlap_requires_pair_level_max_one_serialization
    lanes = [lane("lane-a"), lane("lane-b")]
    maps = {
      "lane-a" => touch_map(1, ["lib/shared.rb"]),
      "lane-b" => touch_map(2, ["lib/shared.rb", "lib/expanded.rb"])
    }
    reservation = expansion_path_reservation(lane_id: "lane-a")
    edges = [{ "id" => "lane-a-before-lane-b", "from" => "lane-a", "to" => "lane-b", "type" => "edit" }]
    gate_lanes = [gate_lane("lane-a"), gate_lane("lane-b", patch_edit: false)]
    input = input_for(
      lanes: lanes,
      maps: maps,
      reservations: [reservation],
      edges: edges,
      gate_lanes: gate_lanes
    )
    input.fetch("stage_dependency_gate")["status"] = "gated"

    result, _stderr, status = evaluate(input)

    refute status.success?
    collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
    assert_equal %w[lane-a lane-b], collision.fetch("lane_ids")
    assert_includes collision.fetch("message"), "max-1 serialization"
    assert_includes collision.fetch("message"), "lib/expanded.rb"
    assert_includes collision.fetch("message"), "lib/shared.rb"

    lanes.each { |record| record["serialization_group"] = "expanded-path-writers" }
    groups = [{ "id" => "expanded-path-writers", "max_concurrency" => 1 }]
    result, stderr, status = evaluate(
      input_for(
        lanes: lanes,
        maps: maps,
        groups: groups,
        reservations: [reservation],
        edges: edges,
        gate_lanes: gate_lanes
      )
    )

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
  end

  def test_reserved_path_collides_with_another_lanes_verified_file_touch_path
    lanes = [lane("lane-a"), lane("lane-b")]
    maps = {
      "lane-a" => touch_map(1, ["lib/lane-a.rb"]),
      "lane-b" => touch_map(2, ["lib/expanded.rb"])
    }

    result, _stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, reservations: [expansion_path_reservation])
    )

    refute status.success?
    collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
    assert_equal %w[lane-a lane-b], collision.fetch("lane_ids")
    assert_includes collision.fetch("message"), "lib/expanded.rb"
  end

  def test_sole_editor_reservation_protects_path_when_another_lane_later_joins
    reservation = expansion_path_reservation(lane_id: "lane-a")
    result, stderr, status = evaluate(input_for(reservations: [reservation]))
    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")

    lanes = [lane("lane-a"), lane("lane-b")]
    maps = {
      "lane-a" => touch_map(1, ["lib/lane-a.rb"]),
      "lane-b" => touch_map(2, ["lib/expanded.rb"])
    }
    result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps, reservations: [reservation]))

    refute status.success?
    collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
    assert_equal %w[lane-a lane-b], collision.fetch("lane_ids")
    assert_includes collision.fetch("message"), "lib/expanded.rb"
  end

  def test_blocked_requester_remains_held_until_max_one_holder_completes_and_requester_transitions
    holder = lane("lane-holder").merge("serialization_group" => "expanded-path-writers")
    requester = lane("lane-requester").merge("serialization_group" => "expanded-path-writers")
    lanes = [holder, requester]
    groups = [{ "id" => "expanded-path-writers", "max_concurrency" => 1 }]
    reservation = expansion_path_reservation(lane_id: "lane-requester")
    active_and_blocked = [
      lane_lifecycle_state(lane_id: "lane-holder", state: "active"),
      lane_lifecycle_state(lane_id: "lane-requester", state: "blocked")
    ]

    result, stderr, status = evaluate(
      input_for(lanes: lanes, groups: groups, lifecycle_states: active_and_blocked, reservations: [reservation])
    )
    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_includes result.dig("launch", "held_lane_ids"), "lane-requester"
    refute_includes result.dig("launch", "eligible_lane_ids"), "lane-requester"

    holder_done_requester_blocked = [
      lane_lifecycle_state(lane_id: "lane-holder"),
      lane_lifecycle_state(lane_id: "lane-requester", state: "blocked")
    ]
    result, stderr, status = evaluate(
      input_for(
        lanes: lanes,
        groups: groups,
        lifecycle_states: holder_done_requester_blocked,
        reservations: [reservation]
      )
    )
    assert status.success?, stderr
    assert_includes result.dig("launch", "completed_lane_ids"), "lane-holder"
    assert_includes result.dig("launch", "held_lane_ids"), "lane-requester"
    refute_includes result.dig("launch", "eligible_lane_ids"), "lane-requester"

    holder_done_requester_planned = [
      lane_lifecycle_state(lane_id: "lane-holder"),
      lane_lifecycle_state(lane_id: "lane-requester", state: "planned")
    ]
    result, stderr, status = evaluate(
      input_for(
        lanes: lanes,
        groups: groups,
        lifecycle_states: holder_done_requester_planned,
        reservations: [reservation]
      )
    )
    assert status.success?, stderr
    assert_includes result.dig("launch", "completed_lane_ids"), "lane-holder"
    assert_includes result.dig("launch", "eligible_lane_ids"), "lane-requester"
    refute_includes result.dig("launch", "held_lane_ids"), "lane-requester"
  end

  def test_blocked_disjoint_requester_remains_held_until_requester_transitions
    lanes = [lane("lane-holder"), lane("lane-requester")]
    reservation = expansion_path_reservation(lane_id: "lane-requester")
    blocked = [lane_lifecycle_state(lane_id: "lane-requester", state: "blocked")]

    result, stderr, status = evaluate(
      input_for(lanes: lanes, lifecycle_states: blocked, reservations: [reservation])
    )
    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_includes result.dig("launch", "held_lane_ids"), "lane-requester"
    refute_includes result.dig("launch", "eligible_lane_ids"), "lane-requester"

    planned = [lane_lifecycle_state(lane_id: "lane-requester", state: "planned")]
    result, stderr, status = evaluate(
      input_for(lanes: lanes, lifecycle_states: planned, reservations: [reservation])
    )
    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_includes result.dig("launch", "eligible_lane_ids"), "lane-requester"
    refute_includes result.dig("launch", "held_lane_ids"), "lane-requester"
  end

  def test_expansion_path_reservations_fail_closed_on_invalid_identity_shape_or_evidence
    valid = expansion_path_reservation
    cases = {
      "not an array" => "UNKNOWN",
      "malformed record" => [valid.merge("extra" => true)],
      "UNKNOWN reason" => [valid.merge("reason" => "UNKNOWN")],
      "multiline reason" => [valid.merge("reason" => "Required\nfor another file")],
      "UNKNOWN evidence" => [valid.merge("evidence_ref" => "UNKNOWN")],
      "noncanonical path" => [valid.merge("path" => "../outside.rb")],
      "unknown lane" => [valid.merge("lane_id" => "lane-z")],
      "foreign batch" => [valid.merge("batch_plan_id" => "other-batch")],
      "foreign dependency plan" => [valid.merge("stage_dependency_plan_id" => "other-plan")],
      "wrong wave" => [valid.merge("wave" => "wave-z")]
    }

    cases.each do |label, reservations|
      result, _stderr, status = evaluate(input_for(reservations: reservations))
      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "expansion-path-reservations-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_expansion_rename_reservations_require_exact_distinct_canonical_endpoints
    valid = expansion_rename_reservation
    cases = {
      "malformed record" => valid.merge("extra" => true),
      "malformed rename" => valid.merge("rename" => { "old" => "lib/old" }),
      "noncanonical old endpoint" => valid.merge("rename" => { "old" => "../old", "new" => "lib/new" }),
      "noncanonical new endpoint" => valid.merge("rename" => { "old" => "lib/old", "new" => "/new" }),
      "identical endpoints" => valid.merge("rename" => { "old" => "lib/same", "new" => "lib/same" })
    }

    cases.each do |label, reservation|
      result, _stderr, status = evaluate(input_for(reservations: [reservation]))
      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "expansion-path-reservations-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_duplicate_completed_or_reflected_expansion_path_reservations_are_stale
    reservation = expansion_path_reservation

    duplicate = input_for(reservations: [reservation, reservation.dup])
    result, _stderr, status = evaluate(duplicate)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-duplicate"

    completed = input_for(
      reservations: [reservation],
      lifecycle_states: [lane_lifecycle_state]
    )
    result, _stderr, status = evaluate(completed)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-stale"

    reflected = input_for(
      maps: { "lane-a" => touch_map(1, ["lib/lane-a.rb", "lib/expanded.rb"]) },
      reservations: [reservation]
    )
    result, _stderr, status = evaluate(reflected)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-stale"
  end

  def test_duplicate_completed_or_reflected_expansion_rename_reservations_are_stale
    reservation = expansion_rename_reservation

    duplicate = input_for(reservations: [reservation, reservation.dup])
    result, _stderr, status = evaluate(duplicate)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-duplicate"

    completed = input_for(
      reservations: [reservation],
      lifecycle_states: [lane_lifecycle_state]
    )
    result, _stderr, status = evaluate(completed)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-stale"

    reflected_map = touch_map(1, %w[lib/lane-a.rb lib/old lib/new])
    reflected_map["renames"] = [{ "old" => "lib/old", "new" => "lib/new" }]
    reflected = input_for(maps: { "lane-a" => reflected_map }, reservations: [reservation])
    result, _stderr, status = evaluate(reflected)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-stale"
  end

  def test_planned_path_evidence_does_not_make_matching_expansion_path_reservation_stale
    input = input_for(
      maps: { "lane-a" => planned_path_evidence(%w[lib/lane-a.rb lib/expanded.rb]) },
      reservations: [expansion_path_reservation]
    )

    result, stderr, status = evaluate(input)

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    refute_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-stale"
  end

  def test_planned_path_evidence_does_not_make_matching_expansion_rename_reservation_stale
    rename = { "old" => "lib/old", "new" => "lib/new" }
    input = input_for(
      maps: { "lane-a" => planned_path_evidence(%w[lib/lane-a.rb lib/old lib/new], renames: [rename]) },
      reservations: [expansion_rename_reservation]
    )

    result, stderr, status = evaluate(input)

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    refute_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "expansion-path-reservation-stale"
  end

  def test_directory_rename_endpoints_are_reported_as_integration_advisories
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

      assert status.success?, endpoint
      assert_empty result.fetch("violations"), endpoint
      advisory = result.fetch("advisories").find { |item| item.fetch("code") == "file-overlap-advisory" }
      assert_equal %w[lane-a lane-b], advisory.fetch("lane_ids"), endpoint
      assert_includes advisory.fetch("message"), descendant, endpoint
    end
  end

  def test_reserved_directory_rename_endpoints_collide_with_descendant_touches
    %w[old new].each do |endpoint|
      lanes = [lane("lane-a"), lane("lane-b")]
      descendant = "lib/#{endpoint}/nested.rb"
      maps = {
        "lane-a" => touch_map(1, ["lib/lane-a.rb"]),
        "lane-b" => touch_map(2, [descendant])
      }

      result, _stderr, status = evaluate(
        input_for(lanes: lanes, maps: maps, reservations: [expansion_rename_reservation])
      )

      refute status.success?, endpoint
      collision = result.fetch("violations").find { |item| item.fetch("code") == "unsafe-concurrent-edit" }
      assert_equal %w[lane-a lane-b], collision.fetch("lane_ids"), endpoint
      assert_includes collision.fetch("message"), descendant, endpoint
    end
  end

  def test_scalar_path_reservation_preserves_exact_path_collision_semantics
    lanes = [lane("lane-a"), lane("lane-b")]
    maps = {
      "lane-a" => touch_map(1, ["lib/lane-a.rb"]),
      "lane-b" => touch_map(2, ["lib/expanded.rb/nested.rb"])
    }

    result, stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, reservations: [expansion_path_reservation])
    )

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
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

  def test_helper_has_no_project_lifecycle_signing_or_fixed_trust_contract
    source = File.read(HELPER, encoding: "UTF-8")

    refute_includes source, "workflow-control-lifecycle-trust"
    refute_includes source, "OpenSSL"
    refute_includes source, "signature"
    refute_includes source, "lane_lifecycle_receipts"
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

  def test_file_overlap_does_not_create_a_semantic_dependency
    lanes = [lane("foundation"), lane("consumer")]
    maps = {
      "foundation" => touch_map(1, ["CHANGELOG.md"]),
      "consumer" => touch_map(2, ["CHANGELOG.md"])
    }
    result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps, edges: []))

    assert status.success?
    assert_equal %w[consumer foundation], result.dig("launch", "eligible_lane_ids").sort
    advisory = result.fetch("advisories").find { |item| item.fetch("code") == "file-overlap-advisory" }
    assert_equal %w[consumer foundation], advisory.fetch("lane_ids")
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

  def test_unequal_m5_m1_worker_capacity_sums_without_legacy_backend_ceiling
    fixture = JSON.parse(File.read(UNEQUAL_HOST_CAPACITY_FIXTURE, encoding: "UTF-8"))
    lanes = fixture.fetch("lanes").map do |row|
      lane(row.fetch("id"), host_id: row.fetch("host_id"), surfaces: ["security_boundary"])
    end

    result, stderr, status = evaluate(
      input_for(lanes: lanes, backend: "generic", capacity: fixture.fetch("capacity"))
    )

    assert status.success?, stderr
    assert_equal fixture.dig("expected", "eligible_lane_ids"), result.dig("launch", "eligible_lane_ids")
    assert_equal fixture.dig("expected", "held_lane_ids"), result.dig("launch", "held_lane_ids")
    assert_equal 12, result.dig("capacity", "admitted_worker_slots")
    host_ids = result.dig("capacity", "hosts").map { |host| host.fetch("id") }
    assert_equal %w[m1 m5], host_ids
    available_by_host = result.dig("capacity", "hosts").to_h do |host|
      [host.fetch("id"), host.dig("worker", "available")]
    end
    assert_equal({ "m1" => 5, "m5" => 7 }, available_by_host)
  end

  def test_terminal_lane_refills_the_same_host_slot_without_rebuilding_the_plan
    fixture = JSON.parse(File.read(READY_SLOT_REFILL_FIXTURE, encoding: "UTF-8"))
    lanes = fixture.fetch("lanes").map do |row|
      lane(row.fetch("id"), host_id: row.fetch("host_id"))
    end

    fixture.fetch("steps").each do |step|
      lifecycle_states = step.fetch("completed_lane_ids").map do |lane_id|
        lane_lifecycle_state(lane_id: lane_id)
      end
      result, stderr, status = evaluate(
        input_for(lanes: lanes, lifecycle_states: lifecycle_states,
                  capacity: fixture.fetch("capacity"))
      )

      assert status.success?, stderr
      assert_equal step.fetch("expected_eligible_lane_ids"), result.dig("launch", "eligible_lane_ids")
      assert_equal step.fetch("expected_held_lane_ids"), result.dig("launch", "held_lane_ids")
    end
  end

  def test_host_capacity_counts_only_the_active_launch_wave
    lanes = [
      lane("active", wave: "wave-a", host_id: "m5", uses_external_quota: true),
      lane("inactive-a", wave: "wave-b", host_id: "m5", uses_external_quota: true),
      lane("inactive-b", wave: "wave-b", host_id: "m5")
    ]
    capacity = capacity_envelope(
      host_capacity(id: "m5", worker_limit: 1, external_quota_limit: 1)
    )

    result, stderr, status = evaluate(
      input_for(lanes: lanes, active_wave: "wave-a", capacity: capacity)
    )

    assert status.success?, stderr
    assert_equal ["active"], result.dig("launch", "eligible_lane_ids")
    assert_equal %w[inactive-a inactive-b], result.dig("launch", "held_lane_ids")
    assert_equal "inactive-wave", result.dig("launch", "held_reasons", "inactive-a")
    assert_equal "inactive-wave", result.dig("launch", "held_reasons", "inactive-b")
    assert_equal 1, result.dig("capacity", "admitted_worker_slots")
  end

  def test_worker_heavy_root_and_external_quota_budgets_remain_independent
    lanes = [
      lane("ordinary", host_id: "m5"),
      lane("quota-a", host_id: "m5", uses_external_quota: true),
      lane("quota-b", host_id: "m5", uses_external_quota: true)
    ]
    capacity = capacity_envelope(
      host_capacity(id: "m5", worker_limit: 3, heavy_root_limit: 0, external_quota_limit: 1)
    )

    result, stderr, status = evaluate(input_for(lanes: lanes, capacity: capacity))

    assert status.success?, stderr
    assert_equal %w[ordinary quota-a], result.dig("launch", "eligible_lane_ids")
    assert_equal ["quota-b"], result.dig("launch", "held_lane_ids")
    assert_equal "external-quota-full", result.dig("launch", "held_reasons", "quota-b")
    assert_equal "heavy-root-admission/v1", result.dig("capacity", "hosts", 0, "heavy_root", "admission")
  end

  def test_simultaneous_worker_and_external_quota_overcommit_reports_both_violations
    lanes = [lane("quota-active", host_id: "m5", uses_external_quota: true)]
    capacity = capacity_envelope(
      host_capacity(
        id: "m5",
        worker_limit: 1,
        worker_occupied: 1,
        external_quota_limit: 1,
        external_quota_occupied: 1
      )
    )
    lifecycle_states = [lane_lifecycle_state(lane_id: "quota-active", state: "active")]

    result, _stderr, status = evaluate(
      input_for(lanes: lanes, lifecycle_states: lifecycle_states, capacity: capacity)
    )

    refute status.success?
    capacity_violations = result.fetch("violations").select do |item|
      item.fetch("code").start_with?("host-") && item.fetch("code").end_with?("-overcommitted")
    end
    assert_equal(
      %w[host-external-quota-overcommitted host-worker-capacity-overcommitted],
      capacity_violations.map { |item| item.fetch("code") }.sort
    )
    assert(capacity_violations.all? { |item| item.fetch("lane_ids") == ["quota-active"] })
  end

  def test_external_quota_overcommit_attributes_only_quota_lifecycle_lanes
    lanes = [
      lane("ordinary-active", host_id: "m5"),
      lane("quota-active", host_id: "m5", uses_external_quota: true)
    ]
    capacity = capacity_envelope(
      host_capacity(id: "m5", worker_limit: 2, external_quota_limit: 0)
    )
    lifecycle_states = lanes.map do |record|
      lane_lifecycle_state(lane_id: record.fetch("id"), state: "active")
    end

    result, _stderr, status = evaluate(
      input_for(lanes: lanes, lifecycle_states: lifecycle_states, capacity: capacity)
    )

    refute status.success?
    quota_violation = result.fetch("violations").find do |item|
      item.fetch("code") == "host-external-quota-overcommitted"
    end
    assert_equal ["quota-active"], quota_violation.fetch("lane_ids")
  end

  def test_capacity_envelope_and_lane_host_assignment_fail_closed
    valid = capacity_envelope(host_capacity)
    cases = {
      "missing hosts" => valid.tap { |value| value.delete("hosts") },
      "UNKNOWN source" => capacity_envelope(host_capacity(source: "UNKNOWN")),
      "duplicate host" => capacity_envelope(host_capacity, host_capacity),
      "overcommitted worker snapshot" => capacity_envelope(host_capacity(worker_limit: 1, worker_occupied: 2)),
      "wrong heavy-root admission" => capacity_envelope(
        host_capacity.tap { |host| host.fetch("heavy_root")["admission"] = "inline-scheduler/v1" }
      )
    }

    cases.each do |label, capacity|
      result, _stderr, status = evaluate(input_for(capacity: capacity))
      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "host-capacity-envelope-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end

    unknown_host = input_for(capacity: capacity_envelope(host_capacity))
    unknown_host.dig("plan", "lanes", 0)["host_id"] = "m1"
    result, _stderr, status = evaluate(unknown_host)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-host-capacity-unknown"
    assert_empty result.dig("launch", "eligible_lane_ids")

    missing_host = input_for(capacity: capacity_envelope(host_capacity))
    missing_host.dig("plan", "lanes", 0).delete("host_id")
    result, _stderr, status = evaluate(missing_host)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-host-capacity-unknown"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_explicit_envelope_does_not_infer_missing_lifecycle_lane_host_occupancy
    %w[active blocked].each do |lifecycle_state|
      lanes = [lane("quota-lifecycle", host_id: nil, uses_external_quota: true)]
      capacity = capacity_envelope(
        host_capacity(
          worker_limit: 1,
          worker_occupied: 1,
          external_quota_limit: 1,
          external_quota_occupied: 1
        )
      )
      lifecycle_states = [
        lane_lifecycle_state(lane_id: "quota-lifecycle", state: lifecycle_state)
      ]

      result, _stderr, status = evaluate(
        input_for(lanes: lanes, lifecycle_states: lifecycle_states, capacity: capacity)
      )

      refute status.success?, lifecycle_state
      codes = result.fetch("violations").map { |item| item.fetch("code") }
      assert_includes codes, "lane-host-capacity-unknown", lifecycle_state
      refute_includes codes, "host-worker-capacity-overcommitted", lifecycle_state
      refute_includes codes, "host-external-quota-overcommitted", lifecycle_state
      host = result.dig("capacity", "hosts", 0)
      assert_equal 0, host.dig("worker", "lifecycle_occupied"), lifecycle_state
      assert_equal 0, host.dig("external_quota", "lifecycle_occupied"), lifecycle_state
    end
  end

  def test_rejected_capacity_decision_preserves_uniform_slot_budget_shape
    accepted_result, accepted_stderr, accepted_status = evaluate(input_for)
    assert accepted_status.success?, accepted_stderr

    rejected_input = input_for
    rejected_input.fetch("plan")["backend"] = "invalid"
    rejected_result, _stderr, rejected_status = evaluate(rejected_input)

    refute rejected_status.success?
    accepted_host = accepted_result.dig("capacity", "hosts", 0)
    rejected_host = rejected_result.dig("capacity", "hosts", 0)
    %w[worker external_quota].each do |budget|
      assert_equal accepted_host.fetch(budget).keys.sort, rejected_host.fetch(budget).keys.sort, budget
      assert_equal 0, rejected_host.dig(budget, "lifecycle_occupied"), budget
      assert_equal 0, rejected_host.dig(budget, "available"), budget
      assert_equal 0, rejected_host.dig(budget, "admitted"), budget
    end
  end

  def test_lifecycle_overcommit_rejection_reports_actual_host_local_occupancy
    lanes = [
      lane("ordinary-active"),
      lane("quota-blocked", uses_external_quota: true)
    ]
    capacity = capacity_envelope(
      host_capacity(worker_limit: 1, external_quota_limit: 0)
    )
    lifecycle_states = [
      lane_lifecycle_state(lane_id: "ordinary-active", state: "active"),
      lane_lifecycle_state(lane_id: "quota-blocked", state: "blocked")
    ]

    result, _stderr, status = evaluate(
      input_for(lanes: lanes, lifecycle_states: lifecycle_states, capacity: capacity)
    )

    refute status.success?
    violations_by_code = result.fetch("violations").to_h { |item| [item.fetch("code"), item] }
    assert_equal %w[ordinary-active quota-blocked],
                 violations_by_code.fetch("host-worker-capacity-overcommitted").fetch("lane_ids")
    assert_equal ["quota-blocked"],
                 violations_by_code.fetch("host-external-quota-overcommitted").fetch("lane_ids")
    host = result.dig("capacity", "hosts", 0)
    assert_equal 2, host.dig("worker", "lifecycle_occupied")
    assert_equal 1, host.dig("external_quota", "lifecycle_occupied")
    %w[worker external_quota].each do |budget|
      assert_equal 0, host.dig(budget, "available"), budget
      assert_equal 0, host.dig(budget, "admitted"), budget
    end
    assert_equal 0, result.dig("capacity", "admitted_worker_slots")
  end

  def test_explicit_fallback_source_rejects_arbitrary_capacity_limits
    cases = {
      "all limits" => host_capacity(
        source: "fallback",
        worker_limit: 99,
        heavy_root_limit: 99,
        external_quota_limit: 99
      ),
      "worker limit" => host_capacity(source: "fallback", worker_limit: 2),
      "heavy-root limit" => host_capacity(source: "fallback", heavy_root_limit: 2),
      "external-quota limit" => host_capacity(source: "fallback", external_quota_limit: 2)
    }

    cases.each do |label, host|
      result, _stderr, status = evaluate(input_for(capacity: capacity_envelope(host)))

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "host-capacity-envelope-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_explicit_fallback_source_accepts_occupied_slots_within_conservative_limits
    capacity = capacity_envelope(
      host_capacity(
        source: "fallback",
        worker_occupied: 1,
        external_quota_occupied: 1
      )
    )

    result, stderr, status = evaluate(input_for(capacity: capacity))

    assert status.success?, stderr
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_equal ["lane-a"], result.dig("launch", "held_lane_ids")
    assert_equal "worker-budget-full", result.dig("launch", "held_reasons", "lane-a")
  end

  def test_missing_capacity_uses_documented_single_slot_fallback
    lanes = [lane("lane-b"), lane("lane-a")]
    input = input_for(lanes: lanes)
    input.delete("host_capacity")

    result, stderr, status = evaluate(input)

    assert status.success?, stderr
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["lane-b"], result.dig("launch", "held_lane_ids")
    assert_equal "fallback", result.dig("capacity", "hosts", 0, "source")
  end

  def test_missing_capacity_infers_one_fallback_host_only_for_compatible_lane_assignments
    inferred_lanes = [lane("lane-b", host_id: nil), lane("lane-a", host_id: nil)]
    inferred_input = input_for(lanes: inferred_lanes)
    inferred_input.delete("host_capacity")

    result, stderr, status = evaluate(inferred_input)

    assert status.success?, stderr
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["lane-b"], result.dig("launch", "held_lane_ids")
    assert_equal "generic-fallback", result.dig("capacity", "hosts", 0, "id")

    incompatible_lanes = [lane("lane-a", host_id: "m1"), lane("lane-b", host_id: "m5")]
    incompatible_input = input_for(lanes: incompatible_lanes)
    incompatible_input.delete("host_capacity")

    result, _stderr, status = evaluate(incompatible_input)

    refute status.success?
    assert_equal 2, result.fetch("violations").count do |item|
      item.fetch("code") == "lane-host-capacity-unknown"
    end
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_missing_capacity_rejects_agreed_invalid_host_ids_at_each_lane_path
    { "uppercase" => "M5", "unknown" => "UNKNOWN" }.each do |label, invalid_host_id|
      lanes = [
        lane("lane-a", host_id: invalid_host_id),
        lane("lane-b", host_id: invalid_host_id)
      ]
      input = input_for(lanes: lanes)
      input.delete("host_capacity")

      result, _stderr, status = evaluate(input)

      refute status.success?, label
      host_violations = result.fetch("violations").select do |item|
        item.fetch("code") == "lane-host-capacity-unknown"
      end
      assert_equal(
        ["$.plan.lanes[0].host_id", "$.plan.lanes[1].host_id"],
        host_violations.map { |item| item.fetch("path") },
        label
      )
      refute_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "host-capacity-envelope-invalid", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_serialized_group_admits_a_runnable_sibling_when_the_first_member_exceeds_quota
    lanes = [
      lane("a-quota", uses_external_quota: true).merge("serialization_group" => "changelog-writers"),
      lane("b-ordinary").merge("serialization_group" => "changelog-writers")
    ]
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    capacity = capacity_envelope(host_capacity(worker_limit: 2, external_quota_limit: 0))

    result, stderr, status = evaluate(input_for(lanes: lanes, groups: groups, capacity: capacity))

    assert status.success?, stderr
    assert_equal ["b-ordinary"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["a-quota"], result.dig("launch", "held_lane_ids")
    assert_equal "external-quota-full", result.dig("launch", "held_reasons", "a-quota")
    assert_equal 1, result.dig("capacity", "admitted_worker_slots")
  end

  def test_serialized_group_admits_the_member_whose_host_still_has_a_free_worker_slot
    lanes = [
      lane("a-busy-host", host_id: "m1").merge("serialization_group" => "changelog-writers"),
      lane("b-free-host", host_id: "m5").merge("serialization_group" => "changelog-writers")
    ]
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    capacity = capacity_envelope(
      host_capacity(id: "m1", worker_limit: 1, worker_occupied: 1),
      host_capacity(id: "m5", worker_limit: 1)
    )

    result, stderr, status = evaluate(input_for(lanes: lanes, groups: groups, capacity: capacity))

    assert status.success?, stderr
    assert_equal ["b-free-host"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["a-busy-host"], result.dig("launch", "held_lane_ids")
    assert_equal "worker-budget-full", result.dig("launch", "held_reasons", "a-busy-host")
  end

  def test_serialized_group_follows_host_then_lane_order_when_both_hosts_are_free
    lanes = [
      lane("m-on-host-b", host_id: "host-b").merge("serialization_group" => "changelog-writers"),
      lane("z-on-host-a", host_id: "host-a").merge("serialization_group" => "changelog-writers")
    ]
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    capacity = capacity_envelope(
      host_capacity(id: "host-a", worker_limit: 1),
      host_capacity(id: "host-b", worker_limit: 1)
    )

    result, stderr, status = evaluate(input_for(lanes: lanes, groups: groups, capacity: capacity))

    assert status.success?, stderr
    assert_equal ["z-on-host-a"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["m-on-host-b"], result.dig("launch", "held_lane_ids")
    assert_equal "dependency-or-protected-gate", result.dig("launch", "held_reasons", "m-on-host-b")
  end

  def test_cross_host_serialized_group_still_fills_every_free_worker_slot
    lanes = [
      lane("z-group", host_id: "host-a").merge("serialization_group" => "changelog-writers"),
      lane("a-group", host_id: "host-b").merge("serialization_group" => "changelog-writers"),
      lane("c-ordinary", host_id: "host-b")
    ]
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    capacity = capacity_envelope(
      host_capacity(id: "host-a", worker_limit: 1),
      host_capacity(id: "host-b", worker_limit: 1)
    )

    result, stderr, status = evaluate(input_for(lanes: lanes, groups: groups, capacity: capacity))

    assert status.success?, stderr
    assert_equal %w[c-ordinary z-group], result.dig("launch", "eligible_lane_ids")
    assert_equal ["a-group"], result.dig("launch", "held_lane_ids")
    assert_equal "dependency-or-protected-gate", result.dig("launch", "held_reasons", "a-group")
    assert_equal 2, result.dig("capacity", "admitted_worker_slots")
  end

  def test_serialized_group_still_admits_at_most_one_member_with_ample_capacity
    lanes = [
      lane("a-first").merge("serialization_group" => "changelog-writers"),
      lane("b-second").merge("serialization_group" => "changelog-writers")
    ]
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    capacity = capacity_envelope(host_capacity(worker_limit: 5, external_quota_limit: 5))

    result, stderr, status = evaluate(input_for(lanes: lanes, groups: groups, capacity: capacity))

    assert status.success?, stderr
    assert_equal ["a-first"], result.dig("launch", "eligible_lane_ids")
    assert_equal ["b-second"], result.dig("launch", "held_lane_ids")
    assert_equal "dependency-or-protected-gate", result.dig("launch", "held_reasons", "b-second")
    assert_equal 1, result.dig("capacity", "admitted_worker_slots")
    assert_equal "dependency-or-protected-gate", result.dig("capacity", "hosts", 0, "next_lane_reason")
  end

  def test_occupied_serialized_group_holds_every_member_regardless_of_free_capacity
    lanes = [
      lane("a-ready").merge("serialization_group" => "changelog-writers"),
      lane("b-active").merge("serialization_group" => "changelog-writers")
    ]
    groups = [{ "id" => "changelog-writers", "max_concurrency" => 1 }]
    capacity = capacity_envelope(host_capacity(worker_limit: 5, external_quota_limit: 5))
    lifecycle_states = [lane_lifecycle_state(lane_id: "b-active", state: "active")]

    result, stderr, status = evaluate(
      input_for(lanes: lanes, groups: groups, capacity: capacity, lifecycle_states: lifecycle_states)
    )

    assert status.success?, stderr
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_equal ["a-ready"], result.dig("launch", "held_lane_ids")
    assert_equal "dependency-or-protected-gate", result.dig("launch", "held_reasons", "a-ready")
  end

  def test_missing_capacity_derives_valid_fallback_host_for_invalid_backend
    { "uppercase" => "Generic", "spaced" => "generic backend", "empty" => "" }.each do |label, backend|
      lanes = [lane("lane-a", host_id: nil), lane("lane-b", host_id: nil)]
      input = input_for(lanes: lanes, backend: backend)
      input.delete("host_capacity")

      result, _stderr, status = evaluate(input)

      refute status.success?, label
      codes = result.fetch("violations").map { |item| item.fetch("code") }
      assert_includes codes, "backend-invalid", label
      refute_includes codes, "host-capacity-envelope-invalid", label
      refute_includes codes, "lane-host-capacity-unknown", label
      assert_equal "generic-fallback", result.dig("capacity", "hosts", 0, "id"), label
      assert_equal "fallback", result.dig("capacity", "hosts", 0, "source"), label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_missing_capacity_keeps_declared_backend_in_fallback_host_id
    BACKENDS_UNDER_TEST.each do |backend|
      lanes = [lane("lane-a", host_id: nil), lane("lane-b", host_id: nil)]
      input = input_for(lanes: lanes, backend: backend)
      input.delete("host_capacity")

      result, stderr, status = evaluate(input)

      assert status.success?, "#{backend}: #{stderr}"
      assert_equal "#{backend}-fallback", result.dig("capacity", "hosts", 0, "id"), backend
    end
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
        "external-api-support-blocks-implementation" => 1
      },
      result.fetch("violations").map { |item| item.fetch("code") }.tally
    )
    assert_equal(
      { "file-overlap-advisory" => 10 },
      result.fetch("advisories").map { |item| item.fetch("code") }.tally
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

  def test_missing_lane_id_with_reservations_preserves_lane_identity_violations
    input = input_for(reservations: [expansion_path_reservation])
    input.dig("plan", "lanes", 0).delete("id")

    result, _stderr, status = evaluate(input)

    refute status.success?
    codes = result.fetch("violations").map { |item| item.fetch("code") }
    assert_includes codes, "lane-id-invalid-or-duplicate"
    assert_includes codes, "lane-record-invalid"
    refute_includes codes, "invalid-envelope"
    assert_empty result.dig("launch", "eligible_lane_ids")
  end

  def test_invalid_lane_ids_gate_reservations_and_preserve_invalid_stage_plan_violations
    {
      "missing stage plan" => ->(input) { input.delete("stage_dependency_plan") },
      "malformed stage plan" => ->(input) { input["stage_dependency_plan"] = { "contract" => "UNKNOWN" } }
    }.each do |label, invalidate_stage_plan|
      input = input_for(reservations: [expansion_path_reservation])
      input.dig("plan", "lanes", 0).delete("id")
      invalidate_stage_plan.call(input)

      result, _stderr, status = evaluate(input)

      refute status.success?, label
      codes = result.fetch("violations").map { |item| item.fetch("code") }
      assert_includes codes, "lane-id-invalid-or-duplicate", label
      assert_includes codes, "lane-record-invalid", label
      assert_includes codes, "stage-dependency-plan-invalid", label
      refute_includes codes, "expansion-path-reservations-invalid", label
      refute_includes codes, "invalid-envelope", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_valid_lane_ids_preserve_structured_violations_when_stage_plan_is_invalid_with_reservations
    {
      "missing stage plan" => ->(input) { input.delete("stage_dependency_plan") },
      "malformed stage plan" => ->(input) { input["stage_dependency_plan"] = { "contract" => "UNKNOWN" } }
    }.each do |label, invalidate_stage_plan|
      input = input_for(reservations: [expansion_path_reservation])
      input.dig("file_touch_map", "lane-a")["source"] = "local-diff"
      invalidate_stage_plan.call(input)

      result, _stderr, status = evaluate(input)

      refute status.success?, label
      codes = result.fetch("violations").map { |item| item.fetch("code") }
      assert_includes codes, "file-touch-map-unverified", label
      assert_includes codes, "expansion-path-reservations-invalid", label
      assert_includes codes, "stage-dependency-plan-invalid", label
      refute_includes codes, "invalid-envelope", label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
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

  def test_validation_open_and_merge_order_edges_do_not_turn_overlap_into_a_launch_blocker
    %w[validation_open merge_order].each do |edge_type|
      lanes = [lane("lane-a"), lane("lane-b")]
      maps = {
        "lane-a" => touch_map(1, ["CHANGELOG.md"]),
        "lane-b" => touch_map(2, ["CHANGELOG.md"])
      }
      edges = [{ "id" => "#{edge_type}-edge", "from" => "lane-a", "to" => "lane-b", "type" => edge_type }]
      result, _stderr, status = evaluate(input_for(lanes: lanes, maps: maps, edges: edges))

      assert status.success?, edge_type
      assert_empty result.fetch("violations"), edge_type
      assert_includes result.fetch("advisories").map { |item| item.fetch("code") },
                      "file-overlap-advisory", edge_type
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
