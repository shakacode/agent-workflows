#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "time"
require "tmpdir"

# End-to-end tests for the stale-assignment sweep. A fake `gh` is written to a
# tmp dir and prepended to PATH; it serves canned issue/timeline fixtures and
# logs every invocation so mutation calls can be asserted (or their absence
# proven). The reference clock is injected via --now so the fixtures are
# deterministic. No real network or gh access happens.
class StaleAssignmentSweepTest < Minitest::Test
  SCRIPT = File.expand_path("stale-assignment-sweep", __dir__)
  NOW = Time.utc(2026, 7, 22)
  NOW_ISO = NOW.iso8601
  IDENTITY = "sweeper-bot"
  NUDGE_MARKER = "<!-- stale-assignment-sweep:nudge -->"

  # --- dry-run -----------------------------------------------------------

  def test_dry_run_makes_no_gh_mutations
    result, log = run_cli

    assert result.fetch(:status).success?, result.fetch(:stderr)
    refute_includes log, "/comments"
    refute_includes log, "DELETE"
    refute_includes log, "assignees[]"
    assert_includes result.fetch(:stdout), "DRY-RUN"
  end

  def test_dry_run_digest_lists_would_nudge_and_would_release_with_reasons
    result, = run_cli
    out = result.fetch(:stdout)

    assert_includes out, "WOULD NUDGE (4):"
    assert_includes out, "#1 issue @alice: time-to-first-activity 30d inactive >= ttl 7d"
    assert_includes out, "#9 PR @grace: inactivity-after-start 10d inactive >= ttl 7d"
    assert_includes out, "#13 issue @maintainer1: time-to-first-activity 30d inactive >= ttl 7d"

    assert_includes out, "WOULD RELEASE (2):"
    assert_includes out, "#2 issue @bob:"
    assert_includes out, "nudged 5d ago >= grace 4d"
  end

  def test_dry_run_reports_every_skip_reason
    result, = run_cli
    out = result.fetch(:stdout)

    assert_includes out, "#3 issue: nudged 2d ago, in grace (2d left)"
    assert_includes out, "#4 issue: renewed: assignee replied after nudge"
    assert_includes out, "#5 issue: exempt label (blocked) — clock paused"
    assert_includes out, "#6 issue: agent-claimed — owned by backend heartbeat leases"
    assert_includes out, "#7 issue: automation-only assignee (app-runner[bot]) — ignored"
    assert_includes out, "#8 issue: no assignee"
    assert_includes out, "#10 issue: active; inactivity-after-start 10d < ttl 14d"
    assert_includes out, "#12 issue: automation-only assignee (servicebot) — ignored"
  end

  # --- apply: nudge ------------------------------------------------------

  def test_apply_nudge_posts_a_comment
    _result, log = run_cli(apply: true)

    assert_includes log, "repos/owner/repo/issues/1/comments"
    assert_includes log, "Heads up @alice"
    assert_includes log, NUDGE_MARKER
    # A stale-but-unnudged item is nudged, never released.
    refute_includes log, "issues/1/assignees"
  end

  def test_apply_nudge_bodies_never_begin_with_at
    _result, log = run_cli(apply: true)

    log.each_line do |line|
      next unless line.include?("body=")

      body = line.split("body=", 2).last
      refute body.start_with?("@"), "comment body must not begin with '@': #{body.inspect}"
    end
  end

  # --- apply: release ----------------------------------------------------

  def test_apply_release_removes_assignee_and_posts_audit_comment
    result, log = run_cli(apply: true)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes log, "repos/owner/repo/issues/2/comments"
    assert_includes log, "Released @bob"
    assert_includes log, "-X DELETE repos/owner/repo/issues/2/assignees -f assignees[]=bob"
  end

  def test_release_requires_a_prior_nudge_and_respects_the_grace_window
    _result, log = run_cli(apply: true)

    # #3 was nudged only 2 days ago (< 4-day grace): no release yet.
    refute_includes log, "issues/3/assignees"
    # #1 is stale but never nudged: nudged, not released.
    refute_includes log, "issues/1/assignees"
  end

  def test_exempt_label_pauses_the_clock_with_no_nudge
    _result, log = run_cli(apply: true)

    refute_includes log, "issues/5/comments"
    refute_includes log, "issues/5/assignees"
  end

  def test_assignee_reply_after_nudge_resets_and_prevents_release
    _result, log = run_cli(apply: true)

    refute_includes log, "issues/4/assignees"
    refute_includes log, "issues/4/comments"
  end

  def test_agent_claimed_items_are_skipped_entirely
    _result, log = run_cli(apply: true)

    refute_includes log, "issues/6/comments"
    refute_includes log, "issues/6/assignees"
  end

  # --- automation set never swept ---------------------------------------

  def test_automation_assignees_are_never_swept
    _result, log = run_cli(apply: true)

    # Bot-suffixed and trusted_bots logins are never removed or nudged.
    refute_includes log, "assignees[]=app-runner[bot]"
    refute_includes log, "assignees[]=helper[bot]"
    refute_includes log, "assignees[]=servicebot"
    refute_includes log, "issues/7/comments"
    refute_includes log, "issues/12/comments"
  end

  def test_release_keeps_a_coassigned_automation_identity
    _result, log = run_cli(apply: true)

    # #14: judy (human) + helper[bot] (automation), nudged 5d ago -> release judy only.
    assert_includes log, "-X DELETE repos/owner/repo/issues/14/assignees -f assignees[]=judy"
    refute_includes log, "assignees[]=helper[bot]"
  end

  def test_unassigned_and_automation_only_items_are_ignored
    _result, log = run_cli(apply: true)

    refute_includes log, "issues/8/comments"
    refute_includes log, "issues/8/assignees"
  end

  # --- fail closed -------------------------------------------------------

  def test_unresolved_automation_set_fails_closed_with_no_mutations
    result, log = run_cli(apply: true, trust_config: "/nonexistent/trusted-github-actors.yml")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes result.fetch(:stdout), "UNRESOLVED"
    assert_includes result.fetch(:stdout), "fail-closed: automation set unresolved"
    refute_includes log, "/comments"
    refute_includes log, "DELETE"
  end

  def test_repo_with_a_leading_at_segment_is_rejected_before_any_gh_call
    result, log = run_cli(repo: "@evil/repo")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--repo must use OWNER/REPO form"
    refute_includes log, "issues?state=open"
  end

  # --- help --------------------------------------------------------------

  def test_help_exits_zero_and_documents_clocks
    out, _err, status = Open3.capture3(RUBY_BIN, SCRIPT, "--help")

    assert status.success?
    assert_includes out, "time-to-first-activity"
    assert_includes out, "inactivity-after-start"
  end

  private

  RUBY_BIN = "ruby"

  def days_ago(days)
    (NOW - (days * 86_400)).utc.iso8601
  end

  def run_cli(apply: false, trust_config: nil, repo: "owner/repo")
    Dir.mktmpdir("stale-assignment-sweep-test") do |dir|
      build_fixtures(dir)
      log_path = File.join(dir, "gh.log")
      args = [
        RUBY_BIN, SCRIPT,
        "--repo", repo,
        "--now", NOW_ISO,
        "--comment-identity", IDENTITY,
        "--trust-config", trust_config || File.join(dir, "trust.yml")
      ]
      args << "--apply" if apply
      stdout, stderr, status = Open3.capture3(cli_env(dir, log_path), *args)
      stdout = stdout.force_encoding("UTF-8")
      stderr = stderr.force_encoding("UTF-8")
      log = File.exist?(log_path) ? File.read(log_path, encoding: "UTF-8") : ""
      [{ stdout:, stderr:, status: }, log]
    end
  end

  def cli_env(dir, log_path)
    {
      "PATH" => "#{dir}:#{ENV.fetch('PATH')}",
      "GH_LOG" => log_path,
      "GH_FIXTURE_DIR" => dir
    }
  end

  def build_fixtures(dir)
    write_fake_gh(dir)
    write_trust_config(dir)
    File.write(File.join(dir, "list.json"), JSON.generate([list_items]))
    timelines.each do |number, events|
      File.write(File.join(dir, "timeline-#{number}.json"), JSON.generate([events]))
    end
  end

  def write_trust_config(dir)
    File.write(
      File.join(dir, "trust.yml"),
      "trusted_bots:\n  - servicebot\ntrusted_users:\n  - maintainer1\n"
    )
  end

  def write_fake_gh(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      log = ENV["GH_LOG"]
      File.open(log, "a") { |file| file.puts(ARGV.join(" ")) } if log
      argv = ARGV.join(" ")
      fixtures = ENV.fetch("GH_FIXTURE_DIR")
      if argv.include?("issues?state=open")
        print File.read(File.join(fixtures, "list.json"))
      elsif (match = argv.match(%r{issues/(\\d+)/timeline}))
        path = File.join(fixtures, "timeline-\#{match[1]}.json")
        print(File.exist?(path) ? File.read(path) : "[[]]")
      elsif argv.include?("/comments")
        print '{"id":1}'
      elsif argv.include?("assignees")
        print '{}'
      else
        warn "unexpected gh invocation: \#{argv}"
        exit 1
      end
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def list_items
    [
      issue(1, %w[alice]),
      issue(2, %w[bob]),
      issue(3, %w[carol]),
      issue(4, %w[dave]),
      issue(5, %w[erin], labels: %w[blocked]),
      issue(6, %w[frank], labels: %w[agent-claimed]),
      issue(7, ["app-runner[bot]"]),
      issue(8, []),
      pull(9, %w[grace]),
      issue(10, %w[heidi]),
      issue(11, ["ivan", "app-runner[bot]"]),
      issue(12, %w[servicebot]),
      issue(13, %w[maintainer1]),
      issue(14, ["judy", "helper[bot]"])
    ]
  end

  def issue(number, logins, labels: [])
    {
      "number" => number,
      "assignees" => logins.map { |login| { "login" => login } },
      "labels" => labels.map { |name| { "name" => name } },
      "html_url" => "https://github.com/owner/repo/issues/#{number}"
    }
  end

  def pull(number, logins, labels: [])
    issue(number, logins, labels:).merge("pull_request" => { "url" => "https://api" })
  end

  def timelines
    {
      1 => [assigned("alice", 30)],
      2 => [assigned("bob", 30), nudge(5)],
      3 => [assigned("carol", 30), nudge(2)],
      4 => [assigned("dave", 30), nudge(5), comment("dave", 1)],
      9 => [assigned("grace", 30), review("grace", 10)],
      10 => [assigned("heidi", 30), comment("heidi", 10)],
      11 => [assigned("ivan", 30)],
      13 => [assigned("maintainer1", 30)],
      14 => [assigned("judy", 30), nudge(5)]
    }
  end

  def assigned(login, days)
    {
      "event" => "assigned",
      "created_at" => days_ago(days),
      "assignee" => { "login" => login },
      "actor" => { "login" => "owner" }
    }
  end

  def comment(login, days)
    {
      "event" => "commented",
      "created_at" => days_ago(days),
      "actor" => { "login" => login },
      "user" => { "login" => login },
      "body" => "working on it"
    }
  end

  def review(login, days)
    {
      "event" => "reviewed",
      "submitted_at" => days_ago(days),
      "user" => { "login" => login },
      "state" => "COMMENTED",
      "body" => ""
    }
  end

  def nudge(days)
    {
      "event" => "commented",
      "created_at" => days_ago(days),
      "actor" => { "login" => IDENTITY },
      "user" => { "login" => IDENTITY },
      "body" => "Heads up — no activity.\n\n#{NUDGE_MARKER}"
    }
  end
end
