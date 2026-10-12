"""Controller catalog only: no shell, candidate code, network, or source writes."""
import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import select
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.parse

GIT = "/Library/Developer/CommandLineTools/usr/bin/git"
PROFILE = '(version 1)(deny default)(allow process-exec (literal "/Library/Developer/CommandLineTools/usr/bin/git"))(allow file-read*)(allow file-write* (literal "/dev/null"))(allow sysctl-read)(allow mach-lookup)'
MAX_FRAME = 2_097_152
MAX_OUTPUT = 1_048_576


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read_input():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        raise ValueError("frame_rejected")
    size = int.from_bytes(header, "big")
    if not 0 < size <= MAX_FRAME:
        raise ValueError("frame_rejected")
    raw = sys.stdin.buffer.read(size)
    if len(raw) != size:
        raise ValueError("frame_rejected")
    packet = json.loads(raw)
    if set(packet) != {"binding_json", "helper_pid"}:
        raise ValueError("packet_rejected")
    return packet


def companion(binding):
    path = pathlib.Path(__file__).resolve().with_name("worker_file_companion.py")
    if str(path) != binding["companion_path"] or sha(path.read_bytes()) != binding["companion_sha256"]:
        raise ValueError("companion_changed")
    if sha(pathlib.Path(__file__).read_bytes()) != binding["helper_sha256"]:
        raise ValueError("helper_changed")
    spec = importlib.util.spec_from_file_location("controller_companion", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def authorize(connection, raw, binding, pid):
    row = connection.execute("SELECT * FROM controller_checks WHERE check_key = ?", (binding["check_key"],)).fetchone()
    if row is None or (row["binding_json"], row["binding_sha256"], row["phase"], row["helper_pid"]) != (raw, sha(raw.encode()), "RUNNING", pid):
        raise ValueError("check_not_committed")
    access = connection.execute("SELECT * FROM workspace_access WHERE reservation_key = ?", (binding["reservation_key"],)).fetchone()
    worker = connection.execute("SELECT * FROM worker_evidence WHERE request_key = ?", (binding["worker_request_key"],)).fetchone()
    run = connection.execute("SELECT * FROM runs WHERE run_id = ?", (binding["run_id"],)).fetchone()
    if access is None or worker is None or run is None:
        raise ValueError("authorization_missing")
    if access["released_at"] is not None or access["generation"] != binding["generation"] or access["canonical_path"] != binding["cwd"] or sha(access["binding_json"].encode()) != binding["workspace_binding_sha256"]:
        raise ValueError("reservation_changed")
    if worker["status"] != "RESULT_RECORDED" or worker["owner_stopped_at"] is None:
        raise ValueError("worker_not_stopped")
    for field, expected in (("binding_json", "worker_binding_sha256"), ("output_json", "worker_output_sha256"), ("owner_stop_json", "worker_stop_sha256")):
        if sha(worker[field].encode()) != binding[expected]:
            raise ValueError("worker_changed")
    captured = json.loads(worker["binding_json"])
    task = connection.execute("SELECT * FROM factory_tasks WHERE task_key = ?", (worker["task_key"],)).fetchone()
    if task is None or any(task[field] != captured[field] for field in ("role", "stage", "model", "reasoning_effort", "prompt_sha256")):
        raise ValueError("worker_inputs_changed")
    if any(run[field] != binding[field] for field in ("candidate_sha", "spec_revision", "contract_sha256")):
        raise ValueError("candidate_changed")
    pending = connection.execute("SELECT call_id FROM worker_file_operations WHERE request_key = ? AND (phase = 'PREPARED' OR io_pending = 1)", (binding["worker_request_key"],)).fetchone()
    if pending is not None:
        raise ValueError("file_operations_pending")


def execute(packet, binding, module, spool):
    pid = packet["helper_pid"]
    if pid != os.getpid():
        raise ValueError("producer_pid_changed")
    if binding["action"] != "git-diff-check" or binding["program"] != GIT or sha(pathlib.Path(GIT).read_bytes()) != binding["program_sha256"] or sha(PROFILE.encode()) != binding["profile_sha256"]:
        raise ValueError("catalog_changed")
    for field in ("base_sha", "candidate_sha"):
        value = binding[field]
        if not isinstance(value, str) or len(value) != 40 or any(char not in "0123456789abcdef" for char in value):
            raise ValueError("candidate_rejected")
    source = module.directory(binding["cwd"])
    try:
        if module.identity(source) != (binding["root_device"], binding["root_inode"]):
            raise ValueError("source_changed")
        os.fchdir(source)
        if os.getcwd() != binding["cwd"]:
            raise ValueError("execution_directory_changed")
    finally:
        os.close(source)
    uri = "file:" + urllib.parse.quote(binding["database"], safe="/") + "?mode=rw"
    with sqlite3.connect(uri, uri=True, timeout=3) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute("BEGIN IMMEDIATE")
        authorize(connection, packet["binding_json"], binding, pid)
        module.publish(spool, binding["invocation"] + ".check-claim", packet["binding_json"].encode())
        connection.commit()
    environment = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"}
    arguments = ["/usr/bin/sandbox-exec", "-p", PROFILE, GIT, "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "diff", "--check", "--no-ext-diff", "--no-textconv", binding["base_sha"] + "^{commit}", binding["candidate_sha"] + "^{commit}", "--"]
    child = subprocess.Popen(arguments, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    deadline = time.monotonic() + 20
    timed_out = overflow = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                child.kill()
                break
            if select.select([child.stdout], [], [], min(remaining, 0.1))[0]:
                data = os.read(child.stdout.fileno(), 65_536)
                if not data:
                    break
                room = MAX_OUTPUT - len(output)
                output.extend(data[:room])
                if len(data) > room:
                    overflow = True
                    child.kill()
                    break
        code = child.wait(timeout=max(deadline - time.monotonic(), 1))
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        child.stdout.close()
    terminal = {"kind": "exited", "code": code} if code >= 0 else {"kind": "signaled", "signal": -code}
    receipt = {"version": 1, "binding_json": packet["binding_json"], "helper_pid": pid, "pid": child.pid, "cwd": binding["cwd"], "base_sha": binding["base_sha"], "candidate_sha": binding["candidate_sha"], "termination": terminal, "result": "PASS" if code == 0 and not timed_out and not overflow else "FAIL", "output_base64": base64.b64encode(output).decode(), "output_sha256": sha(output), "timed_out": timed_out, "overflow": overflow}
    raw = json.dumps(receipt, separators=(",", ":")).encode()
    module.publish(spool, binding["invocation"] + ".check-receipt", raw)
    return raw


def main():
    signal.alarm(28)
    if len(sys.argv) != 2 or sys.argv[1] not in ("--execute", "--status"):
        raise ValueError("mode_rejected")
    packet = read_input()
    binding = json.loads(packet["binding_json"])
    nonce = binding["invocation"]
    if not isinstance(nonce, str) or len(nonce) != 64 or any(char not in "0123456789abcdef" for char in nonce):
        raise ValueError("invocation_rejected")
    module = companion(binding)
    spool = module.open_spool(binding)
    try:
        if sys.argv[1] == "--execute":
            raw = execute(packet, binding, module, spool)
        else:
            if module.read_at(spool, nonce + ".check-claim", MAX_FRAME) != packet["binding_json"].encode():
                raise ValueError("claim_changed")
            raw = module.read_at(spool, nonce + ".check-receipt", MAX_FRAME)
        sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
        sys.stdout.buffer.flush()
    finally:
        os.close(spool)


if __name__ == "__main__":
    main()
