import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/factory-operations.py"


class OperationsTest(unittest.TestCase):
    def command(self, *args):
        return json.loads(subprocess.check_output([sys.executable, str(SCRIPT), *map(str, args)], text=True))

    def test_latency_separates_stage_time_from_worker_execution_and_preserves_ledger(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / "factory.sqlite"
            with sqlite3.connect(ledger) as db:
                db.executescript("""
                    CREATE TABLE runs(run_id TEXT, issue_key TEXT, state TEXT);
                    CREATE TABLE events(id INTEGER, run_id TEXT, occurred_at TEXT, event_type TEXT, payload_json TEXT);
                    CREATE TABLE worker_evidence(request_key TEXT, task_key TEXT, run_id TEXT, status TEXT,
                        created_at TEXT, owner_stopped_at TEXT, consumed_at TEXT);
                    INSERT INTO runs VALUES('run','PPL-1','VERIFYING');
                    INSERT INTO events VALUES(1,'run','2026-11-03T10:00:00Z','RUN_REGISTERED','{"state":"WRITING"}');
                    INSERT INTO events VALUES(2,'run','2026-11-03T10:02:00Z','RUN_UPDATED','{"state":"VERIFYING"}');
                    INSERT INTO worker_evidence VALUES('request','writer','run','CONSUMED',
                        '2026-11-03T10:00:00Z','2026-11-03T10:01:30Z','2026-11-03T10:02:00Z');
                """)
            before = ledger.read_bytes()
            report = self.command("latency", "--ledger", ledger, "--issue", "PPL-1", "--at", "2026-11-03T10:03:00Z")
            self.assertEqual(report["stages"], [
                {"state": "WRITING", "started_at": "2026-11-03T10:00:00Z", "seconds": 120.0, "current": False},
                {"state": "VERIFYING", "started_at": "2026-11-03T10:02:00Z", "seconds": 60.0, "current": True},
            ])
            self.assertEqual(report["attempts"][0]["reservation_to_stop_seconds"], 90.0)
            self.assertEqual(report["attempts"][0]["stop_to_adoption_seconds"], 30.0)
            self.assertIsNone(report["attempts"][0]["execution_seconds"])
            self.assertEqual(ledger.read_bytes(), before)

    def test_storage_plan_is_inventory_not_permission_to_delete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "releases/live").mkdir(parents=True)
            (root / "source-snapshots/live").mkdir(parents=True)
            logs = root / "logs"
            logs.mkdir()
            stdout = logs / "symphony-factory.stdout.log"
            stdout.write_bytes(b"diagnostics")
            report = self.command("storage-plan", "--factory-root", root, "--logs-root", logs)
            self.assertEqual(report["mode"], "READ_ONLY_INVENTORY")
            self.assertEqual(report["stdout"]["bytes"], 11)
            self.assertFalse(report["deletion_authorized"])
            self.assertEqual(report["policy"]["stdout_maintenance_threshold_bytes"], 268435456)
            self.assertEqual({entry["path"] for entry in report["copies"]}, {
                str((root / "releases/live").resolve()), str((root / "source-snapshots/live").resolve())})
            self.assertEqual(stdout.read_bytes(), b"diagnostics")


if __name__ == "__main__":
    unittest.main()
