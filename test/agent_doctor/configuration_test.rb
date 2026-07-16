# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/agent_doctor/configuration"

class AgentDoctorConfigurationTest < Minitest::Test
  def test_dashboard_url_accepts_only_bounded_loopback_http_base
    assert_equal "http://127.0.0.1:4319", AgentDoctor::Configuration.dashboard_uri("http://127.0.0.1:4319").to_s
    %w[https://localhost:4319 http://example.com:4319 http://user:pass@localhost:4319 http://localhost:4319/path].each do |url|
      assert_raises(AgentDoctor::Configuration::UsageError) { AgentDoctor::Configuration.dashboard_uri(url) }
    end
  end

  def test_runtime_state_precedes_implicit_xdg_state
    Dir.mktmpdir do |directory|
      runtime = File.join(directory, "runtime")
      xdg = File.join(directory, "xdg")
      FileUtils.mkdir_p([File.join(runtime, "state"), File.join(xdg, "agent-coordination")])

      selector = AgentDoctor::Configuration.coordination_selector(runtime, environment: { "XDG_STATE_HOME" => xdg })

      assert_equal ["--state-root", File.join(runtime, "state")], selector
    end
  end

  def test_missing_explicit_state_root_remains_authoritative
    Dir.mktmpdir do |directory|
      missing = File.join(directory, "missing")

      selector = AgentDoctor::Configuration.coordination_selector(directory,
                                                                  environment: { "AGENT_COORD_STATE_ROOT" => missing })

      assert_equal ["--state-root", missing], selector
      refute_path_exists missing
    end
  end

  def test_explicit_api_and_backend_selectors_are_forwarded
    assert_equal ["--api-url", "https://coord.example"],
                 AgentDoctor::Configuration.coordination_selector("/missing", environment: { "AGENT_COORD_API_URL" => "https://coord.example" })
    assert_equal ["--backend", "http"],
                 AgentDoctor::Configuration.coordination_selector("/missing", environment: { "AGENT_COORD_BACKEND" => "http" })
  end

  def test_empty_host_home_overrides_use_defaults_and_do_not_count_as_auto_candidates
    Dir.mktmpdir do |home|
      environment = { "CODEX_HOME" => "", "CLAUDE_HOME" => "" }

      assert_equal ["codex", File.join(home, ".codex")],
                   AgentDoctor::Configuration.host_and_target("codex", nil, environment: environment, home: home)
      FileUtils.mkdir_p(File.join(home, ".claude"))
      assert_equal ["claude", File.join(home, ".claude")],
                   AgentDoctor::Configuration.host_and_target("auto", nil, environment: environment, home: home)
    end
  end
end
