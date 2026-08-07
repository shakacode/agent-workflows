#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

HELPER = File.expand_path("dispatcher-capability-preflight", __dir__)
UNSIGNED_DISPATCH_FIXTURE = File.expand_path("../fixtures/unsigned-dispatch-smoke.json", __dir__)

class DispatcherCapabilityPreflightTest < Minitest::Test
  def dispatch(input)
    stdout, stderr, status = Open3.capture3(HELPER, stdin_data: JSON.generate(input))
    assert status.success?, "helper failed: #{stderr}"

    JSON.parse(stdout)
  end

  def dispatch_raw(input)
    stdout, stderr, status = Open3.capture3(HELPER, stdin_data: input)
    assert status.success?, "helper failed: #{stderr}"

    JSON.parse(stdout)
  end

  def requested_route(model: "Sol", effort: "high", dispatcher: "remote")
    {
      "route" => { "model" => model, "effort" => effort },
      "dispatcher" => dispatcher
    }
  end

  def candidate(model: "Sol", effort: "high", dispatcher: "remote", instance_id: "remote-1",
                fallback_authorized: nil, observed_host: nil)
    record = {
      "route" => { "model" => model, "effort" => effort },
      "dispatcher" => dispatcher,
      "instance_id" => instance_id
    }
    record["fallback_authorized"] = fallback_authorized unless fallback_authorized.nil?
    record["observed_host"] = observed_host if observed_host
    record
  end

  def input_for(lane_id: "lane-a", requested: requested_route, candidates: [candidate], authority: {})
    {
      "lane_id" => lane_id,
      "requested" => requested,
      "authority" => authority,
      "candidates" => candidates,
      "lane_state" => {
        "claim" => "claim-a",
        "branch" => "codex/lane-a",
        "worktree" => "/tmp/lane-a"
      }
    }
  end

  def select(input = input_for)
    output = dispatch(input)
    assert_equal "selected", output.fetch("status")
    output
  end

  def replacement_proof(prior_assignment, replacement_assignment, consumed: false)
    {
      "type" => "replacement-proof",
      "version" => 1,
      "id" => "replacement-1",
      "consumed" => consumed,
      "stop_attestation" => "stopped",
      "reconciliation_attestation" => "reconciled",
      "prior_assignment" => prior_assignment,
      "replacement_assignment" => replacement_assignment
    }
  end

  def test_route_preferences_do_not_require_binding_attestation_or_an_exact_match
    output = dispatch(
      input_for(
        requested: requested_route(model: "Sol", effort: "high"),
        candidates: [candidate(model: "Terra", effort: "medium")],
        authority: { "dispatch" => true }
      )
    )

    assert_equal "selected", output.fetch("status")
    assert_equal({ "model" => "Sol", "effort" => "high" }, output.fetch("preferred_route"))
    assert_equal({ "model" => "Terra", "effort" => "medium" }, output.fetch("selected_route_preference"))
    assert_equal(
      { "host" => "UNKNOWN", "model" => "UNKNOWN", "effort" => "UNKNOWN" },
      output.fetch("observed_host")
    )
    refute output.key?("actual_route")
  end

  def test_clean_install_fixture_dispatches_without_trust_material
    output = dispatch_raw(File.read(UNSIGNED_DISPATCH_FIXTURE))

    assert_equal "selected", output.fetch("status")
    assert_equal "advisory-route-fallback", output.fetch("reason")
    assert_equal "launch-pending", output.dig("dispatch", "lifecycle")
  end

  def test_legacy_hard_route_flag_is_ignored_as_advisory_metadata
    preference = requested_route.merge("hard_route" => true)
    output = dispatch(input_for(requested: preference, candidates: [candidate(model: "Terra")]))

    assert_equal "selected", output.fetch("status")
    refute output.dig("dispatch", "requested").key?("hard_route")
  end

  def test_unknown_model_and_effort_preferences_do_not_block_dispatch
    output = dispatch(
      input_for(
        requested: requested_route(model: "UNKNOWN", effort: "UNKNOWN"),
        candidates: [candidate(model: "UNKNOWN", effort: "UNKNOWN")]
      )
    )

    assert_equal "selected", output.fetch("status")
    assert_equal "UNKNOWN", output.dig("preferred_route", "model")
  end

  def test_partial_host_observation_uses_field_granular_unknown_without_blocking
    output = select(
      input_for(
        candidates: [candidate(observed_host: { "host" => "codex", "model" => "gpt-5.6-sol" })]
      )
    )

    assert_equal(
      { "host" => "codex", "model" => "gpt-5.6-sol", "effort" => "UNKNOWN" },
      output.fetch("observed_host")
    )
    assert_equal output.fetch("observed_host"), output.dig("dispatch", "observed_host")
  end

  def test_invalid_host_observation_is_rejected_as_an_unusable_candidate_not_an_exception
    input = input_for
    input.fetch("candidates").first["observed_host"] = "self-declared"
    output = dispatch(input)

    assert_equal "blocked-user-input", output.fetch("status")
    assert_equal [{ "dispatcher" => "remote", "reason" => "candidate-observed-host-invalid" }],
                 output.fetch("rejections")
  end

  def test_prefers_exact_route_then_same_dispatcher_before_an_authorized_dispatcher_fallback
    candidates = [
      candidate(model: "Terra", dispatcher: "other", instance_id: "other-1", fallback_authorized: true),
      candidate(model: "Terra", dispatcher: "remote", instance_id: "remote-route-fallback"),
      candidate(model: "Sol", dispatcher: "remote", instance_id: "remote-exact")
    ]
    output = select(input_for(candidates:, authority: { "dispatch" => true }))

    assert_equal "remote-exact", output.dig("dispatch", "instance_id")
    assert_equal "preferred-route-and-dispatcher", output.fetch("reason")
  end

  def test_same_dispatcher_route_fallback_needs_no_special_authority
    output = select(input_for(candidates: [candidate(model: "Terra", effort: "medium")]))

    assert_equal "advisory-route-fallback", output.fetch("reason")
    assert_equal "remote", output.fetch("selected_dispatcher")
  end

  def test_dispatcher_fallback_requires_explicit_candidate_and_dispatch_authority
    fallback = candidate(dispatcher: "other", instance_id: "other-1", fallback_authorized: true)
    blocked = dispatch(input_for(candidates: [fallback]))

    assert_equal "blocked-user-input", blocked.fetch("status")
    assert_equal "no-authorized-dispatcher-candidate", blocked.fetch("reason")
    assert_equal true, blocked.dig(
      "dispatch_decision_request", "viable_fallback_choices", 0, "required_authority", "dispatch"
    )

    selected = select(input_for(candidates: [fallback], authority: { "dispatch" => true }))
    assert_equal "authorized-dispatcher-fallback", selected.fetch("reason")
  end

  def test_blocked_decision_request_is_stable_and_operator_decision_preserves_history
    fallback = candidate(dispatcher: "other", instance_id: "other-1", fallback_authorized: true)
    input = input_for(candidates: [fallback])
    first = dispatch(input)
    second = dispatch(input)
    request = first.fetch("dispatch_decision_request")

    assert_equal request, second.fetch("dispatch_decision_request")
    decision = {
      "type" => "dispatch-decision",
      "version" => 1,
      "id" => "decision-1",
      "request_id" => request.fetch("id"),
      "lane_id" => "lane-a",
      "choice_id" => request.dig("viable_fallback_choices", 0, "choice_id"),
      "updated_authority" => { "dispatch" => true }
    }
    selected = dispatch(input.merge("dispatch_decision_request" => request, "operator_decision" => decision))

    assert_equal "selected", selected.fetch("status")
    assert_equal request, selected.fetch("dispatch_decision_request")
    assert_equal "dispatch-decision", selected.dig("decision_resolution", "action")
    assert_equal "dispatch-decision-fallback", selected.dig("dispatch", "selection_provenance")
  end

  def test_operator_decision_authorizes_fallback_whose_candidate_omitted_optional_route
    fallback = candidate(
      dispatcher: "other", instance_id: "other-1", fallback_authorized: true
    ).reject { |key, _value| key == "route" }
    input = input_for(candidates: [fallback])
    request = dispatch(input).fetch("dispatch_decision_request")
    choice = request.fetch("viable_fallback_choices").fetch(0)
    decision = {
      "type" => "dispatch-decision",
      "version" => 1,
      "id" => "decision-materialized-route",
      "request_id" => request.fetch("id"),
      "lane_id" => "lane-a",
      "choice_id" => choice.fetch("choice_id"),
      "updated_authority" => { "dispatch" => true }
    }

    assert_equal requested_route.fetch("route"), choice.fetch("route")
    selected = dispatch(
      input.merge("dispatch_decision_request" => request, "operator_decision" => decision)
    )

    assert_equal "selected", selected.fetch("status")
    assert_equal choice.fetch("choice_id"), selected.dig("decision_resolution", "choice_id")
    assert_equal requested_route.fetch("route"), selected.dig("dispatch", "route_preference")
    assert_equal "dispatch-decision-fallback", selected.dig("dispatch", "selection_provenance")
  end

  def test_persisted_decision_resolution_replays_without_transient_operator_decision
    fallback = candidate(dispatcher: "other", instance_id: "other-1", fallback_authorized: true)
    input = input_for(candidates: [fallback])
    request = dispatch(input).fetch("dispatch_decision_request")
    decision = {
      "type" => "dispatch-decision",
      "version" => 1,
      "id" => "decision-1",
      "request_id" => request.fetch("id"),
      "lane_id" => "lane-a",
      "choice_id" => request.dig("viable_fallback_choices", 0, "choice_id"),
      "updated_authority" => { "dispatch" => true }
    }
    first = dispatch(input.merge("dispatch_decision_request" => request, "operator_decision" => decision))
    resolution = first.fetch("decision_resolution")
    replay = dispatch(
      input.merge("dispatch_decision_request" => request, "decision_resolution" => resolution)
    )

    assert_equal "selected", replay.fetch("status")
    assert_equal first.dig("dispatch", "launch_token"), replay.dig("dispatch", "launch_token")
  end

  def test_pending_replay_reissues_the_same_token_and_active_replay_emits_no_dispatch
    input = input_for
    selected = select(input)
    pending = selected.fetch("active_assignments").first
    pending_replay = dispatch(input.merge("candidates" => [], "active_assignments" => [pending]))
    active = pending.merge("lifecycle" => "active")
    active_replay = dispatch(input.merge("candidates" => [], "active_assignments" => [active]))

    assert_equal "launch-pending", pending_replay.fetch("status")
    assert_equal pending.fetch("launch_token"), pending_replay.dig("dispatch", "launch_token")
    assert_equal "replay-already-active", active_replay.fetch("status")
    refute active_replay.key?("dispatch")
  end

  def test_pending_replay_ignores_malformed_optional_route_telemetry_for_same_identity
    input = input_for
    pending = select(input).fetch("active_assignments").first
    malformed_candidate = candidate.merge("route" => { "model" => "Sol" })

    replay = dispatch(
      input.merge("candidates" => [malformed_candidate], "active_assignments" => [pending])
    )

    assert_equal "launch-pending", replay.fetch("status")
    assert_equal pending.fetch("launch_token"), replay.dig("dispatch", "launch_token")
    assert_equal pending.fetch("route_preference"), replay.fetch("selected_route_preference")
    refute_equal "blocked-replacement-fencing", replay.fetch("status")
  end

  def test_malformed_current_route_preserves_different_persisted_fallback_route_on_replay
    input = input_for(candidates: [candidate(model: "Terra", effort: "medium")])
    pending = select(input).fetch("active_assignments").first
    malformed_candidate = candidate(model: "Terra", effort: "medium")
                          .merge("route" => { "model" => "Terra" })

    {
      "launch-pending" => pending,
      "replay-already-active" => pending.merge("lifecycle" => "active")
    }.each do |expected_status, assignment|
      replay = dispatch(
        input.merge("candidates" => [malformed_candidate], "active_assignments" => [assignment])
      )

      assert_equal expected_status, replay.fetch("status")
      assert_equal pending.fetch("launch_token"), replay.dig("active_assignments", 0, "launch_token")
      assert_equal({ "model" => "Terra", "effort" => "medium" }, replay.fetch("selected_route_preference"))
      assert_equal pending.fetch("route_preference"), replay.dig("active_assignments", 0, "route_preference")
      refute_equal "blocked-replacement-fencing", replay.fetch("status")
    end
  end

  def test_active_replay_ignores_malformed_optional_host_telemetry_for_same_identity
    observed_host = { "host" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" }
    input = input_for(candidates: [candidate(observed_host:)])
    active = select(input).fetch("active_assignments").first.merge("lifecycle" => "active")
    malformed_candidate = candidate.merge("observed_host" => { "host" => "" })

    replay = dispatch(
      input.merge("candidates" => [malformed_candidate], "active_assignments" => [active])
    )

    assert_equal "replay-already-active", replay.fetch("status")
    assert_equal active.fetch("launch_token"), replay.dig("active_assignments", 0, "launch_token")
    assert_equal active.fetch("observed_host"), replay.fetch("observed_host")
    refute replay.key?("replacement_transition")
  end

  def test_partial_current_host_telemetry_merges_field_by_field_for_pending_and_active_replay
    persisted_host = {
      "host" => "codex", "model" => "gpt-5.6-sol", "effort" => "high",
      "observed_at" => "2026-08-06T12:00:00Z", "evidence_ref" => "host://codex/first"
    }
    input = input_for(candidates: [candidate(observed_host: persisted_host)])
    pending = select(input).fetch("active_assignments").first
    current_candidate = candidate(observed_host: { "host" => "codex-desktop" })
    expected_host = persisted_host.merge("host" => "codex-desktop")

    {
      "launch-pending" => pending,
      "replay-already-active" => pending.merge("lifecycle" => "active")
    }.each do |expected_status, assignment|
      replay = dispatch(
        input.merge("candidates" => [current_candidate], "active_assignments" => [assignment])
      )

      assert_equal expected_status, replay.fetch("status")
      assert_equal expected_host, replay.fetch("observed_host")
      assert_equal expected_host, replay.dig("active_assignments", 0, "observed_host")
      assert_equal assignment.fetch("launch_token"), replay.dig("active_assignments", 0, "launch_token")
    end
  end

  def test_launch_confirmation_input_cannot_activate_an_ordinary_pending_assignment
    input = input_for
    pending = select(input).fetch("active_assignments").first
    output = dispatch(
      input.merge(
        "candidates" => [],
        "active_assignments" => [pending],
        "launch_confirmation" => { "type" => "launch-confirmation", "version" => 2 }
      )
    )

    assert_equal "launch-pending", output.fetch("status")
    refute output.key?("launch_confirmation")
  end

  def test_ordinary_active_state_replays_across_route_preference_changes_without_replacement
    input = input_for
    active = select(input).fetch("active_assignments").first.merge(
      "lifecycle" => "active",
      "observed_host" => { "host" => "codex", "model" => "UNKNOWN", "effort" => "UNKNOWN" }
    )
    replay = dispatch(
      input.merge(
        "requested" => requested_route(model: "Terra", effort: "medium"),
        "candidates" => [candidate(model: "Terra", effort: "medium")],
        "active_assignments" => [active]
      )
    )

    assert_equal "replay-already-active", replay.fetch("status")
    assert_equal active.fetch("launch_token"), replay.dig("active_assignments", 0, "launch_token")
    assert_equal({ "model" => "Terra", "effort" => "medium" }, replay.fetch("selected_route_preference"))
    assert_equal "codex", replay.dig("observed_host", "host")
    refute replay.key?("replacement_transition")
  end

  def test_launch_token_identity_is_stable_when_only_route_preference_changes
    first = select(input_for(requested: requested_route(model: "Sol"), candidates: [candidate(model: "Sol")]))
    second = select(input_for(requested: requested_route(model: "Terra"), candidates: [candidate(model: "Terra")]))

    assert_equal first.dig("dispatch", "launch_token"), second.dig("dispatch", "launch_token")
  end

  def test_instance_change_requires_stop_and_reconcile_replacement_fencing
    input = input_for
    active = select(input).fetch("active_assignments").first.merge("lifecycle" => "active")
    changed = input_for(candidates: [candidate(instance_id: "remote-2")])
    output = dispatch(changed.merge("active_assignments" => [active]))

    assert_equal "blocked-replacement-fencing", output.fetch("status")
    assert_equal "stop-and-reconcile-prior-instance", output.fetch("required_action")
    assert_equal "remote-2", output.dig("prospective_replacement_assignment", "instance_id")
  end

  def test_dispatcher_change_requires_replacement_even_when_authorized
    input = input_for
    active = select(input).fetch("active_assignments").first.merge("lifecycle" => "active")
    changed = input_for(
      requested: requested_route(dispatcher: "other"),
      candidates: [candidate(dispatcher: "other", instance_id: "other-1")]
    )
    output = dispatch(changed.merge("active_assignments" => [active]))

    assert_equal "blocked-replacement-fencing", output.fetch("status")
  end

  def test_exact_replacement_proof_is_consumed_once
    original_input = input_for
    active = select(original_input).fetch("active_assignments").first.merge("lifecycle" => "active")
    changed = input_for(candidates: [candidate(instance_id: "remote-2")])
    fence = dispatch(changed.merge("active_assignments" => [active]))
    replacement = fence.fetch("prospective_replacement_assignment")
    proof = replacement_proof(active, replacement)
    selected = dispatch(changed.merge("active_assignments" => [active], "replacement" => proof))

    assert_equal "selected", selected.fetch("status")
    assert_equal true, selected.dig("replacement_transition", "consumed")
    assert_equal "active_assignments-and-replacement-proof-consumption",
                 selected.dig("persistence", "record")

    consumed = dispatch(
      changed.merge(
        "active_assignments" => [active],
        "replacement" => proof.merge("consumed" => true)
      )
    )
    assert_equal "blocked-replacement-fencing", consumed.fetch("status")
  end

  def test_replacement_proof_is_bound_to_exact_prior_and_replacement_identity
    original_input = input_for
    active = select(original_input).fetch("active_assignments").first.merge("lifecycle" => "active")
    changed = input_for(candidates: [candidate(instance_id: "remote-2")])
    replacement = dispatch(changed.merge("active_assignments" => [active]))
                  .fetch("prospective_replacement_assignment")
    proof = replacement_proof(active.merge("launch_token" => "dispatch-forged"), replacement)
    output = dispatch(changed.merge("active_assignments" => [active], "replacement" => proof))

    assert_equal "blocked-replacement-fencing", output.fetch("status")
  end

  def test_multiple_or_cross_lane_assignments_are_invalid
    assignment = select(input_for).fetch("active_assignments").first
    multiple = dispatch(input_for.merge("active_assignments" => [assignment, assignment]))
    cross_lane = dispatch(input_for(lane_id: "lane-b").merge("active_assignments" => [assignment]))

    assert_equal "invalid-input", multiple.fetch("status")
    assert_equal "active_assignments must contain at most one well-formed persisted assignment",
                 multiple.fetch("reason")
    assert_equal "invalid-input", cross_lane.fetch("status")
    assert_equal "active_assignments lane_id must match input lane_id", cross_lane.fetch("reason")
  end

  def test_legacy_confirmed_active_lifecycle_is_not_an_activation_path
    assignment = select(input_for).fetch("active_assignments").first.merge("lifecycle" => "confirmed-active")
    output = dispatch(input_for.merge("active_assignments" => [assignment]))

    assert_equal "invalid-input", output.fetch("status")
  end

  def test_missing_or_unknown_instance_identity_blocks_without_dispatch
    missing = input_for(candidates: [candidate.reject { |key, _value| key == "instance_id" }])
    unknown = input_for(candidates: [candidate(instance_id: "UNKNOWN")])

    {
      missing => "instance-identity-missing",
      unknown => "instance-id-unknown"
    }.each do |input, reason|
      output = dispatch(input)
      assert_equal "blocked-user-input", output.fetch("status")
      assert_equal reason, output.dig("rejections", 0, "reason")
      refute output.key?("dispatch")
    end
  end

  def test_input_shapes_fail_with_structured_invalid_input
    cases = {
      "malformed" => dispatch_raw("{"),
      "non-object" => dispatch_raw("[]"),
      "missing lane" => dispatch(input_for.reject { |key, _value| key == "lane_id" }),
      "bad authority" => dispatch(input_for.merge("authority" => { "route" => true })),
      "bad candidates" => dispatch(input_for.merge("candidates" => {})),
      "bad lane state" => dispatch(input_for.merge("lane_state" => []))
    }

    cases.each do |label, output|
      assert_equal "invalid-input", output.fetch("status"), label
      assert output.fetch("reason"), label
    end
  end

  def test_helper_has_no_project_signing_trust_or_hard_route_activation_contract
    source = File.read(HELPER, encoding: "UTF-8")

    refute_includes source, "dispatcher-launch-trust"
    refute_includes source, "workflow-control-lifecycle-trust"
    refute_includes source, "OpenSSL"
    refute_includes source, "launch_confirmation"
    refute_includes source, "hard_route"
    refute_includes source, '"actual_route"'
  end
end
