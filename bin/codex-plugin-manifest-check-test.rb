#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("codex-plugin-manifest-check", __dir__)

class CodexPluginManifestCheckTest < Minitest::Test
  def test_current_source_pack_manifest_passes
    out, status = run_check(File.expand_path("..", __dir__))

    assert status.success?, out
    assert_includes out, "PASS Codex plugin manifest"
  end

  def test_missing_manifest_fails
    with_source_pack do |root|
      FileUtils.rm_f(File.join(root, ".codex-plugin/plugin.json"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "missing .codex-plugin/plugin.json"
    end
  end

  def test_version_must_match_version_file
    with_source_pack do |root|
      write_manifest(root, "version" => "9.9.9")

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "version must match VERSION \"0.1.0\""
    end
  end

  def test_description_must_match_readme_summary
    with_source_pack do |root|
      write_manifest(root, "description" => "Different description.")

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "description must match README summary"
    end
  end

  def test_wrapped_readme_summary_is_joined_before_manifest_comparison
    with_source_pack do |root|
      File.write(File.join(root, "README.md"), <<~MARKDOWN)
        # ShakaCode Agent Workflows

        Reusable agent workflow skills
        for ShakaCode repositories.
      MARKDOWN
      write_manifest(root, "description" => "Reusable agent workflow skills for ShakaCode repositories.")

      out, status = run_check(root)

      assert status.success?, out
    end
  end

  def test_skills_path_must_resolve_to_complete_skill_tree
    with_source_pack do |root|
      FileUtils.mkdir_p(File.join(root, "plugin-skills/example"))
      FileUtils.cp(File.join(root, "skills/example/SKILL.md"), File.join(root, "plugin-skills/example/SKILL.md"))
      write_manifest(root, "skills" => "./plugin-skills/")

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "skills must be \"./skills/\""
    end
  end

  def test_skills_path_must_not_escape_plugin_root_through_symlink
    with_source_pack do |root|
      Dir.mktmpdir("external-skills") do |external_skills|
        FileUtils.rm_rf(File.join(root, "skills"))
        FileUtils.mkdir_p(File.join(external_skills, "example"))
        File.write(File.join(external_skills, "example/SKILL.md"), "---\nname: example\ndescription: External.\n---\n")
        File.symlink(external_skills, File.join(root, "skills"))

        out, status = run_check(root)

        refute status.success?, out
        assert_includes out, "skills path must stay inside the plugin root"
      end
    end
  end

  def test_each_referenced_skill_requires_skill_md
    with_source_pack do |root|
      FileUtils.rm_f(File.join(root, "skills/review/SKILL.md"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "skill \"review\" is missing SKILL.md"
    end
  end

  def test_manifest_rejects_consumer_policy
    with_source_pack do |root|
      write_manifest(root, "interface" => base_interface.merge("longDescription" => "Run bin/validate on main before merging."))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "contains hardcoded branch name"
      assert_includes out, "contains consumer script path"
    end
  end

  def test_manifest_rejects_case_variant_branch_policy
    with_source_pack do |root|
      write_manifest(root, "interface" => base_interface.merge("longDescription" => "Run checks on MASTER before merging."))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "contains hardcoded branch name"
    end
  end

  private

  def run_check(root)
    Open3.capture2e("ruby", SCRIPT, "--root", root)
  end

  def with_source_pack
    Dir.mktmpdir("codex-plugin-manifest-check-test") do |root|
      FileUtils.mkdir_p(File.join(root, ".codex-plugin"))
      FileUtils.mkdir_p(File.join(root, "skills/example"))
      FileUtils.mkdir_p(File.join(root, "skills/review"))
      File.write(File.join(root, "VERSION"), "0.1.0\n")
      File.write(File.join(root, "README.md"), "# ShakaCode Agent Workflows\n\nReusable agent workflow skills for ShakaCode repositories.\n")
      File.write(File.join(root, "skills/example/SKILL.md"), "---\nname: example\ndescription: Example skill.\n---\n")
      File.write(File.join(root, "skills/review/SKILL.md"), "---\nname: review\ndescription: Review skill.\n---\n")
      write_manifest(root)
      yield root
    end
  end

  def write_manifest(root, overrides = {})
    manifest = base_manifest.merge(overrides)
    File.write(File.join(root, ".codex-plugin/plugin.json"), "#{JSON.pretty_generate(manifest)}\n")
  end

  def base_manifest
    {
      "name" => "agent-workflows",
      "version" => "0.1.0",
      "description" => "Reusable agent workflow skills for ShakaCode repositories.",
      "author" => {
        "name" => "ShakaCode",
        "url" => "https://github.com/shakacode"
      },
      "homepage" => "https://github.com/shakacode/agent-workflows#readme",
      "repository" => "https://github.com/shakacode/agent-workflows",
      "skills" => "./skills/",
      "interface" => base_interface
    }
  end

  def base_interface
    {
      "displayName" => "ShakaCode Agent Workflows",
      "shortDescription" => "Reusable Codex workflows for PR batches, reviews, CI, and audits.",
      "longDescription" => "Reusable Codex skills for PR batch planning and audit loops.",
      "developerName" => "ShakaCode",
      "category" => "Productivity",
      "defaultPrompt" => ["Plan a safe PR batch."]
    }
  end
end
