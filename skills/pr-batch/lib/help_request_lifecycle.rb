# frozen_string_literal: true

require "time"

module HelpRequestLifecycle
  class InputError < StandardError; end

  VERSION = 1
  RESOLUTION_TYPES = {
    "help_request.resolved" => "resolved",
    "help_request.declined" => "declined"
  }.freeze
  PROHIBITED_PERMISSION_PHASES = %w[implementation review].freeze

  module_function

  def evaluate(payload, now:, max_open_seconds:, lane: nil)
    validate_input!(payload, now, max_open_seconds)

    requests = {}
    prohibited_transitions = []
    terminal_events = []

    events = ordered_events(payload.fetch("events"))
    events = events.select { |event| event["lane"] == lane } if lane
    events.each do |event|
      event_id = required_string(event, "event_id")
      raise InputError, "duplicate event_id #{event_id}" if requests.key?(event_id)

      case event["type"]
      when "help_requested"
        requests[event_id] = open_request(event, event_id)
      when *RESOLUTION_TYPES.keys
        apply_resolution!(requests, event, event_id)
      when "phase.changed"
        record_prohibited_transition!(requests, prohibited_transitions, event)
      when "lane_closed"
        terminal_events << event
      end
    end

    request_rows = requests.values.sort_by { |request| [request.fetch("requested_at"), request.fetch("request_id")] }
    request_rows.each { |request| add_age!(request, now) }
    blocking_request = request_rows.find { |request| blocking_permission_request?(request) }
    overdue = blocking_request && blocking_request.fetch("age_seconds") >= max_open_seconds
    terminal_recorded = overdue && terminal_for_request?(terminal_events, blocking_request)

    {
      "contract" => "help-request-lifecycle",
      "version" => VERSION,
      "status" => lifecycle_status(blocking_request, overdue),
      "max_open_seconds" => max_open_seconds,
      "evaluated_at" => now.utc.iso8601,
      "lane" => lane,
      "requests" => request_rows,
      "unresolved_requests" => request_rows.select { |request| request["state"] == "open" },
      "blocking_request_id" => blocking_request&.fetch("request_id", nil),
      "blocking_request" => blocking_request,
      "phase_gate" => phase_gate(blocking_request),
      "prohibited_phase_transitions" => prohibited_transitions,
      "terminal_action" => terminal_action(blocking_request, overdue, terminal_recorded)
    }
  end

  def validate_input!(payload, now, max_open_seconds)
    raise InputError, "input must be a JSON object" unless payload.is_a?(Hash)
    if payload.key?("contract") && payload["contract"] != "help-request-lifecycle-input"
      raise InputError, "unsupported contract #{payload['contract'].inspect}"
    end
    if payload.key?("version") && payload["version"] != VERSION
      raise InputError, "unsupported version #{payload['version'].inspect}"
    end
    raise InputError, "events must be an array" unless payload["events"].is_a?(Array)
    raise InputError, "now must be a Time" unless now.is_a?(Time)
    unless max_open_seconds.is_a?(Integer) && max_open_seconds.positive?
      raise InputError, "max_open_seconds must be a positive integer"
    end
  end

  def ordered_events(events)
    ids = {}
    events.each_with_index.map do |event, index|
      raise InputError, "event #{index} must be an object" unless event.is_a?(Hash)

      event_id = required_string(event, "event_id")
      raise InputError, "duplicate event_id #{event_id}" if ids.key?(event_id)

      ids[event_id] = true
      [event_time(event), index, event]
    end.sort_by { |at, index, _event| [at, index] }.map(&:last)
  end

  def open_request(event, event_id)
    reason = required_string(event, "reason")
    {
      "request_id" => event_id,
      "state" => "open",
      "reason" => reason,
      "requested_at" => event_time(event).utc.iso8601,
      "batch_id" => optional_string(event["batch_id"]),
      "lane" => optional_string(event["lane"]),
      "agent_id" => optional_string(event["agent_id"]),
      "message" => optional_string(event["message"]),
      "scope_key" => request_scope_key(event)
    }
  end

  def apply_resolution!(requests, event, resolution_event_id)
    request_id = required_string(event, "evidence")
    request = requests[request_id]
    raise InputError, "resolution #{resolution_event_id} references unknown request #{request_id}" unless request
    raise InputError, "request #{request_id} already #{request['state']}" unless request["state"] == "open"
    unless request.fetch("scope_key") == request_scope_key(event)
      raise InputError, "resolution #{resolution_event_id} does not match request #{request_id} lane"
    end

    request["state"] = RESOLUTION_TYPES.fetch(event.fetch("type"))
    request["resolution_event_id"] = resolution_event_id
    request["resolved_at"] = event_time(event).utc.iso8601
    request["resolution_message"] = optional_string(event["message"])
  end

  def record_prohibited_transition!(requests, rows, event)
    phase = optional_string(event["phase"] || event["new_phase"])
    return unless PROHIBITED_PERMISSION_PHASES.include?(phase)

    request = requests.values.find do |candidate|
      blocking_permission_request?(candidate) && candidate.fetch("scope_key") == request_scope_key(event)
    end
    return unless request

    rows << {
      "event_id" => required_string(event, "event_id"),
      "at" => event_time(event).utc.iso8601,
      "phase" => phase,
      "request_id" => request.fetch("request_id")
    }
  end

  def add_age!(request, now)
    requested_at = Time.iso8601(request.fetch("requested_at"))
    endpoint = request["resolved_at"] ? Time.iso8601(request.fetch("resolved_at")) : now
    age = (endpoint - requested_at).to_i
    raise InputError, "request #{request['request_id']} has a future timestamp" if age.negative?

    request["age_seconds"] = age
    request.delete("scope_key")
  end

  def blocking_permission_request?(request)
    request["state"] == "open" && request["reason"] == "permission"
  end

  def terminal_for_request?(events, request)
    events.any? do |event|
      normalized_status = event["status"].to_s.downcase.tr("-", "_")
      event["evidence"] == request["request_id"] && normalized_status == "blocked_user_input"
    end
  end

  def lifecycle_status(blocking_request, overdue)
    return "clear" unless blocking_request
    return "blocked-user-input" if overdue

    "blocked"
  end

  def phase_gate(blocking_request)
    return { "allowed" => true, "request_id" => nil } unless blocking_request

    {
      "allowed" => false,
      "request_id" => blocking_request.fetch("request_id"),
      "blocked_phases" => PROHIBITED_PERMISSION_PHASES
    }
  end

  def terminal_action(blocking_request, overdue, recorded)
    return { "required" => false, "recorded" => false } unless overdue

    {
      "required" => !recorded,
      "recorded" => recorded,
      "status" => "blocked-user-input",
      "request_id" => blocking_request.fetch("request_id"),
      "blocker" => blocking_request.fetch("message") || "Unresolved permission request #{blocking_request.fetch('request_id')}"
    }
  end

  def request_scope_key(event)
    batch_id = optional_string(event["batch_id"]) || "UNKNOWN"
    lane = optional_string(event["lane"])
    return [batch_id, "lane", lane] if lane

    target = optional_string(event["target"])
    return [batch_id, "target", target.sub(/\A(?:issue|pr):/, "")] if target

    [batch_id, "unscoped"]
  end

  def event_time(event)
    value = required_string(event, "at")
    Time.iso8601(value)
  rescue ArgumentError
    raise InputError, "invalid event timestamp #{value.inspect}"
  end

  def required_string(object, key)
    value = optional_string(object[key])
    raise InputError, "event missing #{key}" unless value

    value
  end

  def optional_string(value)
    value.is_a?(String) && !value.strip.empty? ? value.strip : nil
  end
end
