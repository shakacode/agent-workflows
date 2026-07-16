# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../bin/agent_doctor/workflows_component"

class AgentDoctorWorkflowsComponentTest < Minitest::Test
  ResultRunner = Struct.new(:result) do
    def capture(_command)
      result
    end
  end

  def test_not_installed_status_is_preserved_as_an_actionable_failure
    check = installation_check(status_payload("NOT_INSTALLED"), exit_status: 2)

    assert_equal "failed", check["status"]
    assert_equal "workflow installation is not installed", check["summary"]
    assert_equal "NOT_INSTALLED", check.dig("details", "source_status")
    assert_equal "/tmp/codex", check.dig("details", "target")
    assert_equal "/tmp/source", check.dig("details", "source")
    assert_equal "Install workflows with `agent-stack sync`.", check["guidance"]
  end

  def test_check_failed_status_preserves_reason_details_and_source_guidance
    payload = status_payload(
      "CHECK_FAILED",
      "reason" => "native and flat delivery cannot both be active",
      "guidance" => "Rerun with --delivery-mode plugin-companion.",
      "native" => { "state" => "active" },
      "flat" => { "state" => "present" }
    )
    check = installation_check(payload, exit_status: 3)

    assert_equal "failed", check["status"]
    assert_equal "workflow status check failed: native and flat delivery cannot both be active", check["summary"]
    assert_equal "CHECK_FAILED", check.dig("details", "source_status")
    assert_equal({ "state" => "active" }, check.dig("details", "native"))
    assert_equal({ "state" => "present" }, check.dig("details", "flat"))
    assert_equal "Rerun with --delivery-mode plugin-companion.", check["guidance"]
  end

  def test_failure_status_still_rejects_exit_and_schema_mismatches
    wrong_exit = installation_check(status_payload("NOT_INSTALLED"), exit_status: 3)
    wrong_schema = installation_check(status_payload("CHECK_FAILED", "reason" => nil), exit_status: 3)

    [wrong_exit, wrong_schema].each do |check|
      assert_equal "failed", check["status"]
      assert_equal "workflow status returned malformed JSON or a mismatched status", check["summary"]
    end
  end

  def test_healthy_status_for_another_invocation_is_rejected_without_echoing_child_paths
    payload = status_payload(
      "UP_TO_DATE",
      "host" => "claude",
      "target" => "/tmp/other-target?token=target-secret",
      "source" => "/tmp/other-source?token=source-secret",
      "installed_version" => "0.1.0",
      "installed_revision" => "abc"
    )

    check = installation_check(payload, exit_status: 0)

    assert_equal "failed", check["status"]
    assert_equal "workflow status identity does not match the requested invocation", check["summary"]
    assert_equal %w[host target source], check.dig("details", "mismatched_fields")
    assert_equal "Rerun `agent-stack sync` to repair the workflow status helper.", check["guidance"]
    refute_includes JSON.generate(check), "target-secret"
    refute_includes JSON.generate(check), "source-secret"
  end

  def test_each_requested_identity_field_is_bound_to_the_child_payload
    {
      "host" => "claude",
      "target" => "/tmp/other-target",
      "source" => "/tmp/other-source"
    }.each do |field, child_value|
      payload = status_payload(
        "UP_TO_DATE", field => child_value, "installed_version" => "0.1.0", "installed_revision" => "abc"
      )

      check = installation_check(payload, exit_status: 0)

      assert_equal "failed", check["status"], field
      assert_equal [field], check.dig("details", "mismatched_fields"), field
    end
  end

  def test_resolved_auto_host_with_matching_canonical_paths_remains_healthy
    payload = status_payload(
      "UP_TO_DATE", "installed_version" => "0.1.0", "installed_revision" => "abc"
    )

    check = installation_check(payload, exit_status: 0, host: "auto")

    assert_equal "healthy", check["status"]
  end

  private

  def installation_check(payload, exit_status:, host: "codex", target: "/tmp/codex", source: "/tmp/source")
    runner = ResultRunner.new({ stdout: JSON.generate(payload), stderr: "", exit: exit_status, failure: nil })
    component = AgentDoctor::WorkflowsComponent.new(runner: runner).call(
      host:, target:, source:, deep: false
    )
    component.fetch("checks").first
  end

  def status_payload(status, overrides = {})
    {
      "status" => status,
      "host" => "codex",
      "target" => "/tmp/codex",
      "source" => "/tmp/source",
      "installed_version" => nil,
      "installed_revision" => nil,
      "available_version" => "0.1.0",
      "available_revision" => nil,
      "checked_remote" => false,
      "reason" => nil,
      "guidance" => nil,
      "delivery_mode" => "flat",
      "native" => nil,
      "flat" => nil
    }.merge(overrides)
  end
end
