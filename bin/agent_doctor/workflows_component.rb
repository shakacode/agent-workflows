# frozen_string_literal: true

require "json"
require_relative "contract"

module AgentDoctor
  class WorkflowsComponent
    STATUS_DEFINITIONS = {
      ["UP_TO_DATE", 0] => ["healthy", "workflow installation matches source"],
      ["UPGRADE_AVAILABLE", 1] => ["degraded", "workflow upgrade available"],
      ["NOT_INSTALLED", 2] => ["failed", "workflow installation is not installed"],
      ["CHECK_FAILED", 3] => ["failed", nil]
    }.freeze
    STATUS_FIELDS = %w[
      status host target source installed_version installed_revision available_version available_revision
      checked_remote reason guidance delivery_mode native flat
    ].freeze
    DETAIL_FIELDS = %w[
      host target source installed_version installed_revision available_version available_revision
      checked_remote delivery_mode native flat
    ].freeze

    def initialize(runner:)
      @runner = runner
    end

    def call(host:, target:, source:, deep:)
      checks = [installation([File.join(target, "bin", "agent-workflows-status"), "--host", host,
                              "--target", target, "--source", source, "--json"], host:, target:, source:)]
      checks << if deep
                  seam([File.join(target, "bin", "agent-workflow-seam-doctor"), "--root", source,
                        "--shared", source, "--json"])
                else
                  Contract.check("workflows.seam", "skipped", "deep workflow checks not run", guidance: "Rerun with `--deep`.")
                end
      Contract.component("agent-workflows", checks)
    end

    private

    def installation(command, host:, target:, source:)
      result = @runner.capture(command)
      if result[:failure]
        return Contract.check("workflows.installation", "failed", result[:failure],
                              guidance: "Reinstall workflows with `agent-stack sync`.")
      end

      payload = JSON.parse(result[:stdout])
      raise JSON::ParserError, "invalid status payload" unless payload.is_a?(Hash)

      definition = validate_status_payload(payload, result[:exit])
      mismatched_fields = identity_mismatches(payload, host:, target:, source:)
      unless mismatched_fields.empty?
        return Contract.check(
          "workflows.installation", "failed", "workflow status identity does not match the requested invocation",
          details: { "mismatched_fields" => mismatched_fields },
          guidance: "Rerun `agent-stack sync` to repair the workflow status helper."
        )
      end
      status, summary = definition
      summary ||= "workflow status check failed: #{payload['reason']}"

      Contract.check("workflows.installation", status,
                     summary,
                     details: status_details(payload, host),
                     guidance: status_guidance(payload))
    rescue JSON::ParserError
      malformed_installation
    end

    def malformed_installation
      Contract.check("workflows.installation", "failed", "workflow status returned malformed JSON or a mismatched status",
                     guidance: "Reinstall workflows with `agent-stack sync`.")
    end

    def validate_status_payload(payload, child_exit)
      raise JSON::ParserError, "invalid status payload" unless (STATUS_FIELDS - payload.keys).empty?

      definition = STATUS_DEFINITIONS[[payload["status"], child_exit]]
      common_valid = definition && payload["host"].is_a?(String) && payload["target"].is_a?(String) &&
                     payload["source"].is_a?(String) && %w[flat plugin-companion].include?(payload["delivery_mode"]) &&
                     [true, false].include?(payload["checked_remote"]) && nullable_string?(payload["guidance"]) &&
                     nullable_hash?(payload["native"]) && nullable_hash?(payload["flat"])
      raise JSON::ParserError, "status/exit mismatch" unless common_valid && status_fields_valid?(payload)

      definition
    end

    def status_fields_valid?(payload)
      nullable_versions = %w[installed_version installed_revision available_version available_revision]
      return false unless nullable_versions.all? { |field| nullable_string?(payload[field]) }

      case payload["status"]
      when "UP_TO_DATE", "UPGRADE_AVAILABLE"
        payload["installed_version"].is_a?(String) && payload["available_version"].is_a?(String) && payload["reason"].nil?
      when "NOT_INSTALLED"
        payload["installed_version"].nil? && payload["installed_revision"].nil? && payload["reason"].nil?
      when "CHECK_FAILED"
        payload["reason"].is_a?(String) && !payload["reason"].empty?
      else
        false
      end
    end

    def identity_mismatches(payload, host:, target:, source:)
      mismatches = []
      host_matches = payload["host"] == host || (host == "auto" && %w[codex claude].include?(payload["host"]))
      mismatches << "host" unless host_matches
      mismatches << "target" unless payload["target"] == target
      mismatches << "source" unless payload["source"] == source
      mismatches
    end

    def status_details(payload, requested_host)
      details = DETAIL_FIELDS.to_h { |field| [field, payload[field]] }
      details["source_status"] = payload["status"]
      details["requested_host"] = requested_host if requested_host != payload["host"]
      details
    end

    def status_guidance(payload)
      return payload["guidance"] if payload["guidance"]
      return "Upgrade workflows with `agent-stack sync`." if payload["status"] == "UPGRADE_AVAILABLE"
      return "Install workflows with `agent-stack sync`." if payload["status"] == "NOT_INSTALLED"
      return "Run `agent-workflows-status --json` directly for the underlying failure." if payload["status"] == "CHECK_FAILED"

      nil
    end

    def nullable_string?(value)
      value.nil? || value.is_a?(String)
    end

    def nullable_hash?(value)
      value.nil? || value.is_a?(Hash)
    end

    def seam(command)
      result = @runner.capture(command)
      if result[:failure]
        return Contract.check("workflows.seam", "failed", result[:failure],
                              guidance: "Run the seam doctor directly for full guidance.")
      end

      payload = JSON.parse(result[:stdout])
      valid = result[:exit]&.zero? && payload.is_a?(Hash) && payload["status"] == "PASS" &&
              payload["issues"].is_a?(Array) && payload["issues"].empty?
      raise JSON::ParserError, "invalid seam payload" unless valid

      Contract.check("workflows.seam", "healthy", "workflow seam contract passes")
    rescue JSON::ParserError
      Contract.check("workflows.seam", "failed", "workflow seam doctor returned malformed JSON or reported issues",
                     guidance: "Run the seam doctor directly for full guidance.")
    end
  end
end
