#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "minitest/autorun"

SCRIPT = File.expand_path("closeout-evidence-replay", __dir__)

class CloseoutEvidenceReplayTest < Minitest::Test
  def run_replay(body)
    Tempfile.create("closeout-evidence") do |file|
      file.write(body)
      file.flush
      out, status = Open3.capture2e("ruby", SCRIPT, file.path)
      assert status.success?, out
      JSON.parse(out)
    end
  end

  def test_missing_markers_are_unknown
    data = run_replay("### QA Evidence\n\n- QA lane: missing marker\n")
    assert_equal "UNKNOWN", data.fetch("overall_verdict")
    assert_equal "UNKNOWN", data.fetch("qa_evidence").fetch("verdict")
    assert_equal "NOT_APPLICABLE", data.fetch("priority_finding_dispositions").fetch("verdict")
  end

  def test_valid_qa_and_priority_markers_are_satisfied
    data = run_replay(<<~MARKDOWN)
      ### QA Evidence

      - QA lane: qa/evidence-gates

      <!-- qa-evidence v1
      required: yes
      status: satisfied
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md, skills/pr-batch
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: none
      release_blocking: clear
      process_gap_disposition: schema
      -->

      <!-- priority-finding-dispositions v1
      head_sha: abc123
      finding: url=https://example.test/review/1 | severity=P1 | disposition=fixed | evidence=https://example.test/pr/123#discussion_r1
      finding: url=https://example.test/review/2 | severity=Must-Fix | disposition=fixed | evidence=https://example.test/pr/123#discussion_r2
      -->
    MARKDOWN

    assert_equal "SATISFIED", data.fetch("overall_verdict")
    assert_equal "SATISFIED", data.fetch("qa_evidence").fetch("verdict")
    assert_equal "SATISFIED", data.fetch("priority_finding_dispositions").fetch("verdict")
    assert_equal 2, data.fetch("priority_finding_dispositions").fetch("findings").length
  end

  def test_waived_qa_marker_preserves_waived_overall
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: yes
      status: waived
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: waived by maintainer
      release_blocking: waived
      process_gap_disposition: schema
      -->
    MARKDOWN

    assert_equal "WAIVED", data.fetch("overall_verdict")
    assert_equal "WAIVED", data.fetch("qa_evidence").fetch("verdict")
    assert_equal "NOT_APPLICABLE", data.fetch("priority_finding_dispositions").fetch("verdict")
  end

  def test_waived_priority_marker_preserves_waived_overall
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: yes
      status: satisfied
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: none
      release_blocking: clear
      process_gap_disposition: schema
      -->

      <!-- priority-finding-dispositions v1
      head_sha: abc123
      finding: url=https://example.test/review/2 | severity=Must-Fix | disposition=waived | evidence=https://example.test/pr/123#discussion_r2 | waiver=https://example.test/pr/123#issuecomment-1
      -->
    MARKDOWN

    assert_equal "WAIVED", data.fetch("overall_verdict")
    assert_equal "WAIVED", data.fetch("priority_finding_dispositions").fetch("verdict")
  end

  def test_valid_qa_marker_without_priority_marker_is_satisfied
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: yes
      status: satisfied
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: none
      release_blocking: clear
      process_gap_disposition: schema
      -->
    MARKDOWN

    assert_equal "SATISFIED", data.fetch("overall_verdict")
    assert_equal "SATISFIED", data.fetch("qa_evidence").fetch("verdict")
    assert_equal "NOT_APPLICABLE", data.fetch("priority_finding_dispositions").fetch("verdict")
  end

  def test_incomplete_qa_marker_is_unknown
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: yes
      status: satisfied
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      release_blocking: clear
      process_gap_disposition: schema
      -->
    MARKDOWN

    assert_equal "UNKNOWN", data.fetch("overall_verdict")
    assert_equal "UNKNOWN", data.fetch("qa_evidence").fetch("verdict")
    assert_includes data.fetch("qa_evidence").fetch("missing"), "manual_checks"
    assert_includes data.fetch("qa_evidence").fetch("missing"), "findings"
  end

  def test_invalid_qa_required_value_is_unknown
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: maybe
      status: satisfied
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: none
      release_blocking: clear
      process_gap_disposition: schema
      -->
    MARKDOWN

    assert_equal "UNKNOWN", data.fetch("overall_verdict")
    assert_includes data.fetch("qa_evidence").fetch("missing"), "required"
  end

  def test_blocked_qa_maps_to_blocked_overall
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: yes
      status: blocked
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: release blocker found
      release_blocking: blocked
      process_gap_disposition: schema
      -->
    MARKDOWN

    assert_equal "BLOCKED", data.fetch("overall_verdict")
    assert_equal "BLOCKED", data.fetch("qa_evidence").fetch("verdict")
  end

  def test_later_blocked_qa_marker_blocks_aggregate
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: yes
      status: satisfied
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: none
      release_blocking: clear
      process_gap_disposition: schema
      -->

      <!-- qa-evidence v1
      required: yes
      status: blocked
      tested_at: PR #123 head abc123
      scope: workflows/post-merge-audit.md
      automated_checks: bin/validate
      manual_checks: replay case failed
      findings: selected CI still pending
      release_blocking: blocked
      process_gap_disposition: schema
      -->
    MARKDOWN

    qa = data.fetch("qa_evidence")
    assert_equal "BLOCKED", data.fetch("overall_verdict")
    assert_equal "BLOCKED", qa.fetch("verdict")
    assert_equal 2, qa.fetch("marker_count")
    assert_equal "BLOCKED", qa.fetch("markers").last.fetch("verdict")
  end

  def test_priority_marker_without_dispositions_is_unknown
    data = run_replay(<<~MARKDOWN)
      <!-- priority-finding-dispositions v1
      head_sha: abc123
      finding: url=https://example.test/review/1 | severity=P1 | evidence=https://example.test/pr/123#discussion_r1
      -->
    MARKDOWN

    assert_equal "UNKNOWN", data.fetch("priority_finding_dispositions").fetch("verdict")
    assert_includes data.fetch("priority_finding_dispositions").fetch("missing"), "finding[0].disposition"
  end

  def test_priority_marker_with_invalid_severity_is_unknown
    data = run_replay(<<~MARKDOWN)
      <!-- priority-finding-dispositions v1
      head_sha: abc123
      finding: url=https://example.test/review/1 | severity=Optional | disposition=fixed | evidence=https://example.test/pr/123#discussion_r1
      -->
    MARKDOWN

    assert_equal "UNKNOWN", data.fetch("overall_verdict")
    assert_equal "UNKNOWN", data.fetch("priority_finding_dispositions").fetch("verdict")
    assert_includes data.fetch("priority_finding_dispositions").fetch("missing"), "finding[0].severity"
  end

  def test_later_invalid_priority_marker_is_unknown
    data = run_replay(<<~MARKDOWN)
      <!-- qa-evidence v1
      required: yes
      status: satisfied
      tested_at: PR #123 head abc123
      scope: workflows/pr-processing.md
      automated_checks: bin/validate
      manual_checks: not applicable
      findings: none
      release_blocking: clear
      process_gap_disposition: schema
      -->

      <!-- priority-finding-dispositions v1
      head_sha: abc123
      finding: url=https://example.test/review/1 | severity=P1 | disposition=fixed | evidence=https://example.test/pr/123#discussion_r1
      -->

      <!-- priority-finding-dispositions v1
      head_sha: abc123
      finding: url=https://example.test/review/2 | severity=Optional | disposition=fixed | evidence=https://example.test/pr/123#discussion_r2
      -->
    MARKDOWN

    priority = data.fetch("priority_finding_dispositions")
    assert_equal "UNKNOWN", data.fetch("overall_verdict")
    assert_equal "UNKNOWN", priority.fetch("verdict")
    assert_equal 2, priority.fetch("marker_count")
    assert_includes priority.fetch("missing"), "marker[1].finding[0].severity"
  end
end
