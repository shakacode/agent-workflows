#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

SCRIPT = File.expand_path("autonomous-merge-closeout", __dir__)

class AutonomousMergeCloseoutTest < Minitest::Test
  HEAD_SHA = "a" * 40

  def test_policy_change_names_the_actual_path_after_the_plain_english_summary
    result = evaluator_result(
      gates: ["autonomous-merge-policy-change"],
      path_matches: [
        {
          "path" => "workflows/pr-processing.md",
          "gate" => "autonomous-merge-policy-change",
          "reason" => "policy"
        }
      ]
    )

    output, status = render(result)

    assert status.success?, output
    assert output.start_with?("Auto-merge is paused because this PR changes rules that govern autonomous merge.")
    assert_operator output.index("Auto-merge is paused"), :<, output.index("autonomous-merge-policy-change")
    assert_includes output, "This is a policy and authority gate."
    assert_includes output, "It does not report a code defect, failed CI, or a review finding"
    assert_includes output, 'Path evidence: "workflows/pr-processing.md" (policy)'
  end

  def test_architectural_judgment_is_explained_as_judgment_not_a_defect
    output, status = render(evaluator_result(gates: ["architectural-product-judgment"]))

    assert status.success?, output
    assert_includes output, "requires architectural or product judgment"
    assert_includes output, "judgment that automation cannot supply"
    assert_includes output, "ordinary readiness remains a separate requirement"
  end

  def test_security_gate_explains_the_trust_boundary
    output, status = render(evaluator_result(gates: ["security-auth-privacy"]))

    assert status.success?, output
    assert_includes output, "changes security, authentication, privacy, or a trust boundary"
    assert_includes output, "trusted semantic assessment"
  end

  def test_combined_gates_are_individually_explained_with_one_exact_action
    gates = %w[
      architectural-product-judgment
      autonomous-merge-policy-change
      security-auth-privacy
    ]
    output, status = render(
      evaluator_result(
        gates:,
        path_matches: [
          {
            "path" => "skills/pr-batch/SKILL.md",
            "gate" => "autonomous-merge-policy-change",
            "reason" => "policy"
          }
        ]
      )
    )

    assert status.success?, output
    gates.each { |gate| assert_includes output, "- `#{gate}`" }
    assert_equal 1, output.scan("Next action:").length
    assert_includes output, "human identity and merge authority are verified"
    assert_includes output, "complete autonomous-merge-risk-decision:v1 comment on this PR"
    assert_includes output, "Durable means"
    assert_includes output, "Current-head means"
    assert_includes output, HEAD_SHA
    assert_includes output, "Any new head invalidates this decision"
  end

  def test_unknown_explains_repair_and_cannot_be_treated_as_approvable
    result = evaluator_result(
      verdict: "UNKNOWN",
      gates: [],
      head_sha: "UNKNOWN",
      rollback_assessment: "UNKNOWN",
      evidence_failures: ["trusted base is unavailable", "review pagination is incomplete"],
      policy_provenance: "UNKNOWN"
    )

    output, status = render(result)

    assert status.success?, output
    assert output.start_with?("Auto-merge is blocked because required exact-head eligibility evidence")
    assert_includes output, "not a human-approvable policy-risk verdict"
    assert_includes output, "risk approval cannot clear it"
    assert_includes output, '"trusted base is unavailable"'
    assert_includes output, "re-run autonomous-merge-eligibility"
    assert_includes output, "AUTONOMOUS_RESULT_PATH"
    assert_includes output, "collect and bind the current full head SHA"
  end

  def test_json_format_preserves_exact_machine_facts
    source = evaluator_result(
      gates: ["security-auth-privacy"],
      policy_provenance: "git:#{'b' * 40}"
    )

    output, status = render(source, format: "json")
    result = JSON.parse(output)

    assert status.success?, output
    assert_equal "autonomous-merge-closeout", result.fetch("contract")
    assert_equal 1, result.fetch("version")
    assert_equal source.fetch("verdict"), result.fetch("verdict")
    assert_equal source.fetch("head_sha"), result.fetch("head_sha")
    assert_equal source.fetch("triggered_gates"), result.fetch("triggered_gates")
    assert_equal source.fetch("rollback_assessment"), result.fetch("rollback_assessment")
    assert_equal source.fetch("policy_provenance"), result.fetch("policy_provenance")
    assert_equal source.fetch("evidence_failures"), result.fetch("evidence_failures")
  end

  def test_malformed_human_approval_input_fails_closed
    result = evaluator_result(gates: ["security-auth-privacy"], evidence_failures: ["ambiguous evidence"])

    output, status = render(result)

    refute status.success?
    assert_includes output, "human-approval-required cannot carry evidence failures"
    refute_includes output, "Next action:"
  end

  private

  def render(result, format: "markdown")
    Open3.capture2e("ruby", SCRIPT, "--format", format, stdin_data: JSON.generate(result))
  end

  def evaluator_result(
    gates:,
    verdict: "human-approval-required",
    head_sha: HEAD_SHA,
    path_matches: [],
    rollback_assessment: "code-only-rollback-established",
    evidence_failures: [],
    policy_provenance: "git:#{'b' * 40}"
  )
    {
      "verdict" => verdict,
      "head_sha" => head_sha,
      "policy_provenance" => policy_provenance,
      "path_matches" => path_matches,
      "triggered_gates" => gates,
      "rollback_assessment" => rollback_assessment,
      "evidence_failures" => evidence_failures
    }
  end
end
