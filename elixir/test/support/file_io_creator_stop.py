"""Stop the real owned helper after durable creator attestation, before its ACK."""
import importlib.util
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

companion, database, invocation = sys.argv[1:]
helper = str(pathlib.Path(companion).with_name("worker_file_io.py"))
children = []
original = subprocess.Popen


class SourceChild(original):
    def __init__(self, command, *args, **kwargs):
        super().__init__(command, *args, **kwargs)
        if isinstance(command, list) and command[0] == "/usr/bin/sandbox-exec" and helper in command:
            children.append(self)


spec = importlib.util.spec_from_file_location("factory_creator_stop_fixture", companion)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_publish = module.publish
original_frame = module.child_frame


def child_frame(stream, deadline):
    raw = original_frame(stream, deadline)
    mode = pathlib.Path(database).parent / "creator-stop-mode"
    event = json.loads(raw)
    if mode.exists() and mode.read_text(encoding="ascii") == "pid-mismatch" and event.get("event") == "TEMP_CREATED":
        event["pid"] += 1
        return json.dumps(event, separators=(",", ":")).encode("utf-8")
    return raw


def publish(parent, name, data):
    mode_path = pathlib.Path(database).parent / "creator-stop-mode"
    mode = mode_path.read_text(encoding="ascii") if mode_path.exists() else ""
    if name == invocation + ".receipt" and mode in {"receipt-loss", "receipt-loss-applied", "receipt-barrier"}:
        terminal = json.loads(module.read_at(parent, invocation + ".terminal", 4_194_304))
        cleanup = json.loads(module.read_at(parent, invocation + ".cleanup", 16384))
        observed = {"companion_pid": os.getpid(), "primary_pid": terminal["pid"], "cleanup_pid": cleanup["pid"]}
        (pathlib.Path(database).parent / "companion-stop-observed").write_text(json.dumps(observed), encoding="utf-8")
        if mode == "receipt-barrier":
            release = pathlib.Path(database).parent / "companion-release"
            deadline = time.monotonic() + 3
            while not release.exists():
                if time.monotonic() >= deadline:
                    raise RuntimeError("final-publication barrier expired")
                time.sleep(0.01)
        else:
            os.kill(os.getpid(), signal.SIGKILL)
    original_publish(parent, name, data)
    if name == invocation + ".creator":
        creator = json.loads(data)
        child = children[-1]
        if child.poll() is not None:
            raise RuntimeError("creator fault requires a live owned helper")
        binding = json.loads(module.read_at(parent, invocation + ".claim", module.MAX_FRAME))
        temporary = pathlib.Path(binding["root"]) / pathlib.Path(creator["path"]).parent / creator["temporary"]
        info = temporary.lstat()
        observed = {"pid": child.pid, "device": info.st_dev, "inode": info.st_ino, "bytes": info.st_size}
        if mode == "replacement":
            temporary.rename(temporary.with_name(temporary.name + ".preserved"))
            temporary.write_bytes(b"unrelated replacement\n")
            observed["replacement_inode"] = temporary.lstat().st_ino
        (pathlib.Path(database).parent / "creator-stop-observed").write_text(json.dumps(observed), encoding="utf-8")
        if mode not in {"receipt-loss-applied", "receipt-barrier"}:
            child.kill()


module.subprocess.Popen = SourceChild
module.publish = publish
module.child_frame = child_frame
sys.argv = [companion, database, invocation]
module.main()
