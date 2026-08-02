# frozen_string_literal: true

require "json"
require "time"
require "uri"

module AgentDoctor
  module SignedLaunchWaiverRecord
    REQUIRED_CONSTRAINTS = %w[
      fallback_dispatchers_forbidden generated_keys_forbidden inherited_routing_forbidden
      other_gate_bypass_forbidden preserve_validation_open_dependency scope_expansion_forbidden
      serial_execution synthetic_signatures_forbidden
    ].freeze
    REQUIRED_GATES = [
      "security preflight",
      "stage dependency gate",
      "batch plan gate",
      "TDD and focused tests",
      "bin/validate",
      "independent final-head QA and review",
      "current-head CI and configured reviewer completion",
      "unresolved review-thread gate",
      "autonomous merge eligibility",
      "merge assurance",
      "exact-head merge submission",
      "completed-batch audit"
    ].freeze

    module_function

    def read(path, helper_path:)
      return unless absolute_path?(path)

      helper_uid = File.stat(helper_path).uid
      parent_stat = File.lstat(File.dirname(path))
      file_stat = File.lstat(path)
      return unless parent_stat.directory? && parent_stat.uid == helper_uid && (parent_stat.mode & 0o022).zero?
      return unless file_stat.file? && file_stat.uid == helper_uid && (file_stat.mode & 0o022).zero?

      record = JSON.parse(File.read(path, encoding: "UTF-8"))
      record if record.is_a?(Hash)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def bootstrap?(record)
      expected_keys = %w[
        authorized_dispatcher authorized_exception authorized_lanes authorized_route batch_id constraints
        grant_source granted_at issue not_waived type version waiver_id
      ]
      return false unless record.is_a?(Hash) && record.keys.sort == expected_keys
      return false unless record["type"] == "agent-workflow-bootstrap-waiver" && record["version"] == 1
      return false unless %w[waiver_id batch_id issue authorized_exception].all? { |key| nonempty?(record[key]) }
      return false unless timestamp?(record["granted_at"]) && direct_human_source?(record["grant_source"])
      return false unless record["authorized_lanes"].is_a?(Array) && !record["authorized_lanes"].empty? &&
                          record["authorized_lanes"].all? { |lane| nonempty?(lane) } &&
                          record["authorized_lanes"].uniq == record["authorized_lanes"]
      return false unless nonempty?(record["authorized_dispatcher"]) && authorized_route?(record["authorized_route"])
      return false unless constraints?(record["constraints"])
      return false unless record["not_waived"].is_a?(Array) &&
                          (REQUIRED_GATES - record["not_waived"]).empty?

      !nested_unknown?(record)
    end

    def authorized_route_matches?(authorized, actual)
      authorized_route?(authorized) && actual.is_a?(Hash) &&
        actual.keys.sort == %w[effort model] && authorized["model"] == actual["model"] &&
        authorized["effort"] == actual["effort"]
    end

    def absolute_path?(value)
      nonempty?(value) && File.absolute_path(value) == value
    rescue ArgumentError
      false
    end

    def durable_ref?(value)
      nonempty?(value) && URI.parse(value).absolute?
    rescue URI::InvalidURIError
      false
    end

    def timestamp?(value)
      return false unless nonempty?(value)

      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end

    def nested_unknown?(value)
      case value
      when Hash
        value.any? { |key, entry| nested_unknown?(key) || nested_unknown?(entry) }
      when Array
        value.any? { |entry| nested_unknown?(entry) }
      else
        value.is_a?(String) && value.strip.casecmp?("UNKNOWN")
      end
    end

    def direct_human_source?(source)
      source.is_a?(Hash) && source.keys.sort == %w[exact_message kind thread_id] &&
        source["kind"] == "direct-in-session-human-user" && nonempty?(source["thread_id"]) &&
        nonempty?(source["exact_message"])
    end
    private_class_method :direct_human_source?

    def authorized_route?(route)
      route.is_a?(Hash) && route.keys.sort == %w[effort fallbacks model] &&
        nonempty?(route["model"]) && nonempty?(route["effort"]) && route["fallbacks"] == []
    end
    private_class_method :authorized_route?

    def constraints?(constraints)
      expected_keys = (REQUIRED_CONSTRAINTS + ["merge_authority"]).sort
      constraints.is_a?(Hash) && constraints.keys.sort == expected_keys &&
        REQUIRED_CONSTRAINTS.all? { |key| constraints[key] == true } && nonempty?(constraints["merge_authority"])
    end
    private_class_method :constraints?

    def nonempty?(value)
      value.is_a?(String) && !value.strip.empty?
    end
    private_class_method :nonempty?
  end
end
