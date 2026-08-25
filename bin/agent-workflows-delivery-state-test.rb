#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-delivery-state", __dir__)
load SCRIPT

class AgentWorkflowsDeliveryStateTest < Minitest::Test
  def setup
    @fake_codex_dir = Dir.mktmpdir("fake-codex-plugin-list")
    @fake_codex = File.join(@fake_codex_dir, "codex")
    File.write(@fake_codex, <<~RUBY)
      #!#{RbConfig.ruby}
      state = ENV.fetch("QA_CODEX_PLUGIN_STATE", "enabled")
      abort "unexpected arguments: \#{ARGV.inspect}" unless ARGV == %w[plugin list --marketplace agent-workflows]
      case state
      when "enabled"
        version = ENV.fetch("QA_CODEX_PLUGIN_VERSION", "0.1.0")
        source = ENV.fetch("QA_CODEX_PLUGIN_SOURCE", "https://github.com/shakacode/agent-workflows.git")
        puts "PLUGIN STATUS VERSION PATH"
        puts "scw@agent-workflows  installed, enabled  \#{version}  \#{source}"
      when "disabled"
        puts "PLUGIN STATUS VERSION PATH"
        puts "scw@agent-workflows  installed, disabled  0.1.0  /fake/scw"
      when "absent"
        puts "No plugins found in marketplace `agent-workflows`."
      when "ambiguous"
        puts "scw@agent-workflows  installed, enabled  0.1.0  /fake/one"
        puts "scw@agent-workflows  installed, disabled  0.1.0  /fake/two"
      when "malformed"
        puts "scw@agent-workflows enabled maybe"
      when "error"
        warn "invalid Codex TOML"
        exit 2
      when "sleep"
        sleep 5
      else
        abort "unknown fake state: \#{state}"
      end
    RUBY
    FileUtils.chmod(0o755, @fake_codex)
  end

  def teardown
    FileUtils.remove_entry(@fake_codex_dir)
  end

  def run_state(
    *args,
    codex_state: "enabled",
    codex_executable: @fake_codex,
    codex_version: nil,
    codex_source: nil
  )
    env = {
      "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => codex_executable,
      "QA_CODEX_PLUGIN_STATE" => codex_state
    }
    env["QA_CODEX_PLUGIN_VERSION"] = codex_version if codex_version
    env["QA_CODEX_PLUGIN_SOURCE"] = codex_source if codex_source
    Open3.capture3(env, "ruby", SCRIPT, *args)
  end

  def run_state_with_env(env, *args)
    defaults = {
      "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => @fake_codex,
      "QA_CODEX_PLUGIN_STATE" => "enabled"
    }
    Open3.capture3(defaults.merge(env), "ruby", SCRIPT, *args)
  end

  def write_manifest(root, host:)
    manifest_dir = File.join(root, host == "codex" ? ".codex-plugin" : ".claude-plugin")
    FileUtils.mkdir_p(manifest_dir)
    FileUtils.mkdir_p(File.join(root, "skills/example"))
    File.write(File.join(root, "skills/example/SKILL.md"), "example\n")
    manifest = {
      "name" => "scw",
      "version" => File.basename(root),
      "repository" => "https://github.com/shakacode/agent-workflows",
      "skills" => "./skills/"
    }
    File.write(File.join(manifest_dir, "plugin.json"), "#{JSON.pretty_generate(manifest)}\n")
  end

  def write_codex_native_state(target)
    plugin_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
    FileUtils.mkdir_p(target)
    File.write(File.join(target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
    write_manifest(plugin_root, host: "codex")
  end

  def create_source(root)
    FileUtils.mkdir_p(File.join(root, "skills/alpha"))
    FileUtils.mkdir_p(File.join(root, "skills/beta/bin"))
    File.write(File.join(root, "skills/alpha/SKILL.md"), "alpha — portable\n")
    File.write(File.join(root, "skills/beta/SKILL.md"), "beta\n")
    File.write(File.join(root, "skills/beta/bin/run"), "#!/bin/sh\n")
    FileUtils.chmod(0o755, File.join(root, "skills/beta/bin/run"))
    system("git", "-C", root, "init", "--quiet", "--initial-branch=main", exception: true)
    system("git", "-C", root, "config", "user.email", "delivery-state@example.com", exception: true)
    system("git", "-C", root, "config", "user.name", "Delivery State Test", exception: true)
    system("git", "-C", root, "add", ".", exception: true)
    system("git", "-C", root, "commit", "--quiet", "-m", "source", exception: true)
    Open3.capture2("git", "-C", root, "rev-parse", "HEAD").first.strip
  end

  def write_metadata(target, metadata)
    File.write(File.join(target, ".agent-workflows-install.json"), "#{JSON.pretty_generate(metadata)}\n")
  end

  def test_directory_snapshot_conflict_does_not_report_revision_unavailable
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      installed = File.join(tmp, "target/skills/alpha")
      FileUtils.mkdir_p(source)
      recorded_revision = create_source(source)
      FileUtils.remove_entry(File.join(source, ".git"))
      FileUtils.mkdir_p(installed)
      FileUtils.cp(File.join(source, "skills/alpha/SKILL.md"), installed)
      File.open(File.join(installed, "SKILL.md"), "a") { |file| file << "personal edit\n" }
      metadata = {
        "mode" => "copy",
        "source" => source,
        "source_revision" => recorded_revision
      }

      result = AgentWorkflowsDeliveryState.flat_skill_ownership_conflict(
        source: source,
        metadata: metadata,
        present: [installed],
        revision: recorded_revision
      )

      assert_equal "ambiguous", result.fetch("state")
      assert_equal [installed], result.fetch("blocking")
      refute result.key?("reason"), result.inspect
    end
  end

  def test_detects_active_native_plugin_from_real_host_state_shapes
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      codex_home = File.join(tmp, "codex")
      codex_plugin = File.join(codex_home, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(codex_home)
      File.write(File.join(codex_home, "config.toml"), <<~TOML)
        [plugins."scw@agent-workflows"]
        enabled = true
      TOML
      write_manifest(codex_plugin, host: "codex")

      claude_home = File.join(tmp, "claude")
      claude_plugin = File.join(claude_home, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(File.join(claude_home, "plugins"))
      File.write(File.join(claude_home, "settings.json"), "#{JSON.pretty_generate('enabledPlugins' => { 'scw@agent-workflows' => true })}\n")
      File.write(
        File.join(claude_home, "plugins/installed_plugins.json"),
        "#{JSON.pretty_generate('version' => 2, 'plugins' => { 'scw@agent-workflows' => [{ 'scope' => 'user', 'installPath' => claude_plugin, 'version' => '0.1.0' }] })}\n"
      )
      write_manifest(claude_plugin, host: "claude")

      [["codex", codex_home], ["claude", claude_home]].each do |host, target|
        out, err, status = run_state("check", "--host", host, "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")

        assert status.success?, "#{host}: #{out}#{err}"
        assert_equal "active", JSON.parse(out).dig("native", "state")
      end
    end
  end

  def test_codex_real_cli_source_url_resolves_the_unique_versioned_cache
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      plugin_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
      write_codex_native_state(target)

      out, err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert_equal "active", payload.dig("native", "state")
      assert_equal [plugin_root], payload.dig("native", "roots")
      assert_equal "https://github.com/shakacode/agent-workflows.git", payload.dig("native", "source")

      out, _err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json",
        codex_source: "https://github.com/example/unrelated.git"
      )

      refute status.success?, out
      assert_equal "unknown", JSON.parse(out).dig("native", "state")
    end
  end

  def test_plugin_companion_ignores_unrelated_skill_without_install_metadata
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      unrelated = File.join(target, "skills/personal/SKILL.md")
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.dirname(unrelated))
      File.write(unrelated, "personal\n")

      out, err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert payload.fetch("compatible")
      assert_equal "absent", payload.dig("flat", "state")
      assert_empty payload.dig("flat", "blocking")
      assert_equal "personal\n", File.read(unrelated)
    end
  end

  def test_plugin_companion_ignores_unrelated_skill_after_companion_install
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      unrelated = File.join(target, "skills/personal/SKILL.md")
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.dirname(unrelated))
      File.write(unrelated, "personal\n")
      write_metadata(target, "delivery_mode" => "plugin-companion")

      out, err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert payload.fetch("compatible")
      assert_equal "absent", payload.dig("flat", "state")
      assert_empty payload.dig("flat", "blocking")
      assert_equal "personal\n", File.read(unrelated)
    end
  end

  def test_plugin_companion_blocks_new_current_native_skill_missing_from_recorded_revision
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      recorded_revision = create_source(source)
      write_codex_native_state(target)
      write_metadata(
        target,
        "host" => "codex",
        "mode" => "copy",
        "delivery_mode" => "plugin-companion",
        "source" => source,
        "source_revision" => recorded_revision
      )
      metadata_path = File.join(target, ".agent-workflows-install.json")
      metadata_before = File.binread(metadata_path)

      new_skill = File.join(source, "skills/current-only/SKILL.md")
      FileUtils.mkdir_p(File.dirname(new_skill))
      File.write(new_skill, "current source\n")
      system("git", "-C", source, "add", "skills/current-only", exception: true)
      system("git", "-C", source, "commit", "--quiet", "-m", "add current skill", exception: true)
      native_skill = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0/skills/current-only/SKILL.md")
      FileUtils.mkdir_p(File.dirname(native_skill))
      File.write(native_skill, "current native\n")
      flat_skill = File.join(target, "skills/current-only/SKILL.md")
      FileUtils.mkdir_p(File.dirname(flat_skill))
      File.write(flat_skill, "personal collision\n")

      out, _err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", source,
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      refute status.success?
      refute payload.fetch("compatible")
      assert_equal [File.dirname(flat_skill)], payload.dig("flat", "blocking")
      assert_equal "personal collision\n", File.binread(flat_skill)
      assert_equal metadata_before, File.binread(metadata_path)
    end
  end

  def test_plugin_companion_blocks_native_skill_removed_from_current_source
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      recorded_revision = create_source(source)
      write_codex_native_state(target)
      write_metadata(
        target,
        "host" => "codex",
        "mode" => "copy",
        "delivery_mode" => "plugin-companion",
        "source" => source,
        "source_revision" => recorded_revision
      )

      native_skill = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0/skills/alpha/SKILL.md")
      FileUtils.mkdir_p(File.dirname(native_skill))
      File.write(native_skill, "recorded native\n")
      FileUtils.rm_r(File.join(source, "skills/alpha"))
      system("git", "-C", source, "add", "-u", "skills/alpha", exception: true)
      system("git", "-C", source, "commit", "--quiet", "-m", "remove alpha skill", exception: true)
      flat_skill = File.join(target, "skills/alpha/SKILL.md")
      FileUtils.mkdir_p(File.dirname(flat_skill))
      File.write(flat_skill, "flat duplicate\n")

      out, _err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", source,
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      refute status.success?
      refute payload.fetch("compatible")
      assert_equal [File.dirname(flat_skill)], payload.dig("flat", "blocking")
      assert_equal "flat duplicate\n", File.binread(flat_skill)
    end
  end

  def test_plugin_companion_rejects_mixed_valid_and_invalid_candidate_native_roots
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      FileUtils.mkdir_p(source)
      recorded_revision = create_source(source)

      %w[codex claude].each do |host|
        target = File.join(tmp, host)
        stale_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
        candidate_root = File.join(target, "plugins/cache/agent-workflows/scw/0.2.0")
        write_manifest(stale_root, host: host)
        manifest_dir = File.join(candidate_root, host == "codex" ? ".codex-plugin" : ".claude-plugin")
        FileUtils.mkdir_p(File.join(candidate_root, "skills/beta"))
        FileUtils.mkdir_p(manifest_dir)
        File.write(File.join(candidate_root, "skills/beta/SKILL.md"), "candidate beta\n")
        File.write(File.join(manifest_dir, "plugin.json"), "{malformed\n")

        if host == "codex"
          File.write(File.join(target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
        else
          FileUtils.mkdir_p(File.join(target, "plugins"))
          File.write(
            File.join(target, "settings.json"),
            "#{JSON.generate('enabledPlugins' => { 'scw@agent-workflows' => true })}\n"
          )
          receipts = {
            "plugins" => {
              "scw@agent-workflows" => [{ "installPath" => stale_root }, { "installPath" => candidate_root }]
            }
          }
          File.write(
            File.join(target, "plugins/installed_plugins.json"),
            "#{JSON.generate(receipts)}\n"
          )
        end

        write_metadata(
          target,
          "host" => host,
          "mode" => "copy",
          "delivery_mode" => "plugin-companion",
          "source" => source,
          "source_revision" => recorded_revision
        )
        metadata_path = File.join(target, ".agent-workflows-install.json")
        metadata_before = File.binread(metadata_path)
        flat_skill = File.join(target, "skills/beta/SKILL.md")
        FileUtils.mkdir_p(File.dirname(flat_skill))
        File.write(flat_skill, "personal beta\n")

        out, _err, status = run_state(
          "check", "--host", host, "--target", target, "--source", source,
          "--delivery-mode", "plugin-companion", "--json", codex_version: "0.2.0"
        )
        payload = JSON.parse(out)

        refute status.success?, "#{host}: #{out}"
        assert_equal "unknown", payload.dig("native", "state"), host
        assert_equal "personal beta\n", File.binread(flat_skill)
        assert_equal metadata_before, File.binread(metadata_path)
      end
    end
  end

  def test_codex_enabled_setting_accepts_indentation_and_inline_comments
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      plugin_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "config.toml"), <<~TOML)
        [plugins."scw@agent-workflows"]
          enabled = true # managed by Codex
      TOML
      write_manifest(plugin_root, host: "codex")

      out, err, status = run_state("check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")

      assert status.success?, "#{out}#{err}"
      assert_equal "active", JSON.parse(out).dig("native", "state")
    end
  end

  def test_codex_enabled_setting_accepts_quoted_and_dotted_toml_forms
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      plugin_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(target)
      write_manifest(plugin_root, host: "codex")

      [
        "[plugins.\"scw@agent-workflows\"] # plugin\n  \"enabled\" = true\n",
        "plugins.\"scw@agent-workflows\".enabled = true # dotted\n"
      ].each do |config|
        File.write(File.join(target, "config.toml"), config)
        out, err, status = run_state("check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")

        assert status.success?, "#{config.inspect}: #{out}#{err}"
        assert_equal "active", JSON.parse(out).dig("native", "state")
      end

      File.write(File.join(target, "config.toml"), "plugins.\"scw@agent-workflows\".\"enabled\" = false\n")
      out, err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "flat", "--json", codex_state: "disabled"
      )
      assert status.success?, "#{out}#{err}"
      assert_equal "inactive", JSON.parse(out).dig("native", "state")
    end
  end

  def test_codex_multiline_arrays_are_not_mistaken_for_malformed_tables
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      plugin_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(target)
      write_manifest(plugin_root, host: "codex")
      File.write(File.join(target, "config.toml"), <<~TOML)
        features = [
          "one",
          "two",
        ]
        [plugins."scw@agent-workflows"] # active plugin
        enabled = true
      TOML

      out, err, status = run_state("check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")

      assert status.success?, "#{out}#{err}"
      assert_equal "active", JSON.parse(out).dig("native", "state")
    end
  end

  def test_codex_cli_is_authoritative_for_inline_tables_and_plugin_looking_multiline_strings
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      plugin_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(target)
      write_manifest(plugin_root, host: "codex")
      File.write(File.join(target, "config.toml"), <<~'TOML')
        note = """
        plugins."scw@agent-workflows".enabled = false
        """
        plugins."scw@agent-workflows" = { enabled = true }
      TOML

      out, err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json", codex_state: "enabled"
      )

      assert status.success?, "#{out}#{err}"
      assert_equal "active", JSON.parse(out).dig("native", "state")
    end
  end

  def test_codex_cli_missing_error_absent_ambiguous_and_unparseable_states_are_unknown
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(target)
      File.write(
        File.join(target, "config.toml"),
        "[plugins.\"scw@agent-workflows\"]\nenabled = true\nenabled = false # duplicate invalid TOML\n"
      )

      [
        ["error", @fake_codex],
        ["absent", @fake_codex],
        ["ambiguous", @fake_codex],
        ["malformed", @fake_codex],
        ["enabled", File.join(tmp, "missing-codex")]
      ].each do |state, executable|
        out, _err, status = run_state(
          "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
          "--delivery-mode", "flat", "--json", codex_state: state, codex_executable: executable
        )

        refute status.success?, "#{state} unexpectedly succeeded: #{out}"
        payload = JSON.parse(out)
        assert_equal "unknown", payload.dig("native", "state")
        assert_includes payload.fetch("guidance"), "native plugin state"
      end
    end
  end

  def test_codex_plugin_list_timeout_is_structured_unknown
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")

      out, _err, status = run_state_with_env(
        { "QA_CODEX_PLUGIN_STATE" => "sleep", "AGENT_WORKFLOWS_CODEX_TIMEOUT_SECONDS" => "0.05" },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "flat", "--json"
      )
      payload = JSON.parse(out)

      refute status.success?, out
      assert_equal "unknown", payload.dig("native", "state")
      assert_includes payload.fetch("reason"), "timed out"
    end
  end

  def test_legacy_codex_native_plugin_blocks_both_delivery_modes_with_migration_guidance
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      legacy_root = File.join(target, "plugins/cache/agent-workflows/agent-workflows/0.1.0")
      FileUtils.mkdir_p(File.join(legacy_root, ".codex-plugin"))
      FileUtils.mkdir_p(File.join(legacy_root, "skills/example"))
      File.write(
        File.join(target, "config.toml"),
        "[plugins.\"agent-workflows@agent-workflows\"]\nenabled = true\n"
      )
      File.write(
        File.join(legacy_root, ".codex-plugin/plugin.json"),
        "#{JSON.generate('name' => 'agent-workflows', 'skills' => './skills')}\n"
      )
      File.write(File.join(legacy_root, "skills/example/SKILL.md"), "legacy\n")

      %w[flat plugin-companion].each do |delivery_mode|
        out, _err, status = run_state(
          "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
          "--delivery-mode", delivery_mode, "--json", codex_state: "absent"
        )
        payload = JSON.parse(out)

        refute status.success?, "#{delivery_mode} unexpectedly allowed legacy native coexistence"
        assert_equal "unknown", payload.dig("native", "state")
        assert_includes payload.fetch("reason"), "agent-workflows@agent-workflows"
        assert_includes payload.fetch("guidance").downcase, "remove"
        assert_includes payload.fetch("guidance"), "scw@agent-workflows"
      end
    end
  end

  def test_codex_present_but_inconclusive_plugin_config_is_unknown
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "config.toml"), <<~TOML)
        [plugins."scw@agent-workflows"]
        enabled = "yes"
      TOML

      out, _err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "flat", "--json", codex_state: "error"
      )

      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("native", "state")
    end
  end

  def test_distinguishes_disabled_cache_from_uncertain_enabled_state
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      disabled_home = File.join(tmp, "disabled")
      cached_plugin = File.join(disabled_home, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(disabled_home)
      File.write(File.join(disabled_home, "config.toml"), <<~TOML)
        [plugins."scw@agent-workflows"]
        enabled = false
      TOML
      write_manifest(cached_plugin, host: "codex")

      out, err, status = run_state(
        "check", "--host", "codex", "--target", disabled_home, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "flat", "--json", codex_state: "disabled"
      )
      assert status.success?, "#{out}#{err}"
      assert_equal "inactive", JSON.parse(out).dig("native", "state")

      enabled_home = File.join(tmp, "enabled-without-cache")
      FileUtils.mkdir_p(enabled_home)
      File.write(File.join(enabled_home, "config.toml"), <<~TOML)
        [plugins."scw@agent-workflows"]
        enabled = true
      TOML

      out, _err, status = run_state("check", "--host", "codex", "--target", enabled_home, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("native", "state")

      invalid_home = File.join(tmp, "invalid-state")
      FileUtils.mkdir_p(invalid_home)
      File.write(File.join(invalid_home, "config.toml"), <<~TOML)
        [plugins."scw@agent-workflows"
        enabled = true
      TOML

      out, _err, status = run_state(
        "check", "--host", "codex", "--target", invalid_home, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "flat", "--json", codex_state: "error"
      )
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("native", "state")

      corrupt_home = File.join(tmp, "manifest-without-skills")
      corrupt_plugin = File.join(corrupt_home, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(File.join(corrupt_plugin, ".codex-plugin"))
      File.write(File.join(corrupt_home, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
      File.write(
        File.join(corrupt_plugin, ".codex-plugin/plugin.json"),
        "#{JSON.generate('name' => 'scw', 'version' => '0.1.0', 'skills' => './skills/')}\n"
      )

      out, _err, status = run_state("check", "--host", "codex", "--target", corrupt_home, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("native", "state")

      null_skills_home = File.join(tmp, "manifest-with-null-skills")
      null_skills_plugin = File.join(null_skills_home, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(File.join(null_skills_plugin, ".codex-plugin"))
      File.write(File.join(null_skills_home, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
      File.write(File.join(null_skills_plugin, ".codex-plugin/plugin.json"), "#{JSON.generate('name' => 'scw', 'skills' => nil)}\n")

      out, _err, status = run_state("check", "--host", "codex", "--target", null_skills_home, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("native", "state")
    end
  end

  def test_unreadable_or_looping_codex_cache_path_is_structured_unknown
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      cache_root = File.join(target, "plugins/cache/agent-workflows/scw")
      plugin_root = File.join(cache_root, "0.1.0")
      FileUtils.mkdir_p(File.join(plugin_root, ".codex-plugin"))
      File.write(File.join(target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
      File.write(
        File.join(plugin_root, ".codex-plugin/plugin.json"),
        "#{JSON.generate('name' => 'scw', 'skills' => './loop')}\n"
      )
      File.symlink("loop", File.join(plugin_root, "loop"))

      out, _err, status = run_state(
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      refute status.success?, out
      assert_equal "unknown", payload.dig("native", "state")
      assert_includes payload.fetch("reason"), "no valid installed cache"
    end
  end

  def test_malformed_claude_state_shapes_are_unknown
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "claude")
      FileUtils.mkdir_p(File.join(target, "plugins"))
      File.write(File.join(target, "settings.json"), "[]\n")

      out, _err, status = run_state("check", "--host", "claude", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("native", "state")

      File.write(File.join(target, "settings.json"), "#{JSON.generate('enabledPlugins' => { 'scw@agent-workflows' => true })}\n")
      File.write(File.join(target, "plugins/installed_plugins.json"), "[]\n")

      out, _err, status = run_state("check", "--host", "claude", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("native", "state")
    end
  end

  def test_claude_installed_plugin_defaults_enabled_and_explicit_false_overrides
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "claude")
      plugin_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(File.join(target, "plugins"))
      write_manifest(plugin_root, host: "claude")
      File.write(File.join(target, "settings.json"), "{}\n")
      File.write(
        File.join(target, "plugins/installed_plugins.json"),
        "#{JSON.generate('plugins' => { 'scw@agent-workflows' => [{ 'installPath' => plugin_root }] })}\n"
      )

      out, err, status = run_state("check", "--host", "claude", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "plugin-companion", "--json")
      assert status.success?, "#{out}#{err}"
      assert_equal "active", JSON.parse(out).dig("native", "state")

      File.write(File.join(target, "settings.json"), "#{JSON.generate('enabledPlugins' => { 'scw@agent-workflows' => false })}\n")
      out, err, status = run_state("check", "--host", "claude", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "flat", "--json")
      assert status.success?, "#{out}#{err}"
      assert_equal "inactive", JSON.parse(out).dig("native", "state")

      File.write(File.join(target, "settings.json"), "{}\n")
      FileUtils.rm_f(File.join(target, "plugins/installed_plugins.json"))
      out, err, status = run_state("check", "--host", "claude", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "flat", "--json")
      assert status.success?, "#{out}#{err}"
      assert_equal "inactive", JSON.parse(out).dig("native", "state")
    end
  end

  def test_native_state_read_errors_are_structured_unknown
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      injection = File.join(tmp, "binread-error.rb")
      File.write(injection, <<~RUBY)
        module InjectNativeBinreadError
          def binread(path, *)
            raise Errno::EIO, path if path.end_with?("config.toml", "settings.json")
            super
          end
        end
        File.singleton_class.prepend(InjectNativeBinreadError)
      RUBY

      { "codex" => "config.toml", "claude" => "settings.json" }.each do |host, state_file|
        target = File.join(tmp, host)
        FileUtils.mkdir_p(target)
        File.write(File.join(target, state_file), "{}\n")
        out, _err, status = run_state_with_env(
          { "RUBYOPT" => "-r#{injection}" }, "check", "--host", host, "--target", target,
          "--source", File.expand_path("..", __dir__), "--delivery-mode", "flat", "--json"
        )

        refute status.success?, host
        assert_equal "unknown", JSON.parse(out).dig("native", "state")
      end
    end
  end

  def test_migrates_only_unchanged_legacy_managed_copies
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      FileUtils.cp_r(File.join(source, "skills/beta"), File.join(target, "skills/beta"))
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => revision)

      out, err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      assert status.success?, "#{out}#{err}"
      refute_path_exists File.join(target, "skills/alpha")
      refute_path_exists File.join(target, "skills/beta")
      assert_equal %w[alpha beta], JSON.parse(out).dig("flat", "removed").map { |path| File.basename(path) }.sort
    end
  end

  def test_actual_skill_absent_from_recorded_revision_blocks_all_migration
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills/stale-renamed-skill"))
      File.write(File.join(target, "skills/stale-renamed-skill/SKILL.md"), "legacy\n")
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => revision)

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert_path_exists File.join(target, "skills/stale-renamed-skill/SKILL.md")
      assert_path_exists File.join(target, "skills/alpha/SKILL.md"), "known managed paths must remain when any direct child is unknown"
      assert_equal [File.join(target, "skills/stale-renamed-skill")], JSON.parse(out).dig("flat", "blocking")
    end
  end

  def test_modified_copy_blocks_all_migration_and_is_preserved
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      FileUtils.cp_r(File.join(source, "skills/beta"), File.join(target, "skills/beta"))
      File.write(File.join(target, "skills/alpha/SKILL.md"), "user modification\n")
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => revision)

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")
      payload = JSON.parse(out)

      refute status.success?
      assert_path_exists File.join(target, "skills/alpha/SKILL.md")
      assert_path_exists File.join(target, "skills/beta/SKILL.md"), "safe paths must not be removed when any path is ambiguous"
      assert_equal [File.join(target, "skills/alpha")], payload.dig("flat", "blocking")
      assert_includes payload.fetch("guidance"), "preserved"
    end
  end

  def test_invalid_install_metadata_is_unknown_and_preserved
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      create_source(source)
      write_codex_native_state(target)
      metadata_path = File.join(target, ".agent-workflows-install.json")
      File.write(metadata_path, "{not-json\n")

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("flat", "state")
      assert_equal "{not-json\n", File.read(metadata_path)

      File.write(metadata_path, "[]\n")
      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("flat", "state")
      assert_equal "[]\n", File.read(metadata_path)

      File.write(metadata_path, "#{JSON.generate('source' => [], 'source_revision' => 'unknown', 'delivery_mode' => 'flat')}\n")
      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")
      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("flat", "state")
    end
  end

  def test_symlinked_install_metadata_cannot_authorize_fingerprint_migration
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      installed = File.join(target, "skills/alpha")
      external_metadata = File.join(tmp, "external-metadata.json")
      FileUtils.mkdir_p(source)
      create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.dirname(installed))
      FileUtils.cp_r(File.join(source, "skills/alpha"), installed)
      fingerprint = AgentWorkflowsDeliveryState.directory_fingerprint(installed)
      File.write(external_metadata, "#{JSON.generate(
        'mode' => 'copy',
        'delivery_mode' => 'flat',
        'source' => source,
        'source_revision' => 'unknown',
        'managed_skill_copy_fingerprints' => { 'alpha' => fingerprint }
      )}\n")
      metadata_path = File.join(target, ".agent-workflows-install.json")
      File.symlink(external_metadata, metadata_path)

      out, _err, status = run_state(
        "migrate", "--host", "codex", "--target", target, "--source", source,
        "--delivery-mode", "plugin-companion", "--json"
      )

      refute status.success?
      assert_equal "unknown", JSON.parse(out).dig("flat", "state")
      assert_path_exists File.join(installed, "SKILL.md")
      assert File.symlink?(metadata_path)
      assert_path_exists external_metadata
    end
  end

  def test_mismatched_symlink_blocks_all_migration
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      other = File.join(tmp, "other-alpha")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.mkdir_p(other)
      File.symlink(other, File.join(target, "skills/alpha"))
      File.symlink(File.join(source, "skills/beta"), File.join(target, "skills/beta"))
      write_metadata(target, "host" => "codex", "mode" => "symlink", "source" => source, "source_revision" => revision)

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert File.symlink?(File.join(target, "skills/alpha"))
      assert File.symlink?(File.join(target, "skills/beta")), "known managed link must remain when any link is ambiguous"
      assert_equal [File.join(target, "skills/alpha")], JSON.parse(out).dig("flat", "blocking")
    end
  end

  def test_symlinked_skills_parent_blocks_migration_without_touching_source
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      File.symlink(File.join(source, "skills"), File.join(target, "skills"))
      write_metadata(target, "host" => "codex", "mode" => "symlink", "source" => source, "source_revision" => revision)

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert File.symlink?(File.join(target, "skills"))
      assert_path_exists File.join(source, "skills/alpha/SKILL.md")
      assert_path_exists File.join(source, "skills/beta/SKILL.md")
      assert_equal [File.join(target, "skills")], JSON.parse(out).dig("flat", "blocking")
    end
  end

  def test_non_directory_skills_parent_blocks_fingerprint_migration
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      create_source(source)
      write_codex_native_state(target)
      skills_path = File.join(target, "skills")
      File.write(skills_path, "personal skills sentinel\n")
      fingerprint = AgentWorkflowsDeliveryState.directory_fingerprint(File.join(source, "skills/alpha"))
      write_metadata(
        target,
        "host" => "codex",
        "mode" => "copy",
        "delivery_mode" => "flat",
        "source" => source,
        "source_revision" => "unknown",
        "managed_skill_copy_fingerprints" => { "alpha" => fingerprint }
      )

      out, _err, status = run_state(
        "migrate", "--host", "codex", "--target", target, "--source", source,
        "--delivery-mode", "plugin-companion", "--json"
      )

      refute status.success?
      assert_equal [skills_path], JSON.parse(out).dig("flat", "blocking")
      assert_equal "personal skills sentinel\n", File.read(skills_path)
    end
  end

  def test_symlinked_target_ancestor_blocks_migration
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      real_parent = File.join(tmp, "real-parent")
      linked_parent = File.join(tmp, "linked-parent")
      target = File.join(linked_parent, "codex")
      FileUtils.mkdir_p(source)
      FileUtils.mkdir_p(real_parent)
      File.symlink(real_parent, linked_parent)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => revision)

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert_path_exists File.join(target, "skills/alpha/SKILL.md")
      assert_equal [linked_parent], JSON.parse(out).dig("flat", "blocking")
    end
  end

  def test_deletion_failure_blocks_migration_and_reports_remaining_paths
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => revision)
      injection = File.join(tmp, "rename-failure.rb")
      File.write(injection, <<~RUBY)
        class << File
          alias qa_original_rename rename
          def rename(source, destination)
            if destination.include?(".agent-workflows-flat-migration-")
              raise Errno::EACCES, destination
            end
            qa_original_rename(source, destination)
          end
        end
      RUBY

      out, _err, status = run_state_with_env(
        { "RUBYOPT" => "-r#{injection}" },
        "migrate", "--host", "codex", "--target", target, "--source", source,
        "--delivery-mode", "plugin-companion", "--json"
      )

      refute status.success?
      assert_path_exists File.join(target, "skills/alpha/SKILL.md")
      payload = JSON.parse(out)
      refute payload.fetch("compatible")
      assert_equal [File.join(target, "skills/alpha")], payload.dig("flat", "blocking")
      assert_includes payload.fetch("reason"), "failed to remove"
    end
  end

  def test_new_direct_child_during_staging_rolls_back_and_blocks_migration
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      injection = File.join(tmp, "staging-race.rb")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      FileUtils.cp_r(File.join(source, "skills/beta"), File.join(target, "skills/beta"))
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => revision)
      File.write(injection, <<~RUBY)
        require "fileutils"
        class << File
          alias qa_original_rename rename
          def rename(source, destination)
            result = qa_original_rename(source, destination)
            unless defined?(@qa_race_injected) && @qa_race_injected
              @qa_race_injected = true
              raced = File.join(File.dirname(source), "raced-child")
              FileUtils.mkdir_p(raced)
              File.write(File.join(raced, "SKILL.md"), "raced\n")
            end
            result
          end
        end
      RUBY

      out, err, status = run_state_with_env(
        { "RUBYOPT" => "-r#{injection}" },
        "migrate", "--host", "codex", "--target", target, "--source", source,
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      refute status.success?, "#{out}#{err}"
      assert_path_exists File.join(target, "skills/alpha/SKILL.md")
      assert_path_exists File.join(target, "skills/beta/SKILL.md")
      assert_path_exists File.join(target, "skills/raced-child/SKILL.md")
      assert_equal [File.join(target, "skills/raced-child")], payload.dig("flat", "blocking")
    end
  end

  def test_partial_quarantine_cleanup_failure_does_not_attempt_lossy_rollback
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      injection = File.join(tmp, "partial-cleanup-failure.rb")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      FileUtils.cp_r(File.join(source, "skills/beta"), File.join(target, "skills/beta"))
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => revision)
      File.write(injection, <<~RUBY)
        require "fileutils"
        module PartialCleanupFailure
          def remove_entry(path, force = false)
            if File.basename(path).start_with?(".agent-workflows-flat-migration-")
              first = Dir.children(path).sort.first
              super(File.join(path, first), force)
              raise Errno::EACCES, path
            end
            super
          end
        end
        FileUtils.singleton_class.prepend(PartialCleanupFailure)
      RUBY

      out, err, status = run_state_with_env(
        { "RUBYOPT" => "-r#{injection}" },
        "migrate", "--host", "codex", "--target", target, "--source", source,
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      refute_path_exists File.join(target, "skills/alpha")
      refute_path_exists File.join(target, "skills/beta")
      assert payload.dig("flat", "cleanup_pending")
      assert_path_exists payload.dig("flat", "staging")
    end
  end

  def test_missing_recorded_revision_blocks_copy_migration
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => "0" * 40)

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert_path_exists File.join(target, "skills/alpha/SKILL.md")
      assert_equal "unknown", JSON.parse(out).dig("flat", "state")
    end
  end

  def test_option_like_recorded_revision_fails_closed_without_git_option_injection
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      create_source(source)
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills/alpha"))
      File.write(File.join(target, "skills/alpha/SKILL.md"), "alpha\n")
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => "--help")

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert_path_exists File.join(target, "skills/alpha/SKILL.md")
      assert_equal "unknown", JSON.parse(out).dig("flat", "state")
    end
  end

  def test_null_legacy_delivery_mode_falls_back_to_flat
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(source)
      revision = create_source(source)
      FileUtils.mkdir_p(File.join(target, "skills"))
      FileUtils.cp_r(File.join(source, "skills/alpha"), File.join(target, "skills/alpha"))
      write_metadata(
        target,
        "host" => "codex", "mode" => "copy", "delivery_mode" => nil,
        "source" => source, "source_revision" => revision
      )

      out, err, status = run_state("check", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "flat", "--json")

      assert status.success?, "#{out}#{err}"
      assert_equal "present", JSON.parse(out).dig("flat", "state")
    end
  end

  def test_unknown_recorded_revision_blocks_when_current_source_drops_a_legacy_skill
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(File.join(source, "skills/beta"))
      File.write(File.join(source, "skills/beta/SKILL.md"), "beta\n")
      write_codex_native_state(target)
      FileUtils.mkdir_p(File.join(target, "skills/legacy"))
      File.write(File.join(target, "skills/legacy/SKILL.md"), "legacy pack skill\n")
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => "unknown")

      out, _err, status = run_state("migrate", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      refute status.success?
      assert_path_exists File.join(target, "skills/legacy/SKILL.md")
      assert_equal "unknown", JSON.parse(out).dig("flat", "state")
    end
  end

  def test_unknown_recorded_revision_allows_an_already_empty_flat_tree
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(File.join(source, "skills/beta"))
      File.write(File.join(source, "skills/beta/SKILL.md"), "beta\n")
      write_codex_native_state(target)
      write_metadata(target, "host" => "codex", "mode" => "copy", "source" => source, "source_revision" => "unknown")

      out, err, status = run_state("check", "--host", "codex", "--target", target, "--source", source, "--delivery-mode", "plugin-companion", "--json")

      assert status.success?, "#{out}#{err}"
      assert_equal "absent", JSON.parse(out).dig("flat", "state")
    end
  end
end
