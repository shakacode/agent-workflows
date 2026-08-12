#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

WORKFLOW_PATH = File.expand_path("../.github/workflows/downstream-seam-audit.yml", __dir__)
VALIDATE_PATH = File.expand_path("validate", __dir__)

class DownstreamSeamAuditWorkflowTest < Minitest::Test
  def setup
    @text = File.read(WORKFLOW_PATH)
    @workflow = YAML.safe_load(@text, aliases: false)
    @triggers = @workflow.fetch("on") { @workflow.fetch(true) }
  end

  def test_contract_changes_schedule_and_manual_dispatch_trigger_the_audit
    push = @triggers.fetch("push")
    assert_equal ["main"], push.fetch("branches")
    expected_paths = [
      ".github/workflows/downstream-seam-audit.yml",
      "bin/agent-workflow-seam-doctor",
      "bin/push-downstream*",
      "downstream.yml",
      "seam-presets.yml"
    ]
    expected_paths.each { |path| assert_includes push.fetch("paths"), path }
    refute_empty @triggers.fetch("schedule")

    inputs = @triggers.fetch("workflow_dispatch").fetch("inputs")
    publish = inputs.fetch("publish")
    assert_equal "boolean", publish.fetch("type")
    assert_equal false, publish.fetch("default")
    assert inputs.key?("source_sha")
  end

  def test_automatic_audit_is_read_only_and_publisher_is_manually_gated
    assert_equal({ "contents" => "read" }, @workflow.fetch("permissions"))
    audit = @workflow.fetch("jobs").fetch("audit")
    audit_text = YAML.dump(audit)
    assert_includes audit_text, "bin/push-downstream --audit"
    refute_includes audit_text, "--apply"
    refute_includes audit_text, "DOWNSTREAM_SEAM_PUBLISH_TOKEN"
    assert_includes audit_text, "persist-credentials: false"

    publisher = @workflow.fetch("jobs").fetch("publish")
    assert_includes publisher.fetch("if"), "github.event_name == 'workflow_dispatch'"
    assert_includes publisher.fetch("if"), "inputs.publish == true"
    assert_equal "downstream-seam-publisher", publisher.fetch("environment")
    publisher_text = YAML.dump(publisher)
    assert_includes publisher_text, "secrets.DOWNSTREAM_SEAM_PUBLISH_TOKEN"
    assert_includes publisher_text, "--publish-report"
    assert_includes publisher_text, "bin/push-downstream --audit"
    assert_includes publisher_text, "--source-sha"
    assert_includes publisher_text, "--confirm-publish"
    assert_includes publisher_text, "persist-credentials: false"

    refute_includes @text, "gh pr merge"
    refute_includes @text, "git push"
    refute_includes @text, "--force"
  end

  def test_repository_validation_runs_the_workflow_and_publisher_contract_tests
    validate = File.read(VALIDATE_PATH)

    assert_includes validate, "ruby bin/downstream-seam-audit-workflow-test.rb"
    assert_includes validate, "ruby bin/push-downstream-publisher-test.rb"
  end
end
