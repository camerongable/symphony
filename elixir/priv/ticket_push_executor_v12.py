"""Ordinary nonforce CI-repair push with exact dedicated evidence-successor qualification."""
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
LIMIT = 1_048_576
RECEIPT_LIMIT = 4_194_304
PREISSUANCE_REASONS = frozenset("""
execution_changed checkout_changed candidate_changed repository_changed branch_rejected
origin_changed run_changed ordinary_route_changed claim_changed reservation_changed
reservation_binding_changed parent_changed bootstrap_changed bootstrap_failure_changed
bootstrap_recovery_changed bootstrap_recovery_completion_changed verifier_changed
verifier_binding_changed verifier_inputs_changed verifier_pass_changed authorization_expired
history_program_changed ci_evidence_successor_changed ordinary_verifier_repair_unproven ci_repair_claim_changed ci_repair_diagnosis_changed ci_repair_round_changed
ci_repair_inputs_changed pending_human_input pending_amendment pending_question human_input_changed
human_parent_changed worker_history_changed worker_history_encoding_unproven
worker_history_source_unreleased worker_history_stop_unproven worker_history_transfer_unproven
worker_history_lineage_unproven worker_history_failed_transfer_unproven
worker_history_blocked_transfer_unproven worker_history_transfer_kind_unproven
latest_writer_missing latest_writer_unconsumed worker_history_active_source caller_stopped output_rejected
""".split())


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def companion(execution):
    path = pathlib.Path(__file__).resolve().with_name("worker_file_companion.py")
    raw = path.read_bytes()
    if str(path) != execution["companion_path"] or sha(raw) != execution["companion_sha256"] or sha(pathlib.Path(__file__).read_bytes()) != execution["helper_sha256"]:
        raise ValueError("program_changed")
    spec = importlib.util.spec_from_file_location("push_companion", path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), "exec", dont_inherit=True, optimize=0), module.__dict__)
    return module


def input_bytes(size):
    raw = bytearray()
    while len(raw) < size:
        chunk = os.read(sys.stdin.fileno(), size - len(raw))
        if not chunk:
            raise ValueError("frame_rejected")
        raw.extend(chunk)
    return bytes(raw)


def packet():
    header = input_bytes(4)
    if len(header) != 4 or not 0 < (size := int.from_bytes(header, "big")) <= LIMIT:
        raise ValueError("frame_rejected")
    raw = input_bytes(size)
    if len(raw) != size:
        raise ValueError("frame_rejected")
    if select.select([sys.stdin.fileno()], [], [], 0)[0] and os.read(sys.stdin.fileno(), 1):
        raise ValueError("frame_rejected")
    value = json.loads(raw)
    if set(value) != {"execution_json", "helper_pid"}:
        raise ValueError("packet_rejected")
    if not isinstance(value["execution_json"], str) or len(value["execution_json"].encode()) > LIMIT:
        raise ValueError("packet_rejected")
    terminal = {"version": 1, "execution_json": value["execution_json"], "helper_pid": 9223372036854775807,
                "child_pid": 9223372036854775807, "termination": {"kind": "signaled", "signal": 64},
                "timed_out": False, "overflow": False, "output_base64": "A" * 87384,
                "output_sha256": "f" * 64, "stderr_code": "AUTHENTICATION_DENIED", "stderr_bytes": 16384,
                "stderr_sha256": "f" * 64}
    if len(json.dumps(terminal, separators=(",", ":")).encode()) > RECEIPT_LIMIT:
        raise ValueError("packet_rejected")
    return value


def arguments(root, args):
    return [GIT, "--no-lazy-fetch", "--no-replace-objects", "-C", root, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "gc.auto=0", "-c", "remote.origin.mirror=false", "-c", "push.followTags=false", "-c", "push.recurseSubmodules=no", "-c", "remote.origin.tagOpt=--no-tags"] + args


def read_git(root, args, execution):
    result = subprocess.run(arguments(root, args), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3, check=True)
    if len(result.stdout) > 16_384:
        raise ValueError("output_rejected")
    return result.stdout.decode().strip()


