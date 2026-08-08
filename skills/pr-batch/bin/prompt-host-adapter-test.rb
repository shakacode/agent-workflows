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
    [JSON.parse(stdout), stderr, status, stdout]
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

  def legacy_prompt(host:, body:)
    invocation = {
      "codex" => "/goal\nUse $pr-batch to complete the batch.",
      "claude" => "/pr-batch complete the batch."
    }.fetch(host)
    "#{invocation}\n#{body}\n"
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

  def test_generated_triage_prompt_converts_every_canonical_mechanic_in_both_directions
    cases = [
      {
        source_host: "codex",
        active_host: "claude",
        source_wrapper: "/goal\n",
        expected_wrapper: "",
        source_mode: "goal",
        expected_mode: "batch",
        source_sigil: "$",
        expected_sigil: "/"
      },
      {
        source_host: "claude",
        active_host: "codex",
        source_wrapper: "",
        expected_wrapper: "/goal\n",
        source_mode: "batch",
        expected_mode: "goal",
        source_sigil: "/",
        expected_sigil: "$"
      }
    ]

    cases.each do |entry|
      prompt = <<~PROMPT
        #{entry.fetch(:source_wrapper)}Prompt host: #{entry.fetch(:source_host)}
        Prompt mode: #{entry.fetch(:source_mode)}
        Preferred route: default
        Route requirement: advisory
        Use #{entry.fetch(:source_sigil)}pr-batch to complete this generated triage batch with subagents.
        Batch size target: #{entry.fetch(:source_host)}; wave: 1/1.
        - Resolve `base_branch` via repo/`AGENTS.md` config; fetch/prune origin; verify #{entry.fetch(:source_sigil)}pr-batch+workflow; unresolved=>UNKNOWN.
        - ask=>#{entry.fetch(:source_sigil)}pr-walkthrough;large/complex full;refresh;chg=>redo/stop;gate fail=>stop;ask iff same clean
      PROMPT
      expected = <<~PROMPT
        #{entry.fetch(:expected_wrapper)}Prompt host: #{entry.fetch(:active_host)}
        Prompt mode: #{entry.fetch(:expected_mode)}
        Preferred route: default
        Route requirement: advisory
        Use #{entry.fetch(:expected_sigil)}pr-batch to complete this generated triage batch with subagents.
        Batch size target: #{entry.fetch(:active_host)}; wave: 1/1.
        - Resolve `base_branch` via repo/`AGENTS.md` config; fetch/prune origin; verify #{entry.fetch(:expected_sigil)}pr-batch+workflow; unresolved=>UNKNOWN.
        - ask=>#{entry.fetch(:expected_sigil)}pr-walkthrough;large/complex full;refresh;chg=>redo/stop;gate fail=>stop;ask iff same clean
      PROMPT

      result, stderr, status = run_adapter(prompt, active_host: entry.fetch(:active_host))

      assert status.success?, stderr
      assert_equal "conversion-required", result.fetch("classification"), entry.inspect
      assert_equal false, result.fetch("execute_allowed"), entry.inspect
      assert_equal true, result.fetch("relaunch_required"), entry.inspect
      assert_equal true, result.fetch("replanning_required"), entry.inspect
      assert_equal true, result.fetch("semantic_payload_preserved"), entry.inspect
      assert_equal expected, result.fetch("prompt"), entry.inspect

      relaunched, relaunch_stderr, relaunch_status = run_adapter(expected, active_host: entry.fetch(:active_host))
      assert relaunch_status.success?, relaunch_stderr
      assert_equal "compatible", relaunched.fetch("classification"), entry.inspect
      assert_equal expected, relaunched.fetch("prompt"), entry.inspect
    end
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

  def test_header_like_malformed_declarations_block_legacy_inference_without_echo
    malformed_lines = [
      "Prompt host : claude",
      " Prompt mode: batch",
      "preferred route: default",
      "Route-requirement: advisory",
      "Prompt host:: claude",
      "Prompt_host: claude",
      "PREFERRED ROUTE: default",
      "Route requirement = advisory"
    ]

    %w[codex claude].each do |legacy_host|
      malformed_lines.each_with_index do |line, index|
        marker = "SECRET_MALFORMED_HEADER_#{legacy_host.upcase}_#{index}"
        prompt = legacy_prompt(host: legacy_host, body: "#{line}\nObjective: #{marker}")

        %w[codex claude].each do |active_host|
          result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

          assert status.success?, stderr
          assert_equal "ambiguous", result.fetch("classification"), line
          assert_equal "malformed-headers", result.fetch("reason_code"), line
          assert_nil result.fetch("declared_host"), line
          assert_equal false, result.fetch("execute_allowed"), line
          assert_equal false, result.fetch("relaunch_required"), line
          assert_nil result.fetch("prompt"), line
          refute_includes stdout, marker
        end
      end
    end

    incidental_prose = [
      "Discuss the Prompt host field as an incidental name.",
      "Document Prompt host: claude as literal prose.",
      "The preferred route is advisory prose.",
      "Describe Route requirement: advisory without declaring a header."
    ]
    %w[codex claude].each do |host|
      incidental_prose.each do |prose|
        prompt = legacy_prompt(host: host, body: prose)
        result, stderr, status = run_adapter(prompt, active_host: host)

        assert status.success?, stderr
        assert_equal "compatible", result.fetch("classification"), prose
        assert_equal true, result.fetch("execute_allowed"), prose
        assert_equal prompt, result.fetch("prompt"), prose
      end

      prompt = direct_prompt(host: host, body: "Objective: preserve complete valid headers.")
      result, stderr, status = run_adapter(prompt, active_host: host)

      assert status.success?, stderr
      assert_equal "compatible", result.fetch("classification"), host
      assert_equal true, result.fetch("execute_allowed"), host
      assert_equal prompt, result.fetch("prompt"), host
    end
  end

  def test_legacy_malformed_or_contradictory_batch_size_target_fails_closed_without_echo
    cases = [
      ["Codex matching unsupported", "codex", "codex", "rust; wave: 1/1.", "invalid-batch-size-target"],
      ["Codex cross malformed", "codex", "claude", "codex wave: 1/1.", "invalid-batch-size-target"],
      ["Claude matching unsupported", "claude", "claude", "rust; wave: 1/1.", "invalid-batch-size-target"],
      ["Claude cross malformed", "claude", "codex", "claude wave: 1/1.", "invalid-batch-size-target"],
      ["Codex matching contradiction", "codex", "codex", "claude; wave: 1/1.",
       "contradictory-batch-size-target"],
      ["Codex cross source contradiction", "codex", "claude", "claude; wave: 1/1.",
       "contradictory-batch-size-target"],
      ["Claude matching contradiction", "claude", "claude", "codex; wave: 1/1.",
       "contradictory-batch-size-target"],
      ["Claude cross source contradiction", "claude", "codex", "codex; wave: 1/1.",
       "contradictory-batch-size-target"]
    ]

    cases.each do |label, legacy_host, active_host, field_value, reason_code|
      marker = "SECRET_#{label.upcase.gsub(/\W+/, '_')}"
      prompt = legacy_prompt(
        host: legacy_host,
        body: "Batch size target: #{field_value}\nObjective: #{marker}"
      )

      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), label
      assert_equal reason_code, result.fetch("reason_code"), label
      assert_equal legacy_host, result.fetch("declared_host"), label
      assert_equal false, result.fetch("execute_allowed"), label
      assert_equal false, result.fetch("relaunch_required"), label
      assert_equal false, result.fetch("replanning_required"), label
      assert_nil result.fetch("semantic_payload_preserved"), label
      assert_nil result.fetch("prompt"), label
      refute_includes stdout, marker
    end
  end

  def test_legacy_duplicate_batch_size_target_fails_closed_without_echo
    cases = [
      ["Codex matching identical", "codex", "codex", %w[codex codex]],
      ["Codex matching conflicting", "codex", "codex", %w[codex claude]],
      ["Codex cross identical", "codex", "claude", %w[codex codex]],
      ["Codex cross conflicting", "codex", "claude", %w[codex claude]],
      ["Claude matching identical", "claude", "claude", %w[claude claude]],
      ["Claude matching conflicting", "claude", "claude", %w[claude codex]],
      ["Claude cross identical", "claude", "codex", %w[claude claude]],
      ["Claude cross conflicting", "claude", "codex", %w[claude codex]]
    ]

    cases.each do |label, legacy_host, active_host, targets|
      marker = "SECRET_#{label.upcase.gsub(/\W+/, '_')}"
      fields = targets.map { |target| "Batch size target: #{target}; wave: 1/1." }.join("\n")
      prompt = legacy_prompt(host: legacy_host, body: "#{fields}\nObjective: #{marker}")

      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), label
      assert_equal "duplicate-batch-size-target", result.fetch("reason_code"), label
      assert_equal legacy_host, result.fetch("declared_host"), label
      assert_equal false, result.fetch("execute_allowed"), label
      assert_equal false, result.fetch("relaunch_required"), label
      assert_equal false, result.fetch("replanning_required"), label
      assert_nil result.fetch("semantic_payload_preserved"), label
      assert_nil result.fetch("prompt"), label
      refute_includes stdout, marker
    end
  end

  def test_legacy_valid_batch_size_target_matches_converts_and_relaunches_with_omission_preserved
    cases = [
      {
        source_host: "codex",
        target_host: "claude",
        expected_with_field: <<~PROMPT,
          Prompt host: claude
          Prompt mode: batch
          Preferred route: default
          Route requirement: advisory
          Use /pr-batch to complete the batch.
          Batch size target: claude; wave: 1/1.
          Objective: Preserve legacy Codex payload.
        PROMPT
        expected_without_field: <<~PROMPT
          Prompt host: claude
          Prompt mode: batch
          Preferred route: default
          Route requirement: advisory
          Use /pr-batch to complete the batch.
          Objective: Preserve legacy Codex payload.
        PROMPT
      },
      {
        source_host: "claude",
        target_host: "codex",
        expected_with_field: <<~PROMPT,
          /goal
          Prompt host: codex
          Prompt mode: goal
          Preferred route: default
          Route requirement: advisory
          Use $pr-batch complete the batch.
          Batch size target: codex; wave: 1/1.
          Objective: Preserve legacy Claude payload.
        PROMPT
        expected_without_field: <<~PROMPT
          /goal
          Prompt host: codex
          Prompt mode: goal
          Preferred route: default
          Route requirement: advisory
          Use $pr-batch complete the batch.
          Objective: Preserve legacy Claude payload.
        PROMPT
      }
    ]

    cases.each do |entry|
      source_host = entry.fetch(:source_host)
      target_host = entry.fetch(:target_host)
      objective = "Preserve legacy #{source_host.capitalize} payload."
      matching_prompt = legacy_prompt(
        host: source_host,
        body: "Batch size target: #{source_host}; wave: 1/1.\nObjective: #{objective}"
      )

      matching, matching_stderr, matching_status = run_adapter(matching_prompt, active_host: source_host)
      assert matching_status.success?, matching_stderr
      assert_equal "compatible", matching.fetch("classification"), entry.inspect
      assert_equal true, matching.fetch("execute_allowed"), entry.inspect
      assert_equal matching_prompt, matching.fetch("prompt"), entry.inspect

      converted, converted_stderr, converted_status = run_adapter(matching_prompt, active_host: target_host)
      assert converted_status.success?, converted_stderr
      assert_equal "conversion-required", converted.fetch("classification"), entry.inspect
      assert_equal false, converted.fetch("execute_allowed"), entry.inspect
      assert_equal true, converted.fetch("relaunch_required"), entry.inspect
      assert_equal true, converted.fetch("replanning_required"), entry.inspect
      assert_equal true, converted.fetch("semantic_payload_preserved"), entry.inspect
      assert_equal entry.fetch(:expected_with_field), converted.fetch("prompt"), entry.inspect

      relaunched, relaunch_stderr, relaunch_status = run_adapter(
        entry.fetch(:expected_with_field),
        active_host: target_host
      )
      assert relaunch_status.success?, relaunch_stderr
      assert_equal "compatible", relaunched.fetch("classification"), entry.inspect
      assert_equal true, relaunched.fetch("execute_allowed"), entry.inspect
      assert_equal entry.fetch(:expected_with_field), relaunched.fetch("prompt"), entry.inspect

      omitted_prompt = legacy_prompt(host: source_host, body: "Objective: #{objective}")
      omitted_matching, omitted_stderr, omitted_status = run_adapter(omitted_prompt, active_host: source_host)
      assert omitted_status.success?, omitted_stderr
      assert_equal "compatible", omitted_matching.fetch("classification"), entry.inspect
      assert_equal omitted_prompt, omitted_matching.fetch("prompt"), entry.inspect

      omitted_converted, omitted_cross_stderr, omitted_cross_status = run_adapter(
        omitted_prompt,
        active_host: target_host
      )
      assert omitted_cross_status.success?, omitted_cross_stderr
      assert_equal "conversion-required", omitted_converted.fetch("classification"), entry.inspect
      assert_equal false, omitted_converted.fetch("execute_allowed"), entry.inspect
      assert_equal true, omitted_converted.fetch("relaunch_required"), entry.inspect
      assert_equal false, omitted_converted.fetch("replanning_required"), entry.inspect
      assert_equal entry.fetch(:expected_without_field), omitted_converted.fetch("prompt"), entry.inspect
    end
  end

  def test_legacy_codex_canonical_mechanics_convert_to_claude
    prompt = <<~PROMPT
      /goal
      Use $pr-batch to continue the verified batch.
      Base:repo/AGENTS;fetch/prune origin;verify $pr-batch+workflow;unresolved=>UNKNOWN
      - Resolve $pr-batch; load persisted state before launch.
      - ask=>$pr-walkthrough;gate fail=>stop
    PROMPT
    expected = <<~PROMPT
      Prompt host: claude
      Prompt mode: batch
      Preferred route: default
      Route requirement: advisory
      Use /pr-batch to continue the verified batch.
      Base:repo/AGENTS;fetch/prune origin;verify /pr-batch+workflow;unresolved=>UNKNOWN
      - Resolve /pr-batch; load persisted state before launch.
      - ask=>/pr-walkthrough;gate fail=>stop
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("semantic_payload_preserved")
    assert_equal expected, result.fetch("prompt")

    relaunched, relaunch_stderr, relaunch_status = run_adapter(expected, active_host: "claude")
    assert relaunch_status.success?, relaunch_stderr
    assert_equal "compatible", relaunched.fetch("classification")
    assert_equal expected, relaunched.fetch("prompt")
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

  def test_contradictory_batch_size_target_fails_closed_without_echo
    cases = [
      %w[claude claude codex],
      %w[codex codex claude],
      %w[codex claude claude],
      %w[claude codex codex]
    ]

    cases.each do |declared_host, active_host, batch_size_target|
      marker = "SECRET_#{declared_host.upcase}_#{active_host.upcase}_#{batch_size_target.upcase}"
      prompt = direct_prompt(
        host: declared_host,
        body: "Batch size target: #{batch_size_target}; wave: 1/1. #{marker}"
      )

      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), marker
      assert_equal "contradictory-batch-size-target", result.fetch("reason_code"), marker
      assert_equal false, result.fetch("execute_allowed"), marker
      assert_equal false, result.fetch("relaunch_required"), marker
      assert_nil result.fetch("semantic_payload_preserved"), marker
      assert_nil result.fetch("prompt"), marker
      refute_includes stdout, marker
    end
  end

  def test_matching_and_portable_generic_batch_size_targets_remain_byte_exact
    cases = [
      %w[codex codex codex compatible],
      %w[claude claude claude compatible],
      %w[portable codex generic portable],
      %w[portable claude generic portable]
    ]

    cases.each do |declared_host, active_host, batch_size_target, classification|
      prompt = direct_prompt(
        host: declared_host,
        body: "Batch size target: #{batch_size_target}; wave: 1/1."
      )

      result, stderr, status = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal classification, result.fetch("classification"), prompt
      assert_equal true, result.fetch("execute_allowed"), prompt
      assert_equal prompt, result.fetch("prompt"), prompt
    end
  end

  def test_prefixed_batch_size_targets_share_the_canonical_field_contract
    prefixes = ["  ", "- ", "  - ", "* ", "+ "]

    prefixes.each do |prefix|
      [%w[codex codex], %w[claude claude]].each do |declared_host, active_host|
        prompt = direct_prompt(
          host: declared_host,
          body: "#{prefix}Batch size target: #{declared_host}; wave: 1/1."
        )
        result, stderr, status = run_adapter(prompt, active_host: active_host)

        assert status.success?, stderr
        assert_equal "compatible", result.fetch("classification"), prefix.inspect
        assert_equal true, result.fetch("execute_allowed"), prefix.inspect
        assert_equal prompt, result.fetch("prompt"), prefix.inspect
      end

      %w[codex claude].each do |active_host|
        prompt = direct_prompt(
          host: "portable",
          body: "#{prefix}Batch size target: generic; wave: 1/1."
        )
        result, stderr, status = run_adapter(prompt, active_host: active_host)

        assert status.success?, stderr
        assert_equal "portable", result.fetch("classification"), prefix.inspect
        assert_equal true, result.fetch("execute_allowed"), prefix.inspect
        assert_equal prompt, result.fetch("prompt"), prefix.inspect
      end
    end

    contradictory_cases = [
      [direct_prompt(host: "codex", body: "  Batch size target: claude; SECRET_PREFIX_CONTRADICT_1"),
       "codex"],
      [direct_prompt(host: "claude", body: "- Batch size target: codex; SECRET_PREFIX_CONTRADICT_2"),
       "claude"],
      [direct_prompt(host: "portable", body: "  - Batch size target: codex; SECRET_PREFIX_CONTRADICT_3"),
       "codex"],
      [direct_prompt(host: "codex", body: "* Batch size target: claude; SECRET_PREFIX_CONTRADICT_4"),
       "claude"],
      [legacy_prompt(host: "codex", body: "+ Batch size target: claude; SECRET_PREFIX_CONTRADICT_5"),
       "codex"],
      [legacy_prompt(host: "claude", body: "  Batch size target: codex; SECRET_PREFIX_CONTRADICT_6"),
       "codex"]
    ]
    contradictory_cases.each do |prompt, active_host|
      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification")
      assert_equal "contradictory-batch-size-target", result.fetch("reason_code")
      assert_equal false, result.fetch("execute_allowed")
      assert_equal false, result.fetch("relaunch_required")
      assert_nil result.fetch("prompt")
      refute_includes stdout, "SECRET_PREFIX_CONTRADICT"
    end

    malformed_cases = [
      [direct_prompt(host: "codex", body: "  Batch size target: rust; SECRET_PREFIX_MALFORMED_1"), "codex"],
      [direct_prompt(host: "claude", body: "- Batch size target: claude SECRET_PREFIX_MALFORMED_2"), "codex"],
      [direct_prompt(host: "portable", body: "  - Batch size target: generic SECRET_PREFIX_MALFORMED_3"), "claude"],
      [legacy_prompt(host: "codex", body: "* Batch size target: codex SECRET_PREFIX_MALFORMED_4"), "codex"],
      [legacy_prompt(host: "claude", body: "+ Batch size target: rust; SECRET_PREFIX_MALFORMED_5"), "codex"]
    ]
    malformed_cases.each do |prompt, active_host|
      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification")
      assert_equal "invalid-batch-size-target", result.fetch("reason_code")
      assert_equal false, result.fetch("execute_allowed")
      assert_equal false, result.fetch("relaunch_required")
      assert_nil result.fetch("prompt")
      refute_includes stdout, "SECRET_PREFIX_MALFORMED"
    end

    duplicate_cases = [
      [direct_prompt(
        host: "codex",
        body: "  Batch size target: codex;\n- Batch size target: codex; SECRET_PREFIX_DUPLICATE_1"
      ), "codex"],
      [direct_prompt(
        host: "claude",
        body: "* Batch size target: claude;\n+ Batch size target: codex; SECRET_PREFIX_DUPLICATE_2"
      ), "codex"],
      [direct_prompt(
        host: "portable",
        body: "Batch size target: generic;\n  - Batch size target: generic; SECRET_PREFIX_DUPLICATE_3"
      ), "claude"],
      [legacy_prompt(
        host: "codex",
        body: "  Batch size target: codex;\n* Batch size target: claude; SECRET_PREFIX_DUPLICATE_4"
      ), "codex"],
      [legacy_prompt(
        host: "claude",
        body: "- Batch size target: claude;\n  Batch size target: claude; SECRET_PREFIX_DUPLICATE_5"
      ), "codex"]
    ]
    duplicate_cases.each do |prompt, active_host|
      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification")
      assert_equal "duplicate-batch-size-target", result.fetch("reason_code")
      assert_equal false, result.fetch("execute_allowed")
      assert_equal false, result.fetch("relaunch_required")
      assert_nil result.fetch("prompt")
      refute_includes stdout, "SECRET_PREFIX_DUPLICATE"
    end

    [
      ["codex", "claude", "  "],
      ["claude", "codex", "- "]
    ].each do |source_host, target_host, prefix|
      prompt = direct_prompt(
        host: source_host,
        body: "#{prefix}Batch size target: #{source_host}; wave: 1/1."
      )
      expected = direct_prompt(
        host: target_host,
        body: "#{prefix}Batch size target: #{target_host}; wave: 1/1."
      )
      result, stderr, status = run_adapter(prompt, active_host: target_host)

      assert status.success?, stderr
      assert_equal "conversion-required", result.fetch("classification"), prefix.inspect
      assert_equal false, result.fetch("execute_allowed"), prefix.inspect
      assert_equal true, result.fetch("relaunch_required"), prefix.inspect
      assert_equal true, result.fetch("replanning_required"), prefix.inspect
      assert_equal true, result.fetch("semantic_payload_preserved"), prefix.inspect
      assert_equal expected, result.fetch("prompt"), prefix.inspect

      relaunched, relaunch_stderr, relaunch_status = run_adapter(expected, active_host: target_host)
      assert relaunch_status.success?, relaunch_stderr
      assert_equal "compatible", relaunched.fetch("classification"), prefix.inspect
      assert_equal expected, relaunched.fetch("prompt"), prefix.inspect
    end

    legacy_conversions = [
      {
        source_host: "codex",
        target_host: "claude",
        prefix: "  ",
        expected: <<~PROMPT
          Prompt host: claude
          Prompt mode: batch
          Preferred route: default
          Route requirement: advisory
          Use /pr-batch to complete the batch.
            Batch size target: claude; wave: 1/1.
        PROMPT
      },
      {
        source_host: "claude",
        target_host: "codex",
        prefix: "- ",
        expected: <<~PROMPT
          /goal
          Prompt host: codex
          Prompt mode: goal
          Preferred route: default
          Route requirement: advisory
          Use $pr-batch complete the batch.
          - Batch size target: codex; wave: 1/1.
        PROMPT
      }
    ]
    legacy_conversions.each do |entry|
      prompt = legacy_prompt(
        host: entry.fetch(:source_host),
        body: "#{entry.fetch(:prefix)}Batch size target: #{entry.fetch(:source_host)}; wave: 1/1."
      )
      result, stderr, status = run_adapter(prompt, active_host: entry.fetch(:target_host))

      assert status.success?, stderr
      assert_equal "conversion-required", result.fetch("classification"), entry.inspect
      assert_equal true, result.fetch("replanning_required"), entry.inspect
      assert_equal true, result.fetch("semantic_payload_preserved"), entry.inspect
      assert_equal entry.fetch(:expected), result.fetch("prompt"), entry.inspect

      relaunched, relaunch_stderr, relaunch_status = run_adapter(
        entry.fetch(:expected),
        active_host: entry.fetch(:target_host)
      )
      assert relaunch_status.success?, relaunch_stderr
      assert_equal "compatible", relaunched.fetch("classification"), entry.inspect
    end

    ordinary_prose = "Objective: document the phrase Batch size target: claude; without declaring a field."
    %w[codex claude].each do |host|
      prompt = direct_prompt(host: host, body: ordinary_prose)
      result, stderr, status = run_adapter(prompt, active_host: host)

      assert status.success?, stderr
      assert_equal "compatible", result.fetch("classification"), host
      assert_equal true, result.fetch("execute_allowed"), host
      assert_equal prompt, result.fetch("prompt"), host
    end
  end

  def test_malformed_or_unsupported_batch_size_target_fails_closed_without_echo
    cases = [
      ["matching Codex", "codex", "codex", "rust; wave: 1/1."],
      ["matching Claude", "claude", "claude", "claude wave: 1/1."],
      ["cross-host conversion", "codex", "claude", "rust; wave: 1/1."],
      ["converted relaunch", "claude", "claude", "rust; wave: 1/1."],
      ["portable unsupported value", "portable", "codex", "rust; wave: 1/1."],
      ["portable malformed delimiter", "portable", "claude", "generic wave: 1/1."]
    ]

    cases.each do |label, declared_host, active_host, field_value|
      marker = "SECRET_#{label.upcase.gsub(/\W+/, '_')}"
      prompt = direct_prompt(
        host: declared_host,
        body: "Batch size target: #{field_value}\nObjective: #{marker}"
      )

      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), label
      assert_equal "invalid-batch-size-target", result.fetch("reason_code"), label
      assert_equal false, result.fetch("execute_allowed"), label
      assert_equal false, result.fetch("relaunch_required"), label
      assert_equal false, result.fetch("replanning_required"), label
      assert_nil result.fetch("semantic_payload_preserved"), label
      assert_nil result.fetch("prompt"), label
      refute_includes stdout, marker
    end
  end

  def test_duplicate_batch_size_target_fails_closed_without_echo
    cases = [
      ["matching identical", "codex", "codex", %w[codex codex]],
      ["matching conflicting", "codex", "codex", %w[codex claude]],
      ["cross-host identical", "codex", "claude", %w[codex codex]],
      ["cross-host conflicting", "codex", "claude", %w[codex claude]],
      ["converted relaunch identical", "claude", "claude", %w[claude claude]],
      ["portable identical", "portable", "codex", %w[generic generic]],
      ["portable conflicting", "portable", "claude", %w[generic codex]]
    ]

    cases.each do |label, declared_host, active_host, targets|
      marker = "SECRET_#{label.upcase.gsub(/\W+/, '_')}"
      fields = targets.map { |target| "Batch size target: #{target}; wave: 1/1." }.join("\n")
      prompt = direct_prompt(host: declared_host, body: "#{fields}\nObjective: #{marker}")

      result, stderr, status, stdout = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), label
      assert_equal "duplicate-batch-size-target", result.fetch("reason_code"), label
      assert_equal false, result.fetch("execute_allowed"), label
      assert_equal false, result.fetch("relaunch_required"), label
      assert_equal false, result.fetch("replanning_required"), label
      assert_nil result.fetch("semantic_payload_preserved"), label
      assert_nil result.fetch("prompt"), label
      refute_includes stdout, marker
    end
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

  def test_neutral_canonical_mechanics_fail_closed_for_host_specific_prompts_only
    mechanics = [
      "- ask=>pr-walkthrough;gate fail=>stop",
      "Base:repo/AGENTS;fetch/prune origin;verify pr-batch+workflow;unresolved=>UNKNOWN",
      "- Resolve pr-batch; load persisted state before launch.",
      "- Resolve `base_branch` via repo/`AGENTS.md` config; fetch/prune origin; " \
        "verify pr-batch+workflow; unresolved=>UNKNOWN."
    ]

    %w[codex claude].each do |declared_host|
      mechanics.each do |mechanic|
        marker = "SECRET_NEUTRAL_#{declared_host.upcase}_#{mechanics.index(mechanic)}"
        prompt = direct_prompt(host: declared_host, body: "#{mechanic}\nObjective: #{marker}")

        result, stderr, status, stdout = run_adapter(prompt, active_host: declared_host)

        assert status.success?, stderr
        assert_equal "ambiguous", result.fetch("classification"), mechanic
        assert_equal "unsupported-host-mechanic", result.fetch("reason_code"), mechanic
        assert_equal false, result.fetch("execute_allowed"), mechanic
        assert_equal false, result.fetch("relaunch_required"), mechanic
        assert_nil result.fetch("prompt"), mechanic
        refute_includes stdout, marker
      end

      prompt = legacy_prompt(host: declared_host, body: mechanics.last)
      result, stderr, status = run_adapter(prompt, active_host: declared_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), declared_host
      assert_equal "unsupported-host-mechanic", result.fetch("reason_code"), declared_host
      assert_equal false, result.fetch("execute_allowed"), declared_host
      assert_nil result.fetch("prompt"), declared_host
    end

    [%w[codex claude], %w[claude codex]].each do |declared_host, active_host|
      prompt = direct_prompt(host: declared_host, body: mechanics.first)
      result, stderr, status = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal "ambiguous", result.fetch("classification"), declared_host
      assert_equal "unsupported-host-mechanic", result.fetch("reason_code"), declared_host
      assert_equal false, result.fetch("execute_allowed"), declared_host
      assert_equal false, result.fetch("relaunch_required"), declared_host
      assert_nil result.fetch("prompt"), declared_host
    end

    %w[codex claude].each do |active_host|
      mechanics.each do |mechanic|
        prompt = direct_prompt(host: "portable", body: mechanic)
        result, stderr, status = run_adapter(prompt, active_host: active_host)

        assert status.success?, stderr
        assert_equal "portable", result.fetch("classification"), mechanic
        assert_equal true, result.fetch("execute_allowed"), mechanic
        assert_equal prompt, result.fetch("prompt"), mechanic
      end
    end

    incidental_prose = [
      "Document pr-batch and pr-walkthrough as literal names only.",
      "Inspect skills/pr-batch/bin/prompt-host-adapter before closeout.",
      "The Base verifier discusses pr-batch+workflow in prose.",
      "Resolve the pr-batch documentation before launch."
    ]
    %w[codex claude].each do |host|
      incidental_prose.each do |prose|
        prompt = direct_prompt(host: host, body: prose)
        result, stderr, status = run_adapter(prompt, active_host: host)

        assert status.success?, stderr
        assert_equal "compatible", result.fetch("classification"), prose
        assert_equal true, result.fetch("execute_allowed"), prose
        assert_equal prompt, result.fetch("prompt"), prose
      end
    end
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

  def test_arbitrary_sigiled_commands_are_host_mechanics_without_a_verb_allowlist
    cases = [
      ["claude", "claude", "Execute $address-review before closeout."],
      ["claude", "claude", "Trigger $address-review before closeout."],
      ["claude", "claude", "Launch $address-review before closeout."],
      ["claude", "claude", "Apply $address-review before closeout."],
      ["claude", "claude", "  - $address-review before closeout."],
      ["codex", "codex", "Execute /address-review before closeout."],
      ["portable", "codex", "Trigger $address-review before closeout."],
      ["portable", "claude", "  - /address-review before closeout."],
      ["claude", "claude", "Execute $address-review; document $address-review as literal names only."]
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
    end
  end

  def test_case_variant_and_underscore_sigiled_commands_fail_closed
    cases = [
      ["claude", "claude", "Execute $PR-Batch before closeout."],
      ["codex", "codex", "Execute /Pr-Walkthrough before closeout."],
      ["claude", "claude", "Execute $pr_batch before closeout."],
      ["portable", "codex", "Execute /PR-BATCH before closeout."],
      ["portable", "claude", "Execute $pr_batch before closeout."]
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
    end
  end

  def test_punctuation_delimited_sigiled_commands_fail_closed
    cases = [
      ["codex", "codex", "Execute:/address-review before closeout."],
      ["claude", "claude", "Execute:$address-review before closeout."],
      ["codex", "codex", "Trigger./address-review before closeout."],
      ["claude", "claude", "Launch-$address-review before closeout."],
      ["portable", "codex", "Apply:/address-review before closeout."],
      ["portable", "claude", "Apply:$address-review before closeout."],
      ["portable", "codex", "Trigger./address-review before closeout."],
      ["portable", "claude", "Launch-$address-review before closeout."]
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
    end
  end

  def test_conversion_rejects_punctuation_delimited_residual_target_mechanics_before_relaunch
    prompt = direct_prompt(
      host: "codex",
      body: "Execute:$address-review before closeout."
    )
    result, stderr, status = run_adapter(prompt, active_host: "claude")

    assert status.success?, stderr
    assert_equal "ambiguous", result.fetch("classification")
    assert_equal "unsupported-host-mechanic", result.fetch("reason_code")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal false, result.fetch("relaunch_required")
    assert_nil result.fetch("prompt")
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
      prompt = direct_prompt(host: declared_host, body: prose)
      result, stderr, status = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      expected = declared_host == "portable" ? "portable" : "compatible"
      assert_equal expected, result.fetch("classification"), prose
      assert_equal true, result.fetch("execute_allowed"), prose
      assert_equal prompt, result.fetch("prompt"), prose
    end
  end

  def test_filesystem_paths_and_urls_are_not_slash_command_mechanics
    cases = [
      ["codex", "codex", "Inspect /tmp/work/file before closeout.", "compatible"],
      ["codex", "codex", "Inspect /tmp.json before closeout.", "compatible"],
      ["portable", "codex", "Read /var/data.json as evidence.", "portable"],
      ["portable", "claude", "Compare /tmp/work/file with /var/data.json.", "portable"],
      ["portable", "codex", "Review https://example.com/address-review as evidence.", "portable"],
      ["portable", "claude", "Inspect ./address-review, ../address-review, and ~/address-review.", "portable"]
    ]

    cases.each do |declared_host, active_host, prose, expected_classification|
      prompt = direct_prompt(host: declared_host, body: prose)
      result, stderr, status = run_adapter(prompt, active_host: active_host)

      assert status.success?, stderr
      assert_equal expected_classification, result.fetch("classification"), prose
      assert_equal true, result.fetch("execute_allowed"), prose
      assert_equal prompt, result.fetch("prompt"), prose
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

    normal_result, normal_stderr, normal_status, normal_stdout = run_adapter(prompt, active_host: "claude")
    assert normal_status.success?, normal_stderr

    result, stderr, status, stdout = run_adapter(prompt, active_host: "claude", env: env)

    assert status.success?, stderr
    assert_equal normal_result, result
    assert_equal normal_stdout, stdout
    assert_equal normal_stderr, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_includes result.fetch("prompt"), "café and 東京"

    relaunched, relaunch_stderr, relaunch_status, relaunch_stdout = run_adapter(
      result.fetch("prompt"),
      active_host: "claude",
      env: env
    )
    normal_relaunched, normal_relaunch_stderr, normal_relaunch_status, normal_relaunch_stdout = run_adapter(
      result.fetch("prompt"),
      active_host: "claude"
    )
    assert normal_relaunch_status.success?, normal_relaunch_stderr
    assert relaunch_status.success?, relaunch_stderr
    assert_equal normal_relaunched, relaunched
    assert_equal normal_relaunch_stdout, relaunch_stdout
    assert_equal normal_relaunch_stderr, relaunch_stderr
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

  def test_legacy_claude_canonical_mechanics_convert_to_codex
    prompt = <<~PROMPT
      /pr-batch continue the verified batch.
      Base:repo/AGENTS;fetch/prune origin;verify /pr-batch+workflow;unresolved=>UNKNOWN
      - Resolve /pr-batch; load persisted state before launch.
      - ask=>/pr-walkthrough;gate fail=>stop
    PROMPT
    expected = <<~PROMPT
      /goal
      Prompt host: codex
      Prompt mode: goal
      Preferred route: default
      Route requirement: advisory
      Use $pr-batch continue the verified batch.
      Base:repo/AGENTS;fetch/prune origin;verify $pr-batch+workflow;unresolved=>UNKNOWN
      - Resolve $pr-batch; load persisted state before launch.
      - ask=>$pr-walkthrough;gate fail=>stop
    PROMPT

    result, stderr, status = run_adapter(prompt, active_host: "codex")

    assert status.success?, stderr
    assert_equal "conversion-required", result.fetch("classification")
    assert_equal false, result.fetch("execute_allowed")
    assert_equal true, result.fetch("semantic_payload_preserved")
    assert_equal expected, result.fetch("prompt")

    relaunched, relaunch_stderr, relaunch_status = run_adapter(expected, active_host: "codex")
    assert relaunch_status.success?, relaunch_stderr
    assert_equal "compatible", relaunched.fetch("classification")
    assert_equal expected, relaunched.fetch("prompt")
  end
end
