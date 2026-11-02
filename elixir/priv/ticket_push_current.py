"""Current-candidate push; receipt version 2 is data, not executable history."""
import contextlib
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import select
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.parse

GIT = "/Library/Developer/CommandLineTools/usr/bin/git"
LIMIT = 262_144
RECEIPT_LIMIT = 1_048_576
RUN_FIELDS = "run_id issue_key state repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round code_repair_round".split()
QUIET_QUERIES = (
    "SELECT reservation_key FROM workspace_access WHERE run_id=? AND mode='SOURCE' AND released_at IS NULL LIMIT 1",
    "SELECT op.call_id FROM worker_file_operations op JOIN worker_evidence worker ON worker.request_key=op.request_key WHERE worker.run_id=? AND (op.phase='PREPARED' OR op.io_pending=1) LIMIT 1",
    "SELECT check_row.check_key FROM controller_checks check_row JOIN worker_evidence worker ON worker.request_key=check_row.worker_request_key WHERE worker.run_id=? AND check_row.phase!='COMPLETE' LIMIT 1",
    "SELECT i.intent_key FROM ticket_ci_generation_intents i WHERE i.run_id=? AND NOT EXISTS(SELECT 1 FROM ticket_ci_generation_events e WHERE e.intent_key=i.intent_key AND e.event_type='FINALIZED' AND e.path='') LIMIT 1",
    "SELECT i.intent_key FROM ticket_ordinary_generation_intents i WHERE i.run_id=? AND NOT EXISTS(SELECT 1 FROM ticket_ordinary_generation_events e WHERE e.intent_key=i.intent_key AND e.event_type='FINALIZED' AND e.path='') LIMIT 1",
    "SELECT command_key FROM ticket_chat_commands WHERE run_id=? AND status IN ('PENDING','ACCEPTED') LIMIT 1",
    "SELECT question_key FROM ticket_chat_questions WHERE run_id=? AND status='OPEN' LIMIT 1",
    "SELECT command_key FROM ticket_contract_amendments WHERE run_id=? AND active_owner=1 LIMIT 1",
)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def read_bytes(size):
    raw = bytearray()
    while len(raw) < size:
        chunk = os.read(sys.stdin.fileno(), size - len(raw))
        require(bool(chunk), "frame_rejected")
        raw.extend(chunk)
    return bytes(raw)


def packet():
    size = int.from_bytes(read_bytes(4), "big")
    require(0 < size <= LIMIT, "frame_rejected")
    value = json.loads(read_bytes(size))
    if select.select([sys.stdin.fileno()], [], [], 0)[0]:
        require(not os.read(sys.stdin.fileno(), 1), "frame_rejected")
    require(set(value) == {"execution_json", "helper_pid"}, "packet_rejected")
    require(type(value["execution_json"]) is str and type(value["helper_pid"]) is int and value["helper_pid"] > 0, "packet_rejected")
    return value


def companion(execution, issuance):
    path = pathlib.Path(__file__).resolve().with_name("worker_file_companion.py")
    raw = path.read_bytes()
    if issuance:
        require(str(path) == execution["companion_path"] and sha(raw) == execution["companion_sha256"], "program_changed")
        require(sha(pathlib.Path(__file__).read_bytes()) == execution["helper_sha256"], "program_changed")
    spec = importlib.util.spec_from_file_location("push_companion", path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), "exec", dont_inherit=True, optimize=0), module.__dict__)
    return module


def arguments(root, args):
    return [GIT, "--no-lazy-fetch", "--no-replace-objects", "-C", root, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "gc.auto=0", "-c", "remote.origin.mirror=false", "-c", "push.followTags=false", "-c", "push.recurseSubmodules=no", "-c", "remote.origin.tagOpt=--no-tags"] + args


def read_git(root, args, execution):
    result = subprocess.run(arguments(root, args), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3, check=True)
    require(len(result.stdout) <= 16_384, "output_rejected")
    return result.stdout.decode().strip()


