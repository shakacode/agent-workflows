# frozen_string_literal: true

require "json"

pinned_json_schemer_version = ENV["JSON_SCHEMER_VERSION"]
gem "json_schemer", pinned_json_schemer_version if pinned_json_schemer_version
require "json_schemer"

module VerifiedBackport
  SCHEMA_PATH = File.expand_path("../../../docs/schemas/verified-backport-v1.json", __dir__)
  SCHEMA = JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH, encoding: "UTF-8")))
  SHA = /\A[0-9a-f]{40}\z/
  PATCH_ID = /\A[0-9a-f]{40}\z/
  EXACT_MECHANISMS = %w[git-patch-id-stable-v1].freeze
  REQUIRED_SECTIONS = %w[
    source source_evidence target patch target_only_delta reused_evidence
    target_requirements review_generated_changes forward_port_dispositions
  ].freeze
  OBJECT_KEYS = {
    "source" => %w[repository pull_request author head_sha merge_sha trusted_status],
    "source_evidence" => %w[required_coverage reviews checks],
    "required_coverage" => %w[policy_source review_ids check_ids],
    "review_evidence" => %w[id actor head_sha status url],
    "check_evidence" => %w[id name head_sha status url],
    "target" => %w[branch base_sha head_sha],
    "patch" => %w[
      relation mechanism source_patch_id target_patch_id source_head_sha target_base_sha target_head_sha
    ],
    "target_only_delta" => %w[files hunks behavior_change rationale],
    "reused_evidence" => %w[kind source_id head_sha],
    "target_requirements" => %w[
      policy_source branch_protection current_head_ci current_head_review checks
    ],
    "review_generated_change" => %w[id files hunks behavior_change rationale],
    "forward_port_disposition" => %w[change_id status rationale url]
  }.transform_values { |keys| keys.sort.freeze }.freeze

  module_function

  def classify(evidence)
    reasons = classification_reasons(evidence)
    exact = reasons.empty?
    target_requirements = evidence["target_requirements"] if evidence.is_a?(Hash)

    {
      "schema" => "verified-backport-classification-v1",
      "classification" => exact ? "exact" : "ordinary-full",
      "fast_path" => exact,
      "reasons" => reasons,
      "reused_evidence" => exact ? evidence.fetch("reused_evidence") : [],
      "target_requirements" => target_requirements.is_a?(Hash) ? target_requirements : "UNKNOWN",
      "target_gates_waived" => false,
      "forward_port_complete" => forward_port_complete?(evidence)
    }
  end

  def classification_reasons(evidence)
    return ["invalid-contract"] unless contract_shape?(evidence)

    reasons = []
    reasons << "unknown-evidence" if contains_unknown?(evidence)
    source_reasons(evidence, reasons)
    patch_reasons(evidence, reasons)
    reuse_reasons(evidence, reasons)
    target_policy_reasons(evidence, reasons)
    review_change_reasons(evidence, reasons)
    reasons.uniq.sort
  end

  def contract_shape?(evidence)
    evidence.is_a?(Hash) && SCHEMA.valid?(evidence) &&
      exact_keys?(evidence, ["schema", *REQUIRED_SECTIONS]) && evidence["schema"] == "verified-backport-v1" &&
      REQUIRED_SECTIONS.all? { |key| evidence.key?(key) } &&
      %w[source source_evidence target patch target_only_delta target_requirements].all? do |key|
        exact_keys?(evidence[key], OBJECT_KEYS.fetch(key))
      end &&
      %w[reused_evidence review_generated_changes forward_port_dispositions].all? do |key|
        evidence[key].is_a?(Array)
      end && evidence.dig("source_evidence", "reviews").is_a?(Array) &&
      evidence.dig("source_evidence", "checks").is_a?(Array) &&
      exact_keys?(evidence.dig("source_evidence", "required_coverage"),
                  OBJECT_KEYS.fetch("required_coverage")) &&
      evidence.dig("source_evidence", "reviews").all? do |item|
        exact_keys?(item, OBJECT_KEYS.fetch("review_evidence"))
      end &&
      evidence.dig("source_evidence", "checks").all? do |item|
        exact_keys?(item, OBJECT_KEYS.fetch("check_evidence"))
      end &&
      evidence.fetch("reused_evidence").all? do |item|
        exact_keys?(item, OBJECT_KEYS.fetch("reused_evidence"))
      end &&
      evidence.fetch("review_generated_changes").all? do |item|
        exact_keys?(item, OBJECT_KEYS.fetch("review_generated_change"))
      end &&
      evidence.fetch("forward_port_dispositions").all? do |item|
        exact_keys?(item, OBJECT_KEYS.fetch("forward_port_disposition"))
      end
  end

  def exact_keys?(value, keys)
    value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } && value.keys.sort == keys.sort
  end

  def source_reasons(evidence, reasons)
    source = evidence.fetch("source")
    source_evidence = evidence.fetch("source_evidence")
    source_head = source["head_sha"]
    reasons << "source-not-trusted" unless source["trusted_status"] == "merged"
    reasons << "invalid-source-identity" unless valid_source?(source)

    reviews = source_evidence["reviews"]
    checks = source_evidence["checks"]
    unless reviews.is_a?(Array) && !reviews.empty? && checks.is_a?(Array) && !checks.empty?
      reasons << "source-evidence-missing"
      return
    end

    evidence_entries = reviews + checks
    reasons << "stale-source-evidence" unless evidence_entries.all? { |item| item["head_sha"] == source_head }
    successful = reviews.all? { |item| item["status"] == "accepted" } &&
                 checks.all? { |item| item["status"] == "passed" }
    reasons << "source-evidence-not-successful" unless successful

    required = source_evidence["required_coverage"]
    review_ids = reviews.map { |item| item["id"] }
    check_ids = checks.map { |item| item["id"] }
    identities_unique = review_ids.uniq.length == review_ids.length && check_ids.uniq.length == check_ids.length
    reasons << "source-evidence-identity-ambiguous" unless identities_unique

    required_review_ids = required["review_ids"]
    required_check_ids = required["check_ids"]
    coverage_complete = nonempty_string?(required["policy_source"]) &&
                        required_review_ids.is_a?(Array) && !required_review_ids.empty? &&
                        required_check_ids.is_a?(Array) && !required_check_ids.empty? &&
                        (required_review_ids - review_ids).empty? && (required_check_ids - check_ids).empty?
    reasons << "source-required-coverage-incomplete" unless coverage_complete

    required_reviews = reviews.select { |item| Array(required_review_ids).include?(item["id"]) }
    independent = required_reviews.all? do |item|
      nonempty_string?(item["actor"]) && !item["actor"].strip.casecmp?(source["author"].to_s.strip)
    end
    reasons << "source-review-not-independent" unless independent
  end

  def patch_reasons(evidence, reasons)
    patch = evidence.fetch("patch")
    source = evidence.fetch("source")
    target = evidence.fetch("target")
    delta = evidence.fetch("target_only_delta")
    relation = patch["relation"]

    reasons << "patch-relation-#{normalized_reason(relation)}" unless relation == "exact"
    reasons << "unsupported-patch-mechanism" unless EXACT_MECHANISMS.include?(patch["mechanism"])
    unless patch["source_patch_id"].is_a?(String) && patch["source_patch_id"].match?(PATCH_ID) &&
           patch["source_patch_id"] == patch["target_patch_id"]
      reasons << "patch-identity-mismatch"
    end
    unless patch.values_at("source_head_sha", "target_base_sha", "target_head_sha") ==
           [source["head_sha"], target["base_sha"], target["head_sha"]]
      reasons << "stale-patch-evidence"
    end
    unless delta["files"] == [] && delta["hunks"] == [] && delta["behavior_change"] == false &&
           nonempty_string?(delta["rationale"])
      reasons << "target-only-delta-present"
    end
  end

  def reuse_reasons(evidence, reasons)
    source_head = evidence.dig("source", "head_sha")
    reused = evidence.fetch("reused_evidence")
    reasons << "reused-evidence-missing" if reused.empty?
    reasons << "reused-evidence-stale" unless reused.all? { |item| item["head_sha"] == source_head }

    source_ids = {
      "review" => Array(evidence.dig("source_evidence", "reviews")).map { |item| item["id"] },
      "check" => Array(evidence.dig("source_evidence", "checks")).map { |item| item["id"] }
    }
    resolved = reused.all? do |item|
      source_ids.fetch(item["kind"], []).include?(item["source_id"])
    end
    reasons << "reused-evidence-unresolved" unless resolved

    required = evidence.dig("source_evidence", "required_coverage")
    required_reuse = Array(required["review_ids"]).map { |id| ["review", id] } +
                     Array(required["check_ids"]).map { |id| ["check", id] }
    reused_identities = reused.map { |item| [item["kind"], item["source_id"]] }
    reasons << "reused-evidence-incomplete" unless (required_reuse - reused_identities).empty?
  end

  def target_policy_reasons(evidence, reasons)
    target = evidence.fetch("target")
    policy = evidence.fetch("target_requirements")
    reasons << "invalid-target-identity" unless valid_target?(target)
    explicit_policy = nonempty_string?(policy["policy_source"]) &&
                      %w[retain not-configured].include?(policy["branch_protection"]) &&
                      %w[required not-required].include?(policy["current_head_ci"]) &&
                      %w[required not-required].include?(policy["current_head_review"]) &&
                      policy["checks"].is_a?(Array) && policy["checks"].all? { |item| nonempty_string?(item) }
    reasons << "target-policy-missing" unless explicit_policy
    return unless policy["checks"].is_a?(Array)

    ci_policy_consistent = (policy["current_head_ci"] == "required" && !policy["checks"].empty?) ||
                           (policy["current_head_ci"] == "not-required" && policy["checks"].empty?)
    reasons << "contradictory-target-policy" unless ci_policy_consistent
  end

  def review_change_reasons(evidence, reasons)
    behavior_changes = evidence.fetch("review_generated_changes").select do |change|
      change.is_a?(Hash) && change["behavior_change"] == true
    end
    return if behavior_changes.empty?

    reasons << "review-generated-behavior-change"
    reasons << "forward-port-disposition-missing" unless forward_port_complete?(evidence)
  end

  def forward_port_complete?(evidence)
    return false unless contract_shape?(evidence)

    changes = evidence.fetch("review_generated_changes")
    change_ids = changes.filter_map { |change| change["id"] if change.is_a?(Hash) }
    return false unless change_ids.uniq.length == change_ids.length

    behavior_change_ids = changes.filter_map do |change|
      change["id"] if change.is_a?(Hash) && change["behavior_change"] == true
    end

    dispositions = evidence.fetch("forward_port_dispositions")
    behavior_change_ids.all? do |id|
      matches = dispositions.select { |item| item.is_a?(Hash) && item["change_id"] == id }
      matches.length == 1 && %w[applied tracked not-applicable].include?(matches.first["status"]) &&
        nonempty_string?(matches.first["rationale"]) && durable_url?(matches.first["url"])
    end
  end

  def valid_source?(source)
    nonempty_string?(source["repository"]) && source["repository"].match?(%r{\A[^/\s]+/[^/\s]+\z}) &&
      source["pull_request"].is_a?(Integer) && source["pull_request"].positive? &&
      valid_sha?(source["head_sha"]) && valid_sha?(source["merge_sha"])
  end

  def valid_target?(target)
    nonempty_string?(target["branch"]) && valid_sha?(target["base_sha"]) && valid_sha?(target["head_sha"])
  end

  def contains_unknown?(value)
    case value
    when Hash then value.any? { |key, item| contains_unknown?(key) || contains_unknown?(item) }
    when Array then value.any? { |item| contains_unknown?(item) }
    else value == "UNKNOWN"
    end
  end

  def valid_sha?(value)
    value.is_a?(String) && value.match?(SHA)
  end

  def nonempty_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def durable_url?(value)
    value.is_a?(String) && value.match?(%r{\Ahttps://[^\s]+\z})
  end

  def normalized_reason(value)
    value.is_a?(String) && value.match?(/\A[a-z0-9-]+\z/) ? value : "invalid"
  end
end
