#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

SCRIPT = File.expand_path("merge-assurance", __dir__)
load SCRIPT

class MergeAssuranceTest < Minitest::Test
  HEAD_SHA = "a" * 40
  BASE_SHA = "b" * 40
  DIFF_IDENTITY = "c" * 64
  NOW = Time.iso8601("2026-07-30T12:00:00Z")
  SAFE_TMP_PARENT = File.expand_path("../../..", __dir__)

  def setup
    @fake_gh_dir = Dir.mktmpdir("merge-assurance-gh", SAFE_TMP_PARENT)
    @fake_gh_calls = File.join(@fake_gh_dir, "calls")
    @fake_gh_environment = File.join(@fake_gh_dir, "environment.json")
    @fake_gh_response = File.join(@fake_gh_dir, "response.json")
    @fake_gh_exit_status = File.join(@fake_gh_dir, "exit-status")
    @fake_gh_hang = File.join(@fake_gh_dir, "hang")
    @fake_gh_child_pid = File.join(@fake_gh_dir, "hung-child.pid")
    @original_path = ENV.fetch("PATH")
    ENV["PATH"] = @fake_gh_dir
    File.write(@fake_gh_exit_status, "0")
    File.write(@fake_gh_response, JSON.generate(fake_issue))
    @fake_gh = File.join(@fake_gh_dir, "gh")
    File.write(@fake_gh, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(#{@fake_gh_calls.inspect}, "a") { |file| file.puts(ARGV.join("\t")) }
      File.write(#{@fake_gh_environment.inspect}, JSON.generate(ENV.to_h))
      if File.exist?(#{@fake_gh_hang.inspect})
        child_pid = fork do
          trap("TERM", "IGNORE")
          File.write(#{@fake_gh_child_pid.inspect}, Process.pid.to_s)
          sleep 2
        end
        trap("TERM", "IGNORE")
        sleep 2
        Process.wait(child_pid)
      end
      STDOUT.write(File.read(#{@fake_gh_response.inspect}))
      exit Integer(File.read(#{@fake_gh_exit_status.inspect}))
    RUBY
    File.chmod(0o755, @fake_gh)
  end

  def teardown
    ENV["PATH"] = @original_path
    ENV.delete("MERGE_ASSURANCE_GH_TIMEOUT_SECONDS")
    FileUtils.remove_entry(@fake_gh_dir)
  end

  def test_auto_mode_emits_integrity_bound_eligible_receipt
    result = assess_with_replay(
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

  def test_autonomous_result_must_exactly_match_recomputed_owning_evaluator_result
    supplied = autonomous_result("autonomous-merge-eligible")
    supplied.fetch("metrics")["changed_files"] = 30
    recomputed = Marshal.load(Marshal.dump(supplied))
    recomputed["verdict"] = "human-approval-required"
    recomputed["triggered_gates"] = ["changed-files-limit"]

    result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: supplied,
      recomputed_autonomous_result: recomputed,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("failures"), "autonomous_result does not match trusted live replay"
  end

  def test_cli_replays_fixed_sibling_and_rejects_a_supplied_result_with_omitted_threshold_gate
    supplied = autonomous_result("autonomous-merge-eligible")
    supplied.fetch("metrics")["changed_files"] = 30
    recomputed = Marshal.load(Marshal.dump(supplied))
    recomputed["verdict"] = "human-approval-required"
    recomputed["triggered_gates"] = ["changed-files-limit"]

    execution = run_replay_cli(supplied:, recomputed:)

    refute execution.fetch(:status).success?
    assert_includes(
      execution.fetch(:result).fetch("failures"),
      "autonomous_result does not match trusted live replay"
    )
    assert_equal(
      [
        "--repo-root", execution.fetch(:repo_root),
        "--trusted-base", BASE_SHA,
        "--trusted-helper-provenance", "trusted-base:#{BASE_SHA}",
        "--repo", "owner/repo",
        "--pr", "42",
        "--semantic-assessment", execution.fetch(:semantic_assessment)
      ],
      execution.fetch(:helper_call).fetch("argv")
    )
    assert execution.fetch(:helper_call).fetch("autonomous_merge_gh_present")
    assert_equal(
      execution.fetch(:trusted_gh_executable),
      execution.dig(:helper_call, "environment", "AUTONOMOUS_MERGE_GH")
    )
  end

  def test_cli_replay_does_not_resolve_the_sibling_interpreter_from_path
    supplied = autonomous_result("autonomous-merge-eligible")
    recomputed = Marshal.load(Marshal.dump(supplied))
    recomputed["verdict"] = "human-approval-required"
    recomputed["triggered_gates"] = ["changed-files-limit"]

    execution = run_replay_cli(
      supplied:,
      recomputed:,
      poisoned_ruby: true
    )

    refute execution.fetch(:status).success?
    assert_includes(
      execution.fetch(:result).fetch("failures"),
      "autonomous_result does not match trusted live replay"
    )
    refute execution.fetch(:poisoned_ruby_ran)
  end

  def test_cli_accepts_coordinator_established_absolute_git_and_gh_executables
    autonomous = autonomous_result("autonomous-merge-eligible")

    execution = run_replay_cli(supplied: autonomous, recomputed: autonomous)

    assert execution.fetch(:status).success?, execution.fetch(:stderr)
    assert_equal(
      execution.fetch(:trusted_git_executable),
      execution.dig(:helper_call, "environment", "AUTONOMOUS_MERGE_GIT")
    )
    assert_equal(
      execution.fetch(:trusted_gh_executable),
      execution.dig(:helper_call, "environment", "AUTONOMOUS_MERGE_GH")
    )
  end

  def test_trusted_executable_validation_supports_a_safe_homebrew_style_symlink
    Dir.mktmpdir("merge-assurance-homebrew", SAFE_TMP_PARENT) do |root|
      cellar = File.join(root, "opt/homebrew/Cellar")
      target_dir = File.join(cellar, "gh/2.96.0/bin")
      link_dir = File.join(root, "opt/homebrew/bin")
      FileUtils.mkdir_p([target_dir, link_dir])
      File.chmod(0o775, cellar)
      target = File.join(target_dir, "gh")
      File.write(target, "#!#{RbConfig.ruby}\nexit 0\n")
      File.chmod(0o755, target)
      link = File.join(link_dir, "gh")
      File.symlink(target, link)

      assert_equal(
        File.realpath(target),
        MergeAssurance.trusted_executable_path(link, "--trusted-gh-executable")
      )
    end
  end

  def test_trusted_executable_validation_rejects_nonabsolute_and_writable_targets_and_ancestors
    failures = {}
    failures[:nonabsolute] = assert_raises(MergeAssurance::Error) do
      MergeAssurance.trusted_executable_path("bin/gh", "--trusted-gh-executable")
    end
    Dir.mktmpdir("merge-assurance-unsafe-executable") do |root|
      writable_target = File.join(root, "writable-gh")
      File.write(writable_target, "#!#{RbConfig.ruby}\nexit 0\n")
      File.chmod(0o777, writable_target)
      failures[:writable_target] = assert_raises(MergeAssurance::Error) do
        MergeAssurance.trusted_executable_path(writable_target, "--trusted-gh-executable")
      end

      unsafe_ancestor = File.join(root, "world-writable")
      FileUtils.mkdir_p(unsafe_ancestor)
      File.chmod(0o777, unsafe_ancestor)
      nested_target = File.join(unsafe_ancestor, "gh")
      File.write(nested_target, "#!#{RbConfig.ruby}\nexit 0\n")
      File.chmod(0o755, nested_target)
      failures[:writable_ancestor] = assert_raises(MergeAssurance::Error) do
        MergeAssurance.trusted_executable_path(nested_target, "--trusted-gh-executable")
      end

      escaping_link = File.join(root, "escaping-gh")
      File.symlink(writable_target, escaping_link)
      failures[:unsafe_symlink_target] = assert_raises(MergeAssurance::Error) do
        MergeAssurance.trusted_executable_path(escaping_link, "--trusted-gh-executable")
      end
    end

    assert_includes failures.fetch(:nonabsolute).message, "must be an absolute path"
    assert_includes failures.fetch(:writable_target).message, "target is group- or world-writable"
    assert_includes failures.fetch(:writable_ancestor).message, "ancestor is world-writable"
    assert_includes failures.fetch(:unsafe_symlink_target).message, "target is group- or world-writable"
  end

  def test_trusted_executable_validation_rejects_foreign_owners_and_unsafe_group_ancestors
    stat_type = Struct.new(:uid, :mode, :kind) do
      def file?
        kind == :file
      end

      def directory?
        kind == :directory
      end
    end
    foreign_target = stat_type.new(Process.euid + 10_000, 0o755, :file)
    error = assert_raises(MergeAssurance::Error) do
      MergeAssurance.validate_trusted_executable_target!(
        foreign_target, "--trusted-gh-executable"
      )
    end
    assert_includes error.message, "target owner is not trusted"

    skip "foreign trusted-owner case requires a non-root effective UID" if Process.euid.zero?
    unsafe_group_ancestor = stat_type.new(0, 0o775, :directory)
    error = assert_raises(MergeAssurance::Error) do
      MergeAssurance.validate_trusted_executable_ancestor!(
        unsafe_group_ancestor, "--trusted-gh-executable"
      )
    end
    assert_includes error.message, "ancestor is group-writable by a foreign owner"
  end

  def test_replay_comparison_covers_every_threshold_gate_family_and_reviewed_head_mode
    cases = {
      "changed-files" => ["changed_files", 30, ["changed-files-limit"], []],
      "changed-lines" => ["changed_lines", 1_000, ["changed-lines-limit"], []],
      "commits" => ["commits", 10, ["commit-count-limit"], []],
      "reviewed-heads-enforced" => ["reviewed_heads", 4, ["reviewed-heads-limit"], []],
      "reviewed-heads-shadow" => ["reviewed_heads", 4, [], ["reviewed-heads-limit"]]
    }

    eligible_mismatches = cases.filter_map do |label, (metric, value, triggered, shadow)|
      supplied = autonomous_result("autonomous-merge-eligible")
      supplied.fetch("metrics")[metric] = value
      recomputed = Marshal.load(Marshal.dump(supplied))
      recomputed["triggered_gates"] = triggered
      recomputed["shadow_triggered_gates"] = shadow
      recomputed["verdict"] = "human-approval-required" unless triggered.empty?
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: supplied,
        recomputed_autonomous_result: recomputed,
        context: context("auto_merge_when_gates_pass")
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_mismatches
  end

  def test_exact_boundary_results_without_threshold_gates_remain_eligible
    exact_boundary = autonomous_result("autonomous-merge-eligible")
    exact_boundary["metrics"] = {
      "changed_files" => 29,
      "changed_lines" => 999,
      "commits" => 9,
      "reviewed_heads" => 3
    }

    result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: exact_boundary,
      context: context("auto_merge_when_gates_pass")
    )

    assert result.fetch("eligible")
  end

  def test_cli_accepts_exact_trusted_base_and_verified_installed_pack_replays
    results = [
      autonomous_result("autonomous-merge-eligible"),
      autonomous_result("autonomous-merge-eligible").merge(
        "helper_provenance" => "verified-installed-pack:#{'d' * 64}"
      )
    ].map do |autonomous|
      run_replay_cli(
        supplied: autonomous,
        recomputed: autonomous,
        provenance: autonomous.fetch("helper_provenance")
      )
    end

    assert(results.all? { |execution| execution.fetch(:status).success? })
    assert(results.all? { |execution| execution.fetch(:result).fetch("eligible") })
  end

  def test_cli_fixed_sibling_replay_is_layout_independent
    statuses = %i[flat symlink native_plugin_cache].to_h do |layout|
      autonomous = autonomous_result("autonomous-merge-eligible")
      execution = run_replay_cli(supplied: autonomous, recomputed: autonomous, layout:)
      [layout, execution.fetch(:status).success?]
    end

    assert_equal(
      { flat: true, symlink: true, native_plugin_cache: true },
      statuses
    )
  end

  def test_cli_replay_fails_closed_for_missing_malformed_unknown_and_mismatched_provenance
    autonomous = autonomous_result("autonomous-merge-eligible")
    failures = {
      missing: "autonomous eligibility sibling is unavailable",
      malformed: "autonomous eligibility replay returned invalid JSON",
      unknown: "autonomous eligibility replay returned UNKNOWN",
      nonzero: "autonomous eligibility replay failed"
    }.to_h do |mode, expected|
      execution = run_replay_cli(supplied: autonomous, recomputed: autonomous, helper_mode: mode)
      [mode, [execution.fetch(:status).success?, execution.fetch(:result).fetch("failures"), expected]]
    end
    mismatched = run_replay_cli(
      supplied: autonomous,
      recomputed: autonomous,
      provenance: "verified-installed-pack:#{'d' * 64}"
    )

    failures.each_value do |success, messages, expected|
      refute success
      assert messages.any? { |message| message.include?(expected) }, messages.inspect
    end
    refute mismatched.fetch(:status).success?
    assert mismatched.fetch(:result).fetch("failures").any? do |message|
      message.include?("helper provenance does not match coordinator expectation")
    end
  end

  def test_cli_replay_rejects_semantic_assessment_inside_repo_and_inherited_tool_overrides
    autonomous = autonomous_result("autonomous-merge-eligible")
    semantic = run_replay_cli(
      supplied: autonomous,
      recomputed: autonomous,
      semantic_inside_repo: true
    )
    overrides = %w[AUTONOMOUS_MERGE_GIT AUTONOMOUS_MERGE_GH].to_h do |key|
      [key, run_replay_cli(
        supplied: autonomous,
        recomputed: autonomous,
        extra_env: { key => "/tmp/forbidden-tool" }
      )]
    end

    refute semantic.fetch(:status).success?
    assert semantic.fetch(:result).fetch("failures").any? do |message|
      message.include?("semantic assessment must be supplied from outside the evaluated repository")
    end
    assert_empty semantic.fetch(:helper_call)
    overrides.each do |key, override|
      refute override.fetch(:status).success?
      assert override.fetch(:result).fetch("failures").any? do |message|
        message.include?("#{key} is forbidden")
      end
      assert_empty override.fetch(:helper_call)
    end
  end

  def test_autonomous_replay_timeout_terminates_the_helper_process_group
    Dir.mktmpdir("merge-assurance-autonomous-timeout") do |root|
      helper = File.join(root, "autonomous-merge-eligibility")
      File.write(helper, <<~RUBY)
        #!#{RbConfig.ruby}
        trap("TERM") { exit 0 }
        sleep 2
      RUBY
      File.chmod(0o755, helper)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _stdout, _stderr, _status, timed_out, cleanup_complete =
        MergeAssurance.run_autonomous_replay(helper, [], timeout_seconds: 0.05)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert timed_out
      assert cleanup_complete
      assert_operator elapsed, :<, 1
    end
  end

  def test_ci_evidence_host_must_match_merge_context
    ci_result = ready_ci
    ci_result["context"]["host"] = "github.example"
    result = assess_with_replay(
      ci_result:,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal false, result.fetch("eligible")
    assert_includes result.fetch("failures"), "ci_result host binding mismatch"
  end

  def test_ci_scope_declared_ready_or_not_applicable_must_match_recomputed_rows
    cases = {
      "failed" => [
        "READY",
        { "name" => "lint", "status" => "completed", "conclusion" => "failure" },
        "NOT_READY"
      ],
      "pending" => [
        "NOT_APPLICABLE",
        { "name" => "lint", "status" => "queued", "conclusion" => nil },
        "NOT_READY"
      ],
      "cancelled" => ["READY", { "name" => "lint", "bucket" => "cancel" }, "NOT_READY"],
      "unknown" => [
        "NOT_APPLICABLE",
        { "name" => "lint", "status" => "completed", "conclusion" => nil },
        "UNKNOWN"
      ],
      "malformed" => ["READY", nil, "UNKNOWN"]
    }

    cases.each do |label, (declared, row, recomputed)|
      ci_result = ready_ci
      scope = ci_result.fetch("scopes").fetch("github_actions")
      scope["state"] = declared
      scope["rows"] = [row]
      result = assess_with_replay(
        ci_result:,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )

      refute result.fetch("eligible"), label
      refute result.key?("evidence_digest"), label
      assert_includes(
        result.fetch("failures"),
        "ci_result scope github_actions declared #{declared} but recomputed #{recomputed}",
        label
      )
    end
  end

  def test_ci_row_representations_must_be_recognized_and_agree
    invalid_rows = {
      "bucket-state-contradiction" => {
        "name" => "lint", "bucket" => "pass", "state" => "failure"
      },
      "bucket-status-contradiction" => {
        "name" => "lint", "bucket" => "pass", "status" => "in_progress"
      },
      "bucket-conclusion-contradiction" => {
        "name" => "lint", "bucket" => "pass",
        "status" => "completed", "conclusion" => "failure"
      },
      "state-status-contradiction" => {
        "name" => "lint", "state" => "success", "status" => "in_progress"
      },
      "state-conclusion-contradiction" => {
        "name" => "lint", "state" => "success",
        "status" => "completed", "conclusion" => "failure"
      },
      "status-conclusion-contradiction" => {
        "name" => "lint", "bucket" => "pass",
        "status" => "in_progress", "conclusion" => "success"
      },
      "unrecognized-bucket" => {
        "name" => "lint", "bucket" => "mystery", "state" => "success"
      },
      "unrecognized-state" => {
        "name" => "lint", "bucket" => "pass", "state" => "mystery"
      },
      "unrecognized-status" => {
        "name" => "lint", "bucket" => "pass", "status" => "mystery"
      },
      "unrecognized-conclusion" => {
        "name" => "lint", "bucket" => "pass",
        "status" => "completed", "conclusion" => "mystery"
      }
    }

    eligible_invalid_rows = invalid_rows.filter_map do |label, row|
      ci_result = ready_ci
      ci_result.fetch("scopes").fetch("github_actions")["rows"] = [row]
      result = assess_with_replay(
        ci_result:,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_rows
  end

  def test_ci_row_official_gh_bucket_state_pairs_are_compatible
    cases = {
      "pass/SUCCESS" => [%w[pass SUCCESS], "READY"],
      "skipping/SKIPPED" => [%w[skipping SKIPPED], "READY"],
      "skipping/NEUTRAL" => [%w[skipping NEUTRAL], "READY"],
      "fail/ERROR" => [%w[fail ERROR], "NOT_READY"],
      "fail/FAILURE" => [%w[fail FAILURE], "NOT_READY"],
      "fail/TIMED_OUT" => [%w[fail TIMED_OUT], "NOT_READY"],
      "fail/ACTION_REQUIRED" => [%w[fail ACTION_REQUIRED], "NOT_READY"],
      "cancel/CANCELLED" => [%w[cancel CANCELLED], "NOT_READY"],
      "pending/EXPECTED" => [%w[pending EXPECTED], "NOT_READY"],
      "pending/REQUESTED" => [%w[pending REQUESTED], "NOT_READY"],
      "pending/WAITING" => [%w[pending WAITING], "NOT_READY"],
      "pending/QUEUED" => [%w[pending QUEUED], "NOT_READY"],
      "pending/PENDING" => [%w[pending PENDING], "NOT_READY"],
      "pending/IN_PROGRESS" => [%w[pending IN_PROGRESS], "NOT_READY"],
      "pending/STALE" => [%w[pending STALE], "NOT_READY"]
    }

    actual_states = cases.to_h do |label, ((bucket, state), _expected)|
      [label, MergeAssurance.ci_evidence_row_state({ "bucket" => bucket, "state" => state })]
    end
    skipping_ci = ready_ci
    skipping_ci.fetch("scopes").fetch("github_actions")["rows"] = [
      { "name" => "lint", "bucket" => "skipping", "state" => "SKIPPED" }
    ]
    skipping_result = assess_with_replay(
      ci_result: skipping_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert_equal(
      {
        "states" => cases.transform_values(&:last),
        "skipping_eligible" => true
      },
      {
        "states" => actual_states,
        "skipping_eligible" => skipping_result.fetch("eligible")
      }
    )
  end

  def test_ci_row_agreeing_producer_shapes_preserve_pass_fail_and_pending_states
    cases = {
      { "bucket" => "pass", "state" => "success" } => "READY",
      { "bucket" => "fail", "state" => "failure" } => "NOT_READY",
      { "bucket" => "pending", "state" => "pending" } => "NOT_READY",
      { "status" => "completed", "conclusion" => "success" } => "READY",
      { "status" => "completed", "conclusion" => "failure" } => "NOT_READY",
      { "status" => "in_progress", "conclusion" => nil } => "NOT_READY"
    }

    states = cases.keys.map { |row| MergeAssurance.ci_evidence_row_state(row) }

    assert_equal cases.values, states
  end

  def test_literal_or_nested_unknown_in_consumed_evidence_blocks
    auto = autonomous_result("autonomous-merge-eligible")
    auto["helper_trust"]["manifest"]["note"] = "nested UNKNOWN evidence"

    result = assess_with_replay(
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
      result = assess_with_replay(
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
      assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      ).fetch("eligible")
    end

    assert_equal [true, true, true], verdicts
  end

  def test_autonomous_helper_trust_requires_the_exact_runtime_manifest
    canonical = autonomous_runtime_manifest
    invalid_manifests = {
      "empty" => {},
      "non-string-value" => canonical.merge("helper" => 123),
      "missing-role" => canonical.reject { |role, _path| role == "decision-library" },
      "extra-role" => canonical.merge("future-library" => "/trusted/future.rb"),
      "blank-path" => canonical.merge("policy-library" => " "),
      "legacy-digest-only" => { "digest" => "sha256:#{'d' * 64}" }
    }

    eligible_invalid_manifests = invalid_manifests.filter_map do |label, manifest|
      autonomous = autonomous_result("autonomous-merge-eligible")
      autonomous["helper_trust"]["manifest"] = manifest
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_manifests
  end

  def test_autonomous_result_requires_exactly_empty_evidence_failures
    autonomous = autonomous_result("autonomous-merge-eligible")
    autonomous["evidence_failures"] = ["live force-push evidence is incomplete"]
    result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    refute result.fetch("eligible")
    refute result.key?("evidence_digest")
    assert_includes result.fetch("failures"), "autonomous_result evidence failures must be empty"
  end

  def test_autonomous_verdict_must_match_gates_and_decision_evidence
    contradictions = [
      {
        "verdict" => "autonomous-merge-eligible",
        "triggered_gates" => ["changed-files-limit"],
        "human_decision_evidence" => { "status" => "none" }
      },
      {
        "verdict" => "human-approved-for-current-head",
        "triggered_gates" => [],
        "human_decision_evidence" => {
          "status" => "accepted",
          "comment_id" => "123",
          "url" => "https://github.com/owner/repo/pull/42#issuecomment-123",
          "approved_by" => "maintainer",
          "source" => "human-pr-comment"
        }
      },
      {
        "verdict" => "human-approved-for-current-head",
        "triggered_gates" => ["changed-files-limit"],
        "human_decision_evidence" => { "status" => "none" }
      }
    ]

    eligible_contradictions = contradictions.filter_map do |fields|
      autonomous = autonomous_result(fields.fetch("verdict")).merge(fields)
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      fields if result.fetch("eligible")
    end

    assert_empty eligible_contradictions
  end

  def test_accepts_each_exact_autonomous_verdict_relation_without_recomputing_thresholds
    autonomous = autonomous_result("autonomous-merge-eligible")
    autonomous["metrics"] = {
      "changed_files" => 10_000,
      "changed_lines" => 1_000_000,
      "commits" => 1_000,
      "reviewed_heads" => 100
    }
    autonomous_result_receipt = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    helper_approved_receipt = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approved-for-current-head"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    external_approval_receipt = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )

    assert_equal [true, true, true], [
      autonomous_result_receipt.fetch("eligible"),
      helper_approved_receipt.fetch("eligible"),
      external_approval_receipt.fetch("eligible")
    ]
  end

  def test_autonomous_result_requires_the_exact_consumed_output_shape
    mutations = {
      "unknown-top-level-field" => ->(result) { result["future_field"] = true },
      "non-string-top-level-field" => ->(result) { result[:future_field] = true },
      "missing-metrics" => ->(result) { result.delete("metrics") },
      "unknown-metric" => ->(result) { result["metrics"]["threshold"] = 10 },
      "unknown-helper-trust-field" => ->(result) { result["helper_trust"]["source"] = "caller" },
      "malformed-path-matches" => ->(result) { result["path_matches"] = {} }
    }

    eligible_mutations = mutations.filter_map do |label, mutation|
      autonomous = autonomous_result("autonomous-merge-eligible")
      mutation.call(autonomous)
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_path_matches_require_an_exact_gate_or_generated_record_shape
    invalid_path_matches = {
      "non-object" => [nil],
      "unknown-field" => [{
        "path" => "skills/example.rb",
        "gate" => "changed-files-limit",
        "reason" => "policy",
        "extra" => true
      }],
      "missing-reason" => [{
        "path" => "skills/example.rb",
        "gate" => "changed-files-limit"
      }],
      "unknown-classification" => [{
        "path" => "generated/example.rb",
        "classification" => "vendored"
      }],
      "blank-path" => [{
        "path" => " ",
        "classification" => "generated"
      }]
    }

    eligible_invalid_matches = invalid_path_matches.filter_map do |label, path_matches|
      autonomous = autonomous_result("human-approval-required")
      autonomous["path_matches"] = path_matches
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("explicit_approval", human_merge_decision: human_merge_decision),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_matches
  end

  def test_gate_bearing_path_match_requires_its_triggered_gate
    autonomous = autonomous_result("autonomous-merge-eligible")
    autonomous["path_matches"] = [{
      "gate" => "repo-path:security",
      "path" => "config/security.yml",
      "reason" => "repository policy matched the security path"
    }]
    result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("failures"),
                    "autonomous_result path match gates are absent from triggered gates"
  end

  def test_generated_path_rows_and_conservative_gates_preserve_one_way_binding
    generated = autonomous_result("autonomous-merge-eligible")
    generated["path_matches"] = [{
      "classification" => "generated",
      "path" => "dist/generated.js"
    }]
    generated_result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: generated,
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    conservative_result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approved-for-current-head"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )

    assert generated_result.fetch("eligible")
    assert conservative_result.fetch("eligible")
  end

  def test_autonomous_triggered_gates_must_be_canonical_unique_and_sorted
    invalid_gates = {
      "unknown" => ["future-gate"],
      "duplicate" => %w[changed-files-limit changed-files-limit],
      "unsorted" => %w[commit-count-limit changed-files-limit],
      "malformed-repo-path" => ["repo-path:bad_id"]
    }

    eligible_invalid_gates = invalid_gates.filter_map do |label, gates|
      autonomous = autonomous_result("human-approval-required")
      autonomous["triggered_gates"] = gates
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("explicit_approval", human_merge_decision: human_merge_decision),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_invalid_gates
  end

  def test_autonomous_shadow_fields_require_the_pinned_helper_shapes
    mutations = {
      "shadow-gates-not-array" => ->(result) { result["shadow_triggered_gates"] = "reviewed-heads-limit" },
      "shadow-gate-unknown" => ->(result) { result["shadow_triggered_gates"] = ["changed-files-limit"] },
      "shadow-gate-duplicate" => lambda do |result|
        result["shadow_triggered_gates"] = %w[reviewed-heads-limit reviewed-heads-limit]
      end,
      "shadow-evidence-unknown" => ->(result) { result["shadow_evidence_unknown"] = ["future-evidence"] },
      "shadow-evidence-duplicate" => lambda do |result|
        result["shadow_evidence_unknown"] = %w[submitted-review-head-missing submitted-review-head-missing]
      end,
      "shadow-evidence-reversed" => lambda do |result|
        result["shadow_evidence_unknown"] = %w[review-pagination-incomplete submitted-review-head-missing]
      end
    }

    eligible_mutations = mutations.filter_map do |label, mutation|
      autonomous = autonomous_result("autonomous-merge-eligible")
      mutation.call(autonomous)
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_safe_class_and_rollback_assessment_must_be_compatible_known_enums
    mutations = {
      "unknown-safe-class" => ->(result) { result["safe_class"] = "future-safe-class" },
      "unknown-rollback" => ->(result) { result["rollback_assessment"] = "UNKNOWN" },
      "unsafe-not-applicable" => lambda do |result|
        result["safe_class"] = "none"
        result["rollback_assessment"] = "not-applicable"
      end
    }

    eligible_mutations = mutations.filter_map do |label, mutation|
      autonomous = autonomous_result("autonomous-merge-eligible")
      mutation.call(autonomous)
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label if result.fetch("eligible")
    end

    assert_empty eligible_mutations
  end

  def test_autonomous_decision_evidence_requires_an_exact_none_or_accepted_record
    accepted = {
      "status" => "accepted",
      "comment_id" => "123",
      "url" => "https://github.com/owner/repo/pull/42#issuecomment-123",
      "approved_by" => "maintainer",
      "source" => "human-pr-comment"
    }
    cases = {
      "none-extra-field" => [
        "autonomous-merge-eligible", [], { "status" => "none", "reason" => "caller supplied" }
      ],
      "accepted-extra-field" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("reason" => "extra")
      ],
      "accepted-missing-url" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.reject { |key, _value| key == "url" }
      ],
      "accepted-non-string-comment-id" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("comment_id" => 123)
      ],
      "accepted-blank-url" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("url" => " ")
      ],
      "accepted-blank-approver" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("approved_by" => "")
      ],
      "accepted-unknown-source" => [
        "human-approved-for-current-head", ["changed-files-limit"], accepted.merge("source" => "automation")
      ],
      "uncertain" => [
        "human-approved-for-current-head",
        ["changed-files-limit"],
        accepted.merge(
          "status" => "uncertain",
          "reason" => "matching human and merge-authority attestation is missing or uncertain"
        )
      ]
    }

    missing_shape_failures = cases.filter_map do |label, (verdict, gates, decision)|
      autonomous = autonomous_result(verdict)
      autonomous["triggered_gates"] = gates
      autonomous["human_decision_evidence"] = decision
      result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous,
        context: context("auto_merge_when_gates_pass"),
        now: NOW
      )
      label unless Array(result["failures"]).include?(
        "autonomous_result human decision evidence shape is invalid"
      )
    end

    assert_empty missing_shape_failures
  end

  def test_accepted_autonomous_decision_evidence_must_bind_to_current_merge_target
    accepted = autonomous_result("human-approved-for-current-head").fetch("human_decision_evidence")
    cases = {
      "other-host" => [accepted.merge(
        "url" => "https://evil.example/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "other-repo" => [accepted.merge(
        "url" => "https://github.com/other/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "other-pr" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/43#issuecomment-123"
      ), "github.com"],
      "other-comment" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42#issuecomment-124"
      ), "github.com"],
      "zero-comment-id" => [accepted.merge("comment_id" => "0"), "github.com"],
      "leading-zero-comment-id" => [accepted.merge("comment_id" => "0123"), "github.com"],
      "non-decimal-comment-id" => [accepted.merge("comment_id" => "+123"), "github.com"],
      "malformed-url" => [accepted.merge("url" => "https://[invalid"), "github.com"],
      "http-url" => [accepted.merge(
        "url" => "http://github.com/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "userinfo" => [accepted.merge(
        "url" => "https://user@github.com/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "query" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42?view=1#issuecomment-123"
      ), "github.com"],
      "extra-path" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42/files#issuecomment-123"
      ), "github.com"],
      "leading-zero-pr" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/042#issuecomment-123"
      ), "github.com"],
      "unsupported-form" => [accepted.merge(
        "url" => "https://github.com/owner/repo/commit/42#issuecomment-123"
      ), "github.com"],
      "missing-fragment" => [accepted.merge(
        "url" => "https://github.com/owner/repo/pull/42"
      ), "github.com"],
      "default-port-mismatch" => [accepted.merge(
        "url" => "https://github.com:8443/owner/repo/pull/42#issuecomment-123"
      ), "github.com"],
      "custom-port-mismatch" => [accepted.merge(
        "url" => "https://github.example/owner/repo/pull/42#issuecomment-123"
      ), "github.example:8443"]
    }

    missing_binding_failures = cases.filter_map do |label, (decision, host)|
      merge_context = context("auto_merge_when_gates_pass")
      merge_context["host"] = host
      ci_result = ready_ci
      ci_result.fetch("context")["host"] = host
      autonomous = autonomous_result("human-approved-for-current-head")
      autonomous["human_decision_evidence"] = decision
      result = assess_with_replay(
        ci_result:,
        autonomous_result: autonomous,
        context: merge_context,
        now: NOW
      )
      label unless Array(result["failures"]).include?(
        "autonomous_result human decision evidence shape is invalid"
      )
    end

    assert_empty missing_binding_failures
  end

  def test_accepted_autonomous_decision_evidence_allows_bound_comment_permalink_forms
    cases = {
      "github-pull" => [
        "github.com",
        "owner/repo",
        "https://github.com/owner/repo/pull/42#issuecomment-123"
      ],
      "github-issues" => [
        "github.com",
        "owner/repo",
        "https://github.com/owner/repo/issues/42#issuecomment-123"
      ],
      "explicit-default-port" => [
        "github.com",
        "owner/repo",
        "https://github.com:443/owner/repo/pull/42#issuecomment-123"
      ],
      "ghes-custom-port" => [
        "github.example:8443",
        "owner/repo",
        "https://github.example:8443/owner/repo/issues/42#issuecomment-123"
      ],
      "case-insensitive-host-and-repo" => [
        "GitHub.Example:8443",
        "Owner/Repo",
        "https://github.example:8443/oWnEr/rEpO/pull/42#issuecomment-123"
      ]
    }

    blocked_cases = cases.filter_map do |label, (host, repo, url)|
      merge_context = context("auto_merge_when_gates_pass")
      merge_context["host"] = host
      merge_context["repo"] = repo
      ci_result = ready_ci
      ci_result.fetch("context")["host"] = host
      ci_result["repo"] = repo
      autonomous = autonomous_result("human-approved-for-current-head")
      autonomous.fetch("human_decision_evidence")["url"] = url
      result = assess_with_replay(
        ci_result:,
        autonomous_result: autonomous,
        context: merge_context,
        now: NOW
      )
      [label, result.fetch("failures")] unless result.fetch("eligible")
    end

    assert_empty blocked_cases
  end

  def test_ask_requires_exact_head_human_decision_and_same_diff_walkthrough
    missing = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("ask"),
      now: NOW
    )
    eligible = assess_with_replay(
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
    decision_result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: unbound_decision),
      now: NOW
    )
    walkthrough_result = assess_with_replay(
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
      decision_result = assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("human-approval-required"),
        context: context("explicit_approval", human_merge_decision: decision),
        now: NOW
      )
      walkthrough_result = assess_with_replay(
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
    unapproved = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        operations: [ordinary_follow_up("bundle-1", approval_scope: nil)]
      ),
      now: NOW
    )
    missing_additional = assess_with_replay(
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
    approved = assess_with_replay(
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
    result = assess_with_replay(
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
      result = assess_with_replay(
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
    result = assess_with_replay(
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
    result = assess_with_replay(
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
      result = assess_with_replay(
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
        assess_with_replay(
          ci_result: ready_ci,
          autonomous_result: autonomous_result("human-approval-required"),
          context: context("explicit_approval", human_merge_decision: decision),
          now: NOW
        ).fetch("eligible"),
        assess_with_replay(
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
    result = assess_with_replay(
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
    missing = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true
      ),
      now: NOW
    )
    duplicate = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context(
        "auto_merge_when_gates_pass",
        semantic_github_actions_change: true,
        operations: [semantic_tracker, semantic_tracker.merge("tracker" => "https://github.com/owner/repo/issues/2")]
      ),
      now: NOW
    )
    eligible = assess_with_replay(
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
    File.write(@fake_gh_exit_status, "1")
    result = assess_with_replay(
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
    result = assess_with_replay(
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
    result = assess_with_replay(
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
    result = assess_with_replay(
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

  def test_semantic_tracker_uses_the_trusted_gh_with_an_exact_sanitized_environment
    poison_root = Dir.mktmpdir("merge-assurance-poisoned-gh")
    poisoned_gh_marker = File.join(poison_root, "poisoned-gh-ran")
    preload_marker = File.join(poison_root, "ruby-preload-ran")
    preload = File.join(poison_root, "preload.rb")
    File.write(preload, <<~RUBY)
      File.write(#{preload_marker.inspect}, "yes") if File.basename($PROGRAM_NAME) == "gh"
    RUBY
    File.write(File.join(poison_root, "gh"), <<~RUBY)
      #!#{RbConfig.ruby}
      File.write(#{poisoned_gh_marker.inspect}, "yes")
      exit 99
    RUBY
    File.chmod(0o755, File.join(poison_root, "gh"))
    hostile = {
      "PATH" => "#{poison_root}:#{@original_path}",
      "GH_HOST" => "attacker.example",
      "GH_TOKEN" => "allowed-token",
      "RUBYOPT" => "-r#{preload}",
      "RUBYLIB" => poison_root,
      "RUBYGEMS_GEMDEPS" => "sentinel",
      "GEM_HOME" => poison_root,
      "BUNDLE_GEMFILE" => File.join(poison_root, "Gemfile"),
      "LD_PRELOAD" => File.join(poison_root, "preload.so"),
      "DYLD_INSERT_LIBRARIES" => File.join(poison_root, "preload.dylib"),
      "UNRELATED_SENTINEL" => "must-not-pass"
    }

    with_environment(hostile) do
      result = MergeAssurance.assess(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        recomputed_autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        trusted_gh_executable: @fake_gh,
        now: NOW
      )

      assert result.fetch("eligible")
    end
    child_environment = JSON.parse(File.read(@fake_gh_environment))

    refute File.exist?(poisoned_gh_marker)
    refute File.exist?(preload_marker)
    assert_equal "github.com", child_environment.fetch("GH_HOST")
    assert_equal "allowed-token", child_environment.fetch("GH_TOKEN")
    hostile.keys.grep_v(/\A(?:GH_HOST|GH_TOKEN)\z/).each do |key|
      refute child_environment.key?(key), key
    end
  ensure
    FileUtils.remove_entry(poison_root) if poison_root && File.exist?(poison_root)
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
      File.write(@fake_gh_exit_status, exit_status)
      File.write(@fake_gh_response, response)
      result = assess_with_replay(
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
      File.write(@fake_gh_response, JSON.generate(issue))
      result = assess_with_replay(
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
    error = assert_raises(MergeAssurance::Error) do
      assess_with_replay(
        ci_result: ready_ci,
        autonomous_result: autonomous_result("autonomous-merge-eligible"),
        context: context(
          "auto_merge_when_gates_pass",
          semantic_github_actions_change: true,
          operations: [semantic_tracker]
        ),
        now: NOW
      )
    end

    assert_includes error.message, "--trusted-gh-executable could not be safely resolved"
    assert_equal 0, fake_gh_call_count
  end

  def test_semantic_tracker_read_timeout_terminates_the_entire_process_group
    child_pid_path = @fake_gh_child_pid
    system(@fake_gh, "--version", out: File::NULL, err: File::NULL)
    reset_fake_gh_calls
    File.write(@fake_gh_hang, "yes")
    ENV["MERGE_ASSURANCE_GH_TIMEOUT_SECONDS"] = "0.5"
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = assess_with_replay(
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
    child_pid_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until File.size?(child_pid_path)
      flunk "fake gh child pid was not recorded" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= child_pid_deadline

      sleep 0.01
    end
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
    result = assess_with_replay(
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
    File.write(@fake_gh_exit_status, "1")
    result = assess_with_replay(
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
    default_result = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("autonomous-merge-eligible"),
      context: context("auto_merge_when_gates_pass"),
      now: NOW
    )
    report_only_result = assess_with_replay(
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
    explicit = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("human-approval-required"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )
    none = assess_with_replay(
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
    malformed = assess_with_replay(
      ci_result: ready_ci,
      autonomous_result: autonomous_result("unexpected-verdict"),
      context: context("explicit_approval", human_merge_decision: human_merge_decision),
      now: NOW
    )
    known_human_gate = assess_with_replay(
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

  def run_replay_cli(
    supplied:, recomputed:, provenance: "trusted-base:#{BASE_SHA}",
    helper_mode: :result, layout: :flat, semantic_inside_repo: false, extra_env: {},
    poisoned_ruby: false
  )
    Dir.mktmpdir("merge-assurance-replay", SAFE_TMP_PARENT) do |root|
      supplied_path = write_json_fixture(root, "autonomous.json", supplied)
      recomputed_path = write_json_fixture(root, "recomputed.json", recomputed)
      helper_call_path = File.join(root, "helper-call.json")
      trusted_bin = File.join(root, "trusted-bin")
      FileUtils.mkdir_p(trusted_bin)
      trusted_git_executable = File.join(trusted_bin, "git")
      trusted_gh_executable = File.join(trusted_bin, "gh")
      [trusted_git_executable, trusted_gh_executable].each do |executable|
        File.write(executable, "#!#{RbConfig.ruby}\nexit 0\n")
        File.chmod(0o755, executable)
      end
      real_skill_dir = case layout
                       when :native_plugin_cache
                         File.join(root, "agent-home/plugins/cache/scw/1.0.0/skills/pr-batch")
                       when :symlink
                         File.join(root, "source/skills/pr-batch")
                       else
                         File.join(root, "skills/pr-batch")
                       end
      bin_dir = File.join(real_skill_dir, "bin")
      lib_dir = File.join(real_skill_dir, "lib")
      FileUtils.mkdir_p([bin_dir, lib_dir])
      real_merge_script = File.join(bin_dir, "merge-assurance")
      FileUtils.cp(SCRIPT, real_merge_script)
      FileUtils.cp(
        File.expand_path("../lib/autonomous_merge_runtime_trust.rb", __dir__),
        File.join(lib_dir, "autonomous_merge_runtime_trust.rb")
      )
      helper = File.join(bin_dir, "autonomous-merge-eligibility")
      unless helper_mode == :missing
        File.write(helper, <<~RUBY)
          #!#{poisoned_ruby ? '/usr/bin/env ruby' : RbConfig.ruby}
          require "json"
          File.write(
            #{helper_call_path.inspect},
            JSON.generate(
              "argv" => ARGV,
              "autonomous_merge_gh_present" => ENV.key?("AUTONOMOUS_MERGE_GH"),
              "environment" => ENV.to_h
            )
          )
          case #{helper_mode.to_s.inspect}
          when "malformed"
            STDOUT.write("not-json")
          when "unknown", "semantic_rejection"
            STDOUT.write(JSON.generate("verdict" => "UNKNOWN"))
          when "nonzero"
            exit 9
          else
            STDOUT.write(File.read(#{recomputed_path.inspect}))
          end
        RUBY
        File.chmod(0o755, helper)
      end
      merge_script = real_merge_script
      if layout == :symlink
        linked_skills = File.join(root, "agent-home/skills")
        FileUtils.mkdir_p(linked_skills)
        File.symlink(real_skill_dir, File.join(linked_skills, "pr-batch"))
        merge_script = File.join(linked_skills, "pr-batch/bin/merge-assurance")
      end

      repo_root = File.join(root, "consumer")
      FileUtils.mkdir_p(repo_root)
      semantic_assessment = if semantic_inside_repo
                              File.join(repo_root, "semantic-assessment.json")
                            else
                              File.join(root, "semantic-assessment.json")
                            end
      File.write(semantic_assessment, "{}\n")
      ci_path = write_json_fixture(root, "ci.json", fresh_ready_ci)
      context_path = write_json_fixture(root, "context.json", context("auto_merge_when_gates_pass"))
      poisoned_ruby_marker = File.join(root, "poisoned-ruby-ran")
      if poisoned_ruby
        poisoned_bin = File.join(root, "poisoned-bin")
        FileUtils.mkdir_p(poisoned_bin)
        File.write(File.join(poisoned_bin, "ruby"), <<~RUBY)
          #!#{RbConfig.ruby}
          File.write(#{poisoned_ruby_marker.inspect}, "yes")
          STDOUT.write(File.read(#{supplied_path.inspect}))
        RUBY
        File.chmod(0o755, File.join(poisoned_bin, "ruby"))
        extra_env = extra_env.merge("PATH" => "#{poisoned_bin}:#{ENV.fetch('PATH')}")
      end
      env = extra_env
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        merge_script,
        "--ci-result", ci_path,
        "--autonomous-result", supplied_path,
        "--context", context_path,
        "--repo-root", repo_root,
        "--semantic-assessment", semantic_assessment,
        "--trusted-helper-provenance", provenance,
        "--trusted-git-executable", trusted_git_executable,
        "--trusted-gh-executable", trusted_gh_executable
      )
      return {
        status:,
        result: JSON.parse(stdout),
        stderr:,
        repo_root:,
        semantic_assessment:,
        trusted_git_executable: File.realpath(trusted_git_executable),
        trusted_gh_executable: File.realpath(trusted_gh_executable),
        helper_call: File.exist?(helper_call_path) ? JSON.parse(File.read(helper_call_path)) : {},
        poisoned_ruby_ran: File.exist?(poisoned_ruby_marker)
      }
    end
  end

  def write_json_fixture(root, name, value)
    path = File.join(root, name)
    File.write(path, "#{JSON.generate(value)}\n")
    path
  end

  def fresh_ready_ci
    ready = ready_ci
    checked_at = Time.now.utc.iso8601
    ready["checked_at"] = checked_at
    ready.fetch("scopes").each_value { |scope| scope["checked_at"] = checked_at }
    ready
  end

  def assess_with_replay(
    ci_result:, autonomous_result:, context:,
    recomputed_autonomous_result: autonomous_result, now: NOW
  )
    MergeAssurance.assess(
      ci_result:,
      autonomous_result:,
      recomputed_autonomous_result:,
      context:,
      trusted_gh_executable: @fake_gh,
      now:
    )
  end

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

  def with_environment(overrides)
    original = overrides.to_h { |key, _value| [key, ENV.key?(key) ? ENV.fetch(key) : nil] }
    ENV.update(overrides)
    yield
  ensure
    original&.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def eligible_semantic_binding_mutations
    semantic_binding_lines.filter_map do |key, expected_line|
      reset_fake_gh_calls
      issue = fake_issue
      issue["body"] = "#{issue['body']}\n#{yield(key, expected_line)}"
      File.write(@fake_gh_response, JSON.generate(issue))
      result = assess_with_replay(
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
    triggered_gates, human_decision_evidence =
      case verdict
      when "human-approval-required"
        [["changed-files-limit"], { "status" => "none" }]
      when "human-approved-for-current-head"
        [
          ["changed-files-limit"],
          {
            "status" => "accepted",
            "comment_id" => "123",
            "url" => "https://github.com/owner/repo/pull/42#issuecomment-123",
            "approved_by" => "maintainer",
            "source" => "human-pr-comment"
          }
        ]
      else
        [[], { "status" => "none" }]
      end
    {
      "verdict" => verdict,
      "head_sha" => HEAD_SHA,
      "policy_provenance" => "git:#{BASE_SHA}",
      "helper_provenance" => "trusted-base:#{BASE_SHA}",
      "helper_trust" => {
        "status" => "mechanically-verified",
        "manifest" => autonomous_runtime_manifest
      },
      "metrics" => { "changed_files" => 1, "changed_lines" => 2, "commits" => 1, "reviewed_heads" => 0 },
      "path_matches" => [],
      "safe_class" => "tests",
      "triggered_gates" => triggered_gates,
      "shadow_triggered_gates" => [],
      "shadow_evidence_unknown" => [],
      "rollback_assessment" => "code-only-rollback-established",
      "human_decision_evidence" => human_decision_evidence,
      "evidence_failures" => []
    }
  end

  def autonomous_runtime_manifest
    {
      "helper" => "skills/pr-batch/bin/autonomous-merge-eligibility",
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
