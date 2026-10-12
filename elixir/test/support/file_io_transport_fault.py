"""Bounded real transport failures before companion dispatch; never manufacture receipts."""
import json
import pathlib
import struct
import sys
import time

packet_size = struct.unpack(">I", sys.stdin.buffer.read(4))[0]
packet = json.loads(sys.stdin.buffer.read(packet_size))
operation = json.loads(packet["input"])
mode = operation["arguments"]["path"]
database = pathlib.Path(sys.argv[2])
(database.parent / "fault-started").write_text(mode, encoding="ascii")

if mode == "nonzero":
    sys.exit(23)
if mode == "truncated":
    sys.stdout.buffer.write(struct.pack(">I", 1024) + b"{")
elif mode == "overflow":
    sys.stdout.buffer.write(b"x" * 4_194_309)
elif mode == "deadline":
    time.sleep(7)
else:
    raise ValueError("unsupported fixture mode")
