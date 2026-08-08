#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

class PromptHostAdapterTest < Minitest::Test
  ADAPTER = File.expand_path("prompt-host-adapter", __dir__)
  FIXTURES = File.expand_path("../fixtures", __dir__)
  WORKFLOW = File.expand_path("../../../workflows/pr-processing.md", __dir__)

  def run_adapter(prompt, active_host: "codex", env: {})
    stdout, stderr, status = Open3.capture3(
      env,
      ADAPTER,
      "--active-host",
      active_host,
      stdin_data: prompt
    )
    [JSON.parse(stdout), stderr, status]
  end

  def direct_prompt(host:, body:)
    invocation = {
      "codex" => "Use $pr-batch to continue this batch.",
      "claude" => "Use /pr-batch to continue this batch.",
      "portable" => "Use the pr-batch skill to continue this batch."
    }.fetch(host)
    <<~PROMPT
      Prompt host: #{host}
      Prompt mode: direct
      Preferred route: default
      Route requirement: advisory
      #{invocation}
      #{body}
    PROMPT
  end

  def continuation_prompt
    workflow = File.read(WORKFLOW, encoding: "UTF-8")
    heading = workflow.index("### Generic PR-Batch Continuation Prompt")
    fence = workflow.index("```text\n", heading)
    closing = workflow.index("\n```", fence + 8)
    workflow[(fence + 8)...(closing + 1)]
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

    relaunched, relaunch_stderr, relaunch_status = run_adapter(result.fetch("prompt"), active_host: "claude")
    assert relaunch_status.success?, relaunch_stderr
    assert_equal "compatible", relaunched.fetch("classification")
    assert_equal true, relaunched.fetch("execute_allowed")
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

    relaunched, relaunch_stderr, relaunch_status = run_adapter(result.fetch("prompt"), active_host: "codex")
    assert relaunch_status.success?, relaunch_stderr
    assert_equal "compatible", relaunched.fetch("classification")
    assert_equal true, relaunched.fetch("execute_allowed")
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
        - Use $address-review before closeout.
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal "unsupported-host-mechanic", result.fetch("reason_code")
    assert_equal false, result.fetch("execute_allowed")
    assert_nil result.fetch("prompt")
  end

  def test_opposite_host_mechanics_never_reach_an_executable_classification
    cases = [
      ["codex", "codex", "  - ask=>/pr-walkthrough; before closeout."],
      ["codex", "codex", "Run /address-review before closeout."],
      ["codex", "codex", "Before closeout, run the /address-review skill."],
      ["claude", "claude", "  - Use $address-review before closeout."],
      ["claude", "claude", "  - Use the $address-review skill before closeout."],
      ["claude", "claude", "Before closeout, run $address-review now."],
      ["portable", "codex", "Before closeout, invoke /address-review now."],
      ["portable", "claude", "Before closeout, use $address-review now."],
      ["portable", "codex", "Before closeout, use the $address-review skill."],
      ["portable", "claude", "Before closeout, run the /address-review skill."]
    ]

    cases.each do |declared_host, active_host, mechanic|
      result, stderr, status = run_adapter(
        direct_prompt(host: declared_host, body: mechanic),
        active_host: active_host
      )

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), mechanic
      assert_equal "unsupported-host-mechanic", result.fetch("reason_code"), mechanic
      assert_equal false, result.fetch("execute_allowed"), mechanic
      assert_nil result.fetch("prompt"), mechanic
      refute_includes JSON.generate(result), mechanic
    end
  end

  def test_explicit_conversion_rejects_mechanics_contradicting_the_declared_source_host
    cases = [
      ["codex", "claude", "Before closeout, run /address-review now."],
      ["claude", "codex", "Before closeout, use the $address-review skill."]
    ]

    cases.each do |declared_host, active_host, mechanic|
      result, stderr, status = run_adapter(
        direct_prompt(host: declared_host, body: mechanic),
        active_host: active_host
      )

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), mechanic
      assert_equal "contradictory-source-mechanic", result.fetch("reason_code"), mechanic
      assert_equal false, result.fetch("execute_allowed"), mechanic
      assert_nil result.fetch("prompt"), mechanic
    end
  end

  def test_incidental_command_names_without_invocation_cues_remain_allowed
    cases = [
      ["codex", "codex", "Document /address-review and /pr-batch as literal names only."],
      ["claude", "claude", "Document $address-review and $pr-batch as literal names only."],
      ["portable", "codex", "Document $address-review and /address-review as literal names only."],
      ["portable", "claude", "Document $address-review and /address-review as literal names only."]
    ]

    cases.each do |declared_host, active_host, prose|
      result, stderr, status = run_adapter(direct_prompt(host: declared_host, body: prose), active_host: active_host)

      assert status.success?, stderr
      expected = declared_host == "portable" ? "portable" : "compatible"
      assert_equal expected, result.fetch("classification"), prose
      assert_equal true, result.fetch("execute_allowed"), prose
    end
  end

  def test_reason_codes_are_stable_and_do_not_echo_malformed_prompt_text
    cases = {
      "unknown-active-host" => [direct_prompt(host: "portable", body: "Objective: safe."), "unknown"],
      "partial-headers" => ["Prompt host: codex\nPrompt mode: goal\nUse $pr-batch TOKEN_PARTIAL.\n", "codex"],
      "duplicate-headers" => [direct_prompt(host: "codex", body: "Prompt host: TOKEN_DUPLICATE"), "codex"],
      "non-advisory-route" => [direct_prompt(host: "codex", body: "Objective: TOKEN_ROUTE.")
                               .sub("Route requirement: advisory", "Route requirement: mandatory"), "codex"],
      "invalid-preferred-route" => [direct_prompt(host: "codex", body: "Objective: TOKEN_PREFERRED.")
                                    .sub("Preferred route: default", "Preferred route: sol/xhigh/hard"), "codex"],
      "invalid-host-mode-wrapper" => [direct_prompt(host: "codex", body: "Objective: TOKEN_WRAPPER.")
                                      .sub("Prompt mode: direct", "Prompt mode: goal"), "codex"],
      "contradictory-host-mechanic" => [direct_prompt(host: "codex", body: "Objective: TOKEN_CONTRADICT.")
                                        .sub("Use $pr-batch", "Use /pr-batch"), "codex"],
      "unrecognized-prompt" => ["Discuss TOKEN_UNRECOGNIZED /goal and /pr-batch as names.\n", "codex"]
    }

    cases.each do |expected_reason, (prompt, active_host)|
      result, stderr, status = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), expected_reason
      assert_equal expected_reason, result.fetch("reason_code"), expected_reason
      assert_equal false, result.fetch("execute_allowed"), expected_reason
      refute_match(/TOKEN_[A-Z]+/, JSON.generate(result), expected_reason)
    end
  end

  def test_utf8_prompt_is_deterministic_under_c_locale
    prompt = direct_prompt(host: "codex", body: "Objective: preserve café and 東京.")
    env = { "LANG" => "C", "LC_ALL" => "C" }

    result, stderr, status = run_adapter(prompt, active_host: "claude", env: env)

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_includes result.fetch("prompt"), "café and 東京"

    relaunched, relaunch_stderr, relaunch_status = run_adapter(
      result.fetch("prompt"),
      active_host: "claude",
      env: env
    )
    assert relaunch_status.success?, relaunch_stderr
    assert_equal "compatible", relaunched.fetch("classification")
    assert_includes relaunched.fetch("prompt"), "café and 東京"
  end

  def test_invalid_utf8_fails_closed_with_json_under_c_locale
    prompt = direct_prompt(host: "codex", body: "Objective: invalid bytes follow.").b
    prompt << "\xFF\n".b

    result, stderr, status = run_adapter(
      prompt,
      active_host: "codex",
      env: { "LANG" => "C", "LC_ALL" => "C" }
    )

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal "invalid-encoding", result.fetch("reason_code")
    assert_equal false, result.fetch("execute_allowed")
    assert_nil result.fetch("prompt")
  end

  def test_saved_generic_continuation_prompt_is_portable_on_both_hosts
    prompt = continuation_prompt.sub("Preferred route: <model/class>/<effort>", "Preferred route: default")

    %w[codex claude].each do |active_host|
      result, stderr, status = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "portable", result.fetch("classification"), active_host
      assert_equal true, result.fetch("execute_allowed"), active_host
      assert_equal prompt, result.fetch("prompt"), active_host
    end
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
