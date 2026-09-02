#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

ROOT = File.expand_path("../../..", __dir__)
COMPONENT_PATH = File.join(ROOT, "workflows/pr-batch-integration-closeout.md")
PRODUCTION_RELEASE_PATH = File.join(ROOT, "workflows/pr-production-release.md")
WORKFLOW_PATH = File.join(ROOT, "workflows/pr-processing.md")
SKILL_PATH = File.join(ROOT, "skills/pr-batch/SKILL.md")
VALIDATE_WORKFLOW_PATH = File.join(ROOT, ".github/workflows/validate.yml")

def route_after(text, heading)
  match = text.match(/^(\#{2,4}) #{Regexp.escape(heading)}[[:blank:]]*$/)
  raise "missing route #{heading}" unless match

  heading_level = match[1].length
  cursor = match.end(0)
  finish = nil
  while (candidate = text.match(/^(\#{2,4})[[:blank:]]+/, cursor))
    if candidate[1].length <= heading_level
      finish = candidate
      break
    end

    cursor = candidate.end(0)
  end

  text[match.end(0)...(finish ? finish.begin(0) : text.length)]
end

class IntegrationCloseoutContractTest < Minitest::Test
  WORKFLOW_ROUTES = [
    "Integration And PR Publication",
    "Batch QA Lane",
    "Hosted Runtime QA Gate",
    "QA Evidence",
    "Human-First PR Description Contract",
    "Batch Handoff Format",
    "Goal Mode Completion Contract",
    "Coordinator Closeout Lane",
    "Local Validation Gate",
    "Review Completion Gate",
    "Merge Readiness Gate",
    "Autonomous Merge Eligibility Gate",
    "Merge Assurance Gate",
    "Exact-Head Merge Submission",
    "Multi-PR Landing Plan",
    "Post-Merge Batch Audit"
  ].freeze

  SKILL_ROUTES = [
    "Integration And PR Publication",
    "Review-Wave And Validation Cohorts",
    "Autonomous Merge Eligibility",
    "Merge Assurance Gate",
    "Batch Handoff Format",
    "Coordinator Closeout Lane"
  ].freeze

  def setup
    @component = File.read(COMPONENT_PATH, encoding: "UTF-8")
    @production_release = File.read(PRODUCTION_RELEASE_PATH, encoding: "UTF-8")
    @workflow = File.read(WORKFLOW_PATH, encoding: "UTF-8")
    @skill = File.read(SKILL_PATH, encoding: "UTF-8")
    @validate_workflow = File.read(VALIDATE_WORKFLOW_PATH, encoding: "UTF-8")
  end

  def test_route_after_keeps_nested_headings_and_stops_at_the_next_peer
    markdown = <<~MARKDOWN
      ## Selected Route

      Parent content.

      ### Nested Route

      Nested content.

      ## Next Route

      Later content.
    MARKDOWN

    route = route_after(markdown, "Selected Route")

    assert_includes route, "### Nested Route"
    assert_includes route, "Nested content."
    refute_includes route, "## Next Route"
    refute_includes route, "Later content."
  end

  def test_component_owns_the_full_closeout_interface
    [
      "Boundary",
      "Input Contract",
      "Output Contract",
      "Integration And PR Publication",
      "Batch QA Lane",
      "Human-First PR Description Contract",
      "Batch Handoff Format",
      "Goal Mode Completion Contract",
      "Review-Wave And Validation Cohorts",
      "Coordinator Closeout Lane",
      "Completed-Batch Audit Receipt And Archive Replay",
      "Local Validation Gate",
      "Review Completion Gate",
      "Merge Readiness Gate",
      "Autonomous Merge Eligibility Gate",
      "Merge Assurance Gate",
      "Exact-Head Merge Submission",
      "Multi-PR Landing Plan",
      "Post-Merge Batch Audit"
    ].each do |heading|
      assert_match(/^\#{2,3} #{Regexp.escape(heading)}$/, @component, heading)
    end

    assert_operator @component.bytesize, :<, 165_000
    assert_operator @workflow.bytesize, :<, 185_000
    assert_operator @skill.bytesize, :<, 60_000
    assert_operator @component.bytesize + @workflow.bytesize + @skill.bytesize, :<, 395_000
    assert_includes @component, "worker-execution-handoff v1"
    assert_includes @component, "one replayable target ledger and human-first handoff"
    assert_includes @component, "current-head closeout gates"
  end

  def test_worker_head_has_one_bounded_integration_and_publication_owner
    section = route_after(@component, "Integration And PR Publication")

    [
      "worker-execution-handoff v1",
      "clean committed implementation head",
      "current base",
      "dependency permission",
      "ordinary in-scope conflicts",
      "Local Validation Gate",
      "Push only the verified owned branch",
      "exactly one draft PR",
      "no-pr-evidence",
      "pr-open` Lane Card"
    ].each { |term| assert_includes section, term }

    assert_operator section.index("Fetch the configured base"), :<,
                    section.index("Local Validation Gate")
    assert_operator section.index("Local Validation Gate"), :<,
                    section.index("Push only the verified owned branch")
    assert_operator section.index("Push only the verified owned branch"), :<,
                    section.index("exactly one draft PR")
  end

  def test_superseded_validation_churn_is_cancelled_and_measured_without_a_gate
    review_wave = route_after(@component, "Review-Wave And Validation Cohorts")
    backpressure = route_after(@component, "Hosted CI Backpressure")
    churn = route_after(@component, "Review Churn Measurement")
    normalized_review_wave = review_wave.gsub(/\s+/, " ")
    normalized_backpressure = backpressure.gsub(/\s+/, " ")
    normalized_churn = churn.gsub(/\s+/, " ")

    assert_includes normalized_review_wave, "whole current-head cohort"
    assert_includes normalized_review_wave, "one consolidated remediation push"
    assert_includes normalized_review_wave, "freeze one candidate"

    assert_includes normalized_backpressure,
                    "classify in-progress hosted validation for older heads as superseded"
    assert_includes normalized_backpressure, "workflow concurrency"
    assert_includes normalized_backpressure, "never cancel a current-head"
    assert_includes normalized_backpressure, "release, security, or forensic evidence"
    assert_includes normalized_backpressure, "does not create a new approval gate"

    assert_includes normalized_churn, "superseded_validation_runs=<count|UNKNOWN>"
    assert_includes normalized_churn, "wasted_runner_minutes=<minutes|UNKNOWN>"
    assert_includes normalized_churn, "directional and informational"

    assert_includes @validate_workflow,
                    "group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.run_id }}"
    assert_includes @validate_workflow,
                    "cancel-in-progress: ${{ github.event_name == 'pull_request' }}"
  end

  def test_retained_processing_contracts_use_existing_compatibility_routes
    assert_equal 2,
                 @component.scan("pr-processing.md#production-and-release-compatibility-route").length
    assert_equal 2,
                 @component.scan("pr-processing.md#accelerated-rc-auto-merge-compatibility-route").length
    assert_includes @component,
                    "[Ordinary Review Fallback](pr-processing.md#ordinary-review-fallback)"
    assert_includes @component,
                    "[Process Gap Disposition](pr-processing.md#process-gap-disposition)"
    refute_includes @component, "pr-processing.md#release-mode-preflight"
    refute_includes @component, "pr-processing.md#accelerated-rc-auto-merge)"
  end

  def test_workflow_is_an_index_and_compatibility_shim
    WORKFLOW_ROUTES.each do |heading|
      route = route_after(@workflow, heading)
      nested_heading = route.match(/^\#{2,4}[[:blank:]]+/)
      direct_route = route[0...(nested_heading ? nested_heading.begin(0) : route.length)]

      assert_includes direct_route, "pr-batch-integration-closeout.md", heading
      assert_includes direct_route, "compatibility route", heading
      assert_operator direct_route.bytesize, :<, 450, heading
      refute_includes direct_route, "priority-finding-dispositions v1", heading
      refute_includes direct_route, "bin/pr-ci-readiness", heading
      refute_includes direct_route, "bin/merge-assurance", heading
    end

    assert_includes @workflow,
                    "[Completed-Batch Audit Receipt And Archive Replay](pr-batch-integration-closeout.md#completed-batch-audit-receipt-and-archive-replay)"
  end

  def test_pr_batch_routes_without_mirroring_closeout
    SKILL_ROUTES.each do |heading|
      route = route_after(@skill, heading)
      assert_includes route, "pr-batch-integration-closeout.md", heading
      assert_includes route, "compatibility route", heading
      assert_operator route.bytesize, :<, 500, heading
      refute_includes route, "priority-finding-dispositions v1", heading
      refute_includes route, "autonomous-merge-risk-decision:v1", heading
      refute_includes route, "completed-batch-publication-preflight", heading
    end
  end

  def test_every_component_route_resolves_to_a_real_heading
    anchors = @component.scan(/^\#{1,6}[[:blank:]]+(.+?)[[:blank:]]*$/).map do |heading|
      heading.first.downcase
             .gsub(/[`*_]/, "")
             .gsub(/[^\p{Alnum}\s-]/, "")
             .strip
             .gsub(/[[:space:]]+/, "-")
    end

    [@workflow, @skill].each do |entrypoint|
      routes = entrypoint.scan(%r{(?:\.\./\.\./workflows/)?pr-batch-integration-closeout\.md#([a-z0-9-]+)})
      refute_empty routes
      routes.flatten.each { |anchor| assert_includes anchors, anchor }
    end
  end

  def test_component_keeps_closeout_helpers_and_fail_closed_states
    %w[
      hosted-qa-readiness
      qa-evidence
      pr-ci-readiness
      autonomous-merge-eligibility
      autonomous-merge-closeout
      merge-assurance
      configured-review-gate
      pr-merge-submit
      completed-batch-publication-preflight
      coordination-declaration
    ].each { |term| assert_includes @component, term }

    assert_includes @component, "unresolved review threads"
    assert_includes @component, "ready-no-merge-authority"
    assert_includes @component, "autonomous-merge-evidence-unknown"
    assert_includes @component, "receipt's reviewed base while binding the current live base"
    assert_includes @component.gsub(/\s+/, " "),
                    "Structured gates reject queues: advisory state cannot stop a queued merge."
    assert_includes @component, "Conversation status: Ready for archiving."
    assert_includes @component, "Conversation status: Follow-ups remain"
  end

  def test_blocked_reconciliation_does_not_invent_a_missing_receipt
    assert_includes @component,
                    "Existing verified receipt only; missing means no line and an Unblock blocker:"
    refute_includes @component, "Before the Unblock Block and final status, emit only:"
  end

  def test_goal_closeout_puts_unblock_immediately_before_non_clean_status
    closeout = route_after(@component, "Coordinator Closeout Lane")

    assert_includes closeout,
                    "Use `Conversation status: Ready for archiving.` iff archive-ready and the union is empty; " \
                    "otherwise put an `Unblock:` block with every normalized blocker immediately before the final " \
                    "`Conversation status: Follow-ups remain — <each exact action or blocker>.` line."
  end

  def test_sibling_components_remain_outside_the_boundary
    refute_match(/^## Release Mode Preflight$/, @component)
    refute_match(/^### Accelerated RC Auto-Merge$/, @component)
    refute_match(/^### Coordination State$/, @component)
    refute_match(/^### Coordination Telemetry And Provenance$/, @component)
    refute_match(/^### Worker Rules$/, @component)

    assert_includes @component, "does not own implementation"
    assert_includes @component, "claims/liveness/telemetry"
    assert_includes @component, "Production and release remain downstream"
    assert_includes @component, "pr-processing.md#coordination-state"
    assert_includes @component, "pr-processing.md#coordination-telemetry-and-provenance"
    assert_includes @component, "pr-processing.md#production-and-release-compatibility-route"
    assert_includes @component, "pr-processing.md#accelerated-rc-auto-merge-compatibility-route"
    refute_includes @component, "agent-coord`-compatible telemetry-completeness"
    refute_includes @component, "Arguments, in order and as separate values: `batch-audit`"
    refute_includes @component, "Refresh stale release-mode classification"
    refute_includes @component, "During accelerated-RC auto-merge"
    refute_includes @component, "append the audit report to the release-gate audit ledger"
    assert_match(/^## Release Audit Ledger Handoff$/, @production_release)
    release_audit_route = route_after(@workflow, "Release Audit Ledger Handoff")
    assert_includes release_audit_route.gsub(/\s+/, " "),
                    "resolved PR Production And Release component"
    assert_includes release_audit_route, "compatibility route"
    assert_operator release_audit_route.bytesize, :<, 450
  end
end
