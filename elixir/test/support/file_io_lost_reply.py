"""External transport fault: relay to the real companion, then withhold its reply."""
import os
import pathlib
import subprocess
import sys
import time

companion, database, invocation = sys.argv[1:]
size_bytes = sys.stdin.buffer.read(4)
size = int.from_bytes(size_bytes, "big")
data = sys.stdin.buffer.read(size)
child = subprocess.Popen(
    ["/usr/bin/python3", "-I", "-S", "-B", companion, database, invocation],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={},
)
response, _ = child.communicate(size_bytes + data, timeout=5)
if child.returncode != 0:
    sys.exit(child.returncode)
marker = pathlib.Path(database).parent / "reply-withheld"
marker.write_text("terminal child receipt recorded\n", encoding="utf-8")
deadline = time.monotonic() + 3
while time.monotonic() < deadline and not (marker.parent / "reply-release").exists():
    time.sleep(0.01)
try:
    sys.stdout.buffer.write(response)
    sys.stdout.buffer.flush()
except BrokenPipeError:
    pass
