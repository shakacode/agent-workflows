# frozen_string_literal: true

module GitHubCommentEnvelope
  VERSION = 1
  MARKER = "agent-comment-attribution:v#{VERSION}".freeze
  RUNNER_DISPLAY = {
    "codex" => "Codex",
    "claude" => "Claude"
  }.freeze
  VALUE_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._:/-]*\z}

  module_function

  def render(body:, runner:, host:, task_or_run:)
    runner = normalized_value(runner, "runner").downcase
    host = normalized_value(host, "host")
    task_or_run = normalized_value(task_or_run, "task-or-run")
    raise ArgumentError, "body already has an attribution envelope" if parse(body)

    display_runner = RUNNER_DISPLAY.fetch(runner) do
      raise ArgumentError, "runner must be codex or claude"
    end
    visible = "🤖 #{display_runner}"
    marker = <<~MARKER.chomp
      <!-- #{MARKER}
      runner: #{runner}
      host: #{host}
      task_or_run: #{task_or_run}
      -->
    MARKER
    "#{visible}\n#{marker}\n\n#{body.sub(/\A\n+/, '')}"
  end

  def agent_authored?(body)
    !parse(body).nil? || body.to_s.match?(/\A🤖 [^\r\n]+(?:\r?\n|\z)/)
  end

  def payload(body)
    return body unless parse(body)

    body.lines.drop(6).join.sub(/\A\n/, "")
  end

  def validate!(body)
    parse(body) || raise(ArgumentError, "missing attribution envelope")
  end

  def parse(body)
    return unless body.is_a?(String)

    lines = body.lines(chomp: true).first(6).map { |line| line.delete_suffix("\r") }
    return if lines.length < 6

    visible = lines[0]
    return unless lines[1] == "<!-- #{MARKER}"
    return unless lines[2].start_with?("runner: ")
    return unless lines[3].start_with?("host: ")
    return unless lines[4].start_with?("task_or_run: ")
    return unless lines[5] == "-->"
    runner = lines[2].delete_prefix("runner: ")
    host = lines[3].delete_prefix("host: ")
    task_or_run = lines[4].delete_prefix("task_or_run: ")
    return unless [runner, host, task_or_run].all? { |value| value.match?(VALUE_PATTERN) }

    display_runner = RUNNER_DISPLAY[runner.downcase]
    return unless display_runner
    return unless visible == "🤖 #{display_runner}"

    { "version" => VERSION, "runner" => runner.downcase, "host" => host, "task_or_run" => task_or_run }
  end

  def normalized_value(value, name)
    value = value.to_s.strip
    raise ArgumentError, "#{name} is invalid" unless value.match?(VALUE_PATTERN)

    value
  end
end
