# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../bin/agent_doctor/ci_readiness_policy"

class CiReadinessPolicyTest < Minitest::Test
  def test_accepts_the_closed_circleci_rule_contract
    policy = valid_policy

    assert_empty CiReadinessPolicy.validation_errors(policy)
    assert_same policy, CiReadinessPolicy.validate!(policy)
  end

  def test_rejects_every_trusted_rule_constraint
    invalid_policies = [
      valid_policy.merge("version" => 2),
      valid_policy.merge("extra" => true),
      valid_policy.merge("optional_approval_held_checks" => []),
      policy_with_rule("id" => "Bad_ID"),
      policy_with_rule("app_slug" => "other-ci"),
      policy_with_rule("name" => "UNKNOWN"),
      policy_with_rule("extra" => true),
      duplicate_policy("id" => "storybook-review-app"),
      duplicate_policy("id" => "second-rule")
    ]

    invalid_policies.each do |policy|
      errors = CiReadinessPolicy.validation_errors(policy)
      refute_empty errors, policy.inspect
      assert_raises(CiReadinessPolicy::Error) { CiReadinessPolicy.validate!(policy) }
    end
  end

  def test_duplicate_key_errors_are_scoped_to_ci_readiness
    yaml = <<~YAML
      other:
        value: 1
        value: 2
      ci_readiness:
        version: 1
        version: 1
    YAML

    assert_equal ["$.ci_readiness contains duplicate key \"version\""],
                 CiReadinessPolicy.duplicate_key_errors(yaml)
  end

  private

  def valid_policy
    {
      "version" => 1,
      "optional_approval_held_checks" => [{
        "id" => "storybook-review-app",
        "app_slug" => "circleci-checks",
        "name" => "storybook-review-app"
      }]
    }
  end

  def policy_with_rule(changes)
    valid_policy.merge(
      "optional_approval_held_checks" => [valid_policy.fetch("optional_approval_held_checks").first.merge(changes)]
    )
  end

  def duplicate_policy(changes)
    valid_policy.merge(
      "optional_approval_held_checks" => [
        valid_policy.fetch("optional_approval_held_checks").first,
        valid_policy.fetch("optional_approval_held_checks").first.merge(changes)
      ]
    )
  end
end