def physical_checkout(binding, execution, module):
    checkout = binding["checkout"]
    root = binding["worktree"]
    require(re.fullmatch("[0-9a-f]{40}", binding["candidate_sha"]), "candidate_changed")
    descriptor = module.directory(root)
    try:
        require(module.identity(descriptor) == (checkout["root_device"], checkout["root_inode"]), "checkout_changed")
    finally:
        os.close(descriptor)
    require(os.path.realpath(root) == root == checkout["path"], "checkout_changed")
    require(read_git(root, ["rev-parse", "HEAD"], execution) == binding["candidate_sha"], "candidate_changed")
    require(read_git(root, ["branch", "--show-current"], execution) == binding["branch"], "branch_changed")
    require(not read_git(root, ["status", "--porcelain", "--untracked-files=all"], execution), "dirty_checkout")
    require(binding["branch"] not in ("main", "master", binding["base_branch"]), "protected_branch")
    require(read_git(root, ["check-ref-format", "--branch", binding["branch"]], execution) == binding["branch"], "branch_changed")
    git_dir = os.path.realpath(read_git(root, ["rev-parse", "--absolute-git-dir"], execution))
    common = os.path.realpath(os.path.join(root, read_git(root, ["rev-parse", "--git-common-dir"], execution)))
    repo_common = os.path.realpath(os.path.join(binding["repo_path"], read_git(binding["repo_path"], ["rev-parse", "--git-common-dir"], execution)))
    require((git_dir, common, repo_common) == (checkout["git_dir"], checkout["common_dir"], checkout["common_dir"]), "repository_changed")
    for path, args in ((root, ["remote", "get-url", "--push", "--all", "origin"]), (binding["repo_path"], ["remote", "get-url", "--all", "origin"])):
        urls = read_git(path, args, execution).splitlines()
        require(len(urls) == 1 and sha(urls[0].encode()) == binding["origin"]["destination_sha256"], "origin_changed")


def fingerprint(connection, table, key, expected):
    row = connection.execute("SELECT * FROM " + table + " WHERE " + key + "=?", (expected[key],)).fetchone()
    require(row is not None and all(row[name] == value for name, value in expected.items()), "acceptance_changed")
    return row


def current_acceptance(connection, binding):
    proof = binding["verifier"]
    if binding["ci_preflight"]:
        require(proof is None and binding["state"] == "CI_PUSHING", "preflight_changed")
        return
    require(binding["state"] == "PUSHING" and isinstance(proof, dict), "acceptance_changed")
    worker = fingerprint(connection, "worker_evidence", "request_key", proof["evidence"])
    task = fingerprint(connection, "factory_tasks", "task_key", proof["task"])
    require(worker["status"] == task["status"] == "CONSUMED", "acceptance_changed")
    require(worker["owner_stopped_at"] and worker["owner_stop_json"] and worker["consumed_at"], "acceptance_changed")
    require(task["output_json"] == worker["output_json"] and sha(worker["output_json"].encode()) == worker["output_sha256"], "acceptance_changed")
    require(sha(worker["binding_json"].encode()) == worker["binding_sha256"], "acceptance_changed")
    output = json.loads(worker["output_json"])
    require((output.get("status"), output.get("candidate_sha")) == ("PASS", binding["candidate_sha"]), "acceptance_changed")


