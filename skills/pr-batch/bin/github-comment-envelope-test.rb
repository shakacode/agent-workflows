#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tempfile"

SCRIPT = File.expand_path("github-comment-envelope", __dir__)
VISIBLE_PREFIX = "🤖 AI agent — Codex on M5"

class GitHubCommentEnvelopeTest < Minitest::Test
  def test_render_adds_visible_first_line_and_hidden_attribution
    result = run_cli(
      "render",
      "--runner", "codex",
      "--host", "M5",
      "--task-or-run", "aw-pr731-m5",
      stdin: "Review complete."
    )

    assert_predicate result[:status], :success?, result[:stderr]
    lines = result[:stdout].lines
    assert_equal "#{VISIBLE_PREFIX}\n", lines.first
    assert_includes result[:stdout], "<!-- agent-comment-attribution:v1"
    assert_includes result[:stdout], "runner: codex"
    assert_includes result[:stdout], "host: M5"
    assert_includes result[:stdout], "task_or_run: aw-pr731-m5"
    assert_includes result[:stdout], "Review complete."
  end

  def test_validate_rejects_an_unattributed_agent_comment
    result = run_cli("validate", stdin: "Automated review complete.\n")

    refute_predicate result[:status], :success?
    assert_includes result[:stderr], "missing attribution envelope"
  end

  def test_classify_reports_agent_only_for_a_complete_envelope
    rendered = run_cli(
      "render",
      "--runner", "claude",
      "--host", "M1",
      "--task-or-run", "run-42",
      stdin: "Done."
    )
    classified = run_cli("classify", stdin: rendered[:stdout])
    human = run_cli("classify", stdin: "I approve this change.\n")

    assert_equal "agent\n", classified[:stdout]
    assert_equal "human\n", human[:stdout]
  end

  def test_autonomous_human_authority_explicitly_excludes_agent_envelopes
    source = File.read(File.expand_path("../lib/autonomous_merge_decision.rb", __dir__))

    assert_includes source, "GitHubCommentEnvelope.agent_authored?(comment[\"body\"])"
  end

  private

  def run_cli(*arguments, stdin: "")
    stdout, stderr, status = Open3.capture3(SCRIPT, *arguments, stdin_data: stdin)
    { stdout:, stderr:, status: }
  end
end
