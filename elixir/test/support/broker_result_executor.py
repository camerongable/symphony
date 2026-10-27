import json
import pathlib
import sys
import base64
import hashlib
import os
import time

with pathlib.Path(sys.argv[1]).open("a") as trace:
    trace.write("executed\n")
if len(sys.argv) > 3 and sys.argv[3] == "linked":
    running = pathlib.Path(sys.argv[2])
    body = b'{"ok":{"receipt":"external-complete"}}'
    known = running.with_suffix(".known")
    temporary = pathlib.Path(str(known) + ".writing." + "1" * 16)
    envelope = {
        "version": 1, "mailbox_id": running.stem,
        "database_root": str(running.parent.parent),
        "request_sha256": hashlib.sha256(running.read_bytes()).hexdigest(),
        "response_sha256": hashlib.sha256(body).hexdigest(),
        "response_base64": base64.b64encode(body).decode(),
    }
    with temporary.open("xb") as stream:
        os.chmod(temporary, 0o600)
        stream.write(json.dumps(envelope, separators=(",", ":")).encode())
        stream.flush()
        os.fsync(stream.fileno())
    os.link(temporary, known)
    pathlib.Path(sys.argv[1] + ".ready").write_text("ready")
    deadline = time.monotonic() + 5
    while not pathlib.Path(sys.argv[1] + ".release").exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("release missing")
        time.sleep(0.01)
    temporary.unlink()
elif len(sys.argv) > 3 and sys.argv[3] == "finish":
    running = pathlib.Path(sys.argv[2])
    running.rename(running.with_suffix(".finished"))
elif len(sys.argv) > 3 and sys.argv[3] == "conflict":
    pathlib.Path(sys.argv[2]).write_text('{"ok":"conflicting outcome"}')
elif len(sys.argv) > 2:
    pathlib.Path(sys.argv[2]).mkdir()
print(json.dumps({"receipt": "external-complete"}, separators=(",", ":")))
