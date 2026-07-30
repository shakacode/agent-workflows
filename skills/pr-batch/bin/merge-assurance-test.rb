#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"

SCRIPT = File.expand_path("merge-assurance", __dir__)
load SCRIPT

class MergeAssuranceTest < Minitest::Test
  HEAD_SHA = "a" * 40
  BASE_SHA = "b" * 40
  DIFF_IDENTITY = "c" * 64
  NOW = Time.iso8601("2026-07-30T12:00:00Z")

  def test_auto_mode_emits_integrity_bound_eligible_receipt
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal true, result.fetch("eligible")
    assert_equal "merge-assurance-receipt", result.fetch("contract")
    assert_equal 1, result.fetch("version")
    assert_equal "2026-07-30T12:00:00Z", result.fetch("issued_at")
    assert_equal(
      {
        "host" => "github.com",
        "repo" => "owner/repo",
        "pr" => 42,
        "base" => { "ref" => "main", "sha" => BASE_SHA },
        "head_sha" => HEAD_SHA,
        "authority" => "auto_merge_when_gates_pass",
        "diff_identity" => DIFF_IDENTITY
      },
      result.fetch("bindings")
    )
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.fetch("evidence_digest"))
    assert MergeAssurance.valid_evidence_digest?(result)
  end

  def test_literal_or_nested_unknown_in_consumed_evidence_blocks
    auto = autonomous_result("autonomous-merge-eligible")
    auto["helper_trust"]["manifest"]["note"] = "nested UNKNOWN evidence"

    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: auto,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
    assert_equal "BLOCKED", result.fetch("verdict")
    assert_includes result.fetch("failures"), "autonomous_result contains UNKNOWN"
    refute result.key?("evidence_digest")
  end

  def test_ask_requires_exact_head_human_decision_and_same_diff_walkthrough
    missing = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("ask"),
      now: NOW
    )
    eligible = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context(
        "ask",
        human_merge_decision: human_merge_decision,
        walkthrough: walkthrough("completed", "pr-walkthrough")
      ),
      now: NOW
    )

    assert_equal false, missing.fetch("eligible")
    assert_includes missing.fetch("failures"), "ask authority requires a proven exact-current-head human merge decision"
    assert_includes missing.fetch("failures"), "ask authority requires a same-diff walkthrough or explicit user skip"
    assert_equal true, eligible.fetch("eligible")
  end

  def test_ordinary_follow_up_requires_human_approval_and_second_bundle_requires_additional_approval
    unapproved = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [ordinary_follow_up("bundle-1", approval_scope: nil)]
      ),
      now: NOW
    )
    missing_additional = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [
          ordinary_follow_up("bundle-1", approval_scope: "first-bundle"),
          ordinary_follow_up("bundle-2", approval_scope: "first-bundle")
        ]
      ),
      now: NOW
    )
    approved = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [
          ordinary_follow_up("bundle-1", approval_scope: "first-bundle"),
          ordinary_follow_up("bundle-2", approval_scope: "additional-bundle")
        ]
      ),
      now: NOW
    )

    assert_includes unapproved.fetch("failures"), "ordinary follow-up bundle bundle-1 lacks explicit human approval"
    assert_includes missing_additional.fetch("failures"), "ordinary follow-up bundle bundle-2 lacks additional explicit approval"
    assert_equal true, approved.fetch("eligible")
    assert_equal(
      %w[bundle-1 bundle-2],
      approved.dig("follow_up_accounting", "ordinary_follow_up_bundles").map { |bundle| bundle.fetch("bundle_id") }
    )
  end

  def test_semantic_github_actions_change_requires_exactly_one_complete_mandatory_tracker
    missing = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true
      ),
      now: NOW
    )
    duplicate = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker, semantic_tracker.merge("tracker" => "https://github.com/owner/repo/issues/2")]
      ),
      now: NOW
    )
    eligible = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_includes missing.fetch("failures"), "semantic GitHub Actions change requires exactly one exercise tracker"
    assert_includes duplicate.fetch("failures"), "semantic GitHub Actions change requires exactly one exercise tracker"
    assert_equal true, eligible.fetch("eligible")
    assert_equal(
      semantic_tracker,
      eligible.dig("follow_up_accounting", "semantic_github_actions_tracker")
    )
  end

  def test_post_merge_audit_defaults_to_accounted_and_report_only_is_a_typed_operation
    default_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    report_only_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [{
          "type" => "post-merge-audit-report-only",
          "disposition" => "report-only",
          "reason" => "The user explicitly requested a report without issue creation.",
          "provenance" => "direct-user"
        }]
      ),
      now: NOW
    )

    assert_equal "accounted", default_result.dig("follow_up_accounting", "post_merge_audit", "disposition")
    assert_equal(
      {
        "disposition" => "report-only",
        "reason" => "The user explicitly requested a report without issue creation.",
        "provenance" => "direct-user"
      },
      report_only_result.dig("follow_up_accounting", "post_merge_audit")
    )
  end

  def test_explicit_approval_requires_only_current_head_human_decision_and_none_never_qualifies
    explicit = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )
    none = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("none"),
      now: NOW
    )

    assert_equal true, explicit.fetch("eligible")
    assert_nil explicit.dig("evidence", "context", "walkthrough")
    assert_equal false, none.fetch("eligible")
    assert_includes none.fetch("failures"), "merge authority none can never produce an eligible receipt"
  end

  def test_human_authority_modes_require_a_known_current_autonomous_helper_result_without_applying_auto_policy
    malformed = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("unexpected-verdict"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )
    known_human_gate = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )

    assert_equal false, malformed.fetch("eligible")
    assert_includes malformed.fetch("failures"), "autonomous_result verdict is unrecognized"
    assert_equal true, known_human_gate.fetch("eligible")
  end

  private

  def ready_ci
    rows = {
      "required_status_check_rollup" => [
        { "name" => "required", "bucket" => "pass" }
      ],
      "github_actions" => [
        { "name" => "CI", "status" => "completed", "conclusion" => "success" }
      ],
      "dependabot" => [],
      "other" => []
    }
    scopes = rows.to_h do |name, scope_rows|
      [
        name,
        {
          "state" => scope_rows.empty? ? "NOT_APPLICABLE" : "READY",
          "source" => "github.test.#{name}",
          "complete" => true,
          "head_sha" => HEAD_SHA,
          "rows" => scope_rows,
          "checked_at" => "2026-07-30T11:59:00Z"
        }
      ]
    end
    {
      "contract" => "pr-ci-readiness",
      "version" => 2,
      "repo" => "owner/repo",
      "pr" => 42,
      "head_sha" => HEAD_SHA,
      "checked_at" => "2026-07-30T11:59:00Z",
      "verdict" => "READY",
      "ordinary_verdict" => "READY",
      "scopes" => scopes
    }
  end

  def autonomous_result(verdict)
    {
      "verdict" => verdict,
      "head_sha" => HEAD_SHA,
      "policy_provenance" => "git:#{BASE_SHA}",
      "helper_provenance" => "trusted-base:#{BASE_SHA}",
      "helper_trust" => {
        "status" => "mechanically-verified",
        "manifest" => { "digest" => "sha256:#{'d' * 64}" }
      },
      "metrics" => { "changed_files" => 1, "changed_lines" => 2, "commits" => 1, "reviewed_heads" => 0 },
      "path_matches" => [],
      "safe_class" => "tests",
      "triggered_gates" => [],
      "shadow_triggered_gates" => [],
      "shadow_evidence_unknown" => [],
      "rollback_assessment" => "code-only-rollback-established",
      "human_decision_evidence" => { "status" => "none" },
      "evidence_failures" => []
    }
  end

  def context(
    authority, operations: [], human_merge_decision: nil, walkthrough: nil,
    semantic_github_actions_change: false
  )
    {
      "contract" => "merge-assurance-context",
      "version" => 1,
      "host" => "github.com",
      "repo" => "owner/repo",
      "pr" => 42,
      "base" => { "ref" => "main", "sha" => BASE_SHA },
      "head_sha" => HEAD_SHA,
      "authority" => authority,
      "diff_identity" => DIFF_IDENTITY,
      "human_merge_decision" => human_merge_decision,
      "walkthrough" => walkthrough,
      "semantic_github_actions_change" => semantic_github_actions_change,
      "operations" => operations
    }
  end

  def human_merge_decision
    {
      "contract" => "human-merge-decision",
      "version" => 1,
      "decision" => "approved",
      "head_sha" => HEAD_SHA,
      "diff_identity" => DIFF_IDENTITY,
      "provenance" => "direct-user",
      "merge_authority" => true,
      "decided_at" => "2026-07-30T11:59:30Z"
    }
  end

  def walkthrough(disposition, provenance)
    {
      "contract" => "pr-walkthrough",
      "version" => 1,
      "disposition" => disposition,
      "head_sha" => HEAD_SHA,
      "diff_identity" => DIFF_IDENTITY,
      "provenance" => provenance
    }
  end

  def ordinary_follow_up(bundle_id, approval_scope:)
    approval = if approval_scope
                 {
                   "contract" => "follow-up-approval",
                   "version" => 1,
                   "decision" => "approved",
                   "provenance" => "direct-user",
                   "scope" => approval_scope,
                   "approved_at" => "2026-07-30T11:59:30Z"
                 }
               end
    {
      "type" => "ordinary-follow-up-bundle",
      "bundle_id" => bundle_id,
      "items" => ["deferred cleanup"],
      "approval" => approval
    }
  end

  def semantic_tracker
    {
      "type" => "semantic-github-actions-tracker",
      "tracker" => "https://github.com/owner/repo/issues/1",
      "source_pr" => "https://github.com/owner/repo/pull/42",
      "changed_files" => [".github/workflows/ci.yml"],
      "exercise" => "Open a secondary verification PR after merge.",
      "expected_evidence" => "The dynamic matrix checks appear on the verification PR.",
      "cleanup_instructions" => "Close the verification-only PR without merging.",
      "owner" => "maintainer"
    }
  end
end
