#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "tempfile"

SCRIPT = File.expand_path("completed-batch-publication-preflight", __dir__)
FIXTURES = File.expand_path("../fixtures", __dir__)
load SCRIPT

class CompletedBatchPublicationPreflightTest < Minitest::Test
  BACKEND = "agent-coord private backend"

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, name), encoding: "UTF-8"))
  end

  def test_premature_hichee_publication_replays_blocked_for_coordination_target_and_qa
    result = CompletedBatchPublicationPreflight.assess(
      fixture("completed-batch-publication-hichee-premature.json"),
      coordination_backend: BACKEND
    )

    refute result.fetch("eligible")
    assert_equal "BLOCKED", result.fetch("verdict")
    assert_includes result.fetch("blockers"), "coordination batch is not completed"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10036 coordination lane is nonterminal"
    assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:10036 target is not merged"
    [10_026, 10_048, 10_049].each do |number|
      assert_includes result.fetch("blockers"), "shakacode/hichee#pull_request:#{number} QA evidence is absent"
    end
    target_numbers = result.fetch("targets").map { |target| target.fetch("number") }
    assert_equal [10_026, 10_036, 10_048, 10_049], target_numbers
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.fetch("snapshot_digest"))
    assert_equal "sha256:78743edf641a114bf78424d667c4d30c40af202acebdbade974da12422efee64",
                 result.fetch("snapshot_digest")
  end

  def test_real_premature_marker_fixture_preserves_reported_hash_and_is_not_well_formed
    marker = File.read(
      File.join(FIXTURES, "completed-batch-publication-hichee-premature-marker.txt"),
      encoding: "UTF-8"
    )

    assert_equal "5ede1b523b283a091d74ce51a429a4d5fde200404cc37ae8c5eff32f6e0e6352",
                 Digest::SHA256.hexdigest(marker)
  end

  def test_four_terminal_reconciled_lanes_pass_with_exact_head_dispositions
    result = CompletedBatchPublicationPreflight.assess(
      fixture("completed-batch-publication-hichee-terminal.json"),
      coordination_backend: BACKEND
    )

    assert result.fetch("eligible"), result.fetch("blockers").join("\n")
    assert_equal "ELIGIBLE", result.fetch("verdict")
    assert_empty result.fetch("blockers")
    target_numbers = result.fetch("targets").map { |target| target.fetch("number") }
    assert_equal [10_026, 10_036, 10_048, 10_049], target_numbers
    assert_equal(
      %w[WAIVED SATISFIED NOT_APPLICABLE SATISFIED],
      result.dig("snapshot", "qa").map { |qa| qa.fetch("verdict") }
    )
    assert CompletedBatchPublicationPreflight.valid_receipt?(result)
    assert_equal "sha256:955d6d8650040421dcebadc9f9dffaa1c5a778c7c664a96753ed13cf8086ad84",
                 result.fetch("snapshot_digest")
  end

  def test_snapshot_is_deterministic_under_source_array_reordering
    input = fixture("completed-batch-publication-hichee-terminal.json")
    baseline = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)
    input.fetch("expected_targets").reverse!
    input.fetch("target_snapshots").rotate!
    input.fetch("qa_evidence").reverse!
    input.dig("coordination_status", "batches", 0, "lanes").rotate!
    replay = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)

    assert_equal baseline.fetch("snapshot"), replay.fetch("snapshot")
    assert_equal baseline.fetch("snapshot_digest"), replay.fetch("snapshot_digest")
  end

  def test_unknown_and_in_progress_qa_block_completion
    %w[unknown in_progress].each do |status|
      input = fixture("completed-batch-publication-hichee-terminal.json")
      qa = input.fetch("qa_evidence").first
      qa["evidence"] = qa.fetch("evidence")
                         .sub("status: satisfied", "status: #{status}")
                         .sub("release_blocking: clear", "release_blocking: blocked")
      result = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)

      refute result.fetch("eligible"), status
      assert_includes result.fetch("blockers"),
                      "shakacode/hichee#pull_request:10049 QA disposition is #{status}", status
    end
  end

  def test_waived_qa_requires_replayable_maintainer_waiver
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.fetch("qa_evidence").last.delete("maintainer_waiver")
    result = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 maintainer QA waiver is not replayable"
  end

  def test_expected_target_absent_from_coordination_scope_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    input.dig("coordination_status", "batches", 0, "lanes").pop
    result = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "shakacode/hichee#pull_request:10026 is absent from resolved coordination scope"
  end

  def test_conflicting_lane_url_and_target_identity_blocks
    input = fixture("completed-batch-publication-hichee-terminal.json")
    lane = input.dig("coordination_status", "batches", 0, "lanes", 0)
    lane["targets"] = ["10026"]
    result = CompletedBatchPublicationPreflight.assess(input, coordination_backend: BACKEND)

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"),
                    "coordination lane hc-b-10049 target is absent or ambiguous"
  end

  def test_eligible_receipt_requires_a_nonempty_valid_target_set
    result = CompletedBatchPublicationPreflight.assess(
      fixture("completed-batch-publication-hichee-terminal.json"),
      coordination_backend: BACKEND
    )
    result["targets"] = []
    result["snapshot"]["targets"] = []
    result["snapshot"]["qa"] = []
    result["snapshot"]["coordination"]["lanes"] = []
    result["snapshot_digest"] = CompletedBatchPublicationPreflight.digest(result.fetch("snapshot"))
    result["receipt_digest"] = CompletedBatchPublicationPreflight.digest(
      result.reject { |key, _value| key == "receipt_digest" }
    )

    refute CompletedBatchPublicationPreflight.valid_receipt?(result)
  end

  def test_no_configured_coordination_backend_fails_closed
    result = CompletedBatchPublicationPreflight.assess(
      fixture("completed-batch-publication-hichee-terminal.json"),
      coordination_backend: "n/a"
    )

    refute result.fetch("eligible")
    assert_includes result.fetch("blockers"), "configured coordination backend is unavailable"
  end

  def test_cli_reads_the_repository_coordination_backend_seam
    Tempfile.create(["agent-workflow", ".yml"]) do |config|
      config.write("coordination_backend: agent-coord private backend\n")
      config.flush
      out, err, status = Open3.capture3(
        "ruby",
        SCRIPT,
        "--workflow-config",
        config.path,
        "--input",
        File.join(FIXTURES, "completed-batch-publication-hichee-terminal.json")
      )

      assert status.success?, err
      result = JSON.parse(out)
      assert result.fetch("eligible")
      assert_equal "agent-coord private backend", result.dig("snapshot", "coordination_backend")
    end
  end
end
