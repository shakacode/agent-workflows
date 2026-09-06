#!/usr/bin/env python3

import json
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("local_chat_inventory.py")


class LocalChatInventoryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="codex#home-")
        self.home = Path(self.temporary.name)
        (self.home / "sqlite").mkdir()
        state = sqlite3.connect(self.home / "state_5.sqlite")
        state.execute(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, "
            "cwd TEXT, updated_at INTEGER, updated_at_ms INTEGER, recency_at INTEGER, "
            "recency_at_ms INTEGER, archived INTEGER, source TEXT, thread_source TEXT, "
            "agent_path TEXT, is_pinned INTEGER, project_id TEXT)"
        )
        state.executemany(
            "INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                ("active", "", None, "/a", 20, 20000, 19, 19000, 0, "vscode", "user", None, 1, "p"),
                ("state-only", "State only", None, "/h", 17, 17000, 16, 16000, 0, "vscode", "user", None, 0, None),
                ("missing-active", "Missing active", None, "/i", 28, 28000, 27, 27000, 0, "vscode", "user", None, 0, None),
                ("archived", "old", None, "/b", 10, 10000, 9, 9000, 1, "vscode", "user", None, 0, None),
                ("aged-archived", "aged", None, "/e", 8, 8000, 7, 7000, 1, "vscode", "user", None, 0, None),
                ("agent-created", "worker", None, "/f", 18, 18000, 17, 17000, 0, "vscode", "agent_created_thread", None, 0, None),
                ("worker", "worker", None, "/c", 30, 30000, 29, 29000, 0, "vscode", "subagent", "/root/w", 0, None),
                ("exec", "command", None, "/d", 40, 40000, 39, 39000, 0, "exec", "user", None, 0, None),
            ],
        )
        state.commit()
        state.close()

        catalog = sqlite3.connect(self.home / "sqlite/codex-dev.db")
        catalog.execute(
            "CREATE TABLE local_thread_catalog (host_id TEXT, thread_id TEXT, "
            "display_title TEXT, source_kind TEXT, cwd TEXT, source_updated_at REAL, "
            "source_recency_at REAL, missing_candidate INTEGER)"
        )
        catalog.executemany(
            "INSERT INTO local_thread_catalog VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                ("local", "active", "Visible task", "vscode", "/a", 21, 19, 0),
                ("local", "catalog-only", "Catalog task", "vscode", "/g", 20, 18, 0),
                ("local", "missing-active", "Missing task", "vscode", "/i", 28, 27, 1),
                ("local", "archived", "Archived task", "vscode", "/b", 99, 9, 1),
                ("local", "worker", "Internal worker", "vscode", "/c", 31, 29, 0),
                ("local", "exec", "Command", "exec", "/d", 41, 39, 0),
                ("remote", "remote", "Remote task", "vscode", "/e", 51, 49, 0),
            ],
        )
        catalog.commit()
        catalog.close()

    def tearDown(self):
        self.temporary.cleanup()

    def run_script(self, *arguments):
        result = subprocess.run(
            [str(SCRIPT), "--codex-home", str(self.home), *arguments],
            check=True,
            text=True,
            capture_output=True,
        )
        return json.loads(result.stdout)

    def test_lists_only_unarchived_user_visible_local_tasks(self):
        result = self.run_script()
        self.assertEqual("desktop-catalog", result["scope"])
        self.assertEqual(
            ["active", "catalog-only", "state-only"],
            [task["id"] for task in result["tasks"]],
        )
        self.assertEqual("Visible task", result["tasks"][0]["title"])
        self.assertEqual(19, result["tasks"][0]["recency_at"])
        self.assertTrue(result["tasks"][0]["pinned"])
        self.assertIsNone(result["tasks"][1]["archived"])
        self.assertFalse(result["tasks"][1]["state_available"])

    def test_catalog_tombstone_excludes_unarchived_state_but_not_known_archived(self):
        self.assertNotIn("missing-active", [task["id"] for task in self.run_script()["tasks"]])

        result = self.run_script("--include-archived")
        self.assertNotIn("missing-active", [task["id"] for task in result["tasks"]])
        self.assertIn("archived", [task["id"] for task in result["tasks"]])

    def test_can_include_archived_tasks_without_including_workers(self):
        result = self.run_script("--include-archived")
        self.assertEqual(
            ["active", "catalog-only", "state-only", "archived", "aged-archived"],
            [task["id"] for task in result["tasks"]],
        )

    def test_fallback_normalizes_millisecond_timestamps_to_seconds(self):
        (self.home / "sqlite/codex-dev.db").unlink()
        result = self.run_script()
        self.assertEqual("state-vscode-fallback", result["scope"])
        active = next(task for task in result["tasks"] if task["id"] == "active")
        self.assertEqual("", active["title"])
        self.assertEqual(19, active["recency_at"])
        self.assertEqual(20, active["updated_at"])

    def test_unsupported_catalog_uses_state_fallback(self):
        catalog_path = self.home / "sqlite/codex-dev.db"
        catalog_path.unlink()
        catalog = sqlite3.connect(catalog_path)
        catalog.execute("CREATE TABLE unrelated (value TEXT)")
        catalog.close()
        result = self.run_script()
        self.assertEqual("state-vscode-fallback", result["scope"])
        self.assertIn("unsupported", result["warning"])
        self.assertEqual(
            ["missing-active", "active", "state-only"],
            [task["id"] for task in result["tasks"]],
        )

    def test_state_schema_requires_archive_and_source_columns(self):
        state_path = self.home / "state_5.sqlite"
        state_path.unlink()
        state = sqlite3.connect(state_path)
        state.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
        state.close()
        result = subprocess.run(
            [str(SCRIPT), "--codex-home", str(self.home)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(1, result.returncode)
        self.assertIn("threads has an unsupported schema", result.stderr)


if __name__ == "__main__":
    unittest.main()
