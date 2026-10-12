"""Fault at the OS process boundary: kill and reap the real owned source helper before input."""
import importlib.util
import pathlib
import subprocess
import sys

companion, database, invocation = sys.argv[1:]
helper = str(pathlib.Path(companion).with_name("worker_file_io.py"))
original = subprocess.Popen


class SignaledChild(original):
    def __init__(self, command, *args, **kwargs):
        self.source_child = isinstance(command, list) and command[0] == "/usr/bin/sandbox-exec" and helper in command
        super().__init__(command, *args, **kwargs)
        if self.source_child and self.poll() is None:
            self.kill()


spec = importlib.util.spec_from_file_location("factory_companion_fixture", companion)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.subprocess.Popen = SignaledChild
sys.argv = [companion, database, invocation]
module.main()
