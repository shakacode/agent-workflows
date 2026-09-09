"""Replay readiness-only, misrouted, and stale fleet acknowledgments."""
import copy
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

loader = importlib.machinery.SourceFileLoader("recovery_status", str(Path(__file__).with_name("recovery-status")))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class RecoveryStatusTest(unittest.TestCase):
    def setUp(self):
        self.fleet = {"restart_id": "restart-b", "parents": [
            {"id": "task-a", "handoff": "/private/restart-b/task-a.md", "resume_disposition": "resume",
             "state": "RESTART_READY"},
            {"id": "task-b", "handoff": None, "resume_disposition": "keep-paused"}]}

    def acknowledge(self, index, status):
        parent = self.fleet["parents"][index]
        parent["recovery"] = {"restart_id": "restart-b", "parent_id": parent["id"], "status": status,
                              "evidence": "parent readback and live state verified", "next_action": "saved next step"}

    def test_ready_or_sent_message_cannot_complete_recovery(self):
        self.fleet["parents"][0]["resume_sent"] = True
        self.acknowledge(1, "preserved-pause")
        result = module.audit(self.fleet)
        self.assertEqual(result["status"], "RECOVERY_INCOMPLETE")
        self.assertIn("no recovery acknowledgment", result["parents"][0]["reason"])
        self.acknowledge(0, "resumed")
        self.assertEqual(module.audit(self.fleet)["status"], "RECOVERY_COMPLETE")

    def test_other_task_filename_is_rejected_even_with_success_receipt(self):
        self.acknowledge(0, "resumed")
        self.fleet["parents"][0]["handoff"] = "/private/restart-b/task-b.md"
        self.assertIn("another parent", module.audit(self.fleet)["parents"][0]["reason"])

    def test_old_generation_and_wrong_recipient_receipts_do_not_count(self):
        self.acknowledge(0, "resumed")
        good = copy.deepcopy(self.fleet)
        for key, wrong in (("restart_id", "restart-a"), ("parent_id", "task-b")):
            self.fleet = copy.deepcopy(good)
            self.fleet["parents"][0]["recovery"][key] = wrong
            self.assertIn("another restart or parent", module.audit(self.fleet)["parents"][0]["reason"])

    def test_restart_hold_must_resume_but_prior_pause_must_remain(self):
        self.acknowledge(0, "preserved-pause")
        self.acknowledge(1, "resumed")
        self.assertTrue(all(row["reason"] for row in module.audit(self.fleet)["parents"]))

    def test_missing_handoff_can_recover_with_verified_logs_and_live_state(self):
        self.fleet["parents"][0]["handoff"] = None
        self.acknowledge(0, "resumed")
        self.acknowledge(1, "preserved-pause")
        self.assertEqual(module.audit(self.fleet)["status"], "RECOVERY_COMPLETE")

    def test_duplicate_parent_and_empty_fleet_are_not_success(self):
        self.fleet["parents"].append(copy.deepcopy(self.fleet["parents"][0]))
        with self.assertRaises(ValueError):
            module.audit(self.fleet)
        self.fleet["parents"] = []
        with self.assertRaises(ValueError):
            module.audit(self.fleet)


if __name__ == "__main__":
    unittest.main()
