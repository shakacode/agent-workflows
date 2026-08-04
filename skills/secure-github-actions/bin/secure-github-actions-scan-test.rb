#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/secure_github_actions_scanner"
load File.expand_path("../../../bin/validate-review-findings", __dir__)

class SecureGitHubActionsScanTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures", __dir__)
  SCANNER = File.expand_path("secure-github-actions-scan", __dir__)

  def test_reports_expression_syntax_inside_parsed_run_values
    result = SecureGitHubActions::Scanner.new(File.join(FIXTURES, "expression-in-run")).scan

    assert_equal 1, result.findings.length
    finding = result.findings.first
    assert_equal "secure-github-actions/expression-in-run", finding.fetch("rule_id")
    assert_equal true, finding.fetch("deterministic")
    assert_equal ".github/workflows/vulnerable.yml", finding.dig("location", "file")
    assert_equal "jobs.build.steps.0.run", finding.dig("location", "symbol")
  end

  def test_reports_secrets_inherit_on_reusable_workflow_calls
    result = SecureGitHubActions::Scanner.new(File.join(FIXTURES, "secrets-inherit")).scan

    assert_equal 1, result.findings.length
    finding = result.findings.first
    assert_equal "secure-github-actions/secrets-inherit", finding.fetch("rule_id")
    assert_equal true, finding.fetch("deterministic")
    assert_equal "jobs.deploy.secrets", finding.dig("location", "symbol")
  end

  def test_reports_mutable_external_action_references_without_flagging_local_actions
    result = SecureGitHubActions::Scanner.new(File.join(FIXTURES, "action-refs")).scan

    assert_equal 2, result.findings.length
    rule_ids = result.findings.map { |finding| finding.fetch("rule_id") }
    assert_equal [
      "secure-github-actions/unpinned-external-use",
      "secure-github-actions/unpinned-external-use"
    ], rule_ids
    symbols = result.findings.map { |finding| finding.dig("location", "symbol") }
    assert_equal [
      "jobs.build.steps.0.uses",
      "jobs.build.steps.1.uses"
    ], symbols
  end

  def test_safe_consumer_fixture_is_clean_and_preserves_supported_yaml_scalars
    result = SecureGitHubActions::Scanner.new(File.join(FIXTURES, "consumer-safe")).scan

    assert_equal [".github/workflows/safe.yml"], result.files
    assert_empty result.findings
  end

  def test_malformed_yaml_fails_closed_as_a_structured_finding
    result = SecureGitHubActions::Scanner.new(File.join(FIXTURES, "malformed")).scan

    assert_equal 1, result.findings.length
    finding = result.findings.first
    assert_equal "secure-github-actions/invalid-yaml", finding.fetch("rule_id")
    assert_equal "P1", finding.fetch("severity")
    assert_equal ".github/workflows/broken.yml", finding.dig("location", "file")
  end

  def test_invalid_scalar_shapes_fail_closed
    Dir.mktmpdir("secure-github-actions") do |root|
      workflow_path = File.join(root, ".github/workflows/invalid.yml")
      FileUtils.mkdir_p(File.dirname(workflow_path))
      File.write(workflow_path, <<~YAML)
        jobs:
          build:
            steps:
              - uses: { owner: action }
              - run: [echo, unsafe]
          call:
            uses: [owner, workflow]
            secrets: all
      YAML

      result = SecureGitHubActions::Scanner.new(root).scan

      assert_equal 4, result.findings.length
      assert result.findings.all? do |finding|
        finding.fetch("rule_id") == "secure-github-actions/invalid-structure"
      end
      symbols = result.findings.map { |finding| finding.dig("location", "symbol") }
      assert_equal [
        "jobs.build.steps.0.uses",
        "jobs.build.steps.1.run",
        "jobs.call.secrets",
        "jobs.call.uses"
      ], symbols
    end
  end

  def test_discovers_composite_actions_below_an_arbitrary_consumer_root
    Dir.mktmpdir("secure-github-actions") do |root|
      action_path = File.join(root, "skills/example/tmp/action.yml")
      ignored_path = File.join(root, "tmp/action.yml")
      workflow_path = File.join(root, ".github/workflows/z.yml")
      FileUtils.mkdir_p(File.dirname(action_path))
      FileUtils.mkdir_p(File.dirname(ignored_path))
      FileUtils.mkdir_p(File.dirname(workflow_path))
      action = <<~YAML
        runs:
          using: composite
          steps:
            - uses: owner/action@v1
      YAML
      File.write(action_path, action)
      File.write(ignored_path, action)
      File.write(workflow_path, "jobs: {}\n")

      result = SecureGitHubActions::Scanner.new(root).scan

      assert_equal [".github/workflows/z.yml", "skills/example/tmp/action.yml"], result.files
      assert_equal 1, result.findings.length
      assert_equal "runs.steps.0.uses", result.findings.first.dig("location", "symbol")
    end
  end

  def test_cli_emits_machine_readable_findings_and_exits_nonzero
    stdout, stderr, status = run_cli("--format", "json", File.join(FIXTURES, "expression-in-run"))

    assert_equal 1, status.exitstatus
    assert_empty stderr
    document = JSON.parse(stdout)
    assert_equal "review-finding-v0", document.fetch("schema")
    assert_equal "secure-github-actions/expression-in-run",
                 document.fetch("review_findings").first.fetch("rule_id")
    assert_empty ValidateReviewFindings.validate_document(document, "scanner output")
    assert_equal stdout, run_cli("--json", File.join(FIXTURES, "expression-in-run")).first
  end

  def test_cli_emits_stable_clean_text_and_exits_zero_only_for_clean_scans
    stdout, stderr, status = run_cli(File.join(FIXTURES, "consumer-safe"))

    assert_predicate status, :success?
    assert_empty stderr
    assert_equal "secure-github-actions-scan: CLEAN (1 file scanned)\n", stdout

    findings_stdout, findings_stderr, findings_status = run_cli(File.join(FIXTURES, "action-refs"))
    assert_equal 1, findings_status.exitstatus
    assert_empty findings_stderr
    assert_includes findings_stdout,
                    '".github/workflows/vulnerable.yml:jobs.build.steps.0.uses" '
    assert_includes findings_stdout, "[secure-github-actions/unpinned-external-use]"

    _malformed_stdout, _malformed_stderr, malformed_status = run_cli(
      "--json",
      File.join(FIXTURES, "malformed")
    )
    assert_equal 1, malformed_status.exitstatus
  end

  def test_scanning_never_executes_consumer_run_content
    Dir.mktmpdir("secure-github-actions") do |root|
      marker = File.join(root, "executed")
      workflow_path = File.join(root, ".github/workflows/inert.yml")
      FileUtils.mkdir_p(File.dirname(workflow_path))
      File.write(workflow_path, <<~YAML)
        jobs:
          inert:
            steps:
              - run: touch #{marker}
      YAML

      result = SecureGitHubActions::Scanner.new(root).scan

      assert_predicate result, :clean?
      refute_path_exists marker
    end
  end

  def test_workflow_file_symlink_fails_closed_without_parsing_external_content
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      workflow_path = File.join(root, ".github/workflows/linked.yml")
      clean_target = File.join(outer, "clean-workflow.yml")
      vulnerable_target = File.join(outer, "vulnerable-workflow.yml")
      FileUtils.mkdir_p(File.dirname(workflow_path))
      File.write(clean_target, "jobs: {}\n")
      File.write(vulnerable_target, <<~YAML)
        jobs:
          build:
            steps:
              - run: echo "${{ github.event.pull_request.title }}"
      YAML

      clean_document = scan_symlink_target(root, workflow_path, clean_target)
      vulnerable_document = scan_symlink_target(root, workflow_path, vulnerable_target)

      assert_equal clean_document, vulnerable_document
      assert_equal "secure-github-actions/unsafe-file",
                   clean_document.fetch("review_findings").first.fetch("rule_id")
    end
  end

  def test_composite_action_file_symlink_fails_closed_without_parsing_external_content
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      action_path = File.join(root, "actions/example/action.yml")
      clean_target = File.join(outer, "clean-action.yml")
      vulnerable_target = File.join(outer, "vulnerable-action.yml")
      FileUtils.mkdir_p(File.dirname(action_path))
      File.write(clean_target, <<~YAML)
        runs:
          using: composite
          steps:
            - uses: owner/action@0123456789abcdef0123456789abcdef01234567
      YAML
      File.write(vulnerable_target, <<~YAML)
        runs:
          using: composite
          steps:
            - uses: owner/action@v1
      YAML

      clean_document = scan_symlink_target(root, action_path, clean_target)
      vulnerable_document = scan_symlink_target(root, action_path, vulnerable_target)

      assert_equal clean_document, vulnerable_document
      assert_equal "secure-github-actions/unsafe-file",
                   clean_document.fetch("review_findings").first.fetch("rule_id")
    end
  end

  def test_symlinked_parent_directory_blocks_composite_action_discovery
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      outside = File.join(outer, "outside-actions")
      linked_parent = File.join(root, "components/external")
      FileUtils.mkdir_p([File.dirname(linked_parent), outside])
      File.write(File.join(outside, "action.yml"), <<~YAML)
        runs:
          using: composite
          steps:
            - uses: owner/action@v1
      YAML
      File.symlink(outside, linked_parent)

      result = SecureGitHubActions::Scanner.new(root).scan

      assert_equal 1, result.findings.length
      assert_equal "secure-github-actions/unsafe-file", result.findings.first.fetch("rule_id")
      assert_equal "components/external", result.findings.first.dig("location", "file")
    end
  end

  def test_symlinked_workflows_directory_fails_closed_without_enumerating_external_files
    Dir.mktmpdir("secure-github-actions") do |outer|
      root = File.join(outer, "consumer")
      outside = File.join(outer, "outside-workflows")
      workflows_directory = File.join(root, ".github/workflows")
      FileUtils.mkdir_p([File.dirname(workflows_directory), outside])
      File.write(File.join(outside, "vulnerable.yml"), <<~YAML)
        jobs:
          build:
            steps:
              - run: echo "${{ github.event.pull_request.title }}"
      YAML
      File.symlink(outside, workflows_directory)

      result = SecureGitHubActions::Scanner.new(root).scan

      assert_equal 1, result.findings.length
      assert_equal "secure-github-actions/unsafe-file", result.findings.first.fetch("rule_id")
      assert_equal ".github/workflows", result.findings.first.dig("location", "file")
      refute_includes result.files, ".github/workflows/vulnerable.yml"
    end
  end

  def test_non_regular_composite_action_entries_fail_closed_without_opening_them
    Dir.mktmpdir("secure-github-actions") do |root|
      directory_action = File.join(root, "components/directory/action.yml")
      fifo_action = File.join(root, "components/fifo/action.yml")
      FileUtils.mkdir_p([directory_action, File.dirname(fifo_action)])
      File.mkfifo(fifo_action)

      result = SecureGitHubActions::Scanner.new(root).scan

      assert_equal 2, result.findings.length
      assert result.findings.all? do |finding|
        finding.fetch("rule_id") == "secure-github-actions/unsafe-file"
      end
      locations = result.findings.map { |finding| finding.dig("location", "file") }
      assert_equal [
        "components/directory/action.yml",
        "components/fifo/action.yml"
      ], locations
    end
  end

  private

  def scan_symlink_target(root, link_path, target_path)
    File.unlink(link_path) if File.symlink?(link_path)
    File.symlink(target_path, link_path)
    SecureGitHubActions::Scanner.new(root).scan.document
  end

  def run_cli(*arguments)
    Open3.capture3(RbConfig.ruby, SCANNER, *arguments)
  end
end
