#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-release", __dir__)

class AgentWorkflowsReleaseTest < Minitest::Test
  def test_check_version_accepts_one_shared_stable_version
    with_release_root do |root|
      write_versions(root, "1.2.3")

      output, status = Open3.capture2e("ruby", SCRIPT, "check-version", "--root", root, "--json")
      payload = JSON.parse(output)

      assert status.success?, output
      assert_equal "VERSION_OK", payload.fetch("status")
      assert_equal "1.2.3", payload.fetch("version")
      assert_equal "1.2.3", payload.dig("metadata", "claude")
      assert_equal "1.2.3", payload.dig("metadata", "codex")
    end
  end

  def test_check_version_rejects_mismatch_malformed_and_missing_metadata
    with_release_root do |root|
      write_versions(root, "1.2.3")
      manifest_path = File.join(root, ".codex-plugin", "plugin.json")
      File.write(manifest_path, "#{JSON.generate('name' => 'scw', 'version' => '1.2.4')}\n")

      payload, status = run_json("check-version", "--root", root)

      assert_equal 2, status.exitstatus
      assert_equal "RELEASE_CHECK_FAILED", payload.fetch("status")
      assert_includes payload.fetch("reason"), "do not match"

      write_versions(root, "release-1.2.3")
      payload, status = run_json("check-version", "--root", root)

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "stable semantic version"

      FileUtils.rm_f(File.join(root, ".claude-plugin", "plugin.json"))
      payload, status = run_json("check-version", "--root", root)

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "missing release metadata"
    end
  end

  def test_verify_tag_accepts_an_immutable_annotated_tag_at_the_approved_commit
    with_release_repository("1.2.3") do |root, commit|
      git(root, "tag", "-a", "v1.2.3", "-m", "Agent Workflows v1.2.3")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")

      payload, status = run_json(
        "verify-tag",
        "--root", root,
        "--release", "v1.2.3",
        "--approved-commit", commit,
        "--expected-tag-object", tag_object
      )

      assert status.success?, payload.inspect
      assert_equal "TAG_VERIFIED", payload.fetch("status")
      assert_equal "v1.2.3", payload.fetch("release_ref")
      assert_equal tag_object, payload.fetch("tag_object")
      assert_equal commit, payload.fetch("peeled_commit")
    end
  end

  def test_verify_tag_rejects_malformed_missing_lightweight_moved_and_wrong_commit_tags
    with_release_repository("1.2.3") do |root, commit|
      git(root, "tag", "v1.2.3")
      lightweight_object = git(root, "rev-parse", "refs/tags/v1.2.3")

      payload, status = verify_tag(root, "release-1.2.3", commit, lightweight_object)
      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "exact vX.Y.Z"

      payload, status = verify_tag(root, "v9.9.9", commit, lightweight_object)
      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "refs/tags/v9.9.9"

      payload, status = verify_tag(root, "v1.2.3", commit, lightweight_object)
      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "annotated tag"

      git(root, "tag", "-d", "v1.2.3")
      git(root, "tag", "-a", "v1.2.3", "-m", "replacement tag")
      moved_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      refute_equal lightweight_object, moved_object

      payload, status = verify_tag(root, "v1.2.3", commit, lightweight_object)
      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "tag moved"

      payload, status = verify_tag(root, "v1.2.3", "0" * 40, moved_object)
      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "not approved commit"
    end
  end

  def test_verify_tag_rejects_source_ref_version_mismatch
    with_release_repository("1.2.4") do |root, commit|
      git(root, "tag", "-a", "v1.2.3", "-m", "mismatched release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")

      payload, status = verify_tag(root, "v1.2.3", commit, tag_object)

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "does not match VERSION 1.2.4"
    end
  end

  def test_record_receipt_binds_exact_release_commit_and_protected_environment_approval
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "Agent Workflows v1.2.3")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")

      payload, status = run_json(
        "record-receipt",
        "--root", root,
        "--release", "v1.2.3",
        "--approved-commit", commit,
        "--expected-tag-object", tag_object,
        "--environment", "stable-release",
        "--change-author", "feature-author",
        "--release-actor", "release-operator",
        "--approval-reviewer", "release-approver",
        "--workflow-run-url", "https://github.com/shakacode/agent-workflows/actions/runs/1234",
        "--recorded-at", "2026-08-08T12:00:00Z",
        "--receipt", receipt_path
      )
      receipt = JSON.parse(File.read(receipt_path))

      assert status.success?, payload.inspect
      assert_equal "RECEIPT_WRITTEN", payload.fetch("status")
      assert_equal "stable", receipt.fetch("channel")
      assert_equal "v1.2.3", receipt.fetch("release_ref")
      assert_equal tag_object, receipt.fetch("tag_object")
      assert_equal commit, receipt.fetch("peeled_commit")
      assert_equal commit, receipt.dig("approval", "exact_commit")
      assert_equal "stable-release", receipt.dig("approval", "environment")
      assert_equal "release-approver", receipt.dig("approval", "reviewer")
      assert_equal true, receipt.dig("approval", "human_non_author")
      assert_equal "2026-08-08T12:00:00Z", receipt.fetch("recorded_at")
    end
  end

  def test_verify_receipt_rejects_a_tag_moved_after_release
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "original tag")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)

      payload, status = run_json("verify-receipt", "--root", root, "--receipt", receipt_path)
      assert status.success?, payload.inspect
      assert_equal "RECEIPT_VERIFIED", payload.fetch("status")

      git(root, "tag", "-d", "v1.2.3")
      git(root, "tag", "-a", "v1.2.3", "-m", "moved tag")
      payload, status = run_json("verify-receipt", "--root", root, "--receipt", receipt_path)

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "tag moved"
    end
  end

  private

  def with_release_root
    Dir.mktmpdir("agent-workflows-release-test") do |root|
      FileUtils.mkdir_p(File.join(root, ".claude-plugin"))
      FileUtils.mkdir_p(File.join(root, ".codex-plugin"))
      yield root
    end
  end

  def write_versions(root, version)
    File.write(File.join(root, "VERSION"), "#{version}\n")
    File.write(
      File.join(root, ".claude-plugin", "plugin.json"),
      "#{JSON.generate('name' => 'scw', 'version' => version)}\n"
    )
    File.write(
      File.join(root, ".codex-plugin", "plugin.json"),
      "#{JSON.generate('name' => 'scw', 'version' => version)}\n"
    )
  end

  def run_json(*args)
    output, status = Open3.capture2e("ruby", SCRIPT, *args, "--json")
    [JSON.parse(output), status]
  end

  def verify_tag(root, release, approved_commit, expected_tag_object)
    run_json(
      "verify-tag",
      "--root", root,
      "--release", release,
      "--approved-commit", approved_commit,
      "--expected-tag-object", expected_tag_object
    )
  end

  def record_receipt(root, commit, tag_object, receipt_path)
    payload, status = run_json(
      "record-receipt",
      "--root", root,
      "--release", "v1.2.3",
      "--approved-commit", commit,
      "--expected-tag-object", tag_object,
      "--environment", "stable-release",
      "--change-author", "feature-author",
      "--release-actor", "release-operator",
      "--approval-reviewer", "release-approver",
      "--workflow-run-url", "https://github.com/shakacode/agent-workflows/actions/runs/1234",
      "--recorded-at", "2026-08-08T12:00:00Z",
      "--receipt", receipt_path
    )
    raise payload.inspect unless status.success?
  end

  def with_release_repository(version)
    with_release_root do |root|
      write_versions(root, version)
      git(root, "init", "--quiet")
      git(root, "config", "user.email", "release-test@example.com")
      git(root, "config", "user.name", "Release Test")
      git(root, "add", ".")
      git(root, "commit", "--quiet", "-m", "release fixture")
      yield root, git(root, "rev-parse", "HEAD")
    end
  end

  def git(root, *args)
    output, status = Open3.capture2e("git", "-C", root, *args)
    raise output unless status.success?

    output.strip
  end
end
