#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "time"

SCRIPT = File.expand_path("pr-merge-submit", __dir__)
ASSURANCE_SCRIPT = File.expand_path("merge-assurance", __dir__)
load ASSURANCE_SCRIPT
load SCRIPT

class PrMergeSubmitTest < Minitest::Test
  HEAD_SHA = "a" * 40
  NUMERIC_SHA = "1" * 40
  MOVED_SHA = "b" * 40
  BASE_SHA = Open3.capture2("git", "rev-parse", "HEAD", chdir: File.expand_path("../../..", __dir__)).first.strip
  HOST = "ghe.example:8443"
  ADVANCED_BASE_SHA = "d" * 40
  MERGE_COMMIT_SHA = "c" * 40
  SOURCE_REPO_POLICY = Object.new.freeze

  # A gh deadline has to be sized against what the scenario needs to SUCCEED,
  # not just against the hang it is meant to catch.
  #
  # These modes hang exactly one call -- the mutation -- and need the
  # metadata query before it and the reconciliation query after it to succeed.
  # At 0.1s those queries lost the race with the stub's own startup, so the run
  # died in setup and the mutation-timeout path was never exercised (#222).
  #
  # `warm_stub` removes the multi-second first-exec tail, leaving a warm stub
  # measured at p50 0.075s / max 0.101s over 60 samples on a loaded machine.
  # 2s is ~20x that, and matches the deadline the sibling hanging-gh test in
  # stale-assignment-sweep-test.rb uses; only the stub's deliberate 5s sleep
  # can cross it.
  MUTATION_TIMEOUT_MODES = %w[
    enqueue_timeout_unknown enqueue_timeout_merged
  ].freeze
  MUTATION_TIMEOUT_GH_SECONDS = "2"
  GUARD_TIMEOUT_GH_SECONDS = "2"
  # The remaining timeout modes hang their only gh call, so a startup-induced
  # timeout is the same observable event as the hang under test. They keep the
  # tight deadline that makes their elapsed-time bounds meaningful.
  SOLE_CALL_TIMEOUT_GH_SECONDS = "0.1"
  # metadata_timeout_descendant is a sole-call hang too, but unlike the group
  # above its assertion cares what happens *inside* the hang: whether the stub
  # reached its fork() before termination. A tight deadline there makes the
  # test vacuous (#238) -- the stub is usually killed before it forks. 1s is
  # ~10x the warm stub's measured max (0.101s), and the descendant deliberately
  # ignores TERM, so termination also consumes a full 1s TERM grace before
  # escalating to KILL -- leaving the total comfortably below the stub's
  # deliberate 30s sleep.
  DESCENDANT_TIMEOUT_GH_SECONDS = "1"
  NO_TIMEOUT_GH_SECONDS = "60"
  # Attempts allowed for a mutation-timeout scenario whose setup query raced.
  MUTATION_TIMEOUT_ATTEMPTS = 3
  # Attempts allowed for the descendant-timeout scenario whose stub never
  # reached its fork() before the deadline (an empty PID file: a precondition
  # miss, per #230, not a product failure).
  DESCENDANT_TIMEOUT_ATTEMPTS = 3
  QUEUE_DISABLED_ERROR = "queue-disabled submission is unsupported by the trusted-base " \
                         "merge_submission policy; configure mode: direct, configure an explicit " \
                         "repository-owned guarded-direct exception, or enable the repository merge queue"
  DIRECT_QUEUE_ERROR = "live repository merge queue is enabled but merge_submission mode is direct; " \
                       "configure merge_submission.mode: merge_queue_only (or " \
                       "merge_queue_or_guarded_direct) to opt into Merge Queue"

  def test_queue_disabled_pr_without_merge_submission_uses_portable_direct_default
    trusted_policy = nil
    result, log, guard_log = run_cli(
      mode: "direct",
      merge_submission: nil,
      trusted_policy_observer: ->(policy) { trusted_policy = policy }
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_equal "squash", payload.fetch("method")
    assert_equal false, payload.fetch("atomic_expected_base_oid")
    assert_equal({ "base_branch" => "main" }, trusted_policy)
    refute trusted_policy.key?("merge_submission")
    refute_includes log, "enqueuePullRequest"
    assert_includes log, "mergePullRequest"
    assert_includes log, "expectedHeadOid="
    assert_empty guard_log
  end

  def test_selected_hosted_ci_non_success_receipts_block_queue_and_guarded_direct
    cases = %i[
      selected_hosted_missing
      selected_hosted_cancelled
      selected_hosted_failed
      selected_hosted_nonterminal
    ]
    routes = {
      "queue" => { mode: "queue", merge_submission: SOURCE_REPO_POLICY },
      "guarded-direct" => {
        mode: "guard_success", merge_submission: guarded_direct_policy
      }
    }

    unexpectedly_mutated = routes.each_with_object([]) do |(route, route_options), failures|
      cases.each do |receipt_mode|
        result, log, guard_log = run_cli(
          **route_options, receipt_mode:
        )
        failures << "#{route}/#{receipt_mode}" if
          result.fetch(:status).success? || !log.empty? || !guard_log.empty?
      end
    end

    assert_empty unexpectedly_mutated
  end

  def test_selected_hosted_ci_success_receipt_replays_for_queue_and_guarded_direct
    queue_result, queue_log = run_cli(
      mode: "queue",
      merge_submission: merge_queue_policy,
      receipt_mode: :selected_hosted_success
    )
    guard_result, guard_log, guard_command_log = run_cli(
      mode: "guard_success",
      merge_submission: guarded_direct_policy,
      receipt_mode: :selected_hosted_success
    )

    assert queue_result.fetch(:status).success?, queue_result.fetch(:stderr)
    assert_includes queue_log, "enqueuePullRequest"
    assert guard_result.fetch(:status).success?, guard_result.fetch(:stderr)
    refute_empty guard_log
    refute_empty guard_command_log
  end

  def test_explicit_queue_only_policy_also_refuses_queue_disabled_submission
    result, log, guard_log = run_cli(
      mode: "direct",
      merge_submission: { "mode" => "merge_queue_only" }
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_equal "Error: #{QUEUE_DISABLED_ERROR}\n", result.fetch(:stderr)
    refute_includes log, "enqueuePullRequest"
    assert_empty guard_log
  end

  def test_only_a_missing_trusted_base_policy_blob_uses_the_portable_default
    missing_result, missing_log, = run_cli(
      mode: "direct", merge_submission: nil, policy_fixture: :missing
    )
    assert missing_result.fetch(:status).success?, missing_result.fetch(:stderr)
    assert_equal "direct", JSON.parse(missing_result.fetch(:stdout)).fetch("submission")
    assert_includes missing_log, "mergePullRequest"

    malformed_result, malformed_log, = run_cli(
      mode: "direct", merge_submission: nil, policy_fixture: :malformed
    )
    assert_equal 1, malformed_result.fetch(:status).exitstatus
    assert_includes malformed_result.fetch(:stderr),
                    "Error: trusted-base merge-submission policy is invalid YAML:"
    assert_empty malformed_log

    invalid_base_result, invalid_base_log, = run_cli(
      mode: "direct", merge_submission: nil, receipt_base_sha: "f" * 40
    )
    assert_equal 1, invalid_base_result.fetch(:status).exitstatus
    assert_includes invalid_base_result.fetch(:stderr),
                    "Error: trusted-base merge-submission policy is unavailable:"
    assert_empty invalid_base_log
  end

  def test_direct_mode_rejects_a_queue_enabled_repository_before_mutation
    result, log, guard_log = run_cli(
      mode: "queue", merge_submission: { "mode" => "direct" }
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_equal "Error: #{DIRECT_QUEUE_ERROR}\n", result.fetch(:stderr)
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
    assert_empty guard_log
  end

  def test_direct_mode_rechecks_queue_control_immediately_before_mutation
    result, log, = run_cli(mode: "direct_queue_race")

    assert_equal 1, result.fetch(:status).exitstatus
    assert_equal "Error: #{DIRECT_QUEUE_ERROR}\n", result.fetch(:stderr)
    assert_equal(2, log.lines.count { |line| line.include?("number=42") })
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_ambiguous_direct_transport_reconciles_only_an_exact_merge
    merged_result, merged_log, = run_cli(mode: "direct_transport_merged")

    assert merged_result.fetch(:status).success?, merged_result.fetch(:stderr)
    merged_payload = JSON.parse(merged_result.fetch(:stdout))
    assert_equal "already_merged", merged_payload.fetch("submission")
    assert_equal "direct", merged_payload.fetch("attempted_submission")
    assert_equal true, merged_payload.fetch("reconciled_after_failure")
    assert_includes merged_log, "mergePullRequest"

    unknown_result, unknown_log, = run_cli(mode: "direct_transport_unknown")
    assert_equal 2, unknown_result.fetch(:status).exitstatus
    assert_includes unknown_result.fetch(:stderr), "do not retry blindly"
    assert_includes unknown_log, "mergePullRequest"
  end

  def test_direct_graphql_errors_reconcile_an_exact_merge
    result, log, = run_cli(mode: "direct_graphql_error_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_unknown_reconciled_merge(
      JSON.parse(result.fetch(:stdout)), attempted_submission: "direct"
    )
    assert_includes log, "mergePullRequest"
  end

  def test_direct_graphql_errors_pin_open_queue_configuration_failures
    %w[direct_graphql_error_queue_enabled direct_graphql_error_in_queue].each do |mode|
      result, log, = run_cli(mode:)

      assert_equal 1, result.fetch(:status).exitstatus, mode
      assert_equal "Error: #{DIRECT_QUEUE_ERROR}\n", result.fetch(:stderr), mode
      assert_includes log, "mergePullRequest", mode
    end
  end

  def test_direct_graphql_errors_with_unresolved_state_are_unknown
    result, log, = run_cli(mode: "direct_graphql_error_unknown")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "direct merge submission outcome could not be proven after GraphQL errors"
    assert_includes result.fetch(:stderr), "do not retry blindly"
    assert_includes log, "mergePullRequest"
  end

  def test_invalid_direct_merge_response_reconciles_an_exact_merge
    result, log, = run_cli(mode: "direct_response_invalid_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_unknown_reconciled_merge(
      JSON.parse(result.fetch(:stdout)), attempted_submission: "direct"
    )
    assert_includes log, "mergePullRequest"
  end

  def test_invalid_direct_merge_response_with_unresolved_state_is_unknown
    result, log, = run_cli(mode: "direct_response_invalid_unknown")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "direct merge response validation outcome could not be proven"
    assert_includes result.fetch(:stderr), "do not retry blindly"
    assert_includes log, "mergePullRequest"
  end

  def test_guarded_direct_delegates_with_fixed_argv_and_reconciles_exact_merge
    result, log, guard_log, _attacker_log, fixture_head = run_cli(
      mode: "guard_success",
      merge_submission: guarded_direct_policy,
      body: "Detailed merge body"
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "guarded_direct", payload.fetch("submission")
    assert_equal "squash", payload.fetch("method")
    assert_equal false, payload.fetch("atomic_expected_base_oid")
    assert_equal true, payload.dig("non_atomic_base", "acknowledged")
    assert_equal ".agents/bin/merge-pr-after-checks", payload.dig("guard", "path")
    assert_match(/\A[0-9a-f]{64}\z/, payload.dig("guard", "sha256"))
    assert_equal true, payload.fetch("reconciled_after_guard")
    assert_equal MERGE_COMMIT_SHA, payload.fetch("merge_commit")
    refute_includes log, "enqueuePullRequest"
    refute_includes log, "mergePullRequest"
    argv = guard_log.lines.map(&:chomp)
    assert_equal [
      "--repo", "owner/repo", "--host", HOST, "--pr", "42",
      "--expected-head", fixture_head, "--expected-base", "main",
      "--expected-base-sha", payload.dig("guard", "trusted_base_sha"),
      "--method", "squash"
    ], argv.first(14)
    assert_equal "--merge-assurance-receipt", argv[14]
    assert_equal File.absolute_path(argv[15]), argv[15]
    assert_equal [
      "--subject", "Fix the thing (#42)", "--body", "Detailed merge body"
    ], argv.last(4)
  end

  def test_guard_executes_identity_bound_bytes_when_live_path_is_swapped_after_validation
    result, log, guard_log, attacker_log, fixture_head = run_cli(
      mode: "guard_path_swap",
      merge_submission: guarded_direct_policy
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "guarded_direct", payload.fetch("submission")
    assert_equal Digest::SHA256.hexdigest(fake_guard), payload.dig("guard", "sha256")
    assert_equal ".agents/bin/merge-pr-after-checks", payload.dig("guard", "path")
    assert_includes guard_log, "--expected-head\n#{fixture_head}"
    assert_empty attacker_log
    refute_includes log, "mergePullRequest"
  end

  def test_guard_timeout_and_interrupt_are_unknown_and_reconciled
    timeout_result, timeout_log, = run_cli(
      mode: "guard_timeout",
      merge_submission: guarded_direct_policy,
      guard_timeout_seconds: "0.1"
    )

    assert_equal 2, timeout_result.fetch(:status).exitstatus
    assert_match(
      /guarded-direct executable (?:timed out|process group did not exit after forced termination)/,
      timeout_result.fetch(:stderr)
    )
    assert_includes timeout_result.fetch(:stderr), "do not retry blindly"
    assert_equal(3, timeout_log.lines.count { |line| line.include?("number=42") })

    interrupt_result, interrupt_log, interrupt_guard_log = run_cli(
      mode: "guard_interrupt",
      merge_submission: guarded_direct_policy,
      interrupt_guard: true
    )

    assert_equal 2, interrupt_result.fetch(:status).exitstatus
    assert_match(
      /guarded-direct executable (?:was interrupted by SIGINT|process group did not exit after forced termination)/,
      interrupt_result.fetch(:stderr)
    )
    assert_includes interrupt_result.fetch(:stderr), "do not retry blindly"
    assert_equal(3, interrupt_log.lines.count { |line| line.include?("number=42") })
    refute_empty interrupt_guard_log
  end

  def test_hichee_style_queue_disabled_master_replay_uses_guarded_direct
    result, _log, guard_log, attacker_log, fixture_head = run_cli(
      mode: "hichee_replay",
      base: "master",
      expected_base: "master",
      repo: "shakacode/hichee",
      merge_submission: guarded_direct_policy(
        rationale: "HiChee owns a checks-and-head-validating direct squash wrapper."
      ),
      guard_fixture: :delegating
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "guarded_direct", payload.fetch("submission")
    assert_equal "master", payload.fetch("expected_base")
    assert_equal "shakacode/hichee", payload.fetch("repo")
    assert_includes guard_log, "shakacode/hichee"
    assert_includes guard_log, "master"
    assert_includes guard_log, "delegated trusted-base dependency"
    assert_includes guard_log, "\nHEAD\n#{payload.dig('guard', 'trusted_base_sha')}\n"
    assert_includes guard_log, fixture_head
    assert_empty attacker_log
  end

  def test_guarded_direct_never_executes_a_pr_head_secondary_dependency
    result, _log, guard_log, attacker_log, fixture_head = run_cli(
      mode: "guard_success",
      merge_submission: guarded_direct_policy,
      guard_fixture: :delegating
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes guard_log, "delegated trusted-base dependency"
    assert_includes guard_log, fixture_head
    assert_empty attacker_log
  end

  def test_private_guard_git_head_cannot_read_pr_tree_bytes
    result, _log, guard_log = run_cli(
      mode: "guard_success",
      merge_submission: guarded_direct_policy,
      guard_fixture: :delegating
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes guard_log, "delegated trusted-base dependency"
    refute_includes guard_log, "PR-only dependency executed"
  end

  def test_guard_interpreter_ignores_checkout_controlled_path
    result, _log, guard_log, attacker_log = run_cli(
      mode: "guard_success",
      merge_submission: guarded_direct_policy,
      interpreter_attack: true
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "/usr/bin/env ruby", payload.dig("guard", "interpreter", "requested")
    assert_equal File.realpath(RbConfig.ruby), payload.dig("guard", "interpreter", "path")
    assert_match(/\A[0-9a-f]{64}\z/, payload.dig("guard", "interpreter", "sha256"))
    assert_empty attacker_log
    refute_empty guard_log
  end

  def test_guard_environment_ignores_checkout_controlled_bash_env
    result, _log, guard_log, attacker_log = run_cli(
      mode: "guard_success",
      merge_submission: guarded_direct_policy,
      guard_fixture: :bash_executable,
      bash_env_attack: true
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_empty attacker_log
    refute_empty guard_log
  end

  def test_guard_rejects_an_absolute_interpreter_inside_the_pr_checkout
    result, _log, guard_log, attacker_log = run_cli(
      mode: "guard_success",
      merge_submission: guarded_direct_policy,
      guard_fixture: :checkout_interpreter
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "interpreter must be outside the consumer repository"
    assert_empty attacker_log
    assert_empty guard_log
  end

  def test_guard_failure_ambiguous_state_and_head_movement_are_unknown
    {
      "guard_failure" => "guard failed",
      "guard_failure_merged" => "guard failed",
      "guard_ambiguous" => "not an exact terminal merge",
      "guard_head_moved" => "PR head moved"
    }.each do |mode, detail|
      result, log, guard_log = run_cli(mode:, merge_submission: guarded_direct_policy)

      assert_equal 2, result.fetch(:status).exitstatus, mode
      assert_includes result.fetch(:stderr), detail, mode
      assert_includes result.fetch(:stderr), "do not retry blindly", mode
      refute_includes log, "enqueuePullRequest", mode
      refute_empty guard_log, mode
    end
  end

  def test_malformed_or_untrusted_base_guard_configuration_stops_before_github
    cases = {
      "unknown mode" => [{ "mode" => "unknown" }, :executable],
      "missing guard" => [guarded_direct_policy, :missing],
      "non-executable guard" => [guarded_direct_policy, :non_executable]
    }
    cases.each do |label, (seam, guard_fixture)|
      result, log, guard_log = run_cli(
        mode: "guard_ambiguous", merge_submission: seam, guard_fixture:
      )

      assert_equal 1, result.fetch(:status).exitstatus, label
      assert_includes result.fetch(:stderr), label.include?("mode") ? "mode is invalid" : "guarded-direct executable", label
      assert_empty log, label
      assert_empty guard_log, label
    end
  end

  def test_live_guard_drift_stops_open_direct_submission_before_mutation
    result, log, guard_log = run_cli(
      mode: "guard_ambiguous",
      merge_submission: guarded_direct_policy,
      guard_fixture: :modified_after_commit
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "guarded-direct executable does not match the trusted-base blob"
    assert_equal(2, log.lines.count { |line| line.include?("number=42") })
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
    assert_empty guard_log
  end

  def test_guarded_direct_rejects_an_absolute_interpreter_in_the_checkout
    result, log, guard_log = run_cli(
      mode: "guard_ambiguous",
      merge_submission: guarded_direct_policy,
      guard_fixture: :launch_eacces
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr),
                    "trusted-base guarded-direct interpreter must be outside the consumer repository"
    assert_equal(2, log.lines.count { |line| line.include?("number=42") })
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
    assert_empty guard_log
  end

  def test_guarded_direct_rejects_a_missing_absolute_interpreter
    result, log, guard_log = run_cli(
      mode: "guard_ambiguous",
      merge_submission: guarded_direct_policy,
      guard_fixture: :launch_enoent
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "trusted-base guarded-direct interpreter is unavailable"
    assert_equal(2, log.lines.count { |line| line.include?("number=42") })
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
    assert_empty guard_log
  end

  def test_private_repository_cleanup_failure_after_guard_launch_is_reconciled
    runner = PrMergeSubmit::Runner.allocate
    runner.define_singleton_method(:remove_private_guard_directory!) do |_directory|
      raise Errno::EACCES, "cleanup denied"
    end
    successful_status = Object.new
    successful_status.define_singleton_method(:success?) { true }

    stdout, stderr, status = runner.send(
      :cleanup_private_guard_directory!,
      "/private/guard", ["guard stdout", "guard stderr", successful_status]
    )

    assert_equal "guard stdout", stdout
    assert_includes stderr, "guard stderr"
    assert_includes stderr, "private guarded-direct repository cleanup failed"
    refute status.success?
  end

  def test_forced_termination_unknown_is_returned_for_exact_reconciliation
    runner = PrMergeSubmit::Runner.allocate
    runner.instance_variable_set(
      :@merge_assurance_receipt,
      { "bindings" => { "base" => { "sha" => BASE_SHA } } }
    )
    runner.define_singleton_method(:materialize_trusted_base_repository!) { |directory| directory }
    runner.define_singleton_method(:guarded_direct_launch_command!) do |_bytes, executable|
      [[executable], nil]
    end
    runner.define_singleton_method(:guard_timeout_seconds) { 0.1 }
    runner.define_singleton_method(:run_process) do |*_args, **_kwargs|
      raise PrMergeSubmit::UnknownOutcome,
            "guarded-direct executable process group did not exit after forced termination; " \
            "remote outcome is UNKNOWN"
    end

    _stdout, stderr, status = runner.send(
      :run_guard,
      { "method" => "squash", "trusted_bytes" => fake_guard, "identity" => {} },
      {
        repo: "owner/repo", host: HOST, pr: 42, expected_head: HEAD_SHA,
        expected_base: "main", method: "squash",
        merge_assurance_receipt: "/tmp/receipt.json", subject: nil, body: nil
      }
    )

    assert_includes stderr, "process group did not exit after forced termination"
    refute status.success?
  end

  def test_guarded_direct_ignores_unneeded_head_branch_metadata
    [:missing, "bad..branch"].each do |head_ref_name|
      result, _log, guard_log = run_cli(
        mode: "guard_success",
        merge_submission: guarded_direct_policy,
        head_ref_name:
      )

      assert result.fetch(:status).success?, result.fetch(:stderr)
      refute_empty guard_log
    end
  end

  def test_guarded_direct_rejects_shebangless_text_before_spawn
    runner = PrMergeSubmit::Runner.new

    error = assert_raises(PrMergeSubmit::Error) do
      runner.send(:guarded_direct_launch_command!, "echo attacker\n", "/tmp/guard")
    end

    assert_equal(
      "trusted-base guarded-direct executable must have a supported explicit shebang",
      error.message
    )
  end

  def test_guarded_direct_rejects_all_shebangless_native_magic_prefixes
    runner = PrMergeSubmit::Runner.new
    [
      "\x7FELF", "\xFE\xED\xFA\xCE", "\xCE\xFA\xED\xFE",
      "\xCA\xFE\xBA\xBE", "MZ", "", "echo native\n"
    ].each do |bytes|
      assert_raises(PrMergeSubmit::Error) do
        runner.send(:guarded_direct_launch_command!, "#{bytes}payload".b, "/tmp/guard")
      end
    end
  end

  def test_run_gh_ignores_checkout_controlled_path_shim
    original_path = ENV.fetch("PATH")
    runner = PrMergeSubmit::Runner.new

    Dir.mktmpdir("pr-merge-submit-gh-shim") do |dir|
      marker = File.join(dir, "gh-shim-ran")
      File.write(
        File.join(dir, "gh"),
        "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'ran')\n"
      )
      FileUtils.chmod(0o755, File.join(dir, "gh"))
      ENV["PATH"] = dir
      statuses = [false, true].map do |mutation|
        _stdout, _stderr, status = runner.send(
          :run_gh, "--version", host: HOST, mutation:
        )
        status
      end

      assert statuses.all?(&:success?)
      refute_path_exists marker
    end
  ensure
    ENV["PATH"] = original_path
  end

  def test_run_gh_uses_closed_environment_with_only_supported_nonempty_tokens
    original_values = {
      "GH_CONFIG_DIR" => ENV["GH_CONFIG_DIR"],
      "GH_DEBUG" => ENV["GH_DEBUG"],
      "GH_REPO" => ENV["GH_REPO"],
      "GIT_DIR" => ENV["GIT_DIR"],
      "GH_TOKEN" => ENV["GH_TOKEN"],
      "GITHUB_TOKEN" => ENV["GITHUB_TOKEN"]
    }
    Dir.mktmpdir("pr-merge-submit-gh-environment") do |dir|
      capture = File.join(dir, "environment.json")
      gh = File.join(dir, "trusted-gh")
      File.write(
        gh,
        "#!#{RbConfig.ruby}\nrequire 'json'\nFile.write(#{capture.inspect}, JSON.generate(ENV.to_h))\n"
      )
      FileUtils.chmod(0o755, gh)
      ENV.update(
        "GH_CONFIG_DIR" => File.join(dir, "checkout-config"),
        "GH_DEBUG" => "api",
        "GH_REPO" => "attacker/repo",
        "GIT_DIR" => File.join(dir, "attacker-git-dir"),
        "GH_TOKEN" => "supported-token",
        "GITHUB_TOKEN" => ""
      )
      runner = PrMergeSubmit::Runner.new(system_tools: { "gh" => gh })

      _stdout, stderr, status = runner.send(:run_gh, "--version", host: HOST)

      assert status.success?, stderr
      environment = JSON.parse(File.read(capture))
      assert_equal "supported-token", environment["GH_TOKEN"]
      refute environment.key?("GITHUB_TOKEN")
      %w[GH_CONFIG_DIR GH_DEBUG GH_REPO GIT_DIR].each do |name|
        refute environment.key?(name), name
      end
    end
  ensure
    original_values&.each do |name, value|
      value ? ENV[name] = value : ENV.delete(name)
    end
  end

  def test_git_capture_ignores_checkout_controlled_path_shim
    runner = PrMergeSubmit::Runner.new

    Dir.mktmpdir("pr-merge-submit-git-shim") do |dir|
      marker = File.join(dir, "git-shim-ran")
      File.write(
        File.join(dir, "git"),
        "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'ran')\n"
      )
      FileUtils.chmod(0o755, File.join(dir, "git"))
      original_path = ENV.fetch("PATH")
      ENV["PATH"] = dir
      _stdout, _stderr, status = runner.send(:git_capture, "--version", chdir: dir)

      assert status.success?
      refute_path_exists marker
    ensure
      ENV["PATH"] = original_path
    end
  end

  def test_first_git_capture_rejects_a_resolved_tool_inside_the_candidate_repository
    Dir.mktmpdir("pr-merge-submit-repository-git") do |repo_root|
      marker = File.join(repo_root, "git-ran")
      git = File.join(repo_root, "git")
      File.write(git, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, 'ran')\n")
      FileUtils.chmod(0o755, git)
      runner = PrMergeSubmit::Runner.new(system_tools: { "git" => git })

      error = assert_raises(PrMergeSubmit::Error) do
        runner.send(:git_capture, "--version", chdir: repo_root)
      end

      assert_equal "git must resolve outside the consumer repository", error.message
      refute_path_exists marker
    end
  end

  def test_git_capture_ignores_ambient_git_injection_variables
    repo_root = File.expand_path("../../..", __dir__)
    runner = PrMergeSubmit::Runner.new
    runner.instance_variable_set(:@repo_root, repo_root)
    original_git_dir = ENV["GIT_DIR"]
    ENV["GIT_DIR"] = File.join(repo_root, "checkout-controlled-git-dir")

    stdout, stderr, status = runner.send(
      :git_capture, "-C", repo_root, "rev-parse", "HEAD", chdir: repo_root
    )

    assert status.success?, stderr
    assert_match(/\A[0-9a-f]{40}\n\z/, stdout)
  ensure
    original_git_dir ? ENV["GIT_DIR"] = original_git_dir : ENV.delete("GIT_DIR")
  end

  def test_missing_local_account_fails_with_deterministic_submitter_error
    runner = PrMergeSubmit::Runner.new
    original_getpwuid = Etc.method(:getpwuid)
    Etc.singleton_class.define_method(:getpwuid) { |_uid| raise ArgumentError, "can't find user" }

    error = assert_raises(PrMergeSubmit::Error) do
      runner.send(:guarded_direct_environment, host: HOST, repo: "owner/repo")
    end

    assert_equal "local account identity is unavailable for uid #{Process.uid}", error.message
  ensure
    Etc.singleton_class.define_method(:getpwuid, original_getpwuid)
  end

  def test_git_and_gh_spawn_races_use_deterministic_submitter_errors
    runner = PrMergeSubmit::Runner.new
    runner.define_singleton_method(:resolve_system_tool!) { |name, **| "/usr/bin/#{name}" }

    original_capture3 = Open3.method(:capture3)
    Open3.singleton_class.define_method(:capture3) { |*| raise Errno::EACCES, "git disappeared" }
    git_error = assert_raises(PrMergeSubmit::Error) do
      runner.send(:git_capture, "--version", chdir: Dir.pwd)
    end
    assert_includes git_error.message, "git could not be launched after trusted resolution"
    Open3.singleton_class.define_method(:capture3, original_capture3)

    runner.define_singleton_method(:run_process) { |*_, **| raise Errno::ENOENT, "gh disappeared" }
    gh_error = assert_raises(PrMergeSubmit::Error) do
      runner.send(:run_gh, "--version", host: HOST)
    end
    assert_includes gh_error.message, "gh could not be launched after trusted resolution"
  ensure
    Open3.singleton_class.define_method(:capture3, original_capture3) if original_capture3
  end

  def test_unknown_guard_fixture_fails_closed
    error = assert_raises(RuntimeError) do
      run_cli(
        mode: "guard_ambiguous",
        merge_submission: guarded_direct_policy,
        guard_fixture: :unknown
      )
    end

    assert_equal "unknown guard fixture: :unknown", error.message
  end

  def test_guard_blob_oid_accepts_only_exact_sha1_or_sha256_lengths
    runner = PrMergeSubmit::Runner.new

    assert runner.send(:valid_git_blob_oid?, "a" * 40)
    assert runner.send(:valid_git_blob_oid?, "b" * 64)
    [0, 39, 41, 63, 65].each do |length|
      refute runner.send(:valid_git_blob_oid?, "c" * length), length
    end
  end

  def test_trusted_blob_returns_non_ascii_bytes_with_binary_encoding
    runner = PrMergeSubmit::Runner.new
    runner.instance_variable_set(:@repo_root, "/trusted/repo")
    status = Object.new
    status.define_singleton_method(:success?) { true }
    trusted_bytes = "#!/bin/sh\n# snowman: \u2603\n"
    runner.define_singleton_method(:git_capture) do |*_args, **_kwargs|
      [trusted_bytes, "", status]
    end

    result = runner.send(:trusted_blob!, HEAD_SHA, ".agents/bin/guard", "test guard")

    assert_equal trusted_bytes.b, result
    assert_equal Encoding::BINARY, result.encoding
  end

  def test_trusted_base_merge_submission_rejects_closed_schema_violations
    cases = [
      { "mode" => "merge_queue_or_guarded_direct" },
      guarded_direct_policy.tap do |seam|
        seam["guarded_direct"]["non_atomic_base"]["acknowledged"] = false
      end,
      guarded_direct_policy(executable: ".agents/bin/merge-pr --force"),
      guarded_direct_policy.tap do |seam|
        seam["guarded_direct"]["shell"] = "bash -lc"
      end
    ]
    cases.each do |seam|
      result, log, guard_log = run_cli(
        mode: "guard_ambiguous", merge_submission: seam
      )

      assert_equal 1, result.fetch(:status).exitstatus, seam.inspect
      assert_includes result.fetch(:stderr), "merge_submission", seam.inspect
      assert_empty log, seam.inspect
      assert_empty guard_log, seam.inspect
    end
  end

  def test_non_string_merge_submission_keys_fail_closed_without_sort_exceptions
    cases = [
      guarded_direct_policy.merge(1 => "unexpected"),
      guarded_direct_policy.tap { |seam| seam.fetch("guarded_direct")[1] = "unexpected" },
      guarded_direct_policy.tap do |seam|
        seam.dig("guarded_direct", "non_atomic_base")[1] = "unexpected"
      end
    ]

    cases.each do |seam|
      result, log, guard_log = run_cli(mode: "guard_ambiguous", merge_submission: seam)

      assert_equal 1, result.fetch(:status).exitstatus, seam.inspect
      assert_includes result.fetch(:stderr), "merge_submission", seam.inspect
      refute_includes result.fetch(:stderr), "comparison of", seam.inspect
      assert_empty log, seam.inspect
      assert_empty guard_log, seam.inspect
    end
  end

  def test_guarded_direct_requested_method_must_match_trusted_base_method
    result, log, guard_log = run_cli(
      mode: "guard_ambiguous",
      merge_submission: guarded_direct_policy(method: "merge")
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "does not match trusted-base guarded-direct method"
    assert_equal(1, log.lines.count { |line| line.include?("number=42") })
    assert_empty guard_log
  end

  def test_enabled_merge_queue_enqueues_the_same_head_without_a_direct_attempt
    result, log, guard_log = run_cli(
      mode: "queue", merge_submission: guarded_direct_policy
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal "squash", payload.fetch("direct_method_requested")
    refute payload.key?("requested_method")
    assert_equal HEAD_SHA, payload.fetch("expected_head")
    assert_equal "main", payload.fetch("expected_base")
    assert_equal "MQE_1", payload.dig("merge_queue_entry", "id")
    assert_empty guard_log
    assert_includes log, "enqueuePullRequest"
    assert_includes log, "expectedHeadOid=#{HEAD_SHA}"
    assert_includes log, "GH_HOST=#{HOST} api graphql"
    assert_equal 3, log.scan("GraphQL-Features: merge_queue").length
    refute_includes log, "--auto"
  end

  def test_enqueue_graphql_failure_with_unresolved_state_is_unknown
    result, log = run_cli(mode: "enqueue_graphql_error", merge_submission: merge_queue_policy)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "do not retry blindly"
    assert_includes log, "enqueuePullRequest"
  end

  def test_head_movement_stops_before_any_merge_mutation
    result, log = run_cli(mode: "direct", head: MOVED_SHA)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "PR head moved"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_base_retarget_stops_before_any_merge_mutation
    result, log = run_cli(mode: "direct", base: "release")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "PR base moved"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_returned_pr_url_must_match_explicit_host
    result, log = run_cli(mode: "direct", url_host: "github.com")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "PR URL host mismatch"
    refute_includes log, "mergePullRequest"
  end

  def test_repository_name_and_head_oid_are_sent_as_raw_strings
    result, log = run_cli(
      mode: "queue", repo: "owner/123", head: NUMERIC_SHA,
      expected_head: NUMERIC_SHA, merge_submission: merge_queue_policy
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes log, "-f name=123"
    refute_includes log, "-F name=123"
    assert_includes log, "-f expectedHeadOid=#{NUMERIC_SHA}"
    refute_includes log, "-F expectedHeadOid=#{NUMERIC_SHA}"
  end

  def test_queue_response_without_entry_fails_closed
    result, = run_cli(mode: "queue_missing_entry", merge_submission: merge_queue_policy)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "outcome could not be proven"
  end

  def test_existing_exact_queue_entry_is_idempotent
    result, log = run_cli(mode: "already_queued", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal "MQE_1", payload.dig("merge_queue_entry", "id")
    refute_includes log, "enqueuePullRequest"
    refute_includes log, "mergePullRequest"
  end

  def test_initial_queue_membership_with_a_merge_commit_is_not_exact_queue_proof
    result, log = run_cli(mode: "already_queued_with_commit", merge_submission: merge_queue_policy)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "lacks strict proof"
    refute_includes log, "enqueuePullRequest"
    refute_includes log, "mergePullRequest"
  end

  def test_existing_exact_merge_is_idempotent
    result, log = run_cli(mode: "already_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "already_merged", payload.fetch("submission")
    assert_equal "UNKNOWN", payload.fetch("merge_provenance")
    assert_equal true, payload.fetch("already_complete")
    assert_equal MERGE_COMMIT_SHA, payload.fetch("merge_commit")
    refute payload.key?("method")
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_existing_exact_merge_is_idempotent_when_the_live_guard_drifted
    result, log, guard_log = run_cli(
      mode: "already_merged",
      merge_submission: guarded_direct_policy,
      guard_fixture: :modified_after_commit
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "already_merged", payload.fetch("submission")
    assert_equal true, payload.fetch("already_complete")
    assert_equal(1, log.lines.count { |line| line.include?("number=42") })
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
    assert_empty guard_log
  end

  def test_existing_exact_merge_accepts_an_advanced_base_oid_before_old_base_guard
    result, log = run_cli(mode: "already_merged_base_advanced")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "already_merged", payload.fetch("submission")
    assert_equal true, payload.fetch("already_complete")
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_initial_merged_state_requires_a_full_hex_merge_commit_oid
    ["", "malformed", "UNKNOWN"].each do |merge_commit_oid|
      result, log = run_cli(mode: "already_merged", merge_commit_oid:)

      refute result.fetch(:status).success?, merge_commit_oid
      assert_includes result.fetch(:stderr), "PR state is not valid for submission", merge_commit_oid
      refute_includes log, "mergePullRequest", merge_commit_oid
      refute_includes log, "enqueuePullRequest", merge_commit_oid
    end
  end

  def test_base_advancement_never_qualifies_open_queued_states
    {
      "enqueue_transport_queued_base_advanced" => "enqueuePullRequest",
      "queue_post_queued_base_advanced" => "enqueuePullRequest"
    }.each do |mode, attempted_mutation|
      result, log = run_cli(mode:, merge_submission: merge_queue_policy)

      assert_equal 2, result.fetch(:status).exitstatus, mode
      assert_includes log, attempted_mutation, mode
    end
  end

  def test_initial_open_or_queued_base_advancement_stops_before_any_mutation
    %w[initial_open_base_advanced already_queued_base_advanced].each do |mode|
      result, log = run_cli(
        mode:,
        merge_submission: queue_submission_mode?(mode) ? merge_queue_policy : SOURCE_REPO_POLICY
      )

      refute result.fetch(:status).success?, mode
      assert_includes result.fetch(:stderr), "receipt base SHA mismatch", mode
      refute_includes log, "mergePullRequest", mode
      refute_includes log, "enqueuePullRequest", mode
    end
  end

  def test_enqueue_transport_failure_reconciles_an_exact_queue_entry
    result, = run_cli(mode: "enqueue_transport_queued", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
  end

  def test_enqueue_transport_failure_keeps_merge_provenance_unknown
    result, = run_cli(mode: "enqueue_transport_merged", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_unknown_reconciled_merge(
      JSON.parse(result.fetch(:stdout)), attempted_submission: "merge_queue"
    )
  end

  def test_enqueue_graphql_errors_keep_merge_provenance_unknown
    result, = run_cli(mode: "enqueue_graphql_error_merged", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_unknown_reconciled_merge(
      JSON.parse(result.fetch(:stdout)), attempted_submission: "merge_queue"
    )
  end

  def test_valid_merge_proof_wins_when_queue_fields_coexist
    result, = run_cli(mode: "enqueue_graphql_error_merged_queued", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "already_merged", payload.fetch("submission")
    assert_equal "merge_queue", payload.fetch("attempted_submission")
    refute payload.key?("queue_method")
  end

  def test_terminal_queue_fields_with_an_invalid_commit_prove_neither_outcome
    %w[UNKNOWN malformed].each do |merge_commit_oid|
      result, = run_cli(
        mode: "enqueue_graphql_error_merged_queued", merge_commit_oid:,
        merge_submission: merge_queue_policy
      )

      assert_equal 2, result.fetch(:status).exitstatus, merge_commit_oid
      assert_includes result.fetch(:stderr), "outcome could not be proven", merge_commit_oid
    end
  end

  def test_enqueue_reconciliation_callers_reject_queue_state_with_a_merge_commit
    {
      "enqueue_transport_queued_with_commit" => "enqueuePullRequest",
      "enqueue_graphql_error_queued_with_commit" => "enqueuePullRequest"
    }.each do |mode, attempted_mutation|
      result, log = run_cli(mode:, merge_submission: merge_queue_policy)

      assert_equal 2, result.fetch(:status).exitstatus, mode
      assert_includes result.fetch(:stderr), "could not be proven", mode
      assert_includes log, attempted_mutation, mode
    end
  end

  def test_successful_enqueue_response_preserves_queue_provenance_after_fast_merge
    result, = run_cli(mode: "queue_fast_merged", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_reconciled_queue_merge(JSON.parse(result.fetch(:stdout)))
  end

  def test_fast_post_enqueue_merge_accepts_an_advanced_base_oid_before_old_base_guard
    result, = run_cli(mode: "queue_fast_merged_base_advanced", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_reconciled_queue_merge(JSON.parse(result.fetch(:stdout)))
  end

  def test_fast_post_enqueue_merge_requires_a_full_hex_merge_commit_oid
    ["", "malformed", "UNKNOWN"].each do |merge_commit_oid|
      result, = run_cli(mode: "queue_fast_merged", merge_commit_oid:, merge_submission: merge_queue_policy)

      assert_equal 2, result.fetch(:status).exitstatus, merge_commit_oid
      assert_includes result.fetch(:stderr), "live membership could not be confirmed", merge_commit_oid
    end
  end

  def test_fast_post_enqueue_queue_with_a_merge_commit_is_not_exact_queue_proof
    result, = run_cli(mode: "queue_post_queued_with_commit", merge_submission: merge_queue_policy)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "live membership could not be confirmed"
  end

  def test_initial_metadata_timeout_is_bounded
    started_at = nil
    result, = run_cli(
      mode: "metadata_timeout",
      after_stub_warmup: -> { started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "timed out"
    assert_operator elapsed, :<, 2
  end

  def test_timeout_kills_a_surviving_process_group_descendant
    # An empty/missing PID file means the stub never reached its fork() before
    # the deadline: a precondition miss (see DESCENDANT_TIMEOUT_GH_SECONDS),
    # not a product failure, so retry it instead of reporting a misleading
    # pass or orphan. A real orphan regression still fails, because there the
    # stub does fork, records the descendant's pid, and the descendant
    # survives termination. Mirrors
    # stale-assignment-sweep-test.rb#test_timed_out_gh_call_terminates_its_process_group_with_no_orphan.
    status = nil
    stderr = nil
    descendant_pid = nil
    started_at = nil
    DESCENDANT_TIMEOUT_ATTEMPTS.times do
      started_at = nil
      result, _log, _guard_log, _attacker_log, _fixture_head, descendant_pid = run_cli(
        mode: "metadata_timeout_descendant",
        after_stub_warmup: -> { started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      )
      status = result.fetch(:status)
      stderr = result.fetch(:stderr)
      break if descendant_pid
    end

    refute_nil descendant_pid,
               "stub gh never recorded a spawned descendant pid in #{DESCENDANT_TIMEOUT_ATTEMPTS} " \
               "attempts, so the process-group-descendant path was never exercised: #{stderr}"

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal 1, status.exitstatus
    assert_includes stderr, "timed out"
    # Both substrings come from the same literal on the :timed_out diagnostic
    # path, so together they pin its exact shape without a clock. "timed out"
    # is the stronger discriminator of the two: the :undead path raises
    # UnknownOutcome before any diagnostic is built and warns a message
    # containing neither substring, and the interrupt path emits
    # "was terminated" without "timed out". Asserting both keeps the message
    # from drifting into either neighbour.
    assert_includes stderr, "was terminated"
    # Loose sanity check, not the load-bearing assertion: well under the
    # stub's deliberate 30s sleep (measured ~2.2-2.5s over 15 runs at load
    # avg 11-14), so a pass still corroborates that termination was bounded
    # rather than merely waiting out the sleep. The 30s stub / 10s bound gap
    # (vs. the old 5s / 3.5s gap) makes this essentially load-insensitive; a
    # genuine unbounded-termination regression now takes ~30s to surface
    # instead of ~5s.
    assert_operator elapsed, :<, 10
    assert descendant_terminated?(descendant_pid),
           "descendant #{descendant_pid} was orphaned instead of terminated with its process group"
  end

  def test_interrupt_is_forwarded_and_mutation_outcome_is_reconciled
    started_at = nil
    result, log = run_cli_with_interrupt(
      mode: "enqueue_interrupt_unknown", wait_for: "enqueuePullRequest",
      after_stub_warmup: -> { started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "interrupted by SIGINT"
    assert_includes result.fetch(:stderr), "do not retry blindly"
    assert_includes log, "enqueuePullRequest"
    assert_operator elapsed, :<, 3
  end

  def test_interrupted_mutation_that_exits_zero_still_reconciles
    result, log = run_cli_with_interrupt(
      mode: "enqueue_interrupt_exit_zero", wait_for: "enqueuePullRequest"
    )

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "interrupted by SIGINT"
    assert_includes result.fetch(:stderr), "do not retry blindly"
    assert_includes log, "enqueuePullRequest"
  end

  def test_interrupted_metadata_request_that_exits_zero_cannot_mutate
    result, log = run_cli_with_interrupt(
      mode: "metadata_interrupt_exit_zero", wait_for: "number=42"
    )

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "interrupted by SIGINT"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_persistent_cancellation_blocks_a_later_mutation
    runner = PrMergeSubmit::Runner.new
    runner.instance_variable_set(:@mutation_attempted, true)
    runner.instance_variable_set(:@cancellation_signal, "INT")
    runner.instance_variable_set(:@pending_signal, nil)

    stdout, stderr, status = runner.send(
      :run_gh, "api", "graphql", host: HOST, mutation: true
    )

    assert_empty stdout
    assert_includes stderr, "cancelled by SIGINT before it started"
    refute status.success?
  end

  def test_enqueue_mutation_timeout_with_unchanged_state_is_unknown
    result = run_mutation_timeout_cli("enqueue_timeout_unknown")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "timed out"
    assert_includes result.fetch(:stderr), "do not retry blindly"
  end

  def test_enqueue_mutation_timeout_reconciles_with_unknown_provenance
    result = run_mutation_timeout_cli("enqueue_timeout_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_unknown_reconciled_merge(
      JSON.parse(result.fetch(:stdout)), attempted_submission: "merge_queue"
    )
  end

  def test_non_object_enqueue_response_reconciles_an_exact_queue_entry
    result, = run_cli(mode: "enqueue_non_object_response_queued", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
  end

  def test_enqueue_transport_failure_does_not_dequeue_a_retargeted_entry
    assert_retargeted_queue_entry_is_not_dequeued("enqueue_transport_base_race")
  end

  def test_enqueue_graphql_errors_do_not_dequeue_a_retargeted_entry
    assert_retargeted_queue_entry_is_not_dequeued("enqueue_graphql_error_base_race")
  end

  def test_post_enqueue_base_mismatch_reports_unknown_without_dequeue
    result, log = run_cli(mode: "queue_base_race", merge_submission: merge_queue_policy)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "PR base moved"
    assert_includes result.fetch(:stderr), "automatic queue cleanup is unsafe"
    refute_includes log, "dequeuePullRequest"
  end

  def test_post_enqueue_replacement_entry_is_not_dequeued
    result, log = run_cli(mode: "queue_entry_replaced", merge_submission: merge_queue_policy)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "automatic queue cleanup is unsafe"
    refute_includes log, "dequeuePullRequest"
  end

  def test_post_enqueue_exact_replacement_reports_the_live_queue_entry
    result, log = run_cli(mode: "queue_entry_replaced_same_target", merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "MQE_2", payload.dig("merge_queue_entry", "id")
    assert_equal 7, payload.dig("merge_queue_entry", "position")
    refute_includes log, "dequeuePullRequest"
  end

  def test_expected_head_is_required
    result, log = run_cli(mode: "direct", include_expected_head: false)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--expected-head must be a full commit SHA"
    assert_empty log
  end

  def test_merge_assurance_receipt_flag_is_required_before_any_gh_call
    result, log = run_cli(mode: "direct", include_merge_assurance_receipt: false)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--merge-assurance-receipt is required"
    assert_empty log
  end

  def test_unavailable_merge_assurance_receipt_stops_before_any_gh_call
    result, log = run_cli(mode: "direct", receipt_mode: :missing)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "merge-assurance receipt is unavailable"
    assert_empty log
  end

  def test_authenticated_semantic_tracker_receipt_reaches_the_merge_mutation
    result, log = run_cli(mode: "queue", receipt_mode: :semantic, merge_submission: merge_queue_policy)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes log, "repos/owner/repo/issues/1"
    assert_includes log, "enqueuePullRequest"
  end

  def test_authenticated_tracker_receipt_evidence_is_exact_and_current
    cases = {
      semantic_read_missing: "authenticated tracker read count is malformed",
      semantic_read_binding_mismatch: "authenticated tracker read is malformed or mismatched",
      semantic_read_metadata_changed: "authenticated tracker read does not match the current issue",
      semantic_read_unknown: "receipt evidence contains UNKNOWN"
    }
    cases.each do |receipt_mode, expected_error|
      result, log = run_cli(mode: "direct", receipt_mode:)

      refute result.fetch(:status).success?, receipt_mode
      assert_includes result.fetch(:stderr), expected_error, receipt_mode
      refute_includes log, "mergePullRequest", receipt_mode
      refute_includes log, "enqueuePullRequest", receipt_mode
    end
  end

  def test_unknown_nested_in_receipt_evidence_stops_before_any_mutation
    result, log = run_cli(mode: "direct", receipt_mode: :nested_unknown)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "receipt evidence does not currently qualify"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_unavailable_autonomous_helper_result_stops_before_any_mutation
    result, log = run_cli(mode: "direct", receipt_mode: :autonomous_unavailable)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "receipt evidence does not currently qualify"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_evidence_digest_and_envelope_binding_mismatches_stop_before_any_gh_call
    {
      digest_mismatch: "evidence digest mismatch",
      binding_mismatch: "bindings or accounting do not match"
    }.each do |receipt_mode, expected|
      result, log = run_cli(mode: "direct", receipt_mode:)

      refute result.fetch(:status).success?, receipt_mode
      assert_includes result.fetch(:stderr), expected, receipt_mode
      assert_empty log, receipt_mode
    end
  end

  def test_stale_and_future_receipts_stop_before_any_gh_call
    { stale: "stale", future: "future" }.each do |receipt_mode, expected|
      result, log = run_cli(mode: "direct", receipt_mode:)

      refute result.fetch(:status).success?, receipt_mode
      assert_includes result.fetch(:stderr), expected, receipt_mode
      assert_empty log, receipt_mode
    end
  end

  def test_receipt_age_and_future_skew_boundaries_are_exactly_300_and_30_seconds
    runner = PrMergeSubmit::Runner.new
    now = Time.iso8601("2026-07-30T12:00:00Z")

    runner.send(:validate_receipt_freshness!, { "issued_at" => (now - 300).iso8601 }, now)
    runner.send(:validate_receipt_freshness!, { "issued_at" => (now + 30).iso8601 }, now)
    assert_raises(PrMergeSubmit::Error) do
      runner.send(:validate_receipt_freshness!, { "issued_at" => (now - 300.001).iso8601(3) }, now)
    end
    assert_raises(PrMergeSubmit::Error) do
      runner.send(:validate_receipt_freshness!, { "issued_at" => (now + 30.001).iso8601(3) }, now)
    end
  end

  def test_live_base_sha_mismatch_stops_before_any_mutation
    result, log = run_cli(mode: "initial_open_base_advanced")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "receipt base SHA mismatch"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_expected_base_is_required
    result, log = run_cli(mode: "direct", include_expected_base: false)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--expected-base must be a valid branch name"
    assert_empty log
  end

  def test_subject_beginning_with_at_is_rejected_before_any_gh_call
    result, log = run_cli(mode: "direct", subject: "@/etc/passwd")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--subject must not begin with '@'"
    assert_empty log
  end

  def test_body_beginning_with_at_is_rejected_before_any_gh_call
    result, log = run_cli(mode: "direct", body: "@~/.ssh/id_rsa")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--body must not begin with '@'"
    assert_empty log
  end

  def test_repo_with_a_leading_at_segment_is_rejected_before_any_gh_call
    ["@evil/repo", "owner/@evil"].each do |repo|
      result, log = run_cli(mode: "direct", repo:)

      refute result.fetch(:status).success?, "expected #{repo} to be rejected"
      assert_includes result.fetch(:stderr), "--repo must use OWNER/REPO form"
      assert_empty log
    end
  end

  private

  def guarded_direct_policy(
    executable: ".agents/bin/merge-pr-after-checks",
    method: "squash",
    rationale: "The repository guard revalidates policy immediately before direct squash."
  )
    {
      "mode" => "merge_queue_or_guarded_direct",
      "guarded_direct" => {
        "executable" => executable,
        "method" => method,
        "non_atomic_base" => {
          "acknowledged" => true,
          "rationale" => rationale
        }
      }
    }
  end

  def merge_queue_policy
    { "mode" => "merge_queue_only" }
  end

  def assert_reconciled_queue_merge(payload)
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal "repository_configured", payload.fetch("queue_method")
    assert_equal "MERGED", payload.fetch("post_submission_state")
    assert_equal MERGE_COMMIT_SHA, payload.fetch("merge_commit")
    refute payload.key?("reconciled_after_failure")
    refute payload.key?("method")
    assert_equal "MQE_1", payload.dig("merge_queue_entry", "id")
  end

  def assert_unknown_reconciled_merge(payload, attempted_submission:)
    assert_equal "already_merged", payload.fetch("submission")
    assert_equal "UNKNOWN", payload.fetch("merge_provenance")
    assert_equal attempted_submission, payload.fetch("attempted_submission")
    assert_equal MERGE_COMMIT_SHA, payload.fetch("merge_commit")
    assert_equal true, payload.fetch("reconciled_after_failure")
    refute payload.key?("method")
    refute payload.key?("queue_method")
  end

  def assert_retargeted_queue_entry_is_not_dequeued(mode)
    result, log = run_cli(mode:, merge_submission: merge_queue_policy)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "PR base moved"
    assert_includes result.fetch(:stderr), "cannot be safely dequeued"
    refute_includes log, "dequeuePullRequest"
  end

  # One mutation-timeout scenario, retried only while the harness raced itself.
  #
  # These scenarios hang the mutation alone: the metadata query before it and
  # the reconciliation query after it are supposed to succeed. When one of those
  # queries times out instead, the stub `gh` never finished starting inside the
  # deadline, the mutation was never issued (or its outcome never read live
  # state), and the run says nothing about the product -- a precondition miss,
  # not a failure. Retry it, the same way #230 handles the sibling hanging-gh
  # test in stale-assignment-sweep-test.rb.
  #
  # A real regression still fails: there the queries succeed, the loop stops on
  # the first attempt, and the caller's assertions run against a genuine
  # outcome. A precondition that never holds fails too, naming what went wrong.
  def run_mutation_timeout_cli(mode)
    result = nil
    MUTATION_TIMEOUT_ATTEMPTS.times do
      result, = run_cli(mode:, merge_submission: merge_queue_policy)
      break unless setup_query_timed_out?(result)
    end

    refute setup_query_timed_out?(result),
           "stub gh never started inside the #{MUTATION_TIMEOUT_GH_SECONDS}s deadline in " \
           "#{MUTATION_TIMEOUT_ATTEMPTS} attempts, so the #{mode} path was never exercised: " \
           "#{result.fetch(:stderr)}"
    result
  end

  # True when a gh call this scenario needs to SUCCEED timed out instead. Both
  # the initial fetch and the reconciliation fetch report through "could not
  # fetch PR metadata"; a timed-out mutation never does.
  def setup_query_timed_out?(result)
    stderr = result.fetch(:stderr)
    stderr.include?("could not fetch PR metadata") && stderr.include?("timed out")
  end

  def run_cli(
    mode:,
    repo: "owner/repo",
    head: HEAD_SHA,
    expected_head: HEAD_SHA,
    base: "main",
    expected_base: "main",
    url_host: HOST,
    include_expected_head: true,
    include_expected_base: true,
    subject: "Fix the thing (#42)",
    body: nil,
    include_merge_assurance_receipt: true,
    receipt_mode: :valid,
    after_stub_warmup: nil,
    trusted_policy_observer: nil,
    merge_commit_oid: MERGE_COMMIT_SHA,
    merge_submission: SOURCE_REPO_POLICY,
    policy_fixture: :present,
    receipt_base_sha: nil,
    guard_fixture: :executable,
    head_ref_name: "feature/test",
    interpreter_attack: false,
    bash_env_attack: false,
    guard_timeout_seconds: nil,
    interrupt_guard: false
  )
    Dir.mktmpdir("pr-merge-submit-test") do |dir|
      source_repo_policy = merge_submission.equal?(SOURCE_REPO_POLICY)
      if source_repo_policy
        merge_submission = {
          "mode" => queue_submission_mode?(mode) ? "merge_queue_only" : "direct"
        }
      end
      repo_root, base_sha, fixture_head = if source_repo_policy
                                            [File.expand_path("../../..", __dir__), BASE_SHA, HEAD_SHA]
                                          else
                                            prepare_consumer_repo(
                                              dir, merge_submission:, policy_fixture:, guard_fixture:
                                            )
                                          end
      if !source_repo_policy &&
         (mode.start_with?("guard") || mode == "hichee_replay")
        head = fixture_head
        expected_head = fixture_head
      end
      trusted_policy_observer&.call(
        YAML.safe_load(
          run_git!(repo_root, "show", "#{base_sha}:.agents/agent-workflow.yml"),
          permitted_classes: [], permitted_symbols: [], aliases: false
        )
      )
      log_path = File.join(dir, "gh.log")
      guard_log_path = File.join(dir, "guard.log")
      guard_marker_path = File.join(dir, "guard-called")
      attacker_log_path = File.join(dir, "attacker-called")
      descendant_pid_path = File.join(dir, "descendant.pid")
      File.write(File.join(dir, "guard-mode"), mode)
      File.write(
        File.join(dir, "guard-live-path"),
        File.join(repo_root, ".agents/bin/merge-pr-after-checks")
      )
      interpreter_attack_path = prepare_interpreter_attack(dir, attacker_log_path, guard_marker_path) if
        interpreter_attack
      bash_env_attack_path = prepare_bash_env_attack(dir, attacker_log_path) if bash_env_attack
      gh_path = File.join(dir, "gh")
      File.write(
        gh_path,
        fake_gh(
          mode:, head:, base:, base_sha: receipt_base_sha || base_sha,
          url_host:, repo:, merge_commit_oid:, head_ref_name:
        )
      )
      FileUtils.chmod(0o755, gh_path)
      warm_stub(dir, gh_path) if mode.include?("timeout")
      after_stub_warmup&.call
      receipt_path = File.join(dir, "merge-assurance-receipt.json")
      unless receipt_mode == :missing
        write_merge_assurance_receipt(
          receipt_path, mode: receipt_mode, repo:, head: expected_head,
                        base_ref: expected_base, base_sha: receipt_base_sha || base_sha,
                        host: HOST, pr_number: 42, gh_dir: dir
        )
      end
      environment = cli_environment(
        dir, log_path, mode,
        guard_log_path:, guard_marker_path:, attacker_log_path:,
        guard_live_path: File.join(repo_root, ".agents/bin/merge-pr-after-checks"),
        interpreter_attack_path:, bash_env_attack_path:,
        guard_timeout_seconds:, descendant_pid_path:
      )
      arguments = cli_arguments(
        repo, expected_head, include_expected_head, include_expected_base,
        expected_base:, subject:, body:, include_merge_assurance_receipt:, receipt_path:, gh_path:
      )
      result = if interrupt_guard
                 capture_with_interrupt(
                   environment, arguments, chdir: repo_root, wait_path: guard_marker_path
                 )
               else
                 stdout, stderr, status = Open3.capture3(environment, *arguments, chdir: repo_root)
                 { stdout:, stderr:, status: }
               end
      log = File.exist?(log_path) ? File.read(log_path) : ""
      guard_log = File.exist?(guard_log_path) ? File.read(guard_log_path) : ""
      attacker_log = File.exist?(attacker_log_path) ? File.read(attacker_log_path) : ""
      descendant_pid = read_descendant_pid(descendant_pid_path)
      [result, log, guard_log, attacker_log, fixture_head, descendant_pid]
    end
  end

  def queue_submission_mode?(mode)
    mode == "already_queued" || mode == "already_queued_base_advanced" ||
      mode == "already_queued_with_commit" || mode.start_with?("queue") ||
      mode.start_with?("enqueue")
  end

  def capture_with_interrupt(environment, arguments, chdir:, wait_path:)
    Open3.popen3(environment, *arguments, chdir:) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stdout_reader = Thread.new { stdout.read }
      stderr_reader = Thread.new { stderr.read }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until File.exist?(wait_path)
        raise "guard did not start before interrupt deadline" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
      Process.kill("INT", wait_thread.pid)
      {
        stdout: stdout_reader.value,
        stderr: stderr_reader.value,
        status: wait_thread.value
      }
    end
  end

  def run_cli_with_interrupt(mode:, wait_for: "enqueuePullRequest", after_stub_warmup: nil)
    Dir.mktmpdir("pr-merge-submit-interrupt-test") do |dir|
      repo_root, base_sha, = prepare_consumer_repo(
        dir,
        merge_submission: { "mode" => "merge_queue_only" },
        policy_fixture: :present,
        guard_fixture: :executable
      )
      log_path = File.join(dir, "gh.log")
      gh_path = File.join(dir, "gh")
      File.write(
        gh_path,
        fake_gh(
          mode:, head: HEAD_SHA, base: "main", base_sha:,
          url_host: HOST, repo: "owner/repo"
        )
      )
      FileUtils.chmod(0o755, gh_path)
      warm_stub(dir, gh_path)
      after_stub_warmup&.call
      receipt_path = File.join(dir, "merge-assurance-receipt.json")
      write_merge_assurance_receipt(
        receipt_path, mode: :valid, repo: "owner/repo", head: HEAD_SHA,
                      base_ref: "main", base_sha:, host: HOST, pr_number: 42, gh_dir: dir
      )
      result = Open3.popen3(
        cli_environment(
          dir, log_path, mode,
          guard_log_path: File.join(dir, "guard.log"),
          guard_marker_path: File.join(dir, "guard-called")
        ),
        *cli_arguments(
          "owner/repo", HEAD_SHA, true, true,
          include_merge_assurance_receipt: true, receipt_path:, gh_path:
        ),
        chdir: repo_root
      ) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        until File.exist?(log_path) && File.read(log_path).include?(wait_for)
          raise "gh request did not start before interrupt deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.01
        end
        Process.kill("INT", wait_thread.pid)
        {
          stdout: stdout_reader.value,
          stderr: stderr_reader.value,
          status: wait_thread.value
        }
      end
      log = File.exist?(log_path) ? File.read(log_path) : ""
      [result, log]
    end
  end

  # Pay the stub's first-execution cost before anything is being timed.
  #
  # macOS assesses a newly written executable the first time it runs. Measured
  # on this stub, spawned exactly as the product spawns gh: the first exec of a
  # fresh file is p50 0.205s but has a 9.9s tail (2 of 60 samples over 2s),
  # while re-executing the same file is p50 0.075s, max 0.101s. That cold tail,
  # not the product, is what blew the gh deadline in #222 and is what any
  # deadline in this file would otherwise have to out-wait.
  #
  # The warm-up call matches no request branch in the stub, so it changes no
  # stub state, and its log goes to a throwaway path so GH_LOG still records
  # only the gh calls the run under test actually made.
  def warm_stub(dir, gh_path)
    system(
      { "GH_LOG" => File.join(dir, "warmup.log") },
      gh_path, "--version", out: File::NULL, err: File::NULL
    )
  end

  # An empty/missing file means the mode's stub never reached the point where
  # it records a descendant pid (e.g. the metadata_timeout_descendant stub was
  # killed before its fork()) -- a precondition miss for the caller to retry,
  # not a value to report as terminated. See #238.
  def read_descendant_pid(path)
    return nil unless File.exist?(path)

    contents = File.read(path).strip
    contents.empty? ? nil : Integer(contents)
  end

  # Poll until the pid is gone (ESRCH), mirroring
  # stale-assignment-sweep-test.rb#child_terminated?. A short grace avoids a
  # race with the descendant's own SIGKILL-driven teardown.
  def descendant_terminated?(pid)
    deadline = Time.now + 5
    loop do
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return true
      rescue Errno::EPERM
        return false
      end
      return false if Time.now >= deadline

      sleep 0.05
    end
  end

  def cli_environment(
    dir, log_path, mode,
    guard_log_path:, guard_marker_path:,
    attacker_log_path: File.join(dir, "attacker-called"),
    guard_live_path: "",
    interpreter_attack_path: nil,
    bash_env_attack_path: nil,
    guard_timeout_seconds: nil,
    descendant_pid_path: File.join(dir, "descendant.pid")
  )
    path = [interpreter_attack_path, dir, ENV.fetch("PATH")].compact.join(File::PATH_SEPARATOR)
    environment = {
      "PATH" => path,
      "GH_LOG" => log_path,
      "PR_TEST_MODE" => mode,
      "PR_TEST_GUARD_LOG" => guard_log_path,
      "PR_TEST_GUARD_MARKER" => guard_marker_path,
      "PR_TEST_ATTACKER_MARKER" => attacker_log_path,
      "PR_TEST_GUARD_LIVE_PATH" => guard_live_path,
      "PR_TEST_DESCENDANT_PID_FILE" => descendant_pid_path,
      "PR_MERGE_SUBMIT_GH_TIMEOUT_SECONDS" => gh_timeout_seconds_for(mode)
    }
    environment["PR_MERGE_SUBMIT_GUARD_TIMEOUT_SECONDS"] = guard_timeout_seconds if guard_timeout_seconds
    environment["BASH_ENV"] = bash_env_attack_path if bash_env_attack_path
    environment
  end

  def prepare_interpreter_attack(dir, attacker_log_path, guard_marker_path)
    attack_dir = File.join(dir, "checkout-controlled-bin")
    FileUtils.mkdir_p(attack_dir)
    attacker = File.join(attack_dir, "ruby")
    File.write(
      attacker,
      <<~RUBY
        #!#{RbConfig.ruby}
        File.write(#{attacker_log_path.inspect}, "checkout-controlled interpreter executed\n")
        File.write(#{guard_marker_path.inspect}, "called\n")
      RUBY
    )
    FileUtils.chmod(0o755, attacker)
    attack_dir
  end

  def prepare_bash_env_attack(dir, attacker_log_path)
    attack_path = File.join(dir, "checkout-controlled-bash-env")
    File.write(attack_path, "printf 'checkout-controlled BASH_ENV executed\\n' > #{attacker_log_path}\n")
    attack_path
  end

  def gh_timeout_seconds_for(mode)
    return NO_TIMEOUT_GH_SECONDS unless mode.include?("timeout")
    return GUARD_TIMEOUT_GH_SECONDS if mode == "guard_timeout"
    return MUTATION_TIMEOUT_GH_SECONDS if MUTATION_TIMEOUT_MODES.include?(mode)
    return DESCENDANT_TIMEOUT_GH_SECONDS if mode == "metadata_timeout_descendant"

    SOLE_CALL_TIMEOUT_GH_SECONDS
  end

  def cli_arguments(
    repo, expected_head, include_expected_head, include_expected_base,
    gh_path:,
    expected_base: "main",
    subject: "Fix the thing (#42)", body: nil,
    include_merge_assurance_receipt: true, receipt_path: nil
  )
    runner = <<~RUBY
      load #{SCRIPT.inspect}
      test_environment = %w[GH_LOG PR_TEST_GUARD_MARKER PR_TEST_DESCENDANT_PID_FILE].to_h { |name| [name, ENV.fetch(name)] }
      runner = PrMergeSubmit::Runner.new(system_tools: { "gh" => #{gh_path.inspect} })
      runner.define_singleton_method(:system_tool_test_environment) { test_environment }
      exit runner.run(ARGV)
    RUBY
    args = [
      RbConfig.ruby, "-e", runner, "42", "--repo", repo, "--host", HOST,
      "--method", "squash", "--subject", subject
    ]
    args.concat(["--body", body]) unless body.nil?
    args.concat(["--expected-head", expected_head]) if include_expected_head
    args.concat(["--expected-base", expected_base]) if include_expected_base
    args.concat(["--merge-assurance-receipt", receipt_path]) if include_merge_assurance_receipt
    args
  end

  def write_merge_assurance_receipt(
    path, mode:, repo:, head:, base_ref:, base_sha:, host:, pr_number:, gh_dir:
  )
    now = Time.now.utc
    checked_at = (now - 1).iso8601
    scope = lambda do |name, rows|
      {
        "state" => rows.empty? ? "NOT_APPLICABLE" : "READY",
        "source" => "github.test.#{name}",
        "complete" => true,
        "head_sha" => head,
        "rows" => rows,
        "checked_at" => checked_at
      }
    end
    ci_result = {
      "contract" => "pr-ci-readiness",
      "version" => 2,
      "context" => { "host" => host },
      "repo" => repo,
      "pr" => pr_number,
      "head_sha" => head,
      "checked_at" => checked_at,
      "verdict" => "READY",
      "ordinary_verdict" => "READY",
      "scopes" => {
        "required_status_check_rollup" => scope.call(
          "required", [{ "name" => "required", "bucket" => "pass" }]
        ),
        "github_actions" => scope.call(
          "actions", [{ "name" => "CI", "status" => "completed", "conclusion" => "success" }]
        ),
        "dependabot" => scope.call("dependabot", []),
        "other" => scope.call("other", [])
      }
    }
    autonomous_result = {
      "verdict" => "autonomous-merge-eligible",
      "head_sha" => head,
      "policy_provenance" => "git:#{base_sha}",
      "helper_provenance" => "trusted-base:#{base_sha}",
      "helper_trust" => {
        "status" => "mechanically-verified",
        "manifest" => {
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
      },
      "metrics" => {
        "changed_files" => 1,
        "changed_lines" => 2,
        "commits" => 1,
        "reviewed_heads" => 0
      },
      "path_matches" => [],
      "safe_class" => "tests",
      "triggered_gates" => [],
      "shadow_triggered_gates" => [],
      "shadow_evidence_unknown" => [],
      "rollback_assessment" => "code-only-rollback-established",
      "human_decision_evidence" => { "status" => "none" },
      "evidence_failures" => []
    }
    tracker = semantic_tracker(host:, repo:, pr_number:)
    semantic = mode.to_s.start_with?("semantic")
    selected_hosted = mode.to_s.start_with?("selected_hosted")
    selected_hosted_run = {
      "provider" => "circleci",
      "run_id" => "selected-workflow"
    }
    context = {
      "contract" => "merge-assurance-context",
      "version" => 1,
      "host" => host,
      "repo" => repo,
      "pr" => pr_number,
      "base" => { "ref" => base_ref, "sha" => base_sha },
      "head_sha" => head,
      "authority" => "auto_merge_when_gates_pass",
      "diff_identity" => "e" * 64,
      "human_merge_decision" => nil,
      "walkthrough" => nil,
      "semantic_github_actions_change" => semantic,
      "selected_hosted_runs" => selected_hosted ? [selected_hosted_run] : [],
      "operations" => semantic ? [tracker] : []
    }
    selected_hosted_receipts = MergeAssurance.empty_selected_hosted_ci_receipts
    if selected_hosted
      selected_hosted_receipts["records"] = [{
        **selected_hosted_run,
        "repository" => repo,
        "pr" => pr_number,
        "head_sha" => head,
        "selected_at" => checked_at,
        "terminal_result" => "success"
      }]
    end
    receipt = with_fake_gh(gh_dir) do
      MergeAssurance.assess(
        ci_result:, autonomous_result:, context:,
        selected_hosted_ci_receipts: selected_hosted_receipts,
        now:
      )
    end
    raise "test receipt did not qualify: #{receipt.inspect}" unless receipt["eligible"]

    case mode
    when :nested_unknown
      receipt.dig("evidence", "autonomous_result", "helper_trust", "manifest")["note"] = "UNKNOWN"
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    when :autonomous_unavailable
      receipt["evidence"]["autonomous_result"] = nil
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    when :digest_mismatch
      receipt["evidence_digest"] = "sha256:#{'0' * 64}"
    when :binding_mismatch
      receipt["bindings"]["diff_identity"] = "f" * 64
    when :stale
      receipt["issued_at"] = (now - 301).iso8601
    when :future
      receipt["issued_at"] = (now + 60).iso8601
    when :semantic_read_missing
      receipt["evidence"]["authenticated_tracker_reads"] = []
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    when :semantic_read_binding_mismatch
      receipt.dig("evidence", "authenticated_tracker_reads", 0)["head_sha"] = MOVED_SHA
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    when :semantic_read_metadata_changed
      receipt.dig(
        "evidence", "authenticated_tracker_reads", 0, "issue_metadata"
      )["body_digest"] = "sha256:#{'f' * 64}"
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    when :semantic_read_unknown
      receipt.dig(
        "evidence", "authenticated_tracker_reads", 0, "issue_metadata"
      )["title"] = "UNKNOWN"
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    when :selected_hosted_missing
      receipt.dig("evidence", "selected_hosted_ci_receipts")["records"] = []
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    when :selected_hosted_cancelled, :selected_hosted_failed, :selected_hosted_nonterminal
      receipt.dig(
        "evidence", "selected_hosted_ci_receipts", "records", 0
      )["terminal_result"] = mode.to_s.delete_prefix("selected_hosted_")
      receipt["evidence_digest"] = MergeAssurance.evidence_digest(receipt.fetch("evidence"))
    end
    File.write(path, JSON.generate(receipt))
  end

  def with_fake_gh(dir)
    original_path = ENV.fetch("PATH")
    original_log = ENV["GH_LOG"]
    ENV["PATH"] = "#{dir}:#{original_path}"
    ENV["GH_LOG"] = File.join(dir, "receipt-gh.log")
    yield
  ensure
    ENV["PATH"] = original_path
    original_log ? ENV["GH_LOG"] = original_log : ENV.delete("GH_LOG")
  end

  def semantic_tracker(host:, repo:, pr_number:)
    {
      "type" => "semantic-github-actions-tracker",
      "tracker" => "https://#{host}/#{repo}/issues/1",
      "source_pr" => "https://#{host}/#{repo}/pull/#{pr_number}",
      "changed_files" => [".github/workflows/ci.yml"],
      "exercise" => "Open a secondary verification PR after merge.",
      "expected_evidence" => "The dynamic matrix checks appear on the verification PR.",
      "cleanup_instructions" => "Close the verification-only PR without merging.",
      "owner" => "maintainer"
    }
  end

  def semantic_issue_payload(host:, repo:, pr_number:, head:)
    tracker = semantic_tracker(host:, repo:, pr_number:)
    {
      "id" => 101,
      "node_id" => "I_kwDOExample",
      "number" => 1,
      "url" => "https://#{host}/api/v3/repos/#{repo}/issues/1",
      "html_url" => tracker["tracker"],
      "state" => "open",
      "title" => "Exercise semantic GitHub Actions behavior",
      "body" => [
        "Verify the semantic workflow behavior after merge.",
        "semantic-tracker-source-pr: #{tracker['source_pr']}",
        "semantic-tracker-head-sha: #{head}",
        "semantic-tracker-diff-identity: #{'e' * 64}",
        "semantic-tracker-operation-digest: " \
          "#{MergeAssurance.semantic_tracker_operation_digest(tracker)}"
      ].join("\n"),
      "updated_at" => Time.now.utc.iso8601
    }
  end

  def prepare_consumer_repo(dir, merge_submission:, policy_fixture:, guard_fixture:)
    root = File.join(dir, "consumer")
    FileUtils.mkdir_p(File.join(root, ".agents/bin"))
    policy = { "base_branch" => "main" }
    policy["merge_submission"] = merge_submission unless merge_submission.nil?
    policy_path = File.join(root, ".agents/agent-workflow.yml")
    case policy_fixture
    when :present
      File.write(policy_path, policy.to_yaml)
    when :malformed
      File.write(policy_path, "merge_submission: [\n")
    when :missing
      nil
    else
      raise "unknown policy fixture: #{policy_fixture.inspect}"
    end
    File.write(File.join(root, "README.md"), "consumer fixture\n")

    executable = merge_submission.dig("guarded_direct", "executable") if merge_submission.is_a?(Hash)
    guard_path = File.join(root, executable.to_s)
    if guard_fixture != :missing && executable.to_s.match?(%r{\A\.agents/bin/[A-Za-z0-9_.-]+\z})
      guard_body = case guard_fixture
                   when :executable, :non_executable, :modified_after_commit
                     fake_guard
                   when :bash_executable
                     fake_bash_guard(dir)
                   when :checkout_interpreter
                     checkout_interpreter = File.join(root, "checkout-interpreter")
                     File.write(checkout_interpreter, trusted_checkout_interpreter)
                     FileUtils.chmod(0o755, checkout_interpreter)
                     "#!#{checkout_interpreter}\n"
                   when :delegating
                     fake_delegating_guard
                   when :launch_eacces
                     blocked_interpreter = File.join(root, "non-executable-guard-interpreter")
                     File.write(blocked_interpreter, "#!/bin/sh\nexit 0\n")
                     File.chmod(0o644, blocked_interpreter)
                     "#!#{blocked_interpreter}\n"
                   when :launch_enoent
                     "#!#{File.join(root, 'missing-guard-interpreter')}\n"
                   else
                     raise "unknown guard fixture: #{guard_fixture.inspect}"
                   end
      File.write(guard_path, guard_body)
      FileUtils.chmod(guard_fixture == :non_executable ? 0o644 : 0o755, guard_path)
    end

    run_git!(root, "init", "-q")
    if guard_fixture == :delegating
      secondary_path = File.join(root, "script/merge_pr_after_checks")
      FileUtils.mkdir_p(File.dirname(secondary_path))
      File.write(secondary_path, trusted_base_secondary)
      FileUtils.chmod(0o755, secondary_path)
    end
    run_git!(root, "add", "--all")
    run_git!(root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "fixture")
    base_sha = run_git!(root, "rev-parse", "HEAD").strip
    File.open(guard_path, "a") { |file| file.write("# changed after trusted base\n") } if
      guard_fixture == :modified_after_commit && File.file?(guard_path)
    if guard_fixture == :delegating
      File.write(File.join(root, "script/merge_pr_after_checks"), pr_head_secondary)
      FileUtils.chmod(0o755, File.join(root, "script/merge_pr_after_checks"))
      run_git!(root, "add", "--all")
      run_git!(
        root, "-c", "user.name=Test", "-c", "user.email=test@example.com",
        "commit", "-qm", "untrusted PR head"
      )
    elsif guard_fixture == :checkout_interpreter
      File.write(File.join(root, "checkout-interpreter"), pr_head_checkout_interpreter)
      FileUtils.chmod(0o755, File.join(root, "checkout-interpreter"))
      run_git!(root, "add", "--all")
      run_git!(
        root, "-c", "user.name=Test", "-c", "user.email=test@example.com",
        "commit", "-qm", "untrusted interpreter replacement"
      )
    end
    [root, base_sha, run_git!(root, "rev-parse", "HEAD").strip]
  end

  def run_git!(root, *args)
    environment = {
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_CONFIG_PARAMETERS" => nil,
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "commit.gpgSign",
      "GIT_CONFIG_VALUE_0" => "false"
    }
    stdout, stderr, status = Open3.capture3(environment, "git", *args, chdir: root)
    raise "git fixture failed: #{stderr}" unless status.success?

    stdout
  end

  def fake_guard
    attacker_guard = <<~RUBY
      #!#{RbConfig.ruby}
      receipt = ARGV.fetch(ARGV.index("--merge-assurance-receipt") + 1)
      test_root = File.dirname(receipt)
      File.write(File.join(test_root, "attacker-called"), "attacker bytes executed\n")
      File.write(File.join(test_root, "guard-called"), "called\n")
    RUBY
    <<~RUBY
      #!/usr/bin/env ruby
      receipt = ARGV.fetch(ARGV.index("--merge-assurance-receipt") + 1)
      test_root = File.dirname(receipt)
      mode = File.read(File.join(test_root, "guard-mode"))
      if mode == "guard_path_swap"
        live_path = File.read(File.join(test_root, "guard-live-path"))
        File.write(live_path, #{attacker_guard.inspect})
        File.chmod(0o755, live_path)
      end
      File.open(File.join(test_root, "guard.log"), "a") { |file| file.puts(ARGV.join("\n")) }
      File.write(File.join(test_root, "guard-called"), "called\n")
      sleep 5 if %w[guard_timeout guard_interrupt].include?(mode)
      if %w[guard_failure guard_failure_merged].include?(mode)
        warn "repository guard rejected direct submission"
        exit 1
      end
      puts "guard output is not merge proof"
    RUBY
  end

  def fake_delegating_guard
    <<~RUBY
      #!/usr/bin/env ruby
      exec File.join(Dir.pwd, "script/merge_pr_after_checks"), *ARGV
    RUBY
  end

  def fake_bash_guard(dir)
    <<~BASH
      #!/bin/bash
      printf '%s\\n' "$@" >> #{File.join(dir, 'guard.log')}
      printf 'called\\n' > #{File.join(dir, 'guard-called')}
    BASH
  end

  def trusted_checkout_interpreter
    <<~RUBY
      #!#{RbConfig.ruby}
      exec #{RbConfig.ruby.inspect}, *ARGV
    RUBY
  end

  def pr_head_checkout_interpreter
    <<~RUBY
      #!#{RbConfig.ruby}
      receipt = ARGV.fetch(ARGV.index("--merge-assurance-receipt") + 1)
      test_root = File.dirname(receipt)
      File.write(File.join(test_root, "attacker-called"), "PR interpreter executed\n")
      File.write(File.join(test_root, "guard-called"), "called\n")
    RUBY
  end

  def trusted_base_secondary
    <<~RUBY
      #!/usr/bin/env ruby
      receipt = ARGV.fetch(ARGV.index("--merge-assurance-receipt") + 1)
      test_root = File.dirname(receipt)
      branch = `git rev-parse --abbrev-ref HEAD`.strip
      head = `git rev-parse HEAD`.strip
      head_dependency = `git show HEAD:script/merge_pr_after_checks`
      File.open(File.join(test_root, "guard.log"), "a") do |file|
        file.puts("delegated trusted-base dependency", branch, head, head_dependency, ARGV)
      end
      File.write(File.join(test_root, "guard-called"), "called\n")
    RUBY
  end

  def pr_head_secondary
    <<~RUBY
      #!/usr/bin/env ruby
      receipt = ARGV.fetch(ARGV.index("--merge-assurance-receipt") + 1)
      test_root = File.dirname(receipt)
      File.write(File.join(test_root, "attacker-called"), "PR-only dependency executed\n")
      File.write(File.join(test_root, "guard-called"), "called\n")
    RUBY
  end

  def fake_gh(
    mode:, head:, base:, base_sha:, url_host:, repo:, head_ref_name: "feature/test",
    merge_commit_oid: MERGE_COMMIT_SHA
  )
    head_ref_entry = if head_ref_name == :missing
                       ""
                     else
                       %("headRefName" => #{head_ref_name.inspect},)
                     end
    semantic_issue = semantic_issue_payload(
      host: HOST, repo: "owner/repo", pr_number: 42, head:
    )
    queue_payload = if mode == "queue_missing_entry"
                      { "data" => { "enqueuePullRequest" => { "mergeQueueEntry" => nil } } }
                    else
                      {
                        "data" => {
                          "enqueuePullRequest" => {
                            "mergeQueueEntry" => {
                              "id" => "MQE_1", "position" => 1, "state" => "QUEUED",
                              "estimatedTimeToMerge" => "2026-07-20T15:00:00Z"
                            }
                          }
                        }
                      }
                    end
    <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      File.open(ENV.fetch("GH_LOG"), "a") do |file|
        file.puts("GH_HOST=\#{ENV.fetch('GH_HOST', '')} \#{ARGV.join(' ')}")
      end
      if ARGV.include?("repos/owner/repo/issues/1")
        puts #{JSON.generate(semantic_issue).inspect}
        exit 0
      end

      if ARGV.any? { |arg| arg == "number=42" }
        if #{mode.inspect} == "metadata_interrupt_exit_zero"
          trap("INT") { exit 0 }
          sleep 5
        end
        if #{mode.inspect} == "metadata_timeout_descendant"
          descendant_pid = fork do
            trap("TERM", "IGNORE")
            sleep 30
            exit! 0
          end
          File.write(ENV.fetch("PR_TEST_DESCENDANT_PID_FILE"), descendant_pid.to_s)
          sleep 30
        end
        sleep 5 if #{mode.inspect} == "metadata_timeout"
        query_count_path = ENV.fetch("GH_LOG") + ".queries"
        query_count = File.exist?(query_count_path) ? File.read(query_count_path).to_i : 0
        File.write(query_count_path, (query_count + 1).to_s)
        current_mode = #{mode.inspect}
        guard_called = File.exist?(ENV.fetch("PR_TEST_GUARD_MARKER"))
        queue_enabled = case current_mode
                        when "queue", "queue_fast_merged", "queue_fast_merged_base_advanced",
                             "queue_missing_entry", "already_queued", "already_queued_base_advanced",
                             "already_queued_with_commit",
                             "enqueue_transport_queued", "enqueue_transport_merged",
                             "enqueue_transport_queued_with_commit",
                             "enqueue_graphql_error", "enqueue_graphql_error_merged",
                             "enqueue_graphql_error_merged_queued",
                             "enqueue_graphql_error_queued_with_commit",
                             "enqueue_timeout_unknown", "enqueue_timeout_merged",
                             "enqueue_interrupt_unknown", "enqueue_interrupt_exit_zero",
                             "enqueue_transport_base_race", "enqueue_graphql_error_base_race",
                             "enqueue_transport_queued_base_advanced", "queue_post_queued_base_advanced",
                             "queue_post_queued_with_commit",
                             "enqueue_non_object_response_queued", "queue_base_race",
                             "queue_entry_replaced", "queue_entry_replaced_same_target" then true
                        when "direct_queue_race" then query_count.positive?
                        when "direct_graphql_error_queue_enabled" then query_count >= 2
                        else false
                        end
        queued = case current_mode
                 when "already_queued", "already_queued_base_advanced",
                      "already_queued_with_commit" then true
                 when "queue", "enqueue_transport_queued", "enqueue_non_object_response_queued",
                      "enqueue_transport_queued_base_advanced",
                      "enqueue_transport_queued_with_commit",
                      "enqueue_graphql_error_queued_with_commit",
                      "enqueue_graphql_error_merged_queued",
                      "queue_entry_replaced_same_target",
                      "queue_post_queued_base_advanced",
                      "queue_post_queued_with_commit" then query_count.positive?
                 when "queue_base_race", "enqueue_transport_base_race",
                      "enqueue_graphql_error_base_race", "queue_entry_replaced" then query_count == 1
                 when "direct_graphql_error_in_queue" then query_count >= 2
                 else false
                 end
        merged_after_mutation = [
          "enqueue_transport_merged", "enqueue_graphql_error_merged",
          "enqueue_graphql_error_merged_queued",
          "enqueue_timeout_merged", "queue_fast_merged", "queue_fast_merged_base_advanced"
        ].include?(current_mode)
        guarded_direct_merged = %w[
          guard_success guard_path_swap hichee_replay guard_failure_merged
        ].include?(current_mode) &&
                                guard_called
        direct_attempted = File.read(ENV.fetch("GH_LOG")).include?("mergePullRequest")
        directly_merged = %w[
          direct_transport_merged direct_graphql_error_merged direct_response_invalid_merged
        ].include?(current_mode) && direct_attempted
        merged = ["already_merged", "already_merged_base_advanced"].include?(current_mode) ||
                 (merged_after_mutation && query_count.positive?) || guarded_direct_merged || directly_merged
        base_race_modes = [
          "queue_base_race", "queue_entry_replaced", "enqueue_transport_base_race",
          "enqueue_graphql_error_base_race"
        ]
        live_base = if base_race_modes.include?(current_mode) && query_count.positive?
                      "release"
                    else
                      #{base.inspect}
                    end
        base_advanced_modes = %w[
          already_merged_base_advanced
          initial_open_base_advanced already_queued_base_advanced
          queue_fast_merged_base_advanced
          queue_post_queued_base_advanced enqueue_transport_queued_base_advanced
        ]
        initially_advanced_modes = %w[
          already_merged_base_advanced initial_open_base_advanced already_queued_base_advanced
        ]
        live_base_oid = if base_advanced_modes.include?(current_mode) &&
                           (initially_advanced_modes.include?(current_mode) || query_count.positive?)
                          #{ADVANCED_BASE_SHA.inspect}
                        else
                          #{base_sha.inspect}
                        end
        queue_entry = if queued
                        {
                          "id" => current_mode.start_with?("queue_entry_replaced") ? "MQE_2" : "MQE_1",
                          "position" => current_mode == "queue_entry_replaced_same_target" ? 7 : 1,
                          "state" => "QUEUED",
                          "estimatedTimeToMerge" => 60
                        }
                      end
        puts JSON.generate(
          "data" => {
            "repository" => {
              "pullRequest" => {
                "id" => "PR_42",
                #{head_ref_entry}
                "headRefOid" => if current_mode == "guard_head_moved" && guard_called
                                  #{MOVED_SHA.inspect}
                                else
                                  #{head.inspect}
                                end,
                "baseRefName" => live_base,
                "baseRefOid" => live_base_oid,
                "state" => merged ? "MERGED" : "OPEN",
                "isDraft" => false,
                "url" => "https://#{url_host}/#{repo}/pull/42",
                "merged" => merged,
                "mergedAt" => merged ? "2026-07-20T15:00:00Z" : nil,
                "mergeCommit" => if merged || %w[
                  already_queued_with_commit queue_post_queued_with_commit
                  enqueue_transport_queued_with_commit enqueue_graphql_error_queued_with_commit
                ].include?(current_mode)
                                   { "oid" => #{merge_commit_oid.inspect} }
                                 end,
                "isInMergeQueue" => queued,
                "mergeQueueEntry" => queue_entry,
                "isMergeQueueEnabled" => queue_enabled
              }
            }
          }
        )
        exit 0
      end

      if ARGV.any? { |arg| arg.include?("enqueuePullRequest") }
        sleep 5 if #{mode.inspect} == "enqueue_interrupt_unknown"
        if #{mode.inspect} == "enqueue_interrupt_exit_zero"
          trap("INT") do
            puts #{JSON.generate(queue_payload).inspect}
            exit 0
          end
          sleep 5
        end
        if ["enqueue_timeout_unknown", "enqueue_timeout_merged"].include?(#{mode.inspect})
          sleep 5
        end
        if [
          "enqueue_transport_queued", "enqueue_transport_merged", "enqueue_transport_base_race",
          "enqueue_transport_queued_base_advanced", "enqueue_transport_queued_with_commit"
        ].include?(#{mode.inspect})
          warn "connection reset after request"
          exit 1
        end
        if [
          "enqueue_graphql_error", "enqueue_graphql_error_merged", "enqueue_graphql_error_merged_queued",
          "enqueue_graphql_error_base_race",
          "enqueue_graphql_error_queued_with_commit"
        ].include?(#{mode.inspect})
          puts JSON.generate(
            "data" => { "enqueuePullRequest" => { "mergeQueueEntry" => nil } },
            "errors" => [{ "message" => "nested field resolution failed" }]
          )
          exit 1
        end
        if #{mode.inspect} == "enqueue_non_object_response_queued"
          puts JSON.generate(nil)
          exit 0
        end
        puts #{JSON.generate(queue_payload).inspect}
        exit 0
      end

      if ARGV.any? { |arg| arg.include?("mergePullRequest") }
        if ["direct_transport_merged", "direct_transport_unknown"].include?(#{mode.inspect})
          warn "connection reset after direct merge request"
          exit 1
        end
        if [
          "direct_graphql_error_merged", "direct_graphql_error_queue_enabled",
          "direct_graphql_error_in_queue", "direct_graphql_error_unknown"
        ].include?(#{mode.inspect})
          puts JSON.generate(
            "data" => { "mergePullRequest" => { "pullRequest" => nil } },
            "errors" => [{ "message" => "nested field resolution failed" }]
          )
          exit 1
        end
        response_head = if ["direct_response_invalid_merged", "direct_response_invalid_unknown"].include?(#{mode.inspect})
                          #{MOVED_SHA.inspect}
                        else
                          #{head.inspect}
                        end
        puts JSON.generate(
          "data" => {
            "mergePullRequest" => {
              "pullRequest" => {
                "headRefOid" => response_head,
                "baseRefName" => #{base.inspect},
                "baseRefOid" => #{base_sha.inspect},
                "state" => "MERGED",
                "merged" => true,
                "mergedAt" => "2026-07-20T15:00:00Z",
                "url" => "https://#{url_host}/#{repo}/pull/42",
                "mergeCommit" => { "oid" => #{merge_commit_oid.inspect} }
              }
            }
          }
        )
        exit 0
      end

      warn "unexpected gh invocation: \#{ARGV.join(' ')}"
      exit 1
    RUBY
  end
end
