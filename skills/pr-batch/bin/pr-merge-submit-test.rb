#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("pr-merge-submit", __dir__)

class PrMergeSubmitTest < Minitest::Test
  HEAD_SHA = "a" * 40
  NUMERIC_SHA = "1" * 40
  MOVED_SHA = "b" * 40
  HOST = "ghe.example:8443"

  def test_direct_merge_uses_exact_head_bound_graphql_mutation
    result, log = run_cli(mode: "direct")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_equal "main", payload.fetch("expected_base")
    assert_equal "COMMIT_1", payload.fetch("merge_commit")
    assert_includes log, "GH_HOST=#{HOST} api graphql"
    assert_includes log, "GraphQL-Features: merge_queue"
    assert_includes log, "mergePullRequest"
    assert_includes log, "expectedHeadOid=#{HEAD_SHA}"
    assert_includes log, "mergeMethod=SQUASH"
    assert_includes log, "commitHeadline=Fix the thing (#42)"
    refute_includes log, "pr merge"
    refute_includes log, "--auto"
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

  def test_queue_enablement_race_retries_only_after_explicit_queue_error
    result, log = run_cli(mode: "queue_race")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_includes payload.fetch("direct_attempt"), "set by the merge queue"
    query_count = log.lines.count { |line| line.include?("number=42") }
    assert_equal 3, query_count
    assert_includes log, "mergePullRequest"
    assert_includes log, "enqueuePullRequest"
  end

  def test_unrelated_direct_failure_does_not_enqueue
    result, log = run_cli(mode: "direct_failure")

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "direct merge submission returned errors"
    refute_includes log, "enqueuePullRequest"
  end

  def test_enqueue_graphql_failure_is_not_reported_as_unknown
    result, log = run_cli(mode: "enqueue_graphql_error")

    assert_equal 1, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "merge-queue submission returned errors"
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

  def test_successful_api_diagnostics_do_not_corrupt_json
    result, = run_cli(mode: "direct_with_stderr")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_includes payload.fetch("diagnostics"), "debug diagnostic"
  end

  def test_returned_pr_url_must_match_explicit_host
    result, log = run_cli(mode: "direct", url_host: "github.com")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "PR URL host mismatch"
    refute_includes log, "mergePullRequest"
  end

  def test_repository_name_and_commit_oid_are_sent_as_raw_strings
    result, log = run_cli(
      mode: "direct", repo: "owner/123", head: NUMERIC_SHA,
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

  def test_existing_exact_merge_is_idempotent
    result, log = run_cli(mode: "already_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "already_merged", payload.fetch("submission")
    assert_equal "UNKNOWN", payload.fetch("merge_provenance")
    assert_equal true, payload.fetch("already_complete")
    assert_equal "COMMIT_1", payload.fetch("merge_commit")
    refute payload.key?("method")
    refute_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_direct_transport_failure_reconciles_an_exact_merge
    result, log = run_cli(mode: "direct_transport_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal true, payload.fetch("reconciled_after_failure")
    assert_equal "COMMIT_1", payload.fetch("merge_commit")
    assert_includes log, "mergePullRequest"
  end

  def test_invalid_direct_response_reconciles_an_exact_merge
    result, = run_cli(mode: "direct_invalid_json_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
    assert_equal "COMMIT_1", payload.fetch("merge_commit")
  end

  def test_direct_graphql_errors_reconcile_an_exact_merge
    result, = run_cli(mode: "direct_graphql_error_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
    assert_equal "COMMIT_1", payload.fetch("merge_commit")
  end

  def test_incomplete_direct_response_reconciles_an_exact_merge
    result, = run_cli(mode: "direct_incomplete_response_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
    assert_equal "COMMIT_1", payload.fetch("merge_commit")
  end

  def test_incomplete_direct_response_with_unchanged_live_state_reports_unknown
    result, = run_cli(mode: "direct_incomplete_response_unknown")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "do not retry blindly"
  end

  def test_non_object_direct_response_reconciles_an_exact_merge
    result, = run_cli(mode: "direct_non_object_response_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
  end

  def test_unresolved_direct_transport_failure_reports_unknown
    result, log = run_cli(mode: "direct_transport_unknown")

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "do not retry blindly"
    assert_includes log, "mergePullRequest"
    refute_includes log, "enqueuePullRequest"
  end

  def test_enqueue_transport_failure_reconciles_an_exact_queue_entry
    result, = run_cli(mode: "enqueue_transport_queued")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal true, payload.fetch("reconciled_after_failure")
  end

  def test_enqueue_transport_failure_preserves_queue_provenance_after_merge
    result, = run_cli(mode: "enqueue_transport_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_reconciled_queue_merge(JSON.parse(result.fetch(:stdout)))
  end

  def test_enqueue_graphql_errors_preserve_queue_provenance_after_merge
    result, = run_cli(mode: "enqueue_graphql_error_merged")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_reconciled_queue_merge(JSON.parse(result.fetch(:stdout)))
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

  def test_expected_head_is_required
    result, log = run_cli(mode: "direct", include_expected_head: false)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--expected-head must be a full commit SHA"
    assert_empty log
  end

  def test_expected_base_is_required
    result, log = run_cli(mode: "direct", include_expected_base: false)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--expected-base must be a valid branch name"
    assert_empty log
  end

  private

  def assert_reconciled_queue_merge(payload)
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal "repository_configured", payload.fetch("queue_method")
    assert_equal "MERGED", payload.fetch("post_submission_state")
    assert_equal "COMMIT_1", payload.fetch("merge_commit")
    assert_equal true, payload.fetch("reconciled_after_failure")
    refute payload.key?("method")
    refute payload.key?("merge_queue_entry")
  end

  def assert_retargeted_queue_entry_is_not_dequeued(mode)
    result, log = run_cli(mode:)

    assert_equal 2, result.fetch(:status).exitstatus
    assert_includes result.fetch(:stderr), "PR base moved"
    assert_includes result.fetch(:stderr), "cannot be safely dequeued"
    refute_includes log, "dequeuePullRequest"
  end

  def run_cli(
    mode:,
    repo: "owner/repo",
    head: HEAD_SHA,
    expected_head: HEAD_SHA,
    base: "main",
    url_host: HOST,
    include_expected_head: true,
    include_expected_base: true
  )
    Dir.mktmpdir("pr-merge-submit-test") do |dir|
      log_path = File.join(dir, "gh.log")
      gh_path = File.join(dir, "gh")
      File.write(gh_path, fake_gh(mode:, head:, base:, url_host:))
      FileUtils.chmod(0o755, gh_path)
      args = [
        SCRIPT, "42", "--repo", repo, "--host", HOST,
        "--method", "squash", "--subject", "Fix the thing (#42)"
      ]
      args.concat(["--expected-head", expected_head]) if include_expected_head
      args.concat(["--expected-base", "main"]) if include_expected_base
      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "GH_LOG" => log_path },
        *args
      )
      log = File.exist?(log_path) ? File.read(log_path) : ""
      [{ stdout:, stderr:, status: }, log]
    end
  end

  def fake_gh(mode:, head:, base:, url_host:)
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
    direct_payload = {
      "data" => {
        "mergePullRequest" => {
          "pullRequest" => {
            "headRefOid" => head,
            "baseRefName" => base,
            "merged" => true,
            "mergedAt" => "2026-07-20T15:00:00Z",
            "url" => "https://#{url_host}/owner/repo/pull/42",
            "mergeCommit" => { "oid" => "COMMIT_1" }
          }
        }
      }
    }
    <<~RUBY
      #!/usr/bin/env ruby
      require "json"
      File.open(ENV.fetch("GH_LOG"), "a") do |file|
        file.puts("GH_HOST=\#{ENV.fetch('GH_HOST', '')} \#{ARGV.join(' ')}")
      end
      warn "debug diagnostic" if #{mode.inspect} == "direct_with_stderr"

      if ARGV.any? { |arg| arg == "number=42" }
        query_count_path = ENV.fetch("GH_LOG") + ".queries"
        query_count = File.exist?(query_count_path) ? File.read(query_count_path).to_i : 0
        File.write(query_count_path, (query_count + 1).to_s)
        current_mode = #{mode.inspect}
        queue_enabled = case current_mode
                        when "queue", "queue_missing_entry", "already_queued",
                             "enqueue_transport_queued", "enqueue_transport_merged",
                             "enqueue_graphql_error", "enqueue_graphql_error_merged",
                             "enqueue_transport_base_race", "enqueue_graphql_error_base_race",
                             "enqueue_non_object_response_queued", "queue_base_race",
                             "queue_entry_replaced" then true
                        when "queue_race" then query_count.positive?
                        else false
                        end
        queued = case current_mode
                 when "already_queued" then true
                 when "queue", "enqueue_transport_queued", "enqueue_non_object_response_queued" then query_count.positive?
                 when "queue_race" then query_count > 1
                 when "queue_base_race", "enqueue_transport_base_race",
                      "enqueue_graphql_error_base_race", "queue_entry_replaced" then query_count == 1
                 else false
                 end
        merged_after_mutation = [
          "direct_transport_merged", "direct_invalid_json_merged", "direct_graphql_error_merged",
          "direct_incomplete_response_merged", "direct_non_object_response_merged",
          "enqueue_transport_merged", "enqueue_graphql_error_merged"
        ].include?(current_mode)
        merged = current_mode == "already_merged" || (merged_after_mutation && query_count.positive?)
        base_race_modes = [
          "queue_base_race", "queue_entry_replaced", "enqueue_transport_base_race",
          "enqueue_graphql_error_base_race"
        ]
        live_base = if base_race_modes.include?(current_mode) && query_count.positive?
                      "release"
                    else
                      #{base.inspect}
                    end
        queue_entry = if queued
                        {
                          "id" => current_mode == "queue_entry_replaced" ? "MQE_2" : "MQE_1",
                          "position" => 1, "state" => "QUEUED",
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
                "state" => merged ? "MERGED" : "OPEN",
                "isDraft" => false,
                "url" => "https://#{url_host}/owner/repo/pull/42",
                "merged" => merged,
                "mergedAt" => merged ? "2026-07-20T15:00:00Z" : nil,
                "mergeCommit" => merged ? { "oid" => "COMMIT_1" } : nil,
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
        when "queue_race"
          puts JSON.generate("errors" => [{ "message" => "The merge strategy for main is set by the merge queue" }])
          exit 1
        when "direct_failure"
          puts JSON.generate("errors" => [{ "message" => "permission denied" }])
          exit 1
        when "direct_transport_merged", "direct_transport_unknown"
          warn "connection reset after request"
          exit 1
        when "direct_invalid_json_merged"
          puts "truncated json"
        when "direct_graphql_error_merged"
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
        if [
          "enqueue_transport_queued", "enqueue_transport_merged", "enqueue_transport_base_race"
        ].include?(#{mode.inspect})
          warn "connection reset after request"
          exit 1
        end
        if [
          "enqueue_graphql_error", "enqueue_graphql_error_merged", "enqueue_graphql_error_base_race"
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
