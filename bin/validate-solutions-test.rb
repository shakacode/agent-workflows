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
      FileUtils.mkdir_p(File.join(root, "workflows"))
      File.write(File.join(root, "workflows/pr-processing.md"), "# Workflow\n")
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

  def test_nested_solution_docs_fail_while_flat_solution_remains_valid
    with_solution_root do |root|
      write_solution(root, "coordination-unknown-state.md", valid_solution)
      %w[review/deep/second.md coordination/first.md .archive/deep/hidden.md].each do |relative|
        path = File.join(root, "docs/solutions", relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, valid_solution)
      end

      expected = [
        "docs/solutions/.archive/deep/hidden.md: nested solution docs are not allowed",
        "docs/solutions/coordination/first.md: nested solution docs are not allowed",
        "docs/solutions/review/deep/second.md: nested solution docs are not allowed"
      ]
      assert_equal expected, ValidateSolutions.validate(root)
    end
  end

  def test_missing_solution_docs_fails
    with_solution_root do |root|
      write_solution(root, "README.md", "# Solutions\n")

      assert_equal ["docs/solutions: no solution docs found"], ValidateSolutions.validate(root)
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

  def test_unpadded_yaml_date_fails_before_date_normalization
    with_solution_root do |root|
      write_solution(root, "unpadded-date.md", valid_solution.sub('date: "2026-07-02"', "date: 2026-7-2"))

      assert_includes ValidateSolutions.validate(root), "docs/solutions/unpadded-date.md: date must be ISO 8601 YYYY-MM-DD"
    end
  end

  def test_unquoted_strict_yaml_date_passes
    with_solution_root do |root|
      write_solution(root, "unquoted-date.md", valid_solution.sub('date: "2026-07-02"', "date: 2026-07-02"))

      assert_empty ValidateSolutions.validate(root)
    end
  end

  def test_unquoted_date_with_inline_comment_passes
    with_solution_root do |root|
      write_solution(root, "commented-date.md", valid_solution.sub('date: "2026-07-02"', "date: 2026-07-02  # learned date"))

      assert_empty ValidateSolutions.validate(root)
    end
  end

  def test_missing_related_file_fails
    with_solution_root do |root|
      write_solution(root, "missing-related-file.md", valid_solution.sub("workflows/pr-processing.md", "missing/path.md"))

      assert_includes ValidateSolutions.validate(root), "docs/solutions/missing-related-file.md: related_files not found: missing/path.md"
    end
  end
end
