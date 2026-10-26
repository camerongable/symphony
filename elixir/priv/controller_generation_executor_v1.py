"""Controller-only text effects; tool execution and worker authority are separate."""

import contextlib
import base64
import datetime
import hashlib
import json
import os
import pathlib
import sqlite3
import stat
import re
import select
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
import types
import urllib.parse

FILE_PROGRAM_SHA = "fb7a123f7415c0ded2c0ca8a18a4cae34fc88c3f0b50f60c5eec384ae4e965a4"
MAX_FILE = 262_144
MAX_EFFECT_SECONDS = 4
MAX_FRAME = 2_097_152
MAX_OUTPUT = 32_768
MAX_RUN_SECONDS = 110
QUERIES = {
    "run": ("SELECT * FROM runs WHERE run_id=?", "run_id"),
    "tasks": ("SELECT * FROM factory_tasks WHERE run_id=? ORDER BY task_key", "run_id"),
    "evidence": ("SELECT * FROM worker_evidence WHERE run_id=? ORDER BY request_key", "run_id"),
    "access": ("SELECT * FROM workspace_access WHERE run_id=? ORDER BY reservation_key", "run_id"),
    "source": ("SELECT * FROM native_source_bindings WHERE run_id=?", "run_id"),
    "base": ("SELECT * FROM ticket_review_bases WHERE run_id=?", "run_id"),
    "claims": ("SELECT * FROM ticket_ci_repair_claims WHERE run_id=? ORDER BY round", "run_id"),
    "control": ("SELECT * FROM control WHERE scope=?", "scope"),
    "commands": ("SELECT * FROM ticket_chat_commands WHERE run_id=? ORDER BY command_key", "run_id"),
    "questions": ("SELECT * FROM ticket_chat_questions WHERE run_id=? ORDER BY question_key", "run_id"),
    "amendments": ("SELECT * FROM ticket_contract_amendments WHERE run_id=? ORDER BY command_key", "run_id"),
    "parent": ("SELECT chat.* FROM ticket_chats chat JOIN ticket_chat_runs r ON r.chat_key=chat.chat_key WHERE r.run_id=?", "run_id"),
    "bootstrap": ("SELECT request.* FROM desktop_requests request JOIN ticket_chats chat ON chat.create_request_key=request.request_key JOIN ticket_chat_runs r ON r.chat_key=chat.chat_key WHERE r.run_id=?", "run_id"),
    "inputs": ("SELECT input.* FROM ticket_chat_inputs input JOIN ticket_chat_runs r ON r.chat_key=input.chat_key WHERE r.run_id=? ORDER BY input.input_key", "run_id"),
    "file_operations": ("SELECT op.* FROM worker_file_operations op JOIN worker_evidence e ON e.request_key=op.request_key WHERE e.run_id=? ORDER BY op.call_id", "run_id")
}
READ_TABLES = frozenset("""
runs factory_tasks worker_evidence workspace_access native_source_bindings ticket_review_bases
ticket_ci_repair_claims ticket_ci_repair_diagnoses control ticket_chat_commands ticket_chat_questions
ticket_contract_amendments ticket_chats ticket_chat_runs desktop_requests ticket_chat_inputs
worker_file_operations ticket_ci_generation_intents ticket_ci_generation_events
""".split())
READ_TABLES = READ_TABLES | {"ticket_chat_runs"}


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def read_frame():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        raise ValueError("generation_parent_unavailable")
    size = int.from_bytes(header, "big")
    if not 0 < size <= MAX_FRAME:
        raise ValueError("generation_frame_unproven")
    raw = sys.stdin.buffer.read(size)
    if len(raw) != size:
        raise ValueError("generation_frame_unproven")
    return json.loads(raw)


def send_frame(value):
    raw = compact(value)
    if len(raw) > MAX_FRAME:
        raise ValueError("generation_frame_unproven")
    sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
    sys.stdout.buffer.flush()


def parent_observer():
    if not hasattr(select, "kqueue"):
        raise ValueError("generation_parent_observer_unavailable")
    queue = select.kqueue()
    queue.control([select.kevent(0, filter=select.KQ_FILTER_READ, flags=select.KQ_EV_ADD)], 0)

    def check():
        for event in queue.control(None, 1, 0):
            if event.flags & select.KQ_EV_EOF:
                raise ValueError("generation_parent_unavailable")

    def watch():
        while True:
            try:
                check()
            except BaseException:
                os.kill(os.getpid(), signal.SIGKILL)
            time.sleep(0.02)

    threading.Thread(target=watch, daemon=True).start()
    return check


