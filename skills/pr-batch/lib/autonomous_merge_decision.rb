# frozen_string_literal: true

require "time"
require "yaml"
require_relative "../../../bin/agent_doctor/autonomous_merge_policy"

module AutonomousMergeDecision
  MARKER = "<!-- autonomous-merge-risk-decision:v1 -->"
  PAYLOAD_KEYS = %w[
    head_sha
    triggered_gates
    rollback_disposition
    decision
    approved_by
    source
    evidence
  ].freeze
  SOURCES = %w[direct-user-task human-pr-review human-pr-comment].freeze
  PORTABLE_GATE_IDS = %w[
    architectural-product-judgment
    autonomous-merge-policy-change
    changed-files-limit
    changed-lines-limit
    commit-count-limit
    infrastructure-delivery
    irreversible-external-effect
    persistent-data-storage
    public-compatibility
    reviewed-heads-limit
    security-auth-privacy
    total-changed-lines-limit
  ].freeze

  module_function

  def select(comments:, provenance:, head_sha:, triggered_gates:)
    attestations = provenance.each_with_object({}) do |entry, result|
      next unless entry.is_a?(Hash) && entry.key?("comment_id")

      result[entry["comment_id"].to_s] = entry
    end
    candidates = comments.filter_map do |comment|
      payload = parse(comment["body"])
      next unless payload
      next unless valid_payload?(payload, comment:, head_sha:, triggered_gates:)

      attestation = attestations[comment["id"].to_s]
      status = valid_attestation?(attestation, payload) ? "accepted" : "uncertain"
      [Time.iso8601(comment.fetch("created_at")), comment.fetch("id").to_s, comment, payload, status]
    rescue ArgumentError, KeyError
      nil
    end
    selected = candidates.max_by { |created_at, id, _comment, _payload, _status| [created_at, id] }
    return { "status" => "none" } unless selected

    _created_at, _id, comment, payload, status = selected
    result = {
      "status" => status,
      "comment_id" => comment.fetch("id").to_s,
      "url" => comment.fetch("url"),
      "approved_by" => payload.fetch("approved_by"),
      "source" => payload.fetch("source")
    }
    result["reason"] = "matching human and merge-authority attestation is missing or uncertain" if status == "uncertain"
    result
  end

  def parse(body)
    return unless body.is_a?(String)
    return unless body.start_with?("#{MARKER}\n")
    return unless body.scan(MARKER).length == 1
    return if body.include?("\r")

    yaml = body.delete_prefix("#{MARKER}\n")
    return unless yaml.start_with?("---\n")
    return unless yaml.match?(/\n\.\.\.[\t ]*(?:\n[\t ]*)?\z/)

    stream = Psych.parse_stream(yaml)
    return unless stream.children.length == 1
    return unless AutonomousMergePolicy.duplicate_key_errors(yaml).empty?
    return if forbidden_yaml_node?(stream)

    payload = YAML.safe_load(yaml, aliases: false)
    payload if payload.is_a?(Hash) && (payload.keys - PAYLOAD_KEYS).empty? &&
               (PAYLOAD_KEYS - payload.keys).empty?
  rescue Psych::Exception
    nil
  end

  def forbidden_yaml_node?(node)
    return true if node.is_a?(Psych::Nodes::Alias)
    return true if node.respond_to?(:tag) && node.tag &&
                   !%w[tag:yaml.org,2002:str tag:yaml.org,2002:seq tag:yaml.org,2002:map].include?(node.tag)
    return false unless node.respond_to?(:children) && node.children.is_a?(Array)

    node.children.any? { |child| forbidden_yaml_node?(child) }
  end

  def valid_payload?(payload, comment:, head_sha:, triggered_gates:)
    gates = payload["triggered_gates"]
    return false unless payload["head_sha"] == head_sha
    return false unless gates.is_a?(Array) && gates.all? { |gate| canonical_gate?(gate) }
    return false unless gates == gates.uniq.sort && gates == triggered_gates
    return false unless nonempty_string?(payload["rollback_disposition"])
    return false unless payload["decision"] == "approve"
    return false unless nonempty_string?(payload["approved_by"])
    return false unless payload["approved_by"] == comment["author"]
    return false unless SOURCES.include?(payload["source"])

    nonempty_string?(payload["evidence"])
  end

  def valid_attestation?(attestation, payload)
    attestation.is_a?(Hash) &&
      attestation["source"] == payload["source"] &&
      attestation["human_provenance_verified"] == true &&
      attestation["merge_authority_verified"] == true
  end

  def canonical_gate?(gate)
    gate.is_a?(String) &&
      (PORTABLE_GATE_IDS.include?(gate) || gate.match?(/\Arepo-path:[a-z0-9]+(?:-[a-z0-9]+)*\z/))
  end

  def nonempty_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end
end
