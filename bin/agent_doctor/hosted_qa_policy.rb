# frozen_string_literal: true

require "yaml"
require_relative "autonomous_merge_policy"

module HostedQaPolicy
  POLICY_KEY = "hosted_qa_gate"
  POLICY_KEYS = %w[
    version change_paths target deployment_verifier acceptance_criteria waiver_mode
  ].freeze
  VERIFIER_PATTERN = %r{\A\.agents/bin/[A-Za-z0-9][A-Za-z0-9_.-]*\z}
  CRITERION_ID_PATTERN = /\A[a-z0-9]+(?:[._-][a-z0-9]+)*\z/
  TARGET_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/

  Result = Struct.new(:state, :policy, :errors, keyword_init: true)

  module_function

  def parse(yaml)
    duplicate_errors = AutonomousMergePolicy.duplicate_key_errors(yaml).select do |error|
      error.include?(POLICY_KEY)
    end
    document = YAML.safe_load(yaml, aliases: false) || {}
    return invalid("policy document must be a mapping", *duplicate_errors) unless document.is_a?(Hash)

    result = parse_value(document[POLICY_KEY], present: document.key?(POLICY_KEY))
    result.errors.concat(duplicate_errors).uniq!
    result.state = :invalid unless result.errors.empty?
    result
  rescue Psych::Exception => e
    invalid("malformed policy YAML: #{e.message.lines.first.to_s.strip}")
  end

  def parse_value(value, present: true)
    return Result.new(state: :absent, policy: nil, errors: []) unless present
    return Result.new(state: :not_applicable, policy: nil, errors: []) if value == "n/a"
    return invalid("must be exactly n/a or a closed version 1 mapping") unless value.is_a?(Hash)

    errors = []
    unknown_keys = value.keys.reject { |key| POLICY_KEYS.include?(key) }
    unknown_keys.each { |key| errors << "contains unknown key #{key.inspect}" }
    missing_keys = POLICY_KEYS.reject { |key| value.key?(key) }
    missing_keys.each { |key| errors << "is missing key #{key.inspect}" }
    errors << "keys must be strings" unless value.keys.all?(String)
    errors << "version must be 1" unless value["version"] == 1

    change_paths, glob_errors = AutonomousMergePolicy.parse_glob_list(
      value["change_paths"],
      "change_paths"
    )
    errors.concat(glob_errors)
    errors << "change_paths must contain at least one pattern" if change_paths.empty?
    errors << "change_paths contains duplicate patterns" if change_paths.uniq.length != change_paths.length

    target = value["target"]
    errors << "target is invalid" unless target.is_a?(String) && target.match?(TARGET_PATTERN)
    verifier = value["deployment_verifier"]
    unless verifier.is_a?(String) && verifier.match?(VERIFIER_PATTERN) && !%w[. ..].include?(File.basename(verifier))
      errors << "deployment_verifier must name one repository-root-relative file under .agents/bin"
    end

    criteria = value["acceptance_criteria"]
    unless criteria.is_a?(Array) && !criteria.empty?
      errors << "acceptance_criteria must be a nonempty list"
      criteria = []
    end
    criteria.each_with_index do |criterion, index|
      unless criterion.is_a?(String) && criterion.match?(CRITERION_ID_PATTERN)
        errors << "acceptance_criteria[#{index}] is invalid"
      end
    end
    errors << "acceptance_criteria contains duplicate IDs" if criteria.uniq.length != criteria.length
    errors << "waiver_mode must be forbidden or maintainer" unless
      %w[forbidden maintainer].include?(value["waiver_mode"])

    policy = {
      "version" => value["version"],
      "change_paths" => change_paths,
      "target" => target,
      "deployment_verifier" => verifier,
      "acceptance_criteria" => criteria,
      "waiver_mode" => value["waiver_mode"]
    }
    Result.new(state: errors.empty? ? :configured : :invalid, policy:, errors: errors.uniq)
  end

  def match?(policy, path)
    policy.fetch("change_paths").any? { |pattern| AutonomousMergePolicy.match?(pattern, path) }
  end

  def invalid(*errors)
    Result.new(state: :invalid, policy: nil, errors: errors.flatten.compact.uniq)
  end
end
