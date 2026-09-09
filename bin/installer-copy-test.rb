#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class InstallerCopyTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("installer-copy-")
    @source = File.join(@tmp, "source with spaces")
    @target = File.join(@tmp, "target with spaces")
    FileUtils.mkdir_p([@source, @target])
    installer = File.read(File.join(__dir__, "install-agent-workflows"))
    # Exercise the real copy operation without unrelated metadata/host setup.
    @functions = %w[ensure_real_directory copy_children_preserving_unrelated].map do |name|
      installer.match(/^#{name}\(\) \{\n.*?^\}/m).to_s
    end.join("\n")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def copy(env = {})
    Open3.capture3({ "BASH_ENV" => nil }.merge(env), "bash", "-euc", "#{@functions}\ncopy_children_preserving_unrelated \"$1\" \"$2\"",
                   "installer-copy-test", @source, @target)
  end

  def write(root, path, content)
    destination = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, content)
    destination
  end

  def test_replaces_managed_children_and_preserves_unrelated_entries
    write(@source, "skill one/SKILL.md", "new skill")
    executable = write(@source, "skill one/bin/helper", "helper")
    File.chmod(0o755, executable)
    write(@source, "workflow.md", "workflow")
    write(@source, ".unpackaged", "hidden source")
    write(@target, "skill one/obsolete", "stale")
    write(@target, "workflow.md", "old workflow")
    write(@target, "personal/SKILL.md", "personal")
    write(@target, ".unpackaged", "hidden target")

    _stdout, stderr, status = copy

    assert status.success?, stderr
    assert_equal "new skill", File.read(File.join(@target, "skill one/SKILL.md"))
    assert_equal 0o755, File.stat(File.join(@target, "skill one/bin/helper")).mode & 0o777
    refute_path_exists File.join(@target, "skill one/obsolete")
    assert_equal "workflow", File.read(File.join(@target, "workflow.md"))
    assert_equal "personal", File.read(File.join(@target, "personal/SKILL.md"))
    assert_equal "hidden target", File.read(File.join(@target, ".unpackaged"))
  end

  def test_replaces_destination_symlinks_without_following_them
    outside = File.join(@tmp, "outside")
    write(outside, "keep", "outside")
    write(@source, "skill/SKILL.md", "managed")
    File.symlink(outside, File.join(@target, "skill"))

    _stdout, stderr, status = copy

    assert status.success?, stderr
    refute File.symlink?(File.join(@target, "skill"))
    assert_equal "managed", File.read(File.join(@target, "skill/SKILL.md"))
    assert_equal ["keep"], Dir.children(outside)
  end

  def test_preserves_source_symlinks_and_ignores_dangling_source_links
    write(@source, "skill/SKILL.md", "managed")
    File.symlink("skill", File.join(@source, "alias"))
    File.symlink("missing", File.join(@source, "dangling"))
    write(@target, "dangling", "unrelated")

    _stdout, stderr, status = copy

    assert status.success?, stderr
    assert_equal "skill", File.readlink(File.join(@target, "alias"))
    assert_equal "unrelated", File.read(File.join(@target, "dangling"))
  end

  def test_empty_source_succeeds_without_invoking_rsync
    fake_bin = File.join(@tmp, "bin")
    script = write(fake_bin, "rsync", "#!/usr/bin/env bash\nexit 23\n")
    File.chmod(0o755, script)
    write(@target, "personal", "keep")

    _stdout, stderr, status = copy("PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}")

    assert status.success?, stderr
    assert_equal ["personal"], Dir.children(@target)
  end

  def test_copy_failure_remains_a_failure
    fake_bin = File.join(@tmp, "bin")
    script = write(fake_bin, "rsync", "#!/usr/bin/env bash\nexit 23\n")
    File.chmod(0o755, script)
    write(@source, "workflow.md", "workflow")

    _stdout, _stderr, status = copy("PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}")

    assert_equal 23, status.exitstatus
  end
end
