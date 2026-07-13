# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../../bin/agent_doctor/orchestrator"
require_relative "../../bin/agent_doctor/process_runner"
require_relative "../../bin/agent_doctor/sanitizer"

class AgentDoctorOrchestratorTrustTest < Minitest::Test
  COMPONENTS = %w[agent-workflows agent-coordination agent-coordination-dashboard].freeze

  def setup
    @tmp = Dir.mktmpdir("agent-doctor-trust")
    @sentinel = path("dashboard-executed")
    @environment = { "NODE_BIN" => RbConfig.ruby }
    FileUtils.mkdir_p([path("target/bin"), path("install"), path("runtime/state"), path("compat"), path("src")])
    %w[agent-workflows agent-coordination].each { |name| create_checkout(name) }
    create_untrusted_dashboard
    COMPONENTS.each { |name| File.symlink(path("src", name), path("compat", name)) }
    write_delegate(path("target/bin/agent-workflows-doctor"), "agent-workflows", "workflows.installation")
    write_delegate(path("install/agent-coord"), "agent-coordination", "coordination.backend")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_failed_dashboard_source_is_not_executed
    payload = AgentDoctor::Orchestrator.new(options, runner: AgentDoctor::ProcessRunner.new,
                                                     sanitizer: AgentDoctor::Sanitizer.new,
                                                     environment: @environment).call
    checks = payload.fetch("components").last.fetch("checks")
    ids = checks.map { |check| check.fetch("id") }
    statuses = checks.map { |check| check.fetch("status") }

    refute_path_exists @sentinel
    assert_equal %w[agent-coordination-dashboard.source agent-coordination-dashboard.compatibility
                    agent-coordination-dashboard.doctor], ids
    assert_equal %w[failed healthy degraded], statuses
  end

  def test_failed_sources_block_source_resident_installed_delegates
    delegates = [
      ["agent-workflows", path("target/bin/agent-workflows-doctor"), "workflows.installation"],
      ["agent-coordination", path("install/agent-coord"), "coordination.backend"]
    ]
    sentinels = delegates.map do |component, installed, check_id|
      sentinel = path("#{component}-executed")
      source_helper = path("src", component, "bin", File.basename(installed))
      FileUtils.mkdir_p(File.dirname(source_helper))
      write_delegate(source_helper, component, check_id, sentinel: sentinel)
      FileUtils.rm_f(installed)
      File.symlink(source_helper, installed)
      system("git", "-C", path("src", component), "remote", "set-url", "origin", path("wrong.git"), exception: true)
      sentinel
    end

    orchestrator.call

    sentinels.each { |sentinel| refute_path_exists sentinel }
  end

  private

  def options
    { source_root: path("src"), compat_root: path("compat"), runtime_root: path("runtime"),
      install_dir: path("install"), host: "codex", target: path("target"),
      dashboard_url: "http://127.0.0.1:4319", deep: false }
  end

  def path(*parts)
    File.join(@tmp, *parts)
  end

  def create_checkout(name)
    checkout = path("src", name)
    origin = path("origins", "#{name}.git")
    FileUtils.mkdir_p(checkout)
    system("git", "-C", checkout, "init", "--quiet", "-b", "main", exception: true)
    system("git", "-C", checkout, "config", "user.email", "doctor@example.com", exception: true)
    system("git", "-C", checkout, "config", "user.name", "Doctor", exception: true)
    File.write(File.join(checkout, "README.md"), "#{name}\n")
    system("git", "-C", checkout, "add", "README.md", exception: true)
    system("git", "-C", checkout, "commit", "--quiet", "-m", "fixture", exception: true)
    system("git", "-C", checkout, "remote", "add", "origin", origin, exception: true)
    @environment["AGENT_STACK_#{name.tr('-', '_').upcase}_URL"] = origin
  end

  def create_untrusted_dashboard
    dashboard = path("src/agent-coordination-dashboard")
    FileUtils.mkdir_p(File.join(dashboard, "bin"))
    write_delegate(File.join(dashboard, "bin/agent-coordination-dashboard.js"),
                   "agent-coordination-dashboard", "dashboard.health", sentinel: @sentinel)
  end

  def orchestrator
    AgentDoctor::Orchestrator.new(options, runner: AgentDoctor::ProcessRunner.new,
                                           sanitizer: AgentDoctor::Sanitizer.new,
                                           environment: @environment)
  end

  def write_delegate(file, component, check_id, sentinel: nil)
    File.write(file, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      File.write(#{sentinel.inspect}, "executed") if #{!sentinel.nil?}
      puts JSON.generate("schema_version" => 1, "component" => #{component.inspect}, "status" => "healthy",
        "checks" => [{"id" => #{check_id.inspect}, "status" => "healthy", "summary" => "ready",
                      "details" => {}, "guidance" => nil}])
    RUBY
    File.chmod(0o755, file)
  end
end
