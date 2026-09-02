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
require_relative "agent_doctor/install_ownership"

SCRIPT = File.expand_path("agent-workflows-status", __dir__)
REPO_ROOT = File.expand_path("..", __dir__)

class AgentWorkflowsStatusTest < Minitest::Test
  def setup
    @fake_codex_dir = Dir.mktmpdir("status-fake-codex")
    @fake_codex = File.join(@fake_codex_dir, "codex")
    @superpowers_catalog_root = File.join(@fake_codex_dir, "superpowers-catalog")
    FileUtils.mkdir_p(File.join(@superpowers_catalog_root, ".codex-plugin"))
    File.write(
      File.join(@superpowers_catalog_root, ".codex-plugin/plugin.json"),
      "#{JSON.generate('name' => 'superpowers', 'version' => '5.1.3', 'repository' => 'https://github.com/obra/superpowers')}\n"
    )
    File.write(@fake_codex, <<~RUBY)
      #!#{RbConfig.ruby}
      abort "unexpected arguments: \#{ARGV.inspect}" unless ARGV[0, 3] == %w[plugin list --marketplace] && ARGV.length == 4
      marketplace = ARGV.fetch(3)
      File.open(ENV.fetch("QA_CODEX_CALLS"), "a") { |file| file.puts(marketplace) } if ENV["QA_CODEX_CALLS"]
      case marketplace
      when "agent-workflows"
        puts "PLUGIN STATUS VERSION PATH"
        puts "scw@agent-workflows  installed, enabled  0.1.0  https://github.com/shakacode/agent-workflows.git"
      when "openai-curated"
        selected = marketplace == ENV.fetch("QA_SUPERPOWERS_MARKETPLACE", "openai-curated")
        if selected
          state = ENV.fetch("QA_SUPERPOWERS_STATE", "installed-disabled")
          puts "PLUGIN STATUS VERSION PATH"
          status = state == "active" ? "installed, enabled" : "installed, disabled"
          puts "superpowers@\#{marketplace}  \#{status}  host-version  \#{ENV.fetch('QA_SUPERPOWERS_CATALOG_ROOT')}"
        else
          puts "No plugins found in marketplace `\#{marketplace}`."
        end
      when "openai-curated-remote", "superpowers-dev"
        selected = marketplace == ENV.fetch("QA_SUPERPOWERS_MARKETPLACE", "openai-curated")
        if selected
          state = ENV.fetch("QA_SUPERPOWERS_STATE", "installed-disabled")
          puts "PLUGIN STATUS VERSION PATH"
          status = state == "active" ? "installed, enabled" : "installed, disabled"
          puts "superpowers@\#{marketplace}  \#{status}  host-version  \#{ENV.fetch('QA_SUPERPOWERS_CATALOG_ROOT')}"
        else
          puts "No plugins found in marketplace `\#{marketplace}`."
        end
      else
        abort "unexpected marketplace: \#{marketplace}"
      end
    RUBY
    FileUtils.chmod(0o755, @fake_codex)
  end

  def teardown
    FileUtils.remove_entry(@fake_codex_dir)
  end

  def run_status(env, *)
    defaults = {
      "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => @fake_codex,
      "QA_SUPERPOWERS_CATALOG_ROOT" => @superpowers_catalog_root
    }
    Open3.capture2e(defaults.merge(env), "ruby", SCRIPT, *)
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
    manifest = {
      "name" => "scw",
      "version" => "0.1.0",
      "repository" => "https://github.com/shakacode/agent-workflows",
      "skills" => "./skills/"
    }
    File.write(File.join(plugin_root, "plugin.json"), "#{JSON.generate(manifest)}\n")
  end

  def test_claude_not_installed_text_omits_superpowers_diagnostic
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      out, status = run_status({}, "--target", target, "--host", "claude")

      assert_equal 2, status.exitstatus, out
      assert_includes out, "NOT_INSTALLED"
      refute_includes out, "superpowers"
    end
  end

  def test_claude_not_installed_json_omits_superpowers_diagnostic
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      out, status = run_status({}, "--target", target, "--host", "claude", "--json")
      payload = JSON.parse(out)

      assert_equal 2, status.exitstatus, out
      assert_equal "NOT_INSTALLED", payload.fetch("status")
      refute payload.key?("superpowers"), out
    end
  end

  def test_not_installed_json_reports_active_superpowers_advisory
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      out, status = run_status(
        { "QA_SUPERPOWERS_STATE" => "active", "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev" },
        "--target", target, "--host", "codex", "--json"
      )
      payload = JSON.parse(out)

      assert_equal 2, status.exitstatus, out
      assert_equal "NOT_INSTALLED", payload.fetch("status")
      assert_equal "active", payload.dig("superpowers", "state")
      assert_equal "superpowers@superpowers-dev", payload.dig("superpowers", "catalog_entries", 0, "plugin_id")
      assert_equal "host-version", payload.dig("superpowers", "catalog_entries", 0, "installed_version")
      assert_equal "5.1.3", payload.dig("superpowers", "catalog_entries", 0, "catalog_version")
    end
  end

  def test_not_installed_text_warns_when_superpowers_is_active
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      out, status = run_status(
        { "QA_SUPERPOWERS_STATE" => "active", "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev" },
        "--target", target, "--host", "codex"
      )

      assert_equal 2, status.exitstatus, out
      assert_includes out, "NOT_INSTALLED"
      assert_includes out, "superpowers=active"
      assert_includes out, "superpowers_catalog_versions=5.1.3"
      assert_includes out, "WARNING Agent Workflows remains the sole delivery orchestrator"
    end
  end

  def test_malformed_metadata_preserves_active_superpowers_advisory_in_check_failed_output
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      File.write(File.join(target, ".agent-workflows-install.json"), "{not-json")
      environment = {
        "QA_SUPERPOWERS_STATE" => "active",
        "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev"
      }

      json_out, json_status = run_status(environment, "--target", target, "--host", "codex", "--json")
      payload = JSON.parse(json_out)

      assert_equal 3, json_status.exitstatus, json_out
      assert_equal "CHECK_FAILED", payload.fetch("status")
      assert_includes payload.fetch("reason"), "invalid metadata"
      assert_equal "active", payload.dig("superpowers", "state")

      text_out, text_status = run_status(environment, "--target", target, "--host", "codex")

      assert_equal 3, text_status.exitstatus, text_out
      assert_includes text_out, "CHECK_FAILED"
      assert_includes text_out, "superpowers=active"
      assert_includes text_out, "WARNING Agent Workflows remains the sole delivery orchestrator"
    end
  end

  def test_wrong_shaped_metadata_preserves_active_superpowers_advisory_in_check_failed_output
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      File.write(File.join(target, ".agent-workflows-install.json"), "[]\n")
      environment = {
        "QA_SUPERPOWERS_STATE" => "active",
        "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev"
      }

      json_out, json_status = run_status(environment, "--target", target, "--host", "codex", "--json")
      payload = JSON.parse(json_out)

      assert_equal 3, json_status.exitstatus, json_out
      assert_equal "CHECK_FAILED", payload.fetch("status")
      assert_includes payload.fetch("reason"), "invalid metadata"
      assert_equal "active", payload.dig("superpowers", "state")

      text_out, text_status = run_status(environment, "--target", target, "--host", "codex")

      assert_equal 3, text_status.exitstatus, text_out
      assert_includes text_out, "CHECK_FAILED"
      assert_includes text_out, "superpowers=active"
      assert_includes text_out, "WARNING Agent Workflows remains the sole delivery orchestrator"
    end
  end

  def test_claude_up_to_date_text_omits_superpowers_diagnostic
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")

        out, status = run_status({}, "--target", target, "--host", "claude")

        assert_equal 0, status.exitstatus, out
        assert_includes out, "UP_TO_DATE"
        refute_includes out, "superpowers"
      end
    end
  end

  def test_claude_up_to_date_json_omits_superpowers_diagnostic
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")

        out, status = run_status({}, "--target", target, "--host", "claude", "--json")
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "UP_TO_DATE", payload.fetch("status")
        refute payload.key?("superpowers"), out
      end
    end
  end

  def test_status_json_surfaces_recorded_runtime_manifest_digests
    digest = "a" * 64
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        doctor_root = File.join(target, "bin/agent_doctor")
        FileUtils.mkdir_p(doctor_root)
        marker = File.join(doctor_root, ".agent-workflows-managed")
        File.write(marker, "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n")
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "",
          "managed_runtime_manifest_digests" => { "autonomous-merge" => digest }
        )

        out, status = run_status({}, "--target", target, "--host", "claude", "--json")
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal({ "autonomous-merge" => digest }, payload.fetch("runtime_manifest_digests"))
      end
    end
  end

  def test_tampered_workflow_doctor_tree_withholds_runtime_manifest_digests
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      install_env = {
        "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => @fake_codex,
        "QA_SUPERPOWERS_CATALOG_ROOT" => @superpowers_catalog_root
      }
      install_output, install_status = Open3.capture2e(
        install_env,
        File.join(REPO_ROOT, "bin/install-agent-workflows"),
        "--host", "codex", "--target", target, "--mode", "copy", "--delivery-mode", "flat"
      )
      assert_equal 0, install_status.exitstatus, install_output

      File.open(File.join(target, "bin/agent_doctor/autonomous_merge_policy.rb"), "a") do |file|
        file.puts("# tamper")
      end

      out, status = run_status({}, "--target", target, "--host", "codex", "--json")
      payload = JSON.parse(out)

      assert_equal 0, status.exitstatus, out
      assert_equal "UP_TO_DATE", payload.fetch("status")
      assert_nil payload.fetch("runtime_manifest_digests")
    end
  end

  def test_metadata_path_disappearing_mid_read_becomes_check_failed
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      digest = "a" * 64
      source = File.join(target, "source")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "VERSION"), "9.9.9\n")
      doctor_root = File.join(target, "bin/agent_doctor")
      FileUtils.mkdir_p(doctor_root)
      File.write(
        File.join(doctor_root, ".agent-workflows-managed"),
        "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n"
      )
      write_metadata(
        target,
        "version" => "9.9.9",
        "source" => source,
        "source_revision" => "",
        "managed_runtime_manifest_digests" => { "autonomous-merge" => digest }
      )
      injection = File.join(target, "lstat-race.rb")
      File.write(injection, <<~RUBY)
        class << File
          alias_method :qa_original_lstat, :lstat

          def lstat(path, *args)
            raise Errno::ENOENT, path if path == ENV.fetch("QA_METADATA_PATH")

            qa_original_lstat(path, *args)
          end
        end
      RUBY

      out, status = run_status(
        {
          "QA_METADATA_PATH" => File.join(target, ".agent-workflows-install.json"),
          "RUBYOPT" => "-r#{injection}"
        },
        "--target", target, "--host", "claude", "--json"
      )
      payload = JSON.parse(out)

      assert_equal 3, status.exitstatus, out
      assert_equal "CHECK_FAILED", payload.fetch("status")
      assert_includes payload.fetch("reason"), "changed while being read"
      assert_nil payload.fetch("runtime_manifest_digests")
    end
  end

  def test_status_json_reports_null_runtime_manifest_digests_for_legacy_installs
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")

        out, status = run_status({}, "--target", target, "--host", "claude", "--json")
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert payload.key?("runtime_manifest_digests"), out
        assert_nil payload.fetch("runtime_manifest_digests")
      end
    end
  end

  def test_malformed_runtime_manifest_digests_are_check_failed
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "",
          "managed_runtime_manifest_digests" => { "autonomous-merge" => "not-a-digest" }
        )

        out, status = run_status({}, "--target", target, "--host", "claude", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "managed_runtime_manifest_digests is malformed"
        assert_nil payload.fetch("runtime_manifest_digests")
      end
    end
  end

  def test_symlinked_install_metadata_is_check_failed
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        elsewhere = File.join(source, "elsewhere.json")
        File.write(
          elsewhere,
          "#{JSON.pretty_generate(
            'version' => '9.9.9',
            'source' => source,
            'source_revision' => '',
            'managed_runtime_manifest_digests' => { 'autonomous-merge' => 'a' * 64 }
          )}\n"
        )
        File.symlink(elsewhere, File.join(target, ".agent-workflows-install.json"))

        out, status = run_status({}, "--target", target, "--host", "claude", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "refusing to follow a symlink"
        assert_nil payload.fetch("runtime_manifest_digests")
      end
    end
  end

  def test_check_failed_withholds_recorded_runtime_manifest_digests
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      write_metadata(
        target,
        "version" => "9.9.9",
        "source" => File.join(target, "missing-source"),
        "source_revision" => "",
        "managed_runtime_manifest_digests" => { "autonomous-merge" => "a" * 64 }
      )

      out, status = run_status({}, "--target", target, "--host", "claude", "--json")
      payload = JSON.parse(out)

      assert_equal 3, status.exitstatus, out
      assert_equal "CHECK_FAILED", payload.fetch("status")
      assert_nil payload.fetch("runtime_manifest_digests"), out
    end
  end

  def test_symlinked_target_ancestor_withholds_runtime_manifest_digests
    Dir.mktmpdir("agent-workflows-status-test") do |root|
      real_home = File.join(root, "real-home")
      linked_home = File.join(root, "linked-home")
      FileUtils.mkdir_p(real_home)
      File.symlink(real_home, linked_home)
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        doctor_root = File.join(real_home, "bin/agent_doctor")
        FileUtils.mkdir_p(doctor_root)
        File.write(
          File.join(doctor_root, ".agent-workflows-managed"),
          "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n"
        )
        metadata = {
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "",
          "managed_runtime_manifest_digests" => { "autonomous-merge" => "a" * 64 }
        }
        write_metadata(real_home, metadata)

        direct, direct_status = run_status({}, "--target", real_home, "--host", "claude", "--json")
        linked, linked_status = run_status({}, "--target", linked_home, "--host", "claude", "--json")

        assert_equal 0, direct_status.exitstatus, direct
        assert_equal 0, linked_status.exitstatus, linked
        assert_equal({ "autonomous-merge" => "a" * 64 },
                     JSON.parse(direct).fetch("runtime_manifest_digests"), direct)
        assert_equal "UP_TO_DATE", JSON.parse(linked).fetch("status"), linked
        assert_nil JSON.parse(linked).fetch("runtime_manifest_digests"), linked
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

  def test_json_status_reports_active_superpowers_advisory_without_changing_exit_status
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

        out, status = run_status(
          { "QA_SUPERPOWERS_STATE" => "active", "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev" },
          "--target", target, "--host", "codex", "--json"
        )
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "UP_TO_DATE", payload.fetch("status")
        assert_equal "active", payload.dig("superpowers", "state")
        assert_equal "superpowers@superpowers-dev", payload.dig("superpowers", "catalog_entries", 0, "plugin_id")
        assert_equal "5.1.3", payload.dig("superpowers", "catalog_entries", 0, "catalog_version")
      end
    end
  end

  def test_text_status_warns_when_superpowers_is_active
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

        out, status = run_status(
          { "QA_SUPERPOWERS_STATE" => "active", "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev" },
          "--target", target, "--host", "codex"
        )

        assert_equal 0, status.exitstatus, out
        assert_includes out, "superpowers=active"
        assert_includes out, "superpowers_catalog_versions=5.1.3"
        assert_includes out, "superpowers_upstream_version=not-queried"
        assert_includes out, "WARNING Agent Workflows remains the sole delivery orchestrator"
      end
    end
  end

  def test_companion_status_reports_scalar_native_manifests_as_unknown
    ["scw", 123, true].each do |manifest|
      Dir.mktmpdir("agent-workflows-status-test") do |target|
        Dir.mktmpdir("agent-workflows-status-source") do |source|
          File.write(File.join(source, "VERSION"), "9.9.9\n")
          write_codex_native_state(target)
          manifest_path = File.join(
            target,
            "plugins/cache/agent-workflows/scw/0.1.0/.codex-plugin/plugin.json"
          )
          File.write(manifest_path, "#{JSON.generate(manifest)}\n")
          write_metadata(
            target,
            "version" => "9.9.9",
            "source" => source,
            "source_revision" => "",
            "delivery_mode" => "plugin-companion"
          )

          out, status = run_status({}, "--target", target, "--host", "codex", "--json")
          payload = JSON.parse(out)

          assert_equal 3, status.exitstatus, out
          assert_equal "CHECK_FAILED", payload.fetch("status")
          assert_equal "unknown", payload.dig("native", "state")
          refute_includes out, "NoMethodError"
        end
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

  def test_incompatible_delivery_reuses_the_helpers_superpowers_advisory
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        calls = File.join(target, "codex-calls")
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

        out, status = run_status({ "QA_CODEX_CALLS" => calls }, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "cannot be active"
        assert payload.key?("superpowers"), out
        marketplaces = File.readlines(calls, chomp: true)
        assert_equal 1, marketplaces.count("openai-curated")
        assert_equal 1, marketplaces.count("openai-curated-remote")
        assert_equal 1, marketplaces.count("superpowers-dev")
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

  def test_malformed_nested_delivery_mode_preserves_active_superpowers_advisory
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "", "delivery_mode" => [])
        environment = {
          "QA_SUPERPOWERS_STATE" => "active",
          "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev"
        }

        json_out, json_status = run_status(environment, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(json_out)

        assert_equal 3, json_status.exitstatus, json_out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "delivery-state check failed"
        assert_equal "active", payload.dig("superpowers", "state")

        text_out, text_status = run_status(environment, "--target", target, "--host", "codex")

        assert_equal 3, text_status.exitstatus, text_out
        assert_includes text_out, "CHECK_FAILED"
        assert_includes text_out, "superpowers=active"
        assert_includes text_out, "WARNING Agent Workflows remains the sole delivery orchestrator"
      end
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
        refute payload.key?("superpowers"), out
      end
    end
  end

  def test_delivery_helper_system_call_failure_preserves_active_superpowers_advisory
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        injection = File.join(target, "raise-delivery-helper-system-call.rb")
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
        File.write(injection, <<~RUBY)
          require "open3"
          module RaiseDeliveryHelperSystemCall
            def capture3(*arguments)
              helper = arguments.find { |argument| argument.to_s.end_with?("/agent-workflows-delivery-state") }
              raise Errno::EACCES, "delivery helper" if helper

              super
            end
          end
          Open3.singleton_class.prepend(RaiseDeliveryHelperSystemCall)
        RUBY
        environment = {
          "RUBYOPT" => "-r#{injection}",
          "QA_SUPERPOWERS_STATE" => "active",
          "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev"
        }

        json_out, json_status = run_status(environment, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(json_out)

        assert_equal 3, json_status.exitstatus, json_out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "Permission denied"
        assert_equal "active", payload.dig("superpowers", "state")

        text_out, text_status = run_status(environment, "--target", target, "--host", "codex")

        assert_equal 3, text_status.exitstatus, text_out
        assert_includes text_out, "CHECK_FAILED"
        assert_includes text_out, "superpowers=active"
        assert_includes text_out, "WARNING Agent Workflows remains the sole delivery orchestrator"
      end
    end
  end
end
