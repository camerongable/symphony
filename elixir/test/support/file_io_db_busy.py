"""Hold a real SQLite writer lock after PREPARED admission, before companion execution."""
import sqlite3
import subprocess
import sys

companion, database, invocation = sys.argv[1:]
size_bytes = sys.stdin.buffer.read(4)
data = sys.stdin.buffer.read(int.from_bytes(size_bytes, "big"))
with sqlite3.connect(database, timeout=2) as connection:
    connection.execute("BEGIN IMMEDIATE")
    child = subprocess.Popen(
        ["/usr/bin/python3", "-I", "-S", "-B", companion, database, invocation],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={},
    )
    response, _ = child.communicate(size_bytes + data)
    connection.rollback()
if child.returncode != 0:
    sys.exit(child.returncode)
sys.stdout.buffer.write(response)
sys.stdout.buffer.flush()
