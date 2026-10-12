"""Controller-only fixed push, exclusive claim and durable waitpid receipt."""
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
    return [GIT, "--no-lazy-fetch", "--no-replace-objects", "-C", root, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "gc.auto=0"] + args


def read_git(root, args, execution):
    result = subprocess.run(arguments(root, args), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3, check=True)
    if len(result.stdout) > 16_384:
        raise ValueError("output_rejected")
    return result.stdout.decode().strip()


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
        if connection.execute("SELECT request_key FROM worker_evidence WHERE run_id = ? AND status != 'CONSUMED' LIMIT 1", (execution["run_id"],)).fetchone():
            raise ValueError("worker_unconsumed")
        if owned["stopped"]:
            raise ValueError("caller_stopped")
        owned["issuance_started"] = True
        module.publish(spool, execution["invocation"] + ".push-claim", value["execution_json"].encode())
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGHUP, signal.SIGTERM, signal.SIGINT})
        try:
            if owned["stopped"]:
                raise ValueError("caller_stopped")
            owned["issuance_started"] = True
            child = subprocess.Popen(arguments(root, ["push", "--no-verify", "origin", binding["candidate_sha"] + ":refs/heads/" + binding["branch"]]), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            owned["child"] = child
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        connection.commit()
        return child


def execute(value, execution, module, spool):
    binding = json.loads(execution["intent_json"])
    owned = {"child": None, "stopped": False, "issuance_started": False, "authority_confirmed": False}

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
        deadline = time.monotonic() + 25
        with contextlib.closing(select.kqueue()) as events:
            try:
                exited = bool(events.control([select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                    flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 1, 0))
            except ProcessLookupError:
                exited = True
            while not exited:
                if owned["stopped"] or time.monotonic() >= deadline or (select.select([sys.stdin], [], [], 0)[0] and not os.read(sys.stdin.fileno(), 1)):
                    stop()
                    break
                exited = bool(events.control([], 1, 0.1))
        code = reap_owned()
    except Exception as error:
        if owned["issuance_started"] or not owned["authority_confirmed"]:
            raise
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        receipt = {"version": 1, "kind": "PREISSUANCE_REJECTED", "execution_json": value["execution_json"], "helper_pid": os.getpid(), "child_pid": None, "reason": reason}
        raw = json.dumps(receipt, separators=(",", ":")).encode()
        module.publish(spool, execution["invocation"] + ".push-rejection", raw)
        return raw
    finally:
        if owned["child"] is not None:
            reap_owned()
    termination = {"kind": "exited", "code": code} if code >= 0 else {"kind": "signaled", "signal": -code}
    receipt = {"version": 1, "execution_json": value["execution_json"], "helper_pid": os.getpid(), "child_pid": child.pid, "termination": termination, "timed_out": owned["stopped"], "overflow": False, "output_base64": "", "output_sha256": sha(b"")}
    raw = json.dumps(receipt, separators=(",", ":")).encode()
    module.publish(spool, execution["invocation"] + ".push-receipt", raw)
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
                raw = module.read_at(spool, nonce + ".push-rejection", LIMIT)
                rejected = json.loads(raw)
                if rejected.get("kind") != "PREISSUANCE_REJECTED" or rejected.get("execution_json") != value["execution_json"] or rejected.get("helper_pid") != value["helper_pid"] or rejected.get("child_pid") is not None:
                    raise ValueError("rejection_changed")
                for suffix in (".push-claim", ".push-receipt"):
                    try:
                        module.read_at(spool, nonce + suffix, LIMIT)
                    except FileNotFoundError:
                        continue
                    raise ValueError("rejection_conflicts_with_issuance")
            except FileNotFoundError:
                if module.read_at(spool, nonce + ".push-claim", LIMIT) != value["execution_json"].encode():
                    raise ValueError("claim_changed")
                raw = module.read_at(spool, nonce + ".push-receipt", LIMIT)
        sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
        sys.stdout.buffer.flush()
    finally:
        os.close(spool)


if __name__ == "__main__":
    main()
