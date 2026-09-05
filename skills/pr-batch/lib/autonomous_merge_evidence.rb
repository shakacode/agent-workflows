# frozen_string_literal: true

require "json"
require "open3"
require "time"

module AutonomousMergeEvidence
  class CollectionError < StandardError; end

  SUBMITTED_REVIEW_STATES = %w[APPROVED CHANGES_REQUESTED COMMENTED DISMISSED].freeze
  REVIEW_STATES = (SUBMITTED_REVIEW_STATES + ["PENDING"]).freeze
  FILE_STATUSES = %w[added removed modified renamed copied changed unchanged].freeze
  RENAME_STATUSES = %w[renamed copied].freeze
  FILES_API_CAP = 3_000
  COMMITS_API_CAP = 250

  module_function

  def collect(repo:, pr_number:, api: method(:gh_api))
    raise CollectionError, "repository must use OWNER/REPO form" unless repo.match?(%r{\A[^/\s]+/[^/\s]+\z})
    unless pr_number.is_a?(Integer) && pr_number.positive?
      raise CollectionError, "PR number must be positive"
    end

    prefix = "repos/#{repo}"
    initial = api.call("#{prefix}/pulls/#{pr_number}")
    raise CollectionError, "malformed GitHub PR detail" unless initial.is_a?(Hash)

    initial_changed_files = validate_changed_files!(initial, phase: "initial")
    initial_commits = validate_commits!(initial, phase: "initial")
    initial_force_push_watermark = force_push_watermark(
      paginate(api, "#{prefix}/issues/#{pr_number}/timeline")
    )
    files = paginate(api, "#{prefix}/pulls/#{pr_number}/files")
    commits = paginate(api, "#{prefix}/pulls/#{pr_number}/commits")
    reviews = paginate(api, "#{prefix}/pulls/#{pr_number}/reviews")
    comments = paginate(api, "#{prefix}/issues/#{pr_number}/comments")
    final_force_push_watermark = force_push_watermark(
      paginate(api, "#{prefix}/issues/#{pr_number}/timeline")
    )
    final = api.call("#{prefix}/pulls/#{pr_number}")
    raise CollectionError, "malformed GitHub PR detail" unless final.is_a?(Hash)

    final_changed_files = validate_changed_files!(final, phase: "final")
    final_commits = validate_commits!(final, phase: "final")
    initial_updated_at = initial["updated_at"]
    final_updated_at = final["updated_at"]
    unless github_timestamp?(initial_updated_at) && github_timestamp?(final_updated_at)
      raise CollectionError, "GitHub PR updated_at must be an ISO 8601 timestamp"
    end
    unless final_updated_at == initial_updated_at
      raise CollectionError, "PR updated during evidence collection"
    end

    initial_head = initial.dig("head", "sha")
    initial_base = initial.dig("base", "sha")
    initial_base_ref = initial.dig("base", "ref")
    unless full_sha?(initial_head) && full_sha?(initial_base) &&
           initial_base_ref.is_a?(String) && !initial_base_ref.strip.empty? &&
           final.dig("head", "sha") == initial_head && final.dig("base", "sha") == initial_base &&
           final.dig("base", "ref") == initial_base_ref
      raise CollectionError, "head or base moved during evidence collection"
    end

    unless final_force_push_watermark == initial_force_push_watermark
      raise CollectionError, "force-push watermark changed during evidence collection"
    end
    unless final_changed_files == initial_changed_files
      raise CollectionError, "PR changed_files changed during evidence collection"
    end
    unless final_commits == initial_commits
      raise CollectionError, "PR commits changed during evidence collection"
    end
    unless files.length == final_changed_files
      raise CollectionError,
            "listed file count (#{files.length}) does not match PR changed_files (#{final_changed_files})"
    end
    normalized_commits = commits.map { |commit| normalize_commit(commit) }
    commit_shas = normalized_commits.map { |commit| commit.fetch("sha") }
    unless commit_shas.uniq.length == commit_shas.length
      raise CollectionError, "GitHub commit SHAs must be unique"
    end
    unless normalized_commits.length == final_commits
      raise CollectionError,
            "listed commit count (#{normalized_commits.length}) does not match PR commits (#{final_commits})"
    end

    {
      "head_sha" => initial_head,
      "base_sha" => initial_base,
      "base_ref" => initial_base_ref,
      "files_complete" => true,
      "files" => files.map { |file| normalize_file(file) },
      "commits_complete" => true,
      "commits" => normalized_commits,
      "reviews_complete" => true,
      "reviews" => reviews.map { |review| normalize_review(review) },
      "decision_comments_complete" => true,
      "decision_comments" => comments.map { |comment| normalize_comment(comment) }
    }
  rescue CollectionError
    raise
  rescue KeyError, TypeError, JSON::ParserError => e
    raise CollectionError, "malformed GitHub evidence: #{e.message}"
  end

  def paginate(api, path)
    values = []
    page = 1
    loop do
      response = api.call("#{path}?per_page=100&page=#{page}")
      raise CollectionError, "paginated GitHub response is not a list: #{path}" unless response.is_a?(Array)

      values.concat(response)
      break if response.length < 100

      page += 1
    end
    values
  end

  def gh_api(path)
    command = ENV.fetch("AUTONOMOUS_MERGE_GH", "gh")
    stdout, stderr, status = Open3.capture3(command, "api", path)
    unless status.success?
      detail = stderr.lines.first.to_s.strip
      raise CollectionError, "GitHub API failed for #{path}: #{detail}"
    end

    JSON.parse(stdout)
  rescue Errno::ENOENT
    raise CollectionError, "GitHub CLI is unavailable"
  end

  def normalize_file(file)
    raise CollectionError, "malformed GitHub file evidence" unless file.is_a?(Hash)

    filename = file.fetch("filename")
    unless filename.is_a?(String) && !filename.strip.empty?
      raise CollectionError, "GitHub file filename must be a nonempty string"
    end

    status = file.fetch("status")
    unless status.is_a?(String) && FILE_STATUSES.include?(status)
      raise CollectionError, "GitHub file status is unrecognized"
    end

    additions = file.fetch("additions")
    deletions = file.fetch("deletions")
    unless additions.is_a?(Integer) && additions >= 0 && deletions.is_a?(Integer) && deletions >= 0
      raise CollectionError, "GitHub file line counts must be nonnegative integers"
    end

    normalized = {
      "path" => filename,
      "status" => status,
      "additions" => additions,
      "deletions" => deletions
    }
    if RENAME_STATUSES.include?(status)
      previous_path = file.fetch("previous_filename")
      unless previous_path.is_a?(String) && !previous_path.strip.empty?
        raise CollectionError, "GitHub #{status} file previous_filename must be a nonempty string"
      end

      normalized["previous_path"] = previous_path
    elsif !file["previous_filename"].nil?
      raise CollectionError, "GitHub file previous_filename requires renamed or copied status"
    end
    normalized
  end

  def validate_changed_files!(detail, phase:)
    changed_files = detail["changed_files"]
    unless changed_files.is_a?(Integer) && changed_files >= 0
      raise CollectionError, "GitHub PR #{phase} changed_files must be a nonnegative integer"
    end
    if changed_files >= FILES_API_CAP
      raise CollectionError,
            "GitHub PR #{phase} changed_files is at or above the Files API cap (#{FILES_API_CAP})"
    end

    changed_files
  end

  def validate_commits!(detail, phase:)
    commits = detail["commits"]
    unless commits.is_a?(Integer) && commits >= 0
      raise CollectionError, "GitHub PR #{phase} commits must be a nonnegative integer"
    end
    if commits >= COMMITS_API_CAP
      raise CollectionError,
            "GitHub PR #{phase} commits is at or above the Commits API cap (#{COMMITS_API_CAP})"
    end

    commits
  end

  def force_push_watermark(events)
    ids = events.filter_map do |event|
      raise CollectionError, "malformed GitHub timeline event" unless event.is_a?(Hash)

      event_type = event["event"]
      raise CollectionError, "GitHub timeline event type must be a string" unless event_type.is_a?(String)
      next unless event_type == "head_ref_force_pushed"

      id = event["id"]
      unless id.is_a?(Integer) && id.positive?
        raise CollectionError, "GitHub force-push timeline event requires a positive integer ID"
      end

      id
    end
    if ids.uniq.length != ids.length
      raise CollectionError, "GitHub force-push timeline event IDs must be unique"
    end

    ids.sort
  end

  def normalize_comment(comment)
    raise CollectionError, "malformed GitHub comment evidence" unless comment.is_a?(Hash)

    author = comment["user"]
    login = author["login"] if author.is_a?(Hash)
    author_type = author["type"] if author.is_a?(Hash)
    unless login.is_a?(String) && !login.strip.empty?
      raise CollectionError, "GitHub comment author must contain a nonempty login"
    end

    {
      "id" => comment.fetch("id").to_s,
      "url" => comment.fetch("html_url"),
      "created_at" => comment.fetch("created_at"),
      "body" => comment.fetch("body"),
      "author" => login,
      "author_type" => author_type
    }
  end

  def normalize_commit(commit)
    raise CollectionError, "malformed GitHub commit evidence" unless commit.is_a?(Hash)

    sha = commit.fetch("sha")
    raise CollectionError, "GitHub commit requires a full hexadecimal SHA" unless full_sha?(sha)

    { "sha" => sha }
  end

  def normalize_review(review)
    raise CollectionError, "malformed GitHub review evidence" unless review.is_a?(Hash)

    state = review.fetch("state")
    commit_id = review["commit_id"]
    raise CollectionError, "GitHub review state must be a string" unless state.is_a?(String)
    unless REVIEW_STATES.include?(state)
      raise CollectionError, "GitHub review state is unrecognized"
    end
    unless commit_id.nil? || commit_id.is_a?(String)
      raise CollectionError, "GitHub review commit_id must be a string or null"
    end
    if SUBMITTED_REVIEW_STATES.include?(state) &&
       !commit_id.nil? && !full_sha?(commit_id)
      raise CollectionError, "GitHub submitted-review commit_id requires a full hexadecimal SHA"
    end

    { "state" => state, "commit_id" => commit_id }
  end

  def full_sha?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-fA-F]{40}\z/)
  end

  def github_timestamp?(value)
    return false unless value.is_a?(String)

    Time.iso8601(value)
    true
  rescue ArgumentError
    false
  end
end
