"""Read-only, exact-runtime verification of one guarded input-fence receipt."""
import ast
import datetime
import hashlib
import json
import os
import re
import select
import stat
import struct
import subprocess
import sys

LIMIT = 16 * 1024 * 1024
CONFIG = {"MODE", "PINS", "REVIEWED_SCOPES"}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


class Reader:
    def __init__(self):
        self.files = []

    def read(self, path, expected=None, private=False):
        require(isinstance(path, str) and os.path.isabs(path) and os.path.realpath(path) == path, "canonical_file_required")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        self.files.append((fd, path, os.fstat(fd)))
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid in (0, os.getuid()) and info.st_size <= LIMIT, "owned_bounded_regular_file_required")
        require(not info.st_mode & 0o022, "mutable_file_rejected")
        if private:
            parent = os.stat(os.path.dirname(path), follow_symlinks=False)
            require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid() and stat.S_IMODE(parent.st_mode) == 0o700 and stat.S_IMODE(info.st_mode) == 0o600, "private_receipt_required")
        raw = bytearray()
        while len(raw) <= LIMIT:
            chunk = os.read(fd, min(65536, LIMIT + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        require(len(raw) <= LIMIT and len(raw) == info.st_size, "bounded_unchanged_file_required")
        raw = bytes(raw)
        require(expected is None or digest(raw) == expected, "pinned_file_changed")
        return raw

    def check(self):
        for fd, path, before in self.files:
            after = os.fstat(fd)
            named = os.stat(path, follow_symlinks=False)
            fields = lambda item: (item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_size, item.st_mtime_ns, item.st_ctime_ns)
            require(fields(before) == fields(after) == fields(named), "file_identity_changed")

    def close(self):
        for fd, _, _ in self.files:
            os.close(fd)


def guard_config(raw):
    tree = ast.parse(raw.decode("utf-8"))
    values, body = {}, []
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and node.targets[0].id in CONFIG:
            name = node.targets[0].id
            require(name not in values, "duplicate_config")
            values[name] = ast.literal_eval(node.value)
        else:
            body.append(node)
    require(set(values) == CONFIG, "exact_literal_config_required")
    tree.body = body
    for node in ast.walk(tree):
        bound = None
        if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            bound = node.id
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.ExceptHandler)):
            bound = node.name
        elif isinstance(node, ast.arg):
            bound = node.arg
        elif isinstance(node, ast.alias):
            bound = node.asname or node.name.split(".")[0]
        require(bound not in CONFIG, "config_rebinding_rejected")
    return values, digest(ast.dump(tree, annotate_fields=True, include_attributes=False).encode())


