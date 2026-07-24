#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/autonomous_merge_evidence"

class AutonomousMergeEvidenceTest < Minitest::Test
  HEAD_SHA = "a" * 40
  BASE_SHA = "b" * 40
  UPDATED_AT = "2026-07-25T12:00:00Z"

  def test_collects_every_page_and_rechecks_exact_head_and_base
    calls = []
    api = lambda do |path|
      calls << path
      case path
      when "repos/example/repo/pulls/7"
        pull_detail
      when "repos/example/repo/issues/7/timeline?per_page=100&page=1"
        Array.new(100) { { "event" => "labeled" } }
      when "repos/example/repo/issues/7/timeline?per_page=100&page=2"
        [{ "id" => 41, "event" => "head_ref_force_pushed" }]
      when "repos/example/repo/pulls/7/files?per_page=100&page=1"
        Array.new(100) { |index| file("lib/file_#{index}.rb") }
      when "repos/example/repo/pulls/7/files?per_page=100&page=2"
        [file("lib/final.rb")]
      when "repos/example/repo/pulls/7/commits?per_page=100&page=1"
        [{ "sha" => "c" * 40 }]
      when "repos/example/repo/pulls/7/reviews?per_page=100&page=1"
        [{ "state" => "COMMENTED", "commit_id" => HEAD_SHA }]
      when "repos/example/repo/issues/7/comments?per_page=100&page=1"
        []
      else
        raise "unexpected API path #{path}"
      end
    end

    objective = AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)

    assert_equal 101, objective.fetch("files").length
    assert_equal HEAD_SHA, objective.fetch("head_sha")
    assert_equal BASE_SHA, objective.fetch("base_sha")
    assert objective.fetch("files_complete")
    assert objective.fetch("commits_complete")
    assert objective.fetch("reviews_complete")
    assert objective.fetch("decision_comments_complete")
    assert_equal(2, calls.count { |path| path.include?("/files?") })
    assert_equal(2, calls.count { |path| path == "repos/example/repo/pulls/7" })
    assert_equal(2, calls.count { |path| path.include?("/timeline?per_page=100&page=2") })
  end

  def test_head_movement_during_collection_is_unknown
    reads = 0
    api = lambda do |path|
      if path == "repos/example/repo/pulls/7"
        reads += 1
        sha = reads == 1 ? HEAD_SHA : "d" * 40
        next(pull_detail(head_sha: sha))
      end
      []
    end

    error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
    end

    assert_includes error.message, "head or base moved during evidence collection"
  end

  def test_force_push_aba_during_collection_is_unknown_even_when_detail_timestamps_match
    detail_reads = 0
    timeline_reads = 0
    api = lambda do |path|
      case path
      when "repos/example/repo/pulls/7"
        detail_reads += 1
        {
          "head" => { "sha" => HEAD_SHA },
          "base" => { "sha" => BASE_SHA },
          "updated_at" => "2026-07-25T12:00:00Z"
        }
      when "repos/example/repo/issues/7/timeline?per_page=100&page=1"
        timeline_reads += 1
        timeline_reads == 1 ? [] : [{ "id" => 99, "event" => "head_ref_force_pushed" }]
      when %r{\Arepos/example/repo/(?:pulls/7/(?:files|commits|reviews)|issues/7/comments)\?}
        []
      else
        raise "unexpected API path #{path}"
      end
    end

    error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
    end

    assert_equal 2, detail_reads
    assert_includes error.message, "force-push watermark changed during evidence collection"
  end

  def test_concurrent_ordinary_pr_update_during_collection_is_unknown
    detail_reads = 0
    api = lambda do |path|
      case path
      when "repos/example/repo/pulls/7"
        detail_reads += 1
        {
          "head" => { "sha" => HEAD_SHA },
          "base" => { "sha" => BASE_SHA },
          "updated_at" => detail_reads == 1 ? "2026-07-25T12:00:00Z" : "2026-07-25T12:00:01Z"
        }
      when "repos/example/repo/issues/7/timeline?per_page=100&page=1"
        []
      when %r{\Arepos/example/repo/(?:pulls/7/(?:files|commits|reviews)|issues/7/comments)\?}
        []
      else
        raise "unexpected API path #{path}"
      end
    end

    error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
    end

    assert_includes error.message, "PR updated during evidence collection"
  end

  def test_collection_rejects_malformed_force_push_timeline_events
    malformed = [
      nil,
      { "event" => nil },
      { "event" => "head_ref_force_pushed" },
      { "id" => "99", "event" => "head_ref_force_pushed" }
    ]

    malformed.each do |event|
      complete = complete_api(commits: [], reviews: [])
      api = lambda do |path|
        if path == "repos/example/repo/issues/7/timeline?per_page=100&page=1"
          [event]
        else
          complete.call(path)
        end
      end

      assert_raises(AutonomousMergeEvidence::CollectionError) do
        AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
      end
    end
  end

  def test_collection_rejects_incomplete_timeline_pagination
    complete = complete_api(commits: [], reviews: [])
    api = lambda do |path|
      case path
      when "repos/example/repo/issues/7/timeline?per_page=100&page=1"
        Array.new(100) { { "event" => "labeled" } }
      when "repos/example/repo/issues/7/timeline?per_page=100&page=2"
        { "message" => "pagination unavailable" }
      else
        complete.call(path)
      end
    end

    error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
    end

    assert_includes error.message, "paginated GitHub response is not a list"
  end

  def test_collection_rejects_duplicate_force_push_ids_from_unstable_pagination
    complete = complete_api(commits: [], reviews: [])
    api = lambda do |path|
      if path == "repos/example/repo/issues/7/timeline?per_page=100&page=1"
        [
          { "id" => 99, "event" => "head_ref_force_pushed" },
          { "id" => 99, "event" => "head_ref_force_pushed" }
        ]
      else
        complete.call(path)
      end
    end

    error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
    end

    assert_includes error.message, "timeline event IDs must be unique"
  end

  def test_collection_rejects_missing_or_malformed_pr_updated_at
    [nil, 123, "not-a-timestamp"].each do |updated_at|
      complete = complete_api(commits: [], reviews: [])
      api = lambda do |path|
        path == "repos/example/repo/pulls/7" ? pull_detail(updated_at:) : complete.call(path)
      end

      error = assert_raises(AutonomousMergeEvidence::CollectionError) do
        AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
      end

      assert_includes error.message, "updated_at must be an ISO 8601 timestamp"
    end
  end

  def test_collection_rejects_malformed_commit_and_submitted_review_shas
    malformed_commit_api = complete_api(
      commits: [{ "sha" => "abc123" }],
      reviews: [{ "state" => "COMMENTED", "commit_id" => HEAD_SHA }]
    )
    malformed_review_api = complete_api(
      commits: [{ "sha" => "c" * 40 }],
      reviews: [{ "state" => "DISMISSED", "commit_id" => "abc123" }]
    )

    commit_error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api: malformed_commit_api)
    end
    review_error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api: malformed_review_api)
    end

    assert_includes commit_error.message, "full hexadecimal SHA"
    assert_includes review_error.message, "full hexadecimal SHA"
  end

  def test_collection_preserves_null_submitted_heads_and_ignores_pending_head_shape
    api = complete_api(
      commits: [{ "sha" => "c" * 40 }],
      reviews: [
        { "state" => "COMMENTED", "commit_id" => nil },
        { "state" => "PENDING", "commit_id" => "viewer-local-draft" }
      ]
    )

    objective = AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)

    assert_nil objective.fetch("reviews").first.fetch("commit_id")
    assert_equal "viewer-local-draft", objective.fetch("reviews").last.fetch("commit_id")
  end

  def test_collection_wraps_malformed_array_elements_as_collection_error
    error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(
        repo: "example/repo",
        pr_number: 7,
        api: complete_api(
          commits: [{ "sha" => "c" * 40 }],
          reviews: []
        ).then do |complete|
          lambda do |path|
            path.include?("/files?") ? [nil] : complete.call(path)
          end
        end
      )
    end

    assert_includes error.message, "malformed GitHub file evidence"
  end

  def test_collection_rejects_nullable_or_malformed_comment_author_as_collection_error
    [nil, [], {}, { "login" => nil }, { "login" => "" }, { "login" => " " }, { "login" => 123 }].each do |author|
      complete = complete_api(commits: [], reviews: [])
      api = lambda do |path|
        if path == "repos/example/repo/issues/7/comments?per_page=100&page=1"
          [
            {
              "id" => 123,
              "html_url" => "https://github.com/example/repo/pull/7#issuecomment-123",
              "created_at" => UPDATED_AT,
              "body" => "decision",
              "user" => author
            }
          ]
        else
          complete.call(path)
        end
      end

      error = assert_raises(AutonomousMergeEvidence::CollectionError) do
        AutonomousMergeEvidence.collect(repo: "example/repo", pr_number: 7, api:)
      end

      assert_includes error.message, "GitHub comment author"
    end
  end

  def test_collection_wraps_malformed_pull_detail_as_collection_error
    error = assert_raises(AutonomousMergeEvidence::CollectionError) do
      AutonomousMergeEvidence.collect(
        repo: "example/repo",
        pr_number: 7,
        api: ->(path) { path == "repos/example/repo/pulls/7" ? nil : [] }
      )
    end

    assert_includes error.message, "malformed GitHub PR detail"
  end

  private

  def complete_api(commits:, reviews:)
    lambda do |path|
      case path
      when "repos/example/repo/pulls/7"
        pull_detail
      when "repos/example/repo/issues/7/timeline?per_page=100&page=1"
        []
      when "repos/example/repo/pulls/7/files?per_page=100&page=1"
        [file("lib/service.rb")]
      when "repos/example/repo/pulls/7/commits?per_page=100&page=1"
        commits
      when "repos/example/repo/pulls/7/reviews?per_page=100&page=1"
        reviews
      when "repos/example/repo/issues/7/comments?per_page=100&page=1"
        []
      else
        raise "unexpected API path #{path}"
      end
    end
  end

  def file(path)
    { "filename" => path, "additions" => 1, "deletions" => 0 }
  end

  def pull_detail(head_sha: HEAD_SHA, updated_at: UPDATED_AT)
    {
      "head" => { "sha" => head_sha },
      "base" => { "sha" => BASE_SHA },
      "updated_at" => updated_at
    }
  end
end
