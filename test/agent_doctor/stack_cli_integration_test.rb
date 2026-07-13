# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class AgentDoctorStackCLIIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  COMPONENTS = %w[agent-workflows agent-coordination agent-coordination-dashboard].freeze

  def setup
    @tmp = Dir.mktmpdir("agent-doctor-integration")
    COMPONENTS.each { |name| create_checkout(name) }
    FileUtils.mkdir_p([path("compat"), path("target/bin"), path("install"), path("runtime/state")])
    COMPONENTS.each { |name| File.symlink(path("src", name), path("compat", name)) }
    write_delegate(path("target/bin/agent-workflows-doctor"), "agent-workflows", "workflows.installation")
    write_delegate(path("install/agent-coord"), "agent-coordination", "coordination.backend")
    write_dashboard
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_public_command_aggregates_three_component_owned_contracts
    stdout, stderr, status = doctor("--json")
    payload = JSON.parse(stdout)

    assert_predicate status, :success?, stderr
    assert_equal "healthy", payload["status"]
    assert_equal(COMPONENTS, payload["components"].map { |component| component["component"] })
    payload["components"].each do |component|
      assert_equal(2, component["checks"].count { |check| check["id"].end_with?(".source", ".compatibility") })
    end
  end

  def test_deep_mode_forwards_each_component_interface
    files = %w[workflow coord dashboard].to_h { |name| [name, path("#{name}-args")] }
    doctor("--deep", "--json", environment: {
             "DOCTOR_WORKFLOW_ARGS_FILE" => files["workflow"], "DOCTOR_COORD_ARGS_FILE" => files["coord"],
             "DOCTOR_DASHBOARD_ARGS_FILE" => files["dashboard"]
           })

    assert_equal ["--stack-json", "--host", "codex", "--target", path("target"), "--source", path("src/agent-workflows"), "--deep"], File.readlines(files["workflow"], chomp: true)
    assert_equal ["doctor", "--stack-json", "--deep", "--state-root", path("runtime/state")], File.readlines(files["coord"], chomp: true)
    assert_equal ["doctor", "--stack-json", "--deep", "--url", "http://127.0.0.1:4319"], File.readlines(files["dashboard"], chomp: true)
  end

  def test_empty_port_environment_uses_default_dashboard_port
    args = path("dashboard-args")
    doctor("--deep", "--json", dashboard_url: nil,
                               environment: { "PORT" => "", "DOCTOR_DASHBOARD_ARGS_FILE" => args })

    assert_equal ["doctor", "--stack-json", "--deep", "--url", "http://127.0.0.1:4319"],
                 File.readlines(args, chomp: true)
  end

  def test_human_output_is_problems_first_and_preserves_guidance
    stdout, = doctor(environment: { "DOCTOR_DASHBOARD_FIXTURE" => "stopped" })

    assert_match(/\AAgent Stack Doctor: DEGRADED/, stdout)
    assert_operator stdout.index("[DEGRADED] agent-coordination-dashboard"), :<, stdout.index("[HEALTHY] agent-workflows")
    assert_includes stdout, "Next         Start the optional dashboard, then rerun doctor."
  end

  def test_human_and_json_output_scrub_uri_and_multiline_environment_credentials
    secret = "private-key-first-line\nprivate-key-second-line"
    endpoint = "postgres://db-user:db-password@db.example/app?password=query-secret&sslmode=require note=#{secret}"
    environment = { "DOCTOR_ENDPOINT_FIXTURE" => endpoint, "DOCTOR_PRIVATE_KEY" => secret }
    json_output, = doctor("--json", environment: environment)
    human_output, = doctor(environment: environment)

    [json_output, human_output].each do |output|
      assert_includes output, "[REDACTED]@db.example/app"
      assert_includes output, "sslmode=require"
      refute_includes output, "db-user"
      refute_includes output, "db-password"
      refute_includes output, "query-secret"
      refute_includes output, secret
      refute_match(/private-key-first-line\\+x0Aprivate-key-second-line/, output)
    end
  end

  def test_human_and_json_output_scrub_nested_credentialed_uri_query_values
    endpoint = "http://example.test/?next=http://user:pass@db.test/path&label=visible"
    json_output, = doctor("--json", environment: { "DOCTOR_ENDPOINT_FIXTURE" => endpoint })
    human_output, = doctor(environment: { "DOCTOR_ENDPOINT_FIXTURE" => endpoint })

    [json_output, human_output].each do |output|
      assert_includes output, "%5BREDACTED%5D%40db.test"
      assert_includes output, "label=visible"
      refute_includes output, "user:pass"
      refute_match(/user%3Apass%40/i, output)
    end
  end

  def test_human_and_json_output_scrub_raw_and_encoded_oauth_fragment_credentials
    endpoints = [
      "http://localhost/cb#access_token=access:secret@token&id_token=id:secret@token&state=visible",
      "http://localhost/cb#access_token=access%3Asecret%40token&id_token=id%3Asecret%40token&state=visible"
    ]

    endpoints.each do |endpoint|
      outputs = [doctor("--json", environment: { "DOCTOR_ENDPOINT_FIXTURE" => endpoint }).first,
                 doctor(environment: { "DOCTOR_ENDPOINT_FIXTURE" => endpoint }).first]
      outputs.each do |output|
        assert_includes output, "access_token=%5BREDACTED%5D"
        assert_includes output, "id_token=%5BREDACTED%5D"
        assert_includes output, "state=visible"
        refute_includes output, "access:secret@token"
        refute_includes output, "id:secret@token"
        refute_match(/(?:access|id)%3Asecret%40token/i, output)
      end
    end
  end

  def test_human_and_json_output_scrub_webhook_paths_and_preserve_informative_paths
    webhook_secret = "T01234567/B01234567/slack-webhook-secret-value"
    hex_secret = "0123456789abcdef0123456789abcdef"
    endpoint = "https://hooks.slack.com/services/#{webhook_secret} " \
               "https://example.test/callback/#{hex_secret} " \
               "https://example.test/api/v1/projects/agent-workflows/releases/2026-07-13"

    outputs = [doctor("--json", environment: { "DOCTOR_ENDPOINT_FIXTURE" => endpoint }).first,
               doctor(environment: { "DOCTOR_ENDPOINT_FIXTURE" => endpoint }).first]

    outputs.each do |output|
      assert_includes output, "https://hooks.slack.com/services/%5BREDACTED%5D"
      assert_includes output, "https://example.test/callback/%5BREDACTED%5D"
      assert_includes output, "https://example.test/api/v1/projects/agent-workflows/releases/2026-07-13"
      refute_includes output, webhook_secret
      refute_includes output, hex_secret
    end
  end

  def test_explicit_missing_state_root_is_forwarded_without_creation
    missing = path("missing-state")
    args = path("coord-args")
    doctor("--json", environment: { "AGENT_COORD_STATE_ROOT" => missing, "DOCTOR_COORD_ARGS_FILE" => args })

    assert_includes File.readlines(args, chomp: true), missing
    refute_path_exists missing
  end

  def test_unsafe_dashboard_url_is_rejected_before_delegation
    _stdout, stderr, status = doctor("--json", dashboard_url: "http://example.com:4319")

    assert_equal 64, status.exitstatus
    assert_includes stderr, "must use loopback HTTP"
  end

  private

  def path(*parts)
    File.join(@tmp, *parts)
  end

  def doctor(*arguments, environment: {}, dashboard_url: "http://127.0.0.1:4319")
    env = COMPONENTS.to_h { |name| ["AGENT_STACK_#{name.tr('-', '_').upcase}_URL", path("origins", "#{name}.git")] }
    env["AGENT_COORD_STATE_ROOT"] = path("runtime/state")
    command = [File.join(ROOT, "bin/agent-stack"), "doctor",
               "--source-root", path("src"), "--compat-root", path("compat"), "--runtime-root", path("runtime"),
               "--target", path("target"), "--agent-coord-install-dir", path("install")]
    command.concat(["--dashboard-url", dashboard_url]) if dashboard_url
    Open3.capture3(env.merge(environment), *command, *arguments)
  end

  def create_checkout(name)
    checkout = path("src", name)
    FileUtils.mkdir_p([checkout, path("origins")])
    system("git", "-C", checkout, "init", "--quiet", "-b", "main", exception: true)
    system("git", "-C", checkout, "config", "user.email", "doctor@example.com", exception: true)
    system("git", "-C", checkout, "config", "user.name", "Doctor", exception: true)
    File.write(File.join(checkout, "README.md"), "#{name}\n")
    system("git", "-C", checkout, "add", "README.md", exception: true)
    system("git", "-C", checkout, "commit", "--quiet", "-m", "fixture", exception: true)
    system("git", "-C", checkout, "remote", "add", "origin", path("origins", "#{name}.git"), exception: true)
  end

  def write_delegate(file, component, check_id)
    File.write(file, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      key = #{component.inspect} == "agent-workflows" ? "DOCTOR_WORKFLOW_ARGS_FILE" : "DOCTOR_COORD_ARGS_FILE"
      File.write(ENV[key], ARGV.join("\\n") + "\\n") if ENV[key]
      details = ENV["DOCTOR_ENDPOINT_FIXTURE"] ? {"endpoint" => ENV["DOCTOR_ENDPOINT_FIXTURE"]} : {}
      puts JSON.generate("schema_version" => 1, "component" => #{component.inspect}, "status" => "healthy",
        "checks" => [{"id" => #{check_id.inspect}, "status" => "healthy", "summary" => "ready", "details" => details, "guidance" => nil}])
    RUBY
    File.chmod(0o755, file)
  end

  def write_dashboard
    file = path("src/agent-coordination-dashboard/bin/agent-coordination-dashboard.js")
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, <<~JS)
      const fs = require("fs"); if (process.env.DOCTOR_DASHBOARD_ARGS_FILE) fs.writeFileSync(process.env.DOCTOR_DASHBOARD_ARGS_FILE, process.argv.slice(2).join("\\n") + "\\n");
      const stopped = process.env.DOCTOR_DASHBOARD_FIXTURE === "stopped";
      console.log(JSON.stringify({schema_version: 1, component: "agent-coordination-dashboard", status: stopped ? "degraded" : "healthy", checks: [{id: "dashboard.health", status: stopped ? "degraded" : "healthy", summary: stopped ? "dashboard service is not running" : "ready", details: {}, guidance: stopped ? "Start the optional dashboard, then rerun doctor." : null}]})); if (stopped) process.exitCode = 1;
    JS
    checkout = path("src/agent-coordination-dashboard")
    system("git", "-C", checkout, "add", "bin/agent-coordination-dashboard.js", exception: true)
    system("git", "-C", checkout, "commit", "--quiet", "-m", "doctor fixture", exception: true)
  end
end
