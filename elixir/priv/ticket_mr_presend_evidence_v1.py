"""Read-only, incident-bound evidence; never executes historical source or grants a send."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

MAX_FILE = 2 * 1024 * 1024 * 1024
MAX_LINE = 4 * 1024 * 1024
MAX_SUFFIX = 128 * 1024 * 1024
MAX_TURNS = 1024
MAX_CALLS = 4096
REGISTRY_SHA256 = "530577c49c021d5298f8978c785bd0961281a3008e80b2b8719c748846fc7787"


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
    path = str(Path(__file__).resolve().parent / "ticket_mr_presend_registry_v1.json")
    descriptor, before = open_regular(path, 262144)
    with os.fdopen(descriptor, "rb") as stream:
        raw = stream.read(262145)
        require(identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_registry_changed")
    require(digest(raw) == REGISTRY_SHA256, "mr_presend_registry_changed")
    result = decode(raw)
    require(result["version"] == 1, "mr_presend_registry_invalid")
    historical = result["historical_runtime"]
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
    for path, expected in result["external_readers"].items():
        descriptor, before = open_regular(path, 1048576)
        with os.fdopen(descriptor, "rb") as stream:
            require(digest(stream.read(1048577)) == expected
                    and identity(os.fstat(stream.fileno())) == identity(before), "mr_presend_runtime_unproven")
    return result


def state_initial():
    return {"turn": None, "turns": [], "completed_turns": [], "calls": {}, "pending": {},
            "incident_seen": False, "incident_output": False, "suffix_bytes": 0,
            "incident_offset": None, "active_recovery": None}


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


def start_wait(payload, state):
    active = state["active_recovery"]
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
    elif entry["classification"] == "CURRENT_RECOVERY":
        require(state["active_recovery"] is None, "mr_presend_recovery_conflict")
        cell = running_cell(payload.get("output"))
        state["active_recovery"] = {**entry, "exec_call_id": call, "cell_id": cell}
    elif entry["classification"] == "CURRENT_RECOVERY_WAIT":
        active = state["active_recovery"]
        require(isinstance(active, dict) and entry["exec_call_id"] == active["exec_call_id"]
                and entry["cell_id"] == active["cell_id"], "mr_presend_wait_unproven")
        require(running_cell(payload.get("output")) == active["cell_id"], "mr_presend_cell_mismatch")


def apply_record(record, raw, offset, state, policy):
    kind, payload = record.get("type"), record.get("payload")
    require(isinstance(payload, dict), "mr_presend_record_invalid")
    if kind == "event_msg":
        event = payload.get("type")
        require(event in {"task_started", "task_complete", "item_completed", "token_count", "thread_settings_applied"},
                "mr_presend_event_unknown")
        if event == "task_started":
            turn = payload.get("turn_id")
            require(isinstance(turn, str) and turn not in state["turns"], "mr_presend_turn_conflict")
            require(state["turn"] is None or state["turn"] in state["completed_turns"], "mr_presend_turn_incomplete")
            require(state["active_recovery"] is None, "mr_presend_recovery_conflict")
            state["turn"] = turn
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
                if code == policy["recovery_loader"]["input_sha256"]:
                    classification = "CURRENT_RECOVERY"
                    require(len(raw_input) == policy["recovery_loader"]["input_bytes"], "mr_presend_loader_unproven")
                elif classification is not None:
                    require(len(raw_input) == policy["approved_inputs"][code]["bytes"], "mr_presend_input_unreviewed")
                require(classification in {"READ_ONLY", "LOCAL_COMPLETION", "CURRENT_RECOVERY"},
                        "mr_presend_input_unreviewed:" + code)
            require(len(state["calls"]) < MAX_CALLS, "mr_presend_call_limit")
            entry = {"sha256": code, "classification": classification, "turn_id": state["turn"],
                     "call_type": "custom_tool_call"}
            state["calls"][call] = True
            state["pending"][call] = entry
        elif action == "custom_tool_call_output":
            finish_call(record, state, policy, "custom_tool_call")
        elif action == "function_call":
            start_wait(payload, state)
        elif action == "function_call_output":
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
    require(expected["latest_turn_status"] in {"completed", "inProgress"}, "mr_presend_latest_turn_mismatch")
    descriptor, before = open_regular(policy["session_path"], MAX_FILE)
    require(previous is None or all(identity(before)[key] == previous["identity"][key]
                                  for key in ["device", "inode"]), "mr_presend_session_replaced")
    state = state_initial() if previous is None else previous["state"]
    hasher = hashlib.sha256()
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
            if offset == 0:
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
    require(state["turn"] == expected["latest_turn_id"], "mr_presend_latest_turn_mismatch")
    require((state["turn"] in state["completed_turns"]) == (expected["latest_turn_status"] == "completed"),
            "mr_presend_latest_turn_mismatch")
    active = state["active_recovery"]
    require(active is None or active["turn_id"] == state["turn"]
            and active["classification"] == "CURRENT_RECOVERY" and active["exec_call_id"] in state["calls"]
            and active["sha256"] == policy["recovery_loader"]["input_sha256"], "mr_presend_recovery_conflict")
    require(all(entry["turn_id"] == state["turn"] and
                (active is None and entry["classification"] == "CURRENT_RECOVERY"
                 or active is not None and entry["classification"] == "CURRENT_RECOVERY_WAIT"
                 and entry["exec_call_id"] == active["exec_call_id"] and entry["cell_id"] == active["cell_id"])
                for entry in state["pending"].values()) and len(state["pending"]) <= 1,
            "mr_presend_unfinished_call")
    require(not (state["pending"] or active is not None) or expected["latest_turn_status"] == "inProgress", "mr_presend_unfinished_call")
    return {"version": 1, "identity": identity(before), "sha256": hasher.hexdigest(), "state": state,
            "registry_sha256": REGISTRY_SHA256}


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
