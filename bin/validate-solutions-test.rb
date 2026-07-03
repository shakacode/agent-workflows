#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

SCRIPT = File.expand_path("validate-solutions", __dir__)
load SCRIPT

class ValidateSolutionsTest < Minitest::Test
  def with_solution_root
    Dir.mktmpdir("validate-solutions-test") do |root|
      FileUtils.mkdir_p(File.join(root, "docs/solutions"))
      yield root
    end
  end

  def write_solution(root, name, body)
    File.write(File.join(root, "docs/solutions", name), body)
  end

  def valid_solution
    <<~MARKDOWN
      ---
      title: Preserve UNKNOWN coordination state
      date: "2026-07-02"
      category: coordination
      component: pr-processing
      problem_type: degraded-private-state
      symptoms:
        - Bounded coordination reads time out or return setup errors.
      root_cause: Coordination reads are observational and can degrade independently from claim results.
      resolution: Report the affected read as UNKNOWN unless a direct compare-and-swap claim succeeds.
      related_files:
        - workflows/pr-processing.md
      related_issues:
        - https://github.com/shakacode/agent-workflows/issues/37
      ---

      Keep degraded private state explicit in handoffs.
    MARKDOWN
  end

  def test_valid_solution_passes_and_readme_is_skipped
    with_solution_root do |root|
      write_solution(root, "README.md", "# Solutions\n")
      write_solution(root, "coordination-unknown-state.md", valid_solution)

      assert_empty ValidateSolutions.validate(root)
    end
  end

  def test_missing_frontmatter_fails
    with_solution_root do |root|
      write_solution(root, "missing-frontmatter.md", "# Missing\n")

      assert_equal ["docs/solutions/missing-frontmatter.md: missing YAML frontmatter"], ValidateSolutions.validate(root)
    end
  end

  def test_missing_required_field_fails
    with_solution_root do |root|
      write_solution(root, "missing-field.md", valid_solution.sub("resolution: Report the affected read as UNKNOWN unless a direct compare-and-swap claim succeeds.\n", ""))

      assert_includes ValidateSolutions.validate(root), "docs/solutions/missing-field.md: missing required fields: resolution"
    end
  end

  def test_invalid_list_field_fails
    with_solution_root do |root|
      write_solution(root, "invalid-list.md", valid_solution.sub("symptoms:\n  - Bounded coordination reads time out or return setup errors.\n", "symptoms: Bounded coordination reads time out.\n"))

      assert_includes ValidateSolutions.validate(root), "docs/solutions/invalid-list.md: symptoms must be a list"
    end
  end

  def test_invalid_date_fails
    with_solution_root do |root|
      write_solution(root, "invalid-date.md", valid_solution.sub('date: "2026-07-02"', 'date: "July 2, 2026"'))

      assert_includes ValidateSolutions.validate(root), "docs/solutions/invalid-date.md: date must be ISO 8601 YYYY-MM-DD"
    end
  end

  def test_iso_basic_and_datetime_dates_fail
    with_solution_root do |root|
      write_solution(root, "basic-date.md", valid_solution.sub('date: "2026-07-02"', 'date: "20260702"'))
      write_solution(root, "datetime.md", valid_solution.sub('date: "2026-07-02"', 'date: "2026-07-02T12:00:00Z"'))

      failures = ValidateSolutions.validate(root)
      assert_includes failures, "docs/solutions/basic-date.md: date must be ISO 8601 YYYY-MM-DD"
      assert_includes failures, "docs/solutions/datetime.md: date must be ISO 8601 YYYY-MM-DD"
    end
  end
end
