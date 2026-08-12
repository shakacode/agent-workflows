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
    repository_mutation github_mutation control_transfer
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

    invoke_raw(JSON.generate(input))
  end

  def invoke_raw(input, parse: true)
    stdout, stderr, status = Open3.capture3([HELPER, HELPER], stdin_data: input)
    [parse ? JSON.parse(stdout) : stdout, stderr, status]
  end

  def test_allows_control_for_an_exact_manifest_member
    result, stderr, status = invoke("human_authorized_control_transfer" => true)

    assert_predicate status, :success?, stderr
    assert_equal "allowed", result.fetch("status")
    assert_equal "manifest-member", result.fetch("disposition")
    assert_equal true, result.fetch("target_membership")
    assert_equal true, result.fetch("control_allowed")
    assert_equal false, result.fetch("evidence_delivery_allowed")
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

    first_stdout, first_stderr, first_status = invoke_raw(input, parse: false)
    second_stdout, second_stderr, second_status = invoke_raw(input, parse: false)

    assert_equal 2, first_status.exitstatus, first_stderr
    assert_equal first_status.exitstatus, second_status.exitstatus, second_stderr
    assert_equal first_stdout, second_stdout
  end

  def test_malformed_utf8_fails_closed_before_json_parsing_or_duplicate_scanning
    malformed_inputs = {
      "duplicate object key" => "{\"\xFF\":1,\"\xFF\":2}".b,
      "single object key" => "{\"\xFF\":1}".b,
      "string value" => "{\"metadata\":\"\xFF\"}".b
    }

    malformed_inputs.each do |location, input|
      first_stdout, first_stderr, first_status = invoke_raw(input, parse: false)
      second_stdout, second_stderr, second_status = invoke_raw(input, parse: false)
      result = JSON.parse(first_stdout)

      assert_equal 2, first_status.exitstatus, "#{location}: #{first_stderr}"
      assert_empty first_stderr, location
      assert_equal first_status.exitstatus, second_status.exitstatus, location
      assert_equal first_stdout, second_stdout, location
      assert_equal first_stderr, second_stderr, location
      assert_equal "UNKNOWN", result.fetch("status"), location
      assert_equal "UNKNOWN", result.fetch("disposition"), location
      assert_equal "UNKNOWN", result.fetch("target_membership"), location
      assert_equal false, result.fetch("control_allowed"), location
      assert_equal false, result.fetch("evidence_delivery_allowed"), location
      assert_equal "input is not valid UTF-8", result.fetch("reason"), location
      assert_equal "provide UTF-8 encoded JSON and replay the guard",
                   result.fetch("next_action"), location
    end
  end

  def test_blocks_control_for_a_foreign_target_as_evidence_only
    result, stderr, status = invoke("target" => "shakacode/hichee#9992")

    assert_equal 3, status.exitstatus, stderr
    assert_equal "blocked", result.fetch("status")
    assert_equal "foreign-target / evidence-only", result.fetch("disposition")
    assert_equal "dispatch", result.fetch("operation")
    assert_equal false, result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal false, result.fetch("evidence_delivery_allowed")
    assert_equal "submit a new exact evidence_delivery request or obtain an explicit human-authorized control transfer to a task already bound to that target",
                 result.fetch("next_action")
  end

  def test_allows_foreign_target_evidence_delivery_without_control
    [false, true].each do |human_authority|
      result, stderr, status = invoke(
        "target" => "shakacode/hichee#9992",
        "operation" => "evidence_delivery",
        "human_authorized_control_transfer" => human_authority
      )

      assert_predicate status, :success?, stderr
      assert_equal "allowed", result.fetch("status")
      assert_equal "foreign-target / evidence-only", result.fetch("disposition")
      assert_equal false, result.fetch("target_membership")
      assert_equal false, result.fetch("control_allowed")
      assert_equal true, result.fetch("evidence_delivery_allowed")
    end
  end

  def test_manifest_member_evidence_delivery_remains_evidence_only
    [false, true].each do |human_authority|
      result, stderr, status = invoke(
        "operation" => "evidence_delivery",
        "human_authorized_control_transfer" => human_authority
      )

      assert_predicate status, :success?, stderr
      assert_equal "allowed", result.fetch("status")
      assert_equal "manifest-member / evidence-only", result.fetch("disposition")
      assert_equal true, result.fetch("target_membership")
      assert_equal false, result.fetch("control_allowed")
      assert_equal true, result.fetch("evidence_delivery_allowed")
    end
  end

  def test_denies_control_transfer_without_explicit_human_authority
    result, stderr, status = invoke("operation" => "control_transfer")

    assert_equal 3, status.exitstatus, stderr
    assert_equal "blocked", result.fetch("status")
    assert_equal "control-transfer-authority-required", result.fetch("disposition")
    assert_equal true, result.fetch("target_membership")
    assert_equal false, result.fetch("control_allowed")
    assert_equal false, result.fetch("evidence_delivery_allowed")
  end

  def test_non_boolean_human_authority_returns_structured_unknown
    ["true", 1, nil].each do |invalid_authority|
      result, stderr, status = invoke(
        "human_authorized_control_transfer" => invalid_authority
      )

      assert_equal 2, status.exitstatus, "#{invalid_authority.inspect}: #{stderr}"
      assert_equal "UNKNOWN", result.fetch("status"), invalid_authority.inspect
      assert_equal "UNKNOWN", result.fetch("disposition"), invalid_authority.inspect
      assert_equal false, result.fetch("control_allowed"), invalid_authority.inspect
      assert_equal false, result.fetch("evidence_delivery_allowed"), invalid_authority.inspect
      assert_equal "human_authorized_control_transfer must be true or false",
                   result.fetch("reason"), invalid_authority.inspect
    end
  end

  def test_wrong_contract_or_version_returns_structured_unknown
    [
      { "contract" => "wrong-contract" },
      { "version" => 2 }
    ].each do |overrides|
      result, stderr, status = invoke(overrides)

      assert_equal 2, status.exitstatus, "#{overrides.inspect}: #{stderr}"
      assert_equal "UNKNOWN", result.fetch("status"), overrides.inspect
      assert_equal "UNKNOWN", result.fetch("disposition"), overrides.inspect
      assert_equal false, result.fetch("control_allowed"), overrides.inspect
      assert_equal false, result.fetch("evidence_delivery_allowed"), overrides.inspect
      assert_equal "invalid target-membership-request contract or version",
                   result.fetch("reason"), overrides.inspect
    end
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
    assert_equal false, result.fetch("evidence_delivery_allowed")
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
      "target" => "Shaka-Code/.Agent_Workflows-Guard#403",
      "human_authorized_control_transfer" => true
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

  def test_every_control_boundary_requires_membership_and_explicit_human_authority
    CONTROL_OPERATIONS.each do |operation|
      result, stderr, status = invoke(
        "operation" => operation,
        "human_authorized_control_transfer" => false
      )

      assert_equal 3, status.exitstatus, "#{operation}: #{stderr}"
      assert_equal "blocked", result.fetch("status"), operation
      assert_equal true, result.fetch("target_membership"), operation
      assert_equal false, result.fetch("control_allowed"), operation
      assert_equal false, result.fetch("evidence_delivery_allowed"), operation
      assert_equal "obtain explicit human authority before packet-driven control or mutation",
                   result.fetch("next_action"), operation

      result, stderr, status = invoke(
        "operation" => operation,
        "human_authorized_control_transfer" => true
      )

      assert_predicate status, :success?, "#{operation}: #{stderr}"
      assert_equal operation, result.fetch("operation")
      assert_equal true, result.fetch("target_membership")
      assert_equal true, result.fetch("control_allowed")
      assert_equal false, result.fetch("evidence_delivery_allowed")

      [false, true].each do |human_authority|
        result, stderr, status = invoke(
          "target" => "shakacode/hichee#9992",
          "operation" => operation,
          "human_authorized_control_transfer" => human_authority
        )

        assert_equal 3, status.exitstatus, "#{operation}/#{human_authority}: #{stderr}"
        assert_equal "blocked", result.fetch("status"), operation
        assert_equal "foreign-target / evidence-only", result.fetch("disposition"), operation
        assert_equal false, result.fetch("target_membership"), operation
        assert_equal false, result.fetch("control_allowed"), operation
        assert_equal false, result.fetch("evidence_delivery_allowed"), operation
        assert_equal "submit a new exact evidence_delivery request or obtain an explicit human-authorized control transfer to a task already bound to that target",
                     result.fetch("next_action"), operation
      end
    end
  end

  def test_malformed_target_remains_unknown_regardless_of_human_authority
    [false, true].each do |human_authority|
      result, stderr, status = invoke(
        "target" => "UNKNOWN",
        "human_authorized_control_transfer" => human_authority
      )

      assert_equal 2, status.exitstatus, stderr
      assert_equal "UNKNOWN", result.fetch("status")
      assert_equal "UNKNOWN", result.fetch("target_membership")
      assert_equal false, result.fetch("control_allowed")
      assert_equal false, result.fetch("evidence_delivery_allowed")
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
    assert_equal false, result.fetch("evidence_delivery_allowed")
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

    first_stdout, first_stderr, first_status = invoke_raw(input, parse: false)
    second_stdout, second_stderr, second_status = invoke_raw(input, parse: false)

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

  def test_bin_validate_executes_the_target_membership_guard_suite_in_the_pr_batch_section
    validate = File.readlines(File.join(ROOT, "bin/validate"), chomp: true)
    guard_test = "ruby skills/pr-batch/bin/target-membership-guard-test.rb"
    previous_test = "ruby skills/batch-status/bin/batch-status-test.rb"
    next_test = "ruby skills/pr-batch/bin/pr-body-human-first-contract-test.rb"

    assert_includes validate, guard_test
    assert_operator validate.index(previous_test), :<, validate.index(guard_test)
    assert_operator validate.index(guard_test), :<, validate.index(next_test)
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
      assert_includes normalized_text, "Every packet-driven operation other than `evidence_delivery`", relative_path
    end

    workflow = File.read(File.join(ROOT, "workflows/pr-processing.md"), encoding: "UTF-8").gsub(/\s+/, " ")
    assert_includes workflow,
                    "`evidence_delivery_allowed: true` appears only on a request whose operation is `evidence_delivery`"
  end

  def test_portable_skill_summaries_distinguish_foreign_evidence_from_unknown_identity
    surfaces = {
      "skills/pr-batch/SKILL.md" => [/## Cross-Task Target Membership Gate/, /## Continuing From Saved Handoffs/],
      "skills/plan-pr-batch/SKILL.md" => [
        /Preserve the manifest/,
        /- For PRs with review feedback/
      ]
    }

    surfaces.each do |relative_path, (start_pattern, end_pattern)|
      text = File.read(File.join(ROOT, relative_path), encoding: "UTF-8")
      section = text.match(/#{start_pattern.source}(.*?)#{end_pattern.source}/m)&.[](1)

      refute_nil section, "#{relative_path} is missing its target-membership summary"
      normalized_section = section.gsub(/\s+/, " ")
      assert_includes normalized_section,
                      "exact repository-qualified foreign target may use only a new exact `evidence_delivery` request",
                      relative_path
      assert_includes normalized_section,
                      "Missing, ambiguous, synthetic, malformed, or literal `UNKNOWN` target identity returns structured `UNKNOWN` and blocks both control and evidence delivery until resolved",
                      relative_path
      CONTROL_OPERATIONS.each do |operation|
        assert_includes section, operation, "#{relative_path} is missing control operation #{operation}"
      end
    end
  end
end
