#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for pr-ci-readiness.
# Run with: ruby .agents/skills/pr-batch/bin/pr-ci-readiness-test.rb

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

SCRIPT = File.expand_path("pr-ci-readiness", __dir__)
load SCRIPT

class PrCiReadinessTest < Minitest::Test
  # --- Pure verdict logic (module_function), tested directly ---------------

  def circleci_approval_held_row(id: 31, name: "storybook-review-app", summary_status: "Blocked")
    workflow_id = format("00000000-0000-4000-8000-%012d", id)
    workflow_url = "https://app.circleci.com/workflow/#{workflow_id}"
    {
      "kind" => "check_run", "id" => id, "name" => name,
      "status" => "in_progress", "conclusion" => nil,
      "started_at" => "2026-08-24T08:07:48Z", "completed_at" => nil,
      "app_slug" => "circleci-checks", "dependabot" => false, "actions" => nil,
      "details_url" => workflow_url,
      "output" => {
        "title" => "Workflow: #{name}",
        "summary" => "[View CircleCI Workflow](#{workflow_url})\n\n* start - #{summary_status}\n"
      }
    }
  end

  def test_all_passing_is_ready
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [
                                 { "name" => "rspec", "bucket" => "pass" },
                                 { "name" => "examples", "bucket" => "skipping" }
                               ])
    assert_equal "READY", out["verdict"]
    assert_equal true, out["required_used"]
    assert_empty out["failing"]
    assert_empty out["pending"]
  end

  def test_failing_is_not_ready_with_name_surfaced
    out = PrCiReadiness.assess(pr_number: 1, required_used: false, rows: [
                                 { "name" => "rspec", "bucket" => "pass" },
                                 { "name" => "lint", "bucket" => "fail" }
                               ])
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["lint"], out["failing"]
    assert_empty out["pending"]
  end

  def test_pending_is_not_ready
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [
                                 { "name" => "rspec", "bucket" => "pass" },
                                 { "name" => "build", "bucket" => "pending" }
                               ])
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["build"], out["pending"]
  end

  def test_empty_rows_is_unknown
    out = PrCiReadiness.assess(pr_number: 1, required_used: false, rows: [])
    assert_equal "UNKNOWN", out["verdict"]
  end

  def test_cancel_only_is_unknown
    out = PrCiReadiness.assess(pr_number: 1, required_used: false,
                               rows: [{ "name" => "stale", "bucket" => "cancel" }])
    assert_equal "UNKNOWN", out["verdict"]
  end

  def test_same_context_current_pass_supersedes_cancelled_history
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [
                                 { "workflow" => "CI", "name" => "rspec", "bucket" => "pass" },
                                 { "workflow" => "CI", "name" => "rspec", "bucket" => "cancel" }
                               ])
    assert_equal "READY", out["verdict"]
    assert_empty out["failing"]
    assert_empty out["pending"]
  end

  def test_distinct_cancelled_required_context_is_not_ready_with_name_surfaced
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [
                                 { "workflow" => "CI", "name" => "unit", "bucket" => "pass" },
                                 { "workflow" => "Security", "name" => "security", "bucket" => "cancel" }
                               ])

    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["security"], out["pending"]
  end

  def test_same_name_in_different_workflow_does_not_supersede_cancelled_required_context
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [
                                 { "workflow" => "CI", "name" => "unit", "bucket" => "pass" },
                                 { "workflow" => "Security", "name" => "unit", "bucket" => "cancel" }
                               ])

    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["unit"], out["pending"]
  end

  def test_cancel_row_dropped_from_failing_and_pending
    out = PrCiReadiness.assess(pr_number: 1, required_used: false, rows: [
                                 { "name" => "lint", "bucket" => "fail" },
                                 { "name" => "stale", "bucket" => "cancel" }
                               ])
    assert_equal ["lint"], out["failing"]
    assert_equal "NOT_READY", out["verdict"]
  end

  # --- #202 contract 1: unknown/malformed check rows fail closed -----------
  #
  # Reconciled from React on Rails PR #4749's review of the pinned pack: an
  # unrecognized `bucket` value (e.g. a future gh CLI state this script does
  # not yet know about) or a structurally invalid row was silently treated
  # as a pass-equivalent, so a single such row could produce READY on its
  # own. Only the explicitly recognized buckets may contribute to READY now;
  # anything else fails closed to NOT_READY with the offending row named in
  # `invalid` so the result explains why.

  def test_unrecognized_bucket_fails_closed_instead_of_ready
    # Exact reproduction from #202.
    out = PrCiReadiness.assess(
      pr_number: 1, required_used: true,
      rows: [{ "workflow" => "CI", "name" => "mystery", "bucket" => "future-state" }]
    )
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["mystery (bucket: \"future-state\")"], out["invalid"]
    assert_empty out["failing"]
    assert_empty out["pending"]
  end

  def test_missing_bucket_field_fails_closed
    out = PrCiReadiness.assess(pr_number: 1, required_used: true,
                               rows: [{ "workflow" => "CI", "name" => "unit" }])
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["unit (bucket: nil)"], out["invalid"]
  end

  def test_non_string_bucket_fails_closed
    out = PrCiReadiness.assess(pr_number: 1, required_used: true,
                               rows: [{ "workflow" => "CI", "name" => "unit", "bucket" => 1 }])
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["unit (bucket: 1)"], out["invalid"]
  end

  def test_non_object_row_fails_closed
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: ["not-a-row"])
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["row was not an object (String)"], out["invalid"]
  end

  def test_null_row_entry_fails_closed
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [nil])
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["row was not an object (NilClass)"], out["invalid"]
  end

  def test_invalid_row_alongside_otherwise_passing_rows_still_fails_closed
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [
                                 { "workflow" => "CI", "name" => "unit", "bucket" => "pass" },
                                 { "workflow" => "CI", "name" => "mystery", "bucket" => "future-state" }
                               ])
    assert_equal "NOT_READY", out["verdict"]
    assert_equal ["mystery (bucket: \"future-state\")"], out["invalid"]
  end

  def test_all_recognized_buckets_remain_unaffected_by_invalid_row_validation
    out = PrCiReadiness.assess(pr_number: 1, required_used: true, rows: [
                                 { "name" => "rspec", "bucket" => "pass" },
                                 { "name" => "examples", "bucket" => "skipping" }
                               ])
    assert_equal "READY", out["verdict"]
    assert_empty out["invalid"]
  end

  # --- parse helpers --------------------------------------------------------

  def test_usable_checks_discriminates_payloads
    assert PrCiReadiness.usable_checks?('[{"name":"a","bucket":"pass"}]')
    refute PrCiReadiness.usable_checks?("[]")
    refute PrCiReadiness.usable_checks?("")
    refute PrCiReadiness.usable_checks?(nil)
    refute PrCiReadiness.usable_checks?("no required checks") # non-JSON message
    # Cancel-only rows are not usable: they must not short-circuit the fallback.
    refute PrCiReadiness.usable_checks?('[{"name":"stale","bucket":"cancel"}]')
  end

  def test_parse_rows_handles_non_array_json
    assert_equal [], PrCiReadiness.parse_rows('{"oops":true}')
  end

  def test_text_summary_format
    out = PrCiReadiness.assess(pr_number: 9, required_used: true, rows: [
                                 { "name" => "lint", "bucket" => "fail" }
                               ])
    text = PrCiReadiness.text_summary(out)
    assert_includes text, "NOT_READY"
    assert_includes text, "required_used: true"
    assert_includes text, "failing: lint"
    assert_includes text, "pending: (none)"
  end

  def test_text_summary_labels_review_drafts_as_authenticated_viewer_scoped
    text = PrCiReadiness.text_summary(
      "verdict" => "NOT_READY",
      "required_used" => true,
      "failing" => [],
      "pending" => [],
      "viewer_pending_review_drafts" => [{ "id" => "PRR_one" }],
      "viewer_review_inventory" => { "scope" => "authenticated_viewer", "complete" => true }
    )

    assert_includes text, "viewer_pending_review_drafts: PRR_one"
    assert_includes text, "viewer_review_inventory: complete (scope: authenticated_viewer)"
  end

  def test_usage_describes_authenticated_viewer_scope_and_unobservable_drafts
    assert_includes PrCiReadiness::USAGE, "visible to the current authenticated"
    assert_includes PrCiReadiness::USAGE, "Other reviewers'"
    assert_includes PrCiReadiness::USAGE, '"viewer_pending_review_drafts"'
    assert_includes PrCiReadiness::USAGE, '"scope": "authenticated_viewer"'
  end

  def test_versioned_exact_head_scope_contract_has_four_closed_states
    head = "a" * 40
    ready = PrCiReadiness.evidence_scope(
      source: "github.actions.exact_head", head_sha: head, complete: true,
      rows: [{ "name" => "ci", "status" => "completed", "conclusion" => "success" }],
      checked_at: "2026-07-30T12:00:00Z"
    )
    not_ready = PrCiReadiness.evidence_scope(
      source: "github.actions.exact_head", head_sha: head, complete: true,
      rows: [{ "name" => "ci", "status" => "in_progress", "conclusion" => nil }],
      checked_at: "2026-07-30T12:00:00Z"
    )
    not_applicable = PrCiReadiness.evidence_scope(
      source: "github.actions.exact_head", head_sha: head, complete: true, rows: [],
      checked_at: "2026-07-30T12:00:00Z"
    )
    unknown = PrCiReadiness.evidence_scope(
      source: "github.actions.exact_head", head_sha: head, complete: false,
      rows: [], error: "query failed", checked_at: "2026-07-30T12:00:00Z"
    )

    assert_equal "READY", ready.fetch("state")
    assert_equal "NOT_READY", not_ready.fetch("state")
    assert_equal "NOT_APPLICABLE", not_applicable.fetch("state")
    assert_equal "UNKNOWN", unknown.fetch("state")
    assert_equal(
      %w[checked_at complete head_sha rows source state],
      ready.keys.sort
    )
    assert_equal "query failed", unknown.fetch("error")
  end

  def test_exact_head_evidence_contract_fails_closed_for_unknown_or_not_ready_scope
    head = "a" * 40
    scopes = {
      "required_status_check_rollup" => PrCiReadiness.evidence_scope(
        source: "github.pull_request.status_check_rollup.required", head_sha: head,
        complete: true, rows: [{ "name" => "required", "bucket" => "pass" }],
        checked_at: "2026-07-30T12:00:00Z"
      ),
      "github_actions" => PrCiReadiness.evidence_scope(
        source: "github.actions.exact_head", head_sha: head, complete: true, rows: [],
        checked_at: "2026-07-30T12:00:00Z"
      ),
      "dependabot" => PrCiReadiness.evidence_scope(
        source: "github.dependabot.exact_head", head_sha: head, complete: false,
        rows: [], error: "unavailable", checked_at: "2026-07-30T12:00:00Z"
      ),
      "other" => PrCiReadiness.evidence_scope(
        source: "github.checks_and_statuses.exact_head.non_required", head_sha: head,
        complete: true,
        rows: [{ "name" => "external", "state" => "failure" }],
        checked_at: "2026-07-30T12:00:00Z"
      )
    }

    contract = PrCiReadiness.evidence_contract(
      repo: "owner/repo", pr_number: 7,
      base: { "ref" => "main", "sha" => "b" * 40 }, diff_base_sha: "c" * 40, head_sha: head,
      checked_at: "2026-07-30T12:00:00Z", scopes:
    )

    assert_equal "pr-ci-readiness", contract.fetch("contract")
    assert_equal 2, contract.fetch("version")
    assert_equal({ "ref" => "main", "sha" => "b" * 40 }, contract.fetch("base"))
    assert_equal "c" * 40, contract.fetch("diff_base_sha")
    assert_equal DiffIdentity.derive(base_ref: "main", base_sha: "c" * 40, head_sha: head),
                 contract.fetch("diff_identity")
    assert_equal head, contract.fetch("head_sha")
    assert_equal "UNKNOWN", contract.fetch("verdict")
    assert_equal scopes, contract.fetch("scopes")
  end

  def test_exact_head_inventory_partitions_dynamic_actions_dependabot_and_other_rows
    head = "a" * 40
    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [
        { "workflow" => "external-ci", "name" => "required", "bucket" => "pass" },
        { "workflow" => "", "name" => "required-status", "bucket" => "pass" }
      ],
      required_complete: true,
      actions_rows: [
        { "kind" => "run", "id" => 10, "name" => "CI", "status" => "completed",
          "conclusion" => "success", "dependabot" => false },
        { "kind" => "check_run", "id" => 11, "name" => "dynamic-matrix", "status" => "completed",
          "conclusion" => "success", "app_slug" => "github-actions", "dependabot" => false },
        { "kind" => "run", "id" => 12, "name" => "Dependabot Updates", "status" => "completed",
          "conclusion" => "success", "dependabot" => true }
      ],
      actions_complete: true,
      check_runs: [
        { "kind" => "check_run", "id" => 13, "name" => "required", "status" => "completed",
          "conclusion" => "success", "app_slug" => "external-ci", "dependabot" => false },
        { "kind" => "check_run", "id" => 14, "name" => "security", "status" => "completed",
          "conclusion" => "success", "app_slug" => "external-ci", "dependabot" => false }
      ],
      check_runs_complete: true,
      statuses: [
        { "kind" => "status", "id" => 15, "name" => "required-status", "state" => "success" },
        { "kind" => "status", "id" => 16, "name" => "required", "state" => "success" },
        { "kind" => "status", "id" => 17, "name" => "legacy", "state" => "success" }
      ],
      statuses_complete: true
    )

    assert_equal(
      %w[required required-status],
      scopes.dig("required_status_check_rollup", "rows").map { |row| row["name"] }
    )
    assert_equal(
      %w[CI dynamic-matrix],
      scopes.dig("github_actions", "rows").map { |row| row["name"] }.sort
    )
    assert_equal(["Dependabot Updates"], scopes.dig("dependabot", "rows").map { |row| row["name"] })
    assert_equal(
      %w[legacy required required-status security],
      scopes.dig("other", "rows").map { |row| row["name"] }.sort
    )
    assert_equal(%w[READY READY READY READY], scopes.values.map { |scope| scope.fetch("state") })
  end

  def test_required_rollup_filters_other_checks_by_producer_and_context_not_name_alone
    head = "a" * 40
    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [{ "workflow" => "required-ci", "name" => "lint", "bucket" => "pass" }],
      required_complete: true,
      actions_rows: [],
      actions_complete: true,
      check_runs: [
        { "kind" => "check_run", "id" => 21, "name" => "lint", "status" => "completed",
          "conclusion" => "success", "app_slug" => "required-ci", "dependabot" => false },
        { "kind" => "check_run", "id" => 22, "name" => "lint", "status" => "completed",
          "conclusion" => "success", "app_slug" => "external-ci", "dependabot" => false }
      ],
      check_runs_complete: true,
      statuses: [],
      statuses_complete: true
    )

    other_ids = scopes.dig("other", "rows").map { |row| row.fetch("id") }
    assert_equal [22], other_ids
  end

  def test_trusted_policy_keeps_optional_approval_held_rows_but_removes_them_from_blocking_state
    head = "a" * 40
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }
    held = circleci_approval_held_row

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [], required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [held], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal [held], scopes.dig("other", "rows")
    assert_equal "READY", scopes.dig("other", "state")
    assert_equal(
      [
        {
          "disposition" => "optional_approval_held",
          "rule_id" => "circleci-storybook",
          "kind" => "check_run",
          "id" => 31,
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ],
      scopes.dig("other", "policy_dispositions")
    )
  end

  def test_optional_policy_rejects_historical_shaped_running_links_without_terminal_evidence
    head = "a" * 40
    held = circleci_approval_held_row
    workflow_url = held.fetch("details_url")
    held = held.merge(
      "output" => held.fetch("output").merge(
        "summary" => "[View CircleCI Workflow](#{workflow_url})\n\n" \
                     "* setup - Success\n" \
                     "* [start-cypress](#{workflow_url}) - Running\n" \
                     "* [start-plugin](#{workflow_url}) - Running\n" \
                     "* [start-mobile](#{workflow_url}) - Running\n" \
                     "* [start-playwright](#{workflow_url}) - Running\n" \
                     "* build-storybook-review-app - Blocked\n" \
                     "* deploy-storybook-review-app - Blocked\n"
      )
    )
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [], required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [held], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal "NOT_READY", scopes.dig("other", "state")
    assert_empty scopes.dig("other", "policy_dispositions")
  end

  def test_optional_policy_accepts_successful_prerequisites_and_downstream_blocked_phases
    head = "a" * 40
    held = circleci_approval_held_row
    workflow_url = held.fetch("details_url")
    held = held.merge(
      "output" => held.fetch("output").merge(
        "summary" => "[View CircleCI Workflow](#{workflow_url})\n\n" \
                     "* setup - Success\n" \
                     "* build-storybook-review-app - Blocked\n"
      )
    )
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [], required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [held], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal "READY", scopes.dig("other", "state")
    refute_empty scopes.dig("other", "policy_dispositions")
  end

  def test_optional_policy_keeps_an_actively_running_check_blocking
    head = "a" * 40
    running = circleci_approval_held_row(summary_status: "Running")
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [], required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [running], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal "NOT_READY", scopes.dig("other", "state")
    assert_empty scopes.dig("other", "policy_dispositions")
  end

  def test_optional_policy_requires_complete_noncontradictory_circleci_phase_evidence
    head = "a" * 40
    base_row = circleci_approval_held_row
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }

    ambiguous_rows = {
      "missing started_at" => base_row.reject { |key| key == "started_at" },
      "malformed started_at" => base_row.merge("started_at" => "not-a-timestamp"),
      "non-string started_at" => base_row.merge("started_at" => 123),
      "completed timestamp" => base_row.merge("completed_at" => "2026-08-24T08:08:48Z"),
      "check actions" => base_row.merge("actions" => []),
      "missing output" => base_row.reject { |key| key == "output" },
      "mismatched title" => base_row.merge("output" => base_row.fetch("output").merge("title" => "Other")),
      "mixed running summary" => circleci_approval_held_row.merge(
        "output" => circleci_approval_held_row.fetch("output").merge(
          "summary" => "[View CircleCI Workflow](#{base_row.fetch('details_url')})\n\n" \
                       "* start - Blocked\n* build-hold-artifacts - Running\n"
        )
      ),
      "plain approval-like running job" => circleci_approval_held_row.merge(
        "output" => circleci_approval_held_row.fetch("output").merge(
          "summary" => "[View CircleCI Workflow](#{base_row.fetch('details_url')})\n\n" \
                       "* approval-tests - Running\n* build - Blocked\n"
        )
      ),
      "job URL with approval-like label" => circleci_approval_held_row.merge(
        "output" => circleci_approval_held_row.fetch("output").merge(
          "summary" => "[View CircleCI Workflow](#{base_row.fetch('details_url')})\n\n" \
                       "* [approval-tests](https://app.circleci.com/job/123) - Running\n" \
                       "* build - Blocked\n"
        )
      ),
      "different workflow UUID with approval-like label" => circleci_approval_held_row.merge(
        "output" => circleci_approval_held_row.fetch("output").merge(
          "summary" => "[View CircleCI Workflow](#{base_row.fetch('details_url')})\n\n" \
                       "* [approval-tests](https://app.circleci.com/workflow/" \
                       "00000000-0000-4000-8000-000000000099) - Running\n" \
                       "* build - Blocked\n"
        )
      ),
      "failed prerequisite with approval hold" => circleci_approval_held_row.merge(
        "output" => circleci_approval_held_row.fetch("output").merge(
          "summary" => "[View CircleCI Workflow](#{base_row.fetch('details_url')})\n\n" \
                       "* setup - Failed\n* hold - Running\n* build - Blocked\n"
        )
      ),
      "non-CircleCI details URL" => base_row.merge("details_url" => "https://example.test/workflow/31"),
      "ordinary queued phase" => base_row.merge("status" => "queued", "started_at" => nil)
    }

    ambiguous_rows.each do |label, row|
      scopes = PrCiReadiness.inventory_scopes(
        head_sha: head,
        checked_at: "2026-07-30T12:00:00Z",
        required_rows: [], required_complete: true,
        actions_rows: [], actions_complete: true,
        check_runs: [row], check_runs_complete: true,
        statuses: [], statuses_complete: true,
        optional_approval_held_policy: policy
      )

      assert_equal "NOT_READY", scopes.dig("other", "state"), label
      assert_empty scopes.dig("other", "policy_dispositions"), label
    end
  end

  def test_optional_policy_does_not_apply_circleci_phase_evidence_to_another_provider
    row = circleci_approval_held_row.merge("app_slug" => "other-ci")
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        { "id" => "other-storybook", "app_slug" => "other-ci", "name" => "storybook-review-app" }
      ]
    }

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: "a" * 40, checked_at: "2026-07-30T12:00:00Z",
      required_rows: [], required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [row], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal "NOT_READY", scopes.dig("other", "state")
    assert_empty scopes.dig("other", "policy_dispositions")
  end

  def test_optional_policy_does_not_disposition_duplicate_conflicting_check_run_identity
    head = "a" * 40
    held = {
      "kind" => "check_run", "id" => 31, "name" => "storybook-review-app",
      "status" => "in_progress", "conclusion" => nil,
      "app_slug" => "circleci-checks", "dependabot" => false
    }
    failed = held.merge("status" => "completed", "conclusion" => "failure")
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [], required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [held, failed], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal "NOT_READY", scopes.dig("other", "state")
    assert_empty scopes.dig("other", "policy_dispositions")
    assert_equal [held, failed], scopes.dig("other", "rows")
  end

  def test_optional_policy_does_not_disposition_duplicate_provider_identity_with_distinct_ids
    head = "a" * 40
    held = {
      "kind" => "check_run", "id" => 31, "suite_id" => 10, "name" => "storybook-review-app",
      "status" => "in_progress", "conclusion" => nil, "started_at" => nil,
      "app_slug" => "circleci-checks", "dependabot" => false
    }
    replacement = held.merge("id" => 32, "suite_id" => 20)
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [], required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [held, replacement], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal "NOT_READY", scopes.dig("other", "state")
    assert_empty scopes.dig("other", "policy_dispositions")
    assert_equal [held, replacement], scopes.dig("other", "rows")
  end

  def test_optional_policy_indexes_check_run_identity_once_per_row
    rows = Array.new(100) do |index|
      circleci_approval_held_row(id: index + 1, name: "check-#{index}")
    end
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => rows.map do |row|
        {
          "id" => "rule-#{row.fetch('id')}",
          "app_slug" => row.fetch("app_slug"),
          "name" => row.fetch("name")
        }
      end
    }
    original = PrCiReadiness.method(:check_run_identity)
    identity_calls = 0
    PrCiReadiness.define_singleton_method(:check_run_identity) do |row|
      identity_calls += 1
      original.call(row)
    end

    dispositions = PrCiReadiness.optional_approval_held_dispositions(
      rows, required_rows: [], policy:
    )

    assert_equal rows.length, dispositions.length
    assert_operator identity_calls, :<=, rows.length * 2
  ensure
    PrCiReadiness.define_singleton_method(:check_run_identity, original) if original
  end

  def test_required_reclassification_prevents_optional_approval_held_disposition
    head = "a" * 40
    held = {
      "kind" => "check_run", "id" => 32, "name" => "storybook-review-app",
      "status" => "in_progress", "conclusion" => nil,
      "app_slug" => "circleci-checks", "dependabot" => false
    }
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        {
          "id" => "circleci-storybook",
          "app_slug" => "circleci-checks",
          "name" => "storybook-review-app"
        }
      ]
    }

    scopes = PrCiReadiness.inventory_scopes(
      head_sha: head,
      checked_at: "2026-07-30T12:00:00Z",
      required_rows: [
        { "workflow" => "circleci-checks", "name" => "storybook-review-app", "bucket" => "pending" }
      ],
      required_complete: true,
      actions_rows: [], actions_complete: true,
      check_runs: [held], check_runs_complete: true,
      statuses: [], statuses_complete: true,
      optional_approval_held_policy: policy
    )

    assert_equal "NOT_READY", scopes.dig("required_status_check_rollup", "state")
    assert_equal "NOT_APPLICABLE", scopes.dig("other", "state")
    assert_empty scopes.dig("other", "policy_dispositions")
  end

  def test_required_third_party_row_remains_required_across_workflow_shapes
    head = "a" * 40
    held = {
      "kind" => "check_run", "id" => 32, "name" => "storybook-review-app",
      "status" => "in_progress", "conclusion" => nil, "started_at" => nil,
      "app_slug" => "circleci-checks", "dependabot" => false
    }
    policy = {
      "version" => 1,
      "optional_approval_held_checks" => [
        { "id" => "circleci-storybook", "app_slug" => "circleci-checks", "name" => "storybook-review-app" }
      ]
    }

    ["", "future-third-party-workflow-shape"].each do |workflow|
      scopes = PrCiReadiness.inventory_scopes(
        head_sha: head, checked_at: "2026-07-30T12:00:00Z",
        required_rows: [{ "workflow" => workflow, "name" => "storybook-review-app", "bucket" => "pending" }],
        required_complete: true, actions_rows: [], actions_complete: true,
        check_runs: [held], check_runs_complete: true,
        statuses: [], statuses_complete: true,
        optional_approval_held_policy: policy
      )

      assert_equal "NOT_READY", scopes.dig("required_status_check_rollup", "state"), workflow
      assert_equal "NOT_READY", scopes.dig("other", "state"), workflow
      assert_empty scopes.dig("other", "policy_dispositions"), workflow
    end
  end

  def test_trusted_ci_policy_is_loaded_from_the_exact_base_commit_not_worktree_bytes
    Dir.mktmpdir("pr-ci-policy") do |root|
      run_fixture_git(root, "init", "-q")
      run_fixture_git(root, "config", "user.name", "Test User")
      run_fixture_git(root, "config", "user.email", "test@example.test")
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(
        File.join(root, ".agents", "agent-workflow.yml"),
        {
          "ci_readiness" => {
            "version" => 1,
            "optional_approval_held_checks" => [
              {
                "id" => "circleci-storybook",
                "app_slug" => "circleci-checks",
                "name" => "storybook-review-app"
              }
            ]
          }
        }.to_yaml
      )
      run_fixture_git(root, "add", ".agents/agent-workflow.yml")
      run_fixture_git(root, "commit", "-q", "-m", "policy")
      base_sha = run_fixture_git(root, "rev-parse", "HEAD").strip
      File.write(File.join(root, ".agents", "agent-workflow.yml"), "ci_readiness: UNKNOWN\n")

      policy = PrCiReadiness.trusted_ci_policy_at(
        repo_root: root, base_ref: "main", base_sha:
      )

      assert_equal base_sha, policy.dig("base", "sha")
      assert_equal "storybook-review-app", policy.dig("optional_approval_held_checks", 0, "name")
      assert_match(
        %r{\Agit:#{base_sha}:\.agents/agent-workflow\.yml@[0-9a-f]{40}\z},
        policy.fetch("provenance")
      )
    end
  end

  def test_trusted_ci_policy_rejects_duplicate_ci_readiness_keys
    fixtures = {
      root: <<~YAML,
        ci_readiness:
          version: 1
          optional_approval_held_checks: []
        ci_readiness:
          version: 1
          optional_approval_held_checks: []
      YAML
      version: <<~YAML,
        ci_readiness:
          version: 1
          version: 1
          optional_approval_held_checks: []
      YAML
      rule: <<~YAML
        ci_readiness:
          version: 1
          optional_approval_held_checks:
            - id: circleci-storybook
              app_slug: circleci-checks
              app_slug: circleci-checks
              name: storybook-review-app
      YAML
    }

    fixtures.each do |label, yaml|
      Dir.mktmpdir("pr-ci-policy-duplicate") do |root|
        run_fixture_git(root, "init", "-q")
        run_fixture_git(root, "config", "user.name", "Test User")
        run_fixture_git(root, "config", "user.email", "test@example.test")
        FileUtils.mkdir_p(File.join(root, ".agents"))
        File.write(File.join(root, ".agents", "agent-workflow.yml"), yaml)
        run_fixture_git(root, "add", ".agents/agent-workflow.yml")
        run_fixture_git(root, "commit", "-q", "-m", "duplicate policy")
        base_sha = run_fixture_git(root, "rev-parse", "HEAD").strip

        error = assert_raises(PrCiReadiness::Error) do
          PrCiReadiness.trusted_ci_policy_at(repo_root: root, base_ref: "main", base_sha:)
        end

        assert_includes error.message, "duplicate key", label
      end
    end
  end

  def test_trusted_ci_policy_ignores_repository_replacement_refs
    Dir.mktmpdir("pr-ci-policy-replace") do |root|
      run_fixture_git(root, "init", "-q")
      run_fixture_git(root, "config", "user.name", "Test User")
      run_fixture_git(root, "config", "user.email", "test@example.test")
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(
        File.join(root, ".agents", "agent-workflow.yml"),
        optional_policy_yaml("trusted-check")
      )
      run_fixture_git(root, "add", ".agents/agent-workflow.yml")
      run_fixture_git(root, "commit", "-q", "-m", "trusted policy")
      base_sha = run_fixture_git(root, "rev-parse", "HEAD").strip
      trusted_blob_sha = run_fixture_git(
        root, "rev-parse", "#{base_sha}:.agents/agent-workflow.yml"
      ).strip

      File.write(
        File.join(root, ".agents", "agent-workflow.yml"),
        optional_policy_yaml("forged-check")
      )
      run_fixture_git(root, "add", ".agents/agent-workflow.yml")
      run_fixture_git(root, "commit", "-q", "-m", "forged policy")
      forged_sha = run_fixture_git(root, "rev-parse", "HEAD").strip
      forged_blob_sha = run_fixture_git(
        root, "rev-parse", "#{forged_sha}:.agents/agent-workflow.yml"
      ).strip
      run_fixture_git(root, "replace", base_sha, forged_sha)

      policy = PrCiReadiness.trusted_ci_policy_at(
        repo_root: root, base_ref: "main", base_sha:
      )

      assert_equal "trusted-check", policy.dig("optional_approval_held_checks", 0, "name")
      assert_equal(
        "git:#{base_sha}:.agents/agent-workflow.yml@#{trusted_blob_sha}",
        policy.fetch("provenance")
      )
      refute_includes policy.fetch("provenance"), forged_blob_sha
    end
  end

  def test_trusted_ci_policy_does_not_inherit_git_dir
    Dir.mktmpdir("pr-ci-policy-root") do |root|
      Dir.mktmpdir("pr-ci-policy-attacker") do |attacker|
        [root, attacker].each do |repo|
          run_fixture_git(repo, "init", "-q")
          run_fixture_git(repo, "config", "user.name", "Test User")
          run_fixture_git(repo, "config", "user.email", "test@example.test")
          FileUtils.mkdir_p(File.join(repo, ".agents"))
        end
        File.write(File.join(root, ".agents", "agent-workflow.yml"), optional_policy_yaml("trusted-check"))
        run_fixture_git(root, "add", ".agents/agent-workflow.yml")
        run_fixture_git(root, "commit", "-q", "-m", "trusted policy")
        File.write(File.join(attacker, ".agents", "agent-workflow.yml"), optional_policy_yaml("forged-check"))
        run_fixture_git(attacker, "add", ".agents/agent-workflow.yml")
        run_fixture_git(attacker, "commit", "-q", "-m", "forged policy")
        attacker_sha = run_fixture_git(attacker, "rev-parse", "HEAD").strip

        original_git_dir = ENV["GIT_DIR"]
        ENV["GIT_DIR"] = File.join(attacker, ".git")
        error = assert_raises(PrCiReadiness::Error) do
          PrCiReadiness.trusted_ci_policy_at(
            repo_root: root, base_ref: "main", base_sha: attacker_sha
          )
        end
        assert_match(/does not resolve the exact base SHA/, error.message)
      ensure
        original_git_dir.nil? ? ENV.delete("GIT_DIR") : ENV["GIT_DIR"] = original_git_dir
      end
    end
  end

  def test_unknown_trusted_base_ci_policy_fails_closed
    Dir.mktmpdir("pr-ci-policy-unknown") do |root|
      run_fixture_git(root, "init", "-q")
      run_fixture_git(root, "config", "user.name", "Test User")
      run_fixture_git(root, "config", "user.email", "test@example.test")
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, ".agents", "agent-workflow.yml"), "ci_readiness: UNKNOWN\n")
      run_fixture_git(root, "add", ".agents/agent-workflow.yml")
      run_fixture_git(root, "commit", "-q", "-m", "unknown policy")
      base_sha = run_fixture_git(root, "rev-parse", "HEAD").strip

      error = assert_raises(PrCiReadiness::Error) do
        PrCiReadiness.trusted_ci_policy_at(repo_root: root, base_ref: "main", base_sha:)
      end

      assert_match(/closed version 1 mapping/, error.message)
    end
  end

  def test_heterogeneous_policy_and_rule_keys_fail_with_controlled_errors
    valid_rule = {
      "id" => "circleci-storybook",
      "app_slug" => "circleci-checks",
      "name" => "storybook-review-app"
    }
    policies = [
      {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule],
        1 => "unexpected"
      },
      {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule.merge(1 => "unexpected")]
      }
    ]

    policies.each do |policy|
      error = assert_raises(PrCiReadiness::Error) do
        PrCiReadiness.validate_optional_approval_held_policy!(policy)
      end
      assert_match(/closed version 1 mapping|contain exactly app_slug, id, and name/, error.message)
    end
  end

  def test_optional_approval_held_policy_rejects_every_invalid_security_boundary_shape
    valid_rule = {
      "id" => "circleci-storybook",
      "app_slug" => "circleci-checks",
      "name" => "storybook-review-app"
    }
    cases = {
      "unsupported version" => {
        "version" => 2, "optional_approval_held_checks" => [valid_rule]
      },
      "missing version" => {
        "optional_approval_held_checks" => [valid_rule]
      },
      "empty rules" => {
        "version" => 1, "optional_approval_held_checks" => []
      },
      "non-list rules" => {
        "version" => 1, "optional_approval_held_checks" => valid_rule
      },
      "uppercase rule id" => {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule.merge("id" => "CircleCI-Storybook")]
      },
      "underscored app slug" => {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule.merge("app_slug" => "circleci_checks")]
      },
      "unknown name" => {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule.merge("name" => "UNKNOWN")]
      },
      "multiline name" => {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule.merge("name" => "storybook\nreview")]
      },
      "duplicate rule id" => {
        "version" => 1,
        "optional_approval_held_checks" => [
          valid_rule,
          valid_rule.merge("app_slug" => "other-app", "name" => "other-check")
        ]
      },
      "duplicate check identity" => {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule, valid_rule.merge("id" => "other-rule")]
      }
    }

    cases.each do |label, policy|
      assert_raises(PrCiReadiness::Error, label) do
        PrCiReadiness.validate_optional_approval_held_policy!(policy)
      end
    end
  end

  def test_optional_policy_accepts_resolved_names_containing_unknown
    valid_rule = {
      "id" => "circleci-storybook",
      "app_slug" => "circleci-checks",
      "name" => "storybook-review-app"
    }
    ["Approval UNKNOWN state", "NOT-UNKNOWN"].each do |name|
      policy = {
        "version" => 1,
        "optional_approval_held_checks" => [valid_rule.merge("name" => name)]
      }

      assert_equal policy, PrCiReadiness.validate_optional_approval_held_policy!(policy), name
    end
  end

  def run_fixture_git(root, *arguments)
    output, status = Open3.capture2e(
      { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL },
      "git", *arguments, chdir: root
    )
    raise "fixture git failed: #{output}" unless status.success?

    output
  end

  def optional_policy_yaml(name)
    {
      "ci_readiness" => {
        "version" => 1,
        "optional_approval_held_checks" => [
          {
            "id" => "circleci-storybook",
            "app_slug" => "circleci-checks",
            "name" => name
          }
        ]
      }
    }.to_yaml
  end

  def test_required_rows_without_positive_producer_do_not_hide_failing_same_name_evidence
    head = "a" * 40
    checked_at = "2026-07-30T12:00:00Z"
    cases = [
      {
        label: "missing producer status",
        required: {},
        check_runs: [],
        statuses: [{ "kind" => "status", "id" => 23, "name" => "lint", "state" => "failure" }]
      },
      {
        label: "empty producer check",
        required: { "workflow" => "" },
        check_runs: [
          { "kind" => "check_run", "id" => 24, "name" => "lint", "status" => "completed",
            "conclusion" => "failure", "app_slug" => "", "dependabot" => false }
        ],
        statuses: []
      },
      {
        label: "unknown producer check",
        required: { "workflow" => "UNKNOWN" },
        check_runs: [
          { "kind" => "check_run", "id" => 25, "name" => "lint", "status" => "completed",
            "conclusion" => "failure", "app_slug" => "UNKNOWN", "dependabot" => false }
        ],
        statuses: []
      }
    ]

    cases.each do |item|
      scopes = PrCiReadiness.inventory_scopes(
        head_sha: head,
        checked_at:,
        required_rows: [{ "name" => "lint", "bucket" => "pass" }.merge(item.fetch(:required))],
        required_complete: true,
        actions_rows: [],
        actions_complete: true,
        check_runs: item.fetch(:check_runs),
        check_runs_complete: true,
        statuses: item.fetch(:statuses),
        statuses_complete: true
      )
      contract = PrCiReadiness.evidence_contract(
        repo: "owner/repo", pr_number: 7,
        base: { "ref" => "main", "sha" => "b" * 40 }, diff_base_sha: "b" * 40,
        head_sha: head, checked_at:, scopes:
      )
      other_ids = (item.fetch(:check_runs) + item.fetch(:statuses)).map { |row| row.fetch("id") }

      assert_equal other_ids, scopes.dig("other", "rows").map { |row| row.fetch("id") }, item.fetch(:label)
      assert_equal "NOT_READY", scopes.dig("other", "state"), item.fetch(:label)
      assert_equal "NOT_READY", contract.fetch("verdict"), item.fetch(:label)
    end
  end
