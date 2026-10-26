"""Read one regular Git blob from the controller-bound immutable review base."""
import base64
import hashlib
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import unicodedata

MAX_FRAME = 2_097_152
MAX_FILE = 262_144
GIT = "/Library/Developer/CommandLineTools/usr/bin/git"
BLOCKED = {".git", ".codex", ".agents", ".env", ".ssh", ".aws", ".config", ".factory-file-io", "node_modules", "_build", "deps"}


class Rejected(Exception):
    pass


def require(condition, code):
    if not condition:
        raise Rejected(code)


def path_parts(path):
    require(isinstance(path, str) and 1 <= len(path.encode("utf-8")) <= 1024, "path_rejected")
    require(not any(char in path for char in "\x00\\\r\n"), "path_rejected")
    parts = path.split("/")
    for part in parts:
        folded = unicodedata.normalize("NFC", part).casefold()
        require(part not in ("", ".", "..") and folded not in BLOCKED and not folded.startswith((".env.", ".symphony-")), "path_rejected")
    return parts


def directory(path):
    require(isinstance(path, str) and path.startswith("/") and os.path.normpath(path) == path, "identity_rejected")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split("/")[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def identity(fd):
    value = os.fstat(fd)
    require(stat.S_ISDIR(value.st_mode), "identity_rejected")
    return value.st_dev, value.st_ino


def git(root, args, limit, deadline):
    command = [GIT, "--no-lazy-fetch", "--no-replace-objects", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.pager=cat", "-C", root] + args
    env = {"PATH": "/usr/bin:/bin", "HOME": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_COUNT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1", "LC_ALL": "C"}
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    process.stdin.close()
    output = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0, "git_deadline")
                require(selector.select(remaining), "git_deadline")
                chunk = os.read(process.stdout.fileno(), min(65_536, limit + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                require(len(output) <= limit, "git_output_limit")
        require(process.wait(timeout=max(deadline - time.monotonic(), 0.001)) == 0, "git_rejected")
        return bytes(output)
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        process.stdout.close()


def checkout(root, args, deadline):
    actual_git = git(root, ["rev-parse", "--absolute-git-dir"], 4096, deadline).decode("utf-8").rstrip("\n")
    actual_common = git(root, ["rev-parse", "--git-common-dir"], 4096, deadline).decode("utf-8").rstrip("\n")
    require(os.path.realpath(actual_git) == args["git_dir"] and os.path.realpath(os.path.join(root, actual_common)) == args["common_dir"], "git_identity_changed")
    require(git(root, ["rev-parse", "--verify", "HEAD"], 64, deadline) == (args["expected_sha"] + "\n").encode(), "head_changed")
    require(git(root, ["symbolic-ref", "--quiet", "HEAD"], 2048, deadline) == ("refs/heads/" + args["branch"] + "\n").encode(), "branch_changed")


def operate(request):
    require(set(request) == {"version", "nonce", "root", "device", "inode", "operation", "arguments"} and request["version"] == 1 and request["operation"] == "revision", "request_rejected")
    args = request["arguments"]
    require(isinstance(args, dict) and set(args) == {"path", "revision", "expected_sha", "branch", "git_dir", "common_dir", "binary"}, "request_rejected")
    path_parts(args["path"])
    require(all(isinstance(args[key], str) and re.fullmatch(r"[0-9a-f]{40}", args[key]) for key in ("revision", "expected_sha")), "revision_rejected")
    require(isinstance(args["branch"], str) and isinstance(args["binary"], bool), "request_rejected")
    deadline = time.monotonic() + 3.5
    descriptors = [directory(request["root"]), directory(args["git_dir"]), directory(args["common_dir"])]
    try:
        initial = [identity(fd) for fd in descriptors]
        require(initial[0] == (request["device"], request["inode"]), "root_identity_changed")
        require(not os.path.lexists(os.path.join(args["common_dir"], "objects", "info", "alternates")), "external_objects_rejected")
        checkout(request["root"], args, deadline)
        require(git(request["root"], ["cat-file", "-t", args["revision"]], 16, deadline) == b"commit\n", "revision_rejected")
        tree = git(request["root"], ["ls-tree", "-z", args["revision"], "--", args["path"]], 2048, deadline)
        match = re.fullmatch(rb"(100644|100755) blob ([0-9a-f]{40})\t" + re.escape(args["path"].encode()) + b"\x00", tree)
        require(match is not None, "regular_blob_required")
        blob = match[2].decode()
        size_raw = git(request["root"], ["cat-file", "-s", blob], 32, deadline)
        require(re.fullmatch(rb"[0-9]+\n", size_raw) is not None, "blob_size_rejected")
        size = int(size_raw)
        require(size <= MAX_FILE, "file_too_large")
        raw = git(request["root"], ["cat-file", "blob", blob], MAX_FILE, deadline)
        require(len(raw) == size, "blob_changed")
        checkout(request["root"], args, deadline)
        for index, path in enumerate((request["root"], args["git_dir"], args["common_dir"])):
            current = directory(path)
            try:
                require(identity(current) == initial[index] == identity(descriptors[index]), "identity_changed")
            finally:
                os.close(current)
        result = {"revision": args["revision"], "blob_oid": blob, "mode": match[1].decode(), "sha256": hashlib.sha256(raw).hexdigest(), "total_bytes": len(raw)}
        if args["binary"]:
            result["content_base64"] = base64.b64encode(raw).decode("ascii")
        else:
            require(b"\x00" not in raw, "non_text")
            result["text"] = raw.decode("utf-8", errors="strict")
        return result
    finally:
        for fd in descriptors:
            os.close(fd)


def main():
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(4)
    request = {}
    try:
        header = sys.stdin.buffer.read(4)
        require(len(header) == 4 and 1 <= int.from_bytes(header, "big") <= MAX_FRAME, "frame_rejected")
        data = sys.stdin.buffer.read(int.from_bytes(header, "big"))
        require(len(data) == int.from_bytes(header, "big"), "frame_rejected")
        request = json.loads(data)
        require(isinstance(request, dict), "request_rejected")
        result = operate(request)
        response = {"version": 1, "nonce": request["nonce"], "ok": True, "result": result}
    except (Rejected, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        response = {"version": 1, "nonce": request.get("nonce") if isinstance(request, dict) else None, "ok": False, "error": str(error) if isinstance(error, Rejected) else "revision_read_rejected:" + type(error).__name__}
    encoded = json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    require(len(encoded) <= MAX_FRAME, "frame_rejected")
    sys.stdout.buffer.write(len(encoded).to_bytes(4, "big") + encoded)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
