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
    dashboard = payload.fetch("components").last
    checks = dashboard.fetch("checks")
    ids = checks.map { |check| check.fetch("id") }
    statuses = checks.map { |check| check.fetch("status") }

    refute_path_exists @sentinel
    assert_equal "degraded", dashboard.fetch("status")
    assert_equal "degraded", payload.fetch("status")
    assert_equal %w[agent-coordination-dashboard.source agent-coordination-dashboard.compatibility
                    agent-coordination-dashboard.doctor], ids
    assert_equal %w[degraded healthy degraded], statuses
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

  def test_degraded_dirty_sources_block_all_source_resident_delegates
    dashboard = path("src/agent-coordination-dashboard")
    FileUtils.rm_rf(dashboard)
    create_checkout("agent-coordination-dashboard")
    delegates = [
      ["agent-workflows", path("target/bin/agent-workflows-doctor"), "workflows.installation"],
      ["agent-coordination", path("install/agent-coord"), "coordination.backend"],
      ["agent-coordination-dashboard", nil, "dashboard.health"]
    ]
    sentinels = delegates.map do |component, installed, check_id|
      sentinel = path("#{component}-dirty-executed")
      basename = component == "agent-coordination-dashboard" ? "agent-coordination-dashboard.js" : File.basename(installed)
      source_helper = path("src", component, "bin", basename)
      FileUtils.mkdir_p(File.dirname(source_helper))
      write_delegate(source_helper, component, check_id, sentinel: sentinel)
      system("git", "-C", path("src", component), "add", "bin/#{basename}", exception: true)
      system("git", "-C", path("src", component), "commit", "--quiet", "-m", "delegate fixture", exception: true)
      File.open(source_helper, "a") { |file| file.puts "# tracked dirty change" }
      if installed
        FileUtils.rm_f(installed)
        File.symlink(source_helper, installed)
      end
      sentinel
    end

    payload = orchestrator.call
    component_statuses = payload.fetch("components").map { |component| component.fetch("status") }

    sentinels.each { |sentinel| refute_path_exists sentinel }
    assert_equal %w[failed failed degraded], component_statuses
  end

  def test_off_main_source_blocks_source_resident_delegate
    sentinel = path("off-main-workflow-executed")
    source_helper = path("src/agent-workflows/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(source_helper))
    write_delegate(source_helper, "agent-workflows", "workflows.installation", sentinel: sentinel)
    system("git", "-C", path("src/agent-workflows"), "add", "bin/agent-workflows-doctor", exception: true)
    system("git", "-C", path("src/agent-workflows"), "commit", "--quiet", "-m", "delegate fixture", exception: true)
    system("git", "-C", path("src/agent-workflows"), "switch", "--quiet", "-c", "topic", exception: true)
    FileUtils.rm_f(path("target/bin/agent-workflows-doctor"))
    File.symlink(source_helper, path("target/bin/agent-workflows-doctor"))

    orchestrator.call

    refute_path_exists sentinel
  end

  def test_degraded_source_blocks_delegate_symlink_that_escapes_checkout
    sentinel = path("escaped-workflow-executed")
    external_delegate = path("external-agent-workflows-doctor")
    source_helper = path("src/agent-workflows/bin/agent-workflows-doctor")
    installed = path("target/bin/agent-workflows-doctor")
    write_delegate(external_delegate, "agent-workflows", "workflows.installation", sentinel: sentinel)
    FileUtils.mkdir_p(File.dirname(source_helper))
    File.symlink(external_delegate, source_helper)
    FileUtils.rm_f(installed)
    File.symlink(source_helper, installed)

    orchestrator.call

    refute_path_exists sentinel
  end

  def test_degraded_source_blocks_hardlinked_installed_delegate
    sentinel = path("hardlinked-workflow-executed")
    source_helper = path("src/agent-workflows/bin/agent-workflows-doctor")
    installed = path("target/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(source_helper))
    write_delegate(source_helper, "agent-workflows", "workflows.installation", sentinel: sentinel)
    FileUtils.rm_f(installed)
    File.link(source_helper, installed)

    orchestrator.call

    refute_path_exists sentinel
  end

  def test_degraded_source_blocks_installed_delegate_hardlinked_to_renamed_checkout_file
    sentinel = path("renamed-hardlinked-workflow-executed")
    source_file = path("src/agent-workflows/tools/renamed-helper")
    installed = path("target/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(source_file))
    write_delegate(source_file, "agent-workflows", "workflows.installation", sentinel: sentinel)
    FileUtils.rm_f(installed)
    File.link(source_file, installed)

    orchestrator.call

    refute_path_exists sentinel
  end

  def test_inode_scan_exhaustion_fails_closed
    candidate = path("trusted/candidate")
    linked = path("trusted/linked")
    source = path("tiny-source")
    FileUtils.mkdir_p([File.dirname(candidate), source])
    File.write(candidate, "candidate")
    File.link(candidate, linked)
    File.write(File.join(source, "unrelated"), "unrelated")

    refute orchestrator.send(:source_contains_inode?, candidate, source, entry_limit: 10)
    assert orchestrator.send(:source_contains_inode?, candidate, source, entry_limit: 0)
  end

  def test_degraded_source_allows_external_copy_of_source_delegate
    sentinel = path("copied-workflow-executed")
    source_helper = path("src/agent-workflows/bin/agent-workflows-doctor")
    installed = path("target/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(source_helper))
    write_delegate(source_helper, "agent-workflows", "workflows.installation", sentinel: sentinel)
    FileUtils.rm_f(installed)
    FileUtils.cp(source_helper, installed, preserve: true)

    refute File.identical?(source_helper, installed)
    orchestrator.call

    assert_path_exists sentinel
  end

  def test_degraded_source_blocks_source_resident_nested_workflow_delegate
    sentinel = path("nested-workflow-executed")
    source_helper = path("src/agent-workflows/bin/agent-workflows-status")
    installed_status = path("target/bin/agent-workflows-status")
    installed_doctor = path("target/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(source_helper))
    write_delegate(source_helper, "agent-workflows", "workflows.installation", sentinel: sentinel)
    File.symlink(source_helper, installed_status)
    File.write(installed_doctor, "#!/usr/bin/env ruby\nexec File.expand_path('agent-workflows-status', __dir__)\n")
    FileUtils.chmod(0o755, installed_doctor)

    orchestrator.call

    refute_path_exists sentinel
  end

  def test_degraded_source_blocks_source_resident_nested_deep_seam_delegate
    sentinel = path("nested-workflow-seam-executed")
    source_helper = path("src/agent-workflows/bin/agent-workflow-seam-doctor")
    installed_seam = path("target/bin/agent-workflow-seam-doctor")
    installed_doctor = path("target/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(source_helper))
    write_delegate(source_helper, "agent-workflows", "workflows.seam", sentinel: sentinel)
    File.symlink(source_helper, installed_seam)
    File.write(installed_doctor, "#!/usr/bin/env ruby\nexec File.expand_path('agent-workflow-seam-doctor', __dir__)\n")
    FileUtils.chmod(0o755, installed_doctor)

    orchestrator(options.merge(deep: true)).call

    refute_path_exists sentinel
  end

  def test_degraded_source_blocks_source_resident_workflow_modules
    %i[symlink hardlink].each do |variant|
      sentinel = path("#{variant}-workflow-module-executed")
      source_module = path("src/agent-workflows/bin/agent_doctor/workflows_cli.rb")
      installed_module = path("target/bin/agent_doctor/workflows_cli.rb")
      FileUtils.mkdir_p([File.dirname(source_module), File.dirname(installed_module)])
      File.write(source_module, "# source-resident module\n")
      variant == :symlink ? File.symlink(source_module, installed_module) : File.link(source_module, installed_module)
      write_delegate(path("target/bin/agent-workflows-doctor"), "agent-workflows", "workflows.installation",
                     sentinel: sentinel)

      orchestrator.call

      refute_path_exists sentinel, variant
      FileUtils.rm_f([installed_module, source_module])
    end
  end

  def test_degraded_source_allows_delegate_hardlinked_only_to_external_path
    sentinel = path("external-hardlinked-workflow-executed")
    external = path("trusted/renamed-helper")
    installed = path("target/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(external))
    write_delegate(external, "agent-workflows", "workflows.installation", sentinel: sentinel)
    FileUtils.rm_f(installed)
    File.link(external, installed)
    File.open(path("src/agent-workflows/README.md"), "a") { |file| file.puts "tracked dirty change" }

    orchestrator.call

    assert_path_exists sentinel
  end

  def test_healthy_source_allows_hardlinked_installed_delegate
    sentinel = path("healthy-hardlinked-workflow-executed")
    source_helper = path("src/agent-workflows/bin/agent-workflows-doctor")
    installed = path("target/bin/agent-workflows-doctor")
    FileUtils.mkdir_p(File.dirname(source_helper))
    write_delegate(source_helper, "agent-workflows", "workflows.installation", sentinel: sentinel)
    system("git", "-C", path("src/agent-workflows"), "add", "bin/agent-workflows-doctor", exception: true)
    system("git", "-C", path("src/agent-workflows"), "commit", "--quiet", "-m", "delegate fixture", exception: true)
    FileUtils.rm_f(installed)
    File.link(source_helper, installed)

    payload = orchestrator.call

    assert_path_exists sentinel
    assert_equal "healthy", payload.fetch("components").first.fetch("status")
  end

  def test_degraded_source_reports_missing_delegate_instead_of_source_trust_failure
    File.open(path("src/agent-workflows/README.md"), "a") { |file| file.puts "tracked dirty change" }
    FileUtils.rm_f(path("target/bin/agent-workflows-doctor"))

    payload = orchestrator.call
    doctor = payload.fetch("components").first.fetch("checks").find do |check|
      check.fetch("id") == "agent-workflows.doctor"
    end

    assert_equal "component doctor executable is missing", doctor.fetch("summary")
    assert_equal "Install or repair the component doctor, then rerun `agent-stack doctor`.", doctor.fetch("guidance")
  end

  def test_degraded_sources_still_allow_external_installed_delegates
    delegates = [
      ["agent-workflows", path("target/bin/agent-workflows-doctor"), "workflows.installation"],
      ["agent-coordination", path("install/agent-coord"), "coordination.backend"]
    ]
    sentinels = delegates.map do |component, installed, check_id|
      sentinel = path("#{component}-installed-executed")
      write_delegate(installed, component, check_id, sentinel: sentinel)
      File.open(path("src", component, "README.md"), "a") { |file| file.puts "tracked dirty change" }
      sentinel
    end

    payload = orchestrator.call
    component_statuses = payload.fetch("components").map { |component| component.fetch("status") }

    sentinels.each { |sentinel| assert_path_exists sentinel }
    assert_equal %w[degraded degraded degraded], component_statuses
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

  def orchestrator(selected_options = options)
    AgentDoctor::Orchestrator.new(selected_options,
                                  runner: AgentDoctor::ProcessRunner.new,
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
