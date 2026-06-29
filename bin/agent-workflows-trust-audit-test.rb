#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "shellwords"
require "tmpdir"

SCRIPT = File.expand_path("agent-workflows-trust-audit", __dir__)

class AgentWorkflowsTrustAuditTest < Minitest::Test
  def test_blocked_preflight_suggests_bot_and_write_user_candidates
    with_fake_commands("blocked") do |env, preflight_path|
      out, status = run_script(env, preflight_path)

      refute status.success?, out
      assert_equal 2, status.exitstatus
      assert_includes out, "Merged PR sample: #347, #363"
      assert_includes out, "Preflight status: SECURITY_PREFLIGHT_BLOCKED"
      assert_includes out, "  - #363: untrusted-interactions"
      assert_includes out, "  - ihabadham"
      assert_includes out, "  - chatgpt-codex-connector"
      assert_includes out, "  - greptile-apps"
      assert_includes out, "  - Copilot: permission=none"
      assert_includes out, "  - hiddenbot[bot]: permission=unknown; prs=#363; interactions=participant"
      assert_includes out, "  - write-only-user: permission=write; prs=#347; interactions=participant"
      refute_includes out, "  - hiddenbot\n"
      refute_includes out, "  - write-only-user\n"
    end
  end

  def test_clean_preflight_exits_successfully
    with_fake_commands("ok") do |env, preflight_path|
      out, status = run_script(env, preflight_path)

      assert status.success?, out
      assert_includes out, "Preflight status: SECURITY_PREFLIGHT_OK"
      assert_includes out, "Blocking risks: none"
      assert_includes out, "trusted_users:\n  []"
      assert_includes out, "trusted_bots:\n  []"
    end
  end

  def test_acknowledged_findings_are_not_reported_as_blocking_risks
    with_fake_commands("acknowledged") do |env, preflight_path|
      out, status = run_script(env, preflight_path)

      assert status.success?, out
      assert_includes out, "Preflight status: SECURITY_PREFLIGHT_OK"
      assert_includes out, "Blocking risks: none"
      refute_includes out, "  - #363: untrusted-interactions"
    end
  end

  def test_unknown_blocking_risk_message_warns
    with_fake_commands("unknown-risk") do |env, preflight_path|
      out, status = run_script(env, preflight_path)

      refute status.success?, out
      assert_includes out, "WARN: unknown pr-security-preflight risk message: renamed risk text"
      assert_includes out, "  - #363: unknown (renamed risk text)"
    end
  end

  def test_json_output_contains_candidates
    with_fake_commands("blocked") do |env, preflight_path|
      out, status = run_script(env, preflight_path, "--json")
      payload = JSON.parse(out)

      refute status.success?, out
      assert_equal "owner/repo", payload.fetch("repo")
      assert_equal "SECURITY_PREFLIGHT_BLOCKED", payload.fetch("preflight_status")
      assert_includes payload.dig("candidate_trust", "trusted_users"), "ihabadham"
      assert_includes payload.dig("candidate_trust", "trusted_bots"), "greptile-apps"
      assert_equal ["untrusted-interactions"], payload.fetch("risks").map { |risk| risk.fetch("risk_id") }.uniq
      assert_includes payload.fetch("manual_review_actors").map { |actor| actor.fetch("login") }, "hiddenbot[bot]"
    end
  end

  def test_preflight_operational_failure_is_not_reported_as_security_block
    with_fake_commands("error") do |env, preflight_path|
      out, status = run_script(env, preflight_path)

      refute status.success?, out
      assert_equal 1, status.exitstatus
      assert_includes out, "Preflight status: PREFLIGHT_ERROR"
      assert_includes out, "Blocking risks: unavailable because preflight did not complete"
      assert_includes out, "Candidate repo-local trust entries: unavailable"
      refute_includes out, "Preflight status: SECURITY_PREFLIGHT_BLOCKED"
    end
  end

  def test_json_preflight_operational_failure_suppresses_candidates
    with_fake_commands("partial-error") do |env, preflight_path|
      out, status = run_script(env, preflight_path, "--json")
      payload = JSON.parse(out)

      refute status.success?, out
      assert_equal 1, status.exitstatus
      assert_equal "PREFLIGHT_ERROR", payload.fetch("preflight_status")
      assert_equal true, payload.fetch("candidate_trust").fetch("unavailable")
      assert_empty payload.dig("candidate_trust", "trusted_users")
      assert_empty payload.dig("candidate_trust", "trusted_bots")
      assert_empty payload.fetch("manual_review_actors")
    end
  end

  private

  def run_script(env, preflight_path, *extra_args)
    Open3.capture2e(
      env,
      "ruby",
      SCRIPT,
      "--repo",
      "owner/repo",
      "--limit",
      "2",
      "--trust-config",
      "/tmp/trusted.yml",
      "--preflight",
      preflight_path,
      *extra_args
    )
  end

  def with_fake_commands(mode)
    Dir.mktmpdir("agent-workflows-trust-audit-test") do |dir|
      gh_path = File.join(dir, "gh")
      preflight_path = File.join(dir, "pr-security-preflight")
      File.write(gh_path, fake_gh_script)
      File.write(preflight_path, fake_preflight_script(mode))
      FileUtils.chmod(0o755, gh_path)
      FileUtils.chmod(0o755, preflight_path)

      env = { "PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}" }
      yield env, preflight_path
    end
  end

  def fake_gh_script
    <<~SH
      #!/usr/bin/env bash
      set -euo pipefail

      if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1" ]; then
        cat <<'JSON'
      [
        {
          "number":363,
          "title":"Deploy review app",
          "html_url":"https://github.com/owner/repo/pull/363",
          "merged_at":"2026-05-01T00:00:00Z",
          "updated_at":"2026-06-02T00:00:00Z"
        },
        {
          "number":999,
          "title":"Closed unmerged",
          "html_url":"https://github.com/owner/repo/pull/999",
          "merged_at":null,
          "updated_at":"2026-06-01T12:00:00Z"
        },
        {
          "number":347,
          "title":"Docs update",
          "html_url":"https://github.com/owner/repo/pull/347",
          "merged_at":"2026-06-01T00:00:00Z",
          "updated_at":"2026-06-01T00:00:00Z"
        },
        {
          "number":301,
          "title":"Older merged",
          "html_url":"https://github.com/owner/repo/pull/301",
          "merged_at":"2026-04-01T00:00:00Z",
          "updated_at":"2026-04-01T00:00:00Z"
        }
      ]
      JSON
        exit 0
      fi

      if [ "$1" = "api" ] && [ "$2" = "repos/owner/repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=2" ]; then
        printf '[]'
        exit 0
      fi

      printf 'unexpected gh call: %s\\n' "$*" >&2
      exit 1
    SH
  end

  def fake_preflight_script(mode)
    ok_output = <<~TEXT
      PR #363
        URL: https://github.com/owner/repo/pull/363
        Untrusted or hidden participant findings: none
        Untrusted comment/review queue: none

      PR #347
        URL: https://github.com/owner/repo/pull/347
        Untrusted or hidden participant findings: none
        Untrusted comment/review queue: none

      SECURITY_PREFLIGHT_OK
    TEXT
    acknowledged_output = <<~TEXT
      PR #363
        URL: https://github.com/owner/repo/pull/363
        Untrusted or hidden participant findings:
          - Copilot: no visible comment/review/commit/reaction trail; not in trusted actor allowlist; permission=none
        Untrusted comment/review queue:
          - greptile-apps[bot] issue comment (https://github.com/owner/repo/pull/363#issuecomment-1)

      Acknowledged security preflight findings:
      - #363: untrusted comment/review author(s)
      SECURITY_PREFLIGHT_OK
    TEXT
    blocked_output = <<~TEXT
      PR #363
        URL: https://github.com/owner/repo/pull/363
        Untrusted or hidden participant findings:
          - Copilot: no visible comment/review/commit/reaction trail; not in trusted actor allowlist; permission=none
          - hiddenbot[bot]: no visible comment/review/commit/reaction trail; not in trusted actor allowlist; permission=unknown
        Untrusted comment/review queue:
          - greptile-apps[bot] issue comment (https://github.com/owner/repo/pull/363#issuecomment-1)
          - chatgpt-codex-connector[bot] review comment (https://github.com/owner/repo/pull/363#discussion_r1)

      PR #347
        URL: https://github.com/owner/repo/pull/347
        Untrusted or hidden participant findings:
          - ihabadham: not in trusted actor allowlist; permission=write
          - write-only-user: no visible comment/review/commit/reaction trail; not in trusted actor allowlist; permission=write
        Untrusted comment/review queue:
          - ihabadham issue comment (https://github.com/owner/repo/pull/347#issuecomment-2)

      SECURITY_PREFLIGHT_BLOCKED
      - #363: untrusted comment/review author(s)
      - #347: untrusted comment/review author(s)
    TEXT
    unknown_risk_output = <<~TEXT
      PR #363
        URL: https://github.com/owner/repo/pull/363
        Untrusted or hidden participant findings: none
        Untrusted comment/review queue: none

      SECURITY_PREFLIGHT_BLOCKED
      - #363: renamed risk text
    TEXT
    output = case mode
             when "ok"
               ok_output
             when "acknowledged"
               acknowledged_output
             when "unknown-risk"
               unknown_risk_output
             when "error"
               "gh auth failed\n"
             when "partial-error"
               blocked_output
             else
               blocked_output
             end
    exit_status = if %w[ok acknowledged].include?(mode)
                    0
                  elsif mode == "error"
                    1
                  elsif mode == "partial-error"
                    1
                  else
                    2
                  end

    <<~SH
      #!/usr/bin/env bash
      printf '%s' #{Shellwords.escape(output)}
      exit #{exit_status}
    SH
  end
end
