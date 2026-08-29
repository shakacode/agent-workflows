# frozen_string_literal: true

require "yaml"

module AutonomousMergePolicy
  class InvalidGlob < StandardError; end

  PORTABLE_THRESHOLDS = {
    "max_changed_files" => 29,
    "max_changed_lines" => 999,
    "max_commits" => 9,
    "max_reviewed_heads" => 3
  }.freeze
  AUTONOMOUS_KEYS = %w[
    thresholds
    threshold_relaxation
    human_review_paths
    policy_paths
    safe_path_groups
    generated_paths
  ].freeze
  THRESHOLD_RELAXATION_KEYS = %w[rationale].freeze
  HUMAN_REVIEW_PATH_KEYS = %w[id pattern reason detail].freeze
  HUMAN_REVIEW_REASONS = %w[
    migration
    infrastructure
    release
    security
    hot-path
    policy
    other
  ].freeze
  SAFE_PATH_GROUP_KEYS = %w[include exclude].freeze

  Result = Struct.new(
    :thresholds, :human_review_paths, :policy_paths, :safe_path_groups, :generated_paths, :errors,
    keyword_init: true
  )
end

require_relative "autonomous_merge_policy_globs"
require_relative "autonomous_merge_policy_yaml"

module AutonomousMergePolicy
  module_function

  def parse(yaml)
    duplicate_errors = duplicate_key_errors(yaml)
    document = YAML.safe_load(yaml, aliases: false) || {}
    return invalid("policy document must be a mapping", duplicate_errors) unless document.is_a?(Hash)

    mapping = document.fetch("autonomous_merge", {})
    return invalid("autonomous_merge must be a mapping", duplicate_errors) unless mapping.is_a?(Hash)

    errors = duplicate_errors
    errors.concat(unknown_key_errors(mapping, AUTONOMOUS_KEYS, "autonomous_merge"))
    thresholds, threshold_errors = parse_thresholds(mapping["thresholds"])
    errors.concat(threshold_errors)
    errors.concat(threshold_relaxation_errors(mapping["threshold_relaxation"], thresholds))

    human_review_paths, human_path_errors = parse_human_review_paths(mapping["human_review_paths"])
    policy_paths, policy_path_errors = parse_glob_list(mapping["policy_paths"], "autonomous_merge.policy_paths")
    generated_paths, generated_path_errors = parse_glob_list(
      mapping["generated_paths"],
      "autonomous_merge.generated_paths"
    )
    safe_path_groups, safe_path_errors = parse_safe_path_groups(mapping["safe_path_groups"])
    errors.concat(human_path_errors)
    errors.concat(policy_path_errors)
    errors.concat(generated_path_errors)
    errors.concat(safe_path_errors)

    Result.new(
      thresholds:,
      human_review_paths:,
      policy_paths:,
      safe_path_groups:,
      generated_paths:,
      errors: errors.uniq
    )
  rescue Psych::Exception => e
    invalid("malformed trusted-base YAML: #{e.message.lines.first.to_s.strip}")
  end

  def invalid(*errors)
    Result.new(
      thresholds: PORTABLE_THRESHOLDS.dup,
      human_review_paths: [],
      policy_paths: [],
      safe_path_groups: portable_safe_path_groups,
      generated_paths: [],
      errors: errors.flatten.compact
    )
  end

  def parse_thresholds(value)
    return [PORTABLE_THRESHOLDS.dup, []] if value.nil?
    return [PORTABLE_THRESHOLDS.dup, ["autonomous_merge.thresholds must be a mapping"]] unless value.is_a?(Hash)

    errors = unknown_key_errors(value, PORTABLE_THRESHOLDS.keys, "autonomous_merge.thresholds")
    thresholds = PORTABLE_THRESHOLDS.dup
    value.each do |key, entry|
      next unless PORTABLE_THRESHOLDS.key?(key)

      if entry.is_a?(Integer) && entry >= 0
        thresholds[key] = entry
      else
        errors << "autonomous_merge.thresholds.#{key} must be an integer greater than or equal to zero"
      end
    end
    [thresholds, errors]
  end

  def threshold_relaxation_errors(value, thresholds)
    relaxed = PORTABLE_THRESHOLDS.any? { |key, maximum| thresholds[key].is_a?(Integer) && thresholds[key] > maximum }
    return ["threshold_relaxation.rationale is required"] if relaxed && value.nil?
    return [] if value.nil?
    return ["autonomous_merge.threshold_relaxation must be a mapping"] unless value.is_a?(Hash)

    errors = unknown_key_errors(
      value,
      THRESHOLD_RELAXATION_KEYS,
      "autonomous_merge.threshold_relaxation"
    )
    rationale = value["rationale"]
    unless rationale.is_a?(String) && !rationale.strip.empty?
      errors << "autonomous_merge.threshold_relaxation.rationale must be a nonempty string"
    end
    errors
  end

  def parse_human_review_paths(value)
    return [[], []] if value.nil?
    return [[], ["autonomous_merge.human_review_paths must be a list"]] unless value.is_a?(Array)

    errors = []
    ids = {}
    entries = value.filter_map.with_index do |entry, index|
      prefix = "autonomous_merge.human_review_paths[#{index}]"
      unless entry.is_a?(Hash)
        errors << "#{prefix} must be a mapping"
        next
      end

      errors.concat(unknown_key_errors(entry, HUMAN_REVIEW_PATH_KEYS, prefix))
      id = entry["id"]
      pattern = entry["pattern"]
      reason = entry["reason"]
      detail = entry["detail"]
      errors << "#{prefix}.id must be a kebab-case identifier" unless id.is_a?(String) &&
                                                                      id.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      if id.is_a?(String) && ids.key?(id)
        errors << "#{prefix}.id duplicates #{id.inspect}"
      else
        ids[id] = true
      end
      errors.concat(glob_errors(pattern, "#{prefix}.pattern"))
      errors << "#{prefix}.reason is invalid" unless HUMAN_REVIEW_REASONS.include?(reason)
      if reason == "other"
        errors << "#{prefix}.detail must be a nonempty string for reason other" unless nonempty_string?(detail)
      elsif entry.key?("detail")
        errors << "#{prefix}.detail must be omitted unless reason is other"
      end
      entry if id.is_a?(String) && pattern.is_a?(String)
    end
    [entries, errors]
  end

  def nonempty_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def unknown_key_errors(mapping, allowed, prefix)
    mapping.keys.reject { |key| allowed.include?(key) }.map do |key|
      "#{prefix} contains unknown key #{key.inspect}"
    end
  end
end
