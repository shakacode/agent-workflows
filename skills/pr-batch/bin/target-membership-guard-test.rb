#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

class TargetMembershipGuardTest < Minitest::Test
  HELPER = File.expand_path("target-membership-guard", __dir__)
  ROOT = File.expand_path("../../..", __dir__)
  CONTROL_OPERATIONS = %w[
    claim supersede replacement worker_spawn dispatch ownership
    heartbeat_mutation lease_mutation resource_lock_handoff
    repository_mutation github_mutation
  ].freeze

  def invoke(overrides = {})
    input = {
      "contract" => "target-membership-request",
      "version" => 1,
      "canonical_target_manifest" => ["shakacode/agent-workflows#403"],
      "target" => "shakacode/agent-workflows#403",
      "operation" => "dispatch",
      "human_authorized_control_transfer" => false
    }.merge(overrides)

    stdout, stderr, status = Open3.capture3(HELPER, stdin_data: JSON.generate(input))
    [JSON.parse(stdout), stderr, status]
  end

  def invoke_raw(input)
    stdout, stderr, status = Open3.capture3(HELPER, stdin_data: input)
    [JSON.parse(stdout), stderr, status]
  end

  def test_allows_control_for_an_exact_manifest_member
    result, stderr, status = invoke

    assert_predicate status, :success?, stderr
    assert_equal "allowed", result.fetch("status")
    assert_equal "manifest-member", result.fetch("disposition")
    assert_equal true, result.fetch("target_membership")
    assert_equal true, result.fetch("control_allowed")
    assert_equal true, result.fetch("evidence_delivery_allowed")
  end

  def test_duplicate_json_keys_fail_closed_at_every_contract_field
    pairs = [
      ["contract", "target-membership-request"],
      ["version", 1],
      ["canonical_target_manifest", ["shakacode/agent-workflows#403"]],
      ["target", "shakacode/agent-workflows#403"],
      ["operation", "dispatch"],
      ["human_authorized_control_transfer", false]
    ]

    pairs.each do |duplicate_key, duplicate_value|
      duplicated_pairs = pairs + [[duplicate_key, duplicate_value]]
      input = "{#{duplicated_pairs.map { |key, value| "#{JSON.generate(key)}:#{JSON.generate(value)}" }.join(',')}}"

      result, stderr, status = invoke_raw(input)

      assert_equal 2, status.exitstatus, "#{duplicate_key}: #{stderr}"
      assert_equal "UNKNOWN", result.fetch("status"), duplicate_key
      assert_equal false, result.fetch("control_allowed"), duplicate_key
      assert_equal false, result.fetch("evidence_delivery_allowed"), duplicate_key
      assert_equal "input contains duplicate JSON object key: #{duplicate_key}", result.fetch("reason"), duplicate_key
    end
  end

  def test_duplicate_json_key_in_nested_object_also_fails_closed
    input = <<~JSON.delete("\n")
      {
        "contract":"target-membership-request",
        "version":1,
        "canonical_target_manifest":["shakacode/agent-workflows#403"],
        "target":"shakacode/agent-workflows#403",
        "operation":"dispatch",
        "human_authorized_control_transfer":false,
        "metadata":{"replay":1,"replay":1}
      }
    JSON

    result, stderr, status = invoke_raw(input)

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal false, result.fetch("control_allowed")
    assert_equal false, result.fetch("evidence_delivery_allowed")
    assert_equal "input contains duplicate JSON object key: replay", result.fetch("reason")
  end

  def test_escaped_and_literal_duplicate_json_keys_are_equivalent
    input = <<~JSON.delete("\n")
      {
        "contract":"target-membership-request",
        "version":1,
        "canonical_target_manifest":["shakacode/agent-workflows#403"],
        "target":"shakacode/agent-workflows#403",
        "operation":"dispatch",
        "human_authorized_control_transfer":false,
        "metadata":{"target":1,"\\u0074arget":2}
      }
    JSON

    result, stderr, status = invoke_raw(input)

    assert_equal 2, status.exitstatus, stderr
    assert_equal "input contains duplicate JSON object key: target", result.fetch("reason")
    assert_equal false, result.fetch("control_allowed")
    assert_equal false, result.fetch("evidence_delivery_allowed")
  end

  def test_duplicate_json_key_replay_is_byte_for_byte_deterministic
    input = '{"contract":"target-membership-request","contract":"target-membership-request"}'

    first_stdout, first_stderr, first_status = Open3.capture3(HELPER, stdin_data: input)
    second_stdout, second_stderr, second_status = Open3.capture3(HELPER, stdin_data: input)

    assert_equal 2, first_status.exitstatus, first_stderr
    assert_equal first_status.exitstatus, second_status.exitstatus, second_stderr
    assert_equal first_stdout, second_stdout
  end

  def test_blocks_control_for_a_foreign_target_as_evidence_only
    result, stderr, status = invoke("target" => "shakacode/hichee#9992")

    assert_equal 3, status.exitstatus, stderr
    assert_equal "blocked", result.fetch("status")
    assert_equal "foreign-target / evidence-only", result.fetch("disposition")
    assert_equal "dispatch", result.fetch("operation")
    assert_equal false, result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal true, result.fetch("evidence_delivery_allowed")
    assert_equal "route evidence to the exact target-bound task or obtain an explicit human-authorized control transfer to a task already bound to that target",
                 result.fetch("next_action")
  end

  def test_allows_foreign_target_evidence_delivery_without_control
    result, stderr, status = invoke(
      "target" => "shakacode/hichee#9992",
      "operation" => "evidence_delivery"
    )

    assert_predicate status, :success?, stderr
    assert_equal "allowed", result.fetch("status")
    assert_equal "foreign-target / evidence-only", result.fetch("disposition")
    assert_equal false, result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal true, result.fetch("evidence_delivery_allowed")
  end

  def test_manifest_member_evidence_delivery_remains_evidence_only
    result, stderr, status = invoke("operation" => "evidence_delivery")

    assert_predicate status, :success?, stderr
    assert_equal "allowed", result.fetch("status")
    assert_equal "manifest-member / evidence-only", result.fetch("disposition")
    assert_equal true, result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal true, result.fetch("evidence_delivery_allowed")
  end

  def test_denies_control_transfer_without_explicit_human_authority
    result, stderr, status = invoke("operation" => "control_transfer")

    assert_equal 3, status.exitstatus, stderr
    assert_equal "blocked", result.fetch("status")
    assert_equal "control-transfer-authority-required", result.fetch("disposition")
    assert_equal true, result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal true, result.fetch("evidence_delivery_allowed")
  end

  def test_allows_explicit_human_authorized_transfer_to_target_bound_task
    result, stderr, status = invoke(
      "operation" => "control_transfer",
      "human_authorized_control_transfer" => true
    )

    assert_predicate status, :success?, stderr
    assert_equal "allowed", result.fetch("status")
    assert_equal "control-transfer-authorized", result.fetch("disposition")
    assert_equal true, result.fetch("target_membership")
    assert_equal true, result.fetch("human_authorized_control_transfer")
    assert_equal true, result.fetch("control_allowed")
  end

  def test_missing_target_returns_structured_unknown_and_blocks_work
    result, stderr, status = invoke("target" => nil)

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("disposition")
    assert_equal "UNKNOWN", result.fetch("target")
    assert_equal "UNKNOWN", result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal false, result.fetch("evidence_delivery_allowed")
  end

  def test_synthetic_target_returns_structured_unknown
    result, stderr, status = invoke("target" => "adhoc:20260811-foreign")

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("target_membership")
    assert_equal "synthetic targets cannot establish cross-task membership",
                 result.fetch("reason")
    assert_equal false, result.fetch("control_allowed")
  end

  def test_punctuation_only_target_segments_return_structured_unknown
    %w[-/-#1 _/_#1 ./..#1].each do |malformed_target|
      result, stderr, status = invoke("target" => malformed_target)

      assert_equal 2, status.exitstatus, "#{malformed_target}: #{stderr}"
      assert_equal "UNKNOWN", result.fetch("status"), malformed_target
      assert_equal "UNKNOWN", result.fetch("target_membership"), malformed_target
      assert_equal false, result.fetch("control_allowed"), malformed_target
      assert_equal false, result.fetch("evidence_delivery_allowed"), malformed_target
    end
  end

  def test_punctuation_only_manifest_segment_returns_structured_unknown
    result, stderr, status = invoke("canonical_target_manifest" => ["-/-#1"])

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal false, result.fetch("evidence_delivery_allowed")
  end

  def test_punctuated_repository_identity_remains_valid_and_case_normalized
    result, stderr, status = invoke(
      "canonical_target_manifest" => ["shaka-code/.agent_workflows-guard#403"],
      "target" => "Shaka-Code/.Agent_Workflows-Guard#403"
    )

    assert_predicate status, :success?, stderr
    assert_equal "allowed", result.fetch("status")
    assert_equal true, result.fetch("target_membership")
    assert_equal true, result.fetch("control_allowed")
  end

  def test_literal_unknown_target_stays_unknown_and_blocks_work
    result, stderr, status = invoke("target" => "UNKNOWN")

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("target")
    assert_equal "literal UNKNOWN is not a target identity", result.fetch("reason")
    assert_equal false, result.fetch("control_allowed")
  end

  def test_ambiguous_target_list_returns_structured_unknown
    result, stderr, status = invoke(
      "target" => ["shakacode/agent-workflows#403", "shakacode/hichee#9992"]
    )

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("target_membership")
    assert_equal "ambiguous target identity; expected one scalar repository-qualified issue/PR",
                 result.fetch("reason")
    assert_equal false, result.fetch("control_allowed")
  end

  def test_unknown_operation_fails_closed
    result, stderr, status = invoke("operation" => "take_over_everything")

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("disposition")
    assert_equal false, result.fetch("control_allowed")
    assert_equal "operation is missing or unsupported", result.fetch("reason")
  end

  def test_missing_manifest_fails_closed_as_unknown
    result, stderr, status = invoke("canonical_target_manifest" => nil)

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal "canonical target manifest is missing, empty, or invalid", result.fetch("reason")
  end

  def test_every_control_boundary_uses_the_same_membership_decision
    CONTROL_OPERATIONS.each do |operation|
      result, stderr, status = invoke("operation" => operation)

      assert_predicate status, :success?, "#{operation}: #{stderr}"
      assert_equal operation, result.fetch("operation")
      assert_equal true, result.fetch("target_membership")
      assert_equal true, result.fetch("control_allowed")
    end
  end

  def test_human_authority_cannot_waive_receiver_manifest_membership
    result, stderr, status = invoke(
      "target" => "shakacode/hichee#9992",
      "operation" => "control_transfer",
      "human_authorized_control_transfer" => true
    )

    assert_equal 3, status.exitstatus, stderr
    assert_equal "foreign-target / evidence-only", result.fetch("disposition")
    assert_equal false, result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal true, result.fetch("evidence_delivery_allowed")
  end

  def test_duplicate_manifest_identity_is_ambiguous_after_normalization
    result, stderr, status = invoke(
      "canonical_target_manifest" => [
        "shakacode/agent-workflows#403",
        "ShakaCode/Agent-Workflows#403"
      ]
    )

    assert_equal 2, status.exitstatus, stderr
    assert_equal "UNKNOWN", result.fetch("status")
    assert_equal "UNKNOWN", result.fetch("target_membership")
    assert_equal "canonical target manifest is ambiguous after repository identity normalization",
                 result.fetch("reason")
  end

  def test_replay_is_byte_for_byte_deterministic
    input = JSON.generate(
      "contract" => "target-membership-request",
      "version" => 1,
      "canonical_target_manifest" => ["shakacode/agent-workflows#403"],
      "target" => "shakacode/hichee#9992",
      "operation" => "replacement",
      "human_authorized_control_transfer" => false
    )

    first_stdout, first_stderr, first_status = Open3.capture3(HELPER, stdin_data: input)
    second_stdout, second_stderr, second_status = Open3.capture3(HELPER, stdin_data: input)

    assert_equal 3, first_status.exitstatus, first_stderr
    assert_equal first_status.exitstatus, second_status.exitstatus, second_stderr
    assert_equal first_stdout, second_stdout
  end

  def test_portable_workflow_surfaces_require_the_guard_before_control_or_mutation
    required_surfaces = %w[
      skills/pr-batch/SKILL.md
      skills/plan-pr-batch/SKILL.md
      workflows/pr-processing.md
    ]

    required_surfaces.each do |relative_path|
      text = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")

      assert_includes text, "target-membership-guard", relative_path
      assert_includes text, "foreign-target / evidence-only", relative_path
      assert_includes text, "explicit human-authorized control transfer", relative_path
    end
  end

  def test_portable_contract_documents_transfer_authority_and_duplicate_key_fail_closed_rules
    required_surfaces = %w[
      skills/pr-batch/SKILL.md
      workflows/pr-processing.md
    ]

    required_surfaces.each do |relative_path|
      text = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")
      normalized_text = text.gsub(/\s+/, " ")

      assert_includes normalized_text, "trusted explicit out-of-band human authorization", relative_path
      assert_includes normalized_text, "self-asserted worker input", relative_path
      assert_includes normalized_text, "Duplicate JSON object keys anywhere", relative_path
      assert_includes normalized_text, "unrelated nested metadata", relative_path
    end
  end
end
