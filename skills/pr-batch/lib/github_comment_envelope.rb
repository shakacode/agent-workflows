# frozen_string_literal: true

module GitHubCommentEnvelope
  VERSION = 1
  MARKER = "agent-comment-attribution:v#{VERSION}".freeze
  RUNNER_DISPLAY = {
    "codex" => "Codex",
    "claude" => "Claude",
    "cursor" => "Cursor"
  }.freeze
  VALUE_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._:/-]*\z}
  HOST_PATTERN = /\A(?!.*-->)[^\r\n]+\z/
  LEGACY_WORKFLOW_MARKER = /\A<!-- address-review-(?:summary|status) -->\r?\n/
  LEGACY_AGENT_HEADER = /\A🤖 \*\*(?:Codex|Claude|Cursor)(?: · [^*\r\n]+)?\*\*(?:\r?\n|\z)/
  VISIBLE_AGENT_PREFIX = /\A🤖 (?:Codex|Claude|Cursor)(?:\r?\n| · Agent comment(?:\r?\n|\z)|\z)/
  TEMP_VISIBLE_AGENT_PREFIX = /\A🤖 (?:Codex|Claude|Cursor) [^\r\n]*\r?\n\r?\n<details>/

  module_function

  def render(body:, runner:, host:, task_or_run:)
    runner = normalized_value(runner, "runner").downcase
    host = normalized_value(host, "host", pattern: HOST_PATTERN)
    task_or_run = normalized_value(task_or_run, "task-or-run")
    raise ArgumentError, "body already has an attribution envelope" if parse(body)

    display_runner = RUNNER_DISPLAY.fetch(runner) do
      raise ArgumentError, "runner must be codex, claude, or cursor"
    end
    payload = body.sub(/\A[\r\n]+/, "")
    marker = [
      MARKER,
      "runner: #{runner}",
      "host: #{host}",
      "task_or_run: #{task_or_run}",
      "payload_layout: after-attribution"
    ]
    marker = marker.join("\n")
    "🤖 #{display_runner} · Agent comment\n\n<details>\n<summary>Agent attribution</summary>\n\n```text\n#{marker}\n```\n</details>\n\n#{payload}"
  end

  def agent_authored?(body)
    !parse(body).nil? || body.to_s.match?(VISIBLE_AGENT_PREFIX) ||
      body.to_s.match?(TEMP_VISIBLE_AGENT_PREFIX) ||
      body.to_s.sub(LEGACY_WORKFLOW_MARKER, "").match?(LEGACY_AGENT_HEADER)
  end

  def payload(body)
    parsed = parse(body)
    return body unless parsed

    body[parsed.fetch("payload_offset")..].to_s
  end

  def parse(body)
    return unless body.is_a?(String)

    match = body.match(%r{\A(?<visible>🤖 [^\r\n]+)\r?\n\r?\n<details>\r?\n<summary>Agent attribution</summary>\r?\n\r?\n```text\r?\n#{MARKER}\r?\nrunner: (?<runner>[^\r\n]+)\r?\nhost: (?<host>[^\r\n]+)\r?\ntask_or_run: (?<task>[^\r\n]+)\r?\npayload_layout: after-attribution\r?\n```\r?\n</details>\r?\n\r?\n}m)
    return parse_legacy(body) unless match

    visible = match[:visible]
    runner = match[:runner]
    host = match[:host]
    task_or_run = match[:task]

    return unless valid_fields?(visible, runner, host, task_or_run)

    parsed = {
      "version" => VERSION,
      "runner" => runner.downcase,
      "host" => host,
      "task_or_run" => task_or_run,
      "payload_offset" => match.end(0)
    }
    return unless visible == "🤖 #{RUNNER_DISPLAY.fetch(runner.downcase)} · Agent comment"

    parsed.merge("payload_layout" => "after-attribution")
  end

  def parse_legacy(body)
    lines = body.split(/\r\n|\n|\r/, -1).first(6)
    return if lines.length < 6

    visible = lines[0]
    return unless lines[1] == "<!-- #{MARKER}" && lines[5] == "-->"

    return unless lines[2].start_with?("runner: ") && lines[3].start_with?("host: ") &&
                  lines[4].start_with?("task_or_run: ")

    runner = lines[2].delete_prefix("runner: ")
    host = lines[3].delete_prefix("host: ")
    task_or_run = lines[4].delete_prefix("task_or_run: ")
    return unless valid_fields?(visible, runner, host, task_or_run)
    return unless visible == "🤖 #{RUNNER_DISPLAY.fetch(runner.downcase)}"

    line_endings = body.scan(/\r\n|\n|\r/)
    payload_offset = lines.zip(line_endings.first(6)).sum { |line, ending| line.length + ending.to_s.length }
    separator = line_endings.fetch(6, "")
    payload_offset += separator.length if body[payload_offset, separator.length] == separator
    { "version" => VERSION, "runner" => runner.downcase, "host" => host, "task_or_run" => task_or_run, "payload_offset" => payload_offset }
  end

  def valid_fields?(visible, runner, host, task_or_run)
    runner.match?(VALUE_PATTERN) && host.match?(HOST_PATTERN) && task_or_run.match?(VALUE_PATTERN) &&
      RUNNER_DISPLAY[runner.downcase] && visible.match?(/\A🤖 #{Regexp.escape(RUNNER_DISPLAY.fetch(runner.downcase))}(?: |\z)/)
  end

  def normalized_value(value, name, pattern: VALUE_PATTERN)
    value = value.to_s.strip
    unless value.match?(pattern)
      message = name == "host" ? "host must be a safe non-empty single-line value" : "#{name} is invalid"
      raise ArgumentError, message
    end

    value
  end
end
