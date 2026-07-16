# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class AgentDoctorLauncherTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("agent-doctor-launcher")
    @bin = File.join(@tmp, "bin")
    FileUtils.mkdir_p(@bin)
    FileUtils.cp(File.join(ROOT, "bin/agent-stack"), File.join(@bin, "agent-stack"))
    FileUtils.cp_r(File.join(ROOT, "bin/agent_stack"), @bin)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_missing_doctor_dependency_fails_cleanly_for_regular_and_symlinked_helpers
    %i[regular symlink].each do |variant|
      helper_root = variant == :regular ? @bin : File.join(@tmp, "helper-source")
      FileUtils.mkdir_p(helper_root)
      helper = File.join(helper_root, "agent-stack-doctor")
      FileUtils.cp(File.join(ROOT, "bin/agent-stack-doctor"), helper)
      FileUtils.ln_sf(helper, File.join(@bin, "agent-stack-doctor")) if variant == :symlink

      _stdout, stderr, status = run_doctor

      assert_equal 64, status.exitstatus, variant
      assert_includes stderr, "agent-stack doctor module missing", variant
      refute_includes stderr, "LoadError", variant
      refute_includes stderr, "require_relative", variant
      FileUtils.rm_f(File.join(@bin, "agent-stack-doctor"))
    end
  end

  def test_missing_transitive_doctor_dependency_fails_cleanly_for_regular_and_symlinked_helpers
    %i[regular symlink].each do |variant|
      helper_root = variant == :regular ? @bin : File.join(@tmp, "helper-source")
      FileUtils.mkdir_p(helper_root)
      helper = File.join(helper_root, "agent-stack-doctor")
      FileUtils.cp(File.join(ROOT, "bin/agent-stack-doctor"), helper)
      FileUtils.cp_r(File.join(ROOT, "bin/agent_doctor"), helper_root)
      FileUtils.rm(File.join(helper_root, "agent_doctor/contract.rb"))
      FileUtils.ln_sf(helper, File.join(@bin, "agent-stack-doctor")) if variant == :symlink

      _stdout, stderr, status = run_doctor

      assert_equal 64, status.exitstatus, variant
      assert_includes stderr, "agent-stack doctor module missing", variant
      assert_includes stderr, "contract.rb", variant
      refute_includes stderr, "LoadError", variant
      refute_includes stderr, "require_relative", variant
      FileUtils.rm_f(File.join(@bin, "agent-stack-doctor"))
      FileUtils.rm_rf(File.join(helper_root, "agent_doctor"))
    end
  end

  def test_symlinked_helper_uses_its_complete_source_module_tree
    FileUtils.ln_s(File.join(ROOT, "bin/agent-stack-doctor"), File.join(@bin, "agent-stack-doctor"))

    stdout, stderr, status = run_doctor

    assert_predicate status, :success?, stderr
    assert_includes stdout, "Usage: agent-stack doctor"
  end

  def test_missing_adjacent_helper_does_not_execute_source_fallback
    source_root = File.join(@tmp, "source")
    source_bin = File.join(source_root, "agent-workflows", "bin")
    sentinel = File.join(@tmp, "source-doctor-executed")
    FileUtils.mkdir_p(source_bin)
    FileUtils.cp_r(File.join(ROOT, "bin/agent_doctor"), source_bin)
    File.write(File.join(source_bin, "agent-stack-doctor"), <<~RUBY)
      File.write(#{sentinel.inspect}, "executed")
      exit 0
    RUBY

    _stdout, stderr, status = Open3.capture3({ "AGENT_STACK_SOURCE_ROOT" => source_root },
                                             File.join(@bin, "agent-stack"), "doctor", "--help")

    assert_equal 64, status.exitstatus
    assert_includes stderr, "agent-stack doctor helper missing"
    refute_path_exists sentinel
  end

  def test_doctor_does_not_source_fallback_module_tree
    source_root = File.join(@tmp, "source")
    source_modules = File.join(source_root, "agent-workflows", "bin", "agent_stack")
    sentinel = File.join(@tmp, "source-module-executed")
    FileUtils.mkdir_p(File.dirname(source_modules))
    FileUtils.cp_r(File.join(ROOT, "bin/agent_stack"), source_modules)
    usage = File.join(source_modules, "usage.bash")
    File.write(usage, ": > #{sentinel.inspect}\n#{File.read(usage)}")
    FileUtils.rm(File.join(@bin, "agent_stack", "usage.bash"))

    _stdout, stderr, status = Open3.capture3({ "AGENT_STACK_SOURCE_ROOT" => source_root },
                                             File.join(@bin, "agent-stack"), "doctor", "--help")

    assert_equal 64, status.exitstatus
    assert_includes stderr, "doctor requires complete modules beside the command"
    refute_path_exists sentinel
  end

  def test_workflow_doctor_missing_dependency_fails_cleanly
    %w[workflows_cli.rb contract.rb].each do |missing_module|
      %i[regular symlink].each do |variant|
        helper_root = variant == :regular ? @bin : File.join(@tmp, "workflow-helper-source")
        FileUtils.mkdir_p(helper_root)
        helper = File.join(helper_root, "agent-workflows-doctor")
        FileUtils.cp(File.join(ROOT, "bin/agent-workflows-doctor"), helper)
        FileUtils.cp_r(File.join(ROOT, "bin/agent_doctor"), helper_root)
        FileUtils.rm(File.join(helper_root, "agent_doctor", missing_module))
        installed = File.join(@bin, "agent-workflows-doctor")
        FileUtils.ln_sf(helper, installed) if variant == :symlink

        _stdout, stderr, status = Open3.capture3(installed, "--help")

        message = "#{variant} #{missing_module}"
        assert_equal 64, status.exitstatus, message
        assert_includes stderr, "agent-workflows doctor module missing", message
        assert_includes stderr, missing_module, message
        refute_includes stderr, "LoadError", message
        FileUtils.rm_f(installed)
        FileUtils.rm_rf(File.join(helper_root, "agent_doctor"))
      end
    end
  end

  private

  def run_doctor
    Open3.capture3({ "AGENT_STACK_SOURCE_ROOT" => File.join(@tmp, "missing-source") },
                   File.join(@bin, "agent-stack"), "doctor", "--help")
  end
end
