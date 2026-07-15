#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for check-agent-workflow-drift.
# Run with: ruby bin/check-agent-workflow-drift-test.rb

require "digest"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

SCRIPT = File.expand_path("check-agent-workflow-drift", __dir__)

class CheckAgentWorkflowDriftTest < Minitest::Test
  def test_requires_all_explicit_paths
    _out, err, status = Open3.capture3("ruby", SCRIPT)

    assert_equal 2, status.exitstatus
    assert_includes err, "--manifest, --source-root, --consumer-root"
  end

  def test_reports_clean_identical_file_and_expected_overlay
    with_fixture do |fixture|
      out, err, status = run_checker(fixture)

      assert status.success?, "#{out}#{err}"
      assert_includes out, "CLEAN IDENTICAL (1)"
      assert_includes out, "skills/example/SKILL.md -> .agents/skills/example/SKILL.md"
      assert_includes out, "EXPECTED OVERLAYS (1)"
      assert_includes out, "workflows/example.md -> .agents/workflows/example.md"
      assert_includes out, "consumer keeps repository-specific commands"
      assert_includes out, "UNEXPECTED DRIFT (0)"
      assert_empty err
    end
  end

  def test_detects_changed_identical_file
    with_fixture do |fixture|
      write_file(fixture.fetch(:consumer_root), ".agents/skills/example/SKILL.md", "consumer drift\n")

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "identical files differ"
    end
  end

  def test_detects_consumer_executable_mode_drift_for_identical_file
    with_fixture do |fixture|
      consumer_path = File.join(fixture.fetch(:consumer_root), ".agents/skills/example/SKILL.md")
      File.chmod(0o755, consumer_path)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "consumer mode differs from pinned source (expected 100644, found 100755)"
    end
  end

  def test_detects_current_source_mode_drift_from_pinned_revision
    with_fixture do |fixture|
      source_path = File.join(fixture.fetch(:source_root), "skills/example/SKILL.md")
      File.chmod(0o755, source_path)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "source mode differs from pinned source (expected 100644, found 100755)"
    end
  end

  def test_accepts_identical_file_when_pinned_source_is_executable
    with_fixture do |fixture|
      source_path = File.join(fixture.fetch(:source_root), "skills/example/SKILL.md")
      consumer_path = File.join(fixture.fetch(:consumer_root), ".agents/skills/example/SKILL.md")
      File.chmod(0o755, source_path)
      File.chmod(0o755, consumer_path)
      revision = commit_source_change(fixture.fetch(:source_root), "make fixture executable")
      update_manifest(fixture) { |manifest| manifest["source_revision"] = revision }

      out, err, status = run_checker(fixture)

      assert status.success?, "#{out}#{err}"
      assert_includes out, "CLEAN IDENTICAL (1)"
      assert_includes out, "UNEXPECTED DRIFT (0)"
    end
  end

  def test_rejects_consumer_symlink_file_kind_even_when_bytes_match
    with_fixture do |fixture|
      relative_path = ".agents/skills/example/SKILL.md"
      consumer_path = File.join(fixture.fetch(:consumer_root), relative_path)
      target_path = File.join(fixture.fetch(:consumer_root), "shared-skill-target.md")
      File.binwrite(target_path, "shared skill\n")
      FileUtils.rm_f(consumer_path)
      File.symlink(target_path, consumer_path)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "consumer has unsupported file kind (Git mode 120000): #{relative_path}"
    end
  end

  def test_rejects_intermediate_consumer_directory_symlink
    with_fixture do |fixture|
      consumer_root = fixture.fetch(:consumer_root)
      component = File.join(consumer_root, ".agents/skills")
      target = File.join(consumer_root, "consumer-skills")
      FileUtils.mv(component, target)
      File.symlink(target, component)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "consumer path has a symlinked intermediate component: .agents/skills/example/SKILL.md (.agents/skills)"
    end
  end

  def test_rejects_intermediate_source_directory_symlink
    with_fixture do |fixture|
      source_root = fixture.fetch(:source_root)
      component = File.join(source_root, "skills")
      target = File.join(source_root, "source-skills")
      FileUtils.mv(component, target)
      File.symlink(target, component)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "source path has a symlinked intermediate component: skills/example/SKILL.md (skills)"
    end
  end

  def test_accepts_symlink_aliases_for_cli_roots
    with_fixture do |fixture|
      parent = File.dirname(fixture.fetch(:source_root))
      source_alias = File.join(parent, "source-alias")
      consumer_alias = File.join(parent, "consumer-alias")
      File.symlink(fixture.fetch(:source_root), source_alias)
      File.symlink(fixture.fetch(:consumer_root), consumer_alias)

      out, err, status = run_checker(
        fixture,
        "--source-root", source_alias,
        "--consumer-root", consumer_alias
      )

      assert status.success?, "#{out}#{err}"
      assert_includes out, "CLEAN IDENTICAL (1)"
      assert_includes out, "EXPECTED OVERLAYS (1)"
    end
  end

  def test_rejects_unsupported_pinned_source_file_kind
    with_fixture do |fixture|
      source_root = fixture.fetch(:source_root)
      mapped_path = File.join(source_root, "skills/example/SKILL.md")
      write_file(source_root, "skills/shared-target.md", "shared skill\n")
      FileUtils.rm_f(mapped_path)
      File.symlink("../shared-target.md", mapped_path)
      revision = commit_source_change(source_root, "make fixture a symlink")
      update_manifest(fixture) { |manifest| manifest["source_revision"] = revision }

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "unsupported pinned source mode 120000: skills/example/SKILL.md"
    end
  end

  def test_detects_changed_source_side_of_overlay
    with_fixture do |fixture|
      write_file(fixture.fetch(:source_root), "workflows/example.md", "source overlay drift\n")

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "source hash changed"
      refute_includes out, "consumer hash changed"
    end
  end

  def test_detects_changed_consumer_side_of_overlay
    with_fixture do |fixture|
      write_file(fixture.fetch(:consumer_root), ".agents/workflows/example.md", "consumer overlay drift\n")

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "consumer hash changed"
      refute_includes out, "source hash changed"
    end
  end

  def test_detects_consumer_executable_mode_drift_for_overlay
    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest.fetch("files").last["consumer_mode"] = "100644" }
      consumer_path = File.join(fixture.fetch(:consumer_root), ".agents/workflows/example.md")
      File.chmod(0o755, consumer_path)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "consumer mode differs from reviewed overlay (expected 100644, found 100755)"
    end
  end

  def test_detects_current_source_mode_drift_for_overlay
    with_fixture do |fixture|
      source_path = File.join(fixture.fetch(:source_root), "workflows/example.md")
      File.chmod(0o755, source_path)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "source mode differs from pinned source (expected 100644, found 100755)"
    end
  end

  def test_accepts_reviewed_executable_consumer_overlay
    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest.fetch("files").last["consumer_mode"] = "100755" }
      consumer_path = File.join(fixture.fetch(:consumer_root), ".agents/workflows/example.md")
      File.chmod(0o755, consumer_path)

      out, err, status = run_checker(fixture)

      assert status.success?, "#{out}#{err}"
      assert_includes out, "EXPECTED OVERLAYS (1)"
      assert_includes out, "UNEXPECTED DRIFT (0)"
    end
  end

  def test_orders_results_independently_of_manifest_order
    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest.fetch("files").reverse! }
      write_file(fixture.fetch(:consumer_root), ".agents/skills/example/SKILL.md", "consumer drift\n")
      write_file(fixture.fetch(:consumer_root), ".agents/workflows/example.md", "overlay drift\n")

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "UNEXPECTED DRIFT (2)"
      assert_operator out.index("skills/example/SKILL.md"), :<, out.index("workflows/example.md")
    end
  end

  def test_rejects_duplicate_source_mapping
    with_fixture do |fixture|
      duplicate_consumer = ".agents/skills/example-copy/SKILL.md"
      write_file(fixture.fetch(:consumer_root), duplicate_consumer, "shared skill\n")
      manifest = YAML.safe_load_file(fixture.fetch(:manifest_path), aliases: false)
      manifest.fetch("files") << {
        "source" => "skills/example/SKILL.md",
        "consumer" => duplicate_consumer,
        "mode" => "identical"
      }
      File.write(fixture.fetch(:manifest_path), YAML.dump(manifest))

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "duplicate source path: skills/example/SKILL.md"
    end
  end

  def test_rejects_source_content_that_does_not_match_pinned_revision
    with_fixture do |fixture|
      source_path = "workflows/example.md"
      write_file(fixture.fetch(:source_root), source_path, "uncommitted source content\n")
      manifest = YAML.safe_load_file(fixture.fetch(:manifest_path), aliases: false)
      overlay = manifest.fetch("files").find { |entry| entry.fetch("mode") == "overlay" }
      overlay["source_sha256"] = Digest::SHA256.file(File.join(fixture.fetch(:source_root), source_path)).hexdigest
      File.write(fixture.fetch(:manifest_path), YAML.dump(manifest))

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "source file does not match pinned revision"
    end
  end

  def test_rejects_stale_source_revision
    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest["source_revision"] = "0" * 40 }

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "source revision mismatch"
      assert_includes out, "expected #{'0' * 40}"
      assert_includes out, "found #{fixture.fetch(:revision)}"
    end
  end

  def test_rejects_duplicate_consumer_mapping
    with_fixture do |fixture|
      source_path = "skills/example-copy/SKILL.md"
      write_file(fixture.fetch(:source_root), source_path, "shared skill copy\n")
      git(fixture.fetch(:source_root), "add", ".")
      git(fixture.fetch(:source_root), "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", "second fixture")
      new_revision, status = Open3.capture2("git", "-C", fixture.fetch(:source_root), "rev-parse", "HEAD")
      assert status.success?, new_revision
      update_manifest(fixture) do |manifest|
        manifest["source_revision"] = new_revision.strip
        manifest.fetch("files") << {
          "source" => source_path,
          "consumer" => ".agents/skills/example/SKILL.md",
          "mode" => "identical"
        }
      end

      out, _err, result = run_checker(fixture)

      refute result.success?
      assert_includes out, "duplicate consumer path: .agents/skills/example/SKILL.md"
    end
  end

  def test_rejects_traversal_and_absolute_paths
    ["../outside.md", "/tmp/outside.md"].each do |unsafe_path|
      with_fixture do |fixture|
        update_manifest(fixture) { |manifest| manifest.fetch("files").first["source"] = unsafe_path }

        out, _err, status = run_checker(fixture)

        refute status.success?, unsafe_path
        assert_includes out, "must not be absolute, traversing, or non-canonical"
      end
    end
  end

  def test_rejects_symlink_that_escapes_consumer_root
    with_fixture do |fixture|
      consumer_path = File.join(fixture.fetch(:consumer_root), ".agents/skills/example/SKILL.md")
      outside_path = File.join(File.dirname(fixture.fetch(:consumer_root)), "outside.md")
      File.binwrite(outside_path, "shared skill\n")
      FileUtils.rm_f(consumer_path)
      File.symlink(outside_path, consumer_path)

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "consumer path escapes its root or is not a file"
    end
  end

  def test_reports_consumer_symlink_cycle_without_backtrace
    with_fixture do |fixture|
      relative_path = ".agents/skills/example/SKILL.md"
      consumer_path = File.join(fixture.fetch(:consumer_root), relative_path)
      FileUtils.rm_f(consumer_path)
      File.symlink("SKILL.md", consumer_path)

      out, err, status = run_checker(fixture)

      assert_equal 1, status.exitstatus
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "consumer path has a symlink cycle: #{relative_path}"
      assert_empty err
    end
  end

  def test_reports_root_symlink_cycle_without_backtrace
    with_fixture do |fixture|
      cycle_root = File.join(File.dirname(fixture.fetch(:consumer_root)), "consumer-cycle")
      File.symlink("consumer-cycle", cycle_root)

      out, err, status = run_checker(fixture, "--consumer-root", cycle_root)

      assert_equal 1, status.exitstatus
      assert_includes out, "UNEXPECTED DRIFT (1)"
      assert_includes out, "consumer root has a symlink cycle: #{cycle_root}"
      assert_empty err
    end
  end

  def test_rejects_missing_mapped_file
    with_fixture do |fixture|
      FileUtils.rm_f(File.join(fixture.fetch(:consumer_root), ".agents/skills/example/SKILL.md"))

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "consumer file is missing"
    end
  end

  def test_rejects_overlay_without_reason_or_valid_hashes
    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest.fetch("files").last["reason"] = "" }

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "reason must be nonempty"
    end

    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest.fetch("files").last["consumer_sha256"] = "not-a-hash" }

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "consumer_sha256 must be a 64-hex SHA-256"
    end

    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest.fetch("files").last["consumer_mode"] = "0755" }

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "consumer_mode must be 100644 or 100755"
    end
  end

  def test_rejects_malformed_or_extended_schema
    with_fixture do |fixture|
      File.write(fixture.fetch(:manifest_path), "version: [\n")

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "invalid YAML"
    end

    with_fixture do |fixture|
      update_manifest(fixture) { |manifest| manifest["unexpected"] = true }

      out, _err, status = run_checker(fixture)

      refute status.success?
      assert_includes out, "manifest has unknown keys: unexpected"
    end
  end

  def test_accepts_colon_leading_source_paths_as_literal_git_paths
    with_fixture do |fixture|
      source_root = fixture.fetch(:source_root)
      consumer_root = fixture.fetch(:consumer_root)
      literal_paths = [":foo", ":(glob)foo"]

      literal_paths.each do |path|
        write_file(source_root, path, "#{path} contents\n")
        write_file(consumer_root, path, "#{path} contents\n")
      end
      revision = commit_source_change(source_root, "add colon-leading paths")
      update_manifest(fixture) do |manifest|
        manifest["source_revision"] = revision
        literal_paths.each do |path|
          manifest.fetch("files") << {
            "source" => path,
            "consumer" => path,
            "mode" => "identical"
          }
        end
      end

      out, err, status = run_checker(fixture)

      assert status.success?, "#{out}#{err}"
      assert_includes out, "CLEAN IDENTICAL (3)"
      literal_paths.each { |path| assert_includes out, "#{path} -> #{path}" }
      assert_includes out, "UNEXPECTED DRIFT (0)"
    end
  end

  private

  def with_fixture
    Dir.mktmpdir("agent-workflow-drift") do |tmp|
      source_root = File.join(tmp, "source")
      consumer_root = File.join(tmp, "consumer")
      write_file(source_root, "skills/example/SKILL.md", "shared skill\n")
      write_file(source_root, "workflows/example.md", "shared workflow\n")
      revision = commit_source(source_root)

      write_file(consumer_root, ".agents/skills/example/SKILL.md", "shared skill\n")
      write_file(consumer_root, ".agents/workflows/example.md", "local workflow overlay\n")

      manifest_path = File.join(tmp, "agent-workflow-drift.yml")
      manifest = {
        "version" => 1,
        "source_revision" => revision,
        "files" => [
          {
            "source" => "skills/example/SKILL.md",
            "consumer" => ".agents/skills/example/SKILL.md",
            "mode" => "identical"
          },
          {
            "source" => "workflows/example.md",
            "consumer" => ".agents/workflows/example.md",
            "mode" => "overlay",
            "reason" => "consumer keeps repository-specific commands",
            "consumer_mode" => "100644",
            "source_sha256" => Digest::SHA256.file(File.join(source_root, "workflows/example.md")).hexdigest,
            "consumer_sha256" => Digest::SHA256.file(File.join(consumer_root, ".agents/workflows/example.md")).hexdigest
          }
        ]
      }
      File.write(manifest_path, YAML.dump(manifest))

      yield manifest_path:, source_root:, consumer_root:, revision:
    end
  end

  def write_file(root, path, contents)
    destination = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.binwrite(destination, contents)
  end

  def commit_source(source_root)
    git(source_root, "init", "--quiet", "--initial-branch=main")
    git(source_root, "add", ".")
    git(source_root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", "fixture")
    out, status = Open3.capture2("git", "-C", source_root, "rev-parse", "HEAD")
    assert status.success?, out
    out.strip
  end

  def commit_source_change(source_root, message)
    git(source_root, "add", ".")
    git(source_root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", message)
    out, status = Open3.capture2("git", "-C", source_root, "rev-parse", "HEAD")
    assert status.success?, out
    out.strip
  end

  def update_manifest(fixture)
    manifest = YAML.safe_load_file(fixture.fetch(:manifest_path), aliases: false)
    yield manifest
    File.write(fixture.fetch(:manifest_path), YAML.dump(manifest))
  end

  def git(root, *)
    _out, err, status = Open3.capture3("git", "-C", root, *)
    assert status.success?, err
  end

  def run_checker(fixture, *)
    Open3.capture3(
      "ruby", SCRIPT,
      "--manifest", fixture.fetch(:manifest_path),
      "--source-root", fixture.fetch(:source_root),
      "--consumer-root", fixture.fetch(:consumer_root),
      *
    )
  end
end
