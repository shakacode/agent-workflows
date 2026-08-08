#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)

class UpgradeAgentWorkflowsTest < Minitest::Test
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

  private

  def with_release_repository
    Dir.mktmpdir("upgrade-agent-workflows-test") do |tmp|
      source = File.join(tmp, "source")
      target = File.join(tmp, "codex-home")
      FileUtils.mkdir_p(source)
      system("rsync", "-a", "--exclude", ".git", "#{ROOT}/", "#{source}/", exception: true)
      git(source, "init", "--quiet")
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
      git(source, "add", ".")
      git(source, "commit", "--quiet", "-m", "release two")
      commit_two = git(source, "rev-parse", "HEAD")
      git(source, "tag", "-a", "v0.1.1", "-m", "Agent Workflows v0.1.1")

      yield source, target, { "v0.1.0" => commit_one, "v0.1.1" => commit_two }
    end
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

  def assert_install_metadata(target, release_ref:, revision:)
    metadata = JSON.parse(File.read(File.join(target, ".agent-workflows-install.json")))
    assert_equal "stable", metadata.fetch("channel")
    assert_equal release_ref, metadata.fetch("release_ref")
    assert_equal revision, metadata.fetch("source_revision")
  end

  def run_command(*command)
    Open3.capture2e({ "AGENT_WORKFLOWS_CHANNEL" => nil }, *command)
  end

  def git(root, *args)
    output, status = Open3.capture2e("git", "-C", root, *args)
    raise output unless status.success?

    output.strip
  end
end
