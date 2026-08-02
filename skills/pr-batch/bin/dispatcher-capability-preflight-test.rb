#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "openssl"
require "tmpdir"
require_relative "../../../bin/agent_doctor/signed_launch_waiver"

HELPER = File.expand_path("dispatcher-capability-preflight", __dir__)

class DispatcherCapabilityPreflightTest < Minitest::Test
  class << self
    def dispatcher_signing_key
      @dispatcher_signing_key ||= OpenSSL::PKey::RSA.generate(2048)
    end

    def weak_dispatcher_signing_key
      @weak_dispatcher_signing_key ||= OpenSSL::PKey::RSA.generate(1024)
    end
  end

  def dispatch(input, env_or_helper = {}, helper = HELPER)
    env = env_or_helper.is_a?(Hash) ? env_or_helper : {}
    helper = env_or_helper unless env_or_helper.is_a?(Hash)
    stdout, stderr, status = Open3.capture3(env, helper, stdin_data: JSON.generate(input))
    assert status.success?, "helper failed: #{stderr}"

    JSON.parse(stdout)
  end

  def dispatch_raw(stdin_data)
    stdout, stderr, status = Open3.capture3(HELPER, stdin_data:)
    assert status.success?, "helper failed: #{stderr}"

    JSON.parse(stdout)
  end

  def launch_confirmation(assignment, overrides = {}, signing_key = dispatcher_signing_key)
    confirmation = {
      "type" => "launch-confirmation",
      "version" => 2,
      "id" => "launch-confirmation-v2",
      "assignment" => assignment,
      "actual_model" => assignment.dig("route", "model"),
      "actual_effort" => assignment.dig("route", "effort"),
      "binding_source" => "dispatcher-bound",
      "attestation" => "instance-bound",
      "instance_id" => assignment.fetch("instance_id"),
      "observed_at" => "2026-07-30T00:00:00Z",
      "routing_mode" => "explicit",
      "inherited" => false,
      "evidence_ref" => "dispatcher-receipt://test-launch-observation",
      "key_id" => "test-dispatcher-key"
    }.merge(overrides)
    return confirmation if overrides.key?("signature")

    payload = JSON.generate(canonicalize(launch_observation_payload(confirmation)))
    signature = signing_key.sign(OpenSSL::Digest.new("SHA256"), payload)
    confirmation.merge("signature" => Base64.strict_encode64(signature))
  end

  def dispatcher_signing_key
    self.class.dispatcher_signing_key
  end

  def weak_dispatcher_signing_key
    self.class.weak_dispatcher_signing_key
  end

  def caller_dispatcher_trust_env(key_id: "test-dispatcher-key", key: dispatcher_signing_key)
    {
      "AGENT_WORKFLOW_DISPATCHER_TRUSTED_KEY_ID" => key_id,
      "AGENT_WORKFLOW_DISPATCHER_TRUSTED_PUBLIC_KEY_PEM" => key.public_to_pem
    }
  end

  def installed_dispatcher_helper(key_id: "test-dispatcher-key", key: dispatcher_signing_key,
                                  config_mode: 0o600, agents_mode: 0o700, root_mode: 0o700, config_symlink: false,
                                  agents_symlink: false)
    root = secure_mktmpdir("dispatcher-trust-install")
    File.chmod(root_mode, root)
    (@dispatcher_install_roots ||= []) << root
    helper = File.join(root, "skills/pr-batch/bin/dispatcher-capability-preflight")
    agents_dir = File.join(root, ".agents")
    config_path = File.join(agents_dir, "dispatcher-launch-trust.json")
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
      "type" => "agent-workflow-dispatcher-trust-anchor",
      "version" => 1,
      "agent_workflow_dispatcher_trusted_key_id" => key_id,
      "agent_workflow_dispatcher_trusted_public_key_pem" => key.public_to_pem
    }
    if config_symlink
      target = File.join(root, "caller-substitutable-trust.json")
      File.write(target, JSON.generate(trust_record))
      File.symlink(target, config_path)
    else
      File.write(config_path, JSON.generate(trust_record))
      File.chmod(config_mode, config_path)
    end
    [helper, config_path]
  end

  def fixed_dispatcher_trust(key_id: "test-dispatcher-key", key: dispatcher_signing_key)
    helper, = installed_dispatcher_helper(key_id:, key:)
    helper
  end

  def installed_unsupported_dispatcher_helper
    root = secure_mktmpdir("dispatcher-unsupported-install")
    File.chmod(0o700, root)
    (@dispatcher_install_roots ||= []) << root
    helper = File.join(root, "skills/pr-batch/bin/dispatcher-capability-preflight")
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

  def bootstrap_waiver(root, batch_id:, lane_id:, route:, dispatcher: "codex-collaboration")
    waiver_dir = File.join(root, "waivers")
    FileUtils.mkdir_p(waiver_dir, mode: 0o700)
    path = File.join(waiver_dir, "bootstrap-waiver.json")
    record = {
      "type" => "agent-workflow-bootstrap-waiver",
      "version" => 1,
      "waiver_id" => "#{batch_id}-human-waiver",
      "batch_id" => batch_id,
      "issue" => "shakacode/agent-workflows#299",
      "granted_at" => (Time.now.utc - 60).iso8601,
      "grant_source" => {
        "kind" => "direct-in-session-human-user",
        "thread_id" => "human-thread",
        "exact_message" => "go ahead with the one-time exception for issue #299."
      },
      "authorized_lanes" => [lane_id],
      "authorized_dispatcher" => dispatcher,
      "authorized_route" => route.merge("fallbacks" => []),
      "authorized_exception" => "Use live host-bound route metadata for this exact batch only.",
      "constraints" => {
        "serial_execution" => true,
        "preserve_validation_open_dependency" => true,
        "generated_keys_forbidden" => true,
        "synthetic_signatures_forbidden" => true,
        "inherited_routing_forbidden" => true,
        "fallback_dispatchers_forbidden" => true,
        "scope_expansion_forbidden" => true,
        "other_gate_bypass_forbidden" => true,
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

  def launch_waiver(path:, record:, assignment:, overrides: {})
    observation = {
      "type" => "agent-workflow-waived-host-observation",
      "version" => 1,
      "waiver_id" => record.fetch("waiver_id"),
      "batch_id" => record.fetch("batch_id"),
      "lane_id" => assignment.fetch("lane_id"),
      "dispatcher" => assignment.fetch("dispatcher"),
      "route" => assignment.fetch("route"),
      "instance_id" => assignment.fetch("instance_id"),
      "launch_token" => assignment.fetch("launch_token"),
      "actual_model" => assignment.dig("route", "model"),
      "actual_effort" => assignment.dig("route", "effort"),
      "binding_source" => "dispatcher-bound",
      "attestation" => "instance-bound",
      "observed_at" => Time.now.utc.iso8601,
      "routing_mode" => "explicit",
      "inherited" => false,
      "evidence_ref" => "codex-worker://live-request-metadata"
    }.merge(overrides)
    {
      "type" => "dispatcher-launch-waiver",
      "version" => 1,
      "waiver_ref" => path,
      "waiver_digest" => waiver_digest(record),
      "observation" => observation
    }
  end

  def waiver_digest(record)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(record)))}"
  end

  def dispatcher_trust_env(key_id: "test-dispatcher-key", key: dispatcher_signing_key)
    fixed_dispatcher_trust(key_id:, key:)
  end

  def teardown
    Array(@dispatcher_install_roots).each { |root| FileUtils.remove_entry(root) if File.exist?(root) }
    FileUtils.remove_entry(@secure_fixture_root) if @secure_fixture_root && File.exist?(@secure_fixture_root)
  end

  def secure_mktmpdir(prefix)
    @secure_fixture_root ||= Dir.mktmpdir("dispatcher-preflight-fixtures", __dir__).tap do |root|
      File.chmod(0o700, root)
    end
    Dir.mktmpdir(prefix, @secure_fixture_root).tap { |root| File.chmod(0o700, root) }
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, canonical| canonical[key] = canonicalize(value[key]) }
    when Array
      value.map { |entry| canonicalize(entry) }
    else
      value
    end
  end

  def launch_observation_payload(confirmation)
    assignment = confirmation.fetch("assignment")
    {
      "type" => "dispatcher-launch-observation",
      "version" => 1,
      "confirmation_id" => confirmation["id"],
      "key_id" => confirmation["key_id"],
      "lane_id" => assignment["lane_id"],
      "route" => assignment["route"],
      "dispatcher" => assignment["dispatcher"],
      "instance_id" => confirmation["instance_id"],
      "launch_token" => assignment["launch_token"],
      "actual_model" => confirmation["actual_model"],
      "actual_effort" => confirmation["actual_effort"],
      "binding_source" => confirmation["binding_source"],
      "attestation" => confirmation["attestation"],
      "observed_at" => confirmation["observed_at"],
      "routing_mode" => confirmation["routing_mode"],
      "inherited" => confirmation["inherited"],
      "evidence_ref" => confirmation["evidence_ref"]
    }
  end

  def test_required_route_and_dispatcher_bind_attest_and_resume_once
    output = dispatch(
      "lane_id" => "incident-116",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ],
      "lane_state" => { "claim" => "claim-1", "branch" => "fix/116", "worktree" => "/tmp/116" }
    )

    assert_equal "selected", output.fetch("status")
    assert_equal({ "model" => "Sol", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal "remote", output.fetch("actual_dispatcher")
    assert_equal true, output.fetch("resume_goal")
    assert_equal 1, output.fetch("active_assignments").length
    assert_equal "claim-1", output.dig("lane_state", "claim")
    assert output.dig("dispatch", "launch_token")
  end

  def test_uses_an_explicitly_authorized_ordered_route_fallback
    output = dispatch(
      "lane_id" => "incident-stronger-fallback",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "selected", output.fetch("status")
    assert_equal({ "model" => "Sol", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal "authorized-fallback-bound-and-attested", output.fetch("reason")
  end

  def test_prefers_an_authorized_exact_route_dispatcher_fallback_before_later_route_downgrade
    output = dispatch(
      "lane_id" => "incident-dispatcher-fallback",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "in-process",
          "fallback_authorized" => true,
          "binding" => nil,
          "attestation" => nil
        },
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "remote", output.fetch("actual_dispatcher")
    assert_equal({ "model" => "Sol", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal "authorized-exact-route-dispatcher-fallback", output.fetch("reason")
    assert_equal 1, output.fetch("active_assignments").length
  end

  def test_direct_authorized_fallback_assignment_replays_without_rediscovery
    input = {
      "lane_id" => "incident-direct-fallback-recovery",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => false },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "direct-fallback-instance"
      }]
    }
    selected = dispatch(input)
    pending_assignment = selected.fetch("active_assignments").first
    active_assignment = pending_assignment.merge("lifecycle" => "confirmed-active")

    pending_replay = dispatch(
      input.merge("candidates" => [], "active_assignments" => [pending_assignment])
    )
    active_replay = dispatch(
      input.merge("candidates" => [], "active_assignments" => [active_assignment])
    )

    assert_equal input.fetch("requested"), pending_assignment.fetch("requested")
    assert_equal "top-level-authorized-fallback", pending_assignment.fetch("selection_provenance")
    assert_equal "launch-pending", pending_replay.fetch("status")
    assert_equal pending_assignment.fetch("launch_token"), pending_replay.dig("dispatch", "launch_token")
    assert_equal "replay-already-active", active_replay.fetch("status")
    refute active_replay.key?("dispatch")
  end

  def test_direct_fallback_empty_discovery_revalidates_current_authority_for_pending_and_active
    input = {
      "lane_id" => "incident-direct-fallback-authority-revoked",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => false },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "revoked-authority-instance"
      }]
    }
    selected = dispatch(input)
    pending_assignment = selected.fetch("active_assignments").first
    revoked_input = input.merge(
      "authority" => { "dispatch" => false, "route" => false },
      "candidates" => []
    )
    outputs = [
      dispatch(revoked_input.merge("active_assignments" => [pending_assignment])),
      dispatch(revoked_input.merge("active_assignments" => [pending_assignment.merge("lifecycle" => "confirmed-active")]))
    ]

    outputs.each do |output|
      assert_equal "blocked-replacement-fencing", output.fetch("status")
      assert_equal false, output.fetch("resume_goal")
      refute output.key?("dispatch")
    end
  end

  def test_direct_fallback_empty_discovery_revalidates_route_and_combined_authority
    scenarios = [
      {
        "name" => "route-only",
        "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
        "candidate_route" => { "model" => "Terra", "effort" => "high" },
        "candidate_dispatcher" => "remote",
        "authority" => { "dispatch" => false, "route" => true },
        "revoked" => [{ "dispatch" => false, "route" => false }]
      },
      {
        "name" => "route-and-dispatcher",
        "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "in-process" },
        "candidate_route" => { "model" => "Terra", "effort" => "high" },
        "candidate_dispatcher" => "remote",
        "authority" => { "dispatch" => true, "route" => true },
        "revoked" => [{ "dispatch" => false, "route" => true }, { "dispatch" => true, "route" => false }]
      }
    ]

    scenarios.each do |scenario|
      input = {
        "lane_id" => "incident-#{scenario.fetch('name')}-authority",
        "requested" => scenario.fetch("requested"),
        "authority" => scenario.fetch("authority"),
        "candidates" => [{
          "route" => scenario.fetch("candidate_route"),
          "dispatcher" => scenario.fetch("candidate_dispatcher"),
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "#{scenario.fetch('name')}-instance"
        }]
      }
      selected = dispatch(input)
      pending_assignment = selected.fetch("active_assignments").first
      durable_replay = dispatch(input.merge("candidates" => [], "active_assignments" => [pending_assignment]))
      assert_equal "launch-pending", durable_replay.fetch("status"), scenario.fetch("name")

      scenario.fetch("revoked").each do |revoked_authority|
        %w[launch-pending confirmed-active].each do |lifecycle|
          output = dispatch(
            input.merge(
              "authority" => revoked_authority,
              "candidates" => [],
              "active_assignments" => [pending_assignment.merge("lifecycle" => lifecycle)]
            )
          )
          assert_equal "blocked-replacement-fencing", output.fetch("status"),
                       "#{scenario.fetch('name')} #{revoked_authority.inspect} #{lifecycle}"
          assert_equal false, output.fetch("resume_goal")
          refute output.key?("dispatch")
        end
      end
    end
  end

  def test_direct_fallback_replay_provenance_fails_closed_for_changed_or_malformed_state
    input = {
      "lane_id" => "incident-direct-fallback-guards",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => false },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "guarded-fallback-instance"
      }]
    }
    selected = dispatch(input)
    assignment = selected.fetch("active_assignments").first
    changed_request = dispatch(
      input.merge(
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "in-process" },
        "candidates" => [],
        "active_assignments" => [assignment]
      )
    )
    changed_to_selected_tuple = dispatch(
      input.merge(
        "requested" => { "route" => assignment.fetch("route"), "dispatcher" => assignment.fetch("dispatcher") },
        "candidates" => [],
        "active_assignments" => [assignment]
      )
    )
    unusable_evidence = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("binding" => "UNKNOWN")],
        "active_assignments" => [assignment]
      )
    )
    different_instance = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("instance_id" => "different-instance")],
        "active_assignments" => [assignment]
      )
    )
    missing_fallback_flag = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.reject { |key, _value| key == "fallback_authorized" }],
        "active_assignments" => [assignment]
      )
    )
    false_fallback_flag = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("fallback_authorized" => false)],
        "active_assignments" => [assignment.merge("lifecycle" => "confirmed-active")]
      )
    )
    unknown_fallback_flag = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("fallback_authorized" => "UNKNOWN")],
        "active_assignments" => [assignment]
      )
    )
    legacy_assignment = assignment.reject { |key, _value| %w[requested selection_provenance].include?(key) }
    legacy_replay = dispatch(
      input.merge("candidates" => [], "active_assignments" => [legacy_assignment])
    )
    partial_provenance = assignment.reject { |key, _value| key == "selection_provenance" }
    malformed_replay = dispatch(
      input.merge("candidates" => [], "active_assignments" => [partial_provenance])
    )

    [changed_request, changed_to_selected_tuple, unusable_evidence, different_instance,
     missing_fallback_flag, false_fallback_flag, unknown_fallback_flag, legacy_replay].each do |output|
      assert_equal "blocked-replacement-fencing", output.fetch("status")
      refute output.key?("dispatch")
    end
    assert_equal "invalid-input", malformed_replay.fetch("status")
    assert_equal "active_assignments must contain at most one well-formed persisted assignment",
                 malformed_replay.fetch("reason")
    refute malformed_replay.key?("required_action")
  end

  def test_irrelevant_replacement_key_cannot_bypass_stale_assignment_requested_policy
    input = {
      "lane_id" => "incident-stale-policy-with-replacement-key",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => false },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "stale-policy-instance"
      }]
    }
    selected = dispatch(input)
    pending_assignment = selected.fetch("active_assignments").first
    irrelevant_proof = {
      "type" => "replacement-proof", "version" => 1, "id" => "irrelevant-proof",
      "consumed" => false,
      "prior_assignment" => pending_assignment,
      "replacement_assignment" => pending_assignment.merge(
        "instance_id" => "irrelevant-instance", "launch_token" => "irrelevant-token"
      ),
      "stop_attestation" => "stopped", "reconciliation_attestation" => "reconciled"
    }
    changed_input = input.merge(
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "local" },
      "replacement" => irrelevant_proof
    )
    outputs = [
      dispatch(changed_input.merge("active_assignments" => [pending_assignment])),
      dispatch(changed_input.merge("active_assignments" => [pending_assignment.merge("lifecycle" => "confirmed-active")]))
    ]

    outputs.each do |output|
      assert_equal "blocked-replacement-fencing", output.fetch("status")
      assert_equal false, output.fetch("resume_goal")
      refute output.key?("dispatch")
    end
  end

  def test_assignment_requested_policy_treats_omitted_hard_route_as_false_in_both_replay_paths
    omitted_request = {
      "route" => { "model" => "Sol", "effort" => "high" },
      "dispatcher" => "remote"
    }
    explicit_false_request = {
      "dispatcher" => "remote",
      "route" => { "effort" => "high", "model" => "Sol" },
      "hard_route" => false
    }
    base = {
      "lane_id" => "incident-semantic-assignment-policy",
      "authority" => {},
      "candidates" => [{
        "route" => omitted_request.fetch("route"),
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "semantic-policy-instance"
      }]
    }
    selected_omitted = dispatch(base.merge("requested" => omitted_request))
    selected_false = dispatch(base.merge("requested" => explicit_false_request))
    omitted_assignment = selected_omitted.fetch("active_assignments").first
    irrelevant_proof = {
      "type" => "replacement-proof", "version" => 1, "id" => "semantic-policy-irrelevant-proof",
      "consumed" => false,
      "prior_assignment" => omitted_assignment,
      "replacement_assignment" => omitted_assignment.merge(
        "instance_id" => "semantic-policy-other-instance", "launch_token" => "semantic-policy-other-token"
      ),
      "stop_attestation" => "stopped", "reconciliation_attestation" => "reconciled"
    }

    omitted_to_false = dispatch(
      base.merge(
        "requested" => explicit_false_request,
        "active_assignments" => [omitted_assignment],
        "replacement" => irrelevant_proof
      )
    )
    false_to_omitted = dispatch(
      base.merge(
        "requested" => omitted_request,
        "candidates" => [],
        "active_assignments" => selected_false.fetch("active_assignments")
      )
    )
    true_mismatch = dispatch(
      base.merge(
        "requested" => explicit_false_request.merge("hard_route" => true),
        "candidates" => [],
        "active_assignments" => [omitted_assignment]
      )
    )

    assert_equal "launch-pending", omitted_to_false.fetch("status")
    assert_equal omitted_assignment.fetch("launch_token"), omitted_to_false.dig("dispatch", "launch_token")
    assert_equal "launch-pending", false_to_omitted.fetch("status")
    assert_equal selected_false.dig("dispatch", "launch_token"), false_to_omitted.dig("dispatch", "launch_token")
    assert_equal "blocked-replacement-fencing", true_mismatch.fetch("status")
    refute true_mismatch.key?("dispatch")
  end

  def test_rejects_an_unattested_dispatcher_before_a_later_authorized_candidate
    output = dispatch(
      "lane_id" => "incident-attestation",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "in-process",
          "binding" => "operator-selected",
          "attestation" => nil
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "remote", output.fetch("actual_dispatcher")
    assert_equal [{ "dispatcher" => "in-process", "reason" => "attestation-missing" }], output.fetch("rejections")
  end

  def test_no_authorized_fallback_emits_one_stable_restart_safe_decision_request
    input = {
      "lane_id" => "incident-decision",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Terra", "effort" => "medium" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ],
      "lane_state" => { "branch" => "fix/decision", "generation" => 7 }
    }

    first = dispatch(input)
    replay = dispatch(input)

    assert_equal "blocked-user-input", first.fetch("status")
    assert_equal false, first.fetch("resume_goal")
    assert_equal first.fetch("dispatch_decision_request"), replay.fetch("dispatch_decision_request")
    assert_equal "dispatch-decision-request", first.dig("dispatch_decision_request", "type")
    assert_equal 1, first.dig("dispatch_decision_request", "version")
    assert_equal input.fetch("requested"), first.dig("dispatch_decision_request", "requested")
    assert_equal "Which bound, attested requested tuple or explicitly authorized fallback should dispatch lane incident-decision?",
                 first.dig("dispatch_decision_request", "question")
    assert_equal input.fetch("lane_state"), first.fetch("lane_state")
  end

  def test_persisted_blocker_keeps_canonical_viable_fallback_choices_across_reconstructed_discovery
    input = {
      "lane_id" => "incident-persisted-decision",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "medium" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "fallback-instance"
      }]
    }

    first = dispatch(input)
    replay = dispatch(
      input.merge(
        "candidates" => [],
        "dispatch_decision_request" => first.fetch("dispatch_decision_request")
      )
    )

    assert_equal "blocked-user-input", first.fetch("status")
    choice = first.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    assert_equal({ "model" => "Terra", "effort" => "medium" }, choice.fetch("route"))
    assert_equal "remote", choice.fetch("dispatcher")
    assert_equal "operator-selected", choice.fetch("binding")
    assert_equal "instance-bound", choice.fetch("attestation")
    assert_equal "fallback-instance", choice.fetch("instance_id")
    assert_equal({ "dispatch" => false, "route" => true }, choice.fetch("required_authority"))
    assert_match(/^choice-/, choice.fetch("choice_id"))
    assert_equal first.fetch("dispatch_decision_request"), replay.fetch("dispatch_decision_request")
    assert_equal "dispatch_decision_request", replay.dig("persistence", "record")
    assert_equal false, replay.fetch("resume_goal")
  end

  def test_semantically_identical_requested_key_order_keeps_the_decision_request_id
    input = {
      "lane_id" => "incident-canonical-decision",
      "requested" => {
        "route" => {
          "model" => "Sol",
          "effort" => "high",
          "constraints" => [{ "capacity" => { "minimum" => 1, "maximum" => 2 } }]
        },
        "dispatcher" => "remote"
      },
      "authority" => { "dispatch" => true, "route" => true }
    }
    reordered = {
      "authority" => { "route" => true, "dispatch" => true },
      "requested" => {
        "dispatcher" => "remote",
        "route" => {
          "constraints" => [{ "capacity" => { "maximum" => 2, "minimum" => 1 } }],
          "effort" => "high",
          "model" => "Sol"
        }
      },
      "lane_id" => "incident-canonical-decision"
    }

    assert_equal dispatch(input).dig("dispatch_decision_request", "id"),
                 dispatch(reordered).dig("dispatch_decision_request", "id")
  end

  def test_hard_route_and_missing_explicit_authority_reject_substitution_and_coordinator_inheritance
    output = dispatch(
      "lane_id" => "incident-authority",
      "requested" => {
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "hard_route" => true
      },
      "coordinator_route" => { "model" => "Sol", "effort" => "high" },
      "authority" => { "use_subagents" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "authority must contain only boolean dispatch/route fields", output.fetch("reason")
  end

  def test_hard_route_rejects_a_route_substitution_even_when_the_fallback_is_authorized
    output = dispatch(
      "lane_id" => "incident-hard-route",
      "requested" => {
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "hard_route" => true
      },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal "hard-route-restriction", output.fetch("reason")
  end

  def test_hard_route_does_not_mask_unusable_evidence_as_a_route_restriction
    output = dispatch(
      "lane_id" => "incident-unusable-hard-route-fallback",
      "requested" => {
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "hard_route" => true
      },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "remote",
          "binding" => "unbound",
          "attestation" => "instance-bound",
          "instance_id" => "requested-instance"
        },
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "unbound",
          "attestation" => "instance-bound",
          "instance_id" => "fallback-instance"
        }
      ]
    )

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal "no-authorized-bound-attested-candidate", output.fetch("reason")
    assert_equal [], output.dig("dispatch_decision_request", "viable_fallback_choices")
  end

  def test_round_trips_lane_state_and_replay_uses_one_stable_assignment
    lane_state = {
      "claim" => { "holder" => "worker-7", "generation" => 3 },
      "branch" => "fix/116",
      "worktree" => "/tmp/aw-d-i116",
      "file_map" => ["skills/pr-batch/**"],
      "sanitized_handoff" => { "next" => "verify" },
      "instance" => { "id" => "instance-7" }
    }
    input = {
      "lane_id" => "incident-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }],
      "lane_state" => lane_state
    }

    first = dispatch(input)
    replay = dispatch(input.merge("active_assignments" => first.fetch("active_assignments")))

    assert_equal "active_assignments", first.dig("persistence", "record")
    assert_equal "before-goal-resume-or-worker-launch", first.dig("persistence", "required_before")
    assert_equal "launch-pending", replay.fetch("status")
    assert_equal true, replay.fetch("resume_goal")
    assert_equal first.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal lane_state, replay.fetch("lane_state")
    assert_equal first.fetch("active_assignments"), replay.fetch("active_assignments")
    assert_equal 1, replay.fetch("active_assignments").length
  end

  def test_replay_rejects_a_token_match_with_corrupt_assignment_identity
    input = {
      "lane_id" => "incident-corrupt-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    }
    first = dispatch(input)
    corrupt = first.fetch("active_assignments").first.merge(
      "route" => { "model" => "Terra", "effort" => "low" },
      "dispatcher" => "untrusted",
      "candidate_index" => 99
    ).reject { |key, _value| %w[requested selection_provenance].include?(key) }

    replay = dispatch(input.merge("active_assignments" => [corrupt]))

    assert_equal "blocked-replacement-fencing", replay.fetch("status")
    assert_equal "prior-instance-stop-and-reconciliation-required", replay.fetch("reason")
    assert_equal "stop-and-reconcile-prior-instance", replay.fetch("required_action")
    refute replay.key?("dispatch_decision_request")
    assert_equal [corrupt], replay.fetch("active_assignments")
  end

  def test_replay_rebuilds_the_canonical_assignment_instead_of_returning_persisted_fields
    input = {
      "lane_id" => "incident-canonical-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    }
    first = dispatch(input)
    persisted = first.fetch("active_assignments").first.merge("untrusted_metadata" => "must-not-echo")

    replay = dispatch(input.merge("active_assignments" => [persisted]))

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal first.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal [first.fetch("dispatch")], replay.fetch("active_assignments")
  end

  def test_replay_ignores_candidate_index_but_rebuilds_it_from_current_discovery_order
    input = {
      "lane_id" => "incident-discovery-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "stable-instance"
      }]
    }
    first = dispatch(input)
    shifted_candidates = [{
      "route" => { "model" => "Terra", "effort" => "low" },
      "dispatcher" => "unavailable",
      "binding" => "",
      "attestation" => "",
      "instance_id" => "unusable-instance"
    }] + input.fetch("candidates")

    replay = dispatch(input.merge("candidates" => shifted_candidates, "active_assignments" => first.fetch("active_assignments")))

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal first.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal first.fetch("active_assignments"), replay.fetch("active_assignments")
  end

  def test_semantically_identical_candidate_route_key_order_keeps_the_launch_token
    input = {
      "lane_id" => "incident-canonical-token",
      "requested" => {
        "route" => {
          "model" => "Sol",
          "effort" => "high",
          "constraints" => [{ "capacity" => { "minimum" => 1, "maximum" => 2 } }]
        },
        "dispatcher" => "remote"
      },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => {
          "model" => "Sol",
          "effort" => "high",
          "constraints" => [{ "capacity" => { "minimum" => 1, "maximum" => 2 } }]
        },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    }
    reordered = Marshal.load(Marshal.dump(input))
    reordered["candidates"][0]["route"] = {
      "constraints" => [{ "capacity" => { "maximum" => 2, "minimum" => 1 } }],
      "effort" => "high",
      "model" => "Sol"
    }

    assert_equal dispatch(input).dig("dispatch", "launch_token"),
                 dispatch(reordered).dig("dispatch", "launch_token")
  end

  def test_replacement_requires_stopped_and_reconciled_prior_instance
    output = dispatch(
      "lane_id" => "incident-replacement",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }],
      "active_assignments" => [{ "lane_id" => "incident-replacement", "launch_token" => "dispatch-old" }],
      "replacement" => { "prior_instance_stopped" => false, "reconciled" => false }
    )

    assert_equal "invalid-input", output.fetch("status")
  end

  def test_same_tuple_replacement_is_not_mistaken_for_a_replay
    input = {
      "lane_id" => "incident-same-tuple-replacement",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "worker-original"
      }]
    }
    first = dispatch(input)
    replacement = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("instance_id" => "worker-replacement")],
        "active_assignments" => first.fetch("active_assignments"),
        "replacement" => { "prior_instance_stopped" => false, "reconciled" => false }
      )
    )

    assert_equal "invalid-input", replacement.fetch("status")
  end

  def test_replacement_proof_is_bound_to_the_exact_prior_assignment_and_cannot_be_generic
    input = {
      "lane_id" => "incident-identity-bound-replacement",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "worker-original"
      }]
    }
    first = dispatch(input)
    confirmed = dispatch(
      input.merge(
        "active_assignments" => first.fetch("active_assignments"),
        "launch_confirmation" => launch_confirmation(
          first.fetch("dispatch"),
          "id" => "confirm-replacement-proof-1"
        )
      ),
      dispatcher_trust_env
    )
    replacement_candidate = input.fetch("candidates").map { |candidate| candidate.merge("instance_id" => "worker-new") }

    generic = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => { "prior_instance_stopped" => true, "reconciled" => true }
      )
    )
    fenced = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => confirmed.fetch("active_assignments")
      )
    )
    expected_replacement = fenced.fetch("prospective_replacement_assignment")
    proof = {
      "type" => "replacement-proof",
      "version" => 1,
      "id" => "replacement-proof-1",
      "consumed" => false,
      "prior_assignment" => first.fetch("dispatch"),
      "replacement_assignment" => expected_replacement,
      "stop_attestation" => "stopped",
      "reconciliation_attestation" => "reconciled"
    }
    replaced = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => proof
      )
    )
    tampered_outputs = [
      { "launch_token" => "tampered-token" },
      { "instance_id" => "tampered-instance" }
    ].map do |tampering|
      dispatch(
        input.merge(
          "candidates" => replacement_candidate,
          "active_assignments" => confirmed.fetch("active_assignments"),
          "replacement" => proof.merge(
            "replacement_assignment" => expected_replacement.merge(tampering)
          )
        )
      )
    end
    early_fence = dispatch(
      input.merge(
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
        "candidates" => [],
        "active_assignments" => confirmed.fetch("active_assignments")
      )
    )
    reused = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => first.fetch("active_assignments"),
        "replacement" => proof.merge("consumed" => true)
      )
    )

    assert_equal "invalid-input", generic.fetch("status")
    assert_equal "blocked-replacement-fencing", fenced.fetch("status")
    assert_equal false, fenced.fetch("resume_goal")
    refute fenced.key?("dispatch")
    assert_equal "replacement_fence", fenced.dig("persistence", "record")
    assert_equal "launch-pending", expected_replacement.fetch("lifecycle")
    assert_equal replacement_candidate.first.fetch("instance_id"), expected_replacement.fetch("instance_id")
    assert expected_replacement.fetch("launch_token").start_with?("dispatch-")
    assert_equal "selected", replaced.fetch("status")
    assert_equal expected_replacement, replaced.fetch("dispatch")
    assert_equal "replacement-proof-1", replaced.dig("replacement_transition", "proof_id")
    assert_equal true, replaced.dig("replacement_transition", "consumed")
    tampered_outputs.each do |tampered|
      assert_equal "blocked-replacement-fencing", tampered.fetch("status")
      assert_equal expected_replacement, tampered.fetch("prospective_replacement_assignment")
    end
    assert_equal "blocked-replacement-fencing", early_fence.fetch("status")
    refute early_fence.key?("prospective_replacement_assignment")
    assert_equal "blocked-replacement-fencing", reused.fetch("status")
  end

  def test_replacement_proof_cannot_authorize_a_different_replacement_target_and_is_durably_consumed
    input = {
      "lane_id" => "incident-replacement-target",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "worker-original"
      }]
    }
    first = dispatch(input)
    confirmed = dispatch(
      input.merge(
        "active_assignments" => first.fetch("active_assignments"),
        "launch_confirmation" => launch_confirmation(
          first.fetch("dispatch"),
          "id" => "confirm-replacement-target-1"
        )
      ),
      dispatcher_trust_env
    )
    replacement_candidate = input.fetch("candidates").map { |candidate| candidate.merge("instance_id" => "worker-new") }
    expected_replacement = dispatch(input.merge("candidates" => replacement_candidate)).fetch("dispatch")
    proof = {
      "type" => "replacement-proof",
      "version" => 1,
      "id" => "replacement-proof-target-1",
      "consumed" => false,
      "prior_assignment" => first.fetch("dispatch"),
      "replacement_assignment" => expected_replacement,
      "stop_attestation" => "stopped",
      "reconciliation_attestation" => "reconciled"
    }

    replaced = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => proof
      )
    )
    reused_for_other_target = dispatch(
      input.merge(
        "candidates" => replacement_candidate.map { |candidate| candidate.merge("instance_id" => "worker-other") },
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => proof
      )
    )

    assert_equal "selected", replaced.fetch("status")
    assert_equal "active_assignments-and-replacement-proof-consumption", replaced.dig("persistence", "record")
    assert_equal true, replaced.dig("replacement_transition", "consumed")
    assert_equal expected_replacement, replaced.dig("replacement_transition", "replacement_assignment")
    assert_equal "blocked-replacement-fencing", reused_for_other_target.fetch("status")
  end

  def test_first_viable_authorized_tuple_wins_in_declared_order
    output = dispatch(
      "lane_id" => "incident-ordered",
      "requested" => { "route" => { "model" => "Terra", "effort" => "medium" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "dispatcher-a",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "dispatcher-b",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "dispatcher-a", output.fetch("actual_dispatcher")
    assert_equal 0, output.dig("dispatch", "candidate_index")
  end

  def test_prefers_the_requested_tuple_over_an_earlier_authorized_fallback
    output = dispatch(
      "lane_id" => "incident-requested-priority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal({ "model" => "Terra", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal 1, output.dig("dispatch", "candidate_index")
    assert_equal "requested-tuple-bound-and-attested", output.fetch("reason")
  end

  def test_selects_the_requested_tuple_without_fallback_authority
    output = dispatch(
      "lane_id" => "incident-requested-no-fallback-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => {},
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )

    assert_equal "selected", output.fetch("status")
    assert_equal "requested-tuple-bound-and-attested", output.fetch("reason")
  end

  def test_separates_dispatcher_and_route_fallback_authority
    exact_route_dispatcher_fallback = dispatch(
      "lane_id" => "incident-dispatch-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )
    route_fallback = dispatch(
      "lane_id" => "incident-route-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )
    missing_dispatch_authority = dispatch(
      "lane_id" => "incident-missing-dispatch-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "route" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )

    assert_equal "selected", exact_route_dispatcher_fallback.fetch("status")
    assert_equal "selected", route_fallback.fetch("status")
    assert_equal "blocked-user-input", missing_dispatch_authority.fetch("status")
  end

  def test_rejects_empty_binding_and_attestation_evidence
    output = dispatch(
      "lane_id" => "incident-empty-evidence",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => {},
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "",
        "attestation" => ""
      }]
    )

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal [{ "dispatcher" => "remote", "reason" => "binding-missing" }], output.fetch("rejections")
  end

  def test_rejects_unknown_binding_attestation_and_prospective_instance_evidence
    %w[binding attestation instance_id].each do |field|
      candidate = {
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "prospective-instance"
      }
      candidate[field] = "  uNkNoWn  "

      output = dispatch(
        "lane_id" => "incident-unknown-#{field}",
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
        "authority" => {},
        "candidates" => [candidate]
      )

      assert_equal "blocked-user-input", output.fetch("status")
      assert_equal false, output.fetch("resume_goal")
      assert_equal [{ "dispatcher" => "remote", "reason" => "#{field.tr('_', '-')}-unknown" }],
                   output.fetch("rejections")
    end
  end

  def test_fails_closed_for_unknown_requested_tuple_and_unaccepted_or_negative_evidence
    %w[model effort].each do |field|
      requested = { "model" => "Sol", "effort" => "high" }
      requested[field] = "UNKNOWN"
      output = dispatch(
        "lane_id" => "incident-unknown-requested-#{field}",
        "requested" => { "route" => requested, "dispatcher" => "remote" }
      )

      assert_equal "invalid-input", output.fetch("status")
      assert_equal "requested model, effort, and dispatcher cannot be UNKNOWN", output.fetch("reason")
    end

    unknown_dispatcher = dispatch(
      "lane_id" => "incident-unknown-requested-dispatcher",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "UNKNOWN" }
    )
    evidence = dispatch(
      "lane_id" => "incident-evidence-vocabulary",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "unbound",
        "attestation" => "arbitrary-nonempty-string",
        "instance_id" => "prospective-instance"
      }]
    )

    assert_equal "invalid-input", unknown_dispatcher.fetch("status")
    assert_equal "requested model, effort, and dispatcher cannot be UNKNOWN", unknown_dispatcher.fetch("reason")
    assert_equal "blocked-user-input", evidence.fetch("status")
    assert_equal [{ "dispatcher" => "remote", "reason" => "binding-negative" }], evidence.fetch("rejections")
  end

  def test_identity_bound_operator_decision_resolves_persisted_request_without_erasing_history
    input = {
      "lane_id" => "incident-operator-decision",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "decision-instance"
      }]
    }
    blocked = dispatch(input)
    choice = blocked.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    resolved = dispatch(
      input.merge(
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => {
          "type" => "dispatch-decision",
          "version" => 1,
          "id" => "operator-decision-1",
          "request_id" => blocked.dig("dispatch_decision_request", "id"),
          "lane_id" => input.fetch("lane_id"),
          "choice_id" => choice.fetch("choice_id"),
          "updated_authority" => { "dispatch" => true, "route" => true }
        }
      )
    )

    assert_equal "selected", resolved.fetch("status")
    assert_equal true, resolved.fetch("resume_goal")
    assert_equal blocked.fetch("dispatch_decision_request"), resolved.fetch("dispatch_decision_request")
    assert_equal "operator-decision-1", resolved.dig("decision_resolution", "decision_id")
  end

  def test_identity_bound_refresh_revises_a_zero_choice_hard_route_request_before_later_availability
    input = {
      "lane_id" => "incident-hard-route-refresh",
      "requested" => {
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "hard_route" => true
      },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "wrong-route"
      }]
    }
    blocked = dispatch(input)
    refresh = {
      "type" => "dispatch-decision-refresh",
      "version" => 1,
      "id" => "operator-refresh-1",
      "request_id" => blocked.dig("dispatch_decision_request", "id"),
      "lane_id" => input.fetch("lane_id")
    }
    still_blocked = dispatch(
      input.merge(
        "candidates" => [],
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => refresh
      )
    )
    later_available = dispatch(
      input.merge(
        "candidates" => [{
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "later-exact-instance"
        }],
        "dispatch_decision_request" => still_blocked.fetch("dispatch_decision_request"),
        "operator_decision" => refresh.merge("request_id" => still_blocked.dig("dispatch_decision_request", "id"), "id" => "operator-refresh-2")
      )
    )

    assert_equal "blocked-user-input", blocked.fetch("status")
    assert_empty blocked.dig("dispatch_decision_request", "viable_fallback_choices")
    assert_equal "blocked-user-input", still_blocked.fetch("status")
    assert_equal 2, still_blocked.dig("dispatch_decision_request", "revision")
    assert_equal blocked.fetch("dispatch_decision_request"), still_blocked.dig("dispatch_decision_request", "prior_request")
    assert_equal "selected", later_available.fetch("status")
    assert_equal still_blocked.fetch("dispatch_decision_request"), later_available.fetch("dispatch_decision_request")
    assert_equal "operator-refresh-2", later_available.dig("decision_resolution", "decision_id")
  end

  def test_fresh_dispatch_decision_after_persisted_refresh_resolution_uses_fresh_authority
    input = {
      "lane_id" => "incident-refresh-then-dispatch",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => false, "route" => false },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "refresh-then-dispatch-instance"
      }]
    }
    initial = dispatch(input)
    refresh = {
      "type" => "dispatch-decision-refresh", "version" => 1,
      "id" => "refresh-before-dispatch", "request_id" => initial.dig("dispatch_decision_request", "id"),
      "lane_id" => input.fetch("lane_id")
    }
    refreshed = dispatch(
      input.merge(
        "dispatch_decision_request" => initial.fetch("dispatch_decision_request"),
        "operator_decision" => refresh
      )
    )
    refreshed_request = refreshed.fetch("dispatch_decision_request")
    choice = refreshed_request.fetch("viable_fallback_choices").first
    approval = {
      "type" => "dispatch-decision", "version" => 1, "id" => "dispatch-after-refresh",
      "request_id" => refreshed_request.fetch("id"), "lane_id" => input.fetch("lane_id"),
      "choice_id" => choice.fetch("choice_id"),
      "updated_authority" => { "dispatch" => false, "route" => true }
    }

    selected = dispatch(
      input.merge(
        "dispatch_decision_request" => refreshed_request,
        "decision_resolution" => refreshed.fetch("decision_resolution"),
        "operator_decision" => approval
      )
    )

    assert_equal 2, refreshed_request.fetch("revision")
    assert_equal "dispatch-decision-refresh", refreshed.dig("decision_resolution", "action")
    refute refreshed.fetch("decision_resolution").key?("updated_authority")
    assert_equal "selected", selected.fetch("status")
    assert_equal approval.fetch("updated_authority"), selected.fetch("authority")
    assert_equal choice.fetch("route"), selected.fetch("actual_route")
    assert selected.key?("dispatch")
  end

  def test_persisted_dispatch_resolution_must_target_the_current_request_id_and_revision
    input = {
      "lane_id" => "incident-resolution-revision-binding",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => false, "route" => false },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "revision-binding-instance"
      }]
    }
    initial = dispatch(input)
    request_v1 = initial.fetch("dispatch_decision_request")
    choice_v1 = request_v1.fetch("viable_fallback_choices").first
    approval_v1 = {
      "type" => "dispatch-decision", "version" => 1, "id" => "revision-one-approval",
      "request_id" => request_v1.fetch("id"), "lane_id" => input.fetch("lane_id"),
      "choice_id" => choice_v1.fetch("choice_id"),
      "updated_authority" => { "dispatch" => false, "route" => true }
    }
    approved_v1 = dispatch(
      input.merge("dispatch_decision_request" => request_v1, "operator_decision" => approval_v1)
    )
    refreshed = dispatch(
      input.merge(
        "dispatch_decision_request" => request_v1,
        "operator_decision" => {
          "type" => "dispatch-decision-refresh", "version" => 1, "id" => "revision-two-refresh",
          "request_id" => request_v1.fetch("id"), "lane_id" => input.fetch("lane_id")
        }
      )
    )
    request_v2 = refreshed.fetch("dispatch_decision_request")
    resolution_v1 = approved_v1.fetch("decision_resolution")
    stale_resolutions = [
      resolution_v1,
      resolution_v1.merge("request_id" => request_v2.fetch("id")),
      resolution_v1.merge("request_revision" => request_v2.fetch("revision"))
    ]

    assert_equal 1, request_v1.fetch("revision")
    assert_equal 2, request_v2.fetch("revision")
    assert_equal request_v1, request_v2.fetch("prior_request")
    assert_equal choice_v1.fetch("choice_id"), request_v2.dig("viable_fallback_choices", 0, "choice_id")
    stale_resolutions.each do |resolution|
      output = dispatch(
        input.merge("dispatch_decision_request" => request_v2, "decision_resolution" => resolution)
      )

      assert_equal "invalid-input", output.fetch("status"), resolution.inspect
      assert_equal "decision_resolution must be a well-formed persisted resolution for this request",
                   output.fetch("reason")
      refute output.key?("dispatch")
      refute output.key?("resume_goal")
    end

    approval_v2 = approval_v1.merge(
      "id" => "revision-two-approval",
      "request_id" => request_v2.fetch("id")
    )
    approved_v2 = dispatch(
      input.merge("dispatch_decision_request" => request_v2, "operator_decision" => approval_v2)
    )
    current_replay = dispatch(
      input.merge(
        "dispatch_decision_request" => request_v2,
        "decision_resolution" => approved_v2.fetch("decision_resolution")
      )
    )
    assert_equal "selected", current_replay.fetch("status")
    assert current_replay.key?("dispatch")
  end

  def test_decision_replay_with_active_assignment_preserves_the_request_and_resolution
    input = {
      "lane_id" => "incident-decision-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "decision-replay-instance"
      }]
    }
    blocked = dispatch(input)
    choice = blocked.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    decision = {
      "type" => "dispatch-decision",
      "version" => 1,
      "id" => "operator-decision-replay-1",
      "request_id" => blocked.dig("dispatch_decision_request", "id"),
      "lane_id" => input.fetch("lane_id"),
      "choice_id" => choice.fetch("choice_id"),
      "updated_authority" => { "dispatch" => true, "route" => true }
    }
    selected = dispatch(input.merge("dispatch_decision_request" => blocked.fetch("dispatch_decision_request"), "operator_decision" => decision))
    replay = dispatch(
      input.merge(
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => decision,
        "active_assignments" => selected.fetch("active_assignments")
      )
    )

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal true, replay.fetch("resume_goal")
    assert_equal selected.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal blocked.fetch("dispatch_decision_request"), replay.fetch("dispatch_decision_request")
    assert_equal selected.fetch("decision_resolution"), replay.fetch("decision_resolution")
  end

  def test_launch_pending_replays_the_same_instruction_until_an_identity_bound_confirmation_marks_it_active
    input = {
      "lane_id" => "incident-launch-lifecycle",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "lifecycle-instance"
      }]
    }

    pending = dispatch(input)
    replay_pending = dispatch(input.merge("active_assignments" => pending.fetch("active_assignments")))
    confirmation = launch_confirmation(
      pending.fetch("dispatch"),
      "id" => "launch-confirmation-1"
    )
    confirmed = dispatch(
      input.merge(
        "active_assignments" => replay_pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      dispatcher_trust_env
    )
    assert_equal "replay-already-active", confirmed.fetch("status")
    replay_active = dispatch(
      input.merge(
        "active_assignments" => confirmed.fetch("active_assignments"),
        "launch_confirmation" => confirmed.fetch("launch_confirmation")
      ),
      dispatcher_trust_env
    )

    assert_equal "launch-pending", pending.dig("active_assignments", 0, "lifecycle")
    assert_equal "launch-pending", replay_pending.fetch("status")
    assert_equal pending.fetch("dispatch"), replay_pending.fetch("dispatch")
    assert_equal pending.dig("dispatch", "launch_token"), replay_pending.dig("dispatch", "launch_token")
    assert_equal "confirmed-active", confirmed.dig("active_assignments", 0, "lifecycle")
    assert_equal confirmation, confirmed.fetch("launch_confirmation")
    assert_equal "replay-already-active", replay_active.fetch("status")
    refute replay_active.key?("dispatch")
  end

  def test_exact_human_waiver_activates_and_replays_an_unsupported_host_lane_distinctly
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299",
      "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route,
        "dispatcher" => "codex-collaboration",
        "binding" => "dispatcher-bound",
        "attestation" => "instance-bound",
        "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    waiver = launch_waiver(path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"))

    activated = dispatch(
      input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => waiver),
      helper
    )
    replay = dispatch(
      input.merge("candidates" => [], "active_assignments" => activated.fetch("active_assignments"),
                  "launch_waiver" => activated.fetch("launch_waiver")),
      helper
    )

    assert_equal "replay-already-active", activated.fetch("status")
    assert_equal "waived-active", activated.dig("active_assignments", 0, "lifecycle")
    assert_equal waiver_record.fetch("waiver_id"), activated.dig("active_assignments", 0, "waiver_id")
    assert_equal waiver_path, activated.dig("active_assignments", 0, "waiver_ref")
    assert_equal waiver.fetch("waiver_digest"), activated.dig("active_assignments", 0, "waiver_digest")
    assert_equal "matching-persisted-waived-active-assignment", activated.fetch("reason")
    assert_equal waiver, activated.fetch("launch_waiver")
    assert_equal activated.fetch("active_assignments"), replay.fetch("active_assignments")
    assert_equal "matching-persisted-waived-active-assignment", replay.fetch("reason")
    refute replay.key?("dispatch")
  end

  def test_waived_active_replay_rejects_a_different_waiver_for_the_same_batch_lane_and_route
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299", "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    waiver = launch_waiver(path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"))
    activated = dispatch(
      input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => waiver),
      helper
    )

    replacement_record = JSON.parse(JSON.generate(waiver_record))
    replacement_record["waiver_id"] = "batch-299-replacement-human-waiver"
    replacement_path = File.join(File.dirname(waiver_path), "replacement-bootstrap-waiver.json")
    File.write(replacement_path, JSON.generate(replacement_record))
    File.chmod(0o600, replacement_path)
    replacement = launch_waiver(
      path: replacement_path, record: replacement_record, assignment: activated.dig("active_assignments", 0)
    )
    replay = dispatch(
      input.merge("candidates" => [], "active_assignments" => activated.fetch("active_assignments"),
                  "launch_waiver" => replacement),
      helper
    )

    assert_equal "invalid-input", replay.fetch("status")
    assert_includes replay.fetch("reason"), "same durable launch_waiver"
  end

  def test_waived_active_replay_rejects_mutated_canonical_waiver_content_at_the_same_path
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299", "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    waiver = launch_waiver(path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"))
    activated = dispatch(
      input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => waiver), helper
    )
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
      replay = dispatch(
        input.merge("candidates" => [], "active_assignments" => activated.fetch("active_assignments"),
                    "launch_waiver" => activated.fetch("launch_waiver")),
        helper
      )

      assert_equal "invalid-input", replay.fetch("status"), label
      assert_includes replay.fetch("reason"), "launch_waiver", label
    end
  end

  def test_human_waiver_rejects_cross_batch_lane_route_and_inherited_reuse
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299",
      "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    valid = launch_waiver(path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"))
    variants = {
      "batch" => [input.merge("batch_id" => "another-batch"), valid],
      "lane" => [input, launch_waiver(path: waiver_path, record: waiver_record,
                                      assignment: pending.fetch("dispatch"), overrides: { "lane_id" => "aw299-qa" })],
      "dispatcher" => [input, launch_waiver(path: waiver_path, record: waiver_record,
                                            assignment: pending.fetch("dispatch"), overrides: { "dispatcher" => "remote" })],
      "route" => [input, launch_waiver(path: waiver_path, record: waiver_record,
                                       assignment: pending.fetch("dispatch"), overrides: { "actual_effort" => "high" })],
      "inherited" => [input, launch_waiver(path: waiver_path, record: waiver_record,
                                           assignment: pending.fetch("dispatch"), overrides: { "inherited" => true })]
    }

    variants.each do |label, (variant_input, waiver)|
      output = dispatch(
        variant_input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => waiver),
        helper
      )
      assert_equal "invalid-input", output.fetch("status"), label
      assert_includes output.fetch("reason"), "launch_waiver", label
    end
  end

  def test_human_waiver_requires_the_exact_active_issue
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299",
      "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    waiver = launch_waiver(path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"))

    variants = {
      "cross issue" => input.merge("expected_issue" => "shakacode/agent-workflows#999"),
      "missing issue" => input.reject { |key, _value| key == "expected_issue" },
      "unknown issue" => input.merge("expected_issue" => "UNKNOWN")
    }
    variants.each do |label, variant|
      replay = dispatch(
        variant.merge(
          "active_assignments" => pending.fetch("active_assignments"),
          "launch_waiver" => waiver
        ),
        helper
      )

      assert_equal "invalid-input", replay.fetch("status"), label
      assert_includes replay.fetch("reason"), "issue", label
    end
  end

  def test_human_waiver_rejects_stale_future_pregrant_observations_and_future_grants
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299", "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    now = Time.now.utc
    max_age = AgentDoctor::SignedLaunchWaiver::MAX_OBSERVATION_AGE_SECONDS
    max_future = AgentDoctor::SignedLaunchWaiver::MAX_FUTURE_SKEW_SECONDS
    variants = {
      "stale" => [waiver_record, { "observed_at" => (now - max_age - 5).iso8601 }],
      "too far future" => [waiver_record, { "observed_at" => (now + max_future + 5).iso8601 }],
      "before grant" => [waiver_record, { "observed_at" => (Time.iso8601(waiver_record.fetch("granted_at")) - 1).iso8601 }],
      "future grant" => [waiver_record.merge("granted_at" => (now + 5).iso8601),
                         { "observed_at" => (now + 10).iso8601 }]
    }

    variants.each do |label, (record, overrides)|
      File.write(waiver_path, JSON.generate(record))
      waiver = launch_waiver(path: waiver_path, record:, assignment: pending.fetch("dispatch"), overrides:)
      output = dispatch(
        input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => waiver), helper
      )

      assert_equal "invalid-input", output.fetch("status"), label
      assert_includes output.fetch("reason"), "launch_waiver", label
    end
  end

  def test_waiver_library_defensively_requires_nonempty_assignment_and_observation_runtime_identity
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    batch_id = "batch-299"
    lane_id = "aw299-implementation"
    assignment = {
      "lane_id" => lane_id, "route" => route, "dispatcher" => "codex-collaboration",
      "instance_id" => "live-worker-299", "launch_token" => "launch-token-299"
    }
    waiver_path, waiver_record = bootstrap_waiver(root, batch_id:, lane_id:, route:)
    variants = {
      "assignment instance" => [assignment.merge("instance_id" => ""), {}],
      "assignment token" => [assignment.merge("launch_token" => ""), {}],
      "observation instance" => [assignment, { "instance_id" => "" }],
      "observation token" => [assignment, { "launch_token" => "" }]
    }

    variants.each do |label, (candidate_assignment, overrides)|
      wrapper = launch_waiver(
        path: waiver_path, record: waiver_record, assignment: candidate_assignment, overrides:
      )
      validated, reason = AgentDoctor::SignedLaunchWaiver.validate_dispatcher(
        wrapper:, expected_issue: waiver_record.fetch("issue"), batch_id:, lane_id:,
        assignment: candidate_assignment, host: "codex", target: root, helper_path: helper
      )

      assert_nil validated, label
      assert_includes reason, "observation", label
    end
  end

  def test_human_waiver_evidence_references_use_the_documented_durable_scheme_allowlist
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299", "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    allowed = %w[
      https://example.test/evidence codex-worker://live-request dispatcher-receipt://launch
      plan-state://batch/lane workflow-control-state://batch/lane
      workflow-control-waiver-state://batch/lane codex-worker:live-request
      dispatcher-receipt:launch plan-state:batch/lane workflow-control-state:batch/lane
      workflow-control-waiver-state:batch/lane
    ]
    rejected = %w[
      http://example.test/evidence file:///tmp/evidence https: codex-worker: dispatcher-receipt:
      plan-state: workflow-control-state: workflow-control-waiver-state:
    ]

    allowed.each do |evidence_ref|
      wrapper = launch_waiver(
        path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"), overrides: { "evidence_ref" => evidence_ref }
      )
      output = dispatch(
        input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => wrapper), helper
      )
      assert_equal "replay-already-active", output.fetch("status"), evidence_ref
    end
    rejected.each do |evidence_ref|
      wrapper = launch_waiver(
        path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"), overrides: { "evidence_ref" => evidence_ref }
      )
      output = dispatch(
        input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => wrapper), helper
      )
      assert_equal "invalid-input", output.fetch("status"), evidence_ref
    end
  end

  def test_bootstrap_waiver_merge_authority_uses_the_canonical_allowlist
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299", "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )

    %w[none ask auto_merge_when_gates_pass owner].each do |merge_authority|
      record = JSON.parse(JSON.generate(waiver_record))
      record["constraints"]["merge_authority"] = merge_authority
      File.write(waiver_path, JSON.generate(record))
      wrapper = launch_waiver(path: waiver_path, record:, assignment: pending.fetch("dispatch"))
      output = dispatch(
        input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => wrapper), helper
      )

      expected = merge_authority == "owner" ? "invalid-input" : "replay-already-active"
      assert_equal expected, output.fetch("status"), merge_authority
    end
  end

  def test_human_waiver_rejects_unsafe_file_nonhuman_provenance_and_weakened_constraints
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299", "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )
    wrapper = launch_waiver(path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"))

    mutations = {
      "writable file" => -> { File.chmod(0o666, waiver_path) },
      "nonhuman provenance" => lambda do
        changed = JSON.parse(JSON.generate(waiver_record))
        changed["grant_source"]["kind"] = "coordinator-asserted"
        File.write(waiver_path, JSON.generate(changed))
        File.chmod(0o600, waiver_path)
      end,
      "weakened constraints" => lambda do
        changed = JSON.parse(JSON.generate(waiver_record))
        changed["constraints"]["generated_keys_forbidden"] = false
        File.write(waiver_path, JSON.generate(changed))
        File.chmod(0o600, waiver_path)
      end
    }

    mutations.each do |label, mutation|
      File.write(waiver_path, JSON.generate(waiver_record))
      File.chmod(0o600, waiver_path)
      mutation.call
      output = dispatch(
        input.merge("active_assignments" => pending.fetch("active_assignments"), "launch_waiver" => wrapper),
        helper
      )
      assert_equal "invalid-input", output.fetch("status"), label
      assert_includes output.fetch("reason"), "launch_waiver", label
    end
  end

  def test_waiver_record_rejects_an_unsafe_writable_ancestor_chain
    Dir.mktmpdir("unsafe-waiver-ancestor", "/tmp") do |unsafe_root|
      route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
      waiver_path, = bootstrap_waiver(
        unsafe_root, batch_id: "batch-299", lane_id: "aw299-implementation", route:
      )

      assert_nil AgentDoctor::SignedLaunchWaiverRecord.read(waiver_path, helper_path: HELPER)
    end
  end

  def test_waiver_record_rejects_a_symlink_anywhere_in_its_ancestor_chain
    Dir.mktmpdir("symlinked-waiver-ancestor") do |temporary_root|
      root = File.realpath(temporary_root)
      real_parent = File.join(root, "real/nested")
      FileUtils.mkdir_p(real_parent, mode: 0o700)
      File.symlink("real", File.join(root, "alias"))
      path = File.join(real_parent, "bootstrap-waiver.json")
      File.write(path, "{}")
      File.chmod(0o600, path)
      aliased_path = File.join(root, "alias/nested/bootstrap-waiver.json")

      assert_nil AgentDoctor::SignedLaunchWaiverRecord.read(aliased_path, helper_path: HELPER)
    end
  end

  def test_waiver_record_reads_from_the_single_validated_file_descriptor
    helper, root = installed_unsupported_dispatcher_helper
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: "batch-299", lane_id: "aw299-implementation", route:
    )
    replacement = waiver_record.merge("issue" => "shakacode/agent-workflows#999")
    substitute_path_read = ->(*_args, **_kwargs) { JSON.generate(replacement) }

    original_path_read = File.method(:read)
    File.singleton_class.send(:define_method, :read, substitute_path_read)
    actual = begin
      AgentDoctor::SignedLaunchWaiverRecord.read(waiver_path, helper_path: helper)
    ensure
      File.singleton_class.send(:define_method, :read, original_path_read)
    end

    assert_equal waiver_record, actual
  end

  def test_human_waiver_is_rejected_for_unknown_partial_host_capability
    helper, root = installed_unsupported_dispatcher_helper
    File.write(File.join(root, ".agents/signed-launch-capability.json"), "{}\n")
    route = { "model" => "gpt-5.6-sol", "effort" => "xhigh" }
    input = {
      "batch_id" => "batch-299", "expected_issue" => "shakacode/agent-workflows#299",
      "lane_id" => "aw299-implementation",
      "requested" => { "route" => route, "dispatcher" => "codex-collaboration", "hard_route" => true },
      "candidates" => [{
        "route" => route, "dispatcher" => "codex-collaboration", "binding" => "dispatcher-bound",
        "attestation" => "instance-bound", "instance_id" => "live-worker-299"
      }]
    }
    pending = dispatch(input, helper)
    waiver_path, waiver_record = bootstrap_waiver(
      root, batch_id: input.fetch("batch_id"), lane_id: input.fetch("lane_id"), route:
    )

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_waiver" => launch_waiver(path: waiver_path, record: waiver_record, assignment: pending.fetch("dispatch"))
      ),
      helper
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_includes output.fetch("reason"), "unsupported"
  end

  def test_forged_v2_confirmation_cannot_activate_by_copying_assignment_and_self_declaring_enums
    input = {
      "lane_id" => "incident-forged-launch-confirmation",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "forged-confirmation-instance"
      }]
    }
    pending = dispatch(input)
    forged_confirmation = launch_confirmation(
      pending.fetch("dispatch"),
      "attestation" => "instance-bound",
      "inherited" => false,
      "evidence_ref" => "dispatcher-receipt://forged-confirmation",
      "key_id" => "attacker-key",
      "signature" => "Zm9yZ2Vk"
    )

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => forged_confirmation
      )
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_public_input_cannot_override_fixed_dispatcher_trust
    input = {
      "lane_id" => "incident-public-input-trust-override",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "public-input-trust-instance"
      }]
    }
    pending = dispatch(input)
    trusted_helper = fixed_dispatcher_trust
    trusted_confirmation = launch_confirmation(pending.fetch("dispatch"))
    trusted = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => trusted_confirmation
      ),
      trusted_helper
    )
    assert_equal "replay-already-active", trusted.fetch("status")

    attacker_key = OpenSSL::PKey::RSA.generate(1024)
    forged_confirmation = launch_confirmation(pending.fetch("dispatch"), {}, attacker_key)
    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => forged_confirmation,
        "agent_workflow_dispatcher_trusted_key_id" => "test-dispatcher-key",
        "agent_workflow_dispatcher_trusted_public_key_pem" => attacker_key.public_to_pem,
        "dispatcher_trust_anchor" => {
          "type" => "agent-workflow-dispatcher-trust-anchor",
          "version" => 1,
          "agent_workflow_dispatcher_trusted_key_id" => "test-dispatcher-key",
          "agent_workflow_dispatcher_trusted_public_key_pem" => attacker_key.public_to_pem
        }
      ),
      trusted_helper
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "caller input cannot override dispatcher trust", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_v2_confirmation_rejects_a_symlinked_fixed_trust_config
    input = {
      "lane_id" => "incident-symlinked-trust-config",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "symlinked-trust-config-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(pending.fetch("dispatch"))
    unsafe_helper, = installed_dispatcher_helper(config_symlink: true)

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      {},
      unsafe_helper
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_v2_confirmation_rejects_a_group_or_world_writable_fixed_trust_config
    input = {
      "lane_id" => "incident-writable-trust-config",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "writable-trust-config-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(pending.fetch("dispatch"))
    unsafe_helper, = installed_dispatcher_helper(config_mode: 0o666)

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      {},
      unsafe_helper
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_v2_confirmation_rejects_a_symlinked_trust_config_directory
    input = {
      "lane_id" => "incident-symlinked-trust-directory",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "symlinked-trust-directory-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(pending.fetch("dispatch"))
    unsafe_helper, = installed_dispatcher_helper(agents_symlink: true)

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      {},
      unsafe_helper
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_v2_confirmation_rejects_missing_replaced_or_writable_fixed_trust_configuration
    input = {
      "lane_id" => "incident-untrusted-fixed-config",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "untrusted-fixed-config-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(pending.fetch("dispatch"))

    missing_helper, missing_config = installed_dispatcher_helper
    File.unlink(missing_config)

    replaced_helper, replaced_config = installed_dispatcher_helper
    replaced_record = JSON.parse(File.read(replaced_config))
    replaced_record["agent_workflow_dispatcher_trusted_public_key_pem"] =
      OpenSSL::PKey::RSA.generate(1024).public_to_pem
    File.write(replaced_config, JSON.generate(replaced_record))
    File.chmod(0o600, replaced_config)

    writable_dir_helper, = installed_dispatcher_helper(agents_mode: 0o777)
    writable_root_helper, = installed_dispatcher_helper(root_mode: 0o777)
    unsafe_helpers = {
      "missing config" => missing_helper,
      "replaced key" => replaced_helper,
      "writable config directory" => writable_dir_helper,
      "writable installation root" => writable_root_helper
    }

    unsafe_helpers.each do |label, helper|
      output = dispatch(
        input.merge(
          "active_assignments" => pending.fetch("active_assignments"),
          "launch_confirmation" => confirmation
        ),
        {},
        helper
      )

      assert_equal "invalid-input", output.fetch("status"), label
      assert_equal "launch_confirmation must be a well-formed identity-bound confirmation",
                   output.fetch("reason"), label
      refute output.key?("dispatch"), label
    end
  end

  def test_v2_confirmation_rejects_a_bad_signature_under_the_configured_trust_anchor
    input = {
      "lane_id" => "incident-bad-launch-signature",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "bad-signature-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(
      pending.fetch("dispatch"),
      "attestation" => "instance-bound",
      "inherited" => false,
      "evidence_ref" => "dispatcher-receipt://bad-signature",
      "key_id" => "test-dispatcher-key",
      "signature" => "Zm9yZ2Vk"
    )

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      dispatcher_trust_env
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_v2_confirmation_requires_a_durable_observation_evidence_reference
    input = {
      "lane_id" => "incident-nondurable-evidence-ref",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "nondurable-evidence-ref-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(
      pending.fetch("dispatch"),
      "evidence_ref" => "copied request fields"
    )

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      dispatcher_trust_env
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_v2_confirmation_fails_closed_for_missing_mismatched_or_invalid_trust_anchors
    input = {
      "lane_id" => "incident-invalid-trust-anchor",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "invalid-trust-anchor-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(pending.fetch("dispatch"))
    another_key = OpenSSL::PKey::RSA.generate(1024)
    missing_helper, missing_config = installed_dispatcher_helper
    File.unlink(missing_config)
    malformed_helper, malformed_config = installed_dispatcher_helper
    malformed_record = JSON.parse(File.read(malformed_config))
    malformed_record["agent_workflow_dispatcher_trusted_public_key_pem"] = "not-a-public-key"
    File.write(malformed_config, JSON.generate(malformed_record))
    File.chmod(0o600, malformed_config)
    private_helper, private_config = installed_dispatcher_helper
    private_record = JSON.parse(File.read(private_config))
    private_record["agent_workflow_dispatcher_trusted_public_key_pem"] = dispatcher_signing_key.to_pem
    File.write(private_config, JSON.generate(private_record))
    File.chmod(0o600, private_config)
    trust_anchors = {
      "missing" => missing_helper,
      "wrong key id" => dispatcher_trust_env(key_id: "different-key-id"),
      "wrong public key" => dispatcher_trust_env(key: another_key),
      "malformed public key" => malformed_helper,
      "private key material" => private_helper
    }

    trust_anchors.each do |label, trust_env|
      output = dispatch(
        input.merge(
          "active_assignments" => pending.fetch("active_assignments"),
          "launch_confirmation" => confirmation
        ),
        trust_env
      )

      assert_equal "invalid-input", output.fetch("status"), label
      assert_equal "launch_confirmation must be a well-formed identity-bound confirmation",
                   output.fetch("reason"), label
      refute output.key?("dispatch"), label
    end
  end

  def test_launch_confirmation_fails_closed_without_its_matching_persisted_assignment
    assignment = {
      "lane_id" => "incident-orphan-confirmation",
      "route" => { "model" => "Sol", "effort" => "high" },
      "dispatcher" => "remote",
      "instance_id" => "confirmed-instance",
      "launch_token" => "dispatch-confirmed-instance"
    }
    input = {
      "lane_id" => assignment.fetch("lane_id"),
      "requested" => { "route" => assignment.fetch("route"), "dispatcher" => assignment.fetch("dispatcher") },
      "candidates" => [{
        "route" => assignment.fetch("route"),
        "dispatcher" => assignment.fetch("dispatcher"),
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => assignment.fetch("instance_id")
      }],
      "launch_confirmation" => {
        "type" => "launch-confirmation", "version" => 1, "id" => "orphan-confirmation",
        "assignment" => assignment
      }
    }
    wrong_lane_assignment = assignment.merge(
      "lane_id" => "unrelated-lane",
      "lifecycle" => "launch-pending"
    )

    outputs = {
      "launch_confirmation requires a matching active assignment identity" =>
        dispatch(input.merge("active_assignments" => [])),
      "active_assignments lane_id must match input lane_id" =>
        dispatch(input.merge("active_assignments" => [wrong_lane_assignment]))
    }

    outputs.each do |reason, output|
      assert_equal "invalid-input", output.fetch("status")
      assert_equal reason, output.fetch("reason")
      refute output.key?("dispatch")
      refute output.key?("resume_goal")
    end
  end

  def test_legacy_launch_confirmation_is_parseable_but_cannot_activate_a_pending_assignment
    input = {
      "lane_id" => "incident-legacy-launch-confirmation",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "legacy-confirmation-instance"
      }]
    }
    pending = dispatch(input)
    legacy_confirmation = {
      "type" => "launch-confirmation",
      "version" => 1,
      "id" => "legacy-launch-confirmation",
      "assignment" => pending.fetch("dispatch")
    }

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => legacy_confirmation
      )
    )

    assert_equal "launch-pending", output.fetch("status")
    assert_equal "launch-pending", output.dig("active_assignments", 0, "lifecycle")
    assert_equal pending.fetch("dispatch"), output.fetch("dispatch")
    refute output.key?("launch_confirmation")
  end

  def test_launch_confirmation_requires_a_well_formed_observation_timestamp
    input = {
      "lane_id" => "incident-launch-observation-time",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "observation-time-instance"
      }]
    }
    pending = dispatch(input)

    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => launch_confirmation(
          pending.fetch("dispatch"),
          "observed_at" => "not-a-timestamp"
        )
      ),
      dispatcher_trust_env
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_launch_confirmation_v2_requires_complete_positive_explicit_host_evidence
    input = {
      "lane_id" => "incident-launch-evidence",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "launch-evidence-instance"
      }]
    }
    pending = dispatch(input)
    assignment = pending.fetch("dispatch")
    valid_confirmation = launch_confirmation(assignment)
    malformed_confirmations = {
      "actual model mismatch" => valid_confirmation.merge("actual_model" => "Terra"),
      "actual effort mismatch" => valid_confirmation.merge("actual_effort" => "medium"),
      "request-only operator binding" => valid_confirmation.merge("binding_source" => "operator-selected"),
      "negative binding" => valid_confirmation.merge("binding_source" => "binding-rejected"),
      "dispatcher-only attestation" => valid_confirmation.merge("attestation" => "dispatcher-attested"),
      "negative attestation" => valid_confirmation.merge("attestation" => "attestation-failed"),
      "instance mismatch" => valid_confirmation.merge("instance_id" => "different-instance"),
      "implicit routing" => valid_confirmation.merge("routing_mode" => "implicit"),
      "inherited routing" => valid_confirmation.merge("routing_mode" => "inherited"),
      "inherited flag" => valid_confirmation.merge("inherited" => true),
      "nested unknown" => valid_confirmation.merge(
        "host_metadata" => { "probe" => [{ "result" => "UNKNOWN" }] }
      )
    }
    evidence_fields = %w[
      actual_model actual_effort binding_source attestation instance_id observed_at routing_mode inherited
      evidence_ref key_id signature
    ]
    %w[type version id assignment].concat(evidence_fields).each do |field|
      malformed_confirmations["missing #{field}"] = valid_confirmation.reject { |key, _value| key == field }
    end
    evidence_fields.each do |field|
      malformed_confirmations["unknown #{field}"] = valid_confirmation.merge(field => "UNKNOWN")
    end
    %w[lane_id route dispatcher instance_id launch_token].each do |field|
      malformed_confirmations["malformed assignment missing #{field}"] =
        valid_confirmation.merge("assignment" => assignment.reject { |key, _value| key == field })
    end

    malformed_confirmations.each do |label, confirmation|
      output = dispatch(
        input.merge(
          "active_assignments" => pending.fetch("active_assignments"),
          "launch_confirmation" => confirmation
        ),
        dispatcher_trust_env
      )

      assert_equal "invalid-input", output.fetch("status"), label
      assert_equal "launch_confirmation must be a well-formed identity-bound confirmation",
                   output.fetch("reason"), label
      refute output.key?("dispatch"), label
    end
  end

  def test_launch_confirmation_v2_is_bound_to_every_persisted_assignment_identity_field
    input = {
      "lane_id" => "incident-confirmation-identity",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "identity-instance"
      }]
    }
    pending = dispatch(input)
    assignment = pending.fetch("dispatch")
    stale_assignments = {
      "lane" => assignment.merge("lane_id" => "stale-lane"),
      "route" => assignment.merge("route" => { "model" => "Terra", "effort" => "high" }),
      "dispatcher" => assignment.merge("dispatcher" => "local"),
      "instance" => assignment.merge("instance_id" => "stale-instance"),
      "launch token" => assignment.merge("launch_token" => "stale-launch-token")
    }

    stale_assignments.each do |label, stale_assignment|
      output = dispatch(
        input.merge(
          "active_assignments" => pending.fetch("active_assignments"),
          "launch_confirmation" => launch_confirmation(stale_assignment)
        ),
        dispatcher_trust_env
      )

      assert_equal "invalid-input", output.fetch("status"), label
      assert_equal "launch_confirmation requires a matching active assignment identity",
                   output.fetch("reason"), label
      refute output.key?("dispatch"), label
    end
  end

  def test_launch_confirmation_v2_accepts_signed_dispatcher_bound_instance_bound_runtime_evidence
    input = {
      "lane_id" => "incident-positive-runtime-observation",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "positive-runtime-observation-instance"
      }]
    }
    pending = dispatch(input)
    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => launch_confirmation(pending.fetch("dispatch"))
      ),
      dispatcher_trust_env
    )

    assert_equal "replay-already-active", output.fetch("status")
    assert_equal "confirmed-active", output.dig("active_assignments", 0, "lifecycle")
    refute output.key?("dispatch")
  end

  def test_launch_confirmation_v2_rejects_an_rsa_1024_trust_anchor
    input = {
      "lane_id" => "incident-weak-runtime-observation-key",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "weak-runtime-observation-key-instance"
      }]
    }
    pending = dispatch(input)
    weak_key = weak_dispatcher_signing_key
    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => launch_confirmation(pending.fetch("dispatch"), {}, weak_key)
      ),
      fixed_dispatcher_trust(key: weak_key)
    )

    assert_equal "invalid-input", output.fetch("status")
    refute(Array(output["active_assignments"]).any? do |assignment|
      assignment["lifecycle"] == "confirmed-active"
    end)
    refute output.key?("dispatch")
  end

  def test_checker_lane_effort_must_match_the_selected_route_exactly
    input = {
      "lane_id" => "checker-launch-evidence",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "checker-instance"
      }]
    }
    pending = dispatch(input)
    output = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => launch_confirmation(
          pending.fetch("dispatch"),
          "actual_effort" => "medium"
        )
      ),
      dispatcher_trust_env
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "launch_confirmation must be a well-formed identity-bound confirmation", output.fetch("reason")
    refute output.key?("dispatch")
  end

  def test_legacy_launch_confirmation_remains_parseable_for_confirmed_history
    input = {
      "lane_id" => "incident-legacy-confirmed-history",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "legacy-history-instance"
      }]
    }
    pending = dispatch(input)
    confirmed = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => launch_confirmation(pending.fetch("dispatch"))
      ),
      dispatcher_trust_env
    )
    legacy_confirmation = {
      "type" => "launch-confirmation",
      "version" => 1,
      "id" => "legacy-history-confirmation",
      "assignment" => confirmed.fetch("active_assignments").first
    }

    replay = dispatch(
      input.merge(
        "candidates" => [],
        "active_assignments" => confirmed.fetch("active_assignments"),
        "launch_confirmation" => legacy_confirmation
      )
    )

    assert_equal "replay-already-active", replay.fetch("status")
    assert_equal "confirmed-active", replay.dig("active_assignments", 0, "lifecycle")
    assert_equal legacy_confirmation, replay.fetch("launch_confirmation")
    refute replay.key?("dispatch")
  end

  def test_launch_pending_does_not_bypass_replacement_fencing_after_the_requested_identity_changes
    input = {
      "lane_id" => "incident-pending-route-change",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote", "binding" => "operator-selected",
        "attestation" => "instance-bound", "instance_id" => "pending-old"
      }]
    }
    pending = dispatch(input)
    changed = dispatch(
      input.merge(
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" },
                         "dispatcher" => "remote", "hard_route" => true },
        "candidates" => [],
        "active_assignments" => pending.fetch("active_assignments")
      )
    )

    assert_equal "blocked-replacement-fencing", changed.fetch("status")
    assert_equal pending.fetch("active_assignments"), changed.fetch("active_assignments")
  end

  def test_changed_requested_identity_fences_when_discovery_still_lists_the_old_assignment
    input = {
      "lane_id" => "incident-stale-candidate-after-route-change",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote", "binding" => "operator-selected",
        "attestation" => "instance-bound", "instance_id" => "old-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(
      pending.fetch("dispatch"),
      "id" => "old-instance-confirmation"
    )
    active = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      dispatcher_trust_env
    )
    changed_request = {
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" },
                       "dispatcher" => "remote", "hard_route" => true },
      "candidates" => input.fetch("candidates")
    }

    pending_change = dispatch(input.merge(changed_request,
                                          "active_assignments" => pending.fetch("active_assignments")))
    active_change = dispatch(input.merge(changed_request,
                                         "active_assignments" => active.fetch("active_assignments")))

    assert_equal "blocked-replacement-fencing", pending_change.fetch("status")
    assert_equal "blocked-replacement-fencing", active_change.fetch("status")
  end

  def test_confirmed_active_replays_without_requiring_fresh_discovery
    input = {
      "lane_id" => "incident-active-empty-discovery",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote", "binding" => "operator-selected",
        "attestation" => "instance-bound", "instance_id" => "active-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = launch_confirmation(
      pending.fetch("dispatch"),
      "id" => "active-confirmation"
    )
    active = dispatch(
      input.merge(
        "active_assignments" => pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      ),
      dispatcher_trust_env
    )
    replay = dispatch(input.merge("candidates" => [], "active_assignments" => active.fetch("active_assignments")))
    changed = dispatch(
      input.merge(
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" },
                         "dispatcher" => "remote", "hard_route" => true },
        "candidates" => [],
        "active_assignments" => active.fetch("active_assignments")
      )
    )

    assert_equal "replay-already-active", replay.fetch("status")
    refute replay.key?("dispatch")
    assert_equal "blocked-replacement-fencing", changed.fetch("status")
  end

  def test_pending_replay_fences_changed_or_unusable_current_candidate_evidence
    input = {
      "lane_id" => "incident-pending-candidate-revalidation",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote", "binding" => "operator-selected",
        "attestation" => "instance-bound", "instance_id" => "stable-instance"
      }]
    }
    pending = dispatch(input)
    changed_instance = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("instance_id" => "different-instance")],
        "active_assignments" => pending.fetch("active_assignments")
      )
    )
    unknown_evidence = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("binding" => "UNKNOWN")],
        "active_assignments" => pending.fetch("active_assignments")
      )
    )

    assert_equal "blocked-replacement-fencing", changed_instance.fetch("status")
    assert_equal "blocked-replacement-fencing", unknown_evidence.fetch("status")
  end

  def test_cross_lane_replacement_state_is_invalid_before_replacement_fencing
    input = {
      "lane_id" => "incident-current-lane",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "replacement-instance"
      }],
      "active_assignments" => [{
        "lane_id" => "other-lane",
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "instance_id" => "prior-instance",
        "launch_token" => "dispatch-prior",
        "lifecycle" => "confirmed-active"
      }],
      "replacement" => {
        "type" => "replacement-proof",
        "version" => 1,
        "id" => "cross-lane-proof",
        "consumed" => false,
        "stop_attestation" => "stopped",
        "reconciliation_attestation" => "reconciled",
        "prior_assignment" => {
          "lane_id" => "other-lane",
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "instance_id" => "prior-instance",
          "launch_token" => "dispatch-prior"
        },
        "replacement_assignment" => {
          "lane_id" => "other-lane",
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "instance_id" => "replacement-instance",
          "launch_token" => "dispatch-irrelevant"
        }
      }
    }
    seed_input = input.dup
    seed_input.delete("active_assignments")
    seed_input.delete("replacement")
    input.fetch("replacement")["replacement_assignment"] = dispatch(seed_input).fetch("dispatch")

    output = dispatch(input)

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "active_assignments lane_id must match input lane_id", output.fetch("reason")
    refute output.key?("required_action")
  end

  def test_cross_lane_active_assignment_is_invalid_instead_of_fencing_an_unrelated_instance
    output = dispatch(
      "lane_id" => "incident-current-lane-state",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "current-lane-instance"
      }],
      "active_assignments" => [{
        "lane_id" => "unrelated-lane",
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "instance_id" => "unrelated-instance",
        "launch_token" => "dispatch-unrelated-instance",
        "lifecycle" => "confirmed-active"
      }]
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "active_assignments lane_id must match input lane_id", output.fetch("reason")
    refute output.key?("required_action")
  end

  def test_persisted_decision_resolution_replays_without_a_transient_operator_decision
    input = {
      "lane_id" => "incident-resolution-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "resolution-instance"
      }]
    }
    blocked = dispatch(input)
    choice = blocked.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    selected = dispatch(
      input.merge(
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => {
          "type" => "dispatch-decision",
          "version" => 1,
          "id" => "resolution-decision",
          "request_id" => blocked.dig("dispatch_decision_request", "id"),
          "lane_id" => input.fetch("lane_id"),
          "choice_id" => choice.fetch("choice_id"),
          "updated_authority" => { "dispatch" => true, "route" => true }
        }
      )
    )
    replay = dispatch(
      input.merge(
        "dispatch_decision_request" => selected.fetch("dispatch_decision_request"),
        "decision_resolution" => selected.fetch("decision_resolution"),
        "active_assignments" => selected.fetch("active_assignments")
      )
    )

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal selected.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal selected.fetch("decision_resolution"), replay.fetch("decision_resolution")
  end

  def test_persisted_resolution_rejects_a_stale_requested_tuple_before_selecting_the_old_choice
    input = {
      "lane_id" => "incident-stale-resolution-request",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "stale-resolution-instance"
      }]
    }
    blocked = dispatch(input)
    choice = blocked.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    selected = dispatch(
      input.merge(
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => {
          "type" => "dispatch-decision", "version" => 1, "id" => "stale-resolution-decision",
          "request_id" => blocked.dig("dispatch_decision_request", "id"),
          "lane_id" => input.fetch("lane_id"),
          "choice_id" => choice.fetch("choice_id"),
          "updated_authority" => { "dispatch" => true, "route" => true }
        }
      )
    )
    persisted_state = {
      "dispatch_decision_request" => selected.fetch("dispatch_decision_request"),
      "decision_resolution" => selected.fetch("decision_resolution")
    }
    changed_requests = [
      { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "local" },
      { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote", "hard_route" => true }
    ]

    changed_requests.each do |changed_request|
      output = dispatch(input.merge(persisted_state, "requested" => changed_request))

      assert_equal "invalid-input", output.fetch("status"), changed_request.inspect
      assert_equal "dispatch_decision_request requested tuple must match current requested tuple; refresh persisted decision state",
                   output.fetch("reason")
      refute output.key?("dispatch")
      refute output.key?("resume_goal")
    end

    reordered_request = {
      "dispatcher" => "remote",
      "route" => { "effort" => "high", "model" => "Sol" }
    }
    unchanged = dispatch(input.merge(persisted_state, "requested" => reordered_request))
    assert_equal "selected", unchanged.fetch("status")
    assert_equal selected.fetch("dispatch"), unchanged.fetch("dispatch")
  end

  def test_persisted_decision_requested_policy_treats_omitted_hard_route_as_false
    omitted_request = {
      "route" => { "model" => "Sol", "effort" => "high" },
      "dispatcher" => "remote"
    }
    explicit_false_request = {
      "dispatcher" => "remote",
      "route" => { "effort" => "high", "model" => "Sol" },
      "hard_route" => false
    }
    base = { "lane_id" => "incident-semantic-request-policy", "authority" => {}, "candidates" => [] }
    omitted = dispatch(base.merge("requested" => omitted_request))
    explicit_false = dispatch(base.merge("requested" => explicit_false_request))

    omitted_to_false = dispatch(
      base.merge(
        "requested" => explicit_false_request,
        "dispatch_decision_request" => omitted.fetch("dispatch_decision_request")
      )
    )
    false_to_omitted = dispatch(
      base.merge(
        "requested" => omitted_request,
        "dispatch_decision_request" => explicit_false.fetch("dispatch_decision_request")
      )
    )
    true_mismatch = dispatch(
      base.merge(
        "requested" => explicit_false_request.merge("hard_route" => true),
        "dispatch_decision_request" => omitted.fetch("dispatch_decision_request")
      )
    )

    assert_equal "blocked-user-input", omitted_to_false.fetch("status")
    assert_equal omitted.fetch("dispatch_decision_request"), omitted_to_false.fetch("dispatch_decision_request")
    assert_equal "blocked-user-input", false_to_omitted.fetch("status")
    assert_equal explicit_false.fetch("dispatch_decision_request"), false_to_omitted.fetch("dispatch_decision_request")
    assert_equal "invalid-input", true_mismatch.fetch("status")
  end

  def test_present_malformed_decision_resolution_values_return_structured_invalid_input
    input = {
      "lane_id" => "incident-malformed-resolution-shape",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "malformed-resolution-instance"
      }]
    }
    blocked = dispatch(input)

    [false, nil, true, 0, "not-a-resolution", [], {}].each do |malformed_resolution|
      output = dispatch(
        input.merge(
          "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
          "decision_resolution" => malformed_resolution
        )
      )

      assert_equal "invalid-input", output.fetch("status"), malformed_resolution.inspect
      assert_equal "decision_resolution must be a well-formed persisted resolution for this request",
                   output.fetch("reason")
    end
  end

  def test_deeply_malformed_persisted_state_is_invalid_input_instead_of_an_exception
    base = {
      "lane_id" => "incident-invalid-persisted-state",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => []
    }
    malformed_inputs = [
      base.merge("active_assignments" => [{ "lane_id" => "incident-invalid-persisted-state" }]),
      base.merge("active_assignments" => [{
                   "lane_id" => "incident-invalid-persisted-state",
                   "route" => { "model" => "Sol", "effort" => "high" },
                   "dispatcher" => "remote", "instance_id" => "UNKNOWN",
                   "launch_token" => "dispatch-token", "lifecycle" => "launch-pending"
                 }]),
      base.merge("replacement" => { "type" => "replacement-proof", "prior_assignment" => [] }),
      base.merge("launch_confirmation" => []),
      base.merge("dispatch_decision_request" => true),
      base.merge("dispatch_decision_request" => "not-a-request"),
      base.merge("dispatch_decision_request" => {
                   "type" => "dispatch-decision-request", "version" => 1,
                   "id" => "orphan-revision", "revision" => 2,
                   "lane_id" => "incident-invalid-persisted-state",
                   "requested" => base.fetch("requested"), "authority" => {},
                   "reason" => "bad", "question" => "bad", "viable_fallback_choices" => []
                 }),
      base.merge("dispatch_decision_request" => {
                   "type" => "dispatch-decision-request", "version" => 1,
                   "id" => "bad-request", "revision" => 1,
                   "lane_id" => "incident-invalid-persisted-state",
                   "requested" => base.fetch("requested"), "authority" => {},
                   "reason" => "bad", "question" => "bad",
                   "viable_fallback_choices" => [{ "choice_id" => [] }]
                 }),
      base.merge("dispatch_decision_request" => {
                   "type" => "dispatch-decision-request", "version" => 1,
                   "id" => "bad-history", "revision" => 2,
                   "lane_id" => "incident-invalid-persisted-state",
                   "requested" => base.fetch("requested"), "authority" => {},
                   "reason" => "bad", "question" => "bad", "viable_fallback_choices" => [],
                   "prior_request" => { "revision" => "one" }
                 }, "decision_resolution" => [])
    ]

    malformed_inputs.each do |input|
      output = dispatch(input)
      assert_equal "invalid-input", output.fetch("status"), input.inspect
    end
  end

  def test_malformed_json_returns_structured_invalid_input
    output = dispatch_raw("{not-json")

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "malformed-json", output.fetch("reason")
  end

  def test_rejects_a_candidate_without_explicit_instance_identity
    output = dispatch(
      "lane_id" => "incident-missing-instance-identity",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => {},
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound"
      }]
    )

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal [{ "dispatcher" => "remote", "reason" => "instance-identity-missing" }], output.fetch("rejections")
  end

  def test_rejects_malformed_top_level_authority_shape
    output = dispatch(
      "lane_id" => "incident-invalid-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => [true],
      "candidates" => []
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "authority must contain only boolean dispatch/route fields", output.fetch("reason")
  end

  def test_rejects_unknown_or_non_boolean_authority_fields_before_persisting_a_request
    [{ "use_subagents" => true }, { "dispatch" => "yes" }].each do |authority|
      output = dispatch(
        "lane_id" => "incident-invalid-authority-fields",
        "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
        "authority" => authority,
        "candidates" => []
      )

      assert_equal "invalid-input", output.fetch("status")
      assert_equal "authority must contain only boolean dispatch/route fields", output.fetch("reason")
    end
  end
end
