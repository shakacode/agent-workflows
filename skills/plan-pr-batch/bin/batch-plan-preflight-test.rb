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

HELPER = File.expand_path("batch-plan-preflight", __dir__)
STAGE_DEPENDENCY_GATE = File.expand_path("../../pr-batch/bin/stage-dependency-gate", __dir__)
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
    root = Dir.mktmpdir("workflow-control-trust-install")
    File.chmod(root_mode, root)
    (@workflow_control_install_roots ||= []) << root
    helper = File.join(root, "skills/plan-pr-batch/bin/batch-plan-preflight")
    stage_dependency_gate = File.join(root, "skills/pr-batch/bin/stage-dependency-gate")
    agents_dir = File.join(root, ".agents")
    config_path = File.join(agents_dir, "workflow-control-lifecycle-trust.json")
    FileUtils.mkdir_p(File.dirname(helper))
    FileUtils.mkdir_p(File.dirname(stage_dependency_gate))
    FileUtils.cp(HELPER, helper)
    FileUtils.cp(STAGE_DEPENDENCY_GATE, stage_dependency_gate)
    File.chmod(0o755, helper)
    File.chmod(0o755, stage_dependency_gate)
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
    [helper, config_path, stage_dependency_gate]
  end

  def workflow_control_helper
    @workflow_control_helper ||= installed_workflow_control_helper.first
  end

  def installed_preflight_with_stage_helper(body)
    helper, _config_path, stage_dependency_gate = installed_workflow_control_helper
    File.write(stage_dependency_gate, "#!#{RbConfig.ruby}\n#{body}\n")
    File.chmod(0o755, stage_dependency_gate)
    helper
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

  def stage_lane(id, head_sha: "1" * 40)
    {
      "id" => id,
      "maker" => "maker-#{id}",
      "checker" => "checker-#{id}",
      "head_sha" => head_sha,
      "base_sha" => "a" * 40,
      "preparation" => {
        "source_patch_inspection" => "plan-state://preparation/source-patch",
        "collision_domain_mapping" => "plan-state://preparation/collision-domains",
        "semantic_adaptation_notes" => "plan-state://preparation/semantic-adaptation",
        "validation_review_plan" => "plan-state://preparation/validation-review",
        "evidence_templates" => "plan-state://preparation/evidence-templates"
      }
    }
  end

  def stage_dependency_replay(stage_lanes, edges, gate_lanes)
    stage_lanes_by_id = stage_lanes.to_h { |record| [record.fetch("id"), record] }
    gate_lanes_by_id = gate_lanes.to_h { |record| [record.fetch("id"), record] }
    live_edges = edges.map do |edge|
      target_held = gate_lanes_by_id.dig(edge["to"], "permissions", "patch_edit") == false
      if target_held
        { "id" => edge["id"], "state" => "pending" }
      else
        evidence = { "evidence_ref" => "plan-state://evidence/#{edge['id']}" }
        case edge["type"]
        when "validation_open"
          target = stage_lanes_by_id.fetch(edge["to"])
          evidence.merge!("head_sha" => target.fetch("head_sha"), "base_sha" => target.fetch("base_sha"))
          {
            "id" => edge["id"],
            "state" => "satisfied",
            "evidence" => evidence,
            "base_movement" => {
              "status" => "unchanged",
              "semantic_overlap" => false,
              "required_dependency" => false,
              "conflict_or_base_sensitive" => false,
              "consumer_policy" => false
            }
          }
        when "merge_order"
          evidence.merge!(
            "terminal_state" => "merged",
            "head_sha" => stage_lanes_by_id.fetch(edge["from"]).fetch("head_sha")
          )
          { "id" => edge["id"], "state" => "satisfied", "evidence" => evidence }
        else
          { "id" => edge["id"], "state" => "satisfied", "evidence" => evidence }
        end
      end
    end
    {
      "contract" => "stage-dependency-gate",
      "version" => 1,
      "lanes" => stage_lanes,
      "edges" => live_edges
    }
  end

  def input_for(lanes: [lane], maps: nil, edges: [], groups: [], premises: [], gate_lanes: nil,
                backend: "generic", active_wave: "wave-a", batch_plan_id: "batch-plan-1",
                lifecycle_receipts: [])
    maps ||= lanes.each_with_index.to_h { |record, index| [record.fetch("id"), touch_map(index + 1, ["lib/#{record.fetch('id')}.rb"])] }
    gate_lanes ||= lanes.map { |record| gate_lane(record.fetch("id")) }
    plan_id = "trusted-plan-1"
    dependency_plan = {
      "contract" => "stage-dependency-plan",
      "version" => 1,
      "id" => plan_id,
      "edges" => edges
    }
    stage_lanes = lanes.map { |record| stage_lane(record.fetch("id")) }
    dependency_replay = stage_dependency_replay(stage_lanes, edges, gate_lanes)
    valid_edges = edges.all? do |edge|
      edge.is_a?(Hash) &&
        %w[edit validation_open merge_order].include?(edge["type"]) &&
        stage_lanes.map { |record| record.fetch("id") }.include?(edge["from"]) &&
        stage_lanes.map { |record| record.fetch("id") }.include?(edge["to"])
    end
    dependency_gate =
      if valid_edges
        evaluate_stage_dependency_gate(
          dependency_plan,
          lanes: dependency_replay.fetch("lanes"),
          edges: dependency_replay.fetch("edges")
        )
      else
        {
          "contract" => "stage-dependency-gate",
          "version" => 1,
          "status" => "eligible",
          "trusted_plan_id" => plan_id,
          "trusted_plan_binding" => stage_dependency_plan_binding(dependency_plan),
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
      end
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
      "stage_dependency_plan" => dependency_plan,
      "stage_dependency_replay" => dependency_replay,
      "stage_dependency_gate" => dependency_gate
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

  def evaluate_with_runtime_env(input, runtime_env, helper: HELPER)
    launcher = <<~RUBY
      require "json"
      ENV.update(JSON.parse(ARGV.fetch(0)))
      load ARGV.fetch(1)
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-e",
      launcher,
      JSON.generate(runtime_env),
      helper,
      stdin_data: JSON.generate(input)
    )
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

  def test_stale_satisfied_edit_gate_rejects_changed_replay_facts_before_launch
    lanes = [lane("foundation"), lane("consumer")]
    plan = {
      "contract" => "stage-dependency-plan",
      "version" => 1,
      "id" => "trusted-plan-1",
      "edges" => [{
        "id" => "foundation-before-consumer",
        "from" => "foundation",
        "to" => "consumer",
        "type" => "edit"
      }]
    }
    replay = {
      "contract" => "stage-dependency-gate",
      "version" => 1,
      "lanes" => [stage_lane("foundation"), stage_lane("consumer")],
      "edges" => [{
        "id" => "foundation-before-consumer",
        "state" => "satisfied",
        "evidence" => { "evidence_ref" => "plan-state://evidence/foundation" }
      }]
    }
    satisfied_gate = evaluate_stage_dependency_gate(
      plan,
      lanes: replay.fetch("lanes"),
      edges: replay.fetch("edges")
    )
    replay_mutations = {
      "edge state changed" => ["stage-dependency-replay-mismatch", lambda do |value|
        value.dig("edges", 0)["state"] = "pending"
        value.dig("edges", 0).delete("evidence")
      end],
      "edge evidence changed" => ["stage-dependency-replay-mismatch", lambda do |value|
        value.dig("edges", 0, "evidence").delete("evidence_ref")
      end],
      "lane SHA changed to malformed" => ["stage-dependency-replay-output-invalid", lambda do |value|
        value.dig("lanes", 1)["head_sha"] = "short"
      end]
    }

    replay_mutations.each do |label, (expected_code, mutate)|
      changed_replay = JSON.parse(JSON.generate(replay))
      mutate.call(changed_replay)
      input = input_for(lanes: lanes, edges: plan.fetch("edges"))
      input["stage_dependency_replay"] = changed_replay
      input["stage_dependency_gate"] = satisfied_gate
      result, _stderr, status = evaluate(input)

      refute status.success?, label
      assert_equal "rejected", result.fetch("status"), label
      assert_equal [expected_code], result.fetch("violations").map { |item| item.fetch("code") }, label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_replay_envelope_is_required_well_formed_and_known
    mutations = {
      "missing" => ["stage-dependency-replay-missing", lambda do |input|
        input.delete("stage_dependency_replay")
      end],
      "not an object" => ["stage-dependency-replay-invalid", lambda do |input|
        input["stage_dependency_replay"] = []
      end],
      "extra field" => ["stage-dependency-replay-invalid", lambda do |input|
        input.fetch("stage_dependency_replay")["caller_override"] = "/tmp/gate"
      end],
      "unknown nested fact" => ["stage-dependency-replay-unknown", lambda do |input|
        input.dig("stage_dependency_replay", "lanes", 0)["head_sha"] = "UNKNOWN"
      end]
    }

    mutations.each do |label, (expected_code, mutate)|
      input = input_for
      mutate.call(input)
      result, _stderr, status = evaluate(input)

      refute status.success?, label
      assert_equal [expected_code], result.fetch("violations").map { |item| item.fetch("code") }, label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
      assert_empty result.dig("launch", "held_lane_ids"), label
      assert_empty result.dig("launch", "completed_lane_ids"), label
    end
  end

  def test_replay_mismatch_preempts_lifecycle_collision_and_launch_consumption
    lanes = [lane("foundation"), lane("consumer")]
    edge = {
      "id" => "foundation-before-consumer",
      "from" => "foundation",
      "to" => "consumer",
      "type" => "edit"
    }
    shared_maps = {
      "foundation" => touch_map(1, ["lib/shared.rb"]),
      "consumer" => touch_map(2, ["lib/shared.rb"])
    }
    input = input_for(
      lanes: lanes,
      maps: shared_maps,
      edges: [edge],
      lifecycle_receipts: [{}]
    )
    input.dig("stage_dependency_replay", "edges", 0)["state"] = "pending"
    input.dig("stage_dependency_replay", "edges", 0).delete("evidence")

    result, _stderr, status = evaluate(input)

    refute status.success?
    violation_codes = result.fetch("violations").map { |item| item.fetch("code") }
    assert_equal ["stage-dependency-replay-mismatch"], violation_codes
    assert_empty result.dig("launch", "eligible_lane_ids")
    assert_empty result.dig("launch", "held_lane_ids")
    assert_empty result.dig("launch", "completed_lane_ids")
  end

  def test_fixed_replay_helper_accepts_safe_copy_and_symlink_layouts
    copied_helper, = installed_workflow_control_helper
    symlink_root = Dir.mktmpdir("batch-plan-preflight-symlink-install")
    (@workflow_control_install_roots ||= []) << symlink_root
    symlinked_helper = File.join(symlink_root, "skills/plan-pr-batch/bin/batch-plan-preflight")
    FileUtils.mkdir_p(File.dirname(symlinked_helper))
    File.symlink(HELPER, symlinked_helper)

    {
      "copied pack" => copied_helper,
      "symlinked preflight" => symlinked_helper
    }.each do |label, helper|
      result, stderr, status = evaluate(input_for, helper: helper)

      assert status.success?, "#{label}: #{stderr}"
      assert_equal "accepted", result.fetch("status"), label
      assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_fixed_replay_helper_accepts_symlinked_pr_batch_directory
    helper, = installed_workflow_control_helper
    installation_root = File.expand_path("../../../../", helper)
    pr_batch = File.join(installation_root, "skills/pr-batch")
    target = File.join(installation_root, "shared-pr-batch")
    FileUtils.mv(pr_batch, target)
    File.symlink(target, pr_batch)

    result, stderr, status = evaluate(input_for, helper:)

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
  end

  def test_fixed_replay_helper_rejects_symlink_target_beneath_writable_ancestor
    helper, = installed_workflow_control_helper
    installation_root = File.expand_path("../../../../", helper)
    pr_batch = File.join(installation_root, "skills/pr-batch")
    writable_parent = File.join(installation_root, "writable-parent")
    target = File.join(writable_parent, "pr-batch")
    FileUtils.mkdir_p(writable_parent)
    File.chmod(0o777, writable_parent)
    FileUtils.mv(pr_batch, target)
    File.symlink(target, pr_batch)

    result, _stderr, status = evaluate(input_for, helper:)

    refute status.success?
    assert_equal(
      ["stage-dependency-helper-unsafe"],
      result.fetch("violations").map { |violation| violation.fetch("code") }
    )
  ensure
    File.chmod(0o700, writable_parent) if writable_parent && File.exist?(writable_parent)
  end

  def test_fixed_replay_helper_rejects_missing_or_unsafe_pack_sibling
    missing_helper, _missing_config, missing_stage_helper = installed_workflow_control_helper
    File.unlink(missing_stage_helper)
    unsafe_helper, _unsafe_config, unsafe_stage_helper = installed_workflow_control_helper
    File.chmod(0o777, unsafe_stage_helper)

    {
      "missing sibling" => [missing_helper, "stage-dependency-helper-missing"],
      "writable sibling" => [unsafe_helper, "stage-dependency-helper-unsafe"]
    }.each do |label, (helper, expected_code)|
      result, _stderr, status = evaluate(input_for, helper: helper)

      refute status.success?, label
      assert_equal [expected_code], result.fetch("violations").map { |item| item.fetch("code") }, label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
  end

  def test_path_cannot_override_the_fixed_replay_helper
    fake_bin = Dir.mktmpdir("caller-stage-dependency-gate")
    (@workflow_control_install_roots ||= []) << fake_bin
    fake_helper = File.join(fake_bin, "stage-dependency-gate")
    File.write(fake_helper, "#!#{RbConfig.ruby}\nexit 29\n")
    File.chmod(0o755, fake_helper)

    result, stderr, status = evaluate(
      input_for,
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}" }
    )

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal ["lane-a"], result.dig("launch", "eligible_lane_ids")
  end

  def test_path_cannot_replace_the_ruby_interpreter_for_replay
    lanes = [lane("foundation"), lane("consumer")]
    edge = {
      "id" => "foundation-before-consumer",
      "from" => "foundation",
      "to" => "consumer",
      "type" => "edit"
    }
    input = input_for(lanes: lanes, edges: [edge])
    input.dig("stage_dependency_replay", "edges", 0)["state"] = "pending"
    input.dig("stage_dependency_replay", "edges", 0).delete("evidence")

    fake_bin = Dir.mktmpdir("caller-ruby")
    (@workflow_control_install_roots ||= []) << fake_bin
    stale_gate_path = File.join(fake_bin, "stale-gate.json")
    fake_ruby_marker = File.join(fake_bin, "fake-ruby-ran")
    File.write(stale_gate_path, JSON.generate(input.fetch("stage_dependency_gate")))
    fake_ruby = File.join(fake_bin, "ruby")
    File.write(
      fake_ruby,
      "#!/bin/sh\n: > \"#{fake_ruby_marker}\"\nexec /bin/cat \"#{stale_gate_path}\"\n"
    )
    File.chmod(0o755, fake_ruby)

    result, _stderr, status = evaluate(
      input,
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}" }
    )

    refute status.success?
    assert_equal "rejected", result.fetch("status")
    violation_codes = result.fetch("violations").map { |item| item.fetch("code") }
    assert_equal ["stage-dependency-replay-mismatch"], violation_codes
    assert_empty result.dig("launch", "eligible_lane_ids")
    refute File.exist?(fake_ruby_marker)
  end

  def test_ruby_and_bundler_preload_environment_cannot_run_in_replay
    ruby_probe_dir = Dir.mktmpdir("replay-ruby-preload")
    (@workflow_control_install_roots ||= []) << ruby_probe_dir
    ruby_marker = File.join(ruby_probe_dir, "ruby-preload-ran")
    File.write(
      File.join(ruby_probe_dir, "replay_preload_probe.rb"),
      "File.write(#{ruby_marker.dump}, \"ran\")\n"
    )

    bundle_probe_dir = Dir.mktmpdir("replay-bundle-preload")
    (@workflow_control_install_roots ||= []) << bundle_probe_dir
    bundle_marker = File.join(bundle_probe_dir, "bundle-preload-ran")
    bundle_gemfile = File.join(bundle_probe_dir, "Gemfile")
    File.write(
      bundle_gemfile,
      "source \"https://rubygems.org\"\nFile.write(#{bundle_marker.dump}, \"ran\")\n"
    )

    cases = {
      "RUBYOPT and RUBYLIB" => [
        {
          "RUBYOPT" => "-rreplay_preload_probe",
          "RUBYLIB" => ruby_probe_dir
        },
        ruby_marker
      ],
      "RUBYOPT and BUNDLE_GEMFILE" => [
        {
          "RUBYOPT" => "-rbundler/setup",
          "BUNDLE_GEMFILE" => bundle_gemfile
        },
        bundle_marker
      ]
    }

    cases.each do |label, (runtime_env, marker)|
      result, stderr, status = evaluate_with_runtime_env(input_for, runtime_env)

      assert status.success?, "#{label}: #{stderr}"
      assert_equal "accepted", result.fetch("status"), label
      refute File.exist?(marker), label
    end
  end

  def test_replay_child_inherits_only_the_minimal_deterministic_environment
    probe_dir = Dir.mktmpdir("replay-child-env")
    (@workflow_control_install_roots ||= []) << probe_dir
    marker = File.join(probe_dir, "inherited-env.json")
    forbidden_names = %w[
      BUNDLE_GEMFILE
      BUNDLE_WITH
      DYLD_INSERT_LIBRARIES
      GEM_HOME
      GEM_PATH
      LD_PRELOAD
      RUBYGEMS_GEMDEPS
      RUBYLIB
      RUBYOPT
    ]
    probe_body = <<~RUBY
      require "json"
      inherited = ENV.keys & #{forbidden_names.inspect}
      File.write(#{marker.dump}, JSON.generate(inherited.sort))
      load #{STAGE_DEPENDENCY_GATE.dump}
    RUBY
    helper = installed_preflight_with_stage_helper(probe_body)
    runtime_env = forbidden_names.to_h { |name| [name, "caller-controlled"] }
    runtime_env["RUBYOPT"] = ""
    runtime_env["DYLD_INSERT_LIBRARIES"] = ""
    runtime_env["LD_PRELOAD"] = ""

    result, stderr, status = evaluate_with_runtime_env(input_for, runtime_env, helper: helper)

    assert status.success?, stderr
    assert_equal "accepted", result.fetch("status")
    assert_equal [], JSON.parse(File.read(marker, encoding: "UTF-8"))
  end

  def test_fixed_replay_helper_timeout_nonzero_and_invalid_output_fail_closed
    cases = {
      "timeout" => [
        installed_preflight_with_stage_helper("sleep 10"),
        "stage-dependency-replay-timeout"
      ],
      "nonzero" => [
        installed_preflight_with_stage_helper("exit 23"),
        "stage-dependency-replay-execution-failed"
      ],
      "invalid output" => [
        installed_preflight_with_stage_helper('puts "not-json"'),
        "stage-dependency-replay-output-invalid"
      ]
    }

    cases.each do |label, (helper, expected_code)|
      result, _stderr, status = evaluate(input_for, helper: helper)

      refute status.success?, label
      assert_equal [expected_code], result.fetch("violations").map { |item| item.fetch("code") }, label
      assert_empty result.dig("launch", "eligible_lane_ids"), label
    end
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
      expected_code =
        if label == "writable installation root"
          "stage-dependency-helper-unsafe"
        else
          "lane-lifecycle-receipt-invalid"
        end

      refute status.success?, label
      assert_includes result.fetch("violations").map { |item| item.fetch("code") },
                      expected_code, label
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
