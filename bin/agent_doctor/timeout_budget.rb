# frozen_string_literal: true

module AgentDoctor
  module TimeoutBudget
    DELIVERY_STATE_HELPER_DEFAULT = 5.0
    WORKFLOW_STATUS_DEFAULT = 7.0
    WORKFLOW_STATUS_MAXIMUM = 12.0
    STACK_COMPONENT_DEFAULT = 18.0
    MAXIMUM = 30.0
    DEEP_COMPONENT_MULTIPLIER = 2.25

    unless DELIVERY_STATE_HELPER_DEFAULT < WORKFLOW_STATUS_DEFAULT &&
           WORKFLOW_STATUS_DEFAULT * 2 < STACK_COMPONENT_DEFAULT && STACK_COMPONENT_DEFAULT <= MAXIMUM &&
           WORKFLOW_STATUS_MAXIMUM * DEEP_COMPONENT_MULTIPLIER <= MAXIMUM
      raise "invalid agent doctor timeout hierarchy"
    end

    module_function

    def workflow_status(environment)
      bounded(environment["AGENT_DOCTOR_WORKFLOW_STATUS_TIMEOUT_SECONDS"], WORKFLOW_STATUS_DEFAULT,
              WORKFLOW_STATUS_MAXIMUM)
    end

    def stack_component(environment)
      configured = bounded(environment["AGENT_DOCTOR_STACK_COMPONENT_TIMEOUT_SECONDS"], STACK_COMPONENT_DEFAULT, MAXIMUM)
      [configured, workflow_status(environment) * DEEP_COMPONENT_MULTIPLIER].max
    end

    def bounded(value, fallback, maximum)
      return fallback if value.to_s.empty?

      seconds = Float(value)
      seconds.positive? ? [seconds, maximum].min : fallback
    rescue ArgumentError, TypeError
      fallback
    end
    private_class_method :bounded
  end
end
