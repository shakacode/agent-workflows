#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

class PromptCompatibilityTest < Minitest::Test
  HELPER = File.expand_path("prompt-compatibility", __dir__)
  FIXTURES = File.expand_path("../fixtures/prompt-compatibility", __dir__)
  SCHEMA = File.expand_path("../../../docs/schemas/prompt-compatibility-v1.schema.json", __dir__)
  DECISIONS = %w[compatible portable conversion-required].freeze

  def fixture(name)
    File.binread(File.join(FIXTURES, name))
  end

  def run_helper(prompt, active_host:)
    stdout, stderr, status = Open3.capture3(
      HELPER,
      "--active-host",
      active_host,
      stdin_data: prompt
    )
    [JSON.parse(stdout), stderr, status, stdout]
  end

  def assert_decision(result, expected)
    assert_equal expected, result.fetch("decision")
    assert_includes DECISIONS, result.fetch("decision")
  end

  def test_matching_active_host_is_compatible_and_byte_stable
    prompt = fixture("active-host-codex.txt")

    result, stderr, status = run_helper(prompt, active_host: "codex")

    assert status.success?, stderr
    assert_decision result, "compatible"
    assert_equal true, result.fetch("execute_allowed")
    assert_equal false, result.fetch("stop_required")
    assert_equal prompt, result.fetch("prompt")
    assert_nil result.fetch("converted_prompt")
  end

  def test_portable_prompt_routes_through_the_host_adapter_without_rewriting
    prompt = fixture("portable.txt")

    result, stderr, status = run_helper(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_decision result, "portable"
    assert_equal true, result.fetch("execute_allowed")
    assert_equal "docs/host-adapter/contract.md", result.fetch("adapter_contract")
    assert_equal prompt, result.fetch("prompt")
    assert_nil result.fetch("converted_prompt")
  end

  def test_codex_to_claude_conversion_is_deterministic_inert_and_preserves_payload
    prompt = fixture("codex-to-claude.txt")
    expected = fixture("codex-to-claude.expected.txt")

    first, stderr, status = run_helper(prompt, active_host: "claude")
    second, second_stderr, second_status = run_helper(prompt, active_host: "claude")

    assert status.success?, stderr
    assert second_status.success?, second_stderr
    assert_decision first, "conversion-required"
    assert_equal first, second
    assert_equal false, first.fetch("execute_allowed")
    assert_equal true, first.fetch("stop_required")
    assert_nil first.fetch("prompt")
    assert_equal expected, first.fetch("converted_prompt")
    assert_equal "sol/xhigh", first.fetch("preferred_route")
    assert_preserved_payload prompt, expected
  end

  def test_claude_to_codex_conversion_is_deterministic_inert_and_preserves_payload
    prompt = fixture("claude-to-codex.txt")
    expected = fixture("claude-to-codex.expected.txt")

    result, stderr, status = run_helper(prompt, active_host: "codex")

    assert status.success?, stderr
    assert_decision result, "conversion-required"
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("stop_required")
    assert_nil result.fetch("prompt")
    assert_equal expected, result.fetch("converted_prompt")
    assert_equal "Opus 5/high", result.fetch("preferred_route")
    assert_preserved_payload prompt, expected
  end

  def test_converted_prompt_requires_a_new_run_before_it_can_execute
    converted, stderr, status = run_helper(fixture("codex-to-claude.txt"), active_host: "claude")
    assert status.success?, stderr

    relaunched, relaunch_stderr, relaunch_status = run_helper(
      converted.fetch("converted_prompt"),
      active_host: "claude"
    )

    assert relaunch_status.success?, relaunch_stderr
    assert_decision relaunched, "compatible"
    assert_equal true, relaunched.fetch("execute_allowed")
    assert_equal false, relaunched.fetch("stop_required")
  end

  def test_legacy_goal_is_recognized_but_only_converted_for_an_opposite_known_host
    prompt = fixture("legacy-goal.txt")

    matching, matching_stderr, matching_status = run_helper(prompt, active_host: "codex")
    converted, converted_stderr, converted_status = run_helper(prompt, active_host: "claude")

    assert matching_status.success?, matching_stderr
    assert_decision matching, "compatible"
    assert_equal prompt, matching.fetch("prompt")

    assert converted_status.success?, converted_stderr
    assert_decision converted, "conversion-required"
    assert_equal fixture("legacy-goal.expected.txt"), converted.fetch("converted_prompt")
    assert_equal false, converted.fetch("execute_allowed")
  end

  def test_incidental_host_names_do_not_trigger_legacy_detection_or_conversion
    marker = "INCIDENTAL_HOST_NAMES_MUST_NOT_BE_ECHOED"
    prompt = fixture("incidental-names.txt") + marker

    result, stderr, status, stdout = run_helper(prompt, active_host: "codex")

    refute status.success?
    assert_empty stderr
    assert_equal "unrecognized-prompt", result.fetch("error")
    refute result.key?("decision")
    refute result.key?("converted_prompt")
    refute_includes stdout, marker
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("stop_required")
  end

  def test_ambiguous_active_host_fails_closed_without_a_decision_or_prompt_echo
    marker = "AMBIGUOUS_HOST_PROMPT_MUST_NOT_BE_ECHOED"
    prompt = fixture("ambiguous-host.txt") + marker

    result, stderr, status, stdout = run_helper(prompt, active_host: "unknown")

    refute status.success?
    assert_empty stderr
    assert_equal "ambiguous-active-host", result.fetch("error")
    refute result.key?("decision")
    refute result.key?("prompt")
    refute result.key?("converted_prompt")
    refute_includes stdout, marker
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("stop_required")
  end

  def test_partial_or_non_advisory_metadata_fails_closed_before_host_inference
    prompts = [
      fixture("active-host-codex.txt").sub("Route requirement: advisory\n", ""),
      fixture("active-host-codex.txt").sub("Route requirement: advisory", "Route requirement: required")
    ]

    prompts.each do |prompt|
      result, stderr, status = run_helper(prompt, active_host: "codex")

      refute status.success?
      assert_empty stderr
      refute result.key?("decision")
      assert_equal false, result.fetch("execute_allowed")
      assert_equal true, result.fetch("stop_required")
    end
  end

  def test_host_metadata_converts_a_host_neutral_readable_batch_body
    prompt = <<~PROMPT
      Prompt host: codex
      Prompt mode: batch
      Preferred route: default
      Route requirement: advisory
      Repository: shakacode/agent-workflows
      Work item: https://github.com/shakacode/agent-workflows/issues/372
      Instruction: Use PR-batch to complete this work item.
    PROMPT

    result, stderr, status = run_helper(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_decision result, "conversion-required"
    assert_equal prompt.sub("Prompt host: codex", "Prompt host: claude"), result.fetch("converted_prompt")
    assert_equal false, result.fetch("execute_allowed")
  end

  def test_malformed_header_like_text_cannot_hide_behind_legacy_detection
    marker = "MALFORMED_METADATA_MUST_NOT_BE_ECHOED"
    prompt = fixture("legacy-goal.txt") + "Prompt host : claude #{marker}\n"

    result, stderr, status, stdout = run_helper(prompt, active_host: "codex")

    refute status.success?
    assert_empty stderr
    assert_equal "invalid-metadata", result.fetch("error")
    refute result.key?("decision")
    refute_includes stdout, marker
  end

  def test_schema_exposes_only_the_three_decisions_and_keeps_errors_separate
    schema = JSON.parse(File.read(SCHEMA, encoding: "UTF-8"))
    success, error = schema.fetch("oneOf")

    assert_equal DECISIONS, success.dig("properties", "decision", "enum")
    assert_includes success.fetch("required"), "decision"
    refute_includes error.fetch("properties").keys, "decision"
    assert_includes error.fetch("required"), "error"
    assert_equal false, success.fetch("additionalProperties")
    assert_equal false, error.fetch("additionalProperties")
  end

  private

  def assert_preserved_payload(source, converted)
    labels = %w[Objective Targets Scope Dependencies Permissions Safety QA Review merge_authority]
    labels.each do |label|
      source_line = source.lines.find { |line| line.start_with?("#{label}:") }
      refute_nil source_line, "source fixture is missing #{label}"
      assert_includes converted.lines, source_line, "conversion changed #{label}"
    end
    assert_includes converted, "Preferred route: #{source[/^Preferred route: (.+)$/, 1]}"
    assert_includes converted, "Route requirement: advisory"
  end
end
