# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "yaml"

module HumanAttention
  STATES = %w[walkthrough merge].freeze
  PR_LIST_LIMIT = 1000
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

  def global_labels(config)
    labels = validate_labels(config.fetch("labels", {}))
    missing = STATES - labels.keys
    unless missing.empty?
      raise Error, "human_attention labels must define walkthrough and merge"
    end
    if labels.values.map(&:downcase).uniq.length != labels.length
      raise Error, "human-attention labels must be distinct"
    end

    labels.dup
  end

  def labels_for(config, repo, base_labels: global_labels(config))
    raise Error, "repository must use OWNER/REPO form" unless repo.match?(REPOSITORY_PATTERN)

    labels = base_labels.dup
    repositories = config.fetch("repositories", {})
    if repositories.is_a?(Hash)
      matching_repositories = repositories.keys.select do |configured_repo|
        configured_repo.is_a?(String) && configured_repo.casecmp?(repo)
      end
      if matching_repositories.length > 1
        raise Error, "repository configuration for #{repo} is ambiguous"
      end

      repository_key = matching_repositories.first
    end
    if repository_key
      entry = repositories.fetch(repository_key) || {}
      raise Error, "repository configuration for #{repo} must be a mapping" unless entry.is_a?(Hash)

      labels.merge!(validate_labels(entry.fetch("labels", {})))
    end
    if labels.values.map(&:downcase).uniq.length != labels.length
      raise Error, "human-attention labels must be distinct"
    end

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
    unless values.map(&:downcase).uniq.length == values.length
      raise Error, "human-attention repositories must be unique ignoring case"
    end

    values.uniq.sort
  end

  def classify(labels:, configured_labels:)
    matches = STATES.select { |state| label_present?(labels, configured_labels.fetch(state)) }
    raise Error, "a PR must not carry both human-attention labels" if matches.length > 1

    matches.first || "none"
  end

  def label_present?(labels, configured_label)
    labels.any? { |label| label.is_a?(String) && label.casecmp?(configured_label) }
  end

  def desk(config:, github_cli: ENV.fetch("HUMAN_ATTENTION_GH", "gh"), refreshed_at: Time.now.utc.iso8601)
    entries = []
    degraded = []
    configured_repositories = repositories(config)
    base_labels = global_labels(config)
    configured_repositories.each do |repo|
      labels = labels_for(config, repo, base_labels:)
      stdout, _stderr, status = Open3.capture3(
        github_cli, "pr", "list", "--repo", repo, "--state", "open",
        "--limit", PR_LIST_LIMIT.to_s, "--json", "number,title,url,updatedAt,headRefOid,labels"
      )
      unless status.success?
        degraded << repo
        next
      end

      rows = JSON.parse(stdout)
      raise Error, "query result is not a list" unless rows.is_a?(Array)

      repo_entries = rows.filter_map do |row|
        row_labels = Array(row["labels"]).filter_map { |label| label["name"] if label.is_a?(Hash) }
        state = classify(labels: row_labels, configured_labels: labels)
        next if state == "none"

        normalize_entry(row, repo:, state:, refreshed_at:)
      rescue Error, KeyError
        degraded << repo
        nil
      end
      entries.concat(repo_entries)
    rescue JSON::ParserError, Error, KeyError
      degraded << repo
    end

    [entries.sort_by { |entry| [entry.fetch("repo"), entry.fetch("number"), entry.fetch("state")] }, degraded.uniq.sort]
  end

  def render_desk(entries, degraded)
    noun = entries.length == 1 ? "decision" : "decisions"
    lines = ["# Human Attention", "", "#{entries.length} human #{noun}.",
             "This queue does not represent remaining agent-owned work.", ""]
    entries.each_with_index do |entry, index|
      action = entry.fetch("state").upcase
      reason = if action == "WALKTHROUGH"
                 "Confirm the walkthrough matches the current head before review."
               else
                 "Revalidate ordinary gates for the current head before deciding whether to merge."
               end
      lines.concat([
                     "## #{index + 1} of #{entries.length} — #{action} — #{entry.fetch('repo')} — #{entry.fetch('title')}",
                     "", "- PR: #{entry.fetch('url')}", "- Reason: #{reason}",
                     "- Current head: `#{entry.fetch('head_sha')}`",
                     "- Readiness: Exact-head readiness is unverified from the label alone.",
                     "- Refreshed: #{entry.fetch('refreshed_at')}", ""
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
    allowed_pr_states = state == "none" ? %w[OPEN CLOSED MERGED] : ["OPEN"]
    raise Error, "PR is not open" unless allowed_pr_states.include?(detail["state"])
    raise Error, "PR head changed" unless detail["headRefOid"] == expected_head

    current = Array(detail["labels"]).filter_map { |label| label["name"] if label.is_a?(Hash) }
    classify(labels: current, configured_labels: labels)
    arguments = [github_cli, "pr", "edit", pr_number.to_s, "--repo", repo]
    labels.each do |semantic, label|
      desired = semantic == state
      arguments.concat(["--remove-label", label]) if !desired && label_present?(current, label)
      arguments.concat(["--add-label", label]) if desired && !label_present?(current, label)
    end
    if arguments.length > 6
      _edit_stdout, edit_stderr, edit_status = Open3.capture3(*arguments)
      unless edit_status.success?
        reconcile_stdout, reconcile_stderr, reconcile_status = Open3.capture3(
          github_cli, "pr", "view", pr_number.to_s, "--repo", repo, "--json", "state,headRefOid,labels"
        )
        unless reconcile_status.success?
          raise Error, "cannot reconcile failed human-attention update: #{reconcile_stderr.lines.first.to_s.strip}"
        end

        reconciled = JSON.parse(reconcile_stdout)
        reconciled_labels = Array(reconciled["labels"]).filter_map do |label|
          label["name"] if label.is_a?(Hash)
        end
        clear_attention_state!(
          github_cli:, repo:, pr_number:, labels:, current_labels: reconciled_labels,
          error_prefix: "human-attention label update failed"
        )
        raise Error,
              "human-attention label update failed; attention state cleared: #{edit_stderr.lines.first.to_s.strip}"
      end
    end

    verify_stdout, verify_stderr, verify_status = Open3.capture3(
      github_cli, "pr", "view", pr_number.to_s, "--repo", repo, "--json", "state,headRefOid,labels"
    )
    raise Error, "cannot verify human-attention labels: #{verify_stderr.lines.first.to_s.strip}" unless verify_status.success?

    verified = JSON.parse(verify_stdout)
    unchanged = verified["state"] == detail["state"] && verified["headRefOid"] == expected_head
    verified_labels = Array(verified["labels"]).filter_map { |label| label["name"] if label.is_a?(Hash) }
    unless unchanged
      clear_attention_state!(
        github_cli:, repo:, pr_number:, labels:, current_labels: verified_labels,
        error_prefix: "PR changed while updating human-attention labels"
      )
      raise Error, "PR changed while updating human-attention labels; attention state cleared"
    end

    verification_error = begin
      verified_state = classify(labels: verified_labels, configured_labels: labels)
      "label update did not reach the requested state" unless verified_state == state
    rescue Error => e
      e.message
    end
    if verification_error
      clear_attention_state!(
        github_cli:, repo:, pr_number:, labels:, current_labels: verified_labels,
        error_prefix: "human-attention label verification mismatch"
      )
      raise Error, "human-attention label verification mismatch; attention state cleared: #{verification_error}"
    end

    { "repo" => repo, "pr" => pr_number, "head_sha" => expected_head, "state" => state, "labels" => labels }
  rescue JSON::ParserError
    raise Error, "PR state response is malformed"
  end

  def clear_attention_state!(github_cli:, repo:, pr_number:, labels:, current_labels:, error_prefix:)
    cleanup = [github_cli, "pr", "edit", pr_number.to_s, "--repo", repo]
    labels.each_value do |label|
      cleanup.concat(["--remove-label", label]) if label_present?(current_labels, label)
    end
    if cleanup.length > 6
      _cleanup_stdout, cleanup_stderr, cleanup_status = Open3.capture3(*cleanup)
      unless cleanup_status.success?
        raise Error, "#{error_prefix}; cleanup failed: #{cleanup_stderr.lines.first.to_s.strip}"
      end
    end

    cleanup_stdout, cleanup_stderr, cleanup_status = Open3.capture3(
      github_cli, "pr", "view", pr_number.to_s, "--repo", repo, "--json", "state,headRefOid,labels"
    )
    unless cleanup_status.success?
      raise Error, "#{error_prefix}; cleanup verification failed: #{cleanup_stderr.lines.first.to_s.strip}"
    end

    cleaned = JSON.parse(cleanup_stdout)
    cleaned_labels = Array(cleaned["labels"]).filter_map { |label| label["name"] if label.is_a?(Hash) }
    return if classify(labels: cleaned_labels, configured_labels: labels) == "none"

    raise Error, "#{error_prefix}; cleanup did not clear the attention state"
  end

  def validate_labels(value)
    raise Error, "human_attention labels must be a mapping" unless value.is_a?(Hash)

    unknown = value.keys - STATES
    raise Error, "unknown human-attention label keys: #{unknown.join(', ')}" unless unknown.empty?
    unless value.values.all? { |label| label.is_a?(String) && !label.strip.empty? && !label.include?("\n") }
      raise Error, "human-attention label names must be nonempty single-line strings"
    end
    unless value.values.all? { |label| label == label.strip }
      raise Error, "human-attention label names must not have leading or trailing whitespace"
    end
    if value.values.any? { |label| label.include?(",") }
      raise Error, "human-attention label names must not contain commas"
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
