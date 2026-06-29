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
      assert_includes out, "Merged PR sample: #363, #347"
      assert_includes out, "Preflight status: SECURITY_PREFLIGHT_BLOCKED"
      assert_includes out, "  - #363: untrusted-interactions"
      assert_includes out, "  - ihabadham"
      assert_includes out, "  - chatgpt-codex-connector"
      assert_includes out, "  - greptile-apps"
      assert_includes out, "  - Copilot: permission=none"
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

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        cat <<'JSON'
      [
        {"number":363,"title":"Deploy review app","url":"https://github.com/owner/repo/pull/363","mergedAt":"2026-06-01T00:00:00Z"},
        {"number":347,"title":"Docs update","url":"https://github.com/owner/repo/pull/347","mergedAt":"2026-05-01T00:00:00Z"}
      ]
      JSON
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
        Untrusted comment/review queue:
          - greptile-apps[bot] issue comment (https://github.com/owner/repo/pull/363#issuecomment-1)
          - chatgpt-codex-connector[bot] review comment (https://github.com/owner/repo/pull/363#discussion_r1)

      PR #347
        URL: https://github.com/owner/repo/pull/347
        Untrusted or hidden participant findings:
          - ihabadham: not in trusted actor allowlist; permission=write
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
             else
               blocked_output
             end
    exit_status = %w[ok acknowledged].include?(mode) ? 0 : 2

    <<~SH
      #!/usr/bin/env bash
      printf '%s' #{Shellwords.escape(output)}
      exit #{exit_status}
    SH
  end
end
