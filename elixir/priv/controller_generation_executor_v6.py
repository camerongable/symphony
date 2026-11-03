"""Shared confined generation for CI, verifier, and generated-only repairs."""

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
    "file_operations": ("SELECT op.* FROM worker_file_operations op JOIN worker_evidence e ON e.request_key=op.request_key WHERE e.run_id=? ORDER BY op.call_id", "run_id"),
    "instruction_snapshots": ("SELECT * FROM worker_instruction_snapshots WHERE run_id=? ORDER BY binding_sha256", "run_id"),
    "instruction_bindings": ("SELECT * FROM worker_instruction_task_bindings WHERE run_id=? ORDER BY task_key,prompt_sha256", "run_id")
}
READ_TABLES = frozenset("""
runs factory_tasks worker_evidence workspace_access native_source_bindings ticket_review_bases
ticket_ci_repair_claims ticket_ci_repair_diagnoses control ticket_chat_commands ticket_chat_questions
ticket_contract_amendments ticket_chats ticket_chat_runs desktop_requests ticket_chat_inputs
worker_file_operations ticket_ci_generation_intents ticket_ci_generation_events
ticket_ordinary_generation_intents ticket_ordinary_generation_events
worker_instruction_snapshots worker_instruction_task_bindings ticket_ci_repair_reassessments
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



def generation_mode(binding):
    mode = binding.get("generation_mode")
    if binding.get("generation_version") != 6 or mode not in ("ci", "ordinary", "generated_only"):
        raise ValueError("generation_mode_unproven")
    prefix = "ordinary-generation:" if mode == "ordinary" else "ci-generation:"
    if not binding["intent_key"].startswith(prefix):
        raise ValueError("generation_mode_unproven")
    return mode


def journal(binding):
    if generation_mode(binding) == "ordinary":
        return "ticket_ordinary_generation_intents", "ticket_ordinary_generation_events"
    return "ticket_ci_generation_intents", "ticket_ci_generation_events"


def ledger_fence(connection, binding):
    mode = generation_mode(binding)
    queries = QUERIES if mode != "ci" else {key: value for key, value in QUERIES.items() if key not in ("instruction_snapshots", "instruction_bindings")}
    expected = binding["ledger"]
    if set(expected) != set(queries):
        raise ValueError("generation_ledger_unproven")
    for name, (sql, parameter) in queries.items():
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
    intents, events = journal(binding)
    cursor = connection.execute("SELECT * FROM " + intents + " WHERE intent_key=?", (binding["intent_key"],))
    values = cursor.fetchone()
    if values is None:
        raise ValueError("generation_intent_missing")
    intent = dict(zip([item[0] for item in cursor.description], values))
    if (intent["binding_sha256"] != binding["intent_sha256"]
            or sha(intent["binding_json"].encode()) != binding["intent_sha256"]
            or intent["request_key"] != binding["request_key"]):
        raise ValueError("generation_intent_changed")
    intent_binding = json.loads(intent["binding_json"])
    kinds = {"ci": "CONTROLLER_CI_GENERATION", "ordinary": "CONTROLLER_ORDINARY_GENERATION", "generated_only": "CONTROLLER_CI_GENERATED_ONLY"}
    if intent_binding.get("kind") != kinds[mode]:
        raise ValueError("generation_mode_unproven")
    if mode == "ordinary":
        proof = intent_binding.get("ordinary_verifier_repair")
        if (not isinstance(proof, dict) or proof.get("kind") != "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1"
                or proof.get("writer_request_key") != intent["request_key"]
                or proof.get("verifier_request_key") != intent["verifier_request_key"]):
            raise ValueError("ordinary_generation_proof_unproven")
    elif mode == "generated_only":
        capability = validate_intent(connection, intent, intent_binding, check_files=True)
        if binding["operation"] != "GAZELLE_DIFF" or binding["paths"] != intent_binding["paths"]:
            raise ValueError("ci_generated_scope_unproven")
        if binding["started_type"] == "EXECUTION_STARTED":
            for value in capability["build_inputs"]:
                path = pathlib.Path(binding["root"]) / value["path"]
                require(str(path.resolve()) == str(path) and stat.S_ISREG(path.lstat().st_mode) and sha(path.read_bytes()) == value["sha256"])
        else:
            proposal = binding["proposal"]
            expected_build = [value for value in capability["build_inputs"] if value["path"] == proposal["path"]]
            require(len(expected_build) == 1 and proposal["before_sha256"] == expected_build[0]["sha256"])
    row = connection.execute("SELECT receipt_json,receipt_sha256,event_type FROM " + events + " WHERE event_key=?", (binding["started_key"],)).fetchone()
    if row is None or sha(row[0].encode()) != row[1] or row[2] != binding["started_type"]:
        raise ValueError("generation_start_unproven")
    started = json.loads(row[0])
    if started["helper_pid"] != binding["helper_pid"] or started["binding_json"] != binding["sealed_json"]:
        raise ValueError("generation_producer_changed")
    if binding.get("preview_retry"):
        validate_retry(connection, binding)
    elif connection.execute("SELECT event_key FROM " + events + " WHERE intent_key=? AND event_type IN ('BLOCKED','UNCERTAIN') LIMIT 1", (binding["intent_key"],)).fetchone() is not None:
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
        args = config["gazelle_flags"] + ["-external=static"] + packages
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
        deadline = time.monotonic() + 30
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


PROFILE_SHA = "917e8a5caacdbb2f4cede1572f1368b31ca97738ebd40320d9a174aa3503e6c1"
TOOLSET_SHA = "a7b82db9826c6dcc1e7cf2f726f7ca47c3677125e164bbc9c27abf7f2350282e"
GUIDANCE = "Controller-only mechanical BUILD capability, not writer permission. Only a genuine no-edit COMPLETE at the exact failed candidate, with no CONTINUE lineage, can select it. Never edit BUILD or invent a source edit to trigger generation. Source edits remain governed solely by the original CI scope."


def require(condition):
    if not condition:
        raise ValueError("ci_generated_scope_unproven")


def one(connection, sql, args):
    cursor = connection.execute(sql, args)
    values = cursor.fetchall()
    require(len(values) == 1)
    return dict(zip([column[0] for column in cursor.description], values[0]))


def checked(row, field, digest_field):
    require(type(row[field]) is str and len(row[field].encode()) <= 2097152 and sha(row[field].encode()) == row[digest_field])
    value = json.loads(row[field], object_pairs_hook=unique_object)
    require(type(value) is dict)
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def relative(path):
    return (type(path) is str and 0 < len(path.encode()) <= 1024
            and not path.startswith("/") and all(part not in ("", ".", "..")
            and not part.startswith("-") for part in path.split("/")))


def validate_capability(capability, claim, diagnosis_row, diagnosis, preimage):
    fields = set("version kind profile_sha256 toolset_manifest_sha256 run_id repo_key gitlab_project_id spec_revision contract_sha256 failed_candidate_sha pipeline_id diagnosis_key diagnosis_sha256 preimage_sha256 claim_key traces go_inputs build_inputs generated_paths".split())
    require(type(capability) is dict and set(capability) == fields)
    require(type(capability["version"]) is int and capability["version"] == 1 and capability["kind"] == "CI_GENERATED_ONLY_V1")
    local = pathlib.Path(__file__).resolve().parent
    require(sha((local / "ci_generated_only_profile_v1.json").read_bytes()) == capability["profile_sha256"] == PROFILE_SHA)
    raw = (local / "controller_generation_toolset_v1.json").read_bytes()
    require(sha(raw) == capability["toolset_manifest_sha256"] == TOOLSET_SHA)
    toolset = json.loads(raw)
    prior = claim["prior_run"]
    require(capability["repo_key"] == prior["repo_key"] == toolset["repo_key"])
    require(capability["gitlab_project_id"] == str(preimage["ci_snapshots"]["mr"]["project_id"]) == toolset["gitlab_project_id"])
    for key in ("run_id", "spec_revision", "contract_sha256"):
        require(capability[key] == prior[key] == preimage["run"][key])
    require(capability["claim_key"] == claim["claim_key"] == "ci-claim:" + sha(claim["diagnosis_key"].encode()))
    require(capability["diagnosis_key"] == claim["diagnosis_key"] == diagnosis_row["diagnosis_key"])
    for key in ("diagnosis_sha256", "preimage_sha256", "pipeline_id"):
        require(capability[key] == diagnosis_row[key])
    require(capability["failed_candidate_sha"] == prior["candidate_sha"] == diagnosis_row["candidate_sha"] == preimage["run"]["candidate_sha"])
    require(diagnosis["status"] == "REPAIRABLE" and diagnosis["pipeline_id"] == capability["pipeline_id"])
    require(diagnosis["allowed_writer_paths"] == claim["allowed_writer_paths"] and diagnosis["required_generated_paths"] == claim["required_generated_paths"])
    permitted = set(diagnosis["changed_paths"]) & set(diagnosis["allowed_writer_paths"])
    sources, traces = set(), []
    for entry in diagnosis["logs"]:
        selected = sorted(set(re.findall(r'(go/src/[A-Za-z0-9_./-]+\.go): import of "[^"\r\n]+"', entry["text"])) & permitted)
        if not selected:
            continue
        job = entry["job_id"]
        require(any(value["id"] == job for value in diagnosis["failed_jobs"]))
        require(any(value["job_id"] == job and value["status"] == "COMPLETE" for value in diagnosis["trace_availability"]))
        provenance = [value for value in diagnosis["trace_provenance"] if value.get("arguments", {}).get("job_id") == str(job)]
        require(len(provenance) == 1 and provenance[0]["arguments"]["project_id"] == capability["gitlab_project_id"])
        require(re.fullmatch("[0-9a-f]{64}", provenance[0]["raw_sha256"]) is not None)
        traces.append({"job_id": job, "log_sha256": sha(entry["text"].encode()), "provenance_sha256": sha(compact(provenance[0])), "source_paths": selected})
        sources.update(selected)
    require(1 <= len(sources) <= 16 and all(relative(path) for path in sources))
    unique_traces = {compact(value): value for value in traces}
    require(capability["traces"] == sorted(unique_traces.values(), key=lambda value: value["job_id"]))
    require(type(capability["go_inputs"]) is list and type(capability["build_inputs"]) is list)
    require([value["path"] for value in capability["go_inputs"]] == sorted(sources))
    builds = [value["path"] for value in capability["build_inputs"]]
    require(builds == sorted(set(builds)) == capability["generated_paths"])
    require(all(relative(path) and pathlib.PurePosixPath(path).name in ("BUILD", "BUILD.bazel") for path in builds))
    require([str(pathlib.PurePosixPath(path).parent) for path in builds] == sorted({str(pathlib.PurePosixPath(path).parent) for path in sources}))
    for value in capability["go_inputs"] + capability["build_inputs"]:
        require(set(value) == set("path mode git_blob_sha sha256 size".split()) and value["mode"] in ("100644", "100755"))
        require(type(value["size"]) is int and 1 <= value["size"] <= 262144)
        require(re.fullmatch("[0-9a-f]{40}", value["git_blob_sha"]) is not None and re.fullmatch("[0-9a-f]{64}", value["sha256"]) is not None)


def validate_intent(connection, intent_row, intent, check_files=False):
    require(intent["kind"] == "CONTROLLER_CI_GENERATED_ONLY" and type(intent["version"]) is int and intent["version"] == 1 and intent["operation"] == "GAZELLE_DIFF")
    require(intent_row["intent_key"] == "ci-generation:" + sha(compact([intent_row["request_key"], "GAZELLE_DIFF"])))
    proof = intent["generated_only_execution"]
    require(set(proof) == set("version kind capability instruction_binding_sha256 packet_sha256 request_key binding_sha256 output_sha256 reservation_key reservation_generation".split()))
    require(type(proof["version"]) is int and proof["version"] == 1 and proof["kind"] == "CI_GENERATED_ONLY_EXECUTION_V1")
    claim_row = one(connection, "SELECT * FROM ticket_ci_repair_claims WHERE claim_key=?", (intent_row["claim_key"],))
    claim = checked(claim_row, "claim_json", "claim_sha256")
    require(claim_row["claim_key"] == claim["claim_key"] == intent_row["claim_key"] and claim_row["round"] == claim["round"])
    capability = claim["generated_only_capability"]
    require(proof["capability"] == capability and intent["paths"] == capability["generated_paths"])
    observed = intent["observation"]["files"]["files"]
    require([value["path"] for value in observed] == capability["generated_paths"])
    for value, expected in zip(observed, capability["build_inputs"]):
        require(value["sha256"] == expected["sha256"] and value["size"] == expected["size"])
        require(sha(base64.b64decode(value["bytes_base64"], validate=True)) == expected["sha256"])
    table = "ticket_ci_repair_reassessments" if "reassessment_key" in claim else "ticket_ci_repair_diagnoses"
    diagnosis_row = one(connection, "SELECT * FROM " + table + " WHERE diagnosis_key=? AND diagnosis_sha256=?", (claim["diagnosis_key"], capability["diagnosis_sha256"]))
    diagnosis = checked(diagnosis_row, "diagnosis_json", "diagnosis_sha256")
    preimage = checked(diagnosis_row, "preimage_json", "preimage_sha256")
    validate_capability(capability, claim, diagnosis_row, diagnosis, preimage)
    worker = one(connection, "SELECT * FROM worker_evidence WHERE request_key=?", (intent_row["request_key"],))
    binding = checked(worker, "binding_json", "binding_sha256")
    output = checked(worker, "output_json", "output_sha256")
    require(proof["request_key"] == worker["request_key"] and worker["run_id"] == intent_row["run_id"] == capability["run_id"])
    require(intent["run_preimage"]["candidate_sha"] == capability["failed_candidate_sha"] and intent["run_preimage"]["code_repair_round"] == claim_row["round"])
    require(all(intent["run_preimage"][key] == claim["prior_run"][key] for key in ("run_id", "spec_revision", "contract_sha256", "repo_key", "repo_path", "worktree", "branch", "implementation_iteration")))
    toolset_raw = pathlib.Path(__file__).resolve().with_name("controller_generation_toolset_v1.json").read_bytes()
    require(sha(toolset_raw) == TOOLSET_SHA == capability["toolset_manifest_sha256"])
    toolset = json.loads(toolset_raw)
    toolset["manifest_sha256"] = TOOLSET_SHA
    require(intent["toolset"] == toolset)
    require(all(proof[key] == worker[key] for key in ("binding_sha256", "output_sha256", "reservation_key")))
    require(proof["reservation_generation"] == binding["reservation_generation"])
    require(binding["expected_sha"] == capability["failed_candidate_sha"] and binding["mode"] == "SOURCE" and binding["role"] == "feature-writer" and binding["stage"] == "REPAIRING")
    require(output["status"] == "COMPLETE" and output["changed_paths"] == [] and worker["owner_stopped_at"] is not None and worker["owner_stop_json"] is not None)
    access = one(connection, "SELECT * FROM workspace_access WHERE reservation_key=?", (worker["reservation_key"],))
    require(access["run_id"] == worker["run_id"] and access["task_key"] == worker["task_key"] and access["request_key"] == worker["request_key"] and access["generation"] == proof["reservation_generation"] and access["mode"] == "SOURCE")
    require(access["canonical_path"] == claim["prior_run"]["worktree"] == intent["observation"]["spool"]["root"])
    stop = json.loads(worker["owner_stop_json"])
    require(stop["transport"] == "owned_app_server" and stop["thread_id"] == worker["thread_id"] and stop["cwd"] == access["canonical_path"] and type(stop["exit_status"]) is int and stop["exit_status"] == 0)
    if check_files:
        require(worker["status"] == "RESULT_RECORDED" and access["released_at"] is None)
    mapping = one(connection, "SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?", (worker["task_key"], binding["prompt_sha256"]))
    require(mapping["instruction_binding_sha256"] == proof["instruction_binding_sha256"] and mapping["run_id"] == worker["run_id"] and mapping["role"] == "feature-writer")
    snapshot = one(connection, "SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?", (mapping["instruction_binding_sha256"],))
    packet = checked(snapshot, "binding_json", "binding_sha256")
    bundle = checked(snapshot, "bundle_json", "bundle_sha256")
    require(snapshot["role"] == "ci-repair-writer" and snapshot["run_id"] == worker["run_id"] and snapshot["binding_sha256"] == proof["packet_sha256"])
    require(packet["stage"] == "REPAIRING" and packet["role"] == "feature-writer" and packet["code_repair_round"] == claim_row["round"])
    require(packet["candidate_sha"] == capability["failed_candidate_sha"] and packet["implementation_iteration"] == claim["prior_run"]["implementation_iteration"])
    require(all(packet[key] == capability[key] == binding[key] for key in ("run_id", "spec_revision", "contract_sha256")))
    require(binding["input_sha256"] == binding["prompt_sha256"] and packet["ci_repair"]["claim_key"] == claim_row["claim_key"])
    require(packet["controller_generation_scope"] == {"version": 1, "kind": "CI_GENERATED_ONLY_PACKET_V1", "capability": capability, "capability_sha256": sha(compact(capability)), "instructions": GUIDANCE})
    require(set(bundle) == {"shared_instructions", "instruction_delivery"} and type(bundle["instruction_delivery"]) is str and bundle["instruction_delivery"])
    instructions = bundle["shared_instructions"]
    require(type(instructions) is list and sum(len(value["content"].encode()) for value in instructions) <= 262144)
    paths = []
    for value in instructions:
        require(set(value) == {"path", "relative_path", "content", "sha256"} and all(type(item) is str for item in value.values()))
        require(1 <= len(value["content"].encode()) <= 65536 and sha(value["content"].encode()) == value["sha256"])
        paths.append(value["relative_path"])
    require(len(paths) == len(set(paths)) and set("AGENTS.md rules/comment-discipline.mdc rules/gitlab-preferences.mdc rules/go-test-style.mdc rules/skills-directory.mdc skills/draft-feature-cycle/SKILL.md skills/select-tests/SKILL.md skills/fix-mr-pipeline/SKILL.md".split()) <= set(paths))
    if check_files:
        root = pathlib.Path(intent["run_preimage"]["worktree"])
        for value in capability["go_inputs"]:
            path = root / value["path"]
            require(str(path.resolve()) == str(path) and stat.S_ISREG(path.lstat().st_mode))
            require(sha(path.read_bytes()) == value["sha256"])
    return capability



def checked_event(connection, key, events):
    cursor = connection.execute("SELECT * FROM " + events + " WHERE event_key=?", (key,))
    rows = cursor.fetchall()
    require(len(rows) == 1)
    row = dict(zip([value[0] for value in cursor.description], rows[0]))
    require(hashlib.sha256(row["receipt_json"].encode()).hexdigest() == row["receipt_sha256"])
    return row, json.loads(row["receipt_json"])


def failures(connection, binding, retry, depth=0):
    _, events = journal(binding)
    require(isinstance(retry, dict) and depth < 2)
    previous = retry.get("previous_retry")
    fields = set("execution_path original_uncertain_key original_uncertain_sha256 original_started_key original_started_sha256".split())
    require(set(retry) == fields | ({"previous_retry"} if previous is not None else set()))
    require(retry["execution_path"] == ("preview-retry:2" if previous else "preview-retry:1"))
    require(not previous or previous.get("previous_retry") is None)
    prior = failures(connection, binding, previous, depth + 1) if previous else []
    path = previous["execution_path"] if previous else ""
    uncertain, failure = checked_event(connection, retry["original_uncertain_key"], events)
    started, owner = checked_event(connection, retry["original_started_key"], events)
    require(uncertain["receipt_sha256"] == retry["original_uncertain_sha256"] and started["receipt_sha256"] == retry["original_started_sha256"])
    require(uncertain["intent_key"] == started["intent_key"] == binding["intent_key"])
    require(uncertain["event_type"] == "UNCERTAIN" and started["event_type"] == "EXECUTION_STARTED" and uncertain["path"] == started["path"] == path)
    original = json.loads(owner["binding_json"])
    require(failure["reason"] in ("OWNED_RECEIPT_UNPROVEN", "READ_ONLY_TOOL_FAILED") and failure["binding_sha256"] == hashlib.sha256(owner["binding_json"].encode()).hexdigest())
    require(original["started_type"] == "EXECUTION_STARTED" and original["proposal"] is None)
    require(original.get("generation_version") in ((4, 5, 6) if previous else (None, 1, 2, 3, 5, 6)))
    if previous:
        require(original["preview_retry"] == previous and original["execution_path"] == path)
    for field in ("intent_key", "intent_sha256", "root", "root_device", "root_inode", "request_key", "run_id", "operation", "paths", "toolset"):
        require(original[field] == binding[field])
    return prior + [uncertain["event_key"]]


def validate_retry(connection, binding):
    _, events = journal(binding)
    retry = binding["preview_retry"]
    require(binding["operation"] in ("GOFMT_DIFF", "GAZELLE_DIFF"))
    expected = failures(connection, binding, retry)
    pending = connection.execute("SELECT event_key FROM " + events + " WHERE intent_key=? AND event_type IN ('BLOCKED','UNCERTAIN')", (binding["intent_key"],)).fetchall()
    require(sorted(row[0] for row in pending) == sorted(expected))
    cursor = connection.execute("SELECT event_key FROM " + events + " WHERE intent_key=? AND event_type='EXECUTION_RECEIPT' AND path=?", (binding["intent_key"], retry["execution_path"]))
    receipt_key = cursor.fetchone()
    if binding["started_type"] == "EXECUTION_STARTED":
        require(binding["execution_path"] == retry["execution_path"] and binding["proposal"] is None)
        if receipt_key is None:
            types = connection.execute("SELECT event_type FROM " + events + " WHERE intent_key=?", (binding["intent_key"],)).fetchall()
            require(not any(row[0].startswith("APPL") for row in types))
    else:
        require(binding["started_type"] == "APPLY_STARTED" and receipt_key is not None)
    if receipt_key is not None:
        row, receipt = checked_event(connection, receipt_key[0], events)
        fresh = json.loads(receipt["binding_json"])
        fresh_owner, actual = checked_event(connection, fresh["started_key"], events)
        require(row["intent_key"] == fresh_owner["intent_key"] == binding["intent_key"])
        require(fresh_owner["event_type"] == "EXECUTION_STARTED" and fresh_owner["path"] == retry["execution_path"])
        require(actual["binding_json"] == receipt["binding_json"] and actual["helper_pid"] == receipt["helper_pid"])
        require(fresh["preview_retry"] == retry and fresh["generation_version"] in (4, 5, 6) and fresh["started_type"] == "EXECUTION_STARTED")
        require(receipt["kind"] == "CONTROLLER_GENERATION_EXECUTED" and isinstance(receipt["results"], list))



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
            try:
                with tempfile.TemporaryDirectory(prefix="generation-bootstrap-", dir=binding["spool"]) as bootstrap:
                    inputs = {item["path"]: base64.b64decode(item["bytes_base64"], validate=True) for item in binding["files"]["files"]}
                    results = [tool_diff(binding, path, inputs[path], bootstrap, parent_alive) for path in binding["paths"]] if binding["operation"] == "GOFMT_DIFF" else [tool_diff(binding, "", b"", bootstrap, parent_alive)]
                value = {"version": 1, "kind": "CONTROLLER_GENERATION_EXECUTED", "binding_json": raw, "helper_pid": os.getpid(), "results": results}
            except ValueError as error:
                reason = str(error)
                if reason not in ("generation_tool_timeout", "generation_tool_failed", "generation_output_unproven", "generation_control_unproven"):
                    raise
                value = {"version": 1, "kind": "CONTROLLER_GENERATION_FAILED", "binding_json": raw, "helper_pid": os.getpid(), "reason": reason}
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

