"""Fixed bounded immutable-object ancestry reads; never fetches or changes refs."""
import json
import os
import select
import signal
import subprocess
import sys
import time

GIT = "/Library/Developer/CommandLineTools/usr/bin/git"


def main():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4 or not 0 < (size := int.from_bytes(header, "big")) <= 65_536:
        raise ValueError("input_rejected")
    value = json.loads(sys.stdin.buffer.read(size))
    args = value["arguments"]
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ValueError("operation_rejected")
    permitted = (len(args) == 4 and args[:2] == ["merge-base", "--is-ancestor"]
                 and all(len(value) == 40 and all(char in "0123456789abcdef" for char in value) for value in args[2:]))
    allowed_env = {"HOME", "PATH", "LC_ALL", "GIT_TERMINAL_PROMPT", "GIT_NO_LAZY_FETCH", "GIT_NO_REPLACE_OBJECTS", "SSH_AUTH_SOCK", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"}
    if not permitted or set(value) != {"root", "arguments", "environment"} or set(value["environment"]) - allowed_env or value["environment"]["GIT_TERMINAL_PROMPT"] != "0":
        raise ValueError("operation_rejected")
    owned = {"child": None, "stopped": False}

    def kill_owned_group():
        child = owned["child"]
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def stop(_signal=None, _frame=None):
        owned["stopped"] = True
        kill_owned_group()

    signals = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
    for item in signals:
        signal.signal(item, stop)

    def reap_owned():
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        try:
            # Darwin reports EPERM for a zombie-only group; bounded wait proves exit.
            kill_owned_group()
            child = owned["child"]
            code = child.wait(timeout=1)
            owned["child"] = None
            return code
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    output = bytearray()
    timeout = False
    try:
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        try:
            if owned["stopped"]:
                raise ValueError("caller_stopped")
            owned["child"] = subprocess.Popen([GIT, "--no-lazy-fetch", "--no-replace-objects", "-C", value["root"], "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + args,
                env=value["environment"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        child = owned["child"]
        deadline = time.monotonic() + 10
        while True:
            if time.monotonic() >= deadline or owned["stopped"]:
                timeout = True
                stop()
                break
            if select.select([child.stdout, sys.stdin], [], [], 0.1)[0]:
                ready = select.select([child.stdout, sys.stdin], [], [], 0)[0]
                if sys.stdin in ready and not os.read(sys.stdin.fileno(), 1):
                    stop()
                if child.stdout in ready:
                    chunk = os.read(child.stdout.fileno(), 16_384)
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) > 16_384:
                        stop()
                        break
        # Keep the leader unreaped until group cleanup so its PID cannot be reused.
        code = reap_owned()
        result = {"status": "TIMEOUT" if timeout else "PASS" if code == 0 and not owned["stopped"] else "FAIL", "output": output.decode() if code == 0 and len(output) <= 16_384 else ""}
        sys.stdout.write(json.dumps(result))
    finally:
        if owned["child"] is not None:
            reap_owned()
        if "child" in locals():
            child.stdout.close()


if __name__ == "__main__":
    main()
