"""One committed invocation, one owned child, durable waitpid evidence before reply."""
import base64
import hashlib
import json
import os
import pathlib
import select
import signal
import sqlite3
import stat
import subprocess
import sys
import time
import unicodedata
import urllib.parse

MAX_FRAME = 2_097_152
WRITE_PROFILE = '(version 1)(deny default)(allow process-exec)(allow file-read*)(allow file-write* (subpath (param "SOURCE_ROOT")))(allow sysctl-read)(allow mach-lookup)'
READ_PROFILE = '(version 1)(deny default)(allow process-exec)(allow file-read*)(allow file-write* (literal "/dev/null"))(allow sysctl-read)(allow mach-lookup)'


class UnprovenProcess(ValueError):
    pass


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def directory(path):
    if not isinstance(path, str) or not path.startswith("/"):
        raise ValueError("absolute_directory_required")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split("/")[1:]:
            if part in ("", ".", ".."):
                raise ValueError("directory_rejected")
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def identity(descriptor):
    info = os.fstat(descriptor)
    return info.st_dev, info.st_ino


def planned_directory(path):
    if not isinstance(path, str) or not path.startswith("/"):
        raise ValueError("absolute_directory_required")
    parts = path.split("/")[1:]
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("directory_rejected")
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(parts):
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            except FileNotFoundError:
                return descriptor, tuple(unicodedata.normalize("NFC", item).casefold() for item in parts[index:])
            os.close(descriptor)
            descriptor = child
        return descriptor, ()
    except BaseException:
        os.close(descriptor)
        raise


