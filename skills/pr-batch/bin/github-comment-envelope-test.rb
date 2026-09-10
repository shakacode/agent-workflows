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
    rendered = GitHubCommentEnvelope.render(
      body: "Review complete.", runner: "codex", host: "M5", task_or_run: "aw-pr731-m5"
    )

    lines = rendered.lines
    assert_equal "#{VISIBLE_PREFIX}\n", lines.first
    assert_includes rendered, "<!-- agent-comment-attribution:v1"
    assert_includes rendered, "runner: codex"
    assert_includes rendered, "host: M5"
    assert_includes rendered, "task_or_run: aw-pr731-m5"
    assert_includes rendered, "Review complete."
  end

  def test_classify_reports_agent_for_a_complete_envelope_or_visible_prefix
    rendered = GitHubCommentEnvelope.render(
      body: "Done.", runner: "claude", host: "M1", task_or_run: "run-42"
    )

    assert GitHubCommentEnvelope.agent_authored?(rendered)
    assert GitHubCommentEnvelope.agent_authored?("🤖 Codex\nlegacy payload")
    refute GitHubCommentEnvelope.agent_authored?("I approve this change.\n")
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

  def test_post_issue_preserves_attribution_when_uploading_attachments
    Dir.mktmpdir("comment-envelope-attach") do |directory|
      fake_gh = File.join(directory, "gh")
      capture = File.join(directory, "capture.json")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        body_index = ARGV.index("--body-file")
        body = File.read(ARGV.fetch(body_index + 1))
        File.write(ENV.fetch("CAPTURE"), JSON.generate({"args" => ARGV, "body" => body}))
        puts "https://github.com/acme/widgets/pull/7#issuecomment-1"
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "post-issue", "--repo", "acme/widgets", "--number", "7",
        "--runner", "codex", "--host", "M5", "--task-or-run", "task-7",
        "--attach", "evidence.png#Before and after", "--attach", "evidence.mp4",
        stdin: "Verified.", env: { "GITHUB_COMMENT_GH" => fake_gh, "CAPTURE" => capture }
      )
      posted = JSON.parse(File.read(capture))

      assert_predicate result[:status], :success?, result[:stderr]
      assert_equal ["pr", "comment", "7", "--repo", "acme/widgets"], posted.fetch("args").first(5)
      attachments = posted.fetch("args").each_index.filter_map do |index|
        posted.fetch("args")[index + 1] if posted.fetch("args")[index] == "--attach"
      end
      assert_equal ["evidence.png#Before and after", "evidence.mp4"], attachments
      assert posted.fetch("body").start_with?("🤖 Codex\n")
    end
  end

  # Production break: malformed CLI values escape the error boundary and expose
  # a Ruby backtrace instead of one actionable parser message.
  def test_invalid_numeric_option_fails_without_a_backtrace
    result = run_cli("post-issue", "--number", "not-a-number")

    refute_predicate result[:status], :success?
    assert_empty result[:stdout]
    assert_equal "invalid argument: --number not-a-number\n", result[:stderr]
  end

  private

  def run_cli(*arguments, stdin: "", env: {})
    stdout, stderr, status = Open3.capture3(env, SCRIPT, *arguments, stdin_data: stdin)
    { stdout:, stderr:, status: }
  end
end