def verify(packet):
    reader = Reader()
    try:
        require(set(packet) == {"resource_path", "resource_sha256", "receipt_path", "receipt_sha256", "guard_path", "current_build_path", "current_io_sha256"}, "exact_packet_required")
        audit = json.loads(reader.read(packet["resource_path"], packet["resource_sha256"]))
        require(set(audit) == {"original_runtime", "operation", "guard", "original_snapshot"}, "exact_resource_required")
        runtime, operation, guard = audit["original_runtime"], audit["operation"], audit["guard"]
        interpreter = guard["interpreter"]
        require(sys.executable == interpreter["executable_path"] and os.path.realpath(sys.executable) == interpreter["binary_path"], "interpreter_identity_changed")
        require(".".join(map(str, sys.version_info[:3])) == interpreter["version"], "interpreter_version_changed")
        reader.read(interpreter["path"], interpreter["sha256"])
        reader.read(interpreter["binary_path"], interpreter["executable_sha256"])
        receipt = json.loads(reader.read(packet["receipt_path"], packet["receipt_sha256"], True))
        required = {"version", "kind", "run_id", "owner_nonce", "original_envelope_sha256", "reservation_key", "reservation_generation", "issuer", "operation", "guard_sha256", "guard_core_sha256", "protected_before_sha256", "protected_after_sha256", "protected_before_path", "protected_after_path", "original_pinned_protected_path", "original_pinned_protected_sha256", "old_schema_path", "old_schema_file_sha256", "protected_row_counts", "repair_row_counts", "old_schema_sha256", "new_schema_sha256", "new_schema_path", "schema_delta_sha256", "shutdown_observation", "migration_window"}
        require(set(receipt) == required and receipt["version"] == 1 and receipt["kind"] == "OWNED_ISSUER_SHUTDOWN", "exact_shutdown_receipt_required")
        require(receipt["issuer"] == runtime and receipt["operation"] == operation, "original_identity_changed")
        for field, key in (("run_id", "run_id"), ("owner_nonce", "nonce"), ("original_envelope_sha256", "envelope_sha256"), ("reservation_key", "reservation_key"), ("reservation_generation", "reservation_generation")):
            require(receipt[field] == operation[key], "operation_changed")
        raw_guard = reader.read(packet["guard_path"], receipt["guard_sha256"])
        config, core = guard_config(raw_guard)
        require(core == guard["core_sha256"] == receipt["guard_core_sha256"], "guard_core_changed")
        require(config["MODE"] == "ROLLOUT_EXACT_HELD_PUSH_INPUT_FENCE", "guard_mode_changed")
        scopes = {key: sorted(value) for key, value in config["REVIEWED_SCOPES"].items()}
        require(scopes == guard["reviewed_scopes"], "guard_scopes_changed")
        pins = config["PINS"]
        pin_keys = {"old_manifest_path", "old_manifest_sha256", "new_manifest_path", "new_manifest_sha256", "artifact_proof_path", "artifact_proof_sha256", "source_proof_path", "source_proof_sha256", "priv_proof_path", "priv_proof_sha256", "protected_path", "protected_sha256", "schema_path", "schema_sha256", "schema_delta_path", "schema_delta_sha256", "old_plist_path", "old_plist_sha256", "new_plist_sha256", "old_build_path", "new_build_path", "old_pid", "old_start", "uid", "source_pins", "beam_pins", "test_pins", "file_pins", "workflow_sha256", "audit_resource_path", "audit_resource_sha256"}
        require(set(pins) == pin_keys and all(value is not None for value in pins.values()), "unarmed_or_extended_guard_rejected")
        require(pins["new_build_path"] == packet["current_build_path"] and pins["beam_pins"].get("lib/symphony_elixir/ebin/Elixir.SymphonyElixir.Factory.TicketPushIO.beam") == packet["current_io_sha256"], "current_artifact_changed")
        reader.read(os.path.join(packet["current_build_path"], "lib/symphony_elixir/ebin/Elixir.SymphonyElixir.Factory.TicketPushIO.beam"), packet["current_io_sha256"])
        for key in ("source_pins", "beam_pins", "test_pins", "file_pins"):
            require(set(pins[key]) == set(scopes[key]), "guard_pin_scope_changed")
        for key, value in (("old_pid", runtime["pid"]), ("uid", runtime["uid"]), ("old_start", runtime["os_start"]), ("old_build_path", runtime["artifact_path"]), ("old_manifest_path", runtime["manifest_path"]), ("old_manifest_sha256", runtime["manifest_sha256"]), ("audit_resource_path", packet["resource_path"]), ("audit_resource_sha256", packet["resource_sha256"])):
            require(pins[key] == value, "guard_original_pin_changed")
        old_manifest = json.loads(reader.read(runtime["manifest_path"], runtime["manifest_sha256"]))
        manifest_files = {item["path"]: item["sha256"] for item in old_manifest["files"]}
        source_root = "/Users/cgable/Repos/symphony-ticket-chat-implementation/elixir/lib/"
        for path, sha in runtime["source_pins"].items():
            prefix, marker, relative = path.rpartition("/lib/")
            require(prefix and marker and manifest_files.get(source_root + relative) == sha, "original_source_manifest_changed")
            reader.read(path, sha)
        for path, sha in runtime["beam_pins"].items():
            require(os.path.commonpath([path, runtime["artifact_path"]]) == runtime["artifact_path"], "original_beam_path_changed")
            reader.read(path, sha)
        reader.read(os.path.realpath(os.path.join(runtime["artifact_path"], "lib/symphony_elixir/priv/ticket_push_executor_v3.py")), runtime["v3_sha256"])
        original = audit["original_snapshot"]
        require(receipt["original_pinned_protected_path"] == original["path"] == pins["protected_path"] and receipt["original_pinned_protected_sha256"] == original["sha256"] == pins["protected_sha256"], "original_snapshot_changed")
        snapshot = json.loads(reader.read(original["path"], original["sha256"], True))
        before = json.loads(reader.read(receipt["protected_before_path"], private=True))
        after = json.loads(reader.read(receipt["protected_after_path"], private=True))
        require(snapshot == before == after and digest(canonical(before)) == receipt["protected_before_sha256"] == receipt["protected_after_sha256"], "protected_rows_changed")
        require({key: len(value) for key, value in snapshot.items() if isinstance(value, list)} == receipt["protected_row_counts"] and {key: len(value) for key, value in snapshot["repair"].items()} == receipt["repair_row_counts"], "protected_counts_changed")
        schema = reader.read(receipt["old_schema_path"], receipt["old_schema_file_sha256"])
        require(receipt["old_schema_path"] == pins["schema_path"] and digest(schema) == pins["schema_sha256"] and digest(canonical(json.loads(schema))) == receipt["old_schema_sha256"], "original_schema_changed")
        require(receipt["schema_delta_sha256"] == pins["schema_delta_sha256"], "schema_delta_changed")
        window = receipt["migration_window"]
        require(isinstance(window, dict) and set(window) == {"startup_started_at", "schema_observed_at", "migration_applied_at"}, "migration_window_required")
        times = {}
        for key, value in window.items():
            require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z", value), "canonical_migration_UTC_required")
            times[key] = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
        require(times["startup_started_at"] <= times["migration_applied_at"] <= times["schema_observed_at"], "migration_outside_owned_startup")
        require((times["schema_observed_at"] - times["startup_started_at"]).total_seconds() <= 90, "migration_window_too_large")
        old_schema = json.loads(schema)
        new_schema = json.loads(reader.read(receipt["new_schema_path"], private=True))
        require(digest(canonical(new_schema)) == receipt["new_schema_sha256"], "new_schema_changed")
        require(set(old_schema) == set(new_schema) == {"objects", "migrations"}, "schema_shape_changed")
        old_rows = old_schema["migrations"]
        new_rows = new_schema["migrations"]
        require([row["version"] for row in old_rows] == list(range(1, 42)), "original_schema_history_changed")
        require(new_rows[:-1] == old_rows and len(new_rows) == 42, "original_migration_rows_changed")
        require(new_rows[-1] == {"version": 42, "applied_at": window["migration_applied_at"]}, "observed_migration_timestamp_changed")
        delta = json.loads(reader.read(pins["schema_delta_path"], pins["schema_delta_sha256"]))
        require(set(delta) == {"added_objects", "added_migrations", "empty_tables"} and delta["added_migrations"] == [{"version": 42}] and delta["empty_tables"] == ["ticket_push_input_retirements"], "exact_schema_delta_required")
        objects = lambda values: {canonical(row) for row in values}
        before_objects, after_objects, added_objects = objects(old_schema["objects"]), objects(new_schema["objects"]), objects(delta["added_objects"])
        require(added_objects and len(before_objects) == len(old_schema["objects"]) and len(after_objects) == len(new_schema["objects"]) and len(added_objects) == len(delta["added_objects"]), "duplicate_or_missing_schema_objects")
        require(not before_objects & added_objects and after_objects == before_objects | added_objects, "unreviewed_schema_object_change")
        probe = subprocess.run(["/bin/ps", "-p", str(runtime["pid"]), "-o", "pid="], capture_output=True, timeout=2)
        require(probe.returncode == 1 and probe.stdout == b"" and probe.stderr == b"", "original_issuer_present_or_unproven")
        require(receipt["shutdown_observation"] == {"argv": probe.args, "returncode": 1, "stdout": "", "stderr": ""}, "shutdown_observation_changed")
        run = snapshot["run"]
        intent = json.loads(run["candidate_handoff"])
        require(run["run_id"] == operation["run_id"] and run["candidate_sha"] == operation["candidate_sha"] and digest(run["candidate_handoff"].encode()) == operation["envelope_sha256"], "original_run_changed")
        require(intent["phase"] == "PUSH_UNCERTAIN" and intent["kind"] == "TICKET_PUSH" and all(intent[key] is None for key in ("helper_pid", "execution_json", "receipt_json", "receipt_sha256", "remote_sha")), "input_fence_not_null")
        reader.check()
        return {"kind": "INPUT_NOT_ISSUED", "version": 1, "operation": operation, "receipt_sha256": packet["receipt_sha256"], "resource_sha256": packet["resource_sha256"], "snapshot": snapshot, "schema": new_schema}
    finally:
        reader.close()


def main():
    def read_exact(length):
        raw = bytearray()
        while len(raw) < length:
            part = os.read(0, length - len(raw))
            if not part:
                break
            raw.extend(part)
        return bytes(raw)
    size = read_exact(4)
    require(len(size) == 4, "frame_required")
    length = struct.unpack(">I", size)[0]
    require(length <= 65536, "packet_too_large")
    raw = read_exact(length)
    require(len(raw) == length, "exact_frame_required")
    if select.select([0], [], [], 0)[0]:
        require(os.read(0, 1) == b"", "trailing_frame_rejected")
    result = canonical(verify(json.loads(raw)))
    require(len(result) <= LIMIT, "result_too_large")
    sys.stdout.buffer.write(struct.pack(">I", len(result)) + result)


if __name__ == "__main__":
    main()
