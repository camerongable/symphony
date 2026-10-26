"""Exact same-candidate CAS reconciliation; the predecessor outcome remains unknown."""
import datetime
import contextlib
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
OLD_HELPER_SHA = "c0e98bd870546c62ec3797592183f2e242d2070d23dd6297dc0ca179bc47ab37"
DEADLINE = time.monotonic() + 30


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def companion(execution):
    path = pathlib.Path(__file__).resolve().with_name("worker_file_companion.py")
    if str(path) != execution["companion_path"] or sha(path.read_bytes()) != execution["companion_sha256"] or sha(pathlib.Path(__file__).read_bytes()) != execution["helper_sha256"]:
        raise ValueError("program_changed")
    spec = importlib.util.spec_from_file_location("push_companion", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def packet():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4 or not 0 < (size := int.from_bytes(header, "big")) <= LIMIT:
        raise ValueError("frame_rejected")
    raw = sys.stdin.buffer.read(size)
    if len(raw) != size:
        raise ValueError("frame_rejected")
    value = json.loads(raw)
    if set(value) != {"execution_json", "helper_pid"}:
        raise ValueError("packet_rejected")
    return value


def arguments(root, args):
    return [GIT, "--no-lazy-fetch", "--no-replace-objects", "-C", root, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "gc.auto=0", "-c", "push.followTags=false", "-c", "remote.origin.mirror=false", "-c", "push.recurseSubmodules=no", "-c", "push.default=nothing"] + args


def read_git(root, args, execution):
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise ValueError("authorization_deadline")
    result = subprocess.run(arguments(root, args), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=min(3, remaining), check=True)
    if len(result.stdout) > 16_384:
        raise ValueError("output_rejected")
    return result.stdout.decode().strip()


def worker_history(connection, execution):
    proof = execution["worker_history"]
    run_id = execution["run_id"]
    queries = {
        "workers": ("SELECT * FROM worker_evidence WHERE run_id = ? ORDER BY request_key",),
        "tasks": ("SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY task_key",),
        "accesses": ("SELECT * FROM workspace_access WHERE run_id = ? ORDER BY reservation_key",),
        "events": ("SELECT * FROM events WHERE run_id = ? AND event_type IN ('TICKET_FAILED_TURN_RECOVERY_AUTHORIZED', 'TICKET_FAILED_TURN_RECOVERY_APPLIED', 'TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED', 'TICKET_INFRASTRUCTURE_RECOVERY_APPLIED') ORDER BY id",),
        "commands": ("SELECT * FROM ticket_chat_commands WHERE run_id = ? ORDER BY command_key",),
    }
    observed = {}
    digest_fields = {"workers": ("binding_json", "output_json", "policy_json"), "tasks": ("output_json",), "accesses": ("binding_json", "release_receipt_json"), "events": ("payload_json",), "commands": ("binding_json", "payload_json", "receipt_json", "application_receipt_json")}
    for name, (query,) in queries.items():
        actual = [dict(row) for row in connection.execute(query, (run_id,))]
        compact = [{key: sha(value.encode()) if key in digest_fields[name] and isinstance(value, str) else value for key, value in row.items()} for row in actual]
        if compact != json.loads(proof[name + "_json"]):
            raise ValueError("worker_history_changed")
        observed[name] = actual
    workers = {row["request_key"]: row for row in observed["workers"]}
    accesses = {row["reservation_key"]: row for row in observed["accesses"]}
    commands = {row["command_key"]: row for row in observed["commands"]}
    events = [(row["event_type"], json.loads(row["payload_json"])) for row in observed["events"]]

    def stopped(worker):
        access = accesses.get(worker["reservation_key"])
        stop = json.loads(worker["owner_stop_json"] or "null")
        process = json.loads(worker["owner_process_json"] or "null")
        return (access is not None and worker["owner_stopped_at"] is not None and isinstance(stop, dict)
                and set(stop) == {"transport", "thread_id", "pid", "invocation_nonce", "exit_status", "cwd"}
                and (stop["transport"], stop["thread_id"], stop["cwd"]) == ("owned_app_server", worker["thread_id"], access["canonical_path"])
                and isinstance(stop["exit_status"], int) and isinstance(stop["pid"], str) and stop["pid"]
                and isinstance(stop["invocation_nonce"], str) and len(stop["invocation_nonce"]) == 64
                and all(char in "0123456789abcdef" for char in stop["invocation_nonce"])
                and process == {"pid": stop["pid"], "invocation_nonce": stop["invocation_nonce"]})

    edges = {}
    for key, worker in workers.items():
        keys = proof["worker_key_order"]
        if set(keys) != set(worker) or len(keys) != len(worker):
            raise ValueError("worker_history_encoding_unproven")
        encoded_worker = json.dumps({name: worker[name] for name in keys}, separators=(",", ":"), ensure_ascii=False).encode()
        access = accesses.get(worker["reservation_key"])
        if access is None or access["released_at"] is None:
            raise ValueError("worker_history_source_unreleased")
        if worker["status"] == "CONSUMED":
            if not stopped(worker):
                raise ValueError("worker_history_stop_unproven")
            continue
        transfer = json.loads(access["release_receipt_json"] or "null")
        if not isinstance(transfer, dict) or transfer.get("old_request_key") != key:
            raise ValueError("worker_history_transfer_unproven")
        destination = workers.get(transfer.get("new_request_key"))
        new_access = accesses.get(destination["reservation_key"]) if destination else None
        if destination is None or new_access is None or (destination["run_id"], destination["task_key"]) != (worker["run_id"], worker["task_key"]) or new_access["generation"] <= access["generation"] or new_access["canonical_path"] != access["canonical_path"]:
            raise ValueError("worker_history_lineage_unproven")
        if transfer.get("kind") in ("FAILED_TURN_QUIESCENCE", "INTERRUPTED_TURN_QUIESCENCE"):
            applied = next((payload for kind, payload in events if kind == "TICKET_FAILED_TURN_RECOVERY_APPLIED" and payload.get("old_request_key") == key), None)
            authorized = next((payload for kind, payload in events if kind == "TICKET_FAILED_TURN_RECOVERY_AUTHORIZED" and applied and payload.get("recovery_key") == applied.get("recovery_key")), None)
            fields = ("kind", "recovery_key", "old_request_key", "new_request_key", "new_reservation_key")
            if applied is None or authorized != {name: val for name, val in applied.items() if name not in ("new_generation", "new_binding_sha256")} or sha(encoded_worker) != applied["old_evidence_sha256"] or transfer != {name: applied[name] for name in fields} or applied["new_binding_sha256"] != sha(destination["binding_json"].encode()) or applied["new_generation"] != new_access["generation"]:
                raise ValueError("worker_history_failed_transfer_unproven")
        elif transfer.get("kind") == "BLOCKED_SOURCE_TRANSFER":
            command = commands.get(transfer.get("command_key"))
            if command is not None:
                application = json.loads(command["application_receipt_json"] or "null")
            else:
                application = None
            if transfer.get("operational_recovery_key"):
                applied = next((payload for kind, payload in events if kind == "TICKET_INFRASTRUCTURE_RECOVERY_APPLIED" and payload.get("prior_request_key") == key), None)
                authorized = next((payload for kind, payload in events if kind == "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED" and applied and payload.get("recovery_key") == applied.get("recovery_key")), None)
                fields = ("kind", "old_request_key", "old_reservation_key", "new_request_key", "new_reservation_key", "disposition_key", "output_sha256", "checkout_head_sha", "operational_recovery_key")
                valid = (stopped(worker) and applied is not None and authorized is not None and all(transfer.get(name) == applied.get(name) for name in fields)
                         and transfer["operational_recovery_key"] == applied["recovery_key"] == authorized["recovery_key"]
                         and authorized["request_key"] == key and authorized["output_sha256"] == worker["output_sha256"] and authorized["binding_sha256"] == worker["binding_sha256"]
                         and new_access["generation"] == applied["new_generation"])
            else:
                valid = (stopped(worker) and command is not None and command["status"] == "APPLIED" and isinstance(application, dict)
                         and application.get("kind") == "BLOCKED_WRITER_RESUMED" and application.get("prior_request_key") == key
                         and application.get("request_key") == destination["request_key"] and application.get("reservation_key") == new_access["reservation_key"]
                         and transfer.get("old_reservation_key") == access["reservation_key"] and transfer.get("output_sha256") == worker["output_sha256"]
                         and transfer.get("input_key") == command["input_key"] and transfer.get("disposition_key") == application.get("disposition_key"))
            if not valid:
                raise ValueError("worker_history_blocked_transfer_unproven")
        else:
            raise ValueError("worker_history_transfer_kind_unproven")
        edges[key] = destination["request_key"]
    for key in edges:
        seen = set()
        while workers[key]["status"] != "CONSUMED":
            if key in seen or key not in edges:
                raise ValueError("worker_history_lineage_unproven")
            seen.add(key)
            key = edges[key]
    if not any(task["role"] == "feature-writer" for task in observed["tasks"]):
        raise ValueError("latest_writer_missing")
    for task in observed["tasks"]:
        if task["role"] == "feature-writer" and (task["status"] != "CONSUMED" or not any(worker["task_key"] == task["task_key"] and worker["status"] == "CONSUMED" and (worker["thread_id"], worker["turn_id"], worker["output_json"]) == (task["thread_id"], task["turn_id"], task["output_json"]) for worker in workers.values())):
            raise ValueError("latest_writer_unconsumed")
    if connection.execute("SELECT reservation_key FROM workspace_access WHERE run_id = ? AND mode = 'SOURCE' AND released_at IS NULL LIMIT 1", (run_id,)).fetchone() or connection.execute("SELECT op.call_id FROM worker_file_operations op JOIN worker_evidence worker ON worker.request_key = op.request_key WHERE worker.run_id = ? AND (op.phase = 'PREPARED' OR op.io_pending = 1) LIMIT 1", (run_id,)).fetchone():
        raise ValueError("worker_history_active_source")


def authorize(value, execution, binding, module, spool, owned):
    if value["helper_pid"] != os.getpid() or sha(execution["intent_json"].encode()) != execution["intent_sha256"] or sha(pathlib.Path(GIT).read_bytes()) != execution["program_sha256"]:
        raise ValueError("execution_changed")
    checkout = binding["checkout"]
    descriptor = module.directory(checkout["path"])
    try:
        if module.identity(descriptor) != (checkout["root_device"], checkout["root_inode"]):
            raise ValueError("checkout_changed")
    finally:
        os.close(descriptor)
    root = binding["worktree"]
    if os.path.realpath(root) != checkout["path"] or read_git(root, ["rev-parse", "HEAD"], execution) != binding["candidate_sha"] or read_git(root, ["branch", "--show-current"], execution) != binding["branch"] or read_git(root, ["status", "--porcelain", "--untracked-files=all"], execution):
        raise ValueError("candidate_changed")
    git_dir = os.path.realpath(read_git(root, ["rev-parse", "--absolute-git-dir"], execution))
    common_dir = os.path.realpath(os.path.join(root, read_git(root, ["rev-parse", "--git-common-dir"], execution)))
    repo_common = os.path.realpath(os.path.join(binding["repo_path"], read_git(binding["repo_path"], ["rev-parse", "--git-common-dir"], execution)))
    if (git_dir, common_dir, repo_common) != (checkout["git_dir"], checkout["common_dir"], checkout["common_dir"]):
        raise ValueError("repository_changed")
    if binding["branch"] in ("main", "master", binding["base_branch"]) or read_git(root, ["check-ref-format", "--branch", binding["branch"]], execution) != binding["branch"]:
        raise ValueError("branch_rejected")
    for name, args in ((root, ["remote", "get-url", "--push", "--all", "origin"]), (binding["repo_path"], ["remote", "get-url", "--all", "origin"])):
        urls = read_git(name, args, execution).splitlines()
        if len(urls) != 1 or sha(urls[0].encode()) != binding["origin"]["destination_sha256"]:
            raise ValueError("origin_changed")
    remote = read_git(root, ["ls-remote", "--refs", "origin", "refs/heads/" + binding["branch"]], execution)
    expected = ""
    if remote:
        fields = remote.split()
        if len(fields) != 2 or fields != [binding["candidate_sha"], "refs/heads/" + binding["branch"]]:
            raise ValueError("remote_ref_conflict")
        expected = fields[0]
    uri = "file:" + urllib.parse.quote(execution["database"], safe="/") + "?mode=rw"
    with sqlite3.connect(uri, uri=True, timeout=3) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute("BEGIN IMMEDIATE")
        run = connection.execute("SELECT * FROM runs WHERE run_id = ?", (execution["run_id"],)).fetchone()
        if run is None or any(run[key] != binding[key] for key in ("run_id", "issue_key", "state", "repo_path", "worktree", "branch", "base_branch", "candidate_sha", "contract_sha256", "spec_revision", "verifier_round")):
            raise ValueError("run_changed")
        if (run["execution_mode"], run["kind"], run["manual_validation_required"]) != ("TICKET_SUPERVISOR_V1", "DELIVERY", 0):
            raise ValueError("ordinary_route_changed")
        intent = json.loads(run["candidate_handoff"])
        if (intent["phase"], intent["binding_json"], intent["binding_sha256"], intent["owner_nonce"], intent["helper_pid"], intent["execution_json"]) != ("PUSH_UNCERTAIN", execution["intent_json"], execution["intent_sha256"], execution["invocation"], os.getpid(), value["execution_json"]):
            raise ValueError("claim_changed")
        original_raw = intent.get("original_envelope")
        if intent.get("kind") != "TICKET_PUSH_CAS_RECOVERY" or intent.get("old_outcome") != "UNKNOWN" or not isinstance(original_raw, str) or sha(original_raw.encode()) != execution["original_envelope_sha256"]:
            raise ValueError("recovery_binding_changed")
        original = json.loads(original_raw)
        old_execution = json.loads(original["execution_json"])
        old_helper = pathlib.Path(old_execution["helper_path"]).resolve()
        if old_helper.name != "ticket_push_executor_v2.py" or old_helper.parent != pathlib.Path(__file__).resolve().parent or sha(old_helper.read_bytes()) != OLD_HELPER_SHA or old_execution["helper_sha256"] != OLD_HELPER_SHA:
            raise ValueError("old_program_changed")
        if original.get("kind") != "TICKET_PUSH" or original.get("phase") != "PUSH_UNCERTAIN" or original.get("receipt_json") is not None or original["binding_json"] != execution["intent_json"] or original["reservation_key"] != intent["reservation_key"] or original["reservation_generation"] != intent["reservation_generation"] or original["owner_nonce"] == intent["owner_nonce"]:
            raise ValueError("old_intent_changed")
        if old_execution["intent_json"] != original["binding_json"] or old_execution["invocation"] != original["owner_nonce"] or old_execution["git_environment"] != execution["git_environment"] or old_execution["program_sha256"] != execution["program_sha256"] or old_execution["companion_sha256"] != execution["companion_sha256"]:
            raise ValueError("old_execution_changed")
        owned["authority_confirmed"] = True
        access = connection.execute("SELECT * FROM workspace_access WHERE reservation_key = ?", (intent["reservation_key"],)).fetchone()
        if access is None or (access["run_id"], access["mode"], access["generation"], access["released_at"], access["task_key"]) != (execution["run_id"], "MAINTENANCE", intent["reservation_generation"], None, None):
            raise ValueError("reservation_changed")
        saved = json.loads(access["binding_json"])
        if (access["canonical_path"], access["git_dir"], access["common_dir"], access["request_key"], saved["expected_sha"], saved["root_device"], saved["root_inode"]) != (root, git_dir, common_dir, intent["reservation_key"], binding["candidate_sha"], checkout["root_device"], checkout["root_inode"]):
            raise ValueError("reservation_binding_changed")
        parent = connection.execute("SELECT c.* FROM ticket_chats c JOIN ticket_chat_runs r ON r.chat_key = c.chat_key WHERE r.run_id = ?", (execution["run_id"],)).fetchone()
        if parent is None or any(parent[key] != val for key, val in binding["parent"].items()):
            raise ValueError("parent_changed")
        bootstrap = connection.execute("SELECT * FROM desktop_requests WHERE request_key = ?", (parent["create_request_key"],)).fetchone()
        if bootstrap is None or any(bootstrap[key] != val for key, val in binding["bootstrap"].items()) or bootstrap["action"] != "CREATE":
            raise ValueError("bootstrap_changed")
        if bootstrap["status"] == "FAILED":
            if bootstrap["failure_code"] != "TICKET_CHAT_BOOTSTRAP_NOT_ACKNOWLEDGED" or json.loads(bootstrap["output_json"]).get("result", {}).get("acknowledged") is not False:
                raise ValueError("bootstrap_failure_changed")
            recovery = connection.execute("SELECT * FROM desktop_requests WHERE request_key = ?", (parent["create_request_key"] + ":bootstrap-recovery:1",)).fetchone()
            proof = binding.get("bootstrap_recovery")
            if not isinstance(proof, dict) or recovery is None or dict(recovery) != proof or (recovery["status"], recovery["action"], recovery["target_kind"], recovery["target_key"], recovery["existing_thread_id"], recovery["thread_id"], recovery["verified_cwd"], recovery["verified_project_id"]) != ("SUCCEEDED", "FOLLOWUP", "TICKET_CHAT", parent["chat_key"], parent["thread_id"], parent["thread_id"], bootstrap["cwd"], None):
                raise ValueError("bootstrap_recovery_changed")
            output = json.loads(recovery["output_json"])
            observation = json.loads(recovery["target_observation_json"])
            if output.get("result", {}).get("acknowledged") is not True or not output.get("native_readback_sha256") or output["native_readback_sha256"] != observation.get("native_readback_sha256"):
                raise ValueError("bootstrap_recovery_completion_changed")
        elif bootstrap["status"] != "SUCCEEDED" or "bootstrap_recovery" in binding:
            raise ValueError("bootstrap_changed")
        if binding["state"] == "PUSHING":
            proof = binding["verifier"]
            verifier = connection.execute("SELECT * FROM worker_evidence WHERE request_key = ? AND run_id = ?", (proof["request_key"], execution["run_id"])).fetchone()
            if verifier is None or verifier["status"] != "CONSUMED" or any(verifier[key] != val for key, val in proof.items()):
                raise ValueError("verifier_changed")
            task = connection.execute("SELECT * FROM factory_tasks WHERE task_key = ?", (verifier["task_key"],)).fetchone()
            output = json.loads(verifier["output_json"])
            review = json.loads(verifier["binding_json"])
            pin = connection.execute("SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", (execution["run_id"],)).fetchone()
            if sha(verifier["binding_json"].encode()) != proof["binding_sha256"] or pin is None or review["base_sha"] != pin["base_sha"] or (review["role"], review["mode"], review["expected_sha"]) != ("change-verifier", "REVIEW", binding["candidate_sha"]):
                raise ValueError("verifier_binding_changed")
            if task is None or any(task[key] != review[key] for key in ("role", "stage", "model", "reasoning_effort", "prompt_sha256")) or any(run[key] != review[key] for key in ("spec_revision", "contract_sha256")):
                raise ValueError("verifier_inputs_changed")
            if task is None or (task["status"], task["thread_id"], task["turn_id"]) != ("CONSUMED", verifier["thread_id"], verifier["turn_id"]) or task["output_json"] != verifier["output_json"] or sha(verifier["output_json"].encode()) != proof["output_sha256"] or (output.get("status"), output.get("candidate_sha")) != ("PASS", binding["candidate_sha"]):
                raise ValueError("verifier_pass_changed")
        observed = datetime.datetime.fromisoformat(execution["authorization"]["observed_at"].replace("Z", "+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - observed).total_seconds()
        if not -5 <= age <= 60:
            raise ValueError("authorization_expired")
        worker_history(connection, execution)
        tick = execution["operator_tick"]
        current_tick = connection.execute("SELECT * FROM control WHERE scope = ?", (tick["scope"],)).fetchone()
        if set(tick) != {"scope", "dispatcher_id", "tick_id", "generation"} or current_tick is None or any(current_tick[key] != val for key, val in tick.items()) or current_tick["status"] != "ACTIVE" or datetime.datetime.fromisoformat(current_tick["lease_expires_at"].replace("Z", "+00:00")) <= datetime.datetime.now(datetime.timezone.utc):
            raise ValueError("operator_tick_unproven")
        if connection.execute("SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status IN ('PENDING', 'ACCEPTED') LIMIT 1", (execution["run_id"],)).fetchone():
            raise ValueError("pending_human_input")
        if connection.execute("SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND phase NOT IN ('APPLIED', 'SUPERSEDED', 'REJECTED') LIMIT 1", (execution["run_id"],)).fetchone():
            raise ValueError("pending_amendment")
        if owned["stopped"]:
            raise ValueError("caller_stopped")
        owned["issuance_started"] = True
        module.publish(spool, execution["invocation"] + ".push-recovery-claim", value["execution_json"].encode())
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGHUP, signal.SIGTERM, signal.SIGINT})
        try:
            if owned["stopped"]:
                raise ValueError("caller_stopped")
            owned["issuance_started"] = True
            lease = "--force-with-lease=refs/heads/" + binding["branch"] + ":" + expected
            child = subprocess.Popen(arguments(root, ["push", "--no-verify", "--no-follow-tags", lease, "origin", binding["candidate_sha"] + ":refs/heads/" + binding["branch"]]), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
            owned["child"] = child
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        connection.commit()
        return child


def execute(value, execution, module, spool):
    binding = json.loads(execution["intent_json"])
    owned = {"child": None, "stopped": False, "issuance_started": False, "authority_confirmed": False}
    stderr = bytearray()
    overflow = False

    def kill_owned_group():
        child = owned["child"]
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def stop(_signum=None, _frame=None):
        owned["stopped"] = True
        kill_owned_group()

    signals = {signal.SIGHUP, signal.SIGTERM, signal.SIGINT}
    for sig in signals:
        signal.signal(sig, stop)

    def reap_owned():
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        try:
            # Keep the leader unreaped through group cleanup, including Darwin zombie EPERM.
            kill_owned_group()
            code = owned["child"].wait(timeout=1)
            owned["child"] = None
            return code
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    try:
        child = authorize(value, execution, binding, module, spool, owned)
        os.set_blocking(child.stderr.fileno(), False)
        deadline = min(time.monotonic() + 25, DEADLINE)
        with contextlib.closing(select.kqueue()) as events:
            try:
                exited = bool(events.control([select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                    flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 1, 0))
            except ProcessLookupError:
                exited = True
            while not exited:
                if select.select([child.stderr], [], [], 0)[0]:
                    chunk = os.read(child.stderr.fileno(), 16_384)
                    if len(stderr) + len(chunk) > 16_384:
                        overflow = True
                        stop()
                        break
                    stderr.extend(chunk)
                if owned["stopped"] or time.monotonic() >= deadline or (select.select([sys.stdin], [], [], 0)[0] and not os.read(sys.stdin.fileno(), 1)):
                    stop()
                    break
                exited = bool(events.control([], 1, 0.1))
        code = reap_owned()
        while select.select([child.stderr], [], [], 0)[0]:
            chunk = os.read(child.stderr.fileno(), 16_384)
            if not chunk:
                break
            if len(stderr) + len(chunk) > 16_384:
                overflow = True
                break
            stderr.extend(chunk)
    except Exception as error:
        if owned["issuance_started"] or not owned["authority_confirmed"]:
            raise
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        receipt = {"version": 1, "kind": "PREISSUANCE_REJECTED", "execution_json": value["execution_json"], "helper_pid": os.getpid(), "child_pid": None, "reason": reason}
        raw = json.dumps(receipt, separators=(",", ":")).encode()
        module.publish(spool, execution["invocation"] + ".push-recovery-rejection", raw)
        return raw
    finally:
        if owned["child"] is not None:
            reap_owned()
        if "child" in locals():
            child.stderr.close()
    termination = {"kind": "exited", "code": code} if code >= 0 else {"kind": "signaled", "signal": -code}
    lowered = bytes(stderr).lower()
    diagnostic = "GIT_EXIT_NONZERO"
    if code == 0:
        diagnostic = "GIT_EXIT_ZERO"
    elif b"stale info" in lowered:
        diagnostic = "CAS_REF_CHANGED"
    elif any(token in lowered for token in (b"authentication failed", b"permission denied", b"could not read username")):
        diagnostic = "AUTHENTICATION_DENIED"
    elif any(token in lowered for token in (b"could not resolve host", b"connection timed out", b"failed to connect")):
        diagnostic = "TRANSPORT_FAILURE"
    receipt = {"version": 1, "execution_json": value["execution_json"], "helper_pid": os.getpid(), "child_pid": child.pid, "termination": termination, "timed_out": owned["stopped"], "overflow": overflow, "output_base64": "", "output_sha256": sha(b""), "stderr_code": diagnostic, "stderr_sha256": sha(bytes(stderr)), "stderr_bytes": len(stderr)}
    raw = json.dumps(receipt, separators=(",", ":")).encode()
    module.publish(spool, execution["invocation"] + ".push-recovery-receipt", raw)
    return raw


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("--execute", "--status"):
        raise ValueError("mode_rejected")
    value = packet()
    execution = json.loads(value["execution_json"])
    nonce = execution["invocation"]
    if not isinstance(nonce, str) or len(nonce) != 64 or any(c not in "0123456789abcdef" for c in nonce):
        raise ValueError("nonce_rejected")
    module = companion(execution)
    spool = module.open_spool(execution)
    try:
        if sys.argv[1] == "--execute":
            raw = execute(value, execution, module, spool)
        else:
            try:
                raw = module.read_at(spool, nonce + ".push-recovery-rejection", LIMIT)
                rejected = json.loads(raw)
                if rejected.get("kind") != "PREISSUANCE_REJECTED" or rejected.get("execution_json") != value["execution_json"] or rejected.get("helper_pid") != value["helper_pid"] or rejected.get("child_pid") is not None:
                    raise ValueError("rejection_changed")
                for suffix in (".push-recovery-claim", ".push-recovery-receipt"):
                    try:
                        module.read_at(spool, nonce + suffix, LIMIT)
                    except FileNotFoundError:
                        continue
                    raise ValueError("rejection_conflicts_with_issuance")
            except FileNotFoundError:
                if module.read_at(spool, nonce + ".push-recovery-claim", LIMIT) != value["execution_json"].encode():
                    raise ValueError("claim_changed")
                raw = module.read_at(spool, nonce + ".push-recovery-receipt", LIMIT)
        sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
        sys.stdout.buffer.flush()
    finally:
        os.close(spool)


if __name__ == "__main__":
    main()
