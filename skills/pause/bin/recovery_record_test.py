"""Exercise interruption boundaries without touching a running agent or remote service."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = Path(__file__).with_name("recovery-record")


class RecoveryRecordTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.command = [sys.executable, str(HELPER), "--state-dir", str(self.root / "state"), "--task", "example-task"]

    def call(self, *args, data=None):
        return subprocess.run(self.command + list(args), input=data, text=True, capture_output=True)

    def evidence(self):
        return json.loads(self.call("inspect").stdout)

    def test_missing_checkpoint_is_normal_and_read_only(self):
        self.assertEqual(self.evidence(), {"records": [], "unresolved": [], "unreadable": []})
        self.assertFalse((self.root / "state").exists())

    def test_newer_operation_preserved_after_stale_checkpoint(self):
        self.assertEqual(self.call("checkpoint", data='{"next":"create result"}').returncode, 0)
        result = self.call("run", "--label", "create result", "--", sys.executable, "-c", "raise SystemExit(7)")
        self.assertEqual(result.returncode, 7)
        records = self.evidence()["records"]
        self.assertEqual([record["kind"] for record in records], ["checkpoint", "operation"])
        self.assertEqual(records[-1]["exit_code"], 7)
        self.assertNotIn("raise SystemExit", json.dumps(records))
        for path in (self.root / "state").rglob("*.json"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_effect_can_finish_after_recorder_dies_without_a_result(self):
        marker = self.root / "external-result"
        started = self.root / "started"
        script = "from pathlib import Path; import time,sys; Path(sys.argv[1]).touch(); time.sleep(.3); Path(sys.argv[2]).touch()"
        with tempfile.TemporaryFile() as stream:
            process = subprocess.Popen(self.command + ["run", "--label", "external result", "--", sys.executable,
                                       "-c", script, str(started), str(marker)], stdout=stream, stderr=stream)
            try:
                deadline = time.monotonic() + 5
                while not started.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(started.exists())
                self.assertEqual(len(self.evidence()["unresolved"]), 1)
                process.kill()
                process.wait(timeout=5)
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(marker.exists())
                self.assertEqual(len(self.evidence()["unresolved"]), 1)
                # Reading evidence never repeats the operation or upgrades intent to success.
                self.assertEqual(self.evidence()["records"][0]["status"], "intent")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def test_failed_recording_prevents_execution(self):
        state = self.root / "state"
        state.mkdir(mode=0o755)
        state.chmod(0o755)
        marker = self.root / "must-not-exist"
        result = self.call("run", "--label", "test", "--", sys.executable, "-c",
                           "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(marker))
        self.assertEqual(result.returncode, 2)
        self.assertFalse(marker.exists())

    def test_corrupt_record_is_reported_without_discarding_good_evidence(self):
        self.call("checkpoint", data='{"done":"tests"}')
        directory = next((self.root / "state").iterdir())
        (directory / "broken.json").write_text("{")
        result = self.call("inspect")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(len(json.loads(result.stdout)["records"]), 1)
        self.assertEqual(json.loads(result.stdout)["unreadable"], ["broken.json"])


if __name__ == "__main__":
    unittest.main()
