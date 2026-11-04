#!/usr/bin/env python3
"""Read-only operational reports. Never dispatches, retries, rotates or deletes."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import subprocess


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def seconds(start, end):
    if not start or not end:
        return None
    elapsed = (instant(end) - instant(start)).total_seconds()
    return round(elapsed, 3) if elapsed >= 0 else None


def latency(args):
    with sqlite3.connect(Path(args.ledger).resolve().as_uri() + "?mode=ro", uri=True) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        runs = list(db.execute("SELECT run_id,issue_key,state FROM runs WHERE issue_key=? ORDER BY rowid DESC LIMIT 1", (args.issue,)))
        if not runs:
            raise ValueError("No recorded run for this issue")
        run = dict(runs[0])
        events = db.execute("SELECT occurred_at,payload_json FROM events WHERE run_id=? AND event_type IN ('RUN_REGISTERED','RUN_UPDATED') ORDER BY id", (run["run_id"],))
        stages = []
        for event in events:
            state = json.loads(event["payload_json"]).get("state")
            if state and (not stages or stages[-1]["state"] != state):
                stages.append({"state": state, "started_at": event["occurred_at"]})
        for index, stage in enumerate(stages):
            current = index == len(stages) - 1
            stage.update(seconds=seconds(stage["started_at"], args.at if current else stages[index + 1]["started_at"]), current=current)
        attempts = []
        for row in db.execute("SELECT request_key,task_key,status,created_at,owner_stopped_at,consumed_at FROM worker_evidence WHERE run_id=? ORDER BY created_at,request_key", (run["run_id"],)):
            attempt = dict(row)
            attempt.update(reservation_to_stop_seconds=seconds(row["created_at"], row["owner_stopped_at"]),
                           stop_to_adoption_seconds=seconds(row["owner_stopped_at"], row["consumed_at"]),
                           execution_seconds=None)
            attempts.append(attempt)
        return {"observed_at": args.at, "run": run, "stages": stages, "attempts": attempts,
                "limits": "Reservation-to-stop includes preparation, execution and recovery. Exact execution/queue split is not recorded; null is unknown. Stage time includes all waits and retries, not CPU time. Latest recorded run only."}


def storage_plan(args):
    root, logs = Path(args.factory_root).resolve(), Path(args.logs_root).resolve()
    stdout = logs / "symphony-factory.stdout.log"
    threshold = 256 * 1024 * 1024
    size = stdout.stat().st_size if stdout.is_file() else None
    try:
        opened = subprocess.run(["/usr/sbin/lsof", "-nP", "-Fpc", str(stdout)], capture_output=True, text=True, timeout=10)
        owners = opened.stdout.splitlines() if opened.returncode == 0 else []
        owner_check = "READ" if opened.returncode in (0, 1) and not opened.stderr else "UNKNOWN"
    except (OSError, subprocess.TimeoutExpired):
        owners, owner_check = [], "UNKNOWN"
    copies = []
    for group in ("releases", "source-snapshots"):
        parent = root / group
        if parent.is_dir():
            for path in sorted(parent.iterdir()):
                if path.is_dir():
                    copies.append({"path": str(path), "modified_at": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(),
                                   "eligibility": "NOT_ASSESSED"})
    return {"mode": "READ_ONLY_INVENTORY", "deletion_authorized": False,
            "stdout": {"path": str(stdout), "bytes": size, "maintenance_due": size is not None and size >= threshold,
                       "open_processes": owners, "owner_check": owner_check,
                       "proposed_archive": str(logs / "archive/symphony-factory.stdout.pre-retention.log.gz")},
            "copies": copies,
            "policy": {"stdout_maintenance_threshold_bytes": threshold, "closed_segments": 7,
                       "closed_segment_budget_bytes": 2 * 1024**3, "compressed_history_days": 30,
                       "compressed_history_budget_bytes": 2 * 1024**3, "complete_rollback_pairs": 2,
                       "unpinned_failed_build_minimum_days": 7, "unpinned_successful_build_minimum_days": 30},
            "next_action": "At an approved quiet stop, archive the closed stdout file and restart normally. Never rename live stdout or copytruncate. Before approving exact release/snapshot paths, recheck active runtime, rollback pairs, ledger/helper bindings, processes and audit/recovery references. Inventory order and age do not prove eligibility. Pinned and incident evidence override retention budgets."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    timing = commands.add_parser("latency")
    timing.add_argument("--ledger", required=True)
    timing.add_argument("--issue", required=True)
    timing.add_argument("--at", default=datetime.now(timezone.utc).isoformat())
    storage = commands.add_parser("storage-plan")
    storage.add_argument("--factory-root", required=True)
    storage.add_argument("--logs-root", required=True)
    args = parser.parse_args()
    try:
        result = latency(args) if args.command == "latency" else storage_plan(args)
    except (ValueError, OSError, sqlite3.Error) as error:
        parser.exit(1, f"Report unavailable: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
