# frozen_string_literal: true

require "time"
require_relative "signed_launch_readiness"
require_relative "signed_launch_waiver_record"

module AgentDoctor
  module SignedLaunchWaiver
    module_function

    def validate_dispatcher(wrapper:, batch_id:, lane_id:, assignment:, host:, target:, helper_path:)
      return [nil, "launch_waiver must be an exact v1 dispatcher waiver"] unless dispatcher_wrapper_shape?(wrapper)

      observation = wrapper.fetch("observation")
      record, reason = validate_bootstrap(
        waiver_ref: wrapper.fetch("waiver_ref"), batch_id:, lane_id:,
        dispatcher: assignment["dispatcher"], route: assignment["route"], host:, target:, helper_path:
      )
      return [nil, "launch_waiver #{reason}"] unless record
      return [nil, "launch_waiver observation is not exactly bound to the active assignment"] unless
        dispatcher_observation_valid?(observation, record:, batch_id:, lane_id:, assignment:)

      [wrapper, nil]
    rescue KeyError, TypeError
      [nil, "launch_waiver must be an exact v1 dispatcher waiver"]
    end

    def validate_bootstrap(waiver_ref:, batch_id:, lane_id:, dispatcher:, route:, host:, target:, helper_path:)
      readiness = SignedLaunchReadiness.inspect(host:, target:)
      return [nil, "requires exact typed unsupported host readiness"] unless readiness["capability"] == "unsupported"

      record = SignedLaunchWaiverRecord.read(waiver_ref, helper_path:)
      return [nil, "reference must name a safe durable human waiver file"] unless SignedLaunchWaiverRecord.bootstrap?(record)
      return [nil, "batch binding does not match"] unless record["batch_id"] == batch_id
      return [nil, "lane binding does not match"] unless record.fetch("authorized_lanes").include?(lane_id)
      return [nil, "dispatcher binding does not match"] unless record["authorized_dispatcher"] == dispatcher
      return [nil, "route binding does not match"] unless
        SignedLaunchWaiverRecord.authorized_route_matches?(record["authorized_route"], route)

      [record, nil]
    rescue KeyError, TypeError
      [nil, "record is malformed"]
    end

    def validate_lifecycle(wrapper:, batch_plan_id:, stage_dependency_plan_id:, lane:, host:, target:, helper_path:)
      return [nil, "lifecycle waiver must be an exact v1 workflow-control waiver"] unless
        lifecycle_wrapper_shape?(wrapper)

      record, reason = validate_bootstrap(
        waiver_ref: wrapper.fetch("waiver_ref"), batch_id: batch_plan_id, lane_id: lane.fetch("id"),
        dispatcher: wrapper.fetch("dispatcher"), route: wrapper.fetch("route"), host:, target:, helper_path:
      )
      return [nil, "lifecycle waiver #{reason}"] unless record
      return [nil, "lifecycle waiver identity does not match the plan"] unless
        wrapper["waiver_id"] == record["waiver_id"] && wrapper["batch_plan_id"] == batch_plan_id &&
        wrapper["stage_dependency_plan_id"] == stage_dependency_plan_id && wrapper["lane_id"] == lane["id"] &&
        wrapper["wave"] == lane["wave"]
      return [nil, "lifecycle waiver chronology is invalid"] unless lifecycle_chronology_valid?(wrapper)
      return [nil, "lifecycle waiver durable references are invalid"] unless
        wrapper["receipt_ref"] == lifecycle_receipt_ref(wrapper) &&
        SignedLaunchWaiverRecord.durable_ref?(wrapper["evidence_ref"])

      [wrapper, nil]
    rescue KeyError, TypeError
      [nil, "lifecycle waiver must be an exact v1 workflow-control waiver"]
    end

    def dispatcher_wrapper_shape?(wrapper)
      wrapper.is_a?(Hash) && wrapper.keys.sort == %w[observation type version waiver_ref] &&
        wrapper["type"] == "dispatcher-launch-waiver" && wrapper["version"] == 1 &&
        SignedLaunchWaiverRecord.absolute_path?(wrapper["waiver_ref"]) && wrapper["observation"].is_a?(Hash) &&
        !SignedLaunchWaiverRecord.nested_unknown?(wrapper)
    end
    private_class_method :dispatcher_wrapper_shape?

    def lifecycle_wrapper_shape?(wrapper)
      expected_keys = %w[
        batch_plan_id completed_at completion_attestation dispatcher evidence_ref lane_id producer receipt_ref
        recorded_at route stage_dependency_plan_id state type version waiver_id waiver_ref wave
      ]
      wrapper.is_a?(Hash) && wrapper.keys.sort == expected_keys &&
        wrapper["type"] == "workflow-control-lane-lifecycle-waiver" && wrapper["version"] == 1 &&
        wrapper["producer"] == "human-waived-pr-batch-workflow-control" &&
        wrapper["state"] == "completed" && wrapper["completion_attestation"] == "coordinator-observed-completed" &&
        SignedLaunchWaiverRecord.absolute_path?(wrapper["waiver_ref"]) &&
        !SignedLaunchWaiverRecord.nested_unknown?(wrapper)
    end
    private_class_method :lifecycle_wrapper_shape?

    def lifecycle_chronology_valid?(wrapper)
      SignedLaunchWaiverRecord.timestamp?(wrapper["completed_at"]) &&
        SignedLaunchWaiverRecord.timestamp?(wrapper["recorded_at"]) &&
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
        observation["type"] == "agent-workflow-waived-host-observation" && observation["version"] == 1 &&
        observation["waiver_id"] == record["waiver_id"] && observation["batch_id"] == batch_id &&
        observation["lane_id"] == lane_id && observation["dispatcher"] == assignment["dispatcher"] &&
        observation["route"] == assignment["route"] && observation["instance_id"] == assignment["instance_id"] &&
        observation["launch_token"] == assignment["launch_token"] &&
        observation["actual_model"] == assignment.dig("route", "model") &&
        observation["actual_effort"] == assignment.dig("route", "effort") &&
        observation["binding_source"] == "dispatcher-bound" && observation["attestation"] == "instance-bound" &&
        SignedLaunchWaiverRecord.timestamp?(observation["observed_at"]) &&
        observation["routing_mode"] == "explicit" && observation["inherited"] == false &&
        SignedLaunchWaiverRecord.durable_ref?(observation["evidence_ref"]) &&
        !SignedLaunchWaiverRecord.nested_unknown?(observation)
    end
    private_class_method :dispatcher_observation_valid?
  end
end
