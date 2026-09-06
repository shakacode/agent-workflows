#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tempfile"
require "tmpdir"
require_relative "../lib/autonomous_merge_calibration"

SCRIPT = File.expand_path("autonomous-merge-calibrate", __dir__)
FIXTURE_DIR = File.expand_path("../fixtures", __dir__)

class AutonomousMergeCalibrateTest < Minitest::Test
  def test_reports_distributions_near_misses_and_shadow_disposition_without_complete_review_history
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => false,
        "window" => "representative checked fixture",
        "repositories" => ["example/one", "example/two"]
      },
      "prs" => [
        pr("example/one", 1, files: 29, lines: 999, commits: 9, reviewed_heads: 3),
        pr("example/one", 2, files: 30, lines: 1_000, commits: 10, reviewed_heads: 4),
        pr("example/two", 3, files: 2, lines: 20, commits: 1, reviewed_heads: nil)
      ]
    }

    Tempfile.create(["calibration", ".json"]) do |file|
      file.write(JSON.generate(dataset))
      file.flush
      stdout, stderr, status = Open3.capture3(
        "ruby", SCRIPT,
        "--input", file.path,
        "--repo", "example/one",
        "--repo", "example/two",
        "--pr-count", "100",
        "--sample", "2"
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)

      assert_equal "autonomous-merge-calibration-report", result.fetch("contract")
      assert_equal 3, result.dig("coverage", "pr_count")
      assert_equal 2, result.dig("coverage", "reviewed_heads_known")
      assert_equal "shadow", result.dig("reviewed_heads", "disposition")
      assert_includes result.dig("reviewed_heads", "graduation_blockers"), "dataset scope is incomplete"
      assert_equal([2], result.fetch("triggered_sample").map { |entry| entry.fetch("number") })
      assert_equal([1], result.fetch("near_miss_sample").map { |entry| entry.fetch("number") })
    end
  end

  def test_reports_path_category_distribution_and_complete_proposed_threshold_classification_changes
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => false,
        "window" => "proposed-threshold comparison fixture",
        "repositories" => ["example/one", "example/two"]
      },
      "prs" => [
        pr(
          "example/one", 1,
          files: 29, lines: 999, commits: 9, reviewed_heads: 3,
          path_categories: %w[app docs]
        ),
        pr(
          "example/one", 2,
          files: 30, lines: 1_000, commits: 10, reviewed_heads: 4,
          path_categories: %w[app db]
        ),
        pr(
          "example/two", 3,
          files: 2, lines: 20, commits: 1, reviewed_heads: nil,
          path_categories: %w[docs]
        )
      ]
    }

    Tempfile.create(["calibration", ".json"]) do |file|
      file.write(JSON.generate(dataset))
      file.flush
      stdout, stderr, status = Open3.capture3(
        "ruby", SCRIPT,
        "--input", file.path,
        "--sample", "1",
        "--max-changed-files", "1"
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)

      assert_equal(
        { "app" => 2, "db" => 1, "docs" => 2 },
        result.fetch("path_category_distribution")
      )
      assert_equal(
        [
          {
            "repository" => "example/one",
            "number" => 1,
            "portable_default_triggered" => false,
            "proposed_threshold_triggered" => true
          },
          {
            "repository" => "example/two",
            "number" => 3,
            "portable_default_triggered" => false,
            "proposed_threshold_triggered" => true
          }
        ],
        result.fetch("proposed_threshold_classification_changes")
      )
      assert_equal 1, result.fetch("triggered_sample").length
      assert_equal false, result.fetch("merge_decisions_emitted")
    end
  end

  def test_checked_calibration_decision_is_exactly_reproducible_and_emits_no_merge_decisions
    dataset = File.join(FIXTURE_DIR, "autonomous-merge-calibration-dataset.json")
    decision = File.join(FIXTURE_DIR, "autonomous-merge-reviewed-heads-calibration.json")
    stdout, stderr, status = Open3.capture3(
      "ruby", SCRIPT,
      "--input", dataset,
      "--pr-count", "100",
      "--sample", "5",
      "--format", "decision"
    )

    assert status.success?, stderr
    assert_equal JSON.parse(File.read(decision)), JSON.parse(stdout)

    report_stdout, report_stderr, report_status = Open3.capture3(
      "ruby", SCRIPT,
      "--input", dataset,
      "--pr-count", "100",
      "--sample", "5"
    )
    assert report_status.success?, report_stderr
    report = JSON.parse(report_stdout)
    assert_equal false, report.fetch("merge_decisions_emitted")
    assert_equal "shadow", report.dig("reviewed_heads", "disposition")
  end

  def test_complete_dataset_with_malformed_counts_cannot_emit_an_enforced_decision
    malformed = pr(
      "example/one", 1,
      files: "30", lines: -1, commits: 1, reviewed_heads: -1,
      path_categories: ["app"]
    )
    malformed["semantic_inspection"] = "reviewed"
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => true,
        "window" => "malformed enforced-decision fixture",
        "repositories" => ["example/one"],
        "reviewed_heads_decision" => {
          "disposition" => "enforced",
          "rationale" => "Malformed numeric evidence must never graduate enforcement."
        }
      },
      "prs" => [malformed]
    }

    Tempfile.create(["calibration", ".json"]) do |file|
      file.write(JSON.generate(dataset))
      file.flush
      stdout, stderr, status = Open3.capture3(
        "ruby", SCRIPT,
        "--input", file.path,
        "--format", "decision"
      )

      refute status.success?
      assert_empty stdout
      assert_includes stderr, "calibration PR changed_files must be a nonnegative integer"
    end
  end

  def test_complete_dataset_rejects_null_enforcement_metrics_before_decision_emission
    %w[changed_files changed_lines commits].each do |field|
      incomplete_metric = pr(
        "example/one", 1,
        files: 1, lines: 1, commits: 1, reviewed_heads: 1,
        path_categories: ["app"]
      )
      incomplete_metric[field] = nil
      incomplete_metric["semantic_inspection"] = "reviewed"
      dataset = {
        "contract" => "autonomous-merge-calibration-dataset",
        "version" => 1,
        "scope" => {
          "complete" => true,
          "window" => "null complete-scope metric fixture",
          "repositories" => ["example/one"],
          "reviewed_heads_decision" => {
            "disposition" => "enforced",
            "rationale" => "Complete evidence is required before enforcement."
          }
        },
        "prs" => [incomplete_metric]
      }

      stdout, stderr, status = run_calibrator(dataset, "--format", "decision")

      refute status.success?, field
      assert_empty stdout, field
      assert_includes(
        stderr,
        "calibration PR #{field} must be a nonnegative integer when dataset scope is complete",
        field
      )
    end
  end

  def test_complete_dataset_with_null_reviewed_heads_remains_shadow
    incomplete_reviews = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: nil,
      path_categories: ["app"]
    )
    incomplete_reviews["semantic_inspection"] = "reviewed"
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => true,
        "window" => "incomplete reviewed-head history fixture",
        "repositories" => ["example/one"],
        "reviewed_heads_decision" => {
          "disposition" => "enforced",
          "rationale" => "Enforcement still requires complete reviewed-head history."
        }
      },
      "prs" => [incomplete_reviews]
    }

    stdout, stderr, status = run_calibrator(dataset)

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal "shadow", report.dig("reviewed_heads", "disposition")
    assert_includes(
      report.dig("reviewed_heads", "graduation_blockers"),
      "reviewed-head history is incomplete"
    )
    assert_equal false, report.fetch("merge_decisions_emitted")
  end

  def test_broader_offline_window_cannot_preserve_complete_scope_or_enforcement
    evidence = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["app"]
    )
    evidence["semantic_inspection"] = "reviewed"
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => true,
        "window" => "latest 1 merged PRs per repository",
        "repositories" => ["example/one"],
        "request" => {
          "repositories" => ["example/one"],
          "mode" => "pr-count",
          "value" => 1,
          "page_size" => 100
        },
        "reviewed_heads_decision" => {
          "disposition" => "enforced",
          "rationale" => "Only the collected request may graduate."
        }
      },
      "prs" => [evidence]
    }

    stdout, stderr, status = run_calibrator(dataset, "--pr-count", "2")

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal false, report.dig("coverage", "scope_complete")
    assert_equal "shadow", report.dig("reviewed_heads", "disposition")
    assert_includes(
      report.dig("reviewed_heads", "graduation_blockers"),
      "requested analysis window exceeds checkpoint scope"
    )

    stdout, stderr, status = run_calibrator(dataset, "--pr-count", "1")

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal true, report.dig("coverage", "scope_complete")
    assert_equal "enforced", report.dig("reviewed_heads", "disposition")

    since_dataset = JSON.parse(JSON.generate(dataset))
    since_dataset.dig("scope", "request")["mode"] = "since"
    since_dataset.dig("scope", "request")["value"] = "2026-07-01"
    since_dataset.fetch("prs").fetch(0)["merged_at"] = "2026-07-03T00:00:00Z"

    stdout, stderr, status = run_calibrator(since_dataset, "--since", "2026-06-30")

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal false, report.dig("coverage", "scope_complete")
    assert_equal "shadow", report.dig("reviewed_heads", "disposition")

    stdout, stderr, status = run_calibrator(since_dataset, "--since", "2026-07-02")

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal true, report.dig("coverage", "scope_complete")
    assert_equal "enforced", report.dig("reviewed_heads", "disposition")
  end

  def test_complete_empty_dataset_cannot_graduate_reviewed_heads
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => true,
        "window" => "empty complete-scope fixture",
        "repositories" => [],
        "reviewed_heads_decision" => {
          "disposition" => "enforced",
          "rationale" => "Empty evidence must never graduate enforcement."
        }
      },
      "prs" => []
    }

    stdout, stderr, status = run_calibrator(dataset)

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal "shadow", report.dig("reviewed_heads", "disposition")
    assert_includes report.dig("reviewed_heads", "graduation_blockers"), "dataset has no repositories"
    assert_includes report.dig("reviewed_heads", "graduation_blockers"), "dataset has no PRs"
    assert_equal false, report.fetch("merge_decisions_emitted")
  end

  def test_selected_pr_identity_timestamp_and_count_fields_fail_closed
    invalid_fields = {
      "repository" => ["invalid", "repository must use OWNER/REPO form"],
      "number" => [0, "number must be a positive integer"],
      "merged_at" => ["not-a-timestamp", "merged_at must be an ISO 8601 timestamp"],
      "changed_files" => ["30", "changed_files must be a nonnegative integer or null"],
      "changed_lines" => [-1, "changed_lines must be a nonnegative integer or null"],
      "commits" => [-1, "commits must be a nonnegative integer or null"],
      "reviewed_heads" => [-1, "reviewed_heads must be a nonnegative integer or null"],
      "automation_reviewed_heads" => [-1, "automation_reviewed_heads must be a nonnegative integer or null"]
    }

    invalid_fields.each do |field, (value, expected_error)|
      malformed = pr(
        "example/one", 1,
        files: 1, lines: 1, commits: 1, reviewed_heads: 1,
        path_categories: ["app"]
      )
      malformed[field] = value
      dataset = calibration_dataset([malformed], repositories: [malformed.fetch("repository")])

      stdout, stderr, status = run_calibrator(dataset)

      refute status.success?, field
      assert_empty stdout, field
      assert_includes stderr, expected_error, field
    end
  end

  def test_selected_pr_identities_must_be_unique
    duplicate = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["app"]
    )
    stdout, stderr, status = run_calibrator(
      calibration_dataset([duplicate, duplicate.dup], repositories: ["example/one"])
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "calibration PR identities must be unique"
  end

  def test_every_pr_repository_shape_is_validated_before_repository_filtering
    selected = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["app"]
    )
    selected["semantic_inspection"] = "reviewed"
    base_dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => true,
        "window" => "pre-filter validation fixture",
        "repositories" => ["example/one"],
        "reviewed_heads_decision" => {
          "disposition" => "enforced",
          "rationale" => "Every dataset entry must be structurally valid before filtering."
        }
      }
    }
    malformed_repository = selected.merge("repository" => "not-owner-repo", "number" => 2)
    cases = {
      "--repo filtering" => [
        base_dataset.merge("prs" => [selected, "not-a-mapping"]),
        ["--repo", "example/one"],
        "calibration PR must be a mapping"
      ],
      "dataset-scope filtering" => [
        base_dataset.merge("prs" => [selected, malformed_repository]),
        [],
        "calibration PR repository must use OWNER/REPO form"
      ]
    }

    results = cases.transform_values do |dataset, arguments, expected_error|
      stdout, stderr, status = run_calibrator(dataset, *arguments)
      {
        "stdout" => stdout,
        "stderr" => stderr,
        "status" => status,
        "expected_error" => expected_error
      }
    end
    failures = results.filter_map do |label, result|
      next unless result.fetch("status").success? || !result.fetch("stdout").empty? ||
                  !result.fetch("stderr").include?(result.fetch("expected_error"))

      "#{label}: status=#{result.fetch('status').exitstatus}, stdout=#{result.fetch('stdout').inspect}, " \
        "stderr=#{result.fetch('stderr').inspect}"
    end

    assert_empty failures, failures.join("\n")
  end

  def test_valid_filtered_metrics_do_not_contaminate_zero_and_null_boundaries
    selected = pr(
      "example/one", 1,
      files: 0, lines: 0, commits: 0, reviewed_heads: nil,
      path_categories: []
    )
    selected["merged_at"] = "2026-07-03T00:00:00Z"
    excluded_by_repository = pr(
      "example/two", 2,
      files: 30, lines: 1_000, commits: 10, reviewed_heads: 4,
      path_categories: ["db"]
    )
    excluded_by_date = pr(
      "example/one", 3,
      files: 40, lines: 2_000, commits: 11, reviewed_heads: 5,
      path_categories: ["docs"]
    )
    excluded_by_date["merged_at"] = "2026-06-30T00:00:00Z"
    excluded_by_count = pr(
      "example/one", 4,
      files: 50, lines: 3_000, commits: 12, reviewed_heads: 6,
      path_categories: ["app"]
    )
    excluded_by_count["merged_at"] = "2026-07-02T00:00:00Z"
    dataset = calibration_dataset(
      [selected, excluded_by_repository, excluded_by_date, excluded_by_count],
      repositories: ["example/one", "example/two"]
    )

    stdout, stderr, status = run_calibrator(
      dataset,
      "--repo", "example/one",
      "--since", "2026-07-01",
      "--pr-count", "1"
    )

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal 1, report.dig("coverage", "pr_count")
    assert_equal(
      { "count" => 1, "p50" => 0, "p90" => 0, "max" => 0 },
      report.dig("distributions", "changed_files")
    )
    assert_equal 0, report.dig("coverage", "reviewed_heads_known")
  end

  def test_malformed_records_fail_before_repository_date_and_count_filters
    selected = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["app"]
    )
    selected["merged_at"] = "2026-07-03T00:00:00Z"
    excluded_by_repository = pr(
      "example/two", 2,
      files: "30", lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["docs"]
    )
    excluded_by_date = pr(
      "example/one", 3,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: [""]
    )
    excluded_by_date["merged_at"] = "2026-06-30T00:00:00Z"
    excluded_by_count = pr(
      "example/one", 4,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["docs"]
    )
    excluded_by_count["automation_reviewed_heads"] = -1
    excluded_by_count["merged_at"] = "2026-07-02T00:00:00Z"
    cases = {
      "repository filter" => [excluded_by_repository, ["--repo", "example/one"],
                              "calibration PR changed_files must be a nonnegative integer or null"],
      "date filter" => [excluded_by_date, ["--since", "2026-07-01"],
                        "calibration PR path_categories must be a list of nonempty strings"],
      "PR-count filter" => [excluded_by_count, ["--pr-count", "1"],
                            "calibration PR automation_reviewed_heads must be a nonnegative integer or null"]
    }

    results = cases.transform_values do |malformed, arguments, expected_error|
      repositories = ["example/one", malformed.fetch("repository")].uniq
      stdout, stderr, status = run_calibrator(
        calibration_dataset([selected, malformed], repositories:),
        *arguments
      )
      [stdout, stderr, status, expected_error]
    end
    failures = results.filter_map do |label, (stdout, stderr, status, expected_error)|
      next unless status.success? || !stdout.empty? || !stderr.include?(expected_error)

      "#{label}: status=#{status.exitstatus}, stdout=#{stdout.inspect}, stderr=#{stderr.inspect}"
    end

    assert_empty failures, failures.join("\n")
  end

  def test_hostile_cross_repo_record_cannot_emit_an_enforced_decision
    selected = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["app"]
    )
    selected["semantic_inspection"] = "reviewed"
    malformed = pr(
      "example/two", 2,
      files: "30", lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["docs"]
    )
    dataset = {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => true,
        "window" => "hostile cross-repository fixture",
        "repositories" => ["example/one", "example/two"],
        "reviewed_heads_decision" => {
          "disposition" => "enforced",
          "rationale" => "Excluded malformed evidence must never reach enforcement."
        }
      },
      "prs" => [selected, malformed]
    }

    stdout, stderr, status = run_calibrator(
      dataset,
      "--repo", "example/one",
      "--format", "decision"
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "calibration PR changed_files must be a nonnegative integer"
  end

  def test_raw_dataset_identities_must_be_unique_before_repository_filtering
    selected = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["app"]
    )
    duplicate = pr(
      "example/two", 2,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1,
      path_categories: ["docs"]
    )
    stdout, stderr, status = run_calibrator(
      calibration_dataset([selected, duplicate, duplicate.dup], repositories: ["example/one", "example/two"]),
      "--repo", "example/one"
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "calibration PR identities must be unique"
  end

  def test_pr_count_parses_all_candidate_timestamps_and_sorts_by_actual_instant
    newer = pr(
      "example/one", 1,
      files: 11, lines: 1, commits: 1, reviewed_heads: 1
    )
    newer["merged_at"] = "2026-07-01T00:00:00Z"
    older = pr(
      "example/one", 2,
      files: 22, lines: 1, commits: 1, reviewed_heads: 1
    )
    older["merged_at"] = "2026-07-01T00:30:00+01:00"

    stdout, stderr, status = run_calibrator(
      calibration_dataset([newer, older], repositories: ["example/one"]),
      "--pr-count", "1"
    )

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal 11, report.dig("distributions", "changed_files", "max")

    malformed = pr(
      "example/one", 3,
      files: 33, lines: 1, commits: 1, reviewed_heads: 1
    )
    malformed["merged_at"] = "0000-not-a-timestamp"
    stdout, stderr, status = run_calibrator(
      calibration_dataset([newer, malformed], repositories: ["example/one"]),
      "--pr-count", "1"
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "calibration PR merged_at must be an ISO 8601 timestamp"
  end

  def test_pr_count_validates_candidate_identities_and_duplicates_before_truncation
    selected = pr(
      "example/one", 1,
      files: 1, lines: 1, commits: 1, reviewed_heads: 1
    )
    invalid_number = pr(
      "example/one", 0,
      files: 2, lines: 1, commits: 1, reviewed_heads: 1
    )
    invalid_number["merged_at"] = "2026-06-01T00:00:00Z"

    stdout, stderr, status = run_calibrator(
      calibration_dataset([selected, invalid_number], repositories: ["example/one"]),
      "--pr-count", "1"
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "calibration PR number must be a positive integer"

    duplicate = selected.dup
    duplicate["merged_at"] = "2026-06-01T00:00:00Z"
    stdout, stderr, status = run_calibrator(
      calibration_dataset([selected, duplicate], repositories: ["example/one"]),
      "--pr-count", "1"
    )

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "calibration PR identities must be unique"
  end

  def test_collection_paginates_and_preserves_complete_review_object_history
    Dir.mktmpdir("autonomous-merge-calibration-collection") do |root|
      checkpoint = File.join(root, "dataset.json")
      sha_one = "1" * 40
      sha_two = "2" * 40
      responses = {
        discovery_path("example/one", page: 1, per_page: 2) => [
          list_entry(7, "2026-07-20T00:00:00Z"),
          list_entry(6, "2026-07-19T00:00:00Z")
        ],
        discovery_path("example/one", page: 2, per_page: 2) => [],
        "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z", changed_files: 3),
        page_path("example/one", 7, "files", 1, 2) => [
          github_file("lib/a.rb", additions: 2),
          github_file("lib/b.rb", deletions: 1)
        ],
        page_path("example/one", 7, "files", 2, 2) => [
          github_file("docs/c.md", additions: 3)
        ],
        page_path("example/one", 7, "commits", 1, 2) => [
          { "sha" => "a" * 40 }
        ],
        page_path("example/one", 7, "reviews", 1, 2) => [
          github_review("COMMENTED", sha_one, id: 1),
          github_review("DISMISSED", sha_two, id: 2)
        ],
        page_path("example/one", 7, "reviews", 2, 2) => [
          github_review("PENDING", "viewer-local-draft", id: 3),
          github_review("APPROVED", nil, id: 4)
        ],
        page_path("example/one", 7, "reviews", 3, 2) => []
      }
      calls = []
      api = mapped_api(responses, calls:)

      dataset = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 1,
        page_size: 2,
        api:
      )
      collected = dataset.fetch("prs").fetch(0)

      assert dataset.dig("scope", "complete")
      assert_equal false, dataset.fetch("merge_decisions_emitted")
      assert_equal 3, collected.fetch("changed_files")
      assert_equal 6, collected.fetch("changed_lines")
      assert_equal [sha_one, sha_two], collected.fetch("reviewed_head_shas")
      assert_nil collected.fetch("reviewed_heads")
      assert_equal false, collected.fetch("review_head_history_complete")
      assert_equal(
        %w[COMMENTED DISMISSED PENDING APPROVED],
        collected.fetch("reviews").map { |review| review["state"] }
      )
      assert_includes calls, discovery_path("example/one", page: 2, per_page: 2)
      assert_includes calls, page_path("example/one", 7, "files", 2, 2)
      assert_includes calls, page_path("example/one", 7, "reviews", 3, 2)
      assert_equal dataset, JSON.parse(File.read(checkpoint, encoding: "UTF-8"))
    end
  end

  def test_collection_rejects_unknown_review_states
    error = assert_raises(AutonomousMergeCalibration::CollectionError) do
      AutonomousMergeCalibration.normalize_review(
        github_review("FUTURE_SUBMITTED_STATE", "f" * 40)
      )
    end

    assert_equal "review-evidence", error.kind
    assert_includes error.message, "GitHub review state is unrecognized"
  end

  def test_github_client_rejects_invalid_utf8_body_with_headers_as_collection_error
    response = +"HTTP/2 200\nx-ratelimit-remaining: 99\n\n{\"body\":\""
    response << "\xFF"
    response << "\"}"

    with_github_api_response(response) do
      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration::GitHubClient.new.call("repos/example/repo/pulls/7")
      end

      assert_equal "api", error.kind
      assert_equal(
        "GitHub API response is not valid UTF-8 for repos/example/repo/pulls/7",
        error.message
      )
    end
  end

  def test_github_client_rejects_lone_surrogates_in_json_keys_and_values_as_collection_error
    payloads = [
      %q({"metadata":{"key":"\udcff"}}),
      %q({"metadata":{"\udcff":"value"}})
    ]

    payloads.each do |body|
      with_github_api_response("HTTP/2 200\nx-ratelimit-remaining: 99\n\n#{body}") do
        error = assert_raises(AutonomousMergeCalibration::CollectionError) do
          AutonomousMergeCalibration::GitHubClient.new.call("repos/example/repo/pulls/7")
        end

        assert_equal "api", error.kind
        assert_equal(
          "GitHub API response contains invalid Unicode scalar data for repos/example/repo/pulls/7",
          error.message
        )
      end
    end
  end

  def test_historical_file_normalization_preserves_and_validates_rename_copy_sources
    renamed = AutonomousMergeCalibration.normalize_file(
      github_file(
        "lib/new.rb",
        additions: 3,
        deletions: 2,
        status: "renamed",
        previous_filename: ".agents/agent-workflow.yml"
      )
    )
    copied = AutonomousMergeCalibration.normalize_file(
      github_file(
        "docs/copied.md",
        additions: 4,
        status: "copied",
        previous_filename: "skills/pr-batch/SKILL.md"
      )
    )

    assert_equal(
      {
        "path" => "lib/new.rb",
        "status" => "renamed",
        "previous_path" => ".agents/agent-workflow.yml",
        "additions" => 3,
        "deletions" => 2
      },
      renamed
    )
    assert_equal(
      {
        "path" => "docs/copied.md",
        "status" => "copied",
        "previous_path" => "skills/pr-batch/SKILL.md",
        "additions" => 4,
        "deletions" => 0
      },
      copied
    )

    invalid_files = [
      github_file("lib/new.rb", status: "renamed"),
      github_file("lib/copy.rb", status: "copied", previous_filename: ""),
      github_file("lib/current.rb", previous_filename: "lib/old.rb"),
      github_file("lib/current.rb", status: "future-status"),
      github_file("lib/current.rb").tap { |file| file.delete("status") }
    ]
    invalid_files.each do |file|
      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.normalize_file(file)
      end

      assert_equal "file-evidence", error.kind
    end
  end

  def test_historical_rename_copy_sources_contribute_paths_and_categories_without_double_counting_metrics
    Dir.mktmpdir("autonomous-merge-calibration-rename-copy") do |root|
      checkpoint = File.join(root, "dataset.json")
      responses = {
        discovery_path("example/one", page: 1, per_page: 100) => [
          list_entry(7, "2026-07-20T00:00:00Z")
        ],
        "repos/example/one/pulls/7" => detail(
          7,
          "2026-07-20T00:00:00Z",
          changed_files: 2
        ),
        page_path("example/one", 7, "files", 1, 100) => [
          github_file(
            "lib/new.rb",
            additions: 3,
            deletions: 2,
            status: "renamed",
            previous_filename: ".agents/agent-workflow.yml"
          ),
          github_file(
            "docs/copied.md",
            additions: 4,
            status: "copied",
            previous_filename: "skills/pr-batch/SKILL.md"
          )
        ],
        page_path("example/one", 7, "commits", 1, 100) => [{ "sha" => "7" * 40 }],
        page_path("example/one", 7, "reviews", 1, 100) => []
      }

      dataset = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 1,
        api: mapped_api(responses)
      )
      collected = dataset.fetch("prs").fetch(0)

      assert_equal(
        [
          "lib/new.rb",
          ".agents/agent-workflow.yml",
          "docs/copied.md",
          "skills/pr-batch/SKILL.md"
        ],
        collected.fetch("file_paths")
      )
      assert_equal %w[.agents docs lib skills], collected.fetch("path_categories")
      assert_equal 2, collected.fetch("changed_files")
      assert_equal 9, collected.fetch("changed_lines")
    end
  end

  def test_collection_checkpoints_rate_limit_and_resumes_without_refetching_completed_prs
    Dir.mktmpdir("autonomous-merge-calibration-resume") do |root|
      checkpoint = File.join(root, "dataset.json")
      discovery = discovery_path("example/one", page: 1, per_page: 100)
      first_calls = []
      first_api = lambda do |path|
        first_calls << path
        case path
        when discovery
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when "repos/example/one/pulls/8"
          detail(8, "2026-07-21T00:00:00Z")
        when page_path("example/one", 8, "files", 1, 100)
          [github_file("lib/eight.rb")]
        when page_path("example/one", 8, "commits", 1, 100)
          [{ "sha" => "8" * 40 }]
        when page_path("example/one", 8, "reviews", 1, 100)
          []
        when "repos/example/one/pulls/7"
          raise AutonomousMergeCalibration::RateLimitError, "rate limit exhausted"
        else
          raise "unexpected first-run path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::RateLimitError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 2,
          api: first_api
        )
      end
      assert_includes error.message, "rate limit"
      partial = JSON.parse(File.read(checkpoint, encoding: "UTF-8"))
      assert_equal false, partial.dig("scope", "complete")
      assert_equal "rate-limit", partial.dig("scope", "last_error", "kind")
      assert_equal [8], partial.dig("scope", "repository_progress", "example/one", "completed_pr_numbers")

      resume_calls = []
      resume_api = mapped_api(
        {
          "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z"),
          page_path("example/one", 7, "files", 1, 100) => [github_file("lib/seven.rb")],
          page_path("example/one", 7, "commits", 1, 100) => [{ "sha" => "7" * 40 }],
          page_path("example/one", 7, "reviews", 1, 100) => []
        },
        calls: resume_calls
      )
      complete = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 2,
        api: resume_api
      )

      assert complete.dig("scope", "complete")
      assert_equal [7, 8], complete.fetch("prs").map { |entry| entry.fetch("number") }.sort
      refute(resume_calls.any? { |path| path.include?("/pulls/8") })
      refute_includes resume_calls, discovery
    end
  end

  def test_collection_terminally_records_malformed_reviewer_and_resumes_past_it
    Dir.mktmpdir("autonomous-merge-calibration-terminal-pr") do |root|
      checkpoint = File.join(root, "dataset.json")
      responses = {
        discovery_path("example/one", page: 1, per_page: 100) => [
          list_entry(8, "2026-07-21T00:00:00Z"),
          list_entry(7, "2026-07-20T00:00:00Z")
        ],
        "repos/example/one/pulls/8" => detail(8, "2026-07-21T00:00:00Z"),
        page_path("example/one", 8, "files", 1, 100) => [github_file("lib/eight.rb")],
        page_path("example/one", 8, "commits", 1, 100) => [{ "sha" => "8" * 40 }],
        page_path("example/one", 8, "reviews", 1, 100) => [
          github_review("APPROVED", "8" * 40).merge("user" => nil)
        ],
        "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z"),
        page_path("example/one", 7, "files", 1, 100) => [github_file("lib/seven.rb")],
        page_path("example/one", 7, "commits", 1, 100) => [{ "sha" => "7" * 40 }],
        page_path("example/one", 7, "reviews", 1, 100) => []
      }

      partial = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 2,
        api: mapped_api(responses)
      )

      assert_equal false, partial.dig("scope", "complete")
      collected_numbers = partial.fetch("prs").map { |entry| entry.fetch("number") }
      assert_equal [7], collected_numbers
      assert_equal(
        [
          {
            "repository" => "example/one",
            "number" => 8,
            "kind" => "review-evidence",
            "reason" => "GitHub review author evidence is malformed"
          }
        ],
        partial.dig("scope", "terminal_pr_failures")
      )
      assert_equal false, partial.fetch("merge_decisions_emitted")

      resume_calls = []
      resumed = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 2,
        api: lambda do |path|
          resume_calls << path
          raise "unexpected API path #{path}"
        end
      )

      assert_equal partial, resumed
      assert_empty resume_calls
    end
  end

  def test_collection_terminally_records_a_mid_pagination_change
    Dir.mktmpdir("autonomous-merge-calibration-moving-pr") do |root|
      checkpoint = File.join(root, "dataset.json")
      files_path = page_path("example/one", 7, "files", 1, 100)
      file_reads = 0
      api = lambda do |path|
        case path
        when discovery_path("example/one", page: 1, per_page: 100)
          [list_entry(7, "2026-07-20T00:00:00Z")]
        when "repos/example/one/pulls/7"
          detail(7, "2026-07-20T00:00:00Z")
        when files_path
          file_reads += 1
          additions = file_reads == 1 ? 1 : 2
          [github_file("lib/a.rb", additions:)]
        when page_path("example/one", 7, "commits", 1, 100)
          [{ "sha" => "7" * 40 }]
        when page_path("example/one", 7, "reviews", 1, 100)
          []
        else
          raise "unexpected API path #{path}"
        end
      end

      dataset = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 1,
        api:
      )

      assert_equal false, dataset.dig("scope", "complete")
      assert_empty dataset.fetch("prs")
      assert_equal "pagination", dataset.dig("scope", "terminal_pr_failures", 0, "kind")
      assert_includes dataset.dig("scope", "terminal_pr_failures", 0, "reason"), "changed while paginating"
    end
  end

  def test_collection_terminally_records_duplicate_review_identities
    Dir.mktmpdir("autonomous-merge-calibration-duplicate-reviews") do |root|
      checkpoint = File.join(root, "dataset.json")
      responses = {
        discovery_path("example/one", page: 1, per_page: 100) => [
          list_entry(7, "2026-07-20T00:00:00Z")
        ],
        "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z"),
        page_path("example/one", 7, "files", 1, 100) => [github_file("lib/a.rb")],
        page_path("example/one", 7, "commits", 1, 100) => [{ "sha" => "7" * 40 }],
        page_path("example/one", 7, "reviews", 1, 100) => [
          github_review("COMMENTED", "7" * 40, id: 1),
          github_review("APPROVED", "7" * 40, id: 1)
        ]
      }

      dataset = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 1,
        api: mapped_api(responses)
      )

      assert_equal false, dataset.dig("scope", "complete")
      assert_empty dataset.fetch("prs")
      assert_equal "pagination", dataset.dig("scope", "terminal_pr_failures", 0, "kind")
      assert_includes dataset.dig("scope", "terminal_pr_failures", 0, "reason"), "repeated reviews identity"
    end
  end

  def test_collection_terminally_records_changed_files_mismatch_and_cap
    [
      ["1", [], "detail is malformed"],
      [2, [github_file("lib/a.rb")], "does not match"],
      [3_000, [], "3,000-file API cap"]
    ].each do |changed_files, files, expected_reason|
      Dir.mktmpdir("autonomous-merge-calibration-file-count") do |root|
        checkpoint = File.join(root, "dataset.json")
        responses = {
          discovery_path("example/one", page: 1, per_page: 100) => [
            list_entry(7, "2026-07-20T00:00:00Z")
          ],
          "repos/example/one/pulls/7" => detail(
            7,
            "2026-07-20T00:00:00Z",
            changed_files:
          ),
          page_path("example/one", 7, "files", 1, 100) => files,
          page_path("example/one", 7, "commits", 1, 100) => [{ "sha" => "7" * 40 }],
          page_path("example/one", 7, "reviews", 1, 100) => []
        }

        dataset = AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 1,
          api: mapped_api(responses)
        )

        assert_equal false, dataset.dig("scope", "complete")
        assert_empty dataset.fetch("prs")
        assert_equal "file-evidence", dataset.dig("scope", "terminal_pr_failures", 0, "kind")
        assert_includes dataset.dig("scope", "terminal_pr_failures", 0, "reason"), expected_reason
      end
    end
  end

  def test_collection_terminally_records_untrustworthy_commit_counts
    [
      ["1", [{ "sha" => "7" * 40 }], "detail is malformed"],
      [2, [{ "sha" => "7" * 40 }], "does not match"],
      [250, [], "250-commit API cap"]
    ].each do |commit_count, commits, expected_reason|
      Dir.mktmpdir("autonomous-merge-calibration-commit-count") do |root|
        checkpoint = File.join(root, "dataset.json")
        responses = {
          discovery_path("example/one", page: 1, per_page: 100) => [
            list_entry(7, "2026-07-20T00:00:00Z")
          ],
          "repos/example/one/pulls/7" => detail(
            7,
            "2026-07-20T00:00:00Z",
            commits: commit_count
          ),
          page_path("example/one", 7, "files", 1, 100) => [github_file("lib/a.rb")],
          page_path("example/one", 7, "commits", 1, 100) => commits,
          page_path("example/one", 7, "reviews", 1, 100) => []
        }

        dataset = AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 1,
          api: mapped_api(responses)
        )

        assert_equal false, dataset.dig("scope", "complete")
        assert_empty dataset.fetch("prs")
        assert_equal "commit-evidence", dataset.dig("scope", "terminal_pr_failures", 0, "kind")
        assert_includes dataset.dig("scope", "terminal_pr_failures", 0, "reason"), expected_reason
        assert_equal false, dataset.fetch("merge_decisions_emitted")
      end
    end
  end

  def test_collection_terminally_records_pr_detail_that_changes_around_pagination
    %i[changed_files commits].each do |moving_field|
      Dir.mktmpdir("autonomous-merge-calibration-moving-detail") do |root|
        checkpoint = File.join(root, "dataset.json")
        detail_reads = 0
        api = lambda do |path|
          case path
          when discovery_path("example/one", page: 1, per_page: 100)
            [list_entry(7, "2026-07-20T00:00:00Z")]
          when "repos/example/one/pulls/7"
            detail_reads += 1
            detail_options = { moving_field => detail_reads }
            detail(7, "2026-07-20T00:00:00Z", **detail_options)
          when page_path("example/one", 7, "files", 1, 100)
            [github_file("lib/a.rb")]
          when page_path("example/one", 7, "commits", 1, 100)
            [{ "sha" => "7" * 40 }]
          when page_path("example/one", 7, "reviews", 1, 100)
            []
          else
            raise "unexpected API path #{path}"
          end
        end

        dataset = AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 1,
          api:
        )

        assert_equal false, dataset.dig("scope", "complete"), moving_field
        assert_empty dataset.fetch("prs"), moving_field
        assert_equal "pagination", dataset.dig("scope", "terminal_pr_failures", 0, "kind"), moving_field
        assert_includes dataset.dig("scope", "terminal_pr_failures", 0, "reason"), "detail changed", moving_field
      end
    end
  end

  def test_incomplete_discovery_resume_restarts_page_one_when_closed_pr_order_shifts
    Dir.mktmpdir("autonomous-merge-calibration-shifting-discovery") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_one = discovery_path("example/one", page: 1, per_page: 2)
      page_two = discovery_path("example/one", page: 2, per_page: 2)
      first_api = lambda do |path|
        case path
        when page_one
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when page_two
          raise AutonomousMergeCalibration::RateLimitError, "rate limit exhausted"
        else
          raise "unexpected first-run path #{path}"
        end
      end

      assert_raises(AutonomousMergeCalibration::RateLimitError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 2,
          page_size: 2,
          api: first_api
        )
      end
      assert_equal(
        2,
        JSON.parse(File.read(checkpoint)).dig(
          "scope", "repository_progress", "example/one", "discovery_next_page"
        )
      )

      resume_calls = []
      responses = {
        page_one => [
          list_entry(9, "2026-07-22T00:00:00Z"),
          list_entry(8, "2026-07-21T00:00:00Z")
        ],
        page_two => [list_entry(7, "2026-07-20T00:00:00Z")],
        "repos/example/one/pulls/9" => detail(9, "2026-07-22T00:00:00Z"),
        page_path("example/one", 9, "files", 1, 2) => [github_file("lib/nine.rb")],
        page_path("example/one", 9, "commits", 1, 2) => [{ "sha" => "9" * 40 }],
        page_path("example/one", 9, "reviews", 1, 2) => [],
        "repos/example/one/pulls/8" => detail(8, "2026-07-21T00:00:00Z"),
        page_path("example/one", 8, "files", 1, 2) => [github_file("lib/eight.rb")],
        page_path("example/one", 8, "commits", 1, 2) => [{ "sha" => "8" * 40 }],
        page_path("example/one", 8, "reviews", 1, 2) => []
      }
      complete = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        pr_count: 2,
        page_size: 2,
        api: mapped_api(responses, calls: resume_calls)
      )

      assert_equal page_one, resume_calls.first
      assert_equal [8, 9], complete.fetch("prs").map { |entry| entry.fetch("number") }.sort
      assert complete.dig("scope", "complete")
    end
  end

  def test_collection_fails_closed_when_page_one_changes_during_discovery
    Dir.mktmpdir("autonomous-merge-calibration-moving-window") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_one_reads = 0
      api = lambda do |path|
        case path
        when discovery_path("example/one", page: 1, per_page: 2)
          page_one_reads += 1
          if page_one_reads == 1
            [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
          else
            [list_entry(9, "2026-07-22T00:00:00Z"), list_entry(8, "2026-07-21T00:00:00Z")]
          end
        when discovery_path("example/one", page: 2, per_page: 2)
          []
        else
          raise "unexpected API path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 2,
          page_size: 2,
          api:
        )
      end
      saved = JSON.parse(File.read(checkpoint))
      progress = saved.dig("scope", "repository_progress", "example/one")

      assert_equal "pagination", error.kind
      assert_includes error.message, "changed while paginating"
      assert_equal false, saved.dig("scope", "complete")
      assert_equal false, progress.fetch("discovery_complete")
      assert_equal 1, progress.fetch("discovery_next_page")
      assert_equal [], progress.fetch("discovered_merged_prs")
    end
  end

  def test_collection_fails_closed_when_later_page_changes_during_discovery
    Dir.mktmpdir("autonomous-merge-calibration-moving-later-page") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_two_reads = 0
      api = lambda do |path|
        case path
        when discovery_path("example/one", page: 1, per_page: 2)
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when discovery_path("example/one", page: 2, per_page: 2)
          page_two_reads += 1
          if page_two_reads == 1
            [list_entry(6, "2026-07-19T00:00:00Z"), list_entry(5, "2026-07-18T00:00:00Z")]
          else
            [list_entry(6, "2026-07-19T00:00:00Z"), list_entry(4, "2026-07-17T00:00:00Z")]
          end
        when discovery_path("example/one", page: 3, per_page: 2)
          []
        else
          raise "unexpected API path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          since: Date.new(2027, 1, 1),
          page_size: 2,
          api:
        )
      end
      saved = JSON.parse(File.read(checkpoint))
      progress = saved.dig("scope", "repository_progress", "example/one")

      assert_equal "pagination", error.kind
      assert_includes error.message, "changed while paginating"
      assert_equal 2, page_two_reads
      assert_equal false, saved.dig("scope", "complete")
      assert_equal false, progress.fetch("discovery_complete")
      assert_equal 1, progress.fetch("discovery_next_page")
      assert_equal [], progress.fetch("discovered_merged_prs")
    end
  end

  def test_verification_pagination_failure_checkpoints_restart_from_page_one
    Dir.mktmpdir("autonomous-merge-calibration-verification-failure") do |root|
      checkpoint = File.join(root, "dataset.json")
      page_two_reads = 0
      api = lambda do |path|
        case path
        when discovery_path("example/one", page: 1, per_page: 2)
          [list_entry(8, "2026-07-21T00:00:00Z"), list_entry(7, "2026-07-20T00:00:00Z")]
        when discovery_path("example/one", page: 2, per_page: 2)
          page_two_reads += 1
          unless page_two_reads == 1
            raise AutonomousMergeCalibration::RateLimitError, "verification rate limit exhausted"
          end

          [list_entry(6, "2026-07-19T00:00:00Z"), list_entry(5, "2026-07-18T00:00:00Z")]
        when discovery_path("example/one", page: 3, per_page: 2)
          []
        else
          raise "unexpected API path #{path}"
        end
      end

      error = assert_raises(AutonomousMergeCalibration::RateLimitError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          since: Date.new(2027, 1, 1),
          page_size: 2,
          api:
        )
      end
      saved = JSON.parse(File.read(checkpoint))
      progress = saved.dig("scope", "repository_progress", "example/one")

      assert_includes error.message, "verification rate limit"
      assert_equal "rate-limit", saved.dig("scope", "last_error", "kind")
      assert_equal false, saved.dig("scope", "complete")
      assert_equal false, progress.fetch("discovery_complete")
      assert_equal 1, progress.fetch("discovery_next_page")
      assert_equal [], progress.fetch("discovered_merged_prs")
    end
  end

  def test_collection_fails_closed_and_checkpoints_malformed_pagination
    Dir.mktmpdir("autonomous-merge-calibration-pagination") do |root|
      checkpoint = File.join(root, "dataset.json")
      api = mapped_api(
        {
          discovery_path("example/one", page: 1, per_page: 100) => [
            list_entry(7, "2026-07-20T00:00:00Z")
          ],
          "repos/example/one/pulls/7" => detail(7, "2026-07-20T00:00:00Z"),
          page_path("example/one", 7, "files", 1, 100) => { "not" => "a list" }
        }
      )

      dataset = AutonomousMergeCalibration.collect(
        checkpoint_path: checkpoint,
        repositories: ["example/one"],
        since: Date.new(2026, 7, 1),
        api:
      )
      checkpoint_data = JSON.parse(File.read(checkpoint, encoding: "UTF-8"))

      assert_equal dataset, checkpoint_data
      assert_equal false, checkpoint_data.dig("scope", "complete")
      assert_equal "pagination", checkpoint_data.dig("scope", "terminal_pr_failures", 0, "kind")
    end
  end

  def test_checkpoint_cannot_claim_completed_pr_detail_that_is_missing
    Dir.mktmpdir("autonomous-merge-calibration-incomplete-checkpoint") do |root|
      checkpoint = File.join(root, "dataset.json")
      request = AutonomousMergeCalibration.collection_request(
        repositories: ["example/one"],
        since: nil,
        pr_count: 1,
        page_size: 100
      )
      dataset = AutonomousMergeCalibration.load_or_initialize_checkpoint(checkpoint, request)
      progress = dataset.dig("scope", "repository_progress", "example/one")
      progress["discovery_complete"] = true
      progress["selected_pr_numbers"] = [7]
      progress["completed_pr_numbers"] = [7]
      dataset.fetch("scope")["complete"] = true
      File.write(checkpoint, JSON.generate(dataset))

      error = assert_raises(AutonomousMergeCalibration::CollectionError) do
        AutonomousMergeCalibration.collect(
          checkpoint_path: checkpoint,
          repositories: ["example/one"],
          pr_count: 1,
          api: ->(path) { raise "unexpected API path #{path}" }
        )
      end

      assert_equal "checkpoint", error.kind
      assert_includes error.message, "completed PR detail is missing"
    end
  end

  def test_checkpoint_securely_creates_missing_parent_directories
    Dir.mktmpdir("autonomous-merge-calibration-checkpoint-parent") do |root|
      parent = File.join(root, "private", "nested")
      checkpoint = File.join(parent, "dataset.json")
      dataset = { "checkpoint" => true }

      AutonomousMergeCalibration.write_checkpoint(checkpoint, dataset)

      assert_equal dataset, JSON.parse(File.read(checkpoint, encoding: "UTF-8"))
      assert_equal 0o700, File.stat(File.join(root, "private")).mode & 0o777
      assert_equal 0o700, File.stat(parent).mode & 0o777
      assert_equal 0o600, File.stat(checkpoint).mode & 0o777
    end
  end

  def test_collection_cli_writes_the_explicit_checkpoint_and_emits_no_merge_decisions
    Dir.mktmpdir("autonomous-merge-calibration-cli") do |root|
      checkpoint = File.join(root, "dataset.json")
      fake_gh = File.join(root, "fake-gh")
      File.write(fake_gh, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        path = ARGV.last
        body = case path
               when "repos/example/one/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1"
                 [{ "number" => 7, "merged_at" => "2026-07-20T00:00:00Z" }]
               when "repos/example/one/pulls/7"
                 {
                   "number" => 7,
                   "merged_at" => "2026-07-20T00:00:00Z",
                   "changed_files" => 1,
                   "commits" => 1
                 }
               when "repos/example/one/pulls/7/files?per_page=100&page=1"
                 [{ "filename" => "lib/service.rb", "status" => "modified", "additions" => 2, "deletions" => 1 }]
               when "repos/example/one/pulls/7/commits?per_page=100&page=1"
                 [{ "sha" => "7" * 40 }]
               when "repos/example/one/pulls/7/reviews?per_page=100&page=1"
                 []
               else
                 warn "unexpected path #{path}"
                 exit 1
               end
        print "HTTP/2 200\nx-ratelimit-remaining: 99\n\n#{JSON.generate(body)}"
      RUBY
      File.chmod(0o755, fake_gh)

      stdout, stderr, status = Open3.capture3(
        { "AUTONOMOUS_MERGE_GH" => fake_gh },
        "ruby", SCRIPT,
        "--collect", checkpoint,
        "--repo", "example/one",
        "--pr-count", "1"
      )
      assert status.success?, stderr
      emitted = JSON.parse(stdout)
      saved = JSON.parse(File.read(checkpoint, encoding: "UTF-8"))

      assert emitted.dig("scope", "complete")
      assert_equal false, emitted.fetch("merge_decisions_emitted")
      assert_equal emitted, saved
      collected_numbers = saved.fetch("prs").map { |entry| entry.fetch("number") }
      assert_equal [7], collected_numbers
    end
  end

  private

  def with_github_api_response(response)
    Dir.mktmpdir("autonomous-merge-calibration-gh-api") do |root|
      payload = File.join(root, "payload")
      fake_gh = File.join(root, "gh")
      File.binwrite(payload, response)
      File.write(fake_gh, <<~'RUBY')
        #!/usr/bin/env ruby
        $stdout.binmode
        $stdout.write(File.binread(ENV.fetch("AUTONOMOUS_MERGE_TEST_RESPONSE")))
      RUBY
      File.chmod(0o755, fake_gh)

      original_command = ENV["AUTONOMOUS_MERGE_GH"]
      original_response = ENV["AUTONOMOUS_MERGE_TEST_RESPONSE"]
      ENV["AUTONOMOUS_MERGE_GH"] = fake_gh
      ENV["AUTONOMOUS_MERGE_TEST_RESPONSE"] = payload
      yield
    ensure
      ENV["AUTONOMOUS_MERGE_GH"] = original_command
      ENV["AUTONOMOUS_MERGE_TEST_RESPONSE"] = original_response
    end
  end

  def calibration_dataset(prs, repositories:)
    {
      "contract" => "autonomous-merge-calibration-dataset",
      "version" => 1,
      "scope" => {
        "complete" => false,
        "window" => "validation test fixture",
        "repositories" => repositories
      },
      "prs" => prs
    }
  end

  def run_calibrator(dataset, *arguments)
    Tempfile.create(["calibration", ".json"]) do |file|
      file.write(JSON.generate(dataset))
      file.flush
      return Open3.capture3("ruby", SCRIPT, "--input", file.path, *arguments)
    end
  end

  def mapped_api(responses, calls: [])
    lambda do |path|
      calls << path
      raise "unexpected API path #{path}" unless responses.key?(path)

      responses.fetch(path)
    end
  end

  def discovery_path(repository, page:, per_page:)
    "repos/#{repository}/pulls?state=closed&sort=updated&direction=desc&per_page=#{per_page}&page=#{page}"
  end

  def page_path(repository, number, collection, page, per_page)
    "repos/#{repository}/pulls/#{number}/#{collection}?per_page=#{per_page}&page=#{page}"
  end

  def list_entry(number, merged_at)
    { "number" => number, "merged_at" => merged_at }
  end

  def detail(number, merged_at, changed_files: 1, commits: 1)
    {
      "number" => number,
      "merged_at" => merged_at,
      "changed_files" => changed_files,
      "commits" => commits
    }
  end

  def github_file(path, additions: 0, deletions: 0, status: "modified", previous_filename: nil)
    result = { "filename" => path, "status" => status, "additions" => additions, "deletions" => deletions }
    result["previous_filename"] = previous_filename unless previous_filename.nil?
    result
  end

  def github_review(state, commit_id, id: 1)
    {
      "id" => id,
      "state" => state,
      "commit_id" => commit_id,
      "user" => { "login" => "reviewer", "type" => "User" },
      "submitted_at" => state == "PENDING" ? nil : "2026-07-20T01:00:00Z"
    }
  end

  def pr(repository, number, files:, lines:, commits:, reviewed_heads:, path_categories: [])
    {
      "repository" => repository,
      "number" => number,
      "merged_at" => "2026-07-01T00:00:00Z",
      "changed_files" => files,
      "changed_lines" => lines,
      "commits" => commits,
      "reviewed_heads" => reviewed_heads,
      "automation_reviewed_heads" => reviewed_heads.nil? ? nil : [reviewed_heads - 1, 0].max,
      "path_categories" => path_categories
    }
  end
end
