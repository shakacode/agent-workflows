#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflow-writing-style", __dir__)
DEFAULT_GUIDE = File.expand_path("../docs/writing-style.md", __dir__)

class AgentWorkflowWritingStyleTest < Minitest::Test
  def run_resolver(repo_root:, home:, script: SCRIPT)
    Open3.capture3(
      { "HOME" => home },
      RbConfig.ruby,
      script,
      "--repo-root",
      repo_root,
      "--format",
      "json"
    )
  end

  def test_invalid_utf8_packaged_default_fails_cleanly
    Dir.mktmpdir do |directory|
      script = File.join(directory, "bin", "agent-workflow-writing-style")
      default_guide = File.join(directory, "docs", "writing-style.md")
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.dirname(script))
      FileUtils.mkdir_p(File.dirname(default_guide))
      Dir.mkdir(repo_root)
      Dir.mkdir(home)
      FileUtils.cp(SCRIPT, script)
      File.binwrite(default_guide, "Valid\n\xFF".b)

      stdout, stderr, status = run_resolver(repo_root:, home:, script:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid packaged writing style"
      assert_includes stderr, "must contain valid UTF-8"
      refute_includes stderr, script
    end
  end

  def test_no_configuration_returns_the_packaged_default_with_provenance
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      Dir.mkdir(repo_root)
      Dir.mkdir(home)

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal File.read(DEFAULT_GUIDE, encoding: "UTF-8").strip, result.fetch("guide")
      assert_equal [], result.fetch("warnings")
      assert_empty stderr
    end
  end

  def test_nonexistent_repository_root_fails_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "missing-repo")
      home = File.join(directory, "home")
      Dir.mkdir(home)

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository root"
      assert_includes stderr, "expected an existing directory"
      refute_includes stderr, SCRIPT
    end
  end

  def test_repository_guide_wins_without_reading_malformed_user_config
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(repo_root, "docs"))
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.write(File.join(repo_root, "docs", "writing-style.md"), "Repository house style.\n")
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )
      File.write(File.join(home, ".agents", "agent-workflow.yml"), "writing_style: [broken\n")

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "repo", result.fetch("provenance")
      assert_equal "Repository house style.", result.fetch("guide")
      assert_equal [], result.fetch("warnings")
      assert_empty stderr
    end
  end

  def test_repository_guide_rejects_an_absolute_path
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      outside_path = File.join(directory, "outside.md")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      Dir.mkdir(home)
      File.write(outside_path, "Outside style must not load.\n")
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: #{outside_path}\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style"
      assert_includes stderr, "expected a nonblank relative Markdown-file path"
      refute_includes stderr, "Outside style must not load"
    end
  end

  def test_repository_guide_rejects_parent_traversal_even_when_the_target_exists
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      Dir.mkdir(home)
      File.write(File.join(directory, "outside.md"), "Outside style must not load.\n")
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: ../outside.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style path"
      assert_includes stderr, "must not contain '..' traversal"
      refute_includes stderr, "Outside style must not load"
    end
  end

  def test_repository_guide_rejects_a_null_byte_path_without_a_backtrace
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      Dir.mkdir(home)
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: \"docs/evil\\0.md\"\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style file"
      assert_includes stderr, "ArgumentError"
      refute_includes stderr, SCRIPT
    end
  end

  def test_repository_guide_rejects_a_symlink_escape
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      outside_path = File.join(directory, "outside.md")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(repo_root, "docs"))
      Dir.mkdir(home)
      File.write(outside_path, "Outside style must not load.\n")
      File.symlink(outside_path, File.join(repo_root, "docs", "writing-style.md"))
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style path"
      assert_includes stderr, "resolves outside its trusted root"
      refute_includes stderr, "Outside style must not load"
    end
  end

  def test_missing_repository_guide_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      Dir.mkdir(home)
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/missing.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style file"
      assert_includes stderr, "expected a readable regular Markdown file"
      refute_includes stderr, "agent-workflow-writing-style:"
    end
  end

  def test_empty_repository_guide_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(repo_root, "docs"))
      Dir.mkdir(home)
      File.write(File.join(repo_root, "docs", "writing-style.md"), " \n\t")
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style file"
      assert_includes stderr, "must not be empty"
    end
  end

  def test_invalid_utf8_repository_guide_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(repo_root, "docs"))
      Dir.mkdir(home)
      File.binwrite(File.join(repo_root, "docs", "writing-style.md"), "Valid\n\xFF".b)
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style file"
      assert_includes stderr, "must contain valid UTF-8"
      refute_includes stderr, "agent-workflow-writing-style:"
    end
  end

  def test_repository_guide_requires_a_markdown_file_path
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(repo_root, "docs"))
      Dir.mkdir(home)
      File.write(File.join(repo_root, "docs", "writing-style.txt"), "Plain text is not the contract.\n")
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.txt\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style path"
      assert_includes stderr, "must end in .md"
    end
  end

  def test_repository_guide_must_be_a_regular_file
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(repo_root, "docs", "writing-style.md"))
      Dir.mkdir(home)
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style file"
      assert_includes stderr, "expected a readable regular Markdown file"
    end
  end

  def test_unreadable_repository_guide_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      guide_path = File.join(repo_root, "docs", "writing-style.md")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.dirname(guide_path))
      Dir.mkdir(home)
      File.write(guide_path, "Unreadable repository style.\n")
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout = stderr = status = nil
      File.chmod(0o000, guide_path)
      begin
        if File.readable?(guide_path)
          skip "filesystem does not enforce owner read permissions"
        end
        stdout, stderr, status = run_resolver(repo_root:, home:)
      ensure
        File.chmod(0o600, guide_path)
      end

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style file"
      assert_includes stderr, "expected a readable regular Markdown file"
      refute_includes stderr, "Unreadable repository style"
    end
  end

  def test_repository_guide_allows_a_symlink_that_stays_beneath_the_repository_root
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(repo_root, "docs"))
      Dir.mkdir(home)
      File.write(File.join(repo_root, "docs", "shared.md"), "Trusted shared style.\n")
      File.symlink("shared.md", File.join(repo_root, "docs", "writing-style.md"))
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "repo", result.fetch("provenance")
      assert_equal "Trusted shared style.", result.fetch("guide")
    end
  end

  def test_missing_user_global_guide_warns_and_uses_the_packaged_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      Dir.mkdir(repo_root)
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style: docs/missing.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal File.read(DEFAULT_GUIDE, encoding: "UTF-8").strip, result.fetch("guide")
      assert_equal 1, result.fetch("warnings").length
      assert_includes stderr, "invalid user-global writing_style file"
      assert_includes stderr, "using portable default"
    end
  end

  def test_user_global_guide_symlink_escape_warns_and_uses_the_packaged_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      outside_path = File.join(directory, "outside.md")
      Dir.mkdir(repo_root)
      FileUtils.mkdir_p(File.join(home, ".agents", "docs"))
      File.write(outside_path, "Outside style must not load.\n")
      File.symlink(outside_path, File.join(home, ".agents", "docs", "writing-style.md"))
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal 1, result.fetch("warnings").length
      assert_includes stderr, "invalid user-global writing_style path"
      assert_includes stderr, "resolves outside its trusted root"
      refute_includes stdout, "Outside style must not load"
    end
  end

  def test_missing_repository_key_falls_back_to_user_global_guide_and_ignores_other_user_policy
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(home, ".agents", "docs"))
      File.write(File.join(repo_root, ".agents", "agent-workflow.yml"), "base_branch: main\n")
      File.write(
        File.join(home, ".agents", "docs", "writing-style.md"),
        "Personal readable style.\n"
      )
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "base_branch: should-not-inherit\nwriting_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "user-global", result.fetch("provenance")
      assert_equal "Personal readable style.", result.fetch("guide")
      assert_equal [], result.fetch("warnings")
      assert_empty stderr
    end
  end

  def test_empty_repository_document_still_falls_back_to_user_global_guide
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(home, ".agents", "docs"))
      File.write(File.join(repo_root, ".agents", "agent-workflow.yml"), "")
      File.write(
        File.join(home, ".agents", "docs", "writing-style.md"),
        "Personal readable style.\n"
      )
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style: docs/writing-style.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "user-global", result.fetch("provenance")
      assert_equal "Personal readable style.", result.fetch("guide")
      assert_equal [], result.fetch("warnings")
      assert_empty stderr
    end
  end

  def test_malformed_explicit_repository_value_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: Repository style.\n  extra: forbidden\n"
      )
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: User fallback must not be used.\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style"
      assert_includes stderr, "expected a nonblank relative Markdown-file path"
      refute_includes stderr, "User fallback must not be used"
    end
  end

  def test_top_level_false_repository_config_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.write(File.join(repo_root, ".agents", "agent-workflow.yml"), "false\n")
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: User fallback must not be used.\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style configuration"
      assert_includes stderr, "expected a top-level mapping"
      refute_includes stderr, "User fallback must not be used"
    end
  end

  def test_dangling_repository_symlink_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      repo_path = File.join(repo_root, ".agents", "agent-workflow.yml")
      FileUtils.mkdir_p(File.dirname(repo_path))
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.symlink(File.join(directory, "missing-repository-config.yml"), repo_path)
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: User fallback must not be used.\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style configuration"
      assert_includes stderr, "expected a readable regular file"
      refute_includes stderr, "User fallback must not be used"
    end
  end

  def test_dangling_repository_parent_symlink_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      Dir.mkdir(repo_root)
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.symlink(File.join(directory, "missing-repository-agents"), File.join(repo_root, ".agents"))
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: User fallback must not be used.\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style configuration"
      assert_includes stderr, "dangling symlink ancestor"
      refute_includes stderr, "User fallback must not be used"
    end
  end

  def test_unsearchable_repository_parent_blocks_instead_of_falling_back
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      agents_dir = File.join(repo_root, ".agents")
      repo_path = File.join(agents_dir, "agent-workflow.yml")
      FileUtils.mkdir_p(agents_dir)
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.write(repo_path, "writing_style:\n  guide: Unreadable repository style.\n")
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: User fallback must not be used.\n"
      )

      stdout = stderr = status = nil
      File.chmod(0o000, agents_dir)
      begin
        begin
          File.lstat(repo_path)
        rescue Errno::EACCES
          stdout, stderr, status = run_resolver(repo_root:, home:)
        else
          skip "filesystem does not enforce owner search permissions"
        end
      ensure
        File.chmod(0o700, agents_dir)
      end

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style configuration"
      assert_includes stderr, "Errno::EACCES"
      refute_includes stderr, "User fallback must not be used"
      refute_includes stderr, "Unreadable repository style"
    end
  end

  def test_malformed_user_global_value_warns_and_falls_back_to_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(home, ".agents"))
      Dir.mkdir(repo_root)
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: [not, prose]\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_includes result.fetch("guide"), "Lead with the outcome"
      assert_equal 1, result.fetch("warnings").length
      assert_includes result.fetch("warnings").first, "invalid user-global writing_style"
      assert_includes stderr, "WARNING: invalid user-global writing_style"
      assert_includes stderr, "Fix or remove"
      assert_includes stderr, File.join(home, ".agents", "agent-workflow.yml")
    end
  end

  def test_top_level_false_user_global_config_warns_and_falls_back_to_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(home, ".agents"))
      Dir.mkdir(repo_root)
      File.write(File.join(home, ".agents", "agent-workflow.yml"), "false\n")

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_includes result.fetch("guide"), "Lead with the outcome"
      assert_equal 1, result.fetch("warnings").length
      assert_includes result.fetch("warnings").first, "expected a top-level mapping"
      assert_includes stderr, "WARNING: invalid user-global writing_style configuration"
      refute_includes stdout, "false"
    end
  end

  def test_unparseable_repository_config_blocks_with_repository_context
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      Dir.mkdir(home)
      File.write(File.join(repo_root, ".agents", "agent-workflow.yml"), "writing_style: [broken\n")

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid repository writing_style configuration"
      assert_includes stderr, "Psych::SyntaxError"
    end
  end

  def test_duplicate_writing_style_keys_are_rejected
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      Dir.mkdir(home)
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style: docs/first.md\nwriting_style: docs/last.md\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "duplicate key \"writing_style\""
    end
  end

  def test_unreadable_user_global_path_warns_and_uses_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      user_path = File.join(home, ".agents", "agent-workflow.yml")
      Dir.mkdir(repo_root)
      FileUtils.mkdir_p(user_path)

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal 1, result.fetch("warnings").length
      assert_includes stderr, "expected a readable regular file"
      assert_includes stderr, "using portable default"
    end
  end

  def test_dangling_user_global_symlink_warns_and_uses_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      user_path = File.join(home, ".agents", "agent-workflow.yml")
      Dir.mkdir(repo_root)
      FileUtils.mkdir_p(File.dirname(user_path))
      File.symlink(File.join(directory, "missing-user-config.yml"), user_path)

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal 1, result.fetch("warnings").length
      assert_includes stderr, "expected a readable regular file"
      assert_includes stderr, "using portable default"
    end
  end

  def test_dangling_user_global_parent_symlink_warns_and_uses_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      Dir.mkdir(repo_root)
      Dir.mkdir(home)
      File.symlink(File.join(directory, "missing-user-agents"), File.join(home, ".agents"))

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal 1, result.fetch("warnings").length
      assert_includes stderr, "invalid user-global writing_style configuration"
      assert_includes stderr, "dangling symlink ancestor"
      assert_includes stderr, "using portable default"
    end
  end

  def test_unsearchable_user_global_parent_warns_and_uses_default
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      agents_dir = File.join(home, ".agents")
      user_path = File.join(agents_dir, "agent-workflow.yml")
      Dir.mkdir(repo_root)
      FileUtils.mkdir_p(agents_dir)
      File.write(user_path, "writing_style:\n  guide: Unreadable user style.\n")

      stdout = stderr = status = nil
      File.chmod(0o000, agents_dir)
      begin
        begin
          File.lstat(user_path)
        rescue Errno::EACCES
          stdout, stderr, status = run_resolver(repo_root:, home:)
        else
          skip "filesystem does not enforce owner search permissions"
        end
      ensure
        File.chmod(0o700, agents_dir)
      end

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal 1, result.fetch("warnings").length
      assert_includes stderr, "invalid user-global writing_style configuration"
      assert_includes stderr, "Errno::EACCES"
      assert_includes stderr, "using portable default"
      refute_includes stdout, "Unreadable user style"
    end
  end

  def test_multidocument_user_global_config_warns_instead_of_silently_ignoring_documents
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(home, ".agents"))
      Dir.mkdir(repo_root)
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "---\nbase_branch: ignored\n---\nwriting_style:\n  guide: Hidden second document.\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "portable-default", result.fetch("provenance")
      assert_equal 1, result.fetch("warnings").length
      assert_includes stderr, "expected one YAML document"
    end
  end
end
