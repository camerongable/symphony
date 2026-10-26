"""Bounded read-only v12 and attested v11 receipts; no push or old-code execution."""
import base64
import hashlib
import json
import os
import pathlib
import re
import select
import sqlite3
import stat
import sys
import unicodedata
import urllib.parse

LIMIT = 1_048_576
RECEIPT_LIMIT = 4_194_304
ORIGINS_SHA256 = "d83ae3638d358e09f33e88dfb4889ca840ec4a536d929f9368ee29cd62290348"
VERSIONS = {
    "ticket_push_executor_v14.py": "59ca083a8a8771e261604acb7c946a92ef65576fec11aa161fbc0f89dd1335e0",
    "ticket_push_executor_v13.py": "8a4b90014af4b1e56e21c1698ba3657e08f7e57b78de58aad33bcebab43b0950",
    "ticket_push_executor_v12.py": "f5513fb5eda319b4df8d2796b37ec0efec08afec3793aab4962de3590c73255b",
    "ticket_push_executor_v11.py": "39646c62bb345a1f4c3776465545bf8afc29a870955e1e608b093fb869ffb8a7",
}
COMPANION_SHA256 = "87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b"

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate_key")
        value[key] = item
    return value

def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object)

def absolute(path):
    return isinstance(path, str) and path.startswith("/") and str(pathlib.PurePosixPath(path)) == path and ".." not in pathlib.PurePosixPath(path).parts

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
        after = os.fstat(descriptor)
        if len(data) > limit or len(data) != info.st_size or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns):
            raise ValueError("receipt_too_large")
        return bytes(data)
    finally:
        os.close(descriptor)


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



def regular(path, limit):
    if not absolute(path):
        raise ValueError("program_changed")
    parent = directory(os.path.dirname(path))
    try:
        return read_at(parent, os.path.basename(path), limit)
    finally:
        os.close(parent)

def outside(path, execution):
    parent = directory(os.path.dirname(path))
    try:
        here = ancestors(parent)
        for item in source_paths(execution["database"], execution["root"]):
            source, missing = planned_directory(item["path"])
            try:
                if not missing and identity(source) in here:
                    raise ValueError("program_in_source")
            finally:
                os.close(source)
    finally:
        os.close(parent)

