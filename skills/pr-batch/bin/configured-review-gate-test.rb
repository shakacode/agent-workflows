#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "time"
require "yaml"

SCRIPT = File.expand_path("configured-review-gate", __dir__)
load SCRIPT

class ConfiguredReviewGateTest < Minitest::Test
  HOST = "github.com"
  REPO = "example/widgets"
  PR = 42
  BASE_SHA = "b" * 40
  HEAD_SHA = "a" * 40
  NOW = Time.iso8601("2026-08-25T12:00:00Z")
  PR4701_FIXTURE = File.expand_path("fixtures/configured-review-pr4701.json", __dir__)
  SOURCE_POLICY = File.expand_path("../../../.agents/agent-workflow.yml", __dir__)
  CLAUDE_REVIEW_WORKFLOW = File.expand_path("../../../.github/workflows/claude-code-review.yml", __dir__)
  CONFIGURED_REVIEW_WORKFLOW = File.expand_path("../../../.github/workflows/configured-review-gate.yml", __dir__)

  FakeClient = Struct.new(:snapshots) do
    def collect
      snapshots.length > 1 ? snapshots.shift : snapshots.first
    end
  end

  class FakeGitHubApiClient < ConfiguredReviewGate::GitHubClient
    # This API fixture deliberately bypasses the production initializer's system-tool resolution.
    # rubocop:disable Lint/MissingSuper
    def initialize(policy:, threads:, reviews: [], checks: [], permissions: {}, workflow_runs: nil)
      @host = HOST
      @repo = REPO
      @pr = PR
      @policy = policy
      @threads = threads
      @reviews = reviews
      @checks = checks
      @permissions = permissions
      @workflow_runs = workflow_runs || [{
        "id" => 1,
        "check_suite_id" => 7,
        "path" => ".github/workflows/claude-code-review.yml",
        "event" => "pull_request",
        "head_sha" => HEAD_SHA,
        "pull_requests" => [{ "number" => PR, "base" => { "sha" => BASE_SHA }, "head" => { "sha" => HEAD_SHA } }]
      }]
    end
    # rubocop:enable Lint/MissingSuper

    private

    def api_json(*arguments)
      endpoint = arguments.find { |argument| argument.start_with?("repos/") }
      return pull_response if endpoint == "repos/#{REPO}/pulls/#{PR}"
      return [{ "check_runs" => @checks }] if endpoint&.include?("/check-runs?")
      return { "workflow_runs" => @workflow_runs } if endpoint&.include?("/actions/runs")
      return { "sha" => "1" * 40 } if endpoint&.include?("/contents/")

      if endpoint&.include?("/collaborators/")
        actor = endpoint.split("/collaborators/", 2).last.split("/permission", 2).first
        return @permissions.fetch(actor, { "permission" => "read", "role_name" => "read" })
      end
      return [[]] if endpoint&.include?("/issues/#{PR}/comments?")
      return [@reviews] if endpoint&.include?("/pulls/#{PR}/reviews?")
      return graphql_response if arguments.include?("graphql")

      raise "unexpected fake GitHub API request: #{arguments.inspect}"
    end

    def pull_response
      {
        "base" => { "ref" => "main", "sha" => BASE_SHA },
        "head" => { "sha" => HEAD_SHA }
      }
    end

    def graphql_response
      [{
        "data" => {
          "repository" => {
            "pullRequest" => {
              "reviewThreads" => {
                "nodes" => @threads,
                "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
              }
            }
          }
        }
      }]
    end
  end

  def snapshot(**overrides)
    {
      "contract" => "configured-review-snapshot",
      "version" => 1,
      "provenance" => "fixture",
      "collected_at" => NOW.iso8601,
      "bindings" => {
        "host" => HOST,
        "repo" => REPO,
        "pr" => PR,
        "base_ref" => "main",
        "base_sha" => BASE_SHA,
        "head_sha" => HEAD_SHA
      },
      "checks" => [],
      "artifacts" => [],
      "threads" => [],
      "complete" => true
    }.merge(overrides)
  end

  def live_snapshot(**overrides)
    snapshot("provenance" => "gh-api", **overrides)
  end

  def policy
    {
      "version" => 1,
      "reviewers" => [
        {
          "id" => "claude",
          "check_name" => "claude-review",
          "producer" => {
            "app_slug" => "github-actions",
            "workflow_path" => ".github/workflows/claude-code-review.yml",
            "event" => "pull_request"
          },
          "artifact" => {
            "actors" => %w[claude claude[bot]],
            "kinds" => %w[pull_request_review review_thread]
          }
        }
      ],
      "require_current_head" => true,
      "artifact_settlement" => { "required" => true, "quiet_period_seconds" => 30 },
      "thread_disposition" => {
        "required" => true,
        "marker" => "configured-review-disposition:"
      },
      "failure_policy" => "block",
      "fallback" => { "mode" => "disabled" }
    }
  end

  def policy_with_producer_completion
    configured = Marshal.load(Marshal.dump(policy))
    configured.dig("reviewers", 0, "artifact")["completion"] = { "mode" => "producer_check" }
    configured
  end

  def check(
    name: "claude-review", status: "completed", conclusion: "success",
    head_sha: HEAD_SHA, output: "review complete", producer: trusted_producer
  )
    {
      "name" => name,
      "status" => status,
      "conclusion" => conclusion,
      "head_sha" => head_sha,
      "started_at" => "2026-08-25T11:55:00Z",
      "completed_at" => status == "completed" ? "2026-08-25T11:59:00Z" : nil,
      "details_url" => "https://github.com/example/widgets/actions/runs/1",
      "output" => output,
      "producer" => producer,
      "app" => { "slug" => producer["app_slug"] },
      "check_suite" => { "id" => 7 }
    }
  end

  def trusted_producer
    {
      "app_slug" => "github-actions",
      "workflow_path" => ".github/workflows/claude-code-review.yml",
      "event" => "pull_request",
      "head_sha" => HEAD_SHA,
      "reviewed_pr" => PR,
      "reviewed_base_sha" => BASE_SHA,
      "workflow_blob_sha" => "1" * 40,
      "trusted_base_workflow_blob_sha" => "1" * 40,
      "verified" => true
    }
  end

  def artifact(
    id: "1", kind: "pull_request_review", actor: "claude", head_sha: HEAD_SHA,
    created_at: "2026-08-25T11:59:10Z", state: "COMMENTED", body: nil
  )
    record = {
      "id" => id,
      "kind" => kind,
      "actor" => actor,
      "created_at" => created_at,
      "url" => "https://github.com/example/widgets/pull/42#issuecomment-1",
      "head_sha" => head_sha
    }
    record["state"] = state if kind == "pull_request_review"
    record["body"] = body if body
    record
  end

  def test_producer_bound_completion_artifact_qualifies_without_inline_review
    result = ConfiguredReviewGate.evaluate(
      policy: policy_with_producer_completion, policy_source: JSON.generate(policy_with_producer_completion),
      snapshot: snapshot("checks" => [check], "artifacts" => []),
      settled: true, now: NOW
    )

    assert_equal "READY", result.fetch("verdict")
  end

  def test_unrelated_github_actions_review_does_not_qualify
    unrelated = artifact(actor: "github-actions[bot]", body: "Looks good")
    result = ConfiguredReviewGate.evaluate(
      policy:, policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [unrelated]),
      settled: true, now: NOW
    )

    assert_equal "configured-review-artifact-missing", result.dig("blockers", 0, "code")
  end

  def thread(id:, resolved: false, head_sha: HEAD_SHA, comments: [])
    {
      "id" => id,
      "url" => "https://github.com/example/widgets/pull/42#discussion_r#{id.delete_prefix('T')}",
      "resolved" => resolved,
      "outdated" => false,
      "root_head_sha" => head_sha,
      "comments" => [
        {
          "id" => "#{id}-root",
          "actor" => "claude",
          "association" => "CONTRIBUTOR",
          "body" => "Please fix this.",
          "created_at" => "2026-08-25T11:59:10Z"
        },
        *comments
      ]
    }
  end

  def with_trusted_policy(yaml)
    Dir.mktmpdir("configured-review-policy-test") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents/agent-workflow.yml"), yaml)
      system("git", "-C", root, "init", "-q", exception: true)
      system("git", "-C", root, "add", ".agents/agent-workflow.yml", exception: true)
      system(
        "git", "-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.com",
        "commit", "-qm", "policy fixture", exception: true
      )
      base_sha, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
      assert status.success?
      yield root, base_sha.strip
    end
  end

  def test_explicit_n_a_is_ready_without_inventing_a_review_cohort
    result = ConfiguredReviewGate.evaluate(
      policy: "n/a",
      policy_source: "review_gate: n/a\n",
      snapshot: snapshot,
      settled: true,
      now: NOW
    )

    assert_equal "READY", result.fetch("verdict")
    assert_empty result.fetch("blockers")
    receipt = result.fetch("receipt")
    assert_equal "configured-review-gate-receipt", receipt.fetch("contract")
    assert_equal snapshot.fetch("bindings"), receipt.fetch("bindings")
    assert_equal true, receipt.dig("policy", "not_applicable")
    assert_equal false, receipt.fetch("mutation_eligible")
  end

  def test_trusted_policy_loader_rejects_duplicate_top_level_review_gate
    with_trusted_policy("review_gate: n/a\nreview_gate: n/a\n") do |root, base_sha|
      error = assert_raises(ConfiguredReviewGate::Error) do
        ConfiguredReviewGate::TrustedPolicy.load(repo_root: root, base_sha:)
      end

      assert_includes error.message, '$ contains duplicate key "review_gate"'
    end
  end

  def test_trusted_policy_loader_rejects_duplicate_nested_review_gate_keys
    yaml = <<~YAML
      review_gate:
        version: 1
        reviewers:
          - id: claude
            check_name: claude-review
            check_name: shadow-review
            artifact:
              actors: [claude]
              kinds: [pull_request_review]
    YAML
    with_trusted_policy(yaml) do |root, base_sha|
      error = assert_raises(ConfiguredReviewGate::Error) do
        ConfiguredReviewGate::TrustedPolicy.load(repo_root: root, base_sha:)
      end

      assert_includes error.message, '$.review_gate.reviewers contains duplicate key "check_name"'
    end
  end

  def test_default_policy_blocks_the_complete_check_state_matrix
    cases = {
      "missing" => [[], "NOT_READY", "configured-review-missing"],
      "pending" => [[check(status: "in_progress", conclusion: nil)], "NOT_READY", "configured-review-pending"],
      "stale" => [[check(head_sha: "c" * 40)], "NOT_READY", "configured-review-stale"],
      "failed" => [[check(conclusion: "failure")], "NOT_READY", "configured-review-failed"],
      "cancelled" => [[check(conclusion: "cancelled")], "NOT_READY", "configured-review-cancelled"],
      "timed out" => [[check(conclusion: "timed_out")], "NOT_READY", "configured-review-timed-out"],
      "action required" => [[check(conclusion: "action_required")], "NOT_READY", "configured-review-action-required"],
      "rate limited" => [[check(conclusion: "failure", output: "HTTP 429 rate limit exceeded")], "NOT_READY", "configured-review-rate-limited"],
      "quota exhausted" => [[check(conclusion: "failure", output: "usage limit quota exhausted")], "NOT_READY", "configured-review-quota-exhausted"],
      "capacity unavailable" => [[check(conclusion: "failure", output: "HTTP 503 provider capacity unavailable")], "NOT_READY", "configured-review-capacity-unavailable"],
      "unknown status" => [[check(status: "mystery", conclusion: nil)], "UNKNOWN", "configured-review-unknown"]
    }

    cases.each do |label, (checks, verdict, blocker_code)|
      result = ConfiguredReviewGate.evaluate(
        policy: policy,
        policy_source: JSON.generate(policy),
        snapshot: snapshot("checks" => checks),
        settled: true,
        now: NOW
      )

      assert_equal verdict, result.fetch("verdict"), label
      assert_includes result.fetch("blockers").map { |blocker| blocker.fetch("code") }, blocker_code, label
      refute result.key?("receipt"), label
    end
  end

  def test_source_policy_names_each_live_claude_artifact_login
    source_policy = YAML.safe_load(File.read(SOURCE_POLICY), aliases: false)

    assert_equal %w[claude claude[bot]],
                 source_policy.dig("review_gate", "reviewers", 0, "artifact", "actors")
    assert_equal trusted_producer.slice("app_slug", "workflow_path", "event"),
                 source_policy.dig("review_gate", "reviewers", 0, "producer")
  end

  def test_completed_claude_workflow_publishes_an_exact_head_gate_accepted_review
    source = File.read(CLAUDE_REVIEW_WORKFLOW)
    workflow = YAML.safe_load(source, aliases: false)
    steps = workflow.dig("jobs", "claude-review", "steps")
    checkout = steps.find { |step| step["name"] == "Checkout repository" }
    verification = steps.find { |step| step["name"] == "Verify review completed (fail on invalid/expired token)" }
    publisher = steps.find { |step| step["name"] == "Publish exact-head review artifact" }

    assert_equal false, checkout.dig("with", "persist-credentials")
    assert_equal "verify-review", verification.fetch("id")
    assert_includes verification.fetch("run"), 'echo "completed=true" >> "$GITHUB_OUTPUT"'
    assert_equal "steps.verify-review.outputs.completed == 'true'", publisher.fetch("if")
    assert_equal "${{ github.event.pull_request.head.sha }}", publisher.dig("env", "EXPECTED_HEAD_SHA")
    refute_includes publisher.fetch("run"), "${{"
    assert_includes publisher.fetch("run"), "repos/${REPOSITORY}/pulls/${PULL_REQUEST_NUMBER}/reviews"
    assert_includes publisher.fetch("run"), "-f event=COMMENT"
    assert_includes publisher.fetch("run"), '-f commit_id="$EXPECTED_HEAD_SHA"'

    source_policy = YAML.safe_load(File.read(SOURCE_POLICY), aliases: false).fetch("review_gate")
    result = ConfiguredReviewGate.evaluate(
      policy: source_policy,
      policy_source: File.read(SOURCE_POLICY),
      snapshot: snapshot(
        "checks" => [check],
        "artifacts" => [artifact(actor: "claude[bot]")]
      ),
      settled: true,
      now: NOW
    )

    assert_equal "READY", result.fetch("verdict")
  end

  def test_same_named_check_from_untrusted_producer_is_blocking
    forged = trusted_producer.merge(
      "workflow_path" => ".github/workflows/forged-review.yml",
      "workflow_blob_sha" => "2" * 40,
      "verified" => false
    )
    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check(producer: forged)]),
      settled: true,
      now: NOW
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-producer-untrusted", result.dig("blockers", 0, "code")
  end

  def test_configured_review_workflow_refreshes_evidence_changes_from_trusted_base
    workflow = YAML.safe_load(File.read(CONFIGURED_REVIEW_WORKFLOW), aliases: false)
    triggers = workflow.fetch(true)
    checkout = workflow.dig("jobs", "configured-review-gate", "steps").find do |step|
      step["name"] == "Checkout trusted base"
    end
    bindings = workflow.dig("jobs", "configured-review-gate", "steps").find do |step|
      step["name"] == "Resolve exact pull request bindings"
    end

    assert_equal %w[opened synchronize edited reopened ready_for_review], triggers.dig("pull_request_target", "types")
    assert_equal %w[submitted edited dismissed], triggers.dig("pull_request_review", "types")
    assert_equal %w[created edited deleted], triggers.dig("pull_request_review_comment", "types")
    assert_equal ["Claude Code Review"], triggers.dig("workflow_run", "workflows")
    assert_equal ["completed"], triggers.dig("workflow_run", "types")
    assert_equal true, triggers.dig("workflow_dispatch", "inputs", "pr", "required")
    assert_equal "string", triggers.dig("workflow_dispatch", "inputs", "pr", "type")
    assert_equal(
      { "actions" => "read", "checks" => "read", "contents" => "read", "pull-requests" => "read", "statuses" => "write" },
      workflow.fetch("permissions")
    )
    assert_equal "bindings", bindings.fetch("id")
    assert_includes bindings.fetch("run"), 'if [ "$GITHUB_EVENT_NAME" = "workflow_run" ]'
    assert_includes bindings.fetch("run"), 'elif [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]'
    assert_includes bindings.fetch("run"), ".inputs.pr"
    assert_includes bindings.fetch("run"), "length == 1"
    assert_includes bindings.fetch("run"), '.workflow_run.event == "pull_request"'
    assert_includes bindings.fetch("run"), '"$live_head_sha" != "$triggering_head_sha"'
    assert_equal "${{ steps.bindings.outputs.base_sha }}", checkout.dig("with", "ref")
    assert_equal false, checkout.dig("with", "persist-credentials")
    assert_equal true, workflow.dig("concurrency", "cancel-in-progress")
    assert_includes workflow.dig("concurrency", "group"), "github.event.workflow_run.head_sha"

    gate = workflow.dig("jobs", "configured-review-gate", "steps").find do |step|
      step["name"] == "Require settled configured reviews"
    end
    assert_equal "${{ steps.bindings.outputs.pr }}", gate.dig("env", "REVIEW_GATE_PR")
    assert_equal "${{ steps.bindings.outputs.base_sha }}", gate.dig("env", "REVIEW_GATE_BASE_SHA")
    assert_equal "${{ steps.bindings.outputs.head_sha }}", gate.dig("env", "REVIEW_GATE_HEAD_SHA")
    assert_includes gate.fetch("run"), 'post_status success "Advisory:'

    processing = File.read(File.expand_path("../../../workflows/pr-processing.md", __dir__))
    assert_includes processing, "advisory `configured-review-gate` commit"
    assert_includes processing, "Never configure\nthis context as a required ruleset or merge-queue check"
    assert_includes processing, "GitHub does not emit an Actions\nevent when a review thread is resolved or unresolved"
  end

  def test_producer_reviewed_base_must_match_current_base
    stale = trusted_producer.merge("reviewed_base_sha" => "d" * 40)
    result = ConfiguredReviewGate.evaluate(
      policy:, policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check(producer: stale)], "artifacts" => [artifact]),
      settled: true, now: NOW
    )

    assert_equal "configured-review-producer-untrusted", result.dig("blockers", 0, "code")
  end

  def test_producer_reviewed_pr_must_match_current_pr
    foreign = trusted_producer.merge("reviewed_pr" => PR + 1)
    result = ConfiguredReviewGate.evaluate(
      policy:, policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check(producer: foreign)], "artifacts" => [artifact]),
      settled: true, now: NOW
    )

    assert_equal "configured-review-producer-untrusted", result.dig("blockers", 0, "code")
  end

  def test_collector_rejects_missing_multiple_and_foreign_workflow_run_pr_associations
    associations = {
      "missing" => [],
      "multiple" => [
        { "number" => PR, "base" => { "sha" => BASE_SHA }, "head" => { "sha" => HEAD_SHA } },
        { "number" => PR + 1, "base" => { "sha" => BASE_SHA }, "head" => { "sha" => HEAD_SHA } }
      ],
      "foreign" => [{ "number" => PR + 1, "base" => { "sha" => BASE_SHA }, "head" => { "sha" => HEAD_SHA } }]
    }
    associations.each do |label, pull_requests|
      run = {
        "id" => 1, "check_suite_id" => 7, "path" => ".github/workflows/claude-code-review.yml",
        "event" => "pull_request", "head_sha" => HEAD_SHA, "pull_requests" => pull_requests
      }
      raw_check = check.merge(
        "output" => { "title" => "review complete", "summary" => nil, "text" => nil },
        "app" => { "slug" => "github-actions" }, "check_suite" => { "id" => 7 }
      )
      collected = FakeGitHubApiClient.new(
        policy:, threads: [], checks: [raw_check], workflow_runs: [run]
      ).collect

      assert_equal false, collected.dig("checks", 0, "producer", "verified"), label
    end
  end

  def test_claude_workflow_retargets_and_fails_closed_when_review_execution_is_absent
    workflow = YAML.safe_load(File.read(File.expand_path("../../../.github/workflows/claude-code-review.yml", __dir__)), aliases: false)
    assert_includes workflow.fetch(true).dig("pull_request", "types"), "edited"
    script = workflow.dig("jobs", "claude-review", "steps").find do |step|
      step["name"] == "Verify review completed (fail on invalid/expired token)"
    end.fetch("run")
    assert_includes script, "No execution output found; no configured review was performed."
    assert_includes script, "No result record in execution output; no configured review was verified."
    assert_includes script, '.subtype == "success"'
    assert_includes script, ".is_error == false"
    assert_includes script, '.num_turns | type == "number" and floor == . and . > 0'
    assert_includes script, '.result | type == "string" and length > 0'
    refute_includes script, ".is_error // false"
    assert_operator script.scan("exit 1").length, :>=, 3
  end

  def test_queued_current_head_duplicate_without_timestamps_blocks_success_and_replay
    successful = check
    queued = check(status: "queued", conclusion: nil).merge(
      "started_at" => nil,
      "completed_at" => nil,
      "details_url" => "https://github.com/example/widgets/actions/runs/2"
    )
    current = live_snapshot("checks" => [successful, queued], "artifacts" => [artifact])

    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: current,
      settled: true,
      now: NOW
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-pending", result.dig("blockers", 0, "code")
    assert_equal "https://github.com/example/widgets/actions/runs/2",
                 result.dig("blockers", 0, "details_url")

    initial = live_snapshot("checks" => [successful], "artifacts" => [artifact])
    receipt = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: initial,
      settled: true,
      now: NOW,
      trusted_live: true
    ).fetch("receipt")
    replay = ConfiguredReviewGate.replay(
      receipt: receipt,
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: current.merge("collected_at" => (NOW + 20).iso8601),
      now: NOW + 20,
      trusted_live: true
    )

    assert_equal "NOT_READY", replay.fetch("verdict")
    assert_equal "configured-review-pending", replay.dig("blockers", 0, "code")
  end

  def test_live_collector_materializes_only_current_head_configured_review_thread_artifacts
    raw_thread = lambda do |id:, actor:, head_sha:, resolved: false|
      {
        "id" => id,
        "isResolved" => resolved,
        "isOutdated" => false,
        "comments" => {
          "nodes" => [{
            "id" => "#{id}-root",
            "url" => "https://github.com/example/widgets/pull/42#discussion_r#{id}",
            "body" => "Please fix this.",
            "createdAt" => "2026-08-25T11:59:10Z",
            "author" => { "login" => actor },
            "authorAssociation" => "CONTRIBUTOR",
            "commit" => { "oid" => head_sha },
            "originalCommit" => { "oid" => head_sha },
            "replyTo" => nil
          }],
          "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
        }
      }
    end
    client = FakeGitHubApiClient.new(
      policy: policy,
      threads: [
        raw_thread.call(id: "current", actor: "claude", head_sha: HEAD_SHA, resolved: true),
        raw_thread.call(id: "stale", actor: "claude", head_sha: "c" * 40),
        raw_thread.call(id: "other", actor: "human-reviewer", head_sha: HEAD_SHA)
      ]
    )

    collected = client.collect

    assert_equal true, collected.fetch("complete")
    assert_equal [{
      "id" => "current-root",
      "kind" => "review_thread",
      "actor" => "claude",
      "created_at" => "2026-08-25T11:59:10Z",
      "url" => "https://github.com/example/widgets/pull/42#discussion_rcurrent",
      "head_sha" => HEAD_SHA
    }], collected.fetch("artifacts")
  end

  def test_live_collector_never_queries_issue_comments_as_review_artifacts
    client_class = Class.new(FakeGitHubApiClient) do
      private

      def api_json(*arguments)
        endpoint = arguments.find { |argument| argument.start_with?("repos/") }
        raise "issue comments cannot prove exact-head review attribution" if endpoint&.include?("/issues/")

        super
      end
    end
    client = client_class.new(policy: policy, threads: [])

    collected = client.collect

    assert_empty collected.fetch("artifacts")
  end

  def test_live_collector_rejects_generic_workflow_bot_completion_review
    review = {
      "id" => 99,
      "user" => { "login" => "github-actions[bot]" },
      "submitted_at" => "2026-08-25T11:59:10Z",
      "html_url" => "https://github.com/example/widgets/pull/42#pullrequestreview-99",
      "commit_id" => HEAD_SHA,
      "state" => "COMMENTED",
      "body" => "Claude review completed for exact head #{HEAD_SHA}."
    }
    client = FakeGitHubApiClient.new(policy: policy_with_producer_completion, threads: [], reviews: [review])

    collected = client.collect

    assert_empty collected.fetch("artifacts")
  end

  def test_live_collector_materializes_pull_request_review_state
    review = {
      "id" => 7,
      "user" => { "login" => "claude[bot]" },
      "state" => "COMMENTED",
      "submitted_at" => "2026-08-25T11:59:10Z",
      "html_url" => "https://github.com/example/widgets/pull/42#pullrequestreview-7",
      "commit_id" => HEAD_SHA
    }
    client = FakeGitHubApiClient.new(policy: policy, threads: [], reviews: [review])

    collected = client.collect

    assert_equal "COMMENTED", collected.dig("artifacts", 0, "state")
  end

  def test_live_collector_proves_check_producer_against_trusted_base_blob
    raw_check = check.merge("output" => { "title" => "review complete", "summary" => nil, "text" => nil })
    client = FakeGitHubApiClient.new(policy: policy, threads: [], checks: [raw_check])

    producer = client.collect.dig("checks", 0, "producer")

    assert_equal true, producer.fetch("verified")
    assert_equal "github-actions", producer.fetch("app_slug")
    assert_equal ".github/workflows/claude-code-review.yml", producer.fetch("workflow_path")
    assert_equal producer.fetch("workflow_blob_sha"), producer.fetch("trusted_base_workflow_blob_sha")
  end

  def test_live_collector_authorizes_disposition_markers_from_repository_permission
    comments = [
      {
        "id" => "root", "url" => "https://github.com/example/widgets/pull/42#discussion_r1",
        "body" => "Please fix this.", "createdAt" => "2026-08-25T11:59:10Z",
        "author" => { "login" => "claude" }, "authorAssociation" => "CONTRIBUTOR",
        "commit" => { "oid" => HEAD_SHA }, "originalCommit" => { "oid" => HEAD_SHA }, "replyTo" => nil
      },
      {
        "id" => "writer", "url" => "https://github.com/example/widgets/pull/42#discussion_r1",
        "body" => "configured-review-disposition: fixed", "createdAt" => "2026-08-25T12:00:00Z",
        "author" => { "login" => "writer" }, "authorAssociation" => "COLLABORATOR",
        "commit" => { "oid" => HEAD_SHA }, "originalCommit" => { "oid" => HEAD_SHA },
        "replyTo" => { "id" => "root" }
      },
      {
        "id" => "triager", "url" => "https://github.com/example/widgets/pull/42#discussion_r1",
        "body" => "configured-review-disposition: waived", "createdAt" => "2026-08-25T12:00:01Z",
        "author" => { "login" => "triager" }, "authorAssociation" => "COLLABORATOR",
        "commit" => { "oid" => HEAD_SHA }, "originalCommit" => { "oid" => HEAD_SHA },
        "replyTo" => { "id" => "root" }
      }
    ]
    thread = {
      "id" => "T1", "isResolved" => false, "isOutdated" => false,
      "comments" => { "nodes" => comments, "pageInfo" => { "hasNextPage" => false, "endCursor" => nil } }
    }
    client = FakeGitHubApiClient.new(
      policy: policy, threads: [thread],
      permissions: {
        "writer" => { "permission" => "write", "role_name" => "maintain" },
        "triager" => { "permission" => "read", "role_name" => "triage" }
      }
    )

    collected_comments = client.collect.dig("threads", 0, "comments")

    assert_equal true, collected_comments[1].fetch("disposition")
    assert_equal true, collected_comments[1].dig("authorization", "trusted")
    assert_equal "maintain", collected_comments[1].dig("authorization", "role_name")
    assert_equal false, collected_comments[2].fetch("disposition")
    assert_equal false, collected_comments[2].dig("authorization", "trusted")
  end

  def test_success_requires_a_current_head_artifact_and_a_settled_snapshot
    missing = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check]),
      settled: true,
      now: NOW
    )
    unsettled = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [artifact]),
      settled: false,
      now: NOW
    )
    stale_artifact = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [artifact(head_sha: "c" * 40)]),
      settled: true,
      now: NOW
    )

    assert_equal "configured-review-artifact-missing", missing.dig("blockers", 0, "code")
    assert_equal "configured-review-artifact-unsettled", unsettled.dig("blockers", 0, "code")
    assert_equal "configured-review-artifact-missing", stale_artifact.dig("blockers", 0, "code")
  end

  def test_only_latest_current_head_pull_request_review_per_actor_can_qualify
    older_comment = artifact(id: "1", created_at: "2026-08-25T11:57:00Z", state: "COMMENTED")
    newer_change_request = artifact(
      id: "2", created_at: "2026-08-25T11:59:00Z", state: "CHANGES_REQUESTED"
    )

    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [older_comment, newer_change_request]),
      settled: true,
      now: NOW
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-artifact-missing", result.dig("blockers", 0, "code")
  end

  def test_rejected_or_unknown_pull_request_review_states_never_qualify
    ["CHANGES_REQUESTED", "DISMISSED", "PENDING", "UNKNOWN", nil].each do |state|
      result = ConfiguredReviewGate.evaluate(
        policy: policy,
        policy_source: JSON.generate(policy),
        snapshot: snapshot("checks" => [check], "artifacts" => [artifact(state:)]),
        settled: true,
        now: NOW
      )

      assert_equal "NOT_READY", result.fetch("verdict"), state.inspect
      assert_equal "configured-review-artifact-missing", result.dig("blockers", 0, "code"), state.inspect
    end
  end

  def test_newest_acceptable_current_head_review_qualifies_regardless_of_api_order
    newer_comment = artifact(id: "2", created_at: "2026-08-25T11:59:00Z", state: "COMMENTED")
    older_change_request = artifact(
      id: "1", created_at: "2026-08-25T11:57:00Z", state: "CHANGES_REQUESTED"
    )

    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [newer_comment, older_change_request]),
      settled: true,
      now: NOW
    )

    assert_equal "READY", result.fetch("verdict")
  end

  def test_equal_time_pull_request_reviews_use_numeric_rest_id_order
    earlier_approved = artifact(id: "9", state: "APPROVED")
    later_change_request = artifact(id: "10", state: "CHANGES_REQUESTED")

    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [later_change_request, earlier_approved]),
      settled: true,
      now: NOW
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-artifact-missing", result.dig("blockers", 0, "code")
  end

  def test_malformed_non_numeric_or_missing_pull_request_review_ids_fail_closed
    [nil, "", "review-10", "10x", "0", "-1"].each do |id|
      result = ConfiguredReviewGate.evaluate(
        policy: policy,
        policy_source: JSON.generate(policy),
        snapshot: snapshot("checks" => [check], "artifacts" => [artifact(id:)]),
        settled: true,
        now: NOW
      )

      assert_equal "NOT_READY", result.fetch("verdict"), id.inspect
      assert_equal "configured-review-artifact-missing", result.dig("blockers", 0, "code"), id.inspect
    end
  end

  def test_latest_blocked_formal_review_hard_blocks_a_resolved_thread_artifact
    review_thread = artifact(id: "thread-1", kind: "review_thread")
    blocked_review = artifact(id: "10", state: "CHANGES_REQUESTED")

    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [review_thread, blocked_review]),
      settled: true,
      now: NOW
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-artifact-missing", result.dig("blockers", 0, "code")
  end

  def test_invalid_latest_formal_review_hard_blocks_a_resolved_thread_artifact
    cases = [
      ["dismissed", artifact(id: "10", state: "DISMISSED")],
      ["unknown state", artifact(id: "10", state: "UNEXPECTED")],
      ["malformed id", artifact(id: "review-10", state: "COMMENTED")],
      ["missing id", artifact(id: nil, state: "COMMENTED")]
    ]

    cases.each do |label, formal_review|
      result = ConfiguredReviewGate.evaluate(
        policy: policy,
        policy_source: JSON.generate(policy),
        snapshot: snapshot(
          "checks" => [check],
          "artifacts" => [artifact(id: "thread-1", kind: "review_thread"), formal_review]
        ),
        settled: true,
        now: NOW
      )

      assert_equal "NOT_READY", result.fetch("verdict"), label
      assert_equal "configured-review-artifact-missing", result.dig("blockers", 0, "code"), label
    end
  end

  def test_later_acceptable_formal_review_supersedes_a_blocked_review_with_a_resolved_thread
    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot(
        "checks" => [check],
        "artifacts" => [
          artifact(id: "thread-1", kind: "review_thread"),
          artifact(id: "9", state: "CHANGES_REQUESTED"),
          artifact(id: "10", state: "COMMENTED")
        ]
      ),
      settled: true,
      now: NOW
    )

    assert_equal "READY", result.fetch("verdict")
  end

  def test_settled_success_with_no_untriaged_current_head_threads_is_ready
    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot("checks" => [check], "artifacts" => [artifact]),
      settled: true,
      now: NOW
    )

    assert_equal "READY", result.fetch("verdict")
    assert_empty result.fetch("blockers")
    receipt = result.fetch("receipt")
    assert_equal HEAD_SHA, receipt.dig("bindings", "head_sha")
    assert_equal BASE_SHA, receipt.dig("bindings", "base_sha")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, receipt.dig("artifact_settlement", "snapshot_digest"))
    assert_equal false, receipt.fetch("mutation_eligible")
  end

  def test_pr_4701_replay_blocks_five_unresolved_untriaged_current_head_threads
    threads = 5.times.map { |index| thread(id: "T#{index + 1}") }
    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot(
        "checks" => [check],
        "artifacts" => [artifact(kind: "review_thread")],
        "threads" => threads
      ),
      settled: true,
      now: NOW
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    blockers = result.fetch("blockers")
    assert_equal(5, blockers.count { |blocker| blocker.fetch("code") == "configured-review-thread-untriaged" })
    assert_equal(threads.map { |item| item.fetch("id") }, blockers.map { |blocker| blocker.fetch("thread_id") })
    refute result.key?("receipt")
  end

  def test_explicit_trusted_thread_dispositions_satisfy_the_gate
    disposition = {
      "id" => "reply-1",
      "actor" => "maintainer",
      "association" => "MEMBER",
      "authorization" => { "permission" => "write", "role_name" => "write", "trusted" => true },
      "body" => "configured-review-disposition: fixed",
      "created_at" => "2026-08-25T11:59:20Z"
    }
    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot(
        "checks" => [check],
        "artifacts" => [artifact(kind: "review_thread")],
        "threads" => [thread(id: "T1", comments: [disposition])]
      ),
      settled: true,
      now: NOW
    )

    assert_equal "READY", result.fetch("verdict")

    normalized = disposition.reject { |key, _value| key == "body" }.merge("disposition" => true)
    live_result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot(
        "checks" => [check],
        "artifacts" => [artifact(kind: "review_thread")],
        "threads" => [thread(id: "T-live", comments: [normalized])]
      ),
      settled: true,
      now: NOW
    )

    assert_equal "READY", live_result.fetch("verdict")
  end

  def test_collaborator_association_without_write_permission_cannot_dispose_a_thread
    disposition = {
      "id" => "reply-1",
      "actor" => "triager",
      "association" => "COLLABORATOR",
      "authorization" => { "permission" => "read", "role_name" => "triage", "trusted" => false },
      "body" => "configured-review-disposition: waived",
      "created_at" => "2026-08-25T11:59:20Z"
    }
    result = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: snapshot(
        "checks" => [check],
        "artifacts" => [artifact(kind: "review_thread")],
        "threads" => [thread(id: "T1", comments: [disposition])]
      ),
      settled: true,
      now: NOW
    )

    assert_equal "configured-review-thread-untriaged", result.dig("blockers", 0, "code")
  end

  def test_explicit_named_attested_fallback_can_override_only_a_configured_trigger
    fallback_policy = policy
    fallback_policy["fallback"] = {
      "mode" => "named_attested_check",
      "triggers" => ["rate_limited"],
      "reviewer" => {
        "id" => "codex-fallback",
        "check_name" => "codex-review",
        "producer" => trusted_producer.slice("app_slug", "workflow_path", "event"),
        "artifact" => {
          "actors" => ["codex-reviewer"],
          "kinds" => ["pull_request_review"]
        }
      }
    }
    result = ConfiguredReviewGate.evaluate(
      policy: fallback_policy,
      policy_source: JSON.generate(fallback_policy),
      snapshot: snapshot(
        "checks" => [
          check(conclusion: "failure", output: "HTTP 429 rate limit exceeded"),
          check(name: "codex-review")
        ],
        "artifacts" => [artifact(actor: "codex-reviewer")]
      ),
      settled: true,
      now: NOW
    )

    assert_equal "READY", result.fetch("verdict")
    override = result.fetch("receipt").dig("policy", "override")
    assert_equal "named_attested_check", override.fetch("mode")
    assert_equal "codex-fallback", override.fetch("reviewer_id")
    assert_equal ["configured-review-rate-limited"], override.fetch("primary_blocker_codes")
  end

  def test_fallback_does_not_override_an_unconfigured_failure_trigger
    fallback_policy = policy
    fallback_policy["fallback"] = {
      "mode" => "named_attested_check",
      "triggers" => ["rate_limited"],
      "reviewer" => {
        "id" => "codex-fallback",
        "check_name" => "codex-review",
        "producer" => trusted_producer.slice("app_slug", "workflow_path", "event"),
        "artifact" => { "actors" => ["codex-reviewer"], "kinds" => ["pull_request_review"] }
      }
    }
    result = ConfiguredReviewGate.evaluate(
      policy: fallback_policy,
      policy_source: JSON.generate(fallback_policy),
      snapshot: snapshot(
        "checks" => [check(conclusion: "cancelled"), check(name: "codex-review")],
        "artifacts" => [artifact(actor: "codex-reviewer")]
      ),
      settled: true,
      now: NOW
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-cancelled", result.dig("blockers", 0, "code")
  end

  def test_replay_accepts_only_an_unchanged_live_exact_head_snapshot
    initial = live_snapshot("checks" => [check], "artifacts" => [artifact])
    receipt = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: initial,
      settled: true,
      now: NOW,
      trusted_live: true
    ).fetch("receipt")
    replay_snapshot = Marshal.load(Marshal.dump(initial))
    replay_snapshot["collected_at"] = (NOW + 20).iso8601

    result = ConfiguredReviewGate.replay(
      receipt: receipt,
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: replay_snapshot,
      settled: true,
      now: NOW + 20,
      trusted_live: true
    )

    assert_equal "READY", result.fetch("verdict")
    assert_equal true, result.fetch("mutation_eligible")

    moved = Marshal.load(Marshal.dump(replay_snapshot))
    moved["bindings"]["head_sha"] = "c" * 40
    moved_result = ConfiguredReviewGate.replay(
      receipt: receipt,
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: moved,
      now: NOW + 20,
      trusted_live: true
    )
    assert_equal "NOT_READY", moved_result.fetch("verdict")
    assert_equal "configured-review-receipt-binding-mismatch", moved_result.dig("blockers", 0, "code")
  end

  def test_replay_rejects_inconsistent_receipt_security_projections_before_live_evaluation
    initial = live_snapshot("checks" => [check], "artifacts" => [artifact])
    receipt = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: initial,
      settled: true,
      now: NOW,
      trusted_live: true
    ).fetch("receipt")
    pending_snapshot = Marshal.load(Marshal.dump(initial))
    pending_snapshot["checks"] << check(status: "queued", conclusion: nil)
    pending_snapshot["collected_at"] = (NOW + 20).iso8601
    cases = {
      "bindings" => lambda do |candidate|
        candidate["bindings"] = candidate.fetch("bindings").merge("head_sha" => "c" * 40)
      end,
      "snapshot digest" => lambda do |candidate|
        candidate["artifact_settlement"]["snapshot_digest"] = "sha256:#{'0' * 64}"
      end,
      "settlement collected_at" => lambda do |candidate|
        candidate["artifact_settlement"]["collected_at"] = (NOW - 60).iso8601
      end,
      "settled flag" => lambda do |candidate|
        candidate["artifact_settlement"]["settled"] = false
      end,
      "quiet period" => lambda do |candidate|
        candidate["artifact_settlement"]["quiet_period_seconds"] = 29
      end
    }

    cases.each do |label, tamper|
      candidate = Marshal.load(Marshal.dump(receipt))
      tamper.call(candidate)
      result = ConfiguredReviewGate.replay(
        receipt: candidate,
        policy: policy,
        policy_source: JSON.generate(policy),
        snapshot: pending_snapshot,
        now: NOW + 20,
        trusted_live: true
      )

      assert_equal "UNKNOWN", result.fetch("verdict"), label
      assert_equal "configured-review-receipt-projection-mismatch",
                   result.dig("blockers", 0, "code"), label
    end
  end

  def test_replay_rejects_receipt_provenance_or_mutation_authority_tampering
    initial = live_snapshot("checks" => [check], "artifacts" => [artifact])
    receipt = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: initial,
      settled: true,
      now: NOW,
      trusted_live: true
    ).fetch("receipt")
    cases = {
      "mutation eligibility" => [
        ->(candidate) { candidate["mutation_eligible"] = false },
        "configured-review-receipt-evidence-digest-mismatch"
      ],
      "evidence provenance" => [
        lambda do |candidate|
          candidate["evidence"]["provenance"] = "fixture"
          candidate["evidence_digest"] = ConfiguredReviewGate.receipt_evidence_digest(candidate)
          candidate["artifact_settlement"]["snapshot_digest"] =
            ConfiguredReviewGate.semantic_snapshot_digest(candidate["evidence"])
        end,
        "configured-review-receipt-non-live"
      ]
    }

    cases.each do |label, (tamper, blocker_code)|
      candidate = Marshal.load(Marshal.dump(receipt))
      tamper.call(candidate)
      result = ConfiguredReviewGate.replay(
        receipt: candidate,
        policy: policy,
        policy_source: JSON.generate(policy),
        snapshot: initial.merge("collected_at" => (NOW + 20).iso8601),
        now: NOW + 20,
        trusted_live: true
      )

      assert_equal "UNKNOWN", result.fetch("verdict"), label
      assert_equal blocker_code, result.dig("blockers", 0, "code"), label
    end
  end

  def test_replay_rejects_a_self_minted_refreshed_receipt_without_live_settlement
    initial = live_snapshot("checks" => [check], "artifacts" => [artifact])
    receipt = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: initial,
      settled: true,
      now: NOW,
      trusted_live: true
    ).fetch("receipt")
    replay_now = NOW + 301
    receipt["issued_at"] = replay_now.iso8601
    receipt["evidence_digest"] = ConfiguredReviewGate.receipt_evidence_digest(receipt)

    result = ConfiguredReviewGate.replay(
      receipt: receipt,
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: live_snapshot(
        "collected_at" => replay_now.iso8601,
        "checks" => [check],
        "artifacts" => [artifact]
      ),
      now: replay_now,
      trusted_live: true
    )

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-artifact-unsettled",
                 result.dig("blockers", 0, "code")
  end

  def test_replay_rejects_new_pending_or_untriaged_current_head_evidence
    initial = live_snapshot("checks" => [check], "artifacts" => [artifact])
    receipt = ConfiguredReviewGate.evaluate(
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: initial,
      settled: true,
      now: NOW,
      trusted_live: true
    ).fetch("receipt")
    pending = Marshal.load(Marshal.dump(initial))
    pending["checks"] << check(status: "in_progress", conclusion: nil).merge(
      "started_at" => "2026-08-25T12:00:10Z"
    )
    pending["collected_at"] = (NOW + 20).iso8601
    pending_result = ConfiguredReviewGate.replay(
      receipt: receipt,
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: pending,
      settled: true,
      now: NOW + 20,
      trusted_live: true
    )
    assert_equal "configured-review-pending", pending_result.dig("blockers", 0, "code")

    untriaged = Marshal.load(Marshal.dump(initial))
    untriaged["threads"] << thread(id: "T-late")
    untriaged["collected_at"] = (NOW + 20).iso8601
    thread_result = ConfiguredReviewGate.replay(
      receipt: receipt,
      policy: policy,
      policy_source: JSON.generate(policy),
      snapshot: untriaged,
      settled: true,
      now: NOW + 20,
      trusted_live: true
    )
    assert_equal "configured-review-thread-untriaged", thread_result.dig("blockers", 0, "code")
  end

  def test_fixture_cli_replays_pr_4701_as_not_ready
    Dir.mktmpdir("configured-review-gate-test") do |directory|
      policy_path = File.join(directory, "policy.yml")
      receipt_path = File.join(directory, "receipt.json")
      File.write(policy_path, { "review_gate" => policy }.to_yaml)

      stdout, stderr, status = Open3.capture3(
        SCRIPT, "fixture",
        "--policy", policy_path,
        "--snapshot", PR4701_FIXTURE,
        "--receipt", receipt_path
      )

      assert_equal 1, status.exitstatus, stderr
      result = JSON.parse(stdout)
      assert_equal "NOT_READY", result.fetch("verdict")
      assert_equal 5, result.fetch("blockers").count
      refute File.exist?(receipt_path)
    end
  end

  def test_fixture_cli_cannot_forge_live_mutation_authority
    Dir.mktmpdir("configured-review-gate-test") do |directory|
      policy_path = File.join(directory, "policy.yml")
      snapshot_path = File.join(directory, "snapshot.json")
      receipt_path = File.join(directory, "receipt.json")
      File.write(policy_path, { "review_gate" => policy }.to_yaml)
      File.write(
        snapshot_path,
        JSON.pretty_generate(live_snapshot("checks" => [check], "artifacts" => [artifact]))
      )

      stdout, stderr, status = Open3.capture3(
        SCRIPT, "fixture",
        "--policy", policy_path,
        "--snapshot", snapshot_path,
        "--receipt", receipt_path
      )

      assert_equal 0, status.exitstatus, stderr
      result = JSON.parse(stdout)
      receipt = result.fetch("receipt")
      assert_equal "READY", result.fetch("verdict")
      assert_equal false, receipt.fetch("mutation_eligible")
      assert_equal "fixture", receipt.dig("evidence", "provenance")
      assert_equal receipt, JSON.parse(File.read(receipt_path))

      promoted = Marshal.load(Marshal.dump(receipt))
      promoted["mutation_eligible"] = true
      promoted["artifact_settlement"]["snapshot_digest"] =
        ConfiguredReviewGate.semantic_snapshot_digest(
          live_snapshot("checks" => [check], "artifacts" => [artifact])
        )
      replay = ConfiguredReviewGate.replay(
        receipt: promoted,
        policy: policy,
        policy_source: File.read(policy_path),
        snapshot: live_snapshot("checks" => [check], "artifacts" => [artifact]),
        now: Time.iso8601(receipt.fetch("issued_at")),
        trusted_live: true
      )
      assert_equal "UNKNOWN", replay.fetch("verdict")
      assert_equal "configured-review-receipt-evidence-digest-mismatch",
                   replay.dig("blockers", 0, "code")
    end
  end

  def test_replay_cli_rejects_cross_bound_base_before_trusted_policy_selection
    Dir.mktmpdir("configured-review-gate-test") do |directory|
      receipt_path = File.join(directory, "receipt.json")
      initial = live_snapshot("checks" => [check], "artifacts" => [artifact])
      receipt = ConfiguredReviewGate.evaluate(
        policy: policy,
        policy_source: JSON.generate(policy),
        snapshot: initial,
        settled: true,
        now: NOW,
        trusted_live: true
      ).fetch("receipt")
      receipt = JSON.parse(JSON.generate(receipt))
      cases = {
        "cross-bound top-level base" => [
          lambda do |candidate|
            candidate["bindings"] = candidate.fetch("bindings").merge("base_sha" => "c" * 40)
          end,
          "receipt bindings do not match embedded evidence"
        ],
        "unverified embedded base" => [
          lambda do |candidate|
            candidate["bindings"] = candidate.fetch("bindings").merge("base_sha" => "c" * 40)
            candidate["evidence"]["bindings"]["base_sha"] = "c" * 40
          end,
          "configured-review-receipt-evidence-digest-mismatch"
        ]
      }

      cases.each do |label, (tamper, diagnostic)|
        candidate = Marshal.load(Marshal.dump(receipt))
        tamper.call(candidate)
        File.write(receipt_path, JSON.pretty_generate(candidate))
        status = nil
        _stdout, stderr = capture_io do
          status = ConfiguredReviewGate::CLI.new.run([
                                                       "replay", "--repo", REPO, "--pr", PR.to_s, "--host", HOST,
                                                       "--repo-root", directory, "--receipt", receipt_path
                                                     ])
        end

        assert_equal 2, status, label
        assert_includes stderr, diagnostic, label
      end
    end
  end

  def test_live_evaluator_waits_for_one_quiet_period_before_ready
    current = NOW
    sleeps = []
    live = live_snapshot("checks" => [check], "artifacts" => [artifact])
    result = ConfiguredReviewGate::LiveEvaluator.new(
      client: FakeClient.new([live, Marshal.load(Marshal.dump(live))]),
      policy: policy,
      policy_source: JSON.generate(policy),
      expected_base_sha: BASE_SHA,
      wait_seconds: 60,
      poll_seconds: 30,
      clock: -> { current },
      sleeper: lambda { |seconds|
        sleeps << seconds
        current += seconds
      }
    ).run

    assert_equal "READY", result.fetch("verdict")
    assert_equal [30], sleeps
    assert_equal true, result.dig("receipt", "mutation_eligible")
  end

  def test_live_evaluator_keeps_polling_stable_non_ready_evidence_until_ready
    current = NOW
    sleeps = []
    missing = live_snapshot
    ready = live_snapshot("checks" => [check], "artifacts" => [artifact])
    result = ConfiguredReviewGate::LiveEvaluator.new(
      client: FakeClient.new([
                               missing, Marshal.load(Marshal.dump(missing)),
                               ready, Marshal.load(Marshal.dump(ready))
                             ]),
      policy: policy,
      policy_source: JSON.generate(policy),
      expected_base_sha: BASE_SHA,
      wait_seconds: 120,
      poll_seconds: 30,
      clock: -> { current },
      sleeper: lambda { |seconds|
        sleeps << seconds
        current += seconds
      }
    ).run

    assert_equal "READY", result.fetch("verdict")
    assert_equal [30, 30, 30], sleeps
  end

  def test_live_evaluator_returns_stable_non_ready_evidence_at_deadline
    current = NOW
    sleeps = []
    missing = live_snapshot
    result = ConfiguredReviewGate::LiveEvaluator.new(
      client: FakeClient.new([missing]),
      policy: policy,
      policy_source: JSON.generate(policy),
      expected_base_sha: BASE_SHA,
      wait_seconds: 60,
      poll_seconds: 30,
      clock: -> { current },
      sleeper: lambda { |seconds|
        sleeps << seconds
        current += seconds
      }
    ).run

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_includes result.fetch("blockers").map { |blocker| blocker.fetch("code") }, "configured-review-missing"
    assert_equal [30, 30], sleeps
  end

  def test_live_evaluator_stops_waiting_on_provider_failure_without_waiving_it
    current = NOW
    sleeps = []
    failed = live_snapshot(
      "checks" => [check(conclusion: "failure", output: "quota exhausted")]
    )
    result = ConfiguredReviewGate::LiveEvaluator.new(
      client: FakeClient.new([failed]),
      policy: policy,
      policy_source: JSON.generate(policy),
      expected_base_sha: BASE_SHA,
      wait_seconds: 60,
      poll_seconds: 30,
      clock: -> { current },
      sleeper: lambda { |seconds|
        sleeps << seconds
        current += seconds
      }
    ).run

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-quota-exhausted", result.dig("blockers", 0, "code")
    assert_empty sleeps
  end

  def test_live_evaluator_waits_for_missing_authorized_fallback_to_succeed
    fallback_policy = policy
    fallback_policy["fallback"] = {
      "mode" => "named_attested_check",
      "triggers" => ["quota_exhausted"],
      "reviewer" => {
        "id" => "codex-fallback",
        "check_name" => "codex-review",
        "producer" => trusted_producer.slice("app_slug", "workflow_path", "event"),
        "artifact" => {
          "actors" => ["codex-reviewer"],
          "kinds" => ["pull_request_review"]
        }
      }
    }
    primary_failure = check(conclusion: "failure", output: "quota exhausted")
    missing_fallback = live_snapshot("checks" => [primary_failure])
    successful_fallback = live_snapshot(
      "checks" => [primary_failure, check(name: "codex-review")],
      "artifacts" => [artifact(actor: "codex-reviewer")]
    )
    current = NOW
    sleeps = []

    result = ConfiguredReviewGate::LiveEvaluator.new(
      client: FakeClient.new([missing_fallback, successful_fallback, Marshal.load(Marshal.dump(successful_fallback))]),
      policy: fallback_policy,
      policy_source: JSON.generate(fallback_policy),
      expected_base_sha: BASE_SHA,
      wait_seconds: 90,
      poll_seconds: 30,
      clock: -> { current },
      sleeper: lambda { |seconds|
        sleeps << seconds
        current += seconds
      }
    ).run

    assert_equal "READY", result.fetch("verdict")
    assert_equal [30, 30], sleeps
    assert_equal "codex-fallback", result.dig("receipt", "policy", "override", "reviewer_id")
  end

  def test_live_evaluator_waits_for_queued_authorized_fallback_to_succeed
    fallback_policy = policy
    fallback_policy["fallback"] = {
      "mode" => "named_attested_check",
      "triggers" => ["quota_exhausted"],
      "reviewer" => {
        "id" => "codex-fallback",
        "check_name" => "codex-review",
        "producer" => trusted_producer.slice("app_slug", "workflow_path", "event"),
        "artifact" => {
          "actors" => ["codex-reviewer"],
          "kinds" => ["pull_request_review"]
        }
      }
    }
    primary_failure = check(conclusion: "failure", output: "quota exhausted")
    queued_fallback = live_snapshot(
      "checks" => [primary_failure, check(name: "codex-review", status: "queued", conclusion: nil)]
    )
    successful_fallback = live_snapshot(
      "checks" => [primary_failure, check(name: "codex-review")],
      "artifacts" => [artifact(actor: "codex-reviewer")]
    )
    current = NOW
    sleeps = []

    result = ConfiguredReviewGate::LiveEvaluator.new(
      client: FakeClient.new([queued_fallback, successful_fallback, Marshal.load(Marshal.dump(successful_fallback))]),
      policy: fallback_policy,
      policy_source: JSON.generate(fallback_policy),
      expected_base_sha: BASE_SHA,
      wait_seconds: 90,
      poll_seconds: 30,
      clock: -> { current },
      sleeper: lambda { |seconds|
        sleeps << seconds
        current += seconds
      }
    ).run

    assert_equal "READY", result.fetch("verdict")
    assert_equal [30, 30], sleeps
  end

  def test_live_evaluator_stops_on_provider_failure_without_an_authorized_pending_fallback
    fallback_policy = policy
    fallback_policy["fallback"] = {
      "mode" => "named_attested_check",
      "triggers" => ["rate_limited"],
      "reviewer" => {
        "id" => "codex-fallback",
        "check_name" => "codex-review",
        "producer" => trusted_producer.slice("app_slug", "workflow_path", "event"),
        "artifact" => {
          "actors" => ["codex-reviewer"],
          "kinds" => ["pull_request_review"]
        }
      }
    }
    current = NOW
    sleeps = []
    unavailable = live_snapshot(
      "checks" => [
        check(conclusion: "failure", output: "quota exhausted"),
        check(name: "codex-review", status: "queued", conclusion: nil)
      ]
    )

    result = ConfiguredReviewGate::LiveEvaluator.new(
      client: FakeClient.new([unavailable]),
      policy: fallback_policy,
      policy_source: JSON.generate(fallback_policy),
      expected_base_sha: BASE_SHA,
      wait_seconds: 90,
      poll_seconds: 30,
      clock: -> { current },
      sleeper: lambda { |seconds|
        sleeps << seconds
        current += seconds
      }
    ).run

    assert_equal "NOT_READY", result.fetch("verdict")
    assert_equal "configured-review-quota-exhausted", result.dig("blockers", 0, "code")
    assert_empty sleeps
  end
end
