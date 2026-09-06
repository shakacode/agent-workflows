#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

# Source-contract checks protect the instructions; model behavior is evaluated
# separately by the Astra behavioral scenarios, not inferred from these tests.
class AuthorizedCompletionTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def text(path)
    File.read(File.join(ROOT, path)).gsub(/\s+/, " ")
  end

  def test_continue_preserves_authorized_outcome_and_explicit_boundary
    skill = text("skills/continue/SKILL.md")

    assert_match(/Continue through the \*\*authorized outcome\*\*/, skill)
    assert_match(/Honor an explicit one-step or otherwise bounded request/, skill)
    refute_match(/Stop after completing the objective/, skill)
    assert_match(/never push or take irreversible actions unless the task already authorized them/, skill)
  end

  def test_verify_exhaustion_routes_to_bounded_diagnosis_without_waiving_failure
    skill = text("skills/verify/SKILL.md")

    assert_match(/After three consecutive cycles.*one bounded diagnosis pass/, skill)
    assert_match(/Do not reset the counter to repeat this pass/, skill)
    assert_match(/coordinator resolves decisions within existing authority/, skill)
    assert_match(/never waives a required gate/, skill)
    refute_match(/Ask the user how to proceed rather than/, skill)
  end

  def test_spec_distinguishes_standalone_from_authorized_implementation
    skill = text("skills/spec/SKILL.md")

    assert_match(/standalone specification or plan-only request.*do not implement/, skill)
    assert_match(/authorized implementation task.*same task/, skill)
    assert_match(/spec does not itself authorize implementation, publication, or merge/, skill)
    refute_match(/Action needed: Start a new planning task/, skill)
  end

  def test_local_evidence_contract_is_consumed_without_substituting_for_other_gates
    %w[skills/verify/SKILL.md skills/autoreview/SKILL.md workflows/pr-batch-integration-closeout.md].each do |path|
      assert_match(/Verification evidence reuse/, text(path), path)
    end
    worker = text("workflows/pr-batch-worker-execution.md")
    assert_match(/worker stop returns control to the coordinator, not directly to the user/, worker)
    assert_match(/Keep the lane stopped on its actual security, ownership, scope, or verification gate/, worker)
  end
end
