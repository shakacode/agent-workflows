#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "timeout"
require "tmpdir"
require_relative "../lib/github_comment_envelope"

SCRIPT = File.expand_path("github-comment-envelope", __dir__)
VISIBLE_PREFIX = "🤖 Codex"

class GitHubCommentEnvelopeTest < Minitest::Test
  def test_render_puts_the_payload_outcome_before_closed_visible_attribution
    payload = "Review complete.\nFollow-up evidence is recorded."
    rendered = GitHubCommentEnvelope.render(
      body: payload, runner: "codex", host: "M5", task_or_run: "aw-pr731-m5"
    )

    lines = rendered.lines
    assert_equal "#{VISIBLE_PREFIX} Review complete.\n", lines.first
    assert_operator rendered.index("Review complete."), :<, rendered.index("<summary>Agent attribution</summary>")
    refute_includes rendered, "<!--"
    assert_includes rendered, "<summary>Agent attribution</summary>"
    assert_includes rendered, "```text\nagent-comment-attribution:v1"
    assert_includes rendered, "runner: codex"
    assert_includes rendered, "host: M5"
    assert_includes rendered, "task_or_run: aw-pr731-m5"
    assert_includes rendered, "Follow-up evidence is recorded."
    assert_equal payload, GitHubCommentEnvelope.payload(rendered)
  end

  def test_render_accepts_cursor_as_a_truthful_runner
    rendered = GitHubCommentEnvelope.render(
      body: "Review complete.", runner: "cursor", host: "Cursor desktop", task_or_run: "cursor-7"
    )

    assert rendered.start_with?("🤖 Cursor Review complete.\n")
    assert_equal "cursor", GitHubCommentEnvelope.parse(rendered).fetch("runner")
    assert GitHubCommentEnvelope.agent_authored?("🤖 Cursor\nlegacy payload")
  end

  # Production break: a real runner host such as "Codex desktop" is rejected,
  # so otherwise valid agent comments cannot cross the shared boundary.
  def test_render_accepts_a_human_readable_single_line_host
    rendered = GitHubCommentEnvelope.render(
      body: "Done.", runner: "codex", host: "Codex desktop", task_or_run: "task-7"
    )

    assert_includes rendered, "host: Codex desktop"
    assert_equal "Codex desktop", GitHubCommentEnvelope.parse(rendered).fetch("host")
  end

  # Production break: loosening host names for realistic display values could
  # permit a newline to inject fields into the hidden attribution envelope.
  def test_render_rejects_a_multiline_host_with_an_actionable_error
    error = assert_raises(ArgumentError) do
      GitHubCommentEnvelope.render(
        body: "Done.", runner: "codex", host: "Codex\ndesktop", task_or_run: "task-7"
      )
    end

    assert_equal "host must be a safe non-empty single-line value", error.message
  end

  # Production break: an HTML comment terminator in the host closes the hidden
  # envelope early while the parser still treats the attribution as valid.
  def test_host_rejects_html_comment_terminators
    error = assert_raises(ArgumentError) do
      GitHubCommentEnvelope.render(
        body: "Done.", runner: "codex", host: "Codex --> desktop", task_or_run: "task-7"
      )
    end

    assert_equal "host must be a safe non-empty single-line value", error.message
    refute GitHubCommentEnvelope.parse(<<~BODY)
      🤖 Codex
      <!-- agent-comment-attribution:v1
      runner: codex
      host: Codex --> desktop
      task_or_run: task-7
      -->

      Done.
    BODY
  end

  def test_classify_reports_agent_for_a_complete_envelope_or_visible_prefix
    rendered = GitHubCommentEnvelope.render(
      body: "Done.", runner: "claude", host: "M1", task_or_run: "run-42"
    )

    assert GitHubCommentEnvelope.agent_authored?(rendered)
    assert GitHubCommentEnvelope.agent_authored?("🤖 Codex\nlegacy payload")
    assert GitHubCommentEnvelope.agent_authored?("🤖 Claude\nlegacy payload")
    refute GitHubCommentEnvelope.agent_authored?("🤖 Codex hosted QA waiver: awaiting maintainer action")
    assert GitHubCommentEnvelope.agent_authored?("🤖 **Codex · GPT-5**\n\nlegacy payload")
    assert GitHubCommentEnvelope.agent_authored?(<<~BODY)
      <!-- address-review-summary -->
      🤖 **Claude · Opus 5**

      legacy payload
    BODY
    refute GitHubCommentEnvelope.agent_authored?("🤖 Justin\nI approve this change.")
    refute GitHubCommentEnvelope.agent_authored?("A human quote:\n🤖 **Codex · GPT-5**\n")
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

  def test_render_avoids_a_duplicate_runner_prefix_and_reconstructs_the_original_payload
    payload = "🤖 Codex Review complete.\r\nFollow-up evidence is recorded."
    rendered = GitHubCommentEnvelope.render(
      body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
    )

    assert_equal "🤖 Codex Review complete.\n", rendered.lines.first
    assert_equal payload, GitHubCommentEnvelope.payload(rendered)
  end

  def test_render_preserves_markdown_block_syntax_on_the_payload_first_line
    payloads = [
      "```ruby\nputs :ok\n```\n",
      "# Heading\nEvidence follows.\n",
      "[docs]: https://example.com\nSee [docs] for details.\n",
      "Setext heading\n---\nEvidence follows.\n",
      "> Quoted context\nEvidence follows.\n",
      "<details>\n<summary>Evidence</summary>\n\nVisible details.\n</details>\n"
    ]

    payloads.each do |payload|
      rendered = GitHubCommentEnvelope.render(
        body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
      )

      assert_equal "#{VISIBLE_PREFIX}\n", rendered.lines.first
      assert_equal payload, GitHubCommentEnvelope.payload(rendered)
      assert_includes rendered, "\n\n#{payload}"
    end
  end

  def test_render_does_not_treat_mixed_thematic_break_characters_as_a_block
    payload = "-*_ evidence follows\nTail\n"
    rendered = GitHubCommentEnvelope.render(
      body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
    )

    assert_equal "#{VISIBLE_PREFIX} -*_ evidence follows\n", rendered.lines.first
    assert_equal payload, GitHubCommentEnvelope.payload(rendered)
  end

  def test_payload_round_trips_repeated_plain_first_lines
    ["Repeat\nRepeat\nTail\n", "Repeat\r\nRepeat\r\nTail\r\n"].each do |payload|
      rendered = GitHubCommentEnvelope.render(
        body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
      )

      assert_equal payload, GitHubCommentEnvelope.payload(rendered)
    end
  end

  def test_payload_round_trips_ambiguous_setext_headings_with_duplicate_first_lines
    ["Title\nTitle\n---\nTail\n", "Title\r\nTitle\r\n===\r\nTail\r\n"].each do |payload|
      rendered = GitHubCommentEnvelope.render(
        body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
      )

      assert_includes rendered, "payload_first_line_preserved: true"
      assert_equal payload, GitHubCommentEnvelope.payload(rendered)
    end
  end

  def test_render_preserves_multiline_and_repeated_setext_headings
    [
      "Title\nSubtitle\n---\nTail\n",
      "Title\r\nTitle\r\nTitle\r\nTitle\r\n===\r\nTail\r\n",
      "Title\n    Subtitle\n---\nTail\n",
      "Title\n<span>Subtitle</span>\n---\nTail\n",
      "Title\n[docs]: https://example.com\n---\nTail [docs]\n"
    ].each do |payload|
      rendered = GitHubCommentEnvelope.render(
        body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
      )

      assert_equal "#{VISIBLE_PREFIX}\n", rendered.lines.first
      assert_includes rendered, "payload_first_line_preserved: true"
      assert_equal payload, GitHubCommentEnvelope.payload(rendered)
    end
  end

  def test_payload_reads_metadata_free_preserved_first_line_envelopes
    payload = "Setext heading\n---\nEvidence follows.\n"
    rendered = GitHubCommentEnvelope.render(
      body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
    )
    legacy = rendered.sub("payload_first_line_preserved: true\n", "")

    assert_equal payload, GitHubCommentEnvelope.payload(legacy)
  end

  def test_payload_reads_real_metadata_free_multiline_setext_envelopes
    [
      "Title\nSubtitle\n---\nTail\n",
      "Title\n    Subtitle\n---\nTail\n",
      "Title\r\n<span>Subtitle</span>\r\n---\r\nTail\r\n"
    ].each do |payload|
      legacy = metadata_free_outcome_envelope(payload)

      assert_equal payload, GitHubCommentEnvelope.payload(legacy)
    end
  end

  def test_payload_refuses_tampered_first_line_preservation_metadata
    ordinary = GitHubCommentEnvelope.render(
      body: "No current checkpoint.\n<!-- address-review-summary -->", runner: "codex", host: "M5", task_or_run: "task-7"
    )
    setext = GitHubCommentEnvelope.render(
      body: "Title\n---\nEvidence follows.\n", runner: "codex", host: "M5", task_or_run: "task-7"
    )

    [ordinary.sub("payload_first_line_preserved: false", "payload_first_line_preserved: true"),
     setext.sub("payload_first_line_preserved: true", "payload_first_line_preserved: false")].each do |tampered|
      assert_nil GitHubCommentEnvelope.parse(tampered)
      assert_equal tampered, GitHubCommentEnvelope.payload(tampered)
    end
  end

  def test_payload_refuses_false_metadata_for_preserved_markdown_blocks
    [
      "# Heading\nEvidence follows.\n",
      "```ruby\nputs :ok\n```\n",
      "> Quoted context\nEvidence follows.\n",
      "<details>\n<summary>Evidence</summary>\n\nVisible details.\n</details>\n"
    ].each do |payload|
      rendered = GitHubCommentEnvelope.render(
        body: payload, runner: "codex", host: "M5", task_or_run: "task-7"
      )
      tampered = rendered.sub("payload_first_line_preserved: true", "payload_first_line_preserved: false")

      assert_nil GitHubCommentEnvelope.parse(tampered)
      assert_equal tampered, GitHubCommentEnvelope.payload(tampered)
    end
  end

  def test_payload_refuses_a_tampered_first_line_that_could_inject_a_legacy_checkpoint
    rendered = GitHubCommentEnvelope.render(
      body: "Review complete.\nFollow-up evidence is recorded.", runner: "codex", host: "M5", task_or_run: "task-7"
    )
    tampered = rendered.sub(
      /payload_first_line_b64url: [^\n]+/,
      "payload_first_line_b64url: #{Base64.urlsafe_encode64('<!-- address-review-summary -->', padding: false)}"
    )

    assert_nil GitHubCommentEnvelope.parse(tampered)
    assert_equal tampered, GitHubCommentEnvelope.payload(tampered)
  end

  def test_payload_refuses_an_outcome_first_envelope_downgraded_to_legacy_metadata
    rendered = GitHubCommentEnvelope.render(
      body: "No current checkpoint.\n<!-- address-review-summary -->", runner: "codex", host: "M5", task_or_run: "task-7"
    )
    downgraded = rendered.sub(/payload_first_line_b64url: [^\n]+\npayload_line_ending: [^\n]+\npayload_first_line_preserved: [^\n]+\n/, "")

    assert_nil GitHubCommentEnvelope.parse(downgraded)
    assert_equal downgraded, GitHubCommentEnvelope.payload(downgraded)
  end

  def test_payload_refuses_multiline_or_invalid_utf8_encoded_first_lines
    rendered = GitHubCommentEnvelope.render(
      body: "Review complete.\nFollow-up evidence is recorded.", runner: "codex", host: "M5", task_or_run: "task-7"
    )
    multiline = rendered.sub(
      /payload_first_line_b64url: [^\n]+/,
      "payload_first_line_b64url: #{Base64.urlsafe_encode64("Review\ncomplete", padding: false)}"
    )
    invalid_bytes = [255].pack("C")
    invalid_utf8 = rendered.sub(
      /payload_first_line_b64url: [^\n]+/,
      "payload_first_line_b64url: #{Base64.urlsafe_encode64(invalid_bytes, padding: false)}"
    )

    assert_nil GitHubCommentEnvelope.parse(multiline)
    assert_nil GitHubCommentEnvelope.parse(invalid_utf8)
  end

  def test_render_reconstructs_an_empty_payload_without_a_blank_visible_outcome
    rendered = GitHubCommentEnvelope.render(body: "", runner: "codex", host: "M5", task_or_run: "task-7")

    assert_equal "🤖 Codex\n", rendered.lines.first
    assert_equal "", GitHubCommentEnvelope.payload(rendered)
  end

  def test_payload_unwraps_an_envelope_with_crlf_line_endings
    body = GitHubCommentEnvelope.render(
      body: "<!-- address-review-summary -->\n", runner: "codex", host: "M5", task_or_run: "task-7"
    ).gsub("\n", "\r\n")

    assert_equal "<!-- address-review-summary -->\r\n", GitHubCommentEnvelope.payload(body)
  end

  def test_payload_unwraps_a_legacy_envelope_without_its_separator_line
    body = <<~BODY
      🤖 Codex
      <!-- agent-comment-attribution:v1
      runner: codex
      host: M5
      task_or_run: task-7
      -->

      <!-- address-review-summary -->
    BODY

    assert_equal "<!-- address-review-summary -->\n", GitHubCommentEnvelope.payload(body)
  end

  def test_payload_refuses_a_legacy_html_envelope_with_an_outcome_suffix
    body = <<~BODY
      🤖 Codex No review checkpoint was recorded.
      <!-- agent-comment-attribution:v1
      runner: codex
      host: M5
      task_or_run: task-7
      -->

      <!-- address-review-summary -->
    BODY

    assert_nil GitHubCommentEnvelope.parse(body)
    assert_equal body, GitHubCommentEnvelope.payload(body)
  end

  def test_payload_unwraps_the_previous_visible_envelope_shape
    body = <<~BODY
      🤖 Codex

      <details>
      <summary>Agent attribution</summary>

      ```text
      agent-comment-attribution:v1
      runner: codex
      host: M5
      task_or_run: task-7
      ```
      </details>

      legacy payload
    BODY

    assert_equal "legacy payload\n", GitHubCommentEnvelope.payload(body)
    assert_equal "codex", GitHubCommentEnvelope.parse(body).fetch("runner")
  end

  def test_legacy_parser_requires_all_field_labels
    body = <<~BODY
      🤖 Codex
      <!-- agent-comment-attribution:v1
      codex
      M5
      task-7
      -->

      payload
    BODY

    assert_nil GitHubCommentEnvelope.parse(body)
    assert_equal body, GitHubCommentEnvelope.payload(body)
  end

  # Production break: a Windows-style leading blank line remains before a
  # workflow marker, so downstream first-line checkpoint detection misses it.
  def test_render_removes_leading_crlf_blank_lines_from_the_payload
    rendered = GitHubCommentEnvelope.render(
      body: "\r\n\r\n<!-- address-review-summary -->\r\n",
      runner: "codex", host: "Codex desktop", task_or_run: "task-7"
    )

    assert_equal "<!-- address-review-summary -->\r\n", GitHubCommentEnvelope.payload(rendered)
  end

  def test_render_rejects_unknown_visible_runner_identity
    error = assert_raises(ArgumentError) do
      GitHubCommentEnvelope.render(body: "Done.", runner: "agent-workflows", host: "M5", task_or_run: "task-7")
    end

    assert_equal "runner must be codex, claude, or cursor", error.message
  end

  def test_post_issue_times_out_with_unknown_mutation_outcome
    Dir.mktmpdir("comment-envelope-timeout") do |directory|
      fake_gh = File.join(directory, "gh")
      File.write(fake_gh, "#!/usr/bin/env ruby\nsleep 5\n")
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "post-issue", "--repo", "acme/widgets", "--number", "7",
        "--runner", "codex", "--host", "M5", "--task-or-run", "task-7",
        stdin: "Ready.", env: {
          "GITHUB_COMMENT_GH" => fake_gh,
          "GITHUB_COMMENT_TIMEOUT_SECONDS" => "0.5"
        }
      )

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "command timed out; mutation outcome is unknown"
    end
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
      assert posted.fetch("body").start_with?("🤖 Codex Ready.\n")
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
      assert posted.fetch("body").start_with?("🤖 Codex Fixed.\n")
    end
  end

  # Production break: a public fallback claim can be posted but cannot refresh
  # or enter a terminal state through the required attribution boundary.
  def test_edit_issue_updates_the_existing_enveloped_comment
    Dir.mktmpdir("comment-envelope-edit") do |directory|
      fake_gh = File.join(directory, "gh")
      capture = File.join(directory, "capture.json")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        body_arg = ARGV.find { |arg| arg.start_with?("body=@") }
        body = File.read(body_arg.delete_prefix("body=@"))
        File.write(ENV.fetch("CAPTURE"), JSON.generate({"args" => ARGV, "body" => body}))
        puts JSON.generate({"html_url" => "https://github.com/acme/widgets/issues/7#issuecomment-99"})
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "edit-issue", "--repo", "acme/widgets", "--comment-id", "99",
        "--runner", "codex", "--host", "M5", "--task-or-run", "task-7",
        stdin: "Claim refreshed.", env: { "GITHUB_COMMENT_GH" => fake_gh, "CAPTURE" => capture }
      )
      posted = JSON.parse(File.read(capture)) if File.exist?(capture)

      assert_predicate result[:status], :success?, result[:stderr]
      assert_equal "repos/acme/widgets/issues/comments/99", posted.fetch("args").fetch(1)
      assert_equal "PATCH", posted.fetch("args").fetch(posted.fetch("args").index("-X") + 1)
      assert posted.fetch("body").start_with?("🤖 Codex Claim refreshed.\n")
      assert_includes posted.fetch("body"), "Claim refreshed."
    end
  end

  def test_post_issue_preserves_attribution_when_uploading_attachments
    Dir.mktmpdir("comment-envelope-attach") do |directory|
      fake_gh = File.join(directory, "gh")
      capture = File.join(directory, "capture.json")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        exit 0 if ARGV[0] == "api"
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
      assert posted.fetch("body").start_with?("🤖 Codex Verified.\n")
    end
  end

  def test_attachment_failure_reports_a_partial_result_url
    Dir.mktmpdir("comment-envelope-partial-attach") do |directory|
      fake_gh = File.join(directory, "gh")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        exit 0 if ARGV[0] == "api"
        puts "https://github.com/acme/widgets/pull/7#issuecomment-1"
        warn "second attachment failed"
        exit 1
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "post-issue", "--repo", "acme/widgets", "--number", "7",
        "--runner", "codex", "--host", "M5", "--task-or-run", "task-7",
        "--attach", "one.png", "--attach", "two.png",
        stdin: "Verified.", env: { "GITHUB_COMMENT_GH" => fake_gh }
      )

      refute_predicate result[:status], :success?
      assert_includes result[:stderr], "second attachment failed"
      assert_includes result[:stderr], "partial result: https://github.com/acme/widgets/pull/7#issuecomment-1"
    end
  end

  def test_post_issue_rejects_attachments_when_the_number_is_not_a_pull_request
    Dir.mktmpdir("comment-envelope-issue-attach") do |directory|
      fake_gh = File.join(directory, "gh")
      File.write(fake_gh, <<~RUBY)
        #!/usr/bin/env ruby
        warn "HTTP 404"
        exit 1
      RUBY
      File.chmod(0o755, fake_gh)

      result = run_cli(
        "post-issue", "--repo", "acme/widgets", "--number", "7",
        "--runner", "codex", "--host", "M5", "--task-or-run", "task-7",
        "--attach", "evidence.png", stdin: "Verified.", env: { "GITHUB_COMMENT_GH" => fake_gh }
      )

      refute_predicate result[:status], :success?
      assert_equal "attachments require a pull request: HTTP 404\n", result[:stderr]
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

  # Production break: an invalid command waits forever on a live stdin pipe
  # before the CLI reports its usage error.
  def test_invalid_command_fails_before_stdin_eof
    result = run_cli_with_open_stdin("unknown")

    refute result[:timed_out], "CLI waited for stdin EOF before rejecting the command"
    refute_predicate result[:status], :success?
    assert_empty result[:stdout]
    assert_equal "Usage: github-comment-envelope <post-issue|edit-issue|post-reply> [options]\n", result[:stderr]
  end

  # Production break: a known command with a missing required option waits on
  # a live stdin pipe before it reports the missing option.
  def test_missing_required_option_fails_before_stdin_eof
    result = run_cli_with_open_stdin(
      "post-issue", "--number", "7", "--runner", "codex", "--host", "M5", "--task-or-run", "task-7"
    )

    refute result[:timed_out], "CLI waited for stdin EOF before validating required options"
    refute_predicate result[:status], :success?
    assert_empty result[:stdout]
    assert_includes result[:stderr], "key not found: :repo"
  end

  private

  def metadata_free_outcome_envelope(payload)
    first_line, line_ending, remaining_payload = GitHubCommentEnvelope.split_payload(payload)
    body = <<~BODY
      🤖 Codex #{first_line}

      <details>
      <summary>Agent attribution</summary>

      ```text
      agent-comment-attribution:v1
      runner: codex
      host: M5
      task_or_run: task-7
      payload_first_line_b64url: #{Base64.urlsafe_encode64(first_line, padding: false)}
      payload_line_ending: #{GitHubCommentEnvelope::PAYLOAD_LINE_ENDINGS.fetch(line_ending)}
      ```
      </details>

      #{remaining_payload}
    BODY
    body.delete_suffix("\n")
  end

  def run_cli(*arguments, stdin: "", env: {})
    stdout, stderr, status = Open3.capture3(env, SCRIPT, *arguments, stdin_data: stdin)
    { stdout:, stderr:, status: }
  end

  def run_cli_with_open_stdin(*arguments)
    Open3.popen3(SCRIPT, *arguments) do |stdin, stdout, stderr, wait_thread|
      timed_out = false
      status = begin
        Timeout.timeout(5) { wait_thread.value }
      rescue Timeout::Error
        timed_out = true
        nil
      ensure
        stdin.close
      end
      status ||= wait_thread.value
      return { stdout: stdout.read, stderr: stderr.read, status:, timed_out: }
    end
  end
end
