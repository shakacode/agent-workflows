#!/usr/bin/env python3
"""List user-visible Codex Desktop tasks from local Codex state, read-only."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Optional


def readonly_connection(path: Path) -> sqlite3.Connection:
    uri = f"{path.expanduser().resolve().as_uri()}?mode=ro"
    return sqlite3.connect(uri, uri=True)


def first_existing(paths: list[Path]) -> Optional[Path]:
    return next((path for path in paths if path.is_file()), None)


def columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}


def catalog_rows(path: Path) -> dict[str, dict[str, object]]:
    connection = readonly_connection(path)
    try:
        names = columns(connection, "local_thread_catalog")
        required = {"host_id", "thread_id", "display_title", "source_kind"}
        if not required <= names:
            raise RuntimeError("local_thread_catalog has an unsupported schema")
        selected = ["host_id", "thread_id", "display_title", "source_kind"]
        for optional in (
            "host_id", "cwd", "source_updated_at", "source_recency_at",
            "thread_source", "missing_candidate", "project_id",
        ):
            if optional in names and optional not in selected:
                selected.append(optional)
        query = f"SELECT {', '.join(selected)} FROM local_thread_catalog"
        rows = {}
        for values in connection.execute(query):
            row = dict(zip(selected, values))
            if row.get("source_kind") != "vscode":
                continue
            if row.get("host_id") not in (None, "local"):
                continue
            if bool(row.get("missing_candidate")):
                continue
            rows[str(row["thread_id"])] = row
        return rows
    finally:
        connection.close()


def state_rows(path: Path) -> dict[str, dict[str, object]]:
    connection = readonly_connection(path)
    try:
        names = columns(connection, "threads")
        required = {"id", "archived", "source"}
        if not required <= names:
            raise RuntimeError("threads has an unsupported schema")
        selected = [
            name
            for name in (
                "id", "title", "name", "cwd", "rollout_path", "updated_at",
                "updated_at_ms", "recency_at", "recency_at_ms", "archived",
                "source", "thread_source", "agent_path", "is_pinned", "project_id",
            )
            if name in names
        ]
        query = f"SELECT {', '.join(selected)} FROM threads"
        return {
            str(row["id"]): row
            for values in connection.execute(query)
            for row in [dict(zip(selected, values))]
        }
    finally:
        connection.close()


def state_timestamp(
    row: dict[str, object], seconds_key: str, milliseconds_key: str
) -> object:
    seconds = row.get(seconds_key)
    if seconds is not None:
        return seconds
    milliseconds = row.get(milliseconds_key)
    if milliseconds is None:
        return None
    return float(milliseconds) / 1000


def first_line(value: object) -> str:
    lines = str(value or "").splitlines()
    return lines[0] if lines else ""


def build_inventory(codex_home: Path, include_archived: bool) -> dict[str, object]:
    state_path = first_existing(
        [codex_home / "state_5.sqlite", codex_home / "sqlite/state_5.sqlite"]
    )
    catalog_path = first_existing([codex_home / "sqlite/codex-dev.db"])
    if state_path is None:
        raise RuntimeError("Codex state database not found")

    state = state_rows(state_path)
    candidate_ids = {
        thread_id
        for thread_id, row in state.items()
        if row.get("source") == "vscode"
    }
    warning = None
    if catalog_path:
        try:
            catalog = catalog_rows(catalog_path)
        except (sqlite3.Error, RuntimeError):
            catalog = {}
            scope = "state-vscode-fallback"
            warning = "Desktop catalog unsupported; using Codex state fallback"
        else:
            if catalog or not candidate_ids:
                scope = "desktop-catalog"
                candidate_ids.update(catalog)
            else:
                scope = "state-vscode-fallback"
                warning = "Desktop catalog empty; using Codex state fallback"
    else:
        catalog = {}
        scope = "state-vscode-fallback"
        warning = "Desktop catalog unavailable; inventory may be incomplete"

    tasks = []
    for thread_id in candidate_ids:
        row = state.get(thread_id, {})
        catalog_row = catalog.get(thread_id, {})
        if row and not include_archived and bool(row.get("archived")):
            continue
        if row.get("agent_path"):
            continue
        if row.get("thread_source") in {"subagent", "guardian_review"}:
            continue
        if row.get("thread_source") == "agent_created_thread" and not catalog_row:
            continue
        if catalog_row.get("thread_source") in {"subagent", "guardian_review"}:
            continue
        title = catalog_row.get("display_title") or row.get("name") or row.get("title")
        recency_at = catalog_row.get("source_recency_at")
        if recency_at is None:
            recency_at = state_timestamp(row, "recency_at", "recency_at_ms")
        updated_at = catalog_row.get("source_updated_at")
        if updated_at is None:
            updated_at = state_timestamp(row, "updated_at", "updated_at_ms")
        tasks.append(
            {
                "id": thread_id,
                "title": first_line(title),
                "cwd": catalog_row.get("cwd") or row.get("cwd"),
                "updated_at": updated_at,
                "recency_at": recency_at,
                "archived": bool(row.get("archived")) if row else None,
                "pinned": bool(row.get("is_pinned")) if row else None,
                "project_id": row.get("project_id") or catalog_row.get("project_id"),
                "thread_source": row.get("thread_source")
                or catalog_row.get("thread_source"),
                "state_available": bool(row),
            }
        )
    tasks.sort(key=lambda task: (task["recency_at"] or 0, task["id"]), reverse=True)
    return {
        "schema_version": 1,
        "scope": scope,
        "warning": warning,
        "count": len(tasks),
        "tasks": tasks,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--codex-home",
        type=Path,
        default=Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")),
    )
    parser.add_argument("--include-archived", action="store_true")
    parser.add_argument("--format", choices=("json", "tsv"), default="json")
    args = parser.parse_args()
    try:
        result = build_inventory(args.codex_home.expanduser(), args.include_archived)
    except (OSError, sqlite3.Error, RuntimeError) as error:
        print(f"local_chat_inventory: {error}", file=sys.stderr)
        return 1

    if args.format == "json":
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print("id\ttitle\trecency_at\tupdated_at\tarchived\tpinned\tcwd")
        for task in result["tasks"]:
            values = [
                task["id"], task["title"], task["recency_at"], task["updated_at"],
                task["archived"], task["pinned"], task["cwd"],
            ]
            print("\t".join("" if value is None else str(value) for value in values))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
