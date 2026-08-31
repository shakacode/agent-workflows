#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

HELPER = File.expand_path("host-task-launch", __dir__)
FIXTURES = JSON.parse(File.read(File.expand_path("../fixtures/host-task-launch-cases.json", __dir__)))

class HostTaskLaunchTest < Minitest::Test
  def test_prepare_publishes_before_one_durable_create_attempt
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      first = invoke(input)

      assert_equal "host-native-user-task", first.fetch("launch_mode")
      assert_equal "publish-control-tower", first.dig("action", "kind")
      assert_equal 0o600, File.stat(input.fetch("local_fence_path")).mode & 0o777
      assert_match uuid_v4, first.dig("record", "run_id")
      assert_match uuid_v4, first.dig("record", "launch_idempotency_key")

      repeated = invoke(input)
      assert_equal first.dig("record", "run_id"), repeated.dig("record", "run_id")
      assert_equal first.dig("record", "launch_idempotency_key"), repeated.dig("record", "launch_idempotency_key")

      input["operation"] = "publish"
      input["publication"] = publication_evidence(first.fetch("record"))
      assert_equal "begin-create", invoke(input).dig("action", "kind")

      input["operation"] = "begin-create"
      created = invoke(input)
      assert_equal "create-task", created.dig("action", "kind")
      assert_equal true, created.dig("action", "create_attempt_fenced")
      assert_equal "create-attempted", created.dig("record", "lanes", 0, "transition")
      assert_equal "reconcile-by-run-id", invoke(input).dig("action", "kind")
    end
  end

  def test_rejects_a_different_intent_without_mutating_the_existing_fence
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      invoke(input)
      before = File.binread(input.fetch("local_fence_path"))
      input["intent"]["task_title"] = "different title"

      result = invoke(input)

      assert_equal "invalid-input", result.fetch("status")
      assert_equal before, File.binread(input.fetch("local_fence_path"))
    end
  end

  def test_copy_paste_does_not_return_a_host_create_action
    Dir.mktmpdir("host-task-launch-test") do |directory|
      result = invoke(input_for(directory, fixture: "copy_paste"))

      assert_equal "copy-paste", result.fetch("launch_mode")
      assert_equal "copy-paste", result.dig("action", "kind")
    end
  end

  def test_retry_uses_the_same_key_only_when_host_idempotency_is_supported
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      created = begin_create(input)
      input["operation"] = "retry"
      retry_result = invoke(input)

      assert_equal "reconcile-by-run-id", retry_result.dig("action", "kind")
      assert_equal created.dig("record", "run_id"), retry_result.dig("record", "run_id")

      input.dig("capability_preflight", "launch_safety")["task_creation_idempotency"] = "available"
      assert_equal "retry-create-task", invoke(input).dig("action", "kind")
    end
  end

  def test_binds_immediate_and_provisional_task_identities_and_renders_only_the_outer_marker
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      input["intent"]["task_title"] = "[hostile](javascript:alert(1)) <script>"
      input["operation"] = "bind-provisional"
      input["task_identity"] = { "provisional_id" => "provisional-1" }
      provisional = invoke(input)
      assert_equal "provisional-1", provisional.dig("record", "lanes", 0, "task", "provisional_id")
      assert_equal "UNKNOWN", provisional.dig("record", "lanes", 0, "task", "id")

      input["operation"] = "bind-task"
      input["task_identity"] = { "task_id" => "task-1", "task_url" => "https://example.test/<bad>" }
      result = invoke(input)
      rendered = result.fetch("control_tower")

      assert_equal "task-1", result.dig("record", "lanes", 0, "task", "id")
      assert_equal "provisional-1", result.dig("record", "lanes", 0, "task", "provisional_id")
      assert_equal 1, rendered.scan("<!-- agent-launcher-run-record:v1 -->").length
      refute_includes rendered, "<!-- agent-run-record:v1 -->"
      assert_includes rendered, "&lt;bad&gt;"
      refute_includes rendered, "<script>"
      refute_includes rendered, "hostile"
      assert_includes rendered, "Repository/issue:"
      assert_includes rendered, "Human input needed:"
    end
  end

  def test_waits_for_dependencies_without_returning_a_create_action
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      publish(input)
      input["dependency_state"] = "waiting"

      result = invoke(input)

      assert_equal "waiting", result.dig("record", "lanes", 0, "state")
      assert_equal "wait-for-dependencies", result.dig("action", "kind")
    end
  end

  def test_valid_no_backend_override_keeps_reconciliation_due_visible_and_invalid_override_is_rejected
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      input["publication"] = { "status" => "not-published" }
      input["no_backend_override"] = {
        "authorization_ref" => "issue://owner/repo/561#single-operator",
        "authorization_digest" => "a" * 64,
        "sole_coordinator_interval_seconds" => 300,
        "operator_context" => "single-operator",
        "coordination" => { "status" => "unavailable", "retry_evidence" => "bounded retry exhausted" }
      }
      result = invoke(input)
      assert_equal "create-task", result.dig("action", "kind")
      assert_includes result.fetch("control_tower"), "GitHub reconciliation due: yes"
      assert_equal "issue://owner/repo/561#single-operator", result.dig("record", "no_backend_override", "authorization_ref")

      input["no_backend_override"]["operator_context"] = "multi-operator"
      assert_equal "invalid-input", invoke(input).fetch("status")
    end
  end

  def test_rejects_duplicate_or_incomplete_lane_replay_identity
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      input.dig("intent", "lanes") << input.dig("intent", "lanes", 0).dup
      assert_equal "invalid-input", invoke(input).fetch("status")

      input = input_for(directory)
      input.dig("intent", "lanes", 0).delete("launch_token")
      assert_equal "invalid-input", invoke(input).fetch("status")
    end
  end

  def test_rejects_invalid_nested_helper_evidence
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      input.dig("intent", "lanes", 0, "helper_evidence").delete("run_id")

      assert_equal "invalid-input", invoke(input).fetch("status")
    end
  end

  def test_does_not_offer_a_blind_retry_without_idempotency_or_run_id_reconciliation
    Dir.mktmpdir("host-task-launch-test") do |directory|
      input = input_for(directory)
      begin_create(input)
      input["operation"] = "retry"
      input.dig("capability_preflight", "launch_safety")["reconciliation_by_outer_run_id"] = "unavailable"

      assert_equal "reconciliation-unavailable", invoke(input).dig("action", "kind")
    end
  end

  private

  def input_for(directory, fixture: "native")
    fixture_data = Marshal.load(Marshal.dump(FIXTURES.fetch(fixture)))
    fixture_data.merge(
      "type" => "host-task-launch",
      "version" => 1,
      "operation" => "prepare",
      "lane_id" => "issue-561",
      "capability_preflight" => capability_preflight(fixture),
      "local_fence_path" => File.join(directory, "launch-fence.json"),
      "publication" => { "status" => "not-published" },
      "coordination" => { "status" => "clear", "retry_evidence" => "bounded status read succeeded" },
      "intent" => {
        "repository" => "owner/repo",
        "work_item" => { "kind" => "issue", "number" => 561 },
        "purpose" => "implementation",
        "task_title" => "Owner repo #561 — launcher fence",
        "runner" => "portable-runner",
        "configured_machine_alias" => "machine-a",
        "record_destination" => "https://github.com/owner/repo/issues/561",
        "lanes" => [{
          "lane_id" => "issue-561",
          "dispatcher" => "portable-dispatcher",
          "instance_id" => "instance-1",
          "launch_token" => "launch-1",
          "helper_evidence" => valid_helper_evidence
        }]
      }
    )
  end

  def capability_preflight(fixture)
    native = fixture == "native"
    {
      "type" => "host-task-capability-preflight-result", "version" => 1,
      "status" => native ? "capability-selected" : "copy-paste-required",
      "launch_mode" => native ? "host-native-user-task" : "copy-paste",
      "launch_safety" => {
        "task_creation_idempotency" => "unavailable",
        "reconciliation_by_outer_run_id" => "available"
      }
    }
  end

  def publication_evidence(record)
    {
      "status" => "durably-published",
      "run_id" => record.fetch("run_id"),
      "record_destination" => record.fetch("record_destination"),
      "marker_type" => "agent-launcher-run-record:v1",
      "evidence_ref" => "https://github.com/owner/repo/issues/561#issuecomment-1",
      "rendered_record_sha256" => "b" * 64
    }
  end

  def publish(input)
    prepared = invoke(input)
    input["operation"] = "publish"
    input["publication"] = publication_evidence(prepared.fetch("record"))
    invoke(input)
  end

  def begin_create(input)
    publish(input)
    input["operation"] = "begin-create"
    invoke(input)
  end

  def valid_helper_evidence
    {
      "contract" => "agent-run-record", "version" => 1,
      "run_id" => "123e4567-e89b-42d3-a456-426614174000",
      "launch_idempotency_key" => "65d9f4e3-b51d-4a09-ae97-bd8704aa9aac",
      "repository" => "owner/repo",
      "work_item" => { "kind" => "issue", "number" => 561, "title" => "Title", "url" => "https://github.com/owner/repo/issues/561" },
      "prompt_source" => { "kind" => "issue-body", "url" => "https://github.com/owner/repo/issues/561", "digest_at_selection" => "a" * 64, "digest_at_launch" => "a" * 64, "digest_observed_by_worker" => "a" * 64 },
      "prompt_transport" => { "kind" => "complete-batch-plan", "reference" => "inline", "digest_at_launch" => "a" * 64 },
      "current_main" => { "branch" => "main", "sha" => "1" * 40 },
      "runner" => { "name" => "runner", "machine" => "machine", "model_at_prompt_creation" => "UNKNOWN", "model_at_worker_start" => "UNKNOWN" },
      "workflow_versions" => { "prompt_creation" => workflow("2026-08-30T02:00:56.829Z"), "worker_start" => workflow("2026-08-30T02:00:57.829Z"), "later_observations" => [] },
      "task" => { "title" => "Title", "id" => "UNKNOWN", "url" => "UNKNOWN" },
      "branch" => "UNKNOWN", "pr" => { "number" => "UNKNOWN", "url" => "UNKNOWN" }, "state" => "active", "outcome" => "pending",
      "latest_material_update" => { "at" => "2026-08-30T02:00:57.829Z", "summary" => "started" }, "blocker" => nil,
      "timestamps" => { "selected_at" => "2026-08-30T02:00:55.829Z", "prompt_created_at" => "2026-08-30T02:00:56.829Z", "worker_digest_observed_at" => "2026-08-30T02:00:57.829Z", "worker_started_at" => "2026-08-30T02:00:57.829Z", "observed_at" => "2026-08-30T02:00:59.000Z" }
    }
  end

  def workflow(observed_at)
    { "observed_at" => observed_at, "pack_head" => "2" * 40, "pr_batch_sha256" => "sha256:#{'3' * 64}", "pr_processing_sha256" => "sha256:#{'4' * 64}" }
  end

  def invoke(input)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER, stdin_data: JSON.generate(input))
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def uuid_v4
    /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end
end
