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
      repo: "owner/repo", pr_number: 7, head_sha: head,
      checked_at: "2026-07-30T12:00:00Z", scopes:
    )

    assert_equal "pr-ci-readiness", contract.fetch("contract")
    assert_equal 2, contract.fetch("version")
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
        repo: "owner/repo", pr_number: 7, head_sha: head, checked_at:, scopes:
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
                   exact_status_pages: nil)
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
          exact_status_sha, exact_status_total_count, exact_status_pages
        )
      )
      FileUtils.chmod(0o755, gh)
      env = { "PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}" }
      yield env
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
                             exact_status_pages)
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
                     exact_status_sha, exact_status_total_count, exact_status_pages)
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
          }
        }
        template = JSON.generate(default_identity).sub('"number":0', '"number":%s')
        "printf #{template.inspect} \"$FAKE_PR_NUMBER\""
      end
    run_cases = runs.map do |run_id, payload|
      run_json = JSON.generate(payload.fetch(:run))
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
            printf '%s' #{required_json.inspect}
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
          cat <<'JSON'
      #{JSON.generate(first_page)}
      JSON
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
        if [[ "$*" = *"/check-runs?per_page="* ]]; then
          #{exact_inventory_error == 'check_runs' ? 'exit 1' : ''}
          #{shell_json_printf('total_count' => exact_check_runs.length, 'check_runs' => exact_check_runs)}
          exit 0
        fi
      #{combined_status_branch(
        exact_statuses, exact_inventory_error, exact_status_sha, exact_status_total_count, exact_status_pages
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
                      "commit" => { "oid" => "old-head" } }
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

  def test_requested_hosted_success_does_not_fetch_jobs
    with_fake_gh(
      required_json: '[{"name":"unit","bucket":"pass"}]',
      full_json: '[{"name":"unit","bucket":"pass"}]',
      pr_head: "abc123",
      runs: {
        "42" => {
          run: { "id" => 42, "name" => "hosted", "head_sha" => "abc123", "status" => "completed",
                 "conclusion" => "success", "html_url" => "https://example.test/runs/42" },
          jobs: [],
          jobs_error: true
        }
      }
    ) do |env|
      out, status = run_script(env, "123", "--repo", "owner/repo", "--requested-hosted-run", "42")
      assert status.success?, out
      data = JSON.parse(out)
      assert_equal "READY", data["verdict"]
      assert_empty data.fetch("requested_hosted").fetch("unknown")
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
