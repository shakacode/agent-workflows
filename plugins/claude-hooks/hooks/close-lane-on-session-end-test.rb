#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "timeout"
require_relative "lib/hook_support"

SESSION_END_HOOK = File.expand_path("close-lane-on-session-end", __dir__)
load SESSION_END_HOOK

class CloseLaneOnSessionEndTest < Minitest::Test
  # Happy-path scenarios verify routing, argv, cwd, and stream behavior, not
  # the one-second production default. Give those subprocesses all of the
  # headroom the real SessionEnd contract permits so concurrent validators do
  # not turn scheduler delay into an unrelated assertion failure (#490).
  # Deliberate timeout scenarios override this value explicitly below.
  NON_DEADLINE_HOOK_TIMEOUT_SECONDS = CloseLaneOnSessionEnd::MAX_TIMEOUT_SECONDS.to_s
  NON_DEADLINE_HELPER_TIMEOUT_SECONDS = 10

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

  def test_uses_the_trusted_project_directory_for_the_seam_and_emitter_cwd
    with_repo(backend: "private-http") do |repo, emitter, calls|
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        File.write(#{calls.inspect}, Dir.pwd)
      RUBY

      Dir.mktmpdir("session-end-mutable-cwd") do |payload_cwd|
        FileUtils.mkdir_p(File.join(payload_cwd, ".agents"))
        File.write(File.join(payload_cwd, ".agents/agent-workflow.yml"), "---\ncoordination_backend: n/a\n")

        status, stderr = run_hook(repo, advertisement: [emitter, "event"], payload_cwd: payload_cwd)

        assert_equal 0, status.exitstatus
        assert_includes stderr, "emitted human_intervention kind: drain"
        assert_equal File.realpath(repo), File.realpath(File.read(calls)),
                     "payload cwd changes must not redirect seam lookup or the emitter working directory"
      end
    end
  end

  def test_skips_without_a_canonical_absolute_project_directory
    with_repo(backend: "private-http") do |repo, emitter, calls|
      [nil, "."].each do |project_dir|
        status, stderr = run_hook(repo, advertisement: [emitter, "event"], project_dir: project_dir)

        assert_equal 0, status.exitstatus
        assert_includes stderr, "skipped: no trusted project directory"
      end
      assert_empty emitter_calls(calls)
    end
  end

  def test_records_transport_unavailable_when_nothing_is_advertised
    with_repo(backend: "private-http") do |repo, _emitter, calls|
      status, stderr = run_hook(repo, advertisement: nil)

      assert_equal 0, status.exitstatus
      assert_includes stderr, "conditional drain transport: unavailable"
      assert_empty emitter_calls(calls)
    end
  end

  def test_current_conditional_operation_emits_the_advertised_drain_event_once
    with_repo(backend: "private-http") do |repo, emitter, calls|
      argv = [emitter, "event", "--type", "human_intervention", "--kind", "drain",
              "--batch-id", "aw-f", "--expected-holder", "worker-a", "--expected-generation", "3",
              "--expected-instance", "session-7", "--message", "lane stopped deliberately"]
      status, stderr = run_hook(repo, advertisement: argv)

      assert_equal 0, status.exitstatus
      assert_includes stderr, "emitted human_intervention kind: drain"
      assert_equal [argv.drop(1)], emitter_calls(calls),
                   "the advertised argv must be passed through unmodified, including spaces"
    end
  end

  def test_conditional_drain_skips_when_the_claim_was_replaced
    with_repo(backend: "private-http") do |repo, emitter, calls|
      claim_state = File.join(repo, "claim-state.json")
      File.write(claim_state, {
        "holder" => "replacement-worker",
        "generation" => 2,
        "instance_id" => "replacement-instance",
        "expires_at" => (Time.now + 60).utc.iso8601
      }.to_json)
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        require "time"
        current = JSON.parse(File.read(ARGV.fetch(0)))
        expected = { "holder" => ARGV.fetch(1), "generation" => Integer(ARGV.fetch(2)), "instance_id" => ARGV.fetch(3) }
        exit 3 unless current.values_at(*expected.keys) == expected.values
        exit 3 unless Time.parse(current.fetch("expires_at")) > Time.now
        File.write(#{calls.inspect}, "drained")
      RUBY
      argv = [emitter, claim_state, "original-worker", "1", "original-instance"]

      status, stderr = run_hook(
        repo,
        advertisement: argv,
        env: { "AGENT_WORKFLOWS_CONDITIONAL_DRAIN_ARGV" => argv.to_json }
      )

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: no current live lane claim"
      assert_empty emitter_calls(calls)
    end
  end

  def test_conditional_drain_skips_when_the_claim_lease_expired
    with_repo(backend: "private-http") do |repo, emitter, calls|
      claim_state = File.join(repo, "claim-state.json")
      File.write(claim_state, {
        "holder" => "original-worker",
        "generation" => 1,
        "instance_id" => "original-instance",
        "expires_at" => (Time.now - 60).utc.iso8601
      }.to_json)
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        require "time"
        current = JSON.parse(File.read(ARGV.fetch(0)))
        expected = { "holder" => ARGV.fetch(1), "generation" => Integer(ARGV.fetch(2)), "instance_id" => ARGV.fetch(3) }
        exit 3 unless current.values_at(*expected.keys) == expected.values
        exit 3 unless Time.parse(current.fetch("expires_at")) > Time.now
        File.write(#{calls.inspect}, "drained")
      RUBY
      argv = [emitter, claim_state, "original-worker", "1", "original-instance"]

      status, stderr = run_hook(repo, advertisement: argv)

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: no current live lane claim"
      assert_empty emitter_calls(calls)
    end
  end

  def test_plain_event_transport_is_not_a_conditional_drain_capability
    with_repo(backend: "private-http") do |repo, emitter, calls|
      status, stderr = run_hook(repo, plain_advertisement: [emitter, "record-event", "--kind", "drain"])

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: conditional drain transport: unavailable"
      assert_empty emitter_calls(calls)
    end
  end

  def test_append_only_agent_coord_record_event_is_not_a_conditional_operation
    with_repo(backend: "private-http") do |repo, emitter, calls|
      plain_agent_coord = File.join(repo, "agent-coord")
      FileUtils.mv(emitter, plain_agent_coord)

      status, stderr = run_hook(
        repo,
        advertisement: [plain_agent_coord, "record-event", "--type", "human_intervention", "--kind", "drain"]
      )

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: conditional drain transport: unsupported"
      assert_empty emitter_calls(calls)
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
    ["not json", "{}", "[]", '["ok", 7]', '["   "]', '["ok\\u0000bad"]'].each do |raw|
      with_repo(backend: "private-http") do |repo, _emitter, calls|
        status, stderr = run_hook(repo, raw_advertisement: raw)

        assert_equal 0, status.exitstatus
        assert_includes stderr, "attempted-write failure", "expected #{raw.inspect} to be rejected"
        assert_empty emitter_calls(calls)
      end
    end
  end

  def test_records_unknown_when_the_emitter_fails
    with_repo(backend: "private-http", emitter_exit_code: 4, emitter_stderr: "backend refused") do |repo, emitter, _calls|
      status, stderr = run_hook(repo, advertisement: [emitter, "event"])

      assert_equal 0, status.exitstatus
      assert_includes stderr, "UNKNOWN: drain event write failed"
      assert_includes stderr, "backend refused"
    end
  end

  def test_verbose_emitter_output_is_drained_and_bounded
    with_repo(backend: "private-http") do |repo, emitter, _calls|
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        STDOUT.write("unused stdout" * 400_000)
        STDERR.write("first useful line\n")
        256.times { STDERR.write("x" * 16_384) }
        exit 3
      RUBY

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = HookSupport.run_bounded([emitter], timeout_seconds: 3, chdir: repo)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      refute result[:ok]
      assert_equal 3, result[:status].exitstatus
      assert_nil result[:failure]
      assert_equal "", result[:stdout], "unused stdout must be discarded"
      assert_operator result[:stderr].bytesize, :<=, 4096
      assert result[:stderr].start_with?("first useful line\n")
      assert_operator elapsed, :<, 3, "draining verbose stderr must not block the emitter"
    end
  end

  def test_emitter_stdin_is_dev_null_instead_of_the_hook_input
    with_repo(backend: "private-http") do |repo, emitter, calls|
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        File.binwrite(#{calls.inspect}, STDIN.read)
      RUBY
      harness = File.join(repo, "run-bounded-harness")
      support = File.expand_path("lib/hook_support", __dir__)
      File.write(harness, <<~RUBY)
        #!/usr/bin/env ruby
        require #{support.inspect}
        result = HookSupport.run_bounded(
          [#{emitter.inspect}],
          timeout_seconds: #{NON_DEADLINE_HELPER_TIMEOUT_SECONDS},
          chdir: #{repo.inspect}
        )
        exit(result[:ok] ? 0 : 1)
      RUBY
      FileUtils.chmod(0o755, harness)

      input_reader, input_writer = IO.pipe
      pid = Process.spawn(harness, in: input_reader, out: File::NULL, err: File::NULL)
      input_reader.close
      input_writer.write("hook payload bytes must not reach the emitter")
      input_writer.close
      _waited_pid, status = Process.wait2(pid)

      assert status.success?
      assert_equal "", File.binread(calls), "the emitter must observe immediate EOF from File::NULL"
    ensure
      input_reader&.close unless input_reader&.closed?
      input_writer&.close unless input_writer&.closed?
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

  def test_successful_leader_times_out_when_a_descendant_outlives_the_deadline
    Dir.mktmpdir("session-end-successful-leader-test") do |directory|
      ready_reader, ready_writer = IO.pipe
      release_reader, release_writer = IO.pipe
      leader_pid = nil
      child_pid = nil
      begin
        marker = File.join(directory, "late-marker")
        leader_pid = fork do
          Process.setpgrp
          ready_reader.close
          release_writer.close

          fork do
            release_reader.close
            trap("TERM") { nil }
            ready_writer.puts(Process.pid)
            ready_writer.close
            sleep 0.4
            File.write(marker, "late mutation")
            exit! 0
          end
          ready_writer.close
          release_reader.read(1)
          exit! 0
        end
        ready_writer.close
        release_reader.close

        ready_line = Timeout.timeout(5) { ready_reader.gets }
        refute_nil ready_line, "the descendant must report ready before the leader exits"
        child_pid = Integer(ready_line)
        release_writer.write("x")
        release_writer.close

        status, timed_out = HookSupport.await(leader_pid, 0.15, 0.05)
        leader_pid = nil
        sleep 0.5

        assert status&.success?, "the group leader must have exited successfully"
        assert timed_out, "a successful leader cannot make a live process group successful"
        refute File.exist?(marker), "the lingering descendant must not mutate after the deadline"
        assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
      ensure
        ready_reader.close unless ready_reader.closed?
        ready_writer.close unless ready_writer.closed?
        release_reader.close unless release_reader.closed?
        release_writer.close unless release_writer.closed?
        begin
          Process.kill("KILL", child_pid) if child_pid
        rescue Errno::ESRCH
          nil
        end
        if leader_pid
          begin
            Process.kill("KILL", -leader_pid)
          rescue Errno::ESRCH
            nil
          end
          begin
            Process.wait(leader_pid)
          rescue Errno::ECHILD
            nil
          end
        end
      end
    end
  end

  def test_successful_leader_and_short_lived_descendant_complete_successfully
    with_repo(backend: "private-http") do |repo, emitter, _calls|
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        fork do
          sleep 0.05
          exit! 0
        end
        exit! 0
      RUBY

      result = HookSupport.run_bounded([emitter], timeout_seconds: NON_DEADLINE_HELPER_TIMEOUT_SECONDS, chdir: repo)

      assert result[:ok]
      assert result[:status].success?
      assert_nil result[:failure]
    end
  end

  def test_timeout_kills_a_term_ignoring_descendant_after_the_leader_exits
    Dir.mktmpdir("session-end-group-test") do |directory|
      ready_reader, ready_writer = IO.pipe
      leader_pid = nil
      child_pid = nil
      begin
        marker = File.join(directory, "late-marker")
        leader_pid = fork do
          Process.setpgrp
          ready_reader.close
          trap("TERM") { exit! 0 }

          fork do
            trap("TERM") { nil }
            ready_writer.puts(Process.pid)
            ready_writer.close
            sleep 1.3
            File.write(marker, "late mutation")
            exit! 0
          end
          ready_writer.close
          sleep 30
        end
        ready_writer.close

        ready_line = Timeout.timeout(5) { ready_reader.gets }
        refute_nil ready_line, "the descendant must report ready before the timeout starts"
        child_pid = Integer(ready_line)
        assert Process.kill(0, child_pid), "the TERM-ignoring descendant must be running"

        status, timed_out = HookSupport.await(leader_pid, 0, 0.5)
        leader_pid = nil
        sleep 0.9

        assert_nil status
        assert timed_out
        refute File.exist?(marker), "a TERM-ignoring descendant must not mutate after the hook returns"
        assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
      ensure
        ready_reader.close unless ready_reader.closed?
        ready_writer.close unless ready_writer.closed?
        begin
          Process.kill("KILL", child_pid) if child_pid
        rescue Errno::ESRCH
          nil
        end
        if leader_pid
          begin
            Process.kill("KILL", -leader_pid)
          rescue Errno::ESRCH
            nil
          end
          begin
            Process.wait(leader_pid)
          rescue Errno::ECHILD
            nil
          end
        end
      end
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

  def test_term_resistant_emitter_is_killed_with_host_timeout_margin_remaining
    with_repo(backend: "private-http") do |repo, emitter, calls|
      File.write(emitter, <<~RUBY)
        #!/usr/bin/env ruby
        trap("TERM") { nil }
        File.write(#{calls.inspect}, Process.pid)
        sleep 30
      RUBY
      hook_env = {
        "AGENT_WORKFLOWS_CONDITIONAL_DRAIN_ARGV" => [emitter].to_json,
        "AGENT_WORKFLOWS_DRAIN_EVENT_TIMEOUT_SECONDS" => "30"
      }
      input_reader, input_writer = IO.pipe
      err_reader, err_writer = IO.pipe
      hook_pid = nil
      emitter_pid = nil

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      hook_pid = Process.spawn(
        hook_env,
        SESSION_END_HOOK,
        "--project-dir",
        repo,
        in: input_reader,
        out: File::NULL,
        err: err_writer
      )
      input_reader.close
      err_writer.close
      input_writer.write({ "hook_event_name" => "SessionEnd", "reason" => "clear", "cwd" => repo }.to_json)
      sleep 0.4
      input_writer.close

      Timeout.timeout(2) do
        sleep 0.01 until File.file?(calls)
      end
      emitter_pid = Integer(File.read(calls))
      _waited_pid, status = Timeout.timeout(4.5) { Process.wait2(hook_pid) }
      hook_pid = nil
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      stderr = err_reader.read

      assert_equal 0, status.exitstatus
      assert_includes stderr, "UNKNOWN: drain event write timed out"
      assert_operator elapsed, :<, 3.5,
                      "took #{elapsed.round(2)}s; cleanup must leave 1.5s of the host's 5s budget"
      assert_raises(Errno::ESRCH) { Process.kill(0, emitter_pid) }
    ensure
      input_writer&.close unless input_writer&.closed?
      input_reader&.close unless input_reader&.closed?
      err_writer&.close unless err_writer&.closed?
      err_reader&.close unless err_reader&.closed?
      if hook_pid
        Process.kill("KILL", hook_pid)
        Process.wait(hook_pid)
      end
      begin
        Process.kill("KILL", emitter_pid) if emitter_pid
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_survives_an_unreadable_payload
    _stdout, stderr, status = Open3.capture3(SESSION_END_HOOK, stdin_data: "not json")

    assert_equal 0, status.exitstatus
    assert_includes stderr, "skipped: unreadable SessionEnd payload"
  end

  def test_stops_reading_a_payload_when_stdin_is_held_open
    with_repo(backend: "private-http") do |repo, _emitter, _calls|
      input_reader, input_writer = IO.pipe
      err_reader, err_writer = IO.pipe
      pid = Process.spawn(
        SESSION_END_HOOK,
        in: input_reader,
        out: File::NULL,
        err: err_writer
      )
      input_reader.close
      err_writer.close
      input_writer.write({ "hook_event_name" => "SessionEnd", "reason" => "clear", "cwd" => repo }.to_json)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _waited_pid, status = Timeout.timeout(2) { Process.wait2(pid) }
      pid = nil
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      stderr = err_reader.read

      assert_equal 0, status.exitstatus
      assert_includes stderr, "skipped: SessionEnd payload read timed out"
      assert_operator elapsed, :<, 2, "a held-open stdin must finish well inside the host's 5s timeout"
    ensure
      input_writer&.close unless input_writer&.closed?
      input_reader&.close unless input_reader&.closed?
      err_writer&.close unless err_writer&.closed?
      err_reader&.close unless err_reader&.closed?
      if pid
        Process.kill("KILL", pid)
        Process.wait(pid)
      end
    end
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

  def run_hook(repo, advertisement: nil, plain_advertisement: nil, raw_advertisement: nil, reason: "clear", env: {},
               payload_cwd: repo, project_dir: repo)
    hook_env = { CloseLaneOnSessionEnd::TIMEOUT_ENV => NON_DEADLINE_HOOK_TIMEOUT_SECONDS }.merge(env)
    value = raw_advertisement || advertisement&.to_json
    hook_env["AGENT_WORKFLOWS_CONDITIONAL_DRAIN_ARGV"] = value if value
    if plain_advertisement
      hook_env["AGENT_WORKFLOWS_DRAIN_EVENT_ARGV"] = plain_advertisement.to_json
    end
    payload = { "hook_event_name" => "SessionEnd", "reason" => reason, "cwd" => payload_cwd }
    hook_args = project_dir ? ["--project-dir", project_dir] : []
    _stdout, stderr, status = Open3.capture3(hook_env, SESSION_END_HOOK, *hook_args, stdin_data: payload.to_json)
    [status, stderr]
  end
end
