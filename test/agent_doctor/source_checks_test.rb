# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/agent_doctor/process_runner"
require_relative "../../bin/agent_doctor/source_checks"

class AgentDoctorSourceChecksTest < Minitest::Test
  class RecordingRunner
    attr_reader :commands

    def initialize(delegate)
      @delegate = delegate
      @commands = []
    end

    def capture(command, **options)
      @commands << command
      @delegate.capture(command, **options)
    end
  end

  class FailingDirtyRunner
    def initialize(delegate)
      @delegate = delegate
    end

    def capture(command, **options)
      return { stdout: "", stderr: "fatal", exit: 2, failure: nil } if command.include?("diff-files")

      @delegate.capture(command, **options)
    end
  end

  def setup
    @runner = AgentDoctor::ProcessRunner.new
  end

  def test_checkout_reports_revision_branch_and_dirty_state
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      checks = checker("AGENT_STACK_AGENT_WORKFLOWS_URL" => File.join(directory, "origin.git"))

      healthy = checks.checkout("agent-workflows", checkout)
      File.write(File.join(checkout, "README.md"), "dirty\n")
      dirty = checks.checkout("agent-workflows", checkout)

      assert_equal "healthy", healthy["status"]
      assert_equal "degraded", dirty["status"]
      assert_equal true, dirty.dig("details", "dirty")
    end
  end

  def test_checkout_detects_staged_unstaged_and_untracked_changes
    %i[staged unstaged untracked].each do |scenario|
      Dir.mktmpdir do |directory|
        checkout = create_checkout(directory, "agent-workflows")
        expected_origin = File.join(directory, "origin.git")
        path = scenario == :untracked ? File.join(checkout, "NEW.md") : File.join(checkout, "README.md")
        File.write(path, "changed\n")
        system("git", "-C", checkout, "add", File.basename(path), exception: true) if scenario == :staged

        check = checker("AGENT_STACK_AGENT_WORKFLOWS_URL" => expected_origin)
                .checkout("agent-workflows", checkout)

        assert_equal "degraded", check["status"], scenario
        assert_equal true, check.dig("details", "dirty"), scenario
      end
    end
  end

  def test_empty_repository_override_uses_default_allowed_origins
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      system("git", "-C", checkout, "remote", "set-url", "origin",
             "https://github.com/shakacode/agent-workflows.git", exception: true)

      check = checker("AGENT_STACK_AGENT_WORKFLOWS_URL" => "").checkout("agent-workflows", checkout)

      assert_equal "healthy", check["status"]
    end
  end

  def test_default_origin_allowlist_rejects_ssh_url_without_git_suffix_like_stack_sync
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      system("git", "-C", checkout, "remote", "set-url", "origin",
             "git@github.com:shakacode/agent-workflows", exception: true)

      check = checker.checkout("agent-workflows", checkout)

      assert_equal "failed", check["status"]
      assert_equal "origin does not match the configured repository", check["summary"]
    end
  end

  def test_dirty_probe_disables_optional_locks_and_repository_hooks
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      runner = RecordingRunner.new(@runner)
      checks = AgentDoctor::SourceChecks.new(
        runner: runner, environment: { "AGENT_STACK_AGENT_WORKFLOWS_URL" => File.join(directory, "origin.git") }
      )

      checks.checkout("agent-workflows", checkout)

      dirty_commands = runner.commands.select { |command| %w[diff-index diff-files ls-files].any? { |name| command.include?(name) } }
      assert_equal 3, dirty_commands.length
      dirty_commands.each do |command|
        assert_equal "git", command.first
        assert_includes command, "--no-optional-locks"
        assert_operator command.each_index.select { |index| command[index] == "-c" }.length, :>=, 2
        assert_includes command, "core.fsmonitor=false"
        assert_includes command, "core.hooksPath=/dev/null"
      end
    end
  end

  def test_wrong_origin_is_rejected_before_repository_hooks_can_execute
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      expected_origin = File.join(directory, "origin.git")
      wrong_origin = File.join(directory, "wrong.git")
      system("git", "-C", checkout, "remote", "set-url", "origin", wrong_origin, exception: true)
      system("git", "-C", checkout, "config", "url.#{expected_origin}.insteadOf", wrong_origin, exception: true)
      rewritten_origin = @runner.capture(["git", "-C", checkout, "remote", "get-url", "origin"]).fetch(:stdout).strip
      assert_equal expected_origin, rewritten_origin

      check = checker("AGENT_STACK_AGENT_WORKFLOWS_URL" => expected_origin)
              .checkout("agent-workflows", checkout)

      assert_equal "failed", check["status"]
      assert_equal "origin does not match the configured repository", check["summary"]
      assert_equal wrong_origin, check.dig("details", "origin")
    end
  end

  def test_official_raw_origin_does_not_allow_fsmonitor_execution
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      expected_origin = File.join(directory, "origin.git")
      hook = File.join(directory, "fsmonitor-hook")
      sentinel = "#{hook}.executed"
      File.write(hook, <<~SH)
        #!/bin/sh
        : > "${0}.executed"
        printf '\\0'
      SH
      FileUtils.chmod(0o755, hook)
      system("git", "-C", checkout, "config", "core.fsmonitor", hook, exception: true)

      check = checker("AGENT_STACK_AGENT_WORKFLOWS_URL" => expected_origin)
              .checkout("agent-workflows", checkout)

      assert_equal "healthy", check["status"]
      refute_path_exists sentinel
    end
  end

  def test_dirty_probe_does_not_execute_repository_clean_filter
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      expected_origin = File.join(directory, "origin.git")
      hook = File.join(directory, "clean-filter")
      sentinel = "#{hook}.executed"
      File.write(File.join(checkout, ".gitattributes"), "README.md filter=doctor-test\n")
      system("git", "-C", checkout, "add", ".gitattributes", exception: true)
      system("git", "-C", checkout, "commit", "--quiet", "-m", "attributes", exception: true)
      File.write(hook, <<~SH)
        #!/bin/sh
        : > "#{sentinel}"
        cat
      SH
      FileUtils.chmod(0o755, hook)
      system("git", "-C", checkout, "config", "filter.doctor-test.clean", hook, exception: true)

      probe = @runner.capture(["git", "-C", checkout, "status", "--porcelain"])
      assert_equal 0, probe[:exit]
      assert_path_exists sentinel
      FileUtils.rm_f(sentinel)

      check = checker("AGENT_STACK_AGENT_WORKFLOWS_URL" => expected_origin)
              .checkout("agent-workflows", checkout)

      assert_equal "failed", check["status"]
      assert_equal "source checkout has executable filter configuration", check["summary"]
      refute_path_exists sentinel
    end
  end

  def test_dirty_probe_errors_fail_closed
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      checks = AgentDoctor::SourceChecks.new(
        runner: FailingDirtyRunner.new(@runner),
        environment: { "AGENT_STACK_AGENT_WORKFLOWS_URL" => File.join(directory, "origin.git") }
      )

      check = checks.checkout("agent-workflows", checkout)

      assert_equal "failed", check["status"]
      assert_equal "source checkout is not a readable Git worktree", check["summary"]
    end
  end

  def test_repeated_origin_values_fail_closed_even_when_each_value_is_allowed
    Dir.mktmpdir do |directory|
      checkout = create_checkout(directory, "agent-workflows")
      expected_origin = File.join(directory, "origin.git")
      system("git", "-C", checkout, "config", "--add", "remote.origin.url", expected_origin, exception: true)

      check = checker("AGENT_STACK_AGENT_WORKFLOWS_URL" => expected_origin)
              .checkout("agent-workflows", checkout)

      assert_equal "failed", check["status"]
      assert_equal "source checkout has ambiguous origin configuration", check["summary"]
      assert_equal 2, check.dig("details", "origin_count")
    end
  end

  def test_dangling_and_wrong_compatibility_links_are_distinct
    Dir.mktmpdir do |directory|
      source = create_checkout(directory, "agent-workflows")
      other = create_checkout(directory, "other")
      compat = File.join(directory, "compat")
      FileUtils.mkdir_p(compat)
      link = File.join(compat, "agent-workflows")

      File.symlink(File.join(directory, "missing"), link)
      dangling = checker.compatibility("agent-workflows", compat, source)
      File.unlink(link)
      File.symlink(other, link)
      wrong = checker.compatibility("agent-workflows", compat, source)

      assert_equal "compatibility link is dangling", dangling["summary"]
      assert_equal "compatibility link targets another checkout", wrong["summary"]
    end
  end

  def test_compatibility_degrades_when_configured_source_is_a_symlink_cycle
    Dir.mktmpdir do |directory|
      target = File.join(directory, "target")
      compat = File.join(directory, "compat")
      source = File.join(directory, "source")
      source_peer = File.join(directory, "source-peer")
      FileUtils.mkdir_p([target, compat])
      File.symlink(target, File.join(compat, "agent-workflows"))
      File.symlink(source_peer, source)
      File.symlink(source, source_peer)

      check = checker.compatibility("agent-workflows", compat, source)

      assert_equal "degraded", check["status"]
      assert_equal "compatibility link cannot be resolved", check["summary"]
      assert_equal File.join(compat, "agent-workflows"), check.dig("details", "path")
    end
  end

  def test_compatibility_degrades_when_configured_source_has_a_file_parent
    Dir.mktmpdir do |directory|
      target = File.join(directory, "target")
      compat = File.join(directory, "compat")
      source_parent = File.join(directory, "source-file")
      FileUtils.mkdir_p([target, compat])
      File.write(source_parent, "not a directory\n")
      File.symlink(target, File.join(compat, "agent-workflows"))

      check = checker.compatibility("agent-workflows", compat, File.join(source_parent, "child"))

      assert_equal "degraded", check["status"]
      assert_equal "compatibility link cannot be resolved", check["summary"]
      assert_equal File.join(compat, "agent-workflows"), check.dig("details", "path")
    end
  end

  private

  def checker(environment = {})
    AgentDoctor::SourceChecks.new(runner: @runner, environment: environment)
  end

  def create_checkout(root, name)
    path = File.join(root, name)
    Dir.mkdir(path)
    system("git", "-C", path, "init", "--quiet", "-b", "main", exception: true)
    system("git", "-C", path, "config", "user.email", "doctor@example.com", exception: true)
    system("git", "-C", path, "config", "user.name", "Doctor", exception: true)
    File.write(File.join(path, "README.md"), "ready\n")
    system("git", "-C", path, "add", "README.md", exception: true)
    system("git", "-C", path, "commit", "--quiet", "-m", "fixture", exception: true)
    system("git", "-C", path, "remote", "add", "origin", File.join(root, "origin.git"), exception: true)
    path
  end
end
