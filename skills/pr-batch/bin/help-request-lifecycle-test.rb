#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"

SCRIPT = File.expand_path("help-request-lifecycle", __dir__)
FIXTURE = File.expand_path("../fixtures/help-request-lifecycle-replay.json", __dir__)

class HelpRequestLifecycleTest < Minitest::Test
  def run_lifecycle(input: FIXTURE, now: "2026-08-26T00:44:31Z", max_open_seconds: 14_400, require_phase: nil, lane: nil)
    argv = [
      RbConfig.ruby,
      SCRIPT,
      "--input", input,
      "--now", now,
      "--max-open-seconds", max_open_seconds.to_s
    ]
    argv.concat(["--require-phase", require_phase]) if require_phase
    argv.concat(["--lane", lane]) if lane
    stdout, stderr, status = Open3.capture3(
      *argv
    )
    [JSON.parse(stdout), stderr, status]
  end

  def test_open_permission_request_stops_implementation_and_review_transitions
    %w[implementation review].each do |phase|
      result, stderr, status = run_lifecycle(require_phase: phase)

      assert_equal 2, status.exitstatus, stderr
      assert_equal false, result.fetch("phase_gate").fetch("allowed")
      assert_equal "20260823T054818.000000Z-help4846", result.fetch("phase_gate").fetch("request_id")
    end
  end

  def test_open_permission_request_does_not_block_safe_closeout_phase
    result, stderr, status = run_lifecycle(require_phase: "closeout")

    assert_predicate status, :success?, stderr
    assert_equal false, result.fetch("phase_gate").fetch("allowed")
  end

  def test_open_request_in_another_lane_does_not_block_this_lane
    result, stderr, status = run_lifecycle(require_phase: "implementation", lane: "qa")

    assert_predicate status, :success?, stderr
    assert_equal true, result.fetch("phase_gate").fetch("allowed")
    assert_nil result.fetch("blocking_request_id")
  end

  def test_motivating_replay_names_the_oldest_open_permission_request
    result, stderr, status = run_lifecycle

    assert_predicate status, :success?, stderr
    assert_equal "blocked-user-input", result.fetch("status")
    assert_equal "20260823T054818.000000Z-help4846", result.fetch("blocking_request_id")
    assert_equal 240_973, result.fetch("blocking_request").fetch("age_seconds")
    assert_equal "permission", result.fetch("blocking_request").fetch("reason")
    assert_equal "open", result.fetch("blocking_request").fetch("state")
    assert_equal 15, result.fetch("prohibited_phase_transitions").length
    assert_equal true, result.fetch("terminal_action").fetch("required")
    assert_equal "blocked-user-input", result.fetch("terminal_action").fetch("status")
    assert_equal "20260823T054818.000000Z-help4846", result.fetch("terminal_action").fetch("request_id")
    refute_includes result.fetch("terminal_action").fetch("blocker"), "authorized-scope-exhausted"
  end

  def test_resolution_events_close_only_the_referenced_request
    input = replay_with(
      {
        "event_id" => "resolution-1",
        "batch_id" => "ror-a-issue-4846-20260817",
        "lane" => "review",
        "agent_id" => "ror-a-coordinator",
        "type" => "help_request.resolved",
        "at" => "2026-08-23T05:50:00Z",
        "evidence" => "20260823T054818.000000Z-help4846"
      }
    )

    result, stderr, status = run_lifecycle(input: input.path)

    assert_predicate status, :success?, stderr
    request = result.fetch("requests").find do |item|
      item.fetch("request_id") == "20260823T054818.000000Z-help4846"
    end
    assert_equal "resolved", request.fetch("state")
    assert_equal "resolution-1", request.fetch("resolution_event_id")
    refute_equal "20260823T054818.000000Z-help4846", result["blocking_request_id"]
  ensure
    input&.close!
  end

  def test_declined_request_is_terminally_answered_not_open
    input = replay_with(
      {
        "event_id" => "decline-1",
        "batch_id" => "ror-a-issue-4846-20260817",
        "lane" => "review",
        "agent_id" => "ror-a-coordinator",
        "type" => "help_request.declined",
        "at" => "2026-08-23T05:50:00Z",
        "evidence" => "20260823T054818.000000Z-help4846"
      }
    )

    result, stderr, status = run_lifecycle(input: input.path)

    assert_predicate status, :success?, stderr
    request = result.fetch("requests").find do |item|
      item.fetch("request_id") == "20260823T054818.000000Z-help4846"
    end
    assert_equal "declined", request.fetch("state")
  ensure
    input&.close!
  end

  def test_coordinator_can_resolve_an_unlaned_worker_request_for_the_same_target
    input = Tempfile.new(["help-request-lifecycle-unlaned", ".json"])
    input.write(JSON.generate(
                  "events" => [
                    {
                      "event_id" => "request-1",
                      "batch_id" => "batch-1",
                      "target" => "462",
                      "agent_id" => "worker-1",
                      "type" => "help_requested",
                      "reason" => "permission",
                      "at" => "2026-08-23T05:48:18Z"
                    },
                    {
                      "event_id" => "resolution-1",
                      "batch_id" => "batch-1",
                      "target" => "issue:462",
                      "agent_id" => "coordinator-1",
                      "type" => "help_request.resolved",
                      "evidence" => "request-1",
                      "at" => "2026-08-23T05:50:00Z"
                    }
                  ]
                ))
    input.flush

    result, stderr, status = run_lifecycle(input: input.path, now: "2026-08-23T05:51:00Z")

    assert_predicate status, :success?, stderr
    assert_equal "resolved", result.fetch("requests").first.fetch("state")
    assert_nil result.fetch("blocking_request_id")
  ensure
    input&.close!
  end

  def test_bounded_closeout_must_name_the_original_request
    input = replay_with(
      {
        "event_id" => "blocked-closeout-1",
        "batch_id" => "ror-a-issue-4846-20260817",
        "lane" => "review",
        "agent_id" => "ror-a-coordinator",
        "type" => "lane_closed",
        "at" => "2026-08-26T00:44:30Z",
        "status" => "blocked-user-input",
        "evidence" => "20260823T054818.000000Z-help4846"
      }
    )

    result, stderr, status = run_lifecycle(input: input.path)

    assert_predicate status, :success?, stderr
    assert_equal false, result.fetch("terminal_action").fetch("required")
    assert_equal true, result.fetch("terminal_action").fetch("recorded")
    assert_equal "20260823T054818.000000Z-help4846", result.fetch("terminal_action").fetch("request_id")
  ensure
    input&.close!
  end

  private

  def replay_with(event)
    payload = JSON.parse(File.read(FIXTURE))
    payload.fetch("events").insert(1, event)
    file = Tempfile.new(["help-request-lifecycle", ".json"])
    file.write(JSON.generate(payload))
    file.flush
    file
  end
end
