# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "signed_launch_installation"

class SignedLaunchInstallationTest < Minitest::Test
  RELATIVE_HELPER = "skills/example/bin/helper"

  def test_platform_symlink_ancestor_is_canonicalized
    root = Dir.mktmpdir("signed-launch-installation", "/tmp")
    File.chmod(0o700, root)
    helper = write_helper(root)
    write_metadata(root)

    installation = AgentDoctor::SignedLaunchInstallation.resolve(
      helper_path: helper, relative_helper_path: RELATIVE_HELPER
    )

    assert_equal File.realpath(root), installation.fetch("root")
    assert_equal "codex", installation.fetch("host")
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  def test_direct_helper_without_validated_install_metadata_fails_closed
    root = Dir.mktmpdir("signed-launch-installation")
    File.chmod(0o700, root)
    helper = write_helper(root)

    installation = AgentDoctor::SignedLaunchInstallation.resolve(
      helper_path: helper, relative_helper_path: RELATIVE_HELPER
    )

    assert_nil installation
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  def test_non_platform_symlink_ancestor_fails_closed
    container = Dir.mktmpdir("signed-launch-installation")
    File.chmod(0o700, container)
    physical_root = File.join(container, "physical")
    lexical_root = File.join(container, "caller-selected")
    FileUtils.mkdir_p(physical_root)
    File.chmod(0o700, physical_root)
    helper = write_helper(physical_root)
    write_metadata(physical_root)
    File.symlink(physical_root, lexical_root)
    lexical_helper = helper.sub(physical_root, lexical_root)

    installation = AgentDoctor::SignedLaunchInstallation.resolve(
      helper_path: lexical_helper, relative_helper_path: RELATIVE_HELPER
    )

    assert_nil installation
  ensure
    FileUtils.remove_entry(container) if container && File.exist?(container)
  end

  private

  def write_helper(root)
    helper = File.join(root, RELATIVE_HELPER)
    FileUtils.mkdir_p(File.dirname(helper))
    File.write(helper, "#!/usr/bin/env ruby\n")
    helper
  end

  def write_metadata(root)
    metadata = {
      "delivery_mode" => "flat", "host" => "codex", "installed_at" => "2026-08-04T00:00:00Z",
      "mode" => "copy", "source" => File.realpath(root), "source_branch" => "main",
      "source_remote" => "https://github.com/shakacode/agent-workflows.git",
      "source_revision" => "a" * 40, "version" => "0.1.0"
    }
    path = File.join(root, ".agent-workflows-install.json")
    File.write(path, JSON.generate(metadata))
    File.chmod(0o600, path)
  end
end