end

# CLI / Runner integration via a fake gh on PATH.
class PrCiReadinessCliTest < Minitest::Test
  def test_cli_heterogeneous_trusted_policy_keys_fail_without_a_traceback
    Dir.mktmpdir("pr-ci-policy-heterogeneous") do |root|
      run_policy_git(root, "init", "-q")
      run_policy_git(root, "config", "user.name", "Test User")
      run_policy_git(root, "config", "user.email", "test@example.test")
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(
        File.join(root, ".agents", "agent-workflow.yml"),
        <<~YAML
          ci_readiness:
            version: 1
            optional_approval_held_checks:
              - id: circleci-storybook
                app_slug: circleci-checks
                name: storybook-review-app
                1: unexpected
        YAML
      )
      run_policy_git(root, "add", ".agents/agent-workflow.yml")
      run_policy_git(root, "commit", "-q", "-m", "malformed policy")
      base_sha = run_policy_git(root, "rev-parse", "HEAD").strip
      head = "a" * 40
      identity = {
        "id" => 9_001, "number" => 123,
        "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002, "full_name" => "owner/repo" } },
        "base" => { "sha" => base_sha, "ref" => "main", "repo" => { "id" => 9_003, "full_name" => "owner/repo" } }
      }
      with_fake_gh(required_json: "[]", full_json: "[]", pr_head: head, pr_identity: identity) do |env|
        out, status = run_script(
          env, "123", "--repo", "owner/repo", "--trusted-repo-root", root
        )

        refute status.success?
        assert_includes out, "each optional approval-held check must contain exactly"
        refute_includes out, "ArgumentError"
        refute_includes out, "from "
      end
    end
  end

  HICHEE_DATA_431_HEAD = "6c7f86b92e2eac2fc73ce29c74ab5cce9ea9b2c1"

  def hichee_data_431_identity
    {
      "id" => 18_431, "number" => 431,
      "head" => {
        "sha" => HICHEE_DATA_431_HEAD, "ref" => "upgrade-rails",
        "repo" => { "id" => 43_100, "full_name" => "shakacode/hichee-data" }
      }
    }
  end

  # Build a temp dir with a fake `gh` executable that emits canned `gh pr
  # checks` JSON, then run the real script with that dir prepended to PATH.
  def with_fake_gh(required_json:, full_json:, pr_head: "a" * 40, pr_identity: nil, runs: {},
                   review_pages: {}, review_error: false, required_check_fields: nil,
                   rejected_check_field: nil, check_stderr: nil, check_status: 0,
                   required_check_error: nil, full_check_error: nil, exact_actions: [],
                   exact_check_runs: [], exact_statuses: [], exact_inventory_error: nil,
                   exact_actions_total_count: nil, expected_host: nil,
                   exact_status_sha: :echo, exact_status_total_count: nil,
                   exact_status_pages: nil, exact_status_snapshots: nil)
    pr_identity = add_default_base_identity(pr_identity)
    if pr_identity.nil? && (!pr_head.is_a?(String) || !pr_head.match?(/\A[0-9a-f]{40}\z/i))
      fixture_head = "a" * 40
      runs = replace_fixture_value(runs, pr_head, fixture_head)
      review_pages = replace_fixture_value(review_pages, pr_head, fixture_head)
      exact_actions = replace_fixture_value(exact_actions, pr_head, fixture_head)
      exact_check_runs = replace_fixture_value(exact_check_runs, pr_head, fixture_head)
      pr_head = fixture_head
    end
    Dir.mktmpdir("pr-ci-readiness-test") do |dir|
      gh = File.join(dir, "gh")
      File.write(
        gh,
        fake_gh_script(
          required_json, full_json, pr_head, pr_identity, runs, review_pages, review_error,
          required_check_fields, rejected_check_field, check_stderr, check_status,
          required_check_error, full_check_error, exact_actions, exact_check_runs,
          exact_statuses, exact_inventory_error, exact_actions_total_count,
          File.join(dir, "pr-head-state"), File.join(dir, "pr-identity-state"), expected_host,
          exact_status_sha, exact_status_total_count, exact_status_pages, exact_status_snapshots
        )
      )
      FileUtils.chmod(0o755, gh)
      env = { "PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}" }
      yield env
    end
  end

  def add_default_base_identity(identity)
    return identity.map { |item| add_default_base_identity(item) } if identity.is_a?(Array)
    return identity unless identity.is_a?(Hash) && !identity.key?("base")

    repo = identity.dig("head", "repo", "full_name") || "owner/repo"
    identity.merge(
      "base" => {
        "sha" => "b" * 40,
        "ref" => "main",
        "repo" => { "id" => 9_003, "full_name" => repo }
      }
    )
  end

  def replace_fixture_value(value, old_value, new_value)
    case value
    when Array then value.map { |item| replace_fixture_value(item, old_value, new_value) }
    when Hash
      value.to_h do |key, item|
        [key, replace_fixture_value(item, old_value, new_value)]
      end
    else
      value == old_value ? new_value : value
    end
  end

  # The fake gh handles `gh repo view ...` (so --repo is optional) and
  # `gh pr checks ...`, returning the required vs full payload based on the
  # presence of the --required flag. Non-JSON ("") models "no required checks".
  def shell_json_printf(value)
    "printf '%s' #{JSON.generate(value).inspect}"
  end

  # GitHub's documented combination rule for the combined status endpoint. The
  # script validates this field against the returned per-context statuses.
  def combined_status_state(statuses)
    states = statuses.map { |row| row["state"] }
    return "pending" if states.empty?
    return "failure" if states.any? { |state| %w[failure error].include?(state) }

    states.all? { |state| state == "success" } ? "success" : "pending"
  end

  # `GET /repos/{repo}/commits/{ref}/status` wraps the per-context rows in an
  # envelope whose top-level `sha` echoes the commit GitHub resolved. That
  # echo is the exact-head binding the script asserts, so the fake reproduces
  # it by parsing the requested ref out of the URL. Tests override
  # `exact_status_sha` with a literal SHA (mismatch) or nil (missing) to prove
  # the assertion still fails closed.
  def combined_status_branch(exact_statuses, exact_inventory_error, exact_status_sha, exact_status_total_count,
                             exact_status_pages, exact_status_snapshots, status_state_path)
    if exact_status_snapshots
      snapshot_cases = exact_status_snapshots.each_with_index.map do |payload, index|
        "  #{index}) #{shell_json_printf(payload)} ;;"
      end.join("\n")
      return <<~BASH
        if [[ "$*" = *"/status?per_page="* ]]; then
          #{exact_inventory_error == 'statuses' ? 'exit 1' : ''}
          count=0
          if [ -f #{status_state_path.inspect} ]; then count=$(cat #{status_state_path.inspect}); fi
          case "$count" in
          #{snapshot_cases}
            *) #{shell_json_printf(exact_status_snapshots.last)} ;;
          esac
          printf '%s' "$((count + 1))" > #{status_state_path.inspect}
          exit 0
        fi
      BASH
    end

    if exact_status_pages
      page_cases = exact_status_pages.each_with_index.map do |payload, index|
        "  #{index + 1}) #{shell_json_printf(payload)} ;;"
      end.join("\n")
      return <<~BASH
        if [[ "$*" = *"/status?per_page="* ]]; then
          #{exact_inventory_error == 'statuses' ? 'exit 1' : ''}
          page="${2##*page=}"
          case "$page" in
          #{page_cases}
            *) exit 1 ;;
          esac
          exit 0
        fi
      BASH
    end

    total_count = exact_status_total_count || exact_statuses.length
    combined_state = JSON.generate(combined_status_state(exact_statuses))
    envelope_tail = %(,"state":#{combined_state},"total_count":#{total_count},"statuses":)
    body =
      if exact_status_sha == :echo
        <<~BASH
          ref="${2#*/commits/}"
          ref="${ref%%/status*}"
          printf '%s' '{"sha":"'"$ref"'"#{envelope_tail}'
          #{shell_json_printf(exact_statuses)}
          printf '%s' '}'
        BASH
      else
        envelope = { "state" => combined_status_state(exact_statuses),
                     "total_count" => total_count,
                     "statuses" => exact_statuses }
        envelope = { "sha" => exact_status_sha }.merge(envelope) unless exact_status_sha.nil?
        shell_json_printf(envelope)
      end
    <<~BASH
      if [[ "$*" = *"/status?per_page="* ]]; then
        #{exact_inventory_error == 'statuses' ? 'exit 1' : ''}
      #{body}
        exit 0
      fi
    BASH
  end

  def fake_gh_script(required_json, full_json, pr_head, pr_identity, runs, review_pages, review_error,
                     required_check_fields, rejected_check_field, check_stderr, check_status,
                     required_check_error, full_check_error, exact_actions, exact_check_runs,
                     exact_statuses, exact_inventory_error, exact_actions_total_count,
                     pr_head_state_path, pr_identity_state_path, expected_host,
                     exact_status_sha, exact_status_total_count, exact_status_pages,
                     exact_status_snapshots)
    required_check_command = if required_json.is_a?(Array)
                               state_path = "#{pr_head_state_path}.required-checks"
                               cases = required_json.each_with_index.map do |payload, index|
                                 "#{index}) printf '%s' #{payload.inspect} ;;"
                               end.join("\n")
                               <<~BASH
                                 count=0
                                 if [ -f #{state_path.inspect} ]; then count=$(cat #{state_path.inspect}); fi
                                 case "$count" in
                                 #{cases}
                                   *) printf '%s' #{required_json.last.inspect} ;;
                                 esac
                                 printf '%s' "$((count + 1))" > #{state_path.inspect}
                               BASH
                             else
                               "printf '%s' #{required_json.inspect}"
                             end
    host_guard =
      if expected_host
        <<~BASH
          if [ "$GH_HOST" != #{expected_host.inspect} ]; then
            echo "unexpected GH_HOST: $GH_HOST" >&2
            exit 91
          fi
        BASH
      else
        ""
      end
    pr_head_command =
      if pr_head.is_a?(Array)
        cases = pr_head.each_with_index.map do |head, index|
          "#{index}) payload=#{JSON.generate('headRefOid' => head).inspect} ;;"
        end.join("\n")
        <<~BASH
          count=0
          if [ -f #{pr_head_state_path.inspect} ]; then count=$(cat #{pr_head_state_path.inspect}); fi
          case "$count" in
          #{cases}
          *) payload=#{JSON.generate('headRefOid' => pr_head.last).inspect} ;;
          esac
          printf '%s' "$payload"
          printf '%s' "$((count + 1))" > #{pr_head_state_path.inspect}
        BASH
      else
        <<~BASH
          cat <<'JSON'
          #{JSON.generate('headRefOid' => pr_head)}
          JSON
        BASH
      end
    pr_identity_command =
      if pr_identity.is_a?(Array)
        cases = pr_identity.each_with_index.map do |identity, index|
          if identity.nil?
            "#{index}) exit 1 ;;"
          else
            "#{index}) payload=#{JSON.generate(identity).inspect}; printf '%s' \"$payload\" ;;"
          end
        end.join("\n")
        fallback =
          if pr_identity.last.nil?
            "exit 1"
          else
            "payload=#{JSON.generate(pr_identity.last).inspect}; printf '%s' \"$payload\""
          end
        <<~BASH
          count=0
          if [ -f #{pr_identity_state_path.inspect} ]; then count=$(cat #{pr_identity_state_path.inspect}); fi
          printf '%s' "$((count + 1))" > #{pr_identity_state_path.inspect}
          case "$count" in
          #{cases}
          *) #{fallback} ;;
          esac
        BASH
      elsif pr_identity
        shell_json_printf(pr_identity)
      else
        identity_head =
          if pr_head.is_a?(String) && pr_head.match?(/\A[0-9a-f]{40,64}\z/i)
            pr_head
          else
            "a" * 40
          end
        default_identity = {
          "id" => 9_001,
          "number" => 0,
          "head" => {
            "sha" => identity_head,
            "ref" => "feature",
            "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
          },
          "base" => {
            "sha" => "b" * 40,
            "ref" => "main",
            "repo" => { "id" => 9_003, "full_name" => "owner/repo" }
          }
        }
        template = JSON.generate(default_identity).sub('"number":0', '"number":%s')
        "printf #{template.inspect} \"$FAKE_PR_NUMBER\""
      end
    run_cases = runs.map do |run_id, payload|
      run = payload.fetch(:run)
      run = run.merge("run_attempt" => 1) unless run.key?("run_attempt")
      run_json = JSON.generate(run)
      jobs_json = JSON.generate(
        "total_count" => payload.fetch(:jobs_total_count, payload.fetch(:jobs).length),
        "jobs" => payload.fetch(:jobs)
      )
      jobs_case =
        if payload.fetch(:jobs_error, false)
          <<~BASH
            if [[ "$*" = *"actions/runs/#{run_id}/jobs"* ]]; then
              echo 'jobs should not be fetched for this run' >&2
              exit 1
            fi
          BASH
        else
          <<~BASH
            if [[ "$*" = *"actions/runs/#{run_id}/jobs"* ]]; then
              cat <<'JSON'
            #{jobs_json}
            JSON
              exit 0
            fi
          BASH
        end
      <<~BASH
        #{jobs_case}
        if [[ "$*" = *"actions/runs/#{run_id}"* ]]; then
          cat <<'JSON'
        #{run_json}
        JSON
          exit 0
        fi
      BASH
    end.join("\n")

    review_cases = review_pages.filter_map do |cursor, payload|
      next if cursor.nil?

      <<~BASH
        if [[ "$*" = *"endCursor=#{cursor}"* ]]; then
          cat <<'JSON'
        #{JSON.generate(payload)}
        JSON
          exit 0
        fi
      BASH
    end.join("\n")
    first_page = review_pages.fetch(nil, {
                                      "data" => {
                                        "repository" => {
                                          "pullRequest" => {
                                            "reviews" => {
                                              "nodes" => [],
                                              "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                                            }
                                          }
                                        }
                                      }
                                    })
    first_page_command =
      if first_page.is_a?(Array)
        state_path = "#{pr_head_state_path}.review-inventory"
        cases = first_page.each_with_index.map do |payload, index|
          "#{index}) payload=#{JSON.generate(payload).inspect} ;;"
        end.join("\n")
        <<~BASH
          count=0
          if [ -f #{state_path.inspect} ]; then count=$(cat #{state_path.inspect}); fi
          case "$count" in
          #{cases}
            *) payload=#{JSON.generate(first_page.last).inspect} ;;
          esac
          printf '%s' "$payload"
          printf '%s' "$((count + 1))" > #{state_path.inspect}
        BASH
      else
        shell_json_printf(first_page)
      end
    check_fields_guard = if required_check_fields
                           <<~BASH
                             if [[ " $* " != *" --json #{required_check_fields} "* ]]; then
                               exit 2
                             fi
                           BASH
                         else
                           ""
                         end
    rejected_check_field_guard = if rejected_check_field
                                   <<~BASH
                                     if [[ "$*" = *"#{rejected_check_field}"* ]]; then
                                       exit 1
                                     fi
                                   BASH
                                 else
                                   ""
                                 end
    check_stderr_command = check_stderr ? "printf '%b' #{check_stderr.inspect} >&2" : ""
    required_check_error_command = if required_check_error
                                     <<~BASH
                                       printf '%b' #{required_check_error.inspect} >&2
                                       exit 1
                                     BASH
                                   else
                                     ""
                                   end
    full_check_error_command = if full_check_error
                                 <<~BASH
                                   printf '%b' #{full_check_error.inspect} >&2
                                   exit 1
                                 BASH
                               else
                                 ""
                               end
    identity_payload = pr_identity.is_a?(Array) ? pr_identity.compact.first : pr_identity
    suite_head = identity_payload&.dig("head", "sha") || pr_head
    check_runs_by_slug = exact_check_runs.each_with_index.group_by do |(row, index)|
      row.dig("app", "slug") || "malformed-#{index}"
    end
    prepared_suite_runs = check_runs_by_slug.map.with_index do |(slug, indexed_rows), index|
      suite_id = 800 + index
      app = { "id" => 900 + index, "slug" => slug }
      runs_for_suite = indexed_rows.map do |row, _row_index|
        prepared = JSON.parse(JSON.generate(row))
        if prepared["app"].is_a?(Hash)
          prepared["app"] = app.merge(prepared["app"])
        end
        prepared["check_suite"] ||= { "id" => suite_id }
        unless prepared.key?("started_at")
          prepared["started_at"] = prepared["status"] == "completed" ? "2026-08-25T12:00:00Z" : nil
        end
        prepared
      end
      suite_status = runs_for_suite.any? { |row| row["status"] != "completed" } ? "in_progress" : "completed"
      suite_conclusion = if suite_status == "completed"
                           runs_for_suite.filter_map { |row| row["conclusion"] }
                                         .find { |value| !%w[neutral skipped success].include?(value) } || "success"
                         end
      suite = {
        "id" => suite_id,
        "created_at" => "2026-08-25T#{format('%02d', 10 + index)}:00:00Z",
        "updated_at" => "2026-08-25T#{format('%02d', 10 + index)}:00:00Z",
        "head_sha" => suite_head,
        "app" => app,
        "status" => suite_status,
        "conclusion" => suite_conclusion,
        "latest_check_runs_count" => runs_for_suite.length
      }
      [suite, runs_for_suite]
    end
    suite_rows = prepared_suite_runs.map(&:first)
    suite_run_cases = prepared_suite_runs.map do |suite, suite_runs|
      <<~BASH
        if [[ "$*" = *"/check-suites/#{suite.fetch('id')}/check-runs?filter=latest&per_page="* ]]; then
          #{exact_inventory_error == 'check_runs' ? 'exit 1' : ''}
          #{shell_json_printf('total_count' => suite_runs.length, 'check_runs' => suite_runs)}
          exit 0
        fi
      BASH
    end.join("\n")

    <<~SH
      #!/usr/bin/env bash
      #{host_guard}
      if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
        printf 'owner/repo'
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      #{pr_head_command}
        exit 0
      fi
      if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
      #{check_fields_guard}
      #{rejected_check_field_guard}
        #{check_stderr_command}
        for arg in "$@"; do
          if [ "$arg" = "--required" ]; then
          #{required_check_error_command}
          #{required_check_command}
            exit #{check_status}
          fi
        done
      #{full_check_error_command}
        printf '%s' #{full_json.inspect}
        exit #{check_status}
      fi
      if [ "$1" = "api" ]; then
        if [[ "$2" = repos/*/pulls/* ]]; then
        #{pr_identity_command}
          exit 0
        fi
        if [ "$2" = "graphql" ]; then
          if #{review_error}; then
            exit 1
          fi
      #{review_cases}
      #{first_page_command}
          exit 0
        fi
        if [[ "$*" = *"actions/runs?head_sha="* ]]; then
          #{exact_inventory_error == 'actions' ? 'exit 1' : ''}
          #{shell_json_printf(
            'total_count' => exact_actions_total_count || exact_actions.length,
            'workflow_runs' => exact_actions
          )}
          exit 0
        fi
        if [[ "$*" = *"/check-suites?per_page="* ]]; then
          #{exact_inventory_error == 'check_runs' ? 'exit 1' : ''}
          #{shell_json_printf('total_count' => suite_rows.length, 'check_suites' => suite_rows)}
          exit 0
        fi
      #{suite_run_cases}
      #{combined_status_branch(
        exact_statuses, exact_inventory_error, exact_status_sha, exact_status_total_count, exact_status_pages,
        exact_status_snapshots, "#{pr_head_state_path}.statuses"
      )}
        # The status-history list endpoint is served with its real shape: its
        # rows carry no commit SHA. Nothing should request it -- it is kept so
        # a regression back to it fails closed instead of passing silently.
        if [[ "$*" = *"/statuses?per_page="* ]]; then
          #{exact_inventory_error == 'statuses' ? 'exit 1' : ''}
          #{shell_json_printf(exact_statuses)}
          exit 0
        fi
      #{run_cases}
      fi
      exit 1
    SH
  end

  def run_script(env, *args)
    fake_env = env.merge("FAKE_PR_NUMBER" => args.first.to_s)
    Open3.capture2e(fake_env, "ruby", SCRIPT, *args)
  end

  def with_optional_policy_repo
    Dir.mktmpdir("pr-ci-readiness-policy") do |root|
      run_policy_git(root, "init", "-q")
      run_policy_git(root, "config", "user.name", "Test User")
      run_policy_git(root, "config", "user.email", "test@example.test")
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(
        File.join(root, ".agents", "agent-workflow.yml"),
        {
          "ci_readiness" => {
            "version" => 1,
            "optional_approval_held_checks" => [
              {
                "id" => "circleci-storybook",
                "app_slug" => "circleci-checks",
                "name" => "storybook-review-app"
              }
            ]
          }
        }.to_yaml
      )
      run_policy_git(root, "add", ".agents/agent-workflow.yml")
      run_policy_git(root, "commit", "-q", "-m", "policy")
      yield root, run_policy_git(root, "rev-parse", "HEAD").strip
    end
  end

  def run_policy_git(root, *arguments)
    output, status = Open3.capture2e(
      { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL },
      PrCiReadiness::SYSTEM_GIT, *arguments, chdir: root
    )
    raise "fixture git failed: #{output}" unless status.success?

    output
  end

  def test_check_fetch_requests_workflow_identity
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]",
      required_check_fields: "name,state,bucket,link,workflow"
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      assert_equal "READY", JSON.parse(out)["verdict"]
    end
  end

  def test_explicit_ghes_host_is_normalized_propagated_and_emitted
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]",
      expected_host: "ghe.example.com"
    ) do |env|
      out, status = run_script(env, "123", "--host", "GHE.EXAMPLE.COM:443")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "READY", data.fetch("verdict")
      assert_equal "owner/repo", data.fetch("repo")
      assert_equal "ghe.example.com", data.dig("context", "host")
    end
  end

  def test_explicit_ghes_host_preserves_canonical_nondefault_port
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]",
      expected_host: "ghe.example:8443"
    ) do |env|
      out, status = run_script(env, "123", "--host", "GHE.EXAMPLE:8443")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "READY", data.fetch("verdict")
      assert_equal "ghe.example:8443", data.dig("context", "host")
    end
  end

  def test_explicit_host_rejects_port_above_canonical_range
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]"
    ) do |env|
      out, status = run_script(env, "123", "--host", "ghe.example:65536")

      refute status.success?, out
      assert_includes out, "invalid GitHub host"
    end
  end

  def test_explicit_host_preserves_canonical_port_boundaries
    [1, 65_535].each do |port|
      host = "ghe.example:#{port}"
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
        full_json: "[]",
        expected_host: host
      ) do |env|
        out, status = run_script(env, "123", "--host", host)

        assert status.success?, out
        assert_equal host, JSON.parse(out).dig("context", "host")
      end
    end
  end

  def test_invalid_explicit_hosts_are_rejected
    invalid_hosts = [
      "",
      "https://ghe.example.com",
      "ghe.example.com/path",
      "user@ghe.example.com",
      "ghe.example.com:",
      "ghe.example.com:0",
      "ghe.example.com:0443",
      "ghe.example.com:abc",
      "ghe.example.com:12x",
      "ghe.example.com:65536",
      "[ghe.example.com]:8443",
      "ghe.example.com::8443",
      ":8443",
      "ghe.example.com:8443:1",
      "bad..example.com",
      "-bad.example.com",
      "bad-.example.com",
      "bad_host.example.com"
    ]
    with_fake_gh(required_json: "[]", full_json: "[]") do |env|
      invalid_hosts.each do |host|
        out, status = run_script(env, "123", "--repo", "owner/repo", "--host", host)

        refute status.success?, host
        assert_includes out, "invalid GitHub host", host
      end
    end
  end

  def test_host_defaults_to_caller_environment_then_github_dot_com
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]",
      expected_host: "ghe.env.example"
    ) do |env|
      env["GH_HOST"] = "GHE.ENV.EXAMPLE:443"
      out, status = run_script(env, "123")

      assert status.success?, out
      assert_equal "ghe.env.example", JSON.parse(out).dig("context", "host")
    end

    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]",
      expected_host: "github.com"
    ) do |env|
      env["GH_HOST"] = nil
      out, status = run_script(env, "123")

      assert status.success?, out
      assert_equal "github.com", JSON.parse(out).dig("context", "host")
    end
  end

  def test_host_qualified_repo_cannot_conflict_with_resolved_host
    with_fake_gh(
      required_json: "[]",
      full_json: "[]",
      expected_host: "ghe.example.com"
    ) do |env|
      out, status = run_script(
        env,
        "123",
        "--host", "ghe.example.com",
        "--repo", "github.com/owner/repo"
      )

      refute status.success?
      assert_includes out, "repo host github.com conflicts with resolved GitHub host ghe.example.com"
    end
  end

  def test_matching_host_qualified_repo_is_normalized_for_collection
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]",
      expected_host: "ghe.example.com"
    ) do |env|
      out, status = run_script(
        env,
        "123",
        "--host", "ghe.example.com",
        "--repo", "GHE.EXAMPLE.COM:443/owner/repo"
      )

      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "owner/repo", data.fetch("repo")
      assert_equal "ghe.example.com", data.dig("context", "host")
    end
  end

  def test_matching_nondefault_port_host_qualified_repo_is_normalized_for_collection
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      full_json: "[]",
      expected_host: "ghe.example:8443"
    ) do |env|
      out, status = run_script(
        env,
        "123",
        "--host", "ghe.example:8443",
        "--repo", "GHE.EXAMPLE:8443/owner/repo"
      )

      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "owner/repo", data.fetch("repo")
      assert_equal "ghe.example:8443", data.dig("context", "host")
    end
  end

  def test_host_qualified_repo_port_cannot_conflict_with_resolved_host
    with_fake_gh(
      required_json: "[]",
      full_json: "[]",
      expected_host: "ghe.example:8443"
    ) do |env|
      out, status = run_script(
        env,
        "123",
        "--host", "ghe.example:8443",
        "--repo", "ghe.example:9443/owner/repo"
      )

      refute status.success?
      assert_includes out, "repo host ghe.example:9443 conflicts with resolved GitHub host ghe.example:8443"
    end
  end

  def test_required_checks_used_when_present
    with_fake_gh(
      required_json: '[{"name":"rspec","state":"SUCCESS","bucket":"pass","link":"x"}]',
      full_json: '[{"name":"rspec","bucket":"pass"},{"name":"extra","bucket":"fail"}]'
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_equal true, data["required_used"]
      assert_equal 123, data["pr"]
    end
  end

  # Regression for #202 contract 1, end to end through the CLI: a required
  # row with an unrecognized bucket (e.g. a future gh CLI state) must not be
  # silently treated as passing.
  def test_cli_fails_closed_for_unrecognized_required_bucket
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"mystery","bucket":"future-state"}]',
      full_json: "[]"
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal true, data["required_used"]
      assert_equal ["mystery (bucket: \"future-state\")"], data["invalid"]
    end
  end

  # Regression for the claude-review finding on #202: PrCiReadiness.assess
  # was library-tested against non-object rows, but Runner#assess indexes
  # PrCiReadiness.parse_rows output (`row["bucket"]`, `check_identity`,
  # `active_rows`) several times *before* rows ever reach
  # PrCiReadiness.assess -- e.g. required_cancellations = required_rows.select
  # { |row| row["bucket"] ... }. parse_rows only validates that the parsed
  # JSON is an Array; it does not filter non-Hash elements. A `null` or bare
  # scalar entry in the gh CLI payload therefore raised an uncaught
  # NoMethodError (Error is a distinct class from NoMethodError, and
  # Runner#run only rescues Error) instead of the CLI exiting cleanly with
  # NOT_READY and the row named in "invalid". Drive it through the real
  # Runner/CLI path, not just the library function.
  def test_cli_survives_and_fails_closed_for_non_object_required_rows
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"ok","bucket":"pass"},null,42]',
      full_json: "[]"
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      refute_includes out, "NoMethodError"
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal true, data["required_used"]
      assert_equal(
        ["row was not an object (NilClass)", "row was not an object (Integer)"],
        data["invalid"]
      )
    end
  end

  # A required-checks payload that is entirely non-object rows (e.g. `[null]`)
  # must not be treated as "no usable required checks" -- that would fall
  # back to the full advisory list and silently lose the malformed-evidence
  # signal instead of failing closed on it directly.
  def test_cli_required_only_malformed_rows_fails_closed_without_falling_back
    with_fake_gh(
      required_json: "[null]",
      full_json: '[{"name":"advisory","bucket":"pass"}]'
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      refute_includes out, "NoMethodError"
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal true, data["required_used"]
      assert_equal ["row was not an object (NilClass)"], data["invalid"]
    end
  end

  # Same crash surface, reached via the full-list fallback path (no usable
  # required checks) instead of the required-checks path.
  def test_cli_full_list_fallback_survives_malformed_rows
    with_fake_gh(
      required_json: "",
      full_json: '[{"workflow":"CI","name":"unit","bucket":"pass"},null]'
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      refute_includes out, "NoMethodError"
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal false, data["required_used"]
      assert_equal ["row was not an object (NilClass)"], data["invalid"]
    end
  end

  def test_cli_emits_complete_exact_head_inventory_with_dynamic_and_dependabot_rows
    head = "a" * 40
    action_runs = [
      {
        "id" => 100, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 1, "run_attempt" => 1, "name" => "Dynamic CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "success",
        "actor" => { "login" => "octocat" }, "html_url" => "https://example/run/100"
      },
      {
        "id" => 101, "workflow_id" => 11, "event" => "pull_request",
        "run_number" => 1, "run_attempt" => 1, "name" => "Dependabot CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "success",
        "actor" => { "login" => "dependabot[bot]" }, "html_url" => "https://example/run/101"
      }
    ]
    runs = action_runs.to_h do |run|
      [
        run.fetch("id").to_s,
        {
          run:,
          jobs: [{
            "id" => run.fetch("id") * 10, "name" => "#{run.fetch('name')} job",
            "status" => "completed", "conclusion" => "success",
            "html_url" => "#{run.fetch('html_url')}/job"
          }]
        }
      ]
    end
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_actions: action_runs,
      exact_check_runs: [
        {
          "id" => 300, "name" => "dynamic-check", "status" => "completed",
          "conclusion" => "success", "head_sha" => head,
          "app" => { "slug" => "github-actions" }, "html_url" => "https://example/check/300"
        },
        {
          "id" => 301, "name" => "security", "status" => "completed",
          "conclusion" => "success", "head_sha" => head,
          "app" => { "slug" => "external-ci" }, "html_url" => "https://example/check/301"
        }
      ],
      exact_statuses: [
        {
          "id" => 400, "context" => "legacy", "state" => "success",
          "target_url" => "https://example/status/400"
        }
      ],
      runs:
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "pr-ci-readiness", data.fetch("contract")
      assert_equal 2, data.fetch("version")
      assert_equal head, data.fetch("head_sha")
      assert_equal "READY", data.fetch("verdict")
      assert_equal(
        ["Dynamic CI", "Dynamic CI job", "dynamic-check"],
        data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("name") }.sort
      )
      assert_equal(
        ["Dependabot CI", "Dependabot CI job"],
        data.dig("scopes", "dependabot", "rows").map { |row| row.fetch("name") }.sort
      )
      assert_equal(
        %w[legacy security],
        data.dig("scopes", "other", "rows").map { |row| row.fetch("name") }.sort
      )
      data.fetch("scopes").each_value do |scope|
        assert_equal true, scope.fetch("complete")
        assert_equal head, scope.fetch("head_sha")
        refute_nil scope.fetch("checked_at")
      end
    end
  end

  def test_exact_head_actions_keep_only_current_run_per_workflow_and_event
    head = "a" * 40
    action_runs = [
      {
        "id" => 100, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 7, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "cancelled"
      },
      {
        "id" => 101, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 8, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "cancelled"
      },
      {
        "id" => 102, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 8, "run_attempt" => 2, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "cancelled"
      },
      {
        "id" => 103, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 8, "run_attempt" => 2, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "success"
      },
      {
        "id" => 104, "workflow_id" => 10, "event" => "workflow_dispatch",
        "run_number" => 3, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "success"
      },
      {
        "id" => 105, "workflow_id" => 11, "event" => "pull_request",
        "run_number" => 2, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "success"
      }
    ]
    runs = action_runs.to_h do |run|
      id = run.fetch("id")
      [
        id.to_s,
        if id < 103
          { run:, jobs: [], jobs_error: true }
        else
          {
            run:,
            jobs: [{
              "id" => id * 10, "name" => "unit", "status" => "completed",
              "conclusion" => "success"
            }]
          }
        end
      ]
    end

    results = [action_runs, action_runs.reverse].map do |ordered_runs|
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        exact_actions: ordered_runs,
        runs:
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        [
          data.fetch("verdict"),
          data.dig("scopes", "github_actions", "state"),
          data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("id") }
        ]
      end
    end

    assert_equal(
      Array.new(2) { ["READY", "READY", [103, 1030, 104, 1040, 105, 1050]] },
      results
    )
  end

  # Regression: exact_head_inventory must not re-append a superseded GitHub
  # Actions check run after fetch_exact_head_actions selects the current run.
  def test_exact_head_actions_do_not_reappend_superseded_check_runs
    head = "a" * 40
    old_run = {
      "id" => 100, "workflow_id" => 10, "event" => "pull_request",
      "run_number" => 7, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "pull_requests" => [],
      "status" => "completed", "conclusion" => "failure",
      "html_url" => "https://github.com/owner/repo/actions/runs/100"
    }
    current_run = old_run.merge(
      "id" => 101, "run_number" => 8, "conclusion" => "success",
      "html_url" => "https://github.com/owner/repo/actions/runs/101"
    )
    current_job = {
      "id" => 1010, "name" => "unit", "status" => "completed", "conclusion" => "success",
      "html_url" => "https://github.com/owner/repo/actions/runs/101/job/1010"
    }

    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_actions: [old_run, current_run],
      exact_check_runs: [
        {
          "id" => 2001, "name" => "unit", "status" => "completed", "conclusion" => "success",
          "head_sha" => head, "app" => { "slug" => "github-actions" },
          "html_url" => current_job.fetch("html_url")
        }
      ],
      runs: {
        "100" => { run: old_run, jobs: [], jobs_error: true },
        "101" => { run: current_run, jobs: [current_job] }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "READY", data.fetch("verdict")
      assert_equal "READY", data.dig("scopes", "github_actions", "state")
      assert_equal([101, 1010], data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("id") })
    end
  end

  def test_exact_head_actions_do_not_hide_a_same_job_rerun_that_became_in_progress
    head = "a" * 40
    current_run = {
      "id" => 101, "workflow_id" => 10, "event" => "pull_request",
      "run_number" => 8, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "pull_requests" => [],
      "status" => "completed", "conclusion" => "success",
      "html_url" => "https://github.com/owner/repo/actions/runs/101"
    }
    completed_job = {
      "id" => 1010, "name" => "unit", "status" => "completed", "conclusion" => "success",
      "html_url" => "https://github.com/owner/repo/actions/runs/101/job/1010"
    }
    rerunning_check = {
      "id" => 2001, "name" => "unit", "status" => "in_progress", "conclusion" => nil,
      "head_sha" => head, "app" => { "slug" => "github-actions" },
      "started_at" => "2026-08-25T12:01:00Z", "html_url" => completed_job.fetch("html_url")
    }

    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_actions: [current_run],
      exact_check_runs: [rerunning_check],
      runs: { "101" => { run: current_run, jobs: [completed_job] } }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "NOT_READY", data.fetch("verdict")
      assert_equal "NOT_READY", data.dig("scopes", "github_actions", "state")
      assert_equal(
        [101, 1010, 2001],
        data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("id") }
      )
    end
  end

  def test_exact_head_actions_retain_unobserved_and_unassociated_check_runs
    head = "a" * 40
    current_run = {
      "id" => 101, "workflow_id" => 10, "event" => "pull_request",
      "run_number" => 8, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "pull_requests" => [],
      "status" => "completed", "conclusion" => "success",
      "html_url" => "https://github.com/owner/repo/actions/runs/101"
    }
    current_job = {
      "id" => 1010, "name" => "unit", "status" => "completed", "conclusion" => "success",
      "html_url" => "https://github.com/owner/repo/actions/runs/101/job/1010"
    }

    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_actions: [current_run],
      exact_check_runs: [
        {
          "id" => 2000, "name" => "unknown-run", "status" => "completed", "conclusion" => "failure",
          "head_sha" => head, "app" => { "slug" => "github-actions" },
          "html_url" => "https://github.com/owner/repo/actions/runs/999/job/9990"
        },
        {
          "id" => 2001, "name" => "unassociated", "status" => "completed", "conclusion" => "failure",
          "head_sha" => head, "app" => { "slug" => "github-actions" },
          "html_url" => "https://github.com/owner/repo/actions/runs/101/job/1010/not-a-job-url"
        }
      ],
      runs: { "101" => { run: current_run, jobs: [current_job] } }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "NOT_READY", data.fetch("verdict")
      assert_equal "NOT_READY", data.dig("scopes", "github_actions", "state")
      assert_equal(
        [101, 1010, 2000, 2001],
        data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("id") }
      )
    end
  end

  def test_exact_head_actions_select_target_pr_before_current_run_grouping
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    target_association = {
      "id" => 5_001, "number" => 123, "url" => "https://api.example/pulls/123",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    other_association = {
      "id" => 5_002, "number" => 456, "url" => "https://api.example/pulls/456",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    action_runs = [
      {
        "id" => 100, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 7, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [target_association],
        "status" => "completed", "conclusion" => "failure"
      },
      {
        "id" => 101, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 8, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [other_association],
        "status" => "completed", "conclusion" => "success"
      }
    ]
    runs = action_runs.to_h do |run|
      id = run.fetch("id")
      [
        id.to_s,
        {
          run:,
          jobs: [{
            "id" => id * 10, "name" => "unit", "status" => "completed",
            "conclusion" => run.fetch("conclusion")
          }]
        }
      ]
    end

    results = [action_runs, action_runs.reverse].map do |ordered_runs|
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        pr_identity: target_identity,
        exact_actions: ordered_runs,
        runs:
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        [
          data.fetch("verdict"),
          data.dig("scopes", "github_actions", "state"),
          data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("id") }
        ]
      end
    end

    assert_equal(
      Array.new(2) { ["NOT_READY", "NOT_READY", [100, 1000]] },
      results
    )
  end

  def test_exact_head_actions_accept_uppercase_full_sha_for_consistent_target
    head = "A" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    target_association = {
      "id" => 5_001, "number" => 123, "url" => "https://api.example/pulls/123",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    run = {
      "id" => 100, "workflow_id" => 10, "event" => "pull_request",
      "run_number" => 7, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "pull_requests" => [target_association],
      "status" => "completed", "conclusion" => "success"
    }
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      pr_identity: target_identity,
      exact_actions: [run],
      runs: {
        "100" => {
          run:,
          jobs: [{
            "id" => 1000, "name" => "unit", "status" => "completed",
            "conclusion" => "success"
          }]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data.fetch("verdict")
      assert_equal "READY", data.dig("scopes", "github_actions", "state")
      assert_equal(
        [100, 1000],
        data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("id") }
      )
    end
  end

  def test_exact_head_actions_scope_empty_associations_to_target_branch_and_repository
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    action_runs = [
      {
        "id" => 300, "workflow_id" => 30, "event" => "push",
        "run_number" => 7, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [], "status" => "completed", "conclusion" => "failure"
      },
      {
        "id" => 301, "workflow_id" => 30, "event" => "push",
        "run_number" => 8, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "other-feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [], "status" => "completed", "conclusion" => "success"
      },
      {
        "id" => 302, "workflow_id" => 30, "event" => "push",
        "run_number" => 9, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_003 },
        "pull_requests" => [], "status" => "completed", "conclusion" => "success"
      }
    ]
    runs = action_runs.to_h do |run|
      id = run.fetch("id")
      [
        id.to_s,
        {
          run:,
          jobs: [{
            "id" => id * 10, "name" => "unit", "status" => "completed",
            "conclusion" => run.fetch("conclusion")
          }]
        }
      ]
    end

    results = [action_runs, action_runs.reverse].map do |ordered_runs|
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        pr_identity: target_identity,
        exact_actions: ordered_runs,
        runs:
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        [
          data.fetch("verdict"),
          data.dig("scopes", "github_actions", "state"),
          data.dig("scopes", "github_actions", "rows").map { |row| row.fetch("id") }
        ]
      end
    end

    assert_equal(
      Array.new(2) { ["NOT_READY", "NOT_READY", [300, 3000]] },
      results
    )
  end

  # Regression for #282: `normalize_actions_row` dropped each run's target
  # identity, so exact-head evidence rows (and any merge-assurance receipt
  # built from them) could not be attributed to the PR they came from after
  # the fact. `actions_run_targets_pr?` already scopes correctness (#279);
  # this only adds the identity as observable data on both the run row and
  # its job rows, sorted and de-duplicated, without gating readiness.
  def test_exact_head_actions_rows_carry_head_branch_and_all_associated_pull_request_numbers
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    target_association = {
      "id" => 5_001, "number" => 123, "url" => "https://api.example/pulls/123",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    # A second PR sharing the same branch/head/repo does not conflict with
    # the target identity check (only a partial id/number match would), so
    # both associated numbers should appear in the emitted row, sorted.
    other_association = {
      "id" => 5_003, "number" => 45, "url" => "https://api.example/pulls/45",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    run = {
      "id" => 200, "workflow_id" => 20, "event" => "pull_request",
      "run_number" => 4, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "pull_requests" => [target_association, other_association],
      "status" => "completed", "conclusion" => "success"
    }
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      pr_identity: target_identity,
      exact_actions: [run],
      runs: {
        "200" => {
          run:,
          jobs: [{
            "id" => 2_000, "name" => "unit", "status" => "completed",
            "conclusion" => "success"
          }]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "READY", data.fetch("verdict")
      rows = data.dig("scopes", "github_actions", "rows")
      run_row = rows.find { |row| row.fetch("id") == 200 }
      job_row = rows.find { |row| row.fetch("id") == 2_000 }

      assert_equal "feature", run_row.fetch("head_branch")
      assert_equal [45, 123], run_row.fetch("pull_requests")
      assert_equal "feature", job_row.fetch("head_branch")
      assert_equal [45, 123], job_row.fetch("pull_requests")
    end
  end

  def test_target_pr_identity_move_or_malformed_refetch_invalidates_every_evidence_scope
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    changed_head = ->(values) { target_identity.merge("head" => target_identity.fetch("head").merge(values)) }
    changed_repo = lambda do |values|
      changed_head.call("repo" => target_identity.dig("head", "repo").merge(values))
    end
    final_identities = {
      "PR id moved" => target_identity.merge("id" => 5_002),
      "PR id missing" => target_identity.reject { |key, _value| key == "id" },
      "PR id non-positive" => target_identity.merge("id" => 0),
      "PR number moved" => target_identity.merge("number" => 124),
      "PR number missing" => target_identity.reject { |key, _value| key == "number" },
      "PR number non-positive" => target_identity.merge("number" => 0),
      "head SHA moved" => changed_head.call("sha" => "b" * 40),
      "head SHA missing" => changed_head.call("sha" => nil),
      "head ref moved" => changed_head.call("ref" => "other-feature"),
      "head ref blank" => changed_head.call("ref" => "  "),
      "head repo moved" => changed_repo.call("id" => 9_003),
      "head repo id missing" => changed_repo.call("id" => nil),
      "head repo id non-positive" => changed_repo.call("id" => 0),
      "identity unavailable" => nil
    }

    accepted_invalid_identities = final_identities.filter_map do |label, final_identity|
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        pr_identity: [target_identity, final_identity]
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        invalidated = data.fetch("verdict") == "UNKNOWN" &&
                      data.fetch("scopes").values.all? do |scope|
                        scope.fetch("complete") == false && scope.fetch("state") == "UNKNOWN"
                      end
        label unless invalidated
      end
    end

    assert_empty accepted_invalid_identities
  end

  def test_initial_malformed_or_unavailable_target_identity_emits_unknown_evidence
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    invalid_identities = {
      "missing PR id" => target_identity.reject { |key, _value| key == "id" },
      "wrong PR number" => target_identity.merge("number" => 124),
      "blank head SHA" => target_identity.merge(
        "head" => target_identity.fetch("head").merge("sha" => "  ")
      ),
      "39-character head SHA" => target_identity.merge(
        "head" => target_identity.fetch("head").merge("sha" => "a" * 39)
      ),
      "41-character head SHA" => target_identity.merge(
        "head" => target_identity.fetch("head").merge("sha" => "a" * 41)
      ),
      "64-character head SHA" => target_identity.merge(
        "head" => target_identity.fetch("head").merge("sha" => "a" * 64)
      ),
      "40-character non-hex head SHA" => target_identity.merge(
        "head" => target_identity.fetch("head").merge("sha" => "g" * 40)
      ),
      "blank head ref" => target_identity.merge(
        "head" => target_identity.fetch("head").merge("ref" => "  ")
      ),
      "non-positive head repo id" => target_identity.merge(
        "head" => target_identity.fetch("head").merge(
          "repo" => target_identity.dig("head", "repo").merge("id" => 0)
        )
      ),
      "identity unavailable" => [nil]
    }

    incomplete_initial_identities = invalid_identities.filter_map do |label, identity|
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        pr_identity: identity
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        next label unless status.success?

        data = JSON.parse(out)
        unknown = data.fetch("verdict") == "UNKNOWN" &&
                  data.fetch("scopes").values.all? do |scope|
                    scope.fetch("complete") == false && scope.fetch("state") == "UNKNOWN"
                  end
        label unless unknown
      end
    end

    assert_empty incomplete_initial_identities
  end

  def test_exact_head_actions_fail_closed_for_missing_or_malformed_run_identity
    head = "a" * 40
    valid_run = {
      "id" => 200, "workflow_id" => 20, "event" => "pull_request",
      "run_number" => 4, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "pull_requests" => [],
      "status" => "completed", "conclusion" => "success"
    }
    missing = ->(key) { valid_run.reject { |candidate, _value| candidate == key } }
    changed = ->(key, value) { valid_run.merge(key => value) }
    invalid_runs = {
      "missing workflow_id" => missing.call("workflow_id"),
      "non-integer workflow_id" => changed.call("workflow_id", "20"),
      "non-positive workflow_id" => changed.call("workflow_id", 0),
      "missing event" => missing.call("event"),
      "non-string event" => changed.call("event", 123),
      "blank event" => changed.call("event", "  "),
      "missing run_number" => missing.call("run_number"),
      "non-integer run_number" => changed.call("run_number", "4"),
      "non-positive run_number" => changed.call("run_number", 0),
      "missing run_attempt" => missing.call("run_attempt"),
      "non-integer run_attempt" => changed.call("run_attempt", "1"),
      "non-positive run_attempt" => changed.call("run_attempt", 0),
      "missing id" => missing.call("id"),
      "non-integer id" => changed.call("id", "200"),
      "non-positive id" => changed.call("id", 0),
      "missing head_sha" => missing.call("head_sha"),
      "wrong head_sha" => changed.call("head_sha", "b" * 40),
      "missing head_branch" => missing.call("head_branch"),
      "non-string head_branch" => changed.call("head_branch", 123),
      "blank head_branch" => changed.call("head_branch", "  "),
      "missing head_repository" => missing.call("head_repository"),
      "non-object head_repository" => changed.call("head_repository", "owner/repo"),
      "missing head_repository id" => changed.call("head_repository", {}),
      "non-integer head_repository id" => changed.call("head_repository", { "id" => "9002" }),
      "non-positive head_repository id" => changed.call("head_repository", { "id" => 0 }),
      "missing pull_requests" => missing.call("pull_requests"),
      "non-array pull_requests" => changed.call("pull_requests", {})
    }

    accepted_invalid_runs = invalid_runs.filter_map do |label, run|
      run_id = run["id"]
      runs =
        if run_id
          { run_id.to_s => { run:, jobs: [] } }
        else
          {}
        end
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        exact_actions: [run],
        runs:
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        scope = data.dig("scopes", "github_actions")
        label unless data.fetch("verdict") == "UNKNOWN" &&
                     scope.fetch("state") == "UNKNOWN" &&
                     scope.fetch("complete") == false
      end
    end

    assert_empty accepted_invalid_runs
  end

  def test_exact_head_actions_fail_closed_for_malformed_pull_request_association
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    valid_association = {
      "id" => 5_001, "number" => 123, "url" => "https://api.example/pulls/123",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    missing = ->(key) { valid_association.reject { |candidate, _value| candidate == key } }
    changed = ->(key, value) { valid_association.merge(key => value) }
    changed_head = ->(values) { changed.call("head", valid_association.fetch("head").merge(values)) }
    changed_repo = lambda do |values|
      changed_head.call("repo" => valid_association.dig("head", "repo").merge(values))
    end
    invalid_associations = {
      "non-object association" => "malformed",
      "missing id" => missing.call("id"),
      "non-integer id" => changed.call("id", "5001"),
      "non-positive id" => changed.call("id", 0),
      "missing number" => missing.call("number"),
      "non-integer number" => changed.call("number", "123"),
      "non-positive number" => changed.call("number", 0),
      "missing URL" => missing.call("url"),
      "non-string URL" => changed.call("url", 123),
      "blank URL" => changed.call("url", "  "),
      "missing head" => missing.call("head"),
      "non-object head" => changed.call("head", "feature"),
      "missing head SHA" => changed_head.call("sha" => nil),
      "non-string head SHA" => changed_head.call("sha" => 123),
      "blank head SHA" => changed_head.call("sha" => "  "),
      "missing head ref" => changed_head.call("ref" => nil),
      "non-string head ref" => changed_head.call("ref" => 123),
      "blank head ref" => changed_head.call("ref" => "  "),
      "missing head repo" => changed_head.call("repo" => nil),
      "non-object head repo" => changed_head.call("repo" => "owner/repo"),
      "missing head repo id" => changed_repo.call("id" => nil),
      "non-integer head repo id" => changed_repo.call("id" => "9002"),
      "non-positive head repo id" => changed_repo.call("id" => 0)
    }
    valid_run = {
      "id" => 200, "workflow_id" => 20, "event" => "pull_request",
      "run_number" => 4, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "status" => "completed", "conclusion" => "success"
    }

    accepted_invalid_associations = invalid_associations.filter_map do |label, association|
      run = valid_run.merge("pull_requests" => [association])
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        pr_identity: target_identity,
        exact_actions: [run],
        runs: { "200" => { run:, jobs: [] } }
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        scope = data.dig("scopes", "github_actions")
        label unless data.fetch("verdict") == "UNKNOWN" &&
                     scope.fetch("state") == "UNKNOWN" &&
                     scope.fetch("complete") == false
      end
    end

    assert_empty accepted_invalid_associations
  end

  def test_exact_head_actions_fail_closed_for_malformed_association_head_sha_before_target_filtering
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    target_association = {
      "id" => 5_001, "number" => 123, "url" => "https://api.example/pulls/123",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    other_association = {
      "id" => 5_002, "number" => 456, "url" => "https://api.example/pulls/456",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    invalid_shas = {
      "short" => "short",
      "39-character" => "a" * 39,
      "41-character" => "a" * 41,
      "64-character" => "a" * 64,
      "40-character non-hex" => "g" * 40
    }
    invalid_associations = invalid_shas.flat_map do |sha_label, sha|
      [
        ["target claim with #{sha_label} SHA", target_association],
        ["proven-other PR with #{sha_label} SHA", other_association]
      ].map do |label, association|
        [
          label,
          association.merge("head" => association.fetch("head").merge("sha" => sha))
        ]
      end
    end
    valid_run = {
      "id" => 200, "workflow_id" => 20, "event" => "pull_request",
      "run_number" => 4, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "status" => "completed", "conclusion" => "success"
    }

    accepted_invalid_associations = invalid_associations.filter_map do |label, association|
      run = valid_run.merge("pull_requests" => [association])
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        pr_identity: target_identity,
        exact_actions: [run],
        runs: { "200" => { run:, jobs: [] } }
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        scope = data.dig("scopes", "github_actions")
        label unless data.fetch("verdict") == "UNKNOWN" &&
                     scope.fetch("state") == "UNKNOWN" &&
                     scope.fetch("complete") == false
      end
    end

    assert_empty accepted_invalid_associations
  end

  def test_exact_head_actions_fail_closed_for_contradictory_target_pull_request_association
    head = "a" * 40
    target_identity = {
      "id" => 5_001, "number" => 123,
      "head" => {
        "sha" => head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    target_association = {
      "id" => 5_001, "number" => 123, "url" => "https://api.example/pulls/123",
      "head" => { "sha" => head, "ref" => "feature", "repo" => { "id" => 9_002 } }
    }
    changed_head = lambda do |values|
      target_association.merge("head" => target_association.fetch("head").merge(values))
    end
    changed_repo = lambda do |values|
      changed_head.call("repo" => target_association.dig("head", "repo").merge(values))
    end
    contradictory_associations = {
      "target PR with conflicting head SHA" => changed_head.call("sha" => "b" * 40),
      "target PR with conflicting head ref" => changed_head.call("ref" => "other-feature"),
      "target PR with conflicting head repo id" => changed_repo.call("id" => 9_003),
      "target id with another PR number" => target_association.merge("number" => 456),
      "target number with another PR id" => target_association.merge("id" => 5_002)
    }
    valid_run = {
      "id" => 200, "workflow_id" => 20, "event" => "pull_request",
      "run_number" => 4, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "status" => "completed", "conclusion" => "success"
    }

    accepted_contradictions = contradictory_associations.filter_map do |label, association|
      run = valid_run.merge("pull_requests" => [association])
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        pr_identity: target_identity,
        exact_actions: [run],
        runs: { "200" => { run:, jobs: [] } }
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        scope = data.dig("scopes", "github_actions")
        label unless data.fetch("verdict") == "UNKNOWN" &&
                     scope.fetch("state") == "UNKNOWN" &&
                     scope.fetch("complete") == false
      end
    end

    assert_empty accepted_contradictions
  end

  def test_target_identity_head_movement_marks_every_evidence_scope_incomplete
    original_head = "a" * 40
    moved_head = "b" * 40
    original_identity = {
      "id" => 9_001, "number" => 123,
      "head" => {
        "sha" => original_head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    moved_identity = {
      "id" => 9_001, "number" => 123,
      "head" => {
        "sha" => moved_head, "ref" => "feature",
        "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
      }
    }
    with_fake_gh(
      required_json: "[]",
      full_json: '[{"workflow":"CI","name":"advisory","bucket":"pass"}]',
      pr_head: original_head,
      pr_identity: [original_identity, moved_identity]
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      data.fetch("scopes").each do |name, scope|
        assert_equal false, scope.fetch("complete"), name
        assert_equal "UNKNOWN", scope.fetch("state"), name
        assert_includes scope.fetch("error"), "target PR identity moved during exact-head inventory", name
        assert_includes scope.fetch("error"), original_head, name
        assert_includes scope.fetch("error"), moved_head, name
      end
      assert_empty data.dig("scopes", "required_status_check_rollup", "rows")
    end
  end

  def test_optional_disposition_owns_fallback_verdict_when_required_inventory_is_empty
    head = "a" * 40
    with_optional_policy_repo do |root, base_sha|
      pr_identity = {
        "id" => 9_001, "number" => 123,
        "head" => {
          "sha" => head, "ref" => "feature",
          "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
        },
        "base" => {
          "sha" => base_sha, "ref" => "main",
          "repo" => { "id" => 9_003, "full_name" => "owner/repo" }
        }
      }
      workflow_id = "ac163d39-bfa6-4c1d-9daa-5dff74e2200a"
      details_url = "https://app.circleci.com/workflow/#{workflow_id}?utm_campaign=vcs-integration-link&" \
                    "utm_medium=referral&utm_content=bottom&utm_source=github-checks-link"
      summary_url = "https://app.circleci.com/workflow/#{workflow_id}?utm_campaign=vcs-integration-link&" \
                    "utm_medium=referral&utm_content=summary&utm_source=github-checks-link"
      job_url = "https://app.circleci.com/workflow/#{workflow_id}?utm_campaign=vcs-integration-link&" \
                "utm_medium=referral&utm_source=github-checks-link"
      held = {
        "id" => 31, "name" => "storybook-review-app", "status" => "in_progress",
        "conclusion" => nil, "started_at" => "2026-08-24T08:07:48Z", "completed_at" => nil,
        "head_sha" => head, "app" => { "slug" => "circleci-checks" }, "actions" => nil,
        "details_url" => details_url,
        "output" => {
          "title" => "Workflow: storybook-review-app",
          "summary" => "[View CircleCI Workflow](#{summary_url})\n\n" \
                       "* [start](#{job_url}) - Blocked\n" \
                       "* build-storybook-review-app - Blocked\n"
        },
        "html_url" => "https://example/check/31"
      }
      held_rollup = {
        "workflow" => "", "name" => "storybook-review-app", "bucket" => "pending",
        "state" => "IN_PROGRESS", "link" => details_url
      }
      with_fake_gh(
        required_json: "",
        full_json: JSON.generate([held_rollup]),
        pr_head: head,
        pr_identity:,
        exact_check_runs: [held]
      ) do |env|
        out, status = run_script(
          env, "123", "--repo", "owner/repo", "--trusted-repo-root", root
        )
        assert status.success?, out
        data = JSON.parse(out)

        assert_equal "READY", data.fetch("verdict"), data.inspect
        assert_equal "READY", data.fetch("ordinary_verdict")
        assert_equal "READY", data.dig("scopes", "other", "state")
        refute_empty data.dig("scopes", "other", "policy_dispositions")
      end

      graphql_only_pending = {
        "workflow" => "external-ci", "name" => "security", "bucket" => "pending",
        "state" => "IN_PROGRESS", "link" => "https://example/check/32"
      }
      with_fake_gh(
        required_json: "",
        full_json: JSON.generate([held_rollup, graphql_only_pending]),
        pr_head: head,
        pr_identity:,
        exact_check_runs: [held]
      ) do |env|
        out, status = run_script(
          env, "123", "--repo", "owner/repo", "--trusted-repo-root", root
        )
        assert status.success?, out
        data = JSON.parse(out)

        assert_equal "NOT_READY", data.fetch("verdict")
        assert_equal "NOT_READY", data.fetch("ordinary_verdict")
        assert_equal "READY", data.dig("scopes", "other", "state")
        refute_empty data.dig("scopes", "other", "policy_dispositions")
      end

      running = {
        "id" => 32, "name" => "security", "status" => "in_progress",
        "conclusion" => nil, "started_at" => "2026-07-30T11:58:00Z", "head_sha" => head,
        "app" => { "slug" => "external-ci" }, "html_url" => "https://example/check/32"
      }
      with_fake_gh(
        required_json: "",
        full_json: JSON.generate([held_rollup, graphql_only_pending]),
        pr_head: head,
        pr_identity:,
        exact_check_runs: [held, running]
      ) do |env|
        out, status = run_script(
          env, "123", "--repo", "owner/repo", "--trusted-repo-root", root
        )
        assert status.success?, out
        data = JSON.parse(out)

        assert_equal "NOT_READY", data.fetch("verdict")
        assert_equal "NOT_READY", data.dig("scopes", "other", "state")
        assert_equal 1, data.dig("scopes", "other", "policy_dispositions").length
      end
    end
  end

  def test_optional_disposition_cannot_override_an_unrelated_invalid_check_bucket
    head = "a" * 40
    with_optional_policy_repo do |root, base_sha|
      pr_identity = {
        "id" => 9_001, "number" => 123,
        "head" => {
          "sha" => head, "ref" => "feature",
          "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
        },
        "base" => {
          "sha" => base_sha, "ref" => "main",
          "repo" => { "id" => 9_003, "full_name" => "owner/repo" }
        }
      }
      workflow_url = "https://app.circleci.com/workflow/00000000-0000-4000-8000-000000000031"
      exact_held = {
        "id" => 31, "name" => "storybook-review-app", "status" => "in_progress",
        "conclusion" => nil, "started_at" => "2026-08-24T08:07:48Z", "completed_at" => nil,
        "head_sha" => head, "app" => { "slug" => "circleci-checks" }, "actions" => nil,
        "details_url" => workflow_url,
        "output" => {
          "title" => "Workflow: storybook-review-app",
          "summary" => "[View CircleCI Workflow](#{workflow_url})\n\n* start - Blocked\n"
        },
        "html_url" => "https://example/check/31"
      }
      with_fake_gh(
        required_json: "",
        full_json: '[{"workflow":"circleci-checks","name":"storybook-review-app","bucket":"pending"},' \
                   '{"workflow":"external-ci","name":"mystery","bucket":"future-state"}]',
        pr_head: head,
        pr_identity:,
        exact_check_runs: [exact_held]
      ) do |env|
        out, status = run_script(
          env, "123", "--repo", "owner/repo", "--trusted-repo-root", root
        )
        assert status.success?, out
        data = JSON.parse(out)

        assert_equal "NOT_READY", data.fetch("verdict"), data.inspect
        assert_equal "NOT_READY", data.fetch("ordinary_verdict")
        assert_equal ['mystery (bucket: "future-state")'], data.fetch("invalid")
        refute_empty data.dig("scopes", "other", "policy_dispositions")
      end
    end
  end

  def test_optional_disposition_fails_closed_when_required_inventory_changes_during_assessment
    head = "a" * 40
    with_optional_policy_repo do |root, base_sha|
      identity = {
        "id" => 9_001, "number" => 123,
        "head" => {
          "sha" => head, "ref" => "feature",
          "repo" => { "id" => 9_002, "full_name" => "owner/repo" }
        },
        "base" => {
          "sha" => base_sha, "ref" => "main",
          "repo" => { "id" => 9_003, "full_name" => "owner/repo" }
        }
      }
      held = {
        "id" => 31, "name" => "storybook-review-app", "status" => "in_progress",
        "conclusion" => nil, "started_at" => nil, "head_sha" => head,
        "app" => { "slug" => "circleci-checks" }, "html_url" => "https://example/check/31"
      }
      required = {
        "workflow" => "circleci-checks", "name" => "storybook-review-app", "bucket" => "pending"
      }
      with_fake_gh(
        required_json: ["[]", JSON.generate([required])],
        full_json: JSON.generate([required]),
        pr_head: head, pr_identity: identity, exact_check_runs: [held]
      ) do |env|
        out, status = run_script(
          env, "123", "--repo", "owner/repo", "--trusted-repo-root", root
        )
        assert status.success?, out
        data = JSON.parse(out)

        assert_equal "NOT_READY", data.fetch("verdict")
        assert_equal false, data.dig("scopes", "required_status_check_rollup", "complete")
        assert_includes data.dig("scopes", "required_status_check_rollup", "error"),
                        "required-check inventory changed during exact-head assessment"
      end
    end
  end

  def test_duplicate_combined_status_contexts_fail_closed_case_insensitively
    head = "a" * 40
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_statuses: [
        {
          "id" => 400, "context" => "legacy", "state" => "success",
          "target_url" => "https://example/status/400"
        },
        {
          "id" => 397, "context" => "Legacy", "state" => "success",
          "target_url" => "https://example/status/397"
        }
      ]
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
      assert_equal "UNKNOWN", data.dig("scopes", "other", "state")
      assert_empty data.dig("scopes", "other", "rows")
      assert_includes data.dig("scopes", "other", "error"), "repeated case-insensitive context"
    end
  end

  def test_commit_status_inventory_change_during_assessment_fails_closed
    head = "a" * 40
    success = {
      "id" => 400, "context" => "legacy", "state" => "success",
      "target_url" => "https://example/status/400"
    }
    failure = success.merge("id" => 401, "state" => "failure")
    snapshots = [success, failure].map do |row|
      {
        "sha" => head, "state" => row.fetch("state"),
        "total_count" => 1, "statuses" => [row]
      }
    end

    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]", pr_head: head, exact_status_snapshots: snapshots
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
      assert_includes data.dig("scopes", "other", "error"),
                      "commit-status inventory changed during exact-head assessment"
    end
  end

  def test_unknown_combined_commit_status_fails_closed
    head = "a" * 40
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_statuses: [
        {
          "id" => 500, "context" => "legacy", "state" => "mystery",
          "target_url" => "https://example/status/500"
        },
        {
          "id" => 498, "context" => "distinct", "state" => "success",
          "target_url" => "https://example/status/498"
        }
      ]
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
      assert_equal "UNKNOWN", data.dig("scopes", "other", "state")
      assert_empty data.dig("scopes", "other", "rows")
      assert_includes data.dig("scopes", "other", "error"), "invalid status state"
    end
  end

  # Deterministic replay of shakacode/hichee-data#431: Azure check runs were
  # exact-head green and CodeRabbit's commit-status row omitted `sha`. The
  # combined-status envelope still binds the inventory to the requested head.
  def test_hichee_data_431_status_row_without_sha_replays_ready
    head = HICHEE_DATA_431_HEAD
    coderabbit_status = {
      "id" => 431_001, "context" => "CodeRabbit", "state" => "success",
      "target_url" => "https://example.test/status/431001"
    }
    azure_check_runs = [
      {
        "id" => 2_770_001, "name" => "Azure Pipelines / build",
        "status" => "completed", "conclusion" => "success", "head_sha" => head,
        "app" => { "slug" => "azure-pipelines" },
        "html_url" => "https://example.test/check/2770001"
      },
      {
        "id" => 2_770_002, "name" => "Azure Pipelines / test",
        "status" => "completed", "conclusion" => "success", "head_sha" => head,
        "app" => { "slug" => "azure-pipelines" },
        "html_url" => "https://example.test/check/2770002"
      }
    ]
    refute coderabbit_status.key?("sha")

    with_fake_gh(
      required_json: '[{"workflow":"UNKNOWN","name":"Azure Pipelines / build","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      pr_identity: hichee_data_431_identity,
      exact_check_runs: azure_check_runs,
      exact_statuses: [coderabbit_status]
    ) do |env|
      out, status = run_script(env, "431", "--repo", "shakacode/hichee-data")
      assert status.success?, out
      data = JSON.parse(out)
      other = data.fetch("scopes").fetch("other")

      refute other.key?("error"), other.inspect
      assert_equal true, other.fetch("complete")
      assert_equal head, other.fetch("head_sha")
      assert_equal(
        [
          [2_770_001, "Azure Pipelines / build", "completed", "success", nil],
          [2_770_002, "Azure Pipelines / test", "completed", "success", nil],
          [431_001, "CodeRabbit", nil, nil, "success"]
        ],
        other.fetch("rows").map { |row| row.values_at("id", "name", "status", "conclusion", "state") }
      )
      assert_equal "READY", data.fetch("ordinary_verdict")
      assert_equal "READY", other.fetch("state")
      assert_equal true, data.dig("viewer_review_inventory", "complete")
      assert_empty data.fetch("viewer_pending_review_drafts")
      assert_equal "READY", data.fetch("verdict")
    end
  end

  def test_combined_commit_status_without_sha_fails_closed
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "a" * 40,
      exact_status_sha: nil,
      exact_statuses: [
        { "id" => 601, "context" => "CodeRabbit", "state" => "success",
          "target_url" => "https://example/status/601" }
      ]
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      other = data.fetch("scopes").fetch("other")

      assert_equal false, other.fetch("complete")
      assert_equal "UNKNOWN", other.fetch("state")
      assert_empty other.fetch("rows")
      assert_includes other.fetch("error"), "combined commit status was not bound to exact head"
      assert_includes other.fetch("error"), "found missing"
      assert_equal "UNKNOWN", data.fetch("verdict")
    end
  end

  def test_hichee_data_431_wrong_combined_status_ref_remains_unknown
    head = HICHEE_DATA_431_HEAD
    other_head = "b" * 40
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      pr_identity: hichee_data_431_identity,
      exact_status_sha: other_head,
      exact_statuses: [
        { "id" => 602, "context" => "CodeRabbit", "state" => "success",
          "target_url" => "https://example/status/602" }
      ]
    ) do |env|
      out, status = run_script(env, "431", "--repo", "shakacode/hichee-data")
      assert status.success?, out
      data = JSON.parse(out)

      other = data.fetch("scopes").fetch("other")

      assert_equal false, other.fetch("complete")
      assert_equal "UNKNOWN", other.fetch("state")
      assert_empty other.fetch("rows")
      assert_includes other.fetch("error"), "combined commit status was not bound to exact head #{head}"
      assert_includes other.fetch("error"), other_head
      assert_equal "UNKNOWN", data.fetch("verdict")
    end
  end

  def test_hichee_data_431_status_row_with_contradictory_sha_remains_unknown
    head = HICHEE_DATA_431_HEAD
    other_head = "b" * 40
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      pr_identity: hichee_data_431_identity,
      exact_statuses: [
        {
          "id" => 603, "context" => "CodeRabbit", "state" => "success",
          "sha" => other_head, "target_url" => "https://example/status/603"
        }
      ]
    ) do |env|
      out, status = run_script(env, "431", "--repo", "shakacode/hichee-data")
      assert status.success?, out
      data = JSON.parse(out)
      other = data.fetch("scopes").fetch("other")

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, other.fetch("complete")
      assert_equal "UNKNOWN", other.fetch("state")
      assert_empty other.fetch("rows")
      assert_includes other.fetch("error"), "status context contradicted exact head #{head}"
      assert_includes other.fetch("error"), other_head
    end
  end

  def test_hichee_data_431_status_row_with_matching_sha_remains_ready
    head = HICHEE_DATA_431_HEAD
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      pr_identity: hichee_data_431_identity,
      exact_statuses: [
        {
          "id" => 604, "context" => "CodeRabbit", "state" => "success",
          "sha" => head, "target_url" => "https://example/status/604"
        }
      ]
    ) do |env|
      out, status = run_script(env, "431", "--repo", "shakacode/hichee-data")
      assert status.success?, out
      data = JSON.parse(out)
      other = data.fetch("scopes").fetch("other")

      assert_equal "READY", data.fetch("verdict")
      assert_equal true, other.fetch("complete")
      assert_equal "READY", other.fetch("state")
      normalized_rows = other.fetch("rows").map { |row| row.values_at("id", "name", "state") }
      assert_equal [[604, "CodeRabbit", "success"]], normalized_rows
    end
  end

  def test_partial_combined_status_page_is_unknown_not_complete
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "a" * 40,
      exact_status_total_count: 2,
      exact_statuses: [
        { "id" => 603, "context" => "CodeRabbit", "state" => "success",
          "target_url" => "https://example/status/603" }
      ]
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      other = data.fetch("scopes").fetch("other")

      assert_equal false, other.fetch("complete")
      assert_equal "UNKNOWN", other.fetch("state")
      assert_includes other.fetch("error"), "statuses pagination was incomplete"
      assert_equal "UNKNOWN", data.fetch("verdict")
    end
  end

  def test_duplicate_context_reordered_onto_second_combined_status_page_fails_closed
    head = "a" * 40
    first_page = Array.new(100) do |index|
      { "id" => index + 1, "context" => "status-#{index}", "state" => "success",
        "target_url" => "https://example/status/#{index + 1}" }
    end
    second_page = [
      { "id" => 101, "context" => "STATUS-0", "state" => "success",
        "target_url" => "https://example/status/101" }
    ]
    pages = [first_page, second_page].map do |statuses|
      { "sha" => head, "state" => "success", "total_count" => 101, "statuses" => statuses }
    end
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_status_pages: pages
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
      assert_empty data.dig("scopes", "other", "rows")
      assert_includes data.dig("scopes", "other", "error"), "repeated case-insensitive context"
    end
  end

  def test_changed_combined_state_on_second_status_page_fails_closed
    head = "a" * 40
    first_page = Array.new(100) do |index|
      { "id" => index + 1, "context" => "status-#{index}", "state" => "success",
        "target_url" => "https://example/status/#{index + 1}" }
    end
    pages = [
      { "sha" => head, "state" => "success", "total_count" => 101, "statuses" => first_page },
      {
        "sha" => head, "state" => "pending", "total_count" => 101,
        "statuses" => [
          { "id" => 101, "context" => "status-100", "state" => "success",
            "target_url" => "https://example/status/101" }
        ]
      }
    ]
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_status_pages: pages
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
      assert_empty data.dig("scopes", "other", "rows")
      assert_includes data.dig("scopes", "other", "error"), "state changed during pagination"
    end
  end

  # Regression for #287: `fetch_paginated_collection` calls
  # `validate_page&.call(payload)` unconditionally on every page, so the
  # combined-status envelope's top-level `sha` should be asserted on page 2
  # and beyond, not just page 1. The two existing single-page fixtures above
  # (and `test_combined_commit_status_without_sha_fails_closed` /
  # `test_hichee_data_431_wrong_combined_status_ref_remains_unknown`) only
  # ever exercised a single page, so nothing proved the hook re-fires past
  # its first call. This drives a well-formed 100-row first page (accepted)
  # followed by a second page whose envelope `sha` is mismatched or missing
  # entirely -- if the hook only ran once, neither defect would be caught and
  # the run would incorrectly finish READY.
  def test_combined_status_validate_page_hook_fires_on_every_page_not_just_the_first
    head = "a" * 40
    page_one = Array.new(100) do |index|
      { "id" => index + 1, "context" => "status-#{index}", "state" => "success",
        "target_url" => "https://example/status/#{index + 1}" }
    end
    page_two_statuses = [
      { "id" => 101, "context" => "status-100", "state" => "success",
        "target_url" => "https://example/status/101" }
    ]
    bad_second_pages = {
      "mismatched sha on page 2" => {
        "sha" => "b" * 40, "state" => "success", "total_count" => 101, "statuses" => page_two_statuses
      },
      "missing sha on page 2" => {
        "state" => "success", "total_count" => 101, "statuses" => page_two_statuses
      }
    }

    accepted_bad_pages = bad_second_pages.filter_map do |label, bad_page_two|
      pages = [
        { "sha" => head, "state" => "success", "total_count" => 101, "statuses" => page_one },
        bad_page_two
      ]
      with_fake_gh(
        required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
        full_json: "[]",
        pr_head: head,
        exact_status_pages: pages
      ) do |env|
        out, status = run_script(env, "123", "--repo", "owner/repo")
        assert status.success?, out
        data = JSON.parse(out)
        other = data.dig("scopes", "other")
        failed_closed = data.fetch("verdict") == "UNKNOWN" &&
                        other.fetch("complete") == false &&
                        other.fetch("rows").empty? &&
                        other.fetch("error").include?("combined commit status was not bound to exact head #{head}")
        label unless failed_closed
      end
    end

    assert_empty accepted_bad_pages
  end

  # Follow-up from the #287 review comment: a page can be structurally
  # malformed -- a JSON array instead of an object -- rather than merely
  # missing/mismatching `sha`. `fetch_paginated_collection` already fails
  # closed on this ("... response was not an object") before `validate_page`
  # even runs; this is direct regression coverage for that branch on the
  # combined commit status endpoint specifically, proven on the second page
  # so it cannot be satisfied by only validating the first response.
  def test_combined_status_second_page_returning_json_array_fails_closed
    head = "a" * 40
    page_one = Array.new(100) do |index|
      { "id" => index + 1, "context" => "status-#{index}", "state" => "success",
        "target_url" => "https://example/status/#{index + 1}" }
    end
    pages = [
      { "sha" => head, "state" => "success", "total_count" => 101, "statuses" => page_one },
      %w[not an object]
    ]
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_status_pages: pages
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
      assert_empty data.dig("scopes", "other", "rows")
      assert_includes data.dig("scopes", "other", "error"), "statuses response was not an object"
    end
  end

  def test_single_page_combined_state_inconsistent_with_statuses_fails_closed
    head = "a" * 40
    pages = [{
      "sha" => head,
      "state" => "success",
      "total_count" => 1,
      "statuses" => [
        { "id" => 101, "context" => "status-100", "state" => "pending",
          "target_url" => "https://example/status/101" }
      ]
    }]
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_status_pages: pages
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
      assert_empty data.dig("scopes", "other", "rows")
      assert_includes data.dig("scopes", "other", "error"),
                      "state was inconsistent with its statuses"
    end
  end

  def test_large_exact_status_fixture_does_not_deadlock_fake_gh
    head = "a" * 40
    exact_statuses = Array.new(99) do |index|
      {
        "id" => index + 1,
        "context" => "status-#{index}",
        "state" => "success",
        "target_url" => "https://example.test/#{index}/#{'x' * 2_000}"
      }
    end
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_statuses:
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "READY", data.fetch("verdict")
      assert_equal 99, data.dig("scopes", "other", "rows").length
    end
  end

  def test_large_exact_status_fixture_uses_shell_safe_printf
    exact_statuses = [{
      "id" => 1,
      "context" => "large-status",
      "state" => "success",
      "target_url" => "https://example.test/#{'x' * 100_000}"
    }]
    expected_command = "printf '%s' #{JSON.generate(exact_statuses).inspect}"
    with_fake_gh(
      required_json: "[]",
      full_json: "[]",
      exact_statuses:
    ) do |env|
      fake_gh = File.join(env.fetch("PATH").split(File::PATH_SEPARATOR).first, "gh")
      generated_script = File.read(fake_gh, encoding: "UTF-8")
      status_branch = generated_script[
        %r{if \[\[ "\$\*" = \*"/status\?per_page="\* \]\]; then.*?exit 0}m
      ]

      assert_includes status_branch, expected_command
      refute_includes status_branch, "cat <<'JSON'"
    end
  end

  def test_partial_exact_head_actions_page_is_unknown_not_complete
    head = "a" * 40
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_actions: [{
        "id" => 100, "workflow_id" => 10, "event" => "pull_request",
        "run_number" => 1, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
        "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
        "pull_requests" => [],
        "status" => "completed", "conclusion" => "success",
        "actor" => { "login" => "octocat" }
      }],
      runs: {
        "100" => {
          run: {
            "id" => 100, "workflow_id" => 10, "event" => "pull_request",
            "run_number" => 1, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
            "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
            "pull_requests" => [],
            "status" => "completed", "conclusion" => "success"
          },
          jobs: []
        }
      },
      exact_actions_total_count: 2
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal "UNKNOWN", data.dig("scopes", "github_actions", "state")
      assert_equal false, data.dig("scopes", "github_actions", "complete")
      assert_includes data.dig("scopes", "github_actions", "error"), "incomplete"
    end
  end

  def test_partial_exact_head_actions_jobs_are_unknown_not_complete
    head = "a" * 40
    action_run = {
      "id" => 100, "workflow_id" => 10, "event" => "pull_request",
      "run_number" => 1, "run_attempt" => 1, "name" => "CI", "head_sha" => head,
      "head_branch" => "feature", "head_repository" => { "id" => 9_002 },
      "pull_requests" => [],
      "status" => "completed", "conclusion" => "success",
      "actor" => { "login" => "octocat" }
    }
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"required","bucket":"pass"}]',
      full_json: "[]",
      pr_head: head,
      exact_actions: [action_run],
      runs: {
        "100" => {
          run: action_run,
          jobs: [{
            "id" => 1000, "name" => "unit", "status" => "completed",
            "conclusion" => "success"
          }],
          jobs_total_count: 2
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "github_actions", "complete")
      assert_includes data.dig("scopes", "github_actions", "error"), "incomplete"
    end
  end

  def test_pending_current_head_review_drafts_block_ready_checks
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "3f67da47c44b7f403c72be2ed8f5bf4505666974",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [
                    { "id" => "PRR_one", "state" => "PENDING", "submittedAt" => nil,
                      "commit" => { "oid" => "3f67da47c44b7f403c72be2ed8f5bf4505666974" } },
                    { "id" => "PRR_two", "state" => "PENDING", "submittedAt" => nil,
                      "commit" => { "oid" => "3f67da47c44b7f403c72be2ed8f5bf4505666974" } }
                  ],
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal(%w[PRR_one PRR_two], data.fetch("viewer_pending_review_drafts").map { |review| review["id"] })
      assert_equal "authenticated_viewer", data.fetch("viewer_review_inventory").fetch("scope")
    end
  end

  def test_pending_review_draft_inventory_fails_closed_when_snapshot_changes_during_assessment
    head = "3f67da47c44b7f403c72be2ed8f5bf4505666974"
    review_payload = lambda do |nodes|
      {
        "data" => {
          "repository" => {
            "pullRequest" => {
              "reviews" => {
                "nodes" => nodes,
                "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
              }
            }
          }
        }
      }
    end
    late_draft = {
      "id" => "PRR_late", "state" => "PENDING", "submittedAt" => nil,
      "commit" => { "oid" => head }
    }
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]', full_json: "[]", pr_head: head,
      review_pages: { nil => [review_payload.call([]), review_payload.call([late_draft])] }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)

      assert_equal "NOT_READY", data.fetch("verdict")
      draft_ids = data.fetch("viewer_pending_review_drafts").map { |row| row.fetch("id") }
      assert_equal ["PRR_late"], draft_ids
      assert_equal false, data.dig("viewer_review_inventory", "complete")
      assert_includes data.dig("viewer_review_inventory", "error"), "changed during assessment"
    end
  end

  def test_review_draft_inventory_uses_outer_authenticated_head_during_transient_head_change
    outer_head = "3f67da47c44b7f403c72be2ed8f5bf4505666974"
    transient_head = "4f67da47c44b7f403c72be2ed8f5bf4505666975"
    identity = hichee_data_431_identity.merge(
      "head" => hichee_data_431_identity.fetch("head").merge("sha" => outer_head)
    )
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: transient_head,
      pr_identity: [identity, identity],
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [
                    { "id" => "PRR_outer", "state" => "PENDING", "submittedAt" => nil,
                      "commit" => { "oid" => outer_head } }
                  ],
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "431", "--repo", "shakacode/hichee-data")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data.fetch("verdict")
      assert_equal(
        ["PRR_outer"], data.fetch("viewer_pending_review_drafts").map { |row| row.fetch("id") }
      )
    end
  end

  def test_requested_run_uses_outer_authenticated_head_during_transient_head_change
    outer_head = "3f67da47c44b7f403c72be2ed8f5bf4505666974"
    transient_head = "4f67da47c44b7f403c72be2ed8f5bf4505666975"
    identity = hichee_data_431_identity.merge(
      "head" => hichee_data_431_identity.fetch("head").merge("sha" => outer_head)
    )
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      pr_head: transient_head,
      pr_identity: [identity, identity],
      runs: {
        "100" => {
          run: {
            "id" => 100, "name" => "requested", "head_sha" => transient_head,
            "status" => "completed", "conclusion" => "success",
            "html_url" => "https://github.com/shakacode/hichee-data/actions/runs/100"
          },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(
        env, "431", "--repo", "shakacode/hichee-data", "--requested-hosted-run", "100"
      )
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal(
        ["100"], data.dig("requested_hosted", "stale").map { |row| row.fetch("run_id") }
      )
    end
  end

  def test_requested_run_payload_id_must_match_requested_id
    head = "3f67da47c44b7f403c72be2ed8f5bf4505666974"
    identity = hichee_data_431_identity.merge(
      "head" => hichee_data_431_identity.fetch("head").merge("sha" => head)
    )
    with_fake_gh(
      required_json: "", full_json: "[]", pr_head: head,
      pr_identity: [identity, identity],
      runs: {
        "100" => {
          run: {
            "id" => 999, "name" => "wrong-run", "head_sha" => head,
            "status" => "completed", "conclusion" => "success",
            "html_url" => "https://github.com/shakacode/hichee-data/actions/runs/999"
          },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(
        env, "431", "--repo", "shakacode/hichee-data", "--requested-hosted-run", "100"
      )
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_includes data.dig("requested_hosted", "unknown", 0, "reason"), "id"
    end
  end

  def test_malformed_successful_check_run_makes_exact_inventory_unknown
    head = "3f67da47c44b7f403c72be2ed8f5bf4505666974"
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]', full_json: "[]", pr_head: head,
      exact_check_runs: [
        { "id" => nil, "name" => nil, "head_sha" => head, "app" => nil,
          "status" => "completed", "conclusion" => "success" }
      ]
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data.fetch("verdict")
      assert_equal false, data.dig("scopes", "other", "complete")
    end
  end

  def test_exact_check_inventory_does_not_use_capped_git_ref_runs_endpoint
    runner = PrCiReadiness::Runner.new
    endpoints = []
    runner.define_singleton_method(:fetch_paginated_collection) do |endpoint, _key, validate_page: nil|
      endpoints << endpoint
      _validate_page = validate_page
      []
    end

    runner.send(:fetch_exact_head_check_runs, "owner/repo", "a" * 40)

    refute(endpoints.any? do |endpoint|
      endpoint.include?("/commits/") && endpoint.include?("/check-runs")
    end)
  end

  def test_check_suite_inventory_fails_closed_when_queued_placeholder_appears_during_materialization
    head = "a" * 40
    initial_suite = {
      "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
      "updated_at" => "2026-08-25T10:00:00Z",
      "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
      "status" => "completed", "conclusion" => "success", "latest_check_runs_count" => 1
    }
    late_suite = initial_suite.merge(
      "id" => 20, "created_at" => "2026-08-25T12:00:00Z",
      "updated_at" => "2026-08-25T12:00:00Z",
      "app" => { "id" => 19, "slug" => "dormant-app" },
      "status" => "queued", "conclusion" => nil, "latest_check_runs_count" => 0
    )
    suite_fetches = 0
    runner = PrCiReadiness::Runner.new
    runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
      _validate_page = validate_page
      if key == "check_suites"
        suite_fetches += 1
        suite_fetches == 1 ? [initial_suite] : [initial_suite, late_suite]
      else
        [{
          "id" => 100, "name" => "build", "head_sha" => head,
          "status" => "completed", "conclusion" => "success",
          "started_at" => "2026-08-25T10:00:00Z", "html_url" => "",
          "app" => initial_suite.fetch("app"), "check_suite" => { "id" => 10 }
        }]
      end
    end

    rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

    refute complete
    assert_empty rows
    assert_includes error, "changed during run materialization"
    assert_equal 2, suite_fetches
  end

  def test_check_suite_snapshot_is_order_independent_and_multiplicity_preserving
    head = "a" * 40
    suites = [10, 20].map do |suite_id|
      {
        "id" => suite_id, "created_at" => "2026-08-25T#{suite_id}:00:00Z",
        "updated_at" => "2026-08-25T#{suite_id}:00:00Z",
        "head_sha" => head, "app" => { "id" => suite_id, "slug" => "ci-#{suite_id}" },
        "status" => "completed", "conclusion" => "success", "latest_check_runs_count" => 1
      }
    end
    { reordered: suites.reverse, duplicated: [suites.first, suites.last, suites.last] }.each do |label, final|
      suite_fetches = 0
      runner = PrCiReadiness::Runner.new
      runner.define_singleton_method(:fetch_paginated_collection) do |endpoint, key, validate_page: nil|
        _validate_page = validate_page
        if key == "check_suites"
          suite_fetches += 1
          suite_fetches == 1 ? suites : final
        else
          suite_id = endpoint[%r{/check-suites/(\d+)/}, 1].to_i
          suite = suites.find { |row| row.fetch("id") == suite_id }
          [{
            "id" => suite_id * 10, "name" => "build", "head_sha" => head,
            "status" => "completed", "conclusion" => "success",
            "started_at" => "2026-08-25T10:00:00Z", "html_url" => "",
            "app" => suite.fetch("app"), "check_suite" => { "id" => suite_id }
          }]
        end
      end

      rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

      if label == :reordered
        assert complete, error
        assert_equal [100, 200], rows.map { |row| row.fetch("id") }.sort
      else
        refute complete
        assert_empty rows
        assert_includes error, "changed during run materialization"
      end
    end
  end

  def test_check_run_snapshot_fails_closed_when_phase_changes_after_suite_materialization
    head = "a" * 40
    suite = {
      "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
      "updated_at" => "2026-08-25T10:00:00Z",
      "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
      "status" => "completed", "conclusion" => "success", "latest_check_runs_count" => 1
    }
    successful_run = {
      "id" => 100, "name" => "build", "head_sha" => head,
      "status" => "completed", "conclusion" => "success",
      "started_at" => "2026-08-25T10:00:00Z", "html_url" => "",
      "app" => suite.fetch("app"), "check_suite" => { "id" => 10 }
    }
    changed_run = successful_run.merge("conclusion" => "neutral")
    suite_fetches = 0
    run_fetches = 0
    runner = PrCiReadiness::Runner.new
    runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
      _validate_page = validate_page
      if key == "check_suites"
        suite_fetches += 1
        [suite]
      else
        run_fetches += 1
        [run_fetches == 1 ? successful_run : changed_run]
      end
    end

    rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

    refute complete
    assert_empty rows
    assert_includes error, "check-run inventory changed during final verification"
    assert_equal 3, suite_fetches
    assert_equal 2, run_fetches
  end

  def test_check_suite_snapshot_fails_closed_when_suite_appears_during_final_run_materialization
    head = "a" * 40
    initial_suite = {
      "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
      "updated_at" => "2026-08-25T10:00:00Z",
      "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
      "status" => "completed", "conclusion" => "success", "latest_check_runs_count" => 1
    }
    late_suite = initial_suite.merge(
      "id" => 20, "created_at" => "2026-08-25T12:00:00Z",
      "updated_at" => "2026-08-25T12:00:00Z",
      "status" => "in_progress", "conclusion" => nil, "latest_check_runs_count" => 0
    )
    suite_fetches = 0
    run_fetches = 0
    runner = PrCiReadiness::Runner.new
    runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
      _validate_page = validate_page
      if key == "check_suites"
        suite_fetches += 1
        suite_fetches < 3 ? [initial_suite] : [initial_suite, late_suite]
      else
        run_fetches += 1
        [{
          "id" => 100, "name" => "build", "head_sha" => head,
          "status" => "completed", "conclusion" => "success",
          "started_at" => "2026-08-25T10:00:00Z", "html_url" => "",
          "app" => initial_suite.fetch("app"), "check_suite" => { "id" => 10 }
        }]
      end
    end

    rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

    refute complete
    assert_empty rows
    assert_includes error, "changed during final verification"
    assert_equal 3, suite_fetches
    assert_equal 2, run_fetches
  end

  def test_check_suite_inventory_preserves_same_name_rows_from_distinct_suites
    head = "a" * 40
    %w[success failure].each do |latest_conclusion|
      runner = PrCiReadiness::Runner.new
      runner.define_singleton_method(:fetch_paginated_collection) do |endpoint, key, validate_page: nil|
        _validate_page = validate_page
        if key == "check_suites"
          [
            { "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
              "updated_at" => "2026-08-25T10:00:00Z" },
            { "id" => 20, "created_at" => "2026-08-25T12:00:00Z",
              "updated_at" => "2026-08-25T12:00:00Z" }
          ].map do |suite|
            latest_conclusion_for_suite = if suite.fetch("id") == 10
                                            latest_conclusion == "success" ? "failure" : "success"
                                          else
                                            latest_conclusion
                                          end
            suite.merge(
              "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
              "status" => "completed", "conclusion" => latest_conclusion_for_suite,
              "latest_check_runs_count" => 1
            )
          end
        else
          suite_id = endpoint[%r{/check-suites/(\d+)/}, 1].to_i
          run_id = suite_id == 10 ? 200 : 100
          conclusion = if suite_id == 10
                         latest_conclusion == "success" ? "failure" : "success"
                       else
                         latest_conclusion
                       end
          [{
            "id" => run_id, "name" => "build", "head_sha" => head,
            "status" => "completed", "conclusion" => conclusion,
            "started_at" => suite_id == 10 ? "2026-08-25T11:00:00Z" : "2026-08-25T12:00:00Z",
            "html_url" => "",
            "app" => { "id" => 9, "slug" => "ci-app" },
            "check_suite" => { "id" => suite_id }
          }]
        end
      end

      rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

      assert complete, "#{latest_conclusion}: #{error}"
      assert_nil error, latest_conclusion
      assert_equal [100, 200], rows.map { |row| row.fetch("id") }.sort, latest_conclusion
      assert_equal [10, 20], rows.map { |row| row.fetch("suite_id") }.sort, latest_conclusion
    end
  end

  def test_same_suite_chronology_revalidates_selected_phase_matrix
    head = "a" * 40
    cases = {
      later_success: ["completed", "success", "completed", "failure", "completed", "success", true],
      later_failure: ["completed", "failure", "completed", "success", "completed", "failure", true],
      later_pending: ["in_progress", nil, "completed", "failure", "in_progress", nil, true],
      failure_suite_later_success: ["completed", "failure", "completed", "failure", "completed", "success", false],
      success_suite_later_failure: ["completed", "success", "completed", "success", "completed", "failure", false],
      completed_suite_later_pending: ["completed", "failure", "completed", "failure", "in_progress", nil, false],
      running_suite_later_success: ["in_progress", nil, "completed", "failure", "completed", "success", false]
    }

    cases.each do |label, values|
      suite_status, suite_conclusion, old_status, old_conclusion,
        latest_status, latest_conclusion, expected_complete = values
      suite = {
        "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
        "updated_at" => "2026-08-25T10:00:00Z",
        "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
        "status" => suite_status, "conclusion" => suite_conclusion, "latest_check_runs_count" => 2
      }
      runs = [
        {
          "id" => 100, "name" => "build", "head_sha" => head,
          "status" => old_status, "conclusion" => old_conclusion,
          "started_at" => "2026-08-25T10:00:00Z", "html_url" => "",
          "app" => suite.fetch("app"), "check_suite" => { "id" => 10 }
        },
        {
          "id" => 101, "name" => "build", "head_sha" => head,
          "status" => latest_status, "conclusion" => latest_conclusion,
          "started_at" => "2026-08-25T12:00:00Z", "html_url" => "",
          "app" => suite.fetch("app"), "check_suite" => { "id" => 10 }
        }
      ]
      runner = PrCiReadiness::Runner.new
      runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
        _validate_page = validate_page
        key == "check_suites" ? [suite] : runs
      end

      rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

      if expected_complete
        assert complete, "#{label}: #{error}"
        assert_nil error, label
        assert_equal [101], rows.map { |row| row.fetch("id") }, label
      else
        refute complete, label
        assert_empty rows, label
        assert_match(/contradicted|nonterminal/, error, label)
      end
    end
  end

  def test_check_suite_inventory_preserves_cross_suite_rerequest_as_distinct_evidence
    head = "a" * 40
    {
      running: ["in_progress", nil],
      failed: %w[completed failure]
    }.each do |label, (latest_status, latest_conclusion)|
      runner = PrCiReadiness::Runner.new
      runner.define_singleton_method(:fetch_paginated_collection) do |endpoint, key, validate_page: nil|
        _validate_page = validate_page
        if key == "check_suites"
          [
            {
              "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
              "updated_at" => "2026-08-25T10:00:00Z",
              "status" => latest_status, "conclusion" => latest_conclusion
            },
            {
              "id" => 20, "created_at" => "2026-08-25T12:00:00Z",
              "updated_at" => "2026-08-25T12:00:00Z",
              "status" => "completed", "conclusion" => "success"
            }
          ].map do |suite|
            suite.merge(
              "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
              "latest_check_runs_count" => 1
            )
          end
        else
          suite_id = endpoint[%r{/check-suites/(\d+)/}, 1].to_i
          rerequested = suite_id == 10
          [{
            "id" => rerequested ? 200 : 100, "name" => "build", "head_sha" => head,
            "status" => rerequested ? latest_status : "completed",
            "conclusion" => rerequested ? latest_conclusion : "success",
            "started_at" => rerequested ? "2026-08-25T14:00:00Z" : "2026-08-25T13:00:00Z",
            "html_url" => "", "app" => { "id" => 9, "slug" => "ci-app" },
            "check_suite" => { "id" => suite_id }
          }]
        end
      end

      rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

      assert complete, "#{label}: #{error}"
      assert_nil error, label
      assert_equal [100, 200], rows.map { |row| row.fetch("id") }.sort, label
      assert_equal [10, 20], rows.map { |row| row.fetch("suite_id") }.sort, label
    end
  end

  def test_check_suite_inventory_validates_suite_chronology_without_cross_suite_retry_inference
    head = "a" * 40
    {
      missing_suite_created_at: [nil, "2026-08-25T12:00:00Z", false],
      missing_run_started_at: ["2026-08-25T12:00:00Z", nil, true],
      tied_run_started_at: ["2026-08-25T12:00:00Z", "2026-08-25T11:00:00Z", true]
    }.each do |label, (second_created_at, second_started_at, expected_complete)|
      runner = PrCiReadiness::Runner.new
      runner.define_singleton_method(:fetch_paginated_collection) do |endpoint, key, validate_page: nil|
        _validate_page = validate_page
        if key == "check_suites"
          [
            { "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
              "updated_at" => "2026-08-25T10:00:00Z" },
            { "id" => 20, "created_at" => second_created_at, "updated_at" => second_created_at }
          ].map do |suite|
            suite.merge(
              "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
              "status" => "completed", "conclusion" => "success",
              "latest_check_runs_count" => 1
            )
          end
        else
          suite_id = endpoint[%r{/check-suites/(\d+)/}, 1].to_i
          [{
            "id" => suite_id * 10, "name" => "build", "head_sha" => head,
            "status" => "completed", "conclusion" => "success",
            "started_at" => suite_id == 10 ? "2026-08-25T11:00:00Z" : second_started_at,
            "html_url" => "",
            "app" => { "id" => 9, "slug" => "ci-app" },
            "check_suite" => { "id" => suite_id }
          }]
        end
      end

      rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

      if expected_complete
        assert complete, "#{label}: #{error}"
        assert_nil error, label
        assert_equal [100, 200], rows.map { |row| row.fetch("id") }.sort, label
        assert_equal [10, 20], rows.map { |row| row.fetch("suite_id") }.sort, label
      else
        refute complete, label
        assert_empty rows, label
        assert_match(/created_at/, error, label)
      end
    end
  end

  def test_stable_queued_check_suite_without_published_checks_is_an_authenticated_placeholder
    head = "a" * 40
    runner = PrCiReadiness::Runner.new
    runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
      _validate_page = validate_page
      if key == "check_suites"
        [{
          "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
          "updated_at" => "2026-08-25T10:00:00Z",
          "head_sha" => head, "app" => { "id" => 9, "slug" => "incidental-app" },
          "status" => "queued", "conclusion" => nil, "latest_check_runs_count" => 0
        }]
      else
        []
      end
    end

    rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

    assert complete, error
    assert_empty rows
    assert_nil error
  end

  def test_queued_placeholder_materializing_a_run_fails_suite_snapshot_continuity
    head = "a" * 40
    placeholder = {
      "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
      "updated_at" => "2026-08-25T10:00:00Z",
      "head_sha" => head, "app" => { "id" => 9, "slug" => "incidental-app" },
      "status" => "queued", "conclusion" => nil, "latest_check_runs_count" => 0
    }
    materialized = placeholder.merge("status" => "in_progress", "latest_check_runs_count" => 1)
    suite_fetches = 0
    runner = PrCiReadiness::Runner.new
    runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
      _validate_page = validate_page
      if key == "check_suites"
        suite_fetches += 1
        [suite_fetches == 1 ? placeholder : materialized]
      else
        []
      end
    end

    rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

    refute complete
    assert_empty rows
    assert_includes error, "changed during run materialization"
    assert_equal 2, suite_fetches
  end

  def test_queued_placeholder_updated_at_change_fails_suite_snapshot_continuity
    head = "a" * 40
    placeholder = {
      "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
      "updated_at" => "2026-08-25T10:00:00Z",
      "head_sha" => head, "app" => { "id" => 9, "slug" => "incidental-app" },
      "status" => "queued", "conclusion" => nil, "latest_check_runs_count" => 0
    }
    updated = placeholder.merge("updated_at" => "2026-08-25T10:01:00Z")
    suite_fetches = 0
    runner = PrCiReadiness::Runner.new
    runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
      _validate_page = validate_page
      if key == "check_suites"
        suite_fetches += 1
        [suite_fetches == 1 ? placeholder : updated]
      else
        []
      end
    end

    rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

    refute complete
    assert_empty rows
    assert_includes error, "changed during run materialization"
    assert_equal 2, suite_fetches
  end

  def test_check_suite_updated_at_must_be_present_and_rfc3339
    head = "a" * 40
    [nil, "not-a-timestamp"].each do |updated_at|
      runner = PrCiReadiness::Runner.new
      runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
        _validate_page = validate_page
        if key == "check_suites"
          [{
            "id" => 10, "created_at" => "2026-08-25T10:00:00Z", "updated_at" => updated_at,
            "head_sha" => head, "app" => { "id" => 9, "slug" => "incidental-app" },
            "status" => "queued", "conclusion" => nil, "latest_check_runs_count" => 0
          }]
        else
          []
        end
      end

      rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

      refute complete, updated_at.inspect
      assert_empty rows, updated_at.inspect
      assert_includes error, "updated_at", updated_at.inspect
    end
  end

  def test_empty_nonqueued_or_malformed_check_suite_is_not_complete
    head = "a" * 40
    %w[requested in_progress waiting pending UNKNOWN].each do |suite_status|
      runner = PrCiReadiness::Runner.new
      runner.define_singleton_method(:fetch_paginated_collection) do |_endpoint, key, validate_page: nil|
        _validate_page = validate_page
        if key == "check_suites"
          [{
            "id" => 10, "created_at" => "2026-08-25T10:00:00Z",
            "updated_at" => "2026-08-25T10:00:00Z",
            "head_sha" => head, "app" => { "id" => 9, "slug" => "ci-app" },
            "status" => suite_status, "conclusion" => nil, "latest_check_runs_count" => 0
          }]
        else
          []
        end
      end

      rows, complete, error = runner.send(:fetch_exact_head_check_runs, "owner/repo", head)

      refute complete, suite_status
      assert_empty rows, suite_status
      assert_match(/check suite/, error, suite_status)
    end
  end

  def test_malformed_or_unknown_review_rows_make_inventory_incomplete
    head = "3f67da47c44b7f403c72be2ed8f5bf4505666974"
    identity = hichee_data_431_identity.merge(
      "head" => hichee_data_431_identity.fetch("head").merge("sha" => head)
    )
    invalid_rows = {
      missing_commit: {
        "id" => "PRR_missing_commit", "state" => "PENDING", "submittedAt" => nil, "commit" => nil
      },
      unknown_state: {
        "id" => "PRR_unknown", "state" => "UNKNOWN", "submittedAt" => nil,
        "commit" => { "oid" => head }
      }
    }
    invalid_rows.each do |label, row|
      with_fake_gh(
        required_json: '[{"name":"unit","bucket":"pass"}]',
        full_json: "[]", pr_head: head, pr_identity: [identity, identity],
        review_pages: {
          nil => {
            "data" => {
              "repository" => {
                "pullRequest" => {
                  "reviews" => {
                    "nodes" => [row],
                    "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                  }
                }
              }
            }
          }
        }
      ) do |env|
        out, status = run_script(env, "431", "--repo", "shakacode/hichee-data")
        assert status.success?, "#{label}: #{out}"
        data = JSON.parse(out)
        assert_equal "UNKNOWN", data.fetch("verdict"), label
        assert_equal false, data.dig("viewer_review_inventory", "complete"), label
      end
    end
  end

  def test_pending_current_head_review_drafts_block_unknown_checks
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      pr_head: "current-head",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [
                    { "id" => "PRR_one", "state" => "PENDING", "submittedAt" => nil,
                      "commit" => { "oid" => "current-head" } }
                  ],
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal(["PRR_one"], data.fetch("viewer_pending_review_drafts").map { |review| review["id"] })
    end
  end

  def test_submitted_dismissed_and_old_head_drafts_do_not_block_ready_checks
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "current-head",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [
                    { "id" => "PRR_submitted", "state" => "COMMENTED", "submittedAt" => "2026-07-12T00:00:00Z",
                      "commit" => { "oid" => "current-head" } },
                    { "id" => "PRR_dismissed", "state" => "DISMISSED", "submittedAt" => nil,
                      "commit" => { "oid" => "current-head" } },
                    { "id" => "PRR_old", "state" => "PENDING", "submittedAt" => nil,
                      "commit" => { "oid" => "b" * 40 } }
                  ],
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_empty data.fetch("viewer_pending_review_drafts")
      assert_equal true, data.fetch("viewer_review_inventory").fetch("complete")
    end
  end

  def test_incomplete_review_inventory_is_unknown
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [],
                  "pageInfo" => { "hasNextPage" => true, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data["verdict"]
      assert_equal "authenticated_viewer", data.fetch("viewer_review_inventory").fetch("scope")
      assert_equal false, data.fetch("viewer_review_inventory").fetch("complete")
    end
  end

  def test_incomplete_review_inventory_does_not_overwrite_not_ready_checks
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pending"}]',
      full_json: "[]",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => {},
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal false, data.fetch("viewer_review_inventory").fetch("complete")
    end
  end

  def test_unavailable_review_inventory_is_unknown
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      review_error: true
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data["verdict"]
      assert_equal "authenticated_viewer", data.fetch("viewer_review_inventory").fetch("scope")
      assert_equal false, data.fetch("viewer_review_inventory").fetch("complete")
    end
  end

  def test_malformed_review_inventory_is_unknown
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => {},
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data["verdict"]
      assert_equal "authenticated_viewer", data.fetch("viewer_review_inventory").fetch("scope")
      assert_equal false, data.fetch("viewer_review_inventory").fetch("complete")
    end
  end

  def test_pending_current_head_draft_on_later_review_page_blocks_ready_checks
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "current-head",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [],
                  "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor-1" }
                }
              }
            }
          }
        },
        "cursor-1" => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [
                    { "id" => "PRR_later", "state" => "PENDING", "submittedAt" => nil,
                      "commit" => { "oid" => "current-head" } }
                  ],
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal(["PRR_later"], data.fetch("viewer_pending_review_drafts").map { |review| review["id"] })
      assert_equal 2, data.fetch("viewer_review_inventory").fetch("pages")
    end
  end

  def test_partial_review_inventory_keeps_early_pending_drafts
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "current-head",
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => [
                    { "id" => "PRR_early", "state" => "PENDING", "submittedAt" => nil,
                      "commit" => { "oid" => "current-head" } }
                  ],
                  "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor-1" }
                }
              }
            }
          }
        },
        "cursor-1" => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => {},
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "31", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal(["PRR_early"], data.fetch("viewer_pending_review_drafts").map { |review| review["id"] })
      assert_equal false, data.fetch("viewer_review_inventory").fetch("complete")
      assert_equal 1, data.fetch("viewer_review_inventory").fetch("pages")
    end
  end

  def test_falls_back_to_full_when_no_required_checks
    # Empty required payload => fall back to full list, required_used flips false.
    with_fake_gh(
      required_json: "",
      full_json: '[{"name":"lint","state":"FAILURE","bucket":"fail","link":"x"}]'
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal false, data["required_used"]
      assert_equal ["lint"], data["failing"]
    end
  end

  def test_totally_empty_is_unknown_via_cli
    with_fake_gh(required_json: "", full_json: "[]") do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data["verdict"]
      assert_equal false, data["required_used"]
    end
  end

  def test_cancel_only_required_falls_back_to_full_list
    # A required list of only cancelled rows is not usable: it must fall back to
    # the full check list (which here surfaces a real failure) instead of
    # silently collapsing to UNKNOWN.
    with_fake_gh(
      required_json: '[{"name":"stale","state":"CANCELLED","bucket":"cancel","link":"x"}]',
      full_json: '[{"name":"lint","state":"FAILURE","bucket":"fail","link":"x"}]'
    ) do |env|
      out, = run_script(env, "123", "--repo", "owner/repo")
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      # required form had no usable rows, so the full list was used.
      assert_equal false, data["required_used"]
      assert_equal ["lint"], data["failing"]
    end
  end

  def test_cancel_only_required_and_empty_full_is_not_ready_via_cli
    with_fake_gh(
      required_json: '[{"name":"stale","state":"CANCELLED","bucket":"cancel","link":"x"}]',
      full_json: "[]"
    ) do |env|
      out, = run_script(env, "123", "--repo", "owner/repo")
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal false, data["required_used"]
      assert_equal ["stale"], data["pending"]
    end
  end

  def test_cancelled_required_context_blocks_unrelated_full_list_pass
    with_fake_gh(
      required_json: '[{"workflow":"Security","name":"security","bucket":"cancel"}]',
      full_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]'
    ) do |env|
      out, = run_script(env, "123", "--repo", "owner/repo")
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal false, data["required_used"]
      assert_equal ["security"], data["pending"]
    end
  end

  def test_full_list_pass_cannot_authenticate_failed_required_query
    with_fake_gh(
      required_json: "",
      full_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      required_check_error: "HTTP 503 while querying required checks\n"
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data["verdict"]
      assert_equal false, data["required_used"]
    end
  end

  def test_known_good_no_required_diagnostic_allows_full_list_pass
    with_fake_gh(
      required_json: "",
      full_json: '[{"workflow":"CI","name":"unit","bucket":"pass"}]',
      check_stderr: "no required checks reported on the 'feature' branch\n",
      check_status: 1
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_equal false, data["required_used"]
    end
  end

  def test_full_list_current_pass_supersedes_cancelled_required_context_with_same_identity
    with_fake_gh(
      required_json: '[{"workflow":"Security","name":"security","bucket":"cancel"}]',
      full_json: '[{"workflow":"Security","name":"security","bucket":"pass"}]'
    ) do |env|
      out, = run_script(env, "123", "--repo", "owner/repo")
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_equal false, data["required_used"]
      assert_empty data["pending"]
    end
  end

  def test_same_context_current_pass_supersedes_cancelled_history_via_cli
    with_fake_gh(
      required_json: '[{"workflow":"CI","name":"rspec","bucket":"pass"},{"workflow":"CI","name":"rspec","bucket":"cancel"}]',
      full_json: "[]"
    ) do |env|
      out, = run_script(env, "123", "--repo", "owner/repo")
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
    end
  end

  def test_text_mode_via_cli
    with_fake_gh(
      required_json: '[{"name":"lint","bucket":"fail"}]',
      full_json: "[]"
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--text")
      assert status.success?, out
      assert_includes out, "NOT_READY"
      assert_includes out, "failing: lint"
    end
  end

  def test_text_mode_surfaces_requested_hosted_pending
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "in_progress",
                 "conclusion" => nil, "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "queued", "conclusion" => nil,
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42", "--text")
      assert status.success?, out
      assert_includes out, "requested_hosted_pending: hosted, hosted / linux"
      assert_includes out, "requested_hosted_failing: (none)"
    end
  end

  def test_text_mode_surfaces_invalid_requested_hosted_run
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "abc123",
      runs: {}
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "not-a-run", "--text")
      assert status.success?, out
      assert_includes out, "UNKNOWN"
      assert_includes out, "requested_hosted_unknown: not-a-run: requested hosted run must be a run id"
    end
  end

  def test_repo_defaults_to_gh_repo_view
    with_fake_gh(
      required_json: '[{"name":"rspec","bucket":"pass"}]',
      full_json: "[]"
    ) do |env|
      out, status = run_script(env, "123")
      assert status.success?, out
      assert_equal "READY", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_pending_blocks_ready_required_gate
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"},{"name":"advisory","bucket":"pending"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "in_progress",
                 "conclusion" => nil, "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "queued", "conclusion" => nil,
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal(["hosted", "hosted / linux"], data.fetch("requested_hosted").fetch("pending").map { |row| row["name"] })
      assert_empty data.fetch("requested_hosted").fetch("failing")
    end
  end

  def test_incomplete_review_inventory_does_not_overwrite_not_ready_requested_hosted_run
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: "[]",
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "in_progress",
                 "conclusion" => nil, "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      },
      review_pages: {
        nil => {
          "data" => {
            "repository" => {
              "pullRequest" => {
                "reviews" => {
                  "nodes" => {},
                  "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
                }
              }
            }
          }
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal false, data.fetch("viewer_review_inventory").fetch("complete")
      assert_equal(["hosted"], data.fetch("requested_hosted").fetch("pending").map { |row| row["name"] })
    end
  end

  def test_requested_hosted_run_status_blocks_ready_even_when_jobs_completed
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "in_progress",
                 "conclusion" => nil, "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "completed", "conclusion" => "success",
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      pending_names = data.fetch("requested_hosted").fetch("pending").map { |row| row["name"] }
      assert_equal ["hosted"], pending_names
      assert_empty data.fetch("requested_hosted").fetch("failing")
    end
  end

  def test_requested_hosted_pending_job_blocks_even_when_run_reports_success
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "in_progress", "conclusion" => nil,
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      pending = data.fetch("requested_hosted").fetch("pending").map { |row| row["name"] }
      assert_equal ["hosted / linux"], pending
    end
  end

  def test_requested_hosted_failure_blocks_ready_required_gate
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "failure", "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "completed", "conclusion" => "failure",
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal(["hosted", "hosted / linux"], data.fetch("requested_hosted").fetch("failing").map { |row| row["name"] })
      assert_empty data.fetch("requested_hosted").fetch("pending")
    end
  end

  def test_requested_hosted_success_keeps_required_gate_ready_despite_unrelated_advisory_pending
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"},{"name":"unrelated advisory","bucket":"pending"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "completed", "conclusion" => "success",
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_empty data.fetch("requested_hosted").fetch("pending")
      assert_empty data.fetch("requested_hosted").fetch("failing")
      assert_empty data.fetch("requested_hosted").fetch("stale")
    end
  end

  def test_requested_hosted_success_preserves_complete_job_inventory
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "completed", "conclusion" => "success",
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_empty data.fetch("requested_hosted").fetch("unknown")
      kinds = data.fetch("authenticated_requested_hosted_inventory").map { |row| row["kind"] }
      assert_equal %w[run job], kinds
    end
  end

  def test_requested_hosted_success_is_ready_without_required_checks_despite_unrelated_advisory_pending
    with_fake_gh(
      required_json: "",
      full_json: '[{"name":"unrelated advisory","bucket":"pending"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: [
            { "id" => 7, "name" => "hosted / linux", "status" => "completed", "conclusion" => "success",
              "html_url" => "https://example.test/jobs/7" }
          ]
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_equal false, data["required_used"]
      assert_empty data["pending"]
      assert_empty data.fetch("requested_hosted").fetch("pending")
    end
  end

  def test_requested_hosted_success_does_not_erase_cancelled_required_context
    with_fake_gh(
      required_json: '[{"workflow":"Security","name":"security","bucket":"cancel"}]',
      full_json: "[]",
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal ["security"], data["pending"]
      assert_empty data.fetch("requested_hosted").fetch("failing")
    end
  end

  def test_requested_hosted_success_accepts_same_context_full_list_supersession
    with_fake_gh(
      required_json: '[{"workflow":"Security","name":"security","bucket":"cancel"}]',
      full_json: '[{"workflow":"Security","name":"security","bucket":"pass"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_empty data["pending"]
    end
  end

  def test_requested_hosted_success_does_not_accept_different_workflow_supersession
    with_fake_gh(
      required_json: '[{"workflow":"Security","name":"security","bucket":"cancel"}]',
      full_json: '[{"workflow":"CI","name":"security","bucket":"pass"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal ["security"], data["pending"]
    end
  end

  def test_requested_hosted_success_does_not_override_failed_full_supersession_query
    with_fake_gh(
      required_json: '[{"workflow":"Security","name":"security","bucket":"cancel"}]',
      full_json: '[{"workflow":"Security","name":"security","bucket":"pass"}]',
      full_check_error: "HTTP 503 while querying full checks\n",
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "NOT_READY", data["verdict"]
      assert_equal ["security"], data["pending"]
    end
  end

  def test_requested_hosted_success_is_unknown_when_old_gh_rejects_workflow_field
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      rejected_check_field: "workflow",
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      assert_equal "UNKNOWN", JSON.parse(out)["verdict"]
    end
  end

  def test_plain_invocation_is_unknown_when_old_gh_rejects_workflow_field
    with_fake_gh(required_json: "", full_json: "[]", rejected_check_field: "workflow") do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo")
      assert status.success?, out
      assert_equal "UNKNOWN", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_success_is_ready_after_known_good_no_required_checks_diagnostic
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      check_stderr: "no required checks reported on the 'feature' branch\n",
      check_status: 1,
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      assert_equal "READY", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_success_is_ready_after_known_good_no_checks_diagnostic_with_crlf
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      check_stderr: "no checks reported on the 'feature' branch\r\n",
      check_status: 1,
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      assert_equal "READY", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_success_is_unknown_when_no_checks_diagnostic_has_trailing_error_line
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      check_stderr: "no required checks reported on the 'feature' branch\nHTTP 503 while querying checks\n",
      check_status: 1,
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      assert_equal "UNKNOWN", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_success_is_unknown_when_no_checks_diagnostic_has_same_line_suffix
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      check_stderr: "no required checks reported on the 'feature' branch; HTTP 503 while querying checks\n",
      check_status: 1,
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      assert_equal "UNKNOWN", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_success_is_unknown_without_exception_for_invalid_stderr_byte
    invalid_stderr = "no required checks reported on the 'feat".b + "\xFF".b + "ure' branch\n".b
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      check_stderr: invalid_stderr,
      check_status: 1,
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      assert_equal "UNKNOWN", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_success_is_unknown_for_malformed_non_utf8_stderr_sequence
    malformed_stderr = "no required checks reported on the 'feat".b + "\xC3\x28".b + "ure' branch\n".b
    with_fake_gh(
      required_json: "",
      full_json: "[]",
      check_stderr: malformed_stderr,
      check_status: 1,
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      assert_equal "UNKNOWN", JSON.parse(out)["verdict"]
    end
  end

  def test_requested_hosted_stale_head_is_unknown_when_base_gate_is_ready
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"}]',
      pr_head: "new-head",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "old-head", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: []
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "UNKNOWN", data["verdict"]
      assert_equal(["42"], data.fetch("requested_hosted").fetch("stale").map { |row| row["run_id"] })
    end
  end

  # --- arg validation (no gh needed) ---------------------------------------

  def test_rejects_non_integer_pr
    out, status = Open3.capture2e("ruby", SCRIPT, "not-a-number", "--repo", "owner/repo")
    refute status.success?
    assert_includes out, "positive integer PR number is required"
  end

  def test_rejects_zero_pr
    out, status = Open3.capture2e("ruby", SCRIPT, "0", "--repo", "owner/repo")
    refute status.success?
    assert_includes out, "positive integer PR number is required"
  end

  def test_rejects_bad_repo_form
    out, status = Open3.capture2e("ruby", SCRIPT, "12", "--repo", "owneronly")
    refute status.success?
    assert_includes out, "--repo must be in OWNER/REPO form"
  end

  def test_rejects_repo_with_extra_path_segment
    out, status = Open3.capture2e("ruby", SCRIPT, "12", "--repo", "a/b/c")
    refute status.success?
    assert_includes out, "--repo must be in OWNER/REPO form"
  end

  def test_rejects_repo_with_empty_owner
    out, status = Open3.capture2e("ruby", SCRIPT, "12", "--repo", "/repo")
    refute status.success?
    assert_includes out, "--repo must be in OWNER/REPO form"
  end

  def test_rejects_unknown_option
    out, status = Open3.capture2e("ruby", SCRIPT, "--bogus")
    refute status.success?
    assert_includes out, "unknown option: --bogus"
  end

  def test_help_exits_zero
    out, status = Open3.capture2e("ruby", SCRIPT, "--help")
    assert status.success?, out
    assert_includes out, "Usage: pr-ci-readiness"
  end

  def test_self_check_passes
    out, status = Open3.capture2e("ruby", SCRIPT, "--self-check")
    assert status.success?, out
    assert_includes out, "self-check passed"
  end
end
