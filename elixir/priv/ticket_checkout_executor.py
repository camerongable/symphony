"""One committed checkout claim; fixed confined Git and durable waitpid receipt."""
import base64
import datetime
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
LIMIT = 262_144
READ_PROFILE = '(version 1)(deny default)(allow process-fork)(allow process-exec (literal "' + GIT + '"))(allow file-read*)(allow file-write* (literal "/dev/null"))(allow sysctl-read)(allow mach-lookup)'
ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def companion(execution):
    path = pathlib.Path(__file__).resolve().with_name("worker_file_companion.py")
    if str(path) != execution["companion_path"] or sha(path.read_bytes()) != execution["companion_sha256"] or sha(pathlib.Path(__file__).read_bytes()) != execution["helper_sha256"]:
        raise ValueError("program_changed")
    spec = importlib.util.spec_from_file_location("checkout_companion", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_packet():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        raise ValueError("frame_rejected")
    size = int.from_bytes(header, "big")
    if not 0 < size <= LIMIT:
        raise ValueError("frame_rejected")
    raw = sys.stdin.buffer.read(size)
    if len(raw) != size:
        raise ValueError("frame_rejected")
    packet = json.loads(raw)
    if set(packet) != {"execution_json", "helper_pid"}:
        raise ValueError("packet_rejected")
    return packet


def command(repo, arguments, profile):
    return ["/usr/bin/sandbox-exec", "-p", profile, GIT, "--no-lazy-fetch", "--no-replace-objects", "-C", repo, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments


def read_git(repo, arguments):
    result = subprocess.run(command(repo, arguments, READ_PROFILE), env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3, check=True)
    if len(result.stdout) > 16_384:
        raise ValueError("git_output_rejected")
    return result.stdout.decode().strip()


def check_identity(module, path, device, inode):
    descriptor = module.directory(path)
    try:
        if module.identity(descriptor) != (device, inode):
            raise ValueError("directory_changed")
    finally:
        os.close(descriptor)


def authorize(packet, execution, intent, module, spool):
    if packet["helper_pid"] != os.getpid() or sha(intent_raw := execution["intent_json"].encode()) != execution["intent_sha256"] or sha(pathlib.Path(GIT).read_bytes()) != execution["program_sha256"]:
        raise ValueError("execution_changed")
    check_identity(module, intent["repo_path"], intent["repo_device"], intent["repo_inode"])
    check_identity(module, intent["workspace_root"], intent["root_device"], intent["root_inode"])
    identity = intent["repository_identity"]
    check_identity(module, identity["common_path"], identity["common_device"], identity["common_inode"])
    if os.path.realpath(os.path.join(intent["repo_path"], read_git(intent["repo_path"], ["rev-parse", "--git-common-dir"]))) != identity["common_path"]:
        raise ValueError("repository_changed")
    branch = intent["run"]["branch"]
    if branch in ("main", "master", intent["run"]["base_branch"]) or read_git(intent["repo_path"], ["check-ref-format", "--branch", branch]) != branch:
        raise ValueError("branch_rejected")
    if read_git(intent["repo_path"], ["cat-file", "-t", intent["base_sha"]]) != "commit" or os.path.lexists(intent["path"]):
        raise ValueError("target_rejected")
    uri = "file:" + urllib.parse.quote(execution["database"], safe="/") + "?mode=rw"
    with sqlite3.connect(uri, uri=True, timeout=3) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute("BEGIN IMMEDIATE")
        row = connection.execute("SELECT * FROM ticket_checkout_intents WHERE run_id = ?", (execution["run_id"],)).fetchone()
        if row is None or (row["binding_json"], row["binding_sha256"], row["owner_nonce"], row["helper_pid"], row["execution_json"], row["phase"]) != (intent_raw.decode(), execution["intent_sha256"], execution["invocation"], os.getpid(), packet["execution_json"], "MUTATING_UNCERTAIN"):
            raise ValueError("claim_not_committed")
        run = connection.execute("SELECT * FROM runs WHERE run_id = ?", (execution["run_id"],)).fetchone()
        if run is None or any(run[key] != value for key, value in intent["run"].items()) or run["state"] != "ADMITTING_WRITER" or run["worktree"] is not None or run["candidate_sha"] is not None:
            raise ValueError("run_changed")
        parent = connection.execute("SELECT c.* FROM ticket_chats c JOIN ticket_chat_runs r ON r.chat_key = c.chat_key WHERE r.run_id = ?", (execution["run_id"],)).fetchone()
        if parent is None or any(parent[key] != value for key, value in intent["parent"].items()):
            raise ValueError("parent_changed")
        bootstrap = connection.execute("SELECT * FROM desktop_requests WHERE request_key = ?", (parent["create_request_key"],)).fetchone()
        if bootstrap is None or any(bootstrap[key] != value for key, value in intent["bootstrap"].items()):
            raise ValueError("bootstrap_changed")
        observed = datetime.datetime.fromisoformat(execution["authorization"]["observed_at"].replace("Z", "+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - observed).total_seconds()
        if not 0 <= age <= 60:
            raise ValueError("authorization_expired")
        if connection.execute("SELECT task_key FROM factory_tasks WHERE run_id = ? LIMIT 1", (execution["run_id"],)).fetchone() or connection.execute("SELECT reservation_key FROM workspace_access WHERE run_id = ? AND released_at IS NULL LIMIT 1", (execution["run_id"],)).fetchone():
            raise ValueError("source_owned")
        module.publish(spool, execution["invocation"] + ".checkout-claim", packet["execution_json"].encode())
        child = start_git(intent, module)
        try:
            connection.commit()
        except BaseException:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise
        return child


def start_git(intent, module):
    parent = os.path.dirname(intent["path"])
    if not parent.startswith(intent["workspace_root"] + "/"):
        raise ValueError("target_outside_root")
    descriptor = module.directory(intent["workspace_root"])
    try:
        if module.identity(descriptor) != (intent["root_device"], intent["root_inode"]):
            raise ValueError("root_changed")
        parts = os.path.relpath(parent, intent["workspace_root"]).split("/")
        for part in parts:
            if part in ("", ".", ".."):
                raise ValueError("parent_rejected")
            try:
                os.mkdir(part, 0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            child_directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child_directory
        observed = module.directory(parent)
        try:
            if module.identity(observed) != module.identity(descriptor):
                raise ValueError("parent_changed")
        finally:
            os.close(observed)
    finally:
        os.close(descriptor)
    profile = READ_PROFILE + '(allow file-write* (subpath (param "COMMON_ROOT")) (subpath (param "WRITER_PARENT")))'
    args = command(intent["repo_path"], ["worktree", "add", "-b", intent["run"]["branch"], "--", intent["path"], intent["base_sha"]], profile)
    args[1:1] = ["-D", "COMMON_ROOT=" + intent["repository_identity"]["common_path"], "-D", "WRITER_PARENT=" + parent]
    return subprocess.Popen(args, env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)


def execute(packet, execution, module, spool):
    intent = json.loads(execution["intent_json"])
    child = authorize(packet, execution, intent, module, spool)
    stopped = False

    def stop(_signum=None, _frame=None):
        nonlocal stopped
        stopped = True
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)

    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, stop)
    output = bytearray()
    overflow = False
    deadline = time.monotonic() + 25
    try:
        while True:
            if time.monotonic() >= deadline:
                stop()
                break
            if select.select([child.stdout], [], [], 0.1)[0]:
                chunk = os.read(child.stdout.fileno(), 65_536)
                if not chunk:
                    break
                room = 65_536 - len(output)
                output.extend(chunk[:room])
                if len(chunk) > room:
                    overflow = True
                    stop()
                    break
        code = child.wait(timeout=max(deadline - time.monotonic(), 1))
    finally:
        if child.poll() is None:
            stop()
            child.wait()
        child.stdout.close()
    termination = {"kind": "exited", "code": code} if code >= 0 else {"kind": "signaled", "signal": -code}
    receipt = {"version": 1, "execution_json": packet["execution_json"], "helper_pid": os.getpid(), "child_pid": child.pid, "termination": termination, "timed_out": stopped, "overflow": overflow, "output_base64": base64.b64encode(output).decode(), "output_sha256": sha(output)}
    raw = json.dumps(receipt, separators=(",", ":")).encode()
    module.publish(spool, execution["invocation"] + ".checkout-receipt", raw)
    return raw


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("--execute", "--status"):
        raise ValueError("mode_rejected")
    packet = read_packet()
    execution = json.loads(packet["execution_json"])
    nonce = execution["invocation"]
    if not isinstance(nonce, str) or len(nonce) != 64 or any(char not in "0123456789abcdef" for char in nonce):
        raise ValueError("nonce_rejected")
    module = companion(execution)
    spool = module.open_spool(execution)
    try:
        if sys.argv[1] == "--execute":
            raw = execute(packet, execution, module, spool)
        else:
            if module.read_at(spool, nonce + ".checkout-claim", LIMIT) != packet["execution_json"].encode():
                raise ValueError("claim_changed")
            raw = module.read_at(spool, nonce + ".checkout-receipt", LIMIT)
        sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
        sys.stdout.buffer.flush()
    finally:
        os.close(spool)


if __name__ == "__main__":
    main()