def provenance(execution):
    current = str(pathlib.Path(__file__).parent)
    if str(pathlib.Path(__file__).resolve()) != __file__:
        raise ValueError("program_changed")
    resource_path = current + "/ticket_push_readback_origins_v7.json"
    outside(resource_path, execution)
    resource_raw = regular(resource_path, 65_536)
    if sha(resource_raw) != ORIGINS_SHA256:
        raise ValueError("program_changed")
    resource = decode(resource_raw)
    if set(resource) != {"version", "entries"} or type(resource["version"]) is not int or resource["version"] != 7:
        raise ValueError("program_changed")
    entries = resource["entries"]
    if not isinstance(entries, list) or not 0 < len(entries) <= 8:
        raise ValueError("program_changed")
    keys = {"kind", "manifest_path", "manifest_sha256", "helper_path", "helper_sha256",
            "companion_path", "companion_sha256", "artifact_helper_path", "artifact_companion_path"}
    paths = []
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("kind") not in ("RELEASE_ARTIFACT_V1", "RELEASE_ARTIFACT_V2", "COMPILED_SOURCE_V1"):
            raise ValueError("program_changed")
        expected_keys = keys | ({"compile_proof_raw"} if entry["kind"] == "COMPILED_SOURCE_V1" else set())
        if entry["kind"] == "RELEASE_ARTIFACT_V2":
            expected_keys |= {"release_root", "expected_manifest_kind"}
            if not absolute(entry.get("release_root")) or not isinstance(entry.get("expected_manifest_kind"), str) or re.fullmatch("[A-Z0-9_]{1,128}", entry["expected_manifest_kind"]) is None:
                raise ValueError("program_changed")
        if set(entry) != expected_keys:
            raise ValueError("program_changed")
        if any(not absolute(entry[key]) for key in ("manifest_path", "helper_path", "companion_path", "artifact_helper_path", "artifact_companion_path")):
            raise ValueError("program_changed")
        if any(not isinstance(entry[key], str) or re.fullmatch("[0-9a-f]{64}", entry[key]) is None for key in ("manifest_sha256", "helper_sha256", "companion_sha256")):
            raise ValueError("program_changed")
        paths.append(entry["helper_path"])
    if len(set(paths)) != len(paths):
        raise ValueError("program_changed")
    current_helper = current + "/" + os.path.basename(execution["helper_path"])
    current_companion = current + "/worker_file_companion.py"
    if execution["helper_path"] == current_helper and os.path.basename(current_helper) in ("ticket_push_executor_v12.py", "ticket_push_executor_v13.py", "ticket_push_executor_v14.py"):
        expected = VERSIONS[os.path.basename(current_helper)]
        if execution["helper_sha256"] != expected or execution["companion_path"] != current_companion or execution["companion_sha256"] != COMPANION_SHA256:
            raise ValueError("program_changed")
        for path, digest in ((current_helper, expected), (current_companion, COMPANION_SHA256)):
            outside(path, execution)
            if sha(regular(path, RECEIPT_LIMIT)) != digest:
                raise ValueError("program_changed")
        return
    matched = [entry for entry in entries if entry["helper_path"] == execution["helper_path"]]
    if len(matched) != 1:
        raise ValueError("program_changed")
    entry = matched[0]
    name = os.path.basename(entry["helper_path"])
    expected = VERSIONS.get(name)
    if expected is None or entry["helper_sha256"] != expected or execution["helper_sha256"] != expected:
        raise ValueError("program_changed")
    if entry["companion_sha256"] != COMPANION_SHA256 or execution["companion_sha256"] != COMPANION_SHA256 or execution["companion_path"] != entry["companion_path"] or entry["companion_path"] != os.path.dirname(entry["helper_path"]) + "/worker_file_companion.py":
        raise ValueError("program_changed")
    for path, digest in ((current + "/" + name, expected), (current + "/worker_file_companion.py", COMPANION_SHA256)):
        outside(path, execution)
        if sha(regular(path, 1_048_576)) != digest:
            raise ValueError("program_changed")
    outside(entry["manifest_path"], execution)
    manifest_raw = regular(entry["manifest_path"], 4_194_304)
    if sha(manifest_raw) != entry["manifest_sha256"]:
        raise ValueError("program_changed")
    manifest = decode(manifest_raw)
    if entry["kind"] == "RELEASE_ARTIFACT_V2":
        release = entry["release_root"]
        if entry["manifest_path"] != release + "/evidence/release-manifest.json" or manifest.get("kind") != entry["expected_manifest_kind"]:
            raise ValueError("program_changed")
    else:
        release = manifest["release"]
    if not absolute(release):
        raise ValueError("program_changed")
    descriptor = directory(release)
    os.close(descriptor)
    for kind in ("helper", "companion"):
        path = entry["artifact_" + kind + "_path"]
        relative = "lib/symphony_elixir/priv/" + os.path.basename(entry[kind + "_path"])
        digest = entry[kind + "_sha256"]
        allowed = (release + "/dev/" + relative,) if entry["kind"] == "RELEASE_ARTIFACT_V2" else (release + "/" + relative, release + "/dev/" + relative)
        if path not in allowed or manifest["artifact"].get(relative) != {"sha256": digest}:
            raise ValueError("program_changed")
        outside(path, execution)
        if sha(regular(path, 1_048_576)) != digest:
            raise ValueError("program_changed")
    if entry["kind"] in ("RELEASE_ARTIFACT_V1", "RELEASE_ARTIFACT_V2"):
        if any(entry[kind + "_path"] != entry["artifact_" + kind + "_path"] for kind in ("helper", "companion")):
            raise ValueError("program_changed")
    else:
        raw = entry["compile_proof_raw"]
        if not isinstance(raw, str) or len(raw.encode()) > 65_536 or sha(raw.encode()) != manifest["compile_proof_sha256"]:
            raise ValueError("program_changed")
        proof = decode(raw)
        source = proof["source_root"]
        if not absolute(source) or proof.get("kind") != "EMPTY_CHILD_PRIVATE_COMPILE_V1" or proof.get("exit_code") != 0 or proof.get("source_prepost_equal") is not True or proof.get("old_artifact_unchanged") is not True:
            raise ValueError("program_changed")
        for kind in ("helper", "companion"):
            relative = "elixir/priv/" + os.path.basename(entry[kind + "_path"])
            digest = entry[kind + "_sha256"]
            if entry[kind + "_path"] != source + "/" + relative or proof["inputs"].get(relative) != digest or manifest["source"].get(relative) != {"sha256": digest}:
                raise ValueError("program_changed")

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
    if select.select([sys.stdin.fileno()], [], [], 0)[0] and os.read(sys.stdin.fileno(), 1):
        raise ValueError("frame_rejected")
    value = decode(raw)
    if not isinstance(value, dict) or set(value) != {"execution_json", "helper_pid"} or type(value["helper_pid"]) is not int or value["helper_pid"] <= 0 or not isinstance(value["execution_json"], str):
        raise ValueError("packet_rejected")
    execution = decode(value["execution_json"])
    if len(value["execution_json"].encode()) > execution_limit(execution):
        raise ValueError("execution_changed")
    if not isinstance(execution, dict) or not isinstance(execution.get("invocation"), str) or re.fullmatch("[0-9a-f]{64}", execution["invocation"]) is None:
        raise ValueError("nonce_rejected")
    binding_raw = execution["intent_json"]
    if not isinstance(binding_raw, str) or sha(binding_raw.encode()) != execution["intent_sha256"] or decode(binding_raw)["run_id"] != execution["run_id"]:
        raise ValueError("execution_changed")
    return value, execution

