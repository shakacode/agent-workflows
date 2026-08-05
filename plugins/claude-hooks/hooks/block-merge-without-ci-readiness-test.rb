#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

require_relative "lib/shell_command_scan"

HOOK = File.expand_path("block-merge-without-ci-readiness", __dir__)
PACK_ROOT = File.expand_path("../../..", __dir__)

class BlockMergeWithoutCiReadinessTest < Minitest::Test
  BLOCK = 2
  ALLOW = 0

  # --- the gate actually blocks -------------------------------------------

  def test_blocks_a_merge_when_the_validator_reports_not_ready
    with_stubs(stdout: verdict("NOT_READY", failing: ["build"], pending: ["lint"])) do |env, calls|
      status, stderr = run_hook("gh pr merge 7 --squash", env)

      assert_equal BLOCK, status.exitstatus, "expected the hook to block the merge"
      assert_includes stderr, "readiness for PR #7 is NOT_READY"
      assert_includes stderr, "failing: build"
      assert_includes stderr, "pending: lint"
      assert_equal [["7", "--json"]], validator_calls(calls)
    end
  end

  def test_blocks_a_merge_when_readiness_is_unknown
    with_stubs(stdout: verdict("UNKNOWN")) do |env, _calls|
      status, stderr = run_hook("gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "readiness for PR #7 is UNKNOWN"
    end
  end

  def test_blocks_when_pending_review_drafts_are_the_only_blocker
    payload = { "verdict" => "NOT_READY", "viewer_pending_review_drafts" => [{ "id" => "PRR_1" }] }
    with_stubs(stdout: payload.to_json) do |env, _calls|
      status, stderr = run_hook("gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "pending review drafts: 1"
    end
  end

  # --- fail closed on every inconclusive readiness answer -------------------

  def test_blocks_when_the_validator_exits_non_zero
    with_stubs(stdout: "", stderr: "gh: not authenticated", exit_code: 1) do |env, _calls|
      status, stderr = run_hook("gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "could not run"
      assert_includes stderr, "gh: not authenticated"
    end
  end

  def test_blocks_when_the_validator_prints_unreadable_output
    with_stubs(stdout: "not json at all") do |env, _calls|
      status, stderr = run_hook("gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "unreadable output"
    end
  end

  def test_blocks_when_the_validator_exceeds_its_deadline
    with_stubs(stdout: verdict("READY"), sleep_seconds: 10) do |env, _calls|
      env["AGENT_WORKFLOWS_MERGE_GATE_TIMEOUT_SECONDS"] = "0.4"
      status, stderr = run_hook("gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "timed out"
    end
  end

  # Regression: the two subprocess stages used to get independent budgets, so a
  # slow `gh pr view` followed by a slow readiness check could run past the
  # timeout hooks.json registers for this adapter. They now share one deadline.
  def test_shared_deadline_bounds_the_combined_resolution_and_readiness_path
    with_stubs(stdout: verdict("READY"), sleep_seconds: 30, gh_stdout: "42", gh_sleep_seconds: 0.6) do |env, _calls|
      # Stage timeout deliberately far larger than the total budget: before the
      # fix this path took gh(0.6s) + validator(30s capped at 60s stage) and the
      # budget was never consulted.
      env["AGENT_WORKFLOWS_MERGE_GATE_TIMEOUT_SECONDS"] = "60"
      env["AGENT_WORKFLOWS_MERGE_GATE_TOTAL_BUDGET_SECONDS"] = "1.5"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, stderr = run_hook("gh pr merge", env)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal BLOCK, status.exitstatus, "the combined slow path must still block"
      assert_operator elapsed, :<, 15,
                      "hook took #{elapsed.round(1)}s; it must finish inside its shared budget, not stack per-stage timeouts"
      assert_includes stderr, "PR #42"
    end
  end

  def test_stage_timeout_is_clamped_to_the_total_budget
    with_stubs(stdout: verdict("READY"), sleep_seconds: 30) do |env, _calls|
      env["AGENT_WORKFLOWS_MERGE_GATE_TIMEOUT_SECONDS"] = "300"
      env["AGENT_WORKFLOWS_MERGE_GATE_TOTAL_BUDGET_SECONDS"] = "1.0"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, stderr = run_hook("gh pr merge 7", env)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal BLOCK, status.exitstatus
      assert_operator elapsed, :<, 15, "an operator-raised stage timeout must not escape the total budget"
      assert_includes stderr, "timed out"
    end
  end

  def test_blocks_when_the_budget_is_exhausted_before_the_readiness_check
    with_stubs(stdout: verdict("READY"), gh_stdout: "42", gh_sleep_seconds: 1.2) do |env, calls|
      env["AGENT_WORKFLOWS_MERGE_GATE_TIMEOUT_SECONDS"] = "60"
      env["AGENT_WORKFLOWS_MERGE_GATE_TOTAL_BUDGET_SECONDS"] = "1.0"

      status, stderr = run_hook("gh pr merge", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "could not resolve which pull request"
      assert_empty validator_calls(calls), "the validator must not run once the budget is spent"
    end
  end

  def test_blocks_when_the_validator_is_missing
    with_stubs(stdout: verdict("READY")) do |env, _calls|
      env["AGENT_WORKFLOWS_PR_CI_READINESS"] = File.join(Dir.tmpdir, "definitely-absent-validator")
      status, stderr = run_hook("gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "not executable"
    end
  end

  def test_blocks_when_the_pull_request_cannot_be_identified
    with_stubs(stdout: verdict("READY"), gh_exit_code: 1) do |env, _calls|
      status, stderr = run_hook("gh pr merge", env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "could not resolve which pull request"
    end
  end

  # --- allow only on a proven READY ----------------------------------------

  def test_allows_a_merge_when_the_validator_reports_ready
    with_stubs(stdout: verdict("READY")) do |env, calls|
      status, stderr = run_hook("gh pr merge 7 --merge", env)

      assert_equal ALLOW, status.exitstatus, stderr
      assert_equal [["7", "--json"]], validator_calls(calls)
    end
  end

  def test_forwards_an_explicit_repo_to_the_validator
    with_stubs(stdout: verdict("READY")) do |env, calls|
      status, = run_hook("gh pr merge 5 --repo owner/name", env)

      assert_equal ALLOW, status.exitstatus
      assert_equal [["5", "--json", "--repo", "owner/name"]], validator_calls(calls)
    end
  end

  def test_resolves_a_pull_request_url_without_calling_gh
    with_stubs(stdout: verdict("READY")) do |env, calls|
      status, = run_hook("gh pr merge https://github.com/owner/name/pull/9", env)

      assert_equal ALLOW, status.exitstatus
      assert_equal [["9", "--json"]], validator_calls(calls)
    end
  end

  def test_resolves_the_current_branch_pull_request_through_gh
    with_stubs(stdout: verdict("READY"), gh_stdout: "42") do |env, calls|
      status, = run_hook("gh pr merge", env)

      assert_equal ALLOW, status.exitstatus
      assert_equal [["42", "--json"]], validator_calls(calls)
    end
  end

  # --- applicability is fail-open ------------------------------------------

  def test_ignores_a_merge_phrase_inside_a_quoted_string
    with_stubs(stdout: verdict("NOT_READY")) do |env, calls|
      status, = run_hook(%(echo "run gh pr merge 7 when ready"), env)

      assert_equal ALLOW, status.exitstatus
      assert_empty validator_calls(calls), "the validator must not run for a quoted phrase"
    end
  end

  def test_ignores_a_merge_phrase_inside_a_heredoc_body
    command = "cat <<'NOTE'\ngh pr merge 7\nNOTE"
    with_stubs(stdout: verdict("NOT_READY")) do |env, calls|
      status, = run_hook(command, env)

      assert_equal ALLOW, status.exitstatus
      assert_empty validator_calls(calls), "the validator must not run for a heredoc body"
    end
  end

  def test_still_blocks_a_real_merge_that_follows_a_heredoc
    command = "cat <<'NOTE'\nnothing to see\nNOTE\ngh pr merge 7"
    with_stubs(stdout: verdict("NOT_READY")) do |env, _calls|
      status, stderr = run_hook(command, env)

      assert_equal BLOCK, status.exitstatus
      assert_includes stderr, "NOT_READY"
    end
  end

  def test_still_blocks_a_merge_chained_behind_another_command
    with_stubs(stdout: verdict("NOT_READY")) do |env, _calls|
      status, = run_hook("git push && gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus
    end
  end

  def test_still_blocks_a_merge_carrying_an_inline_environment_prefix
    with_stubs(stdout: verdict("NOT_READY")) do |env, _calls|
      status, = run_hook("AGENT_WORKFLOWS_HOOKS=off gh pr merge 7", env)

      assert_equal BLOCK, status.exitstatus, "an inline env prefix must not disable the gate"
    end
  end

  def test_allows_unrelated_commands
    with_stubs(stdout: verdict("NOT_READY")) do |env, calls|
      status, = run_hook("gh pr view 7 --json state", env)

      assert_equal ALLOW, status.exitstatus
      assert_empty validator_calls(calls)
    end
  end

  def test_allows_when_the_payload_is_not_readable
    with_stubs(stdout: verdict("NOT_READY")) do |env, _calls|
      _stdout, _stderr, status = Open3.capture3(env, HOOK, stdin_data: "{ this is not json")

      assert_equal ALLOW, status.exitstatus
    end
  end

  def test_allows_a_non_bash_tool
    with_stubs(stdout: verdict("NOT_READY")) do |env, _calls|
      payload = { "hook_event_name" => "PreToolUse", "tool_name" => "Read", "cwd" => Dir.pwd,
                  "tool_input" => { "command" => "gh pr merge 7" } }
      _stdout, _stderr, status = Open3.capture3(env, HOOK, stdin_data: payload.to_json)

      assert_equal ALLOW, status.exitstatus
    end
  end

  # --- operator kill switch -------------------------------------------------

  def test_operator_can_disable_the_adapter
    with_stubs(stdout: verdict("NOT_READY")) do |env, calls|
      env["AGENT_WORKFLOWS_HOOKS"] = "off"
      status, = run_hook("gh pr merge 7", env)

      assert_equal ALLOW, status.exitstatus
      assert_empty validator_calls(calls)
    end
  end

  # --- the adapter points at the real host-neutral validator ----------------

  def test_default_validator_path_is_the_shipped_host_neutral_validator
    validator = File.join(PACK_ROOT, "skills/pr-batch/bin/pr-ci-readiness")

    assert File.executable?(validator), "expected the shipped validator at #{validator}"
  end

  # --- command scanning -----------------------------------------------------

  def test_strip_removes_quoted_spans_and_heredoc_bodies
    stripped = ShellCommandScan.strip_quoted_and_heredocs("echo 'gh pr merge 1' && cat <<EOF\ngh pr merge 2\nEOF\n")

    refute_includes stripped, "merge"
  end

  def test_strip_keeps_neighbouring_tokens_separate
    stripped = ShellCommandScan.strip_quoted_and_heredocs(%(gh pr "merge" 7))

    refute_includes stripped, "prmerge"
  end

  def test_here_string_is_not_treated_as_a_heredoc
    invocations = ShellCommandScan.invocations("gh pr merge 7 <<< input", executable: "gh", subcommands: %w[pr merge])

    assert_equal ["7"], invocations.first[:arguments]
  end

  def test_invocations_ignore_flag_values_when_finding_subcommands
    invocations = ShellCommandScan.invocations("gh --repo owner/name pr merge 3", executable: "gh", subcommands: %w[pr merge])

    assert_equal 1, invocations.length
    assert_equal "owner/name", invocations.first[:repo]
    assert_equal ["3"], invocations.first[:arguments]
  end

  def test_invocations_match_an_absolute_executable_path
    invocations = ShellCommandScan.invocations("/opt/homebrew/bin/gh pr merge 4", executable: "gh", subcommands: %w[pr merge])

    assert_equal ["4"], invocations.first[:arguments]
  end

  private

  def verdict(state, failing: [], pending: [])
    { "pr" => 7, "verdict" => state, "failing" => failing, "pending" => pending }.to_json
  end

  # Builds a fake validator and a fake `gh`, both of which record their argv.
  def with_stubs(stdout:, stderr: "", exit_code: 0, sleep_seconds: nil, gh_stdout: "", gh_exit_code: 0, gh_sleep_seconds: nil)
    Dir.mktmpdir("merge-gate-test") do |dir|
      calls = File.join(dir, "calls.txt")
      validator = File.join(dir, "pr-ci-readiness")
      write_script(validator, calls, "validator", stdout, stderr, exit_code, sleep_seconds)

      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      write_script(File.join(bin, "gh"), calls, "gh", gh_stdout, "", gh_exit_code, gh_sleep_seconds)

      env = {
        "AGENT_WORKFLOWS_PR_CI_READINESS" => validator,
        "PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}"
      }
      yield(env, calls)
    end
  end

  def write_script(path, calls_path, label, stdout, stderr, exit_code, sleep_seconds)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.open(#{calls_path.inspect}, "a") { |file| file.puts([#{label.inspect}, *ARGV].join("\\t")) }
      sleep #{sleep_seconds.inspect} if #{!sleep_seconds.nil?}
      $stderr.print #{stderr.inspect}
      print #{stdout.inspect}
      exit #{exit_code}
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def validator_calls(calls_path)
    return [] unless File.file?(calls_path)

    File.readlines(calls_path, chomp: true).filter_map do |line|
      fields = line.split("\t")
      fields.drop(1) if fields.first == "validator"
    end
  end

  def run_hook(command, env)
    payload = {
      "hook_event_name" => "PreToolUse",
      "tool_name" => "Bash",
      "cwd" => Dir.pwd,
      "tool_input" => { "command" => command }
    }
    _stdout, stderr, status = Open3.capture3(env, HOOK, stdin_data: payload.to_json)
    [status, stderr]
  end
end
