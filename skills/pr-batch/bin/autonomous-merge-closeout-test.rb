#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/autonomous_merge_runtime_trust"

SCRIPT = File.expand_path("autonomous-merge-closeout", __dir__)
ELIGIBILITY_SCRIPT = File.expand_path("autonomous-merge-eligibility", __dir__)

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
    assert_includes output, 'Path evidence: ` "workflows/pr-processing.md" ` (policy)'
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

  def test_real_evaluator_human_and_early_unknown_artifacts_remain_renderable
    human = real_human_approval_artifact
    unknown_stdout, unknown_stderr, unknown_status = Open3.capture3("ruby", ELIGIBILITY_SCRIPT)
    unknown = JSON.parse(unknown_stdout)

    human_output, human_status = render(human)
    unknown_output, rendered_unknown_status = render(unknown)

    assert_equal "human-approval-required", human.fetch("verdict")
    assert human_status.success?, human_output
    assert_includes human_output, "changed-files-limit"
    assert unknown_status.success?, unknown_stderr
    assert_equal "UNKNOWN", unknown.fetch("verdict")
    assert_equal "unverified", unknown.dig("helper_trust", "status")
    assert rendered_unknown_status.success?, unknown_output
    assert_includes unknown_output, "required exact-head eligibility evidence is missing"
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
    assert_includes markdown, 'Path evidence: ` "app/services/checkout/charge.rb" ` (hot-path)'
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

  def test_markdown_renders_pr_controlled_paths_as_literal_code_without_changing_json
    adversarial_path =
      "app/services/checkout/](evil)[Click *here*](https://evil.example/x)<script>|#_ ` `` ```\nnext.rb"
    source = evaluator_result(
      gates: ["repo-path:checkout"],
      path_matches: [
        {
          "path" => adversarial_path,
          "gate" => "repo-path:checkout",
          "reason" => "hot-path"
        }
      ]
    )

    markdown, markdown_status = render(source)
    json, json_status = render(source, format: "json")

    assert markdown_status.success?, markdown
    assert_includes markdown,
                    "Path evidence: ```` #{JSON.generate(adversarial_path)} ```` (hot-path)"
    assert_equal 1, markdown.lines.grep(/Path evidence:/).length
    assert json_status.success?, json
    assert_equal adversarial_path,
                 JSON.parse(json).dig("gate_explanations", 0, "path_evidence", 0, "path")
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

  def test_fabricated_presentation_only_result_fails_closed
    fabricated = {
      "verdict" => "human-approval-required",
      "head_sha" => HEAD_SHA,
      "policy_provenance" => "git:#{BASE_SHA}:#{POLICY_PATH}@#{POLICY_BLOB_SHA}",
      "path_matches" => [],
      "triggered_gates" => ["security-auth-privacy"],
      "rollback_assessment" => "code-only-rollback-established",
      "evidence_failures" => []
    }

    assert_fail_closed(fabricated, "evaluator result has unknown or missing fields")
  end

  def test_human_approval_requires_mechanically_verified_helper_trust
    malformed = {
      "unverified" => evaluator_result(gates: ["security-auth-privacy"]).tap do |result|
        result["helper_provenance"] = "UNKNOWN"
        result["helper_trust"] = { "status" => "unverified", "manifest" => {} }
      end,
      "base-mismatch" => evaluator_result(gates: ["security-auth-privacy"]).tap do |result|
        result["helper_provenance"] = "trusted-base:#{'e' * 40}"
      end,
      "missing-role" => evaluator_result(gates: ["security-auth-privacy"]).tap do |result|
        result.dig("helper_trust", "manifest").delete("closeout-helper")
      end
    }

    malformed.each do |label, result|
      assert_fail_closed(
        result,
        "helper provenance and trust are invalid for human-approval-required"
      )
    rescue Minitest::Assertion => e
      raise Minitest::Assertion, "#{label}: #{e.message}"
    end
  end

  def test_full_evaluator_facts_are_validated_not_just_present
    mutations = {
      "metrics" => [
        ->(result) { result["metrics"]["changed_files"] = -1 },
        "metrics shape is invalid"
      ],
      "safe-class" => [
        ->(result) { result["safe_class"] = "probably-safe" },
        "safe_class is invalid"
      ],
      "shadow-gates" => [
        ->(result) { result["shadow_triggered_gates"] = ["changed-files-limit"] },
        "shadow_triggered_gates shape is invalid"
      ],
      "shadow-evidence" => [
        ->(result) { result["shadow_evidence_unknown"] = ["future-evidence"] },
        "shadow_evidence_unknown shape is invalid"
      ],
      "human-decision" => [
        ->(result) { result["human_decision_evidence"] = { "status" => "accepted" } },
        "human_decision_evidence is invalid for human-approval-required"
      ]
    }

    mutations.each do |label, (mutation, error)|
      result = evaluator_result(gates: ["security-auth-privacy"])
      mutation.call(result)

      assert_fail_closed(result, error)
    rescue Minitest::Assertion => e
      raise Minitest::Assertion, "#{label}: #{e.message}"
    end
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

  def test_gated_path_matches_are_limited_to_evaluator_emitted_pairings
    malformed_pairings = [
      evaluator_result(
        gates: ["security-auth-privacy"],
        path_matches: [
          { "path" => "lib/auth.rb", "gate" => "security-auth-privacy", "reason" => "security" }
        ]
      ),
      evaluator_result(
        gates: ["autonomous-merge-policy-change"],
        path_matches: [
          {
            "path" => "workflows/pr-processing.md",
            "gate" => "autonomous-merge-policy-change",
            "reason" => "infrastructure"
          }
        ]
      )
    ]

    malformed_pairings.each do |result|
      assert_fail_closed(result, "path_matches must contain valid path evidence")
    end
    assert_fail_closed(
      evaluator_result(gates: ["autonomous-merge-policy-change"]),
      "autonomous-merge-policy-change requires matching path evidence"
    )
  end

  def test_other_path_reason_requires_and_explains_its_policy_detail
    source = evaluator_result(
      gates: ["repo-path:checkout"],
      path_matches: [
        {
          "path" => "app/services/checkout/charge.rb",
          "gate" => "repo-path:checkout",
          "reason" => "other",
          "detail" => "payment orchestration boundary"
        }
      ]
    )

    markdown, markdown_status = render(source)
    json, json_status = render(source, format: "json")

    assert markdown_status.success?, markdown
    assert_includes markdown, "matching payment orchestration boundary"
    assert_includes markdown, "(other: payment orchestration boundary)"
    assert json_status.success?, json
    assert_equal "payment orchestration boundary",
                 JSON.parse(json).dig("gate_explanations", 0, "path_evidence", 0, "detail")

    assert_fail_closed(
      evaluator_result(
        gates: ["repo-path:checkout"],
        path_matches: [
          { "path" => "app/services/checkout/charge.rb", "gate" => "repo-path:checkout", "reason" => "other" }
        ]
      ),
      "path_matches must contain valid path evidence"
    )
    assert_fail_closed(
      evaluator_result(
        gates: ["repo-path:checkout"],
        path_matches: [
          {
            "path" => "app/services/checkout/charge.rb",
            "gate" => "repo-path:checkout",
            "reason" => "hot-path",
            "detail" => "unexpected detail"
          }
        ]
      ),
      "path_matches must contain valid path evidence"
    )
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

  def test_positional_arguments_fail_closed_without_rendering_output
    stdout, stderr, status = Open3.capture3(
      "ruby", SCRIPT, "unexpected-positional-argument",
      stdin_data: JSON.generate(evaluator_result(gates: ["security-auth-privacy"]))
    )

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "positional arguments are not supported"
    refute_includes stderr, "Next action:"
  end

  private

  def real_human_approval_artifact
    repo_root = File.expand_path("../../..", __dir__)
    base_sha, base_status = Open3.capture2("git", "-C", repo_root, "rev-parse", "HEAD")
    raise "git rev-parse failed" unless base_status.success?

    base_sha = base_sha.strip
    files = Array.new(30) do |index|
      { "path" => format("lib/file_%02d.rb", index), "additions" => 1, "deletions" => 0 }
    end
    objective = {
      "head_sha" => HEAD_SHA,
      "base_sha" => base_sha,
      "files" => files,
      "commits" => [{ "sha" => "c" * 40 }],
      "reviews" => [],
      "decision_comments" => []
    }
    calibration = File.join(
      repo_root,
      "skills/pr-batch/fixtures/autonomous-merge-reviewed-heads-calibration.json"
    )
    digest = AutonomousMergeRuntimeTrust.installed_pack_digest(
      AutonomousMergeRuntimeTrust.runtime_sources(calibration)
    )

    Dir.mktmpdir("autonomous-merge-closeout-integration") do |root|
      objective_path = File.join(root, "objective.json")
      semantic_path = File.join(root, "semantic.json")
      gh_path = File.join(root, "gh")
      File.write(objective_path, JSON.generate(objective))
      File.write(semantic_path, JSON.generate(real_semantic_assessment))
      write_real_evaluator_fake_gh(gh_path)
      stdout, stderr, status = Open3.capture3(
        {
          "AUTONOMOUS_MERGE_GH" => gh_path,
          "AUTONOMOUS_MERGE_TEST_OBJECTIVE" => objective_path
        },
        "ruby", ELIGIBILITY_SCRIPT,
        "--repo-root", repo_root,
        "--trusted-base", base_sha,
        "--trusted-helper-provenance", "verified-installed-pack:#{digest}",
        "--repo", "owner/repo",
        "--pr", "42",
        "--semantic-assessment", semantic_path
      )
      raise stderr unless status.success?

      JSON.parse(stdout)
    end
  end

  def real_semantic_assessment
    {
      "provenance" => "trusted-coordinator",
      "persistent_data_storage" => false,
      "infrastructure_delivery" => false,
      "irreversible_external_effect" => false,
      "public_compatibility" => false,
      "security_auth_privacy" => false,
      "architectural_product_judgment" => false,
      "unresolved_maintainer_concern" => false,
      "rollback_assessment" => "code-only-rollback-established",
      "safe_class" => "none",
      "safe_classification_complete" => true,
      "test_change" => "not-applicable",
      "decision_provenance" => []
    }
  end

  def write_real_evaluator_fake_gh(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      objective = JSON.parse(File.read(ENV.fetch("AUTONOMOUS_MERGE_TEST_OBJECTIVE")))
      request = ARGV.fetch(-1)
      response = case request
                 when "repos/owner/repo/pulls/42"
                   {
                     "head" => { "sha" => objective.fetch("head_sha") },
                     "base" => { "sha" => objective.fetch("base_sha") },
                     "updated_at" => "2026-08-22T12:00:00Z",
                     "changed_files" => objective.fetch("files").length,
                     "commits" => objective.fetch("commits").length
                   }
                 when "repos/owner/repo/issues/42/timeline?per_page=100&page=1"
                   []
                 when "repos/owner/repo/pulls/42/files?per_page=100&page=1"
                   objective.fetch("files").map do |file|
                     {
                       "filename" => file.fetch("path"),
                       "status" => "modified",
                       "additions" => file.fetch("additions"),
                       "deletions" => file.fetch("deletions")
                     }
                   end
                 when "repos/owner/repo/pulls/42/commits?per_page=100&page=1"
                   objective.fetch("commits")
                 when "repos/owner/repo/pulls/42/reviews?per_page=100&page=1"
                   objective.fetch("reviews")
                 when "repos/owner/repo/issues/42/comments?per_page=100&page=1"
                   objective.fetch("decision_comments")
                 else
                   warn "unexpected GitHub API path: #{request}"
                   exit 1
                 end
      puts JSON.generate(response)
    RUBY
    File.chmod(0o755, path)
  end

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
      "helper_provenance" => "trusted-base:#{BASE_SHA}",
      "helper_trust" => {
        "status" => "mechanically-verified",
        "manifest" => autonomous_runtime_manifest
      },
      "metrics" => {
        "changed_files" => 1,
        "changed_lines" => 2,
        "commits" => 1,
        "reviewed_heads" => 0
      },
      "path_matches" => path_matches,
      "safe_class" => "none",
      "triggered_gates" => gates,
      "shadow_triggered_gates" => [],
      "shadow_evidence_unknown" => [],
      "rollback_assessment" => rollback_assessment,
      "human_decision_evidence" => { "status" => "none" },
      "evidence_failures" => evidence_failures
    }
  end

  def autonomous_runtime_manifest
    {
      "helper" => "skills/pr-batch/bin/autonomous-merge-eligibility",
      "closeout-helper" => "skills/pr-batch/bin/autonomous-merge-closeout",
      "decision-library" => "skills/pr-batch/lib/autonomous_merge_decision.rb",
      "evidence-library" => "skills/pr-batch/lib/autonomous_merge_evidence.rb",
      "policy-library" => "bin/agent_doctor/autonomous_merge_policy.rb",
      "policy-glob-library" => "bin/agent_doctor/autonomous_merge_policy_globs.rb",
      "policy-yaml-library" => "bin/agent_doctor/autonomous_merge_policy_yaml.rb",
      "runtime-trust-library" => "skills/pr-batch/lib/autonomous_merge_runtime_trust.rb",
      "calibration-decision" =>
        "skills/pr-batch/fixtures/autonomous-merge-reviewed-heads-calibration.json"
    }
  end
end