@contextlib.contextmanager
def select_locked_role(database, columns):
    if (not isinstance(columns, dict) or not columns or not set(columns) <= READ_TABLES
            or any(not isinstance(values, (list, set, frozenset, tuple))
                   or not 1 <= len(values) <= 256
                   or any(not isinstance(value, str) or not value for value in values)
                   for values in columns.values())):
        raise ValueError("generation_read_role_unproven")
    path = pathlib.Path(database)
    if not path.is_absolute() or str(path.resolve()) != str(path):
        raise ValueError("generation_database_unproven")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    connection = None
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
            raise ValueError("generation_database_unproven")
        uri = "file:" + urllib.parse.quote(str(path), safe="/") + "?mode=rw&cache=private"
        connection = sqlite3.connect(uri, uri=True, timeout=0.25, isolation_level=None)

        def authorize(action, table, column, database_name, _trigger):
            if action == sqlite3.SQLITE_SELECT:
                return sqlite3.SQLITE_OK
            if (action == sqlite3.SQLITE_READ and database_name == "main"
                    and table in columns and column in columns[table]):
                return sqlite3.SQLITE_OK
            if (action == sqlite3.SQLITE_TRANSACTION
                    and table in ("BEGIN", "COMMIT", "ROLLBACK")):
                return sqlite3.SQLITE_OK
            return sqlite3.SQLITE_DENY

        # OPEN_READONLY does not reserve the WAL writer lock. This narrowly
        # privileged role may lock but cannot mutate even one ledger row.
        connection.set_authorizer(authorize)
        if hasattr(connection, "enable_load_extension"):
            connection.enable_load_extension(False)
        after = os.stat(path, follow_symlinks=False)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError("generation_database_changed")
        connection.execute("BEGIN IMMEDIATE")
        yield connection
    finally:
        if connection is not None:
            connection.rollback()
            connection.close()
        os.close(descriptor)


def tick_fence(connection, expected):
    if (set(expected) != {"scope", "tick_id", "dispatcher_id", "lease_expires_at"}
            or any(not isinstance(value, str) or not value for value in expected.values())):
        raise ValueError("generation_tick_unproven")
    cursor = connection.execute("SELECT * FROM control WHERE scope=?", (expected["scope"],))
    values = cursor.fetchone()
    if values is None:
        raise ValueError("generation_tick_unproven")
    current = dict(zip([item[0] for item in cursor.description], values))
    if (current["status"] != "ACTIVE" or current["tick_id"] != expected["tick_id"]
            or current["dispatcher_id"] != expected["dispatcher_id"]):
        raise ValueError("generation_tick_changed")
    deadline = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=MAX_EFFECT_SECONDS + 0.25)
    for value in (current["lease_expires_at"], expected["lease_expires_at"]):
        if not isinstance(value, str):
            raise ValueError("generation_lease_unproven")
        try:
            expiry = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            raise ValueError("generation_lease_unproven") from None
        if expiry.tzinfo is None or expiry <= deadline:
            raise ValueError("generation_lease_unproven")


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def file_program():
    path = pathlib.Path(__file__).resolve().with_name("worker_file_io.py")
    raw = path.read_bytes()
    if sha(raw) != FILE_PROGRAM_SHA:
        raise ValueError("generation_program_changed")
    module = types.ModuleType("controller_generation_file_primitives")
    module.__file__ = str(path)
    exec(compile(raw, str(path), "exec", dont_inherit=True, optimize=0), module.__dict__)
    return module


