#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"

SCRIPT = File.expand_path("merge-assurance", __dir__)
load SCRIPT

class MergeAssuranceTest < Minitest::Test
  HEAD_SHA = "a" * 40
  BASE_SHA = "b" * 40
  DIFF_IDENTITY = "c" * 64
  NOW = Time.iso8601("2026-07-30T12:00:00Z")

  def setup
    @fake_gh_dir = Dir.mktmpdir("merge-assurance-gh")
    @fake_gh_calls = File.join(@fake_gh_dir, "calls")
    @original_path = ENV.fetch("PATH")
    ENV["PATH"] = @fake_gh_dir
    ENV["FAKE_GH_CALLS"] = @fake_gh_calls
    ENV["FAKE_GH_EXIT_STATUS"] = "0"
    ENV["FAKE_GH_RESPONSE"] = JSON.generate(fake_issue)
    @fake_gh = File.join(@fake_gh_dir, "gh")
    File.write(@fake_gh, <<~RUBY)
      #!#{RbConfig.ruby}
      File.open(ENV.fetch("FAKE_GH_CALLS"), "a") { |file| file.puts(ARGV.join("\t")) }
      if ENV["FAKE_GH_HANG"] == "1"
        child_pid = fork do
          trap("TERM", "IGNORE")
          File.write(ENV.fetch("FAKE_GH_CHILD_PID"), Process.pid.to_s)
          sleep 2
        end
        trap("TERM", "IGNORE")
        sleep 2
        Process.wait(child_pid)
      end
      STDOUT.write(ENV.fetch("FAKE_GH_RESPONSE"))
      exit Integer(ENV.fetch("FAKE_GH_EXIT_STATUS"))
    RUBY
    File.chmod(0o755, @fake_gh)
  end

  def teardown
    ENV["PATH"] = @original_path
    ENV.delete("FAKE_GH_CALLS")
    ENV.delete("FAKE_GH_EXIT_STATUS")
    ENV.delete("FAKE_GH_RESPONSE")
    ENV.delete("FAKE_GH_HANG")
    ENV.delete("FAKE_GH_CHILD_PID")
    ENV.delete("MERGE_ASSURANCE_GH_TIMEOUT_SECONDS")
    FileUtils.remove_entry(@fake_gh_dir)
  end

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

  def test_ci_evidence_host_must_match_merge_context
    ci_result = ready_ci
    ci_result["context"]["host"] = "github.example"
    result = MergeAssurance.assess(
      ci_result:,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
    assert_includes result.fetch("failures"), "ci_result host binding mismatch"
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

  def test_autonomous_provenance_must_bind_to_the_exact_base
    mutations = {
      "policy-base" => ["policy_provenance", "git:#{'d' * 40}"],
      "policy-suffix" => ["policy_provenance", "git:#{BASE_SHA}:unverified-policy"],
      "helper-base" => ["helper_provenance", "trusted-base:#{'d' * 40}"],
      "helper-kind" => ["helper_provenance", "caller-asserted:#{BASE_SHA}"]
    }
    eligible_mutations = mutations.filter_map do |name, (field, value)|
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous[field] = value
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      name if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_provenance_accepts_only_documented_bound_forms
    accepted = [
      {
        "policy_provenance" =>
          "git:#{BASE_SHA}:.agents/agent-workflow.yml@#{'d' * 40}"
      },
      {
        "policy_provenance" =>
          "git:#{BASE_SHA}:.agents/agent-workflow.yml(absent; portable-defaults)"
      },
      {
        "helper_provenance" => "verified-installed-pack:#{'d' * 64}"
      }
    ]
    verdicts = accepted.map do |fields|
      autonomous = autonomous_result("autonomous-merge-eligible").merge(fields)
      MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      ).fetch("eligible")
    end

    assert_equal [true, true, true], verdicts
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

  def test_human_decision_and_walkthrough_require_exact_target_bindings
    binding_keys = %w[host repo pr base_ref]
    unbound_decision = human_merge_decision.reject { |key, _value| binding_keys.include?(key) }
    unbound_walkthrough = walkthrough("completed", "pr-walkthrough").reject do |key, _value|
      binding_keys.include?(key)
    end
    decision_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: unbound_decision),
      now: NOW
    )
    walkthrough_result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context(
        "ask",
        human_merge_decision: human_merge_decision,
        walkthrough: unbound_walkthrough
      ),
      now: NOW
    )

    assert_equal [false, false], [
      decision_result.fetch("eligible"),
      walkthrough_result.fetch("eligible")
    ]
  end

  def test_human_receipt_target_bindings_fail_closed_on_every_invalid_shape
    mutations = {
      "missing-host" => ->(receipt) { receipt.delete("host") },
      "unknown-repo" => ->(receipt) { receipt["repo"] = "UNKNOWN" },
      "malformed-pr" => ->(receipt) { receipt["pr"] = "42" },
      "duplicate-host" => ->(receipt) { receipt["host_copy"] = receipt["host"] },
      "conflicting-host" => ->(receipt) { receipt["host"] = "github.example" },
      "conflicting-repo" => ->(receipt) { receipt["repo"] = "other/repo" },
      "conflicting-pr" => ->(receipt) { receipt["pr"] = 43 },
      "conflicting-base-ref" => ->(receipt) { receipt["base_ref"] = "release" }
    }
    eligible_mutations = mutations.keys.flat_map do |name|
      decision = human_merge_decision
      mutations.fetch(name).call(decision)
      walkthrough_receipt = walkthrough("completed", "pr-walkthrough")
      mutations.fetch(name).call(walkthrough_receipt)
      decision_result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("human-approval-required"),
        context: context("explicit_approval", human_merge_decision: decision),
        now: NOW
      )
      walkthrough_result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("human-approval-required"),
        context: context(
          "ask",
          human_merge_decision: human_merge_decision,
          walkthrough: walkthrough_receipt
        ),
        now: NOW
      )
      [
        decision_result.fetch("eligible") ? "#{name}-decision" : nil,
        walkthrough_result.fetch("eligible") ? "#{name}-walkthrough" : nil
      ].compact
    end

    assert_empty eligible_mutations
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

  def test_follow_up_approval_rejects_items_changed_after_approval
    bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    bundle["items"] << "scope added after approval"
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass", operations: [bundle]),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_follow_up_approval_rejects_cross_bundle_and_context_reuse
    mutations = {
      "bundle_id" => "bundle-other",
      "host" => "github.example",
      "repo" => "other/repo",
      "pr" => 43,
      "head_sha" => "d" * 40,
      "diff_identity" => "e" * 64
    }
    eligible_reuses = mutations.filter_map do |field, value|
      bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
      bundle.fetch("approval")[field] = value
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass", operations: [bundle]),
        now: NOW
      )
      field if result.fetch("eligible")
    end

    assert_empty eligible_reuses
  end

  def test_follow_up_approval_identity_is_unique_across_bundles
    first = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    additional = ordinary_follow_up("bundle-2", approval_scope: "additional-bundle")
    additional.fetch("approval")["approval_id"] = first.dig("approval", "approval_id")
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [first, additional]
      ),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_one_additional_approval_cannot_authorize_multiple_bundles
    first = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    second = ordinary_follow_up("bundle-2", approval_scope: "additional-bundle")
    third = ordinary_follow_up("bundle-3", approval_scope: "additional-bundle")
    third["approval"] = second["approval"]
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [first, second, third]
      ),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_follow_up_approval_preserves_human_provenance_and_timestamp_validation
    mutations = {
      "provenance" => "automation",
      "approved_at" => "not-a-timestamp"
    }
    eligible_mutations = mutations.filter_map do |field, value|
      bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
      bundle.fetch("approval")[field] = value
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass", operations: [bundle]),
        now: NOW
      )
      field if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_human_decision_and_follow_up_approval_reject_excessive_future_skew
    verdicts = [30, 30.001].map do |future_seconds|
      timestamp = (NOW + future_seconds).iso8601(3)
      decision = human_merge_decision.merge("decided_at" => timestamp)
      bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
      bundle.fetch("approval")["approved_at"] = timestamp
      [
        MergeAssurance.assess(
          ci_result: ready_ci,
          autonomous_result: autonomous_result("human-approval-required"),
          context: context("explicit_approval", human_merge_decision: decision),
          now: NOW
        ).fetch("eligible"),
        MergeAssurance.assess(
          ci_result: ready_ci,
          autonomous_result: autonomous_result("autonomous-merge-eligible"),
          context: context("auto_merge_when_gates_pass", operations: [bundle]),
          now: NOW
        ).fetch("eligible")
      ]
    end

    assert_equal [[true, true], [false, false]], verdicts
  end

  def test_follow_up_approval_bindings_are_covered_by_receipt_evidence_digest
    bundle = ordinary_follow_up("bundle-1", approval_scope: "first-bundle")
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass", operations: [bundle]),
      now: NOW
    )

    assert_equal true, result.fetch("eligible")
    assert_equal(
      bundle.fetch("approval"),
      result.dig("evidence", "context", "operations", 0, "approval")
    )
    tampered = JSON.parse(JSON.generate(result))
    tampered.dig("evidence", "context", "operations", 0, "approval")["approval_id"] = "other"
    refute MergeAssurance.valid_evidence_digest?(tampered)
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
    assert_equal(
      %w[api --hostname github.com repos/owner/repo/issues/1],
      fake_gh_argv
    )
    assert_equal(
      "gh-api",
      eligible.dig("evidence", "authenticated_tracker_reads", 0, "provenance")
    )
  end

  def test_authenticated_issue_read_fails_closed_on_auth_failure
    ENV["FAKE_GH_EXIT_STATUS"] = "1"
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [false, 1], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_caller_authored_tracker_verification_is_rejected
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [
          semantic_tracker.merge("read_verification" => tracker_read_verification)
        ]
      ),
      now: NOW
    )

    assert_equal [false, 0], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_semantic_tracker_rejects_reviewer_reproduction_with_unbound_urls
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [
          semantic_tracker.merge(
            "tracker" => "https://example.invalid/issues/1",
            "source_pr" => "https://evil.invalid/pull/999"
          )
        ]
      ),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
  end

  def test_semantic_tracker_uses_authenticated_read_without_caller_authored_provenance
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [true, 1], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_semantic_tracker_authenticated_read_fails_closed_on_unavailable_or_malformed_evidence
    cases = {
      "unavailable" => ["1", "{}"],
      "invalid-json" => ["0", "{"],
      "non-object" => ["0", "[]"],
      "malformed-object" => ["0", "{}"]
    }
    eligible_cases = cases.filter_map do |name, (exit_status, response)|
      reset_fake_gh_calls
      ENV["FAKE_GH_EXIT_STATUS"] = exit_status
      ENV["FAKE_GH_RESPONSE"] = response
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        now: NOW
      )
      name if result.fetch("eligible") || fake_gh_call_count != 1
    end

    assert_empty eligible_cases
  end

  def test_semantic_tracker_authenticated_read_rejects_every_exact_binding_mismatch
    mutations = {
      "tracker-host" => ->(issue) { issue["html_url"] = "https://github.example/owner/repo/issues/1" },
      "tracker-repo" => ->(issue) { issue["html_url"] = "https://github.com/other/repo/issues/1" },
      "tracker-issue" => ->(issue) { issue["number"] = 2 },
      "api-repo" => ->(issue) { issue["url"] = "https://api.github.com/repos/other/repo/issues/1" },
      "pull-request" => ->(issue) { issue["pull_request"] = {} },
      "source-pr" => lambda do |issue|
        issue["body"] = issue["body"].sub("/pull/42", "/pull/43")
      end,
      "head-sha" => lambda do |issue|
        issue["body"] = issue["body"].sub(HEAD_SHA, "d" * 40)
      end,
      "diff-identity" => lambda do |issue|
        issue["body"] = issue["body"].sub(DIFF_IDENTITY, "e" * 64)
      end,
      "operation-digest" => lambda do |issue|
        issue["body"] = issue["body"].sub(
          MergeAssurance.semantic_tracker_operation_digest(semantic_tracker),
          "sha256:#{'f' * 64}"
        )
      end
    }
    eligible_mutations = mutations.filter_map do |name, mutate|
      reset_fake_gh_calls
      issue = fake_issue
      mutate.call(issue)
      ENV["FAKE_GH_RESPONSE"] = JSON.generate(issue)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        now: NOW
      )
      name if result.fetch("eligible") || fake_gh_call_count != 1
    end

    assert_empty eligible_mutations
  end

  def test_semantic_tracker_rejects_duplicate_same_value_for_every_binding_key
    eligible_keys = eligible_semantic_binding_mutations do |_key, expected_line|
      expected_line
    end

    assert_empty eligible_keys
  end

  def test_semantic_tracker_rejects_expected_plus_conflicting_value_for_every_binding_key
    eligible_keys = eligible_semantic_binding_mutations do |key, _expected_line|
      "#{key}: conflicting-value"
    end

    assert_empty eligible_keys
  end

  def test_semantic_tracker_rejects_malformed_prefixed_variants_for_every_binding_key
    eligible_keys = eligible_semantic_binding_mutations do |key, _expected_line|
      "#{key}-conflict: conflicting-value"
    end

    assert_empty eligible_keys
  end

  def test_semantic_tracker_fails_closed_when_gh_is_unavailable
    File.rename(@fake_gh, "#{@fake_gh}.unavailable")
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [false, 0], [result.fetch("eligible"), fake_gh_call_count]
  end

  def test_semantic_tracker_read_timeout_terminates_the_entire_process_group
    child_pid_path = File.join(@fake_gh_dir, "hung-child.pid")
    system(@fake_gh, "--version", out: File::NULL, err: File::NULL)
    reset_fake_gh_calls
    ENV["FAKE_GH_HANG"] = "1"
    ENV["FAKE_GH_CHILD_PID"] = child_pid_path
    ENV["MERGE_ASSURANCE_GH_TIMEOUT_SECONDS"] = "0.5"
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    child_pid = Integer(File.read(child_pid_path))

    assert_equal false, result.fetch("eligible")
    assert_operator elapsed, :<, 1.5
    refute process_alive?(child_pid), "hung gh child #{child_pid} leaked"
  ensure
    begin
      Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
    rescue Errno::ESRCH
      nil
    end
  end

  def test_authenticated_tracker_evidence_is_covered_by_receipt_digest
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )
    tampered = JSON.parse(JSON.generate(result))
    tampered.dig("evidence", "authenticated_tracker_reads", 0)["issue"] = 2

    assert_equal true, result.fetch("eligible")
    refute MergeAssurance.valid_evidence_digest?(tampered)
  end

  def test_merge_authority_none_does_not_read_semantic_tracker
    ENV["FAKE_GH_EXIT_STATUS"] = "1"
    result = MergeAssurance.assess(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "none",
        semantic_github_actions_change: true,
        operations: [semantic_tracker]
      ),
      now: NOW
    )

    assert_equal [false, 0], [result.fetch("eligible"), fake_gh_call_count]
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

  def fake_gh_call_count
    return 0 unless File.exist?(@fake_gh_calls)

    File.foreach(@fake_gh_calls).count
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def fake_gh_argv
    File.read(@fake_gh_calls).strip.split("\t")
  end

  def reset_fake_gh_calls
    File.delete(@fake_gh_calls) if File.exist?(@fake_gh_calls)
  end

  def eligible_semantic_binding_mutations
    semantic_binding_lines.filter_map do |key, expected_line|
      reset_fake_gh_calls
      issue = fake_issue
      issue["body"] = "#{issue['body']}\n#{yield(key, expected_line)}"
      ENV["FAKE_GH_RESPONSE"] = JSON.generate(issue)
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        now: NOW
      )
      key if result.fetch("eligible")
    end
  end

  def semantic_binding_lines
    fake_issue.fetch("body").lines(chomp: true).filter_map do |line|
      next unless line.start_with?("semantic-tracker-")

      [line.split(": ", 2).first, line]
    end
  end

  def fake_issue
    {
      "id" => 101,
      "node_id" => "I_kwDOExample",
      "number" => 1,
      "url" => "https://api.github.com/repos/owner/repo/issues/1",
      "html_url" => "https://github.com/owner/repo/issues/1",
      "state" => "open",
      "title" => "Exercise semantic GitHub Actions behavior",
      "body" => [
        "Verify the semantic workflow behavior after merge.",
        "semantic-tracker-source-pr: https://github.com/owner/repo/pull/42",
        "semantic-tracker-head-sha: #{HEAD_SHA}",
        "semantic-tracker-diff-identity: #{DIFF_IDENTITY}",
        "semantic-tracker-operation-digest: " \
          "#{MergeAssurance.semantic_tracker_operation_digest(semantic_tracker)}"
      ].join("\n"),
      "updated_at" => "2026-07-30T11:59:30Z"
    }
  end

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
      "context" => { "host" => "github.com" },
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
      "host" => "github.com",
      "repo" => "owner/repo",
      "pr" => 42,
      "base_ref" => "main",
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
      "host" => "github.com",
      "repo" => "owner/repo",
      "pr" => 42,
      "base_ref" => "main",
      "head_sha" => HEAD_SHA,
      "diff_identity" => DIFF_IDENTITY,
      "provenance" => provenance
    }
  end

  def ordinary_follow_up(bundle_id, approval_scope:)
    items = ["deferred cleanup"]
    approval = if approval_scope
                 {
                   "contract" => "follow-up-approval",
                   "version" => 1,
                   "approval_id" => "approval-#{bundle_id}",
                   "decision" => "approved",
                   "provenance" => "direct-user",
                   "scope" => approval_scope,
                   "bundle_id" => bundle_id,
                   "items_digest" => MergeAssurance.canonical_items_digest(items),
                   "host" => "github.com",
                   "repo" => "owner/repo",
                   "pr" => 42,
                   "head_sha" => HEAD_SHA,
                   "diff_identity" => DIFF_IDENTITY,
                   "approved_at" => "2026-07-30T11:59:30Z"
                 }
               end
    {
      "type" => "ordinary-follow-up-bundle",
      "bundle_id" => bundle_id,
      "items" => items,
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

  def tracker_read_verification
    {
      "contract" => "semantic-tracker-read-verification",
      "version" => 1,
      "status" => "verified",
      "complete" => true,
      "provenance" => "authenticated-github-api",
      "checked_at" => "2026-07-30T11:59:30Z",
      "tracker" => "https://github.com/owner/repo/issues/1",
      "issue" => 1,
      "host" => "github.com",
      "repo" => "owner/repo",
      "source_pr" => "https://github.com/owner/repo/pull/42",
      "head_sha" => HEAD_SHA,
      "diff_identity" => DIFF_IDENTITY
    }
  end
end
