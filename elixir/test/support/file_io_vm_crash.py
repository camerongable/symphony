"""Kill and reap only the fixture BEAM after the actual companion published its receipt."""
import json
import os
import pathlib
import subprocess
import sys
import time

elixir, libraries, driver, database, transport = sys.argv[1:]
args = [elixir, "--erl", "+S 2"]
for ebin in sorted(pathlib.Path(libraries).glob("*/ebin")):
    args.extend(["-pa", str(ebin)])
args.extend([driver, database, transport])
environment = {"PATH": os.environ["PATH"], "LANG": "en_US.UTF-8"}
if "HOME" in os.environ:
    environment["HOME"] = os.environ["HOME"]
child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment)
marker = pathlib.Path(database).parent / "reply-withheld"
pid_marker = marker.parent / "controller-vm.pid"
deadline = time.monotonic() + 12
try:
    while not marker.exists() and child.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    vm_pid = int(pid_marker.read_text(encoding="ascii")) if pid_marker.exists() else None
    observed = marker.exists() and child.poll() is None and vm_pid == child.pid
    if child.poll() is None:
        child.kill()
    output, _ = child.communicate(timeout=5)
    print(json.dumps({"observed_terminal_helper": observed, "controller_pid": child.pid, "executing_vm_pid": vm_pid, "controller_returncode": child.returncode, "output": output.decode("utf-8", errors="replace")[-4096:]}))
finally:
    if child.poll() is None:
        child.kill()
        child.wait(timeout=5)
