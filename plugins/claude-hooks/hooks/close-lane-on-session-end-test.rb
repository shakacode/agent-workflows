#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

SESSION_END_HOOK = File.expand_path("close-lane-on-session-end", __dir__)

class CloseLaneOnSessionEndTest < Minitest::Test
  def test_skips_silently_when_the_repository_has_no_coordination_backend
    with_repo(backend: "n/a") do |repo, _emitter, calls|
      status, stderr = run_hook(repo, advertisement: emitter_argv)

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: no coordination backend"
      assert_empty emitter_calls(calls)
    end
  end

  def test_skips_when_the_repository_has_no_seam_at_all
    Dir.mktmpdir("no-seam") do |repo|
      status, stderr = run_hook(repo, advertisement: nil)

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: no coordination backend"
    end
  end

  def test_records_transport_unavailable_when_nothing_is_advertised
    with_repo(backend: "private-http") do |repo, _emitter, calls|
      status, stderr = run_hook(repo, advertisement: nil)

      assert_equal 0, status.exitstatus
      assert_includes stderr, "typed event transport: unavailable"
      assert_empty emitter_calls(calls)
    end
  end

  def test_emits_the_advertised_drain_event_verbatim
    with_repo(backend: "private-http") do |repo, emitter, calls|
      argv = [emitter, "event", "--type", "human_intervention", "--kind", "drain",
              "--batch-id", "aw-f", "--message", "lane stopped deliberately"]
      status, stderr = run_hook(repo, advertisement: argv)

      assert_equal 0, status.exitstatus
      assert_includes stderr, "emitted human_intervention kind: drain"
      assert_equal [argv.drop(1)], emitter_calls(calls),
                   "the advertised argv must be passed through unmodified, including spaces"
    end
  end

  def test_never_synthesises_a_release
    with_repo(backend: "private-http") do |repo, emitter, calls|
      run_hook(repo, advertisement: [emitter, "event", "--kind", "drain"])

      recorded = emitter_calls(calls).flatten

      refute_includes recorded, "release"
      refute_includes recorded, "--terminal"
    end
  end

  def test_skips_a_resumed_session
    with_repo(backend: "private-http") do |repo, emitter, calls|
      status, stderr = run_hook(repo, advertisement: [emitter, "event"], reason: "resume")

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: session end reason is resume"
      assert_empty emitter_calls(calls)
    end
  end

  def test_operator_can_disable_the_adapter
    with_repo(backend: "private-http") do |repo, emitter, calls|
      status, stderr = run_hook(repo, advertisement: [emitter, "event"], env: { "AGENT_WORKFLOWS_HOOKS" => "off" })

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: adapter disabled"
      assert_empty emitter_calls(calls)
    end
  end

  def test_rejects_a_malformed_advertisement
    ["not json", "{}", "[]", '["ok", 7]', '["   "]'].each do |raw|
      with_repo(backend: "private-http") do |repo, _emitter, calls|
        status, stderr = run_hook(repo, raw_advertisement: raw)

        assert_equal 0, status.exitstatus
        assert_includes stderr, "attempted-write failure", "expected #{raw.inspect} to be rejected"
        assert_empty emitter_calls(calls)
      end
    end
  end

  def test_records_unknown_when_the_emitter_fails
    with_repo(backend: "private-http", emitter_exit_code: 3, emitter_stderr: "backend refused") do |repo, emitter, _calls|
      status, stderr = run_hook(repo, advertisement: [emitter, "event"])

      assert_equal 0, status.exitstatus
      assert_includes stderr, "UNKNOWN: drain event write failed"
      assert_includes stderr, "backend refused"
    end
  end

  def test_records_unknown_when_the_emitter_exceeds_its_deadline
    with_repo(backend: "private-http", emitter_sleep: 10) do |repo, emitter, _calls|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, stderr = run_hook(repo, advertisement: [emitter, "event"],
                                      env: { "AGENT_WORKFLOWS_DRAIN_EVENT_TIMEOUT_SECONDS" => "0.4" })
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 0, status.exitstatus
      assert_includes stderr, "UNKNOWN: drain event write timed out"
      assert_operator elapsed, :<, 5, "a slow backend must not delay session shutdown"
    end
  end

  # Regression: any positive value was accepted, but hooks.json registers a 5s
  # SessionEnd timeout, so a larger value let the host kill the hook mid-write.
  def test_emission_deadline_is_clamped_below_the_registered_session_end_timeout
    with_repo(backend: "private-http", emitter_sleep: 30) do |repo, emitter, _calls|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, stderr = run_hook(repo, advertisement: [emitter, "event"],
                                      env: { "AGENT_WORKFLOWS_DRAIN_EVENT_TIMEOUT_SECONDS" => "10" })
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 0, status.exitstatus
      assert_includes stderr, "UNKNOWN: drain event write timed out"
      assert_operator elapsed, :<, 5,
                      "took #{elapsed.round(1)}s; must finish inside the registered 5s SessionEnd timeout"
    end
  end

  def test_survives_an_unreadable_payload
    _stdout, stderr, status = Open3.capture3(SESSION_END_HOOK, stdin_data: "not json")

    assert_equal 0, status.exitstatus
    assert_includes stderr, "skipped: unreadable SessionEnd payload"
  end

  private

  def emitter_argv
    ["/bin/echo", "unused"]
  end

  def with_repo(backend:, emitter_exit_code: 0, emitter_stderr: "", emitter_sleep: nil)
    Dir.mktmpdir("session-end-test") do |repo|
      FileUtils.mkdir_p(File.join(repo, ".agents"))
      File.write(File.join(repo, ".agents/agent-workflow.yml"), "---\ncoordination_backend: #{backend.inspect}\n")

      calls = File.join(repo, "calls.txt")
      emitter = File.join(repo, "fake-emitter")
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        File.open(#{calls.inspect}, "a") { |file| file.puts(ARGV.join("\\t")) }
        sleep #{emitter_sleep.inspect} if #{!emitter_sleep.nil?}
        $stderr.print #{emitter_stderr.inspect}
        exit #{emitter_exit_code}
      RUBY
      FileUtils.chmod(0o755, emitter)

      yield(repo, emitter, calls)
    end
  end

  def emitter_calls(calls_path)
    return [] unless File.file?(calls_path)

    File.readlines(calls_path, chomp: true).map { |line| line.split("\t") }
  end

  def run_hook(repo, advertisement: nil, raw_advertisement: nil, reason: "clear", env: {})
    hook_env = env.dup
    value = raw_advertisement || advertisement&.to_json
    hook_env["AGENT_WORKFLOWS_DRAIN_EVENT_ARGV"] = value if value
    payload = { "hook_event_name" => "SessionEnd", "reason" => reason, "cwd" => repo }
    _stdout, stderr, status = Open3.capture3(hook_env, SESSION_END_HOOK, stdin_data: payload.to_json)
    [status, stderr]
  end
end
