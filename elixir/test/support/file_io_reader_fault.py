"""Real negative reader transports; no successful receipt or source operation."""
import json
import signal
import struct
import sys
import time

kind, mode = sys.argv[1:]
if kind not in {"request", "status", "spool"}:
    raise ValueError("reader protocol rejected")
signal.alarm(8)
if kind != "status":
    size = struct.unpack(">I", sys.stdin.buffer.read(4))[0]
    json.loads(sys.stdin.buffer.read(size))

if mode == "nonzero":
    sys.exit(23)
elif mode == "deadline":
    time.sleep(7)
elif mode == "overflow":
    sys.stdout.buffer.write(b"x" * 4_194_309)
elif mode == "truncated":
    sys.stdout.buffer.write(struct.pack(">I", 1024) + b"{")
elif mode == "malformed":
    sys.stdout.buffer.write(struct.pack(">I", 1) + b"{")
elif mode == "scalar":
    sys.stdout.buffer.write(struct.pack(">I", 2) + b"[]")
else:
    raise ValueError("reader fault rejected")
