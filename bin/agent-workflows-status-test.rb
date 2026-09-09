#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for agent-workflows-status.
# Run with: ruby bin/agent-workflows-status-test.rb

require "fileutils"
require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-status", __dir__)
load SCRIPT

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

  def test_stable_status_reports_release_identity_and_rejects_a_moved_tag
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, ".claude-plugin"))
        FileUtils.mkdir_p(File.join(source, ".codex-plugin"))
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        FileUtils.mkdir_p(File.join(target, "skills/example"))
        FileUtils.mkdir_p(File.join(source, "workflows"))
        FileUtils.mkdir_p(File.join(target, "workflows"))
        workflow = File.join(target, "workflows/release.md")
        File.write(File.join(source, "workflows/release.md"), "stable workflow\n")
        File.write(workflow, "stable workflow\n")
        File.write(File.join(target, "workflows/personal.md"), "unrelated workflow\n")
        File.write(File.join(source, "VERSION"), "1.2.3\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "stable skill\n")
        File.write(File.join(target, "skills/example/SKILL.md"), "stable skill\n")
        File.write(File.join(source, ".claude-plugin/plugin.json"), "{\"version\":\"1.2.3\"}\n")
        File.write(File.join(source, ".codex-plugin/plugin.json"), "{\"version\":\"1.2.3\"}\n")
        FileUtils.mkdir_p(File.join(source, "bin"))
        [source, target].each do |root|
          FileUtils.mkdir_p(File.join(root, "docs"))
          File.write(File.join(root, "docs/café.md"), "unicode document name\n")
        end
        File.write(File.join(source, "bin/install-agent-workflows"), "echo incidental-inventory-warning >&2\nprintf '%s\\n' '#{JSON.generate(version: 1, bin_helpers: [], pack_docs: ['café.md'])}'\n")
        File.write(File.join(source, "THIRD_PARTY-NOTICES.md"), "release notices\n")
        FileUtils.cp(File.join(source, "THIRD_PARTY-NOTICES.md"), File.join(target, "THIRD_PARTY-NOTICES.md"))
        system("git", "-C", source, "init", "--quiet", exception: true)
        system("git", "-C", source, "config", "user.email", "status-test@example.com", exception: true)
        system("git", "-C", source, "config", "user.name", "Status Test", exception: true)
        system("git", "-C", source, "add", ".", exception: true)
        system("git", "-C", source, "commit", "--quiet", "-m", "stable release", exception: true)
        commit = `git -C #{Shellwords.escape(source)} rev-parse HEAD`.strip
        system("git", "-C", source, "tag", "-a", "v1.2.3", "-m", "stable release", exception: true)
        tag_object = `git -C #{Shellwords.escape(source)} rev-parse refs/tags/v1.2.3`.strip
        File.write(File.join(source, "workflows/release.md"), "development workflow\n")
        File.write(File.join(source, "VERSION"), "1.2.4\n")
        File.write(File.join(source, ".claude-plugin/plugin.json"), "{\"version\":\"1.2.4\"}\n")
        File.write(File.join(source, ".codex-plugin/plugin.json"), "{\"version\":\"1.2.4\"}\n")
        system("git", "-C", source, "add", ".", exception: true)
        system("git", "-C", source, "commit", "--quiet", "-m", "development after release", exception: true)
        write_metadata(
          target,
          "version" => "1.2.3",
          "source" => source,
          "source_revision" => commit,
          "delivery_mode" => "flat",
          "channel" => "stable",
          "release_ref" => "v1.2.3",
          "tag_object" => tag_object,
          "managed_bin_helper_copy_fingerprints" => {},
          "managed_pack_root_copy_fingerprints" => { "THIRD_PARTY-NOTICES.md" => Digest::SHA256.file(File.join(target, "THIRD_PARTY-NOTICES.md")).hexdigest },
          "managed_pack_doc_copy_fingerprints" => { "café.md" => Digest::SHA256.file(File.join(target, "docs/café.md")).hexdigest }
        )

        out, status = run_status(
          { "LANG" => "C", "LC_ALL" => "C" }, "--target", target, "--host", "claude", "--source", source,
          "--channel", "stable", "--release", "v1.2.3", "--json"
        )
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "UP_TO_DATE", payload.fetch("status")
        assert_equal "stable", payload.fetch("channel")
        assert_equal "v1.2.3", payload.fetch("release_ref")
        assert_equal commit, payload.fetch("exact_commit")
        assert_equal "1.2.3", payload.fetch("available_version")

        metadata_path = File.join(target, ".agent-workflows-install.json")
        original_metadata = File.binread(metadata_path)
        invalid_metadata = JSON.parse(original_metadata)
        invalid_metadata["release_ref"] = 123
        File.write(metadata_path, JSON.generate(invalid_metadata))
        invalid_out, invalid_status = run_status({}, "--target", target, "--host", "claude", "--source", source, "--json")
        assert_equal 3, invalid_status.exitstatus, invalid_out
        assert_equal "CHECK_FAILED", JSON.parse(invalid_out).fetch("status")
        File.write(metadata_path, original_metadata)

        out, status = run_status(
          { "QA_SUPERPOWERS_STATE" => "active", "QA_SUPERPOWERS_MARKETPLACE" => "superpowers-dev" },
          "--target", target, "--host", "codex", "--source", source,
          "--channel", "stable", "--release", "v1.2.3", "--json"
        )
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "stable", payload.fetch("channel")
        assert_equal commit, payload.fetch("exact_commit")
        assert_equal "active", payload.dig("superpowers", "state")

        identical_workflow = File.join(source, "identical-workflow.md")
        File.write(identical_workflow, "stable workflow\n")
        { "changed" => "fingerprint changed", "missing" => "is missing",
          "symlink" => "not a safely readable regular file" }.each do |mutation, expected_reason|
          FileUtils.rm_f(workflow)
          File.write(workflow, "changed workflow\n") if mutation == "changed"
          File.symlink(identical_workflow, workflow) if mutation == "symlink"
          out, status = run_status({}, "--target", target, "--host", "claude", "--source", source, "--json")
          assert_equal 3, status.exitstatus, "#{mutation}: #{out}"
          assert_includes JSON.parse(out).fetch("reason"), "release.md"
          assert_includes JSON.parse(out).fetch("reason"), expected_reason
          FileUtils.rm_f(workflow)
          File.write(workflow, "stable workflow\n")
        end

        installed_workflows = File.join(target, "workflows")
        saved_workflows = File.join(target, "saved-workflows")
        FileUtils.mv(installed_workflows, saved_workflows)
        %w[missing symlink].each do |mutation|
          File.symlink(saved_workflows, installed_workflows) if mutation == "symlink"
          out, status = run_status({}, "--target", target, "--host", "claude", "--source", source, "--json")
          assert_equal 3, status.exitstatus, "#{mutation} directory: #{out}"
          assert_includes JSON.parse(out).fetch("reason"), "installed workflow directory"
        end
        FileUtils.rm_f(installed_workflows)
        FileUtils.mv(saved_workflows, installed_workflows)

        system("git", "-C", source, "tag", "-d", "v1.2.3", out: File::NULL, exception: true)
        system("git", "-C", source, "tag", "-a", "v1.2.3", "-m", "moved release", exception: true)
        out, status = run_status({}, "--target", target, "--host", "claude", "--source", source, "--json")

        assert_equal 3, status.exitstatus, out
        assert_includes JSON.parse(out).fetch("reason"), "tag moved"
      end
    end
  end

  def test_stable_status_fails_closed_when_recorded_managed_files_are_missing_changed_or_not_executable
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, ".claude-plugin"))
        FileUtils.mkdir_p(File.join(source, ".codex-plugin"))
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        FileUtils.mkdir_p(File.join(source, "bin"))
        FileUtils.mkdir_p(File.join(source, "docs"))
        FileUtils.mkdir_p(File.join(target, "skills/example"))
        FileUtils.mkdir_p(File.join(target, "bin"))
        FileUtils.mkdir_p(File.join(target, "docs"))
        File.write(File.join(source, "VERSION"), "1.2.3\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "stable skill\n")
        File.write(File.join(target, "skills/example/SKILL.md"), "stable skill\n")
        File.write(File.join(source, ".claude-plugin/plugin.json"), "{\"version\":\"1.2.3\"}\n")
        File.write(File.join(source, ".codex-plugin/plugin.json"), "{\"version\":\"1.2.3\"}\n")
        helper = File.join(target, "bin/release-helper")
        doc = File.join(target, "docs/release-doc.md")
        root_file = File.join(target, "THIRD_PARTY-NOTICES.md")
        File.write(File.join(source, "THIRD_PARTY-NOTICES.md"), "release notices\n")
        FileUtils.cp(File.join(source, "THIRD_PARTY-NOTICES.md"), root_file)
        File.write(File.join(source, "bin/release-helper"), "#!/usr/bin/env bash\nexit 0\n")
        FileUtils.chmod(0o755, File.join(source, "bin/release-helper"))
        FileUtils.cp(File.join(source, "bin/release-helper"), helper)
        FileUtils.chmod(0o755, helper)
        File.write(File.join(source, "docs/release-doc.md"), "stable doc\n")
        FileUtils.cp(File.join(source, "docs/release-doc.md"), doc)
        File.write(File.join(source, "bin/install-agent-workflows"), "printf '%s\\n' '#{JSON.generate(version: 1, bin_helpers: ['release-helper'], pack_docs: ['release-doc.md'])}'\n")
        system("git", "-C", source, "init", "--quiet", exception: true)
        system("git", "-C", source, "config", "user.email", "status-test@example.com", exception: true)
        system("git", "-C", source, "config", "user.name", "Status Test", exception: true)
        system("git", "-C", source, "add", ".", exception: true)
        system("git", "-C", source, "commit", "--quiet", "-m", "stable release", exception: true)
        commit = `git -C #{Shellwords.escape(source)} rev-parse HEAD`.strip
        system("git", "-C", source, "tag", "-a", "v1.2.3", "-m", "stable release", exception: true)
        tag_object = `git -C #{Shellwords.escape(source)} rev-parse refs/tags/v1.2.3`.strip
        write_metadata(
          target,
          "version" => "1.2.3",
          "source" => source,
          "source_revision" => commit,
          "delivery_mode" => "flat",
          "channel" => "stable",
          "release_ref" => "v1.2.3",
          "tag_object" => tag_object,
          "managed_bin_helper_copy_fingerprints" => {
            "release-helper" => Digest::SHA256.file(helper).hexdigest
          },
          "managed_pack_root_copy_fingerprints" => {
            "THIRD_PARTY-NOTICES.md" => Digest::SHA256.file(root_file).hexdigest
          },
          "managed_pack_doc_copy_fingerprints" => {
            "release-doc.md" => Digest::SHA256.file(doc).hexdigest
          }
        )

        FileUtils.rm_f(helper)
        missing_out, missing_status = run_status(
          {}, "--target", target, "--host", "claude", "--source", source,
          "--channel", "stable", "--release", "v1.2.3", "--json"
        )
        FileUtils.cp(File.join(source, "bin/release-helper"), helper)
        File.write(doc, "locally changed\n")
        changed_out, changed_status = run_status(
          {}, "--target", target, "--host", "claude", "--source", source,
          "--channel", "stable", "--release", "v1.2.3", "--json"
        )
        FileUtils.cp(File.join(source, "docs/release-doc.md"), doc)
        FileUtils.chmod(0o644, helper)
        mode_out, mode_status = run_status(
          {}, "--target", target, "--host", "claude", "--source", source,
          "--channel", "stable", "--release", "v1.2.3", "--json"
        )

        failures = []
        missing_payload = JSON.parse(missing_out)
        changed_payload = JSON.parse(changed_out)
        mode_payload = JSON.parse(mode_out)
        failures << "missing helper reported #{missing_payload.fetch('status')}" unless missing_status.exitstatus == 3
        failures << "missing helper reason was not useful" unless missing_payload["reason"].to_s.include?("release-helper")
        failures << "changed document reported #{changed_payload.fetch('status')}" unless changed_status.exitstatus == 3
        failures << "changed document reason was not useful" unless changed_payload["reason"].to_s.include?("release-doc.md")
        failures << "non-executable helper reported #{mode_payload.fetch('status')}" unless mode_status.exitstatus == 3
        unless mode_payload["reason"].to_s.include?("release-helper") && mode_payload["reason"].to_s.include?("executable mode")
          failures << "non-executable helper reason was not useful"
        end
        assert_empty failures, failures.join("\n")
        FileUtils.chmod(0o755, helper)
        %w[changed missing].each do |mutation|
          FileUtils.rm_f(root_file)
          File.write(root_file, "changed notices\n") if mutation == "changed"
          out, status = run_status({}, "--target", target, "--host", "claude", "--source", source, "--json")
          assert_equal 3, status.exitstatus, "#{mutation}: #{out}"
          assert_includes JSON.parse(out).fetch("reason"), "THIRD_PARTY-NOTICES.md"
        end
      end
    end
  end

  def test_stable_managed_surface_rejects_symlinked_parent_directory
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("external-managed-docs") do |external|
        FileUtils.mkdir_p(File.join(target, "docs"))
        File.write(File.join(external, "example.md"), "unchanged content")
        File.symlink(external, File.join(target, "docs/solutions"))
        metadata = {
          "managed_bin_helper_copy_fingerprints" => {},
          "managed_pack_root_copy_fingerprints" => {},
          "managed_pack_doc_copy_fingerprints" => {
            "solutions/example.md" => Digest::SHA256.file(File.join(external, "example.md")).hexdigest
          }
        }
        error = AgentWorkflowsStatus.stable_managed_surface_error(target, metadata)
        assert_includes error.to_s, "ancestor"
      end
    end
  end

  def test_stable_managed_surface_detects_same_inode_mutation_after_hash_read
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      FileUtils.mkdir_p(File.join(target, "bin"))
      helper = File.join(target, "bin/release-helper")
      File.binwrite(helper, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, helper)
      metadata = {
        "managed_bin_helper_copy_fingerprints" => {
          "release-helper" => Digest::SHA256.file(helper).hexdigest
        },
        "managed_pack_root_copy_fingerprints" => {},
        "managed_pack_doc_copy_fingerprints" => {}
      }
      mutated = false
      trace = TracePoint.new(:c_return) do |event|
        next unless !mutated && event.method_id == :read && event.self.is_a?(File) && event.self.path == helper

        before = File.stat(helper)
        File.open(helper, "r+b") { |file| file.write("X") }
        File.utime(before.atime, before.mtime + 1, helper)
        mutated = true
      end

      error = trace.enable do
        AgentWorkflowsStatus.stable_managed_surface_error(target, metadata)
      end

      assert mutated, "fixture did not mutate the helper after its bytes were read"
      assert_includes error.to_s, "release-helper"
      assert_includes error.to_s, "changed during check"
    ensure
      trace&.disable
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

  # A tool-manager shim, or a git advice line, writes to stderr while git itself
  # succeeds. This reproduces that condition deterministically: a `git` wrapper
  # on PATH warns and then execs the real git.
  def noisy_git_env(root)
    FileUtils.mkdir_p(root)
    real_git = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
                  .map { |dir| File.join(dir, "git") }
                  .find { |path| File.file?(path) && File.executable?(path) }
    refute_nil real_git, "no git executable on PATH"
    wrapper = File.join(root, "git")
    File.write(wrapper, <<~SH)
      #!/bin/sh
      echo 'mise WARN  no version is set for shim: git' >&2
      exec #{real_git} "$@"
    SH
    FileUtils.chmod(0o755, wrapper)
    { "PATH" => "#{root}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}" }
  end

  def create_git_source(source)
    FileUtils.mkdir_p(File.join(source, "skills/example"))
    File.write(File.join(source, "VERSION"), "9.9.9\n")
    File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
    system("git", "-C", source, "init", "--quiet", exception: true)
    system("git", "-C", source, "config", "user.email", "status-test@example.com", exception: true)
    system("git", "-C", source, "config", "user.name", "Status Test", exception: true)
    system("git", "-C", source, "add", ".", exception: true)
    system("git", "-C", source, "commit", "--quiet", "-m", "fixture", exception: true)
    revision, revision_status = Open3.capture2("git", "-C", source, "rev-parse", "HEAD")
    assert revision_status.success?, revision
    revision.strip
  end

  def test_available_revision_ignores_incidental_git_stderr
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        Dir.mktmpdir("agent-workflows-status-bin") do |bin|
          revision = create_git_source(source)
          FileUtils.mkdir_p(File.join(target, "skills/example"))
          File.write(File.join(target, "skills/example/SKILL.md"), "example\n")
          write_metadata(
            target,
            "version" => "9.9.9",
            "source" => source,
            "source_revision" => revision,
            "delivery_mode" => "flat"
          )

          out, status = run_status(noisy_git_env(bin), "--target", target, "--host", "codex", "--json")
          payload = JSON.parse(out)

          assert_equal 0, status.exitstatus, out
          assert_equal "UP_TO_DATE", payload.fetch("status")
          assert_equal revision, payload.fetch("available_revision")
          assert_equal "present", payload.dig("flat", "state")
        end
      end
    end
  end

  def test_failed_git_read_reports_git_diagnostics
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
        # Looks like a clone to the source probe, but git cannot read it.
        FileUtils.mkdir_p(File.join(source, ".git"))
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "abc123",
          "delivery_mode" => "flat"
        )

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "git rev-parse HEAD failed"
        assert_includes payload.fetch("reason"), "not a git repository"
      end
    end
  end
end
