# frozen_string_literal: true

require_relative "autonomous_merge_decision"

# One personally authored, live maintainer comment can approve one terminal
# reviewer failure. This is separate from permission to merge and risk approval.
module ConfiguredReviewException
  class Error < StandardError; end

  MARKER = "<!-- configured-review-exception:v1 -->"
  KEYS = %w[
    host repo pr head_sha workflow_id workflow_path job_key job_name job_id
    run_id run_attempt conclusion decision approved_by
  ].freeze

  module_function

  def parse(body)
    raise Error, "review exception comment format is invalid" unless
      body.is_a?(String) && body.start_with?("#{MARKER}\n---\n") &&
      body.scan(MARKER).one? && !body.include?("\r")

    yaml = body.delete_prefix("#{MARKER}\n")
    stream = Psych.parse_stream(yaml)
    raise Error, "review exception YAML is invalid" unless
      yaml.match?(AutonomousMergeDecision::YAML_CLOSE) && stream.children.one? &&
      AutonomousMergePolicy.duplicate_key_errors(yaml).empty? &&
      !AutonomousMergeDecision.forbidden_yaml_node?(stream)

    payload = YAML.safe_load(yaml, aliases: false)
    raise Error, "review exception fields are invalid" unless
      payload.is_a?(Hash) && payload.keys.sort == KEYS.sort

    payload
  rescue Psych::Exception => e
    raise Error, "review exception YAML is invalid: #{e.class}"
  end

  def authenticate!(reference:, host:, repo:, pr_number:, head_sha:, base_sha:, read:, git:, validate_run:, jobs:)
    raise Error, "review exception reference must bind comment ID and body SHA256" unless
      reference.is_a?(Hash) && reference.keys.sort == %w[body_sha256 comment_id] &&
      positive_integer?(reference["comment_id"]) &&
      reference["body_sha256"].is_a?(String) && reference["body_sha256"].match?(/\A[0-9a-f]{64}\z/)

    comment_id = reference.fetch("comment_id")
    comment = read.call("repos/#{repo}/issues/comments/#{comment_id}")
    api_root = host == "github.com" ? "https://api.github.com" : "https://#{host}/api/v3"
    raise Error, "review exception comment identity or bytes changed" unless
      comment.is_a?(Hash) && comment["id"] == comment_id && comment["body"].is_a?(String) &&
      comment["issue_url"] == "#{api_root}/repos/#{repo}/issues/#{pr_number}" &&
      comment["html_url"] == "https://#{host}/#{repo}/pull/#{pr_number}#issuecomment-#{comment_id}" &&
      comment["performed_via_github_app"].nil? &&
      Digest::SHA256.hexdigest(comment["body"]) == reference["body_sha256"]

    payload = parse(comment.fetch("body"))
    expected = { "host" => host, "repo" => repo, "pr" => pr_number, "head_sha" => head_sha,
                 "decision" => "approve-terminal-review-exception", "conclusion" => "failure" }
    raise Error, "review exception target or decision mismatch" unless
      expected.all? { |key, value| payload[key] == value }
    raise Error, "review exception run, workflow or job identity is invalid" unless
      %w[workflow_id job_id run_id run_attempt].all? { |key| positive_integer?(payload[key]) } &&
      payload["workflow_path"].is_a?(String) &&
      payload["workflow_path"].match?(%r{\A\.github/workflows/[A-Za-z0-9_-]+\.ya?ml\z}) &&
      payload["job_key"].is_a?(String) && payload["job_key"].match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/) &&
      payload["job_name"].is_a?(String) && !payload["job_name"].strip.empty?

    author = comment["user"]
    login = payload["approved_by"]
    raise Error, "review exception must be personally authored by a human maintainer" unless
      login.is_a?(String) && login.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*\z/) &&
      author.is_a?(Hash) && author["type"] == "User" && author["login"] == login

    permission = read.call("repos/#{repo}/collaborators/#{login}/permission")
    # GitHub reports maintain as legacy permission=write, role_name=maintain.
    raise Error, "review exception author no longer has maintain/admin permission" unless
      permission.is_a?(Hash) &&
      (permission["permission"] == "admin" ||
        (permission["permission"] == "write" && permission["role_name"] == "maintain")) &&
      permission.dig("user", "login") == login && permission.dig("user", "type") == "User"

    workflow = read.call("repos/#{repo}/actions/workflows/#{payload.fetch('workflow_id')}")
    path = payload.fetch("workflow_path")
    raise Error, "review exception workflow identity mismatch" unless
      workflow.is_a?(Hash) && workflow["id"] == payload["workflow_id"] &&
      workflow["path"] == path && workflow["state"] == "active"

    entry = git.call("ls-tree", base_sha, "--", path)
    raise Error, "reviewer workflow must be a regular trusted-base file" unless
      entry.match?(/\A100644 blob [0-9a-f]{40}\t#{Regexp.escape(path)}\n\z/)

    raw = git.call("cat-file", "blob", "#{base_sha}:#{path}")
    raise Error, "trusted reviewer workflow has duplicate keys" unless
      AutonomousMergePolicy.duplicate_key_errors(raw).empty?

    config = YAML.safe_load(raw, aliases: false)
    job_config = config.dig("jobs", payload["job_key"]) if config.is_a?(Hash) && config["jobs"].is_a?(Hash)
    raise Error, "reviewer job cannot be bound to trusted-base workflow" unless
      config.is_a?(Hash) && config["name"] == workflow["name"] &&
      job_config.is_a?(Hash) && !job_config.key?("strategy") &&
      (job_config["name"] || payload["job_key"]) == payload["job_name"] &&
      !payload["job_name"].include?("${{")

    # The jobs API exposes display names, not workflow job keys. Another static
    # or dynamic name must not make the approved key's identity ambiguous.
    names = config.fetch("jobs").map { |key, definition| definition.is_a?(Hash) ? (definition["name"] || key) : nil }
    raise Error, "trusted reviewer job name is ambiguous" unless
      names.all? { |name| name.is_a?(String) && !name.include?("${{") } &&
      names.count(payload["job_name"]) == 1

    run = read.call("repos/#{repo}/actions/runs/#{payload.fetch('run_id')}")
    validate_run.call(run)
    raise Error, "review exception requires the exact terminal failed run and attempt" unless
      run["id"] == payload["run_id"] && run["run_attempt"] == payload["run_attempt"] &&
      run["workflow_id"] == payload["workflow_id"] && run["path"] == path &&
      run["name"] == workflow["name"] && run["head_sha"] == head_sha &&
      run["status"] == "completed" && run["conclusion"] == "failure" &&
      run["html_url"] == "https://#{host}/#{repo}/actions/runs/#{payload.fetch('run_id')}"

    all_jobs = jobs.call(payload.fetch("run_id"))
    raise Error, "review exception job inventory is incomplete or ambiguous" unless
      all_jobs.is_a?(Array) && !all_jobs.empty? &&
      all_jobs.all? { |job| job.is_a?(Hash) && positive_integer?(job["id"]) } &&
      all_jobs.map { |job| job["id"] }.uniq.length == all_jobs.length

    selected = all_jobs.select { |job| job["id"] == payload["job_id"] }
    raise Error, "review exception must identify exactly one failed reviewer job" unless selected.one?

    all_jobs.each do |job|
      selected_job = job["id"] == payload["job_id"]
      allowed = selected_job ? ["failure"] : %w[success skipped neutral]
      raise Error, "review exception cannot waive unrelated or nonterminal jobs" unless
        job["run_id"] == payload["run_id"] && job["run_attempt"] == payload["run_attempt"] &&
        job["head_sha"] == head_sha && job["status"] == "completed" &&
        allowed.include?(job["conclusion"]) && job["name"].is_a?(String) && !job["name"].empty?
    end
    job = selected.first
    raise Error, "review exception reviewer identity mismatch" unless
      job["name"] == payload["job_name"] &&
      all_jobs.count { |item| item["name"] == payload["job_name"] } == 1 &&
      job["html_url"] == "#{run.fetch('html_url')}/job/#{payload.fetch('job_id')}"

    # Re-read mutable authority and run after collecting its dependent evidence.
    raise Error, "review exception changed during authentication" unless
      read.call("repos/#{repo}/issues/comments/#{comment_id}") == comment &&
      read.call("repos/#{repo}/actions/runs/#{payload.fetch('run_id')}") == run &&
      read.call("repos/#{repo}/collaborators/#{login}/permission") == permission

    { "reference" => reference, "payload" => payload, "run" => run, "job" => job }
  rescue Psych::Exception, KeyError, TypeError => e
    raise Error, "review exception evidence is malformed: #{e.class}"
  end

  def dispositions(rows:, required_rows:, authenticated:)
    return [] unless authenticated

    expected_rows = authenticated.fetch("rows")
    return [] unless expected_rows.all? { |expected| rows.count(expected) == 1 }
    return [] unless required_rows.is_a?(Array) && required_rows.none? do |required|
      !required.is_a?(Hash) || expected_rows.any? do |row|
        required["name"] == row["name"] || required["link"] == row["url"]
      end
    end

    expected_rows.map do |row|
      { "disposition" => "configured_review_exception", "row" => row,
        "comment_id" => authenticated.dig("reference", "comment_id"),
        "body_sha256" => authenticated.dig("reference", "body_sha256") }
    end
  end

  def matches_row?(disposition, row)
    disposition.is_a?(Hash) && disposition["disposition"] == "configured_review_exception" &&
      disposition["row"] == row
  end

  def fallback_row?(row, authenticated)
    return false unless authenticated && row.is_a?(Hash) &&
                        row["bucket"] == "fail" && row["state"] == "FAILURE"

    payload = authenticated.fetch("payload")
    row["name"] == payload["job_name"] && row["workflow"] == authenticated.dig("run", "name") &&
      row["link"] == authenticated.dig("job", "html_url")
  end

  def positive_integer?(value)
    value.is_a?(Integer) && value.positive?
  end
end
