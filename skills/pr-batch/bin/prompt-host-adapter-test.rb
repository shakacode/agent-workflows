#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

class PromptHostAdapterTest < Minitest::Test
  ADAPTER = File.expand_path("prompt-host-adapter", __dir__)
  FIXTURES = File.expand_path("../fixtures", __dir__)

  def run_adapter(prompt, active_host: "codex")
    stdout, stderr, status = Open3.capture3(
      ADAPTER,
      "--active-host",
      active_host,
      stdin_data: prompt
    )
    [JSON.parse(stdout), stderr, status]
  end

  def test_matching_complete_headers_are_compatible_and_unchanged
    prompt = <<~PROMPT
      /goal
      Prompt host: codex
      Prompt mode: goal
      Preferred route: sol/xhigh
      Route requirement: advisory
      Use $pr-batch to complete this batch with subagents.
      Objective: Keep the semantic payload unchanged.
    PROMPT

    result, stderr, status = run_adapter(prompt)

    assert status.success?, stderr
    assert_equal "compatible", result.fetch("classification")
    assert_equal true, result.fetch("execute_allowed")
    assert_equal prompt, result.fetch("prompt")
  end

  def test_portable_headers_resolve_the_contract_without_rewriting
    prompt = <<~PROMPT
      Prompt host: portable
      Prompt mode: batch
      Preferred route: default
      Route requirement: advisory
      Use the pr-batch skill to complete this batch with subagents.
      Objective: Keep portable workflow text intact.
    PROMPT

    result, stderr, status = run_adapter(prompt)

    assert status.success?, stderr
    assert_equal "portable", result.fetch("classification")
    assert_equal true, result.fetch("execute_allowed")
    assert_equal "docs/host-adapter/contract.md", result.fetch("adapter_contract")
    assert_equal prompt, result.fetch("prompt")
  end

  def test_unknown_active_host_is_ambiguous_even_for_portable_input
    prompt = <<~PROMPT
      Prompt host: portable
      Prompt mode: batch
      Preferred route: default
      Route requirement: advisory
      Use the pr-batch skill to complete this batch.
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "unknown")

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_nil result.fetch("prompt")
  end

  def test_codex_prompt_converts_deterministically_to_inert_claude_text
    prompt = File.read(File.join(FIXTURES, "prompt-host-codex.txt"))
    expected = File.read(File.join(FIXTURES, "prompt-host-codex-to-claude.expected.txt"))

    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("relaunch_required")
    assert_equal true, result.fetch("replanning_required")
    assert_equal true, result.fetch("semantic_payload_preserved")
    assert_equal expected, result.fetch("prompt")
  end

  def test_claude_prompt_converts_deterministically_to_inert_codex_text
    prompt = File.read(File.join(FIXTURES, "prompt-host-claude.txt"))
    expected = File.read(File.join(FIXTURES, "prompt-host-claude-to-codex.expected.txt"))

    result, stderr, status = run_adapter(prompt, active_host: "codex")

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("relaunch_required")
    assert_equal true, result.fetch("replanning_required")
    assert_equal true, result.fetch("semantic_payload_preserved")
    assert_equal expected, result.fetch("prompt")
  end

  def test_duplicate_header_is_ambiguous_and_cannot_execute
    prompt = <<~PROMPT
      /goal
      Prompt host: codex
      Prompt mode: goal
      Preferred route: sol/xhigh
      Route requirement: advisory
      Use $pr-batch to complete this batch.
      Prompt host: codex
    PROMPT

    result, stderr, status = run_adapter(prompt)

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_nil result.fetch("prompt")
  end

  def test_codex_goal_headers_without_leading_goal_are_ambiguous
    prompt = <<~PROMPT
      Prompt host: codex
      Prompt mode: goal
      Preferred route: sol/xhigh
      Route requirement: advisory
      Use $pr-batch to complete this batch.
    PROMPT

    result, stderr, status = run_adapter(prompt)

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
  end

  def test_malformed_preferred_route_is_ambiguous
    prompt = <<~PROMPT
      /goal
      Prompt host: codex
      Prompt mode: goal
      Preferred route: sol/xhigh/hard
      Route requirement: advisory
      Use $pr-batch to complete this batch.
    PROMPT

    result, stderr, status = run_adapter(prompt)

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
  end

  def test_legacy_leading_goal_is_unmistakably_codex
    prompt = "/goal\nUse $pr-batch to continue the verified batch.\n"

    result, stderr, status = run_adapter(prompt, active_host: "codex")

    assert status.success?, stderr
    assert_equal "compatible", result.fetch("classification")
    assert_equal "codex", result.fetch("declared_host")
    assert_equal true, result.fetch("execute_allowed")
    assert_equal prompt, result.fetch("prompt")
  end

  def test_legacy_codex_prompt_converts_to_inert_claude_prompt
    prompt = "/goal\nUse $pr-batch to continue the verified batch.\n"
    expected = <<~PROMPT
      Prompt host: claude
      Prompt mode: batch
      Preferred route: default
      Route requirement: advisory
      Use /pr-batch to continue the verified batch.
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("relaunch_required")
    assert_equal true, result.fetch("semantic_payload_preserved")
    assert_equal expected, result.fetch("prompt")
  end

  def test_matching_direct_mode_is_compatible_without_goal_wrapper
    prompt = <<~PROMPT
      Prompt host: codex
      Prompt mode: direct
      Preferred route: default
      Route requirement: advisory
      Use $pr-batch to inspect the named target before launch.
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "codex")

    assert status.success?, stderr
    assert_equal "compatible", result.fetch("classification")
    assert_equal true, result.fetch("execute_allowed")
    assert_equal prompt, result.fetch("prompt")
  end

  def test_known_opposite_direct_host_requires_inert_conversion
    prompt = <<~PROMPT
      Prompt host: codex
      Prompt mode: direct
      Preferred route: default
      Route requirement: advisory
      Use $pr-batch to inspect the named target before launch.
    PROMPT
    expected = <<~PROMPT
      Prompt host: claude
      Prompt mode: direct
      Preferred route: default
      Route requirement: advisory
      Use /pr-batch to inspect the named target before launch.
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("semantic_payload_preserved")
    assert_equal expected, result.fetch("prompt")
  end

  def test_untranslated_host_mechanic_makes_conversion_ambiguous
    prompt = <<~PROMPT
      /goal
      Prompt host: codex
      Prompt mode: goal
      Preferred route: default
      Route requirement: advisory
      Use $pr-batch to complete this batch.
      Use $address-review before closeout.
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_nil result.fetch("prompt")
  end

  def test_partial_non_advisory_incidental_and_contradictory_prompts_are_ambiguous
    prompts = {
      partial: "Prompt host: codex\nPrompt mode: goal\nUse $pr-batch now.\n",
      non_advisory: <<~PROMPT,
        /goal
        Prompt host: codex
        Prompt mode: goal
        Preferred route: sol/xhigh
        Route requirement: mandatory
        Use $pr-batch now.
      PROMPT
      incidental: "Discuss /goal and /pr-batch host names without invoking either.\n",
      contradictory: <<~PROMPT
        /goal
        Prompt host: codex
        Prompt mode: goal
        Preferred route: sol/xhigh
        Route requirement: advisory
        Use /pr-batch now.
      PROMPT
    }

    prompts.each do |label, prompt|
      result, stderr, status = run_adapter(prompt, active_host: "codex")

      assert status.success?, "#{label}: #{stderr}"
      assert_equal "ambiguous", result.fetch("classification"), label.to_s
      assert_equal false, result.fetch("execute_allowed"), label.to_s
      assert_nil result.fetch("prompt"), label.to_s
    end
  end

  def test_legacy_leading_claude_invocation_is_compatible_and_unchanged
    prompt = "/pr-batch continue the verified batch.\n"

    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "compatible", result.fetch("classification")
    assert_equal "claude", result.fetch("declared_host")
    assert_equal true, result.fetch("execute_allowed")
    assert_equal prompt, result.fetch("prompt")
  end

  def test_legacy_leading_claude_invocation_converts_to_inert_codex_prompt
    prompt = "/pr-batch continue the verified batch.\n"
    expected = <<~PROMPT
      /goal
      Prompt host: codex
      Prompt mode: goal
      Preferred route: default
      Route requirement: advisory
      Use $pr-batch continue the verified batch.
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "codex")

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("relaunch_required")
    assert_equal true, result.fetch("semantic_payload_preserved")
    assert_equal expected, result.fetch("prompt")
  end
end
