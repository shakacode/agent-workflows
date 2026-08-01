#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "agent_workflows_operation/lifecycle"
require_relative "agent_workflows_operation/lifecycle_lease"
require_relative "agent_workflows_operation/process_supervisor"
require_relative "agent_workflows_operation/state"
require_relative "agent_workflows_operation/store"

class AgentWorkflowsLifecycleTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  def setup
    @tmp = Dir.mktmpdir("agent-workflows-lifecycle")
    FileUtils.chmod(0o700, @tmp)
    @tmp_identity = AgentWorkflowsOperation::SecurePaths.owned_identity(@tmp)
    @target = File.join(@tmp, "host home")
    FileUtils.mkdir_p(@target, mode: 0o700)
    @state = AgentWorkflowsOperation::State.new(target: @target)
  end

  def teardown
    AgentWorkflowsOperation::SecurePaths.cleanup_owned_directory!(@tmp, @tmp_identity)
  end

  def test_multiple_shared_holders_coexist_and_block_exclusive_acquisition
    ready_reader, ready_writer = IO.pipe
    release_reader, release_writer = IO.pipe
    pid = fork do
      ready_reader.close
      release_writer.close
      lease = lease_with_timeout(1)
      lease.with_shared do
        ready_writer.write("1")
        ready_writer.close
        release_reader.read(1)
      end
      exit! 0
    end
    ready_writer.close
    release_reader.close
    assert_equal "1", ready_reader.read(1)

    lease_with_timeout(0.2).with_shared { assert true }
    error = assert_raises(AgentWorkflowsOperation::LifecycleBusyError) do
      lease_with_timeout(0.1).with_exclusive { flunk "exclusive lease must not overlap a shared holder" }
    end
    assert_includes error.message, "LIFECYCLE_BUSY"
  ensure
    release_writer&.write("1")
    release_writer&.close
    Process.wait(pid) if pid
  end

  def test_lock_identity_substitution_fails_closed
    lease = lease_with_timeout(0.1)
    lease.with_shared { assert true }
    path = lease.lock_path
    File.rename(path, "#{path}.old")
    File.symlink("#{path}.old", path)

    error = assert_raises(AgentWorkflowsOperation::LifecycleError) do
      lease.with_shared { flunk "symlinked lock must not be accepted" }
    end
    assert_includes error.message, "LIFECYCLE_STATE_UNSAFE"
  end

  def test_capacity_constants_ignore_environment
    ENV["AGENT_WORKFLOWS_MAX_LIVE_OPERATIONS"] = "999"
    ENV["AGENT_WORKFLOWS_MAX_RETAINED_REVISIONS"] = "999"
    assert_equal 32, AgentWorkflowsOperation::Lifecycle::MAX_LIVE_OPERATIONS
    assert_equal 8, AgentWorkflowsOperation::Lifecycle::MAX_RETAINED_REVISIONS
  ensure
    ENV.delete("AGENT_WORKFLOWS_MAX_LIVE_OPERATIONS")
    ENV.delete("AGENT_WORKFLOWS_MAX_RETAINED_REVISIONS")
  end

  def test_ninth_protected_revision_is_refused_without_deleting_references
    lifecycle = AgentWorkflowsOperation::Lifecycle.new(
      host: "codex",
      target: @target,
      state: @state,
      store: AgentWorkflowsOperation::Store.new(state_root: @state.root)
    )
    operations = 8.times.map do |index|
      AgentWorkflowsOperation::OperationReference.new(
        handle: format("%064x", index),
        revision: format("%040x", index),
        root: File.join(@state.root, "operations", format("%064x", index))
      )
    end
    inventory = { operations:, installed_revision: operations.first.revision }

    error = assert_raises(AgentWorkflowsOperation::CapacityError) do
      lifecycle.enforce_revision_capacity!(inventory, "f" * 40)
    end
    assert_includes error.message, "STATE_CAPACITY_REACHED"
    assert_equal 8, operations.length
  end

  def test_legacy_over_capacity_revisions_are_preserved_and_refused
    lifecycle = AgentWorkflowsOperation::Lifecycle.new(
      host: "codex",
      target: @target,
      state: @state,
      store: AgentWorkflowsOperation::Store.new(state_root: @state.root)
    )
    operations = 9.times.map do |index|
      AgentWorkflowsOperation::OperationReference.new(
        handle: format("%064x", index),
        revision: format("%040x", index),
        root: File.join(@state.root, "operations", format("%064x", index))
      )
    end
    inventory = { operations:, installed_revision: operations.first.revision }

    error = assert_raises(AgentWorkflowsOperation::CapacityError) do
      lifecycle.enforce_revision_capacity!(inventory)
    end
    assert_includes error.message, "9/8"
    assert_includes error.message, operations.last.handle
    assert_equal 9, operations.length
  end

  def test_exclusive_wrapper_allows_only_its_inherited_target_bound_token
    wrapper = File.join(ROOT, "bin/agent-workflows-lifecycle")
    command = [
      wrapper, "exec-exclusive", "--target", @target, "--",
      RbConfig.ruby, "--disable=gems", wrapper, "validate-exclusive", "--target", @target
    ]
    output, error, status = Open3.capture3(*command)
    assert status.success?, error
    assert_equal "LIFECYCLE_REENTRY_OK\n", output

    forged_environment = {
      "AGENT_WORKFLOWS_LIFECYCLE_FD" => "9",
      "AGENT_WORKFLOWS_LIFECYCLE_TOKEN" => "a" * 64,
      "AGENT_WORKFLOWS_LIFECYCLE_TARGET" => @target
    }
    _output, forged_error, forged_status = Open3.capture3(
      forged_environment,
      wrapper, "validate-exclusive", "--target", @target
    )
    refute forged_status.success?
    assert_includes forged_error, "LIFECYCLE_REENTRY_REJECTED"
  end

  def test_exclusive_wrapper_rejects_a_valid_detached_descriptor_after_normal_unlock
    result = detached_reentry_result(crash_wrapper: false)

    refute_equal 0, result.fetch(:status)
    assert_includes result.fetch(:output), "LIFECYCLE_REENTRY_REJECTED"
    assert_equal "inactive", result.fetch(:token_status)
  end

  def test_exclusive_wrapper_rejects_crash_residue_that_still_holds_the_inherited_descriptor
    result = detached_reentry_result(crash_wrapper: true)

    refute_equal 0, result.fetch(:status)
    assert_includes result.fetch(:output), "LIFECYCLE_REENTRY_REJECTED"
    assert_equal "active", result.fetch(:token_status)
  end

  def test_installer_uses_lifecycle_lease_before_its_inner_migration_lock
    install_target = File.join(@tmp, "installed codex")
    output, error, status = install_pinned_target(install_target)
    assert status.success?, "#{output}\n#{error}"
    assert_path_exists File.join(install_target, ".agent-workflows-operation-state/lifecycle.lock")
    refute_path_exists File.join(install_target, ".agent-workflows-install.lock")
    assert_path_exists File.join(install_target, "bin/agent-workflows-lifecycle")

    installer = File.binread(File.join(ROOT, "bin/install-agent-workflows"))
    assert_operator installer.index("exec-exclusive"), :<, installer.index('install_lock="$target/.agent-workflows-install.lock"')
  end

  def test_upgrader_holds_one_exclusive_lease_through_backup_and_nested_install
    install_target = File.join(@tmp, "upgrade target")
    output, error, status = install_pinned_target(install_target)
    assert status.success?, "#{output}\n#{error}"

    upgrade = File.join(ROOT, "bin/upgrade-agent-workflows")
    output, error, status = Open3.capture3(
      upgrade,
      "--host", "codex",
      "--target", install_target,
      "--source", ROOT,
      "--mode", "copy",
      "--delivery-mode", "flat",
      "--provider-profile", "pinned",
      "--no-fetch"
    )
    assert status.success?, "#{output}\n#{error}"
    assert_includes output, "UPGRADE_COMPLETE"

    script = File.binread(upgrade)
    assert_operator script.index("exec-exclusive"), :<, script.index("\nbackup_target\n")
    assert_includes script, "validate-exclusive"
  end

  def test_installed_upgrader_waits_before_loading_runtime_during_publication
    install_target = File.join(@tmp, "upgrade publication target")
    output, error, status = install_pinned_target(install_target)
    assert status.success?, "#{output}\n#{error}"
    runtime = File.join(install_target, "bin/agent_workflows_operation/lifecycle_lease.rb")
    withheld_runtime = "#{runtime}.withheld"
    upgrade_output = File.join(@tmp, "upgrade-publication.out")
    pid = nil

    lease_with_target(install_target).with_exclusive do
      File.rename(runtime, withheld_runtime)
      pid = Process.spawn(
        File.join(install_target, "bin/upgrade-agent-workflows"),
        "--host", "codex",
        "--target", install_target,
        "--source", ROOT,
        "--mode", "copy",
        "--delivery-mode", "flat",
        "--provider-profile", "pinned",
        "--no-fetch",
        out: upgrade_output,
        err: upgrade_output
      )
      sleep 0.2
      assert process_alive?(pid), File.binread(upgrade_output)
      File.rename(withheld_runtime, runtime)
    end
    _pid, upgrade_status = Process.wait2(pid)
    assert upgrade_status.success?, File.binread(upgrade_output)
  ensure
    File.rename(withheld_runtime, runtime) if withheld_runtime && File.exist?(withheld_runtime)
    Process.kill("KILL", pid) if pid && process_alive?(pid)
  end

  def test_legacy_reentry_requires_a_fresh_source_side_upgrade
    install_target = File.join(@tmp, "legacy transition target")
    output, error, status = install_pinned_target(install_target)
    assert status.success?, "#{output}\n#{error}"
    wrapper = File.join(ROOT, "bin/agent-workflows-lifecycle")
    nested_install = [
      File.join(ROOT, "bin/install-agent-workflows"),
      "--host", "codex",
      "--target", install_target,
      "--mode", "copy",
      "--delivery-mode", "flat",
      "--provider-profile", "pinned"
    ]
    legacy_command = [
      "/bin/sh", "-c",
      "unset AGENT_WORKFLOWS_LIFECYCLE_LIVENESS_FD; exec \"$@\"",
      "legacy-transition",
      *nested_install
    ]

    _output, legacy_error, legacy_status = Open3.capture3(
      wrapper, "exec-exclusive", "--target", install_target, "--", *legacy_command
    )
    refute legacy_status.success?
    assert_includes legacy_error, "LIFECYCLE_RESTART_REQUIRED"

    output, error, status = Open3.capture3(
      File.join(ROOT, "bin/upgrade-agent-workflows"),
      "--host", "codex",
      "--target", install_target,
      "--source", ROOT,
      "--mode", "copy",
      "--delivery-mode", "flat",
      "--provider-profile", "pinned",
      "--no-fetch"
    )
    assert status.success?, "#{output}\n#{error}"
    assert_includes output, "UPGRADE_COMPLETE"
  end

  def test_installer_waits_behind_a_shared_runner_lease_before_inner_lock
    install_target = File.join(@tmp, "serialized target")
    output, error, status = install_pinned_target(install_target)
    assert status.success?, "#{output}\n#{error}"
    state = AgentWorkflowsOperation::State.new(target: install_target)
    lease = AgentWorkflowsOperation::LifecycleLease.new(target: install_target, root: state.root)
    child_output = File.join(@tmp, "serialized-install.out")
    pid = nil

    lease.with_shared do
      pid = Process.spawn(
        File.join(ROOT, "bin/install-agent-workflows"),
        "--host", "codex",
        "--target", install_target,
        "--mode", "copy",
        "--delivery-mode", "flat",
        "--provider-profile", "pinned",
        out: child_output,
        err: child_output
      )
      sleep 0.2
      assert process_alive?(pid)
      refute_path_exists File.join(install_target, ".agent-workflows-install.lock")
    end
    _pid, child_status = Process.wait2(pid)
    assert child_status.success?, File.binread(child_output)
  end

  def test_new_resolver_waits_before_loading_runtime_while_installer_replaces_it
    install_target = File.join(@tmp, "entry ordering target")
    output, error, status = install_pinned_target(install_target)
    assert status.success?, "#{output}\n#{error}"
    fake_bin = File.join(@tmp, "fake-bin")
    FileUtils.mkdir_p(fake_bin)
    ready = File.join(@tmp, "rsync-ready")
    proceed = File.join(@tmp, "rsync-proceed")
    real_mv, real_mv_status = Open3.capture2("sh", "-c", "command -v mv")
    assert real_mv_status.success?
    real_mv = real_mv.strip
    File.write(
      File.join(fake_bin, "mv"),
      <<~BASH
        #!/usr/bin/env bash
        set -euo pipefail
        destination="${!#}"
        if [[ "$destination" = "${QA_TARGET:?}/bin/agent-workflows-resolve" ]]; then
          : >"${QA_READY:?}"
          while [[ ! -e "${QA_PROCEED:?}" ]]; do sleep 0.01; done
        fi
        exec "${QA_REAL_MV:?}" "$@"
      BASH
    )
    FileUtils.chmod(0o755, File.join(fake_bin, "mv"))
    install_output = File.join(@tmp, "entry-order-install.out")
    resolver_output = File.join(@tmp, "entry-order-resolver.out")
    environment = {
      "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
      "QA_TARGET" => install_target,
      "QA_READY" => ready,
      "QA_PROCEED" => proceed,
      "QA_REAL_MV" => real_mv
    }
    installer_pid = Process.spawn(
      environment,
      File.join(ROOT, "bin/install-agent-workflows"),
      "--host", "codex",
      "--target", install_target,
      "--mode", "copy",
      "--delivery-mode", "flat",
      "--provider-profile", "pinned",
      out: install_output,
      err: install_output
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until File.exist?(ready) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert_path_exists ready

    resolver_pid = Process.spawn(
      File.join(install_target, "bin/agent-workflows-resolve"),
      "list", "--host", "codex", "--target", install_target, "--json",
      out: resolver_output,
      err: resolver_output
    )
    sleep 0.2
    assert process_alive?(resolver_pid)
    File.write(proceed, "continue\n")
    _pid, installer_status = Process.wait2(installer_pid)
    _pid, resolver_status = Process.wait2(resolver_pid)
    assert installer_status.success?, File.binread(install_output)
    assert resolver_status.success?, File.binread(resolver_output)
  ensure
    File.write(proceed, "continue\n") if proceed && !File.exist?(proceed)
    Process.kill("KILL", installer_pid) if installer_pid && process_alive?(installer_pid)
    Process.kill("KILL", resolver_pid) if resolver_pid && process_alive?(resolver_pid)
  end

  def test_signal_releases_the_wrapper_lease
    wrapper = File.join(ROOT, "bin/agent-workflows-lifecycle")
    pid = Process.spawn(
      wrapper, "exec-exclusive", "--target", @target, "--",
      "/bin/sh", "-c", "sleep 30",
      out: File::NULL, err: File::NULL
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    token_record = File.join(@state.root, "lifecycle-token.json")
    sleep 0.01 until File.exist?(token_record) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert_equal "active", JSON.parse(File.binread(token_record)).fetch("status")
    Process.kill("TERM", pid)
    Process.wait(pid)
    assert_equal "inactive", JSON.parse(File.binread(token_record)).fetch("status")
    lease_with_timeout(0.3).with_exclusive { assert true }
  ensure
    Process.kill("KILL", pid) if pid && process_alive?(pid)
  end

  def test_signal_arriving_during_spawn_is_forwarded_after_the_child_is_published
    original_spawn = Process.method(:spawn)
    injected_spawn = lambda do |*arguments, **options|
      pid = original_spawn.call(*arguments, **options)
      Process.kill("TERM", Process.pid)
      pid
    end
    Process.singleton_class.define_method(:spawn, injected_spawn)

    status = AgentWorkflowsOperation::ProcessSupervisor.wait!(
      environment: {},
      command: ["/bin/sh", "-c", "sleep 30"]
    )
    assert status.signaled?
    assert_equal Signal.list.fetch("TERM"), status.termsig
  ensure
    Process.singleton_class.define_method(:spawn, original_spawn)
  end

  private

  def detached_reentry_result(crash_wrapper:)
    wrapper = File.join(ROOT, "bin/agent-workflows-lifecycle")
    ready = File.join(@tmp, "detached-ready")
    proceed = File.join(@tmp, "detached-proceed")
    result = File.join(@tmp, "detached-result")
    child = File.join(@tmp, "detached-reentry.rb")
    File.write(
      child,
      <<~RUBY
        wrapper, target, ready, proceed, result, mode = ARGV
        validate = proc do
          File.write(ready, "ready\\n")
          sleep 0.01 until File.exist?(proceed)
          pipe = IO.popen([wrapper, "validate-exclusive", "--target", target], err: [:child, :out])
          output = pipe.read
          pipe.close
          File.write(result, "\#{$?.exitstatus}\\n\#{output}")
        end
        if mode == "detach"
          pid = fork do
            Process.setsid
            validate.call
          end
          Process.detach(pid)
        else
          validate.call
        end
      RUBY
    )
    output = File.join(@tmp, "detached-wrapper.out")
    wrapper_pid = Process.spawn(
      wrapper, "exec-exclusive", "--target", @target, "--",
      RbConfig.ruby, "--disable=gems", child, wrapper, @target, ready, proceed, result,
      crash_wrapper ? "wait" : "detach",
      out: output,
      err: output
    )
    wait_for_path(ready)
    if crash_wrapper
      Process.kill("KILL", wrapper_pid)
      Process.wait(wrapper_pid)
    else
      _pid, status = Process.wait2(wrapper_pid)
      assert status.success?, File.binread(output)
    end
    File.write(proceed, "continue\n")
    wait_for_path(result)
    status_text, command_output = File.binread(result).split("\n", 2)
    token_record = JSON.parse(File.binread(File.join(@state.root, "lifecycle-token.json")))
    {
      status: Integer(status_text, 10),
      output: command_output.to_s,
      token_status: token_record.fetch("status")
    }
  ensure
    File.write(proceed, "continue\n") if proceed && !File.exist?(proceed)
    Process.kill("KILL", wrapper_pid) if wrapper_pid && process_alive?(wrapper_pid)
  end

  def wait_for_path(path, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert_path_exists path
  end

  def lease_with_timeout(timeout)
    AgentWorkflowsOperation::LifecycleLease.new(target: @target, root: @state.root, timeout:)
  end

  def lease_with_target(target, timeout: 10)
    state = AgentWorkflowsOperation::State.new(target:)
    AgentWorkflowsOperation::LifecycleLease.new(target:, root: state.root, timeout:)
  end

  def install_pinned_target(target)
    Open3.capture3(
      File.join(ROOT, "bin/install-agent-workflows"),
      "--host", "codex",
      "--target", target,
      "--mode", "copy",
      "--delivery-mode", "flat",
      "--provider-profile", "pinned"
    )
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
