#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"
load File.expand_path("recovery-status", __dir__)

class RecoveryStatusTest < Minitest::Test
  def setup
    @fleet = { "restart_id" => "restart-b", "parents" => [
      { "id" => "task-a", "handoff" => "/private/restart-b/task-a.md", "resume_disposition" => "resume", "state" => "RESTART_READY" },
      { "id" => "task-b", "handoff" => nil, "resume_disposition" => "keep-paused" }
    ] }
  end

  def acknowledge(index, status)
    parent = @fleet["parents"][index]
    parent["recovery"] = { "restart_id" => "restart-b", "parent_id" => parent["id"], "status" => status,
                           "evidence" => "parent readback and live state verified", "next_action" => "saved next step" }
  end

  def test_ready_or_sent_message_cannot_complete_recovery
    @fleet["parents"][0]["resume_sent"] = true
    acknowledge(1, "preserved-pause")
    result = RecoveryStatus.audit(@fleet)
    assert_equal "RECOVERY_INCOMPLETE", result["status"]
    assert_includes result["parents"][0]["reason"], "no recovery acknowledgment"
    acknowledge(0, "resumed")
    assert_equal "RECOVERY_COMPLETE", RecoveryStatus.audit(@fleet)["status"]
  end

  def test_other_task_filename_is_rejected_even_with_success_receipt
    acknowledge(0, "resumed")
    @fleet["parents"][0]["handoff"] = "/private/restart-b/task-b.md"
    assert_includes RecoveryStatus.audit(@fleet)["parents"][0]["reason"], "another parent"
  end

  def test_old_generation_and_wrong_recipient_receipts_do_not_count
    acknowledge(0, "resumed")
    good = JSON.generate(@fleet)
    { "restart_id" => "restart-a", "parent_id" => "task-b" }.each do |key, wrong|
      @fleet = JSON.parse(good)
      @fleet["parents"][0]["recovery"][key] = wrong
      assert_includes RecoveryStatus.audit(@fleet)["parents"][0]["reason"], "another restart or parent"
    end
  end

  def test_restart_hold_must_resume_but_prior_pause_must_remain
    acknowledge(0, "preserved-pause")
    acknowledge(1, "resumed")
    assert(RecoveryStatus.audit(@fleet)["parents"].all? { |row| row["reason"] })
  end

  def test_missing_handoff_can_recover_with_verified_logs_and_live_state
    @fleet["parents"][0]["handoff"] = nil
    acknowledge(0, "resumed")
    acknowledge(1, "preserved-pause")
    assert_equal "RECOVERY_COMPLETE", RecoveryStatus.audit(@fleet)["status"]
  end

  def test_duplicate_parent_and_empty_fleet_are_not_success
    @fleet["parents"] << @fleet["parents"][0].dup
    assert_raises(ArgumentError) { RecoveryStatus.audit(@fleet) }
    @fleet["parents"] = []
    assert_raises(ArgumentError) { RecoveryStatus.audit(@fleet) }
  end

  def test_complete_disposition_and_missing_evidence
    @fleet["parents"][0]["resume_disposition"] = "complete"
    acknowledge(0, "already-complete")
    acknowledge(1, "preserved-pause")
    assert_equal "RECOVERY_COMPLETE", RecoveryStatus.audit(@fleet)["status"]
    @fleet["parents"][0]["recovery"]["evidence"] = " "
    assert_includes RecoveryStatus.audit(@fleet)["parents"][0]["reason"], "lacks evidence"
  end

  def test_cli_reads_prior_json_manifest_and_returns_incomplete_status
    Tempfile.create(["python-fleet-", ".json"]) do |file|
      file.write(JSON.pretty_generate(@fleet))
      file.flush
      out, _, status = Open3.capture3(RbConfig.ruby, File.expand_path("recovery-status", __dir__), file.path)
      assert_equal 2, status.exitstatus
      assert_equal RecoveryStatus.audit(@fleet), JSON.parse(out)
    end
  end

  def test_cli_reads_utf8_manifest_under_c_locale_and_rejects_invalid_bytes
    acknowledge(0, "resumed")
    acknowledge(1, "preserved-pause")
    @fleet["parents"][0]["recovery"]["evidence"] = "Checked résumé"
    Tempfile.create(["utf8-fleet-", ".json"]) do |file|
      file.write(JSON.pretty_generate(@fleet))
      file.flush
      command = [RbConfig.ruby, File.expand_path("recovery-status", __dir__), file.path]
      out, err, status = Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, *command)
      assert status.success?, err
      assert_equal "RECOVERY_COMPLETE", JSON.parse(out)["status"]

      File.binwrite(file.path, JSON.generate(@fleet).sub("résumé", "\xff".b))
      _, err, status = Open3.capture3(*command)
      assert_equal 2, status.exitstatus
      assert_equal "recovery-status: invalid or unavailable manifest; recovery is UNKNOWN\n", err
    end
  end
end
