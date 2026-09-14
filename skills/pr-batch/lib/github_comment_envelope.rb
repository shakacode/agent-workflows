# frozen_string_literal: true

require "base64"

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
  VISIBLE_AGENT_PREFIX = /\A🤖 (?:Codex|Claude|Cursor)(?:\r?\n|\z)/
  PAYLOAD_RUNNER_PREFIX = /\A🤖 (?:Codex|Claude|Cursor)(?:[ \t]+|(?=\z))/
  MARKDOWN_BLOCK_SYNTAX = %r{\A[ \t]{0,3}(?:`{3,}|~{3,}|\#{1,6}(?:[ \t]|\z)|>[ \t]?|[-+*][ \t]+|\d+[.)][ \t]+|(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,}|<[A-Za-z!/])|\A(?: {4}|[ \t]*\t)}
  PAYLOAD_LINE_ENDINGS = { "\r\n" => "crlf", "\n" => "lf", "\r" => "cr", "" => "none" }.freeze
  PAYLOAD_LINE_ENDING_VALUES = PAYLOAD_LINE_ENDINGS.invert.freeze

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
    first_line, line_ending, remaining_payload = split_payload(payload)
    first_line_preserved = preserve_payload_first_line?(first_line, remaining_payload)
    visible = visible_line(display_runner, first_line, remaining_payload)
    remaining_payload = "#{first_line}#{line_ending}#{remaining_payload}" if first_line_preserved
    marker = [
      MARKER,
      "runner: #{runner}",
      "host: #{host}",
      "task_or_run: #{task_or_run}"
    ]
    unless first_line.empty?
      marker.concat([
                      "payload_first_line_b64url: #{Base64.urlsafe_encode64(first_line, padding: false)}",
                      "payload_line_ending: #{PAYLOAD_LINE_ENDINGS.fetch(line_ending)}",
                      "payload_first_line_preserved: #{first_line_preserved}"
                    ])
    end
    marker = marker.join("\n")
    "#{visible}\n\n<details>\n<summary>Agent attribution</summary>\n\n```text\n#{marker}\n```\n</details>\n\n#{remaining_payload}"
  end

  def agent_authored?(body)
    !parse(body).nil? || body.to_s.match?(VISIBLE_AGENT_PREFIX) ||
      body.to_s.sub(LEGACY_WORKFLOW_MARKER, "").match?(LEGACY_AGENT_HEADER)
  end

  def payload(body)
    parsed = parse(body)
    return body unless parsed

    remaining_payload = body[parsed.fetch("payload_offset")..].to_s
    return remaining_payload unless parsed.key?("payload_first_line")

    preserved_first_line = "#{parsed.fetch('payload_first_line')}#{parsed.fetch('payload_line_ending')}"
    return remaining_payload if parsed["payload_first_line_preserved"] == true
    return "#{preserved_first_line}#{remaining_payload}" if parsed.key?("payload_first_line_preserved")

    if remaining_payload.start_with?(preserved_first_line) &&
       preserve_payload_first_line?(parsed.fetch("payload_first_line"), remaining_payload.delete_prefix(preserved_first_line))
      return remaining_payload
    end

    "#{preserved_first_line}#{remaining_payload}"
  end

  def parse(body)
    return unless body.is_a?(String)

    match = body.match(%r{\A(?<visible>🤖 [^\r\n]+)\r?\n\r?\n<details>\r?\n<summary>Agent attribution</summary>\r?\n\r?\n```text\r?\n#{MARKER}\r?\nrunner: (?<runner>[^\r\n]+)\r?\nhost: (?<host>[^\r\n]+)\r?\ntask_or_run: (?<task>[^\r\n]+)\r?\n(?:payload_first_line_b64url: (?<payload_first_line>[A-Za-z0-9_-]*)\r?\npayload_line_ending: (?<payload_line_ending>crlf|lf|cr|none)\r?\n(?:payload_first_line_preserved: (?<first_line_preserved>true|false)\r?\n)?)?```\r?\n</details>\r?\n\r?\n}m)
    return parse_legacy(body) unless match

    visible = match[:visible]
    runner = match[:runner]
    host = match[:host]
    task_or_run = match[:task]

    return unless valid_fields?(visible, runner, host, task_or_run)

    parsed = { "version" => VERSION, "runner" => runner.downcase, "host" => host, "task_or_run" => task_or_run, "payload_offset" => match.end(0) }
    unless match[:payload_first_line]
      return unless visible == "🤖 #{RUNNER_DISPLAY.fetch(runner.downcase)}"

      return parsed
    end

    payload_first_line = Base64.urlsafe_decode64(match[:payload_first_line]).force_encoding(Encoding::UTF_8)
    return unless Base64.urlsafe_encode64(payload_first_line, padding: false) == match[:payload_first_line]
    return unless payload_first_line.valid_encoding? && !payload_first_line.empty? && !payload_first_line.match?(/[\r\n]/)

    payload_line_ending = PAYLOAD_LINE_ENDING_VALUES.fetch(match[:payload_line_ending])
    envelope_line_ending = body[/\r\n|\n|\r/]
    payload_line_ending = "\r\n" if payload_line_ending == "\n" && envelope_line_ending == "\r\n"
    remaining_payload = body[match.end(0)..].to_s
    preserved_first_line = "#{payload_first_line}#{payload_line_ending}"
    display_runner = RUNNER_DISPLAY.fetch(runner.downcase)
    if match[:first_line_preserved] == "true"
      return unless preserved_payload_first_line?(payload_first_line, remaining_payload, preserved_first_line)

      return unless visible == visible_line(display_runner, payload_first_line, remaining_payload.delete_prefix(preserved_first_line))
    elsif match[:first_line_preserved] == "false"
      return unless visible == visible_line(display_runner, payload_first_line, remaining_payload)
    else
      return unless visible == visible_line(display_runner, payload_first_line, remaining_payload) ||
                    visible == visible_line(display_runner, payload_first_line, remaining_payload.delete_prefix(preserved_first_line))
    end

    payload_first_line.force_encoding(body.encoding)

    payload_metadata = {
      "payload_first_line" => payload_first_line,
      "payload_line_ending" => payload_line_ending
    }
    unless match[:first_line_preserved].nil?
      payload_metadata["payload_first_line_preserved"] = match[:first_line_preserved] == "true"
    end

    parsed.merge(payload_metadata)
  rescue ArgumentError
    nil
  end

  def parse_legacy(body)
    lines = body.lines(chomp: true).first(6).map { |line| line.delete_suffix("\r") }
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

    payload_offset = body.lines.first(6).join.length
    payload_offset += 2 if body[payload_offset, 2] == "\r\n"
    payload_offset += 1 if body[payload_offset, 1] == "\n"
    { "version" => VERSION, "runner" => runner.downcase, "host" => host, "task_or_run" => task_or_run, "payload_offset" => payload_offset }
  end

  def valid_fields?(visible, runner, host, task_or_run)
    runner.match?(VALUE_PATTERN) && host.match?(HOST_PATTERN) && task_or_run.match?(VALUE_PATTERN) &&
      RUNNER_DISPLAY[runner.downcase] && visible.match?(/\A🤖 #{Regexp.escape(RUNNER_DISPLAY.fetch(runner.downcase))}(?: |\z)/)
  end

  def split_payload(payload)
    line_ending = payload.match(/\r\n|\n|\r/)
    return [payload, "", ""] unless line_ending

    index = line_ending.begin(0)
    ending = line_ending[0]
    [payload[0...index], ending, payload[(index + ending.length)..].to_s]
  end

  def visible_line(display_runner, payload_first_line, remaining_payload = "")
    outcome = payload_first_line.sub(PAYLOAD_RUNNER_PREFIX, "").strip
    visible = "🤖 #{display_runner}"
    visible += " #{outcome}" unless outcome.empty? || preserve_payload_first_line?(payload_first_line, remaining_payload)
    visible
  end

  def preserve_payload_first_line?(payload_first_line, remaining_payload = "")
    return false if payload_first_line.empty?

    outcome = payload_first_line.sub(PAYLOAD_RUNNER_PREFIX, "")
    outcome.match?(MARKDOWN_BLOCK_SYNTAX) || remaining_payload.match?(/\A(?: {0,3}=+[ \t]*| {0,3}-+[ \t]*)(?:\r\n|\n|\r|\z)/)
  end

  def preserved_payload_first_line?(payload_first_line, remaining_payload, preserved_first_line)
    remaining_payload.start_with?(preserved_first_line) &&
      preserve_payload_first_line?(payload_first_line, remaining_payload.delete_prefix(preserved_first_line))
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