def read_blob(root, candidate, path, execution):
    result = subprocess.run(arguments(root, ["show", candidate+":"+path]), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3, check=True)
    if len(result.stdout) > 262_144:
        raise ValueError("output_rejected")
    return result.stdout


def row_digest(row, validator):
    row = dict(row)
    if len(row) > 32 or any(type(value) not in (str, int, type(None)) for value in row.values()):
        raise ValueError("ci_repair_diagnosis_changed")
    raw = json.dumps(dict(row), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    if len(raw) > 2_097_152:
        # Use only the already-attested history program from retained_history.
        # The digest remains over complete original row bytes, not projections.
        validator.push_budget_decode(raw.decode(), 'diagnosis_row')
    return sha(raw)


def claimed_diagnosis(connection, claim, validator):
    try:
        original = connection.execute("SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key = ?", (claim["diagnosis_key"],)).fetchone()
        original_fields = {"diagnosis_key", "run_id", "candidate_sha", "pipeline_id", "preimage_json", "preimage_sha256", "diagnosis_json", "diagnosis_sha256", "verdict", "created_at"}
        if original is None or set(original.keys()) != original_fields or sha(original["diagnosis_json"].encode()) != original["diagnosis_sha256"]:
            raise ValueError("ci_repair_diagnosis_changed")
        saved = json.loads(claim["claim_json"])
        key, expected = saved.get("reassessment_key"), saved.get("reassessment_sha256")
        if key is None and expected is None:
            if original["verdict"] != "REPAIRABLE":
                raise ValueError("ci_repair_diagnosis_changed")
            return json.loads(original["diagnosis_json"])
        row = connection.execute("SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key = ?", (key,)).fetchone()
        fields = {"reassessment_key", "diagnosis_key", "collector_version", "original_sha256", "run_id", "candidate_sha", "pipeline_id", "preimage_json", "preimage_sha256", "diagnosis_json", "diagnosis_sha256", "verdict", "created_at", "kind"}
        if row is None or set(row.keys()) != fields or row_digest(row, validator) != expected or row["original_sha256"] != row_digest(original, validator):
            raise ValueError("ci_repair_diagnosis_changed")
        for value in (original, row):
            if type(value["pipeline_id"]) is not int or value["pipeline_id"] <= 0 or any(type(value[field]) is not str for field in value.keys() if field != "pipeline_id"):
                raise ValueError("ci_repair_diagnosis_changed")
        if original["verdict"] != "BLOCKED" or row["verdict"] != "REPAIRABLE" or row["kind"] != "COLLECTOR_REASSESSMENT_V1":
            raise ValueError("ci_repair_diagnosis_changed")
        encoded = json.dumps([claim["diagnosis_key"], row["collector_version"]], separators=(",", ":"), ensure_ascii=False).encode()
        if key != "ci-reassessment:" + sha(encoded) or any(row[field] != original[field] for field in ("diagnosis_key", "run_id", "candidate_sha", "pipeline_id")):
            raise ValueError("ci_repair_diagnosis_changed")
        for value in (original, row):
            if sha(value["preimage_json"].encode()) != value["preimage_sha256"] or sha(value["diagnosis_json"].encode()) != value["diagnosis_sha256"]:
                raise ValueError("ci_repair_diagnosis_changed")
            prior = json.loads(value["preimage_json"])["run"]
            diagnosis = json.loads(value["diagnosis_json"])
            if not isinstance(prior, dict) or not isinstance(diagnosis, dict) or diagnosis.get("status") != value["verdict"]:
                raise ValueError("ci_repair_diagnosis_changed")
            if (prior.get("run_id"), prior.get("candidate_sha"), prior.get("ci_pipeline_id")) != (value["run_id"], value["candidate_sha"], value["pipeline_id"]):
                raise ValueError("ci_repair_diagnosis_changed")
        if any(saved.get(field) != diagnosis.get(field) for field in ("allowed_writer_paths", "required_generated_paths")):
            raise ValueError("ci_repair_diagnosis_changed")
        return diagnosis
    except (KeyError, TypeError, AttributeError, json.JSONDecodeError):
        raise ValueError("ci_repair_diagnosis_changed") from None


def retained_history(connection, execution, binding, run):
    path = pathlib.Path(__file__).resolve().with_name("ticket_push_history_validator_v9.py")
    raw = path.read_bytes()
    if str(path) != execution["history_program_path"] or sha(raw) != execution["history_program_sha256"]:
        raise ValueError("history_program_changed")
    spec = importlib.util.spec_from_file_location("ordinary_history_validator", path)
    validator = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), "exec", dont_inherit=True, optimize=0), validator.__dict__)
    validator.validate_prepared_requalification(connection, execution, binding, run)
    validator.validate_preissuance_retirement(connection, execution, binding, run)
    validator.validate_import_history(connection, execution, binding, run)
    if not any(key in binding for key in ("ci_evidence_successor", "ordinary_verifier_repair", "ci_repair")):
        validator.initial_writer(connection, execution, binding, run)
    elif "ci_evidence_successor" in binding:
        validator.validate_push_proof(connection, execution, binding, run)
    else:
        validator.ordinary_repair(connection, execution, binding, run)
        if binding["state"] == "PUSHING":
            task = dict(connection.execute("SELECT * FROM factory_tasks WHERE run_id=? AND role='feature-writer'", (binding["run_id"],)).fetchone())
            latest = dict(connection.execute("SELECT * FROM worker_evidence WHERE task_key=? AND turn_id=? AND status='CONSUMED'", (task["task_key"],task["turn_id"])).fetchone())
            validator.verified_rollover(connection, execution, binding, run, latest, task)
        elif binding["state"] != "CI_PUSHING" or "verified_ci_rollover" in binding:
            raise ValueError("ci_evidence_successor_changed")
    if "ordinary_verifier_repair" in binding:
        proof = binding["ordinary_verifier_repair"]
        source = connection.execute("SELECT output_json FROM worker_evidence WHERE request_key=?", (proof["writer_request_key"],)).fetchone()
        output = json.loads(source["output_json"])
        parent = proof["source_parent_sha"]
        descendants = read_git(binding["worktree"], ["diff", "--name-only", "--no-renames", proof["reviewed_candidate_sha"]+"..."+parent], execution).splitlines()
        go = sorted({path for path in descendants+output["changed_paths"] if path.endswith(".go")})
        present = read_git(binding["worktree"], ["ls-tree", "-r", "--name-only", binding["candidate_sha"], "--"]+go, execution).splitlines() if go else []
        try:
            generated = validator.ordinary_generation(connection, execution, binding, run, go, sorted(present))
        except (KeyError, TypeError, ValueError, AttributeError, StopIteration):
            raise ValueError("ordinary_verifier_repair_unproven") from None
        for path, expected in generated.items():
            if sha(read_blob(binding["worktree"], binding["candidate_sha"], path, execution)) != expected:
                raise ValueError("ordinary_verifier_repair_unproven")
        effective = sorted(set(output["changed_paths"]) | set(generated))
        if effective:
            if read_git(binding["worktree"], ["rev-parse", "HEAD^"], execution) != parent:
                raise ValueError("ci_evidence_successor_changed")
            committed = read_git(binding["worktree"], ["diff", "--name-only", "--no-renames", parent, binding["candidate_sha"]], execution).splitlines()
            if sorted(committed) != effective:
                raise ValueError("ordinary_verifier_repair_unproven")
        elif parent != binding["candidate_sha"]:
            raise ValueError("ci_evidence_successor_changed")
        if read_git(binding["worktree"], ["merge-base", proof["reviewed_candidate_sha"], binding["candidate_sha"]], execution) != proof["reviewed_candidate_sha"]:
            raise ValueError("ci_evidence_successor_changed")
    validator.worker_history(connection, execution)
    validator.generated_only_commits(connection, execution, binding, run, read_git, read_blob)
    if binding["state"] == "CI_PUSHING" and "ci_repair" in binding:
        proof = binding["ci_repair"]
        claim = connection.execute("SELECT * FROM ticket_ci_repair_claims WHERE claim_key = ? AND run_id = ?", (proof["claim_key"], binding["run_id"])).fetchone()
        if claim is None or sha(claim["claim_json"].encode()) != proof["claim_sha256"] or claim["claim_sha256"] != proof["claim_sha256"]:
            raise ValueError("ci_repair_claim_changed")
        claimed_diagnosis(connection, claim, validator)
        saved = json.loads(claim["claim_json"])
        prior = saved["prior_run"]
        if claim["round"] != run["code_repair_round"] or saved["round"] != claim["round"] or proof["round"] != claim["round"]:
            raise ValueError("ci_repair_round_changed")
        if saved["kind"] != "TICKET_CI_REPAIR" or saved["claim_key"] != proof["claim_key"] or any(prior[key] != binding[key] for key in ("run_id", "repo_path", "worktree", "branch", "base_branch", "contract_sha256", "spec_revision")):
            raise ValueError("ci_repair_inputs_changed")
    if connection.execute("SELECT command_key FROM ticket_chat_commands WHERE run_id = ? AND status IN ('PENDING','ACCEPTED') LIMIT 1", (binding["run_id"],)).fetchone():
        raise ValueError("pending_human_input")
    if connection.execute("SELECT command_key FROM ticket_contract_amendments WHERE run_id = ? AND active_owner = 1 LIMIT 1", (binding["run_id"],)).fetchone():
        raise ValueError("pending_amendment")
    if connection.execute("SELECT question_key FROM ticket_chat_questions WHERE run_id = ? AND status = 'OPEN' LIMIT 1", (binding["run_id"],)).fetchone():
        raise ValueError("pending_question")
    inputs = execution["ci_human_inputs"]
    for table in ("ticket_chat_commands", "ticket_chat_questions", "ticket_contract_amendments"):
        values = [list(row) for row in connection.execute("SELECT * FROM " + table + " WHERE run_id = ? ORDER BY 1", (binding["run_id"],))]
        if sha(json.dumps(values, separators=(",", ":"), ensure_ascii=False).encode()) != inputs[table]:
            raise ValueError("human_input_changed")
    parent = connection.execute("SELECT c.* FROM ticket_chats c JOIN ticket_chat_runs r ON r.chat_key = c.chat_key WHERE r.run_id = ?", (binding["run_id"],)).fetchone()
    bootstrap = connection.execute("SELECT * FROM desktop_requests WHERE request_key = ?", (parent["create_request_key"],)).fetchone() if parent else None
    for name, actual in (("parent", parent), ("bootstrap", bootstrap)):
        proof = inputs[name]
        if actual is None or set(actual.keys()) != set(proof["keys"]) or sha(json.dumps([actual[key] for key in proof["keys"]], separators=(",", ":"), ensure_ascii=False).encode()) != proof["sha256"]:
            raise ValueError("human_parent_changed")
    values = [list(row) for row in connection.execute("SELECT input.* FROM ticket_chat_inputs input JOIN ticket_chat_runs binding ON binding.chat_key=input.chat_key WHERE binding.run_id=? ORDER BY input.input_key", (binding["run_id"],))]
    if sha(json.dumps(values, separators=(",", ":"), ensure_ascii=False).encode()) != inputs["inputs"]:
        raise ValueError("human_input_changed")
    if binding["state"] == "CI_PUSHING" and "ci_repair" in binding and validator.current_policy(connection, execution, binding, run) != binding["ci_evidence_successor"]["attempt_limit"]:
        raise ValueError("ci_evidence_successor_changed")
    if "verified_ci_rollover" in binding:
        validator.rollover_fence(connection, execution, binding, run)


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
        if run is None or any(run[key] != binding[key] for key in ("run_id", "issue_key", "state", "repo_path", "worktree", "branch", "base_branch", "candidate_sha", "contract_sha256", "spec_revision", "verifier_round", "code_repair_round")):
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
        retained_history(connection, execution, binding, run)
        if owned["stopped"]:
            raise ValueError("caller_stopped")
        owned["issuance_started"] = True
        module.publish(spool, execution["invocation"] + ".push-claim", value["execution_json"].encode())
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGHUP, signal.SIGTERM, signal.SIGINT})
        try:
            if owned["stopped"]:
                raise ValueError("caller_stopped")
            owned["issuance_started"] = True
            child = subprocess.Popen(arguments(root, ["push", "--no-verify", "origin", binding["candidate_sha"] + ":refs/heads/" + binding["branch"]]), env=execution["git_environment"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
            os.set_blocking(child.stderr.fileno(), False)
            owned["child"] = child
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        connection.commit()
        return child


def execute(value, execution, module, spool):
    binding = json.loads(execution["intent_json"])
    owned = {"child": None, "stopped": False, "issuance_started": False, "authority_confirmed": False, "stderr": bytearray(), "overflow": False}

    def drain_stderr(child):
        for _ in range(4):
            try:
                chunk = os.read(child.stderr.fileno(), 4096)
            except BlockingIOError:
                return
            if not chunk:
                return
            available = 16384 - len(owned["stderr"])
            owned["stderr"].extend(chunk[:available])
            if len(chunk) > available:
                owned["overflow"] = True
                return

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
                drain_stderr(child)
                if owned["stopped"] or owned["overflow"] or time.monotonic() >= deadline or (select.select([sys.stdin], [], [], 0)[0] and not os.read(sys.stdin.fileno(), 1)):
                    stop()
                    break
                exited = bool(events.control([], 1, 0.1))
        drain_stderr(child)
        code = reap_owned()
        child.stderr.close()
    except Exception as error:
        if owned["issuance_started"] or owned["child"] is not None:
            raise
        message = str(error)
        if type(error) is not ValueError or message not in PREISSUANCE_REASONS:
            raise
        reason = message
        receipt = {"version": 1, "kind": "PREISSUANCE_REJECTED", "execution_json": value["execution_json"], "helper_pid": os.getpid(), "child_pid": None, "reason": reason}
        raw = json.dumps(receipt, separators=(",", ":")).encode()
        module.publish(spool, execution["invocation"] + ".push-rejection", raw)
        return raw
    finally:
        if owned["child"] is not None:
            reap_owned()
    termination = {"kind": "exited", "code": code} if code >= 0 else {"kind": "signaled", "signal": -code}
    stderr = bytes(owned["stderr"])
    lower = stderr.lower()
    stderr_code = "GIT_EXIT_ZERO" if code == 0 else "GIT_EXIT_NONZERO"
    if code != 0 and any(marker in lower for marker in (b"permission denied", b"authentication failed", b"could not read username")):
        stderr_code = "AUTHENTICATION_DENIED"
    elif code != 0 and any(marker in lower for marker in (b"could not resolve", b"connection timed out", b"connection refused", b"remote end hung up", b"connection reset")):
        stderr_code = "TRANSPORT_FAILURE"
    receipt = {"version": 1, "execution_json": value["execution_json"], "helper_pid": os.getpid(), "child_pid": child.pid, "termination": termination, "timed_out": owned["stopped"], "overflow": owned["overflow"], "output_base64": "", "output_sha256": sha(b""), "stderr_code": stderr_code, "stderr_bytes": len(stderr), "stderr_sha256": sha(stderr)}
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
                raw = module.read_at(spool, nonce + ".push-rejection", RECEIPT_LIMIT)
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
                raw = module.read_at(spool, nonce + ".push-receipt", RECEIPT_LIMIT)
        sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
        sys.stdout.buffer.flush()
    finally:
        os.close(spool)


if __name__ == "__main__":
    main()
