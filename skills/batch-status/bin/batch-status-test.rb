#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

SCRIPT = File.expand_path("batch-status", __dir__)

class BatchStatusTest < Minitest::Test
  def test_pr_status_returns_codex_runner_machine_and_thread_deep_link
    coordination = {
      "scope" => { "kind" => "target", "repo" => "shakacode/agent-workflows", "target" => "362" },
      "claims" => [{ "agent_id" => "worker-362", "status" => "active" }],
      "heartbeats" => [{
        "agent_id" => "worker-362",
        "host" => "codex",
        "machine_id" => "kona",
        "session_id" => "019feb28-f6a7-7e53-992e-09fa93633f10",
        "session_source" => "codex_thread_id",
        "status" => "in_progress",
        "liveness" => "live"
      }]
    }

    with_fake_commands(coordination:, github_kind: "pr", number: 362) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--pr", "362",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "pr", row.fetch("target").fetch("kind")
      assert_equal "Codex", row.fetch("editor")
      assert_equal "Codex", row.fetch("runner")
      assert_equal "kona", row.fetch("machine_id")
      assert_equal "019feb28-f6a7-7e53-992e-09fa93633f10", row.fetch("thread_id")
      assert_equal "codex://threads/019feb28-f6a7-7e53-992e-09fa93633f10", row.fetch("codex_deep_link")
      assert_equal "kona", row.fetch("codex_deep_link_machine_id")
    end
  end

  def test_issue_status_returns_claude_editor_without_a_codex_link
    coordination = {
      "scope" => { "kind" => "target", "repo" => "shakacode/agent-workflows", "target" => "186" },
      "claims" => [{ "agent_id" => "worker-186", "status" => "active" }],
      "heartbeats" => [{
        "agent_id" => "worker-186",
        "host" => "claude-code",
        "machine_id" => "m5",
        "session_id" => "claude-session-186",
        "session_source" => "agent_coord_session_id",
        "status" => "in_progress"
      }]
    }

    with_fake_commands(coordination:, github_kind: "issue", number: 186) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "186",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "issue", row.fetch("target").fetch("kind")
      assert_equal "Claude", row.fetch("editor")
      assert_equal "m5", row.fetch("machine_id")
      assert_equal "UNKNOWN", row.fetch("codex_deep_link")
    end
  end

  def test_batch_id_joins_lane_owner_to_current_heartbeat_identity
    coordination = {
      "scope" => { "kind" => "batch", "batch_id" => "aw-b" },
      "batches" => [{
        "batch_id" => "aw-b",
        "repo" => "shakacode/agent-workflows",
        "lanes" => [{
          "name" => "status-skill",
          "owner" => "worker-186",
          "targets" => ["186"],
          "host" => "claude-code"
        }]
      }],
      "heartbeats" => [{
        "agent_id" => "worker-186",
        "host" => "codex",
        "machine_id" => "kona",
        "session_id" => "019feb28-f6a7-7e53-992e-09fa93633f10",
        "session_source" => "codex_thread_id",
        "status" => "validating"
      }]
    }

    with_fake_batch_commands(coordination:) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--batch-id", "aw-b",
        "--json"
      )

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      assert_equal "aw-b", payload.fetch("batch_id")
      row = payload.fetch("items").first
      assert_equal "status-skill", row.fetch("lane")
      assert_equal "Codex", row.fetch("editor"), "current heartbeat must override stale lane metadata"
      assert_equal "kona", row.fetch("machine_id")
      assert_equal "codex://threads/019feb28-f6a7-7e53-992e-09fa93633f10", row.fetch("codex_deep_link")
    end
  end

  def test_rejects_an_unsafe_repository_before_running_external_commands
    stdout, stderr, status = Open3.capture3(
      { "PATH" => "" },
      RbConfig.ruby,
      SCRIPT,
      "--repo", "shakacode/../../private",
      "--pr", "1",
      "--json"
    )

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "invalid repository"
  end

  def test_rejects_a_nonpositive_pr_number
    stdout, stderr, status = Open3.capture3(
      { "PATH" => "" },
      RbConfig.ruby,
      SCRIPT,
      "--repo", "shakacode/agent-workflows",
      "--pr", "0",
      "--json"
    )

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "PR and issue numbers must be positive"
  end

  def test_auto_detects_target_kind_and_explains_missing_codex_link_identity
    coordination = {
      "claims" => [{ "agent_id" => "worker-188", "status" => "active" }],
      "heartbeats" => [{
        "agent_id" => "worker-188",
        "host" => "codex",
        "session_id" => "019feb28-f6a7-7e53-992e-09fa93633f10",
        "session_source" => "codex_thread_id",
        "status" => "in_progress"
      }]
    }

    with_fake_commands(coordination:, github_kind: "issue", number: 188) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--target", "shakacode/agent-workflows#188",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "issue", row.fetch("target").fetch("kind")
      assert_equal "Codex", row.fetch("editor")
      assert_equal "UNKNOWN", row.fetch("machine_id")
      assert_equal "UNKNOWN", row.fetch("codex_deep_link")
      assert_includes row.fetch("unknowns"), "Codex deep link: machine_id missing"
    end
  end

  def test_wrong_shaped_github_json_degrades_to_unknown
    Dir.mktmpdir("batch-status-test") do |dir|
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        puts '{"claims":[],"heartbeats":[]}'
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        puts '[]'
      RUBY
      env = {
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => File.expand_path("../../pr-batch", __dir__)
      }

      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--target", "shakacode/agent-workflows#188",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("target").fetch("kind")
      assert_equal "UNKNOWN", row.fetch("github_state")
      assert_includes row.fetch("unknowns"), "GitHub state: response was not an object"
    end
  end

  private

  def with_fake_commands(coordination:, github_kind:, number:)
    Dir.mktmpdir("batch-status-test") do |dir|
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        abort "unexpected argv: \#{ARGV.inspect}" unless ARGV == ["status", "--repo", "shakacode/agent-workflows", "--target", #{number.to_s.dump}, "--json"]
        puts #{JSON.generate(coordination).dump}
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        abort "unexpected argv: \#{ARGV.inspect}" unless ARGV == ["api", "repos/shakacode/agent-workflows/issues/#{number}"]
        payload = { "state" => "open", "html_url" => "https://github.com/shakacode/agent-workflows/#{github_kind == 'pr' ? 'pull' : 'issues'}/#{number}" }
        payload["pull_request"] = {} if #{github_kind.dump} == "pr"
        puts JSON.generate(payload)
      RUBY

      yield({
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => File.expand_path("../../pr-batch", __dir__)
      })
    end
  end

  def with_fake_batch_commands(coordination:)
    Dir.mktmpdir("batch-status-test") do |dir|
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        abort "unexpected argv: \#{ARGV.inspect}" unless ARGV == ["status", "--batch-id", "aw-b", "--json"]
        puts #{JSON.generate(coordination).dump}
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        abort "unexpected argv: \#{ARGV.inspect}" unless ARGV == ["api", "repos/shakacode/agent-workflows/issues/186"]
        puts JSON.generate({
          "state" => "open",
          "html_url" => "https://github.com/shakacode/agent-workflows/issues/186"
        })
      RUBY

      yield({
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => File.expand_path("../../pr-batch", __dir__)
      })
    end
  end

  def write_executable(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end
end
