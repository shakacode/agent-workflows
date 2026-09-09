#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
load File.expand_path("recovery-record", __dir__)

# Exercise interruption boundaries without touching a running agent or remote service.
class RecoveryRecordTest < Minitest::Test
  HELPER = File.expand_path("recovery-record", __dir__)

  def setup
    @root = Dir.mktmpdir("recovery-record-test-")
    @state = File.join(@root, "state")
    @command = [RbConfig.ruby, HELPER, "--state-dir", @state, "--task", "example-task"]
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def call(*args, data: "")
    Open3.capture3(*@command, *args, stdin_data: data)
  end

  def evidence
    JSON.parse(call("inspect").first)
  end

  def test_missing_checkpoint_is_normal_and_read_only
    assert_equal({ "records" => [], "unresolved" => [], "unreadable" => [] }, evidence)
    refute_path_exists @state
  end

  def test_empty_task_identity_is_rejected_before_writes_or_execution
    @command[-1] = ""
    marker = File.join(@root, "must-not-exist")
    commands = [["checkpoint"], ["inspect"],
                ["run", "--label", "test", "--", RbConfig.ruby, "-e", 'File.write(ARGV[0], "")', marker]]
    commands.each do |args|
      _, _, status = call(*args, data: "{}")
      assert_equal 2, status.exitstatus
      refute_path_exists @state
      refute_path_exists marker
    end
  end

  def test_newer_operation_preserved_after_stale_checkpoint
    assert call("checkpoint", data: '{"next":"create result"}').last.success?
    out, _, status = call("run", "--label", "create result", "--", RbConfig.ruby, "-e", 'puts "private output"; exit 7')
    assert_equal 7, status.exitstatus
    assert_equal "private output\n", out
    records = evidence["records"]
    assert_equal(%w[checkpoint operation], records.map { |record| record["kind"] })
    assert_equal 7, records.last["exit_code"]
    refute_includes JSON.generate(records), "private output"
    Dir.glob(File.join(@state, "**/*.json")).each { |path| assert_equal 0o600, File.stat(path).mode & 0o777 }
  end

  def test_blank_operation_labels_are_rejected_before_recording_or_execution
    marker = File.join(@root, "must-not-exist")
    ["", " \t\n"].each do |label|
      _, _, status = call("run", "--label", label, "--", RbConfig.ruby, "-e", 'File.write(ARGV[0], "")', marker)
      assert_equal 2, status.exitstatus
      refute_path_exists @state
      refute_path_exists marker
    end
  end

  def test_effect_can_finish_after_recorder_dies_without_a_result
    marker = File.join(@root, "external-result")
    started = File.join(@root, "started")
    release = File.join(@root, "release")
    script = 'File.write(ARGV[0], ""); sleep 0.01 until File.exist?(ARGV[1]); File.write(ARGV[2], "")'
    pid = Process.spawn(*@command, "run", "--label", "external result", "--", RbConfig.ruby,
                        "-e", script, started, release, marker, out: File::NULL, err: File::NULL)
    wait_for(started)
    assert_equal 1, evidence["unresolved"].length
    Process.kill("KILL", pid)
    Process.wait(pid)
    pid = nil
    File.write(release, "")
    wait_for(marker)
    assert_equal 1, evidence["unresolved"].length
    # Reading evidence never repeats the operation or upgrades intent to success.
    assert_equal "intent", evidence["records"].first["status"]
  ensure
    File.write(release, "") if release
    if pid
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end

  def test_failed_recording_prevents_execution
    Dir.mkdir(@state, 0o755)
    File.chmod(0o755, @state)
    marker = File.join(@root, "must-not-exist")
    _, _, status = call("run", "--label", "test", "--", RbConfig.ruby, "-e", 'File.write(ARGV[0], "")', marker)
    assert_equal 2, status.exitstatus
    refute_path_exists marker
  end

  def test_corrupt_record_is_reported_without_discarding_good_evidence
    call("checkpoint", data: '{"done":"tests"}')
    directory = Dir.glob(File.join(@state, "*")).first
    File.write(File.join(directory, "broken.json"), "{")
    out, _, status = call("inspect")
    assert_equal 2, status.exitstatus
    assert_equal 1, JSON.parse(out)["records"].length
    assert_equal ["broken.json"], JSON.parse(out)["unreadable"]
  end

  def test_reads_prior_python_format_evidence_without_migration
    directory = File.join(@state, Digest::SHA256.hexdigest("example-task"))
    FileUtils.mkdir_p(directory, mode: 0o700)
    # Original Python UUID hex ids, timestamps, and JSON fields remain readable.
    legacy = [
      { "id" => "a" * 32, "task" => "example-task", "recorded_at" => "2026-09-09T01:02:03.123456+00:00",
        "kind" => "checkpoint", "state" => { "next" => "verify remote result" } },
      { "id" => "b" * 32, "task" => "example-task", "recorded_at" => "2026-09-09T01:02:04.123456+00:00",
        "kind" => "operation", "label" => "remote result", "cwd" => "/example", "status" => "intent" }
    ]
    legacy.each do |record|
      File.write(File.join(directory, "#{record['id']}.json"), JSON.pretty_generate(record), perm: 0o600)
    end
    assert_equal legacy, evidence["records"]
    assert_equal ["b" * 32], evidence["unresolved"]
    call("checkpoint", data: '{"next":"reconcile"}')
    assert_equal legacy, evidence["records"].first(2)
  end

  def test_single_command_string_never_uses_shell_fallback
    marker = File.join(@root, "must-not-exist")
    _, _, status = call("run", "--label", "literal command", "--", "true; touch #{marker}")
    assert_equal 2, status.exitstatus
    refute_path_exists marker
    assert_equal 1, evidence["unresolved"].length
  end

  def test_state_directory_with_glob_characters_preserves_all_evidence
    @state = File.join(@root, "state[local]")
    @command = [RbConfig.ruby, HELPER, "--state-dir", @state, "--task", "example-task"]
    assert call("checkpoint", data: '{"next":"reconcile"}').last.success?
    _, _, status = call("run", "--label", "missing executable", "--", File.join(@root, "missing"))
    assert_equal 2, status.exitstatus

    out, _, status = call("inspect")
    assert status.success?
    result = JSON.parse(out)
    assert_equal(%w[checkpoint operation], result["records"].map { |record| record["kind"] })
    assert_equal [result["records"].last["id"]], result["unresolved"]
    assert_empty result["unreadable"]
  end

  def test_literal_executable_name_with_shell_metacharacters
    executable = File.join(@root, "literal; echo unexpected")
    File.write(executable, "#!#{RbConfig.ruby}\nputs 'literal executable'\n")
    File.chmod(0o700, executable)
    out, _, status = call("run", "--label", "literal executable", "--", executable)
    assert status.success?
    assert_equal "literal executable\n", out
  end

  def test_utf8_checkpoint_and_inspect_under_c_locale
    environment = { "LC_ALL" => "C", "LANG" => "C" }
    state = { "next" => "Read the résumé" }
    _, err, status = Open3.capture3(environment, *@command, "checkpoint", stdin_data: JSON.generate(state))
    assert status.success?, err
    out, err, status = Open3.capture3(environment, *@command, "inspect")
    assert status.success?, err
    assert_equal state, JSON.parse(out)["records"].first["state"]
  end

  def test_invalid_utf8_checkpoint_and_record_are_reported
    _, err, status = call("checkpoint", data: "{\"next\":\"\xff\"}".b)
    assert_equal 2, status.exitstatus
    assert_includes err, "evidence unavailable"
    assert_empty evidence["records"]

    call("checkpoint", data: '{"next":"reconcile"}')
    directory = File.join(@state, Digest::SHA256.hexdigest("example-task"))
    File.binwrite(File.join(directory, "invalid.json"), "{\"next\":\"\xff\"}".b)
    out, _, status = call("inspect")
    assert_equal 2, status.exitstatus
    assert_equal 1, JSON.parse(out)["records"].length
    assert_equal ["invalid.json"], JSON.parse(out)["unreadable"]
  end

  def test_utf8_task_label_and_working_directory_under_c_locale
    environment = { "LC_ALL" => "C", "LANG" => "C" }
    directory = File.join(@root, "résumé")
    Dir.mkdir(directory)
    command = [RbConfig.ruby, HELPER, "--state-dir", @state, "--task", "résumé"]
    _, err, status = Open3.capture3(environment, *command, "run", "--label", "résumé verified", "--",
                                    RbConfig.ruby, "-e", "exit 0", chdir: directory)
    assert status.success?, err
    out, err, status = Open3.capture3(environment, *command, "inspect")
    assert status.success?, err
    record = JSON.parse(out)["records"].first
    assert_equal "résumé", record["task"]
    assert_equal "résumé verified", record["label"]
    assert_equal File.realpath(directory), record["cwd"]
  end

  def test_binary_tagged_metadata_is_normalized_before_json_persistence
    records = []
    argv = ["--state-dir", @state, "--task", "résumé".b, "run", "--label", "résumé verified".b,
            "--", RbConfig.ruby, "-e", "exit 0"]
    writer = RecoveryRecord.method(:atomic_write)
    RecoveryRecord.define_singleton_method(:atomic_write) { |_path, record| records << record.dup }
    capture_io { assert_equal 0, RecoveryRecord.main(argv) }
    assert_equal(%w[intent exited], records.map { |record| record["status"] })
    records.each do |record|
      %w[task label cwd].each do |key|
        assert_equal Encoding::UTF_8, record[key].encoding
        assert record[key].valid_encoding?
      end
    end
  ensure
    RecoveryRecord.define_singleton_method(:atomic_write, writer) if writer
  end

  def test_signal_exit_preserves_python_return_code_convention
    _, _, status = call("run", "--label", "terminated command", "--", RbConfig.ruby, "-e", 'Process.kill("TERM", Process.pid)')
    assert_equal 128 + Signal.list.fetch("TERM"), status.exitstatus
    assert_equal(-Signal.list.fetch("TERM"), evidence["records"].first["exit_code"])
  end

  private

  def wait_for(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert_path_exists path
  end
end
