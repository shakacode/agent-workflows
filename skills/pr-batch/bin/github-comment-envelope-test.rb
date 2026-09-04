#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/github_comment_envelope"

SCRIPT = File.expand_path("github-comment-envelope", __dir__)
VISIBLE_PREFIX = "🤖 Codex"

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

  def test_classify_reports_agent_for_a_complete_envelope_or_visible_prefix
    rendered = run_cli(
      "render",
      "--runner", "claude",
      "--host", "M1",
      "--task-or-run", "run-42",
      stdin: "Done."
    )
    classified = run_cli("classify", stdin: rendered[:stdout])
    prefix_only = run_cli("classify", stdin: "🤖 Codex\nlegacy payload")
    human = run_cli("classify", stdin: "I approve this change.\n")

    assert_equal "agent\n", classified[:stdout]
    assert_equal "agent\n", prefix_only[:stdout]
    assert_equal "human\n", human[:stdout]
  end

  def test_payload_does_not_strip_a_malformed_prefix_only_comment
    body = "🤖 Codex\nlegacy payload"

    assert_equal body, GitHubCommentEnvelope.payload(body)
  end

  def test_payload_preserves_cr_characters_and_an_attribution_marker_in_payload
    payload = "Quoted marker: <!-- agent-comment-attribution:v1 -->\r\n"
    body = GitHubCommentEnvelope.render(body: payload, runner: "codex", host: "M5", task_or_run: "task-7")

    assert_equal payload, GitHubCommentEnvelope.payload(body)
  end

  def test_render_rejects_unknown_visible_runner_identity
    error = assert_raises(ArgumentError) do
      GitHubCommentEnvelope.render(body: "Done.", runner: "agent-workflows", host: "M5", task_or_run: "task-7")
    end

    assert_equal "runner must be codex or claude", error.message
  end

  def test_autonomous_human_authority_explicitly_excludes_agent_envelopes
    source = File.read(File.expand_path("../lib/autonomous_merge_decision.rb", __dir__))

    assert_includes source, "GitHubCommentEnvelope.agent_authored?(comment[\"body\"])"
  end

  def test_post_issue_routes_the_enveloped_body_through_one_boundary
    Dir.mktmpdir("comment-envelope-post") do |directory|
      fake_gh = File.join(directory, "gh")
      capture = File.join(directory, "capture.json")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        body_arg = ARGV.find { |arg| arg.start_with?("body=@") }
        body = File.read(body_arg.delete_prefix("body=@"))
        File.write(ENV.fetch("CAPTURE"), JSON.generate({"args" => ARGV, "body" => body}))
        puts JSON.generate({"html_url" => "https://github.com/acme/widgets/issues/7#issuecomment-1"})
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "post-issue", "--repo", "acme/widgets", "--number", "7",
        "--runner", "codex", "--host", "M5", "--task-or-run", "task-7",
        stdin: "Ready.", env: { "GITHUB_COMMENT_GH" => fake_gh, "CAPTURE" => capture }
      )
      posted = JSON.parse(File.read(capture))

      assert_predicate result[:status], :success?, result[:stderr]
      assert_includes posted.fetch("args"), "repos/acme/widgets/issues/7/comments"
      assert posted.fetch("body").start_with?("🤖 Codex\n")
    end
  end

  def test_post_reply_routes_the_enveloped_body_through_one_boundary
    Dir.mktmpdir("comment-envelope-reply") do |directory|
      fake_gh = File.join(directory, "gh")
      capture = File.join(directory, "capture.json")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        body_arg = ARGV.find { |arg| arg.start_with?("body=@") }
        body = File.read(body_arg.delete_prefix("body=@"))
        File.write(ENV.fetch("CAPTURE"), JSON.generate({"args" => ARGV, "body" => body}))
        puts JSON.generate({"html_url" => "https://github.com/acme/widgets/pull/7#discussion_r99"})
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "post-reply", "--repo", "acme/widgets", "--number", "7", "--comment-id", "99",
        "--runner", "codex", "--host", "M5", "--task-or-run", "task-7",
        stdin: "Fixed.", env: { "GITHUB_COMMENT_GH" => fake_gh, "CAPTURE" => capture }
      )
      posted = JSON.parse(File.read(capture))

      assert_predicate result[:status], :success?, result[:stderr]
      assert_includes posted.fetch("args"), "repos/acme/widgets/pulls/7/comments/99/replies"
      assert posted.fetch("body").start_with?("🤖 Codex\n")
    end
  end

  private

  def run_cli(*arguments, stdin: "", env: {})
    stdout, stderr, status = Open3.capture3(env, SCRIPT, *arguments, stdin_data: stdin)
    { stdout:, stderr:, status: }
  end
end
