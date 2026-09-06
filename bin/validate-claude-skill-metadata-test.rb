#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for validate-claude-skill-metadata.
# Run with: ruby bin/validate-claude-skill-metadata-test.rb

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("validate-claude-skill-metadata", __dir__)

class ValidateClaudeSkillMetadataTest < Minitest::Test
  def test_accepts_pack_baseline_and_documented_claude_fields
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: alpha
        description: Use when running the alpha workflow checks.
        argument-hint: "[scope]"
        allowed-tools: Read
        when_to_use: alpha workflow checks
      YAML

      out, status = run_validator(root)

      assert status.success?, out
      assert_includes out, "PASS 1 skills"
    end
  end

  def test_rejects_unknown_key_with_nearest_known_key_hint
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: alpha
        description: Use when running the alpha workflow checks.
        argument_hint: "[scope]"
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/SKILL.md: unknown frontmatter key \"argument_hint\"; did you mean \"argument-hint\"?"
    end
  end

  def test_rejects_description_without_trigger_phrase
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: alpha
        description: Alpha workflow checks for a maintained repository.
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/SKILL.md: description must include an explicit Use when/before/after/only/for trigger phrase"
    end
  end

  def test_rejects_overlong_description
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: alpha
        description: #{'a' * 1520} Use when running alpha.
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/SKILL.md: description must be 25-1536 characters"
    end
  end

  def test_rejects_description_with_edge_whitespace
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: alpha
        description: " Use when running the alpha workflow checks."
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/SKILL.md: description must not have leading or trailing whitespace"
    end
  end

  def test_rejects_name_that_does_not_match_its_folder
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: beta
        description: Use when running the alpha workflow checks.
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/SKILL.md: name must match folder \"alpha\""
    end
  end

  def test_rejects_non_kebab_case_name
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: Alpha
        description: Use when running the alpha workflow checks.
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/SKILL.md: name must use kebab-case"
    end
  end

  def test_rejects_empty_argument_hint_when_present
    with_fixture do |root|
      write_skill(root, "alpha", <<~YAML)
        name: alpha
        description: Use when running the alpha workflow checks.
        argument-hint: ""
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/SKILL.md: argument-hint must be a non-empty string when present"
    end
  end

  private

  def with_fixture(&block)
    Dir.mktmpdir("claude-skill-metadata-test") do |root|
      block.call(root)
    end
  end

  def write_skill(root, name, frontmatter)
    path = File.join(root, "skills", name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "SKILL.md"), "---\n#{frontmatter}---\n\n# #{name}\n")
  end

  def run_validator(root)
    Open3.capture2e("ruby", SCRIPT, root)
  end
end
