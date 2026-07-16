# frozen_string_literal: true

require "json"

module AgentDoctor
  module Contract
    CHECK_STATUSES = %w[healthy degraded failed skipped].freeze
    COMPONENT_STATUSES = %w[healthy degraded failed].freeze
    SEVERITY = { "healthy" => 0, "skipped" => 0, "degraded" => 1, "failed" => 2 }.freeze
    EXIT_FOR_STATUS = { "healthy" => 0, "degraded" => 1, "failed" => 2 }.freeze

    module_function

    def check(id, status, summary, details: {}, guidance: nil)
      { "id" => id, "status" => status, "summary" => summary, "details" => details, "guidance" => guidance }
    end

    def status(checks)
      worst = checks.map { |item| item.fetch("status") }.max_by { |value| SEVERITY.fetch(value) }
      worst == "skipped" || worst.nil? ? "healthy" : worst
    end

    def component(component_id, checks)
      { "schema_version" => 1, "component" => component_id, "status" => status(checks), "checks" => checks }
    end

    def unavailable(component_id, summary, status: "failed", guidance: nil)
      guidance ||= "Install or repair the component doctor, then rerun `agent-stack doctor`."
      component(component_id, [check("#{component_id}.doctor", status, summary, guidance: guidance)])
    end

    def normalize(payload, expected_component, child_exit)
      validate_envelope!(payload, expected_component)
      seen = {}
      checks = payload["checks"].map do |item|
        validate_check!(item, seen)
        seen[item["id"]] = true
        check(item["id"], item["status"], item["summary"], details: item["details"], guidance: item["guidance"])
      end
      normalized = component(expected_component, checks)
      raise JSON::ParserError, "component/check status mismatch" unless normalized["status"] == payload["status"]
      raise JSON::ParserError, "component status/exit mismatch" unless EXIT_FOR_STATUS[payload["status"]] == child_exit

      normalized
    end

    def delegate(component_id, command, runner:, unavailable_status: "failed")
      result = runner.capture(command)
      return unavailable(component_id, result[:failure], status: unavailable_status) if result[:failure]
      return unavailable(component_id, "component doctor was unable to run", status: unavailable_status) if result[:exit] == 64

      normalize(JSON.parse(result[:stdout]), component_id, result[:exit])
    rescue JSON::ParserError
      unavailable(component_id, "component doctor returned malformed JSON or violated contract", status: unavailable_status)
    end

    def validate_envelope!(payload, expected_component)
      raise JSON::ParserError, "unsupported component contract" unless payload.is_a?(Hash) && payload["schema_version"] == 1
      raise JSON::ParserError, "component mismatch" unless payload["component"] == expected_component
      raise JSON::ParserError, "invalid component status" unless COMPONENT_STATUSES.include?(payload["status"])
      raise JSON::ParserError, "invalid checks" unless payload["checks"].is_a?(Array) && !payload["checks"].empty?
    end
    private_class_method :validate_envelope!

    def validate_check!(item, seen)
      valid = item.is_a?(Hash) && item["id"].is_a?(String) && !item["id"].empty? &&
              CHECK_STATUSES.include?(item["status"]) && item["summary"].is_a?(String) &&
              item["details"].is_a?(Hash) && (item["guidance"].nil? || item["guidance"].is_a?(String))
      raise JSON::ParserError, "invalid check contract" unless valid && !seen[item["id"]]
    end
    private_class_method :validate_check!
  end
end
