#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tempfile"

class WorkflowTelemetryReportTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  HELPER = File.join(__dir__, "workflow-telemetry-report")
  FIXTURE = File.join(ROOT, "skills/pr-batch/fixtures/workflow-telemetry-report-replay.json")

  def test_replays_compact_directional_report_with_literal_unknowns
    stdout, stderr, status = Open3.capture3(HELPER, "--input", FIXTURE, "--format", "json")

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal "workflow-telemetry-report", report.fetch("contract")
    assert_equal 45, report.dig("measurements", "prompt_to_worker_start_seconds")
    assert_equal "UNKNOWN", report.dig("measurements", "models", "prompt_creation")
    assert_equal 120, report.dig("measurements", "phase_seconds", "discovery")
    assert_equal 300, report.dig("measurements", "phase_seconds", "implementation")
    assert_equal "UNKNOWN", report.dig("measurements", "phase_seconds", "review")
    assert_equal "UNKNOWN", report.dig("measurements", "human_questions", "queue_seconds")
    assert_equal 600, report.dig("measurements", "slot_seconds", "occupied")
    assert_equal 60, report.dig("measurements", "slot_seconds", "stopped")
    assert_equal 300, report.dig("measurements", "integration_seconds")
    assert_equal "UNKNOWN", report.dig("measurements", "outcomes", "rollbacks")
    assert_includes report.fetch("unknown_fields"), "/measurements/phase_seconds/planning"
    assert_includes report.fetch("unknown_fields"), "/measurements/human_questions/queue_seconds"
    assert_includes report.fetch("unknown_fields"), "/measurements/outcomes/rollbacks"
  end

  def test_rejects_token_shaped_content_even_in_an_allowlisted_metadata_field_without_echoing_it
    secrets = [
      %w[sk proj do-not-echo-1234567890].join("-"),
      %w[sk live 1234567890abcdefghijklmn].join("_"),
      %w[glpat 0123456789abcdefghijkl].join("-"),
      %w[eyJhbGciOiJIUzI1NiJ9 eyJzdWIiOiIxMjM0NTY3ODkwIn0 signature].join(".")
    ]

    secrets.each do |secret|
      input = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
      input["prompt_creation"]["model"] = secret

      Tempfile.create(["workflow-telemetry", ".json"]) do |file|
        file.write(JSON.generate(input))
        file.flush
        stdout, stderr, status = Open3.capture3(HELPER, "--input", file.path, "--format", "json")

        refute status.success?
        refute_includes stdout, secret
        refute_includes stderr, secret
      end
    end
  end

  def test_accepts_an_opaque_single_line_coordination_batch_id
    input = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
    input["batch_id"] = "prod;batch=42"

    report = run_json(input)

    assert_equal "prod;batch=42", report.fetch("batch_id")
  end

  def test_rejects_prose_in_batch_id_without_echoing_it
    input = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
    private_content = "please inspect the private customer transcript and summarize it"
    input["batch_id"] = private_content

    Tempfile.create(["workflow-telemetry", ".json"]) do |file|
      file.write(JSON.generate(input))
      file.flush
      stdout, stderr, status = Open3.capture3(HELPER, "--input", file.path, "--format", "json")

      refute status.success?
      refute_includes stdout, private_content
      refute_includes stderr, private_content
    end
  end

  def test_propagates_unknown_when_human_question_collection_is_unavailable
    input = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
    input["human_questions"] = "UNKNOWN"

    report = run_json(input)

    assert_equal "UNKNOWN", report.dig("measurements", "human_questions", "count")
    assert_equal "UNKNOWN", report.dig("measurements", "human_questions", "answered_count")
    assert_equal "UNKNOWN", report.dig("measurements", "human_questions", "queue_seconds")
  end

  def test_rejects_non_allowlisted_payload_fields_without_echoing_their_content
    input = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
    private_content = "private prompt content must not be echoed"
    input["raw_prompt"] = private_content

    Tempfile.create(["workflow-telemetry", ".json"]) do |file|
      file.write(JSON.generate(input))
      file.flush
      stdout, stderr, status = Open3.capture3(HELPER, "--input", file.path, "--format", "json")

      refute status.success?
      refute_includes stdout, private_content
      refute_includes stderr, private_content
      assert_includes stderr, "metadata allowlist"
    end
  end

  def test_text_report_is_compact_and_keeps_unknowns_visible
    stdout, stderr, status = Open3.capture3(HELPER, "--input", FIXTURE, "--format", "text")

    assert status.success?, stderr
    assert_operator stdout.lines.length, :<=, 12
    assert_includes stdout, "prompt_to_worker_start_seconds: 45"
    assert_includes stdout, "review=UNKNOWN"
    assert_includes stdout, "rollbacks=UNKNOWN"
    refute_includes stdout, "phase_intervals"
    refute_includes stdout, "human_questions\":"
  end

  def test_malformed_json_errors_do_not_echo_input_content
    private_content = "raw-private-transcript-do-not-echo"

    Tempfile.create(["workflow-telemetry", ".json"]) do |file|
      file.write(%({"contract":"#{private_content}"))
      file.flush
      stdout, stderr, status = Open3.capture3(HELPER, "--input", file.path)

      refute status.success?
      refute_includes stdout, private_content
      refute_includes stderr, private_content
    end
  end

  def test_rejects_timestamps_without_an_explicit_offset
    input = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
    input["worker_start"]["at"] = "2026-08-29T20:00:45"

    Tempfile.create(["workflow-telemetry", ".json"]) do |file|
      file.write(JSON.generate(input))
      file.flush
      _stdout, stderr, status = Open3.capture3(HELPER, "--input", file.path)

      refute status.success?
      assert_includes stderr, "invalid timestamp"
    end
  end

  def test_rejects_invalid_calendar_timestamps_instead_of_normalizing_them
    ["2026-02-30T20:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T23:59:60Z"].each do |value|
      input = JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
      input["prompt_creation"]["at"] = value

      Tempfile.create(["workflow-telemetry", ".json"]) do |file|
        file.write(JSON.generate(input))
        file.flush
        _stdout, stderr, status = Open3.capture3(HELPER, "--input", file.path)

        refute status.success?
        assert_includes stderr, "invalid timestamp"
      end
    end
  end

  def test_directory_input_fails_without_a_backtrace
    _stdout, stderr, status = Open3.capture3(HELPER, "--input", File.dirname(FIXTURE))

    refute status.success?
    assert_equal "workflow-telemetry-report: unable to read input\n", stderr
  end

  private

  def run_json(input)
    Tempfile.create(["workflow-telemetry", ".json"]) do |file|
      file.write(JSON.generate(input))
      file.flush
      stdout, stderr, status = Open3.capture3(HELPER, "--input", file.path, "--format", "json")
      assert status.success?, stderr
      return JSON.parse(stdout)
    end
  end
end
