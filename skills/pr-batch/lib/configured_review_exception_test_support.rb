# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

module ConfiguredReviewExceptionTestSupport
  # A sole failed reviewer must remain a raw failure while an exact live human
  # exception permits readiness without inventing a successful Actions run.
  def with_review_exception(execution_head_sha: "a" * 40)
    Dir.mktmpdir("configured-review-exception") do |root|
      system(PrCiReadiness::SYSTEM_GIT, "-C", root, "init", "-q", exception: true)
      system(PrCiReadiness::SYSTEM_GIT, "-C", root, "config", "user.name", "Test", exception: true)
      system(PrCiReadiness::SYSTEM_GIT, "-C", root, "config", "user.email", "test@example.com", exception: true)
      FileUtils.mkdir_p(File.join(root, ".github/workflows"))
      File.write(File.join(root, ".github/workflows/review.yml"),
                 "name: Review\non: pull_request\njobs:\n  review:\n    name: Reviewer\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n")
      system(PrCiReadiness::SYSTEM_GIT, "-C", root, "add", ".", exception: true)
      system(PrCiReadiness::SYSTEM_GIT, "-C", root, "commit", "-qm", "trusted reviewer", exception: true)
      base = Open3.capture2(PrCiReadiness::SYSTEM_GIT, "-C", root, "rev-parse", "HEAD").first.strip
      head = "a" * 40
      identity = {
        "id" => 9001, "number" => 123,
        "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9002 } },
        "base" => { "sha" => base, "ref" => "main", "repo" => { "id" => 9003 } }
      }
      run = {
        "id" => 42, "workflow_id" => 17, "run_number" => 1, "run_attempt" => 1,
        "name" => "Review", "path" => ".github/workflows/review.yml", "event" => "pull_request",
        "head_sha" => execution_head_sha, "head_branch" => "feature", "head_repository" => { "id" => 9002 },
        "pull_requests" => [{ "id" => 9001, "number" => 123,
                              "url" => "https://api.github.com/repos/owner/repo/pulls/123",
                              "head" => identity.fetch("head") }],
        "status" => "completed", "conclusion" => "failure",
        "html_url" => "https://github.com/owner/repo/actions/runs/42"
      }
      job = {
        "id" => 420, "run_id" => 42, "run_attempt" => 1, "head_sha" => execution_head_sha,
        "name" => "Reviewer", "status" => "completed", "conclusion" => "failure",
        "html_url" => "https://github.com/owner/repo/actions/runs/42/job/420"
      }
      payload = {
        "host" => "github.com", "repo" => "owner/repo", "pr" => 123, "head_sha" => head,
        "workflow_id" => 17, "workflow_path" => ".github/workflows/review.yml",
        "job_key" => "review", "job_name" => "Reviewer", "job_id" => 420,
        "run_id" => 42, "run_attempt" => 1, "conclusion" => "failure",
        "decision" => "approve-terminal-review-exception", "approved_by" => "maintainer"
      }
      body = "<!-- configured-review-exception:v1 -->\n#{payload.to_yaml}...\n"
      reference = { "comment_id" => 501, "body_sha256" => Digest::SHA256.hexdigest(body) }
      comment = {
        "id" => 501, "body" => body, "user" => { "login" => "maintainer", "type" => "User" },
        "issue_url" => "https://api.github.com/repos/owner/repo/issues/123",
        "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-501"
      }
      data = {
        "repos/owner/repo/pulls/123" => identity,
        "repos/owner/repo/issues/comments/501" => comment,
        "repos/owner/repo/collaborators/maintainer/permission" => { "permission" => "write", "role_name" => "maintain", "user" => comment["user"] },
        "repos/owner/repo/actions/workflows/17" => { "id" => 17, "path" => run["path"], "name" => "Review", "state" => "active" },
        "repos/owner/repo/actions/runs/42" => run,
        "repos/owner/repo/actions/runs/42/jobs?per_page=100&page=1" => { "total_count" => 1, "jobs" => [job] },
        "repos/owner/repo/actions/runs?head_sha=#{head}&per_page=100&page=1" => { "total_count" => 1, "workflow_runs" => [run] },
        "repos/owner/repo/commits/#{head}/check-runs?per_page=100&page=1" => { "total_count" => 0, "check_runs" => [] },
        "repos/owner/repo/commits/#{head}/status?per_page=100&page=1" => { "sha" => head, "total_count" => 0, "statuses" => [], "state" => "pending" }
      }
      if execution_head_sha != head
        data["repos/owner/repo/actions/runs?head_sha=#{head}&per_page=100&page=1"] = { "total_count" => 0, "workflow_runs" => [] }
        data["repos/owner/repo/actions/runs?head_sha=#{execution_head_sha}&per_page=100&page=1"] = { "total_count" => 1, "workflow_runs" => [run] }
        data["repos/owner/repo/commits/#{execution_head_sha}/check-runs?per_page=100&page=1"] = { "total_count" => 0, "check_runs" => [] }
        data["repos/owner/repo/commits/#{execution_head_sha}/status?per_page=100&page=1"] = { "sha" => execution_head_sha, "total_count" => 0, "statuses" => [], "state" => "pending" }
      end
      fallback = [{ "workflow" => "Review", "name" => "Reviewer", "bucket" => "fail",
                    "state" => "FAILURE", "link" => job["html_url"] }]
      transport = lambda do |*args, host:|
        raise "wrong host" unless host == "github.com"

        response = case args[0..1]
                   when %w[pr checks]
                     args.include?("--required") ? data.fetch("required_checks", []) : fallback
                   when %w[pr view]
                     { "headRefOid" => head }
                   when %w[api graphql]
                     data.fetch("viewer_reviews") do
                       { "data" => { "repository" => { "pullRequest" => { "reviews" => {
                         "nodes" => [], "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                       } } } } }
                     end
                   else
                     data.fetch(args.fetch(1))
                   end
        [JSON.generate(response), "", Struct.new(:success?).new(true)]
      end
      yield root, base, reference, data, fallback, transport
    end
  end
end
