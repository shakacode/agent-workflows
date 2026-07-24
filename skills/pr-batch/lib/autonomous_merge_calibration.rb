# frozen_string_literal: true

require "date"
require "json"
require "open3"
require "tempfile"

module AutonomousMergeCalibration
  SUBMITTED_REVIEW_STATES = %w[APPROVED CHANGES_REQUESTED COMMENTED DISMISSED].freeze

  class CollectionError < StandardError
    attr_reader :kind

    def initialize(message, kind: "api")
      @kind = kind
      super(message)
    end
  end

  class RateLimitError < CollectionError
    def initialize(message = "GitHub API rate limit exhausted")
      super(message, kind: "rate-limit")
    end
  end

  class GitHubClient
    def initialize(command: ENV.fetch("AUTONOMOUS_MERGE_GH", "gh"))
      @command = command
      @exhausted = false
    end

    def call(path)
      raise RateLimitError if @exhausted

      stdout, stderr, status = Open3.capture3(@command, "api", "--include", path)
      unless status.success?
        detail = stderr.lines.first.to_s.strip
        if detail.match?(/rate.?limit/i)
          raise RateLimitError, "GitHub API rate limit exhausted for #{path}: #{detail}"
        end

        raise CollectionError.new("GitHub API failed for #{path}: #{detail}", kind: "api")
      end

      header_text, body = stdout.split(/\r?\n\r?\n/, 2)
      unless body
        raise CollectionError.new("GitHub API response omitted headers for #{path}", kind: "api")
      end

      headers = header_text.lines.filter_map do |line|
        key, value = line.split(":", 2)
        [key.strip.downcase, value.strip] if value
      end.to_h
      @exhausted = headers["x-ratelimit-remaining"] == "0"
      JSON.parse(body)
    rescue Errno::ENOENT
      raise CollectionError.new("GitHub CLI is unavailable", kind: "api")
    rescue JSON::ParserError => e
      raise CollectionError.new("GitHub API returned malformed JSON for #{path}: #{e.message}", kind: "api")
    end
  end

  module_function

  def collect(checkpoint_path:, repositories:, since: nil, pr_count: nil, page_size: 100,
              api: GitHubClient.new.method(:call))
    request = collection_request(repositories:, since:, pr_count:, page_size:)
    dataset = load_or_initialize_checkpoint(checkpoint_path, request)

    begin
      request.fetch("repositories").each do |repository|
        discover_repository!(dataset, repository, request, api, checkpoint_path)
        collect_repository!(dataset, repository, request, api, checkpoint_path)
      end
      dataset.fetch("scope")["complete"] = dataset.dig("scope", "repository_progress").all? do |_repo, progress|
        progress["discovery_complete"] == true &&
          progress.fetch("selected_pr_numbers").sort == progress.fetch("completed_pr_numbers").sort
      end
      dataset.fetch("scope").delete("last_error")
      normalize_dataset!(dataset)
      write_checkpoint(checkpoint_path, dataset)
      dataset
    rescue CollectionError => e
      checkpoint_failure!(dataset, checkpoint_path, e)
      raise
    rescue StandardError => e
      wrapped = CollectionError.new("GitHub calibration collection failed: #{e.message}", kind: "api")
      checkpoint_failure!(dataset, checkpoint_path, wrapped)
      raise wrapped
    end
  end

  def collection_request(repositories:, since:, pr_count:, page_size:)
    unless repositories.is_a?(Array) && !repositories.empty? &&
           repositories.all? { |repo| repo.is_a?(String) && repo.match?(%r{\A[^/\s]+/[^/\s]+\z}) }
      raise CollectionError.new("collection requires one or more OWNER/REPO values", kind: "input")
    end

    unique_repositories = repositories.uniq.length == repositories.length
    raise CollectionError.new("collection repositories must be unique", kind: "input") unless unique_repositories
    if since.nil? == pr_count.nil?
      raise CollectionError.new("collection requires exactly one of --since or --pr-count", kind: "input")
    end
    unless pr_count.nil? || (pr_count.is_a?(Integer) && pr_count.positive?)
      raise CollectionError.new("--pr-count must be positive", kind: "input")
    end
    unless page_size.is_a?(Integer) && page_size.positive? && page_size <= 100
      raise CollectionError.new("page size must be between 1 and 100", kind: "input")
    end

    normalized_since = since&.then { |value| value.is_a?(Date) ? value : Date.iso8601(value.to_s) }
    {
      "repositories" => repositories.sort,
      "mode" => normalized_since ? "since" : "pr-count",
      "value" => normalized_since ? normalized_since.iso8601 : pr_count,
      "page_size" => page_size
    }
  rescue Date::Error => e
    raise CollectionError.new("invalid --since date: #{e.message}", kind: "input")
  end

  def load_or_initialize_checkpoint(path, request)
    if File.exist?(path)
      dataset = JSON.parse(File.read(path, encoding: "UTF-8"))
      validate_checkpoint!(dataset, request)
      dataset.dig("scope", "repository_progress").each_value do |progress|
        reset_discovery_progress!(progress) unless progress.fetch("discovery_complete")
      end
      return dataset
    end

    {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => false,
        "window" => window_description(request),
        "repositories" => request.fetch("repositories"),
        "request" => request,
        "repository_progress" => request.fetch("repositories").to_h do |repository|
          [
            repository,
            {
              "discovery_complete" => false,
              "discovery_next_page" => 1,
              "discovered_merged_prs" => [],
              "selected_pr_numbers" => [],
              "completed_pr_numbers" => []
            }
          ]
        end
      },
      "prs" => [],
      "merge_decisions_emitted" => false
    }
  rescue JSON::ParserError => e
    raise CollectionError.new("checkpoint is malformed JSON: #{e.message}", kind: "checkpoint")
  end

  def validate_checkpoint!(dataset, request)
    valid = dataset.is_a?(Hash) &&
            dataset["contract"] == "autonomous-merge-calibration-dataset" &&
            dataset["version"] == 1 &&
            dataset["merge_decisions_emitted"] == false &&
            dataset["scope"].is_a?(Hash) &&
            [true, false].include?(dataset.dig("scope", "complete")) &&
            dataset.dig("scope", "request") == request &&
            dataset.dig("scope", "repositories") == request.fetch("repositories") &&
            dataset.dig("scope", "repository_progress").is_a?(Hash) &&
            dataset["prs"].is_a?(Array)
    unless valid
      raise CollectionError.new(
        "checkpoint contract or collection request does not match this invocation",
        kind: "checkpoint"
      )
    end

    request.fetch("repositories").each do |repository|
      progress = dataset.dig("scope", "repository_progress", repository)
      valid_progress = progress.is_a?(Hash) &&
                       [true, false].include?(progress["discovery_complete"]) &&
                       progress["discovery_next_page"].is_a?(Integer) &&
                       progress["discovery_next_page"].positive? &&
                       progress["discovered_merged_prs"].is_a?(Array) &&
                       progress["selected_pr_numbers"].is_a?(Array) &&
                       progress["completed_pr_numbers"].is_a?(Array) &&
                       valid_pr_number_list?(progress["selected_pr_numbers"]) &&
                       valid_pr_number_list?(progress["completed_pr_numbers"])
      next if valid_progress

      raise CollectionError.new("checkpoint progress is malformed for #{repository}", kind: "checkpoint")
    end

    completed_keys = request.fetch("repositories").flat_map do |repository|
      dataset.dig("scope", "repository_progress", repository, "completed_pr_numbers").map do |number|
        [repository, number]
      end
    end
    cached_keys = dataset.fetch("prs").filter_map do |entry|
      [entry["repository"], entry["number"]] if entry.is_a?(Hash) &&
                                                entry["repository"].is_a?(String) &&
                                                entry["number"].is_a?(Integer) &&
                                                entry["number"].positive?
    end
    unless cached_keys.length == dataset.fetch("prs").length && cached_keys.uniq.length == cached_keys.length
      raise CollectionError.new("checkpoint PR detail cache is malformed", kind: "checkpoint")
    end

    missing_keys = completed_keys - cached_keys
    unless missing_keys.empty?
      label = missing_keys.map { |repository, number| "#{repository}##{number}" }.join(", ")
      raise CollectionError.new("checkpoint completed PR detail is missing for #{label}", kind: "checkpoint")
    end

    claimed_complete = dataset.dig("scope", "complete")
    computed_complete = request.fetch("repositories").all? do |repository|
      progress = dataset.dig("scope", "repository_progress", repository)
      progress.fetch("discovery_complete") &&
        progress.fetch("selected_pr_numbers").sort == progress.fetch("completed_pr_numbers").sort
    end
    return unless claimed_complete && !computed_complete

    raise CollectionError.new("checkpoint scope.complete claim is inconsistent", kind: "checkpoint")
  end

  def valid_pr_number_list?(value)
    value.all? { |number| number.is_a?(Integer) && number.positive? } && value.uniq.length == value.length
  end

  def window_description(request)
    if request.fetch("mode") == "since"
      "merged since #{request.fetch('value')}"
    else
      "latest #{request.fetch('value')} merged PRs per repository"
    end
  end

  def discover_repository!(dataset, repository, request, api, checkpoint_path)
    progress = dataset.dig("scope", "repository_progress", repository)
    return if progress.fetch("discovery_complete")

    page_size = request.fetch("page_size")
    initial_snapshot = []
    loop do
      page = progress.fetch("discovery_next_page")
      path = discovery_page_path(repository, page_size, page)
      response = validate_discovery_page(api.call(path), path)
      initial_snapshot.concat(discovery_snapshot(response))

      response.each do |pull|
        next if pull["merged_at"].nil?

        begin
          DateTime.iso8601(pull.fetch("merged_at"))
        rescue Date::Error
          raise CollectionError.new("merged_at is malformed for #{repository}##{pull['number']}", kind: "pagination")
        end
        progress.fetch("discovered_merged_prs") << {
          "number" => pull.fetch("number"),
          "merged_at" => pull.fetch("merged_at")
        }
      end
      progress["discovered_merged_prs"].uniq! { |pull| pull.fetch("number") }
      progress["discovery_next_page"] = page + 1
      if response.length < page_size
        begin
          validate_discovery_snapshot!(initial_snapshot, repository)
          verified_snapshot = fetch_complete_discovery_snapshot(repository, page_size, api)
        rescue StandardError
          reset_discovery_progress!(progress)
          raise
        end
        unless verified_snapshot == initial_snapshot
          reset_discovery_progress!(progress)
          raise CollectionError.new(
            "closed-PR order changed while paginating #{repository}; discovery must restart from page 1",
            kind: "pagination"
          )
        end
        progress["discovery_complete"] = true
        progress["selected_pr_numbers"] = select_pr_numbers(progress, request)
      end
      normalize_dataset!(dataset)
      write_checkpoint(checkpoint_path, dataset)
      break if progress.fetch("discovery_complete")
    end
  end

  def fetch_complete_discovery_snapshot(repository, page_size, api)
    snapshot = []
    page = 1
    loop do
      path = discovery_page_path(repository, page_size, page)
      response = validate_discovery_page(api.call(path), path)
      snapshot.concat(discovery_snapshot(response))
      break if response.length < page_size

      page += 1
    end
    validate_discovery_snapshot!(snapshot, repository)
    snapshot
  end

  def discovery_page_path(repository, page_size, page)
    "repos/#{repository}/pulls?state=closed&sort=updated&direction=desc" \
      "&per_page=#{page_size}&page=#{page}"
  end

  def validate_discovery_page(response, path)
    unless response.is_a?(Array)
      raise CollectionError.new("pagination response is not a list for #{path}", kind: "pagination")
    end

    response.each do |pull|
      unless pull.is_a?(Hash) && pull["number"].is_a?(Integer) && pull["number"].positive? &&
             (pull["merged_at"].nil? || pull["merged_at"].is_a?(String))
        raise CollectionError.new("pagination entry is malformed for #{path}", kind: "pagination")
      end
    end
    response
  end

  def discovery_snapshot(response)
    response.map { |pull| [pull.fetch("number"), pull["merged_at"]] }
  end

  def validate_discovery_snapshot!(snapshot, repository)
    numbers = snapshot.map(&:first)
    return if numbers.uniq.length == numbers.length

    raise CollectionError.new(
      "closed-PR pagination repeated an entry for #{repository}; discovery must restart from page 1",
      kind: "pagination"
    )
  end

  def reset_discovery_progress!(progress)
    progress["discovery_complete"] = false
    progress["discovery_next_page"] = 1
    progress["discovered_merged_prs"] = []
    progress["selected_pr_numbers"] = []
  end

  def select_pr_numbers(progress, request)
    pulls = progress.fetch("discovered_merged_prs")
    selected = if request.fetch("mode") == "since"
                 boundary = Date.iso8601(request.fetch("value"))
                 pulls.select { |pull| DateTime.iso8601(pull.fetch("merged_at")).to_date >= boundary }
               else
                 pulls.sort_by { |pull| DateTime.iso8601(pull.fetch("merged_at")) }
                      .reverse
                      .first(request.fetch("value"))
               end
    selected.map { |pull| pull.fetch("number") }.uniq
  end

  def collect_repository!(dataset, repository, request, api, checkpoint_path)
    progress = dataset.dig("scope", "repository_progress", repository)
    progress.fetch("selected_pr_numbers").each do |number|
      next if progress.fetch("completed_pr_numbers").include?(number)

      collected = collect_pr(repository, number, request.fetch("page_size"), api)
      dataset.fetch("prs").reject! do |entry|
        entry["repository"] == repository && entry["number"] == number
      end
      dataset.fetch("prs") << collected
      progress.fetch("completed_pr_numbers") << number
      normalize_dataset!(dataset)
      write_checkpoint(checkpoint_path, dataset)
    end
  end

  def collect_pr(repository, number, page_size, api)
    detail_path = "repos/#{repository}/pulls/#{number}"
    detail = api.call(detail_path)
    unless detail.is_a?(Hash) && detail["number"] == number && detail["merged_at"].is_a?(String)
      raise CollectionError.new("GitHub PR detail is malformed for #{repository}##{number}", kind: "api")
    end

    begin
      DateTime.iso8601(detail.fetch("merged_at"))
    rescue Date::Error
      raise CollectionError.new("GitHub PR merged_at is malformed for #{repository}##{number}", kind: "api")
    end

    files = paginate(api, "#{detail_path}/files", page_size).map { |file| normalize_file(file) }
    commits = paginate(api, "#{detail_path}/commits", page_size).map { |commit| normalize_commit(commit) }
    reviews = paginate(api, "#{detail_path}/reviews", page_size).map { |review| normalize_review(review) }
    submitted = reviews.select { |review| SUBMITTED_REVIEW_STATES.include?(review.fetch("state")) }
    reviewed_head_shas = submitted.filter_map { |review| review["commit_id"] }.uniq.sort
    review_history_complete = submitted.none? { |review| review["commit_id"].nil? }
    automated = submitted.select { |review| automated_reviewer?(review) }
    automated_history_complete = automated.none? { |review| review["commit_id"].nil? }

    {
      "repository" => repository,
      "number" => number,
      "merged_at" => detail.fetch("merged_at"),
      "changed_files" => files.length,
      "changed_lines" => files.sum { |file| file.fetch("additions") + file.fetch("deletions") },
      "commits" => commits.length,
      "reviewed_heads" => review_history_complete ? reviewed_head_shas.length : nil,
      "automation_reviewed_heads" => if automated_history_complete
                                       automated.filter_map { |review| review["commit_id"] }.uniq.length
                                     end,
      "review_head_history_complete" => review_history_complete,
      "reviewed_head_shas" => reviewed_head_shas,
      "file_paths" => files.map { |file| file.fetch("path") },
      "commit_shas" => commits.map { |commit| commit.fetch("sha") },
      "reviews" => reviews,
      "path_categories" => files.map { |file| file.fetch("path").split("/").first }.uniq.sort,
      "semantic_inspection" => nil
    }
  end

  def paginate(api, path, page_size)
    values = []
    page = 1
    loop do
      request_path = "#{path}?per_page=#{page_size}&page=#{page}"
      response = api.call(request_path)
      unless response.is_a?(Array)
        raise CollectionError.new("pagination response is not a list for #{request_path}", kind: "pagination")
      end

      values.concat(response)
      break if response.length < page_size

      page += 1
    end
    values
  end

  def normalize_file(file)
    unless file.is_a?(Hash) && file["filename"].is_a?(String) && !file["filename"].empty? &&
           file["additions"].is_a?(Integer) && file["additions"] >= 0 &&
           file["deletions"].is_a?(Integer) && file["deletions"] >= 0
      raise CollectionError.new("GitHub file evidence is malformed", kind: "api")
    end

    {
      "path" => file.fetch("filename"),
      "additions" => file.fetch("additions"),
      "deletions" => file.fetch("deletions")
    }
  end

  def normalize_commit(commit)
    sha = commit["sha"] if commit.is_a?(Hash)
    unless full_sha?(sha)
      raise CollectionError.new("GitHub commit requires a full hexadecimal SHA", kind: "api")
    end

    { "sha" => sha }
  end

  def normalize_review(review)
    unless review.is_a?(Hash) && review["state"].is_a?(String) &&
           (review["commit_id"].nil? || review["commit_id"].is_a?(String))
      raise CollectionError.new("GitHub review evidence is malformed", kind: "api")
    end

    state = review.fetch("state")
    commit_id = review["commit_id"]
    if SUBMITTED_REVIEW_STATES.include?(state) && !commit_id.nil? && !full_sha?(commit_id)
      raise CollectionError.new(
        "GitHub submitted-review commit_id requires a full hexadecimal SHA",
        kind: "api"
      )
    end
    user = review["user"]
    unless user.is_a?(Hash) && user["login"].is_a?(String) && user["type"].is_a?(String)
      raise CollectionError.new("GitHub review author evidence is malformed", kind: "api")
    end

    {
      "id" => review["id"],
      "state" => state,
      "commit_id" => commit_id,
      "submitted_at" => review["submitted_at"],
      "author" => user.fetch("login"),
      "author_type" => user.fetch("type")
    }
  end

  def automated_reviewer?(review)
    review.fetch("author_type").casecmp?("Bot") || review.fetch("author").match?(/\[bot\]\z/i)
  end

  def full_sha?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-fA-F]{40}\z/)
  end

  def checkpoint_failure!(dataset, path, error)
    dataset.fetch("scope")["complete"] = false
    dataset.fetch("scope")["last_error"] = {
      "kind" => error.kind,
      "message" => error.message
    }
    dataset["merge_decisions_emitted"] = false
    normalize_dataset!(dataset)
    write_checkpoint(path, dataset)
  end

  def normalize_dataset!(dataset)
    dataset.fetch("prs").sort_by! { |entry| [entry.fetch("repository"), entry.fetch("number")] }
    dataset.dig("scope", "repository_progress").each_value do |progress|
      progress.fetch("discovered_merged_prs").sort_by! { |pull| pull.fetch("number") }
      progress.fetch("completed_pr_numbers").uniq!
      progress.fetch("completed_pr_numbers").sort!
    end
    dataset
  end

  def write_checkpoint(path, dataset)
    expanded = File.expand_path(path)
    directory = File.dirname(expanded)
    unless Dir.exist?(directory)
      raise CollectionError.new("checkpoint parent directory does not exist: #{directory}", kind: "checkpoint")
    end

    Tempfile.create([".autonomous-merge-calibration", ".tmp"], directory, encoding: "UTF-8") do |file|
      file.chmod(0o600)
      file.write("#{JSON.pretty_generate(dataset)}\n")
      file.flush
      file.fsync
      temporary_path = file.path
      file.close
      File.rename(temporary_path, expanded)
    end
  rescue SystemCallError => e
    raise CollectionError.new("cannot write calibration checkpoint: #{e.message}", kind: "checkpoint")
  end
end