def launch(value, execution, module, spool, owned):
    binding = json.loads(execution["intent_json"])
    require(binding["publication_version"] == execution["publication_version"] == 2, "version_rejected")
    require(value["helper_pid"] == os.getpid() and sha(execution["intent_json"].encode()) == execution["intent_sha256"], "execution_changed")
    require(sha(pathlib.Path(GIT).read_bytes()) == execution["program_sha256"], "program_changed")
    physical_checkout(binding, execution, module)
    uri = "file:" + urllib.parse.quote(execution["database"], safe="/") + "?mode=rw"
    with sqlite3.connect(uri, uri=True, timeout=3) as connection:
        connection.row_factory = sqlite3.Row
        # No controller can insert a hold between the final check and child creation.
        connection.execute("BEGIN IMMEDIATE")
        run = connection.execute("SELECT * FROM runs WHERE run_id=?", (execution["run_id"],)).fetchone()
        require(run is not None and all(run[name] == binding[name] for name in RUN_FIELDS), "run_changed")
        require((run["execution_mode"], run["kind"], run["manual_validation_required"]) == ("TICKET_SUPERVISOR_V1", "DELIVERY", 0), "route_changed")
        intent = json.loads(run["candidate_handoff"])
        require((intent["phase"], intent["binding_json"], intent["binding_sha256"], intent["owner_nonce"], intent["helper_pid"], intent["execution_json"]) == ("PUSH_UNCERTAIN", execution["intent_json"], execution["intent_sha256"], execution["invocation"], os.getpid(), value["execution_json"]), "claim_changed")
        access = connection.execute("SELECT * FROM workspace_access WHERE reservation_key=?", (intent["reservation_key"],)).fetchone()
        require(access is not None and (access["run_id"], access["mode"], access["generation"], access["released_at"], access["task_key"], access["request_key"]) == (execution["run_id"], "MAINTENANCE", intent["reservation_generation"], None, None, intent["reservation_key"]), "reservation_changed")
        saved = json.loads(access["binding_json"])
        checkout = binding["checkout"]
        require((access["canonical_path"], access["git_dir"], access["common_dir"]) == (checkout["path"], checkout["git_dir"], checkout["common_dir"]), "reservation_changed")
        require(all(saved[name] == checkout[name] for name in ("root_device", "root_inode")) and saved["expected_sha"] == binding["candidate_sha"], "reservation_changed")
        current_acceptance(connection, binding)
        source = fingerprint(connection, "worker_evidence", "request_key", binding["source_owner"])
        require(source["status"] == "CONSUMED" and source["owner_stopped_at"] and source["owner_stop_json"] and source["consumed_at"], "source_owner_changed")
        require(all(connection.execute(sql, (execution["run_id"],)).fetchone() is None for sql in QUIET_QUERIES), "durable_hold")
        controls = [list(row) for row in connection.execute("SELECT scope,status,dispatcher_id,generation FROM control WHERE scope=?", (binding["controller_scope"],))]
        retained = [list(row) for row in connection.execute("SELECT request_key,status,binding_sha256,output_sha256,owner_stopped_at,owner_stop_json FROM worker_evidence WHERE run_id=? AND status!='CONSUMED' ORDER BY request_key", (execution["run_id"],))]
        require(len(controls) == 1 and controls[0][1] == "ACTIVE" and controls == execution["action_facts"]["controls"], "controller_changed")
        require(retained == execution["action_facts"]["retained_noncurrent_attempts"], "source_owner_changed")
        observed = datetime.datetime.fromisoformat(execution["authorization"]["observed_at"].replace("Z", "+00:00"))
        require(-5 <= (datetime.datetime.now(datetime.timezone.utc) - observed).total_seconds() <= 60, "authorization_expired")
        require(not owned["stopped"], "caller_stopped")
        require(not select.select([sys.stdin.fileno()], [], [], 0)[0], "caller_stopped")
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGHUP, signal.SIGTERM, signal.SIGINT})
        try:
            module.publish(spool, execution["invocation"] + ".current-issued", value["execution_json"].encode())
            owned["issuance_started"] = True
            child = subprocess.Popen(arguments(binding["worktree"], ["push", "--no-verify", "origin", binding["candidate_sha"] + ":refs/heads/" + binding["branch"]]), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
            owned["child"] = child
            os.set_blocking(child.stderr.fileno(), False)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        connection.commit()
        return child


def execute(value, execution, module, spool):
    owned = {"child": None, "stopped": False, "issuance_started": False}
    stderr = bytearray()
    overflow = False

    def stop(_signal=None, _frame=None):
        owned["stopped"] = True
        if owned["child"] is not None:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(owned["child"].pid, signal.SIGKILL)

    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, stop)

    module.publish(spool, execution["invocation"] + ".current-claim", value["execution_json"].encode())
    receipt = {"version": 2, "kind": "TICKET_PUSH_CURRENT", "execution_json": value["execution_json"], "execution_sha256": sha(value["execution_json"].encode()), "helper_pid": os.getpid(), "child_pid": None, "outcome": "NOT_STARTED", "termination": None, "reason": None, "timed_out": False, "overflow": False, "stderr_bytes": 0, "stderr_sha256": sha(b"")}
    try:
        child = launch(value, execution, module, spool, owned)
        deadline = time.monotonic() + 300
        with contextlib.closing(select.kqueue()) as events:
            try:
                exited = bool(events.control([select.kevent(child.pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 1, 0))
            except ProcessLookupError:
                exited = True
            while not exited:
                try:
                    chunk = os.read(child.stderr.fileno(), 4096)
                    if len(stderr) + len(chunk) > 16_384:
                        overflow = True
                    stderr.extend(chunk[:max(0, 16_384 - len(stderr))])
                except BlockingIOError:
                    pass
                if owned["stopped"] or overflow or time.monotonic() >= deadline or (select.select([sys.stdin], [], [], 0)[0] and not os.read(sys.stdin.fileno(), 1)):
                    stop()
                    break
                exited = bool(events.control([], 1, 0.1))
        # Keep the leader unreaped until its entire owned process group is cleaned up.
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(child.pid, signal.SIGKILL)
        code = child.wait(timeout=3)
        child.stderr.close()
        owned["child"] = None
        receipt.update(outcome="ISSUED", child_pid=child.pid, termination={"kind": "exited", "code": code} if code >= 0 else {"kind": "signaled", "signal": -code}, timed_out=owned["stopped"], overflow=overflow, stderr_bytes=len(stderr), stderr_sha256=sha(bytes(stderr)))
    except Exception as error:
        if owned["issuance_started"]:
            raise
        receipt["reason"] = str(error)[:160]
    finally:
        if owned["child"] is not None:
            stop()
            owned["child"].wait(timeout=3)
    raw = json.dumps(receipt, separators=(",", ":")).encode()
    module.publish(spool, execution["invocation"] + ".current-terminal", raw)
    return raw


def readback(value, execution, module, spool):
    require(module.read_at(spool, execution["invocation"] + ".current-claim", LIMIT) == value["execution_json"].encode(), "claim_changed")
    raw = module.read_at(spool, execution["invocation"] + ".current-terminal", RECEIPT_LIMIT)
    receipt = json.loads(raw)
    require((receipt.get("version"), receipt.get("kind"), receipt.get("execution_json"), receipt.get("execution_sha256"), receipt.get("helper_pid")) == (2, "TICKET_PUSH_CURRENT", value["execution_json"], sha(value["execution_json"].encode()), value["helper_pid"]), "receipt_changed")
    require(receipt["outcome"] in ("ISSUED", "NOT_STARTED"), "receipt_changed")
    if receipt["outcome"] == "ISSUED":
        require(module.read_at(spool, execution["invocation"] + ".current-issued", LIMIT) == value["execution_json"].encode(), "issuance_changed")
    else:
        try:
            module.read_at(spool, execution["invocation"] + ".current-issued", LIMIT)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("nonissuance_changed")
    return raw


def fence_observation(value, execution, module, spool):
    try:
        os.stat(execution["invocation"] + ".current-issued", dir_fd=spool, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise ValueError("nonissuance_unproven")
    current = module.directory(execution["spool"])
    try:
        require(module.identity(current) == module.identity(spool), "spool_changed")
    finally:
        os.close(current)
    return json.dumps({"kind": "CURRENT_ISSUANCE_MARKER_ABSENT", "nonce": execution["invocation"], "execution_sha256": sha(value["execution_json"].encode()), "spool": {name: execution[name] for name in ("spool", "spool_device", "spool_inode")}}, separators=(",", ":")).encode()


def main():
    require(len(sys.argv) == 2 and sys.argv[1] in ("--execute", "--status", "--fence"), "mode_rejected")
    value = packet()
    execution = json.loads(value["execution_json"])
    require(execution["publication_version"] == 2 and re.fullmatch("[0-9a-f]{64}", execution["invocation"]), "version_rejected")
    module = companion(execution, sys.argv[1] == "--execute")
    spool = module.open_spool(execution)
    try:
        action = {"--execute": execute, "--status": readback, "--fence": fence_observation}[sys.argv[1]]
        raw = action(value, execution, module, spool)
        sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
        sys.stdout.buffer.flush()
    finally:
        os.close(spool)


if __name__ == "__main__":
    main()
