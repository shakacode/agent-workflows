#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class HumanSecurityReviewGateTest < Minitest::Test
  SCRIPT = File.expand_path("human-security-review-gate", __dir__)
  HEAD_SHA = "a" * 40

  def setup
    @tmp = Dir.mktmpdir("human-security-review-gate")
    @responses = File.join(@tmp, "responses")
    FileUtils.mkdir_p(@responses)
    @fake_gh = File.join(@tmp, "gh")
    File.write(@fake_gh, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"

      abort "expected gh api, got: #{ARGV.inspect}" unless ARGV.shift == "api"
      endpoint = ARGV.shift
      abort "unexpected arguments: #{ARGV.inspect}" unless ARGV.empty?

      root = ENV.fetch("GATE_TEST_RESPONSES")
      filename = endpoint.gsub(%r{[^A-Za-z0-9._-]}, "_")
      path = File.join(root, "#{filename}.json")
      unless File.file?(path)
        warn "missing fixture for #{endpoint}"
        exit 1
      end

      print File.read(path)
    RUBY
    FileUtils.chmod(0o755, @fake_gh)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_high_risk_change_without_human_approval_fails_closed
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => "skills/pr-batch/bin/pr-merge-submit" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [])

    output, status = run_gate

    refute_predicate status, :success?
    assert_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
    assert_includes output, "skills/pr-batch/bin/pr-merge-submit"
    assert_includes output, HEAD_SHA
  end

  def test_current_head_approval_from_a_human_collaborator_passes
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => "bin/install-agent-workflows" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [
                     {
                       "id" => 11,
                       "state" => "APPROVED",
                       "commit_id" => HEAD_SHA,
                       "submitted_at" => "2026-08-01T00:00:00Z",
                       "user" => { "login" => "reviewer", "type" => "User" }
                     }
                   ])
    write_response("repos/shakacode/agent-workflows/collaborators/reviewer/permission", {
                     "permission" => "write"
                   })

    output, status = run_gate

    assert_predicate status, :success?, output
    assert_includes output, "HUMAN_SECURITY_REVIEW_OK"
    assert_includes output, "reviewer=@reviewer"
    assert_includes output, HEAD_SHA
  end

  def test_shared_head_between_open_pull_requests_fails_closed
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls?state=open&per_page=100&page=1", [
                     { "number" => 7, "head" => { "sha" => HEAD_SHA } },
                     { "number" => 8, "head" => { "sha" => HEAD_SHA } }
                   ])

    output, status = run_gate

    assert_equal 2, status.exitstatus
    assert_includes output, "HUMAN_SECURITY_REVIEW_AMBIGUOUS"
    assert_includes output, "#7"
    assert_includes output, "#8"
  end

  def test_later_changes_requested_review_revokes_an_earlier_approval
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => "skills/pr-batch/SKILL.md" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [
                     {
                       "id" => 11,
                       "state" => "APPROVED",
                       "commit_id" => HEAD_SHA,
                       "submitted_at" => "2026-08-01T00:00:00Z",
                       "user" => { "login" => "reviewer", "type" => "User" }
                     },
                     {
                       "id" => 12,
                       "state" => "CHANGES_REQUESTED",
                       "commit_id" => HEAD_SHA,
                       "submitted_at" => "2026-08-01T00:01:00Z",
                       "user" => { "login" => "reviewer", "type" => "User" }
                     }
                   ])
    write_response("repos/shakacode/agent-workflows/collaborators/reviewer/permission", {
                     "permission" => "write"
                   })

    output, status = run_gate

    refute_predicate status, :success?
    assert_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
  end

  def test_changed_file_inventory_is_paginated_before_declaring_review_unnecessary
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1",
                   Array.new(100) { |index| { "filename" => "docs/page-#{index}.md" } })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=2", [
                     { "filename" => ".github/workflows/validate.yml" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [])

    output, status = run_gate

    refute_predicate status, :success?
    assert_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
    assert_includes output, ".github/workflows/validate.yml"
  end

  def test_renaming_an_execution_surface_out_of_a_protected_path_still_requires_review
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     {
                       "filename" => "docs/retired-installer.md",
                       "previous_filename" => "bin/install-agent-workflows",
                       "status" => "renamed"
                     }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [])

    output, status = run_gate

    refute_predicate status, :success?
    assert_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
    assert_includes output, "bin/install-agent-workflows"
  end

  def test_documentation_only_change_does_not_require_review_api_access
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => "docs/security-posture.md" }
                   ])

    output, status = run_gate

    assert_predicate status, :success?, output
    assert_includes output, "HUMAN_SECURITY_REVIEW_NOT_REQUIRED"
  end

  def test_review_policy_files_are_themselves_protected
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => ".github/CODEOWNERS" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [])

    output, status = run_gate

    refute_predicate status, :success?
    assert_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
  end

  def test_stale_head_approval_does_not_pass
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => "bin/install-agent-workflows" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [
                     {
                       "id" => 11,
                       "state" => "APPROVED",
                       "commit_id" => "b" * 40,
                       "submitted_at" => "2026-08-01T00:00:00Z",
                       "user" => { "login" => "reviewer", "type" => "User" }
                     }
                   ])

    output, status = run_gate

    refute_predicate status, :success?
    assert_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
  end

  def test_author_and_bot_approvals_do_not_count_as_human_review
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => "skills/verify/SKILL.md" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [
                     {
                       "id" => 11,
                       "state" => "APPROVED",
                       "commit_id" => HEAD_SHA,
                       "submitted_at" => "2026-08-01T00:00:00Z",
                       "user" => { "login" => "author", "type" => "User" }
                     },
                     {
                       "id" => 12,
                       "state" => "APPROVED",
                       "commit_id" => HEAD_SHA,
                       "submitted_at" => "2026-08-01T00:01:00Z",
                       "user" => { "login" => "review-bot[bot]", "type" => "Bot" }
                     }
                   ])

    output, status = run_gate

    refute_predicate status, :success?
    assert_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
  end

  def test_missing_head_identity_fails_as_an_api_error
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => {},
                     "user" => { "login" => "author" }
                   })
    write_response("repos/shakacode/agent-workflows/pulls/7/files?per_page=100&page=1", [
                     { "filename" => "bin/install-agent-workflows" }
                   ])
    write_response("repos/shakacode/agent-workflows/pulls/7/reviews?per_page=100&page=1", [])

    output, status = run_gate

    refute_predicate status, :success?
    assert_equal 70, status.exitstatus
    assert_includes output, "HUMAN_SECURITY_REVIEW_ERROR"
    refute_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED head="
  end

  def test_expected_head_mismatch_fails_closed_before_reviewing
    write_response("repos/shakacode/agent-workflows/pulls/7", {
                     "head" => { "sha" => HEAD_SHA },
                     "user" => { "login" => "author" }
                   })

    output, status = run_gate("--expected-head", "b" * 40)

    refute_predicate status, :success?
    assert_equal 70, status.exitstatus
    assert_includes output, "HUMAN_SECURITY_REVIEW_ERROR"
    assert_includes output, "head changed"
  end

  def test_github_api_failure_has_a_distinct_infrastructure_exit_status
    output, status = run_gate

    refute_predicate status, :success?
    assert_equal 70, status.exitstatus
    assert_includes output, "HUMAN_SECURITY_REVIEW_ERROR"
    refute_includes output, "HUMAN_SECURITY_REVIEW_REQUIRED"
  end

  private

  def write_response(endpoint, payload)
    filename = endpoint.gsub(/[^A-Za-z0-9._-]/, "_")
    File.write(File.join(@responses, "#{filename}.json"), JSON.generate(payload))
  end

  def run_gate(*extra_args)
    open_pulls_endpoint = "repos/shakacode/agent-workflows/pulls?state=open&per_page=100&page=1"
    open_pulls_path = File.join(@responses, "#{open_pulls_endpoint.gsub(/[^A-Za-z0-9._-]/, '_')}.json")
    unless File.exist?(open_pulls_path)
      write_response(open_pulls_endpoint, [{ "number" => 7, "head" => { "sha" => HEAD_SHA } }])
    end

    Open3.capture2e(
      {
        "AGENT_WORKFLOWS_GH_EXECUTABLE" => @fake_gh,
        "GATE_TEST_RESPONSES" => @responses
      },
      "ruby", SCRIPT,
      "--repo", "shakacode/agent-workflows",
      "--pr", "7",
      *extra_args
    )
  end
end
