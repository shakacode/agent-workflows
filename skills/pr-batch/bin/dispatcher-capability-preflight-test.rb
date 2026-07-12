#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

HELPER = File.expand_path("dispatcher-capability-preflight", __dir__)

class DispatcherCapabilityPreflightTest < Minitest::Test
  def dispatch(input)
    stdout, stderr, status = Open3.capture3(HELPER, stdin_data: JSON.generate(input))
    assert status.success?, "helper failed: #{stderr}"

    JSON.parse(stdout)
  end

  def dispatch_raw(stdin_data)
    stdout, stderr, status = Open3.capture3(HELPER, stdin_data:)
    assert status.success?, "helper failed: #{stderr}"

    JSON.parse(stdout)
  end

  def test_required_route_and_dispatcher_bind_attest_and_resume_once
    output = dispatch(
      "lane_id" => "incident-116",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ],
      "lane_state" => { "claim" => "claim-1", "branch" => "fix/116", "worktree" => "/tmp/116" }
    )

    assert_equal "selected", output.fetch("status")
    assert_equal({ "model" => "Sol", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal "remote", output.fetch("actual_dispatcher")
    assert_equal true, output.fetch("resume_goal")
    assert_equal 1, output.fetch("active_assignments").length
    assert_equal "claim-1", output.dig("lane_state", "claim")
    assert output.dig("dispatch", "launch_token")
  end

  def test_uses_an_explicitly_authorized_ordered_route_fallback
    output = dispatch(
      "lane_id" => "incident-stronger-fallback",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "selected", output.fetch("status")
    assert_equal({ "model" => "Sol", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal "authorized-fallback-bound-and-attested", output.fetch("reason")
  end

  def test_prefers_an_authorized_exact_route_dispatcher_fallback_before_later_route_downgrade
    output = dispatch(
      "lane_id" => "incident-dispatcher-fallback",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "in-process",
          "fallback_authorized" => true,
          "binding" => nil,
          "attestation" => nil
        },
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "remote", output.fetch("actual_dispatcher")
    assert_equal({ "model" => "Sol", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal "authorized-exact-route-dispatcher-fallback", output.fetch("reason")
    assert_equal 1, output.fetch("active_assignments").length
  end

  def test_rejects_an_unattested_dispatcher_before_a_later_authorized_candidate
    output = dispatch(
      "lane_id" => "incident-attestation",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "in-process",
          "binding" => "operator-selected",
          "attestation" => nil
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "remote", output.fetch("actual_dispatcher")
    assert_equal [{ "dispatcher" => "in-process", "reason" => "attestation-missing" }], output.fetch("rejections")
  end

  def test_no_authorized_fallback_emits_one_stable_restart_safe_decision_request
    input = {
      "lane_id" => "incident-decision",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Terra", "effort" => "medium" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ],
      "lane_state" => { "branch" => "fix/decision", "generation" => 7 }
    }

    first = dispatch(input)
    replay = dispatch(input)

    assert_equal "blocked-user-input", first.fetch("status")
    assert_equal false, first.fetch("resume_goal")
    assert_equal first.fetch("dispatch_decision_request"), replay.fetch("dispatch_decision_request")
    assert_equal "dispatch-decision-request", first.dig("dispatch_decision_request", "type")
    assert_equal 1, first.dig("dispatch_decision_request", "version")
    assert_equal input.fetch("requested"), first.dig("dispatch_decision_request", "requested")
    assert_equal "Which bound, attested requested tuple or explicitly authorized fallback should dispatch lane incident-decision?",
                 first.dig("dispatch_decision_request", "question")
    assert_equal input.fetch("lane_state"), first.fetch("lane_state")
  end

  def test_persisted_blocker_keeps_canonical_viable_fallback_choices_across_reconstructed_discovery
    input = {
      "lane_id" => "incident-persisted-decision",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "medium" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "fallback-instance"
      }]
    }

    first = dispatch(input)
    replay = dispatch(
      input.merge(
        "candidates" => [],
        "dispatch_decision_request" => first.fetch("dispatch_decision_request")
      )
    )

    assert_equal "blocked-user-input", first.fetch("status")
    choice = first.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    assert_equal({ "model" => "Terra", "effort" => "medium" }, choice.fetch("route"))
    assert_equal "remote", choice.fetch("dispatcher")
    assert_equal "operator-selected", choice.fetch("binding")
    assert_equal "instance-bound", choice.fetch("attestation")
    assert_equal "fallback-instance", choice.fetch("instance_id")
    assert_equal({ "dispatch" => false, "route" => true }, choice.fetch("required_authority"))
    assert_match(/^choice-/, choice.fetch("choice_id"))
    assert_equal first.fetch("dispatch_decision_request"), replay.fetch("dispatch_decision_request")
    assert_equal "dispatch_decision_request", replay.dig("persistence", "record")
    assert_equal false, replay.fetch("resume_goal")
  end

  def test_semantically_identical_requested_key_order_keeps_the_decision_request_id
    input = {
      "lane_id" => "incident-canonical-decision",
      "requested" => {
        "route" => {
          "model" => "Sol",
          "effort" => "high",
          "constraints" => [{ "capacity" => { "minimum" => 1, "maximum" => 2 } }]
        },
        "dispatcher" => "remote"
      },
      "authority" => { "dispatch" => true, "route" => true }
    }
    reordered = {
      "authority" => { "route" => true, "dispatch" => true },
      "requested" => {
        "dispatcher" => "remote",
        "route" => {
          "constraints" => [{ "capacity" => { "maximum" => 2, "minimum" => 1 } }],
          "effort" => "high",
          "model" => "Sol"
        }
      },
      "lane_id" => "incident-canonical-decision"
    }

    assert_equal dispatch(input).dig("dispatch_decision_request", "id"),
                 dispatch(reordered).dig("dispatch_decision_request", "id")
  end

  def test_hard_route_and_missing_explicit_authority_reject_substitution_and_coordinator_inheritance
    output = dispatch(
      "lane_id" => "incident-authority",
      "requested" => {
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "hard_route" => true
      },
      "coordinator_route" => { "model" => "Sol", "effort" => "high" },
      "authority" => { "use_subagents" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "authority must contain only boolean dispatch/route fields", output.fetch("reason")
  end

  def test_hard_route_rejects_a_route_substitution_even_when_the_fallback_is_authorized
    output = dispatch(
      "lane_id" => "incident-hard-route",
      "requested" => {
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "hard_route" => true
      },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal "hard-route-restriction", output.fetch("reason")
  end

  def test_round_trips_lane_state_and_replay_uses_one_stable_assignment
    lane_state = {
      "claim" => { "holder" => "worker-7", "generation" => 3 },
      "branch" => "fix/116",
      "worktree" => "/tmp/aw-d-i116",
      "file_map" => ["skills/pr-batch/**"],
      "sanitized_handoff" => { "next" => "verify" },
      "instance" => { "id" => "instance-7" }
    }
    input = {
      "lane_id" => "incident-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }],
      "lane_state" => lane_state
    }

    first = dispatch(input)
    replay = dispatch(input.merge("active_assignments" => first.fetch("active_assignments")))

    assert_equal "active_assignments", first.dig("persistence", "record")
    assert_equal "before-goal-resume-or-worker-launch", first.dig("persistence", "required_before")
    assert_equal "launch-pending", replay.fetch("status")
    assert_equal true, replay.fetch("resume_goal")
    assert_equal first.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal lane_state, replay.fetch("lane_state")
    assert_equal first.fetch("active_assignments"), replay.fetch("active_assignments")
    assert_equal 1, replay.fetch("active_assignments").length
  end

  def test_replay_rejects_a_token_match_with_corrupt_assignment_identity
    input = {
      "lane_id" => "incident-corrupt-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    }
    first = dispatch(input)
    corrupt = first.fetch("active_assignments").first.merge(
      "lane_id" => "other-lane",
      "route" => { "model" => "Terra", "effort" => "low" },
      "dispatcher" => "untrusted",
      "candidate_index" => 99
    )

    replay = dispatch(input.merge("active_assignments" => [corrupt]))

    assert_equal "blocked-replacement-fencing", replay.fetch("status")
    assert_equal "prior-instance-stop-and-reconciliation-required", replay.fetch("reason")
    assert_equal "stop-and-reconcile-prior-instance", replay.fetch("required_action")
    refute replay.key?("dispatch_decision_request")
    assert_equal [corrupt], replay.fetch("active_assignments")
  end

  def test_replay_rebuilds_the_canonical_assignment_instead_of_returning_persisted_fields
    input = {
      "lane_id" => "incident-canonical-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    }
    first = dispatch(input)
    persisted = first.fetch("active_assignments").first.merge("untrusted_metadata" => "must-not-echo")

    replay = dispatch(input.merge("active_assignments" => [persisted]))

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal first.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal [first.fetch("dispatch")], replay.fetch("active_assignments")
  end

  def test_replay_ignores_candidate_index_but_rebuilds_it_from_current_discovery_order
    input = {
      "lane_id" => "incident-discovery-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "stable-instance"
      }]
    }
    first = dispatch(input)
    shifted_candidates = [{
      "route" => { "model" => "Terra", "effort" => "low" },
      "dispatcher" => "unavailable",
      "binding" => "",
      "attestation" => "",
      "instance_id" => "unusable-instance"
    }] + input.fetch("candidates")

    replay = dispatch(input.merge("candidates" => shifted_candidates, "active_assignments" => first.fetch("active_assignments")))

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal first.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal first.fetch("active_assignments"), replay.fetch("active_assignments")
  end

  def test_semantically_identical_candidate_route_key_order_keeps_the_launch_token
    input = {
      "lane_id" => "incident-canonical-token",
      "requested" => {
        "route" => {
          "model" => "Sol",
          "effort" => "high",
          "constraints" => [{ "capacity" => { "minimum" => 1, "maximum" => 2 } }]
        },
        "dispatcher" => "remote"
      },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => {
          "model" => "Sol",
          "effort" => "high",
          "constraints" => [{ "capacity" => { "minimum" => 1, "maximum" => 2 } }]
        },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    }
    reordered = Marshal.load(Marshal.dump(input))
    reordered["candidates"][0]["route"] = {
      "constraints" => [{ "capacity" => { "maximum" => 2, "minimum" => 1 } }],
      "effort" => "high",
      "model" => "Sol"
    }

    assert_equal dispatch(input).dig("dispatch", "launch_token"),
                 dispatch(reordered).dig("dispatch", "launch_token")
  end

  def test_replacement_requires_stopped_and_reconciled_prior_instance
    output = dispatch(
      "lane_id" => "incident-replacement",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }],
      "active_assignments" => [{ "lane_id" => "incident-replacement", "launch_token" => "dispatch-old" }],
      "replacement" => { "prior_instance_stopped" => false, "reconciled" => false }
    )

    assert_equal "invalid-input", output.fetch("status")
  end

  def test_same_tuple_replacement_is_not_mistaken_for_a_replay
    input = {
      "lane_id" => "incident-same-tuple-replacement",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "worker-original"
      }]
    }
    first = dispatch(input)
    replacement = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("instance_id" => "worker-replacement")],
        "active_assignments" => first.fetch("active_assignments"),
        "replacement" => { "prior_instance_stopped" => false, "reconciled" => false }
      )
    )

    assert_equal "invalid-input", replacement.fetch("status")
  end

  def test_replacement_proof_is_bound_to_the_exact_prior_assignment_and_cannot_be_generic
    input = {
      "lane_id" => "incident-identity-bound-replacement",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "worker-original"
      }]
    }
    first = dispatch(input)
    confirmed = dispatch(
      input.merge(
        "active_assignments" => first.fetch("active_assignments"),
        "launch_confirmation" => {
          "type" => "launch-confirmation", "version" => 1, "id" => "confirm-replacement-proof-1",
          "assignment" => first.fetch("dispatch")
        }
      )
    )
    replacement_candidate = input.fetch("candidates").map { |candidate| candidate.merge("instance_id" => "worker-new") }
    expected_replacement = dispatch(input.merge("candidates" => replacement_candidate)).fetch("dispatch")

    generic = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => { "prior_instance_stopped" => true, "reconciled" => true }
      )
    )
    proof = {
      "type" => "replacement-proof",
      "version" => 1,
      "id" => "replacement-proof-1",
      "consumed" => false,
      "prior_assignment" => first.fetch("dispatch"),
      "replacement_assignment" => expected_replacement,
      "stop_attestation" => "stopped",
      "reconciliation_attestation" => "reconciled"
    }
    replaced = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => proof
      )
    )
    reused = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => first.fetch("active_assignments"),
        "replacement" => proof.merge("consumed" => true)
      )
    )

    assert_equal "invalid-input", generic.fetch("status")
    assert_equal "selected", replaced.fetch("status")
    assert_equal "replacement-proof-1", replaced.dig("replacement_transition", "proof_id")
    assert_equal true, replaced.dig("replacement_transition", "consumed")
    assert_equal "blocked-replacement-fencing", reused.fetch("status")
  end

  def test_replacement_proof_cannot_authorize_a_different_replacement_target_and_is_durably_consumed
    input = {
      "lane_id" => "incident-replacement-target",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "worker-original"
      }]
    }
    first = dispatch(input)
    confirmed = dispatch(
      input.merge(
        "active_assignments" => first.fetch("active_assignments"),
        "launch_confirmation" => {
          "type" => "launch-confirmation", "version" => 1, "id" => "confirm-replacement-target-1",
          "assignment" => first.fetch("dispatch")
        }
      )
    )
    replacement_candidate = input.fetch("candidates").map { |candidate| candidate.merge("instance_id" => "worker-new") }
    expected_replacement = dispatch(input.merge("candidates" => replacement_candidate)).fetch("dispatch")
    proof = {
      "type" => "replacement-proof",
      "version" => 1,
      "id" => "replacement-proof-target-1",
      "consumed" => false,
      "prior_assignment" => first.fetch("dispatch"),
      "replacement_assignment" => expected_replacement,
      "stop_attestation" => "stopped",
      "reconciliation_attestation" => "reconciled"
    }

    replaced = dispatch(
      input.merge(
        "candidates" => replacement_candidate,
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => proof
      )
    )
    reused_for_other_target = dispatch(
      input.merge(
        "candidates" => replacement_candidate.map { |candidate| candidate.merge("instance_id" => "worker-other") },
        "active_assignments" => confirmed.fetch("active_assignments"),
        "replacement" => proof
      )
    )

    assert_equal "selected", replaced.fetch("status")
    assert_equal "active_assignments-and-replacement-proof-consumption", replaced.dig("persistence", "record")
    assert_equal true, replaced.dig("replacement_transition", "consumed")
    assert_equal expected_replacement, replaced.dig("replacement_transition", "replacement_assignment")
    assert_equal "blocked-replacement-fencing", reused_for_other_target.fetch("status")
  end

  def test_first_viable_authorized_tuple_wins_in_declared_order
    output = dispatch(
      "lane_id" => "incident-ordered",
      "requested" => { "route" => { "model" => "Terra", "effort" => "medium" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "dispatcher-a",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "dispatcher-b",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal "dispatcher-a", output.fetch("actual_dispatcher")
    assert_equal 0, output.dig("dispatch", "candidate_index")
  end

  def test_prefers_the_requested_tuple_over_an_earlier_authorized_fallback
    output = dispatch(
      "lane_id" => "incident-requested-priority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [
        {
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "fallback_authorized" => true,
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        },
        {
          "route" => { "model" => "Terra", "effort" => "high" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "test-instance"
        }
      ]
    )

    assert_equal({ "model" => "Terra", "effort" => "high" }, output.fetch("actual_route"))
    assert_equal 1, output.dig("dispatch", "candidate_index")
    assert_equal "requested-tuple-bound-and-attested", output.fetch("reason")
  end

  def test_selects_the_requested_tuple_without_fallback_authority
    output = dispatch(
      "lane_id" => "incident-requested-no-fallback-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => {},
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )

    assert_equal "selected", output.fetch("status")
    assert_equal "requested-tuple-bound-and-attested", output.fetch("reason")
  end

  def test_separates_dispatcher_and_route_fallback_authority
    exact_route_dispatcher_fallback = dispatch(
      "lane_id" => "incident-dispatch-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )
    route_fallback = dispatch(
      "lane_id" => "incident-route-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "route" => true },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )
    missing_dispatch_authority = dispatch(
      "lane_id" => "incident-missing-dispatch-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "in-process" },
      "authority" => { "route" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "test-instance"
      }]
    )

    assert_equal "selected", exact_route_dispatcher_fallback.fetch("status")
    assert_equal "selected", route_fallback.fetch("status")
    assert_equal "blocked-user-input", missing_dispatch_authority.fetch("status")
  end

  def test_rejects_empty_binding_and_attestation_evidence
    output = dispatch(
      "lane_id" => "incident-empty-evidence",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => {},
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "",
        "attestation" => ""
      }]
    )

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal [{ "dispatcher" => "remote", "reason" => "binding-missing" }], output.fetch("rejections")
  end

  def test_rejects_unknown_binding_attestation_and_prospective_instance_evidence
    %w[binding attestation instance_id].each do |field|
      candidate = {
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "prospective-instance"
      }
      candidate[field] = "  uNkNoWn  "

      output = dispatch(
        "lane_id" => "incident-unknown-#{field}",
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
        "authority" => {},
        "candidates" => [candidate]
      )

      assert_equal "blocked-user-input", output.fetch("status")
      assert_equal false, output.fetch("resume_goal")
      assert_equal [{ "dispatcher" => "remote", "reason" => "#{field.tr('_', '-')}-unknown" }],
                   output.fetch("rejections")
    end
  end

  def test_fails_closed_for_unknown_requested_tuple_and_unaccepted_or_negative_evidence
    %w[model effort].each do |field|
      requested = { "model" => "Sol", "effort" => "high" }
      requested[field] = "UNKNOWN"
      output = dispatch(
        "lane_id" => "incident-unknown-requested-#{field}",
        "requested" => { "route" => requested, "dispatcher" => "remote" }
      )

      assert_equal "invalid-input", output.fetch("status")
      assert_equal "requested model, effort, and dispatcher cannot be UNKNOWN", output.fetch("reason")
    end

    unknown_dispatcher = dispatch(
      "lane_id" => "incident-unknown-requested-dispatcher",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "UNKNOWN" }
    )
    evidence = dispatch(
      "lane_id" => "incident-evidence-vocabulary",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "unbound",
        "attestation" => "arbitrary-nonempty-string",
        "instance_id" => "prospective-instance"
      }]
    )

    assert_equal "invalid-input", unknown_dispatcher.fetch("status")
    assert_equal "requested model, effort, and dispatcher cannot be UNKNOWN", unknown_dispatcher.fetch("reason")
    assert_equal "blocked-user-input", evidence.fetch("status")
    assert_equal [{ "dispatcher" => "remote", "reason" => "binding-negative" }], evidence.fetch("rejections")
  end

  def test_identity_bound_operator_decision_resolves_persisted_request_without_erasing_history
    input = {
      "lane_id" => "incident-operator-decision",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "decision-instance"
      }]
    }
    blocked = dispatch(input)
    choice = blocked.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    resolved = dispatch(
      input.merge(
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => {
          "type" => "dispatch-decision",
          "version" => 1,
          "id" => "operator-decision-1",
          "request_id" => blocked.dig("dispatch_decision_request", "id"),
          "lane_id" => input.fetch("lane_id"),
          "choice_id" => choice.fetch("choice_id"),
          "updated_authority" => { "dispatch" => true, "route" => true }
        }
      )
    )

    assert_equal "selected", resolved.fetch("status")
    assert_equal true, resolved.fetch("resume_goal")
    assert_equal blocked.fetch("dispatch_decision_request"), resolved.fetch("dispatch_decision_request")
    assert_equal "operator-decision-1", resolved.dig("decision_resolution", "decision_id")
  end

  def test_identity_bound_refresh_revises_a_zero_choice_hard_route_request_before_later_availability
    input = {
      "lane_id" => "incident-hard-route-refresh",
      "requested" => {
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "hard_route" => true
      },
      "authority" => { "dispatch" => true, "route" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "wrong-route"
      }]
    }
    blocked = dispatch(input)
    refresh = {
      "type" => "dispatch-decision-refresh",
      "version" => 1,
      "id" => "operator-refresh-1",
      "request_id" => blocked.dig("dispatch_decision_request", "id"),
      "lane_id" => input.fetch("lane_id")
    }
    still_blocked = dispatch(
      input.merge(
        "candidates" => [],
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => refresh
      )
    )
    later_available = dispatch(
      input.merge(
        "candidates" => [{
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "binding" => "operator-selected",
          "attestation" => "instance-bound",
          "instance_id" => "later-exact-instance"
        }],
        "dispatch_decision_request" => still_blocked.fetch("dispatch_decision_request"),
        "operator_decision" => refresh.merge("request_id" => still_blocked.dig("dispatch_decision_request", "id"), "id" => "operator-refresh-2")
      )
    )

    assert_equal "blocked-user-input", blocked.fetch("status")
    assert_empty blocked.dig("dispatch_decision_request", "viable_fallback_choices")
    assert_equal "blocked-user-input", still_blocked.fetch("status")
    assert_equal 2, still_blocked.dig("dispatch_decision_request", "revision")
    assert_equal blocked.fetch("dispatch_decision_request"), still_blocked.dig("dispatch_decision_request", "prior_request")
    assert_equal "selected", later_available.fetch("status")
    assert_equal still_blocked.fetch("dispatch_decision_request"), later_available.fetch("dispatch_decision_request")
    assert_equal "operator-refresh-2", later_available.dig("decision_resolution", "decision_id")
  end

  def test_decision_replay_with_active_assignment_preserves_the_request_and_resolution
    input = {
      "lane_id" => "incident-decision-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "decision-replay-instance"
      }]
    }
    blocked = dispatch(input)
    choice = blocked.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    decision = {
      "type" => "dispatch-decision",
      "version" => 1,
      "id" => "operator-decision-replay-1",
      "request_id" => blocked.dig("dispatch_decision_request", "id"),
      "lane_id" => input.fetch("lane_id"),
      "choice_id" => choice.fetch("choice_id"),
      "updated_authority" => { "dispatch" => true, "route" => true }
    }
    selected = dispatch(input.merge("dispatch_decision_request" => blocked.fetch("dispatch_decision_request"), "operator_decision" => decision))
    replay = dispatch(
      input.merge(
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => decision,
        "active_assignments" => selected.fetch("active_assignments")
      )
    )

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal true, replay.fetch("resume_goal")
    assert_equal selected.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal blocked.fetch("dispatch_decision_request"), replay.fetch("dispatch_decision_request")
    assert_equal selected.fetch("decision_resolution"), replay.fetch("decision_resolution")
  end

  def test_launch_pending_replays_the_same_instruction_until_an_identity_bound_confirmation_marks_it_active
    input = {
      "lane_id" => "incident-launch-lifecycle",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "lifecycle-instance"
      }]
    }

    pending = dispatch(input)
    replay_pending = dispatch(input.merge("active_assignments" => pending.fetch("active_assignments")))
    confirmation = {
      "type" => "launch-confirmation",
      "version" => 1,
      "id" => "launch-confirmation-1",
      "assignment" => pending.fetch("dispatch")
    }
    confirmed = dispatch(
      input.merge(
        "active_assignments" => replay_pending.fetch("active_assignments"),
        "launch_confirmation" => confirmation
      )
    )
    replay_active = dispatch(
      input.merge(
        "active_assignments" => confirmed.fetch("active_assignments"),
        "launch_confirmation" => confirmed.fetch("launch_confirmation")
      )
    )

    assert_equal "launch-pending", pending.dig("active_assignments", 0, "lifecycle")
    assert_equal "launch-pending", replay_pending.fetch("status")
    assert_equal pending.fetch("dispatch"), replay_pending.fetch("dispatch")
    assert_equal pending.dig("dispatch", "launch_token"), replay_pending.dig("dispatch", "launch_token")
    assert_equal "confirmed-active", confirmed.dig("active_assignments", 0, "lifecycle")
    assert_equal confirmation, confirmed.fetch("launch_confirmation")
    assert_equal "replay-already-active", replay_active.fetch("status")
    refute replay_active.key?("dispatch")
  end

  def test_launch_pending_does_not_bypass_replacement_fencing_after_the_requested_identity_changes
    input = {
      "lane_id" => "incident-pending-route-change",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote", "binding" => "operator-selected",
        "attestation" => "instance-bound", "instance_id" => "pending-old"
      }]
    }
    pending = dispatch(input)
    changed = dispatch(
      input.merge(
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" },
                         "dispatcher" => "remote", "hard_route" => true },
        "candidates" => [],
        "active_assignments" => pending.fetch("active_assignments")
      )
    )

    assert_equal "blocked-replacement-fencing", changed.fetch("status")
    assert_equal pending.fetch("active_assignments"), changed.fetch("active_assignments")
  end

  def test_confirmed_active_replays_without_requiring_fresh_discovery
    input = {
      "lane_id" => "incident-active-empty-discovery",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote", "binding" => "operator-selected",
        "attestation" => "instance-bound", "instance_id" => "active-instance"
      }]
    }
    pending = dispatch(input)
    confirmation = {
      "type" => "launch-confirmation", "version" => 1, "id" => "active-confirmation",
      "assignment" => pending.fetch("dispatch")
    }
    active = dispatch(input.merge("active_assignments" => pending.fetch("active_assignments"),
                                  "launch_confirmation" => confirmation))
    replay = dispatch(input.merge("candidates" => [], "active_assignments" => active.fetch("active_assignments")))
    changed = dispatch(
      input.merge(
        "requested" => { "route" => { "model" => "Terra", "effort" => "high" },
                         "dispatcher" => "remote", "hard_route" => true },
        "candidates" => [],
        "active_assignments" => active.fetch("active_assignments")
      )
    )

    assert_equal "replay-already-active", replay.fetch("status")
    refute replay.key?("dispatch")
    assert_equal "blocked-replacement-fencing", changed.fetch("status")
  end

  def test_pending_replay_fences_changed_or_unusable_current_candidate_evidence
    input = {
      "lane_id" => "incident-pending-candidate-revalidation",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote", "binding" => "operator-selected",
        "attestation" => "instance-bound", "instance_id" => "stable-instance"
      }]
    }
    pending = dispatch(input)
    changed_instance = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("instance_id" => "different-instance")],
        "active_assignments" => pending.fetch("active_assignments")
      )
    )
    unknown_evidence = dispatch(
      input.merge(
        "candidates" => [input.fetch("candidates").first.merge("binding" => "UNKNOWN")],
        "active_assignments" => pending.fetch("active_assignments")
      )
    )

    assert_equal "blocked-replacement-fencing", changed_instance.fetch("status")
    assert_equal "blocked-replacement-fencing", unknown_evidence.fetch("status")
  end

  def test_cross_lane_replacement_proof_cannot_authorize_a_current_lane_replacement
    input = {
      "lane_id" => "incident-current-lane",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => [{
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "replacement-instance"
      }],
      "active_assignments" => [{
        "lane_id" => "other-lane",
        "route" => { "model" => "Sol", "effort" => "high" },
        "dispatcher" => "remote",
        "instance_id" => "prior-instance",
        "launch_token" => "dispatch-prior",
        "lifecycle" => "confirmed-active"
      }],
      "replacement" => {
        "type" => "replacement-proof",
        "version" => 1,
        "id" => "cross-lane-proof",
        "consumed" => false,
        "stop_attestation" => "stopped",
        "reconciliation_attestation" => "reconciled",
        "prior_assignment" => {
          "lane_id" => "other-lane",
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "instance_id" => "prior-instance",
          "launch_token" => "dispatch-prior"
        },
        "replacement_assignment" => {
          "lane_id" => "other-lane",
          "route" => { "model" => "Sol", "effort" => "high" },
          "dispatcher" => "remote",
          "instance_id" => "replacement-instance",
          "launch_token" => "dispatch-irrelevant"
        }
      }
    }
    seed_input = input.dup
    seed_input.delete("active_assignments")
    seed_input.delete("replacement")
    input.fetch("replacement")["replacement_assignment"] = dispatch(seed_input).fetch("dispatch")

    output = dispatch(input)

    assert_equal "blocked-replacement-fencing", output.fetch("status")
    assert_equal "stop-and-reconcile-prior-instance", output.fetch("required_action")
  end

  def test_persisted_decision_resolution_replays_without_a_transient_operator_decision
    input = {
      "lane_id" => "incident-resolution-replay",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => { "dispatch" => true },
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "fallback_authorized" => true,
        "binding" => "operator-selected",
        "attestation" => "instance-bound",
        "instance_id" => "resolution-instance"
      }]
    }
    blocked = dispatch(input)
    choice = blocked.dig("dispatch_decision_request", "viable_fallback_choices", 0)
    selected = dispatch(
      input.merge(
        "dispatch_decision_request" => blocked.fetch("dispatch_decision_request"),
        "operator_decision" => {
          "type" => "dispatch-decision",
          "version" => 1,
          "id" => "resolution-decision",
          "request_id" => blocked.dig("dispatch_decision_request", "id"),
          "lane_id" => input.fetch("lane_id"),
          "choice_id" => choice.fetch("choice_id"),
          "updated_authority" => { "dispatch" => true, "route" => true }
        }
      )
    )
    replay = dispatch(
      input.merge(
        "dispatch_decision_request" => selected.fetch("dispatch_decision_request"),
        "decision_resolution" => selected.fetch("decision_resolution"),
        "active_assignments" => selected.fetch("active_assignments")
      )
    )

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal selected.fetch("dispatch"), replay.fetch("dispatch")
    assert_equal selected.fetch("decision_resolution"), replay.fetch("decision_resolution")
  end

  def test_deeply_malformed_persisted_state_is_invalid_input_instead_of_an_exception
    base = {
      "lane_id" => "incident-invalid-persisted-state",
      "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
      "candidates" => []
    }
    malformed_inputs = [
      base.merge("active_assignments" => [{ "lane_id" => "incident-invalid-persisted-state" }]),
      base.merge("active_assignments" => [{
                   "lane_id" => "incident-invalid-persisted-state",
                   "route" => { "model" => "Sol", "effort" => "high" },
                   "dispatcher" => "remote", "instance_id" => "UNKNOWN",
                   "launch_token" => "dispatch-token", "lifecycle" => "launch-pending"
                 }]),
      base.merge("replacement" => { "type" => "replacement-proof", "prior_assignment" => [] }),
      base.merge("launch_confirmation" => []),
      base.merge("dispatch_decision_request" => true),
      base.merge("dispatch_decision_request" => "not-a-request"),
      base.merge("dispatch_decision_request" => {
                   "type" => "dispatch-decision-request", "version" => 1,
                   "id" => "orphan-revision", "revision" => 2,
                   "lane_id" => "incident-invalid-persisted-state",
                   "requested" => base.fetch("requested"), "authority" => {},
                   "reason" => "bad", "question" => "bad", "viable_fallback_choices" => []
                 }),
      base.merge("dispatch_decision_request" => {
                   "type" => "dispatch-decision-request", "version" => 1,
                   "id" => "bad-request", "revision" => 1,
                   "lane_id" => "incident-invalid-persisted-state",
                   "requested" => base.fetch("requested"), "authority" => {},
                   "reason" => "bad", "question" => "bad",
                   "viable_fallback_choices" => [{ "choice_id" => [] }]
                 }),
      base.merge("dispatch_decision_request" => {
                   "type" => "dispatch-decision-request", "version" => 1,
                   "id" => "bad-history", "revision" => 2,
                   "lane_id" => "incident-invalid-persisted-state",
                   "requested" => base.fetch("requested"), "authority" => {},
                   "reason" => "bad", "question" => "bad", "viable_fallback_choices" => [],
                   "prior_request" => { "revision" => "one" }
                 }, "decision_resolution" => [])
    ]

    malformed_inputs.each do |input|
      output = dispatch(input)
      assert_equal "invalid-input", output.fetch("status"), input.inspect
    end
  end

  def test_malformed_json_returns_structured_invalid_input
    output = dispatch_raw("{not-json")

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "malformed-json", output.fetch("reason")
  end

  def test_rejects_a_candidate_without_explicit_instance_identity
    output = dispatch(
      "lane_id" => "incident-missing-instance-identity",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => {},
      "candidates" => [{
        "route" => { "model" => "Terra", "effort" => "high" },
        "dispatcher" => "remote",
        "binding" => "operator-selected",
        "attestation" => "instance-bound"
      }]
    )

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal [{ "dispatcher" => "remote", "reason" => "instance-identity-missing" }], output.fetch("rejections")
  end

  def test_rejects_malformed_top_level_authority_shape
    output = dispatch(
      "lane_id" => "incident-invalid-authority",
      "requested" => { "route" => { "model" => "Terra", "effort" => "high" }, "dispatcher" => "remote" },
      "authority" => [true],
      "candidates" => []
    )

    assert_equal "invalid-input", output.fetch("status")
    assert_equal "authority must contain only boolean dispatch/route fields", output.fetch("reason")
  end

  def test_rejects_unknown_or_non_boolean_authority_fields_before_persisting_a_request
    [{ "use_subagents" => true }, { "dispatch" => "yes" }].each do |authority|
      output = dispatch(
        "lane_id" => "incident-invalid-authority-fields",
        "requested" => { "route" => { "model" => "Sol", "effort" => "high" }, "dispatcher" => "remote" },
        "authority" => authority,
        "candidates" => []
      )

      assert_equal "invalid-input", output.fetch("status")
      assert_equal "authority must contain only boolean dispatch/route fields", output.fetch("reason")
    end
  end
end
