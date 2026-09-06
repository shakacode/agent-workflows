# frozen_string_literal: true

require_relative "autonomous_merge_policy"

module CiReadinessPolicy
  POLICY_KEY = "ci_readiness"
  POLICY_KEYS = %w[optional_approval_held_checks version].freeze
  RULE_KEYS = %w[app_slug id name].freeze
  RULE_ID_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  CIRCLECI_APP_SLUG = "circleci-checks"

  class Error < StandardError; end

  module_function

  def duplicate_key_errors(yaml)
    AutonomousMergePolicy.duplicate_key_errors(yaml).select do |error|
      error == '$ contains duplicate key "ci_readiness"' ||
        error.start_with?("$.ci_readiness contains duplicate key") ||
        error.start_with?("$.ci_readiness.optional_approval_held_checks contains duplicate key")
    end
  end

  def validation_errors(policy)
    unless closed_string_key_schema?(policy, POLICY_KEYS) && policy["version"] == 1
      return ["ci_readiness must be a closed version 1 mapping"]
    end

    rules = policy["optional_approval_held_checks"]
    unless rules.is_a?(Array) && !rules.empty?
      return ["ci_readiness.optional_approval_held_checks must be a nonempty list"]
    end

    validate_rules(rules)
  end

  def validate!(policy, error_class: Error)
    errors = validation_errors(policy)
    raise error_class, errors.first unless errors.empty?

    policy
  end

  def validate_rules(rules)
    errors = []
    seen_ids = {}
    seen_identities = {}
    rules.each do |rule|
      unless closed_string_key_schema?(rule, RULE_KEYS)
        errors << "each optional approval-held check must contain exactly app_slug, id, and name"
        next
      end

      validate_rule(rule, seen_ids, seen_identities, errors)
    end
    errors.uniq
  end

  def validate_rule(rule, seen_ids, seen_identities, errors)
    rule_id = rule["id"]
    app_slug = rule["app_slug"]
    name = rule["name"]
    unless rule_id.is_a?(String) && rule_id.match?(RULE_ID_PATTERN)
      errors << "optional approval-held check id is invalid"
    end
    errors << "optional approval-held check app_slug is invalid" unless app_slug == CIRCLECI_APP_SLUG
    unless name.is_a?(String) && name == name.strip && !name.empty? &&
           !name.match?(/[[:cntrl:]]/) && name != "UNKNOWN"
      errors << "optional approval-held check name must be resolved single-line text"
    end
    errors << "duplicate optional approval-held check id #{rule_id}" if seen_ids[rule_id]

    identity = [app_slug, name]
    if seen_identities[identity]
      errors << "duplicate optional approval-held check identity #{app_slug}/#{name}"
    end
    seen_ids[rule_id] = true
    seen_identities[identity] = true
  end

  def closed_string_key_schema?(value, expected_keys)
    value.is_a?(Hash) && value.keys.all?(String) &&
      value.keys.length == expected_keys.length && (value.keys - expected_keys).empty?
  end
end
