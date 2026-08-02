#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "openssl"
require "rbconfig"
require "tempfile"
require "tmpdir"
require "time"

HELPER = File.expand_path("batch-plan-preflight", __dir__)
STAGE_DEPENDENCY_GATE = File.expand_path("../../pr-batch/bin/stage-dependency-gate", __dir__)
REPLAY_FIXTURE = File.expand_path("../fixtures/ror-wave-a-plan-replay.json", __dir__)

class BatchPlanPreflightTest < Minitest::Test
  class << self
    def workflow_control_signing_key
      @workflow_control_signing_key ||= OpenSSL::PKey::RSA.generate(2048)
    end

    def weak_workflow_control_signing_key
      @weak_workflow_control_signing_key ||= OpenSSL::PKey::RSA.generate(1024)
    end
  end

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
    self.class.workflow_control_signing_key
  end

  def weak_workflow_control_signing_key
    self.class.weak_workflow_control_signing_key
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

  def installed_workflow_control_helper(key_id: "test-workflow-control-key",
                                        key: workflow_control_signing_key,
                                        config_mode: 0o600, agents_mode: 0o700,
                                        root_mode: 0o700, config_symlink: false,
                                        agents_symlink: false)
    root = secure_mktmpdir("workflow-control-trust-install")
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

  def installed_unsupported_workflow_control_helper
    root = secure_mktmpdir("workflow-control-unsupported-install")
    File.chmod(0o700, root)
    (@workflow_control_install_roots ||= []) << root
    helper = File.join(root, "skills/plan-pr-batch/bin/batch-plan-preflight")
    module_root = File.join(root, "bin/agent_doctor")
    FileUtils.mkdir_p(File.dirname(helper))
    FileUtils.mkdir_p(module_root)
    FileUtils.mkdir_p(File.join(root, ".agents"), mode: 0o700)
    FileUtils.cp(HELPER, helper)
    FileUtils.cp(File.expand_path("../../../bin/agent_doctor/signed_launch_readiness.rb", __dir__), module_root)
    FileUtils.cp(File.expand_path("../../../bin/agent_doctor/signed_launch_waiver.rb", __dir__), module_root)
    FileUtils.cp(File.expand_path("../../../bin/agent_doctor/signed_launch_waiver_record.rb", __dir__), module_root)
    File.chmod(0o755, helper)
    [helper, root]
  end

  def symlinked_supported_workflow_control_helper
    root = secure_mktmpdir("workflow-control-symlink-install")
    File.chmod(0o700, root)
    (@workflow_control_install_roots ||= []) << root
    FileUtils.mkdir_p(File.join(root, "skills"))
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.mkdir_p(File.join(root, ".agents"), mode: 0o700)
    File.symlink(File.expand_path("..", __dir__), File.join(root, "skills/plan-pr-batch"))
    File.symlink(File.expand_path("../../../bin/agent_doctor", __dir__), File.join(root, "bin/agent_doctor"))
    key = workflow_control_signing_key
    records = {
      "signed-launch-capability.json" => {
        "type" => "agent-workflow-signed-launch-capability",
        "version" => 1,
        "host" => "codex",
        "producer" => "test-host-producer",
        "dispatcher_launch_key_id" => "test-dispatcher-key",
        "workflow_control_lifecycle_key_id" => "test-workflow-control-key"
      },
      "dispatcher-launch-trust.json" => {
        "type" => "agent-workflow-dispatcher-trust-anchor",
        "version" => 1,
        "agent_workflow_dispatcher_trusted_key_id" => "test-dispatcher-key",
        "agent_workflow_dispatcher_trusted_public_key_pem" => key.public_to_pem
      },
      "workflow-control-lifecycle-trust.json" => {
        "type" => "agent-workflow-control-lifecycle-trust-anchor",
        "version" => 1,
        "agent_workflow_control_lifecycle_trusted_key_id" => "test-workflow-control-key",
        "agent_workflow_control_lifecycle_trusted_public_key_pem" => key.public_to_pem
      }
    }
    records.each do |name, record|
      path = File.join(root, ".agents", name)
      File.write(path, JSON.generate(record))
      File.chmod(0o600, path)
    end
    [File.join(root, "skills/plan-pr-batch/bin/batch-plan-preflight"), root]
  end

  def bootstrap_waiver(root, batch_id:, lane_id:, route:, dispatcher: "codex-collaboration")
    waiver_dir = File.join(root, "waivers")
    FileUtils.mkdir_p(waiver_dir, mode: 0o700)
    path = File.join(waiver_dir, "bootstrap-waiver.json")
    record = {
      "type" => "agent-workflow-bootstrap-waiver", "version" => 1,
      "waiver_id" => "#{batch_id}-human-waiver", "batch_id" => batch_id,
      "issue" => "shakacode/agent-workflows#299", "granted_at" => (Time.now.utc - 60).iso8601,
      "grant_source" => {
        "kind" => "direct-in-session-human-user", "thread_id" => "human-thread",
        "exact_message" => "go ahead with the one-time exception for issue #299."
      },
      "authorized_lanes" => [lane_id], "authorized_dispatcher" => dispatcher,
      "authorized_route" => route.merge("fallbacks" => []),
      "authorized_exception" => "Use live host-bound route metadata for this exact batch only.",
      "constraints" => {
        "serial_execution" => true, "preserve_validation_open_dependency" => true,
        "generated_keys_forbidden" => true, "synthetic_signatures_forbidden" => true,
        "inherited_routing_forbidden" => true, "fallback_dispatchers_forbidden" => true,
        "scope_expansion_forbidden" => true, "other_gate_bypass_forbidden" => true,
        "merge_authority" => "auto_merge_when_gates_pass"
      },
      "not_waived" => [
        "security preflight", "stage dependency gate", "batch plan gate", "TDD and focused tests",
        "bin/validate", "independent final-head QA and review", "current-head CI and configured reviewer completion",
        "unresolved review-thread gate", "autonomous merge eligibility", "merge assurance",
        "exact-head merge submission", "completed-batch audit"
      ]
    }
    File.write(path, JSON.generate(record))
    File.chmod(0o600, path)
    [File.realpath(path), record]
  end

  def lane_lifecycle_waiver(path:, record:, route:, lane_id: "lane-a", wave: "wave-a",
                            stage_dependency_plan_id: "trusted-plan-1", completed_at: nil, recorded_at: nil)
    batch_plan_id = record.fetch("batch_id")
    granted_at = Time.iso8601(record.fetch("granted_at"))
    completed_at ||= (granted_at + 1).iso8601
    recorded_at ||= (granted_at + 2).iso8601
    {
      "type" => "workflow-control-lane-lifecycle-waiver",
      "version" => 1,
      "producer" => "human-waived-pr-batch-workflow-control",
      "waiver_ref" => path,
      "waiver_digest" => "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(record)))}",
      "waiver_id" => record.fetch("waiver_id"),
      "batch_plan_id" => batch_plan_id,
      "stage_dependency_plan_id" => stage_dependency_plan_id,
      "lane_id" => lane_id,
      "wave" => wave,
      "state" => "completed",
      "completed_at" => completed_at,
      "recorded_at" => recorded_at,
      "receipt_ref" => "workflow-control-waiver-state://#{batch_plan_id}/stage-dependency-plans/" \
                       "#{stage_dependency_plan_id}/waves/#{wave}/lanes/#{lane_id}/completed",
      "dispatcher" => record.fetch("authorized_dispatcher"),
      "route" => route,
      "completion_attestation" => "coordinator-observed-completed",
      "evidence_ref" => "codex-worker://completed-lane-state"
    }
  end

  def teardown
    Array(@workflow_control_install_roots).each do |root|
      FileUtils.remove_entry(root) if File.exist?(root)
    end
    FileUtils.remove_entry(@secure_fixture_root) if @secure_fixture_root && File.exist?(@secure_fixture_root)
  end

  def secure_mktmpdir(prefix)
    @secure_fixture_root ||= Dir.mktmpdir("batch-plan-preflight-fixtures", __dir__).tap do |root|
      File.chmod(0o700, root)
    end
    Dir.mktmpdir(prefix, @secure_fixture_root).tap { |root| File.chmod(0o700, root) }
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
                lifecycle_receipts: [], lifecycle_waivers: [])
    waived_lane_ids = lifecycle_waivers.filter_map { |waiver| waiver["lane_id"] if waiver.is_a?(Hash) }
    lanes.each do |planned_lane|
      planned_lane["issue"] = "shakacode/agent-workflows#299" if waived_lane_ids.include?(planned_lane["id"])
    end
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
      "lane_lifecycle_receipts" => lifecycle_receipts,
      "lane_lifecycle_waivers" => lifecycle_waivers,
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

  def test_exact_human_lifecycle_waiver_advances_serial_group_and_replays_stably_on_unsupported_host
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    lanes = [lane("lane-b"), lane("lane-a")]
    lanes.each { |record| record["serialization_group"] = "serial-writers" }
    maps = {
      "lane-a" => touch_map(1, ["CHANGELOG.md"]),
      "lane-b" => touch_map(2, ["CHANGELOG.md"])
    }
    groups = [{ "id" => "serial-writers", "max_concurrency" => 1 }]
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    waiver = lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:)
    input = input_for(
      lanes:, maps:, groups:, backend: "codex", batch_plan_id: "batch-plan-1", lifecycle_waivers: [waiver]
    )

    first, first_stderr, first_status = evaluate(input, helper: helper)
    replay, replay_stderr, replay_status = evaluate(input, helper: helper)

    assert first_status.success?, "#{first_stderr}\n#{first.inspect}"
    assert replay_status.success?, "#{replay_stderr}\n#{replay.inspect}"
    assert_equal ["lane-b"], first.dig("launch", "eligible_lane_ids")
    assert_equal ["lane-a"], first.dig("launch", "completed_lane_ids")
    assert_equal first, replay
  end

  def test_symlink_install_lifecycle_waiver_assesses_readiness_against_the_installed_home
    helper, root = symlinked_supported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    waiver = lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:)

    result, _stderr, status = evaluate(
      input_for(backend: "codex", lifecycle_waivers: [waiver]), helper:
    )

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-waiver-invalid"
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_positive_lifecycle_waiver_is_portable_when_tmpdir_is_world_writable
    original_tmpdir = ENV["TMPDIR"]
    ENV["TMPDIR"] = "/tmp"
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    waiver = lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:)

    result, stderr, status = evaluate(
      input_for(backend: "codex", lifecycle_waivers: [waiver]), helper: helper
    )

    assert status.success?, "#{stderr}\n#{result.inspect}"
    assert_equal ["lane-a"], result.dig("launch", "completed_lane_ids")
  ensure
    ENV["TMPDIR"] = original_tmpdir
  end

  def test_exact_human_lifecycle_waivers_validate_a_second_lane_independently
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    lanes = [lane("lane-a"), lane("lane-b")]
    waivers = lanes.map do |planned_lane|
      lane_id = planned_lane.fetch("id")
      waiver_path, waiver_record = bootstrap_waiver(
        File.join(root, lane_id), batch_id: "batch-plan-1", lane_id:, route:
      )
      lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:, lane_id:)
    end
    input = input_for(lanes:, backend: "codex", lifecycle_waivers: waivers)

    first, first_stderr, first_status = evaluate(input, helper: helper)
    replay, replay_stderr, replay_status = evaluate(input, helper: helper)

    assert first_status.success?, "#{first_stderr}\n#{first.inspect}"
    assert replay_status.success?, "#{replay_stderr}\n#{replay.inspect}"
    assert_equal %w[lane-a lane-b], first.dig("launch", "completed_lane_ids").sort
    assert_empty first.dig("launch", "eligible_lane_ids")
    assert_equal first, replay
  end

  def test_lifecycle_waiver_rejects_mutated_canonical_record_content_at_the_same_path
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    waiver = lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:)
    mutations = {
      "issue" => ->(record) { record["issue"] = "shakacode/agent-workflows#999" },
      "granted_at" => ->(record) { record["granted_at"] = "2026-08-02T07:17:33Z" },
      "exact_message" => ->(record) { record["grant_source"]["exact_message"] = "different approval" },
      "merge_authority" => ->(record) { record["constraints"]["merge_authority"] = "none" }
    }

    mutations.each do |label, mutation|
      changed = JSON.parse(JSON.generate(waiver_record))
      mutation.call(changed)
      File.write(waiver_path, JSON.generate(changed))
      result, _stderr, status = evaluate(
        input_for(backend: "codex", lifecycle_waivers: [waiver]), helper: helper
      )

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-waiver-invalid", label
    end
  end

  def test_lifecycle_waiver_rejects_cross_batch_lane_route_and_partial_host_reuse
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    valid = lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:)
    variants = {
      "batch" => valid.merge("batch_plan_id" => "another-batch"),
      "lane" => valid.merge("lane_id" => "lane-z"),
      "dispatcher" => valid.merge("dispatcher" => "remote"),
      "route" => valid.merge("route" => route.merge("effort" => "high"))
    }

    variants.each do |label, waiver|
      result, _stderr, status = evaluate(input_for(backend: "codex", lifecycle_waivers: [waiver]), helper: helper)
      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-waiver-invalid", label
      assert_empty result.dig("launch", "completed_lane_ids"), label
    end

    File.write(File.join(root, ".agents/signed-launch-capability.json"), "{}\n")
    result, _stderr, status = evaluate(input_for(backend: "codex", lifecycle_waivers: [valid]), helper: helper)
    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-waiver-invalid"
  end

  def test_lifecycle_waiver_requires_the_exact_active_issue
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    waiver = lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:)
    valid_input = input_for(backend: "codex", lifecycle_waivers: [waiver])
    variants = {
      "cross issue" => "shakacode/agent-workflows#999",
      "missing issue" => nil,
      "unknown issue" => "UNKNOWN"
    }
    variants.each do |label, issue|
      input = JSON.parse(JSON.generate(valid_input))
      lane = input.dig("plan", "lanes", 0)
      issue.nil? ? lane.delete("issue") : lane["issue"] = issue

      result, _stderr, status = evaluate(input, helper:)

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-waiver-invalid", label
      assert_empty result.dig("launch", "completed_lane_ids"), label
    end
  end

  def test_lifecycle_waiver_rejects_completion_before_the_bootstrap_grant
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    granted_at = Time.iso8601(waiver_record.fetch("granted_at"))
    waiver = lane_lifecycle_waiver(
      path: waiver_path,
      record: waiver_record,
      route:,
      completed_at: (granted_at - 1).iso8601,
      recorded_at: (granted_at + 1).iso8601
    )

    result, _stderr, status = evaluate(
      input_for(backend: "codex", lifecycle_waivers: [waiver]), helper: helper
    )

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-waiver-invalid"
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_signed_and_waived_lifecycle_records_for_the_same_lane_are_rejected_as_duplicates
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-plan-1", lane_id: "lane-a", route:
    )
    waiver = lane_lifecycle_waiver(path: waiver_path, record: waiver_record, route:)
    input = input_for(backend: "codex", lifecycle_receipts: [lane_lifecycle_receipt], lifecycle_waivers: [waiver])

    result, _stderr, status = evaluate(input, helper: helper)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "lane-lifecycle-record-duplicate"
    assert_empty result.dig("launch", "completed_lane_ids")
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

  def test_signed_lifecycle_receipt_rejects_slash_bearing_or_uri_ambiguous_identifiers
    cases = {
      "batch" => lambda do
        batch_id = "batch/plan"
        [input_for(batch_plan_id: batch_id, lifecycle_receipts: [lane_lifecycle_receipt(batch_plan_id: batch_id)])]
      end,
      "stage plan" => lambda do
        input = input_for
        stage_id = "trusted/plan"
        input.fetch("stage_dependency_plan")["id"] = stage_id
        input.fetch("stage_dependency_gate")["trusted_plan_id"] = stage_id
        input.fetch("stage_dependency_gate")["trusted_plan_binding"] =
          stage_dependency_plan_binding(input.fetch("stage_dependency_plan"))
        input["lane_lifecycle_receipts"] = [lane_lifecycle_receipt(stage_dependency_plan_id: stage_id)]
        [input]
      end,
      "wave" => lambda do
        unsafe_lane = lane("lane-a", wave: "wave/a")
        [input_for(lanes: [unsafe_lane], active_wave: "wave/a",
                   lifecycle_receipts: [lane_lifecycle_receipt(wave: "wave/a")])]
      end,
      "lane" => lambda do
        unsafe_lane = lane("lane/a")
        [input_for(lanes: [unsafe_lane], lifecycle_receipts: [lane_lifecycle_receipt(lane_id: "lane/a")])]
      end,
      "percent escape" => lambda do
        batch_id = "batch%2Fplan"
        [input_for(batch_plan_id: batch_id, lifecycle_receipts: [lane_lifecycle_receipt(batch_plan_id: batch_id)])]
      end
    }

    cases.each do |label, build_input|
      result, _stderr, status = evaluate(build_input.call.fetch(0), helper: workflow_control_helper)

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-receipt-invalid", label
    end
  end

  def test_waived_lifecycle_receipt_rejects_slash_bearing_or_uri_ambiguous_identifiers
    helper, root = installed_unsupported_workflow_control_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    cases = {
      "batch" => { batch: "batch/plan" },
      "stage plan" => { stage: "trusted/plan" },
      "wave" => { wave: "wave/a" },
      "lane" => { lane: "lane/a" },
      "percent escape" => { batch: "batch%2Fplan" }
    }

    cases.each do |label, overrides|
      batch_id = overrides.fetch(:batch, "batch-plan-1")
      stage_id = overrides.fetch(:stage, "trusted-plan-1")
      wave = overrides.fetch(:wave, "wave-a")
      lane_id = overrides.fetch(:lane, "lane-a")
      planned_lane = lane(lane_id, wave:)
      waiver_path, waiver_record = bootstrap_waiver(root, batch_id:, lane_id:, route:)
      waiver = lane_lifecycle_waiver(
        path: waiver_path, record: waiver_record, route:, lane_id:, wave:, stage_dependency_plan_id: stage_id
      )
      input = input_for(
        lanes: [planned_lane], backend: "codex", active_wave: wave, batch_plan_id: batch_id,
        lifecycle_waivers: [waiver]
      )
      input.fetch("stage_dependency_plan")["id"] = stage_id
      input.fetch("stage_dependency_gate")["trusted_plan_id"] = stage_id
      input.fetch("stage_dependency_gate")["trusted_plan_binding"] =
        stage_dependency_plan_binding(input.fetch("stage_dependency_plan"))

      result, _stderr, status = evaluate(input, helper: helper)

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      "lane-lifecycle-waiver-invalid", label
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

  def test_lifecycle_receipt_rejects_an_rsa_1024_trust_anchor
    weak_key = weak_workflow_control_signing_key
    receipt = lane_lifecycle_receipt(key_id: "weak-workflow-control-key", signing_key: weak_key)
    helper, = installed_workflow_control_helper(key_id: "weak-workflow-control-key", key: weak_key)

    result, _stderr, status = evaluate(
      input_for(lifecycle_receipts: [receipt]), helper: helper
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

  def test_edit_edge_overlap_is_safe_after_trusted_predecessor_completion
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
    receipt = lane_lifecycle_receipt(lane_id: "foundation")
    result, stderr, status = evaluate(
      input_for(lanes: lanes, maps: maps, edges: edges, lifecycle_receipts: [receipt]),
      helper: workflow_control_helper
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

  def test_completed_stage_gate_preserves_boolean_permission_decisions
    input = input_for
    input.dig("stage_dependency_gate", "lanes", 0, "permissions").delete("patch_edit")
    result, _stderr, status = evaluate(input)

    refute status.success?
    assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                    "stage-dependency-gate-lane-invalid"
  end
end
