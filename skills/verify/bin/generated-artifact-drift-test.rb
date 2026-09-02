#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class GeneratedArtifactDriftTest < Minitest::Test
  SCRIPT = File.expand_path("generated-artifact-drift", __dir__)

  def test_repository_without_declaration_is_silent
    with_policy("base_branch" => "main") do |root|
      stdout, stderr, status = run_helper(root, "--changed-file", "templates/widget.tt")

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_changed_source_without_golden_test_fails_precisely
    with_policy(
      "generated_artifacts" => [
        {
          "source" => "templates/widget.tt",
          "mirrors" => ["spec/fixtures/widget.rb"]
        }
      ]
    ) do |root|
      stdout, stderr, status = run_helper(root, "--changed-file", "templates/widget.tt")

      refute status.success?
      assert_empty stdout
      assert_includes stderr, 'source "templates/widget.tt" changed'
      assert_includes stderr, "generated_artifacts[0].golden_test is not declared"
      assert_includes stderr, "Add the repo-owned golden test path before verification can pass."
    end
  end

  def test_changed_source_with_missing_declared_golden_test_fails_precisely
    with_policy("generated_artifacts" => [valid_declaration]) do |root|
      stdout, stderr, status = run_helper(
        root,
        "--changed-file", "templates/widget.tt",
        "--changed-file", "spec/fixture.rb"
      )

      refute status.success?
      assert_empty stdout
      assert_includes stderr, 'source "templates/widget.tt" changed'
      assert_includes stderr,
                      'generated_artifacts[0].golden_test "spec/golden/widget_spec.rb" is not an existing repository file'
      assert_includes stderr, "Restore it or update the declaration before verification can pass."
    end
  end

  def test_changed_source_without_changed_mirror_requires_acknowledgment
    with_policy(
      "generated_artifacts" => [
        {
          "source" => "templates/widget.tt",
          "mirrors" => ["spec/fixtures/widget.rb", "spec/dummy/widget.js"],
          "golden_test" => "spec/golden/widget_spec.rb"
        }
      ]
    ) do |root|
      write_file(root, "spec/golden/widget_spec.rb")
      stdout, stderr, status = run_helper(root, "--changed-file", "templates/widget.tt")

      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "ADVISORY acknowledgment-required"
      assert_includes stdout, 'source "templates/widget.tt" changed'
      assert_includes stdout, '"spec/dummy/widget.js", "spec/fixtures/widget.rb"'
      assert_includes stdout, "record why no mirror change is needed in verification evidence"
    end
  end

  def test_changed_mirror_clears_the_advisory
    with_policy(
      "generated_artifacts" => [
        {
          "source" => "templates/widget.tt",
          "mirrors" => ["spec/fixtures/widget.rb"],
          "golden_test" => "spec/golden/widget_spec.rb"
        }
      ]
    ) do |root|
      write_file(root, "spec/golden/widget_spec.rb")
      stdout, stderr, status = run_helper(
        root,
        "--changed-file", "templates/widget.tt",
        "--changed-file", "spec/fixtures/widget.rb"
      )

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_base_ref_discovers_the_committed_branch_diff
    with_policy(
      "generated_artifacts" => [
        {
          "source" => "templates/widget.tt",
          "mirrors" => ["spec/fixtures/widget.rb"],
          "golden_test" => "spec/golden/widget_spec.rb"
        }
      ]
    ) do |root|
      %w[templates/widget.tt spec/fixtures/widget.rb spec/golden/widget_spec.rb].each do |path|
        absolute_path = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        File.write(absolute_path, "original\n")
      end
      run_git(root, "init", "--quiet")
      run_git(root, "config", "user.email", "test@example.com")
      run_git(root, "config", "user.name", "Test")
      run_git(root, "add", ".")
      run_git(root, "commit", "--quiet", "-m", "base")
      base = run_git(root, "rev-parse", "HEAD").strip
      File.write(File.join(root, "templates/widget.tt"), "changed\n")
      run_git(root, "add", ".")
      run_git(root, "commit", "--quiet", "-m", "change source")

      stdout, stderr, status = run_helper(root, "--base-ref", base)

      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "ADVISORY acknowledgment-required"
    end
  end

  def test_base_ref_includes_uncommitted_worktree_changes
    with_policy("generated_artifacts" => [valid_declaration]) do |root|
      %w[templates/widget.tt spec/fixture.rb spec/golden/widget_spec.rb].each do |path|
        absolute_path = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        File.write(absolute_path, "original\n")
      end
      run_git(root, "init", "--quiet")
      run_git(root, "config", "user.email", "test@example.com")
      run_git(root, "config", "user.name", "Test")
      run_git(root, "add", ".")
      run_git(root, "commit", "--quiet", "-m", "base")
      base = run_git(root, "rev-parse", "HEAD").strip
      File.write(File.join(root, "templates/widget.tt"), "changed but uncommitted\n")

      stdout, stderr, status = run_helper(root, "--base-ref", base)

      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "ADVISORY acknowledgment-required"
    end
  end

  def test_invalid_declaration_fails_closed_before_evaluation
    with_policy("generated_artifacts" => { "source" => "templates/widget.tt" }) do |root|
      stdout, stderr, status = run_helper(root, "--changed-file", "templates/widget.tt")

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "invalid generated_artifacts policy: expected a nonempty list"
      refute_includes stderr, "NoMethodError"
    end
  end

  def test_unchanged_declared_source_is_silent
    with_policy(
      "generated_artifacts" => [
        {
          "source" => "templates/widget.tt",
          "mirrors" => ["spec/fixtures/widget.rb"]
        }
      ]
    ) do |root|
      stdout, stderr, status = run_helper(root, "--changed-file", "README.md")

      assert status.success?, stderr
      assert_empty stdout
      assert_empty stderr
    end
  end

  def test_policy_validation_rejects_ambiguous_or_unsafe_declarations
    invalid_policies = {
      "empty declaration list" => [],
      "non-mapping entry" => ["templates/widget.tt"],
      "unknown entry key" => [valid_declaration.merge("mirror" => "spec/typo.rb")],
      "absolute source" => [valid_declaration.merge("source" => "/templates/widget.tt")],
      "traversing source" => [valid_declaration.merge("source" => "../widget.tt")],
      "empty mirrors" => [valid_declaration.merge("mirrors" => [])],
      "duplicate mirrors" => [valid_declaration.merge("mirrors" => ["spec/fixture.rb", "spec/fixture.rb"])],
      "source repeated as mirror" => [valid_declaration.merge("mirrors" => ["templates/widget.tt"])],
      "invalid golden test" => [valid_declaration.merge("golden_test" => "")],
      "duplicate sources" => [valid_declaration, valid_declaration]
    }

    invalid_policies.each do |label, generated_artifacts|
      with_policy("generated_artifacts" => generated_artifacts) do |root|
        stdout, stderr, status = run_helper(root, "--changed-file", "README.md")

        refute status.success?, label
        assert_empty stdout, label
        assert_includes stderr, "invalid generated_artifacts policy", label
        refute_includes stderr, "NoMethodError", label
      end
    end
  end

  def test_duplicate_declaration_keys_fail_closed
    with_policy_text(<<~YAML) do |root|
      generated_artifacts:
        - source: templates/first.tt
          source: templates/second.tt
          mirrors:
            - spec/fixture.rb
    YAML
      stdout, stderr, status = run_helper(root, "--changed-file", "templates/second.tt")

      refute status.success?
      assert_empty stdout
      assert_includes stderr, 'invalid generated_artifacts policy: $.generated_artifacts contains duplicate key "source"'
    end
  end

  private

  def with_policy(policy)
    Dir.mktmpdir("generated-artifact-drift-test") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents/agent-workflow.yml"), policy.to_yaml)
      yield root
    end
  end

  def with_policy_text(text)
    Dir.mktmpdir("generated-artifact-drift-test") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents/agent-workflow.yml"), text)
      yield root
    end
  end

  def run_helper(root, *arguments)
    Open3.capture3("ruby", SCRIPT, "--root", root, *arguments)
  end

  def run_git(root, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
    raise "git fixture failed: #{stderr}" unless status.success?

    stdout
  end

  def write_file(root, path, content = "test\n")
    absolute_path = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content)
  end

  def valid_declaration
    {
      "source" => "templates/widget.tt",
      "mirrors" => ["spec/fixture.rb"],
      "golden_test" => "spec/golden/widget_spec.rb"
    }
  end
end
