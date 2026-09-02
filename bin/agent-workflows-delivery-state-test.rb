#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-delivery-state", __dir__)
load SCRIPT
require_relative "agent_doctor/install_ownership"
require_relative "agent_doctor/timeout_budget"

class AgentWorkflowsDeliveryStateTest < Minitest::Test
  def setup
    @fake_codex_dir = Dir.mktmpdir("fake-codex-plugin-list")
    @fake_codex = File.join(@fake_codex_dir, "codex")
    @superpowers_catalog_root = File.join(@fake_codex_dir, "superpowers-catalog")
    FileUtils.mkdir_p(File.join(@superpowers_catalog_root, ".codex-plugin"))
    File.write(
      File.join(@superpowers_catalog_root, ".codex-plugin/plugin.json"),
      "#{JSON.generate('name' => 'superpowers', 'version' => '5.1.3', 'repository' => 'https://github.com/obra/superpowers')}\n"
    )
    File.write(@fake_codex, <<~RUBY)
      #!#{RbConfig.ruby}
      require "fileutils"

      abort "unexpected arguments: \#{ARGV.inspect}" unless ARGV[0, 3] == %w[plugin list --marketplace] && ARGV.length == 4
      if ENV["QA_SIMULATE_ARG0_BOOTSTRAP"] == "1"
        target = File.expand_path(ENV.fetch("CODEX_HOME"))
        filesystem_root = target
        loop do
          parent = File.dirname(filesystem_root)
          break if parent == filesystem_root

          filesystem_root = parent
        end
        temp_roots = %w[TMPDIR TMP TEMP].map { |name| ENV[name] }
        FileUtils.mkdir_p(File.join(target, "tmp", "arg0")) unless temp_roots.all? { |root| root == filesystem_root }
      end
      marketplace = ARGV.fetch(3)
      if marketplace != "agent-workflows"
        sleep Float(ENV.fetch("QA_SUPERPOWERS_SLEEP_SECONDS", "0"))
        if marketplace == ENV["QA_SUPERPOWERS_FAIL_MARKETPLACE"]
          warn "catalog unavailable"
          exit 2
        end
        state = ENV.fetch("QA_SUPERPOWERS_STATE", "installed-disabled")
        installed_version = ENV.fetch("QA_SUPERPOWERS_VERSION", "host-version")
        catalog_root = ENV.fetch("QA_SUPERPOWERS_CATALOG_ROOT")
        plugin_id = "superpowers@\#{marketplace}"
        if marketplace == ENV.fetch("QA_SUPERPOWERS_MARKETPLACE", "openai-curated")
          puts "PLUGIN STATUS VERSION PATH"
          row = case state
                when "active"
                  "\#{plugin_id}  installed, enabled   \#{installed_version}  \#{catalog_root}"
                when "installed-disabled"
                  "\#{plugin_id}  installed, disabled  \#{installed_version}  \#{catalog_root}"
                when "available-not-installed"
                  version = ENV["QA_SUPERPOWERS_NOT_INSTALLED_VERSION"]
                  if version.to_s.empty?
                    "\#{plugin_id}  not installed                     \#{catalog_root}"
                  else
                    "\#{plugin_id}  not installed  \#{version}  \#{catalog_root}"
                  end
                when "UNKNOWN"
                  warn "catalog unavailable"
                  exit 2
                else
                  abort "unknown Superpowers state: \#{state}"
                end
          puts row
          puts row if marketplace == ENV["QA_SUPERPOWERS_DUPLICATE_MARKETPLACE"]
        else
          puts "No plugins found in marketplace `\#{marketplace}`."
        end
        exit
      end

      state = ENV.fetch("QA_CODEX_PLUGIN_STATE", "enabled")
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
        sleep Float(ENV.fetch("QA_CODEX_PLUGIN_SLEEP_SECONDS", "5"))
      else
        abort "unknown fake state: \#{state}"
      end
    RUBY
    FileUtils.chmod(0o755, @fake_codex)
    warm_fake_codex
  end

  def teardown
    FileUtils.remove_entry(@fake_codex_dir)
  end

  # Pay the fake codex CLI's first-execution cost before anything is being
  # timed. macOS assesses a newly written executable the first time it runs,
  # and that first execution has a multi-second tail on a loaded machine --
  # long enough to blow codex_plugin_cli_state's default 5s budget and report
  # "Codex plugin state command timed out" for tests that never intended to
  # exercise the timeout path (#260, same shape as `warm_stub` in
  # skills/pr-batch/bin/pr-merge-submit-test.rb). Calling the stub with no
  # arguments still reads QA_CODEX_PLUGIN_STATE (an inert ENV.fetch) but then
  # hits its own "unexpected arguments" guard before dispatching on that
  # value, so the warmup never reaches the sleep branch the deliberate-timeout
  # test relies on; its exit status and output are both discarded.
  def warm_fake_codex
    system(@fake_codex, out: File::NULL, err: File::NULL)
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
      "QA_CODEX_PLUGIN_STATE" => codex_state,
      "QA_SUPERPOWERS_CATALOG_ROOT" => @superpowers_catalog_root
    }
    env["QA_CODEX_PLUGIN_VERSION"] = codex_version if codex_version
    env["QA_CODEX_PLUGIN_SOURCE"] = codex_source if codex_source
    Open3.capture3(env, "ruby", SCRIPT, *args)
  end

  def run_state_with_env(env, *args)
    defaults = {
      "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => @fake_codex,
      "QA_CODEX_PLUGIN_STATE" => "enabled",
      "QA_SUPERPOWERS_CATALOG_ROOT" => @superpowers_catalog_root
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

  def write_superpowers_manifest(root, version: "6.2.0")
    FileUtils.mkdir_p(File.join(root, ".codex-plugin"))
    File.write(
      File.join(root, ".codex-plugin/plugin.json"),
      "#{JSON.generate('name' => 'superpowers', 'version' => version, 'repository' => 'https://github.com/obra/superpowers')}\n"
    )
  end

  def target_tree_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .reject { |path| [".", ".."].include?(File.basename(path)) }
       .to_h do |path|
      relative = path.delete_prefix("#{root}#{File::SEPARATOR}")
      value = if File.symlink?(path)
                [:symlink, File.readlink(path)]
              elsif File.file?(path)
                [:file, File.binread(path)]
              else
                [:directory]
              end
      [relative, value]
    end
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

  def test_reports_active_superpowers_as_advisory_coexistence_state
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      write_codex_native_state(target)

      out, err, status = run_state_with_env(
        { "QA_SUPERPOWERS_STATE" => "active", "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev" },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert payload.fetch("compatible"), "Superpowers detection must remain advisory"
      assert_equal "active", payload.dig("superpowers", "state")
      assert_equal "superpowers@superpowers-dev", payload.dig("superpowers", "catalog_entries", 0, "plugin_id")
      assert_equal "5.1.3", payload.dig("superpowers", "catalog_entries", 0, "catalog_version")
      assert_equal "host-version", payload.dig("superpowers", "catalog_entries", 0, "installed_version")
      refute payload.dig("superpowers", "catalog_entries", 0).key?("marketplace_revision")
      assert_equal "https://github.com/obra/superpowers", payload.dig("superpowers", "catalog_entries", 0, "upstream_repository")
      assert_nil payload.dig("superpowers", "upstream_version")
      assert_equal "not-queried", payload.dig("superpowers", "upstream_version_source")
    end
  end

  def test_codex_marketplace_queries_do_not_mutate_the_inspected_target_tree
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      write_codex_native_state(target)
      before = target_tree_snapshot(target)

      out, err, status = run_state_with_env(
        {
          "QA_SIMULATE_ARG0_BOOTSTRAP" => "1",
          "QA_SUPERPOWERS_STATE" => "active"
        },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert_equal "active", payload.dig("superpowers", "state")
      assert_equal before, target_tree_snapshot(target)

      failed_out, failed_err, failed_status = run_state_with_env(
        {
          "QA_SIMULATE_ARG0_BOOTSTRAP" => "1",
          "QA_SUPERPOWERS_FAIL_MARKETPLACE" => "openai-curated"
        },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      failed_payload = JSON.parse(failed_out)

      assert failed_status.success?, "#{failed_out}#{failed_err}"
      assert_equal "UNKNOWN", failed_payload.dig("superpowers", "state")
      assert_includes failed_payload.dig("superpowers", "warnings", 0), "catalog unavailable"
      assert_equal before, target_tree_snapshot(target)
    end
  end

  def test_unexpected_superpowers_probe_failure_returns_structured_unknown
    original = AgentWorkflowsDeliveryState.method(:codex_marketplace_output)
    AgentWorkflowsDeliveryState.define_singleton_method(:codex_marketplace_output) do |*|
      raise StandardError, "unexpected probe failure"
    end

    payload = AgentWorkflowsDeliveryState.superpowers_state("codex", @fake_codex_dir)

    assert_equal "UNKNOWN", payload.fetch("state")
    assert_equal [], payload.fetch("catalog_entries")
    assert_equal 3, payload.fetch("warnings").length
    assert_equal(
      %w[openai-curated openai-curated-remote superpowers-dev],
      payload.fetch("warnings").map { |warning| warning[/marketplace (\S+):/, 1] }
    )
    assert(payload.fetch("warnings").all? { |warning| warning.include?("unexpected probe failure") })
    assert_includes payload.fetch("reason"), "unexpected probe failure"
  ensure
    AgentWorkflowsDeliveryState.define_singleton_method(:codex_marketplace_output, original)
  end

  def test_trailing_separator_catalog_root_retains_metadata_but_noncanonical_roots_do_not
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      write_codex_native_state(target)

      roots = {
        "#{@superpowers_catalog_root}/" => true,
        File.join(@superpowers_catalog_root, "..", File.basename(@superpowers_catalog_root)) => false,
        File.basename(@superpowers_catalog_root) => false
      }
      roots.each do |catalog_root, metadata_expected|
        out, err, status = run_state_with_env(
          {
            "QA_SUPERPOWERS_STATE" => "active",
            "QA_SUPERPOWERS_CATALOG_ROOT" => catalog_root
          },
          "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
          "--delivery-mode", "plugin-companion", "--json"
        )
        entry = JSON.parse(out).dig("superpowers", "catalog_entries", 0)

        assert status.success?, "#{catalog_root}: #{out}#{err}"
        if metadata_expected
          assert_equal "5.1.3", entry.fetch("catalog_version"), catalog_root
          assert_equal "https://github.com/obra/superpowers", entry.fetch("upstream_repository"), catalog_root
        else
          refute entry.key?("catalog_version"), catalog_root
          refute entry.key?("upstream_repository"), catalog_root
        end
      end
    end
  end

  def test_installed_superpowers_url_path_reads_catalog_metadata_from_safe_codex_cache
    {
      "active" => "active",
      "installed-disabled" => "installed-disabled"
    }.each do |fixture_state, expected_state|
      Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
        target = File.join(tmp, "codex")
        version = "6.2.0"
        cache_root = File.join(target, "plugins/cache/openai-curated/superpowers", version)
        write_codex_native_state(target)
        write_superpowers_manifest(cache_root, version: version)

        out, err, status = run_state_with_env(
          {
            "QA_SUPERPOWERS_STATE" => fixture_state,
            "QA_SUPERPOWERS_VERSION" => version,
            "QA_SUPERPOWERS_CATALOG_ROOT" => "https://github.com/obra/superpowers.git"
          },
          "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
          "--delivery-mode", "plugin-companion", "--json"
        )
        payload = JSON.parse(out)
        entry = payload.dig("superpowers", "catalog_entries", 0)

        assert status.success?, "#{fixture_state}: #{out}#{err}"
        assert_equal expected_state, payload.dig("superpowers", "state"), fixture_state
        assert_equal version, entry.fetch("installed_version"), fixture_state
        assert_equal version, entry.fetch("catalog_version"), fixture_state
        assert_equal "https://github.com/obra/superpowers", entry.fetch("upstream_repository"), fixture_state
      end
    end
  end

  def test_installed_superpowers_cache_version_cannot_escape_codex_home
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      escaped_root = File.join(tmp, "escaped")
      write_codex_native_state(target)
      write_superpowers_manifest(escaped_root, version: "escaped-version")

      out, err, status = run_state_with_env(
        {
          "QA_SUPERPOWERS_STATE" => "active",
          "QA_SUPERPOWERS_VERSION" => "../../../../escaped",
          "QA_SUPERPOWERS_CATALOG_ROOT" => "https://github.com/obra/superpowers.git"
        },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)
      entry = payload.dig("superpowers", "catalog_entries", 0)

      assert status.success?, "#{out}#{err}"
      assert_equal "active", payload.dig("superpowers", "state")
      refute entry.key?("catalog_version")
      refute entry.key?("upstream_repository")
    end
  end

  def test_queries_superpowers_marketplaces_concurrently_with_one_timeout_window
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      write_codex_native_state(target)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, err, status = run_state_with_env(
        {
          "AGENT_WORKFLOWS_CODEX_TIMEOUT_SECONDS" => "1",
          "QA_SUPERPOWERS_SLEEP_SECONDS" => "5"
        },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert_equal "UNKNOWN", payload.dig("superpowers", "state")
      assert_equal(
        %w[openai-curated openai-curated-remote superpowers-dev],
        payload.dig("superpowers", "warnings").map { |warning| warning[/marketplace (\S+)/, 1] }
      )
      assert_operator elapsed, :<, 2.2, "marketplace queries took #{elapsed.round(3)}s"
    end
  end

  def test_not_installed_row_with_blank_version_reads_catalog_metadata_from_path
    assert_not_installed_catalog_metadata({})
  end

  def test_not_installed_row_with_version_reads_catalog_metadata_from_final_path_column
    assert_not_installed_catalog_metadata("QA_SUPERPOWERS_NOT_INSTALLED_VERSION" => "catalog-version")
  end

  def test_native_and_superpowers_queries_share_the_workflow_timeout_window
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, _err, status = run_state_with_env(
        {
          "QA_CODEX_PLUGIN_STATE" => "sleep",
          "QA_CODEX_PLUGIN_SLEEP_SECONDS" => "10",
          "QA_SUPERPOWERS_SLEEP_SECONDS" => "10"
        },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "flat", "--json"
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      payload = JSON.parse(out)

      refute status.success?, out
      assert_equal "unknown", payload.dig("native", "state")
      assert_equal "UNKNOWN", payload.dig("superpowers", "state")
      assert_operator elapsed, :<, AgentDoctor::TimeoutBudget::WORKFLOW_STATUS_DEFAULT,
                      "delivery-state check took #{elapsed.round(3)}s"
    end
  end

  def assert_not_installed_catalog_metadata(environment)
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      write_codex_native_state(target)

      out, err, status = run_state_with_env(
        environment.merge("QA_SUPERPOWERS_STATE" => "available-not-installed"),
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)
      entry = payload.dig("superpowers", "catalog_entries", 0)

      assert status.success?, "#{out}#{err}"
      assert_equal "available-not-installed", payload.dig("superpowers", "state")
      assert_nil entry.fetch("installed_version")
      assert_equal "5.1.3", entry.fetch("catalog_version")
      assert_equal "https://github.com/obra/superpowers", entry.fetch("upstream_repository")
    end
  end

  def test_active_superpowers_preserves_partial_marketplace_failures_as_warnings
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      write_codex_native_state(target)

      out, err, status = run_state_with_env(
        {
          "QA_SUPERPOWERS_STATE" => "active",
          "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev",
          "QA_SUPERPOWERS_FAIL_MARKETPLACE" => "openai-curated"
        },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert_equal "active", payload.dig("superpowers", "state")
      assert_equal 1, payload.dig("superpowers", "warnings").length
      assert_includes payload.dig("superpowers", "warnings", 0), "openai-curated"
      assert_includes payload.dig("superpowers", "warnings", 0), "catalog unavailable"
    end
  end

  def test_duplicate_superpowers_rows_are_ambiguous
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      target = File.join(tmp, "codex")
      write_codex_native_state(target)

      out, err, status = run_state_with_env(
        {
          "QA_SUPERPOWERS_STATE" => "installed-disabled",
          "QA_SUPERPOWERS_DUPLICATE_MARKETPLACE" => "openai-curated"
        },
        "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "plugin-companion", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      assert_equal "UNKNOWN", payload.dig("superpowers", "state")
      assert_equal 1, payload.dig("superpowers", "warnings").length
      assert_includes payload.dig("superpowers", "warnings", 0), "ambiguous"
      assert_includes payload.dig("superpowers", "warnings", 0), "openai-curated"
    end
  end

  def test_reports_each_non_active_superpowers_state_without_mutation
    expected_states = {
      "installed-disabled" => "installed-disabled",
      "available-not-installed" => "available-not-installed",
      "UNKNOWN" => "UNKNOWN"
    }

    expected_states.each do |fixture_state, expected_state|
      Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
        target = File.join(tmp, "codex")
        write_codex_native_state(target)
        config_path = File.join(target, "config.toml")
        config_before = File.binread(config_path)

        out, err, status = run_state_with_env(
          { "QA_SUPERPOWERS_STATE" => fixture_state },
          "check", "--host", "codex", "--target", target, "--source", File.expand_path("..", __dir__),
          "--delivery-mode", "plugin-companion", "--json"
        )
        payload = JSON.parse(out)

        assert status.success?, "#{fixture_state}: #{out}#{err}"
        assert payload.fetch("compatible"), fixture_state
        assert_equal expected_state, payload.dig("superpowers", "state"), fixture_state
        assert_equal config_before, File.binread(config_path), fixture_state
      end
    end
  end

  def test_non_codex_json_omits_superpowers_diagnostic
    Dir.mktmpdir("agent-workflows-delivery-state") do |target|
      out, err, status = run_state(
        "check", "--host", "claude", "--target", target, "--source", File.expand_path("..", __dir__),
        "--delivery-mode", "flat", "--json"
      )
      payload = JSON.parse(out)

      assert status.success?, "#{out}#{err}"
      refute payload.key?("superpowers"), out
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

  def managed_path_fingerprint(path)
    stat = File.lstat(path)
    mode = stat.mode & 0o7777
    if stat.directory?
      Digest::SHA256.hexdigest(JSON.generate(["directory", mode]))
    else
      Digest::SHA256.hexdigest(JSON.generate(["file", mode, Digest::SHA256.file(path).hexdigest]))
    end
  end

  def write_managed_bin_copy(target, source, contents)
    fingerprints = {}
    contents.each do |relative, body|
      # Match what a real install produces: helpers at 0755, tree files at 0644.
      mode = relative.include?("/") ? 0o644 : 0o755
      [File.join(target, "bin", relative), File.join(source, "bin", relative)].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        FileUtils.chmod(mode, path)
      end
      fingerprints[relative] = managed_path_fingerprint(File.join(target, "bin", relative))
    end
    fingerprints
  end

  def record_managed_doctor_root(target, source, fingerprints)
    [File.join(target, "bin/agent_doctor"), File.join(source, "bin/agent_doctor")].each do |path|
      FileUtils.chmod(0o755, path) if File.directory?(path)
    end
    fingerprints.merge("agent_doctor" => managed_path_fingerprint(File.join(target, "bin/agent_doctor")))
  end

  def managed_bin_metadata(target, source, fingerprints, overrides = {})
    write_metadata(
      target,
      {
        "host" => "codex",
        "mode" => "copy",
        "delivery_mode" => "flat",
        "source" => source,
        "source_revision" => "unknown",
        "managed_bin_copy_fingerprints" => fingerprints
      }.merge(overrides)
    )
  end

  def check_managed_bin(target, source)
    out, err, status = run_state(
      "check", "--host", "codex", "--target", target, "--source", source,
      "--delivery-mode", "flat", "--json", codex_state: "disabled"
    )
    [JSON.parse(out), status, "#{out}#{err}"]
  end

  def managed_bin_fixture_fingerprints(target, source)
    fingerprints = write_managed_bin_copy(
      target,
      source,
      "agent-workflows-status" => "status helper\n",
      "agent_doctor/autonomous_merge_policy.rb" => "policy library\n",
      "agent_doctor/renderer.rb" => "renderer\n"
    )
    record_managed_doctor_root(target, source, fingerprints)
  end

  def managed_bin_fixture(tmp)
    source = File.join(tmp, "source")
    target = File.join(tmp, "codex")
    FileUtils.mkdir_p(File.join(source, "skills"))
    FileUtils.mkdir_p(target)
    [source, target, managed_bin_fixture_fingerprints(target, source)]
  end

  def test_unmodified_managed_bin_copies_stay_compatible
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_equal "present", payload.dig("bin", "state")
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_modified_managed_bin_copy_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      tampered = File.join(target, "bin/agent_doctor/autonomous_merge_policy.rb")
      File.write(tampered, "policy library\n# tampered\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      refute payload.fetch("compatible")
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [tampered], payload.dig("bin", "blocking")
      assert_includes payload.fetch("reason"), tampered
      assert_path_exists tampered
    end
  end

  def test_modified_managed_bin_helper_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      tampered = File.join(target, "bin/agent-workflows-status")
      File.write(tampered, "status helper\n# local edit\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [tampered], payload.dig("bin", "blocking")
    end
  end

  def test_managed_bin_helper_matching_the_current_source_stays_compatible
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      moved = "status helper v2\n"
      helper = File.join(target, "bin/agent-workflows-status")
      File.write(File.join(source, "bin/agent-workflows-status"), moved)
      File.write(helper, moved)
      # What the installer would write: source content at 0755.
      FileUtils.chmod(0o755, helper)

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_equal "present", payload.dig("bin", "state")
    end
  end

  def test_helper_fallback_uses_the_installed_mode_not_the_source_mode
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      moved = "status helper v2\n"
      source_helper = File.join(source, "bin/agent-workflows-status")
      helper = File.join(target, "bin/agent-workflows-status")
      File.write(source_helper, moved)
      # A source revision that carries the helper at 0644 still installs it at
      # 0755, so an installed helper already in that state is owned.
      FileUtils.chmod(0o644, source_helper)
      File.write(helper, moved)
      FileUtils.chmod(0o755, helper)

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_equal "present", payload.dig("bin", "state")
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_doctor_module_matching_only_the_current_source_still_blocks
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      # Hand-copying newer source content over an installed module leaves the
      # ownership marker attesting the recorded contents, so the installer
      # refuses the upgrade however current the file looks.
      moved = "policy library v2\n"
      module_path = File.join(target, "bin/agent_doctor/autonomous_merge_policy.rb")
      File.write(File.join(source, "bin/agent_doctor/autonomous_merge_policy.rb"), moved)
      File.write(module_path, moved)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [module_path], payload.dig("bin", "blocking")
    end
  end

  def test_missing_managed_bin_helper_does_not_block_reinstallation
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      FileUtils.rm_f(File.join(target, "bin/agent-workflows-status"))

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_equal ["agent-workflows-status"], payload.dig("bin", "missing")
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_missing_doctor_module_blocks_because_the_installer_cannot_restore_it
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      deleted = File.join(target, "bin/agent_doctor/renderer.rb")
      FileUtils.rm_f(deleted)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [deleted], payload.dig("bin", "blocking")
      assert_includes payload.fetch("reason"), "cannot restore"
      assert_includes payload.fetch("guidance"), File.join(target, "bin/agent_doctor")
    end
  end

  def test_missing_doctor_module_the_source_dropped_stays_non_blocking
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      # rsync --delete would remove this module anyway, so there is nothing the
      # installer needs to restore. This is also the shape the installer's own
      # post-rsync verification sees during an upgrade that drops a module.
      FileUtils.rm_f(File.join(source, "bin/agent_doctor/renderer.rb"))
      FileUtils.rm_f(File.join(target, "bin/agent_doctor/renderer.rb"))

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
      assert_equal ["agent_doctor/renderer.rb"], payload.dig("bin", "missing")
    end
  end

  def test_missing_doctor_modules_stay_non_blocking_when_the_tree_is_absent
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      # An absent tree short-circuits the installer's marker check, so rsync
      # restores it and status must not block.
      FileUtils.rm_rf(File.join(target, "bin/agent_doctor"))

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_missing_doctor_modules_stay_non_blocking_when_the_tree_is_empty
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor = File.join(target, "bin/agent_doctor")
      FileUtils.rm_rf(doctor)
      FileUtils.mkdir_p(doctor)

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_unrecorded_bin_paths_do_not_block
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      File.write(File.join(target, "bin/personal-helper"), "unrelated\n")
      doctor_root = File.join(target, "bin/agent_doctor")
      File.write(
        File.join(doctor_root, ".agent-workflows-managed"),
        "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n"
      )

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_chmod_only_change_to_a_managed_bin_copy_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      helper = File.join(target, "bin/agent-workflows-status")
      before = File.binread(helper)
      # Dropping the executable bit leaves an installed command that cannot run.
      FileUtils.chmod(0o644, helper)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [helper], payload.dig("bin", "blocking")
      assert_equal before, File.binread(helper)
    end
  end

  def test_unexpected_entry_under_the_managed_doctor_tree_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      intruder = File.join(target, "bin/agent_doctor/intruder.rb")
      File.write(intruder, "foreign\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [intruder], payload.dig("bin", "blocking")
      assert_path_exists intruder
    end
  end

  def test_unexpected_doctor_subdirectory_blocks_once_without_listing_its_children
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      nested = File.join(target, "bin/agent_doctor/personal")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "notes.md"), "personal\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [nested], payload.dig("bin", "blocking")
    end
  end

  def test_doctor_ownership_markers_and_recorded_subdirectories_do_not_block
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, _fingerprints = managed_bin_fixture(tmp)
      nested = write_managed_bin_copy(target, source, "agent_doctor/nested/module.rb" => "nested\n")
      fingerprints = managed_bin_fixture_fingerprints(target, source).merge(nested)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      # Both markers are excluded from the managed inventory. The workflows
      # marker is additionally verified, so it carries its real attestation.
      File.write(File.join(doctor_root, ".agent-stack-managed"), "agent-stack-module-v1:agent_doctor\n")
      File.write(
        File.join(doctor_root, ".agent-workflows-managed"),
        "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n"
      )

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_equal "present", payload.dig("bin", "state")
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_unrecorded_doctor_tree_does_not_inventory_unexpected_entries
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      # Only top-level helpers recorded: this install never managed the tree.
      managed_bin_metadata(target, source, fingerprints.reject { |name, _| name.include?("/") })
      File.write(File.join(target, "bin/agent_doctor/intruder.rb"), "foreign\n")

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_mode_change_inside_the_executable_boundary_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      # 0644 -> 0600 keeps the file readable and crosses no execute-bit
      # boundary, but the installer's marker hashes the exact mode.
      module_path = File.join(target, "bin/agent_doctor/renderer.rb")
      FileUtils.chmod(0o600, module_path)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [module_path], payload.dig("bin", "blocking")
    end
  end

  def test_managed_doctor_root_mode_change_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor = File.join(target, "bin/agent_doctor")
      FileUtils.chmod(0o700, doctor)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [doctor], payload.dig("bin", "blocking")
    end
  end

  def test_bin_paths_and_missing_partition_recorded_entries_with_blocking_layered_over_both
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      tampered = File.join(target, "bin/agent_doctor/autonomous_merge_policy.rb")
      File.write(tampered, "policy library\n# tampered\n")
      deleted = File.join(target, "bin/agent_doctor/renderer.rb")
      FileUtils.rm_f(deleted)

      payload, status, output = check_managed_bin(target, source)
      bin = payload.fetch("bin")

      refute status.success?, output
      # paths and missing partition the recorded entries by existence...
      assert_equal fingerprints.keys.sort,
                   (bin.fetch("paths").map { |path| path.delete_prefix("#{File.join(target, 'bin')}/") } +
                    bin.fetch("missing")).sort
      assert_empty bin.fetch("paths").map { |path| path.delete_prefix("#{File.join(target, 'bin')}/") } &
                   bin.fetch("missing")
      # ...and blocking is layered over both, naming one of each here.
      assert_equal [tampered, deleted].sort, bin.fetch("blocking")
      assert_includes bin.fetch("paths"), tampered
      assert_includes bin.fetch("missing"), "agent_doctor/renderer.rb"
    end
  end

  def test_symlinked_doctor_ownership_marker_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      marker = File.join(target, "bin/agent_doctor/.agent-workflows-managed")
      File.symlink(File.join(source, "bin/agent-workflows-status"), marker)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [marker], payload.dig("bin", "blocking")
    end
  end

  def test_corrupt_doctor_ownership_marker_blocks_an_otherwise_clean_install
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      marker = File.join(target, "bin/agent_doctor/.agent-workflows-managed")
      File.write(marker, "agent-workflows-doctor-v1:#{'0' * 64}\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [marker], payload.dig("bin", "blocking")
    end
  end

  def test_symlinked_stack_ownership_marker_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      File.write(
        File.join(doctor_root, ".agent-workflows-managed"),
        "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n"
      )
      stack_marker = File.join(doctor_root, ".agent-stack-managed")
      File.symlink(File.join(source, "bin/agent-workflows-status"), stack_marker)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [stack_marker], payload.dig("bin", "blocking")
    end
  end

  def test_non_file_stack_ownership_marker_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      stack_marker = File.join(target, "bin/agent_doctor/.agent-stack-managed")
      FileUtils.mkdir_p(stack_marker)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [stack_marker], payload.dig("bin", "blocking")
    end
  end

  def test_stack_ownership_marker_line_is_the_fallback_when_the_workflows_marker_is_absent
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      stack_marker = File.join(target, "bin/agent_doctor/.agent-stack-managed")
      File.write(stack_marker, "not the stack module line\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [stack_marker], payload.dig("bin", "blocking")

      File.write(stack_marker, "agent-stack-module-v1:agent_doctor\n")
      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_doctor_module_matching_the_current_source_needs_an_attesting_marker
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      module_path = File.join(doctor_root, "autonomous_merge_policy.rb")
      moved = "policy library v2\n"
      File.write(File.join(source, "bin/agent_doctor/autonomous_merge_policy.rb"), moved)
      File.write(module_path, moved)
      # A marker attesting the older contents, as a hand-copied module leaves.
      File.write(File.join(doctor_root, ".agent-workflows-managed"), "agent-workflows-doctor-v1:#{'0' * 64}\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_includes payload.dig("bin", "blocking"), module_path

      # Re-attesting the tree, as the installer does after rsync, adopts it.
      File.write(
        File.join(doctor_root, ".agent-workflows-managed"),
        "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n"
      )
      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_absent_doctor_markers_block_when_the_source_has_advanced
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      # No attestation, and the installed tree is the recorded revision rather
      # than the current source, so nothing left can adopt it.
      File.write(File.join(source, "bin/agent_doctor/renderer.rb"), "renderer v2\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [doctor_root], payload.dig("bin", "blocking")
    end
  end

  def test_absent_doctor_markers_stay_compatible_when_the_tree_matches_the_source
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_emptied_doctor_root_with_a_changed_mode_stays_restorable
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      # The installer accepts an empty destination and restores contents and
      # mode, so the recorded root mode must not block that path.
      FileUtils.rm_rf(doctor_root)
      FileUtils.mkdir_p(doctor_root)
      FileUtils.chmod(0o700, doctor_root)

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_unreadable_doctor_root_is_ignored_when_the_tree_is_unmanaged
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      # Metadata that records only top-level helpers: this install never managed
      # the doctor tree, so nothing about it should be judged.
      helpers_only = fingerprints.reject { |name, _| name.include?("/") || name == "agent_doctor" }
      managed_bin_metadata(target, source, helpers_only)
      doctor_root = File.join(target, "bin/agent_doctor")
      skip "unreadable-directory probe requires an unprivileged user" if Process.euid.zero?

      FileUtils.chmod(0o000, doctor_root)

      begin
        payload, status, output = check_managed_bin(target, source)

        assert status.success?, output
        assert_empty payload.dig("bin", "blocking")
      ensure
        FileUtils.chmod(0o755, doctor_root)
      end
    end
  end

  def test_guidance_names_both_remedies_when_both_apply
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      helper = File.join(target, "bin/agent-workflows-status")
      File.write(helper, "status helper\n# tampered\n")
      FileUtils.rm_f(File.join(target, "bin/agent_doctor/renderer.rb"))

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      guidance = payload.fetch("guidance")
      assert_includes guidance, "Restore them to their recorded pack revision"
      assert_includes guidance, File.join(target, "bin/agent_doctor")
    end
  end

  def test_stack_owned_tree_restores_a_missing_doctor_module
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      # No workflows marker, a valid stack marker: the installer accepts this
      # tree on the marker line alone and rsync restores the missing module.
      File.write(File.join(doctor_root, ".agent-stack-managed"), "agent-stack-module-v1:agent_doctor\n")
      FileUtils.rm_f(File.join(doctor_root, "renderer.rb"))

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
      assert_includes payload.dig("bin", "missing"), "agent_doctor/renderer.rb"
    end
  end

  def test_missing_module_still_blocks_a_workflows_attested_tree
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      deleted = File.join(doctor_root, "renderer.rb")
      FileUtils.rm_f(deleted)
      # A stack marker that does not carry the module line earns nothing.
      File.write(File.join(doctor_root, ".agent-stack-managed"), "not the stack module line\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_includes payload.dig("bin", "blocking"), deleted
    end
  end

  def test_valid_doctor_ownership_marker_stays_compatible
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      File.write(
        File.join(doctor_root, ".agent-workflows-managed"),
        "#{AgentDoctor::InstallOwnership.marker(doctor_root)}\n"
      )

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_marker_conflict_never_masks_a_named_conflict
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      intruder = File.join(target, "bin/agent_doctor/intruder.rb")
      File.write(intruder, "foreign\n")
      File.write(File.join(target, "bin/agent_doctor/.agent-workflows-managed"), "stale\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      # The intruder is what a reader must act on; the stale marker follows from
      # it and must not add a second path to chase.
      assert_equal [intruder], payload.dig("bin", "blocking")
    end
  end

  def test_unreadable_doctor_root_blocks_without_raising
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor_root = File.join(target, "bin/agent_doctor")
      # A 0000 directory stays readable to UID 0, so the probe cannot make the
      # tree unreadable there and the check reaches a different branch.
      skip "unreadable-directory probe requires an unprivileged user" if Process.euid.zero?

      FileUtils.chmod(0o000, doctor_root)

      begin
        payload, status, output = check_managed_bin(target, source)

        refute status.success?, output
        assert_equal [doctor_root], payload.dig("bin", "blocking")
        assert_includes payload.fetch("reason"), "cannot be read"
        refute_includes output, "Errno::EACCES"
      ensure
        FileUtils.chmod(0o755, doctor_root)
      end
    end
  end

  def test_symlinked_managed_bin_copy_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      replaced = File.join(target, "bin/agent-workflows-status")
      FileUtils.rm_f(replaced)
      File.symlink(File.join(source, "bin/agent-workflows-status"), replaced)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [replaced], payload.dig("bin", "blocking")
      assert_equal File.join(source, "bin/agent-workflows-status"), File.readlink(replaced)
    end
  end

  def test_unreadable_managed_bin_root_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      bin_root = File.join(target, "bin")
      skip "unreadable-directory probe requires an unprivileged user" if Process.euid.zero?

      # Without search permission every predicate below this directory answers
      # false, which would otherwise read as an install with nothing present.
      FileUtils.chmod(0o600, bin_root)

      begin
        payload, status, output = check_managed_bin(target, source)

        refute status.success?, output
        assert_equal "ambiguous", payload.dig("bin", "state")
        assert_equal [bin_root], payload.dig("bin", "blocking")
        assert_includes payload.fetch("reason"), "not readable"
      ensure
        FileUtils.chmod(0o755, bin_root)
      end
    end
  end

  def test_plain_file_managed_bin_root_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      bin_root = File.join(target, "bin")
      FileUtils.rm_rf(bin_root)
      File.write(bin_root, "foreign content\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [bin_root], payload.dig("bin", "blocking")
      assert_equal "foreign content\n", File.read(bin_root)
    end
  end

  def test_plain_file_managed_bin_subdirectory_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor = File.join(target, "bin/agent_doctor")
      FileUtils.rm_rf(doctor)
      File.write(doctor, "foreign content\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [doctor], payload.dig("bin", "blocking")
      assert_empty payload.dig("bin", "missing")
    end
  end

  def test_symlinked_managed_bin_root_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      bin_root = File.join(target, "bin")
      relocated = File.join(target, "relocated-bin")
      # Every recorded byte still matches through the link, so only the root
      # classification can catch it.
      File.rename(bin_root, relocated)
      File.symlink(relocated, bin_root)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal "ambiguous", payload.dig("bin", "state")
      assert_equal [bin_root], payload.dig("bin", "blocking")
      assert_includes payload.dig("bin", "reason"), "symlink"
      assert_includes payload.fetch("reason"), bin_root
      assert_equal relocated, File.readlink(bin_root)
    end
  end

  def test_symlinked_managed_bin_directory_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      doctor = File.join(target, "bin/agent_doctor")
      FileUtils.rm_rf(doctor)
      File.symlink(File.join(source, "bin/agent_doctor"), doctor)

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [doctor], payload.dig("bin", "blocking")
    end
  end

  def test_non_file_managed_bin_path_blocks_the_delivery_check
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints)
      collision = File.join(target, "bin/agent-workflows-status")
      FileUtils.rm_f(collision)
      FileUtils.mkdir_p(collision)
      File.write(File.join(collision, "sentinel"), "personal\n")

      payload, status, output = check_managed_bin(target, source)

      refute status.success?, output
      assert_equal [collision], payload.dig("bin", "blocking")
      assert_path_exists File.join(collision, "sentinel")
    end
  end

  def test_metadata_without_managed_bin_fingerprints_stays_compatible
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, _fingerprints = managed_bin_fixture(tmp)
      write_metadata(
        target,
        "host" => "codex", "mode" => "copy", "delivery_mode" => "flat",
        "source" => source, "source_revision" => "unknown"
      )
      File.write(File.join(target, "bin/agent_doctor/autonomous_merge_policy.rb"), "edited\n")

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_equal "unrecorded", payload.dig("bin", "state")
      assert_empty payload.dig("bin", "blocking")
    end
  end

  def test_symlink_mode_metadata_ignores_managed_bin_fingerprints
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      source, target, fingerprints = managed_bin_fixture(tmp)
      managed_bin_metadata(target, source, fingerprints, "mode" => "symlink")
      File.write(File.join(target, "bin/agent-workflows-status"), "edited\n")

      payload, status, output = check_managed_bin(target, source)

      assert status.success?, output
      assert_equal "unrecorded", payload.dig("bin", "state")
    end
  end

  def test_invalid_managed_bin_fingerprints_fail_closed
    Dir.mktmpdir("agent-workflows-delivery-state") do |tmp|
      [
        { "../escape" => "a" * 64 },
        { "agent_doctor/" => "a" * 64 },
        { "agent-workflows-status" => "not-a-digest" },
        { "agent-workflows-status" => 7 },
        { "/absolute" => "a" * 64 }
      ].each do |fingerprints|
        source, target, _recorded = managed_bin_fixture(tmp)
        managed_bin_metadata(target, source, fingerprints)

        payload, status, output = check_managed_bin(target, source)

        refute status.success?, "#{fingerprints.inspect}: #{output}"
        assert_equal "unknown", payload.dig("bin", "state"), output
        assert_includes payload.fetch("reason"), "managed bin copy fingerprints"
        FileUtils.rm_rf([source, target])
      end
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
