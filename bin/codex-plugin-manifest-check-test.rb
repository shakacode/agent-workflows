#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("codex-plugin-manifest-check", __dir__)
load SCRIPT

class CodexPluginManifestCheckTest < Minitest::Test
  def test_current_native_manifests_use_canonical_scw_namespace
    root = File.expand_path("..", __dir__)
    manifest_paths = %w[.codex-plugin/plugin.json .claude-plugin/plugin.json]

    names = manifest_paths.map do |relative_path|
      JSON.parse(File.read(File.join(root, relative_path), encoding: "UTF-8")).fetch("name")
    end

    assert_equal %w[scw scw], names
  end

  def test_current_codex_marketplace_publishes_scw_from_repository_url
    root = File.expand_path("..", __dir__)
    catalog = JSON.parse(File.read(File.join(root, ".agents/plugins/marketplace.json"), encoding: "UTF-8"))

    assert_equal "agent-workflows", catalog["name"]
    assert_equal(["scw"], catalog.fetch("plugins").map { |plugin| plugin["name"] })
    assert_equal({ "source" => "url", "url" => "https://github.com/shakacode/agent-workflows.git" }, catalog.dig("plugins", 0, "source"))
  end

  def test_current_source_pack_manifest_passes
    out, status = run_check(File.expand_path("..", __dir__))

    assert status.success?, out
    assert_includes out, "PASS native plugin manifests"
  end

  def test_isolated_cached_plugin_root_exposes_only_scw_skill_surface
    source_root = File.expand_path("..", __dir__)

    Dir.mktmpdir("scw-plugin-profile") do |profile|
      plugin_root = File.join(profile, "plugins/cache/agent-workflows/scw/0.1.0")
      FileUtils.mkdir_p(plugin_root)
      %w[.agents .codex-plugin .claude-plugin skills VERSION README.md].each do |entry|
        FileUtils.cp_r(File.join(source_root, entry), plugin_root)
      end

      out, status = run_check(plugin_root)
      skill_names = Dir.children(File.join(plugin_root, "skills")).sort
      codex_surfaces = skill_names.map { |name| "scw:#{name}" }
      claude_surfaces = skill_names.map { |name| "/scw:#{name}" }

      assert status.success?, out
      assert_equal Dir.children(File.join(source_root, "skills")).sort, skill_names
      assert_includes codex_surfaces, "scw:verify"
      assert_includes claude_surfaces, "/scw:verify"
      refute((codex_surfaces + claude_surfaces).any? { |name| name.include?("agent-workflows:") })
      refute_path_exists File.join(profile, "skills/verify/SKILL.md")
      assert_includes out, "#{skill_names.length} skills under scw"
    end
  end

  def test_missing_manifest_fails
    with_source_pack do |root|
      FileUtils.rm_f(File.join(root, ".codex-plugin/plugin.json"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "missing .codex-plugin/plugin.json"
    end
  end

  def test_missing_codex_marketplace_fails
    with_source_pack do |root|
      FileUtils.rm_f(File.join(root, ".agents/plugins/marketplace.json"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "missing .agents/plugins/marketplace.json"
    end
  end

  def test_missing_claude_manifest_fails
    with_source_pack do |root|
      FileUtils.rm_f(File.join(root, ".claude-plugin/plugin.json"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "missing .claude-plugin/plugin.json"
    end
  end

  def test_missing_claude_marketplace_fails
    with_source_pack do |root|
      FileUtils.rm_f(File.join(root, ".claude-plugin/marketplace.json"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "missing .claude-plugin/marketplace.json"
    end
  end

  def test_marketplace_plugin_name_must_be_scw
    with_source_pack do |root|
      write_marketplace(root, "plugins" => [{ "name" => "agent-workflows", "source" => "./" }])

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, 'marketplace plugin name must be "scw"'
    end
  end

  def test_codex_marketplace_plugin_source_must_be_repository_url
    with_source_pack do |root|
      write_codex_marketplace(
        root,
        "plugins" => [{ "name" => "scw", "source" => { "source" => "local", "path" => "." } }]
      )

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "Codex marketplace plugin source must use the repository URL"
    end
  end

  def test_codex_marketplace_keeps_product_and_plugin_identities_distinct
    with_source_pack do |root|
      write_codex_marketplace(
        root,
        "name" => "scw",
        "plugins" => [{ "name" => "agent-workflows", "source" => codex_repository_source }]
      )

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, 'Codex marketplace name must be "agent-workflows"'
      assert_includes out, 'Codex marketplace plugin name must be "scw"'
    end
  end

  def test_codex_marketplace_keeps_verified_policy_and_category
    with_source_pack do |root|
      write_codex_marketplace(
        root,
        "plugins" => [
          {
            "name" => "scw",
            "source" => codex_repository_source,
            "policy" => { "installation" => "AVAILABLE", "authentication" => "ON_INSTALL" },
            "category" => "Productivity"
          }
        ]
      )

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "Codex marketplace plugin policy must use AVAILABLE/ON_USE"
      assert_includes out, 'Codex marketplace plugin category must be "Developer Tools"'
    end
  end

  def test_marketplace_plugin_source_must_be_plugin_root
    with_source_pack do |root|
      write_marketplace(root, "plugins" => [{ "name" => "scw", "source" => "./plugin" }])

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, 'marketplace plugin source must be "./"'
    end
  end

  def test_marketplace_keeps_agent_workflows_product_identity
    with_source_pack do |root|
      write_marketplace(root, "name" => "scw")

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, 'marketplace name must be "agent-workflows"'
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

  def test_claude_version_must_match_version_file
    with_source_pack do |root|
      write_claude_manifest(root, "version" => "9.9.9")

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

  def test_claude_skills_path_must_resolve_to_complete_skill_tree
    with_source_pack do |root|
      FileUtils.mkdir_p(File.join(root, "plugin-skills/example"))
      FileUtils.cp(File.join(root, "skills/example/SKILL.md"), File.join(root, "plugin-skills/example/SKILL.md"))
      write_claude_manifest(root, "skills" => "./plugin-skills/")

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

  def test_resolve_relative_path_rejects_traversal
    errors = []

    result = CodexPluginManifestCheck.resolve_relative_path(Dir.tmpdir, "../skills", errors)

    assert_nil result
    assert_includes errors, "skills path must be a relative path inside the plugin root"
  end

  def test_each_referenced_skill_requires_skill_md
    with_source_pack do |root|
      FileUtils.rm_f(File.join(root, "skills/review/SKILL.md"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "skill \"review\" is missing SKILL.md"
    end
  end

  def test_plugin_skill_frontmatter_names_remain_semantic
    with_source_pack do |root|
      path = File.join(root, "skills/example/SKILL.md")
      File.write(path, File.read(path).sub("name: example", "name: scw-example"))

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, 'skill "example" frontmatter name must be "example"'
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

  def test_claude_manifest_rejects_consumer_policy
    with_source_pack do |root|
      write_claude_manifest(root, "description" => "Run bin/validate on main before merging.")

      out, status = run_check(root)

      refute status.success?, out
      assert_includes out, "contains hardcoded branch name"
      assert_includes out, "contains consumer script path"
    end
  end

  def test_claude_marketplace_rejects_consumer_policy
    with_source_pack do |root|
      write_marketplace(root, "description" => "Run bin/validate on main before merging.")

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
      FileUtils.mkdir_p(File.join(root, ".claude-plugin"))
      FileUtils.mkdir_p(File.join(root, ".agents/plugins"))
      FileUtils.mkdir_p(File.join(root, "skills/example"))
      FileUtils.mkdir_p(File.join(root, "skills/review"))
      File.write(File.join(root, "VERSION"), "0.1.0\n")
      File.write(File.join(root, "README.md"), "# ShakaCode Agent Workflows\n\nReusable agent workflow skills for ShakaCode repositories.\n")
      File.write(File.join(root, "skills/example/SKILL.md"), "---\nname: example\ndescription: Example skill.\n---\n")
      File.write(File.join(root, "skills/review/SKILL.md"), "---\nname: review\ndescription: Review skill.\n---\n")
      write_manifest(root)
      write_codex_marketplace(root)
      write_claude_manifest(root)
      write_marketplace(root)
      yield root
    end
  end

  def write_manifest(root, overrides = {})
    manifest = base_manifest.merge(overrides)
    File.write(File.join(root, ".codex-plugin/plugin.json"), "#{JSON.pretty_generate(manifest)}\n")
  end

  def write_claude_manifest(root, overrides = {})
    manifest = base_manifest.reject { |key, _value| key == "interface" }.merge("license" => "MIT").merge(overrides)
    File.write(File.join(root, ".claude-plugin/plugin.json"), "#{JSON.pretty_generate(manifest)}\n")
  end

  def write_codex_marketplace(root, overrides = {})
    marketplace = {
      "name" => "agent-workflows",
      "plugins" => [
        {
          "name" => "scw",
          "source" => codex_repository_source,
          "policy" => {
            "installation" => "AVAILABLE",
            "authentication" => "ON_USE"
          },
          "category" => "Developer Tools"
        }
      ]
    }.merge(overrides)
    File.write(File.join(root, ".agents/plugins/marketplace.json"), "#{JSON.pretty_generate(marketplace)}\n")
  end

  def codex_repository_source
    {
      "source" => "url",
      "url" => "https://github.com/shakacode/agent-workflows.git"
    }
  end

  def write_marketplace(root, overrides = {})
    marketplace = {
      "name" => "agent-workflows",
      "description" => "Reusable agent workflow skills for ShakaCode repositories.",
      "owner" => { "name" => "ShakaCode" },
      "plugins" => [{ "name" => "scw", "source" => "./" }]
    }.merge(overrides)
    File.write(File.join(root, ".claude-plugin/marketplace.json"), "#{JSON.pretty_generate(marketplace)}\n")
  end

  def base_manifest
    {
      "name" => "scw",
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
