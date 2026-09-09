#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)

class UpgradeAgentWorkflowsTest < Minitest::Test
  def test_stack_install_refuses_to_change_a_resolved_stable_target_to_development
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0")
      metadata_path = File.join(target, ".agent-workflows-install.json")
      prior_metadata = File.binread(metadata_path)
      stack_root = File.join(File.dirname(source), "stack")
      FileUtils.mkdir_p(stack_root)
      File.symlink(source, File.join(stack_root, "agent-workflows"))
      %w[explicit default auto].each do |selection|
        output, status = run_command(
          "env", "CODEX_HOME=#{target}",
          "bash", "-c",
          'source "$1"; source_root="$2"; mode=copy; delivery_mode=flat; ' \
          'host=codex; target="$3"; [[ "$4" != auto ]] || host=auto; [[ "$4" != default ]] || target=""; ' \
          "agent_stack_install_workflows",
          "stack-test", File.join(source, "bin/agent_stack/installers.bash"), stack_root, target, selection
        )
        assert_equal 64, status.exitstatus, output
        assert_includes output, "STABLE_CHANNEL_PRESERVED"
        assert_equal prior_metadata, File.binread(metadata_path)
        assert_equal "release one\n", File.read(File.join(target, "docs/release-channel.md"))
      end
    end
  end

  def test_full_stack_sync_preserves_colocated_stable_doctor_before_any_install
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0")
      metadata = File.join(target, ".agent-workflows-install.json")
      marker = File.join(target, "bin/agent_doctor/.agent-workflows-managed")
      prior_metadata = File.binread(metadata)
      prior_marker = File.binread(marker)
      added = "bin/agent_doctor/development-only.rb"
      File.write(File.join(source, added), "# development-only doctor code\n")
      git(source, "branch", "-M", "main")
      git(source, "add", added)
      git(source, "commit", "--quiet", "-m", "development doctor fixture")
      git(source, "remote", "add", "origin", source)
      base = File.dirname(source)
      stack = File.join(base, "stack")
      FileUtils.mkdir_p(stack)
      File.symlink(source, File.join(stack, "agent-workflows"))
      %w[agent-coordination agent-coordination-dashboard].each do |name|
        repo = File.join(stack, name)
        FileUtils.mkdir_p(File.join(repo, "bin"))
        File.write(File.join(repo, "README.md"), "# Local fixture\n")
        if name == "agent-coordination"
          bootstrap = File.join(repo, "bin/agent-coord")
          File.write(bootstrap, "#!/usr/bin/env bash\nprintf unexpected > \"$3/coord-bootstrap-ran\"\n")
          File.chmod(0o755, bootstrap)
        end
        git(repo, "init", "--quiet", "--initial-branch=main")
        git(repo, "config", "user.email", "test@example.invalid")
        git(repo, "config", "user.name", "Stack Test")
        git(repo, "add", ".")
        git(repo, "commit", "--quiet", "-m", "local fixture")
        git(repo, "remote", "add", "origin", repo)
      end
      output, status = run_command(
        "env", "AGENT_STACK_AGENT_WORKFLOWS_URL=#{source}",
        "AGENT_STACK_AGENT_COORDINATION_URL=#{stack}/agent-coordination",
        "AGENT_STACK_AGENT_COORDINATION_DASHBOARD_URL=#{stack}/agent-coordination-dashboard",
        File.join(source, "bin/agent-stack"), "sync", "--no-fetch", "--source-root", stack,
        "--compat-root", File.join(base, "compat"), "--runtime-root", File.join(base, "runtime"),
        "--host", "codex", "--target", target, "--mode", "copy",
        "--agent-coord-install-dir", File.join(target, "bin")
      )
      assert_equal 64, status.exitstatus, output
      assert_includes output, "STABLE_CHANNEL_PRESERVED"
      assert_equal prior_metadata, File.binread(metadata)
      assert_equal prior_marker, File.binread(marker)
      refute File.exist?(File.join(target, added))
      refute File.exist?(File.join(target, "bin/coord-bootstrap-ran"))
      refute File.exist?(File.join(target, "bin/agent-stack"))
    end
  end

  def test_development_source_override_cannot_mislabel_the_installed_checkout
    with_release_repository do |source, target, _commits|
      other_source = File.join(File.dirname(source), "other-source")
      FileUtils.mkdir_p(other_source)
      File.write(File.join(other_source, "VERSION"), "9.9.9\n")
      output, status = run_command(
        File.join(source, "bin/install-agent-workflows"), "--target", target,
        "--channel", "development", "--source", other_source
      )
      assert_equal 64, status.exitstatus, output
      assert_includes output, "Development --source must match"
      refute File.exist?(target), "rejected source override mutated the target"
    end
  end

  def test_symlink_conversion_refuses_omitted_managed_docs_and_helpers
    with_release_repository(add_release_two_assets: true) do |source, target, commits|
      output, status = run_command(
        File.join(source, "bin/install-agent-workflows"), "--target", target,
        "--channel", "development", "--mode", "symlink"
      )
      assert status.success?, output
      metadata_path = File.join(target, ".agent-workflows-install.json")
      prior_metadata = File.binread(metadata_path)
      unrelated = File.join(target, "docs/user-notes")
      File.symlink(File.join(File.dirname(target), "user-notes"), unrelated)
      %w[docs/release-two-only.md bin/agent-workflows-release-two-only].each do |relative|
        output, status = run_command(
          File.join(source, "bin/install-agent-workflows"), "--target", target,
          "--source", source, "--release", "v0.1.0"
        )
        assert_equal 65, status.exitstatus, output
        assert_includes output, "STABLE_INSTRUCTION_SURFACE_CONFLICT"
        assert_includes output, relative
        assert_equal prior_metadata, File.binread(metadata_path)
        assert File.symlink?(File.join(target, "docs/release-channel.md"))
        assert File.symlink?(File.join(target, relative))
        File.unlink(File.join(target, relative))
      end
      install_stable(source, target, "v0.1.0")
      assert File.symlink?(unrelated)
      assert_install_metadata(target, release_ref: "v0.1.0", revision: commits.fetch("v0.1.0"))
    end
  end

  def test_stable_install_verifies_recorded_attempt_after_a_later_failed_rerun
    with_release_repository do |source, target, commits|
      install_stable(source, target, "v0.1.0")

      assert_install_metadata(target, release_ref: "v0.1.0", revision: commits.fetch("v0.1.0"))
    end
  end

  def test_explicit_stable_reinstall_converts_development_symlinks_to_copies
    with_release_repository do |source, target, commits|
      output, status = run_command(
        File.join(source, "bin/install-agent-workflows"), "--target", target,
        "--channel", "development", "--mode", "symlink"
      )
      assert status.success?, output
      assert File.symlink?(File.join(target, "docs/release-channel.md"))
      user_skill = File.join(target, "skills/user-owned")
      File.symlink(File.join(File.dirname(target), "user-skill"), user_skill)

      install_stable(source, target, "v0.1.0")

      assert File.symlink?(user_skill), "unrelated user skill symlink was not preserved"
      refute File.symlink?(File.join(target, "docs/release-channel.md"))
      assert_equal "release one\n", File.read(File.join(target, "docs/release-channel.md"))
      assert_equal "release two\n", File.read(File.join(source, "docs/release-channel.md"))
      assert_install_metadata(target, release_ref: "v0.1.0", revision: commits.fetch("v0.1.0"))
    end
  end

  def test_symlink_conversion_refuses_committed_and_uncommitted_omitted_managed_skills
    with_release_repository(release_two_instruction_surface: "skills") do |source, target, _commits|
      uncommitted = File.join(source, "skills/uncommitted-only")
      FileUtils.mkdir_p(uncommitted)
      File.write(File.join(uncommitted, "SKILL.md"), "uncommitted instructions\n")
      output, status = run_command(
        File.join(source, "bin/install-agent-workflows"), "--target", target,
        "--channel", "development", "--mode", "symlink"
      )
      assert status.success?, output
      metadata_path = File.join(target, ".agent-workflows-install.json")
      prior_metadata = File.binread(metadata_path)

      %w[release-two-only uncommitted-only].each do |name|
        output, status = run_command(
          File.join(source, "bin/install-agent-workflows"), "--target", target,
          "--source", source, "--release", "v0.1.0"
        )

        assert_equal 65, status.exitstatus, output
        assert_includes output, "STABLE_INSTRUCTION_SURFACE_CONFLICT"
        assert_includes output, "skills/#{name}"
        assert_equal prior_metadata, File.binread(metadata_path)
        assert File.symlink?(File.join(target, "docs/release-channel.md"))
        assert_equal "release two\n", File.read(File.join(target, "docs/release-channel.md"))
        installed_skill = File.join(target, "skills", name)
        assert File.symlink?(installed_skill)
        File.unlink(installed_skill)
      end
    end
  end

  def test_rejected_obsolete_release_files_preserve_all_prior_content
    with_release_repository(add_release_two_assets: true) do |source, target, _commits|
      install_stable(source, target, "v0.1.1")
      metadata_path = File.join(target, ".agent-workflows-install.json")
      prior_metadata = File.binread(metadata_path)
      %w[docs/release-two-only.md bin/agent-workflows-release-two-only].each do |relative|
        obsolete = File.join(target, relative)
        original = File.binread(obsolete)
        File.write(obsolete, "user modification\n")

        output, status = run_command(
          File.join(source, "bin/install-agent-workflows"), "--target", target,
          "--source", source, "--release", "v0.1.0"
        )

        assert_equal 65, status.exitstatus, output
        assert_includes output, "MANAGED_SURFACE_RECONCILIATION_FAILED"
        assert_equal "release two\n", File.read(File.join(target, "docs/release-channel.md"))
        assert_equal prior_metadata, File.binread(metadata_path)
        assert_equal "user modification\n", File.read(obsolete)
        File.binwrite(obsolete, original)
      end
    end
  end

  def test_stable_reinstall_refuses_removed_instruction_roots_before_replacement
    %w[skills workflows].each do |surface|
      with_release_repository(release_two_instruction_surface: surface) do |source, target, _commits|
        install_stable(source, target, "v0.1.1")
        metadata_path = File.join(target, ".agent-workflows-install.json")
        prior_metadata = File.binread(metadata_path)
        newer_path = File.join(target, surface, "release-two-only")

        output, status = run_command(
          File.join(source, "bin/install-agent-workflows"), "--target", target,
          "--source", source, "--release", "v0.1.0"
        )

        assert_equal 65, status.exitstatus, output
        assert_includes output, "STABLE_INSTRUCTION_SURFACE_CONFLICT"
        assert_includes output, "#{surface}/release-two-only"
        assert_includes output, "separate clean target"
        assert_equal "release two\n", File.read(File.join(target, "docs/release-channel.md"))
        assert_equal prior_metadata, File.binread(metadata_path)
        assert_path_exists newer_path
      end
    end
  end

  def test_stable_root_file_fingerprint_uses_selected_release_content
    with_release_repository do |source, target, _commits|
      File.write(File.join(source, "THIRD_PARTY-NOTICES.md"), "mutable development notices\n")

      install_stable(source, target, "v0.1.0")

      installed_notices = File.join(target, "THIRD_PARTY-NOTICES.md")
      metadata = JSON.parse(File.read(File.join(target, ".agent-workflows-install.json")))
      assert_equal git(source, "show", "v0.1.0:THIRD_PARTY-NOTICES.md"), File.read(installed_notices).strip
      assert_equal Digest::SHA256.file(installed_notices).hexdigest,
                   metadata.fetch("managed_pack_root_copy_fingerprints").fetch("THIRD_PARTY-NOTICES.md")
    end
  end

  def test_stable_upgrade_and_rollback_each_select_an_explicit_immutable_release
    with_release_repository do |source, target, commits|
      %w[codex claude].each do |host|
        host_target = "#{target}-#{host}"
        install_stable(source, host_target, "v0.1.0", host:)

        output, status = run_command(
          File.join(host_target, "bin/upgrade-agent-workflows"),
          "--host", host, "--target", host_target, "--source", source,
          "--release", "v0.1.1", "--no-fetch"
        )
        assert status.success?, output
        assert_install_metadata(host_target, release_ref: "v0.1.1", revision: commits.fetch("v0.1.1"))
        assert_equal "release two\n", File.read(File.join(host_target, "docs", "release-channel.md"))

        output, status = run_command(
          File.join(host_target, "bin/upgrade-agent-workflows"),
          "--host", host, "--target", host_target, "--source", source,
          "--release", "v0.1.0", "--no-fetch"
        )
        assert status.success?, output
        assert_includes output, "ROLLBACK_COMPLETE"
        assert_install_metadata(host_target, release_ref: "v0.1.0", revision: commits.fetch("v0.1.0"))
        assert_equal "release one\n", File.read(File.join(host_target, "docs", "release-channel.md"))
      end
    end
  end

  def test_stable_upgrade_and_rollback_use_the_selected_release_asset_inventory
    with_release_repository(add_release_two_assets: true) do |source, target, _commits|
      install_stable_with_release_installer(source, target, "v0.1.0")

      upgrade_output, upgrade_status = run_command(
        File.join(target, "bin/upgrade-agent-workflows"),
        "--target", target, "--source", source,
        "--release", "v0.1.1", "--no-fetch"
      )
      release_two_doc = File.join(target, "docs/release-two-only.md")
      release_two_helper = File.join(target, "bin/agent-workflows-release-two-only")
      upgrade_installed_release_two_doc = File.file?(release_two_doc)
      upgrade_installed_release_two_helper = File.file?(release_two_helper)
      unrelated = File.join(target, "docs/user-owned.md")
      File.write(unrelated, "user owned\n")
      rollback_output, rollback_status = run_command(
        File.join(target, "bin/upgrade-agent-workflows"),
        "--target", target, "--source", source,
        "--release", "v0.1.0", "--no-fetch"
      )

      failures = []
      failures << "upgrade failed: #{upgrade_output}" unless upgrade_status.success?
      failures << "upgrade omitted the selected release's new pack document" unless upgrade_installed_release_two_doc
      failures << "upgrade omitted the selected release's new helper" unless upgrade_installed_release_two_helper
      failures << "rollback failed: #{rollback_output}" unless rollback_status.success?
      failures << "rollback did not report completion" unless rollback_output.include?("ROLLBACK_COMPLETE")
      failures << "rollback retained the newer release's managed pack document" if File.exist?(release_two_doc)
      failures << "rollback retained the newer release's managed helper" if File.exist?(release_two_helper)
      failures << "rollback removed an unrelated user-owned path" unless File.read(unrelated) == "user owned\n"

      assert_empty failures, failures.join("\n")
    end
  end

  def test_upgrade_refuses_to_cross_between_stable_and_development_channels
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0")

      output, status = run_command(
        File.join(target, "bin/upgrade-agent-workflows"),
        "--target", target, "--source", source, "--channel", "development", "--no-fetch"
      )

      assert_equal 3, status.exitstatus, output
      assert_includes output, "refusing channel change from stable to development"

      development_target = "#{target}-development"
      output, status = Open3.capture2e(
        File.join(source, "bin/install-agent-workflows"),
        "--target", development_target, "--channel", "development"
      )
      assert status.success?, output
      output, status = run_command(
        File.join(development_target, "bin/upgrade-agent-workflows"),
        "--target", development_target, "--source", source, "--release", "v0.1.1", "--no-fetch"
      )

      assert_equal 3, status.exitstatus, output
      assert_includes output, "refusing channel change from development to stable"
    end
  end

  def test_stable_upgrade_validates_consumers_with_installed_release_content
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0")
      sentinel = File.join(File.dirname(target), "mutable-scanner-executed")
      scanner = File.join(source, "skills/secure-github-actions/lib/secure_github_actions_scanner.rb")
      File.write(
        scanner,
        "File.write(#{sentinel.inspect}, \"executed\\n\")\nraise \"mutable source scanner executed\"\n"
      )

      output, status = run_command(
        File.join(target, "bin/upgrade-agent-workflows"),
        "--target", target,
        "--source", source,
        "--release", "v0.1.1",
        "--consumer-root", ROOT,
        "--no-fetch"
      )

      assert status.success?, output
      refute_path_exists sentinel, "stable seam validation executed the mutable source scanner"
    end
  end

  def test_stable_dry_run_checks_installed_content_before_comparing_another_release
    %w[skills workflows].each do |surface|
      with_release_repository(release_two_instruction_surface: surface) do |source, target, _commits|
        install_stable(source, target, "v0.1.0")
        metadata = File.binread(File.join(target, ".agent-workflows-install.json"))
        output, status = run_command(
          File.join(target, "bin/upgrade-agent-workflows"), "--target", target,
          "--source", source, "--release", "v0.1.1", "--no-fetch", "--dry-run"
        )
        assert status.success?, output
        assert_includes output, "UPGRADE_AVAILABLE"
        assert_equal metadata, File.binread(File.join(target, ".agent-workflows-install.json"))
      end
    end
  end

  def test_stable_dry_run_requires_published_release_provenance
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0")
      receipt_path = File.join(@release_receipt_dir, "v0.1.1.json")
      receipt = File.binread(receipt_path)
      File.unlink(receipt_path)
      output, status = run_command(
        File.join(target, "bin/upgrade-agent-workflows"), "--target", target,
        "--source", source, "--release", "v0.1.1", "--no-fetch", "--dry-run"
      )
      assert_equal 3, status.exitstatus, output
      assert_includes output, "CHECK_FAILED"
      data = JSON.parse(receipt)
      data.fetch("approval")["human_non_author"] = false
      File.write(receipt_path, JSON.generate(data))
      output, status = run_command(
        File.join(target, "bin/upgrade-agent-workflows"), "--target", target,
        "--source", source, "--release", "v0.1.1", "--no-fetch", "--dry-run"
      )
      assert_equal 3, status.exitstatus, output
      assert_includes output, "protected-environment approval"
    end
  end

  def test_stable_status_rejects_reduced_metadata_and_symlinked_ancestors
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0")
      metadata_path = File.join(target, ".agent-workflows-install.json")
      original = File.binread(metadata_path)
      %w[managed_bin_helper_copy_fingerprints managed_pack_doc_copy_fingerprints managed_pack_root_copy_fingerprints].each do |field|
        reduced = JSON.parse(original)
        reduced[field] = {}
        File.write(metadata_path, JSON.generate(reduced))
        output, status = run_command(File.join(target, "bin/agent-workflows-status"), "--target", target, "--source", source, "--json")
        assert_equal 3, status.exitstatus, "#{field}: #{output}"
        assert_includes output, "inventory does not match release: #{field}"
      end
      File.write(metadata_path, original)
      docs = File.join(target, "docs/solutions")
      saved = File.join(File.dirname(target), "external-solutions")
      FileUtils.mv(docs, saved)
      File.symlink(saved, docs)
      output, status = run_command(File.join(target, "bin/agent-workflows-status"), "--target", target, "--source", source, "--json")
      assert_equal 3, status.exitstatus, output
      assert_includes output, "ancestor"
    end
  end

  def test_stable_status_checks_installed_auxiliary_runtimes
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0", host: "claude")
      companion = "#{target}-companion"
      install_stable(source, companion, "v0.1.0", host: "claude")
      plugin = File.join(companion, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p([File.join(plugin, "skills/example"), File.join(plugin, ".claude-plugin")])
      File.write(File.join(plugin, "skills/example/SKILL.md"), "example\n")
      File.write(File.join(plugin, ".claude-plugin/plugin.json"), JSON.generate(name: "scw", version: "0.1.0", skills: "./skills/"))
      File.write(File.join(companion, "settings.json"), JSON.generate(enabledPlugins: { "scw@agent-workflows" => true }))
      File.write(File.join(companion, "plugins/installed_plugins.json"), JSON.generate(version: 2, plugins: {
                                                                                         "scw@agent-workflows" => [{ scope: "user", installPath: plugin, version: "0.1.0" }]
                                                                                       }))
      preview = ["--host", "claude", "--target", companion, "--source", source, "--delivery-mode", "plugin-companion"]
      output, status = run_command(File.join(companion, "bin/agent-workflows-status"), *preview, "--json")
      assert_equal 0, status.exitstatus, output
      output, status = run_command(File.join(companion, "bin/upgrade-agent-workflows"), *preview, "--dry-run", "--release", "v0.1.0", "--no-fetch")
      assert status.success?, output
      assert_equal "flat", JSON.parse(File.read(File.join(companion, ".agent-workflows-install.json"))).fetch("delivery_mode")
      output, status = run_command(File.join(source, "bin/install-agent-workflows"), "--host", "claude", "--target", companion,
                                   "--release", "v0.1.0", "--delivery-mode", "plugin-companion")
      assert status.success?, output

      [[target, "bin/agent_doctor/contract.rb"], [companion, "lib/agent-workflows/secure_github_actions_scanner.rb"]].each do |home, relative|
        command = [File.join(home, "bin/agent-workflows-status"), "--host", "claude", "--target", home, "--source", source, "--json"]
        output, status = run_command(*command)
        assert_equal 0, status.exitstatus, output
        path = File.join(home, relative)
        original = File.binread(path)
        %w[missing modified].each do |mutation|
          FileUtils.rm_f(path)
          File.write(path, "raise 'modified runtime'\n") if mutation == "modified"
          output, status = run_command(*command)
          assert_equal 3, status.exitstatus, "#{relative} #{mutation}: #{output}"
          assert_equal "CHECK_FAILED", JSON.parse(output).fetch("status")
          File.binwrite(path, original)
        end
      end

      command = [File.join(companion, "bin/agent-workflows-status"), "--host", "claude", "--target", companion,
                 "--source", source, "--delivery-mode", "flat", "--json"]
      output, status = run_command(*command)
      refute status.success?, output
      File.write(File.join(companion, "settings.json"), JSON.generate(enabledPlugins: { "scw@agent-workflows" => false }))
      output, status = run_command(*command)
      assert_equal 0, status.exitstatus, output
      scanner = File.join(companion, "lib/agent-workflows/secure_github_actions_scanner.rb")
      original = File.binread(scanner)
      %w[missing modified].each do |mutation|
        FileUtils.rm_f(scanner)
        File.write(scanner, "raise 'modified runtime'\n") if mutation == "modified"
        output, status = run_command(*command)
        assert_equal 3, status.exitstatus, output
        assert_includes JSON.parse(output).fetch("reason"), "scanner"
        File.binwrite(scanner, original)
      end
      File.write(File.join(companion, "settings.json"), JSON.generate(enabledPlugins: { "scw@agent-workflows" => true }))

      lib = File.join(companion, "lib")
      external = "#{companion}-lib"
      FileUtils.mv(lib, external)
      File.symlink(external, lib)
      output, status = run_command(File.join(companion, "bin/agent-workflows-status"), "--host", "claude", "--target", companion, "--source", source, "--json")
      assert_equal 3, status.exitstatus, output
      assert_includes output, "ancestor"
    end
  end

  def test_stable_status_binds_version_to_installed_release_when_checking_upgrades
    with_release_repository do |source, target, _commits|
      install_stable(source, target, "v0.1.0", host: "claude")
      metadata_path = File.join(target, ".agent-workflows-install.json")
      original = File.binread(metadata_path)
      command = [File.join(target, "bin/agent-workflows-status"), "--host", "claude", "--target", target, "--source", source, "--json"]
      [nil, false, "9.9.9"].each do |version|
        metadata = JSON.parse(original)
        version.nil? ? metadata.delete("version") : metadata["version"] = version
        File.write(metadata_path, JSON.generate(metadata))
        [[], ["--release", "v0.1.1"]].each do |selection|
          output, status = run_command(*command, *selection)
          assert_equal 3, status.exitstatus, output
          assert_includes JSON.parse(output).fetch("reason"), "version"
        end
      end
      File.binwrite(metadata_path, original)
      output, status = run_command(*command, "--release", "v0.1.1")
      assert_equal 1, status.exitstatus, output
      payload = JSON.parse(output)
      assert_equal "0.1.0", payload.fetch("installed_version")
      assert_equal "0.1.1", payload.fetch("available_version")
    end
  end

  private

  def with_release_repository(add_release_two_assets: false, release_two_instruction_surface: nil)
    Dir.mktmpdir("upgrade-agent-workflows-test") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex-home")
      FileUtils.mkdir_p(source)
      system("rsync", "-a", "--exclude", ".git", "#{ROOT}/", "#{source}/", exception: true)
      git(source, "init", "--quiet")
      # Background maintenance must not outlive this disposable repository.
      git(source, "config", "maintenance.auto", "false")
      git(source, "config", "user.email", "upgrade-test@example.com")
      git(source, "config", "user.name", "Upgrade Test")
      write_version(source, "0.1.0")
      File.write(File.join(source, "docs/release-channel.md"), "release one\n")
      git(source, "add", ".")
      git(source, "commit", "--quiet", "-m", "release one")
      commit_one = git(source, "rev-parse", "HEAD")
      git(source, "tag", "-a", "v0.1.0", "-m", "Agent Workflows v0.1.0")

      write_version(source, "0.1.1")
      File.write(File.join(source, "docs/release-channel.md"), "release two\n")
      add_release_two_only_assets(source) if add_release_two_assets
      if release_two_instruction_surface
        extra = File.join(source, release_two_instruction_surface, "release-two-only")
        if release_two_instruction_surface == "skills"
          FileUtils.mkdir_p(extra)
          extra = File.join(extra, "SKILL.md")
        end
        File.write(extra, "newer release instructions\n")
      end
      git(source, "add", ".")
      git(source, "commit", "--quiet", "-m", "release two")
      commit_two = git(source, "rev-parse", "HEAD")
      git(source, "tag", "-a", "v0.1.1", "-m", "Agent Workflows v0.1.1")

      @release_receipt_dir = File.join(tmp, "release-receipts")
      @fake_bin = File.join(tmp, "fake-bin")
      FileUtils.mkdir_p([@release_receipt_dir, @fake_bin])
      write_release_receipt(source, "v0.1.0")
      write_release_receipt(source, "v0.1.1")
      write_fake_curl

      yield source, target, { "v0.1.0" => commit_one, "v0.1.1" => commit_two }
    ensure
      @release_receipt_dir = nil
      @fake_bin = nil
    end
  end

  def add_release_two_only_assets(source)
    File.write(File.join(source, "docs/release-two-only.md"), "release two only\n")
    helper = File.join(source, "bin/agent-workflows-release-two-only")
    File.write(helper, "#!/usr/bin/env bash\nprintf 'release two helper\\n'\n")
    FileUtils.chmod(0o755, helper)

    installer = File.join(source, "bin/install-agent-workflows")
    content = File.read(installer)
    unless content.sub!(
      "bin_helpers=(\n",
      "bin_helpers=(\n  agent-workflows-release-two-only\n"
    )
      raise "missing helper inventory insertion point"
    end
    unless content.sub!(
      "pack_docs=(\n",
      "pack_docs=(\n  release-two-only.md\n"
    )
      raise "missing pack document inventory insertion point"
    end

    File.write(installer, content)
  end

  def write_release_receipt(source, release)
    commit = git(source, "rev-parse", "#{release}^{commit}")
    tag_object = git(source, "rev-parse", "refs/tags/#{release}")
    receipt = File.join(@release_receipt_dir, "#{release}.json")
    output, status = Open3.capture2e(
      File.join(source, "bin/agent-workflows-release"), "record-receipt",
      "--root", source,
      "--release", release,
      "--approved-commit", commit,
      "--expected-tag-object", tag_object,
      "--environment", "stable-release",
      "--change-author", "release-author",
      "--release-actor", "release-actor",
      "--approval-reviewer", "release-reviewer",
      "--repository", "shakacode/agent-workflows",
      "--workflow-run-id", "12345",
      "--workflow-run-attempt", "1",
      "--workflow-path", ".github/workflows/release.yml",
      "--workflow-run-url", "https://github.com/shakacode/agent-workflows/actions/runs/12345",
      "--recorded-at", "2026-08-25T00:00:00Z",
      "--receipt", receipt
    )
    raise output unless status.success?
  end

  def write_fake_curl
    path = File.join(@fake_bin, "curl")
    File.write(path, <<~'BASH')
      #!/usr/bin/env bash
      set -euo pipefail
      output=""
      url=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output) output="${2:?}"; shift 2 ;;
          --header) shift 2 ;;
          --*) shift ;;
          *) url="$1"; shift ;;
        esac
      done
      release="${QA_RELEASE_REF:?}"
      receipt="${QA_RELEASE_RECEIPT_DIR:?}/$release.json"
      case "$url" in
        "https://github.com/shakacode/agent-workflows/releases/download/$release/agent-workflows-release-receipt.json")
          install -m 0600 "$receipt" "$output"
          ;;
        "https://api.github.com/repos/shakacode/agent-workflows/releases/tags/$release")
          ruby -rjson -rdigest -e '
            receipt, output, release_ref = ARGV
            data = JSON.parse(File.read(receipt))
            workflow = data.fetch("workflow")
            repository = workflow.fetch("repository")
            payload = {
              "tag_name" => release_ref,
              "draft" => false,
              "prerelease" => false,
              "html_url" => "https://github.com/#{repository}/releases/tag/#{release_ref}",
              "author" => {"login" => "github-actions[bot]", "type" => "Bot"},
              "assets" => [{
                "name" => "agent-workflows-release-receipt.json",
                "state" => "uploaded",
                "size" => File.size(receipt),
                "digest" => "sha256:#{Digest::SHA256.file(receipt).hexdigest}",
                "browser_download_url" => "https://github.com/#{repository}/releases/download/#{release_ref}/agent-workflows-release-receipt.json",
                "uploader" => {"login" => "github-actions[bot]", "type" => "Bot"}
              }]
            }
            File.write(output, JSON.generate(payload))
          ' "$receipt" "$output" "$release"
          ;;
        "https://api.github.com/repos/shakacode/agent-workflows/actions/runs/12345"|\
        "https://api.github.com/repos/shakacode/agent-workflows/actions/runs/12345/attempts/1")
          ruby -rjson -e '
            receipt, output, url = ARGV
            data = JSON.parse(File.read(receipt))
            workflow = data.fetch("workflow")
            payload = {
              "id" => workflow.fetch("run_id"),
              "run_attempt" => workflow.fetch("run_attempt"),
              "path" => workflow.fetch("path"),
              "event" => "workflow_dispatch",
              "status" => "completed",
              "conclusion" => "success",
              "html_url" => workflow.fetch("run_url"),
              "head_branch" => data.fetch("release_ref"),
              "head_sha" => data.fetch("peeled_commit"),
              "actor" => {"login" => workflow.fetch("actor"), "type" => "User"},
              "repository" => {"full_name" => workflow.fetch("repository"), "private" => false}
            }
            unless url.end_with?("/attempts/1")
              payload["run_attempt"] = 2
              payload["conclusion"] = "failure"
            end
            File.write(output, JSON.generate(payload))
          ' "$receipt" "$output" "$url"
          ;;
        "https://api.github.com/repos/shakacode/agent-workflows/actions/runs/12345/approvals")
          ruby -rjson -e '
            receipt, output = ARGV
            reviewer = JSON.parse(File.read(receipt)).dig("approval", "reviewer")
            File.write(output, JSON.generate([{
              "state" => "approved",
              "environments" => [{"name" => "stable-release"}],
              "user" => {"login" => reviewer, "type" => "User"}
            }]))
          ' "$receipt" "$output"
          ;;
        *)
          echo "unexpected curl URL: $url" >&2
          exit 1
          ;;
      esac
    BASH
    FileUtils.chmod(0o755, path)
  end

  def write_version(source, version)
    File.write(File.join(source, "VERSION"), "#{version}\n")
    %w[.claude-plugin/plugin.json .codex-plugin/plugin.json].each do |relative|
      path = File.join(source, relative)
      manifest = JSON.parse(File.read(path))
      manifest["version"] = version
      File.write(path, "#{JSON.pretty_generate(manifest)}\n")
    end
  end

  def install_stable(source, target, release, host: "codex")
    output, status = run_command(
      File.join(source, "bin/install-agent-workflows"),
      "--host", host, "--target", target, "--release", release
    )
    assert status.success?, output
  end

  def install_stable_with_release_installer(source, target, release, host: "codex")
    Dir.mktmpdir("materialized-release-installer") do |materialized|
      archive = File.join(materialized, "release.tar")
      system("git", "-C", source, "archive", "--output", archive, release, exception: true)
      system("tar", "-xf", archive, "-C", materialized, exception: true)
      FileUtils.rm_f(archive)
      output, status = run_command(
        File.join(materialized, "bin/install-agent-workflows"),
        "--host", host, "--target", target, "--source", source, "--release", release
      )
      assert status.success?, output
    end
  end

  def assert_install_metadata(target, release_ref:, revision:)
    metadata = JSON.parse(File.read(File.join(target, ".agent-workflows-install.json")))
    assert_equal "stable", metadata.fetch("channel")
    assert_equal release_ref, metadata.fetch("release_ref")
    assert_equal revision, metadata.fetch("source_revision")
  end

  def run_command(*command)
    env = { "AGENT_WORKFLOWS_CHANNEL" => nil }
    if @fake_bin
      env["PATH"] = "#{@fake_bin}:#{ENV.fetch('PATH')}"
      env["QA_RELEASE_RECEIPT_DIR"] = @release_receipt_dir
      release_index = command.index("--release")
      env["QA_RELEASE_REF"] = command.fetch(release_index + 1) if release_index
    end
    Open3.capture2e(env, *command)
  end

  def git(root, *args)
    output, status = Open3.capture2e("git", "-C", root, *args)
    raise output unless status.success?

    output.strip
  end
end
