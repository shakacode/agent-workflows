#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-refresh", __dir__)

class AgentWorkflowsRefreshTest < Minitest::Test
  def test_codex_refresh_uses_native_marketplace_upgrade
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "codex")

      out, status = run_refresh(bin_dir, calls, "--host", "codex")

      assert_equal 0, status.exitstatus, out
      assert_equal ["codex\tplugin\tmarketplace\tupgrade\tagent-workflows"], File.readlines(calls, chomp: true)
      assert_includes out, "REFRESH_COMPLETE host=codex"
    end
  end

  def test_claude_refresh_updates_marketplace_before_plugin
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "claude")

      out, status = run_refresh(bin_dir, calls, "--host", "claude")

      assert_equal 0, status.exitstatus, out
      assert_equal(
        [
          "claude\tplugin\tmarketplace\tupdate\tagent-workflows",
          "claude\tplugin\tupdate\tscw@agent-workflows"
        ],
        File.readlines(calls, chomp: true)
      )
      assert_includes out, "REFRESH_COMPLETE host=claude"
    end
  end

  def test_auto_selects_explicit_codex_home
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "codex")

      out, status = run_refresh(bin_dir, calls, env: { "CODEX_HOME" => File.join(bin_dir, "codex-home") })

      assert_equal 0, status.exitstatus, out
      assert_equal ["codex\tplugin\tmarketplace\tupgrade\tagent-workflows"], File.readlines(calls, chomp: true)
    end
  end

  def test_auto_selects_explicit_claude_home
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "claude")

      out, status = run_refresh(bin_dir, calls, env: { "CLAUDE_HOME" => File.join(bin_dir, "claude-home") })

      assert_equal 0, status.exitstatus, out
      assert_equal "claude\tplugin\tmarketplace\tupdate\tagent-workflows", File.readlines(calls, chomp: true).first
    end
  end

  def test_auto_selects_existing_claude_home
    with_fake_hosts do |bin_dir, calls|
      home = File.join(File.dirname(bin_dir), "home")
      FileUtils.mkdir_p(File.join(home, ".claude"))
      write_fake_host(bin_dir, "claude")

      out, status = run_refresh(bin_dir, calls)

      assert_equal 0, status.exitstatus, out
      assert_equal "claude\tplugin\tmarketplace\tupdate\tagent-workflows", File.readlines(calls, chomp: true).first
    end
  end

  def test_auto_defaults_to_codex_when_no_host_home_is_detected
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "codex")

      out, status = run_refresh(bin_dir, calls)

      assert_equal 0, status.exitstatus, out
      assert_equal "codex\tplugin\tmarketplace\tupgrade\tagent-workflows", File.readlines(calls, chomp: true).first
    end
  end

  def test_auto_rejects_ambiguous_host_homes
    with_fake_hosts do |bin_dir, calls|
      out, status = run_refresh(
        bin_dir,
        calls,
        env: {
          "CODEX_HOME" => File.join(bin_dir, "codex-home"),
          "CLAUDE_HOME" => File.join(bin_dir, "claude-home")
        }
      )

      assert_equal 64, status.exitstatus, out
      assert_includes out, "found both Codex and Claude homes"
      assert_includes out, "pass --host codex or --host claude"
      refute_path_exists calls
    end
  end

  def test_missing_codex_executable_fails_with_setup_guidance
    with_fake_hosts do |bin_dir, calls|
      out, status = run_refresh(bin_dir, calls, "--host", "codex", path: "/usr/bin:/bin")

      refute status.success?, out
      assert_includes out, "codex"
      assert_includes out, "Install or configure the Codex CLI"
      refute_includes out, "REFRESH_COMPLETE"
    end
  end

  def test_missing_claude_executable_fails_with_setup_guidance
    with_fake_hosts do |bin_dir, calls|
      out, status = run_refresh(bin_dir, calls, "--host", "claude", path: "/usr/bin:/bin")

      refute status.success?, out
      assert_includes out, "claude"
      assert_includes out, "Install or configure the Claude CLI"
      refute_includes out, "REFRESH_COMPLETE"
    end
  end

  def test_invalid_host_exits_with_usage
    with_fake_hosts do |bin_dir, calls|
      out, status = run_refresh(bin_dir, calls, "--host", "other")

      assert_equal 64, status.exitstatus, out
      assert_includes out, "Usage: agent-workflows-refresh"
      assert_includes out, "codex|claude|auto"
      refute_path_exists calls
    end
  end

  def test_native_codex_failure_preserves_output_and_status
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "codex")
      env = {
        "AGENT_WORKFLOWS_REFRESH_TEST_FAIL_COMMAND" => "codex plugin marketplace upgrade agent-workflows",
        "AGENT_WORKFLOWS_REFRESH_TEST_FAIL_STATUS" => "23"
      }

      out, status = run_refresh(bin_dir, calls, "--host", "codex", env: env)

      assert_equal 23, status.exitstatus, out
      assert_includes out, "native codex failure"
      refute_includes out, "REFRESH_COMPLETE"
    end
  end

  def test_claude_stops_when_marketplace_update_fails
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "claude")
      env = {
        "AGENT_WORKFLOWS_REFRESH_TEST_FAIL_COMMAND" => "claude plugin marketplace update agent-workflows",
        "AGENT_WORKFLOWS_REFRESH_TEST_FAIL_STATUS" => "19"
      }

      out, status = run_refresh(bin_dir, calls, "--host", "claude", env: env)

      assert_equal 19, status.exitstatus, out
      assert_equal ["claude\tplugin\tmarketplace\tupdate\tagent-workflows"], File.readlines(calls, chomp: true)
      refute_includes out, "REFRESH_COMPLETE"
    end
  end

  def test_claude_plugin_failure_preserves_output_and_status
    with_fake_hosts do |bin_dir, calls|
      write_fake_host(bin_dir, "claude")
      env = {
        "AGENT_WORKFLOWS_REFRESH_TEST_FAIL_COMMAND" => "claude plugin update scw@agent-workflows",
        "AGENT_WORKFLOWS_REFRESH_TEST_FAIL_STATUS" => "29"
      }

      out, status = run_refresh(bin_dir, calls, "--host", "claude", env: env)

      assert_equal 29, status.exitstatus, out
      assert_includes out, "native claude failure"
      assert_equal 2, File.readlines(calls).length
      refute_includes out, "REFRESH_COMPLETE"
    end
  end

  private

  def with_fake_hosts
    Dir.mktmpdir("agent-workflows-refresh-test") do |tmp|
      bin_dir = File.join(tmp, "bin")
      FileUtils.mkdir_p(bin_dir)
      yield bin_dir, File.join(tmp, "calls")
    end
  end

  def write_fake_host(bin_dir, name)
    path = File.join(bin_dir, name)
    File.write(path, <<~SH)
      #!/bin/sh
      printf '#{name}' >> "$AGENT_WORKFLOWS_REFRESH_TEST_CALLS"
      for argument in "$@"; do
        printf '\\t%s' "$argument" >> "$AGENT_WORKFLOWS_REFRESH_TEST_CALLS"
      done
      printf '\\n' >> "$AGENT_WORKFLOWS_REFRESH_TEST_CALLS"
      if [ "${AGENT_WORKFLOWS_REFRESH_TEST_FAIL_COMMAND:-}" = "#{name} $*" ]; then
        echo "native #{name} failure"
        exit "${AGENT_WORKFLOWS_REFRESH_TEST_FAIL_STATUS:-1}"
      fi
    SH
    FileUtils.chmod(0o755, path)
  end

  def run_refresh(bin_dir, calls, *, env: {}, path: ENV.fetch("PATH"))
    env = {
      "AGENT_WORKFLOWS_REFRESH_TEST_CALLS" => calls,
      "CODEX_HOME" => nil,
      "CLAUDE_HOME" => nil,
      "HOME" => File.join(File.dirname(bin_dir), "home"),
      "PATH" => "#{bin_dir}:#{path}"
    }.merge(env)
    Open3.capture2e(env, "bash", SCRIPT, *)
  end
end
