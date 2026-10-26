"""Read two immutable commit objects; never fetch, update refs, or run hooks."""
import hashlib
import json
import os
import re
import select
import signal
import subprocess
import sys
import time

GIT = "/Library/Developer/CommandLineTools/usr/bin/git"
SHA = re.compile(r"[0-9a-f]{40}\Z")


def read_commit(root, commit):
    environment = {
        "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0",
        "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    child = None
    stopped = False

    def stop(_signum=None, _frame=None):
        nonlocal stopped
        stopped = True
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
    previous_handlers = {item: signal.signal(item, stop) for item in signals}
    try:
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        try:
            if stopped:
                raise ValueError("caller_stopped")
            child = subprocess.Popen(
                [GIT, "--no-lazy-fetch", "--no-replace-objects", "-C", root,
                 "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                 "cat-file", "commit", commit],
                env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, start_new_session=True,
            )
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        output = bytearray()
        deadline = time.monotonic() + 5
        while True:
            if stopped or time.monotonic() >= deadline:
                raise ValueError("read_stopped")
            ready = select.select([child.stdout, sys.stdin], [], [], 0.1)[0]
            if sys.stdin in ready and not os.read(sys.stdin.fileno(), 1):
                raise ValueError("caller_stopped")
            if child.stdout in ready:
                chunk = os.read(child.stdout.fileno(), 4096)
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > 65_536:
                    raise ValueError("output_rejected")
        # Keep the leader unreaped until its owned process group is stopped.
        stop()
        if child.wait(timeout=1) != 0:
            raise ValueError("read_failed")
        child.stdout.close()
        child = None
        raw = bytes(output)
        actual = hashlib.sha1(b"commit " + str(len(raw)).encode("ascii") + b"\0" + raw).hexdigest()
        headers, separator, _body = raw.partition(b"\n\n")
        if actual != commit or not separator:
            raise ValueError("object_rejected")
        lines = headers.split(b"\n")
        trees = [line[5:].decode("ascii") for line in lines if line.startswith(b"tree ")]
        parents = [line[7:].decode("ascii") for line in lines if line.startswith(b"parent ")]
        if len(trees) != 1 or not SHA.fullmatch(trees[0]) or not all(SHA.fullmatch(parent) for parent in parents):
            raise ValueError("object_rejected")
        return {"sha": commit, "tree": trees[0], "parents": parents}
    finally:
        if child is not None:
            stop()
            child.wait(timeout=1)
            child.stdout.close()
        for item, handler in previous_handlers.items():
            signal.signal(item, handler)


def main():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4 or not 0 < (size := int.from_bytes(header, "big")) <= 8192:
        raise ValueError("input_rejected")
    value = json.loads(sys.stdin.buffer.read(size))
    if set(value) != {"root", "previous", "candidate"}:
        raise ValueError("input_rejected")
    if not isinstance(value["root"], str) or not os.path.isabs(value["root"]):
        raise ValueError("root_rejected")
    for field in ("previous", "candidate"):
        if not isinstance(value[field], str) or not SHA.fullmatch(value[field]):
            raise ValueError("sha_rejected")
    previous = read_commit(value["root"], value["previous"])
    candidate = read_commit(value["root"], value["candidate"])
    if candidate["parents"] != [previous["sha"]] or candidate["tree"] != previous["tree"]:
        raise ValueError("empty_child_unproven")
    sys.stdout.write(json.dumps({"kind": "EMPTY_CHILD_OBJECTS_V1", "previous": previous, "candidate": candidate}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError):
        sys.exit(1)
