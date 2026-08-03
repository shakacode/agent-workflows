# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "uri"
require_relative "signed_launch_installation"

module AgentDoctor
  module SignedLaunchWaiverRecord
    REQUIRED_CONSTRAINTS = %w[
      fallback_dispatchers_forbidden generated_keys_forbidden inherited_routing_forbidden
      other_gate_bypass_forbidden preserve_validation_open_dependency scope_expansion_forbidden
      serial_execution synthetic_signatures_forbidden
    ].freeze
    REQUIRED_GATES = [
      "security preflight", "stage dependency gate", "batch plan gate",
      "TDD and focused tests", "bin/validate",
      "independent final-head QA and review", "current-head CI and configured reviewer completion",
      "unresolved review-thread gate", "autonomous merge eligibility", "merge assurance",
      "exact-head merge submission", "completed-batch audit"
    ].freeze
    DURABLE_REF_SCHEMES = %w[
      codex-worker dispatcher-receipt https plan-state workflow-control-state workflow-control-waiver-state
    ].freeze
    MERGE_AUTHORITIES = %w[none ask auto_merge_when_gates_pass].freeze
    RECEIPT_COMPONENT_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/

    module_function

    def read(path, installation_root:)
      return unless absolute_path?(path)

      owner_uid = SignedLaunchInstallation.root_owner_uid(installation_root)
      return unless owner_uid && safe_ancestor_chain?(path, owner_uid)
      return unless File.const_defined?(:NOFOLLOW)

      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        file_stat = file.stat
        next unless file_stat.file? && file_stat.uid == owner_uid && (file_stat.mode & 0o022).zero?

        contents = file.read.force_encoding("UTF-8")
        next unless contents.valid_encoding?

        record = JSON.parse(contents)
        record if record.is_a?(Hash)
      end
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def safe_ancestor_chain?(path, owner_uid)
      directory = File.dirname(path)
      loop do
        stat = File.lstat(directory)
        return false unless stat.directory? && [0, owner_uid].include?(stat.uid) && (stat.mode & 0o022).zero?

        parent = File.dirname(directory)
        return true if parent == directory

        directory = parent
      end
    end
    private_class_method :safe_ancestor_chain?
    def bootstrap?(record)
      expected_keys = %w[
        authorized_dispatcher authorized_exception authorized_lanes authorized_route batch_id constraints
        grant_source granted_at issue not_waived readiness type version waiver_id
      ]
      return false unless record.is_a?(Hash) && record.keys.sort == expected_keys
      return false unless record["type"] == "agent-workflow-bootstrap-waiver" && record["version"] == 1
      return false unless %w[waiver_id batch_id issue authorized_exception].all? { |key| nonempty?(record[key]) }
      return false unless timestamp?(record["granted_at"]) && Time.iso8601(record["granted_at"]) <= Time.now.utc &&
                          direct_human_source?(record["grant_source"])
      return false unless record["authorized_lanes"].is_a?(Array) && !record["authorized_lanes"].empty? &&
                          record["authorized_lanes"].all? { |lane| nonempty?(lane) } &&
                          record["authorized_lanes"].uniq == record["authorized_lanes"]
      return false unless nonempty?(record["authorized_dispatcher"]) && authorized_route?(record["authorized_route"])
      return false unless constraints?(record["constraints"])
      return false unless record["not_waived"].is_a?(Array) &&
                          (REQUIRED_GATES - record["not_waived"]).empty?

      !nested_unknown?(record.except("readiness"))
    end

    def canonical_digest(record)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonicalize(record)))}"
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

    def known_string?(value)
      nonempty?(value) && !value.strip.casecmp?("UNKNOWN")
    end

    def durable_ref?(value)
      return false unless nonempty?(value)

      uri = URI.parse(value)
      return false unless uri.absolute? && DURABLE_REF_SCHEMES.include?(uri.scheme)

      parts = uri.scheme == "https" ? [uri.host] : [uri.opaque, uri.host, uri.path]
      parts.any? { |part| nonempty?(part) && part != "/" }
    rescue URI::InvalidURIError
      false
    end

    def receipt_component?(value)
      value.is_a?(String) && value.match?(RECEIPT_COMPONENT_PATTERN)
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

    def canonicalize(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, canonical| canonical[key] = canonicalize(value[key]) }
      when Array
        value.map { |entry| canonicalize(entry) }
      else
        value
      end
    end
    private_class_method :canonicalize

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
        REQUIRED_CONSTRAINTS.all? { |key| constraints[key] == true } &&
        MERGE_AUTHORITIES.include?(constraints["merge_authority"])
    end
    private_class_method :constraints?

    def nonempty?(value)
      value.is_a?(String) && !value.strip.empty?
    end
    private_class_method :nonempty?
  end
end
