#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "digest"
require "fileutils"
require "tmpdir"

HELPER = File.expand_path("agent-run-record", __dir__)
UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
ROOT = File.expand_path("../../..", __dir__)
CONTRACT_DOC = File.join(ROOT, "docs/github-task-prompts-and-run-records.md")

class AgentRunRecordTest < Minitest::Test
  def valid_record
    {
      "contract" => "agent-run-record",
      "version" => 1,
      "run_id" => "123e4567-e89b-42d3-a456-426614174000",
      "launch_idempotency_key" => "65d9f4e3-b51d-4a09-ae97-bd8704aa9aac",
      "repository" => "shakacode/agent-workflows",
      "issue" => {
        "number" => 560,
        "title" => "Use GitHub task prompts and compact append-only run records",
        "url" => "https://github.com/shakacode/agent-workflows/issues/560"
      },
      "brief" => {
        "kind" => "issue-body",
        "url" => "https://github.com/shakacode/agent-workflows/issues/560",
        "content_sha256" => "a" * 64
      },
      "current_main" => {
        "branch" => "main",
        "sha" => "1" * 40
      },
      "runner" => {
        "name" => "Codex",
        "machine" => "M5",
        "model" => "gpt-5.6-sol"
      },
      "workflow_versions" => {
        "worker_start" => {
          "observed_at" => "2026-08-30T02:00:57.829Z",
          "pack_head" => "2" * 40,
          "pr_batch_sha256" => "sha256:#{'3' * 64}",
          "pr_processing_sha256" => "sha256:#{'4' * 64}"
        },
        "later_observations" => []
      },
      "task" => {
        "title" => "AW #560 — GitHub prompts and run records",
        "id" => "01a05064-7c1e-7781-b3f2-6ede21b8ffdd",
        "url" => "UNKNOWN"
      },
      "branch" => "jg-codex/issue-560-run-records",
      "pr" => {
        "number" => "UNKNOWN",
        "url" => "UNKNOWN"
      },
      "state" => "active",
      "outcome" => "pending",
      "latest_material_update" => {
        "at" => "2026-08-30T02:00:57.829Z",
        "summary" => "worker started"
      },
      "blocker" => nil,
      "timestamps" => {
        "launched_at" => "2026-08-30T02:00:57.829Z",
        "observed_at" => "2026-08-30T02:00:59.000Z"
      }
    }
  end

  def run_helper(*arguments, stdin_data: "")
    Open3.capture3(RbConfig.ruby, HELPER, *arguments, stdin_data: stdin_data)
  end

  def with_fake_launch_environment
    Dir.mktmpdir("agent-run-record-test") do |directory|
      repo = File.join(directory, "repo")
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(File.join(repo, ".agents"))
      FileUtils.mkdir_p(File.join(repo, "skills/pr-batch"))
      FileUtils.mkdir_p(File.join(repo, "workflows"))
      FileUtils.mkdir_p(bin)
      File.write(File.join(repo, ".agents/agent-workflow.yml"), "base_branch: main\nrepo_prefix: AW\n")
      File.write(File.join(repo, "skills/pr-batch/SKILL.md"), "pr-batch v-test\n")
      File.write(File.join(repo, "workflows/pr-processing.md"), "workflow v-test\n")
      gh_log = File.join(directory, "gh.log")
      gh = File.join(bin, "gh")
      git = File.join(bin, "git")
      File.write(gh, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
        case "$*" in
          "repo view --json nameWithOwner")
            printf '%s\\n' '{"nameWithOwner":"shakacode/agent-workflows"}'
            ;;
          "issue view 560 --repo shakacode/agent-workflows --json number,title,body,url")
            printf '%s\\n' '{"number":560,"title":"Compact run records","body":"Exact issue bytes\\nsecond line\\n","url":"https://github.com/shakacode/agent-workflows/issues/560"}'
            ;;
          *)
            printf '%s\\n' "unexpected gh arguments: $*" >&2
            exit 91
            ;;
        esac
      SH
      File.write(git, <<~SH)
        #!/bin/sh
        case "$*" in
          "-C #{repo} rev-parse origin/main") printf '%s\\n' '#{'1' * 40}' ;;
          "-C #{repo} rev-parse HEAD") printf '%s\\n' '#{'2' * 40}' ;;
          *) printf '%s\\n' "unexpected git arguments: $*" >&2; exit 92 ;;
        esac
      SH
      FileUtils.chmod(0o755, [gh, git])
      environment = {
        "PATH" => "#{bin}:/usr/bin:/bin",
        "FAKE_GH_LOG" => gh_log
      }
      yield directory, repo, gh_log, environment
    end
  end

  def test_render_keeps_status_compact_and_generated_provenance_collapsed
    stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(valid_record))

    assert status.success?, stderr
    assert_includes stdout, "<!-- agent-run-record:v1 -->"
    assert_includes stdout, "Agent run: Codex on M5 — active / pending"
    assert_includes stdout, "Latest: 2026-08-30T02:00:57.829Z — worker started"
    assert_includes stdout, "<details>\n<summary>Run details</summary>"
    assert_includes stdout, "Run ID: `123e4567-e89b-42d3-a456-426614174000`"
    assert_includes stdout, "Brief SHA-256: `#{'a' * 64}`"
    assert_includes stdout, "Coordination: not recorded (optional)"
    assert_equal 1, stdout.scan("<details>").length
    assert_operator stdout.index("<details>"), :>, stdout.index("Latest:")
  end

  def test_prepare_derives_issue_main_task_and_exact_body_digest_with_selected_queries
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      identity_file = File.join(directory, "launch-identity.json")
      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--format", "json"
      )

      assert status.success?, stderr
      record = JSON.parse(stdout)
      assert_equal "shakacode/agent-workflows", record.fetch("repository")
      assert_equal 560, record.dig("issue", "number")
      assert_equal "AW #560 — Compact run records", record.dig("task", "title")
      assert_equal "main", record.dig("current_main", "branch")
      assert_equal "1" * 40, record.dig("current_main", "sha")
      assert_equal Digest::SHA256.hexdigest("Exact issue bytes\nsecond line\n"),
                   record.dig("brief", "content_sha256")
      assert_match UUID_V4, record.fetch("run_id")
      assert_match UUID_V4, record.fetch("launch_idempotency_key")
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/,
                   record.dig("timestamps", "launched_at"))
      assert File.file?(identity_file), "prepare must persist launch identity before worker launch"
      assert_equal 0o600, File.stat(identity_file).mode & 0o777
      assert_equal [
        "repo view --json nameWithOwner",
        "issue view 560 --repo shakacode/agent-workflows --json number,title,body,url"
      ], File.readlines(gh_log, chomp: true)
    end
  end

  def test_prepare_binds_a_trusted_maintainer_comment_without_reading_the_issue_body
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      gh = File.join(directory, "bin/gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
        case "$*" in
          "repo view --json nameWithOwner")
            printf '%s\\n' '{"nameWithOwner":"shakacode/agent-workflows"}'
            ;;
          "issue view 560 --repo shakacode/agent-workflows --json number,title,url")
            printf '%s\\n' '{"number":560,"title":"Compact run records","url":"https://github.com/shakacode/agent-workflows/issues/560"}'
            ;;
          "api repos/shakacode/agent-workflows/issues/comments/1234 --jq {body: .body, url: .html_url, author: .user.login, author_association: .author_association}")
            printf '%s\\n' '{"body":"Exact maintainer comment bytes\\n","url":"https://github.com/shakacode/agent-workflows/issues/560#issuecomment-1234","author":"justin808","author_association":"MEMBER"}'
            ;;
          *)
            printf '%s\\n' "unexpected gh arguments: $*" >&2
            exit 91
            ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)
      identity_file = File.join(directory, "comment-launch-identity.json")
      comment_url = "https://github.com/shakacode/agent-workflows/issues/560#issuecomment-1234"
      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        "--issue", "560",
        "--brief", "maintainer-comment",
        "--comment-url", comment_url,
        "--trusted-comment-author", "justin808",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--format", "json"
      )

      assert status.success?, stderr
      record = JSON.parse(stdout)
      assert_equal "maintainer-comment", record.dig("brief", "kind")
      assert_equal comment_url, record.dig("brief", "url")
      assert_equal "justin808", record.dig("brief", "author")
      assert_equal "MEMBER", record.dig("brief", "author_association")
      assert_equal Digest::SHA256.hexdigest("Exact maintainer comment bytes\n"),
                   record.dig("brief", "content_sha256")
      assert_equal [
        "repo view --json nameWithOwner",
        "issue view 560 --repo shakacode/agent-workflows --json number,title,url",
        "api repos/shakacode/agent-workflows/issues/comments/1234 --jq " \
          "{body: .body, url: .html_url, author: .user.login, author_association: .author_association}"
      ], File.readlines(gh_log, chomp: true)
    end
  end

  def test_launch_retry_reuses_identity_and_launch_main_while_rerun_uses_a_new_identity
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      main_counter = File.join(directory, "main-counter")
      git = File.join(directory, "bin/git")
      File.write(git, <<~SH)
        #!/bin/sh
        case "$*" in
          "-C #{repo} rev-parse origin/main")
            count=0
            if [ -f "$FAKE_MAIN_COUNTER" ]; then count=$(sed -n '1p' "$FAKE_MAIN_COUNTER"); fi
            count=$((count + 1))
            printf '%s\\n' "$count" > "$FAKE_MAIN_COUNTER"
            case "$count" in
              1) printf '%s\\n' '#{'1' * 40}' ;;
              2) printf '%s\\n' '#{'3' * 40}' ;;
              *) printf '%s\\n' '#{'5' * 40}' ;;
            esac
            ;;
          "-C #{repo} rev-parse HEAD") printf '%s\\n' '#{'2' * 40}' ;;
          *) printf '%s\\n' "unexpected git arguments: $*" >&2; exit 92 ;;
        esac
      SH
      FileUtils.chmod(0o755, git)
      environment["FAKE_MAIN_COUNTER"] = main_counter
      first_identity = File.join(directory, "run-1.json")
      arguments = [
        RbConfig.ruby, HELPER, "prepare",
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", first_identity,
        "--format", "json"
      ]

      first_stdout, first_stderr, first_status = Open3.capture3(environment, *arguments)
      retry_stdout, retry_stderr, retry_status = Open3.capture3(environment, *arguments)
      assert first_status.success?, first_stderr
      assert retry_status.success?, retry_stderr
      first = JSON.parse(first_stdout)
      retry_record = JSON.parse(retry_stdout)
      assert_equal first.fetch("run_id"), retry_record.fetch("run_id")
      assert_equal first.fetch("launch_idempotency_key"), retry_record.fetch("launch_idempotency_key")
      assert_equal first.dig("timestamps", "launched_at"), retry_record.dig("timestamps", "launched_at")
      assert_equal "1" * 40, retry_record.dig("current_main", "sha")

      rerun_arguments = arguments.dup
      rerun_arguments[rerun_arguments.index(first_identity)] = File.join(directory, "run-2.json")
      rerun_stdout, rerun_stderr, rerun_status = Open3.capture3(environment, *rerun_arguments)
      assert rerun_status.success?, rerun_stderr
      rerun = JSON.parse(rerun_stdout)
      refute_equal first.fetch("run_id"), rerun.fetch("run_id")
      refute_equal first.fetch("launch_idempotency_key"), rerun.fetch("launch_idempotency_key")
      assert_equal "5" * 40, rerun.dig("current_main", "sha")
    end
  end

  def test_documented_v1_contract_covers_briefs_lifecycle_retries_and_optional_coordination
    document = File.read(CONTRACT_DOC, encoding: "UTF-8")
    rendered_table_text = document.gsub("\\|", "|")

    assert_includes document, "issue-body"
    assert_includes document, "maintainer-comment"
    assert_includes rendered_table_text, "launch-pending | active | waiting | blocked | PR-ready | completed"
    assert_includes rendered_table_text, "pending | merged | closed | failed | reverted"
    assert_includes document, "launch_idempotency_key"
    assert_includes document, "content_sha256"
    assert_includes document, "same identity file"
    assert_includes document, "new identity file"
    assert_includes document, "Coordination is optional"
    assert_includes document, "captured directly by the launcher"
    assert_includes document, "workflow_versions.worker_start"
    assert_includes document, "workflow_versions.later_observations"
    assert_includes document, "observe-workflows"
    assert_includes document, "agent-run-record:v0"
    assert_includes document, "Use PR-batch to fix this issue"
  end

  def test_prepare_rejects_an_invalid_configured_task_prefix_before_persisting_identity
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      File.write(File.join(repo, ".agents/agent-workflow.yml"), "base_branch: main\nrepo_prefix: lowercase\n")
      identity_file = File.join(directory, "invalid-prefix-identity.json")
      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--format", "json"
      )

      refute status.success?
      assert_includes stderr, "configured repo_prefix must be 1-6 uppercase ASCII letters or digits"
      refute File.exist?(identity_file), "invalid task-title configuration must fail before launch identity is saved"
    end
  end

  def test_state_and_outcome_are_independent_closed_fields
    %w[launch-pending active waiting blocked PR-ready completed].each do |state_value|
      record = valid_record.merge("state" => state_value)
      _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
      assert status.success?, "state #{state_value.inspect} must be accepted: #{stderr}"
    end
    %w[pending merged closed failed reverted].each do |outcome_value|
      record = valid_record.merge("outcome" => outcome_value)
      _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
      assert status.success?, "outcome #{outcome_value.inspect} must be accepted: #{stderr}"
    end

    { "state" => "integrating", "outcome" => "cancelled" }.each do |field, invalid_value|
      record = valid_record.merge(field => invalid_value)
      _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
      refute status.success?, "#{field} must reject an open-ended value"
      assert_includes stderr, "#{field} must be one of"
    end
  end

  def test_prepare_rejects_more_than_one_blocker_before_github_queries
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      identity_file = File.join(directory, "duplicate-blocker.json")
      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--blocker", "first",
        "--blocker", "second"
      )

      refute status.success?
      assert_includes stderr, "--blocker may be supplied at most once"
      refute File.exist?(gh_log), "invalid generated metadata must fail before any GitHub query"
      refute File.exist?(identity_file)
    end
  end

  def test_prepare_rejects_invalid_lifecycle_before_persisting_launch_identity
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      identity_file = File.join(directory, "invalid-lifecycle.json")
      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--state", "integrating",
        "--outcome", "cancelled"
      )

      refute status.success?
      assert_includes stderr, "--state must be one of"
      refute File.exist?(identity_file), "invalid lifecycle values must fail before launch identity is saved"
    end
  end

  def test_later_workflow_changes_append_timestamped_observations_without_rewriting_worker_start
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      identity_file = File.join(directory, "workflow-history.json")
      prepare_arguments = [
        RbConfig.ruby, HELPER,
        "prepare",
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--format", "json"
      ]
      stdout, stderr, status = Open3.capture3(environment, *prepare_arguments)
      assert status.success?, stderr
      record = JSON.parse(stdout)
      worker_start = record.dig("workflow_versions", "worker_start")
      assert worker_start, "prepare must preserve the immutable worker-start observation"
      assert_empty record.dig("workflow_versions", "later_observations")

      File.write(File.join(repo, "skills/pr-batch/SKILL.md"), "pr-batch v-later\n")
      retry_stdout, retry_stderr, retry_status = Open3.capture3(environment, *prepare_arguments)
      assert retry_status.success?, retry_stderr
      retry_record = JSON.parse(retry_stdout)
      assert_equal worker_start, retry_record.dig("workflow_versions", "worker_start"),
                   "same-launch retries must reuse the original worker-start observation"
      assert_empty retry_record.dig("workflow_versions", "later_observations")

      later_stdout, later_stderr, later_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "observe-workflows",
        "--repo-root", repo,
        stdin_data: JSON.generate(record)
      )
      assert later_status.success?, later_stderr
      updated = JSON.parse(later_stdout)
      assert_equal worker_start, updated.dig("workflow_versions", "worker_start")
      later = updated.dig("workflow_versions", "later_observations")
      assert_equal 1, later.length
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, later.first.fetch("observed_at"))
      refute_equal worker_start.fetch("pr_batch_sha256"), later.first.fetch("pr_batch_sha256")

      unchanged_stdout, unchanged_stderr, unchanged_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "observe-workflows",
        "--repo-root", repo,
        stdin_data: JSON.generate(updated)
      )
      assert unchanged_status.success?, unchanged_stderr
      unchanged = JSON.parse(unchanged_stdout)
      assert_equal later, unchanged.dig("workflow_versions", "later_observations"),
                   "unchanged workflow versions must not add redundant history"
    end
  end
end
