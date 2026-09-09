#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
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

  def test_check_version_accepts_commit_versioned_claude_manifest
    with_release_root do |root|
      write_versions(root, "1.2.3")
      File.write(File.join(root, ".claude-plugin", "plugin.json"), JSON.generate("name" => "scw"))
      payload, status = run_json("check-version", "--root", root)
      assert status.success?, payload.inspect
      assert_nil payload.dig("metadata", "claude")
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
        "--repository", "shakacode/agent-workflows",
        "--workflow-run-id", "1234",
        "--workflow-run-attempt", "2",
        "--workflow-path", ".github/workflows/release.yml",
        "--workflow-run-url", "https://github.com/shakacode/agent-workflows/actions/runs/1234",
        "--recorded-at", "2026-08-08T12:00:00Z",
        "--receipt", receipt_path
      )
      assert status.success?, payload.inspect
      receipt = JSON.parse(File.read(receipt_path))
      assert_equal "RECEIPT_WRITTEN", payload.fetch("status")
      assert_equal "stable", receipt.fetch("channel")
      assert_equal({ "suite" => "full", "exact_commit" => commit, "before_tag" => true }, receipt.fetch("verification"))
      assert_equal "v1.2.3", receipt.fetch("release_ref")
      assert_equal tag_object, receipt.fetch("tag_object")
      assert_equal commit, receipt.fetch("peeled_commit")
      assert_equal commit, receipt.dig("approval", "exact_commit")
      assert_equal "stable-release", receipt.dig("approval", "environment")
      assert_equal "release-approver", receipt.dig("approval", "reviewer")
      assert_equal true, receipt.dig("approval", "human_non_author")
      assert_equal "shakacode/agent-workflows", receipt.dig("workflow", "repository")
      assert_equal 1234, receipt.dig("workflow", "run_id")
      assert_equal 2, receipt.dig("workflow", "run_attempt")
      assert_equal ".github/workflows/release.yml", receipt.dig("workflow", "path")
      assert_equal "2026-08-08T12:00:00Z", receipt.fetch("recorded_at")
    end
  end

  def test_verify_receipt_rejects_a_tag_moved_after_release
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      run_path = File.join(root, "github-workflow-run.json")
      approvals_path = File.join(root, "github-workflow-approvals.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "original tag")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      write_github_release(release_path, receipt_path)
      write_github_workflow_run(run_path, commit)
      write_github_approvals(approvals_path)

      verification_args = [
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path,
        "--github-workflow-run", run_path,
        "--github-workflow-approvals", approvals_path
      ]
      payload, status = run_json(*verification_args)
      assert status.success?, payload.inspect
      assert_equal "RECEIPT_VERIFIED", payload.fetch("status")

      original_receipt = File.read(receipt_path)
      [nil, { "suite" => "selected", "exact_commit" => commit, "before_tag" => true },
       { "suite" => "full", "exact_commit" => "0" * 40, "before_tag" => true },
       { "suite" => "full", "exact_commit" => commit, "before_tag" => false }].each do |verification|
        receipt = JSON.parse(original_receipt)
        receipt["verification"] = verification
        File.write(receipt_path, JSON.generate(receipt))
        write_github_release(release_path, receipt_path)
        rejected, rejected_status = run_json(*verification_args)
        assert_equal 2, rejected_status.exitstatus
        assert_includes rejected.fetch("reason"), "full exact-candidate verification before tagging"
      end
      File.write(receipt_path, original_receipt)
      write_github_release(release_path, receipt_path)

      git(root, "tag", "-d", "v1.2.3")
      git(root, "tag", "-a", "v1.2.3", "-m", "moved tag")
      payload, status = run_json(*verification_args)

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "tag moved"
    end
  end

  def test_verify_receipt_rejects_self_asserted_json_without_github_provenance
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "self-asserted release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)

      payload, status = run_json("verify-receipt", "--root", root, "--receipt", receipt_path)

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "GitHub release provenance"
    end
  end

  def test_verify_receipt_rejects_a_release_asset_digest_mismatch
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "digest-bound release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      File.write(
        release_path,
        JSON.generate(
          "tag_name" => "v1.2.3",
          "draft" => false,
          "prerelease" => false,
          "assets" => [{
            "name" => "agent-workflows-release-receipt.json",
            "state" => "uploaded",
            "digest" => "sha256:#{'0' * 64}",
            "browser_download_url" => "https://github.com/shakacode/agent-workflows/releases/download/v1.2.3/agent-workflows-release-receipt.json"
          }]
        )
      )

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "asset digest"
      refute_equal "sha256:#{Digest::SHA256.file(receipt_path).hexdigest}", "sha256:#{'0' * 64}"
    end
  end

  def test_verify_receipt_rejects_an_asset_without_exact_workflow_run_provenance
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "workflow-bound release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      write_github_release(release_path, receipt_path)

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "workflow run provenance"
    end
  end

  def test_verify_receipt_rejects_workflow_run_metadata_for_the_wrong_head
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      run_path = File.join(root, "github-workflow-run.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "exact-head release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      write_github_release(release_path, receipt_path)
      write_github_workflow_run(run_path, "0" * 40)

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path,
        "--github-workflow-run", run_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "workflow run metadata"
    end
  end

  def test_verify_receipt_rejects_matching_provenance_from_another_workflow
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      run_path = File.join(root, "github-workflow-run.json")
      approvals_path = File.join(root, "github-workflow-approvals.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "workflow-bound release")
      record_receipt(root, commit, git(root, "rev-parse", "refs/tags/v1.2.3"), receipt_path)
      receipt = JSON.parse(File.read(receipt_path))
      receipt.fetch("workflow")["path"] = ".github/workflows/other.yml"
      File.write(receipt_path, JSON.generate(receipt))
      write_github_release(release_path, receipt_path)
      write_github_workflow_run(run_path, commit)
      run = JSON.parse(File.read(run_path))
      run["path"] = receipt.fetch("workflow").fetch("path")
      File.write(run_path, JSON.generate(run))
      write_github_approvals(approvals_path)

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path, "--github-workflow-run", run_path,
        "--github-workflow-approvals", approvals_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "workflow run metadata"
    end
  end

  def test_verify_receipt_rejects_a_successful_run_without_approval_provenance
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      run_path = File.join(root, "github-workflow-run.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "approval-bound release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      write_github_release(release_path, receipt_path)
      write_github_workflow_run(run_path, commit)

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path,
        "--github-workflow-run", run_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "approval provenance"
    end
  end

  def test_verify_receipt_rejects_approval_history_for_the_wrong_reviewer
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      run_path = File.join(root, "github-workflow-run.json")
      approvals_path = File.join(root, "github-workflow-approvals.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "reviewer-bound release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      write_github_release(release_path, receipt_path)
      write_github_workflow_run(run_path, commit)
      write_github_approvals(approvals_path, reviewer: "different-reviewer")

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path,
        "--github-workflow-run", run_path,
        "--github-workflow-approvals", approvals_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "protected-environment approval"
    end
  end

  def test_verify_receipt_rejects_an_asset_uploaded_by_an_untrusted_actor
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      run_path = File.join(root, "github-workflow-run.json")
      approvals_path = File.join(root, "github-workflow-approvals.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "actor-bound release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      write_github_release(release_path, receipt_path, uploader: "different-actor", uploader_type: "User")
      write_github_workflow_run(run_path, commit)
      write_github_approvals(approvals_path)

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "shakacode/agent-workflows",
        "--github-release", release_path,
        "--github-workflow-run", run_path,
        "--github-workflow-approvals", approvals_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "GitHub Actions release publisher"
    end
  end

  def test_verify_receipt_rejects_provenance_for_a_different_expected_repository
    with_release_repository("1.2.3") do |root, commit|
      receipt_path = File.join(root, "release-receipt.json")
      release_path = File.join(root, "github-release.json")
      run_path = File.join(root, "github-workflow-run.json")
      approvals_path = File.join(root, "github-workflow-approvals.json")
      git(root, "tag", "-a", "v1.2.3", "-m", "repository-bound release")
      tag_object = git(root, "rev-parse", "refs/tags/v1.2.3")
      record_receipt(root, commit, tag_object, receipt_path)
      write_github_release(release_path, receipt_path)
      write_github_workflow_run(run_path, commit)
      write_github_approvals(approvals_path)

      payload, status = run_json(
        "verify-receipt", "--root", root, "--receipt", receipt_path,
        "--repository", "other/project",
        "--github-release", release_path,
        "--github-workflow-run", run_path,
        "--github-workflow-approvals", approvals_path
      )

      assert_equal 2, status.exitstatus
      assert_includes payload.fetch("reason"), "expected repository"
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
      "--repository", "shakacode/agent-workflows",
      "--workflow-run-id", "1234",
      "--workflow-run-attempt", "1",
      "--workflow-path", ".github/workflows/release.yml",
      "--workflow-run-url", "https://github.com/shakacode/agent-workflows/actions/runs/1234",
      "--recorded-at", "2026-08-08T12:00:00Z",
      "--receipt", receipt_path
    )
    raise payload.inspect unless status.success?
  end

  def write_github_release(path, receipt_path, uploader: "github-actions[bot]", uploader_type: "Bot")
    File.write(
      path,
      JSON.generate(
        "tag_name" => "v1.2.3",
        "draft" => false,
        "prerelease" => false,
        "html_url" => "https://github.com/shakacode/agent-workflows/releases/tag/v1.2.3",
        "author" => { "login" => "github-actions[bot]", "type" => "Bot" },
        "assets" => [{
          "name" => "agent-workflows-release-receipt.json",
          "state" => "uploaded",
          "size" => File.size(receipt_path),
          "digest" => "sha256:#{Digest::SHA256.file(receipt_path).hexdigest}",
          "browser_download_url" => "https://github.com/shakacode/agent-workflows/releases/download/v1.2.3/agent-workflows-release-receipt.json",
          "uploader" => { "login" => uploader, "type" => uploader_type }
        }]
      )
    )
  end

  def write_github_workflow_run(path, head_sha)
    File.write(
      path,
      JSON.generate(
        "id" => 1234,
        "run_attempt" => 1,
        "path" => ".github/workflows/release.yml",
        "event" => "workflow_dispatch",
        "status" => "completed",
        "conclusion" => "success",
        "html_url" => "https://github.com/shakacode/agent-workflows/actions/runs/1234",
        "head_branch" => "main",
        "head_sha" => head_sha,
        "actor" => { "login" => "release-operator", "type" => "User" },
        "repository" => { "full_name" => "shakacode/agent-workflows", "private" => false }
      )
    )
  end

  def write_github_approvals(path, reviewer: "release-approver")
    File.write(
      path,
      JSON.generate(
        [{
          "state" => "approved",
          "environments" => [{ "name" => "stable-release" }],
          "user" => { "login" => reviewer, "type" => "User" }
        }]
      )
    )
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
