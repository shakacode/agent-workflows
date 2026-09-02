#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "json_schemer"
require "minitest/autorun"
require "open3"

class PromptCompatibilityTest < Minitest::Test
  HELPER = File.expand_path("prompt-compatibility", __dir__)
  FIXTURES = File.expand_path("../fixtures/prompt-compatibility", __dir__)
  SCHEMA = File.expand_path("../../../docs/schemas/prompt-compatibility-v1.schema.json", __dir__)
  INTAKE = File.expand_path("../../../workflows/pr-batch-intake.md", __dir__)
  WORKFLOW = File.expand_path("../../../workflows/pr-processing.md", __dir__)
  DECISIONS = %w[compatible portable conversion-required].freeze

  def fixture(name)
    File.binread(File.join(FIXTURES, name))
  end

  def run_helper(prompt, active_host:)
    host_arguments = Array(active_host).flat_map { |host| ["--active-host", host] }
    stdout, stderr, status = Open3.capture3(
      HELPER,
      *host_arguments,
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
    [["codex-to-claude.txt", "claude"], ["claude-to-codex.txt", "codex"]].each do |name, host|
      converted, stderr, status = run_helper(fixture(name), active_host: host)
      assert status.success?, stderr

      relaunched, relaunch_stderr, relaunch_status = run_helper(
        converted.fetch("converted_prompt"),
        active_host: host
      )

      assert relaunch_status.success?, relaunch_stderr
      assert_decision relaunched, "compatible"
      assert_equal true, relaunched.fetch("execute_allowed")
      assert_equal false, relaunched.fetch("stop_required")
    end
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

  def test_conflicting_active_host_flags_fail_closed
    result, stderr, status, stdout = run_helper(
      fixture("active-host-codex.txt"), active_host: %w[codex claude]
    )

    refute status.success?
    assert_empty stderr
    assert_equal "ambiguous-active-host", result.fetch("error")
    assert_equal "ambiguous", result.fetch("active_host")
    refute result.key?("decision")
    refute_includes stdout, "Keep this prompt byte-stable"
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

  def test_malformed_batch_size_target_fails_closed_instead_of_partial_conversion
    marker = "MALFORMED_BATCH_TARGET_MUST_NOT_BE_ECHOED"
    prompts = [
      fixture("codex-to-claude.txt")
        .sub("Batch size target: codex;wave: 1/1", "Batch size target: codex wave: 1/1"),
      fixture("codex-to-claude.txt")
        .sub("Batch size target: codex;wave: 1/1", "Batch size target = codex;wave: 1/1")
    ]

    prompts.each do |prompt|
      result, stderr, status, stdout = run_helper(prompt + marker, active_host: "claude")

      refute status.success?
      assert_empty stderr
      assert_equal "invalid-batch-size-target", result.fetch("error")
      refute result.key?("decision")
      refute_includes stdout, marker
    end
  end

  def test_legacy_goal_validates_batch_targets_before_execution_or_conversion
    prompts = [
      ["#{fixture('legacy-goal.txt')}Batch size target: claude;wave: 1/1\n", "contradictory-batch-size-target"],
      ["#{fixture('legacy-goal.txt')}Batch size target = codex;wave: 1/1\n", "invalid-batch-size-target"]
    ]

    prompts.each do |prompt, expected_error|
      %w[codex claude].each do |active_host|
        result, stderr, status = run_helper(prompt, active_host:)

        refute status.success?
        assert_empty stderr
        assert_equal expected_error, result.fetch("error")
        refute result.key?("decision")
      end
    end
  end

  def test_goal_mode_is_rejected_for_non_codex_prompt_hosts
    %w[claude portable].each do |prompt_host|
      prompt = fixture("active-host-codex.txt")
               .sub("Prompt host: codex", "Prompt host: #{prompt_host}")
               .sub("Prompt mode: batch", "Prompt mode: goal")

      result, stderr, status = run_helper(prompt, active_host: "codex")

      refute status.success?
      assert_empty stderr
      assert_equal "unsupported-host-mode", result.fetch("error")
      refute result.key?("decision")
    end
  end

  def test_supported_host_mode_matrix_is_stable_across_active_hosts
    cases = {
      %w[codex direct] => "Use $pr-batch for this task.\n",
      %w[codex batch] => "Use $pr-batch for this batch.\n",
      %w[claude direct] => "Use /pr-batch for this task.\n",
      %w[claude batch] => "Use /pr-batch for this batch.\n",
      %w[portable direct] => "Use the pr-batch skill for this task.\n",
      %w[portable batch] => "Use the pr-batch skill for this batch.\n"
    }

    cases.each do |(prompt_host, prompt_mode), body|
      prompt = <<~PROMPT + body
        Prompt host: #{prompt_host}
        Prompt mode: #{prompt_mode}
        Preferred route: default
        Route requirement: advisory
      PROMPT
      %w[codex claude].each do |active_host|
        result, stderr, status = run_helper(prompt, active_host:)
        assert status.success?, stderr
        expected = if prompt_host == "portable"
                     "portable"
                   elsif prompt_host == active_host
                     "compatible"
                   else
                     "conversion-required"
                   end
        assert_decision result, expected
        next unless expected == "conversion-required"

        relaunched, relaunch_stderr, relaunch_status = run_helper(
          result.fetch("converted_prompt"), active_host:
        )
        assert relaunch_status.success?, relaunch_stderr
        assert_decision relaunched, "compatible"
      end
    end
  end

  def test_portable_and_cross_host_prompts_reject_nonconvertible_host_mechanics
    prompts = [
      ["#{fixture('portable.txt')}Use $address-review after QA.\n", "claude"],
      ["#{fixture('codex-to-claude.txt')}Use $address-review after QA.\n", "claude"],
      ["#{fixture('codex-to-claude.txt')}Use $scw:pr-batch for this route.\n", "claude"],
      ["#{fixture('claude-to-codex.txt')}Use Claude Agent with isolation: 'worktree'.\n", "codex"],
      ["#{fixture('claude-to-codex.txt')}Dispatch each lane with the Agent tool.\n", "codex"],
      ["#{fixture('claude-to-codex.txt')}Run /code-review before closeout.\n", "codex"],
      ["#{fixture('claude-to-codex.txt')}Use /loop to monitor CI.\n", "codex"],
      ["#{fixture('codex-to-claude.txt')}Call spawn_agent with sandbox_permissions: use_default.\n", "claude"]
    ]

    prompts.each do |prompt, active_host|
      result, stderr, status = run_helper(prompt, active_host:)

      refute status.success?
      assert_empty stderr
      assert_equal "unsupported-host-mechanic", result.fetch("error")
      refute result.key?("decision")
    end
  end

  def test_relaunchable_workflow_prompts_are_portable_at_the_runtime_gate
    workflow = File.read(WORKFLOW, encoding: "UTF-8")
    headings = ["Model-Routing Recovery Prompt", "Generic PR-Batch Continuation Prompt"]

    headings.each do |heading|
      section = workflow[/^### #{Regexp.escape(heading)}\n(?<body>.*?)(?=^### |\z)/m, :body]
      prompt = section&.match(/```text\n(?<prompt>.*?)```/m)&.[](:prompt)
      refute_nil prompt, heading
      if heading == "Model-Routing Recovery Prompt"
        assert_includes prompt, "Preferred route: <model/class>/<effort>"
        refute_includes prompt, "Coordinator model/effort preference:"
        refute_includes prompt, "Observed host/model/effort:"
        prompt = prompt.sub("Preferred route: <model/class>/<effort>", "Preferred route: sol/high")
      end

      %w[codex claude].each do |active_host|
        result, stderr, status = run_helper(prompt, active_host:)

        assert status.success?, "#{heading} on #{active_host}: #{stderr} #{result.inspect}"
        assert_decision result, "portable"
        assert_equal prompt, result.fetch("prompt")
      end
    end
  end

  def test_same_host_and_legacy_prompts_reject_other_host_mechanics
    claude_prompt = fixture("active-host-codex.txt")
                    .sub("Prompt host: codex", "Prompt host: claude")
                    .sub("Use $pr-batch", "Use /pr-batch")
    prompts = [
      ["#{fixture('active-host-codex.txt')}Use Claude Agent with isolation: 'worktree'.\n", "codex"],
      ["#{claude_prompt}Run /simplify before mutation.\n", "claude"],
      ["#{fixture('legacy-goal.txt')}Use Claude Workflow with isolation: 'worktree'.\n", "codex"]
    ]

    prompts.each do |prompt, active_host|
      result, stderr, status = run_helper(prompt, active_host:)

      refute status.success?
      assert_empty stderr
      assert_equal "unsupported-host-mechanic", result.fetch("error")
      refute result.key?("decision")
    end
  end

  def test_conversion_never_rewrites_protected_semantic_fields
    %w[Objective Targets Scope Dependencies Permissions Safety QA Review merge_authority].each do |label|
      prompt = fixture("codex-to-claude.txt").sub(/^#{label}:.+$/, "#{label}: preserve $pr-batch literally")

      result, stderr, status = run_helper(prompt, active_host: "claude")

      refute status.success?, label
      assert_empty stderr
      assert_equal "protected-field-host-mechanic", result.fetch("error")
      refute result.key?("decision")
    end
  end

  def test_schema_validates_outputs_and_rejects_unsafe_decision_combinations
    schema = JSONSchemer.schema(JSON.parse(File.read(SCHEMA, encoding: "UTF-8")))
    outputs = [
      run_helper(fixture("active-host-codex.txt"), active_host: "codex").first,
      run_helper(fixture("portable.txt"), active_host: "claude").first,
      run_helper(fixture("codex-to-claude.txt"), active_host: "claude").first,
      run_helper(fixture("ambiguous-host.txt"), active_host: "unknown").first
    ]
    outputs.each { |output| assert schema.valid?(output), schema.validate(output).to_a.inspect }

    compatible = outputs.fetch(0)
    portable = outputs.fetch(1)
    conversion = outputs.fetch(2)
    error = outputs.fetch(3)
    unsafe_records = [
      compatible.merge("execute_allowed" => false),
      compatible.merge("prompt_host" => "claude"),
      compatible.merge("prompt" => nil, "converted_prompt" => "unexpected"),
      portable.merge("adapter_contract" => nil),
      portable.merge("prompt_mode" => "goal"),
      conversion.merge("execute_allowed" => true),
      conversion.merge("stop_required" => false),
      conversion.merge("prompt" => fixture("codex-to-claude.txt")),
      conversion.merge("converted_prompt" => nil),
      conversion.merge("active_host" => "codex"),
      error.merge("error" => "unregistered-error")
    ]
    unsafe_records.each { |record| refute schema.valid?(record), record.inspect }
  end

  def test_schema_exposes_only_the_three_decisions_and_keeps_errors_separate
    schema = JSON.parse(File.read(SCHEMA, encoding: "UTF-8"))
    success = schema.fetch("$defs").fetch("success")
    error = schema.fetch("oneOf").last

    assert_equal DECISIONS, success.dig("properties", "decision", "enum")
    assert_includes success.fetch("required"), "decision"
    refute_includes error.fetch("properties").keys, "decision"
    assert_includes error.fetch("required"), "error"
    schema.fetch("oneOf").first(3).each do |decision_branch|
      assert_equal false, decision_branch.fetch("unevaluatedProperties")
    end
    assert_equal false, error.fetch("additionalProperties")
  end

  def test_pre_security_intake_never_executes_a_target_checkout_helper
    intake = File.read(INTAKE, encoding: "UTF-8")

    assert_includes intake, "Never execute the current checkout's repo-pinned\nhelper"
    assert_includes intake, "after the security floor establishes their trusted provenance"
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
