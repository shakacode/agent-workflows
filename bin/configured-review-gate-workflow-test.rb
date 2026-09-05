#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract coverage for the repository's `configured-review-gate` workflow step.
# The step must fail closed on both paths while reporting them distinctly: a
# helper that is absent or non-executable on the trusted base never evaluated
# anything, and must not be described as unsettled reviews.

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

class ConfiguredReviewGateWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WORKFLOW_PATH = File.join(ROOT, ".github/workflows/configured-review-gate.yml")
  JOB_ID = "configured-review-gate"
  GATE_STEP_NAME = "Require settled configured reviews"
  GATE_RELATIVE_PATH = "skills/pr-batch/bin/configured-review-gate"
  BASE_SHA = "ecd42b68491eb898ec4d7045ff91cb59e900905e"
  HEAD_SHA = "d0443a3fdaec3951c978e70c70c2cef14bcccde8"
  UNAVAILABLE_DESCRIPTION = "Advisory: configured-review gate unavailable on the trusted base"
  UNSETTLED_DESCRIPTION = "Advisory: configured reviews are not merge-ready"
  SETTLED_DESCRIPTION = "Advisory: configured reviews are settled for this head"
  PENDING_DESCRIPTION = "Advisory: waiting for exact-head configured reviews"

  def test_a_missing_helper_reports_an_unavailable_gate_rather_than_unsettled_reviews
    run = execute_gate_step(helper: :missing)

    refute_equal 0, run.fetch(:exit_status)
    assert_equal [["failure", UNAVAILABLE_DESCRIPTION]], run.fetch(:statuses)
    assert_includes run.fetch(:stdout), "::error::"
    assert_includes run.fetch(:stdout), GATE_RELATIVE_PATH
    assert_includes run.fetch(:stdout), BASE_SHA
    assert_match(/missing/i, error_annotation(run))
    refute_includes run.fetch(:stdout), UNSETTLED_DESCRIPTION
  end

  def test_a_non_executable_helper_reports_an_unavailable_gate_with_its_own_evidence
    run = execute_gate_step(helper: :not_executable)

    refute_equal 0, run.fetch(:exit_status)
    assert_equal [["failure", UNAVAILABLE_DESCRIPTION]], run.fetch(:statuses)
    assert_includes run.fetch(:stdout), GATE_RELATIVE_PATH
    assert_includes run.fetch(:stdout), BASE_SHA
    assert_match(/not executable/i, error_annotation(run))
    refute_match(/missing/i, error_annotation(run))
    refute_includes run.fetch(:stdout), UNSETTLED_DESCRIPTION
  end

  def test_the_unavailable_annotation_survives_a_failed_status_post
    run = execute_gate_step(helper: :missing, gh_exit_status: 1)

    refute_equal 0, run.fetch(:exit_status)
    assert_includes run.fetch(:stdout), "::error::"
    assert_match(/missing/i, error_annotation(run))
  end

  def test_a_helper_path_that_is_not_a_regular_file_reports_an_unavailable_gate
    run = execute_gate_step(helper: :directory)

    refute_equal 0, run.fetch(:exit_status)
    assert_equal [["failure", UNAVAILABLE_DESCRIPTION]], run.fetch(:statuses)
    assert_match(/not a regular file/i, error_annotation(run))
    refute_includes run.fetch(:stdout), UNSETTLED_DESCRIPTION
  end

  def test_an_executed_gate_with_unsettled_reviews_keeps_the_unsettled_description
    run = execute_gate_step(helper: :executable, helper_exit_status: 8)

    assert_equal 8, run.fetch(:exit_status)
    assert_equal [["pending", PENDING_DESCRIPTION], ["failure", UNSETTLED_DESCRIPTION]], run.fetch(:statuses)
    refute_includes run.fetch(:stdout), UNAVAILABLE_DESCRIPTION
    refute_includes run.fetch(:stdout), "::error::"
  end

  def test_an_executed_gate_with_settled_reviews_still_succeeds
    run = execute_gate_step(helper: :executable, helper_exit_status: 0)

    assert_equal 0, run.fetch(:exit_status)
    assert_equal [["pending", PENDING_DESCRIPTION], ["success", SETTLED_DESCRIPTION]], run.fetch(:statuses)
    assert_includes run.fetch(:helper_invocation), "--expected-base-sha #{BASE_SHA}"
  end

  def test_the_gate_still_evaluates_from_the_trusted_base_checkout
    checkout = steps.find { |step| step["name"] == "Checkout trusted base" }

    assert_equal "${{ steps.bindings.outputs.base_sha }}", checkout.fetch("with").fetch("ref")
    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    assert_operator steps.index(checkout), :<, steps.index(gate_step)
  end

  def test_the_closeout_component_documents_the_two_distinct_advisory_descriptions
    component = File.read(File.join(ROOT, "workflows/pr-batch-integration-closeout.md"), encoding: "UTF-8")
                    .gsub(/\s+/, " ")

    assert_includes component,
                    "A gate that never ran reports `configured-review gate unavailable on the trusted base` " \
                    "instead of `configured reviews are not merge-ready`; both fail closed."
  end

  private

  def workflow
    @workflow ||= YAML.safe_load_file(WORKFLOW_PATH, aliases: false)
  end

  def steps
    workflow.fetch("jobs").fetch(JOB_ID).fetch("steps")
  end

  def gate_step
    steps.find { |step| step["name"] == GATE_STEP_NAME } ||
      raise("missing #{GATE_STEP_NAME.inspect} step in #{WORKFLOW_PATH}")
  end

  def error_annotation(run)
    run.fetch(:stdout).lines.grep(/^::error::/).join
  end

  # Run the workflow step's real shell body against a stubbed `gh` and a
  # controllable helper so both branches are observed, not merely asserted about.
  def execute_gate_step(helper:, helper_exit_status: 0, gh_exit_status: 0)
    Dir.mktmpdir("configured-review-gate-workflow") do |sandbox|
      workspace = File.join(sandbox, "workspace")
      stub_bin = File.join(sandbox, "stub-bin")
      runner_temp = File.join(sandbox, "runner-temp")
      status_log = File.join(sandbox, "statuses.log")
      helper_invocation_path = File.join(sandbox, "helper-invocation.log")
      [File.join(workspace, File.dirname(GATE_RELATIVE_PATH)), stub_bin, runner_temp].each do |path|
        FileUtils.mkdir_p(path)
      end

      write_executable(File.join(stub_bin, "gh"), <<~STUB)
        #!/usr/bin/env bash
        for argument in "$@"; do printf '%s\\n' "$argument"; done >> "$GATE_STATUS_LOG"
        printf '%s\\n' "--" >> "$GATE_STATUS_LOG"
        exit #{gh_exit_status}
      STUB
      install_helper(File.join(workspace, GATE_RELATIVE_PATH), helper, helper_exit_status, helper_invocation_path)

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{stub_bin}:#{ENV.fetch('PATH')}",
          "GATE_STATUS_LOG" => status_log,
          "GATE_HELPER_INVOCATION_LOG" => helper_invocation_path,
          "GH_TOKEN" => "stub-token",
          "REVIEW_GATE_REPO" => "shakacode/agent-workflows",
          "REVIEW_GATE_PR" => "469",
          "REVIEW_GATE_BASE_SHA" => BASE_SHA,
          "REVIEW_GATE_HEAD_SHA" => HEAD_SHA,
          "GITHUB_SERVER_URL" => "https://github.com",
          "GITHUB_REPOSITORY" => "shakacode/agent-workflows",
          "GITHUB_RUN_ID" => "33549668252",
          "GITHUB_WORKSPACE" => workspace,
          "RUNNER_TEMP" => runner_temp
        },
        "bash", "-c", gate_step.fetch("run"),
        chdir: workspace, unsetenv_others: false
      )

      {
        exit_status: status.exitstatus,
        stdout: stdout,
        stderr: stderr,
        statuses: parse_statuses(status_log),
        helper_invocation: File.exist?(helper_invocation_path) ? File.read(helper_invocation_path) : ""
      }
    end
  end

  def install_helper(path, helper, helper_exit_status, helper_invocation_path)
    return if helper == :missing

    if helper == :directory
      FileUtils.mkdir_p(path)
      return
    end

    File.write(path, <<~HELPER)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> "$GATE_HELPER_INVOCATION_LOG"
      exit #{helper_exit_status}
    HELPER
    File.chmod(helper == :executable ? 0o755 : 0o644, path)
    FileUtils.touch(helper_invocation_path)
  end

  def write_executable(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  # Each stubbed `gh` invocation logs one argument per line, terminated by `--`.
  def parse_statuses(status_log)
    return [] unless File.exist?(status_log)

    File.read(status_log).split("--\n").reject { |record| record.strip.empty? }.map do |record|
      fields = record.lines.map(&:chomp)
      [field_value(fields, "state"), field_value(fields, "description")]
    end
  end

  def field_value(fields, key)
    fields.find { |field| field.start_with?("#{key}=") }&.delete_prefix("#{key}=")
  end
end
