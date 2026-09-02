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
      lifecycle = row.fetch("help_request_lifecycle")
      assert_equal "UNKNOWN", lifecycle.fetch("status")
      assert_includes lifecycle.fetch("error"), "batch id unavailable"
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
          "targets" => ["issue:186"],
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

    target_coordination = {
      "claims" => [{ "agent_id" => "worker-186", "status" => "active" }],
      "heartbeats" => coordination.fetch("heartbeats")
    }

    with_fake_batch_commands(coordination:, target_coordination:) do |env|
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
      assert_equal "issue", row.fetch("target").fetch("kind")
      assert_equal "Codex", row.fetch("editor"), "current heartbeat must override stale lane metadata"
      assert_equal "kona", row.fetch("machine_id")
      assert_equal "codex://threads/019feb28-f6a7-7e53-992e-09fa93633f10", row.fetch("codex_deep_link")
    end
  end

  def test_batch_lane_without_name_remains_explicitly_unknown
    coordination = {
      "batches" => [{
        "batch_id" => "aw-b",
        "repo" => "shakacode/agent-workflows",
        "lanes" => [{
          "owner" => "worker-186",
          "targets" => ["issue:186"]
        }]
      }],
      "events" => []
    }
    target_coordination = {
      "claims" => [{ "agent_id" => "worker-186", "status" => "active" }],
      "heartbeats" => []
    }

    with_fake_batch_commands(coordination:, target_coordination:) do |env|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, "--batch-id", "aw-b", "--json")

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("lane")
      assert_includes row.fetch("unknowns"), "batch lane: registration and claim metadata unavailable"
      assert_includes row.fetch("unknowns"), "help-request lifecycle: lane unavailable for target-scoped replay"
    end
  end

  def test_target_status_does_not_leak_an_unscoped_batch_request
    request_id = "20260823T054818.000000Z-help4846"
    target_coordination = {
      "claims" => [{
        "agent_id" => "worker-462",
        "status" => "active",
        "batch_id" => "aw-help"
      }],
      "heartbeats" => []
    }
    batch_coordination = {
      "events" => [{
        "event_id" => request_id,
        "batch_id" => "aw-help",
        "lane" => "different-lane",
        "agent_id" => "worker-462",
        "type" => "help_requested",
        "reason" => "permission",
        "at" => "2026-08-23T05:48:18Z",
        "message" => "Approve the exact merge head."
      }]
    }

    with_fake_help_lifecycle_commands(target_coordination:, batch_coordination:) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "462",
        "--now", "2026-08-23T10:00:00Z",
        "--help-request-max-open-seconds", "14400",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      lifecycle = row.fetch("help_request_lifecycle")
      assert_equal "aw-help", row.fetch("batch_id")
      assert_equal "UNKNOWN", lifecycle.fetch("status")
      assert_includes lifecycle.fetch("error"), "lane unavailable"
      assert_includes row.fetch("unknowns"), "help-request lifecycle: lane unavailable for target-scoped replay"
    end
  end

  def test_target_status_leaves_batch_lifecycles_empty_for_target_probes
    request_id = "20260823T054818.000000Z-help4846"
    target_coordination = {
      "claims" => [{
        "agent_id" => "worker-462",
        "status" => "active",
        "batch_id" => "aw-help",
        "lane" => "review"
      }],
      "heartbeats" => []
    }
    batch_coordination = {
      "events" => [{
        "event_id" => request_id,
        "batch_id" => "aw-help",
        "lane" => "different-lane",
        "agent_id" => "worker-462",
        "type" => "help_requested",
        "reason" => "permission",
        "at" => "2026-08-23T05:48:18Z",
        "message" => "Approve the exact merge head."
      }]
    }

    with_fake_help_lifecycle_commands(target_coordination:, batch_coordination:) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "462",
        "--now", "2026-08-23T10:00:00Z",
        "--help-request-max-open-seconds", "14400",
        "--json"
      )

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      row = payload.fetch("items").first
      lifecycle = row.fetch("help_request_lifecycle")

      assert_equal "aw-help", row.fetch("batch_id")
      assert_equal "review", row.fetch("lane")
      assert_equal "clear", lifecycle.fetch("status")
      assert_empty payload.fetch("help_request_lifecycles")
    end
  end

  def test_batch_item_reports_open_permission_request_age_and_bounded_outcome
    request_id = "20260823T054818.000000Z-help4846"
    coordination = {
      "batches" => [{
        "batch_id" => "aw-b",
        "repo" => "shakacode/agent-workflows",
        "lanes" => [{
          "name" => "status-skill",
          "owner" => "worker-186",
          "targets" => ["issue:186"]
        }]
      }],
      "events" => [{
        "event_id" => request_id,
        "batch_id" => "aw-b",
        "lane" => "status-skill",
        "agent_id" => "worker-186",
        "type" => "help_requested",
        "reason" => "permission",
        "at" => "2026-08-23T05:48:18Z",
        "message" => "Approve the exact merge head."
      }]
    }
    target_coordination = {
      "claims" => [{ "agent_id" => "worker-186", "status" => "active" }],
      "heartbeats" => []
    }

    with_fake_batch_commands(coordination:, target_coordination:) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--batch-id", "aw-b",
        "--now", "2026-08-23T10:00:00Z",
        "--help-request-max-open-seconds", "14400",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      lifecycle = row.fetch("help_request_lifecycle")
      assert_equal "blocked-user-input", lifecycle.fetch("status")
      assert_equal request_id, lifecycle.fetch("blocking_request_id")
      assert_equal 15_102, lifecycle.fetch("blocking_request").fetch("age_seconds")
      assert_equal request_id, lifecycle.fetch("terminal_action").fetch("request_id")
    end
  end

  def test_batch_status_default_comes_from_the_shared_lifecycle_constant
    source = File.read(SCRIPT)

    assert_includes source,
                    "help_request_max_open_seconds: HelpRequestLifecycle::DEFAULT_MAX_OPEN_SECONDS"
    refute_match(/^DEFAULT_HELP_REQUEST_MAX_OPEN_SECONDS\s*=/, source)
  end

  def test_batch_mode_does_not_turn_a_released_claim_into_a_current_task_link
    batch_coordination = {
      "batches" => [{
        "batch_id" => "aw-b",
        "repo" => "shakacode/agent-workflows",
        "lanes" => [{ "name" => "status-skill", "owner" => "worker-186", "targets" => ["issue:186"] }]
      }]
    }
    target_coordination = {
      "claims" => [{ "agent_id" => "worker-186", "status" => "released" }],
      "heartbeats" => [{
        "agent_id" => "worker-186",
        "host" => "codex",
        "machine_id" => "kona",
        "session_id" => "019feb28-f6a7-7e53-992e-09fa93633f10",
        "session_source" => "codex_thread_id",
        "status" => "done"
      }]
    }

    with_fake_batch_commands(coordination: batch_coordination, target_coordination:) do |env|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, "--batch-id", "aw-b", "--json")

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("holder")
      assert_equal "UNKNOWN", row.fetch("editor")
      assert_equal "UNKNOWN", row.fetch("codex_deep_link")
    end
  end

  def test_batch_lookup_never_falls_back_to_an_unrelated_registration
    coordination = {
      "batches" => [{
        "batch_id" => "different-batch",
        "repo" => "shakacode/agent-workflows",
        "lanes" => [{ "name" => "wrong", "owner" => "wrong-worker", "targets" => ["issue:186"] }]
      }]
    }

    with_fake_batch_commands(coordination:, target_coordination: {}) do |env|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, "--batch-id", "aw-b", "--json")

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      assert_empty payload.fetch("items")
      assert_includes payload.fetch("unknowns"), "batch aw-b: exact registration not found"
    end
  end

  def test_batch_status_keeps_help_request_visibility_without_a_registration_record
    request_id = "request-without-registration"
    coordination = {
      "batches" => [],
      "events" => [{
        "event_id" => request_id,
        "batch_id" => "aw-b",
        "lane" => "review",
        "type" => "help_requested",
        "reason" => "permission",
        "at" => "2026-08-23T05:48:18Z"
      }],
      "section_notes" => { "batches" => "batch not found" }
    }

    with_fake_batch_commands(coordination:, target_coordination: {}) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--batch-id", "aw-b",
        "--now", "2026-08-23T10:00:00Z",
        "--json"
      )

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      lifecycle = payload.fetch("help_request_lifecycles").fetch("aw-b")
      assert_empty payload.fetch("items")
      assert_equal "blocked-user-input", lifecycle.fetch("status")
      assert_equal request_id, lifecycle.fetch("blocking_request_id")
      assert_includes payload.fetch("unknowns"), "batch aw-b: exact registration not found"
    end
  end

  def test_wrong_shaped_batch_json_degrades_to_unknown
    with_fake_batch_commands(coordination: [], target_coordination: {}) do |env|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, "--batch-id", "aw-b", "--json")

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      assert_empty payload.fetch("items")
      assert_includes payload.fetch("unknowns"), "batch aw-b: response was not an object"
      lifecycle = payload.fetch("help_request_lifecycles").fetch("aw-b")
      assert_equal "UNKNOWN", lifecycle.fetch("status")
      assert_includes lifecycle.fetch("error"), "event history unavailable"
    end
  end

  def test_failed_batch_fetch_degrades_to_an_explicit_unknown_lifecycle
    Dir.mktmpdir("batch-status-batch-failure") do |dir|
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        warn "batch backend unavailable"
        exit 1
      RUBY
      env = {
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => File.expand_path("../../pr-batch", __dir__)
      }

      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--batch-id", "aw-b",
        "--json"
      )

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      assert_empty payload.fetch("items")
      assert_includes payload.fetch("unknowns"), "batch aw-b: batch backend unavailable"
      lifecycle = payload.fetch("help_request_lifecycles").fetch("aw-b")
      assert_equal "UNKNOWN", lifecycle.fetch("status")
      assert_includes lifecycle.fetch("error"), "event history unavailable"
    end
  end

  def test_failed_batch_fetch_is_cached_across_targets
    Dir.mktmpdir("batch-status-batch-failure") do |dir|
      counter = File.join(dir, "batch-fetch-count")
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        case ARGV
        when ["status", "--repo", "shakacode/agent-workflows", "--target", "186", "--json"]
          puts JSON.generate("claims" => [{ "agent_id" => "worker-186", "status" => "active", "batch_id" => "aw-fail", "lane" => "lane-186" }], "heartbeats" => [])
        when ["status", "--repo", "shakacode/agent-workflows", "--target", "187", "--json"]
          puts JSON.generate("claims" => [{ "agent_id" => "worker-187", "status" => "active", "batch_id" => "aw-fail", "lane" => "lane-187" }], "heartbeats" => [])
        when ["status", "--batch-id", "aw-fail", "--json"]
          count = File.exist?(#{counter.dump}) ? Integer(File.read(#{counter.dump})) : 0
          File.write(#{counter.dump}, (count + 1).to_s)
          warn "batch backend unavailable"
          exit 1
        else
          abort "unexpected argv: \#{ARGV.inspect}"
        end
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        number = ARGV.fetch(1).split("/").last
        puts JSON.generate("state" => "open", "html_url" => "https://github.com/shakacode/agent-workflows/issues/\#{number}")
      RUBY
      env = {
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => File.expand_path("../../pr-batch", __dir__)
      }

      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "186",
        "--issue", "187",
        "--json"
      )

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      failure_count = payload.fetch("unknowns").count { |item| item.start_with?("batch aw-fail:") }
      assert_equal "1", File.read(counter)
      assert_equal 1, failure_count
      assert(payload.fetch("items").all? { |item| item.fetch("help_request_lifecycle").fetch("status") == "UNKNOWN" })
    end
  end

  def test_lane_help_request_replay_is_cached_across_targets
    source = File.read(SCRIPT)

    assert_includes source, "lane_help_request_lifecycles = {}"
    assert_includes source, "lane_cache_key = [batch_id, lane]"
    assert_includes source, "lane_help_request_lifecycles[lane_cache_key] ||= help_request_lifecycle("
  end

  def test_batch_lookup_requires_the_resolved_exact_id
    coordination = {
      "batches" => [{
        "batch_id" => "aw-b-0716-1535",
        "repo" => "shakacode/agent-workflows",
        "lanes" => [{ "name" => "status-skill", "owner" => "worker-186", "targets" => ["issue:186"] }]
      }]
    }
    with_fake_batch_commands(coordination:, target_coordination: {}) do |env|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, "--batch-id", "aw-b", "--json")

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      assert_empty payload.fetch("items")
      assert_includes payload.fetch("unknowns"), "batch aw-b: exact registration not found"
    end
  end

  def test_batch_lookup_rejects_unrelated_prefix_candidates
    coordination = {
      "batches" => %w[aw-b-one aw-b-two].map do |batch_id|
        { "batch_id" => batch_id, "repo" => "shakacode/agent-workflows", "lanes" => [] }
      end
    }

    with_fake_batch_commands(coordination:, target_coordination: {}) do |env|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, SCRIPT, "--batch-id", "aw-b", "--json")

      assert_predicate status, :success?, stderr
      payload = JSON.parse(stdout)
      assert_empty payload.fetch("items")
      assert_includes payload.fetch("unknowns"), "batch aw-b: exact registration not found"
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

  def test_github_lookup_times_out_without_leaving_its_process_group_alive
    Dir.mktmpdir("batch-status-test") do |dir|
      child_marker = File.join(dir, "gh-child-survived")
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        puts '{"claims":[],"heartbeats":[]}'
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        fork do
          sleep 0.6
          File.write(#{child_marker.dump}, "survived")
        end
        sleep 1
        puts '{"state":"open","html_url":"https://github.com/shakacode/agent-workflows/issues/188"}'
      RUBY
      env = {
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => File.expand_path("../../pr-batch", __dir__)
      }

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "188",
        "--timeout", "0.05",
        "--json"
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_predicate status, :success?, stderr
      assert_operator elapsed, :<, 0.5
      sleep 0.7
      refute File.exist?(child_marker), "timed-out gh child process survived"
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("target").fetch("kind")
      assert_includes row.fetch("unknowns"), "GitHub state: command timed out after 0.05s"
    end
  end

  def test_github_timeout_kills_a_term_ignoring_process_group
    Dir.mktmpdir("batch-status-test") do |dir|
      term_marker = File.join(dir, "term-ignoring-gh-received-term")
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        puts '{"claims":[],"heartbeats":[]}'
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        Signal.trap("TERM") { File.write(#{term_marker.dump}, "ignored") }
        fork do
          loop { sleep 0.1 }
        end
        loop { sleep 0.1 }
      RUBY
      env = {
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => File.expand_path("../../pr-batch", __dir__)
      }

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "188",
        "--timeout", "1.5",
        "--json"
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_predicate status, :success?, stderr
      assert_operator elapsed, :>=, 1.7
      assert_operator elapsed, :<, 3.5, "timeout, TERM/KILL cleanup, and the following bounded probe must not hang"
      assert File.exist?(term_marker), "TERM handler did not run before KILL escalation"
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("target").fetch("kind")
      assert_includes row.fetch("unknowns"), "GitHub state: command timed out after 1.5s"
    end
  end

  def test_blank_pr_batch_skill_dir_ignores_a_relative_helper
    Dir.mktmpdir("batch-status-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      write_executable(File.join(dir, "bin", "agent-coord-bounded"), <<~RUBY)
        #!#{RbConfig.ruby}
        puts "not JSON"
      RUBY
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        puts '{"claims":[],"heartbeats":[]}'
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        puts '{"state":"open","html_url":"https://github.com/shakacode/agent-workflows/issues/188"}'
      RUBY
      env = {
        "PATH" => [dir, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
        "PR_BATCH_SKILL_DIR" => ""
      }

      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "188",
        "--json",
        chdir: dir
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "issue", row.fetch("target").fetch("kind")
      refute(row.fetch("unknowns").any? { |item| item.include?("invalid JSON") })
    end
  end

  def test_released_claim_does_not_supply_current_holder_or_task_identity
    coordination = {
      "claims" => [{
        "agent_id" => "former-worker",
        "status" => "released",
        "host" => "codex",
        "machine_id" => "kona",
        "session_id" => "019feb28-f6a7-7e53-992e-09fa93633f10",
        "session_source" => "codex_thread_id"
      }],
      "heartbeats" => [{
        "agent_id" => "former-worker",
        "host" => "codex",
        "machine_id" => "kona",
        "session_id" => "019feb28-f6a7-7e53-992e-09fa93633f10",
        "session_source" => "codex_thread_id",
        "status" => "done"
      }]
    }

    with_fake_commands(coordination:, github_kind: "issue", number: 188) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "188",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("holder")
      assert_equal "UNKNOWN", row.fetch("editor")
      assert_equal "UNKNOWN", row.fetch("codex_deep_link")
      assert_includes row.fetch("unknowns"), "coordination holder: no active claim"
    end
  end

  def test_missing_active_holder_never_joins_a_heartbeat_without_an_agent_id
    coordination = {
      "claims" => [{ "status" => "active" }],
      "heartbeats" => [{
        "host" => "codex",
        "machine_id" => "kona",
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
        "--repo", "shakacode/agent-workflows",
        "--issue", "188",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("holder")
      assert_equal "UNKNOWN", row.fetch("editor")
      assert_equal "UNKNOWN", row.fetch("runner")
      assert_equal "UNKNOWN", row.fetch("machine_id")
      assert_equal "UNKNOWN", row.fetch("thread_id")
      assert_equal "UNKNOWN", row.fetch("codex_deep_link")
      assert_equal "UNKNOWN", row.fetch("heartbeat")
    end
  end

  def test_host_names_that_only_contain_codex_are_not_classified_as_codex
    coordination = {
      "claims" => [{ "agent_id" => "worker-188", "status" => "active" }],
      "heartbeats" => [{
        "agent_id" => "worker-188",
        "host" => "not-codex",
        "machine_id" => "kona",
        "session_id" => "other-session",
        "session_source" => "agent_coord_session_id",
        "status" => "in_progress"
      }]
    }

    with_fake_commands(coordination:, github_kind: "issue", number: 188) do |env|
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        SCRIPT,
        "--repo", "shakacode/agent-workflows",
        "--issue", "188",
        "--json"
      )

      assert_predicate status, :success?, stderr
      row = JSON.parse(stdout).fetch("items").first
      assert_equal "UNKNOWN", row.fetch("editor")
      assert_equal "UNKNOWN", row.fetch("codex_deep_link")
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

  def with_fake_batch_commands(coordination:, target_coordination:)
    Dir.mktmpdir("batch-status-test") do |dir|
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        case ARGV
        when ["status", "--batch-id", "aw-b", "--json"]
          puts #{JSON.generate(coordination).dump}
        when ["status", "--repo", "shakacode/agent-workflows", "--target", "issue:186", "--json"]
          puts #{JSON.generate(target_coordination).dump}
        else
          abort "unexpected argv: \#{ARGV.inspect}"
        end
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

  def with_fake_help_lifecycle_commands(target_coordination:, batch_coordination:)
    Dir.mktmpdir("batch-status-help-lifecycle-test") do |dir|
      write_executable(File.join(dir, "agent-coord"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        case ARGV
        when ["status", "--repo", "shakacode/agent-workflows", "--target", "462", "--json"]
          puts #{JSON.generate(target_coordination).dump}
        when ["status", "--batch-id", "aw-help", "--json"]
          puts #{JSON.generate(batch_coordination).dump}
        else
          abort "unexpected argv: \#{ARGV.inspect}"
        end
      RUBY
      write_executable(File.join(dir, "gh"), <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        abort "unexpected argv: \#{ARGV.inspect}" unless ARGV == ["api", "repos/shakacode/agent-workflows/issues/462"]
        puts JSON.generate({
          "state" => "open",
          "html_url" => "https://github.com/shakacode/agent-workflows/issues/462"
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
