# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "yaml"

module HumanAttention
  DEFAULT_LABELS = {
    "walkthrough" => "human-attention:walkthrough",
    "merge" => "human-attention:merge"
  }.freeze
  STATES = %w[walkthrough merge].freeze
  REPOSITORY_PATTERN = %r{\A[^/\s]+/[^/\s]+\z}

  class Error < StandardError; end

  module_function

  def load_config(repo_root)
    path = File.join(File.expand_path(repo_root), ".agents", "agent-workflow.yml")
    parsed = YAML.safe_load_file(path, aliases: false) || {}
    raise Error, "agent workflow policy must be a mapping" unless parsed.is_a?(Hash)

    human_attention = parsed.fetch("human_attention", {})
    raise Error, "human_attention must be a mapping" unless human_attention.is_a?(Hash)

    human_attention
  rescue Errno::ENOENT, Psych::Exception => e
    raise Error, "cannot load agent workflow policy: #{e.message}"
  end

  def labels_for(config, repo)
    raise Error, "repository must use OWNER/REPO form" unless repo.match?(REPOSITORY_PATTERN)

    labels = DEFAULT_LABELS.merge(validate_labels(config.fetch("labels", {})))
    repositories = config.fetch("repositories", {})
    if repositories.is_a?(Hash) && repositories.key?(repo)
      entry = repositories.fetch(repo) || {}
      raise Error, "repository configuration for #{repo} must be a mapping" unless entry.is_a?(Hash)

      labels.merge!(validate_labels(entry.fetch("labels", {})))
    end
    raise Error, "human-attention labels must be distinct" if labels.values.uniq.length != labels.length

    labels
  end

  def repositories(config)
    configured = config.fetch("repositories", {})
    values = case configured
             when Hash then configured.keys
             when Array then configured
             else raise Error, "human_attention.repositories must be a mapping or list"
             end
    unless values.all? { |repo| repo.is_a?(String) && repo.match?(REPOSITORY_PATTERN) }
      raise Error, "every human-attention repository must use OWNER/REPO form"
    end

    values.uniq.sort
  end

  def classify(labels:, configured_labels:)
    matches = STATES.select { |state| labels.include?(configured_labels.fetch(state)) }
    raise Error, "a PR must not carry both human-attention labels" if matches.length > 1

    matches.first || "none"
  end

  def desk(config:, github_cli: ENV.fetch("HUMAN_ATTENTION_GH", "gh"), refreshed_at: Time.now.utc.iso8601)
    entries = []
    degraded = []
    repositories(config).each do |repo|
      labels = labels_for(config, repo)
      STATES.each do |state|
        stdout, _stderr, status = Open3.capture3(
          github_cli, "pr", "list", "--repo", repo, "--state", "open", "--label", labels.fetch(state),
          "--json", "number,title,url,updatedAt,headRefOid"
        )
        unless status.success?
          degraded << repo
          next
        end
        begin
          rows = JSON.parse(stdout)
          raise Error, "query result is not a list" unless rows.is_a?(Array)

          rows.each do |row|
            entries << normalize_entry(row, repo:, state:, refreshed_at:)
          end
        rescue JSON::ParserError, Error
          degraded << repo
        end
      end
    end
    duplicate_targets = entries.group_by { |entry| [entry.fetch("repo"), entry.fetch("number")] }
                               .select { |_target, rows| rows.map { |row| row.fetch("state") }.uniq.length > 1 }
    raise Error, "a PR must not carry both human-attention labels" unless duplicate_targets.empty?

    [entries.sort_by { |entry| [entry.fetch("repo"), entry.fetch("number"), entry.fetch("state")] }, degraded.uniq.sort]
  end

  def render_desk(entries, degraded)
    noun = entries.length == 1 ? "decision" : "decisions"
    lines = ["# Human Attention", "", "#{entries.length} human #{noun}.",
             "This queue does not represent remaining agent-owned work.", ""]
    entries.each_with_index do |entry, index|
      action = entry.fetch("state").upcase
      reason = if action == "WALKTHROUGH"
                 "Review the complete exact-head walkthrough."
               else
                 "Choose whether to merge after all ordinary gates passed."
               end
      lines.concat([
                     "## #{index + 1} of #{entries.length} — #{action} — #{entry.fetch('repo')} — #{entry.fetch('title')}",
                     "", "- PR: #{entry.fetch('url')}", "- Reason: #{reason}",
                     "- Exact head: `#{entry.fetch('head_sha')}`", "- Refreshed: #{entry.fetch('refreshed_at')}", ""
                   ])
    end
    lines << "Degraded repositories: #{degraded.join(', ')}" unless degraded.empty?
    "#{lines.join("\n").rstrip}\n"
  end

  def transition(config:, repo:, pr_number:, state:, expected_head:,
                 github_cli: ENV.fetch("HUMAN_ATTENTION_GH", "gh"))
    raise Error, "state must be walkthrough, merge, or none" unless (STATES + ["none"]).include?(state)
    raise Error, "PR number must be positive" unless pr_number.is_a?(Integer) && pr_number.positive?
    raise Error, "expected head must be a full lowercase SHA" unless expected_head.match?(/\A[0-9a-f]{40}\z/)

    labels = labels_for(config, repo)
    stdout, stderr, status = Open3.capture3(
      github_cli, "pr", "view", pr_number.to_s, "--repo", repo, "--json", "state,headRefOid,labels"
    )
    raise Error, "cannot read PR state: #{stderr.lines.first.to_s.strip}" unless status.success?

    detail = JSON.parse(stdout)
    raise Error, "PR is not open" unless detail["state"] == "OPEN"
    raise Error, "PR head changed" unless detail["headRefOid"] == expected_head

    current = Array(detail["labels"]).filter_map { |label| label["name"] if label.is_a?(Hash) }
    classify(labels: current, configured_labels: labels)
    arguments = [github_cli, "pr", "edit", pr_number.to_s, "--repo", repo]
    labels.each do |semantic, label|
      desired = semantic == state
      arguments.concat(["--remove-label", label]) if !desired && current.include?(label)
      arguments.concat(["--add-label", label]) if desired && !current.include?(label)
    end
    if arguments.length > 6
      _edit_stdout, edit_stderr, edit_status = Open3.capture3(*arguments)
      raise Error, "cannot update human-attention labels: #{edit_stderr.lines.first.to_s.strip}" unless edit_status.success?
    end

    { "repo" => repo, "pr" => pr_number, "head_sha" => expected_head, "state" => state, "labels" => labels }
  rescue JSON::ParserError
    raise Error, "PR state response is malformed"
  end

  def validate_labels(value)
    raise Error, "human_attention labels must be a mapping" unless value.is_a?(Hash)

    unknown = value.keys - STATES
    raise Error, "unknown human-attention label keys: #{unknown.join(', ')}" unless unknown.empty?
    unless value.values.all? { |label| label.is_a?(String) && !label.strip.empty? && !label.include?("\n") }
      raise Error, "human-attention label names must be nonempty single-line strings"
    end

    value
  end

  def normalize_entry(row, repo:, state:, refreshed_at:)
    raise Error, "PR row must be a mapping" unless row.is_a?(Hash)

    number = row.fetch("number")
    title = row.fetch("title")
    url = row.fetch("url")
    head_sha = row.fetch("headRefOid")
    unless number.is_a?(Integer) && number.positive? && title.is_a?(String) && !title.empty? &&
           url.is_a?(String) && !url.empty? && head_sha.is_a?(String) && head_sha.match?(/\A[0-9a-f]{40}\z/)
      raise Error, "PR row is malformed"
    end

    { "repo" => repo, "number" => number, "title" => title, "url" => url, "state" => state,
      "head_sha" => head_sha, "refreshed_at" => refreshed_at }
  end
end
