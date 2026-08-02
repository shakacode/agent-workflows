#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for agent-workflows-status.
# Run with: ruby bin/agent-workflows-status-test.rb

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "openssl"
require "rbconfig"
require "tmpdir"

require_relative "agent_doctor/signed_launch_readiness"

SCRIPT = File.expand_path("agent-workflows-status", __dir__)

class AgentWorkflowsStatusTest < Minitest::Test
  STRONG_RSA_KEY = OpenSSL::PKey::RSA.generate(2048)
  WEAK_PUBLIC_KEY_PEM = OpenSSL::PKey::RSA.generate(1024).public_to_pem

  def setup
    @fake_codex_dir = Dir.mktmpdir("status-fake-codex")
    @fake_codex = File.join(@fake_codex_dir, "codex")
    File.write(@fake_codex, <<~RUBY)
      #!#{RbConfig.ruby}
      puts "PLUGIN STATUS VERSION PATH"
      puts "scw@agent-workflows  installed, enabled  0.1.0  https://github.com/shakacode/agent-workflows.git"
    RUBY
    FileUtils.chmod(0o755, @fake_codex)
  end

  def teardown
    FileUtils.remove_entry(@fake_codex_dir)
  end

  def run_status(env, *)
    Open3.capture2e({ "AGENT_WORKFLOWS_CODEX_EXECUTABLE" => @fake_codex }.merge(env), "ruby", SCRIPT, *)
  end

  def write_metadata(target, metadata)
    File.write(File.join(target, ".agent-workflows-install.json"), "#{JSON.pretty_generate(metadata)}\n")
  end

  def write_codex_native_state(target)
    cache_root = File.join(target, "plugins/cache/agent-workflows/scw/0.1.0")
    plugin_root = File.join(cache_root, ".codex-plugin")
    FileUtils.mkdir_p(plugin_root)
    FileUtils.mkdir_p(File.join(cache_root, "skills/example"))
    File.write(File.join(target, "config.toml"), "[plugins.\"scw@agent-workflows\"]\nenabled = true\n")
    File.write(File.join(cache_root, "skills/example/SKILL.md"), "example\n")
    manifest = {
      "name" => "scw",
      "version" => "0.1.0",
      "repository" => "https://github.com/shakacode/agent-workflows",
      "skills" => "./skills/"
    }
    File.write(File.join(plugin_root, "plugin.json"), "#{JSON.generate(manifest)}\n")
  end

  def write_signed_launch_capability(target)
    agents = File.join(target, ".agents")
    FileUtils.mkdir_p(agents)
    File.write(
      File.join(agents, "signed-launch-capability.json"),
      JSON.generate(
        "type" => "agent-workflow-signed-launch-capability",
        "version" => 1,
        "host" => "codex",
        "producer" => "codex-collaboration",
        "dispatcher_launch_key_id" => "dispatcher-key",
        "workflow_control_lifecycle_key_id" => "workflow-key"
      )
    )
    File.write(
      File.join(agents, "dispatcher-launch-trust.json"),
      JSON.generate(
        "type" => "agent-workflow-dispatcher-trust-anchor",
        "version" => 1,
        "agent_workflow_dispatcher_trusted_key_id" => "dispatcher-key",
        "agent_workflow_dispatcher_trusted_public_key_pem" => STRONG_RSA_KEY.public_to_pem
      )
    )
    File.write(
      File.join(agents, "workflow-control-lifecycle-trust.json"),
      JSON.generate(
        "type" => "agent-workflow-control-lifecycle-trust-anchor",
        "version" => 1,
        "agent_workflow_control_lifecycle_trusted_key_id" => "workflow-key",
        "agent_workflow_control_lifecycle_trusted_public_key_pem" => STRONG_RSA_KEY.public_to_pem
      )
    )
  end

  def test_not_installed_target_reports_not_installed
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      out, status = run_status({}, "--target", target, "--host", "claude")

      assert_equal 2, status.exitstatus, out
      assert_includes out, "NOT_INSTALLED"
    end
  end

  def test_up_to_date_with_non_git_source
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")

        out, status = run_status({}, "--target", target, "--host", "claude")

        assert_equal 0, status.exitstatus, out
        assert_includes out, "UP_TO_DATE"
      end
    end
  end

  def test_clean_codex_install_reports_signed_launch_as_unsupported_without_a_host_producer
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "UP_TO_DATE", payload.fetch("status")
        assert_equal(
          {
            "type" => "agent-workflow-signed-launch-readiness",
            "version" => 1,
            "host" => "codex",
            "capability" => "unsupported",
            "ready" => false,
            "reason" => "host-producer-unavailable",
            "dispatcher_launch" => "unsupported",
            "workflow_control_lifecycle" => "unsupported",
            "waiver" => "exact-batch-scoped-human-required"
          },
          payload.fetch("signed_launch_readiness")
        )
      end
    end
  end

  def test_codex_install_reports_supported_when_host_capability_and_both_trust_anchors_are_safe
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
        write_signed_launch_capability(target)

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "supported", payload.dig("signed_launch_readiness", "capability")
        assert_equal true, payload.dig("signed_launch_readiness", "ready")
        assert_equal "supported", payload.dig("signed_launch_readiness", "dispatcher_launch")
        assert_equal "supported", payload.dig("signed_launch_readiness", "workflow_control_lifecycle")
        assert_equal "codex-collaboration", payload.dig("signed_launch_readiness", "producer")
      end
    end
  end

  def test_signed_launch_readiness_reads_records_only_from_validated_descriptors
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      write_signed_launch_capability(target)
      path_read = File.method(:read)
      File.singleton_class.send(:define_method, :read) do |*_args, **_kwargs|
        raise "readiness record used a path-level read"
      end

      readiness = begin
        AgentDoctor::SignedLaunchReadiness.assess(host: "codex", target:)
      ensure
        File.singleton_class.send(:define_method, :read, path_read)
      end

      assert_equal "supported", readiness.fetch("capability")
    end
  end

  def test_signed_launch_readiness_rejects_a_symlinked_record
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-record") do |outside|
        write_signed_launch_capability(target)
        path = File.join(target, ".agents/dispatcher-launch-trust.json")
        replacement = File.join(outside, "dispatcher-launch-trust.json")
        FileUtils.mv(path, replacement)
        File.symlink(replacement, path)

        readiness = AgentDoctor::SignedLaunchReadiness.assess(host: "codex", target:)

        assert_equal "UNKNOWN", readiness.fetch("capability")
        assert_equal false, readiness.fetch("ready")
        assert_equal "not-permitted-while-capability-unknown", readiness.fetch("waiver")
      end
    end
  end

  def test_codex_install_rejects_a_1024_bit_public_trust_anchor
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
        write_signed_launch_capability(target)
        path = File.join(target, ".agents/dispatcher-launch-trust.json")
        anchor = JSON.parse(File.read(path))
        anchor["agent_workflow_dispatcher_trusted_public_key_pem"] = WEAK_PUBLIC_KEY_PEM
        File.write(path, JSON.generate(anchor))

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")

        assert_equal 0, status.exitstatus, out
        assert_equal "UNKNOWN", JSON.parse(out).dig("signed_launch_readiness", "capability")
      end
    end
  end

  def test_partial_signed_launch_files_report_unknown_and_do_not_allow_waiver
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
        FileUtils.mkdir_p(File.join(target, ".agents"))
        File.write(File.join(target, ".agents/signed-launch-capability.json"), "{}\n")

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        readiness = JSON.parse(out).fetch("signed_launch_readiness")

        assert_equal 0, status.exitstatus, out
        assert_equal "UNKNOWN", readiness.fetch("capability")
        assert_equal "not-permitted-while-capability-unknown", readiness.fetch("waiver")
      end
    end
  end

  def test_unsafe_agents_symlink_reports_unknown_even_when_host_files_are_absent
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        Dir.mktmpdir("agent-workflows-status-agents") do |outside|
          File.write(File.join(source, "VERSION"), "9.9.9\n")
          write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
          File.symlink(outside, File.join(target, ".agents"))

          out, status = run_status({}, "--target", target, "--host", "codex", "--json")

          assert_equal 0, status.exitstatus, out
          assert_equal "UNKNOWN", JSON.parse(out).dig("signed_launch_readiness", "capability")
        end
      end
    end
  end

  def test_private_or_writable_host_trust_material_reports_unknown
    %w[private-key writable-capability].each do |scenario|
      Dir.mktmpdir("agent-workflows-status-test") do |target|
        Dir.mktmpdir("agent-workflows-status-source") do |source|
          File.write(File.join(source, "VERSION"), "9.9.9\n")
          write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
          write_signed_launch_capability(target)
          if scenario == "private-key"
            path = File.join(target, ".agents/dispatcher-launch-trust.json")
            record = JSON.parse(File.read(path))
            record["agent_workflow_dispatcher_trusted_public_key_pem"] = OpenSSL::PKey::RSA.generate(1024).to_pem
            File.write(path, JSON.generate(record))
          else
            File.chmod(0o666, File.join(target, ".agents/signed-launch-capability.json"))
          end

          out, status = run_status({}, "--target", target, "--host", "codex", "--json")

          assert_equal 0, status.exitstatus, scenario
          assert_equal "UNKNOWN", JSON.parse(out).dig("signed_launch_readiness", "capability"), scenario
        end
      end
    end
  end

  def test_companion_status_reports_delivery_and_native_state
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_codex_native_state(target)
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "",
          "delivery_mode" => "plugin-companion"
        )

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "plugin-companion", payload.fetch("delivery_mode")
        assert_equal "active", payload.dig("native", "state")
        assert_equal "absent", payload.dig("flat", "state")
      end
    end
  end

  def test_companion_status_reports_scalar_native_manifests_as_unknown
    ["scw", 123, true].each do |manifest|
      Dir.mktmpdir("agent-workflows-status-test") do |target|
        Dir.mktmpdir("agent-workflows-status-source") do |source|
          File.write(File.join(source, "VERSION"), "9.9.9\n")
          write_codex_native_state(target)
          manifest_path = File.join(
            target,
            "plugins/cache/agent-workflows/scw/0.1.0/.codex-plugin/plugin.json"
          )
          File.write(manifest_path, "#{JSON.generate(manifest)}\n")
          write_metadata(
            target,
            "version" => "9.9.9",
            "source" => source,
            "source_revision" => "",
            "delivery_mode" => "plugin-companion"
          )

          out, status = run_status({}, "--target", target, "--host", "codex", "--json")
          payload = JSON.parse(out)

          assert_equal 3, status.exitstatus, out
          assert_equal "CHECK_FAILED", payload.fetch("status")
          assert_equal "unknown", payload.dig("native", "state")
          refute_includes out, "NoMethodError"
        end
      end
    end
  end

  def test_status_fails_closed_on_native_plus_flat_collision_with_guidance
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
        write_codex_native_state(target)
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => "",
          "delivery_mode" => "flat"
        )

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "cannot be active"
        assert_includes payload.fetch("guidance"), "--delivery-mode plugin-companion"
      end
    end
  end

  def test_delivery_mode_override_previews_flat_to_companion_migration
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        FileUtils.mkdir_p(File.join(target, "skills/example"))
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
        File.write(File.join(target, "skills/example/SKILL.md"), "example\n")
        system("git", "-C", source, "init", "--quiet", exception: true)
        system("git", "-C", source, "config", "user.email", "status-test@example.com", exception: true)
        system("git", "-C", source, "config", "user.name", "Status Test", exception: true)
        system("git", "-C", source, "add", ".", exception: true)
        system("git", "-C", source, "commit", "--quiet", "-m", "fixture", exception: true)
        revision, revision_status = Open3.capture2("git", "-C", source, "rev-parse", "HEAD")
        assert revision_status.success?, revision
        revision = revision.strip
        write_codex_native_state(target)
        write_metadata(
          target,
          "version" => "9.9.9",
          "source" => source,
          "source_revision" => revision,
          "delivery_mode" => "flat"
        )

        out, status = run_status(
          {}, "--target", target, "--host", "codex", "--delivery-mode", "plugin-companion", "--json"
        )
        payload = JSON.parse(out)

        assert_equal 0, status.exitstatus, out
        assert_equal "UP_TO_DATE", payload.fetch("status")
        assert_equal "plugin-companion", payload.fetch("delivery_mode")
        assert_equal "managed", payload.dig("flat", "state")
      end
    end
  end

  def test_invalid_delivery_mode_override_is_check_failed
    out, status = run_status({}, "--delivery-mode", "hybrid", "--json")

    assert_equal 3, status.exitstatus, out
    assert_includes out, "--delivery-mode must be flat or plugin-companion"
  end

  def test_check_failed_payload_without_resolved_target_reports_typed_unknown_readiness
    load SCRIPT
    payload = AgentWorkflowsStatus.build_payload(
      host: "codex", target: nil, source: nil, delivery_mode: "hybrid", fetch: false
    )

    assert_equal "CHECK_FAILED", payload.fetch("status")
    assert_nil payload.fetch("target")
    assert_equal "UNKNOWN", payload.dig("signed_launch_readiness", "capability")
    assert_equal false, payload.dig("signed_launch_readiness", "ready")
    assert_equal "target-unavailable", payload.dig("signed_launch_readiness", "reason")
    assert_equal "not-permitted-while-capability-unknown", payload.dig("signed_launch_readiness", "waiver")
  end

  def test_flat_status_reports_present_skill_route_without_migration_warning
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        FileUtils.mkdir_p(File.join(source, "skills/example"))
        FileUtils.mkdir_p(File.join(target, "skills/example"))
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        File.write(File.join(source, "skills/example/SKILL.md"), "example\n")
        File.write(File.join(target, "skills/example/SKILL.md"), "example\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "", "delivery_mode" => "flat")

        out, status = run_status({}, "--target", target, "--host", "codex", "--json")

        assert_equal 0, status.exitstatus, out
        assert_equal "present", JSON.parse(out).dig("flat", "state")
      end
    end
  end

  def test_non_ascii_metadata_does_not_crash_under_ascii_locale
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      # A clone path with non-ASCII bytes (accented home dir, em dash) must not
      # crash the JSON/text reads under a non-UTF-8 locale.
      write_metadata(
        target,
        "version" => "0.1.0",
        "source" => "/Users/josé/clones/café—repo",
        "source_revision" => "abc123"
      )

      out, status = run_status({ "LANG" => "C", "LC_ALL" => "C" }, "--target", target, "--host", "claude")

      refute_includes out, "invalid byte sequence"
      refute_includes out, "Encoding::"
      # The bogus source path cannot resolve, so the only valid outcome is a
      # clean CHECK_FAILED status, never an uncaught encoding crash.
      assert_includes out, "CHECK_FAILED"
      assert_equal 3, status.exitstatus, out
    end
  end

  def test_helper_system_call_failure_becomes_check_failed
    Dir.mktmpdir("agent-workflows-status-test") do |target|
      Dir.mktmpdir("agent-workflows-status-source") do |source|
        injection = File.join(target, "raise-system-call.rb")
        File.write(File.join(source, "VERSION"), "9.9.9\n")
        write_metadata(target, "version" => "9.9.9", "source" => source, "source_revision" => "")
        File.write(injection, <<~RUBY)
          require "open3"
          module RaiseSystemCall
            def capture3(*)
              raise Errno::EACCES, "delivery helper"
            end
          end
          Open3.singleton_class.prepend(RaiseSystemCall)
        RUBY

        out, status = run_status({ "RUBYOPT" => "-r#{injection}" }, "--target", target, "--host", "claude", "--json")
        payload = JSON.parse(out)

        assert_equal 3, status.exitstatus, out
        assert_equal "CHECK_FAILED", payload.fetch("status")
        assert_includes payload.fetch("reason"), "Permission denied"
      end
    end
  end
end
