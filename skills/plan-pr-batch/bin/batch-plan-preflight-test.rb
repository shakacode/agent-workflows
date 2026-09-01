#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"
require "tmpdir"

HELPER = File.expand_path("batch-plan-preflight", __dir__)
STAGE_DEPENDENCY_GATE = File.expand_path("../../pr-batch/bin/stage-dependency-gate", __dir__)
REPLAY_FIXTURE = File.expand_path("../fixtures/ror-wave-a-plan-replay.json", __dir__)
COMPANION_PATH_REPLAY_FIXTURE = File.expand_path("../fixtures/ror-companion-path-omission.json", __dir__)
UNSIGNED_LIFECYCLE_FIXTURE = File.expand_path("../fixtures/unsigned-lifecycle-smoke.json", __dir__)

class BatchPlanPreflightTest < Minitest::Test
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

  def test_replays_ror_companion_omission_as_advisory
    with_companion_repo do |root, fixture|
      source = fixture.fetch("source_path")
      companion = fixture.fetch("companion_path")
      input = companion_input(fixture, paths: [source])

      result, stderr, status = evaluate(input, chdir: root)

      assert status.success?, stderr
      assert_equal "accepted", result.fetch("status")
      advisory = result.fetch("advisories").find do |item|
        item["code"] == "companion-path-omitted"
      end
      refute_nil advisory
      assert_equal [fixture.fetch("lane_id")], advisory.fetch("lane_ids")
      assert_equal source, advisory.fetch("source_path")
      assert_equal companion, advisory.fetch("companion_path")
    end
  end

  def test_listed_companion_does_not_produce_advisory
    with_companion_repo do |root, fixture|
      input = companion_input(
        fixture,
        paths: [fixture.fetch("source_path"), fixture.fetch("companion_path")]
      )

      result, stderr, status = evaluate(input, chdir: root)

      assert status.success?, stderr
      assert_equal "accepted", result.fetch("status")
      refute(result.fetch("advisories").any? { |item| item["code"] == "companion-path-omitted" })
    end
  end

  def test_reserved_companion_does_not_produce_advisory
    with_companion_repo do |root, fixture|
      reservation = expansion_path_reservation(
        lane_id: fixture.fetch("lane_id"),
        path: fixture.fetch("companion_path")
      )
      input = companion_input(
        fixture,
        paths: [fixture.fetch("source_path")],
        reservations: [reservation]
      )

      result, stderr, status = evaluate(input, chdir: root)

      assert status.success?, stderr
      assert_equal "accepted", result.fetch("status")
      refute(result.fetch("advisories").any? { |item| item["code"] == "companion-path-omitted" })
    end
  end

  def test_repo_without_companion_conventions_preserves_existing_result
    Dir.mktmpdir("batch-plan-no-companion-config") do |root|
      result, stderr, status = evaluate(input_for, chdir: root)

      assert status.success?, stderr
      assert_equal "accepted", result.fetch("status")
      assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
      assert_empty result.fetch("violations")
      assert_empty result.fetch("advisories")
    end
  end

  def test_comment_only_policy_preserves_existing_result
    Dir.mktmpdir("batch-plan-empty-policy") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents", "agent-workflow.yml"), "# No repo policy configured.\n")

      result, _stderr, status = evaluate(input_for, chdir: root)

      assert status.success?
      assert_equal "accepted", result.fetch("status")
      assert_empty result.fetch("violations")
      assert_empty result.fetch("advisories")
    end
  end

  def test_companion_advisory_does_not_change_launch_or_validation_outcomes
    with_companion_repo do |root, fixture|
      input = companion_input(fixture, paths: [fixture.fetch("source_path")])
      advised, advised_stderr, advised_status = evaluate(input, chdir: root)
      File.write(File.join(root, ".agents", "agent-workflow.yml"), "base_branch: main\n")
      baseline, baseline_stderr, baseline_status = evaluate(input, chdir: root)

      assert advised_status.success?, advised_stderr
      assert baseline_status.success?, baseline_stderr
      assert_equal baseline.except("advisories"), advised.except("advisories")
      assert_empty baseline.fetch("advisories")
      advisory_codes = advised.fetch("advisories").map { |item| item.fetch("code") }
      assert_equal ["companion-path-omitted"], advisory_codes
    end
  end

  def test_invalid_companion_convention_fails_closed
    with_companion_repo do |root, fixture|
      File.write(File.join(root, ".agents", "agent-workflow.yml"), <<~YAML)
        companion_path_conventions:
          - source_glob: #{fixture.fetch('source_glob')}
            companion_glob: react_on_rails/sig/{name}.rbs
      YAML

      result, _stderr, status = evaluate(
        companion_input(fixture, paths: [fixture.fetch("source_path")]),
        chdir: root
      )

      refute status.success?
      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "companion-path-conventions-invalid"
    end
  end

  def with_companion_repo
    fixture = JSON.parse(File.read(COMPANION_PATH_REPLAY_FIXTURE))
    Dir.mktmpdir("batch-plan-companion") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents", "agent-workflow.yml"), <<~YAML)
        companion_path_conventions:
          - source_glob: #{fixture.fetch('source_glob')}
            companion_glob: #{fixture.fetch('companion_glob')}
      YAML
      [fixture.fetch("source_path"), fixture.fetch("companion_path")].each do |path|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), "fixture\n")
      end
      yield root, fixture
    end
  end

  def companion_input(fixture, paths:, reservations: nil)
    lane_record = lane(
      fixture.fetch("lane_id"),
      target: issue_target(fixture.fetch("issue"), repository: fixture.fetch("repository"))
    )
    input_for(
      lanes: [lane_record],
      maps: {
        fixture.fetch("lane_id") => planned_path_evidence(
          paths,
          source_kind: "issue",
          evidence_ref: "issue://#{fixture.fetch('repository')}/#{fixture.fetch('issue')}#planned-paths"
        )
      },
      reservations: reservations
    )
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
           target: :default)
    record = {
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
    record["target"] = target unless target == :default
    record
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
                lifecycle_states: [], reservations: nil)
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

  def evaluate(input, helper: HELPER, env: {}, chdir: nil)
    options = { stdin_data: JSON.generate(input) }
    options[:chdir] = chdir if chdir
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, helper, **options)
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

  def test_backend_risky_capacity_uses_verified_paths_union_active_reservations
    lanes = Array.new(4) do |index|
      lane("lane-#{index}").merge("serialization_group" => "expanded-path-writers")
    end
    groups = [{ "id" => "expanded-path-writers", "max_concurrency" => 1 }]
    reservations = [
      expansion_path_reservation(lane_id: "lane-0", path: "lib/shared-expanded.rb"),
      expansion_path_reservation(lane_id: "lane-1", path: "lib/shared-expanded.rb")
    ]

    result, _stderr, status = evaluate(
      input_for(lanes: lanes, groups: groups, reservations: reservations, backend: "generic")
    )

    refute status.success?
    cap = result.fetch("violations").find { |item| item.fetch("code") == "backend-risky-cap-exceeded" }
    assert_equal lanes.map { |record| record.fetch("id") }, cap.fetch("lane_ids")
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
        "backend-risky-cap-exceeded" => 1,
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