def read_status(value, execution, spool):
    nonce = execution["invocation"]
    receipt_limit = RECEIPT_LIMIT if os.path.basename(execution["helper_path"]) in ("ticket_push_executor_v12.py", "ticket_push_executor_v13.py", "ticket_push_executor_v14.py") else 1_048_576
    try:
        raw = read_at(spool, nonce + ".push-rejection", receipt_limit)
    except FileNotFoundError:
        if read_at(spool, nonce + ".push-claim", execution_limit(execution)) != value["execution_json"].encode():
            raise ValueError("claim_changed")
        raw = read_at(spool, nonce + ".push-receipt", receipt_limit)
        receipt = decode(raw)
        keys = {"version", "execution_json", "helper_pid", "child_pid", "termination", "timed_out", "overflow", "output_base64", "output_sha256", "stderr_code", "stderr_bytes", "stderr_sha256"}
        if set(receipt) != keys or type(receipt.get("version")) is not int or receipt["version"] != 1 or receipt.get("execution_json") != value["execution_json"] or type(receipt.get("helper_pid")) is not int or receipt["helper_pid"] != value["helper_pid"] or type(receipt.get("child_pid")) is not int or receipt["child_pid"] <= 0:
            raise ValueError("receipt_rejected")
        output = base64.b64decode(receipt["output_base64"], validate=True)
        if len(output) > 65_536 or sha(output) != receipt["output_sha256"] or type(receipt.get("timed_out")) is not bool or type(receipt.get("overflow")) is not bool:
            raise ValueError("receipt_rejected")
        termination = receipt["termination"]
        exited = isinstance(termination, dict) and set(termination) == {"kind", "code"} and termination["kind"] == "exited" and type(termination["code"]) is int and 0 <= termination["code"] <= 255
        signaled = isinstance(termination, dict) and set(termination) == {"kind", "signal"} and termination["kind"] == "signaled" and type(termination["signal"]) is int and 1 <= termination["signal"] <= 64
        if not (exited or signaled) or receipt["stderr_code"] not in ("GIT_EXIT_ZERO", "GIT_EXIT_NONZERO", "AUTHENTICATION_DENIED", "TRANSPORT_FAILURE") or type(receipt["stderr_bytes"]) is not int or not 0 <= receipt["stderr_bytes"] <= 16_384 or not isinstance(receipt["stderr_sha256"], str) or re.fullmatch("[0-9a-f]{64}", receipt["stderr_sha256"]) is None:
            raise ValueError("receipt_rejected")
        return raw
    rejected = decode(raw)
    keys = {"version", "kind", "execution_json", "helper_pid", "child_pid", "reason"}
    if set(rejected) != keys or type(rejected.get("version")) is not int or rejected["version"] != 1 or rejected.get("kind") != "PREISSUANCE_REJECTED" or rejected.get("execution_json") != value["execution_json"] or type(rejected.get("helper_pid")) is not int or rejected["helper_pid"] != value["helper_pid"] or rejected.get("child_pid") is not None or not isinstance(rejected.get("reason"), str) or re.fullmatch("[A-Za-z_]{1,80}", rejected["reason"]) is None:
        raise ValueError("rejection_changed")
    for suffix in (".push-claim", ".push-receipt"):
        try:
            read_at(spool, nonce + suffix, receipt_limit if suffix == ".push-receipt" else execution_limit(execution))
        except FileNotFoundError:
            continue
        raise ValueError("rejection_conflicts_with_issuance")
    return raw

def execution_limit(execution):
    return LIMIT if os.path.basename(execution["helper_path"]) in ("ticket_push_executor_v12.py", "ticket_push_executor_v13.py", "ticket_push_executor_v14.py") else 262_144

def main():
    if sys.argv[1:] != ["--status"]:
        raise ValueError("mode_rejected")
    value, execution = packet()
    provenance(execution)
    spool = open_spool(execution)
    try:
        raw = read_status(value, execution, spool)
        sys.stdout.buffer.write(len(raw).to_bytes(4, "big") + raw)
        sys.stdout.buffer.flush()
    finally:
        os.close(spool)

if __name__ == "__main__":
    main()
