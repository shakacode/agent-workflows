#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-delivery-state", __dir__)

class AgentWorkflowsDeliveryStateTest < Minitest::Test
  def run_state(*)
    Open3.capture3("ruby", SCRIPT, *)
  end

  def run_state_with_env(env, *)
    Open3.capture3(env, "ruby", SCRIPT, *)
  end

  def write_manifest(root, host:)
    manifest_dir = File.join(root, host == "codex" ? ".codex-plugin" : ".claude-plugin")
    FileUtils.mkdir_p(manifest_dir)
    FileUtils.mkdir_p(File.join(root, "skills/example"))
    File.write(File.join(root, "skills/example/SKILL.md"), "example\n")
    File.write(File.join(manifest_dir, "plugin.json"), "#{JSON.pretty_generate('name' => 'scw', 'version' => '0.1.0', 'skills' => './skills/')}\n")
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
      out, err, status = run_state("check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "flat", "--json")
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

  def test_codex_present_but_inconclusive_plugin_config_is_unknown
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "config.toml"), <<~TOML)
        [plugins."scw@agent-workflows"]
        enabled = "yes"
      TOML

      out, _err, status = run_state("check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__), "--delivery-mode", "flat", "--json")

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

      out, err, status = run_state("check", "--host", "codex", "--target", disabled_home, "--source", File.expand_path("..", __dir__), "--delivery-mode", "flat", "--json")
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

      out, _err, status = run_state("check", "--host", "codex", "--target", invalid_home, "--source", File.expand_path("..", __dir__), "--delivery-mode", "flat", "--json")
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
