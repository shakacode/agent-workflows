#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflow-writing-style", __dir__)

class AgentWorkflowWritingStyleTest < Minitest::Test
  def run_resolver(repo_root:, home:)
    Open3.capture3(
      { "HOME" => home },
      RbConfig.ruby,
      SCRIPT,
      "--repo-root",
      repo_root,
      "--format",
      "json"
    )
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
      assert_includes result.fetch("guide"), "Lead with the outcome"
      assert_includes result.fetch("guide"), "preserving required evidence"
      assert_equal [], result.fetch("warnings")
      assert_empty stderr
    end
  end

  def test_repository_guide_wins_without_reading_malformed_user_config
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.write(
        File.join(repo_root, ".agents", "agent-workflow.yml"),
        "writing_style:\n  guide: Repository house style.\n"
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

  def test_missing_repository_key_falls_back_to_user_global_guide_and_ignores_other_user_policy
    Dir.mktmpdir do |directory|
      repo_root = File.join(directory, "repo")
      home = File.join(directory, "home")
      FileUtils.mkdir_p(File.join(repo_root, ".agents"))
      FileUtils.mkdir_p(File.join(home, ".agents"))
      File.write(File.join(repo_root, ".agents", "agent-workflow.yml"), "base_branch: main\n")
      File.write(
        File.join(home, ".agents", "agent-workflow.yml"),
        "base_branch: should-not-inherit\nwriting_style:\n  guide: Personal readable style.\n"
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
      assert_includes stderr, "closed mapping containing only a nonblank string guide"
      refute_includes stderr, "User fallback must not be used"
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
        "writing_style:\n  guide: First.\n  guide: Last.\n"
      )

      stdout, stderr, status = run_resolver(repo_root:, home:)

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "duplicate key \"guide\""
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