def ancestors(descriptor):
    current = os.dup(descriptor)
    observed = set()
    try:
        for _ in range(4096):
            here = identity(current)
            observed.add(here)
            parent = os.open("..", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            if identity(parent) == here:
                os.close(parent)
                return observed
            os.close(current)
            current = parent
        raise ValueError("ancestry_unproven")
    finally:
        os.close(current)


def check_boundary(spool, parent, sources):
    spool_ancestors = ancestors(spool if spool is not None else parent)
    spool_identity = identity(spool) if spool is not None else None
    base_identity = identity(spool if spool is not None else parent)
    missing_spool = () if spool is not None else (".factory-file-io",)
    for item in sources:
        if set(item) != {"path", "required"} or not isinstance(item["required"], bool):
            raise ValueError("source_rejected")
        source, missing_source = planned_directory(item["path"])
        try:
            if missing_source and item["required"]:
                raise ValueError("active_source_absent")
            same_base = identity(source) == base_identity
            planned_overlap = same_base and (missing_source[:len(missing_spool)] == missing_spool or missing_spool[:len(missing_source)] == missing_source)
            if planned_overlap or (not missing_source and identity(source) in spool_ancestors) or (spool_identity is not None and spool_identity in ancestors(source)):
                raise ValueError("spool_in_source")
        finally:
            os.close(source)


def spool_state(path, sources, create):
    parent = directory(os.path.dirname(path))
    name = os.path.basename(path)
    spool = None
    try:
        if name != ".factory-file-io" or not isinstance(sources, list) or not sources:
            raise ValueError("spool_rejected")
        try:
            spool = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        except FileNotFoundError:
            pass
        check_boundary(spool, parent, sources)
        if create:
            if spool is None:
                try:
                    os.mkdir(name, 0o700, dir_fd=parent)
                except FileExistsError:
                    pass
                spool = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            check_boundary(spool, parent, sources)
            info = os.fstat(spool)
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise ValueError("spool_rejected")
            return {"version": 1, "device": info.st_dev, "inode": info.st_ino}
        return {"version": 1, "allowed": True}
    finally:
        if spool is not None:
            os.close(spool)
        os.close(parent)


def source_paths(database, root):
    uri = "file:" + urllib.parse.quote(database, safe="/") + "?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        rows = connection.execute("SELECT canonical_path, released_at IS NULL FROM workspace_access UNION SELECT worktree, state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED') FROM runs WHERE worktree IS NOT NULL UNION SELECT repo_path, state NOT IN ('READY_FOR_REVIEW', 'DELIVERED', 'AWAITING_VALIDATION', 'CANCELLED', 'FAILED') FROM runs WHERE repo_path IS NOT NULL").fetchall()
    return [{"path": root, "required": True}] + [{"path": row[0], "required": bool(row[1])} for row in rows]


def read_at(parent, name, limit):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_size > limit:
            raise ValueError("receipt_rejected")
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(descriptor, min(65_536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > limit:
            raise ValueError("receipt_too_large")
        return bytes(data)
    finally:
        os.close(descriptor)


def publish(parent, name, data):
    temporary = name + ".prepared"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.link(temporary, name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
    os.unlink(temporary, dir_fd=parent)
    os.fsync(parent)


def committed(connection, database, invocation, binding_json, raw):
    row = connection.execute(
        "SELECT io_binding_json, phase, io_pending, request_key, call_id, arguments_sha256, path, before_sha256, after_sha256 "
        "FROM worker_file_operations WHERE io_invocation = ?", (invocation,),
    ).fetchone()
    access = connection.execute(
        "SELECT canonical_path, generation, released_at, mode, binding_json, run_id, task_key, request_key "
        "FROM workspace_access WHERE reservation_key = ?", (json.loads(binding_json)["reservation_key"],),
    ).fetchone()
    if row is None or row[0] != binding_json or row[1:3] != ("PREPARED", 1):
        raise ValueError("precommit_unproven")
    binding = json.loads(binding_json)
    if access is None or access[:4] != (binding["root"], binding["generation"], None, "SOURCE") or sha(access[4].encode()) != binding["workspace_binding_sha256"] or access[5] != binding["run_id"]:
        raise ValueError("reservation_changed")
    if binding["version"] != 1 or binding["invocation"] != invocation or binding["database"] != database:
        raise ValueError("binding_rejected")
    if (binding["request_key"], binding["call_id"], binding["arguments_sha256"]) != row[3:6]:
        raise ValueError("operation_mismatch")
    if sha(raw) != binding["input_sha256"]:
        raise ValueError("input_changed")
    request = json.loads(raw)
    observed = (request["nonce"], request["root"], request["device"], request["inode"], request["operation"])
    operation = binding.get("operation", "replace")
    expected = (invocation, binding["root"], binding["root_device"], binding["root_inode"], operation)
    if operation not in ("replace", "replace_binary", "delete", "mkdir") or observed != expected:
        raise ValueError("source_binding_changed")
    arguments = request["arguments"]
    before = arguments.get("expected_sha256", "ABSENT")
    if operation == "replace":
        after = sha(arguments["content"].encode("utf-8"))
    elif operation == "replace_binary":
        after = sha(base64.b64decode(arguments["content_base64"], validate=True))
    else:
        after = "ABSENT" if operation == "delete" else "DIRECTORY"
    effect = (arguments["path"], before, after)
    if (binding["path"], binding["before_sha256"], binding["after_sha256"]) != effect or row[6:] != effect:
        raise ValueError("effect_binding_changed")
    helper = pathlib.Path(__file__).resolve().with_name("worker_file_io.py")
    if sha(helper.read_bytes()) != binding["helper_sha256"] or sha(pathlib.Path(__file__).read_bytes()) != binding["companion_sha256"]:
        raise ValueError("program_changed")
    if sha(WRITE_PROFILE.encode()) != binding["profile_sha256"]:
        raise ValueError("profile_changed")
    return binding, helper, access


def one(connection, sql, arguments):
    row = connection.execute(sql, arguments).fetchone()
    if row is None:
        raise ValueError("authorization_missing")
    return row


def current_authorization(connection, binding, access):
    saved = json.loads(access[4])
    run = one(connection, "SELECT * FROM runs WHERE run_id = ?", (binding["run_id"],))
    evidence = one(connection, "SELECT * FROM worker_evidence WHERE request_key = ?", (binding["request_key"],))
    captured = json.loads(evidence["binding_json"])
    task = one(connection, "SELECT * FROM factory_tasks WHERE task_key = ?", (evidence["task_key"],))
    if (evidence["binding_sha256"] != binding["worker_binding_sha256"] or sha(evidence["binding_json"].encode()) != evidence["binding_sha256"]
            or evidence["status"] != "TURN_BOUND" or evidence["owner_stopped_at"] is not None or evidence["owner_process_json"] is None):
        raise ValueError("worker_not_active")
    if (evidence["owner_id"], evidence["thread_id"], evidence["turn_id"]) != (binding["worker_owner_id"], binding["worker_thread_id"], binding["worker_turn_id"]) or sha(evidence["owner_process_json"].encode()) != binding["worker_process_sha256"]:
        raise ValueError("worker_identity_changed")
    if (evidence["run_id"], evidence["task_key"], evidence["reservation_key"]) != (binding["run_id"], access[6], binding["reservation_key"]) or access[7] != binding["request_key"]:
        raise ValueError("worker_reservation_changed")
    for field in ("task_key", "run_id", "role", "stage", "model", "reasoning_effort", "prompt_sha256"):
        if task[field] != captured[field]:
            raise ValueError("worker_inputs_changed")
    if (captured["role"], captured["mode"], captured["policy"]["mode"], captured["policy"]["source_access"]) != ("feature-writer", "SOURCE", "FILE_SOURCE", "read"):
        raise ValueError("worker_policy_changed")
    if (captured["reservation_key"], captured["reservation_generation"], captured["expected_sha"]) != (binding["reservation_key"], binding["generation"], saved["expected_sha"]):
        raise ValueError("worker_source_changed")
    if run["state"] not in ("WRITING", "REPAIRING", "REVIEW_WRITING") or run["execution_mode"] != "TICKET_SUPERVISOR_V1":
        raise ValueError("run_not_writing")
    for field in ("spec_revision", "contract_sha256", "branch", "candidate_sha"):
        if run[field] != saved[field]:
            raise ValueError("run_inputs_changed")
    if (any(run[field] != captured[field] for field in ("spec_revision", "contract_sha256")) or os.path.realpath(run["worktree"]) != binding["root"]
            or os.path.realpath(run["repo_path"]) != binding["repository_path"] or os.path.realpath(task["workspace"]) != binding["root"]):
        raise ValueError("run_source_changed")
    checkout_authorization(binding, saved, run)


def git(root, arguments):
    environment = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0",
                   "GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"}
    command = ["/usr/bin/sandbox-exec", "-p", READ_PROFILE, "/Library/Developer/CommandLineTools/usr/bin/git",
               "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", root] + arguments
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=2, check=True)
    if len(result.stdout) > 16_384:
        raise ValueError("checkout_output_rejected")
    return result.stdout.decode("utf-8").strip()


def checkout_authorization(binding, saved, run):
    root = directory(binding["root"])
    try:
        if identity(root) != (binding["root_device"], binding["root_inode"]):
            raise ValueError("source_identity_changed")
    finally:
        os.close(root)
    observed = git(binding["root"], ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir", "HEAD"]).splitlines()
    expected = [binding["root"], saved["git_dir"], saved["common_dir"], saved["expected_sha"]]
    if len(observed) != 4 or [os.path.realpath(value) for value in observed[:3]] != expected[:3] or observed[3] != expected[3]:
        raise ValueError("checkout_changed")
    if git(binding["root"], ["symbolic-ref", "--short", "HEAD"]) != run["branch"]:
        raise ValueError("checkout_branch_changed")


def pipe_bytes(stream, size, deadline):
    data = bytearray()
    while len(data) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise subprocess.TimeoutExpired("fixed_source_helper", 4)
        chunk = os.read(stream.fileno(), size - len(data))
        if not chunk:
            raise ValueError("child_frame_incomplete")
        data.extend(chunk)
    return bytes(data)


def send_child(stream, raw, deadline):
    data = len(raw).to_bytes(4, "big") + raw
    offset = 0
    while offset < len(data):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([], [stream], [], remaining)[1]:
            raise subprocess.TimeoutExpired("fixed_source_helper", 4)
        offset += os.write(stream.fileno(), data[offset:])


def child_frame(stream, deadline):
    header = pipe_bytes(stream, 4, deadline)
    size = int.from_bytes(header, "big")
    if not 1 <= size <= MAX_FRAME:
        raise ValueError("child_frame_rejected")
    return pipe_bytes(stream, size, deadline)


def certify_creator(raw, binding, binding_json, spool, owned_pid):
    if len(raw) > 4096 or binding["operation"] not in ("replace", "replace_binary"):
        raise ValueError("creator_rejected")
    event = json.loads(raw)
    fields = {"version", "event", "nonce", "binding_sha256", "pid", "path", "temporary", "root_device", "root_inode", "parent_device", "parent_inode", "device", "inode"}
    expected = {"version": 1, "event": "TEMP_CREATED", "nonce": binding["invocation"], "binding_sha256": sha(binding_json.encode("utf-8")),
                "path": binding["path"], "temporary": ".symphony-" + binding["invocation"], "root_device": binding["root_device"], "root_inode": binding["root_inode"]}
    if set(event) != fields or any(event.get(key) != value for key, value in expected.items()) or any(type(event[key]) is not int or event[key] <= 0 for key in ("version", "root_device", "root_inode", "parent_device", "parent_inode", "device", "inode")):
        raise ValueError("creator_binding_changed")
    if type(event["pid"]) is not int or event["pid"] != owned_pid:
        raise UnprovenProcess("source_pid_unproven")
    parts = binding["path"].split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("creator_path_rejected")
    root = directory(binding["root"])
    parent = os.dup(root)
    try:
        if identity(root) != (event["root_device"], event["root_inode"]):
            raise ValueError("creator_root_changed")
        for part in parts[:-1]:
            nested = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = nested
        info = os.stat(event["temporary"], dir_fd=parent, follow_symlinks=False)
        if identity(parent) != (event["parent_device"], event["parent_inode"]) or (info.st_dev, info.st_ino) != (event["device"], event["inode"]) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
            raise ValueError("creator_identity_changed")
        publish(spool, binding["invocation"] + ".creator", raw)
        return raw.decode("utf-8")
    finally:
        os.close(parent)
        os.close(root)


def child_result(helper, binding, raw, spool, binding_json):
    command = ["/usr/bin/sandbox-exec", "-D", "SOURCE_ROOT=" + binding["root"], "-p", WRITE_PROFILE,
               "/usr/bin/python3", "-I", "-S", "-B", str(helper), "--creator-binding-sha", sha(binding_json.encode("utf-8"))]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={}, bufsize=0)
    deadline = time.monotonic() + 4
    creator, output, failure = None, b"", None
    try:
        os.set_blocking(child.stdin.fileno(), False)
        os.set_blocking(child.stdout.fileno(), False)
        send_child(child.stdin, raw, deadline)
        frame = child_frame(child.stdout, deadline)
        value = json.loads(frame)
        if isinstance(value, dict) and value.get("event") == "TEMP_CREATED":
            creator = certify_creator(frame, binding, binding_json, spool, child.pid)
            ack = json.dumps({"version": 1, "event": "TEMP_RECORDED", "nonce": binding["invocation"], "creator_sha256": sha(frame)}, separators=(",", ":")).encode("utf-8")
            send_child(child.stdin, ack, deadline)
            frame = child_frame(child.stdout, deadline)
        output = len(frame).to_bytes(4, "big") + frame
        child.stdin.close()
        child.stdin = None
        tail, _ = child.communicate(timeout=max(deadline - time.monotonic(), 0.001))
        output += tail
    except (subprocess.TimeoutExpired, OSError, ValueError, TypeError, KeyError) as error:
        failure = error
        # This PID remains our unreaped child; it cannot have been reused by another process.
        if child.poll() is None:
            child.kill()
        if child.stdin is not None:
            child.stdin.close()
            child.stdin = None
        tail, _ = child.communicate()
        output += tail
    if len(output) > MAX_FRAME + 4:
        output = b""
    code = child.returncode
    if isinstance(failure, UnprovenProcess):
        raise failure
    termination = {"kind": "exited", "code": code} if code >= 0 else {"kind": "signaled", "signal": -code}
    return child.pid, termination, output, creator


def cleanup_temporary(helper, binding, binding_json, creator, original_pid, spool):
    observed = json.loads(creator)
    args = {key: observed[key] for key in ("path", "parent_device", "parent_inode", "device", "inode")}
    args.update({"source_nonce": binding["invocation"], "before_sha256": binding["before_sha256"], "after_sha256": binding["after_sha256"]})
    request = {"version": 1, "nonce": binding["invocation"], "root": binding["root"], "device": binding["root_device"], "inode": binding["root_inode"], "operation": "temporary_recover", "arguments": args}
    raw = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    cleanup_binding = dict(binding, operation="temporary_recover")
    pid, termination, output, unexpected_creator = child_result(helper, cleanup_binding, raw, spool, binding_json)
    if unexpected_creator is not None:
        raise ValueError("cleanup_creator_rejected")
    try:
        size = int.from_bytes(output[:4], "big")
        response = json.loads(output[4:])
        if size != len(output) - 4 or response["helper_pid"] != pid or type(response["helper_pid"]) is not int or response["nonce"] != binding["invocation"] or response["version"] != 1:
            raise UnprovenProcess("cleanup_pid_unproven")
    except (ValueError, KeyError, TypeError) as error:
        raise UnprovenProcess("cleanup_pid_unproven") from error
    cleanup = {"version": 1, "binding_sha256": sha(binding_json.encode("utf-8")), "original_pid": original_pid,
               "creator_sha256": sha(creator.encode("utf-8")), "input_json": raw.decode("utf-8"), "input_sha256": sha(raw),
               "pid": pid, "helper_pid": response["helper_pid"], "termination": termination, "output_base64": base64.b64encode(output).decode("ascii")}
    encoded = json.dumps(cleanup, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    publish(spool, binding["invocation"] + ".cleanup", encoded)
    return cleanup


def open_spool(binding):
    spool = directory(binding["spool"])
    info = os.fstat(spool)
    if (info.st_dev, info.st_ino) != (binding["spool_device"], binding["spool_inode"]) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        os.close(spool)
        raise ValueError("spool_changed")
    parent = directory(os.path.dirname(binding["spool"]))
    try:
        check_boundary(spool, parent, source_paths(binding["database"], binding["root"]))
    except BaseException:
        os.close(spool)
        raise
    finally:
        os.close(parent)
    return spool


def read_receipt(database, invocation):
    if len(invocation) != 64 or any(char not in "0123456789abcdef" for char in invocation):
        raise ValueError("invocation_rejected")
    uri = "file:" + urllib.parse.quote(database, safe="/") + "?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        row = connection.execute("SELECT io_binding_json FROM worker_file_operations WHERE io_invocation = ?", (invocation,)).fetchone()
    if row is None:
        raise ValueError("invocation_unknown")
    binding = json.loads(row[0])
    if binding["invocation"] != invocation or binding["database"] != database:
        raise ValueError("binding_changed")
    spool = open_spool(binding)
    try:
        claim = read_at(spool, invocation + ".claim", MAX_FRAME)
        if claim.decode("utf-8") != row[0]:
            raise ValueError("claim_changed")
        try:
            encoded = read_at(spool, invocation + ".receipt", 4_194_304)
        except FileNotFoundError:
            record = complete_artifacts(spool, invocation)
            encoded = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        else:
            record = json.loads(encoded)
            if "recovery" in record:
                raise ValueError("published_recovery_rejected")
        if record["binding_json"] != row[0]:
            raise ValueError("receipt_changed")
        try:
            os.stat(invocation + ".creator", dir_fd=spool, follow_symlinks=False)
            has_creator = True
        except FileNotFoundError:
            has_creator = False
        if has_creator or "creator_json" in record or "creator_sha256" in record:
            creator = read_at(spool, invocation + ".creator", 4096)
            if record["creator_json"].encode("utf-8") != creator or record["creator_sha256"] != sha(creator) or json.loads(creator)["binding_sha256"] != sha(row[0].encode("utf-8")):
                raise ValueError("creator_receipt_changed")
        try:
            os.stat(invocation + ".terminal", dir_fd=spool, follow_symlinks=False)
            has_terminal = True
        except FileNotFoundError:
            has_terminal = False
        try:
            os.stat(invocation + ".cleanup", dir_fd=spool, follow_symlinks=False)
            has_cleanup = True
        except FileNotFoundError:
            has_cleanup = False
        if has_terminal or has_cleanup or "cleanup" in record:
            cleanup = json.loads(read_at(spool, invocation + ".cleanup", 16384))
            terminal = json.loads(read_at(spool, invocation + ".terminal", 4_194_304))
            if record["cleanup"] != cleanup or {key: value for key, value in record.items() if key not in {"cleanup", "recovery"}} != terminal:
                raise ValueError("cleanup_receipt_changed")
        return encoded
    finally:
        os.close(spool)


def complete_artifacts(spool, invocation):
    # Both terminal artifacts are published only after the producer reaps its owned helper.
    artifacts = {}
    for name, limit in (("creator", 4096), ("terminal", 4_194_304), ("cleanup", 16384)):
        artifacts[name] = read_at(spool, invocation + "." + name, limit)
    record = json.loads(artifacts["terminal"])
    fields = {"version", "binding_json", "pid", "termination", "output_base64", "creator_json", "creator_sha256"}
    if set(record) != fields or record["creator_json"].encode("utf-8") != artifacts["creator"] or record["creator_sha256"] != sha(artifacts["creator"]):
        raise ValueError("complete_artifacts_rejected")
    record["cleanup"] = json.loads(artifacts["cleanup"])
    record["recovery"] = {"kind": "COMPLETE_ARTIFACTS"}
    return record


def execute(database, invocation, envelope):
    if len(invocation) != 64 or any(char not in "0123456789abcdef" for char in invocation):
        raise ValueError("invocation_rejected")
    if set(envelope) != {"binding_json", "input"}:
        raise ValueError("envelope_rejected")
    raw = envelope["input"].encode("utf-8")
    if len(raw) > MAX_FRAME:
        raise ValueError("input_too_large")
    uri = "file:" + urllib.parse.quote(database, safe="/") + "?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        connection.row_factory = sqlite3.Row
        binding, helper, _ = committed(connection, database, invocation, envelope["binding_json"], raw)
    spool = open_spool(binding)
    try:
        claim = invocation + ".claim"
        receipt = invocation + ".receipt"
        try:
            descriptor = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=spool)
        except FileExistsError:
            try:
                return read_at(spool, receipt, 4_194_304)
            except FileNotFoundError:
                return b'{"status":"pending"}'
        try:
            data = envelope["binding_json"].encode("utf-8")
            offset = 0
            while offset < len(data):
                offset += os.write(descriptor, data[offset:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.fsync(spool)
        return execute_claimed(database, invocation, envelope, binding, helper, raw, spool, receipt)
    finally:
        os.close(spool)


def execute_claimed(database, invocation, envelope, binding, helper, raw, spool, receipt):
    uri = "file:" + urllib.parse.quote(database, safe="/") + "?mode=rw"
    source_started = False
    try:
        with sqlite3.connect(uri, uri=True, timeout=2) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute("BEGIN IMMEDIATE")
            _, _, access = committed(connection, database, invocation, envelope["binding_json"], raw)
            current_authorization(connection, binding, access)
            signal.alarm(0)
            source_started = True
            pid, termination, output, creator = child_result(helper, binding, raw, spool, envelope["binding_json"])
            signal.alarm(5)
            record = {"version": 1, "binding_json": envelope["binding_json"], "pid": pid,
                      "termination": termination, "output_base64": base64.b64encode(output).decode("ascii")}
            if creator is not None:
                record.update({"creator_json": creator, "creator_sha256": sha(creator.encode("utf-8"))})
                terminal = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                publish(spool, invocation + ".terminal", terminal)
                current_authorization(connection, binding, access)
                record["cleanup"] = cleanup_temporary(helper, binding, envelope["binding_json"], creator, pid, spool)
            encoded = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            publish(spool, receipt, encoded)
            return encoded
    except (sqlite3.Error, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        if source_started:
            raise
        reason = "database_busy" if isinstance(error, sqlite3.OperationalError) else "authorization_changed"
        record = {"version": 1, "binding_json": envelope["binding_json"], "disposition": "NO_SPAWN",
                  "companion_pid": os.getpid(), "reason": reason}
        encoded = json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        publish(spool, receipt, encoded)
        return encoded


def read_frame():
    size_bytes = sys.stdin.buffer.read(4)
    if len(size_bytes) != 4:
        raise ValueError("frame_rejected")
    size = int.from_bytes(size_bytes, "big")
    if not 1 <= size <= 4_194_304:
        raise ValueError("frame_rejected")
    data = sys.stdin.buffer.read(size)
    if len(data) != size:
        raise ValueError("frame_rejected")
    return json.loads(data.decode("utf-8"))


def main():
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(5)
    if len(sys.argv) == 2 and sys.argv[1] == "--spool":
        request = read_frame()
        try:
            result = spool_state(request["path"], request["sources"], request["create"])
        except (OSError, ValueError, TypeError, KeyError) as error:
            result = {"version": 1, "error": str(error)}
        sys.stdout.write(json.dumps(result, separators=(",", ":")))
        return
    if len(sys.argv) == 4 and sys.argv[1] == "--status":
        encoded = read_receipt(sys.argv[2], sys.argv[3])
        sys.stdout.buffer.write(len(encoded).to_bytes(4, "big") + encoded)
        sys.stdout.buffer.flush()
        return
    database, invocation = sys.argv[1:]
    envelope = read_frame()
    encoded = execute(database, invocation, envelope)
    # Receipt publication precedes stdout: a dead controller may have closed this pipe.
    try:
        sys.stdout.buffer.write(len(encoded).to_bytes(4, "big") + encoded)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, sqlite3.Error, subprocess.SubprocessError):
        sys.exit(65)
