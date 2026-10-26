"""Claim- and packet-bound generated-only CI mode over the preserved confined engine."""
import hashlib
import base64
import json
import os
import pathlib
import re
import stat
import types

ENGINE_SHA = "7e6c9b72d084431a5db4fbf3263ad4be0f8d8aa5582132a7e365e5c56c788c42"
PROFILE_SHA = "917e8a5caacdbb2f4cede1572f1368b31ca97738ebd40320d9a174aa3503e6c1"
TOOLSET_SHA = "a7b82db9826c6dcc1e7cf2f726f7ca47c3677125e164bbc9c27abf7f2350282e"
GUIDANCE = "Controller-only mechanical BUILD capability, not writer permission. Only a genuine no-edit COMPLETE at the exact failed candidate, with no CONTINUE lineage, can select it. Never edit BUILD or invent a source edit to trigger generation. Source edits remain governed solely by the original CI scope."


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


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


def engine():
    path = pathlib.Path(__file__).resolve().with_name("controller_generation_executor_v1.py")
    raw = path.read_bytes()
    require(sha(raw) == ENGINE_SHA)
    module = types.ModuleType("generated_only_confined_engine")
    module.__file__ = __file__
    exec(compile(raw, str(path), "exec", dont_inherit=True, optimize=0), module.__dict__)
    module.QUERIES.update({
        "instruction_snapshots": ("SELECT * FROM worker_instruction_snapshots WHERE run_id=? ORDER BY binding_sha256", "run_id"),
        "instruction_bindings": ("SELECT * FROM worker_instruction_task_bindings WHERE run_id=? ORDER BY task_key,prompt_sha256", "run_id")})
    module.READ_TABLES |= {"worker_instruction_snapshots", "worker_instruction_task_bindings", "ticket_ci_repair_reassessments"}
    original = module.ledger_fence

    def fence(connection, binding):
        original(connection, binding)
        row = one(connection, "SELECT * FROM ticket_ci_generation_intents WHERE intent_key=?", (binding["intent_key"],))
        intent = checked(row, "binding_json", "binding_sha256")
        require(binding.get("generation_version") == 3 and binding["paths"] == intent["paths"] and binding["operation"] == "GAZELLE_DIFF")
        capability = validate_intent(connection, row, intent, check_files=True)
        if binding["started_type"] == "EXECUTION_STARTED":
            for value in capability["build_inputs"]:
                path = pathlib.Path(binding["root"]) / value["path"]
                require(str(path.resolve()) == str(path) and stat.S_ISREG(path.lstat().st_mode) and sha(path.read_bytes()) == value["sha256"])
        else:
            proposal = binding["proposal"]
            expected = [value for value in capability["build_inputs"] if value["path"] == proposal["path"]]
            require(len(expected) == 1 and proposal["before_sha256"] == expected[0]["sha256"])

    module.ledger_fence = fence
    return module


if __name__ == "__main__":
    try:
        engine().main()
    except Exception:
        raise SystemExit(1) from None
