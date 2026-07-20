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
  MOVED_SHA = "b" * 40

  def test_direct_merge_is_exact_head_bound_and_never_enables_auto_merge
    result, log = run_cli(mode: "direct")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "direct", payload.fetch("submission")
    assert_includes log, "pr merge 42 --repo owner/repo --squash --match-head-commit #{HEAD_SHA}"
    assert_includes log, "--subject Fix the thing (#42)"
    refute_includes log, "--auto"
    refute_includes log, "pullRequestId="
  end

  def test_enabled_merge_queue_enqueues_the_same_head_without_a_direct_attempt
    result, log = run_cli(mode: "queue")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_equal HEAD_SHA, payload.fetch("expected_head")
    assert_equal "MQE_1", payload.dig("merge_queue_entry", "id")
    refute_includes log, "pr merge"
    assert_includes log, "pullRequestId=PR_42"
    assert_includes log, "expectedHeadOid=#{HEAD_SHA}"
    refute_includes log, "--auto"
  end

  def test_unrelated_direct_failure_does_not_enqueue
    result, log = run_cli(mode: "direct_failure")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "direct merge submission failed: permission denied"
    refute_includes log, "pullRequestId="
  end

  def test_head_movement_stops_before_any_merge_mutation
    result, log = run_cli(mode: "direct", head: MOVED_SHA)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "PR head moved"
    refute_includes log, "pr merge"
    refute_includes log, "pullRequestId="
  end

  def test_queue_enablement_race_requires_a_refreshed_enabled_state
    result, log = run_cli(mode: "queue_race")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    payload = JSON.parse(result.fetch(:stdout))
    assert_equal "merge_queue", payload.fetch("submission")
    assert_includes payload.fetch("direct_attempt"), "set by the merge queue"
    query_count = log.lines.count { |line| line.include?("number=42") }
    assert_equal 2, query_count
    assert_includes log, "pr merge 42"
    assert_includes log, "pullRequestId=PR_42"
  end

  def test_queue_response_without_entry_fails_closed
    result, = run_cli(mode: "queue_missing_entry")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "merge-queue submission returned no queue entry"
  end

  def test_expected_head_is_required
    result, log = run_cli(mode: "direct", include_expected_head: false)

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--expected-head must be a full commit SHA"
    assert_empty log
  end

  private

  def run_cli(mode:, head: HEAD_SHA, include_expected_head: true)
    Dir.mktmpdir("pr-merge-submit-test") do |dir|
      log_path = File.join(dir, "gh.log")
      gh_path = File.join(dir, "gh")
      File.write(gh_path, fake_gh(mode:, head:))
      FileUtils.chmod(0o755, gh_path)
      args = [SCRIPT, "42", "--repo", "owner/repo", "--method", "squash", "--subject", "Fix the thing (#42)"]
      args.concat(["--expected-head", HEAD_SHA]) if include_expected_head
      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "GH_LOG" => log_path },
        *args
      )
      log = File.exist?(log_path) ? File.read(log_path) : ""
      [{ stdout:, stderr:, status: }, log]
    end
  end

  def fake_gh(mode:, head:)
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
      #!/usr/bin/env ruby
      require "json"
      File.open(ENV.fetch("GH_LOG"), "a") { |file| file.puts(ARGV.join(" ")) }

      if ARGV[0, 2] == ["api", "graphql"] && ARGV.any? { |arg| arg == "number=42" }
        query_count_path = ENV.fetch("GH_LOG") + ".queries"
        query_count = File.exist?(query_count_path) ? File.read(query_count_path).to_i : 0
        File.write(query_count_path, (query_count + 1).to_s)
        queue_enabled = case #{mode.inspect}
                        when "queue", "queue_missing_entry" then true
                        when "queue_race" then query_count.positive?
                        else false
                        end
        puts JSON.generate(
          "data" => {
            "repository" => {
              "pullRequest" => {
                "id" => "PR_42",
                "headRefOid" => #{head.inspect},
                "baseRefName" => "main",
                "state" => "OPEN",
                "isDraft" => false,
                "url" => "https://github.com/owner/repo/pull/42",
                "isMergeQueueEnabled" => queue_enabled
              }
            }
          }
        )
        exit 0
      end

      if ARGV[0, 2] == ["pr", "merge"]
        case #{mode.inspect}
        when "direct"
          puts "merged"
          exit 0
        when "queue_race"
          warn "The merge strategy for main is set by the merge queue"
          warn "GraphQL: Auto merge is not allowed (enablePullRequestAutoMerge)"
          exit 1
        else
          warn "permission denied"
          exit 1
        end
      end

      if ARGV[0, 2] == ["api", "graphql"]
        puts #{JSON.generate(queue_payload).inspect}
        exit 0
      end

      warn "unexpected gh invocation: \#{ARGV.join(' ')}"
      exit 1
    RUBY
  end
end
