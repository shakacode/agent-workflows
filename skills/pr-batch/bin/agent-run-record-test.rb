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
PR_BATCH_SKILL = File.join(ROOT, "skills/pr-batch/SKILL.md")
PR_PROCESSING_WORKFLOW = File.join(ROOT, "workflows/pr-processing.md")
SELECTED_AT = "2026-08-30T02:00:55.829Z"
PROMPT_CREATED_AT = "2026-08-30T02:00:56.829Z"
DEFAULT_SELECTION_DIGEST = Digest::SHA256.hexdigest("Exact issue bytes\nsecond line\n")

class AgentRunRecordTest < Minitest::Test
  def valid_record
    {
      "contract" => "agent-run-record",
      "version" => 1,
      "run_id" => "123e4567-e89b-42d3-a456-426614174000",
      "launch_idempotency_key" => "65d9f4e3-b51d-4a09-ae97-bd8704aa9aac",
      "repository" => "shakacode/agent-workflows",
      "work_item" => {
        "kind" => "issue",
        "number" => 560,
        "title" => "Use GitHub task prompts and compact append-only run records",
        "url" => "https://github.com/shakacode/agent-workflows/issues/560"
      },
      "prompt_source" => {
        "kind" => "issue-body",
        "url" => "https://github.com/shakacode/agent-workflows/issues/560",
        "digest_at_selection" => "a" * 64,
        "digest_at_launch" => "a" * 64,
        "digest_observed_by_worker" => "a" * 64
      },
      "prompt_transport" => {
        "kind" => "handoff-envelope",
        "digest_at_launch" => "a" * 64
      },
      "current_main" => {
        "branch" => "main",
        "sha" => "1" * 40
      },
      "runner" => {
        "name" => "Codex",
        "machine" => "M5",
        "model_at_prompt_creation" => "gpt-5.6-sol",
        "model_at_worker_start" => "UNKNOWN"
      },
      "workflow_versions" => {
        "prompt_creation" => {
          "observed_at" => "2026-08-30T02:00:56.829Z",
          "pack_head" => "2" * 40,
          "pr_batch_sha256" => "sha256:#{'3' * 64}",
          "pr_processing_sha256" => "sha256:#{'4' * 64}"
        },
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
        "selected_at" => "2026-08-30T02:00:55.829Z",
        "prompt_created_at" => "2026-08-30T02:00:56.829Z",
        "worker_digest_observed_at" => "2026-08-30T02:00:57.829Z",
        "worker_started_at" => "2026-08-30T02:00:57.829Z",
        "observed_at" => "2026-08-30T02:00:59.000Z"
      }
    }
  end

  def run_helper(*arguments, stdin_data: "")
    Open3.capture3(RbConfig.ruby, HELPER, *arguments, stdin_data: stdin_data)
  end

  def launch_timestamp_arguments(digest = DEFAULT_SELECTION_DIGEST)
    [
      "--selected-at", SELECTED_AT,
      "--prompt-created-at", PROMPT_CREATED_AT,
      "--prompt-digest-at-selection", digest
    ]
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
          "issue view 560 --repo shakacode/agent-workflows --json body,url")
            printf '%s\\n' '{"body":"Exact issue bytes\\nsecond line\\n","url":"https://github.com/shakacode/agent-workflows/issues/560"}'
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
          "-C #{repo} rev-parse --show-toplevel") printf '%s\\n' '#{repo}' ;;
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

  def test_representative_v1_record_is_executable_and_keeps_provenance_collapsed
    stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(valid_record))

    assert status.success?, stderr
    assert_includes stdout, "<!-- agent-run-record:v1 -->"
    assert_includes stdout, "Agent run: Codex on M5 — active / pending"
    assert_includes stdout, "Latest: 2026-08-30T02:00:57.829Z — worker started"
    assert_includes stdout, "<details>\n<summary>Run details</summary>"
    assert_includes stdout, "Run ID: `123e4567-e89b-42d3-a456-426614174000`"
    assert_includes stdout, "Prompt source: issue-body — `https://github.com/shakacode/agent-workflows/issues/560`"
    assert_includes stdout, "Prompt digest at selection: `#{'a' * 64}`"
    assert_includes stdout, "Prompt digest at launch: `#{'a' * 64}`"
    assert_includes stdout, "Prompt digest observed by worker: `#{'a' * 64}`"
    assert_includes stdout, "Prompt transport: handoff-envelope"
    assert_includes stdout, "Selected at: 2026-08-30T02:00:55.829Z"
    assert_includes stdout, "Prompt created at: 2026-08-30T02:00:56.829Z"
    assert_includes stdout, "Worker prompt digest observed at: 2026-08-30T02:00:57.829Z"
    assert_includes stdout, "Worker started at: 2026-08-30T02:00:57.829Z"
    assert_includes stdout, "Model at prompt creation: gpt-5.6-sol"
    assert_includes stdout, "Model observed by worker: UNKNOWN"
    assert_includes stdout, "Configured base at launch: `main`@`#{'1' * 40}`"
    refute_includes stdout, "Current main:"
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
        *launch_timestamp_arguments,
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
      assert_equal "issue", record.dig("work_item", "kind")
      assert_equal 560, record.dig("work_item", "number")
      assert_equal "AW #560 — Compact run records", record.dig("task", "title")
      assert_equal "main", record.dig("current_main", "branch")
      assert_equal "1" * 40, record.dig("current_main", "sha")
      assert_equal Digest::SHA256.hexdigest("Exact issue bytes\nsecond line\n"),
                   record.dig("prompt_source", "digest_at_selection")
      assert_equal "pending", record.dig("prompt_source", "digest_at_launch")
      assert_equal "pending", record.dig("prompt_source", "digest_observed_by_worker")
      refute record.fetch("prompt_source").key?("body")
      refute_includes stdout, "Exact issue bytes"
      assert_equal "pending", record.dig("timestamps", "worker_digest_observed_at")
      assert_nil record.fetch("prompt_transport")
      assert_match UUID_V4, record.fetch("run_id")
      assert_match UUID_V4, record.fetch("launch_idempotency_key")
      assert_equal SELECTED_AT, record.dig("timestamps", "selected_at")
      assert_equal PROMPT_CREATED_AT, record.dig("timestamps", "prompt_created_at")
      assert_equal "pending", record.dig("timestamps", "worker_started_at")
      assert_equal "UNKNOWN", record.dig("runner", "model_at_prompt_creation")
      assert_equal "UNKNOWN", record.dig("runner", "model_at_worker_start")
      assert_equal record.dig("timestamps", "prompt_created_at"),
                   record.dig("workflow_versions", "prompt_creation", "observed_at")
      assert_equal "pending", record.dig("workflow_versions", "worker_start", "observed_at")
      assert File.file?(identity_file), "prepare must persist launch identity before worker launch"
      assert_equal 0o600, File.stat(identity_file).mode & 0o777
      assert_equal [
        "repo view --json nameWithOwner",
        "issue view 560 --repo shakacode/agent-workflows --json number,title,body,url"
      ], File.readlines(gh_log, chomp: true)
    end
  end

  def test_title_only_issue_hashes_null_body_as_empty_utf8_at_all_three_boundaries
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      identity_file = File.join(directory, "title-only-identity.json")
      empty_digest = Digest::SHA256.hexdigest("")
      gh = File.join(directory, "bin/gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        case "$*" in
          "repo view --json nameWithOwner")
            printf '%s\n' '{"nameWithOwner":"shakacode/agent-workflows"}'
            ;;
          "issue view 560 --repo shakacode/agent-workflows --json number,title,body,url")
            printf '%s\n' '{"number":560,"title":"Title only","body":null,"url":"https://github.com/shakacode/agent-workflows/issues/560"}'
            ;;
          "issue view 560 --repo shakacode/agent-workflows --json body,url")
            printf '%s\n' '{"body":null,"url":"https://github.com/shakacode/agent-workflows/issues/560"}'
            ;;
          *) exit 91 ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)

      selected_json, selected_error, selected_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments(empty_digest),
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--format", "json"
      )
      assert selected_status.success?, selected_error

      launched_json, launched_error, launched_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "verify-launch",
        "--handoff-envelope",
        stdin_data: selected_json
      )
      assert launched_status.success?, launched_error

      started_json, started_error, started_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        "--pack-root", repo,
        stdin_data: launched_json
      )
      assert started_status.success?, started_error

      started = JSON.parse(started_json)
      assert_equal empty_digest, started.dig("prompt_source", "digest_at_selection")
      assert_equal empty_digest, started.dig("prompt_source", "digest_at_launch")
      assert_equal empty_digest, started.dig("prompt_source", "digest_observed_by_worker")
    end
  end

  def test_prepare_rejects_source_drift_since_real_selection_without_creating_identity
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      identity_file = File.join(directory, "drift-before-prepare.json")
      selected_digest = Digest::SHA256.hexdigest("Earlier selected issue body")
      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments(selected_digest),
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file,
        "--format", "json"
      )

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "prompt source changed since selection"
      assert_includes stderr, "deliberately start a new run"
      assert_includes stderr, "rerun the security preflight"
      refute File.exist?(identity_file)
      assert_equal [
        "repo view --json nameWithOwner",
        "issue view 560 --repo shakacode/agent-workflows --json number,title,body,url"
      ], File.readlines(gh_log, chomp: true)
    end
  end

  def test_pull_request_body_uses_exact_canonical_bytes_at_all_three_boundaries
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      canonical_body = "Cafe\u0301  \n"
      expected_digest = Digest::SHA256.hexdigest(canonical_body.encode(Encoding::UTF_8))
      pull_request_url = "https://github.com/shakacode/agent-workflows/pull/575"
      full_response = JSON.generate(
        number: 575, title: "Readable prompts", body: canonical_body, url: pull_request_url
      )
      body_response = JSON.generate(body: canonical_body, url: pull_request_url)
      gh = File.join(directory, "bin/gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
        case "$*" in
          "repo view --json nameWithOwner")
            printf '%s\\n' '{"nameWithOwner":"shakacode/agent-workflows"}'
            ;;
          "pr view 575 --repo shakacode/agent-workflows --json number,title,body,url")
            printf '%s\\n' '#{full_response}'
            ;;
          "pr view 575 --repo shakacode/agent-workflows --json body,url")
            printf '%s\\n' '#{body_response}'
            ;;
          *) exit 91 ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)

      prepare_stdout, prepare_stderr, prepare_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments(expected_digest),
        "--pull-request", "575",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", File.join(directory, "pr-launch-identity.json"),
        "--format", "json"
      )
      assert prepare_status.success?, prepare_stderr

      selected = JSON.parse(prepare_stdout)
      assert_equal "pull-request", selected.dig("work_item", "kind")
      assert_equal 575, selected.dig("work_item", "number")
      assert_equal "pull-request-body", selected.dig("prompt_source", "kind")
      assert_equal "https://github.com/shakacode/agent-workflows/pull/575",
                   selected.dig("prompt_source", "url")
      assert_equal expected_digest, selected.dig("prompt_source", "digest_at_selection")

      launch_stdout, launch_stderr, launch_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "verify-launch",
        "--handoff-envelope",
        stdin_data: prepare_stdout
      )
      assert launch_status.success?, launch_stderr
      launched = JSON.parse(launch_stdout)
      assert_equal expected_digest, launched.dig("prompt_source", "digest_at_launch")

      worker_stdout, worker_stderr, worker_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        stdin_data: launch_stdout
      )
      assert worker_status.success?, worker_stderr
      assert_equal expected_digest,
                   JSON.parse(worker_stdout).dig("prompt_source", "digest_observed_by_worker")
      assert_equal [
        "repo view --json nameWithOwner",
        "pr view 575 --repo shakacode/agent-workflows --json number,title,body,url",
        "pr view 575 --repo shakacode/agent-workflows --json body,url",
        "pr view 575 --repo shakacode/agent-workflows --json body,url"
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
        *launch_timestamp_arguments(Digest::SHA256.hexdigest("Exact maintainer comment bytes\n")),
        "--issue", "560",
        "--prompt-source", "maintainer-comment",
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
      assert_equal "maintainer-comment", record.dig("prompt_source", "kind")
      assert_equal comment_url, record.dig("prompt_source", "url")
      assert_equal "justin808", record.dig("prompt_source", "author")
      assert_equal "MEMBER", record.dig("prompt_source", "author_association")
      assert_equal Digest::SHA256.hexdigest("Exact maintainer comment bytes\n"),
                   record.dig("prompt_source", "digest_at_selection")
      assert_equal [
        "repo view --json nameWithOwner",
        "issue view 560 --repo shakacode/agent-workflows --json number,title,url",
        "api repos/shakacode/agent-workflows/issues/comments/1234 --jq " \
          "{body: .body, url: .html_url, author: .user.login, author_association: .author_association}"
      ], File.readlines(gh_log, chomp: true)
    end
  end

  def test_prepare_binds_a_trusted_comment_on_a_pull_request_without_reading_its_body
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      gh = File.join(directory, "bin/gh")
      comment_url = "https://github.com/shakacode/agent-workflows/pull/575#issuecomment-5678"
      File.write(gh, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
        case "$*" in
          "repo view --json nameWithOwner")
            printf '%s\\n' '{"nameWithOwner":"shakacode/agent-workflows"}'
            ;;
          "pr view 575 --repo shakacode/agent-workflows --json number,title,url")
            printf '%s\\n' '{"number":575,"title":"Readable prompts","url":"https://github.com/shakacode/agent-workflows/pull/575"}'
            ;;
          "api repos/shakacode/agent-workflows/issues/comments/5678 --jq {body: .body, url: .html_url, author: .user.login, author_association: .author_association}")
            printf '%s\\n' '{"body":"Trusted PR comment","url":"#{comment_url}","author":"justin808","author_association":"OWNER"}'
            ;;
          *) exit 91 ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)

      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments(Digest::SHA256.hexdigest("Trusted PR comment")),
        "--pull-request", "575",
        "--prompt-source", "maintainer-comment",
        "--comment-url", comment_url,
        "--trusted-comment-author", "justin808",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", File.join(directory, "pr-comment-launch-identity.json"),
        "--format", "json"
      )

      assert status.success?, stderr
      record = JSON.parse(stdout)
      assert_equal "pull-request", record.dig("work_item", "kind")
      assert_equal "maintainer-comment", record.dig("prompt_source", "kind")
      assert_equal comment_url, record.dig("prompt_source", "url")
      assert_equal Digest::SHA256.hexdigest("Trusted PR comment"),
                   record.dig("prompt_source", "digest_at_selection")
      assert_equal [
        "repo view --json nameWithOwner",
        "pr view 575 --repo shakacode/agent-workflows --json number,title,url",
        "api repos/shakacode/agent-workflows/issues/comments/5678 --jq " \
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
          "-C #{repo} rev-parse --show-toplevel") printf '%s\\n' '#{repo}' ;;
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
        RbConfig.ruby, HELPER, "prepare", *launch_timestamp_arguments,
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
      assert_equal first.dig("prompt_source", "digest_at_selection"),
                   retry_record.dig("prompt_source", "digest_at_selection")
      assert_equal first.dig("timestamps", "selected_at"), retry_record.dig("timestamps", "selected_at")
      assert_equal first.dig("timestamps", "prompt_created_at"),
                   retry_record.dig("timestamps", "prompt_created_at")
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

  def test_document_is_the_versioned_v1_contract_owner
    document = File.read(CONTRACT_DOC, encoding: "UTF-8")
    prompt_section = document[/^## Canonical human prompt\n.*?(?=^## )/m]
    compact_section = document[/^## Compact record\n.*?(?=^## )/m]
    expected_prompt = <<~PROMPT
      Repository: OWNER/REPO
      Work item: <exact issue, pull-request, trusted maintainer-comment URL, or accepted plan-state:// or batch:// durable reference>
      Task name: <repository, work item, and purpose>
      Instruction: Use PR-batch to complete this work item against the repository's configured base branch.
      Merge authority: <auto|ask>
      Human available after: <optional time; omit this line when not supplied>
    PROMPT

    assert_match(/\A# GitHub Task Prompts And Run Records\n/, document)
    assert_match(/The `agent-run-record` v1\s+contract/, document)
    assert_equal 1, document.scan(/^## V1 field contract$/).length
    refute_nil prompt_section
    refute_nil compact_section
    assert_equal [expected_prompt], prompt_section.scan(/```text\n(.*?)```\n/m).flatten
    assert_equal 1, document.scan("`Fix issue #123 using $pr-batch with merge authority ask.`").length
    assert_includes document, "Each GitHub-backed lane handled by `agent-run-record` v1"
    assert_equal 1, compact_section.scan("<!-- agent-launcher-run-record:v1 -->").length
    assert_equal 0, compact_section.scan("<!-- agent-run-record:v1 -->").length
    assert_equal 1, compact_section.scan("<summary>Run details</summary>").length
    assert_equal 1, compact_section.scan("- Target lanes:").length
    assert_includes document, "`record_destination`"
    assert_includes document, "`lane_id`, dispatcher, `instance_id`, and launch token"
    assert_includes document, "Each execution publishes exactly one `agent-launcher-run-record:v1`"
    assert_includes document, "does not inject outer identity, destination, or replay values into the helper"
    assert_includes document, "never independently published"
    assert_includes document, "not applicable — trusted-ad-hoc-override"
  end

  def test_prepare_requires_exactly_one_issue_or_pull_request_target
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      common = [
        RbConfig.ruby, HELPER, "prepare", *launch_timestamp_arguments,
        "--runner", "Codex", "--machine", "M5", "--repo-root", repo,
        "--identity-file", File.join(directory, "target.json")
      ]
      _missing_stdout, missing_stderr, missing_status = Open3.capture3(environment, *common)
      _both_stdout, both_stderr, both_status = Open3.capture3(
        environment, *common, "--issue", "560", "--pull-request", "575"
      )

      refute missing_status.success?
      assert_includes missing_stderr, "exactly one of --issue or --pull-request is required"
      refute both_status.success?
      assert_includes both_stderr, "exactly one of --issue or --pull-request is required"
      refute File.exist?(gh_log), "ambiguous targets must fail before GitHub reads"
    end
  end

  def test_prepare_rejects_poison_inputs_before_github_or_identity_creation
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      cases = [
        [
          "swapped timestamps",
          ["--selected-at", "2026-08-30T02:00:57.000Z", "--prompt-created-at", "2026-08-30T02:00:56.000Z",
           "--prompt-digest-at-selection", DEFAULT_SELECTION_DIGEST],
          "Selected at must not be after Prompt created at"
        ],
        [
          "future prompt timestamp",
          ["--selected-at", "2999-08-30T02:00:55.000Z", "--prompt-created-at", "2999-08-30T02:00:56.000Z",
           "--prompt-digest-at-selection", DEFAULT_SELECTION_DIGEST],
          "Prompt created at must not be after preparation preflight time"
        ],
        ["invalid lifecycle", [*launch_timestamp_arguments, "--state", "active", "--outcome", "failed"],
         "invalid state/outcome lifecycle"],
        ["blocked without blocker", [*launch_timestamp_arguments, "--state", "blocked", "--outcome", "pending"],
         "blocked/pending requires one meaningful blocker"],
        ["invalid result PR", [*launch_timestamp_arguments, "--pr", "0"],
         "--pr must be a positive integer"],
        ["missing selection digest", ["--selected-at", SELECTED_AT, "--prompt-created-at", PROMPT_CREATED_AT],
         "--prompt-digest-at-selection is required"],
        ["malformed selection digest", [*launch_timestamp_arguments, "--prompt-digest-at-selection", "bad"],
         "--prompt-digest-at-selection has invalid format"],
        ["trusted ad-hoc helper bypass", [*launch_timestamp_arguments, "--prompt-source", "trusted-ad-hoc-override"],
         "prompt source must be issue-body or maintainer-comment"]
      ]

      cases.each_with_index do |(label, extra_arguments, expected_error), index|
        identity_file = File.join(directory, "poison-#{index}.json")
        _stdout, stderr, status = Open3.capture3(
          environment,
          RbConfig.ruby,
          HELPER,
          "prepare",
          *extra_arguments,
          "--issue", "560",
          "--runner", "Codex",
          "--machine", "M5",
          "--repo-root", repo,
          "--identity-file", identity_file,
          "--format", "json"
        )

        refute status.success?, label
        assert_includes stderr, expected_error, label
        refute File.exist?(identity_file), "#{label} must not create an identity file"
      end
      refute File.exist?(gh_log), "poison inputs must fail before GitHub reads"
    end
  end

  def test_identity_reuse_rejects_stored_selection_after_prompt_creation
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      identity_file = File.join(directory, "ordered-identity.json")
      arguments = [
        RbConfig.ruby, HELPER, "prepare", *launch_timestamp_arguments,
        "--issue", "560", "--runner", "Codex", "--machine", "M5",
        "--repo-root", repo, "--identity-file", identity_file, "--format", "json"
      ]
      _stdout, stderr, status = Open3.capture3(environment, *arguments)
      assert status.success?, stderr

      identity = JSON.parse(File.read(identity_file, encoding: "UTF-8"))
      identity["selected_at"] = "2026-08-30T02:00:57.000Z"
      identity["prompt_created_at"] = "2026-08-30T02:00:56.000Z"
      File.write(identity_file, "#{JSON.pretty_generate(identity)}\n")

      retry_stdout, retry_stderr, retry_status = Open3.capture3(environment, *arguments)
      refute retry_status.success?
      assert_empty retry_stdout
      assert_includes retry_stderr, "identity selected_at must not be after prompt_created_at"
    end
  end

  def test_pr_batch_entrypoints_are_short_distinct_v1_contract_routers
    sections = []

    [PR_BATCH_SKILL, PR_PROCESSING_WORKFLOW].each do |path|
      content = File.read(path, encoding: "UTF-8")
      section = content[/^(?:##|###) Launcher Run Record\n.*?(?=^(?:##|###) |\z)/m]

      refute_nil section, path
      assert_includes section, "agent-run-record v1 contract", path
      assert_match(%r{\]\([^)]*docs/github-task-prompts-and-run-records\.md(?:#[^)]*)?\)}, section, path)
      assert_match(/\[`agent-run-record` CLI\]\([^)]*agent-run-record\)/, section, path)
      assert_match(/GitHub(?: source|\s+source)? and\s+digest evidence/m, section, path)
      assert_match(/never inject.*through the helper/m, section, path)
      assert_match(/trusted-ad-hoc-override.*bypass|bypass.*trusted-ad-hoc-override/m, section, path)
      assert_operator section.lines.length, :<=, 12, path
      sections << section
    end

    refute_equal sections.first, sections.last
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
        *launch_timestamp_arguments,
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

  def test_state_and_outcome_follow_the_closed_lifecycle_matrix
    valid_pairs = [
      %w[launch-pending pending],
      %w[active pending],
      %w[waiting pending],
      %w[PR-ready pending],
      %w[blocked pending],
      *%w[merged closed failed reverted].map { |outcome| ["completed", outcome] }
    ]
    valid_pairs.each do |state_value, outcome_value|
      record = valid_record.merge("state" => state_value, "outcome" => outcome_value)
      record["blocker"] = "waiting for maintainer decision" if state_value == "blocked"
      _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
      assert status.success?, "#{state_value}/#{outcome_value} must be accepted: #{stderr}"
    end

    record = valid_record.merge("state" => "blocked", "outcome" => "pending", "blocker" => nil)
    _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
    refute status.success?
    assert_includes stderr, "blocked/pending requires one meaningful blocker"

    invalid_pairs = [
      %w[active failed],
      %w[waiting closed],
      %w[PR-ready merged],
      %w[completed pending],
      %w[blocked merged],
      %w[blocked closed],
      %w[blocked reverted]
    ]
    invalid_pairs.each do |state_value, outcome_value|
      record = valid_record.merge("state" => state_value, "outcome" => outcome_value)
      _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
      refute status.success?, "#{state_value}/#{outcome_value} must be rejected"
      assert_includes stderr, "invalid state/outcome lifecycle"
    end

    { "state" => "integrating", "outcome" => "cancelled" }.each do |field, invalid_value|
      record = valid_record.merge(field => invalid_value)
      _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
      refute status.success?, "#{field} must reject an open-ended value"
      assert_includes stderr, "#{field} must be one of"
    end
  end

  def test_timestamps_require_utc_milliseconds_and_nondecreasing_event_order
    invalid_timestamps = [
      ["selected_at", "2026-08-30T02:00:55Z", "UTC RFC3339 with millisecond precision"],
      ["selected_at", "2026-08-29T16:00:55.829-10:00", "UTC RFC3339 with millisecond precision"],
      ["selected_at", "2026-08-30T02:00:58.829Z", "Selected at must not be after Prompt created at"],
      ["worker_started_at", "2026-08-30T02:00:55.000Z", "Prompt created at must not be after Worker started at"],
      ["worker_started_at", "2026-08-30T02:01:00.000Z", "Worker started at must not be after record observation"]
    ]
    invalid_timestamps.each do |field, value, expected_error|
      record = valid_record
      record.fetch("timestamps")[field] = value
      if field == "worker_started_at"
        record.fetch("workflow_versions")["worker_start"]["observed_at"] = value
      end
      _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))

      refute status.success?
      assert_includes stderr, expected_error
    end

    record = valid_record
    record.fetch("latest_material_update")["at"] = "2026-08-30T02:01:00.000Z"
    _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
    refute status.success?
    assert_includes stderr, "latest material update must not be after record observation"

    record = valid_record
    record.fetch("workflow_versions")["later_observations"] = [
      {
        "observed_at" => "2026-08-30T02:00:58.500Z",
        "pack_head" => "5" * 40,
        "pr_batch_sha256" => "sha256:#{'6' * 64}",
        "pr_processing_sha256" => "sha256:#{'7' * 64}"
      },
      {
        "observed_at" => "2026-08-30T02:00:58.000Z",
        "pack_head" => "8" * 40,
        "pr_batch_sha256" => "sha256:#{'9' * 64}",
        "pr_processing_sha256" => "sha256:#{'a' * 64}"
      }
    ]
    _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
    refute status.success?
    assert_includes stderr, "later workflow observations must be nondecreasing after Worker started at"

    record = valid_record
    record.fetch("workflow_versions")["later_observations"] = [
      {
        "observed_at" => "2026-08-30T02:00:57.000Z",
        "pack_head" => "5" * 40,
        "pr_batch_sha256" => "sha256:#{'6' * 64}",
        "pr_processing_sha256" => "sha256:#{'7' * 64}"
      }
    ]
    _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))
    refute status.success?
    assert_includes stderr, "later workflow observations must be nondecreasing after Worker started at"
  end

  def test_pending_worker_start_requires_all_field_granular_unknown_values
    record = valid_record
    record.fetch("prompt_source")["digest_observed_by_worker"] = "pending"
    record.fetch("timestamps")["worker_digest_observed_at"] = "pending"
    record.fetch("timestamps")["worker_started_at"] = "pending"
    record.fetch("workflow_versions")["worker_start"] = {
      "observed_at" => "pending",
      "pack_head" => "UNKNOWN",
      "pr_batch_sha256" => "UNKNOWN"
    }

    _stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))

    refute status.success?
    assert_includes stderr, "pr_processing_sha256 is required"
  end

  def test_prepare_rejects_more_than_one_blocker_before_github_queries
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      identity_file = File.join(directory, "duplicate-blocker.json")
      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments,
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
        *launch_timestamp_arguments,
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
        *launch_timestamp_arguments,
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
      assert_equal "pending", record.dig("timestamps", "worker_started_at")
      assert_equal "pending", record.dig("workflow_versions", "worker_start", "observed_at")

      launch_stdout, launch_stderr, launch_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "verify-launch",
        "--handoff-envelope",
        stdin_data: JSON.generate(record)
      )
      assert launch_status.success?, launch_stderr
      record = JSON.parse(launch_stdout)
      assert_equal record.dig("prompt_source", "digest_at_selection"),
                   record.dig("prompt_source", "digest_at_launch")
      assert_equal "pending", record.dig("prompt_source", "digest_observed_by_worker")
      assert_equal "handoff-envelope", record.dig("prompt_transport", "kind")

      started_stdout, started_stderr, started_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        stdin_data: JSON.generate(record)
      )
      assert started_status.success?, started_stderr
      record = JSON.parse(started_stdout)
      worker_start = record.dig("workflow_versions", "worker_start")
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/,
                   record.dig("timestamps", "worker_started_at"))
      assert_equal record.dig("timestamps", "worker_started_at"), worker_start.fetch("observed_at")
      assert_equal record.dig("timestamps", "worker_started_at"),
                   record.dig("timestamps", "worker_digest_observed_at")
      assert_equal "UNKNOWN", record.dig("runner", "model_at_worker_start")
      assert_equal record.dig("prompt_source", "digest_at_launch"),
                   record.dig("prompt_source", "digest_observed_by_worker")
      assert_empty record.dig("workflow_versions", "later_observations")

      File.write(File.join(repo, "skills/pr-batch/SKILL.md"), "pr-batch v-later\n")
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

      _repeat_stdout, repeat_stderr, repeat_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        stdin_data: JSON.generate(updated)
      )
      refute repeat_status.success?
      assert_includes repeat_stderr, "worker-start observation is immutable"
    end
  end

  def test_issue_body_source_rejects_comment_selector_options
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      identity_file = File.join(directory, "ambiguous-source.json")
      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments,
        "--issue", "560",
        "--comment-url", "https://github.com/shakacode/agent-workflows/issues/560#issuecomment-1234",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file
      )

      refute status.success?
      assert_includes stderr, "comment options require --prompt-source maintainer-comment"
      refute File.exist?(gh_log)
      refute File.exist?(identity_file)
    end
  end

  def test_prepare_requires_launcher_captured_selection_and_prompt_creation_timestamps
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      identity_file = File.join(directory, "missing-launcher-timestamps.json")
      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        "--issue", "560",
        "--runner", "Codex",
        "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", identity_file
      )

      refute status.success?
      assert_includes stderr, "--selected-at is required"
      refute File.exist?(gh_log)
      refute File.exist?(identity_file)
    end
  end

  def test_launch_verification_rejects_selection_digest_drift_without_mutation
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      identity_file = File.join(directory, "drifted-prompt.json")
      prepare_arguments = [
        RbConfig.ruby, HELPER, "prepare", *launch_timestamp_arguments,
        "--issue", "560", "--runner", "Codex", "--machine", "M5",
        "--repo-root", repo, "--identity-file", identity_file, "--format", "json"
      ]
      stdout, stderr, status = Open3.capture3(environment, *prepare_arguments)
      assert status.success?, stderr

      gh = File.join(directory, "bin/gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        case "$*" in
          "issue view 560 --repo shakacode/agent-workflows --json body,url")
            printf '%s\\n' '{"body":"Changed after launch","url":"https://github.com/shakacode/agent-workflows/issues/560"}'
            ;;
          *) exit 91 ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)
      launch_stdout, launch_stderr, launch_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "verify-launch",
        "--handoff-envelope",
        stdin_data: stdout
      )

      refute launch_status.success?
      assert_empty launch_stdout
      assert_includes launch_stderr, "deliberately start a new run"
      assert_includes launch_stderr, "rerun the security preflight"
      original = JSON.parse(stdout)
      assert_equal "pending", original.dig("prompt_source", "digest_at_launch")
      assert_equal "pending", original.dig("prompt_source", "digest_observed_by_worker")
      assert_nil original.fetch("prompt_transport")
    end
  end

  def test_worker_digest_mismatch_exits_nonzero_with_durable_failed_record_before_start
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      record = valid_record
      comment_url = "https://github.com/shakacode/agent-workflows/issues/560#issuecomment-1234"
      record["prompt_source"] = {
        "kind" => "maintainer-comment",
        "url" => comment_url,
        "digest_at_selection" => Digest::SHA256.hexdigest("Original comment bytes\n"),
        "digest_at_launch" => Digest::SHA256.hexdigest("Original comment bytes\n"),
        "digest_observed_by_worker" => "pending",
        "author" => "justin808",
        "author_association" => "MEMBER"
      }
      record["prompt_transport"] = {
        "kind" => "handoff-envelope",
        "digest_at_launch" => Digest::SHA256.hexdigest("Original comment bytes\n")
      }
      record.fetch("timestamps")["worker_digest_observed_at"] = "pending"
      record.fetch("timestamps")["worker_started_at"] = "pending"
      record.fetch("workflow_versions")["worker_start"] = {
        "observed_at" => "pending",
        "pack_head" => "UNKNOWN",
        "pr_batch_sha256" => "UNKNOWN",
        "pr_processing_sha256" => "UNKNOWN"
      }
      gh = File.join(directory, "bin/gh")
      File.write(gh, <<~SH)
        #!/bin/sh
        case "$*" in
          "api repos/shakacode/agent-workflows/issues/comments/1234 --jq {body: .body, url: .html_url}")
            printf '%s\\n' '{"body":"Changed comment bytes\\n","url":"#{comment_url}"}'
            ;;
          *) exit 91 ;;
        esac
      SH
      FileUtils.chmod(0o755, gh)

      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        stdin_data: JSON.generate(record)
      )

      refute status.success?
      assert_includes stderr, "worker prompt digest does not match transported launch digest"
      failed = JSON.parse(stdout)
      observed_digest = Digest::SHA256.hexdigest("Changed comment bytes\n")
      assert_equal observed_digest, failed.dig("prompt_source", "digest_observed_by_worker")
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/,
                   failed.dig("timestamps", "worker_digest_observed_at"))
      assert_equal "pending", failed.dig("timestamps", "worker_started_at")
      assert_equal "pending", failed.dig("workflow_versions", "worker_start", "observed_at")
      assert_equal "blocked", failed.fetch("state")
      assert_equal "failed", failed.fetch("outcome")
      assert_equal "worker prompt digest mismatch; source interpretation refused", failed.fetch("blocker")
      assert_equal failed.dig("timestamps", "worker_digest_observed_at"),
                   failed.dig("latest_material_update", "at")

      rendered, render_stderr, render_status = run_helper("render", stdin_data: JSON.generate(failed))
      assert render_status.success?, render_stderr
      assert_includes rendered, "blocked / failed"
      assert_includes rendered, "Blocker: worker prompt digest mismatch; source interpretation refused"
      assert_includes rendered, "Worker started at: pending"

      invalid = JSON.parse(JSON.generate(failed))
      invalid["state"] = "active"
      invalid["outcome"] = "pending"
      invalid["blocker"] = nil
      _invalid_stdout, invalid_stderr, invalid_status = run_helper(
        "render", stdin_data: JSON.generate(invalid)
      )
      refute invalid_status.success?
      assert_includes invalid_stderr,
                      "nonmatching worker digest requires the blocked/failed pre-start failure record"

      retry_stdout, retry_stderr, retry_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        stdin_data: stdout
      )
      refute retry_status.success?
      assert_empty retry_stdout
      assert_includes retry_stderr, "worker prompt verification failure is terminal"
    end
  end

  def test_worker_start_rejects_corrupted_selection_launch_transport_chain_before_refetch
    with_fake_launch_environment do |_directory, repo, gh_log, environment|
      record = valid_record
      record["prompt_source"]["digest_at_selection"] = "a" * 64
      record["prompt_source"]["digest_at_launch"] = "b" * 64
      record["prompt_source"]["digest_observed_by_worker"] = "pending"
      record["prompt_transport"]["digest_at_launch"] = "b" * 64
      record["timestamps"]["worker_digest_observed_at"] = "pending"
      record["timestamps"]["worker_started_at"] = "pending"
      record["workflow_versions"]["worker_start"] = {
        "observed_at" => "pending",
        "pack_head" => "UNKNOWN",
        "pr_batch_sha256" => "UNKNOWN",
        "pr_processing_sha256" => "UNKNOWN"
      }

      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        stdin_data: JSON.generate(record)
      )

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "Prompt digest at launch must equal Prompt digest at selection"
      refute File.exist?(gh_log), "a corrupted transported record must fail before source re-fetch"
    end
  end

  def test_launch_verification_requires_bound_handoff_envelope
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      prepare_stdout, prepare_stderr, prepare_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments,
        "--issue", "560", "--runner", "Codex", "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", File.join(directory, "transport.json"), "--format", "json"
      )
      assert prepare_status.success?, prepare_stderr

      _missing_stdout, missing_stderr, missing_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "verify-launch",
        stdin_data: prepare_stdout
      )
      refute missing_status.success?
      assert_includes missing_stderr, "bound handoff envelope is required"

      _worker_stdout, worker_stderr, worker_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "mark-worker-started",
        "--repo-root", repo,
        stdin_data: prepare_stdout
      )
      refute worker_status.success?
      assert_includes worker_stderr, "transported Prompt digest at launch is required"

      launch_stdout, launch_stderr, launch_status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "verify-launch",
        "--handoff-envelope",
        stdin_data: prepare_stdout
      )
      assert launch_status.success?, launch_stderr
      launched = JSON.parse(launch_stdout)
      assert_equal "handoff-envelope", launched.dig("prompt_transport", "kind")
      refute launched["prompt_transport"].key?("reference")
      assert_equal launched.dig("prompt_source", "digest_at_launch"),
                   launched.dig("prompt_transport", "digest_at_launch")
    end
  end

  def test_render_escapes_markdown_links_from_untrusted_visible_fields
    record = valid_record
    record.fetch("work_item")["title"] = "[click](https://example.invalid)"

    stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))

    assert status.success?, stderr
    refute_includes stdout, "[click](https://example.invalid)"
    assert_includes stdout, "\\[click\\]\\(https&#58;//example.invalid\\)"
  end

  def test_render_neutralizes_gfm_extended_autolinks_from_untrusted_visible_fields
    record = valid_record
    record.fetch("work_item")["title"] = "www.phish.example user@evil.example"

    stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))

    assert status.success?, stderr
    refute_includes stdout, "www.phish.example"
    refute_includes stdout, "user@evil.example"
    assert_includes stdout, "www&#46;phish.example"
    assert_includes stdout, "user&#8203;@evil.example"
  end

  def test_contract_requires_outer_dynamic_values_to_use_the_hostile_value_rendering_contract
    document = File.read(CONTRACT_DOC, encoding: "UTF-8")
    assert_match(
      /The outer renderer applies the helper renderer's HTML escaping, Markdown\s+neutralization, URI-scheme neutralization, and inert-code treatment/m,
      document
    )

    ["target titles", "lane IDs", "every replay-tuple value", "record destinations", "durable references"].each do |field|
      assert_includes document, field
    end
    assert_match(/No outer dynamic value may create a Markdown link, HTML element, or\s+active URI\./m, document)
  end

  def test_helper_title_rendering_primitives_neutralize_representative_hostile_values
    hostile_values = {
      "Markdown link with an active URI" => "[click](javascript:alert(1))",
      "HTML element" => "lane-1<img src=x onerror=alert(1)>",
      "inline-code break with a data URI" => "`tuple`](data:text/html,pwn)",
      "link termination with an active URI" => "https://example.invalid)[open](javascript:alert(1))",
      "custom scheme with an HTML element" => "plan-state://run/path<img src=x onerror=alert(1)>"
    }

    hostile_values.each do |label, hostile_value|
      record = valid_record
      record.fetch("work_item")["title"] = hostile_value
      stdout, stderr, status = run_helper("render", stdin_data: JSON.generate(record))

      assert status.success?, "#{label}: #{stderr}"
      refute_includes stdout, hostile_value, label
      refute_match(/\]\((?:javascript|data):/i, stdout, label)
      refute_includes stdout, "<img", label
    end
  end

  def test_explicit_installed_pack_root_is_observed_separately_from_consumer_repo
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      pack_root = File.join(directory, "installed-agent-workflows")
      FileUtils.mkdir_p(File.join(pack_root, "skills/pr-batch"))
      FileUtils.mkdir_p(File.join(pack_root, "workflows"))
      File.write(File.join(pack_root, "skills/pr-batch/SKILL.md"), "installed skill\n")
      File.write(File.join(pack_root, "workflows/pr-processing.md"), "installed workflow\n")
      git = File.join(directory, "bin/git")
      File.write(git, <<~SH)
        #!/bin/sh
        case "$*" in
          "-C #{repo} rev-parse origin/main") printf '%s\\n' '#{'1' * 40}' ;;
          "-C #{pack_root} rev-parse --show-toplevel") printf '%s\\n' '#{pack_root}' ;;
          "-C #{pack_root} rev-parse HEAD") printf '%s\\n' '#{'9' * 40}' ;;
          *) exit 92 ;;
        esac
      SH
      FileUtils.chmod(0o755, git)

      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments,
        "--issue", "560", "--runner", "Codex", "--machine", "M5",
        "--repo-root", repo, "--pack-root", pack_root,
        "--identity-file", File.join(directory, "installed-pack.json"), "--format", "json"
      )

      assert status.success?, stderr
      record = JSON.parse(stdout)
      observation = record.dig("workflow_versions", "prompt_creation")
      assert_equal "9" * 40, observation.fetch("pack_head")
      assert_equal "sha256:#{Digest::SHA256.hexdigest("installed skill\n")}",
                   observation.fetch("pr_batch_sha256")
    end
  end

  def test_consumer_repo_requires_explicit_loaded_pack_root
    with_fake_launch_environment do |directory, repo, gh_log, environment|
      FileUtils.rm_rf(File.join(repo, "skills"))
      FileUtils.rm_rf(File.join(repo, "workflows"))

      _stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments,
        "--issue", "560", "--runner", "Codex", "--machine", "M5",
        "--repo-root", repo,
        "--identity-file", File.join(directory, "missing-pack.json")
      )

      refute status.success?
      assert_includes stderr, "--pack-root is required when the loaded Agent Workflows pack is separate"
      refute File.exist?(gh_log), "pack provenance must fail before GitHub reads"
    end
  end

  def test_explicit_pinned_agents_pack_uses_digests_without_consumer_head
    with_fake_launch_environment do |directory, repo, _gh_log, environment|
      pack_root = File.join(repo, ".agents")
      FileUtils.mkdir_p(File.join(pack_root, "skills/pr-batch"))
      FileUtils.mkdir_p(File.join(pack_root, "workflows"))
      File.write(File.join(pack_root, "skills/pr-batch/SKILL.md"), "pinned skill\n")
      File.write(File.join(pack_root, "workflows/pr-processing.md"), "pinned workflow\n")
      git = File.join(directory, "bin/git")
      File.write(git, <<~SH)
        #!/bin/sh
        case "$*" in
          "-C #{repo} rev-parse origin/main") printf '%s\\n' '#{'1' * 40}' ;;
          "-C #{pack_root} rev-parse --show-toplevel") printf '%s\\n' '#{repo}' ;;
          *) exit 92 ;;
        esac
      SH
      FileUtils.chmod(0o755, git)

      stdout, stderr, status = Open3.capture3(
        environment,
        RbConfig.ruby,
        HELPER,
        "prepare",
        *launch_timestamp_arguments,
        "--issue", "560", "--runner", "Codex", "--machine", "M5",
        "--repo-root", repo, "--pack-root", pack_root,
        "--identity-file", File.join(directory, "pinned-pack.json"), "--format", "json"
      )

      assert status.success?, stderr
      observation = JSON.parse(stdout).dig("workflow_versions", "prompt_creation")
      assert_equal "UNKNOWN", observation.fetch("pack_head")
      assert_equal "sha256:#{Digest::SHA256.hexdigest("pinned skill\n")}",
                   observation.fetch("pr_batch_sha256")
    end
  end
end
