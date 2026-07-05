#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "minitest/autorun"

SCRIPT = File.expand_path("pr-check-completion-timing", __dir__)

class PrCheckCompletionTimingTest < Minitest::Test
  def with_fake_gh(pr_json:, checks_json:, checks_status: 0)
    Dir.mktmpdir("pr-check-completion-timing-test") do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
          printf 'owner/repo'
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
          cat <<'JSON'
        #{pr_json}
        JSON
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
          cat <<'JSON'
        #{checks_json}
        JSON
          exit #{checks_status}
        fi
        echo "unexpected gh invocation: $*" >&2
        exit 1
      BASH
      FileUtils.chmod(0o755, gh)
      env = { "PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}" }
      yield env
    end
  end

  def run_script(env, *)
    Open3.capture2e(env, "ruby", SCRIPT, *)
  end

  def test_flags_selected_check_completed_after_merge
    pr_json = JSON.generate("number" => 123, "mergedAt" => "2026-07-03T09:00:00Z")
    checks_json = JSON.generate([
                                  { "name" => "hosted linux", "workflow" => "Hosted CI",
                                    "bucket" => "pass", "completedAt" => "2026-07-03T09:02:00Z",
                                    "link" => "https://example.test/check/1" },
                                  { "name" => "unit", "workflow" => "CI",
                                    "bucket" => "pass", "completedAt" => "2026-07-03T08:50:00Z" }
                                ])

    with_fake_gh(pr_json:, checks_json:) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--select-name", "hosted")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "LATE_SELECTED_CHECKS", data.fetch("verdict")
      assert_equal(["hosted linux"], data.fetch("late").map { |row| row.fetch("name") })
    end
  end

  def test_passes_when_selected_checks_finished_before_merge
    pr_json = JSON.generate("number" => 123, "mergedAt" => "2026-07-03T09:00:00Z")
    checks_json = JSON.generate([
                                  { "name" => "hosted linux", "workflow" => "Hosted CI",
                                    "bucket" => "pass", "completedAt" => "2026-07-03T08:59:00Z" }
                                ])

    with_fake_gh(pr_json:, checks_json:) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--select-workflow", "Hosted")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NO_LATE_SELECTED_CHECKS", data.fetch("verdict")
      assert_empty data.fetch("late")
    end
  end

  def test_no_selected_checks_is_unknown
    pr_json = JSON.generate("number" => 123, "mergedAt" => "2026-07-03T09:00:00Z")
    checks_json = JSON.generate([{ "name" => "unit", "workflow" => "CI", "bucket" => "pass" }])

    with_fake_gh(pr_json:, checks_json:) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--select-name", "hosted")
      assert status.success?, out
      assert_equal "UNKNOWN", JSON.parse(out).fetch("verdict")
    end
  end

  def test_pending_selected_check_is_non_clean_when_gh_exits_pending
    pr_json = JSON.generate("number" => 123, "mergedAt" => "2026-07-03T09:00:00Z")
    checks_json = JSON.generate([
                                  { "name" => "hosted linux", "workflow" => "Hosted CI",
                                    "bucket" => "pending", "completedAt" => "" }
                                ])

    with_fake_gh(pr_json:, checks_json:, checks_status: 8) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--select-name", "hosted")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "SELECTED_CHECKS_PENDING", data.fetch("verdict")
      assert_equal(["hosted linux"], data.fetch("pending").map { |row| row.fetch("name") })
    end
  end

  def test_failing_selected_check_is_non_clean
    pr_json = JSON.generate("number" => 123, "mergedAt" => "2026-07-03T09:00:00Z")
    checks_json = JSON.generate([
                                  { "name" => "hosted linux", "workflow" => "Hosted CI",
                                    "bucket" => "fail", "completedAt" => "2026-07-03T08:58:00Z" }
                                ])

    with_fake_gh(pr_json:, checks_json:, checks_status: 1) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--select-workflow", "Hosted")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "SELECTED_CHECKS_FAILED", data.fetch("verdict")
      assert_equal(["hosted linux"], data.fetch("failing").map { |row| row.fetch("name") })
    end
  end

  def test_cancelled_selected_check_is_non_clean_even_before_merge
    pr_json = JSON.generate("number" => 123, "mergedAt" => "2026-07-03T09:00:00Z")
    checks_json = JSON.generate([
                                  { "name" => "hosted linux", "workflow" => "Hosted CI",
                                    "bucket" => "cancel", "completedAt" => "2026-07-03T08:58:00Z" }
                                ])

    with_fake_gh(pr_json:, checks_json:, checks_status: 1) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--select-workflow", "Hosted")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "SELECTED_CHECKS_FAILED", data.fetch("verdict")
      assert_equal(["hosted linux"], data.fetch("failing").map { |row| row.fetch("name") })
      assert_empty data.fetch("late")
    end
  end
end
