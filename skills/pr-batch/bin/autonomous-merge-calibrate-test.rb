#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tempfile"
require "tmpdir"
require_relative "../lib/autonomous_merge_calibration"

SCRIPT = File.expand_path("autonomous-merge-calibrate", __dir__)
FIXTURE_DIR = File.expand_path("../fixtures", __dir__)

class AutonomousMergeCalibrateTest < Minitest::Test
  def test_reports_distributions_near_misses_and_shadow_disposition_without_complete_review_history
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => false,
        "window" => "representative checked fixture",
        "repositories" => ["example/one", "example/two"]
      },
      "prs" => [
        pr("example/one", 1, files: 29, lines: 999, commits: 9, reviewed_heads: 3),
        pr("example/one", 2, files: 30, lines: 1_000, commits: 10, reviewed_heads: 4),
        pr("example/two", 3, files: 2, lines: 20, commits: 1, reviewed_heads: nil)
      ]
    }

    Tempfile.create(["calibration", ".json"]) do |file|
      file.write(JSON.generate(dataset))
      file.flush
      stdout, stderr, status = Open3.capture3(
        "ruby", SCRIPT,
        "--input", file.path,
        "--repo", "example/one",
        "--repo", "example/two",
        "--pr-count", "100",
        "--sample", "2"
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)

      assert_equal "autonomous-merge-calibration-report", result.fetch("contract")
      assert_equal 3, result.dig("coverage", "pr_count")
      assert_equal 2, result.dig("coverage", "reviewed_heads_known")
      assert_equal "shadow", result.dig("reviewed_heads", "disposition")
      assert_includes result.dig("reviewed_heads", "graduation_blockers"), "dataset scope is incomplete"
      assert_equal([2], result.fetch("triggered_sample").map { |entry| entry.fetch("number") })
      assert_equal([1], result.fetch("near_miss_sample").map { |entry| entry.fetch("number") })
    end
  end

  def test_reports_path_category_distribution_and_complete_proposed_threshold_classification_changes
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => false,
        "window" => "proposed-threshold comparison fixture",
        "repositories" => ["example/one", "example/two"]
      },
      "prs" => [
        pr(
          "example/one", 1,
          files: 29, lines: 999, commits: 9, reviewed_heads: 3,
          path_categories: %w[app docs]
        ),
        pr(
          "example/one", 2,
          files: 30, lines: 1_000, commits: 10, reviewed_heads: 4,
          path_categories: %w[app db]
        ),
        pr(
          "example/two", 3,
          files: 2, lines: 20, commits: 1, reviewed_heads: nil,
          path_categories: %w[docs]
        )
      ]
    }

    Tempfile.create(["calibration", ".json"]) do |file|
      file.write(JSON.generate(dataset))
      file.flush
      stdout, stderr, status = Open3.capture3(
        "ruby", SCRIPT,
        "--input", file.path,
        "--sample", "1",
        "--max-changed-files", "1"
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)

      assert_equal(
        { "app" => 2, "db" => 1, "docs" => 2 },
        result.fetch("path_category_distribution")
      )
      assert_equal(
        [
          {
            "repository" => "example/one",
            "number" => 1,
            "portable_default_triggered" => false,
            "proposed_threshold_triggered" => true
          },
          {
            "repository" => "example/two",
            "number" => 3,
            "portable_default_triggered" => false,
            "proposed_threshold_triggered" => true
          }
        ],
        result.fetch("proposed_threshold_classification_changes")
      )
      assert_equal 1, result.fetch("triggered_sample").length
      assert_equal false, result.fetch("merge_decisions_emitted")
    end
  end

  def test_checked_calibration_decision_is_exactly_reproducible_and_emits_no_merge_decisions
    dataset = File.join(FIXTURE_DIR, "autonomous-merge-calibration-dataset.json")
    decision = File.join(FIXTURE_DIR, "autonomous-merge-reviewed-heads-calibration.json")
    stdout, stderr, status = Open3.capture3(
      "ruby", SCRIPT,
      "--input", dataset,
      "--pr-count", "100",
      "--sample", "5",
      "--format", "decision"
    )

    assert status.success?, stderr
    assert_equal JSON.parse(File.read(decision)), JSON.parse(stdout)

    report_stdout, report_stderr, report_status = Open3.capture3(
      "ruby", SCRIPT,
      "--input", dataset,
      "--pr-count", "100",
      "--sample", "5"
    )
    assert report_status.success?, report_stderr
    report = JSON.parse(report_stdout)
    assert_equal false, report.fetch("merge_decisions_emitted")
    assert_equal "shadow", report.dig("reviewed_heads", "disposition")
  end

  def test_collection_paginates_and_preserves_complete_review_object_history
    Dir.mktmpdir("autonomous-merge-calibration-collection") do |root|
      checkpoint = File.join(root, "dataset.json")
      sha_one = "1" * 40
      sha_two = "2" * 40
      responses = {
        discovery_path("example/one", page: 1, per_page: 2) => [
          list_entry(7, "2026-07-20T00:00:00Z"),
          list_entry(6, "2026-07-19T00:00:00Z")
        ],
        discovery_path("example/one", page: 2, per_page: 2) => [],
        "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z"),
        page_path("example/one", 7, "files", 1, 2) => [
          github_file("lib/a.rb", additions: 2),
          github_file("lib/b.rb", deletions: 1)
        ],
        page_path("example/one", 7, "files", 2, 2) => [
          github_file("docs/c.md", additions: 3)
        ],
        page_path("example/one", 7, "commits", 1, 2) => [
          { "sha" => "a" * 40 }
        ],
        page_path("example/one", 7, "reviews", 1, 2) => [
          github_review("COMMENTED", sha_one),
          github_review("DISMISSED", sha_two)
        ],
        page_path("example/one", 7, "reviews", 2, 2) => [
          github_review("PENDING", "viewer-local-draft"),
          github_review("APPROVED", nil)
        ],
        page_path("example/one", 7, "reviews", 3, 2) => []
      }
      calls = []
      api = mapped_api(responses, calls:)

      dataset = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 1,
        page_size: 2,
        api:
      )
      collected = dataset.fetch("prs").fetch(0)

      assert dataset.dig("scope", "complete")
      assert_equal false, dataset.fetch("merge_decisions_emitted")
      assert_equal 3, collected.fetch("changed_files")
      assert_equal 6, collected.fetch("changed_lines")
      assert_equal [sha_one, sha_two], collected.fetch("reviewed_head_shas")
      assert_nil collected.fetch("reviewed_heads")
      assert_equal false, collected.fetch("review_head_history_complete")
      assert_equal(
        %w[COMMENTED DISMISSED PENDING APPROVED],
        collected.fetch("reviews").map { |review| review["state"] }
      )
      assert_includes calls, discovery_path("example/one", page: 2, per_page: 2)
      assert_includes calls, page_path("example/one", 7, "files", 2, 2)
      assert_includes calls, page_path("example/one", 7, "reviews", 3, 2)
      assert_equal dataset, JSON.parse(File.read(checkpoint, encoding: "UTF-8"))
    end
  end

  def test_collection_checkpoints_rate_limit_and_resumes_without_refetching_completed_prs
    Dir.mktmpdir("autonomous-merge-calibration-resume") do |root|
      checkpoint = File.join(root, "dataset.json")
      discovery = discovery_path("example/one", page: 1, per_page: 100)
      first_calls = []
      first_api = lambda do |path|
        first_calls << path
        case path
        when discovery
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when "repos/example/one/pulls/8"
          detail(8, "2026-07-21T00:00:00Z")
        when page_path("example/one", 8, "files", 1, 100)
          [github_file("lib/eight.rb")]
        when page_path("example/one", 8, "commits", 1, 100)
          [{ "sha" => "8" * 40 }]
        when page_path("example/one", 8, "reviews", 1, 100)
          []
        when "repos/example/one/pulls/7"
          raise AutonomousMergeCalibration::RateLimitError, "rate limit exhausted"
        else
          raise "unexpected first-run path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::RateLimitError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 2,
          api: first_api
        )
      end
      assert_includes error.message, "rate limit"
      partial = JSON.parse(File.read(checkpoint, encoding: "UTF-8"))
      assert_equal false, partial.dig("scope", "complete")
      assert_equal "rate-limit", partial.dig("scope", "last_error", "kind")
      assert_equal [8], partial.dig("scope", "repository_progress", "example/one", "completed_pr_numbers")

      resume_calls = []
      resume_api = mapped_api(
        {
          "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z"),
          page_path("example/one", 7, "files", 1, 100) => [github_file("lib/seven.rb")],
          page_path("example/one", 7, "commits", 1, 100) => [{ "sha" => "7" * 40 }],
          page_path("example/one", 7, "reviews", 1, 100) => []
        },
        calls: resume_calls
      )
      complete = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 2,
        api: resume_api
      )

      assert complete.dig("scope", "complete")
      assert_equal [7, 8], complete.fetch("prs").map { |entry| entry.fetch("number") }.sort
      refute(resume_calls.any? { |path| path.include?("/pulls/8") })
      refute_includes resume_calls, discovery
    end
  end

  def test_incomplete_discovery_resume_restarts_page_one_when_closed_pr_order_shifts
    Dir.mktmpdir("autonomous-merge-calibration-shifting-discovery") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_one = discovery_path("example/one", page: 1, per_page: 2)
      page_two = discovery_path("example/one", page: 2, per_page: 2)
      first_api = lambda do |path|
        case path
        when page_one
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when page_two
          raise AutonomousMergeCalibration::RateLimitError, "rate limit exhausted"
        else
          raise "unexpected first-run path #{path}"
        end
      end

      assert_raises(AutonomousMergeCalibration::RateLimitError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 2,
          page_size: 2,
          api: first_api
        )
      end
      assert_equal(
        2,
        JSON.parse(File.read(checkpoint)).dig(
          "scope", "repository_progress", "example/one", "discovery_next_page"
        )
      )

      resume_calls = []
      responses = {
        page_one => [
          list_entry(9, "2026-07-22T00:00:00Z"),
          list_entry(8, "2026-07-21T00:00:00Z")
        ],
        page_two => [list_entry(7, "2026-07-20T00:00:00Z")],
        "repos/example/one/pulls/9" => detail(9, "2026-07-22T00:00:00Z"),
        page_path("example/one", 9, "files", 1, 2) => [github_file("lib/nine.rb")],
        page_path("example/one", 9, "commits", 1, 2) => [{ "sha" => "9" * 40 }],
        page_path("example/one", 9, "reviews", 1, 2) => [],
        "repos/example/one/pulls/8" => detail(8, "2026-07-21T00:00:00Z"),
        page_path("example/one", 8, "files", 1, 2) => [github_file("lib/eight.rb")],
        page_path("example/one", 8, "commits", 1, 2) => [{ "sha" => "8" * 40 }],
        page_path("example/one", 8, "reviews", 1, 2) => []
      }
      complete = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 2,
        page_size: 2,
        api: mapped_api(responses, calls: resume_calls)
      )

      assert_equal page_one, resume_calls.first
      assert_equal [8, 9], complete.fetch("prs").map { |entry| entry.fetch("number") }.sort
      assert complete.dig("scope", "complete")
    end
  end

  def test_collection_fails_closed_when_page_one_changes_during_discovery
    Dir.mktmpdir("autonomous-merge-calibration-moving-window") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_one_reads = 0
      api = lambda do |path|
        case path
        when discovery_path("example/one", page: 1, per_page: 2)
          page_one_reads += 1
          if page_one_reads == 1
            [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
          else
            [list_entry(9, "2026-07-22T00:00:00Z"), list_entry(8, "2026-07-21T00:00:00Z")]
          end
        when discovery_path("example/one", page: 2, per_page: 2)
          []
        else
          raise "unexpected API path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 2,
          page_size: 2,
          api:
        )
      end
      saved = JSON.parse(File.read(checkpoint))
      progress = saved.dig("scope", "repository_progress", "example/one")

      assert_equal "pagination", error.kind
      assert_includes error.message, "changed while paginating"
      assert_equal false, saved.dig("scope", "complete")
      assert_equal false, progress.fetch("discovery_complete")
      assert_equal 1, progress.fetch("discovery_next_page")
      assert_equal [], progress.fetch("discovered_merged_prs")
    end
  end

  def test_collection_fails_closed_when_later_page_changes_during_discovery
    Dir.mktmpdir("autonomous-merge-calibration-moving-later-page") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_two_reads = 0
      api = lambda do |path|
        case path
        when discovery_path("example/one", page: 1, per_page: 2)
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when discovery_path("example/one", page: 2, per_page: 2)
          page_two_reads += 1
          if page_two_reads == 1
            [list_entry(6, "2026-07-19T00:00:00Z"), list_entry(5, "2026-07-18T00:00:00Z")]
          else
            [list_entry(6, "2026-07-19T00:00:00Z"), list_entry(4, "2026-07-17T00:00:00Z")]
          end
        when discovery_path("example/one", page: 3, per_page: 2)
          []
        else
          raise "unexpected API path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          since: Date.new(2027, 1, 1),
          page_size: 2,
          api:
        )
      end
      saved = JSON.parse(File.read(checkpoint))
      progress = saved.dig("scope", "repository_progress", "example/one")

      assert_equal "pagination", error.kind
      assert_includes error.message, "changed while paginating"
      assert_equal 2, page_two_reads
      assert_equal false, saved.dig("scope", "complete")
      assert_equal false, progress.fetch("discovery_complete")
      assert_equal 1, progress.fetch("discovery_next_page")
      assert_equal [], progress.fetch("discovered_merged_prs")
    end
  end

  def test_verification_pagination_failure_checkpoints_restart_from_page_one
    Dir.mktmpdir("autonomous-merge-calibration-verification-failure") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_two_reads = 0
      api = lambda do |path|
        case path
        when discovery_path("example/one", page: 1, per_page: 2)
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when discovery_path("example/one", page: 2, per_page: 2)
          page_two_reads += 1
          unless page_two_reads == 1
            raise AutonomousMergeCalibration::RateLimitError, "verification rate limit exhausted"
          end

          [list_entry(6, "2026-07-19T00:00:00Z"), list_entry(5, "2026-07-18T00:00:00Z")]
        when discovery_path("example/one", page: 3, per_page: 2)
          []
        else
          raise "unexpected API path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::RateLimitError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          since: Date.new(2027, 1, 1),
          page_size: 2,
          api:
        )
      end
      saved = JSON.parse(File.read(checkpoint))
      progress = saved.dig("scope", "repository_progress", "example/one")

      assert_includes error.message, "verification rate limit"
      assert_equal "rate-limit", saved.dig("scope", "last_error", "kind")
      assert_equal false, saved.dig("scope", "complete")
      assert_equal false, progress.fetch("discovery_complete")
      assert_equal 1, progress.fetch("discovery_next_page")
      assert_equal [], progress.fetch("discovered_merged_prs")
    end
  end

  def test_collection_fails_closed_and_checkpoints_malformed_pagination
    Dir.mktmpdir("autonomous-merge-calibration-pagination") do |root|
      checkpoint = File.join(root, "dataset.json")
      api = mapped_api(
        {
          discovery_path("example/one", page: 1, per_page: 100) => [
            list_entry(7, "2026-07-20T00:00:00Z")
          ],
          "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z"),
          page_path("example/one", 7, "files", 1, 100) => { "not" => "a list" }
        }
      )

      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          since: Date.new(2026, 7, 1),
          api:
        )
      end
      checkpoint_data = JSON.parse(File.read(checkpoint, encoding: "UTF-8"))

      assert_includes error.message, "pagination"
      assert_equal false, checkpoint_data.dig("scope", "complete")
      assert_equal "pagination", checkpoint_data.dig("scope", "last_error", "kind")
    end
  end

  def test_checkpoint_cannot_claim_completed_pr_detail_that_is_missing
    Dir.mktmpdir("autonomous-merge-calibration-incomplete-checkpoint") do |root|
      checkpoint = File.join(root, "dataset.json")
      request = AutonomousMergeCalibration.collection_request(
        repositories: ["example/one"],
        since: nil,
        pr_count: 1,
        page_size: 100
      )
      dataset = AutonomousMergeCalibration.load_or_initialize_checkpoint(checkpoint, request)
      progress = dataset.dig("scope", "repository_progress", "example/one")
      progress["discovery_complete"] = true
      progress["selected_pr_numbers"] = [7]
      progress["completed_pr_numbers"] = [7]
      dataset.fetch("scope")["complete"] = true
      File.write(checkpoint, JSON.generate(dataset))

      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 1,
          api: ->(path) { raise "unexpected API path #{path}" }
        )
      end

      assert_equal "checkpoint", error.kind
      assert_includes error.message, "completed PR detail is missing"
    end
  end

  def test_collection_cli_writes_the_explicit_checkpoint_and_emits_no_merge_decisions
    Dir.mktmpdir("autonomous-merge-calibration-cli") do |root|
      checkpoint = File.join(root, "dataset.json")
      fake_gh = File.join(root, "fake-gh")
      File.write(fake_gh, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        path = ARGV.last
        body = case path
               when "repos/example/one/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1"
                 [{ "number" => 7, "merged_at" => "2026-07-20T00:00:00Z" }]
               when "repos/example/one/pulls/7"
                 { "number" => 7, "merged_at" => "2026-07-20T00:00:00Z" }
               when "repos/example/one/pulls/7/files?per_page=100&page=1"
                 [{ "filename" => "lib/service.rb", "additions" => 2, "deletions" => 1 }]
               when "repos/example/one/pulls/7/commits?per_page=100&page=1"
                 [{ "sha" => "7" * 40 }]
               when "repos/example/one/pulls/7/reviews?per_page=100&page=1"
                 []
               else
                 warn "unexpected path #{path}"
                 exit 1
               end
        print "HTTP/2 200\nx-ratelimit-remaining: 99\n\n#{JSON.generate(body)}"
      RUBY
      File.chmod(0o755, fake_gh)

      stdout, stderr, status = Open3.capture3(
        { "AUTONOMOUS_MERGE_GH" => fake_gh },
        "ruby", SCRIPT,
        "--collect", checkpoint,
        "--repo", "example/one",
        "--pr-count", "1"
      )
      assert status.success?, stderr
      emitted = JSON.parse(stdout)
      saved = JSON.parse(File.read(checkpoint, encoding: "UTF-8"))

      assert emitted.dig("scope", "complete")
      assert_equal false, emitted.fetch("merge_decisions_emitted")
      assert_equal emitted, saved
      collected_numbers = saved.fetch("prs").map { |entry| entry.fetch("number") }
      assert_equal [7], collected_numbers
    end
  end

  private

  def mapped_api(responses, calls: [])
    lambda do |path|
      calls << path
      raise "unexpected API path #{path}" unless responses.key?(path)

      responses.fetch(path)
    end
  end

  def discovery_path(repository, page:, per_page:)
    "repos/#{repository}/pulls?state=closed&sort=updated&direction=desc&per_page=#{per_page}&page=#{page}"
  end

  def page_path(repository, number, collection, page, per_page)
    "repos/#{repository}/pulls/#{number}/#{collection}?per_page=#{per_page}&page=#{page}"
  end

  def list_entry(number, merged_at)
    { "number" => number, "merged_at" => merged_at }
  end

  def detail(number, merged_at)
    { "number" => number, "merged_at" => merged_at }
  end

  def github_file(path, additions: 0, deletions: 0)
    { "filename" => path, "additions" => additions, "deletions" => deletions }
  end

  def github_review(state, commit_id)
    {
      "state" => state,
      "commit_id" => commit_id,
      "user" => { "login" => "reviewer", "type" => "User" },
      "submitted_at" => state == "PENDING" ? nil : "2026-07-20T01:00:00Z"
    }
  end

  def pr(repository, number, files:, lines:, commits:, reviewed_heads:, path_categories: [])
    {
      "repository" => repository,
      "number" => number,
      "merged_at" => "2026-07-01T00:00:00Z",
      "changed_files" => files,
      "changed_lines" => lines,
      "commits" => commits,
      "reviewed_heads" => reviewed_heads,
      "automation_reviewed_heads" => reviewed_heads.nil? ? nil : [reviewed_heads - 1, 0].max,
      "path_categories" => path_categories
    }
  end
end
