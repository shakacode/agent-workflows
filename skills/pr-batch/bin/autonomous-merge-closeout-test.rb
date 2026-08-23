#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

SCRIPT = File.expand_path("autonomous-merge-closeout", __dir__)

class AutonomousMergeCloseoutTest < Minitest::Test
  HEAD_SHA = "a" * 40
  BASE_SHA = "b" * 40
  POLICY_BLOB_SHA = "c" * 40
  POLICY_BLOB_SHA_64 = "d" * 64
  POLICY_PATH = ".agents/agent-workflow.yml"
  PORTABLE_GATES = %w[
    architectural-product-judgment
    autonomous-merge-policy-change
    changed-files-limit
    changed-lines-limit
    commit-count-limit
    infrastructure-delivery
    irreversible-external-effect
    persistent-data-storage
    public-compatibility
    reviewed-heads-limit
    security-auth-privacy
  ].freeze
  EXPECTED_SUMMARY_REASON = {
    "architectural-product-judgment" => "requires architectural or product judgment",
    "autonomous-merge-policy-change" => "changes rules that govern autonomous merge",
    "changed-files-limit" => "changed-file limit",
    "changed-lines-limit" => "changed-line limit",
    "commit-count-limit" => "commit-count limit",
    "infrastructure-delivery" => "changes infrastructure or delivery behavior",
    "irreversible-external-effect" => "can cause an irreversible external effect",
    "persistent-data-storage" => "changes persistent data or storage behavior",
    "public-compatibility" => "changes a public compatibility contract",
    "reviewed-heads-limit" => "reviewed-head limit",
    "security-auth-privacy" => "changes security, authentication, privacy, or a trust boundary"
  }.freeze

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

  def test_every_portable_gate_has_an_accurate_human_first_summary
    PORTABLE_GATES.each do |gate|
      path_matches = if gate == "autonomous-merge-policy-change"
                       [{ "path" => "workflows/pr-processing.md", "gate" => gate, "reason" => "policy" }]
                     else
                       []
                     end
      output, status = render(evaluator_result(gates: [gate], path_matches:))

      assert status.success?, "#{gate}: #{output}"
      summary = output.lines.first
      assert_includes summary, EXPECTED_SUMMARY_REASON.fetch(gate), gate
      if %w[
        infrastructure-delivery irreversible-external-effect persistent-data-storage public-compatibility
      ].include?(gate)
        refute_includes summary, "repository limit", gate
      end
      assert_operator output.index(summary), :<, output.index(gate), gate
    end
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

  def test_unknown_explains_triggered_gates_and_retains_repo_path_evidence
    source = evaluator_result(
      verdict: "UNKNOWN",
      gates: ["repo-path:checkout"],
      path_matches: [
        {
          "path" => "app/services/checkout/charge.rb",
          "gate" => "repo-path:checkout",
          "reason" => "hot-path"
        }
      ],
      rollback_assessment: "UNKNOWN",
      evidence_failures: ["rollback assessment is missing or unknown"]
    )

    markdown, markdown_status = render(source)
    json, json_status = render(source, format: "json")
    result = JSON.parse(json)

    assert markdown_status.success?, markdown
    assert_includes markdown, "- `repo-path:checkout`"
    assert_includes markdown, "high-impact runtime path"
    assert_includes markdown, 'Path evidence: "app/services/checkout/charge.rb" (hot-path)'
    assert json_status.success?, json
    assert_equal [
      {
        "gate" => "repo-path:checkout",
        "explanation" =>
          "Trusted-base repository policy reserves this PR's matching high-impact runtime path for human review.",
        "path_evidence" => [{ "path" => "app/services/checkout/charge.rb", "reason" => "hot-path" }]
      }
    ], result.fetch("gate_explanations")
  end

  def test_json_format_preserves_exact_machine_facts
    source = evaluator_result(
      gates: ["security-auth-privacy"],
      policy_provenance: "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA}"
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

  def test_uppercase_head_sha_fails_closed_for_both_verdicts
    results = [
      evaluator_result(gates: ["security-auth-privacy"], head_sha: "A" * 40),
      evaluator_result(
        verdict: "UNKNOWN",
        gates: [],
        head_sha: "A" * 40,
        rollback_assessment: "UNKNOWN",
        evidence_failures: ["evaluator evidence is incomplete"]
      )
    ]

    results.each do |result|
      stdout, stderr, status = render_streams(result)

      assert_equal 64, status.exitstatus, result.fetch("verdict")
      assert_empty stdout, result.fetch("verdict")
      assert_includes stderr, "head_sha must be a full lowercase hexadecimal SHA"
      refute_includes stderr, "Next action:"
    end
  end

  def test_path_match_gate_absent_from_triggered_gates_fails_closed
    result = evaluator_result(
      gates: ["architectural-product-judgment"],
      path_matches: [
        {
          "path" => "workflows/pr-processing.md",
          "gate" => "autonomous-merge-policy-change",
          "reason" => "policy"
        }
      ]
    )

    assert_fail_closed(result, "path_matches contains gates absent from triggered_gates")
  end

  def test_unknown_path_reason_fails_closed
    result = evaluator_result(
      gates: ["repo-path:checkout"],
      path_matches: [{ "path" => "lib/checkout.rb", "gate" => "repo-path:checkout", "reason" => "mystery" }]
    )

    assert_fail_closed(result, "path_matches must contain valid path evidence")
  end

  def test_missing_policy_provenance_fails_closed
    assert_fail_closed(
      evaluator_result(gates: ["security-auth-privacy"], policy_provenance: nil),
      "policy_provenance is not an evaluator-produced form"
    )
  end

  def test_real_evaluator_policy_provenance_forms_remain_compatible
    human_forms = [
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA}",
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA_64}",
      "git:#{BASE_SHA}:#{POLICY_PATH}(absent; portable-defaults)"
    ]
    unknown_forms = [
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA}",
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA_64}",
      "git:#{BASE_SHA}:#{POLICY_PATH}(absent; portable-defaults)",
      "git:#{BASE_SHA}:#{POLICY_PATH}",
      "git:#{BASE_SHA}",
      "UNKNOWN"
    ]

    human_forms.each do |provenance|
      output, status = render(evaluator_result(gates: ["security-auth-privacy"], policy_provenance: provenance))

      assert status.success?, "#{provenance}: #{output}"
      assert_includes output, "Policy provenance: `#{provenance}`"
    end
    unknown_forms.each do |provenance|
      output, status = render(
        evaluator_result(
          verdict: "UNKNOWN",
          gates: [],
          rollback_assessment: "UNKNOWN",
          evidence_failures: ["evaluator evidence is incomplete"],
          policy_provenance: provenance
        )
      )

      assert status.success?, "#{provenance}: #{output}"
      assert_includes output, "Policy provenance: `#{provenance}`"
    end
  end

  def test_malformed_and_verdict_incompatible_policy_provenance_fails_on_stderr_only
    malformed = [
      "git:#{BASE_SHA}:#{POLICY_PATH}@not-a-blob",
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{'c' * 39}",
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{'c' * 65}",
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{'C' * 40}",
      "git:#{BASE_SHA}:#{POLICY_PATH}(absent; portable-defaults);extra",
      "git:#{BASE_SHA}:other-policy.yml",
      "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA}:extra",
      "git:#{BASE_SHA}"
    ]

    malformed.each do |provenance|
      stdout, stderr, status = render_streams(
        evaluator_result(gates: ["security-auth-privacy"], policy_provenance: provenance)
      )

      assert_equal 64, status.exitstatus, provenance
      assert_empty stdout, provenance
      assert_includes stderr, "policy_provenance is not an evaluator-produced form for human-approval-required"
      refute_includes stderr, "Next action:"
    end
  end

  def test_intermediate_length_policy_blob_oids_fail_closed_for_both_verdicts
    [41, 63].each do |length|
      provenance = "git:#{BASE_SHA}:#{POLICY_PATH}@#{'c' * length}"
      results = [
        evaluator_result(gates: ["security-auth-privacy"], policy_provenance: provenance),
        evaluator_result(
          verdict: "UNKNOWN",
          gates: [],
          rollback_assessment: "UNKNOWN",
          evidence_failures: ["evaluator evidence is incomplete"],
          policy_provenance: provenance
        )
      ]

      results.each do |result|
        stdout, stderr, status = render_streams(result)

        assert_equal 64, status.exitstatus, "#{result.fetch('verdict')}: #{provenance}"
        assert_empty stdout, "#{result.fetch('verdict')}: #{provenance}"
        assert_includes stderr,
                        "policy_provenance is not an evaluator-produced form for #{result.fetch('verdict')}"
        refute_includes stderr, "Next action:"
      end
    end
  end

  def test_invalid_non_unknown_rollback_fails_closed
    assert_fail_closed(
      evaluator_result(gates: ["security-auth-privacy"], rollback_assessment: "probably-reversible"),
      "rollback_assessment is invalid for the evaluator verdict"
    )
  end

  def test_repo_path_gate_without_matching_path_evidence_fails_closed_with_usage_status
    assert_fail_closed(
      evaluator_result(gates: ["repo-path:checkout"]),
      "repo-path gates require matching path evidence"
    )
  end

  def test_generated_path_shape_remains_supported
    result = evaluator_result(
      gates: ["security-auth-privacy"],
      path_matches: [{ "path" => "dist/generated.js", "classification" => "generated" }]
    )

    _output, status = render(result)

    assert status.success?
  end

  private

  def render(result, format: "markdown")
    Open3.capture2e("ruby", SCRIPT, "--format", format, stdin_data: JSON.generate(result))
  end

  def render_streams(result, format: "markdown")
    Open3.capture3("ruby", SCRIPT, "--format", format, stdin_data: JSON.generate(result))
  end

  def assert_fail_closed(result, error)
    output, status = render(result)

    assert_equal 64, status.exitstatus, output
    assert_includes output, error
    refute_includes output, "Auto-merge is paused"
    refute_includes output, "Next action:"
  end

  def evaluator_result(
    gates:,
    verdict: "human-approval-required",
    head_sha: HEAD_SHA,
    path_matches: [],
    rollback_assessment: "code-only-rollback-established",
    evidence_failures: [],
    policy_provenance: "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA}"
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
