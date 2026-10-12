"""External transport barrier before the real companion starts; no replacement helper."""
import json
import os
import pathlib
import subprocess
import sys
import time

companion, database, invocation = sys.argv[1:]
size_bytes = sys.stdin.buffer.read(4)
size = int.from_bytes(size_bytes, "big")
data = sys.stdin.buffer.read(size)
root = pathlib.Path(database).parent
(root / "dispatch-withheld").write_text(invocation, encoding="utf-8")
deadline = time.monotonic() + 6
while time.monotonic() < deadline and not (root / "dispatch-release").exists():
    time.sleep(0.01)
if not (root / "dispatch-release").exists():
    (root / "dispatch-finished").write_text("not released", encoding="utf-8")
    sys.exit(65)
child = subprocess.Popen(
    ["/usr/bin/python3", "-I", "-S", "-B", companion, database, invocation],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={},
)
response, _ = child.communicate(size_bytes + data)
completed = root / "dispatch-finished-prepared"
completed.write_text(
    json.dumps({"invocation": invocation, "exit_status": child.returncode}), encoding="utf-8",
)
os.replace(completed, root / "dispatch-finished")
if child.returncode != 0:
    sys.exit(child.returncode)
try:
    sys.stdout.buffer.write(response)
    sys.stdout.buffer.flush()
except BrokenPipeError:
    pass
