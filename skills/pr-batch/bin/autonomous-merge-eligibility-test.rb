#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require_relative "../lib/autonomous_merge_decision"
require_relative "../lib/autonomous_merge_runtime_trust"

SCRIPT = File.expand_path("autonomous-merge-eligibility", __dir__)
CLOSEOUT_SCRIPT = File.expand_path("autonomous-merge-closeout", __dir__)
FIXTURE_DIR = File.expand_path("../fixtures", __dir__)

class AutonomousMergeEligibilityTest < Minitest::Test
  HEAD_SHA = "a" * 40
  SAFE_TMP_PARENT = ENV.fetch(
    "AUTONOMOUS_MERGE_TEST_TMP_PARENT",
    File.expand_path("../../..", __dir__)
  )

  def test_live_evaluator_uses_the_injected_absolute_git_for_all_trusted_reads
    Dir.mktmpdir("autonomous-merge-trusted-git", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      executable_root = File.join(root, "trusted-tools")
      poisoned_root = File.join(root, "poisoned-path")
      FileUtils.mkdir_p([executable_root, poisoned_root])
      trusted_git = File.join(executable_root, "git")
      trusted_log = File.join(root, "trusted-git.log")
      poisoned_marker = File.join(root, "poisoned-git-ran")
      poisoned_gh_marker = File.join(root, "poisoned-gh-ran")
      git_name = "git#{RbConfig::CONFIG.fetch('EXEEXT')}"
      git_candidates = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map do |directory|
        File.join(directory, git_name)
      end
      real_git_candidate = git_candidates.find { |path| File.file?(path) && File.executable?(path) }
      refute_nil real_git_candidate, "git must be available on PATH for this test"
      real_git = File.realpath(real_git_candidate)
      File.write(trusted_git, <<~RUBY)
        #!#{RbConfig.ruby}
        File.open(#{trusted_log.inspect}, "a") { |file| file.puts(ARGV.join("\\t")) }
        exec(#{real_git.inspect}, *ARGV)
      RUBY
      File.chmod(0o755, trusted_git)
      File.write(File.join(poisoned_root, "git"), <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{poisoned_marker.inspect}, "yes")
        exit 99
      RUBY
      File.chmod(0o755, File.join(poisoned_root, "git"))
      File.write(File.join(poisoned_root, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{poisoned_gh_marker.inspect}, "yes")
        exit 99
      RUBY
      File.chmod(0o755, File.join(poisoned_root, "gh"))

      result = invoke(
        root:,
        calibration_path:,
        evaluation: evidence(base_sha:, files: files(1)),
        subprocess_env: {
          "AUTONOMOUS_MERGE_GIT" => trusted_git,
          "PATH" => "#{poisoned_root}:#{ENV.fetch('PATH')}"
        }
      )

      assert_equal "autonomous-merge-eligible", result.fetch("verdict")
      refute File.exist?(poisoned_marker)
      refute File.exist?(poisoned_gh_marker)
      assert_operator File.foreach(trusted_log).count, :>=, 5
    end
  end

  def test_live_evaluator_rejects_relative_and_writable_git_overrides_before_execution
    Dir.mktmpdir("autonomous-merge-untrusted-git", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      marker = File.join(root, "untrusted-git-ran")
      writable_root = File.join(root, "writable-tools")
      FileUtils.mkdir_p(writable_root)
      File.chmod(0o777, writable_root)
      unsafe_git = File.join(writable_root, "git")
      File.write(unsafe_git, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'yes')\n")
      File.chmod(0o755, unsafe_git)
      group_writable_root = File.join(root, "group-writable-tools")
      FileUtils.mkdir_p(group_writable_root)
      File.chmod(0o770, group_writable_root)
      group_writable_git = File.join(group_writable_root, "git")
      File.write(group_writable_git, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'yes')\n")
      File.chmod(0o755, group_writable_git)

      cases = {
        "relative" => {
          "AUTONOMOUS_MERGE_GIT" => "git",
          "PATH" => "#{writable_root}:#{ENV.fetch('PATH')}"
        },
        "world-writable ancestor" => { "AUTONOMOUS_MERGE_GIT" => unsafe_git },
        "same-owner group-writable ancestor" => { "AUTONOMOUS_MERGE_GIT" => group_writable_git }
      }
      cases.each do |label, environment|
        result = invoke(
          root:,
          calibration_path:,
          evaluation: evidence(base_sha:, files: files(1)),
          subprocess_env: environment
        )

        assert_equal "UNKNOWN", result.fetch("verdict"), label
        assert result.fetch("evidence_failures").any? { |failure| failure.include?("AUTONOMOUS_MERGE_GIT") },
               label
        refute File.exist?(marker), label
      end
    ensure
      File.chmod(0o700, writable_root) if writable_root && File.exist?(writable_root)
      File.chmod(0o700, group_writable_root) if group_writable_root && File.exist?(group_writable_root)
    end
  end

  def test_changed_files_value_immediately_below_portable_boundary_is_eligible
    result = evaluate { |base_sha| evidence(base_sha:, files: files(29)) }

    assert_equal "autonomous-merge-eligible", result.fetch("verdict")
    assert_equal [], result.fetch("triggered_gates")
    assert_equal HEAD_SHA, result.fetch("head_sha")
    assert_equal "mechanically-verified", result.dig("helper_trust", "status")
    assert_equal(
      "skills/pr-batch/bin/autonomous-merge-eligibility",
      result.dig("helper_trust", "manifest", "helper")
    )
  end

  def test_disjoint_safe_current_base_delta_preserves_exact_head_eligibility
    result = evaluate do |recorded_base, root|
      stale_evaluation(
        root:, recorded_base:,
        head_path: "lib/feature.rb",
        base_delta_path: "docs/guide.md"
      )
    end

    assert_equal "autonomous-merge-eligible", result.fetch("verdict")
    assert_equal "reuse-exact-head", result.dig("current_integration", "reuse", "decision")
    assert_equal ["base-delta-reuse-safe"], result.dig("current_integration", "reuse", "reasons")
    assert_equal 1, result.dig("current_integration", "telemetry", "validator_replays_avoided")
  end

  def test_disjoint_code_on_both_sides_requires_fresh_integration
    result = evaluate do |recorded_base, root|
      stale_evaluation(
        root:, recorded_base:,
        head_path: "lib/feature.rb",
        base_delta_path: "lib/unrelated.rb"
      )
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_includes result.fetch("evidence_failures").first, "current integration requires fresh evidence"
    assert_includes result.fetch("evidence_failures").first, "neither-delta-reuse-safe"
  end

  def test_copied_file_source_is_not_mistaken_for_a_changed_path
    result = evaluate do |recorded_base, root|
      copied_stale_evaluation(
        root:,
        recorded_base:,
        source_path: "lib/source.rb",
        destination_path: "lib/copied.rb",
        base_delta_path: "docs/guide.md"
      )
    end

    assert_equal "autonomous-merge-eligible", result.fetch("verdict")
    assert_equal "reuse-exact-head", result.dig("current_integration", "reuse", "decision")
    assert_equal ["base-delta-reuse-safe"], result.dig("current_integration", "reuse", "reasons")
  end

  def test_live_collection_returns_a_verdict_with_non_ascii_payload_in_a_c_locale
    result = evaluate(subprocess_env: { "LANG" => "C", "LC_ALL" => "C" }) do |base_sha|
      evidence(
        base_sha:,
        files: files(1),
        decision_comments: [
          decision_comment(
            id: "1",
            url: "https://github.com/example/repo/pull/1#issuecomment-1",
            body: "reviewed by Jos\u00e9"
          )
        ]
      )
    end

    assert_equal "autonomous-merge-eligible", result.fetch("verdict")
    assert_equal [], result.fetch("evidence_failures")
  end

  def test_live_collection_returns_structured_unknown_for_an_undecodable_payload
    result = evaluate(gh_invalid_utf8_field: "filename") do |base_sha|
      evidence(base_sha:, files: files(1))
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_match(/malformed or invalid GitHub evidence/, result.fetch("evidence_failures").first)
  end

  def test_live_collection_rejects_invalid_utf8_in_uninspected_comment_fields
    url = "https://github.com/example/repo/pull/1#issuecomment-1"
    result = evaluate(gh_invalid_utf8_field: "comment_url") do |base_sha|
      evidence(
        base_sha:,
        files: files(30),
        decision_comments: [
          decision_comment(
            id: "1",
            url:,
            body: decision_body(head_sha: HEAD_SHA, gates: ["changed-files-limit"], evidence: url)
          )
        ],
        semantic: semantic_assessment.merge(
          "decision_provenance" => [decision_provenance("1")]
        )
      )
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_match(/malformed or invalid GitHub evidence/, result.fetch("evidence_failures").first)
  end

  def test_live_collection_rejects_invalid_utf8_in_semantic_assessment_fields
    result = evaluate(invalid_utf8_semantic_field: "rollback_assessment") do |base_sha|
      evidence(base_sha:, files: files(1))
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_match(/malformed or invalid semantic assessment/, result.fetch("evidence_failures").first)
  end

  def test_live_collection_returns_structured_unknown_when_parser_error_contains_invalid_utf8
    result = evaluate(invalid_utf8_semantic_syntax: true) do |base_sha|
      evidence(base_sha:, files: files(1))
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_predicate result.fetch("evidence_failures").first, :valid_encoding?
  end

  def test_portable_size_and_commit_boundaries_are_inclusive_human_gates
    cases = {
      "changed-files-limit" => evidence_override(files: files(30)),
      "changed-lines-limit" => evidence_override(
        files: [{ "path" => "lib/large.rb", "additions" => 700, "deletions" => 300 }]
      ),
      "commit-count-limit" => evidence_override(
        commits: Array.new(10) { |index| { "sha" => format("%040x", index + 1) } }
      )
    }

    cases.each do |expected_gate, override|
      result = evaluate { |base_sha| evidence(base_sha:, **override) }

      assert_equal "human-approval-required", result.fetch("verdict"), expected_gate
      assert_equal [expected_gate], result.fetch("triggered_gates"), expected_gate
    end
  end

  def test_distinct_submitted_reviewed_heads_are_shadow_only_before_calibration_graduation
    reviews = [
      review("APPROVED", "1" * 40),
      review("CHANGES_REQUESTED", "2" * 40),
      review("COMMENTED", "3" * 40),
      review("DISMISSED", "4" * 40),
      review("COMMENTED", "4" * 40),
      review("PENDING", "5" * 40)
    ]

    result = evaluate { |base_sha| evidence(base_sha:, files: files(1), reviews:) }

    assert_equal 4, result.dig("metrics", "reviewed_heads")
    assert_equal "autonomous-merge-eligible", result.fetch("verdict")
    assert_equal [], result.fetch("triggered_gates")
    assert_equal ["reviewed-heads-limit"], result.fetch("shadow_triggered_gates")
  end

  def test_graduated_reviewed_heads_threshold_enforces_the_same_distinct_head_signal
    reviews = Array.new(4) { |index| review("COMMENTED", format("%040x", index + 1)) }
    result = evaluate(reviewed_heads_mode: "enforced") do |base_sha|
      evidence(base_sha:, files: files(1), reviews:)
    end

    assert_equal "human-approval-required", result.fetch("verdict")
    assert_equal ["reviewed-heads-limit"], result.fetch("triggered_gates")
    assert_equal [], result.fetch("shadow_triggered_gates")
  end

  def test_reviewed_head_policy_can_tighten_portable_calibration_in_shadow_and_enforced_modes
    policy_yaml = <<~YAML
      autonomous_merge:
        thresholds:
          max_reviewed_heads: 1
    YAML
    reviews = [
      review("COMMENTED", "1" * 40),
      review("APPROVED", "2" * 40)
    ]

    shadow = evaluate(policy_yaml:, reviewed_heads_mode: "shadow") do |base_sha|
      evidence(base_sha:, files: files(1), reviews:)
    end
    enforced = evaluate(policy_yaml:, reviewed_heads_mode: "enforced") do |base_sha|
      evidence(base_sha:, files: files(1), reviews:)
    end

    assert_equal ["reviewed-heads-limit"], shadow.fetch("shadow_triggered_gates")
    assert_equal "autonomous-merge-eligible", shadow.fetch("verdict")
    assert_equal ["reviewed-heads-limit"], enforced.fetch("triggered_gates")
    assert_equal "human-approval-required", enforced.fetch("verdict")
  end

  def test_reviewed_head_policy_can_justifiably_relax_portable_calibration_in_shadow_and_enforced_modes
    policy_yaml = <<~YAML
      autonomous_merge:
        thresholds:
          max_reviewed_heads: 4
        threshold_relaxation:
          rationale: This repository requires a separate current-head review gate for every push.
    YAML
    reviews = Array.new(4) { |index| review("COMMENTED", format("%040x", index + 1)) }

    shadow = evaluate(policy_yaml:, reviewed_heads_mode: "shadow") do |base_sha|
      evidence(base_sha:, files: files(1), reviews:)
    end
    enforced = evaluate(policy_yaml:, reviewed_heads_mode: "enforced") do |base_sha|
      evidence(base_sha:, files: files(1), reviews:)
    end

    assert_equal [], shadow.fetch("shadow_triggered_gates")
    assert_equal "autonomous-merge-eligible", shadow.fetch("verdict")
    assert_equal [], enforced.fetch("triggered_gates")
    assert_equal "autonomous-merge-eligible", enforced.fetch("verdict")
  end

  def test_missing_submitted_review_head_is_shadow_unknown_until_graduation
    reviews = [review("COMMENTED", nil)]

    shadow = evaluate { |base_sha| evidence(base_sha:, files: files(1), reviews:) }
    enforced = evaluate(reviewed_heads_mode: "enforced") do |base_sha|
      evidence(base_sha:, files: files(1), reviews:)
    end

    assert_equal "autonomous-merge-eligible", shadow.fetch("verdict")
    assert_equal ["submitted-review-head-missing"], shadow.fetch("shadow_evidence_unknown")
    assert_equal "UNKNOWN", enforced.fetch("verdict")
    assert_includes enforced.fetch("evidence_failures"),
                    "submitted review commit_id is missing; recollect complete submitted-review evidence with full head SHAs"

    stdout, stderr, status = Open3.capture3("ruby", CLOSEOUT_SCRIPT, stdin_data: JSON.generate(enforced))

    assert status.success?, stderr
    assert_empty stderr
    assert_includes stdout, "recollect complete submitted-review evidence with full head SHAs"
  end

  def test_unavailable_policy_blob_sha_emits_a_renderable_unknown_with_repair_evidence
    Dir.mktmpdir("autonomous-merge-policy-blob-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: "{}\n", include_runtime: true)
      Dir.mktmpdir("autonomous-merge-policy-blob-patch", SAFE_TMP_PARENT) do |patch_root|
        open3_patch = File.join(patch_root, "fail-policy-blob-lookup.rb")
        write_failed_policy_blob_lookup_patch(open3_patch)
        result = invoke(
          root:,
          calibration_path:,
          evaluation: evidence(base_sha:, files: files(1)),
          subprocess_env: { "RUBYOPT" => "-r#{open3_patch}" }
        )

        assert_equal "UNKNOWN", result.fetch("verdict")
        assert_equal "UNKNOWN", result.fetch("policy_provenance")
        assert_includes result.fetch("evidence_failures"),
                        "trusted-base policy blob SHA is unavailable; repair trusted-base Git object access " \
                        "and rerun autonomous-merge-eligibility"

        stdout, stderr, status = Open3.capture3("ruby", CLOSEOUT_SCRIPT, stdin_data: JSON.generate(result))

        assert status.success?, stderr
        assert_empty stderr
        assert_includes stdout, "repair trusted-base Git object access and rerun autonomous-merge-eligibility"
      end
    end
  end

  def test_unknown_review_state_is_rejected_by_direct_evidence_validation
    helper = File.read(SCRIPT, encoding: "UTF-8")

    assert_includes helper, 'recognized_review_states.include?(review["state"])'

    result = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(1),
        reviews: [review("FUTURE_SUBMITTED_STATE", "f" * 40)]
      )
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_includes result.fetch("evidence_failures"), "GitHub review state is unrecognized"
    assert_match(/\Atrusted-base:[0-9a-f]{40}\z/, result.fetch("helper_provenance"))
    assert_equal "mechanically-verified", result.dig("helper_trust", "status")
  end

  def test_final_output_never_reports_a_malformed_head_sha
    Dir.mktmpdir("autonomous-merge-invalid-head-output-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      objective = evidence(base_sha:, files: files(1)).fetch("objective")
      objective["head_sha"] = "not-a-full-sha"

      Dir.mktmpdir("autonomous-merge-invalid-head-input", SAFE_TMP_PARENT) do |input_root|
        objective_path = File.join(input_root, "objective.json")
        semantic_path = File.join(input_root, "semantic.json")
        harness_path = File.join(input_root, "harness.rb")
        File.write(objective_path, JSON.generate(objective))
        File.write(semantic_path, JSON.generate(semantic_assessment))
        File.write(harness_path, <<~RUBY)
          require "json"
          require #{File.expand_path('../lib/autonomous_merge_evidence', __dir__).inspect}

          objective = JSON.parse(File.read(ENV.fetch("TEST_OBJECTIVE")))
          AutonomousMergeEvidence.define_singleton_method(:collect) { |**| objective }
          ARGV.replace(JSON.parse(ENV.fetch("TEST_ARGV")))
          load #{SCRIPT.inspect}
        RUBY
        arguments = [
          "--repo-root", root,
          "--trusted-base", "trusted-base",
          "--trusted-helper-provenance", "trusted-base:#{base_sha}",
          "--calibration-decision", calibration_path,
          "--repo", "example/repo",
          "--pr", "1",
          "--semantic-assessment", semantic_path
        ]

        stdout, stderr, status = Open3.capture3(
          { "TEST_OBJECTIVE" => objective_path, "TEST_ARGV" => JSON.generate(arguments) },
          "ruby", harness_path
        )
        assert status.success?, stderr
        result = JSON.parse(stdout)

        assert_equal "UNKNOWN", result.fetch("verdict")
        assert_equal "UNKNOWN", result.fetch("head_sha")
        assert_includes result.fetch("evidence_failures"), "head_sha must be a full hexadecimal SHA"
      end
    end
  end

  def test_trusted_base_threshold_seam_tightens_defaults_and_requires_rationale_to_relax
    strict = evaluate(policy_yaml: <<~YAML) do |base_sha|
      autonomous_merge:
        thresholds:
          max_changed_files: 0
    YAML
      evidence(base_sha:, files: files(1))
    end
    relaxed = evaluate(policy_yaml: <<~YAML) do |base_sha|
      autonomous_merge:
        thresholds:
          max_changed_files: 30
        threshold_relaxation:
          rationale: Generated API clients are reviewed through a separate required gate.
    YAML
      evidence(base_sha:, files: files(30))
    end
    malformed = evaluate(policy_yaml: <<~YAML) do |base_sha|
      autonomous_merge:
        thresholds:
          max_changed_files: 30
    YAML
      evidence(base_sha:, files: files(1))
    end

    assert_equal ["changed-files-limit"], strict.fetch("triggered_gates")
    assert_equal "autonomous-merge-eligible", relaxed.fetch("verdict")
    assert_equal "UNKNOWN", malformed.fetch("verdict")
    assert_includes malformed.fetch("evidence_failures"), "threshold_relaxation.rationale is required"
  end

  def test_malformed_or_ambiguous_trusted_base_seam_fails_closed
    policies = {
      "duplicate key" => <<~YAML,
        autonomous_merge:
          thresholds:
            max_commits: 9
            max_commits: 8
      YAML
      "unknown key" => <<~YAML,
        autonomous_merge:
          thresholds:
            max_comments: 3
      YAML
      "wrong scalar type" => <<~YAML,
        autonomous_merge:
          thresholds:
            max_commits: "9"
      YAML
      "negative maximum" => <<~YAML
        autonomous_merge:
          thresholds:
            max_commits: -1
      YAML
    }

    policies.each do |name, policy_yaml|
      result = evaluate(policy_yaml:) { |base_sha| evidence(base_sha:, files: files(1)) }

      assert_equal "UNKNOWN", result.fetch("verdict"), name
      refute_empty result.fetch("evidence_failures"), name
    end
  end

  def test_each_common_semantic_category_is_a_non_subtractable_human_gate
    categories = {
      "persistent_data_storage" => "persistent-data-storage",
      "infrastructure_delivery" => "infrastructure-delivery",
      "irreversible_external_effect" => "irreversible-external-effect",
      "public_compatibility" => "public-compatibility",
      "security_auth_privacy" => "security-auth-privacy",
      "architectural_product_judgment" => "architectural-product-judgment",
      "unresolved_maintainer_concern" => "architectural-product-judgment"
    }

    categories.each do |fact, gate|
      result = evaluate do |base_sha|
        evidence(
          base_sha:,
          files: files(1),
          semantic: semantic_assessment.merge(fact => true)
        )
      end

      assert_equal "human-approval-required", result.fetch("verdict"), fact
      assert_equal [gate], result.fetch("triggered_gates"), fact
    end
  end

  def test_reason_tagged_repo_paths_and_builtin_policy_sources_add_human_gates
    policy_yaml = <<~YAML
      autonomous_merge:
        human_review_paths:
          - id: checkout-hot-path
            pattern: app/services/checkout/**
            reason: hot-path
        policy_paths:
          - config/release-policy.yml
    YAML
    result = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [
          file("app/services/checkout/charge.rb"),
          file("config/release-policy.yml"),
          file("workflows/pr-processing.md")
        ]
      )
    end

    assert_equal "human-approval-required", result.fetch("verdict")
    assert_equal(
      ["autonomous-merge-policy-change", "repo-path:checkout-hot-path"],
      result.fetch("triggered_gates")
    )
    assert_includes result.fetch("path_matches"), {
      "path" => "app/services/checkout/charge.rb",
      "gate" => "repo-path:checkout-hot-path",
      "reason" => "hot-path"
    }
  end

  def test_other_repo_path_detail_survives_evaluation_and_human_closeout
    policy_yaml = <<~YAML
      autonomous_merge:
        human_review_paths:
          - id: checkout-boundary
            pattern: app/services/checkout/**
            reason: other
            detail: payment orchestration boundary
    YAML
    result = evaluate(policy_yaml:) do |base_sha|
      evidence(base_sha:, files: [file("app/services/checkout/charge.rb")])
    end

    assert_equal "human-approval-required", result.fetch("verdict")
    assert_includes result.fetch("path_matches"), {
      "path" => "app/services/checkout/charge.rb",
      "gate" => "repo-path:checkout-boundary",
      "reason" => "other",
      "detail" => "payment orchestration boundary"
    }

    stdout, stderr, status = Open3.capture3("ruby", CLOSEOUT_SCRIPT, stdin_data: JSON.generate(result))

    assert status.success?, stderr
    assert_empty stderr
    assert_includes stdout, 'matching ` "payment orchestration boundary" `'
    assert_includes stdout, '(other: ` "payment orchestration boundary" `)'
  end

  def test_renamed_protected_source_path_adds_human_gates_without_double_counting_metrics
    policy_yaml = <<~YAML
      autonomous_merge:
        human_review_paths:
          - id: protected-source
            pattern: protected/**
            reason: policy
        policy_paths:
          - protected/**
    YAML
    result = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [
          file(
            "lib/unprotected.rb",
            additions: 5,
            deletions: 3,
            status: "renamed",
            previous_path: "protected/source.rb"
          )
        ]
      )
    end

    assert_equal "human-approval-required", result.fetch("verdict")
    assert_equal(
      ["autonomous-merge-policy-change", "repo-path:protected-source"],
      result.fetch("triggered_gates")
    )
    assert_equal 1, result.dig("metrics", "changed_files")
    assert_equal 8, result.dig("metrics", "changed_lines")
    assert_includes result.fetch("path_matches"), {
      "path" => "protected/source.rb",
      "gate" => "repo-path:protected-source",
      "reason" => "policy"
    }
    assert_includes result.fetch("path_matches"), {
      "path" => "protected/source.rb",
      "gate" => "autonomous-merge-policy-change",
      "reason" => "policy"
    }
  end

  def test_evaluator_calibrator_libraries_and_checked_decisions_are_builtin_policy_sources
    fixture = JSON.parse(
      File.read(File.join(FIXTURE_DIR, "autonomous-merge-policy-sources.json"), encoding: "UTF-8")
    )
    protected_paths = fixture.fetch("paths")
    result = evaluate do |base_sha|
      evidence(base_sha:, files: protected_paths.map { |path| file(path) })
    end

    assert_equal fixture.fetch("expected_verdict"), result.fetch("verdict")
    assert_equal [fixture.fetch("expected_gate")], result.fetch("triggered_gates")
    protected_paths.each do |path|
      assert_includes result.fetch("path_matches"), {
        "path" => path,
        "gate" => "autonomous-merge-policy-change",
        "reason" => "policy"
      }
    end
  end

  def test_closeout_renderers_are_builtin_policy_sources_in_source_and_installed_layouts
    paths = [
      "skills/pr-batch/bin/autonomous-merge-closeout",
      ".agents/skills/pr-batch/bin/autonomous-merge-closeout"
    ]
    result = evaluate do |base_sha|
      evidence(base_sha:, files: paths.map { |path| file(path) })
    end

    assert_equal "human-approval-required", result.fetch("verdict")
    assert_equal ["autonomous-merge-policy-change"], result.fetch("triggered_gates")
    paths.each do |path|
      assert_includes result.fetch("path_matches"), {
        "path" => path,
        "gate" => "autonomous-merge-policy-change",
        "reason" => "policy"
      }
    end
  end

  def test_invalid_repo_glob_fails_closed
    result = evaluate(policy_yaml: <<~YAML) do |base_sha|
      autonomous_merge:
        human_review_paths:
          - id: bad-pattern
            pattern: ../secrets/**
            reason: security
    YAML
      evidence(base_sha:, files: files(1))
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert(result.fetch("evidence_failures").any? { |failure| failure.include?("invalid glob") })
  end

  def test_missing_human_review_path_reason_fails_closed_with_policy_error
    result = evaluate(policy_yaml: <<~YAML) do |base_sha|
      autonomous_merge:
        human_review_paths:
          - id: protected-path
            pattern: lib/**
    YAML
      evidence(base_sha:, files: [file("lib/protected.rb")])
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_includes(
      result.fetch("evidence_failures").join("; "),
      "autonomous_merge.human_review_paths[0].reason is invalid"
    )
  end

  def test_portable_globs_cross_zero_or_many_components_and_honor_bracket_classes
    policy_yaml = <<~YAML
      autonomous_merge:
        safe_path_groups:
          documentation:
            include:
              - docs/**/guide[0-9].md
            exclude:
              - docs/**/private/**
    YAML
    zero_component = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("docs/guide1.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    nested = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("docs/product/v2/guide2.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    excluded = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("docs/product/private/guide3.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end

    assert_equal "documentation", zero_component.fetch("safe_class")
    assert_equal "documentation", nested.fetch("safe_class")
    assert_equal "UNKNOWN", excluded.fetch("verdict")
    assert_includes excluded.fetch("evidence_failures"), "safe classification documentation contradicts path evidence"
  end

  def test_portable_globs_reject_empty_malformed_and_ambiguous_double_star_components
    patterns = [
      "docs/[]/guide.md",
      "docs/[!]/guide.md",
      "docs/[abc/guide.md",
      "docs/file**/guide.md",
      "docs/**suffix/guide.md",
      "docs/***/guide.md"
    ]

    patterns.each do |pattern|
      result = evaluate(policy_yaml: <<~YAML) do |base_sha|
        autonomous_merge:
          policy_paths:
            - #{pattern}
      YAML
        evidence(base_sha:, files: files(1))
      end

      assert_equal "UNKNOWN", result.fetch("verdict"), pattern
      assert(result.fetch("evidence_failures").any? { |failure| failure.include?("invalid glob") }, pattern)
    end
  end

  def test_safe_groups_are_conjunctive_and_never_subtract_size_or_hard_gates
    policy_yaml = <<~YAML
      autonomous_merge:
        safe_path_groups:
          documentation:
            include:
              - docs/**
            exclude:
              - docs/operator/**
          tests:
            include:
              - spec/**
            exclude:
              - spec/fixtures/runtime/**
    YAML
    safe = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("docs/guide.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    excluded = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("docs/operator/release.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    large = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: Array.new(30) { |index| file("docs/guide_#{index}.md") },
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    weakened_tests = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("spec/service_spec.rb")],
        semantic: semantic_assessment.merge("safe_class" => "tests", "test_change" => "weakens")
      )
    end

    assert_equal "documentation", safe.fetch("safe_class")
    assert_equal "UNKNOWN", excluded.fetch("verdict")
    assert_equal ["changed-files-limit"], large.fetch("triggered_gates")
    assert_equal "UNKNOWN", weakened_tests.fetch("verdict")
  end

  def test_portable_safe_path_groups_classify_docs_and_tests_without_repo_configuration
    documentation = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: [file("docs/usage.md"), file("guides/setup.txt"), file("notes.mdx")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    tests = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: [file("spec/service_spec.rb"), file("test/support/helper.rb"), file("src/__tests__/api.test.ts")],
        semantic: semantic_assessment.merge("safe_class" => "tests", "test_change" => "strengthens-only")
      )
    end

    assert_equal "autonomous-merge-eligible", documentation.fetch("verdict")
    assert_equal "documentation", documentation.fetch("safe_class")
    assert_equal "autonomous-merge-eligible", tests.fetch("verdict")
    assert_equal "tests", tests.fetch("safe_class")
  end

  def test_portable_safe_path_group_excludes_reject_policy_and_sensitive_documents_by_default
    cases = {
      "workflows/pr-processing.md" => true,
      "skills/pr-batch/SKILL.md" => true,
      "docs/adr/0003-smarter-autonomous-merge-gates.md" => true,
      "AGENTS.md" => true,
      "spec/AGENTS.md" => false,
      "CHANGELOG.md" => false,
      "README.md" => false,
      "SECURITY.md" => false
    }

    cases.each do |path, policy_gated|
      safe_class = path.end_with?(".md") && path.start_with?("spec/") ? "tests" : "documentation"
      result = evaluate do |base_sha|
        evidence(
          base_sha:,
          files: [file(path)],
          semantic: semantic_assessment.merge("safe_class" => safe_class, "test_change" => "strengthens-only")
        )
      end

      assert_equal "UNKNOWN", result.fetch("verdict"), path
      assert_includes result.fetch("evidence_failures"),
                      "safe classification #{safe_class} contradicts path evidence", path
      next unless policy_gated

      assert_includes result.fetch("triggered_gates"), "autonomous-merge-policy-change", path
    end
  end

  def test_consumer_safe_path_groups_add_patterns_without_removing_a_portable_exclude
    policy_yaml = <<~YAML
      autonomous_merge:
        safe_path_groups:
          documentation:
            include:
              - handbook/**
              - workflows/**
            exclude:
              - handbook/runbooks/**
    YAML
    added = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("handbook/onboarding.rst")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    portable_include_survives = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("docs/usage.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    consumer_exclude = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("handbook/runbooks/restore.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    portable_exclude_survives = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("workflows/pr-processing.md")],
        semantic: semantic_assessment.merge("safe_class" => "documentation")
      )
    end
    other_group_stays_portable = evaluate(policy_yaml:) do |base_sha|
      evidence(
        base_sha:,
        files: [file("spec/service_spec.rb")],
        semantic: semantic_assessment.merge("safe_class" => "tests", "test_change" => "strengthens-only")
      )
    end

    assert_equal "documentation", added.fetch("safe_class")
    assert_equal "documentation", portable_include_survives.fetch("safe_class")
    assert_equal "UNKNOWN", consumer_exclude.fetch("verdict")
    assert_equal "UNKNOWN", portable_exclude_survives.fetch("verdict")
    assert_includes portable_exclude_survives.fetch("evidence_failures"),
                    "safe classification documentation contradicts path evidence"
    assert_equal "tests", other_group_stays_portable.fetch("safe_class")
  end

  def test_missing_false_invalid_or_ambiguous_safe_classification_fails_closed
    policy_yaml = <<~YAML
      autonomous_merge:
        safe_path_groups:
          documentation:
            include:
              - docs/**
          tests:
            include:
              - spec/**
    YAML
    semantic_cases = {
      "missing completeness" => semantic_assessment.tap { |value| value.delete("safe_classification_complete") },
      "false completeness" => semantic_assessment.merge("safe_classification_complete" => false),
      "missing class" => semantic_assessment.tap { |value| value.delete("safe_class") },
      "invalid class" => semantic_assessment.merge("safe_class" => "mostly-documentation"),
      "path mismatch" => semantic_assessment.merge("safe_class" => "documentation"),
      "ambiguous test effect" => semantic_assessment.merge("safe_class" => "tests", "test_change" => "UNKNOWN")
    }

    semantic_cases.each do |name, semantic|
      path = name == "ambiguous test effect" ? "spec/service_spec.rb" : "lib/service.rb"
      result = evaluate(policy_yaml:) do |base_sha|
        evidence(base_sha:, files: [file(path)], semantic:)
      end

      assert_equal "UNKNOWN", result.fetch("verdict"), name
      refute_empty result.fetch("evidence_failures"), name
    end

    explicit_none = evaluate(policy_yaml:) do |base_sha|
      evidence(base_sha:, files: [file("lib/service.rb")])
    end
    assert_equal "autonomous-merge-eligible", explicit_none.fetch("verdict")
    assert_equal "none", explicit_none.fetch("safe_class")
  end

  def test_generated_paths_are_reporting_only_and_all_generated_lines_still_count
    result = evaluate(policy_yaml: <<~YAML) do |base_sha|
      autonomous_merge:
        generated_paths:
          - generated/**
    YAML
      evidence(
        base_sha:,
        files: [file("generated/client.rb", additions: 1_000)]
      )
    end

    assert_equal 1_000, result.dig("metrics", "changed_lines")
    assert_equal ["changed-lines-limit"], result.fetch("triggered_gates")
    assert_includes result.fetch("path_matches"), {
      "path" => "generated/client.rb",
      "classification" => "generated"
    }
  end

  def test_exact_head_human_decision_requires_durable_marker_exact_gate_set_and_proven_provenance
    url = "https://github.com/example/repo/pull/1#issuecomment-1"
    valid_comment = decision_comment(
      id: "1",
      url:,
      body: decision_body(head_sha: HEAD_SHA, gates: ["changed-files-limit"], evidence: url)
    )
    approved = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(30),
        decision_comments: [valid_comment],
        semantic: semantic_assessment.merge(
          "decision_provenance" => [decision_provenance("1")]
        )
      )
    end
    stale = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(30),
        decision_comments: [
          valid_comment.merge(
            "body" => decision_body(head_sha: "f" * 40, gates: ["changed-files-limit"], evidence: url)
          )
        ],
        semantic: semantic_assessment.merge(
          "decision_provenance" => [decision_provenance("1")]
        )
      )
    end
    unproven = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(30),
        decision_comments: [valid_comment],
        semantic: semantic_assessment.merge("decision_provenance" => [])
      )
    end

    assert_equal "human-approved-for-current-head", approved.fetch("verdict")
    assert_equal url, approved.dig("human_decision_evidence", "url")
    assert_equal "human-approval-required", stale.fetch("verdict")
    assert_equal "UNKNOWN", unproven.fetch("verdict")
    assert_equal "uncertain", unproven.dig("human_decision_evidence", "status")
    assert_includes unproven.fetch("evidence_failures"), "exact current-head human decision provenance is uncertain"
  end

  def test_uppercase_objective_head_is_canonicalized_before_decision_matching_and_closeout
    url = "https://github.com/example/repo/pull/1#issuecomment-1"
    valid_comment = decision_comment(
      id: "1",
      url:,
      body: decision_body(head_sha: HEAD_SHA, gates: ["changed-files-limit"], evidence: url)
    )
    approved = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(30),
        decision_comments: [valid_comment],
        semantic: semantic_assessment.merge(
          "decision_provenance" => [decision_provenance("1")]
        )
      ).tap { |input| input.fetch("objective")["head_sha"] = HEAD_SHA.upcase }
    end
    blocking = evaluate do |base_sha|
      evidence(base_sha:, files: files(30)).tap do |input|
        input.fetch("objective")["head_sha"] = HEAD_SHA.upcase
      end
    end

    assert_equal "human-approved-for-current-head", approved.fetch("verdict")
    assert_equal HEAD_SHA, approved.fetch("head_sha")
    assert_equal "human-approval-required", blocking.fetch("verdict")
    assert_equal HEAD_SHA, blocking.fetch("head_sha")

    stdout, stderr, status = Open3.capture3("ruby", CLOSEOUT_SCRIPT, stdin_data: JSON.generate(blocking))

    assert status.success?, stderr
    assert_empty stderr
    assert_includes stdout, "Exact head: `#{HEAD_SHA}`"
  end

  def test_newer_malformed_decision_does_not_erase_older_valid_exact_head_decision
    older_url = "https://github.com/example/repo/pull/1#issuecomment-1"
    comments = [
      decision_comment(
        id: "1",
        url: older_url,
        created_at: "2026-07-20T00:00:00Z",
        body: decision_body(head_sha: HEAD_SHA, gates: ["changed-files-limit"], evidence: older_url)
      ),
      decision_comment(
        id: "2",
        url: "https://github.com/example/repo/pull/1#issuecomment-2",
        created_at: "2026-07-21T00:00:00Z",
        body: "preface\n<!-- autonomous-merge-risk-decision:v1 -->\n---\ndecision: approve\n..."
      )
    ]
    result = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(30),
        decision_comments: comments,
        semantic: semantic_assessment.merge(
          "decision_provenance" => [decision_provenance("1"), decision_provenance("2")]
        )
      )
    end

    assert_equal "human-approved-for-current-head", result.fetch("verdict")
    assert_equal older_url, result.dig("human_decision_evidence", "url")
  end

  def test_live_objective_collection_does_not_trust_fixture_completeness_flags
    incomplete_files = evaluate do |base_sha|
      evidence(base_sha:, files: files(1)).tap do |input|
        input.fetch("objective")["files_complete"] = false
      end
    end
    incomplete_commits = evaluate do |base_sha|
      evidence(base_sha:, files: files(1)).tap do |input|
        input.fetch("objective")["commits_complete"] = false
      end
    end
    incomplete_reviews_shadow = evaluate do |base_sha|
      evidence(base_sha:, files: files(1)).tap do |input|
        input.fetch("objective")["reviews_complete"] = false
      end
    end
    incomplete_reviews_enforced = evaluate(reviewed_heads_mode: "enforced") do |base_sha|
      evidence(base_sha:, files: files(1)).tap do |input|
        input.fetch("objective")["reviews_complete"] = false
      end
    end
    rollback_unknown = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(1),
        semantic: semantic_assessment.merge("rollback_assessment" => "UNKNOWN")
      )
    end

    assert_equal "autonomous-merge-eligible", incomplete_files.fetch("verdict")
    assert_equal "autonomous-merge-eligible", incomplete_commits.fetch("verdict")
    assert_equal "autonomous-merge-eligible", incomplete_reviews_shadow.fetch("verdict")
    assert_equal [], incomplete_reviews_shadow.fetch("shadow_evidence_unknown")
    assert_equal "autonomous-merge-eligible", incomplete_reviews_enforced.fetch("verdict")
    assert_equal "UNKNOWN", rollback_unknown.fetch("verdict")
  end

  def test_invalid_rollback_is_normalized_to_unknown_and_remains_renderable
    ["probably-reversible", nil].each do |rollback|
      result = evaluate do |base_sha|
        evidence(
          base_sha:,
          files: files(1),
          semantic: semantic_assessment.merge("rollback_assessment" => rollback)
        )
      end

      assert_equal "UNKNOWN", result.fetch("verdict"), rollback.inspect
      assert_equal "UNKNOWN", result.fetch("rollback_assessment"), rollback.inspect
      assert_includes result.fetch("evidence_failures"), "rollback assessment is missing or unknown"

      stdout, stderr, status = Open3.capture3("ruby", CLOSEOUT_SCRIPT, stdin_data: JSON.generate(result))

      assert status.success?, "#{rollback.inspect}: #{stderr}"
      assert_empty stderr, rollback.inspect
      assert_includes stdout, "Rollback assessment: `UNKNOWN`"
      assert_includes stdout, '"rollback assessment is missing or unknown"'
    end
  end

  def test_live_deleted_comment_author_returns_structured_unknown
    result = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(1),
        decision_comments: [
          decision_comment(
            id: "123",
            url: "https://github.com/example/repo/pull/1#issuecomment-123",
            body: "decision"
          ).merge("author" => "__deleted__")
        ]
      )
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_includes result.fetch("evidence_failures"), "GitHub comment author must contain a nonempty login"
  end

  def test_live_capped_or_mismatched_file_lists_return_structured_unknown
    mismatch = evaluate do |base_sha|
      evidence(base_sha:, files: files(1)).tap do |input|
        input.fetch("objective")["github_changed_files"] = 2
      end
    end
    capped = evaluate do |base_sha|
      evidence(base_sha:, files: files(1)).tap do |input|
        input.fetch("objective")["github_changed_files"] = 3_000
      end
    end

    assert_equal "UNKNOWN", mismatch.fetch("verdict")
    assert_empty mismatch.fetch("metrics")
    assert(
      mismatch.fetch("evidence_failures").any? { |failure| failure.include?("listed file count") }
    )
    assert_equal "UNKNOWN", capped.fetch("verdict")
    assert_empty capped.fetch("metrics")
    assert(
      capped.fetch("evidence_failures").any? { |failure| failure.include?("Files API cap") }
    )
  end

  def test_commit_and_nonnull_submitted_review_heads_require_full_shas
    malformed_commit = evaluate do |base_sha|
      evidence(base_sha:, files: files(1), commits: [{ "sha" => "abc123" }])
    end
    malformed_shadow_review = evaluate do |base_sha|
      evidence(base_sha:, files: files(1), reviews: [review("COMMENTED", "abc123")])
    end
    malformed_enforced_review = evaluate(reviewed_heads_mode: "enforced") do |base_sha|
      evidence(base_sha:, files: files(1), reviews: [review("APPROVED", "g" * 40)])
    end

    [malformed_commit, malformed_shadow_review, malformed_enforced_review].each do |result|
      assert_equal "UNKNOWN", result.fetch("verdict")
      assert(result.fetch("evidence_failures").any? { |failure| failure.include?("full hexadecimal SHA") })
    end
    assert_equal [], malformed_shadow_review.fetch("shadow_evidence_unknown")
  end

  def test_unestablished_helper_provenance_fails_closed
    Dir.mktmpdir("autonomous-merge-helper-provenance-test", SAFE_TMP_PARENT) do |root|
      base_sha = initialize_trusted_base(root, policy_yaml: nil)
      calibration_path = write_calibration(root)
      input = JSON.generate(evidence(base_sha:, files: files(1)))

      missing = invoke(root:, calibration_path:, stdin_data: input, helper_provenance: nil)
      malformed = invoke(
        root:,
        calibration_path:,
        stdin_data: input,
        helper_provenance: "verified-installed-pack:not-a-digest"
      )

      assert_equal "UNKNOWN", missing.fetch("verdict")
      assert_equal "UNKNOWN", malformed.fetch("verdict")
      assert_includes missing.fetch("evidence_failures").first, "helper provenance"
      assert_includes malformed.fetch("evidence_failures").first, "helper provenance"
    end
  end

  def test_runtime_trust_authenticates_closeout_renderer_for_base_and_installed_pack
    trusted_base = evaluate { |base_sha| evidence(base_sha:, files: files(1)) }

    assert_equal "skills/pr-batch/bin/autonomous-merge-closeout",
                 trusted_base.dig("helper_trust", "manifest", "closeout-helper")

    Dir.mktmpdir("autonomous-merge-installed-closeout-trust-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil)
      installed = invoke(
        root:,
        calibration_path:,
        evaluation: evidence(base_sha:, files: files(1)),
        helper_provenance: installed_pack_provenance(calibration_path)
      )

      assert_equal "autonomous-merge-eligible", installed.fetch("verdict")
      assert_equal CLOSEOUT_SCRIPT, installed.dig("helper_trust", "manifest", "closeout-helper")
    end
  end

  def test_runtime_trust_requires_the_closeout_renderer_to_be_executable
    Dir.mktmpdir("autonomous-merge-closeout-mode-test", SAFE_TMP_PARENT) do |root|
      closeout_path = File.join(root, "autonomous-merge-closeout")
      File.write(closeout_path, "#!/bin/sh\nexit 0\n")
      File.chmod(0o644, closeout_path)
      sources = {
        "closeout-helper" => {
          path: closeout_path,
          tree_paths: ["skills/pr-batch/bin/autonomous-merge-closeout"]
        }
      }
      original_runtime_sources = AutonomousMergeRuntimeTrust.method(:runtime_sources)
      AutonomousMergeRuntimeTrust.define_singleton_method(:runtime_sources) do |_calibration_path|
        sources
      end

      error = assert_raises(AutonomousMergeRuntimeTrust::ExecutableError) do
        AutonomousMergeRuntimeTrust.trusted_runtime_sources("unused-calibration")
      end

      assert_includes error.message, "closeout-helper runtime source is not executable"
    ensure
      if original_runtime_sources
        AutonomousMergeRuntimeTrust.define_singleton_method(
          :runtime_sources,
          original_runtime_sources
        )
      end
    end
  end

  def test_closeout_workflow_uses_the_authenticated_runtime_directory
    workflow = File.read(
      File.expand_path("../../../workflows/pr-batch-integration-closeout.md", __dir__),
      encoding: "UTF-8"
    )
    index = File.read(File.expand_path("../../../workflows/pr-processing.md", __dir__), encoding: "UTF-8")
    skill = File.read(File.expand_path("../SKILL.md", __dir__), encoding: "UTF-8")

    assert_includes workflow, '"${TRUSTED_PR_BATCH_SKILL_DIR}/bin/autonomous-merge-closeout"'
    assert_includes skill, "pr-batch-integration-closeout.md#autonomous-merge-eligibility-gate"
    assert_includes index, "pr-batch-integration-closeout.md#autonomous-merge-eligibility"
    assert_includes workflow,
                    'git cat-file -e "${TRUSTED_BASE_SHA}:skills/pr-batch/bin/autonomous-merge-closeout"'
    assert_includes workflow,
                    'git cat-file -e "${TRUSTED_BASE_SHA}:.agents/skills/pr-batch/bin/autonomous-merge-closeout"'
  end

  def test_unverified_stdin_objective_cannot_establish_a_passing_verdict
    Dir.mktmpdir("autonomous-merge-unverified-stdin-test", SAFE_TMP_PARENT) do |root|
      base_sha = initialize_trusted_base(root, policy_yaml: nil)
      calibration_path = write_calibration(root)
      result = invoke(
        root:,
        calibration_path:,
        stdin_data: JSON.generate(evidence(base_sha:, files: files(1))),
        helper_provenance: installed_pack_provenance(calibration_path)
      )

      assert_equal "UNKNOWN", result.fetch("verdict")
      assert_includes result.fetch("evidence_failures").first, "stdin objective evidence is unverified"
    end
  end

  def test_trusted_base_claim_fails_when_any_runtime_source_is_absent_from_the_tree
    Dir.mktmpdir("autonomous-merge-missing-runtime-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil)
      result = invoke(
        root:,
        calibration_path:,
        stdin_data: JSON.generate(evidence(base_sha:, files: files(1)))
      )

      assert_equal "UNKNOWN", result.fetch("verdict")
      assert(result.fetch("evidence_failures").any? { |failure| failure.include?("byte-identical") })
    end
  end

  def test_trusted_base_claim_rejects_runtime_bytes_modified_in_the_claimed_tree
    Dir.mktmpdir("autonomous-merge-modified-runtime-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      helper_path = File.join(root, "skills/pr-batch/bin/autonomous-merge-eligibility")
      File.open(helper_path, "a") { |file| file.write("\n# branch-modified runtime\n") }
      system("git", "-C", root, "add", helper_path, exception: true)
      system("git", "-C", root, "commit", "--quiet", "-m", "modify runtime", exception: true)
      base_sha, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
      assert status.success?
      base_sha = base_sha.strip
      system("git", "-C", root, "update-ref", "refs/heads/trusted-base", base_sha, exception: true)

      result = invoke(
        root:,
        calibration_path:,
        stdin_data: JSON.generate(evidence(base_sha:, files: files(1)))
      )

      assert_equal "UNKNOWN", result.fetch("verdict")
      assert(result.fetch("evidence_failures").any? { |failure| failure.start_with?("helper is not byte-identical") })
    end
  end

  def test_installed_pack_claim_binds_the_selected_calibration_bytes
    Dir.mktmpdir("autonomous-merge-installed-pack-digest-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil)
      provenance = installed_pack_provenance(calibration_path)
      File.open(calibration_path, "a") { |file| file.write("\n") }
      result = invoke(
        root:,
        calibration_path:,
        stdin_data: JSON.generate(evidence(base_sha:, files: files(1))),
        helper_provenance: provenance
      )

      assert_equal "UNKNOWN", result.fetch("verdict")
      assert_includes result.fetch("evidence_failures").first, "runtime digest mismatch"
      assert_equal "UNKNOWN", result.fetch("helper_provenance")
      assert_equal "unverified", result.dig("helper_trust", "status")
    end
  end

  def test_repo_contained_semantic_assessment_cannot_establish_a_passing_verdict
    Dir.mktmpdir("autonomous-merge-repo-semantic-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      evaluation = evidence(base_sha:, files: files(1))
      semantic_path = File.join(root, "semantic-assessment.json")
      File.write(semantic_path, JSON.generate(evaluation.fetch("semantic_assessment")))
      result = invoke(root:, calibration_path:, evaluation:, semantic_path:)

      assert_equal "UNKNOWN", result.fetch("verdict")
      assert_includes result.fetch("evidence_failures").first, "outside the evaluated repository"
    end
  end

  def test_unavailable_or_unreadable_semantic_assessment_returns_structured_unknown
    Dir.mktmpdir("autonomous-merge-unreadable-semantic-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      evaluation = evidence(base_sha:, files: files(1))

      Dir.mktmpdir("autonomous-merge-semantic-inputs", SAFE_TMP_PARENT) do |input_root|
        directory_path = File.join(input_root, "assessment-directory")
        missing_path = File.join(input_root, "missing-assessment.json")
        unreadable_path = File.join(input_root, "unreadable-assessment.json")
        Dir.mkdir(directory_path)
        File.write(unreadable_path, JSON.generate(evaluation.fetch("semantic_assessment")))
        File.chmod(0o000, unreadable_path)
        unavailable_paths = [directory_path, missing_path]
        begin
          File.read(unreadable_path, encoding: "UTF-8")
        rescue Errno::EACCES
          unavailable_paths << unreadable_path
        end

        unavailable_paths.each do |semantic_path|
          result = invoke(root:, calibration_path:, evaluation:, semantic_path:)

          assert_equal "UNKNOWN", result.fetch("verdict"), semantic_path
          assert_equal(
            "semantic assessment path is unavailable or unreadable",
            result.fetch("evidence_failures").first,
            semantic_path
          )
        end
      ensure
        File.chmod(0o600, unreadable_path) if unreadable_path && File.exist?(unreadable_path)
      end
    end
  end

  def test_live_cli_rejects_the_github_commits_api_cap
    result = evaluate do |base_sha|
      evidence(base_sha:, files: files(1)).tap do |evaluation|
        evaluation.fetch("objective")["github_commits"] = 250
      end
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_includes result.fetch("evidence_failures").first, "Commits API cap"
  end

  def test_malformed_evaluation_and_calibration_inputs_return_structured_unknown
    Dir.mktmpdir("autonomous-merge-eligibility-malformed-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      base_sha = initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      malformed_json = invoke(root:, calibration_path:, stdin_data: "{")
      missing_reviews = evidence(base_sha:, files: files(1))
      missing_reviews.fetch("objective").delete("reviews")
      malformed_shape = invoke(root:, calibration_path:, stdin_data: JSON.generate(missing_reviews))

      File.write(calibration_path, JSON.generate("contract" => "wrong", "version" => 1))
      malformed_calibration = invoke(
        root:,
        calibration_path:,
        evaluation: evidence(base_sha:, files: files(1)),
        helper_provenance: installed_pack_provenance(calibration_path)
      )

      assert_equal "UNKNOWN", malformed_json.fetch("verdict")
      assert_includes malformed_json.fetch("evidence_failures").first, "malformed"
      assert_equal "UNKNOWN", malformed_shape.fetch("verdict")
      assert_includes malformed_shape.fetch("evidence_failures").first, "stdin objective evidence is unverified"
      assert_equal "UNKNOWN", malformed_calibration.fetch("verdict")
      assert_includes malformed_calibration.fetch("evidence_failures").first, "calibration"
      assert_match(
        /\Averified-installed-pack:[0-9a-f]{64}\z/,
        malformed_calibration.fetch("helper_provenance")
      )
      assert_equal "mechanically-verified", malformed_calibration.dig("helper_trust", "status")
    end
  end

  def test_invalid_utf8_stdin_returns_structured_unknown
    Dir.mktmpdir("autonomous-merge-invalid-stdin-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root)
      initialize_trusted_base(root, policy_yaml: nil, include_runtime: true)
      invalid_json = "{\"x\":".b + "\xFF}".b

      result = invoke(root:, calibration_path:, stdin_data: invalid_json)

      assert_equal "UNKNOWN", result.fetch("verdict")
      assert_match(/malformed autonomous-merge evaluation JSON/, result.fetch("evidence_failures").first)
      assert_predicate result.fetch("evidence_failures").first, :valid_encoding?
    end
  end

  def test_risk_marker_never_converts_unknown_evidence_into_approval
    url = "https://github.com/example/repo/pull/1#issuecomment-1"
    result = evaluate do |base_sha|
      evidence(
        base_sha:,
        files: files(30),
        decision_comments: [
          decision_comment(
            id: "1",
            url:,
            body: decision_body(head_sha: HEAD_SHA, gates: ["changed-files-limit"], evidence: url)
          )
        ],
        semantic: semantic_assessment.merge(
          "rollback_assessment" => "UNKNOWN",
          "decision_provenance" => [decision_provenance("1")]
        )
      )
    end

    assert_equal "UNKNOWN", result.fetch("verdict")
    assert_equal "none", result.dig("human_decision_evidence", "status")
  end

  def test_hichee_9831_regression_fixture_triggers_every_risk_independently_and_when_combined
    fixture = JSON.parse(
      File.read(File.join(FIXTURE_DIR, "autonomous-merge-hichee-9831.json"), encoding: "UTF-8")
    )
    observed = fixture.fetch("observed")
    cases = {
      "changed_files" => ->(base_sha) { evidence(base_sha:, files: files(observed.fetch("changed_files"))) },
      "changed_lines" => lambda do |base_sha|
        evidence(base_sha:, files: [file("app/models/listing.rb", additions: observed.fetch("changed_lines"))])
      end,
      "commits" => lambda do |base_sha|
        commits = Array.new(observed.fetch("commits")) { |index| { "sha" => format("%040x", index + 1) } }
        evidence(base_sha:, files: files(1), commits:)
      end,
      "reviewed_heads_after_graduation" => lambda do |base_sha|
        reviews = Array.new(observed.fetch("reviewed_heads")) do |index|
          review("COMMENTED", format("%040x", index + 1))
        end
        evidence(base_sha:, files: files(1), reviews:)
      end,
      "migrations" => lambda do |base_sha|
        semantic = semantic_assessment.merge("persistent_data_storage" => true)
        evidence(base_sha:, files: [file("db/migrate/add_redirects.rb")], semantic:)
      end,
      "cross_cutting_runtime" => lambda do |base_sha|
        semantic = semantic_assessment.merge("architectural_product_judgment" => true)
        evidence(base_sha:, files: [file("app/models/listing.rb")], semantic:)
      end,
      "rollback_uncertain" => lambda do |base_sha|
        semantic = semantic_assessment.merge("rollback_assessment" => "UNKNOWN")
        evidence(base_sha:, files: files(1), semantic:)
      end,
      "unresolved_maintainer_architecture_concern" => lambda do |base_sha|
        semantic = semantic_assessment.merge("unresolved_maintainer_concern" => true)
        evidence(base_sha:, files: files(1), semantic:)
      end
    }

    cases.each do |name, input_builder|
      mode = name == "reviewed_heads_after_graduation" ? "enforced" : "shadow"
      result = evaluate(reviewed_heads_mode: mode, &input_builder)
      expectation = fixture.fetch("independent_expectations").fetch(name)
      assert_equal expectation.fetch("verdict"), result.fetch("verdict"), name
      gate = expectation["gate"]
      assert_includes result.fetch("triggered_gates"), gate, name if gate
    end

    combined = evaluate do |base_sha|
      reviews = Array.new(observed.fetch("reviewed_heads")) do |index|
        review("COMMENTED", format("%040x", index + 1))
      end
      evidence(
        base_sha:,
        files: Array.new(observed.fetch("changed_files")) do |index|
          file(
            index.zero? ? "db/migrate/add_redirects.rb" : "app/runtime/file_#{index}.rb",
            additions: index.zero? ? observed.fetch("changed_lines") : 0
          )
        end,
        commits: Array.new(observed.fetch("commits")) { |index| { "sha" => format("%040x", index + 1) } },
        reviews:,
        semantic: semantic_assessment.merge(
          "persistent_data_storage" => true,
          "architectural_product_judgment" => true,
          "unresolved_maintainer_concern" => true,
          "rollback_assessment" => "forward-recovery-established"
        )
      ).merge("ordinary_readiness" => fixture.fetch("ordinary_readiness"))
    end
    assert_equal fixture.dig("combined_expectation", "verdict"), combined.fetch("verdict")
  end

  def test_decision_marker_parser_rejects_non_exact_envelopes
    url = "https://github.com/example/repo/pull/1#issuecomment-1"
    valid = decision_body(head_sha: HEAD_SHA, gates: ["changed-files-limit"], evidence: url)
    invalid = {
      "marker later in body" => "preface\n#{valid}",
      "multiple markers" => "#{valid}\n<!-- autonomous-merge-risk-decision:v1 -->",
      "CRLF boundary" => valid.gsub("\n", "\r\n"),
      "trailing prose" => "#{valid}\ntrailing",
      "alias" => valid.sub("head_sha: #{HEAD_SHA}", "head_sha: &head #{HEAD_SHA}")
                      .sub("approved_by: maintainer", "approved_by: *head"),
      "custom tag" => valid.sub("head_sha: #{HEAD_SHA}", "head_sha: !custom #{HEAD_SHA}"),
      "duplicate key" => valid.sub("decision: approve", "decision: approve\ndecision: approve"),
      "unknown key" => valid.sub("decision: approve", "extra: value\ndecision: approve"),
      "multiple YAML documents" => "#{valid}\n---\ndecision: approve\n..."
    }

    refute_nil AutonomousMergeDecision.parse(valid)
    invalid.each do |name, body|
      assert_nil AutonomousMergeDecision.parse(body), name
    end
  end

  # Trusted-base runtime verification must run inside the bounded autonomous
  # replay lifecycle (issue #635).

  def test_trusted_base_verification_is_bounded_and_reaps_its_owned_git_process_group
    Dir.mktmpdir("trusted-base-replay-deadline", SAFE_TMP_PARENT) do |root|
      pid_file, stalling_git, = write_stalling_git(root)
      sources = trusted_base_sources(root)
      base_sha = "b" * 40
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = assert_raises(AutonomousMergeRuntimeTrust::ReplayTimeout) do
        Timeout.timeout(60) do
          AutonomousMergeRuntimeTrust.verify_trusted_base(
            repo_root: root,
            base_sha: base_sha,
            claim: "trusted-base:#{base_sha}",
            sources: sources,
            git_command: stalling_git,
            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
          )
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert error.cleanup_confirmed, "the owned git process group must be reaped"
      assert_equal "trusted-base-runtime-verification", error.phase
      assert_operator elapsed, :<, 30
      refute alive_after_wait?(read_recorded_pid(pid_file), 10),
             "a stalled trusted-base read must leave no descendant alive"
    end
  end

  def test_trusted_base_verification_reports_unconfirmed_cleanup_distinctly
    Dir.mktmpdir("trusted-base-replay-cleanup", SAFE_TMP_PARENT) do |root|
      pid_file, stalling_git, = write_stalling_git(root)
      sources = trusted_base_sources(root)
      base_sha = "c" * 40
      original = AutonomousMergeRuntimeTrust.method(:trusted_base_process_group_alive?)
      AutonomousMergeRuntimeTrust.define_singleton_method(
        :trusted_base_process_group_alive?
      ) { |_pid| true }

      error = assert_raises(AutonomousMergeRuntimeTrust::ReplayTimeout) do
        Timeout.timeout(60) do
          AutonomousMergeRuntimeTrust.verify_trusted_base(
            repo_root: root,
            base_sha: base_sha,
            claim: "trusted-base:#{base_sha}",
            sources: sources,
            git_command: stalling_git,
            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
          )
        end
      end

      refute error.cleanup_confirmed
      assert_includes error.message, "UNKNOWN"
      refute alive_after_wait?(read_recorded_pid(pid_file), 10),
             "forced cleanup must still signal the whole owned process group"
    ensure
      if original
        AutonomousMergeRuntimeTrust.define_singleton_method(
          :trusted_base_process_group_alive?, original
        )
      end
    end
  end

  def test_trusted_base_read_stays_in_the_outer_replay_group_when_not_the_owner
    Dir.mktmpdir("trusted-base-inherited-group", SAFE_TMP_PARENT) do |root|
      pgid_file, recording_git = write_pgid_recording_git(root)
      base_sha = "d" * 40

      AutonomousMergeRuntimeTrust.verify_trusted_base(
        repo_root: root,
        base_sha: base_sha,
        claim: "trusted-base:#{base_sha}",
        sources: trusted_base_sources(root),
        git_command: recording_git,
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60,
        own_process_group: false
      )

      assert_equal Process.getpgid(0), Integer(File.read(pgid_file).strip),
                   "a read inside an outer-owned replay group must not nest a new group"
    end
  end

  def test_trusted_base_read_owns_its_process_group_for_the_outermost_caller
    Dir.mktmpdir("trusted-base-owned-group", SAFE_TMP_PARENT) do |root|
      pgid_file, recording_git = write_pgid_recording_git(root)
      base_sha = "e" * 40

      AutonomousMergeRuntimeTrust.verify_trusted_base(
        repo_root: root,
        base_sha: base_sha,
        claim: "trusted-base:#{base_sha}",
        sources: trusted_base_sources(root),
        git_command: recording_git,
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      )

      refute_equal Process.getpgid(0), Integer(File.read(pgid_file).strip),
                   "the outermost caller must own a reapable group per read"
    end
  end

  def test_unexpected_read_failure_still_reaps_the_trusted_base_child
    Dir.mktmpdir("trusted-base-unexpected-failure", SAFE_TMP_PARENT) do |root|
      pid_file, stalling_git, ready_file = write_stalling_git(root)
      base_sha = "f" * 40
      original = AutonomousMergeRuntimeTrust.method(:drain_trusted_base_pipe)
      AutonomousMergeRuntimeTrust.define_singleton_method(:drain_trusted_base_pipe) do |*_args|
        sleep(0.01) until File.exist?(ready_file)

        raise IOError, "simulated trusted-base pipe failure"
      end

      assert_raises(IOError) do
        Timeout.timeout(60) do
          AutonomousMergeRuntimeTrust.verify_trusted_base(
            repo_root: root,
            base_sha: base_sha,
            claim: "trusted-base:#{base_sha}",
            sources: trusted_base_sources(root),
            git_command: stalling_git,
            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
          )
        end
      end

      refute alive_after_wait?(read_recorded_pid(pid_file), 10),
             "an unexpected read failure must still reap the owned process group"
    ensure
      if original
        AutonomousMergeRuntimeTrust.define_singleton_method(:drain_trusted_base_pipe, original)
      end
    end
  end

  def test_cleanup_probes_treat_unsignalable_process_groups_as_still_alive
    # Signal 0 against pid 1 is side-effect free and raises EPERM for an
    # unprivileged user. Cleanup must read that as "still alive" and fail closed
    # with UNKNOWN evidence rather than letting the error escape.
    assert AutonomousMergeRuntimeTrust.trusted_base_process_group_alive?(-1)
    assert_nil AutonomousMergeRuntimeTrust.signal_trusted_base_target("TERM", -unreachable_pid)
  end

  def unreachable_pid
    candidate = 4_194_303
    candidate += 1 while process_alive?(candidate)
    candidate
  end

  def test_inherited_group_cleanup_escalates_to_kill_without_signalling_the_shared_group
    descendant = nil
    Dir.mktmpdir("trusted-base-inherited-cleanup", SAFE_TMP_PARENT) do |root|
      pid_file, stalling_git, _ready_file, git_pid_file = write_stalling_git(root)
      base_sha = "a" * 40

      assert_raises(AutonomousMergeRuntimeTrust::ReplayTimeout) do
        Timeout.timeout(60) do
          AutonomousMergeRuntimeTrust.verify_trusted_base(
            repo_root: root,
            base_sha: base_sha,
            claim: "trusted-base:#{base_sha}",
            sources: trusted_base_sources(root),
            git_command: stalling_git,
            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1,
            own_process_group: false
          )
        end
      end

      descendant = read_recorded_pid(pid_file)

      refute alive_after_wait?(read_recorded_pid(git_pid_file), 10),
             "a TERM-ignoring read must be escalated to KILL and reaped"
      assert process_alive?(descendant),
             "inherited-group cleanup must signal only its own child, never the shared group"
    end
  ensure
    terminate_fixture_process(descendant)
  end

  private

  def invoke(root:, calibration_path:, stdin_data: "", evaluation: nil, semantic_path: nil,
             helper_provenance: :trusted_base, subprocess_env: {}, gh_invalid_utf8_field: nil,
             invalid_utf8_semantic_field: nil, invalid_utf8_semantic_syntax: false)
    command = [
      "ruby",
      SCRIPT,
      "--repo-root", root,
      "--trusted-base", "trusted-base",
      "--calibration-decision", calibration_path
    ]
    if helper_provenance
      resolved_provenance = if helper_provenance == :trusted_base
                              sha, status = Open3.capture2("git", "-C", root, "rev-parse", "trusted-base")
                              assert status.success?
                              "trusted-base:#{sha.strip}"
                            else
                              helper_provenance
                            end
      command.concat(["--trusted-helper-provenance", resolved_provenance])
    end
    if evaluation
      Dir.mktmpdir("autonomous-merge-live-input", SAFE_TMP_PARENT) do |input_root|
        objective_path = File.join(input_root, "objective.json")
        resolved_semantic_path = semantic_path || File.join(input_root, "semantic.json")
        fake_gh = File.join(input_root, "gh")
        File.write(objective_path, JSON.generate(evaluation.fetch("objective"), ascii_only: true))
        unless semantic_path
          semantic_json = JSON.generate(evaluation.fetch("semantic_assessment"))
          if invalid_utf8_semantic_syntax
            semantic_json = "{\"x\":".b + "\xFF}".b
          elsif invalid_utf8_semantic_field
            semantic_value = evaluation.fetch("semantic_assessment").fetch(invalid_utf8_semantic_field)
            semantic_json = semantic_json.b.sub(semantic_value.b, "\xFF".b)
          end
          File.binwrite(resolved_semantic_path, semantic_json)
        end
        write_fake_gh(fake_gh)
        command.concat(
          ["--repo", "example/repo", "--pr", "1", "--semantic-assessment", resolved_semantic_path]
        )
        stdout, stderr, status = Open3.capture3(
          {
            "AUTONOMOUS_MERGE_GH" => fake_gh,
            "CURRENT_INTEGRATION_GH" => fake_gh,
            "AUTONOMOUS_MERGE_TEST_OBJECTIVE" => objective_path,
            "AUTONOMOUS_MERGE_TEST_INVALID_UTF8_FIELD" => gh_invalid_utf8_field.to_s
          }.merge(subprocess_env),
          *command,
          stdin_data:
        )
        assert status.success?, stderr
        return JSON.parse(stdout)
      end
    end

    stdout, stderr, status = Open3.capture3(*command, stdin_data:)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def evaluate(reviewed_heads_mode: "shadow", policy_yaml: nil, subprocess_env: {},
               gh_invalid_utf8_field: nil, invalid_utf8_semantic_field: nil,
               invalid_utf8_semantic_syntax: false, &evaluation_builder)
    Dir.mktmpdir("autonomous-merge-eligibility-test", SAFE_TMP_PARENT) do |root|
      calibration_path = write_calibration(root, reviewed_heads_mode:)
      base_sha = initialize_trusted_base(root, policy_yaml:, include_runtime: true)
      evaluation = if evaluation_builder.arity == 2
                     evaluation_builder.call(base_sha, root)
                   else
                     evaluation_builder.call(base_sha)
                   end
      invoke(root:, calibration_path:, evaluation:, subprocess_env:, gh_invalid_utf8_field:,
             invalid_utf8_semantic_field:, invalid_utf8_semantic_syntax:)
    end
  end

  def write_calibration(root, reviewed_heads_mode: "shadow", max: 3)
    calibration_path = File.join(
      root,
      "skills/pr-batch/fixtures/autonomous-merge-reviewed-heads-calibration.json"
    )
    FileUtils.mkdir_p(File.dirname(calibration_path))
    File.write(
      calibration_path,
      JSON.generate(
        "contract" => "autonomous-merge-calibration-decision",
        "version" => 1,
        "reviewed_heads" => {
          "disposition" => reviewed_heads_mode,
          "max" => max,
          "evidence" => "test fixture"
        }
      )
    )
    calibration_path
  end

  def installed_pack_provenance(calibration_path)
    digest = AutonomousMergeRuntimeTrust.installed_pack_digest(
      AutonomousMergeRuntimeTrust.runtime_sources(calibration_path)
    )
    "verified-installed-pack:#{digest}"
  end

  def initialize_trusted_base(root, policy_yaml:, include_runtime: false)
    system("git", "init", "--quiet", root, exception: true)
    system("git", "-C", root, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", root, "config", "user.name", "Test", exception: true)
    File.write(File.join(root, "README.md"), "trusted base\n")
    copy_trusted_runtime_sources(root) if include_runtime
    if policy_yaml
      agents_dir = File.join(root, ".agents")
      Dir.mkdir(agents_dir)
      File.write(File.join(agents_dir, "agent-workflow.yml"), policy_yaml)
    end
    system("git", "-C", root, "add", ".", exception: true)
    system(
      { "GIT_AUTHOR_DATE" => "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2000-01-01T00:00:00Z" },
      "git", "-C", root, "commit", "--quiet", "-m", "base",
      exception: true
    )
    actual_base, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    assert status.success?
    actual_base = actual_base.strip
    system("git", "-C", root, "update-ref", "refs/heads/trusted-base", actual_base, exception: true)
    actual_base
  end

  def copy_trusted_runtime_sources(root)
    AutonomousMergeRuntimeTrust::RUNTIME_SOURCES.each_value do |source|
      destination = File.join(root, source.fetch(:tree_paths).first)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source.fetch(:path), destination)
    end
  end

  def write_fake_gh(path)
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      objective = JSON.parse(File.read(ENV.fetch("AUTONOMOUS_MERGE_TEST_OBJECTIVE")))
      if ARGV.include?("graphql")
        response = {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "headRefOid" => objective.fetch("head_sha").downcase,
                "baseRefName" => objective.fetch("base_ref"),
                "potentialMergeCommit" => {
                  "oid" => objective.fetch("test_candidate_oid"),
                  "tree" => { "oid" => objective.fetch("test_candidate_tree") },
                  "parents" => {
                    "totalCount" => 2,
                    "nodes" => [
                      { "oid" => objective.fetch("test_current_base_sha") },
                      { "oid" => objective.fetch("head_sha").downcase }
                    ]
                  }
                }
              },
              "ref" => { "target" => { "oid" => objective.fetch("test_current_base_sha") } }
            }
          }
        }
        puts JSON.generate(response)
        exit
      end

      request = ARGV.fetch(-1)
      response = case request
                 when "repos/example/repo/pulls/1"
                   {
                     "head" => { "sha" => objective.fetch("head_sha") },
                     "base" => {
                       "sha" => objective.fetch("base_sha"),
                       "ref" => objective.fetch("base_ref")
                     },
                     "updated_at" => "2026-07-25T12:00:00Z",
                     "changed_files" => objective.fetch("github_changed_files", objective.fetch("files").length),
                     "commits" => objective.fetch("github_commits", objective.fetch("commits").length)
                   }
                 when "repos/example/repo/issues/1/timeline?per_page=100&page=1"
                   []
                 when "repos/example/repo/pulls/1/files?per_page=100&page=1"
                   objective.fetch("files").map do |file|
                     raw_file = {
                       "filename" => file.fetch("path"),
                       "status" => file.fetch("status", "modified"),
                       "additions" => file.fetch("additions"),
                       "deletions" => file.fetch("deletions")
                     }
                     raw_file["previous_filename"] = file.fetch("previous_path") if file.key?("previous_path")
                     raw_file
                   end
                 when "repos/example/repo/pulls/1/commits?per_page=100&page=1"
                   objective.fetch("commits")
                 when "repos/example/repo/pulls/1/reviews?per_page=100&page=1"
                   objective.fetch("reviews")
                 when "repos/example/repo/issues/1/comments?per_page=100&page=1"
                   objective.fetch("decision_comments").map do |comment|
                     author = comment.fetch("author")
                     {
                       "id" => comment.fetch("id"),
                       "html_url" => comment.fetch("url"),
                       "created_at" => comment.fetch("created_at"),
                       "body" => comment.fetch("body"),
                       "user" => author == "__deleted__" ? nil : { "login" => author }
                     }
                   end
                 else
                   warn "unexpected GitHub API path: #{request}"
                   exit 1
                 end
      payload = JSON.generate(response)
      invalid_field = ENV["AUTONOMOUS_MERGE_TEST_INVALID_UTF8_FIELD"]
      if invalid_field == "filename" && request == "repos/example/repo/pulls/1/files?per_page=100&page=1"
        payload = payload.b.sub("lib/file_00.rb".b, "\xFF".b)
      elsif invalid_field == "comment_url" &&
            request == "repos/example/repo/issues/1/comments?per_page=100&page=1"
        payload = payload.b.sub(
          "https://github.com/example/repo/pull/1#issuecomment-1".b,
          "\xFF".b
        )
      end
      $stdout.write(payload)
      $stdout.write("\n")
    RUBY
    File.chmod(0o755, path)
  end

  def write_failed_policy_blob_lookup_patch(path)
    File.write(path, <<~'RUBY')
      require "open3"

      original_capture2 = Open3.method(:capture2)
      failed_status = Object.new
      failed_status.define_singleton_method(:success?) { false }
      Open3.define_singleton_method(:capture2) do |*command, **options|
        if File.basename(command.first) == "git" && command.include?("rev-parse") &&
           command.last.match?(%r{:\.agents/agent-workflow\.yml\z})
          ["", failed_status]
        else
          original_capture2.call(*command, **options)
        end
      end
    RUBY
  end

  def evidence_override(files: files(1), commits: [{ "sha" => "c" * 40 }])
    { files:, commits: }
  end

  def stale_evaluation(root:, recorded_base:, head_path:, base_delta_path:)
    git!(root, "switch", "--quiet", "--detach", recorded_base)
    git!(root, "switch", "--quiet", "-c", "feature")
    FileUtils.mkdir_p(File.join(root, File.dirname(head_path)))
    File.write(File.join(root, head_path), "feature\n")
    git!(root, "add", head_path)
    git!(root, "commit", "--quiet", "-m", "feature")
    head_sha = git!(root, "rev-parse", "HEAD").strip

    git!(root, "switch", "--quiet", "--detach", recorded_base)
    FileUtils.mkdir_p(File.join(root, File.dirname(base_delta_path)))
    File.write(File.join(root, base_delta_path), "base delta\n")
    git!(root, "add", base_delta_path)
    git!(root, "commit", "--quiet", "-m", "advance base")
    current_base = git!(root, "rev-parse", "HEAD").strip
    git!(root, "update-ref", "refs/heads/trusted-base", current_base)
    candidate_tree = git!(root, "merge-tree", "--write-tree", current_base, head_sha).lines.first.strip

    evidence(base_sha: recorded_base, files: [file(head_path)]).tap do |input|
      objective = input.fetch("objective")
      objective["head_sha"] = head_sha
      objective["test_current_base_sha"] = current_base
      objective["test_candidate_oid"] = "d" * 40
      objective["test_candidate_tree"] = candidate_tree
    end
  end

  def copied_stale_evaluation(root:, recorded_base:, source_path:, destination_path:, base_delta_path:)
    git!(root, "switch", "--quiet", "--detach", recorded_base)
    FileUtils.mkdir_p(File.join(root, File.dirname(source_path)))
    File.write(File.join(root, source_path), "source\n")
    git!(root, "add", source_path)
    git!(root, "commit", "--quiet", "-m", "add copy source")
    recorded_with_source = git!(root, "rev-parse", "HEAD").strip

    git!(root, "switch", "--quiet", "-c", "feature-copy")
    FileUtils.mkdir_p(File.join(root, File.dirname(destination_path)))
    FileUtils.cp(File.join(root, source_path), File.join(root, destination_path))
    git!(root, "add", destination_path)
    git!(root, "commit", "--quiet", "-m", "copy source")
    head_sha = git!(root, "rev-parse", "HEAD").strip

    git!(root, "switch", "--quiet", "--detach", recorded_with_source)
    FileUtils.mkdir_p(File.join(root, File.dirname(base_delta_path)))
    File.write(File.join(root, base_delta_path), "base delta\n")
    git!(root, "add", base_delta_path)
    git!(root, "commit", "--quiet", "-m", "advance base")
    current_base = git!(root, "rev-parse", "HEAD").strip
    git!(root, "update-ref", "refs/heads/trusted-base", current_base)
    candidate_tree = git!(root, "merge-tree", "--write-tree", current_base, head_sha).lines.first.strip

    evidence(
      base_sha: recorded_with_source,
      files: [file(destination_path, status: "copied", previous_path: source_path)]
    ).tap do |input|
      objective = input.fetch("objective")
      objective["head_sha"] = head_sha
      objective["test_current_base_sha"] = current_base
      objective["test_candidate_oid"] = "d" * 40
      objective["test_candidate_tree"] = candidate_tree
    end
  end

  def git!(root, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
    raise stderr unless status.success?

    stdout
  end

  def evidence(base_sha:, files:, commits: [{ "sha" => "c" * 40 }], reviews: [],
               semantic: semantic_assessment, decision_comments: [])
    {
      "contract" => "autonomous-merge-evaluation",
      "version" => 1,
      "objective" => {
        "head_sha" => HEAD_SHA,
        "base_sha" => base_sha,
        "base_ref" => "main",
        "test_current_base_sha" => base_sha,
        "test_candidate_oid" => "d" * 40,
        "test_candidate_tree" => "e" * 40,
        "files_complete" => true,
        "files" => files,
        "commits_complete" => true,
        "commits" => commits,
        "reviews_complete" => true,
        "reviews" => reviews,
        "decision_comments_complete" => true,
        "decision_comments" => decision_comments
      },
      "semantic_assessment" => semantic
    }
  end

  def semantic_assessment
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

  def files(count)
    Array.new(count) do |index|
      {
        "path" => format("lib/file_%02d.rb", index),
        "additions" => 1,
        "deletions" => 0
      }
    end
  end

  def file(path, additions: 1, deletions: 0, status: nil, previous_path: nil)
    result = { "path" => path, "additions" => additions, "deletions" => deletions }
    result["status"] = status if status
    result["previous_path"] = previous_path if previous_path
    result
  end

  def review(state, commit_id)
    { "state" => state, "commit_id" => commit_id }
  end

  def decision_comment(id:, url:, body:, created_at: "2026-07-20T00:00:00Z")
    {
      "id" => id,
      "url" => url,
      "created_at" => created_at,
      "body" => body,
      "author" => "maintainer"
    }
  end

  def decision_provenance(comment_id)
    {
      "comment_id" => comment_id,
      "source" => "direct-user-task",
      "human_provenance_verified" => true,
      "merge_authority_verified" => true
    }
  end

  def decision_body(head_sha:, gates:, evidence:)
    <<~YAML.chomp
      <!-- autonomous-merge-risk-decision:v1 -->
      ---
      head_sha: #{head_sha}
      triggered_gates:
      #{gates.map { |gate| "  - #{gate}" }.join("\n")}
      rollback_disposition: Code rollback and forward recovery were reviewed.
      decision: approve
      approved_by: maintainer
      source: direct-user-task
      evidence: #{evidence}
      ...
    YAML
  end

  # A fake git that stalls on every invocation and forks one TERM-ignoring
  # descendant into the spawned process group.
  def write_stalling_git(root)
    ready_file = File.join(root, "git-descendant-ready")
    pid_file = File.join(root, "git-descendant.pid")
    git_pid_file = File.join(root, "git-self.pid")
    stalling_git = File.join(root, "git")
    File.write(stalling_git, <<~RUBY)
      #!#{RbConfig.ruby}
      # frozen_string_literal: true
      READY_FILE = #{ready_file.inspect}
      File.write(#{git_pid_file.inspect}, Process.pid.to_s)
      descendant = fork do
        trap("TERM", "IGNORE")
        File.write(READY_FILE, "ready")
        sleep 300
      end
      File.write(#{pid_file.inspect}, descendant.to_s)
      trap("TERM", "IGNORE")
      sleep(0.01) until File.exist?(READY_FILE)
      sleep 300
    RUBY
    File.chmod(0o755, stalling_git)
    [pid_file, stalling_git, ready_file, git_pid_file]
  end

  def terminate_fixture_process(pid)
    return if pid.nil?

    Process.kill("KILL", pid)
  rescue SystemCallError
    nil
  end

  def trusted_base_sources(root)
    runtime_path = File.join(root, "runtime-source")
    File.write(runtime_path, "runtime bytes\n")
    {
      "helper" => {
        path: runtime_path,
        tree_paths: ["skills/pr-batch/bin/autonomous-merge-eligibility"]
      }
    }
  end

  # A fake git that records the process group it landed in and exits cleanly.
  def write_pgid_recording_git(root)
    pgid_file = File.join(root, "git-pgid")
    recording_git = File.join(root, "git")
    File.write(recording_git, <<~RUBY)
      #!#{RbConfig.ruby}
      # frozen_string_literal: true
      File.write(#{pgid_file.inspect}, Process.getpgid(0).to_s)
    RUBY
    File.chmod(0o755, recording_git)
    [pgid_file, recording_git]
  end

  def read_recorded_pid(pid_file)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until File.exist?(pid_file) && !File.read(pid_file).strip.empty?
      raise "the fake git never recorded its descendant" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
    Integer(File.read(pid_file).strip)
  end

  def alive_after_wait?(pid, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return false unless process_alive?(pid)
      return true if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
