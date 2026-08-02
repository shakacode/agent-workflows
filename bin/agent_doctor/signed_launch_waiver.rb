# frozen_string_literal: true

require "time"
require_relative "signed_launch_readiness"
require_relative "signed_launch_waiver_record"

module AgentDoctor
  module SignedLaunchWaiver
    MAX_OBSERVATION_AGE_SECONDS = 300
    MAX_FUTURE_SKEW_SECONDS = 300

    module_function

    def validate_dispatcher(wrapper:, expected_issue:, batch_id:, lane_id:, assignment:, host:, target:, helper_path:)
      return [nil, "launch_waiver must be an exact v1 dispatcher waiver"] unless dispatcher_wrapper_shape?(wrapper)

      observation = wrapper.fetch("observation")
      record, reason = validate_bootstrap(
        waiver_ref: wrapper.fetch("waiver_ref"), expected_issue:, batch_id:, lane_id:,
        dispatcher: assignment["dispatcher"], route: assignment["route"], host:, target:, helper_path:
      )
      return [nil, "launch_waiver #{reason}"] unless record
      return [nil, "launch_waiver canonical digest does not match the current waiver record"] unless
        wrapper["waiver_digest"] == SignedLaunchWaiverRecord.canonical_digest(record)
      return [nil, "launch_waiver observation is not exactly bound to the active assignment"] unless
        dispatcher_observation_valid?(observation, record:, batch_id:, lane_id:, assignment:)

      [wrapper, nil]
    rescue KeyError, TypeError
      [nil, "launch_waiver must be an exact v1 dispatcher waiver"]
    end

    def validate_bootstrap(waiver_ref:, expected_issue:, batch_id:, lane_id:, dispatcher:, route:, host:, target:,
                           helper_path:)
      readiness = SignedLaunchReadiness.assess(host:, target:)
      return [nil, "requires exact typed unsupported host readiness"] unless readiness["capability"] == "unsupported"

      record = SignedLaunchWaiverRecord.read(waiver_ref, helper_path:)
      return [nil, "reference must name a safe durable human waiver file"] unless SignedLaunchWaiverRecord.bootstrap?(record)
      return [nil, "issue binding does not match"] unless
        SignedLaunchWaiverRecord.known_string?(expected_issue) && record["issue"] == expected_issue
      return [nil, "batch binding does not match"] unless record["batch_id"] == batch_id
      return [nil, "lane binding does not match"] unless record.fetch("authorized_lanes").include?(lane_id)
      return [nil, "dispatcher binding does not match"] unless record["authorized_dispatcher"] == dispatcher
      return [nil, "route binding does not match"] unless
        SignedLaunchWaiverRecord.authorized_route_matches?(record["authorized_route"], route)

      [record, nil]
    rescue KeyError, TypeError
      [nil, "record is malformed"]
    end

    def validate_lifecycle(wrapper:, expected_issue:, batch_plan_id:, stage_dependency_plan_id:, lane:, host:, target:,
                           helper_path:)
      return [nil, "lifecycle waiver must be an exact v1 workflow-control waiver"] unless
        lifecycle_wrapper_shape?(wrapper)

      record, reason = validate_bootstrap(
        waiver_ref: wrapper.fetch("waiver_ref"), expected_issue:, batch_id: batch_plan_id, lane_id: lane.fetch("id"),
        dispatcher: wrapper.fetch("dispatcher"), route: wrapper.fetch("route"), host:, target:, helper_path:
      )
      return [nil, "lifecycle waiver #{reason}"] unless record
      return [nil, "lifecycle waiver canonical digest does not match the current waiver record"] unless
        wrapper["waiver_digest"] == SignedLaunchWaiverRecord.canonical_digest(record)
      return [nil, "lifecycle waiver identity does not match the plan"] unless
        wrapper["waiver_id"] == record["waiver_id"] && wrapper["batch_plan_id"] == batch_plan_id &&
        wrapper["stage_dependency_plan_id"] == stage_dependency_plan_id && wrapper["lane_id"] == lane["id"] &&
        wrapper["wave"] == lane["wave"]
      return [nil, "lifecycle waiver receipt identifiers are ambiguous"] unless
        %w[batch_plan_id stage_dependency_plan_id wave lane_id state].all? do |field|
          SignedLaunchWaiverRecord.receipt_component?(wrapper[field])
        end
      return [nil, "lifecycle waiver chronology is invalid"] unless lifecycle_chronology_valid?(wrapper, record)
      return [nil, "lifecycle waiver durable references are invalid"] unless
        wrapper["receipt_ref"] == lifecycle_receipt_ref(wrapper) &&
        SignedLaunchWaiverRecord.durable_ref?(wrapper["evidence_ref"])

      [wrapper, nil]
    rescue KeyError, TypeError
      [nil, "lifecycle waiver must be an exact v1 workflow-control waiver"]
    end

    def dispatcher_wrapper_shape?(wrapper)
      wrapper.is_a?(Hash) && wrapper.keys.sort == %w[observation type version waiver_digest waiver_ref] &&
        wrapper["type"] == "dispatcher-launch-waiver" && wrapper["version"] == 1 &&
        SignedLaunchWaiverRecord.absolute_path?(wrapper["waiver_ref"]) &&
        wrapper["waiver_digest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/) && wrapper["observation"].is_a?(Hash) &&
        !SignedLaunchWaiverRecord.nested_unknown?(wrapper)
    end
    private_class_method :dispatcher_wrapper_shape?

    def lifecycle_wrapper_shape?(wrapper)
      expected_keys = %w[
        batch_plan_id completed_at completion_attestation dispatcher evidence_ref lane_id producer receipt_ref
        recorded_at route stage_dependency_plan_id state type version waiver_digest waiver_id waiver_ref wave
      ]
      wrapper.is_a?(Hash) && wrapper.keys.sort == expected_keys &&
        wrapper["type"] == "workflow-control-lane-lifecycle-waiver" && wrapper["version"] == 1 &&
        wrapper["producer"] == "human-waived-pr-batch-workflow-control" &&
        wrapper["state"] == "completed" && wrapper["completion_attestation"] == "coordinator-observed-completed" &&
        SignedLaunchWaiverRecord.absolute_path?(wrapper["waiver_ref"]) &&
        wrapper["waiver_digest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/) &&
        !SignedLaunchWaiverRecord.nested_unknown?(wrapper)
    end
    private_class_method :lifecycle_wrapper_shape?

    def lifecycle_chronology_valid?(wrapper, record)
      SignedLaunchWaiverRecord.timestamp?(wrapper["completed_at"]) &&
        SignedLaunchWaiverRecord.timestamp?(wrapper["recorded_at"]) &&
        Time.iso8601(record.fetch("granted_at")) <= Time.iso8601(wrapper["completed_at"]) &&
        Time.iso8601(wrapper["completed_at"]) <= Time.iso8601(wrapper["recorded_at"]) &&
        Time.iso8601(wrapper["recorded_at"]) <= Time.now.utc + 300
    end
    private_class_method :lifecycle_chronology_valid?

    def lifecycle_receipt_ref(wrapper)
      "workflow-control-waiver-state://#{wrapper['batch_plan_id']}/stage-dependency-plans/" \
        "#{wrapper['stage_dependency_plan_id']}/waves/#{wrapper['wave']}/lanes/" \
        "#{wrapper['lane_id']}/#{wrapper['state']}"
    end
    private_class_method :lifecycle_receipt_ref

    def dispatcher_observation_valid?(observation, record:, batch_id:, lane_id:, assignment:)
      expected_keys = %w[
        actual_effort actual_model attestation batch_id binding_source dispatcher evidence_ref inherited
        instance_id lane_id launch_token observed_at route routing_mode type version waiver_id
      ]
      observation.is_a?(Hash) && observation.keys.sort == expected_keys &&
        %w[instance_id launch_token].all? do |field|
          SignedLaunchWaiverRecord.known_string?(assignment[field]) &&
            SignedLaunchWaiverRecord.known_string?(observation[field])
        end &&
        observation["type"] == "agent-workflow-waived-host-observation" && observation["version"] == 1 &&
        observation["waiver_id"] == record["waiver_id"] && observation["batch_id"] == batch_id &&
        observation["lane_id"] == lane_id && observation["dispatcher"] == assignment["dispatcher"] &&
        observation["route"] == assignment["route"] && observation["instance_id"] == assignment["instance_id"] &&
        observation["launch_token"] == assignment["launch_token"] &&
        observation["actual_model"] == assignment.dig("route", "model") &&
        observation["actual_effort"] == assignment.dig("route", "effort") &&
        observation["binding_source"] == "dispatcher-bound" && observation["attestation"] == "instance-bound" &&
        dispatcher_chronology_valid?(observation, record) &&
        observation["routing_mode"] == "explicit" && observation["inherited"] == false &&
        SignedLaunchWaiverRecord.durable_ref?(observation["evidence_ref"]) &&
        !SignedLaunchWaiverRecord.nested_unknown?(observation)
    end
    private_class_method :dispatcher_observation_valid?

    def dispatcher_chronology_valid?(observation, record)
      return false unless SignedLaunchWaiverRecord.timestamp?(observation["observed_at"])

      now = Time.now.utc
      granted_at = Time.iso8601(record.fetch("granted_at"))
      observed_at = Time.iso8601(observation.fetch("observed_at"))
      granted_at <= now && observed_at >= granted_at &&
        observed_at >= now - MAX_OBSERVATION_AGE_SECONDS &&
        observed_at <= now + MAX_FUTURE_SKEW_SECONDS
    end
    private_class_method :dispatcher_chronology_valid?
  end
end
