# frozen_string_literal: true

require "time"
require "yaml"
require "digest"
require_relative "../../../bin/agent_doctor/autonomous_merge_policy"

module AutonomousMergeDecision
  MARKER = "<!-- autonomous-merge-risk-decision:v1 -->"
  APPROVAL_SUMMARY = "Approved this exact revision for merge after reviewing the listed risk and rollback plan."
  RECEIPT_OPEN = "<details>\n<summary>Approval receipt</summary>\n\n```yaml\n"
  RECEIPT_CLOSE = %r{\n```\n\n</details>[\t \n]*\z}
  YAML_CLOSE = /\n\.\.\.[\t ]*(?:\n[\t ]*)?\z/
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
      status = valid_attestation?(attestation, payload, comment) ? "accepted" : "uncertain"
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

    content = body.delete_prefix("#{MARKER}\n")
    parts = extract_parts(content)
    return unless parts

    yaml, visible = parts
    return unless yaml.start_with?("---\n")
    return unless yaml.match?(YAML_CLOSE)

    stream = Psych.parse_stream(yaml)
    return unless stream.children.length == 1
    return unless AutonomousMergePolicy.duplicate_key_errors(yaml).empty?
    return if forbidden_yaml_node?(stream)

    payload = YAML.safe_load(yaml, aliases: false)
    return unless payload.is_a?(Hash) && (payload.keys - PAYLOAD_KEYS).empty? &&
                  (PAYLOAD_KEYS - payload.keys).empty?

    gates = payload["triggered_gates"]
    return unless gates.is_a?(Array) && gates.all? { |gate| canonical_gate?(gate) }
    return if visible && !valid_visible_summary?(visible, payload)

    payload
  rescue Psych::Exception
    nil
  end

  def extract_parts(content)
    receipt_start = content.index(RECEIPT_OPEN)
    return [content, nil] if receipt_start.nil? && content.start_with?("---\n")
    return unless receipt_start
    return if content.index(RECEIPT_OPEN, receipt_start + RECEIPT_OPEN.length)

    visible = content[0...receipt_start]
    return unless nonempty_string?(visible) && visible.match?(/\n[\t ]*\n\z/)

    receipt_end = content.match(RECEIPT_CLOSE)
    return unless receipt_end

    [content[(receipt_start + RECEIPT_OPEN.length)...receipt_end.begin(0)], visible]
  end

  def valid_visible_summary?(visible, payload)
    lines = visible.lines(chomp: true)
    lines.pop while lines.last&.match?(/\A[\t ]*\z/)
    return false unless lines.length == 7
    return false unless lines[0] == APPROVAL_SUMMARY
    return false unless lines[1].empty?
    return false unless lines[2] == "- Commit: `#{payload.fetch('head_sha')}`"

    risk_line = lines[3]
    risk_items = payload.fetch("triggered_gates").map do |gate|
      label = if gate.start_with?("repo-path:")
                "Repository path: #{gate.delete_prefix('repo-path:').tr('-', ' ')}"
              else
                gate.tr("-", " ").capitalize
              end
      "#{label} (`#{gate}`)"
    end
    return false unless risk_line == "- Risk requiring approval: #{risk_items.join(', ')}"

    return false unless lines[4] == "- Rollback: #{payload.fetch('rollback_disposition')}"
    return false unless lines[5].empty?

    lines[6] == "Ordinary merge checks still apply."
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

  def valid_attestation?(attestation, payload, comment)
    attestation.is_a?(Hash) &&
      attestation["source"] == payload["source"] &&
      attestation["body_sha256"] == Digest::SHA256.hexdigest(comment.fetch("body")) &&
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