def replace_text(binding, proposal, creator_ack, effect_fence):
    if set(proposal) != {"path", "before_sha256", "after_sha256", "content"}:
        raise ValueError("generation_proposal_unproven")
    content = proposal["content"]
    if (not isinstance(content, str) or "\x00" in content
            or len(content.encode("utf-8")) > MAX_FILE
            or sha(content.encode("utf-8")) != proposal["after_sha256"]):
        raise ValueError("generation_proposal_unproven")
    nonce = binding["invocation"]
    if (not isinstance(nonce, str) or len(nonce) != 64
            or any(char not in "0123456789abcdef" for char in nonce)):
        raise ValueError("generation_invocation_unproven")
    helper = file_program()
    parts = helper.components(proposal["path"])
    if any(part.startswith("-") for part in parts):
        raise ValueError("generation_path_unproven")
    root_path = binding["root"]
    if (not isinstance(root_path, str) or not root_path.startswith("/")
            or any(part in ("", ".", "..") for part in root_path.split("/")[1:])):
        raise ValueError("generation_root_unproven")
    request = {"nonce": nonce, "root": root_path, "device": binding["root_device"],
               "inode": binding["root_inode"], "operation": "replace",
               "arguments": {"path": proposal["path"], "expected_sha256": proposal["before_sha256"],
                             "content": content}}
    with contextlib.ExitStack() as stack:
        initial = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        stack.callback(os.close, initial)
        root = stack.enter_context(helper.directory_at(initial, root_path.split("/")[1:]))
        parent = stack.enter_context(helper.directory_at(root, parts[:-1]))
        helper.root_unchanged(root, request)

        def record_creator(root_fd, parent_fd, temporary, created, actual_request):
            if actual_request is not request:
                raise ValueError("generation_creator_unproven")
            root_stat, parent_stat = os.fstat(root_fd), os.fstat(parent_fd)
            creator = {"version": 1, "kind": "CONTROLLER_GENERATION_TEMP_CREATED",
                       "pid": os.getpid(), "invocation": nonce,
                       "intent_key": binding["intent_key"], "event_key": binding["event_key"],
                       "path": proposal["path"], "temporary": temporary,
                       "root_device": root_stat.st_dev, "root_inode": root_stat.st_ino,
                       "parent_device": parent_stat.st_dev, "parent_inode": parent_stat.st_ino,
                       "device": created.st_dev, "inode": created.st_ino,
                       "before_sha256": proposal["before_sha256"], "after_sha256": proposal["after_sha256"]}
            creator_ack(json.dumps(creator, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
            # The app's durable creator ACK precedes this helper-local effect
            # fence; no controller SQL callback is made while it is held.
            stack.enter_context(effect_fence())

        helper.record_creator = record_creator
        result = helper.replace(root, parent, parts[:-1], parts[-1], request)
        return {"path": proposal["path"], "sha256": result["sha256"]}


def ledger_fence(connection, binding):
    expected = binding["ledger"]
    if set(expected) != set(QUERIES):
        raise ValueError("generation_ledger_unproven")
    for name, (sql, parameter) in QUERIES.items():
        cursor = connection.execute(sql, (binding[parameter],))
        actual_columns = [item[0] for item in cursor.description]
        wanted = expected[name]["columns"]
        if any(column not in actual_columns for column in wanted):
            raise ValueError("generation_schema_changed")
        omitted = set(actual_columns) - set(wanted)
        if omitted != (set(("generation", "tick_id", "lease_expires_at", "updated_at")) if name == "control" else set()):
            raise ValueError("generation_schema_changed")
        indexes = [actual_columns.index(column) for column in wanted]
        rows = [[row[index] for index in indexes] for row in cursor.fetchall()]
        if sha(compact([wanted, rows])) != expected[name]["sha256"]:
            raise ValueError("generation_ledger_changed")
    tick_fence(connection, binding["tick"])
    row = connection.execute("SELECT * FROM ticket_ci_generation_intents WHERE intent_key=?", (binding["intent_key"],)).fetchone()
    if row is None:
        raise ValueError("generation_intent_missing")
    columns = [item[0] for item in connection.execute("SELECT * FROM ticket_ci_generation_intents LIMIT 0").description]
    intent = dict(zip(columns, row))
    if (intent["binding_sha256"] != binding["intent_sha256"]
            or sha(intent["binding_json"].encode()) != binding["intent_sha256"]
            or intent["request_key"] != binding["request_key"]):
        raise ValueError("generation_intent_changed")
    row = connection.execute("SELECT receipt_json,receipt_sha256,event_type FROM ticket_ci_generation_events WHERE event_key=?", (binding["started_key"],)).fetchone()
    if row is None or sha(row[0].encode()) != row[1] or row[2] != binding["started_type"]:
        raise ValueError("generation_start_unproven")
    started = json.loads(row[0])
    if started["helper_pid"] != binding["helper_pid"] or started["binding_json"] != binding["sealed_json"]:
        raise ValueError("generation_producer_changed")
    pending = connection.execute("SELECT event_key FROM ticket_ci_generation_events WHERE intent_key=? AND event_type IN ('BLOCKED','UNCERTAIN') LIMIT 1", (binding["intent_key"],)).fetchone()
    if pending is not None:
        raise ValueError("generation_uncertain")


def verify_reference(ref, limit):
    if set(ref) != {"path", "sha256"}:
        raise ValueError("generation_tool_changed")
    path = pathlib.Path(ref["path"])
    if not path.is_absolute() or str(path.resolve()) != str(path):
        raise ValueError("generation_tool_changed")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= limit:
            raise ValueError("generation_tool_changed")
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            data.extend(chunk)
        after = os.stat(path, follow_symlinks=False)
        if len(data) > limit or sha(data) != ref["sha256"] or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("generation_tool_changed")
        return bytes(data)
    finally:
        os.close(descriptor)


def tool_diff(binding, path, before, bootstrap, parent_alive):
    toolset = binding["toolset"]
    operation = binding["operation"]
    kind = "gofmt" if operation == "GOFMT_DIFF" else "gazelle"
    for ref in [toolset["gate"], toolset["shim"], toolset["profile"], toolset["config"], toolset["proof"], *toolset["programs"].values()]:
        verify_reference(ref, 67_108_864)
    config = json.loads(verify_reference(toolset["config"], 262_144))
    if kind == "gofmt":
        args = ["-d"]
    else:
        packages = sorted({str(pathlib.PurePosixPath(item).parent) for item in binding["paths"]})
        if any(item != "." and (item.startswith("-") or item.startswith("/") or any(part in ("", ".", "..") or part.startswith("-") for part in item.split("/"))) for item in packages):
            raise ValueError("generation_package_unproven")
        args = config["gazelle_flags"] + packages
    reader, writer = os.pipe()
    control_reader, control_writer = os.pipe()
    child = None
    nonce = os.urandom(16).hex()
    output, errors, controls, lines = bytearray(), bytearray(), bytearray(), []
    ready = hello = closed = False
    tool_pid = exit_code = None
    selector = selectors.DefaultSelector()
    try:
        child = subprocess.Popen([toolset["gate"]["path"], toolset["shim"]["path"], toolset["programs"][kind]["path"], *args],
                                 cwd=bootstrap, env={"FACTORY_CONFIG_FD": str(reader), "FACTORY_EVENT_FD": str(control_writer)},
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 pass_fds=(reader, control_writer), close_fds=True)
        os.close(reader)
        reader = None
        os.close(control_writer)
        control_writer = None
        streams = {child.stdout.fileno(): "stdout", child.stderr.fileno(): "stderr", control_reader: "control"}
        for fd in streams:
            os.set_blocking(fd, False)
            selector.register(fd, selectors.EVENT_READ)
        deadline = time.monotonic() + 5
        while selector.get_map():
            parent_alive()
            if time.monotonic() >= deadline:
                raise ValueError("generation_tool_timeout")
            for key, _event in selector.select(0.02):
                data = os.read(key.fd, 4096)
                if not data:
                    selector.unregister(key.fd)
                    continue
                stream = streams[key.fd]
                if stream != "control":
                    # Independent pipes may become readable in either order;
                    # only bounded bytes are buffered until READY is proven.
                    if len(output) + len(errors) + len(data) > MAX_OUTPUT:
                        raise ValueError("generation_output_unproven")
                    (output if stream == "stdout" else errors).extend(data)
                    continue
                controls.extend(data)
                if len(controls) + sum(len(line) + 1 for line in lines) > 65_536:
                    raise ValueError("generation_control_unproven")
                while b"\n" in controls:
                    line, _, controls = controls.partition(b"\n")
                    line = line.decode("ascii")
                    lines.append(line)
                    if len(line) > 1024 or len(lines) > 512:
                        raise ValueError("generation_control_unproven")
                    if line == "FDS_CLOSED" and not closed and tool_pid is None:
                        closed = True
                    elif re.fullmatch(r"TOOL_SPAWNED [1-9][0-9]*", line) and closed and tool_pid is None:
                        tool_pid = int(line.split()[1])
                    elif line == "CTOR_HELLO " + str(tool_pid) and tool_pid and not hello:
                        hello = True
                        packet = (binding["root"] + "\n" + nonce).encode()
                        os.write(writer, len(packet).to_bytes(4, "big") + packet)
                        os.close(writer)
                        writer = None
                    elif line == "READY " + str(tool_pid) + " " + nonce and hello and not ready:
                        ready = True
                        if kind == "gofmt":
                            child.stdin.write(before)
                            child.stdin.flush()
                        child.stdin.close()
                    elif re.fullmatch(r"CAP [A-Za-z0-9_]+ [A-Za-z0-9_]+ name=[0-9]+ type=[0-9]+", line):
                        pass
                    elif re.fullmatch(r"TOOL_EXIT [1-9][0-9]* [0-9]+", line) and ready and exit_code is None:
                        _, pid, code = line.split()
                        if int(pid) != tool_pid:
                            raise ValueError("generation_producer_changed")
                        exit_code = int(code)
                    else:
                        raise ValueError("generation_control_unproven")
        code = child.wait(timeout=1)
        if controls or not ready or errors or code not in (0, 1) or code != exit_code:
            raise ValueError("generation_tool_failed")
        return {"path": path, "pid": tool_pid, "launcher_pid": child.pid, "exit_code": code,
                "nonce": nonce, "stdout_base64": base64.b64encode(output).decode(),
                "stdout_sha256": sha(output), "control_sha256": sha(compact(lines))}
    finally:
        selector.close()
        for descriptor in (reader, writer, control_reader, control_writer):
            if descriptor is not None:
                os.close(descriptor)
        if child is not None:
            if child.poll() is None:
                child.kill()
            child.wait()
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream and not stream.closed:
                    stream.close()


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("--execute", "--apply", "--status"):
        raise ValueError("generation_mode_unproven")
    signal.alarm(MAX_RUN_SECONDS + 5 if sys.argv[1] == "--execute" else 8)
    packet = read_frame()
    raw = packet["binding_json"]
    binding = json.loads(raw)
    nonce = binding["invocation"]
    if not re.fullmatch("[0-9a-f]{64}", nonce):
        raise ValueError("generation_invocation_unproven")
    if sha(pathlib.Path(__file__).read_bytes()) != binding["helper_sha256"]:
        raise ValueError("generation_program_changed")
    module = types.ModuleType("generation_companion")
    companion_raw = verify_reference({"path": binding["companion_path"], "sha256": binding["companion_sha256"]}, MAX_FRAME)
    module.__file__ = binding["companion_path"]
    exec(compile(companion_raw, module.__file__, "exec", dont_inherit=True, optimize=0), module.__dict__)
    spool = module.open_spool(binding)
    try:
        claim_name, receipt_name = nonce + ".generation-claim", nonce + ".generation-receipt"
        if sys.argv[1] == "--status":
            if module.read_at(spool, claim_name, MAX_FRAME) != raw.encode():
                raise ValueError("generation_claim_changed")
            send_frame({"kind": "result", "receipt": module.read_at(spool, receipt_name, MAX_FRAME).decode()})
            return
        if packet["helper_pid"] != os.getpid():
            raise ValueError("generation_producer_changed")
        parent_alive = parent_observer()
        binding["helper_pid"] = os.getpid()
        binding["sealed_json"] = raw
        with select_locked_role(binding["database"], binding["read_columns"]) as connection:
            ledger_fence(connection, binding)
            parent_alive()
            module.publish(spool, claim_name, raw.encode())
        if sys.argv[1] == "--execute":
            if binding["started_type"] != "EXECUTION_STARTED":
                raise ValueError("generation_mode_changed")
            with tempfile.TemporaryDirectory(prefix="generation-bootstrap-", dir=binding["spool"]) as bootstrap:
                inputs = {item["path"]: base64.b64decode(item["bytes_base64"], validate=True) for item in binding["files"]["files"]}
                results = [tool_diff(binding, path, inputs[path], bootstrap, parent_alive) for path in binding["paths"]] if binding["operation"] == "GOFMT_DIFF" else [tool_diff(binding, "", b"", bootstrap, parent_alive)]
            value = {"version": 1, "kind": "CONTROLLER_GENERATION_EXECUTED", "binding_json": raw, "helper_pid": os.getpid(), "results": results}
        else:
            if binding["started_type"] != "APPLY_STARTED":
                raise ValueError("generation_mode_changed")

            def creator(receipt):
                send_frame({"kind": "creator", "receipt": receipt.decode()})
                ack = read_frame()
                if ack != {"kind": "creator_ack", "sha256": sha(receipt)}:
                    raise ValueError("generation_creator_ack_unproven")

            @contextlib.contextmanager
            def fence():
                signal.alarm(MAX_EFFECT_SECONDS)
                with select_locked_role(binding["database"], binding["read_columns"]) as connection:
                    ledger_fence(connection, binding)
                    parent_alive()
                    yield

            result = replace_text(binding, binding["proposal"], creator, fence)
            value = {"version": 1, "kind": "CONTROLLER_GENERATION_APPLIED", "binding_json": raw, "helper_pid": os.getpid(), "result": result}
        parent_alive()
        receipt = compact(value)
        module.publish(spool, receipt_name, receipt)
        send_frame({"kind": "result", "receipt": receipt.decode()})
    finally:
        os.close(spool)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # A missing owned receipt remains uncertain; stdout is never an ad hoc
        # replacement for an acknowledged durable effect record.
        raise SystemExit(1) from None
