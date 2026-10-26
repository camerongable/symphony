"""Read-only, incident-bound evidence; never executes historical source or grants a send."""
import base64
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys

MAX_FILE = 2 * 1024 * 1024 * 1024
MAX_LINE = 4 * 1024 * 1024
MAX_SUFFIX = 128 * 1024 * 1024
MAX_TURNS = 1024
MAX_CALLS = 4096
REGISTRY_SHA256 = "6801c933e52b82231a0d85d8ef8d3b65aca618c524c98ee087de058f6cc4db99"


class Refusal(Exception):
    pass


def require(value, code):
    if not value:
        raise Refusal(code)


def pairs(values):
    result = {}
    for key, value in values:
        require(key not in result, "mr_presend_duplicate_json_key")
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=pairs)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def json_digest(value):
    return digest(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode())


def identity(info):
    return {"device": info.st_dev, "inode": info.st_ino, "size": info.st_size,
            "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}


def open_regular(path, maximum):
    require(isinstance(path, str) and path.startswith("/") and str(Path(path)) == path,
            "mr_presend_path_invalid")
    parent = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parts = Path(path).parts[1:]
        for part in parts[:-1]:
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = following
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        info = os.fstat(descriptor)
        valid = stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid() and 0 < info.st_size <= maximum
        if not valid:
            os.close(descriptor)
            raise Refusal("mr_presend_file_invalid")
        return descriptor, info
    finally:
        os.close(parent)


def registry():
    path = str(Path(__file__).resolve().parent / "ticket_mr_presend_registry_v3.json")
    descriptor, before = open_regular(path, 262144)
    with os.fdopen(descriptor, "rb") as stream:
        raw = stream.read(262145)
        require(identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_registry_changed")
    require(digest(raw) == REGISTRY_SHA256, "mr_presend_registry_changed")
    result = decode(raw)
    require(result["version"] == 3, "mr_presend_registry_invalid")
    driver = result["current_driver"]
    descriptor, before = open_regular(str(Path(__file__).resolve().parent / "ticket_mr_broker_driver_v2.js"), 262144)
    with os.fdopen(descriptor, "rb") as stream:
        raw = stream.read(262145)
        require(digest(raw) == driver["sha256"] and len(raw) == driver["bytes"]
                and identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_current_driver_changed")
    additional = result.get("additional_rejected_runtimes", [])
    require(isinstance(additional, list) and len(additional) <= 1, "mr_presend_registry_invalid")
    for historical in [result["historical_runtime"], result["rejected_runtime"]] + additional:
        attest_runtime(historical)
    for path, expected in result["external_readers"].items():
        descriptor, before = open_regular(path, 1048576)
        with os.fdopen(descriptor, "rb") as stream:
            require(digest(stream.read(1048577)) == expected
                    and identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_runtime_unproven")
    return result


def attest_runtime(historical):
    descriptor, before = open_regular(historical["manifest_path"], 8 * 1024 * 1024)
    with os.fdopen(descriptor, "rb") as stream:
        raw = stream.read(8 * 1024 * 1024 + 1)
        require(identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_manifest_changed")
    require(digest(raw) == historical["manifest_sha256"], "mr_presend_manifest_changed")
    manifest = decode(raw)
    require(manifest["release"] == historical["release"], "mr_presend_manifest_changed")
    for name, expected in historical["source"].items():
        require(manifest["source"][name]["sha256"] == expected, "mr_presend_runtime_unproven")
    for name, expected in historical["artifact"].items():
        require(manifest["artifact"][name]["sha256"] == expected, "mr_presend_runtime_unproven")
        descriptor, before = open_regular(str(Path(historical["release"]) / "dev" / name), 16777216)
        with os.fdopen(descriptor, "rb") as stream:
            require(digest(stream.read(16777217)) == expected
                    and identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_runtime_unproven")


def state_initial():
    return {"turn": None, "turns": [], "completed_turns": [], "calls": {}, "pending": {},
            "incident_seen": False, "incident_output": False, "suffix_bytes": 0,
            "incident_offset": None, "active_recovery": None,
            "nested_ids": [], "source_observations": [], "prepare_results": [], "historical_rejection": None,
            "historical_rejections": {}, "bootstrap": [],
            "diagnostic_outputs": {}, "incoming_seen": False, "turn_executed": False, "incoming_ids": []}


def incoming_delegation(record, raw, offset, state, policy):
    payload = record["payload"]
    require("call_id" not in payload and payload.get("name") == "send_message_to_thread"
            and payload.get("namespace") == "codex_app" and isinstance(payload.get("id"), str)
            and re.fullmatch(r"fco_[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", payload["id"]),
            "mr_presend_incoming_unproven")
    require(state["turn"] is not None and state["turn"] not in state["completed_turns"]
            and not state["pending"] and state["active_recovery"] is None and not state["incoming_seen"]
            and payload["id"] not in state["incoming_ids"] and len(state["incoming_ids"]) < MAX_TURNS,
            "mr_presend_incoming_overlap")
    if state["turn_executed"]:
        pin = policy.get("historical_incoming", {}).get(str(offset), {})
        require(pin.get("sha256") == digest(raw) and pin.get("bytes") == len(raw)
                and pin.get("turn_id") == state["turn"] and pin.get("id") == payload["id"],
                "mr_presend_incoming_after_execution")
    output = payload.get("output")
    source = policy.get("incoming_source_thread_id")
    require(isinstance(source, str) and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", source),
            "mr_presend_incoming_source_unproven")
    prefix = "<codex_delegation>\n  <source_thread_id>" + source + "</source_thread_id>\n  <input>"
    suffix = "\n</input>\n</codex_delegation>"
    require(isinstance(output, str) and len(output.encode()) <= 65536 and output.startswith(prefix)
            and output.endswith(suffix) and output.count("<codex_delegation>") == 1
            and output.count("</codex_delegation>") == 1 and output.count("</input>") == 1,
            "mr_presend_incoming_wrapper_unproven")
    state["incoming_seen"] = True
    state["incoming_ids"].append(payload["id"])


def loader_variants(policy):
    return policy.get("recovery_loader_variants", [policy["recovery_loader"]])


def matches_loader(code, size, policy):
    return any(code == entry["input_sha256"] and size == entry["input_bytes"] for entry in loader_variants(policy))


def bootstrap_output(output, group, policy):
    require(isinstance(output, list) and len(output) == 2
            and all(isinstance(block, dict) and set(block) == {"type", "text"}
                    and block["type"] == "input_text" and isinstance(block["text"], str) for block in output),
            "mr_presend_bootstrap_incomplete")
    require(re.fullmatch(r"Script completed\nWall time [0-9]+(?:\.[0-9]+)? seconds\nOutput:\n", output[0]["text"])
            is not None, "mr_presend_bootstrap_incomplete")
    expected = bytearray()
    for path in policy["bootstrap_groups"][group]["files"]:
        descriptor, before = open_regular(str(Path(path).resolve(strict=True)), 262144)
        with os.fdopen(descriptor, "rb") as stream:
            expected.extend(stream.read(262145))
            require(identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_bootstrap_files_changed")
        require(len(expected) <= 262144, "mr_presend_bootstrap_limit")
    require(output[1]["text"].encode() == bytes(expected), "mr_presend_bootstrap_output_changed")


def rejected_windows(policy):
    windows = ([policy["historical_rejection"]] if policy.get("historical_rejection") else [])
    additional = policy.get("additional_historical_rejections", [])
    require(isinstance(additional, list) and len(additional) <= 1, "mr_presend_rejected_boundary_unproven")
    windows += additional
    end = 0
    for window in windows:
        require(type(window.get("offset")) is int and type(window.get("bytes")) is int
                and window["offset"] >= end and 0 < window["bytes"] <= MAX_SUFFIX,
                "mr_presend_rejected_boundary_unproven")
        end = window["offset"] + window["bytes"]
    return windows


def rejected_window(records, raw_sha, state, policy, window):
    require(raw_sha == window["sha256"] and state["turn"] == window["turn_id"]
            and not state["pending"] and state["active_recovery"] is None, "mr_presend_rejected_window_changed")
    first, last = records[0][1], records[-1][1]
    require(first.get("type") == "response_item" and first["payload"].get("type") == "custom_tool_call"
            and first["payload"].get("name") == "exec" and first["payload"].get("call_id") == window["call_id"]
            and isinstance(first["payload"].get("input"), str)
            and digest(first["payload"]["input"].encode()) == window["input_sha256"], "mr_presend_rejected_boundary_unproven")
    require(last.get("type") == "response_item" and last["payload"].get("type") == "function_call_output"
            and last["payload"].get("call_id") == window["terminal_call_id"]
            and json_digest(last["payload"].get("output")) == window["terminal_output_sha256"],
            "mr_presend_rejected_terminal_unproven")
    indexed = {offset: (record, sha) for offset, record, sha in records}
    require(len(indexed) == len(records), "mr_presend_rejected_window_changed")
    for pin in window["events"].values():
        require(pin["offset"] in indexed and indexed[pin["offset"]][1] == pin["sha256"],
                "mr_presend_rejected_event_unproven")
    exported = indexed[window["events"]["export"]["offset"]][0]["payload"]
    prepared = indexed[window["events"]["prepare"]["offset"]][0]["payload"]
    for event in (exported, prepared):
        require(event.get("type") == "item_completed" and event.get("thread_id") == policy["broker_thread_id"]
                and event.get("turn_id") == window["turn_id"] and event.get("item", {}).get("type") == "CommandExecution",
                "mr_presend_rejected_event_unproven")
    export_item, prepare_item = exported["item"], prepared["item"]
    require(export_item.get("status") == "completed" and export_item.get("exit_code") == 0
            and export_item.get("command") == ["/bin/zsh", "-lc", policy["launcher"] + " mr-driver"],
            "mr_presend_rejected_export_unproven")
    bundle = decode(export_item.get("aggregated_output", ""))
    require(bundle.get("version") == 1 and bundle.get("sha256") == window["driver_sha256"]
            and digest(bundle["source"].encode()) == window["driver_sha256"], "mr_presend_rejected_export_unproven")
    expected = [policy["launcher"], "desktop", "prepare-ticket-mr-recovery", policy["incident"]["request_key"],
                "--source-thread-id", policy["broker_thread_id"], "--workflow", policy["workflow"]]
    require(prepare_item.get("status") == "failed" and prepare_item.get("exit_code") == 1
            and prepare_item.get("command", [])[:2] == ["/bin/zsh", "-lc"]
            and shlex.split(prepare_item["command"][2]) == expected
            and prepare_item.get("aggregated_output") == window["prepare_error"], "mr_presend_rejected_prepare_unproven")
    seen, outputs = set(), set()
    for _, record, _ in records:
        payload = record["payload"]
        require(payload.get("type") not in {"task_started", "task_complete"}, "mr_presend_rejected_turn_changed")
        if record["type"] == "response_item":
            kind, call = payload.get("type"), payload.get("call_id")
            if kind in {"custom_tool_call", "function_call"}:
                require(call in {window["call_id"], window["terminal_call_id"]} and call not in seen
                        and call not in state["calls"], "mr_presend_rejected_call_conflict")
                seen.add(call)
            elif kind in {"custom_tool_call_output", "function_call_output"}:
                require(call in seen and call not in outputs, "mr_presend_rejected_output_unpaired")
                outputs.add(call)
        if payload.get("type") == "item_completed" and payload.get("item", {}).get("type") == "McpToolCall":
            item = payload["item"]
            require(item.get("server") == "codex_app" and item.get("tool") == "read_thread",
                    "mr_presend_rejected_issuance_present")
    require(seen == outputs == {window["call_id"], window["terminal_call_id"]}, "mr_presend_rejected_output_unpaired")
    state["calls"].update({call: True for call in seen})
    state["turn_executed"] = True
    state["historical_rejection"] = {"classification": "HISTORICAL_PRECONSUMPTION_REJECTION",
        "offset": window["offset"], "bytes": window["bytes"], "sha256": raw_sha,
        "turn_id": window["turn_id"], "call_id": window["call_id"]}
    state["historical_rejections"][str(window["offset"])] = state["historical_rejection"]


def loader_entry(state):
    entries = [(call, entry) for call, entry in state["pending"].items()
               if entry["classification"] == "CURRENT_RECOVERY"]
    if state["active_recovery"] is not None:
        entry = state["active_recovery"]
        entries.append((entry["exec_call_id"], entry))
    require(len(entries) == 1, "mr_presend_source_loader_unproven")
    return entries[0]


def nested_event(record, offset, state, policy):
    payload = record["payload"]
    item = payload.get("item", {})
    if not isinstance(item, dict):
        raise Refusal("mr_presend_nested_event_invalid")
    # Historical item events are not substituted for the current pending invocation.
    if state["active_recovery"] is None and not any(
            entry["classification"] == "CURRENT_RECOVERY" for entry in state["pending"].values()):
        return
    call, loader = loader_entry(state)
    require(payload.get("thread_id") == policy["broker_thread_id"]
            and payload.get("turn_id") == state["turn"] == loader["turn_id"], "mr_presend_source_turn_unproven")
    identifier = item.get("id")
    require(isinstance(identifier, str) and identifier not in state["nested_ids"], "mr_presend_nested_id_conflict")
    state["nested_ids"].append(identifier)
    require(len(state["nested_ids"]) <= MAX_CALLS, "mr_presend_call_limit")
    if (item.get("type") == "McpToolCall" and item.get("server") == "codex_app" and item.get("tool") == "read_thread"
            and isinstance(item.get("arguments"), dict) and item["arguments"].get("threadId") == policy["broker_thread_id"]):
        source_event(record, offset, call, loader, state, policy)
    elif item.get("type") == "CommandExecution":
        current_export(record, offset, call, loader, state, policy)
        prepare_event(record, offset, call, loader, state, policy)


def current_export(record, offset, call, loader, state, policy):
    if policy.get("current_driver") is None:
        return
    payload, item = record["payload"], record["payload"]["item"]
    if item.get("command") != ["/bin/zsh", "-lc", policy["launcher"] + " mr-driver"]:
        return
    started, completed = nested_times(payload, loader, offset)
    require(item.get("status") == "completed" and type(item.get("exit_code")) is int and item["exit_code"] == 0
            and item.get("source") == "unified_exec_startup"
            and item.get("cwd") == "file://" + str(Path(policy["launcher"]).parent.parent),
            "mr_presend_current_export_unproven")
    raw = item.get("aggregated_output")
    require(isinstance(raw, str) and len(raw.encode()) <= 262144, "mr_presend_current_export_unproven")
    bundle = decode(raw)
    require(isinstance(bundle, dict) and set(bundle) == {"version", "sha256", "source"}
            and bundle["version"] == 1 and isinstance(bundle["source"], str)
            and bundle["sha256"] == policy["current_driver"]["sha256"]
            and digest(bundle["source"].encode()) == policy["current_driver"]["sha256"]
            and len(bundle["source"].encode()) == policy["current_driver"]["bytes"], "mr_presend_current_export_unproven")
    exports = state.setdefault("current_exports", [])
    require(not any(entry["exec_call_id"] == call for entry in exports), "mr_presend_current_export_conflict")
    exports.append({"item_id": item["id"], "exec_call_id": call, "offset": offset,
                    "started_at_ms": started, "completed_at_ms": completed, "event_sha256": json_digest(record)})


def nested_times(payload, loader, offset):
    started, completed = payload.get("started_at_ms"), payload.get("completed_at_ms")
    require(type(started) is int and type(completed) is int and started <= completed,
            "mr_presend_source_time_unproven")
    try:
        input_at = datetime.fromisoformat(loader["input_at"].replace("Z", "+00:00")).timestamp() * 1000
    except (ValueError, TypeError, KeyError):
        raise Refusal("mr_presend_source_time_unproven")
    require(started >= input_at and offset > loader["offset"], "mr_presend_source_order_unproven")
    return started, completed


def source_event(record, offset, call, loader, state, policy):
    payload, item = record["payload"], record["payload"]["item"]
    started, completed = nested_times(payload, loader, offset)
    if policy.get("current_driver") is not None:
        exports = [entry for entry in state.get("current_exports", []) if entry["exec_call_id"] == call]
        require(len(exports) == 1 and offset > exports[0]["offset"] and started >= exports[0]["completed_at_ms"],
                "mr_presend_current_export_unproven")
    args = {"threadId": policy["broker_thread_id"], "includeOutputs": True, "turnLimit": 1, "maxOutputCharsPerItem": 500}
    require(item.get("pluginId") == "codex-app-tools@openai-bundled" and item.get("arguments") == args
            and item.get("status") == "completed" and item.get("error") is None, "mr_presend_source_tool_unproven")
    result = item.get("result")
    require(isinstance(result, dict) and result.get("isError") is False
            and isinstance(result.get("content"), list) and len(result["content"]) == 1,
            "mr_presend_source_result_unproven")
    content = result["content"][0]
    require(isinstance(content, dict) and content.get("type") == "text" and isinstance(content.get("text"), str),
            "mr_presend_source_result_unproven")
    envelope = decode(content["text"])
    require(isinstance(envelope, dict) and envelope.get("schemaVersion") == 1, "mr_presend_source_result_unproven")
    thread, turns, page = envelope.get("thread"), envelope.get("turns"), envelope.get("page")
    require(isinstance(thread, dict) and thread.get("id") == policy["broker_thread_id"]
            and thread.get("cwd") == policy["broker_cwd"] and thread.get("hostId") == "local"
            and thread.get("status") == {"type": "active", "activeFlags": []}, "mr_presend_source_identity_unproven")
    require(isinstance(page, dict) and page.get("order") == "newest_first" and page.get("limit") == 1
            and type(page.get("hasMore")) is bool and isinstance(turns, list) and len(turns) == 1,
            "mr_presend_source_page_unproven")
    turn = turns[0]
    require(isinstance(turn, dict) and turn.get("id") == loader["turn_id"] and turn.get("status") == "inProgress"
            and "error" in turn and turn["error"] is None and "completedAt" in turn and turn["completedAt"] is None,
            "mr_presend_source_active_unproven")
    state["source_observations"].append({"item_id": item["id"], "exec_call_id": call, "turn_id": loader["turn_id"],
        "offset": offset, "started_at_ms": started, "completed_at_ms": completed, "event_sha256": json_digest(record)})


def prepare_event(record, offset, call, loader, state, policy):
    payload, item = record["payload"], record["payload"]["item"]
    command = item.get("command")
    if not (isinstance(command, list) and len(command) == 3 and command[:2] == ["/bin/zsh", "-lc"]):
        return
    expected = [policy.get("launcher"), "desktop", "prepare-ticket-mr-recovery", policy["incident"]["request_key"],
                "--source-thread-id", policy["broker_thread_id"], "--workflow", policy.get("workflow")]
    try:
        argv = shlex.split(command[2])
    except ValueError:
        raise Refusal("mr_presend_prepare_command_unproven")
    if argv != expected:
        return
    started, completed = nested_times(payload, loader, offset)
    require(item.get("status") == "completed" and type(item.get("exit_code")) is int and item["exit_code"] == 0
            and item.get("source") == "unified_exec_startup"
            and item.get("cwd") == "file://" + str(Path(policy["launcher"]).parent.parent),
            "mr_presend_prepare_result_unproven")
    output = item.get("aggregated_output")
    require(isinstance(output, str) and len(output) <= 8192, "mr_presend_prepare_result_unproven")
    response = decode(output)
    require(isinstance(response, dict) and response.get("status") == "MR_OWNER_ADMISSION_PREPARED"
            and response.get("request_key") == policy["incident"]["request_key"] and response.get("action") == "recover"
            and isinstance(response.get("handle"), str) and re.fullmatch("[0-9a-f]{64}", response["handle"]),
            "mr_presend_prepare_result_unproven")
    state["prepare_results"].append({"item_id": item["id"], "exec_call_id": call, "offset": offset,
        "started_at_ms": started, "completed_at_ms": completed, "response": response, "event_sha256": json_digest(record)})


def running_cell(output):
    if isinstance(output, list):
        require(len(output) == 1 and isinstance(output[0], dict)
                and set(output[0]) == {"type", "text"} and output[0]["type"] == "input_text",
                "mr_presend_recovery_already_returned")
        output = output[0]["text"]
    require(isinstance(output, str) and len(output) <= 4096, "mr_presend_recovery_already_returned")
    match = re.fullmatch(r"Script running with cell ID ([1-9][0-9]{0,19})\nWall time [0-9]+(?:\.[0-9]+)? seconds\nOutput:\n", output)
    require(match is not None, "mr_presend_recovery_already_returned")
    return match[1]


def start_wait(payload, state, policy):
    active = state["active_recovery"]
    historical = policy.get("historical_waits", {}).get(payload.get("call_id"))
    if active is None and historical is not None:
        require(payload.get("name") == "wait" and payload.get("namespace") is None
                and isinstance(payload.get("arguments"), str)
                and digest(payload["arguments"].encode()) == historical["arguments_sha256"]
                and state["turn"] == historical["turn_id"] and not state["pending"]
                and state["diagnostic_outputs"].get(historical["origin_call_id"]) == historical["origin_output_sha256"],
                "mr_presend_historical_wait_unproven")
        call = payload["call_id"]
        require(call not in state["calls"], "mr_presend_call_conflict")
        state["calls"][call] = True
        state["pending"][call] = {"classification": "HISTORICAL_DIAGNOSTIC_WAIT", "call_type": "function_call",
            "turn_id": state["turn"], "output_sha256": historical["output_sha256"]}
        return
    require(isinstance(active, dict) and active["turn_id"] == state["turn"]
            and state["turn"] not in state["completed_turns"] and not state["pending"],
            "mr_presend_wait_unproven")
    require(payload.get("name") == "wait" and payload.get("namespace") is None
            and isinstance(payload.get("arguments"), str) and len(payload["arguments"]) <= 4096,
            "mr_presend_wait_unproven")
    args = decode(payload["arguments"])
    require(isinstance(args, dict) and "cell_id" in args
            and set(args) <= {"cell_id", "yield_time_ms", "max_tokens", "terminate"}
            and args["cell_id"] == active["cell_id"]
            and ("terminate" not in args or args["terminate"] is False), "mr_presend_wait_unproven")
    for key, maximum in (("yield_time_ms", 60000), ("max_tokens", 30000)):
        require(key not in args or type(args[key]) is int and 1 <= args[key] <= maximum,
                "mr_presend_wait_unproven")
    call = payload.get("call_id")
    require(isinstance(call, str) and call not in state["calls"], "mr_presend_call_conflict")
    require(len(state["calls"]) < MAX_CALLS, "mr_presend_call_limit")
    state["calls"][call] = True
    state["pending"][call] = {"classification": "CURRENT_RECOVERY_WAIT", "call_type": "function_call",
                              "turn_id": state["turn"], "exec_call_id": active["exec_call_id"],
                              "cell_id": active["cell_id"]}


def finish_call(record, state, policy, call_type):
    payload = record["payload"]
    call = payload.get("call_id")
    require(call in state["pending"], "mr_presend_output_unpaired")
    entry = state["pending"].pop(call)
    require(entry["call_type"] == call_type, "mr_presend_output_type_mismatch")
    require(entry["turn_id"] == state["turn"], "mr_presend_output_turn_mismatch")
    if entry["classification"] == "INCIDENT":
        expected = policy["incident"]
        require(not state["incident_output"] and state["turn"] == expected["turn_id"]
                and record.get("timestamp") == expected["output_at"]
                and json_digest(payload.get("output")) == expected["output_sha256"],
                "mr_presend_rejection_unproven")
        state["incident_output"] = True
    elif entry.get("bootstrap") is not None:
        bootstrap_output(payload.get("output"), entry["bootstrap"], policy)
        state["bootstrap"].append(entry["bootstrap"])
    elif entry["classification"] == "CURRENT_RECOVERY":
        require(state["active_recovery"] is None, "mr_presend_recovery_conflict")
        cell = running_cell(payload.get("output"))
        state["active_recovery"] = {**entry, "exec_call_id": call, "cell_id": cell}
    elif entry["classification"] == "CURRENT_RECOVERY_WAIT":
        active = state["active_recovery"]
        require(isinstance(active, dict) and entry["exec_call_id"] == active["exec_call_id"]
                and entry["cell_id"] == active["cell_id"], "mr_presend_wait_unproven")
        require(running_cell(payload.get("output")) == active["cell_id"], "mr_presend_cell_mismatch")
    elif entry["classification"] == "AUTHORIZED_DIAGNOSTIC":
        state["diagnostic_outputs"][call] = json_digest(payload.get("output"))
    elif entry["classification"] == "HISTORICAL_DIAGNOSTIC_WAIT":
        require(json_digest(payload.get("output")) == entry["output_sha256"], "mr_presend_historical_wait_unproven")


def apply_record(record, raw, offset, state, policy):
    kind, payload = record.get("type"), record.get("payload")
    require(isinstance(payload, dict), "mr_presend_record_invalid")
    if kind == "event_msg":
        event = payload.get("type")
        require(event in {"task_started", "task_complete", "item_completed", "token_count", "thread_settings_applied"},
                "mr_presend_event_unknown")
        if event == "item_completed":
            nested_event(record, offset, state, policy)
        if event == "task_started":
            turn = payload.get("turn_id")
            require(isinstance(turn, str) and turn not in state["turns"], "mr_presend_turn_conflict")
            require(state["turn"] is None or state["turn"] in state["completed_turns"], "mr_presend_turn_incomplete")
            require(state["active_recovery"] is None, "mr_presend_recovery_conflict")
            state["turn"] = turn
            state["bootstrap"] = []
            state["incoming_seen"] = False
            state["turn_executed"] = False
            state["turns"].append(turn)
            require(len(state["turns"]) <= MAX_TURNS, "mr_presend_turn_limit")
        if event == "task_complete":
            require(payload.get("turn_id") == state["turn"], "mr_presend_turn_conflict")
            require(not state["pending"], "mr_presend_unfinished_call")
            require(state["active_recovery"] is None, "mr_presend_unfinished_call")
            require(state["turn"] not in state["completed_turns"], "mr_presend_turn_conflict")
            state["completed_turns"].append(state["turn"])
    elif kind == "response_item":
        action = payload.get("type")
        if action == "custom_tool_call":
            state["turn_executed"] = True
            require(state["active_recovery"] is None
                    and not any(entry["classification"] == "CURRENT_RECOVERY" for entry in state["pending"].values()),
                    "mr_presend_recovery_conflict")
            require(state["turn"] is not None and state["turn"] not in state["completed_turns"],
                    "mr_presend_call_outside_active_turn")
            call = payload.get("call_id")
            require(isinstance(call, str) and call not in state["calls"], "mr_presend_call_conflict")
            require(payload.get("name") == "exec" and isinstance(payload.get("input"), str),
                    "mr_presend_executable_unknown")
            raw_input = payload["input"].encode()
            code = digest(raw_input)
            if call == policy["incident"]["call_id"]:
                expected = policy["incident"]
                require(not state["incident_seen"] and state["turn"] == expected["turn_id"]
                        and code == expected["input_sha256"] and len(raw_input) == expected["input_bytes"]
                        and record.get("timestamp") == expected["input_at"], "mr_presend_incident_unproven")
                state["incident_seen"] = True
                state["incident_call_id"] = call
                state["incident_offset"] = offset
                classification = "INCIDENT"
            else:
                classification = policy["approved_inputs"].get(code, {}).get("classification")
                if matches_loader(code, len(raw_input), policy):
                    classification = "CURRENT_RECOVERY"
                    if policy.get("required_bootstrap"):
                        require(state["incoming_seen"] and state["bootstrap"] == policy["required_bootstrap"],
                                "mr_presend_bootstrap_unproven")
                elif classification is not None:
                    require(len(raw_input) == policy["approved_inputs"][code]["bytes"], "mr_presend_input_unreviewed")
                require(classification in {"READ_ONLY", "LOCAL_COMPLETION", "CURRENT_RECOVERY", "AUTHORIZED_DIAGNOSTIC"},
                        "mr_presend_input_unreviewed:" + code)
            require(len(state["calls"]) < MAX_CALLS, "mr_presend_call_limit")
            entry = {"sha256": code, "classification": classification, "turn_id": state["turn"],
                     "call_type": "custom_tool_call", "input_at": record.get("timestamp"), "offset": offset}
            if classification == "CURRENT_RECOVERY":
                entry["exec_call_id"] = call
            bootstrap = policy["approved_inputs"].get(code, {}).get("bootstrap")
            if bootstrap is not None:
                entry["bootstrap"] = bootstrap
            state["calls"][call] = True
            state["pending"][call] = entry
        elif action == "custom_tool_call_output":
            finish_call(record, state, policy, "custom_tool_call")
        elif action == "function_call":
            start_wait(payload, state, policy)
        elif action == "function_call_output":
            if "call_id" not in payload:
                incoming_delegation(record, raw, offset, state, policy)
            else:
                finish_call(record, state, policy, "function_call")
        else:
            require(action in {"message", "reasoning"}, "mr_presend_executable_unknown")
    else:
        require(kind in {"turn_context", "token_usage_record", "compacted", "world_state"},
                "mr_presend_record_unknown")
    if state["incident_seen"]:
        state["suffix_bytes"] += len(raw)
        require(state["suffix_bytes"] <= MAX_SUFFIX, "mr_presend_suffix_limit")


def read_session(policy, expected, previous=None):
    require(expected["request_key"] == policy["incident"]["request_key"]
            and expected["broker_thread_id"] == policy["broker_thread_id"]
            and expected["claimed_at"] == policy["incident"]["claimed_at"], "mr_presend_request_unproven")
    require(expected["latest_turn_status"] in {"completed", "inProgress", "interrupted"}, "mr_presend_latest_turn_mismatch")
    descriptor, before = open_regular(policy["session_path"], MAX_FILE)
    require(previous is None or all(identity(before)[key] == previous["identity"][key]
                                  for key in ["device", "inode"]), "mr_presend_session_replaced")
    state = state_initial() if previous is None else previous["state"]
    hasher = hashlib.sha256()
    historical_hasher = hashlib.sha256()
    historical_records = []
    windows = rejected_windows(policy)
    offset = 0
    with os.fdopen(descriptor, "rb") as stream:
        if previous is not None:
            remaining = previous["identity"]["size"]
            while remaining:
                chunk = stream.read(min(1048576, remaining))
                require(chunk, "mr_presend_prefix_changed")
                hasher.update(chunk)
                remaining -= len(chunk)
            require(hasher.hexdigest() == previous["sha256"], "mr_presend_prefix_changed")
            offset = previous["identity"]["size"]
        while True:
            raw = stream.readline(MAX_LINE + 1)
            if not raw:
                break
            require(len(raw) <= MAX_LINE and raw.endswith(b"\n"), "mr_presend_line_incomplete")
            hasher.update(raw)
            historical = next((window for window in windows
                               if window["offset"] <= offset < window["offset"] + window["bytes"]), None)
            if historical:
                require(historical_records or offset == historical["offset"], "mr_presend_rejected_boundary_unproven")
                require(offset + len(raw) <= historical["offset"] + historical["bytes"], "mr_presend_rejected_boundary_unproven")
                historical_records.append((offset, decode(raw), digest(raw)))
                historical_hasher.update(raw)
                if offset + len(raw) == historical["offset"] + historical["bytes"]:
                    rejected_window(historical_records, historical_hasher.hexdigest(), state, policy, historical)
                    historical_records = []
                    historical_hasher = hashlib.sha256()
            elif offset == 0:
                record = decode(raw)
                header = record.get("payload", {})
                require(record.get("type") == "session_meta" and header.get("id") == policy["broker_thread_id"]
                        and header.get("cwd") == policy["broker_cwd"] and header.get("originator") == "Codex Desktop"
                        and header.get("source") == "vscode" and header.get("thread_source") == "agent_created_thread",
                        "mr_presend_session_identity_unproven")
            elif state["incident_seen"] or policy["incident"]["turn_id"].encode() in raw or state["turn"] == policy["incident"]["turn_id"]:
                record = decode(raw)
                if not state["incident_seen"]:
                    payload = record.get("payload", {})
                    if record.get("type") == "event_msg" and payload.get("type") == "task_started" and payload.get("turn_id") == policy["incident"]["turn_id"]:
                        require(state["turn"] is None, "mr_presend_incident_ambiguous")
                        state["turn"] = payload["turn_id"]
                        state["turns"].append(payload["turn_id"])
                    elif record.get("type") == "response_item" and payload.get("type") == "custom_tool_call" and payload.get("call_id") == policy["incident"]["call_id"]:
                        apply_record(record, raw, offset, state, policy)
                else:
                    apply_record(record, raw, offset, state, policy)
            offset += len(raw)
        after = os.fstat(stream.fileno())
        require(identity(after) == identity(before) and identity(os.stat(policy["session_path"], follow_symlinks=False)) == identity(before),
                "mr_presend_session_changed")
    require(state["incident_seen"] and state["incident_output"], "mr_presend_incident_incomplete")
    require(all(str(window["offset"]) in state["historical_rejections"] for window in windows),
            "mr_presend_rejected_window_incomplete")
    require(state["turn"] == expected["latest_turn_id"], "mr_presend_latest_turn_mismatch")
    require((state["turn"] in state["completed_turns"]) == (expected["latest_turn_status"] == "completed"),
            "mr_presend_latest_turn_mismatch")
    active = state["active_recovery"]
    require(active is None or active["turn_id"] == state["turn"]
            and active["classification"] == "CURRENT_RECOVERY" and active["exec_call_id"] in state["calls"]
            and active["sha256"] in {entry["input_sha256"] for entry in loader_variants(policy)}, "mr_presend_recovery_conflict")
    require(all(entry["turn_id"] == state["turn"] and
                (active is None and entry["classification"] == "CURRENT_RECOVERY"
                 or active is not None and entry["classification"] == "CURRENT_RECOVERY_WAIT"
                 and entry["exec_call_id"] == active["exec_call_id"] and entry["cell_id"] == active["cell_id"])
                for entry in state["pending"].values()) and len(state["pending"]) <= 1,
            "mr_presend_unfinished_call")
    require(not (state["pending"] or active is not None) or expected["latest_turn_status"] in {"inProgress", "interrupted"},
            "mr_presend_unfinished_call")
    observation = None
    if expected.get("require_source") is True or expected["latest_turn_status"] == "interrupted":
        call, _ = loader_entry(state)
        candidates = [entry for entry in state["source_observations"] if entry["exec_call_id"] == call]
        require(candidates, "mr_presend_source_observation_missing")
        observation = candidates[-1]
        now = expected.get("now_ms")
        require(type(now) is int and 0 <= now - observation["completed_at_ms"] <= 10000,
                "mr_presend_source_observation_expired")
        if expected.get("prepare_handle") is not None:
            prepared = [entry for entry in state["prepare_results"] if entry["exec_call_id"] == call
                        and entry["response"]["handle"] == expected["prepare_handle"]]
            require(len(prepared) == 1 and observation["offset"] > prepared[0]["offset"]
                    and observation["started_at_ms"] >= prepared[0]["completed_at_ms"],
                    "mr_presend_prepare_causality_unproven")
            for field in ("payload_sha256", "expires_at"):
                if expected.get("prepare_" + field) is not None:
                    require(prepared[0]["response"].get(field) == expected["prepare_" + field],
                            "mr_presend_prepare_binding_changed")
            require(observation["item_id"] != expected.get("prepare_source_item_id"),
                    "mr_presend_source_observation_replayed")
    return {"version": 2, "identity": identity(before), "sha256": hasher.hexdigest(), "state": state,
            "source_observation": observation, "registry_sha256": REGISTRY_SHA256}


def main():
    require(len(sys.argv) == 2, "mr_presend_input_invalid")
    raw = base64.b64decode(sys.argv[1], validate=True)
    require(len(raw) <= 262144, "mr_presend_input_limit")
    value = decode(raw)
    policy = registry()
    result = read_session(policy, value["expected"], value.get("previous"))
    print(json.dumps({"ok": result}, ensure_ascii=True, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Refusal as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
    except Exception:
        print(json.dumps({"error": "mr_presend_evidence_unproven"}))
        sys.exit(1)
