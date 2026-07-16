# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class AgentDoctorWorkflowsCLIIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("agent-workflows-doctor-timeout")
    @target = File.join(@tmp, "target")
    @source = File.join(@tmp, "source")
    FileUtils.mkdir_p([File.join(@target, "bin"), @source])
    write_status_helper
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_status_helper_completing_after_four_seconds_is_healthy
    stdout, stderr, status = doctor(delay: 4.1)
    payload = JSON.parse(stdout)

    assert_predicate status, :success?, stderr
    assert_equal "healthy", payload["status"]
    assert_equal "workflow installation matches source", payload.dig("checks", 0, "summary")
  end

  def test_status_helper_exceeding_configured_wrapper_budget_is_bounded
    stdout, = doctor(timeout: 0.05, delay: 0.12)
    payload = JSON.parse(stdout)

    assert_equal "failed", payload["status"]
    assert_equal "diagnostic timed out", payload.dig("checks", 0, "summary")
  end

  def test_mismatched_child_identity_is_failed_exit_two_json_without_child_paths
    stdout, stderr, status = doctor(
      delay: 0,
      environment: {
        "DOCTOR_STATUS_HOST" => "claude",
        "DOCTOR_STATUS_TARGET" => "/tmp/other-target?token=target-secret",
        "DOCTOR_STATUS_SOURCE" => "/tmp/other-source?token=source-secret"
      }
    )
    payload = JSON.parse(stdout)

    assert_equal 2, status.exitstatus, stderr
    assert_equal "failed", payload["status"]
    assert_equal %w[host target source], payload.dig("checks", 0, "details", "mismatched_fields")
    refute_includes stdout, "target-secret"
    refute_includes stdout, "source-secret"
  end

  private

  def doctor(delay:, timeout: nil, environment: {})
    environment = { "DOCTOR_STATUS_DELAY_SECONDS" => delay.to_s }.merge(environment)
    environment["AGENT_DOCTOR_WORKFLOW_STATUS_TIMEOUT_SECONDS"] = timeout.to_s if timeout
    Open3.capture3(environment, File.join(ROOT, "bin/agent-workflows-doctor"), "--stack-json",
                   "--host", "codex", "--target", @target, "--source", @source)
  end

  def write_status_helper
    helper = File.join(@target, "bin/agent-workflows-status")
    File.write(helper, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      sleep Float(ENV.fetch("DOCTOR_STATUS_DELAY_SECONDS"))
      host = ENV.fetch("DOCTOR_STATUS_HOST", ARGV.fetch(ARGV.index("--host") + 1))
      target = ENV.fetch("DOCTOR_STATUS_TARGET", ARGV.fetch(ARGV.index("--target") + 1))
      source = ENV.fetch("DOCTOR_STATUS_SOURCE", ARGV.fetch(ARGV.index("--source") + 1))
      puts JSON.generate(
        "status" => "UP_TO_DATE", "host" => host, "target" => target, "source" => source,
        "installed_version" => "1.0.0", "installed_revision" => "abc", "available_version" => "1.0.0",
        "available_revision" => "abc", "checked_remote" => false, "reason" => nil, "guidance" => nil,
        "delivery_mode" => "flat", "native" => nil, "flat" => nil
      )
    RUBY
    File.chmod(0o755, helper)
  end
end
