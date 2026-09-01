#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class GitHubApiCanaryTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "bin/github-api-canary")
  FIXTURES = File.join(ROOT, "test/fixtures/github-api-canary")

  def run_canary(*arguments, environment: {})
    stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, SCRIPT, *arguments)
    [JSON.parse(stdout), stderr, status]
  end

  def with_fake_gh(response_fixture: nil, response_content: nil, stderr_fixture: nil, exit_status: 0, sleep_seconds: nil)
    raise ArgumentError, "provide one response source" unless [response_fixture, response_content].compact.one?

    Dir.mktmpdir("github-api-canary-test") do |directory|
      executable = File.join(directory, "gh")
      call_log = File.join(directory, "calls.jsonl")
      pid_file = File.join(directory, "pid")
      response_file = if response_content
                        File.join(directory, "response.headers").tap do |path|
                          File.binwrite(path, response_content)
                        end
                      else
                        File.join(FIXTURES, response_fixture)
                      end
      File.write(
        executable,
        <<~'RUBY'
          #!/usr/bin/env ruby
          require "json"
          File.open(ENV.fetch("CANARY_CALL_LOG"), "a", 0o600) do |file|
            file.puts(JSON.generate(ARGV))
          end
          File.write(ENV.fetch("CANARY_PID_FILE"), Process.pid.to_s)
          sleep Float(ENV.fetch("CANARY_SLEEP_SECONDS")) if ENV["CANARY_SLEEP_SECONDS"]
          print File.binread(ENV.fetch("CANARY_RESPONSE_FILE"))
          if ENV["CANARY_STDERR_FILE"]
            warn File.binread(ENV.fetch("CANARY_STDERR_FILE"))
          end
          exit Integer(ENV.fetch("CANARY_EXIT_STATUS"), 10)
        RUBY
      )
      File.chmod(0o700, executable)
      environment = {
        "GITHUB_API_CANARY_GH" => executable,
        "CANARY_CALL_LOG" => call_log,
        "CANARY_PID_FILE" => pid_file,
        "CANARY_RESPONSE_FILE" => response_file,
        "CANARY_EXIT_STATUS" => exit_status.to_s
      }
      environment["CANARY_STDERR_FILE"] = File.join(FIXTURES, stderr_fixture) if stderr_fixture
      environment["CANARY_SLEEP_SECONDS"] = sleep_seconds.to_s if sleep_seconds
      yield environment, call_log, pid_file
    end
  end

  def test_healthy_supplied_headers_emit_a_sanitized_budget_snapshot
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "healthy.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal(
      {
        "contract" => "github-api-canary",
        "version" => 1,
        "source" => "supplied-headers",
        "status" => "healthy",
        "http_status" => 200,
        "request_id" => "C0DE:414",
        "rate_limit_resource" => "core",
        "limit" => 5000,
        "used" => 12,
        "remaining" => 4988,
        "reset_at" => "2026-09-01T11:00:00Z",
        "retry_at" => nil,
        "retry_evidence" => nil,
        "reported_rate_limit_remaining" => nil,
        "rate_limit_telemetry_inconsistent" => false
      },
      result
    )
  end

  def test_exhausted_representative_bucket_emits_primary_rate_limit_with_exact_retry
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "primary-403.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "primary-rate-limited", result.fetch("status")
    assert_equal 403, result.fetch("http_status")
    assert_equal 0, result.fetch("remaining")
    assert_equal "2026-09-01T11:00:00Z", result.fetch("reset_at")
    assert_equal "2026-09-01T11:00:00Z", result.fetch("retry_at")
    assert_equal "x-ratelimit-reset", result.fetch("retry_evidence")
  end

  def test_secondary_limit_with_retry_after_is_not_called_invalid_authentication
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "secondary-429-retry-after.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "possible-secondary-rate-limited", result.fetch("status")
    assert_equal 429, result.fetch("http_status")
    assert_equal 4990, result.fetch("remaining")
    assert_equal "2026-09-01T10:01:00Z", result.fetch("retry_at")
    assert_equal "retry-after", result.fetch("retry_evidence")
  end

  def test_unauthorized_response_remains_denied_or_authentication_unknown
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "denied-401.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "denied-authentication-unknown", result.fetch("status")
    assert_equal 401, result.fetch("http_status")
    refute_equal "primary-rate-limited", result.fetch("status")
  end

  def test_default_live_canary_makes_exactly_one_representative_user_request
    with_fake_gh(response_fixture: "healthy.headers") do |environment, call_log|
      result, stderr, status = run_canary(environment: environment)

      assert status.success?, stderr
      assert_empty stderr
      assert_equal "live-request", result.fetch("source")
      assert_equal "healthy", result.fetch("status")
      calls = File.readlines(call_log, chomp: true).map { |line| JSON.parse(line) }
      assert_equal [["api", "--include", "--silent", "--method", "GET", "/user"]], calls
    end
  end

  def test_live_transport_failure_is_sanitized_and_distinct_from_malformed_headers
    with_fake_gh(
      response_fixture: "empty.response",
      stderr_fixture: "transport.stderr",
      exit_status: 1
    ) do |environment, call_log|
      result, stderr, status = run_canary(environment: environment)

      assert_equal 3, status.exitstatus
      assert_empty stderr
      assert_equal "transport-failure", result.fetch("status")
      assert_nil result.fetch("http_status")
      refute_includes result.to_json, "ghp_DO_NOT_LEAK"
      assert_equal 1, File.readlines(call_log).length
    end
  end

  def test_conflicting_rate_limit_snapshot_never_overrides_representative_exhaustion
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "primary-403.headers"),
      "--reported-rate-limit-remaining",
      "5000"
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "primary-rate-limited", result.fetch("status")
    assert_equal 0, result.fetch("remaining")
    assert_equal 5000, result.fetch("reported_rate_limit_remaining")
    assert result.fetch("rate_limit_telemetry_inconsistent")
  end

  def test_sso_denial_is_not_mislabeled_as_primary_or_secondary_exhaustion
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "sso-403.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "denied-authentication-unknown", result.fetch("status")
    refute_equal "primary-rate-limited", result.fetch("status")
    refute_equal "possible-secondary-rate-limited", result.fetch("status")
  end

  def test_partial_success_with_sso_header_remains_healthy
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "healthy-sso-partial.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "healthy", result.fetch("status")
    assert_equal 206, result.fetch("http_status")
  end

  def test_429_with_exhausted_representative_bucket_is_primary_rate_limited
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "primary-429.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "primary-rate-limited", result.fetch("status")
    assert_equal 0, result.fetch("remaining")
  end

  def test_secondary_limit_without_retry_after_remains_possible_and_has_no_invented_retry
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "secondary-429-no-retry.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "possible-secondary-rate-limited", result.fetch("status")
    assert_nil result.fetch("retry_at")
    assert_nil result.fetch("retry_evidence")
  end

  def test_permission_denial_is_never_called_primary_exhaustion
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "permission-403.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    refute_equal "primary-rate-limited", result.fetch("status")
    assert_equal "possible-secondary-rate-limited", result.fetch("status")
  end

  def test_not_found_response_remains_denied_or_authentication_unknown
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "not-found-404.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "denied-authentication-unknown", result.fetch("status")
    refute_equal "primary-rate-limited", result.fetch("status")
  end

  def test_malformed_supplied_headers_are_sanitized
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "malformed.headers")
    )

    assert_equal 2, status.exitstatus
    assert_empty stderr
    assert_equal "malformed-response", result.fetch("status")
    assert_nil result.fetch("http_status")
    refute_includes result.to_json, "ghp_DO_NOT_LEAK"
    refute_includes result.to_json, "raw untrusted body"
  end

  def test_nonzero_gh_exit_with_response_headers_is_classified_without_retrying
    with_fake_gh(response_fixture: "primary-403.headers", exit_status: 1) do |environment, call_log|
      result, stderr, status = run_canary(environment: environment)

      assert status.success?, stderr
      assert_empty stderr
      assert_equal "primary-rate-limited", result.fetch("status")
      assert_equal 1, File.readlines(call_log).length
      refute_includes result.to_json, "API rate limit exceeded"
    end
  end

  def test_explicit_endpoint_override_is_used_for_the_only_request
    with_fake_gh(response_fixture: "healthy.headers") do |environment, call_log|
      result, stderr, status = run_canary("--endpoint", "/repos/shakacode/agent-workflows", environment: environment)

      assert status.success?, stderr
      assert_empty stderr
      assert_equal "healthy", result.fetch("status")
      calls = File.readlines(call_log, chomp: true).map { |line| JSON.parse(line) }
      assert_equal [["api", "--include", "--silent", "--method", "GET", "/repos/shakacode/agent-workflows"]], calls
    end
  end

  def test_rate_limit_endpoint_variants_are_rejected_without_a_request
    ["/rate_limit", "/rate_limit/", "/Rate_Limit", "/RATE_LIMIT?resource=core"].each do |endpoint|
      with_fake_gh(response_fixture: "healthy.headers") do |environment, call_log|
        result, stderr, status = run_canary("--endpoint", endpoint, environment: environment)

        assert_equal 2, status.exitstatus, endpoint
        assert_empty stderr, endpoint
        assert_equal "malformed-response", result.fetch("status"), endpoint
        refute File.exist?(call_log), endpoint
      end
    end
  end

  def test_oversized_live_response_is_labeled_as_a_live_request_failure
    oversized_headers = "HTTP/2 200\nX-Fill: #{'x' * 65_537}\n\n"

    with_fake_gh(response_content: oversized_headers) do |environment, call_log|
      result, stderr, status = run_canary(environment: environment)

      assert_equal 2, status.exitstatus
      assert_empty stderr
      assert_equal "malformed-response", result.fetch("status")
      assert_equal "live-request", result.fetch("source")
      assert_equal 1, File.readlines(call_log).length
    end
  end

  def test_immediately_affected_workflow_guidance_uses_the_canary_contract
    guidance_paths = [
      File.join(ROOT, "skills/address-review/SKILL.md"),
      File.join(ROOT, "workflows/address-review.md"),
      File.join(ROOT, "skills/update-changelog/SKILL.md")
    ]

    guidance_paths.each do |path|
      guidance = File.read(path, encoding: "UTF-8")
      assert_includes guidance, "A 403 alone does not prove invalid authentication.", path
      assert_match(/Honor `Retry-After` or\s+`X-RateLimit-Reset`/, guidance, path)
      assert_match(
        %r{a conflicting `GET /rate_limit` snapshot is an inconsistency,\s+not\s+restoration}i,
        guidance,
        path
      )
    end

    address_skill = File.read(File.join(ROOT, "skills/address-review/SKILL.md"), encoding: "UTF-8")
    refute_includes address_skill, "If the API returns 403, check authentication with `gh auth status`"
    refute_includes address_skill, "if you hit them, wait a few minutes"
  end

  def test_live_canary_times_out_and_reaps_its_only_request_process
    with_fake_gh(response_fixture: "healthy.headers", sleep_seconds: 5) do |environment, call_log, pid_file|
      result, stderr, status = run_canary("--timeout", "1", environment: environment)

      assert_equal 3, status.exitstatus
      assert_empty stderr
      assert_equal "transport-failure", result.fetch("status")
      assert_equal 1, File.readlines(call_log).length
      pid = Integer(File.read(pid_file), 10)
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_comparison_without_representative_remaining_stays_unknown_not_inconsistent
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "healthy-no-budget.headers"),
      "--reported-rate-limit-remaining",
      "5000"
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "healthy", result.fetch("status")
    assert_nil result.fetch("remaining")
    refute result.fetch("rate_limit_telemetry_inconsistent")
  end

  def test_primary_exhaustion_never_retries_before_the_later_reset_evidence
    result, stderr, status = run_canary(
      "--headers-file",
      File.join(FIXTURES, "primary-both-retry-signals.headers")
    )

    assert status.success?, stderr
    assert_empty stderr
    assert_equal "primary-rate-limited", result.fetch("status")
    assert_equal "2026-09-01T11:00:00Z", result.fetch("retry_at")
    assert_equal "retry-after+x-ratelimit-reset", result.fetch("retry_evidence")
  end
end
