#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
COMPONENT_PATH = File.join(ROOT, "workflows/pr-batch-coordination-observability.md")
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
PAUSE_SKILL_PATH = File.join(ROOT, "skills/pause/SKILL.md")
BACKEND_DOC_PATH = File.join(ROOT, "docs/coordination-backend.md")
ADDRESS_REVIEW_SKILL_PATH = File.join(ROOT, "skills/address-review/SKILL.md")
ADDRESS_REVIEW_WORKFLOW_PATH = File.join(ROOT, "workflows/address-review.md")
VALIDATE_PATH = File.join(ROOT, "bin/validate")

def section(text, heading, next_heading)
  match = text.match(/^#{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing section #{heading}" unless match

  finish = text.match(next_heading, match.end(0))
  text[match.end(0)...(finish ? finish.begin(0) : text.length)]
end

def squish(text)
  text.gsub(/\s+/, " ").strip
end

class CoordinationObservabilityContractTest < Minitest::Test
  def setup
    @component = File.read(COMPONENT_PATH, encoding: "UTF-8")
    @workflow = File.read(WORKFLOW_PATH, encoding: "UTF-8")
    @skill = File.read(SKILL_PATH, encoding: "UTF-8")
    @pause_skill = File.read(PAUSE_SKILL_PATH, encoding: "UTF-8")
    @backend_doc = File.read(BACKEND_DOC_PATH, encoding: "UTF-8")
    @address_review_skill = File.read(ADDRESS_REVIEW_SKILL_PATH, encoding: "UTF-8")
    @address_review_workflow = File.read(ADDRESS_REVIEW_WORKFLOW_PATH, encoding: "UTF-8")
  end

  def test_component_exposes_one_small_optional_adapter
    [
      "Boundary",
      "Adapter Result",
      "Ownership And Liveness",
      "Capacity And Isolation",
      "Status, Monitoring, And Telemetry",
      "Restart, Replacement, And Cancellation",
      "Compatibility And Evidence"
    ].each do |heading|
      assert_match(/^## #{Regexp.escape(heading)}$/, @component, heading)
    end

    assert_includes @component, "coordination-observability v1"
    assert_includes @component, "private | public-fallback | none"
    assert_includes @component, "PR_BATCH_SKILL_DIR"
    assert_includes @component, "${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded"
    assert_includes @component, "${PR_BATCH_SKILL_DIR}/bin/workflow-telemetry-report"
    assert_operator @component.bytesize, :<=, 19_000,
                    "coordination/observability must stay within its extraction budget"
  end

  def test_adapter_never_becomes_an_authority_system
    boundary = squish(section(@component, "## Boundary", /^##\s+/))

    assert_includes boundary, "optional adapter"
    assert_includes boundary, "task mapping, liveness, telemetry, and recovery"
    assert_includes boundary, "cannot grant"
    %w[scope security merge promotion release destructive-action].each do |authority|
      assert_includes boundary, authority
    end
    assert_includes boundary, "Core work remains usable"
  end

  def test_result_is_lane_scoped_and_honest_about_absence
    result = squish(section(@component, "## Adapter Result", /^##\s+/))

    %w[
      canonical_target
      mode
      backend
      capabilities
      ownership
      liveness
      telemetry
      evidence
    ].each { |field| assert_includes result, field }
    assert_includes result, "`coordination_backend: n/a`"
    assert_includes result, "does not call a backend"
    assert_includes result, "literal `UNKNOWN`"
    assert_includes result, "affected lane"
    assert_includes result, "never a fleet-wide fence"
  end

  def test_configured_public_fallback_does_not_require_private_failure
    result = squish(section(@component, "## Adapter Result", /^##\s+/))

    assert_includes result, "`private`: trusted configuration selects a private backend"
    assert_includes result, "`private_state: healthy | claim-only`"
    assert_includes result, "trusted configuration directly selects `public claim-comment fallback`"
    assert_includes result,
                    '"${PR_BATCH_SKILL_DIR}/bin/agent-coord-bounded" --timeout 20 doctor --json'
  end

  def test_reliable_conflict_stops_only_duplicate_execution
    ownership = squish(section(@component, "## Ownership And Liveness", /^##\s+/))

    assert_includes ownership, "Consume the security floor's duplicate-writer result"
    assert_includes ownership, "contradictory reliable live ownership"
    assert_includes ownership, "exact target, branch, and worktree"
    assert_includes ownership, "refuses duplicate execution"
    assert_includes ownership, "does not freeze unrelated"
    assert_includes ownership, "claim timeout"
    assert_includes ownership, "UNKNOWN (claim outcome)"
    assert_includes ownership, "private_state: claim-only"
    assert_includes ownership, "In `mode: private`, run bounded target status before claim"
    assert_includes ownership, "Degraded status with declared `depends_on` refs is a hard stop"
    assert_includes ownership, "For `public-fallback`, after required cross-mode reconciliation"
    assert_includes ownership, "use only the verified public marker flow"
    assert_includes ownership, "For `none`, skip every claim operation"
    assert_includes ownership, "Before dispatching dependency-sensitive lanes"
    assert_includes ownership, "For `mode: private`, create or update private batch and lane state"
    assert_includes ownership, "For `public-fallback` or `none`"
    assert_includes ownership, "coordinator-owned trusted local plan"
    assert_includes ownership, "`depends_on`"
    assert_includes ownership, "selected backend's schema"
    assert_includes ownership, "codex-ready"
    assert_includes ownership, "codex-wip"
    assert_includes ownership, "gh label create"
    assert_includes ownership, "durable takeover receipt"
    assert_includes ownership, "Preserve existing commits"
  end

  def test_capacity_is_separate_from_ownership_and_writer_safety
    capacity = squish(section(@component, "## Capacity And Isolation", /^##\s+/))

    assert_includes capacity, "configurable per-host resource budget"
    assert_includes capacity, "`pr_batch_host_capacity_budget`"
    assert_includes capacity, "explicit current-session operator declaration"
    assert_includes capacity, "repository `AGENTS.md` seam"
    assert_includes capacity, "at most one heavyweight root per host"
    assert_includes capacity, "may lower that to zero, never raise it"
    assert_includes capacity, "fresh normalized-load and healthy-memory evidence"
    assert_includes capacity, "Apply the security floor's branch/worktree isolation result"
    refute_includes capacity, "Keep one writer per branch/worktree"
    assert_includes capacity, "read-only validators and reviewers"
    assert_includes capacity, "isolated committed checkouts"
    assert_includes capacity, "merge, release, deployment, and destructive actions"
    refute_match(/\bM[15]\b/, capacity, "portable component must not hardcode host aliases")
  end

  def test_status_monitoring_and_telemetry_degrade_without_blocking_correctness
    status = squish(section(@component, "## Status, Monitoring, And Telemetry", /^##\s+/))

    assert_includes status, "HST-v1"
    assert_includes status, "no-change"
    assert_includes status, "no user-visible notification"
    assert_includes status, "goal-state-change-monitor"
    assert_includes status, "workflow-telemetry-report"
    assert_includes status, "queue time"
    assert_includes status, "useful-worker time"
    assert_includes status, "human-decision frequency"
    assert_includes status, "memory/load"
    assert_includes status, "retry/review churn"
    assert_includes status, "raw prompts, responses, transcripts, tool results, secrets"
    assert_includes status, "optional telemetry"
  end

  def test_public_fallback_preserves_bounded_identity_and_expiry
    fallback = squish(section(@backend_doc, "## Public Claim Comment Fallback", /^##\s+/))

    assert_match(/^## Batch Coordination Declaration$/, @backend_doc)
    assert_includes fallback, "stable session or thread identifier"
    assert_includes fallback, "distinguishes the active worker instance"
    assert_includes fallback, "`thread: unavailable`"
    assert_includes fallback, "cannot prove self-identity for renewal"
    assert_includes fallback, "packaged fallback intentionally trusts no users, actionable bots, or teams"
    assert_includes fallback, "must configure each claim-authoring human or automation identity"
    assert_includes fallback, "Matching marker fields never bypass author trust"
    assert_includes fallback, "2-4 hours"
    assert_includes fallback, "no later than the known batch window"
    refute_includes fallback, "repository-configured fallback cap"
  end

  def test_untrusted_public_fallback_cannot_veto_mutation
    fallback = squish(section(@backend_doc, "## Public Claim Comment Fallback", /^##\s+/))

    assert_includes fallback, "field-selected GitHub API metadata"
    assert_includes fallback, "`trusted_users`, `trusted_bots`, or `trusted_teams`"
    assert_includes fallback, "A comment body alone never qualifies"
    [fallback, @component, @workflow, @address_review_skill, @address_review_workflow].each do |consumer|
      assert_includes squish(consumer), "authenticated and authorized ownership evidence"
      assert_includes squish(consumer), "proven malformed or unauthorized remains advisory"
      assert_includes squish(consumer), "unavailable or incomplete verification remains `UNKNOWN`"
      assert_includes squish(consumer), "blocks the affected action"
      assert_includes squish(consumer), "concrete author-and-marker verification"
    end
  end

  def test_private_to_public_fallback_reconciles_cross_mode_ownership
    fallback = squish(section(@backend_doc, "## Public Claim Comment Fallback", /^##\s+/))
    result = squish(section(@component, "## Adapter Result", /^##\s+/))

    [fallback, result].each do |consumer|
      assert_includes consumer, "reconcile private ownership or use a trusted cross-mode mirror"
      assert_includes consumer, "If reconciliation is unavailable, stop the affected lane"
    end
  end

  def test_public_fallback_does_not_conflict_with_its_own_renewable_marker
    fallback = squish(section(@backend_doc, "## Public Claim Comment Fallback", /^##\s+/))

    [fallback, squish(@component)].each do |consumer|
      assert_includes consumer, "stable, non-`unavailable` thread"
      assert_includes consumer, "different lane or instance"
      assert_includes consumer, "same comment"
      assert_includes consumer, "cannot be self-renewed"
    end
  end

  def test_restart_replacement_and_cancellation_are_replayable
    recovery = squish(section(@component, "## Restart, Replacement, And Cancellation", /^##\s+/))
    pause_flow = squish(section(@workflow, "### Pausing For An Agent-Runner Restart", /^###\s+/))

    assert_includes recovery, "Bounded Status Recovery"
    assert_includes recovery, "MODEL_REPLACEMENT_HANDOFF"
    assert_includes recovery, "holder/generation/instance"
    assert_includes recovery, "old and replacement instances must not overlap"
    assert_includes recovery, "cooperative drain"
    assert_includes recovery, "human_intervention"
    assert_includes recovery, "kind: drain"
    assert_includes recovery, "release"
    workflow_recovery = squish(@workflow)
    assert_includes workflow_recovery, "stable non-`unavailable` thread"
    assert_includes workflow_recovery, "explicit reassignment"
    complete_refresh_contract = "complete verification shows an authorized author, exactly one well-formed " \
                                "marker on the target's own issue or PR, matching batch, machine, stable " \
                                "non-`unavailable` thread, and branch, `status: in_progress`, a future " \
                                "`expires_at`, and neither conflicting nor `UNKNOWN` ownership evidence"
    assert_equal 2, pause_flow.scan(complete_refresh_contract).length
    assert_includes squish(@pause_skill), complete_refresh_contract
  end

  def test_private_registration_preserves_operational_recovery_context
    evidence = squish(section(@component, "## Compatibility And Evidence", /\z/))

    assert_includes evidence, "When advertised, private registration also preserves"
    %w[objective instructions owners handles].each do |field|
      assert_includes evidence, field
    end
    assert_includes evidence, "dependency mapping"
  end

  def test_workflow_skill_and_public_backend_doc_route_without_mirroring
    route = "pr-batch-coordination-observability.md"
    [@workflow, @skill, @backend_doc].each { |consumer| assert_includes consumer, route }

    workflow_route = squish(section(@workflow, "### Coordination State", /^###\s+/))
    skill_route = squish(section(@skill, "## Coordination State", /^##\s+/))
    assert_operator workflow_route.bytesize, :<, 1_600
    assert_operator skill_route.bytesize, :<, 1_600
    refute_includes workflow_route, "Public claim comment"
    refute_includes skill_route, "Public claim comment"

    isolation_route = @workflow[/^3\. Isolate the work:.*?(?=^4\. Make a local batch:)/m]
    refute_nil isolation_route
    assert_includes isolation_route, route
    assert_operator isolation_route.bytesize, :<, 1_800
    refute_includes isolation_route, "agent-coord-bounded"
    refute_includes isolation_route, "private_state: claim-only"
    refute_includes isolation_route, "Public Claim Comment Fallback"

    telemetry_route = squish(section(@workflow, "### Coordination Telemetry And Provenance", /^###\s+/))
    assert_includes telemetry_route, "#status-monitoring-and-telemetry"
    assert_includes telemetry_route, "#batch-provenance-manifest"
    assert_includes telemetry_route, "#operational-signal-events"
    refute_includes telemetry_route, "It owns exact-pack registration"
  end

  def test_repository_validation_runs_the_component_contract
    validation = File.read(VALIDATE_PATH, encoding: "UTF-8")

    assert_includes validation, "ruby skills/pr-batch/bin/coordination-observability-contract-test.rb"
    assert_includes validation, "ruby skills/pr-batch/bin/coordination-telemetry-contract-test.rb"
    assert_includes validation, "ruby skills/pr-batch/bin/agent-coord-bounded-test.rb"
    assert_includes validation, "ruby skills/pr-batch/bin/stale-assignment-sweep-test.rb"
  end
end
