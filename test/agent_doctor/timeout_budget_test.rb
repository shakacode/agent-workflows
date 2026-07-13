# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../bin/agent_doctor/timeout_budget"

class AgentDoctorTimeoutBudgetTest < Minitest::Test
  def test_defaults_leave_headroom_for_nested_and_deep_delegates
    budget = AgentDoctor::TimeoutBudget

    assert_operator budget::DELIVERY_STATE_HELPER_DEFAULT, :<, budget::WORKFLOW_STATUS_DEFAULT
    assert_operator budget::WORKFLOW_STATUS_DEFAULT * 2, :<, budget::STACK_COMPONENT_DEFAULT
    assert_operator budget::STACK_COMPONENT_DEFAULT, :<=, budget::MAXIMUM
  end

  def test_injected_budgets_remain_positive_and_bounded
    budget = AgentDoctor::TimeoutBudget

    assert_equal 0.05, budget.workflow_status("AGENT_DOCTOR_WORKFLOW_STATUS_TIMEOUT_SECONDS" => "0.05")
    assert_equal budget::WORKFLOW_STATUS_DEFAULT,
                 budget.workflow_status("AGENT_DOCTOR_WORKFLOW_STATUS_TIMEOUT_SECONDS" => "invalid")
    assert_equal budget::MAXIMUM,
                 budget.stack_component("AGENT_DOCTOR_STACK_COMPONENT_TIMEOUT_SECONDS" => "1000")
    environment = { "AGENT_DOCTOR_WORKFLOW_STATUS_TIMEOUT_SECONDS" => "12",
                    "AGENT_DOCTOR_STACK_COMPONENT_TIMEOUT_SECONDS" => "0.1" }
    assert_operator budget.stack_component(environment), :>, budget.workflow_status(environment) * 2
  end
end
