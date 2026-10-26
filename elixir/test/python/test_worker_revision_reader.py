import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "priv" / "worker_revision_reader_v1.py"
TRANSPORT = SOURCE.parent.parent / "lib" / "symphony_elixir" / "factory" / "worker_file_io.ex"
REVISION_PROFILE = json.loads(re.search(r'@revision_profile ("[^\n]+")', TRANSPORT.read_text())[1])
SPEC = importlib.util.spec_from_file_location("revision_reader", SOURCE)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class RevisionReaderTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = os.path.realpath(self.temporary.name)
        self.git("init")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.test")
        files = {"file": b"base\r\n", "[literal] é space": b"exact\n", "binary": b"\x00\xff\r\n", "limit": b"a" * 262_144, "oversized": b"b" * 262_145, "executable": b"exec\n"}
        for name, raw in files.items():
            Path(self.root, name).write_bytes(raw)
        Path(self.root, "executable").chmod(0o755)
        Path(self.root, "link").symlink_to("file")
        Path(self.root, "folder").mkdir()
        Path(self.root, "folder", "child").write_bytes(b"child")
        self.git("add", ".")
        self.git("commit", "--no-verify", "-m", "base")
        self.sha = self.git("rev-parse", "HEAD").decode().strip()
        metadata = str(Path(self.root, ".git"))
        info = os.stat(self.root)
        self.request = {"version": 1, "nonce": "fixture", "root": self.root, "device": info.st_dev, "inode": info.st_ino, "operation": "revision", "arguments": {"path": "file", "revision": self.sha, "expected_sha": self.sha, "branch": self.git("symbolic-ref", "--short", "HEAD").decode().strip(), "git_dir": metadata, "common_dir": metadata, "binary": False}}

    def git(self, *args):
        return subprocess.check_output([READER.GIT, "-C", self.root, *args], stderr=subprocess.STDOUT)

    def read(self, **arguments):
        return READER.operate({**self.request, "arguments": {**self.request["arguments"], **arguments}})

    def test_regular_modes_literal_paths_and_missing_working_file(self):
        Path(self.root, "file").unlink()
        self.assertEqual(self.read()["text"], "base\r\n")
        self.assertEqual(self.read(path="[literal] é space")["text"], "exact\n")
        self.assertEqual(self.read(path="executable")["mode"], "100755")

    def test_nonregular_and_control_paths_are_rejected(self):
        self.git("update-index", "--add", "--cacheinfo", "160000," + self.sha + ",submodule")
        self.git("commit", "--no-verify", "-m", "gitlink")
        current = self.git("rev-parse", "HEAD").decode().strip()
        self.request["arguments"].update(revision=current, expected_sha=current)
        for path in ("link", "submodule", "folder", "missing", "../file", "/file", ".git/config", ".ENV.secret", "folder/../file", "a\nfile", ":(glob)*"):
            with self.subTest(path=path), self.assertRaises(READER.Rejected):
                self.read(path=path)

    def test_exact_file_limit_binary_and_utf8(self):
        self.assertEqual(self.read(path="limit")["total_bytes"], 262_144)
        self.assertEqual(self.read(path="binary", binary=True)["content_base64"], "AP8NCg==")
        with self.assertRaises((UnicodeError, READER.Rejected)):
            self.read(path="binary")
        with self.assertRaises(READER.Rejected):
            self.read(path="oversized", binary=True)

    def test_revision_and_physical_identity_changes_fail_closed(self):
        for changes in ({"revision": "HEAD"}, {"revision": self.sha[:8]}, {"revision": "a" * 40}, {"expected_sha": "a" * 40}, {"branch": "foreign"}, {"git_dir": self.root}, {"common_dir": self.root}):
            with self.subTest(changes=changes), self.assertRaises(READER.Rejected):
                self.read(**changes)
        with self.assertRaises(READER.Rejected):
            READER.operate({**self.request, "inode": self.request["inode"] + 1})
        payloads = [b"null", b"{", json.dumps({**self.request, "unexpected": True}).encode()]
        frames = [len(raw).to_bytes(4, "big") + raw for raw in payloads]
        frames += [b"\x00\x00", (READER.MAX_FRAME + 1).to_bytes(4, "big"), (20).to_bytes(4, "big") + b"{}"]
        for frame in frames:
            result = subprocess.run(["/usr/bin/python3", "-I", "-S", "-B", str(SOURCE)], input=frame, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5, env={})
            self.assertEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
            self.assertEqual(int.from_bytes(result.stdout[:4], "big"), len(result.stdout) - 4)
            self.assertIs(json.loads(result.stdout[4:])["ok"], False)

    def test_replacement_objects_and_executable_local_config_cannot_change_blob(self):
        marker = Path(self.root, "executed")
        command = "echo forbidden > " + str(marker)
        for key in ("core.fsmonitor", "filter.evil.smudge", "filter.evil.clean"):
            self.git("config", key, command)
        self.git("config", "core.hooksPath", self.root)
        hook = Path(self.root, "post-checkout")
        hook.write_text("#!/bin/sh\n" + command + "\n")
        hook.chmod(0o755)
        old = self.git("rev-parse", self.sha + ":file").decode().strip()
        replacement = self.git("rev-parse", self.sha + ":executable").decode().strip()
        self.git("replace", old, replacement)
        self.assertEqual(self.read()["text"], "base\r\n")
        self.assertFalse(marker.exists())

    def test_missing_promisor_object_never_fetches(self):
        blob = self.git("rev-parse", self.sha + ":file").decode().strip()
        Path(self.root, ".git", "objects", blob[:2], blob[2:]).unlink()
        marker = Path(self.root, "fetched")
        self.git("config", "extensions.partialClone", "evil")
        self.git("config", "remote.evil.promisor", "true")
        self.git("config", "remote.evil.url", "ext::sh -c 'touch " + str(marker) + "'")
        with self.assertRaises(READER.Rejected):
            self.read()
        self.assertFalse(marker.exists())

    def test_external_alternate_objects_are_rejected(self):
        Path(self.root, ".git", "objects", "info", "alternates").write_text("/tmp/foreign-objects\n")
        with self.assertRaises(READER.Rejected):
            self.read()

    def test_bounded_git_transport_kills_and_reaps_stalled_or_overflow_child(self):
        script = Path(self.root, "fixed-test-child")
        for body in ("import time; time.sleep(30)", "import os; os.write(1,b'x'*10000)"):
            script.write_text("#!/usr/bin/python3\n" + body + "\n")
            script.chmod(0o755)
            start = time.monotonic()
            with patch.object(READER, "GIT", str(script)), self.assertRaises(READER.Rejected):
                READER.git(self.root, [], 64, start + 0.15)
            self.assertLess(time.monotonic() - start, 2)

    def test_revision_sandbox_denies_source_control_writes_and_network_but_reaps_child(self):
        profile = REVISION_PROFILE
        code = """
import os,socket,subprocess,sys
for path in [sys.argv[1]+'/forbidden',sys.argv[1]+'/.git/config']:
    try:
        descriptor=os.open(path,os.O_WRONLY|os.O_CREAT,0o600)
    except PermissionError:
        pass
    else:
        os.close(descriptor)
        raise AssertionError('write admitted')
try:
    connection=socket.socket()
    connection.connect(('127.0.0.1',9))
except PermissionError:
    pass
else:
    raise AssertionError('network admitted')
child=subprocess.Popen(['/bin/sleep','30'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
child.stdin.close()
child.kill()
assert child.wait(timeout=2)<0
try:
    os.kill(os.getppid(),0)
except PermissionError:
    pass
else:
    raise AssertionError('parent signal admitted')
"""
        result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/python3", "-I", "-S", "-B", "-c", code, self.root], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={}, timeout=4)
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        self.assertFalse(Path(self.root, "forbidden").exists())

    def test_fixed_reader_serves_regular_blob_without_worktree_reads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = os.path.realpath(temporary)

            def git(*args):
                return subprocess.check_output([READER.GIT, "-C", root, *args], stderr=subprocess.STDOUT)

            git("init")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.test")
            Path(root, "file").write_bytes(b"base\r\n")
            git("add", "file")
            git("commit", "--no-verify", "-m", "base")
            sha = git("rev-parse", "HEAD").decode().strip()
            branch = git("symbolic-ref", "--short", "HEAD").decode().strip()
            metadata = os.path.join(root, ".git")
            info = os.stat(root)
            request = {"version": 1, "nonce": "fixture", "root": root, "device": info.st_dev, "inode": info.st_ino, "operation": "revision", "arguments": {"path": "file", "revision": sha, "expected_sha": sha, "branch": branch, "git_dir": metadata, "common_dir": metadata, "binary": False}}
            Path(root, "file").unlink()
            self.assertEqual(READER.operate(request)["text"], "base\r\n")
            code = "import json,runpy,sys; module=runpy.run_path(sys.argv[1]); print(module['operate'](json.load(sys.stdin)))"
            profile = REVISION_PROFILE
            sandboxed = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/python3", "-I", "-S", "-B", "-c", code, str(SOURCE)], input=json.dumps(request).encode(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={})
            self.assertEqual(sandboxed.returncode, 0, sandboxed.stdout.decode())


if __name__ == "__main__":
    unittest.main()
