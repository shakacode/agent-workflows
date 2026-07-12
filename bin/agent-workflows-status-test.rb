#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for agent-workflows-status.
# Run with: ruby bin/agent-workflows-status-test.rb

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-status", __dir__)

class AgentWorkflowsStatusTest < Minitest::Test
  def setup
    @fake_codex_dir = Dir.mktmpdir("status-fake-codex")
    @fake_codex = File.join(@fake_codex_dir, "codex")
    File.write(@fake_codex, <<~RUBY)
      #!#{RbConfig.ruby}
      puts "PLUGIN STATUS VERSION PATH"
      puts "scw@agent-workflows  installed, enabled  0.1.0  /fake/scw"
    RUBY
    FileUtils.chmod(0o755, @fake_codex)
  end

  def teardown
    FileUtils.remove_entry(@fake_codex_dir)
  end

  def run_status(env, *)
    Open3.capture2e({ "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => @fake_codex }.merge(env), "ruby", SCRIPT, *)
  end

  def write_metadata(target, metadata)
    File.write(File.join(target, ".agent-workflows-install.json"), "#{JSON.pretty_generate(metadata)}\n")
  end

  def write_codex_native_state(target)
    cache_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
    plugin_root = File.join(cache_root, ".codex-plugin")
    FileUtils.mkdir_p(plugin_root)
    FileUtils.mkdir_p(File.join(cache_root, "skills/example"))
    File.write(File.join(target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
    File.write(File.join(cache_root, "skills/example/SKILL.md"), "example\n")
    File.write(File.join(plugin_root, "plugin.json"), "#{JSON.generate('name' => 'scw', 'version' => '0.1.0', 'skills' => './skills/')}\n")
  end

  def test_not_installed_target_reports_not_installed
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      out, status = run_status({}, "--target", target, "--host", "claude")

      assert_equal 2, status.exitstatus, out
      assert_includes out, "NOT_INSTALLED"
    end
  end

  def test_up_to_date_with_non_git_source
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")

        out, status = run_status({}, "--target", target, "--host", "claude")

        assert_equal 0, status.exitstatus, out
        assert_includes out, "UP_TO_DATE"
      end
    end
  end

  def test_companion_status_reports_delivery_and_native_state
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_codex_native_state(target)
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "",
          "delivery_mode" => "plugin-companion"
        )

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "plugin-companion", payload.fetch("delivery_mode")
        assert_equal "active", payload.dig("native", "state")
        assert_equal "absent", payload.dig("flat", "state")
      end
    end
  end

  def test_status_fails_closed_on_native_plus_flat_collision_with_guidance
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
        write_codex_native_state(target)
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "",
          "delivery_mode" => "flat"
        )

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "cannot be active"
        assert_includes payload.fetch("guidance"), "--delivery-mode plugin-companion"
      end
    end
  end

  def test_delivery_mode_override_previews_flat_to_companion_migration
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        FileUtils.mkdir_p(File.join(target, "skills/example"))
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
        File.write(File.join(target, "skills/example/SKILL.md"), "example\n")
        system("git", "-C", source, "init", "--quiet", exception: true)
        system("git", "-C", source, "config", "user.email", "status-test@example.com", exception: true)
        system("git", "-C", source, "config", "user.name", "Status Test", exception: true)
        system("git", "-C", source, "add", ".", exception: true)
        system("git", "-C", source, "commit", "--quiet", "-m", "fixture", exception: true)
        revision, revision_status = Open3.capture2("git", "-C", source, "rev-parse", "HEAD")
        assert revision_status.success?, revision
        revision = revision.strip
        write_codex_native_state(target)
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => revision,
          "delivery_mode" => "flat"
        )

        out, status = run_status(
          {}, "--target", target, "--host", "codex", "--delivery-mode", "plugin-companion", "--json"
        )
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "UP_TO_DATE", payload.fetch("status")
        assert_equal "plugin-companion", payload.fetch("delivery_mode")
        assert_equal "managed", payload.dig("flat", "state")
      end
    end
  end

  def test_invalid_delivery_mode_override_is_check_failed
    out, status = run_status({}, "--delivery-mode", "hybrid", "--json")

    assert_equal 3, status.exitstatus, out
    assert_includes out, "--delivery-mode must be flat or plugin-companion"
  end

  def test_flat_status_reports_present_skill_route_without_migration_warning
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        FileUtils.mkdir_p(File.join(target, "skills/example"))
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
        File.write(File.join(target, "skills/example/SKILL.md"), "example\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "", "delivery_mode" => "flat")

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")

        assert_equal 0, status.exitstatus, out
        assert_equal "present", JSON.parse(out).dig("flat", "state")
      end
    end
  end

  def test_non_ascii_metadata_does_not_crash_under_ascii_locale
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      # A clone path with non-ASCII bytes (accented home dir, em dash) must not
      # crash the JSON/text reads under a non-UTF-8 locale.
      write_metadata(
        target,
        "version" => "0.1.0",
        "source" => "/Users/josé/clones/café—repo",
        "source_revision" => "abc123"
      )

      out, status = run_status({ "LANG" => "C", "LC_ALL" => "C" }, "--target", target, "--host", "claude")

      refute_includes out, "invalid byte sequence"
      refute_includes out, "Encoding::"
      # The bogus source path cannot resolve, so the only valid outcome is a
      # clean CHECK_FAILED status, never an uncaught encoding crash.
      assert_includes out, "CHECK_FAILED"
      assert_equal 3, status.exitstatus, out
    end
  end

  def test_helper_system_call_failure_becomes_check_failed
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        injection = File.join(target, "raise-system-call.rb")
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
        File.write(injection, <<~RUBY)
          require "open3"
          module RaiseSystemCall
            def capture3(*)
              raise Errno::EACCES, "delivery helper"
            end
          end
          Open3.singleton_class.prepend(RaiseSystemCall)
        RUBY

        out, status = run_status({ "RUBYOPT" => "-r#{injection}" }, "--target", target, "--host", "claude", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "Permission denied"
      end
    end
  end
end
