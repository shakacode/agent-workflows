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
  HOST = "ghe.example:8443"
  ADVANCED_BASE_SHA = "d" * 40
  MERGE_COMMIT_SHA = "c" * 40

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
  # The remaining timeout modes hang their only gh call, so a startup-induced
  # timeout is the same observable event as the hang under test. They keep the
  # tight deadline that makes their elapsed-time bounds meaningful.
  SOLE_CALL_TIMEOUT_GH_SECONDS = "0.1"
  NO_TIMEOUT_GH_SECONDS = "60"
  # Attempts allowed for a mutation-timeout scenario whose setup query raced.
  MUTATION_TIMEOUT_ATTEMPTS = 3

  def test_open_queue_disabled_pr_fails_closed_before_direct_merge_mutation
    result, log = run_cli(mode: "direct")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "direct merge is unsupported"
    assert_includes result.fetch(:stderr), "merge queue"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_enabled_merge_queue_enqueues_the_same_head_without_a_direct_attempt
    result, log = run_cli(mode: "queue")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal HEAD_SHA, payload.fetch("expected_head")
    assert_equal "main", payload.fetch("expected_base")
    assert_equal "MQE_1", payload.dig("merge_queue_entry", "id")
    refute_includes log, "mergePullRequest"
    assert_includes log, "enqueuePullRequest"
    assert_includes log, "expectedHeadOid=#{HEAD_SHA}"
    assert_includes log, "GH_HOST=#{HOST} api graphql"
    assert_equal 3, log.scan("GraphQL-Features: merge_queue").length
    refute_includes log, "--auto"
  end

  def test_submit_accepts_the_coordinator_established_git_and_gh_executables
    result, log = run_cli(mode: "queue")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes log, "enqueuePullRequest"
  end

  def test_submit_replay_query_and_enqueue_children_ignore_hostile_environment
    result, log = run_cli(mode: "queue", hostile_environment: true)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes log, "enqueuePullRequest"
    assert result.fetch(:sentinel_markers).values.none?, result.fetch(:sentinel_markers).inspect
    excluded = %w[
      PATH RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS GEM_HOME GEM_PATH BUNDLE_GEMFILE
      GEMRC GEM_SPEC_CACHE BUNDLE_PATH BUNDLE_WITH RUBY_ENGINE RUBY_SENTINEL
      LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH
      DYLD_FRAMEWORK_PATH UNRELATED_SENTINEL
    ]
    result.fetch(:gh_environments).each do |environment|
      assert_equal HOST, environment.fetch("GH_HOST")
      assert_equal "allowed-token", environment.fetch("GH_TOKEN")
      assert_equal "https://proxy.example", environment.fetch("HTTPS_PROXY")
      assert_equal "C", environment.fetch("LC_ALL")
      assert environment.fetch("GH_CONFIG_DIR").start_with?("/")
      excluded.each { |key| refute environment.key?(key), key }
    end
    autonomous_environment = result.fetch(:autonomous_environment)
    assert_equal HOST, autonomous_environment.fetch("GH_HOST")
    assert_equal "allowed-token", autonomous_environment.fetch("GH_TOKEN")
    assert_equal "https://proxy.example", autonomous_environment.fetch("HTTPS_PROXY")
    assert_equal "C", autonomous_environment.fetch("LC_ALL")
    assert autonomous_environment.fetch("GH_CONFIG_DIR").start_with?("/")
    assert autonomous_environment.fetch("AUTONOMOUS_MERGE_GIT").start_with?("/")
    assert autonomous_environment.fetch("AUTONOMOUS_MERGE_GH").start_with?("/")
    excluded.each { |key| refute autonomous_environment.key?(key), key }
  end

  def test_enqueue_graphql_failure_with_unresolved_state_is_unknown
    result, log = run_cli(mode: "enqueue_graphql_error")

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
      expected_head: NUMERIC_SHA
    )

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes log, "-f name=123"
    refute_includes log, "-F name=123"
    assert_includes log, "-f expectedHeadOid=#{NUMERIC_SHA}"
    refute_includes log, "-F expectedHeadOid=#{NUMERIC_SHA}"
  end

  def test_queue_response_without_entry_fails_closed
    result, = run_cli(mode: "queue_missing_entry")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "outcome could not be proven"
  end

  def test_existing_exact_queue_entry_is_idempotent
    result, log = run_cli(mode: "already_queued")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal "MQE_1", payload.dig("merge_queue_entry", "id")
    refute_includes log, "enqueuePullRequest"
    refute_includes log, "mergePullRequest"
  end

  def test_initial_queue_membership_with_a_merge_commit_is_not_exact_queue_proof
    result, log = run_cli(mode: "already_queued_with_commit")

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

  def test_base_advancement_never_qualifies_queued_states
    {
      "enqueue_transport_queued_base_advanced" => "enqueuePullRequest",
      "queue_post_queued_base_advanced" => "enqueuePullRequest"
    }.each do |mode, attempted_mutation|
      result, log = run_cli(mode:)

      assert_equal 2, result.fetch(:status).exitstatus, mode
      assert_includes log, attempted_mutation, mode
    end
  end

  def test_initial_open_or_queued_base_advancement_stops_before_any_mutation
    %w[initial_open_base_advanced already_queued_base_advanced].each do |mode|
      result, log = run_cli(mode:)

      refute result.fetch(:status).success?, mode
      assert_includes result.fetch(:stderr), "receipt base SHA mismatch", mode
      refute_includes log, "mergePullRequest", mode
      refute_includes log, "enqueuePullRequest", mode
    end
  end

  def test_enqueue_transport_failure_reconciles_an_exact_queue_entry
    result, = run_cli(mode: "enqueue_transport_queued")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
  end

  def test_enqueue_transport_failure_keeps_merge_provenance_unknown
    result, = run_cli(mode: "enqueue_transport_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_unknown_reconciled_merge(
      JSON.parse(result.fetch(:stdout)), attempted_submission: "merge_queue"
    )
  end

  def test_enqueue_graphql_errors_keep_merge_provenance_unknown
    result, = run_cli(mode: "enqueue_graphql_error_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_unknown_reconciled_merge(
      JSON.parse(result.fetch(:stdout)), attempted_submission: "merge_queue"
    )
  end

  def test_valid_merge_proof_wins_when_queue_fields_coexist
    result, = run_cli(mode: "enqueue_graphql_error_merged_queued")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "already_merged", payload.fetch("submission")
    assert_equal "merge_queue", payload.fetch("attempted_submission")
    refute payload.key?("queue_method")
  end

  def test_terminal_queue_fields_with_an_invalid_commit_prove_neither_outcome
    %w[UNKNOWN malformed].each do |merge_commit_oid|
      result, = run_cli(mode: "enqueue_graphql_error_merged_queued", merge_commit_oid:)

      assert_equal 2, result.fetch(:status).exitstatus, merge_commit_oid
      assert_includes result.fetch(:stderr), "outcome could not be proven", merge_commit_oid
    end
  end

  def test_enqueue_reconciliation_callers_reject_queue_state_with_a_merge_commit
    {
      "enqueue_transport_queued_with_commit" => "enqueuePullRequest",
      "enqueue_graphql_error_queued_with_commit" => "enqueuePullRequest"
    }.each do |mode, attempted_mutation|
      result, log = run_cli(mode:)

      assert_equal 2, result.fetch(:status).exitstatus, mode
      assert_includes result.fetch(:stderr), "could not be proven", mode
      assert_includes log, attempted_mutation, mode
    end
  end

  def test_successful_enqueue_response_preserves_queue_provenance_after_fast_merge
    result, = run_cli(mode: "queue_fast_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_reconciled_queue_merge(JSON.parse(result.fetch(:stdout)))
  end

  def test_fast_post_enqueue_merge_accepts_an_advanced_base_oid_before_old_base_guard
    result, = run_cli(mode: "queue_fast_merged_base_advanced")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_reconciled_queue_merge(JSON.parse(result.fetch(:stdout)))
  end

  def test_fast_post_enqueue_merge_requires_a_full_hex_merge_commit_oid
    ["", "malformed", "UNKNOWN"].each do |merge_commit_oid|
      result, = run_cli(mode: "queue_fast_merged", merge_commit_oid:)

      assert_equal 2, result.fetch(:status).exitstatus, merge_commit_oid
      assert_includes result.fetch(:stderr), "live membership could not be confirmed", merge_commit_oid
    end
  end

  def test_fast_post_enqueue_queue_with_a_merge_commit_is_not_exact_queue_proof
    result, = run_cli(mode: "queue_post_queued_with_commit")

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
    started_at = nil
    result, = run_cli(
      mode: "metadata_timeout_descendant",
      after_stub_warmup: -> { started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "timed out"
    assert_operator elapsed, :<, 3
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
    result, = run_cli(mode: "enqueue_non_object_response_queued")

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
    result, log = run_cli(mode: "queue_base_race")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "PR base moved"
    assert_includes result.fetch(:stderr), "automatic queue cleanup is unsafe"
    refute_includes log, "dequeuePullRequest"
  end

  def test_post_enqueue_replacement_entry_is_not_dequeued
    result, log = run_cli(mode: "queue_entry_replaced")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "automatic queue cleanup is unsafe"
    refute_includes log, "dequeuePullRequest"
  end

  def test_post_enqueue_exact_replacement_reports_the_live_queue_entry
    result, log = run_cli(mode: "queue_entry_replaced_same_target")

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
    result, log = run_cli(mode: "queue", receipt_mode: :semantic)

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

  def test_trusted_git_and_gh_flags_are_required_before_any_gh_call
    cases = {
      git: [false, true, "--trusted-git-executable is required"],
      gh: [true, false, "--trusted-gh-executable is required"]
    }
    cases.each do |name, (include_git, include_gh, expected)|
      result, log = run_cli(
        mode: "direct",
        include_trusted_git_executable: include_git,
        include_trusted_gh_executable: include_gh
      )

      refute result.fetch(:status).success?, name
      assert_includes result.fetch(:stderr), expected, name
      assert_empty log, name
    end
  end

  def test_unavailable_autonomous_helper_result_stops_before_any_mutation
    result, log = run_cli(mode: "direct", receipt_mode: :autonomous_unavailable)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "receipt evidence does not currently qualify"
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_submit_replays_autonomous_eligibility_and_rejects_mutated_receipt_evidence
    result, log = run_cli(mode: "direct", receipt_mode: :autonomous_replay_mismatch)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "autonomous_result does not match trusted live replay"
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
    result, log = run_cli(mode: "direct", receipt_mode: :mismatched_base_sha)

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
    result, log = run_cli(mode:)

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
      result, = run_cli(mode:)
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
    url_host: HOST,
    include_expected_head: true,
    include_expected_base: true,
    subject: "Fix the thing (#42)",
    body: nil,
    include_merge_assurance_receipt: true,
    receipt_mode: :valid,
    after_stub_warmup: nil,
    merge_commit_oid: MERGE_COMMIT_SHA,
    hostile_environment: false,
    include_trusted_git_executable: true,
    include_trusted_gh_executable: true
  )
    Dir.mktmpdir("pr-merge-submit-test") do |dir|
      log_path = File.join(dir, "gh.log")
      gh_path = File.join(dir, "gh")
      File.write(
        gh_path,
        fake_gh(mode:, head:, base:, url_host:, repo:, merge_commit_oid:, log_path:)
      )
      FileUtils.chmod(0o755, gh_path)
      git_path = File.join(dir, "trusted-git")
      File.write(git_path, "#!#{RbConfig.ruby}\nexit 0\n")
      FileUtils.chmod(0o755, git_path)
      autonomous_result_path = File.join(dir, "merge-assurance-receipt.json.replayed.json")
      autonomous_log_path = File.join(dir, "autonomous-replay.log")
      submit_script = prepare_submit_helper_layout(
        dir, autonomous_result_path:, autonomous_log_path:
      )
      warm_stub(dir, gh_path) if mode.include?("timeout")
      after_stub_warmup&.call
      receipt_path = File.join(dir, "merge-assurance-receipt.json")
      unless receipt_mode == :missing
        write_merge_assurance_receipt(
          receipt_path, mode: receipt_mode, repo:, head: expected_head,
                        base_ref: "main", host: HOST, pr_number: 42, gh_dir: dir
        )
      end
      repo_root = File.join(dir, "consumer")
      FileUtils.mkdir_p(repo_root)
      semantic_assessment = File.join(dir, "semantic-assessment.json")
      File.write(semantic_assessment, "{}\n")
      trusted_helper_provenance =
        "trusted-base:#{receipt_mode == :mismatched_base_sha ? 'c' * 40 : 'b' * 40}"
      arguments = cli_arguments(
        repo, expected_head, include_expected_head, include_expected_base,
        subject:, body:, include_merge_assurance_receipt:, receipt_path:,
        script: submit_script, repo_root:, semantic_assessment:,
        trusted_helper_provenance:,
        trusted_git_executable: include_trusted_git_executable ? git_path : nil,
        trusted_gh_executable: include_trusted_gh_executable ? gh_path : nil
      )
      invocation = arguments
      sentinel_markers = {}
      if hostile_environment
        invocation, sentinel_markers = hostile_environment_launcher(dir, arguments)
      end
      stdout, stderr, status = Open3.capture3(
        cli_environment(dir, mode),
        *invocation
      )
      log = File.exist?(log_path) ? File.read(log_path) : ""
      gh_environment_path = "#{log_path}.environments"
      gh_environments = if File.exist?(gh_environment_path)
                          File.readlines(gh_environment_path, chomp: true).map { |line| JSON.parse(line) }
                        else
                          []
                        end
      autonomous_environment = if File.exist?(autonomous_log_path)
                                 JSON.parse(File.read(autonomous_log_path)).fetch("environment")
                               else
                                 {}
                               end
      [
        {
          stdout:, stderr:, status:, gh_environments:, autonomous_environment:,
          sentinel_markers: sentinel_markers.transform_values { |path| File.exist?(path) }
        },
        log
      ]
    end
  end

  def run_cli_with_interrupt(mode:, wait_for: "mergePullRequest", after_stub_warmup: nil)
    Dir.mktmpdir("pr-merge-submit-interrupt-test") do |dir|
      log_path = File.join(dir, "gh.log")
      gh_path = File.join(dir, "gh")
      File.write(
        gh_path,
        fake_gh(
          mode:, head: HEAD_SHA, base: "main", url_host: HOST, repo: "owner/repo",
          log_path:
        )
      )
      FileUtils.chmod(0o755, gh_path)
      git_path = File.join(dir, "trusted-git")
      File.write(git_path, "#!#{RbConfig.ruby}\nexit 0\n")
      FileUtils.chmod(0o755, git_path)
      autonomous_result_path = File.join(dir, "merge-assurance-receipt.json.replayed.json")
      autonomous_log_path = File.join(dir, "autonomous-replay.log")
      submit_script = prepare_submit_helper_layout(
        dir, autonomous_result_path:, autonomous_log_path:
      )
      warm_stub(dir, gh_path)
      after_stub_warmup&.call
      receipt_path = File.join(dir, "merge-assurance-receipt.json")
      write_merge_assurance_receipt(
        receipt_path, mode: :valid, repo: "owner/repo", head: HEAD_SHA,
                      base_ref: "main", host: HOST, pr_number: 42, gh_dir: dir
      )
      repo_root = File.join(dir, "consumer")
      FileUtils.mkdir_p(repo_root)
      semantic_assessment = File.join(dir, "semantic-assessment.json")
      File.write(semantic_assessment, "{}\n")
      result = Open3.popen3(
        cli_environment(dir, mode),
        *cli_arguments(
          "owner/repo", HEAD_SHA, true, true,
          include_merge_assurance_receipt: true, receipt_path:,
          script: submit_script, repo_root:, semantic_assessment:,
          trusted_git_executable: git_path, trusted_gh_executable: gh_path
        )
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
  def warm_stub(_dir, gh_path)
    system(
      gh_path, "--version", out: File::NULL, err: File::NULL
    )
  end

  def cli_environment(dir, mode)
    {
      "PATH" => "#{dir}:#{ENV.fetch('PATH')}",
      "PR_MERGE_SUBMIT_GH_TIMEOUT_SECONDS" => gh_timeout_seconds_for(mode)
    }
  end

  def gh_timeout_seconds_for(mode)
    return NO_TIMEOUT_GH_SECONDS unless mode.include?("timeout")
    return MUTATION_TIMEOUT_GH_SECONDS if MUTATION_TIMEOUT_MODES.include?(mode)

    SOLE_CALL_TIMEOUT_GH_SECONDS
  end

  def hostile_environment_launcher(root, arguments)
    poison_root = File.join(root, "poisoned-path")
    FileUtils.mkdir_p(poison_root)
    markers = %w[ruby git gh preload].to_h do |name|
      [name, File.join(root, "poisoned-#{name}-ran")]
    end
    %w[ruby git gh].each do |name|
      File.write(File.join(poison_root, name), <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{markers.fetch(name).inspect}, "yes")
        exit 99
      RUBY
      File.chmod(0o755, File.join(poison_root, name))
    end
    preload = File.join(root, "preload.rb")
    File.write(preload, "File.write(#{markers.fetch('preload').inspect}, 'yes')\n")
    gh_config_dir = File.join(root, "gh-config")
    FileUtils.mkdir_p(gh_config_dir)
    hostile = {
      "PATH" => "#{poison_root}:#{ENV.fetch('PATH')}",
      "GH_HOST" => "attacker.example",
      "GH_TOKEN" => "allowed-token",
      "GH_CONFIG_DIR" => gh_config_dir,
      "HTTPS_PROXY" => "https://proxy.example",
      "LC_ALL" => "C",
      "RUBYOPT" => "-r#{preload}",
      "RUBYLIB" => poison_root,
      "RUBYGEMS_GEMDEPS" => "sentinel",
      "GEM_HOME" => poison_root,
      "GEM_PATH" => poison_root,
      "GEMRC" => File.join(root, "gemrc"),
      "GEM_SPEC_CACHE" => File.join(root, "gem-spec-cache"),
      "BUNDLE_GEMFILE" => File.join(root, "Gemfile"),
      "BUNDLE_PATH" => File.join(root, "bundle"),
      "BUNDLE_WITH" => "sentinel",
      "RUBY_ENGINE" => "sentinel",
      "RUBY_SENTINEL" => "sentinel",
      "LD_PRELOAD" => File.join(root, "preload.so"),
      "LD_LIBRARY_PATH" => poison_root,
      "DYLD_INSERT_LIBRARIES" => File.join(root, "preload.dylib"),
      "DYLD_LIBRARY_PATH" => poison_root,
      "DYLD_FRAMEWORK_PATH" => poison_root,
      "UNRELATED_SENTINEL" => "must-not-pass"
    }
    environment_path = File.join(root, "late-environment.json")
    arguments_path = File.join(root, "late-arguments.json")
    launcher = File.join(root, "late-launcher.rb")
    File.write(environment_path, JSON.generate(hostile))
    File.write(arguments_path, JSON.generate(arguments))
    File.write(launcher, <<~RUBY)
      require "json"
      ENV.update(JSON.parse(File.read(#{environment_path.inspect})))
      command = JSON.parse(File.read(#{arguments_path.inspect}))
      script = command.shift
      ARGV.replace(command)
      $0 = script
      load script
    RUBY
    [[RbConfig.ruby, launcher], markers]
  end

  def cli_arguments(
    repo, expected_head, include_expected_head, include_expected_base,
    subject: "Fix the thing (#42)", body: nil,
    include_merge_assurance_receipt: true, receipt_path: nil, script: SCRIPT,
    repo_root: nil, semantic_assessment: nil,
    trusted_helper_provenance: "trusted-base:#{'b' * 40}",
    trusted_git_executable: nil, trusted_gh_executable: nil
  )
    args = [
      script, "42", "--repo", repo, "--host", HOST,
      "--method", "squash", "--subject", subject
    ]
    args.concat(["--body", body]) unless body.nil?
    args.concat(["--expected-head", expected_head]) if include_expected_head
    args.concat(["--expected-base", "main"]) if include_expected_base
    args.concat(["--merge-assurance-receipt", receipt_path]) if include_merge_assurance_receipt
    args.concat(["--repo-root", repo_root]) if repo_root
    args.concat(["--semantic-assessment", semantic_assessment]) if semantic_assessment
    if trusted_helper_provenance
      args.concat(["--trusted-helper-provenance", trusted_helper_provenance])
    end
    args.concat(["--trusted-git-executable", trusted_git_executable]) if trusted_git_executable
    args.concat(["--trusted-gh-executable", trusted_gh_executable]) if trusted_gh_executable
    args
  end

  def write_merge_assurance_receipt(path, mode:, repo:, head:, base_ref:, host:, pr_number:, gh_dir:)
    now = Time.now.utc
    base_sha = mode == :mismatched_base_sha ? "c" * 40 : "b" * 40
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
    recomputed_autonomous_result = Marshal.load(Marshal.dump(autonomous_result))
    tracker = semantic_tracker(host:, repo:, pr_number:)
    semantic = mode.to_s.start_with?("semantic")
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
      "operations" => semantic ? [tracker] : []
    }
    receipt = with_fake_gh(gh_dir) do
      MergeAssurance.assess(
        ci_result:,
        autonomous_result:,
        recomputed_autonomous_result: autonomous_result,
        context:,
        trusted_gh_executable: File.join(gh_dir, "gh"),
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
    when :autonomous_replay_mismatch
      receipt.dig("evidence", "autonomous_result", "metrics")["changed_files"] = 30
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
    end
    File.write(path, JSON.generate(receipt))
    File.write("#{path}.replayed.json", JSON.generate(recomputed_autonomous_result))
  end

  def prepare_submit_helper_layout(root, autonomous_result_path:, autonomous_log_path:)
    bin_dir = File.join(root, "runtime/skills/pr-batch/bin")
    FileUtils.mkdir_p(bin_dir)
    submit_script = File.join(bin_dir, "pr-merge-submit")
    assurance_script = File.join(bin_dir, "merge-assurance")
    FileUtils.cp(SCRIPT, submit_script)
    FileUtils.cp(ASSURANCE_SCRIPT, assurance_script)
    FileUtils.chmod(0o755, submit_script)
    FileUtils.chmod(0o755, assurance_script)
    autonomous_helper = File.join(bin_dir, "autonomous-merge-eligibility")
    File.write(autonomous_helper, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.write(
        #{autonomous_log_path.inspect},
        JSON.generate(
          "argv" => ARGV,
          "environment" => ENV.to_h
        )
      )
      STDOUT.write(File.read(#{autonomous_result_path.inspect}))
    RUBY
    FileUtils.chmod(0o755, autonomous_helper)
    submit_script
  end

  def with_fake_gh(_dir)
    yield
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

  def fake_gh(
    mode:, head:, base:, url_host:, repo:, log_path:, merge_commit_oid: MERGE_COMMIT_SHA
  )
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
    direct_base_oid = if %w[
      direct_base_advanced direct_nonterminal_base_advanced
    ].include?(mode)
                        ADVANCED_BASE_SHA
                      else
                        "b" * 40
                      end
    direct_state = mode == "direct_nonterminal_base_advanced" ? "OPEN" : "MERGED"
    direct_payload = {
      "data" => {
        "mergePullRequest" => {
          "pullRequest" => {
            "headRefOid" => head,
            "baseRefName" => base,
            "baseRefOid" => direct_base_oid,
            "state" => direct_state,
            "merged" => true,
            "mergedAt" => "2026-07-20T15:00:00Z",
            "url" => "https://#{url_host}/#{repo}/pull/42",
            "mergeCommit" => { "oid" => merge_commit_oid }
          }
        }
      }
    }
    <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      File.open(#{log_path.inspect}, "a") do |file|
        file.puts("GH_HOST=\#{ENV.fetch('GH_HOST', '')} \#{ARGV.join(' ')}")
      end
      File.open(#{"#{log_path}.environments".inspect}, "a") do |file|
        file.puts(JSON.generate(ENV.to_h))
      end
      warn "debug diagnostic" if #{mode.inspect} == "direct_with_stderr"

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
          fork do
            trap("TERM", "IGNORE")
            sleep 5
            exit! 0
          end
          sleep 5
        end
        sleep 5 if #{mode.inspect} == "metadata_timeout"
        query_count_path = #{"#{log_path}.queries".inspect}
        query_count = File.exist?(query_count_path) ? File.read(query_count_path).to_i : 0
        File.write(query_count_path, (query_count + 1).to_s)
        current_mode = #{mode.inspect}
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
                        when "queue_race", "queue_race_merged", "queue_race_mixed_errors" then query_count.positive?
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
                      "queue_post_queued_with_commit",
                      "direct_graphql_error_queued_with_commit" then query_count.positive?
                 when "queue_race" then query_count > 1
                 when "queue_base_race", "enqueue_transport_base_race",
                      "enqueue_graphql_error_base_race", "queue_entry_replaced" then query_count == 1
                 else false
                 end
        merged_after_mutation = [
          "direct_transport_merged", "direct_invalid_json_merged", "direct_graphql_error_merged",
          "direct_incomplete_response_merged", "direct_non_object_response_merged",
          "direct_timeout_merged", "direct_transport_merged_base_advanced",
          "enqueue_transport_merged", "enqueue_graphql_error_merged",
          "enqueue_graphql_error_merged_queued",
          "enqueue_timeout_merged", "queue_fast_merged", "queue_fast_merged_base_advanced",
          "queue_race_merged"
        ].include?(current_mode)
        merged = ["already_merged", "already_merged_base_advanced"].include?(current_mode) ||
                 (merged_after_mutation && query_count.positive?)
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
          queue_post_queued_base_advanced
          direct_transport_merged_base_advanced direct_transport_open_base_advanced
          enqueue_transport_queued_base_advanced direct_nonterminal_base_advanced
        ]
        initially_advanced_modes = %w[
          already_merged_base_advanced initial_open_base_advanced already_queued_base_advanced
        ]
        live_base_oid = if base_advanced_modes.include?(current_mode) &&
                           (initially_advanced_modes.include?(current_mode) || query_count.positive?)
                          #{ADVANCED_BASE_SHA.inspect}
                        else
                          #{('b' * 40).inspect}
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
                "headRefOid" => #{head.inspect},
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
                  direct_graphql_error_queued_with_commit
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

      if ARGV.any? { |arg| arg.include?("mergePullRequest") }
        case #{mode.inspect}
        when "queue_race", "queue_race_merged"
          puts JSON.generate("errors" => [{ "message" => "The merge strategy for main is set by the merge queue" }])
          exit 1
        when "queue_race_mixed_errors"
          puts JSON.generate(
            "errors" => [
              { "message" => "The merge strategy for main is set by the merge queue" },
              { "message" => "nested field resolution failed" }
            ]
          )
          exit 1
        when "direct_failure"
          puts JSON.generate("errors" => [{ "message" => "permission denied" }])
          exit 1
        when "direct_transport_merged", "direct_transport_merged_base_advanced",
             "direct_transport_open_base_advanced", "direct_transport_unknown"
          warn "connection reset after request"
          exit 1
        when "direct_timeout_unknown", "direct_timeout_merged", "direct_interrupt_unknown"
          sleep 5
        when "direct_interrupt_exit_zero"
          trap("INT") do
            puts #{JSON.generate(direct_payload).inspect}
            exit 0
          end
          sleep 5
        when "direct_raw_queue_error"
          warn "The merge strategy for main is set by the merge queue"
          exit 1
        when "direct_invalid_json_merged"
          puts "truncated json"
        when "direct_graphql_error_merged"
          puts JSON.generate(
            "data" => { "mergePullRequest" => { "pullRequest" => nil } },
            "errors" => [{ "message" => "nested field resolution failed" }]
          )
          exit 1
        when "direct_graphql_error_queued_with_commit"
          puts JSON.generate(
            "data" => { "mergePullRequest" => { "pullRequest" => nil } },
            "errors" => [{ "message" => "nested field resolution failed" }]
          )
          exit 1
        when "direct_incomplete_response_merged", "direct_incomplete_response_unknown"
          puts JSON.generate("data" => { "mergePullRequest" => { "pullRequest" => nil } })
        when "direct_non_object_response_merged"
          puts JSON.generate([])
        else
          puts #{JSON.generate(direct_payload).inspect}
        end
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

      warn "unexpected gh invocation: \#{ARGV.join(' ')}"
      exit 1
    RUBY
  end
end
