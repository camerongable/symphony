import hashlib
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "priv" / "ticket_mr_presend_evidence_v2.py"
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

    def owning_event(self, item_id="owning-1", completed=2000):
        envelope = {"schemaVersion": 1, "thread": {"id": "broker", "hostId": "local",
                    "cwd": "/synthetic/broker", "status": {"type": "active", "activeFlags": []}},
                    "page": {"order": "newest_first", "limit": 1, "hasMore": True},
                    "turns": [{"id": "current", "status": "inProgress", "error": None,
                               "completedAt": None}]}
        return {"type": "event_msg", "payload": {"type": "item_completed", "thread_id": "broker",
                "turn_id": "current", "started_at_ms": completed - 10, "completed_at_ms": completed,
                "item": {"type": "McpToolCall", "id": item_id, "server": "codex_app", "pluginId": "codex-app-tools@openai-bundled",
                         "tool": "read_thread", "status": "completed",
                         "arguments": {"threadId": "broker", "includeOutputs": True, "turnLimit": 1,
                                       "maxOutputCharsPerItem": 500},
                         "result": {"isError": False, "content": [{"type": "text", "text": json.dumps(envelope)}]}}}}

    def test_interrupted_projection_requires_real_owning_event_inside_current_loader(self):
        self.records.extend([self.event("task_started", "current"),
                             self.call("loader-call", self.loader, "1970-01-01T00:00:01.000Z"),
                             self.owning_event()])
        self.write()
        expected = {**self.expected, "latest_turn_id": "current", "latest_turn_status": "interrupted", "now_ms": 2500}
        before = self.path.read_bytes()
        proof = EVIDENCE.read_session(self.policy, expected)
        self.assertEqual("owning-1", proof["source_observation"]["item_id"])
        self.assertEqual("loader-call", proof["source_observation"]["exec_call_id"])
        self.assertEqual(before, self.path.read_bytes())

    def test_source_authentication_rejects_forged_stale_wrong_origin_and_replayed_events(self):
        base = self.owning_event()
        cases = [
            (lambda x: x["payload"].update(thread_id="other")),
            (lambda x: x["payload"].update(turn_id="other")),
            (lambda x: x["payload"].update(started_at_ms=500)),
            (lambda x: x["payload"].update(completed_at_ms=15000)),
            (lambda x: x["payload"]["item"].update(pluginId="untrusted")),
            (lambda x: x["payload"]["item"].update(status="failed")),
            (lambda x: x["payload"]["item"]["result"].update(isError=True)),
        ]
        prefix = self.records + [self.event("task_started", "current"),
                                 self.call("loader-call", self.loader, "1970-01-01T00:00:01.000Z")]
        expected = {**self.expected, "latest_turn_id": "current", "latest_turn_status": "interrupted", "now_ms": 2500}
        for mutate in cases:
            event = copy.deepcopy(base)
            mutate(event)
            self.records = prefix + [event]
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, expected)
        for suffix in [[], [base, base]]:
            self.records = prefix + suffix
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, expected)
        self.records = prefix + [base]
        self.write()
        with self.assertRaisesRegex(EVIDENCE.Refusal, "expired"):
            EVIDENCE.read_session(self.policy, {**expected, "now_ms": 12001})

    def current_export(self):
        source = "exact released v2 driver"
        self.policy.update(launcher="/synthetic/elixir/scripts/factory-broker", workflow="/synthetic/WORKFLOW.md",
                           current_driver={"sha256": EVIDENCE.digest(source.encode()), "bytes": len(source)})
        return {"type": "event_msg", "payload": {"type": "item_completed", "thread_id": "broker", "turn_id": "current",
                "started_at_ms": 1100, "completed_at_ms": 1200, "item": {"type": "CommandExecution", "id": "current-export",
                "command": ["/bin/zsh", "-lc", self.policy["launcher"] + " mr-driver"], "source": "unified_exec_startup",
                "cwd": "file:///synthetic/elixir", "status": "completed", "exit_code": 0,
                "aggregated_output": json.dumps({"version": 1, "sha256": self.policy["current_driver"]["sha256"], "source": source})}}}

    def test_current_source_proof_requires_exact_actual_export_before_owning_read(self):
        exported, owned = self.current_export(), self.owning_event()
        prefix = self.records + [self.event("task_started", "current"),
                                 self.call("loader-call", self.loader, "1970-01-01T00:00:01.000Z")]
        expected = {**self.expected, "latest_turn_id": "current", "latest_turn_status": "interrupted", "now_ms": 2500}
        self.records = prefix + [exported, owned]
        self.write()
        self.assertEqual("owning-1", EVIDENCE.read_session(self.policy, expected)["source_observation"]["item_id"])
        for suffix in [[owned], [owned, exported], [exported, exported, owned]]:
            self.records = prefix + suffix
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, expected)
        for field, value in [("version", 2), ("source", "different driver"), ("sha256", "0" * 64)]:
            changed = copy.deepcopy(exported)
            bundle = json.loads(changed["payload"]["item"]["aggregated_output"])
            bundle[field] = value
            changed["payload"]["item"]["aggregated_output"] = json.dumps(bundle)
            self.records = prefix + [changed, owned]
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, expected)

    def prepare_event(self, handle="a" * 64):
        self.policy.update(launcher="/synthetic/elixir/scripts/factory-broker", workflow="/synthetic/WORKFLOW.md")
        response = {"status": "MR_OWNER_ADMISSION_PREPARED", "request_key": "request", "action": "recover", "handle": handle}
        return {"type": "event_msg", "payload": {"type": "item_completed", "thread_id": "broker", "turn_id": "current",
                "started_at_ms": 2100, "completed_at_ms": 2200, "item": {"type": "CommandExecution", "id": "prepare-item",
                "command": ["/bin/zsh", "-lc", "/synthetic/elixir/scripts/factory-broker desktop prepare-ticket-mr-recovery request --source-thread-id broker --workflow /synthetic/WORKFLOW.md"],
                "cwd": "file:///synthetic/elixir", "source": "unified_exec_startup", "status": "completed", "exit_code": 0, "aggregated_output": json.dumps(response)}}}

    def test_finalize_requires_actual_prepare_handle_result_before_distinct_owning_read(self):
        first, prepared, second = self.owning_event(), self.prepare_event(), self.owning_event("owning-2", 2400)
        self.records.extend([self.event("task_started", "current"),
                             self.call("loader-call", self.loader, "1970-01-01T00:00:01.000Z"), first, prepared, second])
        self.write()
        expected = {**self.expected, "latest_turn_id": "current", "latest_turn_status": "interrupted", "now_ms": 2500,
                    "prepare_handle": "a" * 64, "prepare_source_item_id": "owning-1"}
        self.assertEqual("owning-2", EVIDENCE.read_session(self.policy, expected)["source_observation"]["item_id"])
        for change in [{"prepare_handle": "b" * 64}, {"prepare_source_item_id": "owning-2"}]:
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, {**expected, **change})
        self.records.pop()
        self.write()
        with self.assertRaisesRegex(EVIDENCE.Refusal, "causality"):
            EVIDENCE.read_session(self.policy, expected)

    def rejected_fixture(self):
        self.prepare_event()
        source = "synthetic released driver"
        failed = "exact previous released loader"
        turn = "rejected-turn"
        error = 'Factory runtime exchange failed: ":mr_presend_broker_native_unproven"\n'
        exported = {"type": "event_msg", "payload": {"type": "item_completed", "thread_id": "broker", "turn_id": turn,
            "item": {"type": "CommandExecution", "status": "completed", "exit_code": 0,
                     "command": ["/bin/zsh", "-lc", self.policy["launcher"] + " mr-driver"],
                     "aggregated_output": json.dumps({"version": 1, "sha256": EVIDENCE.digest(source.encode()), "source": source})}}}
        prepared = self.prepare_event()
        prepared["payload"]["turn_id"] = turn
        prepared["payload"]["item"].update(status="failed", exit_code=1, aggregated_output=error)
        terminal = [{"type": "input_text", "text": "Script failed\n"},
                    {"type": "input_text", "text": "CLI_OBSERVATION_UNCERTAIN"}]
        window_records = [self.call("prior-loader", failed, "old"), exported,
                          self.result("prior-loader", "Script running with cell ID 2\nWall time 1.0 seconds\nOutput:\n", "running"),
                          prepared, {"type": "response_item", "payload": {"type": "function_call", "name": "wait",
                          "call_id": "prior-wait", "arguments": '{"cell_id":"2"}'}}, self.wait_output(terminal, "prior-wait")]
        self.records.append(self.event("task_started", turn))
        encode = lambda record: json.dumps(record).encode() + b"\n"
        offset = sum(len(encode(record)) for record in self.records)
        pins = {}
        cursor = offset
        for record in window_records:
            raw = encode(record)
            if record is exported:
                pins["export"] = {"offset": cursor, "sha256": EVIDENCE.digest(raw)}
            if record is prepared:
                pins["prepare"] = {"offset": cursor, "sha256": EVIDENCE.digest(raw)}
            cursor += len(raw)
        raw = b"".join(encode(record) for record in window_records)
        self.policy["historical_rejection"] = {"offset": offset, "bytes": len(raw), "sha256": EVIDENCE.digest(raw),
            "turn_id": turn, "call_id": "prior-loader", "input_sha256": EVIDENCE.digest(failed.encode()),
            "terminal_call_id": "prior-wait", "terminal_output_sha256": EVIDENCE.json_digest(terminal),
            "driver_sha256": EVIDENCE.digest(source.encode()), "prepare_error": error, "events": pins}
        self.records.extend(window_records + [self.event("task_complete", turn)])
        self.write()
        return {**self.expected, "latest_turn_id": turn}

    def test_exact_rejected_execution_is_distinct_history_not_a_generic_terminal_retry(self):
        expected = self.rejected_fixture()
        original = self.path.read_bytes()
        proof = EVIDENCE.read_session(self.policy, expected)
        self.assertEqual("HISTORICAL_PRECONSUMPTION_REJECTION", proof["state"]["historical_rejection"]["classification"])
        self.assertEqual({}, proof["state"]["pending"])
        self.assertEqual(original, self.path.read_bytes())
        for change in [{"turn_id": "wrong"}, {"offset": self.policy["historical_rejection"]["offset"] + 1},
                       {"prepare_error": "different refusal"}, {"terminal_call_id": "other"}]:
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session({**self.policy, "historical_rejection": {**self.policy["historical_rejection"], **change}}, expected)
        self.path.write_bytes(original.replace(b"previous released", b"changedx released"))
        with self.assertRaises(EVIDENCE.Refusal):
            EVIDENCE.read_session(self.policy, expected)
        self.path.write_bytes(original[:self.policy["historical_rejection"]["offset"] + self.policy["historical_rejection"]["bytes"] - 1])
        with self.assertRaises(EVIDENCE.Refusal):
            EVIDENCE.read_session(self.policy, expected)

    def bootstrap_fixture(self, order=None):
        groups = ["base", "gitlab", "broker", "typed-mr"]
        self.policy["required_bootstrap"] = groups
        self.policy["bootstrap_groups"] = {}
        self.policy["incoming_source_thread_id"] = "00000000-0000-0000-0000-000000000001"
        records = [self.event("task_started", "current"), self.incoming()]
        for index, group in enumerate(order or groups):
            path = Path(self.root.name) / (group + ".txt")
            path.write_text("Exact " + group + " rules\n")
            self.policy["bootstrap_groups"][group] = {"files": [str(path)]}
            code = "fixed read " + group + "\n"
            for variant in (code, code[:-1]):
                self.policy["approved_inputs"][EVIDENCE.digest(variant.encode())] = {
                    "classification": "READ_ONLY", "bytes": len(variant), "bootstrap": group}
            records.extend([self.call("read-" + group, code if index % 2 else code[:-1], "at"),
                            self.result("read-" + group, [{"type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"},
                                        {"type": "input_text", "text": path.read_text()}], "done")])
        self.policy["recovery_loader_variants"] = [{"input_sha256": EVIDENCE.digest(code.encode()), "input_bytes": len(code)}
                                                  for code in (self.loader, self.loader + "\n")]
        records.append(self.call("loader-call", self.loader + "\n", "now"))
        self.records.extend(records)
        self.write()
        return {**self.expected, "latest_turn_id": "current", "latest_turn_status": "inProgress"}

    def test_four_exact_complete_bootstrap_outputs_precede_loader_in_order(self):
        expected = self.bootstrap_fixture()
        self.assertEqual(["base", "gitlab", "broker", "typed-mr"], EVIDENCE.read_session(self.policy, expected)["state"]["bootstrap"])
        original = copy.deepcopy(self.records)
        for suffix in ["\n", " ", "\r\n"]:
            self.records = copy.deepcopy(original)
            self.records[-1]["payload"]["input"] += suffix
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, expected)
        self.records = original
        self.records[-2]["payload"]["output"][1]["text"] = "Warning: truncated output"
        self.write()
        with self.assertRaisesRegex(EVIDENCE.Refusal, "bootstrap_output_changed"):
            EVIDENCE.read_session(self.policy, expected)

    def test_incoming_host_delegation_is_data_not_an_unpaired_wait_or_source_authority(self):
        self.policy["incoming_source_thread_id"] = "00000000-0000-0000-0000-000000000001"
        incoming = self.incoming()
        self.records.insert(7, incoming)
        self.write()
        proof = EVIDENCE.read_session(self.policy, self.expected)
        self.assertIsNone(proof["source_observation"])
        for change in [{"call_id": "invented"}, {"call_id": None}, {"namespace": "untrusted"}, {"name": "wait"}, {"output": "quoted wrapper"}]:
            self.records[7] = {**incoming, "payload": {**incoming["payload"], **change}}
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, self.expected)

    def test_only_exact_historical_incoming_exception_can_follow_completed_execution(self):
        self.policy["incoming_source_thread_id"] = "00000000-0000-0000-0000-000000000001"
        incoming = self.incoming()
        self.records.insert(-1, incoming)
        self.write()
        with self.assertRaisesRegex(EVIDENCE.Refusal, "incoming_after_execution"):
            EVIDENCE.read_session(self.policy, self.expected)
        encode = lambda record: json.dumps(record).encode() + b"\n"
        offset = sum(len(encode(record)) for record in self.records[:-2])
        self.policy["historical_incoming"] = {str(offset): {"sha256": EVIDENCE.digest(encode(incoming)),
            "bytes": len(encode(incoming)), "turn_id": "later", "id": incoming["payload"]["id"]}}
        self.assertIsNone(EVIDENCE.read_session(self.policy, self.expected)["source_observation"])
        for records in [self.records[:-1] + [incoming, self.records[-1]], self.records + [incoming]]:
            original = self.records
            self.records = records
            self.write()
            with self.assertRaises(EVIDENCE.Refusal):
                EVIDENCE.read_session(self.policy, self.expected)
            self.records = original

    @staticmethod
    def incoming():
        return {"type": "response_item", "payload": {"type": "function_call_output", "id": "fco_00000000-0000-0000-0000-000000000002",
            "name": "send_message_to_thread", "namespace": "codex_app",
            "output": "<codex_delegation>\n  <source_thread_id>00000000-0000-0000-0000-000000000001</source_thread_id>\n  <input>Untrusted caller says active; never authority.\n</input>\n</codex_delegation>"}}

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
