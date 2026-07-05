#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("task-observer", __dir__)

class TaskObserverTest < Minitest::Test
  def test_init_and_status_use_codex_memory_root
    Dir.mktmpdir("task-observer") do |home|
      out = run!("init", env: { "CODEX_HOME" => home })
      assert_includes out, "initialized"

      root = File.join(home, "memories", "task-observer")
      assert_directory root
      assert_directory File.join(root, "observations")
      assert_directory File.join(root, "staged-updates")

      status = JSON.parse(run!("status", "--json", env: { "CODEX_HOME" => home }))
      assert_equal root, status.fetch("memory_root")
      assert_equal true, status.fetch("initialized")
      assert_equal 0, status.fetch("observations")
      assert_equal 0, status.fetch("staged_updates")
    end
  end

  def test_init_and_status_use_claude_memory_root_when_codex_home_is_unset
    Dir.mktmpdir("task-observer") do |home|
      out = run!("init", env: { "CLAUDE_HOME" => home })
      assert_includes out, "initialized"

      root = File.join(home, "memories", "task-observer")
      status = JSON.parse(run!("status", "--json", env: { "CLAUDE_HOME" => home }))
      assert_equal root, status.fetch("memory_root")
      assert_equal true, status.fetch("initialized")
    end
  end

  def test_runner_env_does_not_leak_parent_agent_homes
    Dir.mktmpdir("task-observer-codex") do |codex_home|
      Dir.mktmpdir("task-observer-claude") do |claude_home|
        with_env("CODEX_HOME" => codex_home, "CLAUDE_HOME" => nil, "TASK_OBSERVER_HOME" => nil) do
          run!("init", env: { "CLAUDE_HOME" => claude_home })
          status = JSON.parse(run!("status", "--json", env: { "CLAUDE_HOME" => claude_home }))

          assert_equal File.join(claude_home, "memories", "task-observer"), status.fetch("memory_root")
        end
      end
    end
  end

  def test_append_writes_sanitized_observation_stub
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out = run!(
        "append",
        "--kind", "skill-improvement",
        "--skill", "pr-batch",
        "--summary", "Worker prompts should preserve dependency state as UNKNOWN when private status degrades.",
        "--source", "issue-41-test",
        env: { "CODEX_HOME" => home, "TASK_OBSERVER_TIME" => "2026-07-03T12:00:00Z" }
      )

      assert_includes out, "appended"
      record_path = File.join(home, "memories", "task-observer", "observations", "2026-07-03.jsonl")
      record = JSON.parse(File.read(record_path))
      assert_equal "skill-improvement", record.fetch("kind")
      assert_equal "pr-batch", record.fetch("skill")
      assert_equal "issue-41-test", record.fetch("source")
      assert_equal "staged-review-only", record.fetch("update_mode")
      assert_equal "2026-07-03T12:00:00Z", record.fetch("observed_at")
    end
  end

  def test_list_reads_observation_stubs
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })
      run!(
        "append",
        "--kind", "gap",
        "--summary", "No skill covers a repeated release-note check.",
        "--source", "test",
        env: { "CODEX_HOME" => home, "TASK_OBSERVER_TIME" => "2026-07-03T12:00:00Z" }
      )

      out = run!("list", env: { "CODEX_HOME" => home })
      assert_includes out, "2026-07-03T12:00:00Z"
      assert_includes out, "gap"
      assert_includes out, "No skill covers a repeated release-note check."
    end
  end

  def test_append_rejects_sensitive_material
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "Store password=secret-value for the next run.",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "sensitive material"
    end
  end

  def test_append_rejects_session_cookie_and_private_key_assignments
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      ["session_cookie=abc123", "private_key=abc123", "session cookie: abc123", "private key: abc123"].each do |summary|
        out, status = capture_task_observer(
          "append",
          "--kind", "correction",
          "--summary", summary,
          "--source", "test",
          env: { "CODEX_HOME" => home }
        )

        refute status.success?
        assert_includes out, "sensitive material"
      end
    end
  end

  def test_append_rejects_missing_required_fields_without_stack_trace
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--summary", "A valid sanitized summary.",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "--kind is required"
      refute_includes out, "KeyError"
    end
  end

  def test_append_rejects_stray_arguments
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "gap",
        "--summary", "Worker",
        "prompts",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "unexpected append arguments"
    end
  end

  def test_append_rejects_overlong_source_and_skill_before_privacy_scan
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "gap",
        "--summary", "A valid sanitized summary.",
        "--source", "s" * 501,
        "--skill", "https://127.0.0.1/private",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "--source must be 500 characters or fewer"

      out, status = capture_task_observer(
        "append",
        "--kind", "gap",
        "--summary", "A valid sanitized summary.",
        "--source", "test",
        "--skill", "k" * 501,
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "--skill must be 500 characters or fewer"
    end
  end

  def test_append_rejects_private_urls_with_query_strings
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "See https://internal.example.test/report?token=abc",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "private URL"
    end
  end

  def test_append_rejects_private_urls_without_query_strings
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "See https://internal.example.test/report",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "private URL"
    end
  end

  def test_append_rejects_sensitive_url_paths
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "See https://example.com/report/password=secret",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "private URL"
    end
  end

  def test_append_rejects_url_userinfo_credentials
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "See https://user:secret@example.com/report",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "private URL"
      assert_includes out, "URL credentials"
    end
  end

  def test_append_rejects_non_http_url_userinfo_credentials
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "See ssh://user:secret@example.com/repo",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "private URL"
      assert_includes out, "URL credentials"
    end
  end

  def test_append_rejects_private_ipv6_hosts
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "See https://[::1]/report",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "private URL"
      assert_includes out, "private host"
    end
  end

  def test_append_rejects_malformed_query_strings_without_stack_trace
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "correction",
        "--summary", "See https://example.com/report?foo=%GG",
        "--source", "test",
        env: { "CODEX_HOME" => home }
      )

      refute status.success?
      assert_includes out, "invalid URL"
      refute_includes out, "ArgumentError"
    end
  end

  def test_append_rejects_non_iso_observer_time
    Dir.mktmpdir("task-observer") do |home|
      run!("init", env: { "CODEX_HOME" => home })

      out, status = capture_task_observer(
        "append",
        "--kind", "gap",
        "--summary", "A valid sanitized summary.",
        "--source", "test",
        env: { "CODEX_HOME" => home, "TASK_OBSERVER_TIME" => "July 3, 2026" }
      )

      refute status.success?
      assert_includes out, "TASK_OBSERVER_TIME must be an ISO 8601 timestamp"
    end
  end

  private

  def run!(*args, env: {})
    out, status = capture_task_observer(*args, env: env)
    assert status.success?, out
    out
  end

  def capture_task_observer(*args, env: {})
    full_env = {
      "PATH" => ENV.fetch("PATH"),
      "HOME" => ENV.fetch("HOME"),
      "TASK_OBSERVER_HOME" => nil,
      "CODEX_HOME" => nil,
      "CLAUDE_HOME" => nil
    }.merge(env)
    out, status = Open3.capture2e(full_env, "ruby", SCRIPT, *args)
    [out, status]
  end

  def with_env(overrides)
    previous = overrides.transform_values { nil }
    overrides.each_key { |key| previous[key] = ENV[key] if ENV.key?(key) }
    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def assert_directory(path)
    assert Dir.exist?(path), "Expected #{path} to exist"
  end
end
