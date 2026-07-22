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
#
# The fake gh is stateful for one item (#18): its timeline changes between the
# first read (release candidate) and later reads (assignee reply appears), which
# exercises the pre-release re-check. A separate single-issue fixture (#17) adds
# an `agent-claimed` label only on the re-fetch.
class StaleAssignmentSweepTest < Minitest::Test
  SCRIPT = File.expand_path("stale-assignment-sweep", __dir__)
  RUBY_BIN = "ruby"
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

    assert_includes out, "WOULD NUDGE (10):"
    assert_includes out, "#1 issue @alice: time-to-first-activity 30d inactive >= ttl 7d"
    assert_includes out, "#9 PR @grace: inactivity-after-start 10d inactive >= ttl 7d"
    assert_includes out, "#13 issue @maintainer1: time-to-first-activity 30d inactive >= ttl 7d"

    assert_includes out, "WOULD RELEASE (4):"
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
    assert_includes out, "#12 issue: automation-only assignee (servicebot[bot]) — ignored"
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

  # --- Fix 1: nudge marker must be attributed to the sweep identity ------

  def test_forged_nudge_marker_from_another_login_does_not_trigger_release
    result, log = run_cli(apply: true)

    # #16 carries a nudge marker posted by `imposter`, not the sweep identity.
    assert_includes result.fetch(:stdout), "#16 issue @karl: time-to-first-activity 30d inactive >= ttl 7d"
    assert_includes log, "issues/16/comments"
    refute_includes log, "issues/16/assignees"
  end

  def test_marker_from_the_sweep_identity_counts_and_releases_after_grace
    _result, log = run_cli(apply: true)

    # #2's marker was posted by the sweep identity, so it is a valid prerequisite.
    assert_includes log, "assignees[]=bob"
  end

  def test_missing_comment_identity_is_auto_resolved_via_gh_user
    result, log = run_cli(apply: true, identity: nil)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes result.fetch(:stdout), "Sweep identity (nudge-marker set): #{IDENTITY}"
    # Auto-resolved identity matches the nudge author, so #2 still releases.
    assert_includes log, "-X DELETE repos/owner/repo/issues/2/assignees -f assignees[]=bob"
  end

  def test_unresolvable_identity_fails_closed_and_disables_releases
    result, log = run_cli(apply: true, identity: nil, gh_fail_user: true)

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes result.fetch(:stdout), "Sweep identity (nudge-marker set): UNRESOLVED"
    # No prior nudge can be verified, so nothing is released even under --apply...
    refute_includes log, "DELETE"
    refute_includes log, "Released @"
    # ...but nudging and reporting still proceed.
    assert_includes log, "issues/1/comments"
  end

  def test_mismatched_comment_identity_still_recognizes_own_nudge_and_warns
    result, log = run_cli(apply: true, identity: "other-bot")

    # A --comment-identity that isn't the real gh poster must not hide the sweep's
    # own gh-posted nudges (else the item is re-nudged forever, never released).
    assert_includes result.fetch(:stderr), "differs from the gh-authenticated login"
    assert_includes result.fetch(:stdout), "Sweep identity (nudge-marker set): #{IDENTITY}, other-bot"
    # The union includes the real gh login, so #2's nudge is recognized -> release.
    assert_includes log, "-X DELETE repos/owner/repo/issues/2/assignees -f assignees[]=bob"
  end

  # --- Fix 2: revalidate immediately before each release ----------------

  def test_release_aborted_when_recheck_shows_an_added_agent_claimed_label
    result, log = run_cli(apply: true)

    assert_includes result.fetch(:stdout), "SKIPPED release #17 on re-check"
    assert_includes result.fetch(:stdout), "agent-claimed"
    refute_includes log, "issues/17/assignees"
    refute_includes log, "issues/17/comments"
  end

  def test_release_aborted_when_recheck_shows_an_assignee_reply
    result, log = run_cli(apply: true)

    assert_includes result.fetch(:stdout), "SKIPPED release #18 on re-check"
    assert_includes result.fetch(:stdout), "renewed: assignee replied after nudge"
    refute_includes log, "issues/18/assignees"
    refute_includes log, "issues/18/comments"
  end

  # --- Fix A: revalidate before a nudge too -----------------------------

  def test_nudge_aborted_when_recheck_shows_an_added_exempt_label
    result, log = run_cli(apply: true)

    # #21 was a nudge in the snapshot; a `blocked` label appears on re-fetch.
    assert_includes result.fetch(:stdout), "SKIPPED nudge #21 on re-check"
    assert_includes result.fetch(:stdout), "exempt label (blocked) — clock paused"
    refute_includes log, "issues/21/comments"
  end

  # --- Fix B: only login-bearing timeline events renew a lease ----------

  def test_cross_referenced_event_by_the_assignee_renews_the_lease
    result, log = run_cli(apply: true)

    # #19: a cross-referenced event by the assignee 2d ago is recent activity.
    assert_includes result.fetch(:stdout), "#19 issue: active; inactivity-after-start 2d < ttl 14d"
    refute_includes log, "issues/19/comments"
    refute_includes log, "issues/19/assignees"
  end

  def test_committed_event_without_a_login_does_not_renew_the_lease
    result, log = run_cli(apply: true)

    # #20's only "activity" is a raw commit (no GitHub login), so it does not
    # count: the item is still nudged on the first-activity clock.
    assert_includes result.fetch(:stdout), "#20 issue @omar: time-to-first-activity 30d inactive >= ttl 7d"
    assert_includes log, "issues/20/comments"
  end

  # --- Fix 3: automation requires the [bot] suffix ----------------------

  def test_automation_assignees_are_never_swept
    _result, log = run_cli(apply: true)

    # Bot-suffixed logins whose base is in trusted_bots are never removed/nudged.
    refute_includes log, "assignees[]=app-runner[bot]"
    refute_includes log, "assignees[]=helper[bot]"
    refute_includes log, "assignees[]=servicebot[bot]"
    refute_includes log, "issues/7/comments"
    refute_includes log, "issues/12/comments"
  end

  def test_bare_login_matching_a_trusted_bot_base_name_is_human_and_swept
    result, log = run_cli(apply: true)

    # `claude` is in trusted_bots, but a BARE `claude` (no [bot] suffix) is human.
    assert_includes result.fetch(:stdout), "#15 issue @claude: time-to-first-activity 30d inactive >= ttl 7d"
    refute_includes result.fetch(:stdout), "#15 issue: automation-only"
    assert_includes log, "issues/15/comments"
  end

  def test_release_keeps_a_coassigned_automation_identity
    _result, log = run_cli(apply: true)

    # #14: judy (human) + helper[bot] (automation), nudged 5d ago -> release judy only.
    assert_includes log, "-X DELETE repos/owner/repo/issues/14/assignees -f assignees[]=judy"
    refute_includes log, "assignees[]=helper[bot]"
  end

  # --- Fix D: multiple human assignees are reserved for manual review ----

  def test_multi_human_assignee_item_is_reserved_and_never_swept
    result, log = run_cli(apply: true)

    # #22: quinn (active) + rob (inactive). Even under --apply it is only reported.
    assert_includes result.fetch(:stdout),
                    "#22 issue: reserved (2 human assignees) — manual review; per-assignee decay is out of scope"
    refute_includes log, "issues/22/comments"
    refute_includes log, "issues/22/assignees"
  end

  def test_unassigned_and_automation_only_items_are_ignored
    _result, log = run_cli(apply: true)

    refute_includes log, "issues/8/comments"
    refute_includes log, "issues/8/assignees"
  end

  # --- fail closed on unresolved automation set -------------------------

  def test_unresolved_automation_set_fails_closed_with_no_mutations
    result, log = run_cli(apply: true, trust_config: "/nonexistent/trusted-github-actors.yml")

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes result.fetch(:stdout), "UNRESOLVED"
    assert_includes result.fetch(:stdout), "fail-closed: automation set unresolved"
    refute_includes log, "/comments"
    refute_includes log, "DELETE"
  end

  # --- Fix E: closed/merged items are skipped ---------------------------

  def test_item_closed_between_listing_and_apply_is_not_swept
    result, log = run_cli(apply: true)

    # #23 is a nudge in the snapshot but closed on the pre-nudge re-fetch.
    assert_includes result.fetch(:stdout), "SKIPPED nudge #23 on re-check: item is closed — skipped"
    refute_includes log, "issues/23/comments"
    refute_includes log, "issues/23/assignees"
  end

  # --- Fix F: --exempt-label adds to the defaults -----------------------

  def test_exempt_label_flag_layers_on_top_of_the_defaults
    result, log = run_cli(apply: true, extra_args: ["--exempt-label", "needs-design"])
    out = result.fetch(:stdout)

    # The built-in default still applies...
    assert_includes out, "#5 issue: exempt label (blocked) — clock paused"
    # ...and the added label now exempts #24 (a nudge without the flag).
    assert_includes out, "#24 issue: exempt label (needs-design) — clock paused"
    refute_includes log, "issues/24/comments"
  end

  # --- Fix G: a gh failure degrades gracefully --------------------------

  def test_one_item_read_failure_is_reported_without_aborting_the_run
    result, = run_cli

    assert result.fetch(:status).success?, result.fetch(:stderr)
    out = result.fetch(:stdout)
    # #25's timeline fetch fails; it is reported, not fatal...
    assert_includes out, "#25 issue: UNKNOWN:"
    assert_includes out, "skipped"
    # ...and the rest of the digest still prints.
    assert_includes out, "WOULD NUDGE (10):"
    assert_includes out, "#1 issue @alice:"
  end

  def test_one_failing_repo_does_not_abort_the_others
    result, = run_cli(repos: ["failrepo/x", "owner/repo"])

    assert result.fetch(:status).success?, result.fetch(:stderr)
    assert_includes result.fetch(:stderr), "repo failrepo/x skipped"
    # The second repo still produces its digest.
    assert_includes result.fetch(:stdout), "Repo owner/repo — stale-assignment sweep"
    assert_includes result.fetch(:stdout), "WOULD NUDGE"
  end

  # --- misc --------------------------------------------------------------

  def test_repo_with_a_leading_at_segment_is_rejected_before_any_gh_call
    result, log = run_cli(repo: "@evil/repo")

    refute result.fetch(:status).success?
    assert_includes result.fetch(:stderr), "--repo must use OWNER/REPO form"
    refute_includes log, "issues?state=open"
  end

  def test_help_exits_zero_and_documents_clocks
    out, _err, status = Open3.capture3(RUBY_BIN, SCRIPT, "--help")

    assert status.success?
    assert_includes out, "time-to-first-activity"
    assert_includes out, "inactivity-after-start"
  end

  private

  def days_ago(days)
    (NOW - (days * 86_400)).utc.iso8601
  end

  def run_cli(apply: false, trust_config: nil, repo: "owner/repo", repos: nil, identity: IDENTITY,
              gh_fail_user: false, extra_args: [])
    Dir.mktmpdir("stale-assignment-sweep-test") do |dir|
      build_fixtures(dir)
      log_path = File.join(dir, "gh.log")
      args = [RUBY_BIN, SCRIPT, "--now", NOW_ISO, "--trust-config", trust_config || File.join(dir, "trust.yml")]
      Array(repos || [repo]).each { |value| args.concat(["--repo", value]) }
      args.concat(["--comment-identity", identity]) if identity
      args.concat(extra_args)
      args << "--apply" if apply
      stdout, stderr, status = Open3.capture3(cli_env(dir, log_path, gh_fail_user), *args)
      stdout = stdout.force_encoding("UTF-8")
      stderr = stderr.force_encoding("UTF-8")
      log = File.exist?(log_path) ? File.read(log_path, encoding: "UTF-8") : ""
      [{ stdout:, stderr:, status: }, log]
    end
  end

  def cli_env(dir, log_path, gh_fail_user)
    env = {
      "PATH" => "#{dir}:#{ENV.fetch('PATH')}",
      "GH_LOG" => log_path,
      "GH_FIXTURE_DIR" => dir
    }
    env["GH_FAIL_USER"] = "1" if gh_fail_user
    env
  end

  def build_fixtures(dir)
    write_fake_gh(dir)
    write_trust_config(dir)
    File.write(File.join(dir, "list.json"), JSON.generate([list_items]))
    timelines.each do |number, events|
      File.write(File.join(dir, "timeline-#{number}.json"), JSON.generate([events]))
    end
    # #17: re-fetch adds an agent-claimed label after the snapshot classified it
    # as a release. #18: re-fetched timeline gains an assignee reply. #21: re-fetch
    # adds an exempt label after the snapshot classified it as a nudge. #23: the
    # item is closed on re-fetch. #25: the fake gh fails its timeline read.
    File.write(File.join(dir, "issue-17.json"), JSON.generate(issue(17, %w[laura], labels: %w[agent-claimed])))
    File.write(File.join(dir, "issue-21.json"), JSON.generate(issue(21, %w[pat], labels: %w[blocked])))
    File.write(File.join(dir, "issue-23.json"), JSON.generate(issue(23, %w[sam], state: "closed")))
    File.write(File.join(dir, "fail-timeline-25"), "")
    File.write(
      File.join(dir, "timeline-18-recheck.json"),
      JSON.generate([[assigned("mona", 30), nudge(5), comment("mona", 1)]])
    )
  end

  def write_trust_config(dir)
    File.write(
      File.join(dir, "trust.yml"),
      <<~YAML
        trusted_bots:
          - app-runner
          - helper
          - servicebot
          - claude
        trusted_users:
          - maintainer1
      YAML
    )
  end

  def write_fake_gh(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      require "json"
      log = ENV["GH_LOG"]
      File.open(log, "a") { |file| file.puts(ARGV.join(" ")) } if log
      argv = ARGV.join(" ")
      fixtures = ENV.fetch("GH_FIXTURE_DIR")

      if argv.include?("api user")
        if ENV["GH_FAIL_USER"]
          warn "gh: authentication required"
          exit 1
        end
        print "#{IDENTITY}\\n"
      elsif argv.include?("issues?state=open")
        if argv.include?("failrepo")
          warn "gh: simulated listing failure"
          exit 1
        end
        print File.read(File.join(fixtures, "list.json"))
      elsif (match = argv.match(%r{issues/(\\d+)/timeline}))
        number = match[1]
        if File.exist?(File.join(fixtures, "fail-timeline-\#{number}"))
          warn "gh: simulated timeline failure for \#{number}"
          exit 1
        end
        base = File.join(fixtures, "timeline-\#{number}.json")
        recheck = File.join(fixtures, "timeline-\#{number}-recheck.json")
        if File.exist?(recheck)
          counter = File.join(fixtures, "reads-\#{number}")
          reads = File.exist?(counter) ? File.read(counter).to_i : 0
          File.write(counter, (reads + 1).to_s)
          path = reads.zero? ? base : recheck
        else
          path = base
        end
        print(File.exist?(path) ? File.read(path) : "[[]]")
      elsif argv.include?("/comments")
        print '{"id":1}'
      elsif argv.include?("assignees")
        print '{}'
      elsif (match = argv.match(%r{issues/(\\d+)$}))
        override = File.join(fixtures, "issue-\#{match[1]}.json")
        if File.exist?(override)
          print File.read(override)
        else
          list = JSON.parse(File.read(File.join(fixtures, "list.json"))).flatten
          print JSON.generate(list.find { |item| item["number"].to_s == match[1] })
        end
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
      issue(12, ["servicebot[bot]"]),
      issue(13, %w[maintainer1]),
      issue(14, ["judy", "helper[bot]"]),
      issue(15, %w[claude]),
      issue(16, %w[karl]),
      issue(17, %w[laura]),
      issue(18, %w[mona]),
      issue(19, %w[nora]),
      issue(20, %w[omar]),
      issue(21, %w[pat]),
      issue(22, %w[quinn rob]),
      issue(23, %w[sam]),
      issue(24, %w[tara], labels: %w[needs-design]),
      issue(25, %w[uma])
    ]
  end

  def issue(number, logins, labels: [], state: "open")
    {
      "number" => number,
      "state" => state,
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
      14 => [assigned("judy", 30), nudge(5)],
      15 => [assigned("claude", 30)],
      16 => [assigned("karl", 30), nudge(5, "imposter")],
      17 => [assigned("laura", 30), nudge(5)],
      18 => [assigned("mona", 30), nudge(5)],
      19 => [assigned("nora", 30), cross_referenced("nora", 2)],
      20 => [assigned("omar", 30), committed_without_login(1)],
      21 => [assigned("pat", 30)],
      # quinn is active, rob is not; the item is still reserved (2 human assignees)
      # and never reaches this timeline (multi-human short-circuits before it).
      22 => [assigned("quinn", 30), assigned("rob", 30), comment("quinn", 2)],
      23 => [assigned("sam", 30)],
      24 => [assigned("tara", 30)]
      # 25 has no timeline fixture: the fake gh fails its timeline fetch (Fix G).
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

  # A commit or PR that references the issue: carries the pusher's actor login.
  def cross_referenced(login, days)
    {
      "event" => "cross-referenced",
      "created_at" => days_ago(days),
      "actor" => { "login" => login }
    }
  end

  # GitHub's timeline `committed` shape: git author/committer only, no GitHub
  # login — so it can never be attributed to an assignee.
  def committed_without_login(days)
    {
      "event" => "committed",
      "author" => { "name" => "Omar Dev", "email" => "omar@example.com", "date" => days_ago(days) },
      "committer" => { "name" => "Omar Dev", "email" => "omar@example.com", "date" => days_ago(days) }
    }
  end

  def nudge(days, author = IDENTITY)
    {
      "event" => "commented",
      "created_at" => days_ago(days),
      "actor" => { "login" => author },
      "user" => { "login" => author },
      "body" => "Heads up — no activity.\n\n#{NUDGE_MARKER}"
    }
  end
end
