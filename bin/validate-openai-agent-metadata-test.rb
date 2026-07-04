#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for validate-openai-agent-metadata.
# Run with: ruby bin/validate-openai-agent-metadata-test.rb

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("validate-openai-agent-metadata", __dir__)

class ValidateOpenaiAgentMetadataTest < Minitest::Test
  def test_validates_existing_files_and_allows_missing_optional_files
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        # Codex UI metadata for skill picker display text and default prompt.
        interface:
          display_name: "Alpha"
          short_description: "Run alpha workflow checks"
          default_prompt: "Use $alpha to run alpha."
      YAML
      write_skill(root, "beta")

      out, status = run_validator(root)

      assert status.success?, out
      assert_includes out, "PASS 1 OpenAI agent metadata files"
    end
  end

  def test_rejects_malformed_yaml
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", "interface: [\n")

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/agents/openai.yaml: invalid YAML"
    end
  end

  def test_rejects_missing_required_fields
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        interface:
          display_name: "Alpha"
          short_description: ""
          default_prompt: "Use $alpha to run alpha."
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/agents/openai.yaml: interface.short_description must be a non-empty string"
    end
  end

  def test_rejects_non_string_required_fields
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        interface:
          display_name: 123
          short_description: "Run alpha workflow checks"
          default_prompt: "Use $alpha to run alpha."
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/agents/openai.yaml: interface.display_name must be a non-empty string"
    end
  end

  def test_rejects_non_string_default_prompt
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        interface:
          display_name: "Alpha"
          short_description: "Run alpha workflow checks"
          default_prompt:
            - "Use $alpha to run alpha."
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/agents/openai.yaml: interface.default_prompt must be a non-empty string"
    end
  end

  def test_rejects_prompt_for_another_skill
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        interface:
          display_name: "Alpha"
          short_description: "Run alpha workflow checks"
          default_prompt: "Use $beta to run alpha."
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/agents/openai.yaml: default_prompt must reference $alpha"
    end
  end

  def test_allows_money_amounts_in_default_prompt
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        interface:
          display_name: "Alpha"
          short_description: "Run alpha workflow checks"
          default_prompt: "Use $alpha to review a $20 budget."
      YAML

      out, status = run_validator(root)

      assert status.success?, out
    end
  end

  def test_rejects_short_description_outside_picker_bounds
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        interface:
          display_name: "Alpha"
          short_description: "Too short"
          default_prompt: "Use $alpha to run alpha."
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/agents/openai.yaml: interface.short_description must be 25-64 characters"
    end
  end

  def test_rejects_prompt_with_multiple_skill_refs
    with_fixture do |root|
      write_skill(root, "alpha")
      write_metadata(root, "alpha", <<~YAML)
        interface:
          display_name: "Alpha"
          short_description: "Run alpha workflow checks"
          default_prompt: "Use $alpha after $beta."
      YAML

      out, status = run_validator(root)

      refute status.success?, out
      assert_includes out, "skills/alpha/agents/openai.yaml: default_prompt must reference $alpha"
    end
  end

  private

  def with_fixture(&block)
    Dir.mktmpdir("openai-agent-metadata-test") do |root|
      block.call(root)
    end
  end

  def write_skill(root, name)
    path = File.join(root, "skills", name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "SKILL.md"), <<~MARKDOWN)
      ---
      name: #{name}
      description: test skill
      ---
    MARKDOWN
  end

  def write_metadata(root, name, contents)
    path = File.join(root, "skills", name, "agents")
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "openai.yaml"), contents)
  end

  def run_validator(root)
    Open3.capture2e("ruby", SCRIPT, root)
  end
end
