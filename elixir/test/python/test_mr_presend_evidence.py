import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "priv" / "ticket_mr_presend_evidence_v1.py"
SPEC = importlib.util.spec_from_file_location("presend_evidence", SOURCE)
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)


class PresendEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory(prefix="presend-evidence-")
        self.addCleanup(self.root.cleanup)
        self.path = Path(self.root.name).resolve() / "session.jsonl"
        self.incident = "exact synthetic guard before send"
        self.readonly = "exact synthetic readonly"
        self.loader = "exact synthetic current recovery loader"
        self.output = [{"type": "input_text", "text": "COMMITTED_CLAIM_OUTPUT_INVALID"}]
        self.policy = {
            "session_path": str(self.path), "broker_thread_id": "broker", "broker_cwd": "/synthetic/broker",
            "incident": {"request_key": "request", "turn_id": "incident", "call_id": "incident-call",
                         "input_sha256": EVIDENCE.digest(self.incident.encode()), "input_bytes": len(self.incident),
                         "input_at": "input-at", "output_at": "output-at",
                         "output_sha256": EVIDENCE.json_digest(self.output), "claimed_at": "claimed-at"},
            "recovery_loader": {"input_sha256": EVIDENCE.digest(self.loader.encode()), "input_bytes": len(self.loader)},
            "approved_inputs": {EVIDENCE.digest(self.readonly.encode()): {"classification": "READ_ONLY", "bytes": len(self.readonly)}}
        }
        self.expected = {"request_key": "request", "broker_thread_id": "broker", "claimed_at": "claimed-at", "latest_turn_id": "later", "latest_turn_status": "completed"}
        self.records = [
            {"type": "session_meta", "payload": {"id": "broker", "cwd": "/synthetic/broker", "originator": "Codex Desktop", "source": "vscode", "thread_source": "agent_created_thread"}},
            self.event("task_started", "incident"), self.call("incident-call", self.incident, "input-at"),
            self.result("incident-call", self.output, "output-at"), self.event("task_complete", "incident"),
            {"type": "compacted", "payload": {"summary": "Not evidence and never interpreted"}},
            self.event("task_started", "later"), self.call("read-call", self.readonly, "read-at"),
            self.result("read-call", [], "read-output-at"), self.event("task_complete", "later")
        ]
        self.write()

    @staticmethod
    def event(kind, turn):
        return {"type": "event_msg", "payload": {"type": kind, "turn_id": turn}}

    @staticmethod
    def call(call_id, code, timestamp):
        return {"type": "response_item", "timestamp": timestamp,
                "payload": {"type": "custom_tool_call", "name": "exec", "call_id": call_id, "input": code}}

    @staticmethod
    def result(call_id, output, timestamp):
        return {"type": "response_item", "timestamp": timestamp,
                "payload": {"type": "custom_tool_call_output", "call_id": call_id, "output": output}}

    def write(self):
        self.path.write_bytes(b"".join(json.dumps(record).encode() + b"\n" for record in self.records))

    def test_exact_positive_cell_and_complete_suffix_survive_compaction_summary(self):
        before = self.path.read_bytes()
        proof = EVIDENCE.read_session(self.policy, self.expected)
        self.assertTrue(proof["state"]["incident_output"])
        self.assertEqual(proof["sha256"], hashlib.sha256(before).hexdigest())
        self.assertEqual(before, self.path.read_bytes())

    def test_current_exact_loader_is_the_only_unfinished_call_and_recheck_is_append_only(self):
        proof = EVIDENCE.read_session(self.policy, self.expected)
        self.records.extend([self.event("task_started", "current"), self.call("loader-call", self.loader, "now")])
        self.write()
        expected = {**self.expected, "latest_turn_id": "current", "latest_turn_status": "inProgress"}
        refreshed = EVIDENCE.read_session(self.policy, expected, proof)
        self.assertEqual(list(refreshed["state"]["pending"]), ["loader-call"])
        self.path.write_bytes(self.path.read_bytes().replace(b"claimed", b"altered", 1))
        self.path.write_bytes(self.path.read_bytes().replace(b"synthetic", b"changedxx", 1))
        with self.assertRaisesRegex(EVIDENCE.Refusal, "prefix_changed"):
            EVIDENCE.read_session(self.policy, expected, refreshed)

    def test_unknown_later_code_even_without_send_substring_is_refused(self):
        self.records.insert(-1, self.call("unknown", "tools[computed_name](payload)", "later"))
        self.write()
        with self.assertRaisesRegex(EVIDENCE.Refusal, "input_unreviewed"):
            EVIDENCE.read_session(self.policy, self.expected)

    def test_wrong_code_output_call_and_turn_are_refused(self):
        for field, value in [("input_sha256", "0" * 64), ("output_sha256", "0" * 64), ("call_id", "other"), ("turn_id", "other")]:
            with self.subTest(field=field):
                policy = {**self.policy, "incident": {**self.policy["incident"], field: value}}
                with self.assertRaises(EVIDENCE.Refusal):
                    EVIDENCE.read_session(policy, self.expected)

    def test_missing_output_duplicate_call_and_truncated_record_are_refused(self):
        original = self.records[:]
        for records in [original[:8] + original[9:], original[:8] + [original[7]] + original[8:]]:
            self.records = records
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, self.expected)
        self.records = original
        self.write()
        self.path.write_bytes(self.path.read_bytes()[:-1])
        with self.assertRaisesRegex(EVIDENCE.Refusal, "line_incomplete"):
            EVIDENCE.read_session(self.policy, self.expected)

    def test_symlink_session_is_never_followed(self):
        real = self.path.with_suffix(".actual")
        self.path.rename(real)
        self.path.symlink_to(real)
        with self.assertRaises(OSError):
            EVIDENCE.read_session(self.policy, self.expected)

    def test_known_loader_after_completed_turn_cannot_claim_to_be_current(self):
        self.records.append(self.call("loader-call", self.loader, "after-completion"))
        self.write()
        with self.assertRaisesRegex(EVIDENCE.Refusal, "call_outside_active_turn"):
            EVIDENCE.read_session(self.policy, self.expected)

    def start_running_loader(self):
        self.records.extend([self.event("task_started", "current"), self.call("loader-call", self.loader, "now"),
                             self.result("loader-call", "Script running with cell ID 1271\nWall time 1.0 seconds\nOutput:\n", "yield")])
        self.write()
        return {**self.expected, "latest_turn_id": "current", "latest_turn_status": "inProgress"}

    @staticmethod
    def wait(call="wait-1", **arguments):
        return {"type": "response_item", "payload": {"type": "function_call", "name": "wait", "call_id": call,
                "arguments": json.dumps({"cell_id": "1271", "yield_time_ms": 1000, "max_tokens": 500, **arguments})}}

    @staticmethod
    def wait_output(output, call="wait-1"):
        return {"type": "response_item", "payload": {"type": "function_call_output", "call_id": call, "output": output}}

    def test_real_shaped_async_exec_running_wait_and_pending_wait_remain_one_execution(self):
        expected = self.start_running_loader()
        first = EVIDENCE.read_session(self.policy, expected)
        self.assertEqual(first["state"]["active_recovery"]["cell_id"], "1271")
        self.records.extend([self.wait(), self.wait_output("Script running with cell ID 1271\nWall time 1.0 seconds\nOutput:\n"),
                             self.wait("wait-2", yield_time_ms=60000, max_tokens=1500)])
        self.write()
        proof = EVIDENCE.read_session(self.policy, expected, first)
        self.assertEqual(list(proof["state"]["pending"]), ["wait-2"])
        self.assertEqual(proof["state"]["active_recovery"]["exec_call_id"], "loader-call")
        self.records.append(self.wait_output([{"type": "input_text", "text": "Script running with cell ID 1271\nWall time 1.0 seconds\nOutput:\n"}], "wait-2"))
        self.write()
        self.assertEqual(EVIDENCE.read_session(self.policy, expected, proof)["state"]["pending"], {})

    def test_async_terminal_error_wrong_cell_and_output_type_never_authorize_recovery(self):
        expected = self.start_running_loader()
        base = self.records[:]
        outputs = ["Script completed\nWall time 0.0 seconds\nOutput:\n", "Error: interrupted", "Script running with cell ID 9999\nWall time 1.0 seconds\nOutput:\n",
                   [{"type": "input_text", "text": "Script completed\nWall time 0.0 seconds\nOutput:\n"}, {"type": "input_text", "text": "{}"}]]
        for output in outputs:
            with self.subTest(output=output):
                self.records = base + [self.wait(), self.wait_output(output)]
                self.write()
                with self.assertRaises(EVIDENCE.Refusal):
                    EVIDENCE.read_session(self.policy, expected)
        self.records = base + [self.wait(), self.result("wait-1", "Script running with cell ID 1271\nWall time 1.0 seconds\nOutput:\n", "wrong-type")]
        self.write()
        with self.assertRaises(EVIDENCE.Refusal):
            EVIDENCE.read_session(self.policy, expected)

    def test_wait_arguments_duplicates_second_execution_and_turn_changes_refuse(self):
        expected = self.start_running_loader()
        base = self.records[:]
        tails = [[self.wait(cell_id="9999")], [self.wait(terminate=True)], [self.wait(yield_time_ms=True)],
                 [self.wait(yield_time_ms=60001)], [self.wait(max_tokens=30001)], [self.wait(extra="unknown")],
                 [self.wait(), self.wait()], [self.wait(), self.wait("wait-2")],
                 [self.call("loader-2", self.loader, "second")], [self.call("read-other", self.readonly, "intervening")], [self.event("task_complete", "current")],
                 [self.event("task_started", "new-turn")]]
        duplicate = self.wait()
        duplicate["payload"]["arguments"] = '{"cell_id":"1271","cell_id":"1271"}'
        tails.append([duplicate])
        for tail in tails:
            with self.subTest(tail=tail):
                self.records = base + tail
                self.write()
                with self.assertRaises(EVIDENCE.Refusal):
                    EVIDENCE.read_session(self.policy, expected)
        self.records = base
        self.write()
        with self.assertRaises(EVIDENCE.Refusal):
            EVIDENCE.read_session(self.policy, {**expected, "latest_turn_status": "completed"})


if __name__ == "__main__":
    unittest.main()
