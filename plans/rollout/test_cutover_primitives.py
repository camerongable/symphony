"""Exercise cutover commands with real disposable processes and SQLite, never launchd."""
from contextlib import closing, contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


@contextmanager
def fixture():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory).resolve()
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        guard = module('cutover_guard')
        guard.ROOT, guard.DB, guard.PLIST = root, root / 'factory.sqlite', root / 'service.plist'
        guard.SERVICE = 'fixture-never-a-live-service'
        guard.OLD_PID, guard.OLD_START = str(child.pid), guard.identity(child.pid)
        guard.PLIST.write_bytes(b'original plist fixture')
        shutil.copy2(TOOLS / 'thaw_guardian.py', root / 'thaw_guardian.py')
        with closing(sqlite3.connect(guard.DB)) as db:
            db.executescript('''
CREATE TABLE control(scope TEXT,status TEXT,tick_id TEXT,lease_expires_at TEXT);
INSERT INTO control VALUES('assigned-jira-work','PAUSED',NULL,NULL);
CREATE TABLE factory_tasks(status TEXT);
CREATE TABLE worker_file_operations(phase TEXT,io_pending INTEGER);
CREATE TABLE controller_checks(phase TEXT);
CREATE TABLE worker_evidence(owner_process_json TEXT,owner_stopped_at TEXT);
CREATE TABLE protected_result(value TEXT);
INSERT INTO protected_result VALUES('original receipt');
''')

        @contextmanager
        def readonly():
            db = sqlite3.connect(guard.DB.as_uri() + '?mode=ro', uri=True)
            try:
                db.execute('PRAGMA query_only=ON')
                yield db
            finally:
                db.close()

        guard.readonly = readonly
        with readonly() as db:
            original = guard.logical_digest(db)
        pins = {'fixture': 'same controls'}
        guard.configuration = lambda: pins
        guard.old_binding = lambda _idle: None
        guard.native_quiet = lambda: None
        guard.native_runtime_admit = lambda _operation: None
        audit = {'fixture': 'bound protected snapshot'}
        guard.qualified = guard.candidate = lambda: ({}, {}, audit)

        def protected(value):
            assert value == audit
            with readonly() as db:
                assert guard.logical_digest(db) == original
            return b'protected'

        guard.protected = protected
        guard.save('captured.json', {'configuration': pins, 'plist_sha256': guard.sha(guard.PLIST)})
        guard.save('cutover-audit.json', audit)
        service_calls = []
        actual_run = subprocess.run

        def process_boundary(args, **kwargs):
            if args[0] != '/bin/launchctl':
                return actual_run(args, **kwargs)
            assert args[-1] == guard.SERVICE
            if args[1] == 'print':
                return subprocess.CompletedProcess(args, 1, '', 'fixture absent')
            assert args[1] == 'bootout'
            service_calls.append(args)
            os.kill(child.pid, signal.SIGKILL)
            child.wait(timeout=3)
            return subprocess.CompletedProcess(args, 0, '', '')

        refused = urllib.error.URLError(ConnectionRefusedError(61, 'fixture port absent'))
        try:
            with patch.object(guard.subprocess, 'run', side_effect=process_boundary), patch.object(guard.urllib.request, 'urlopen', side_effect=refused):
                yield guard, child, service_calls, original
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and list(root.glob('watchdog-*.armed.json')) and not list(root.glob('watchdog-*.done.json')):
                time.sleep(0.05)


class CutoverPrimitiveTests(unittest.TestCase):
    def test_finish_stop_recovers_interrupted_backup_without_reissuing_service_operations(self):
        for interruption in ('before_completion', 'after_completion', 'after_publish'):
            with self.subTest(interruption=interruption), fixture() as (guard, _child, calls, original):
                actual_connect, actual_save = sqlite3.connect, guard.save

                def connect(path, *args, **kwargs):
                    if Path(str(path)).name.startswith('before-cutover-'):
                        raise InterruptedError('fixture interrupted backup')
                    return actual_connect(path, *args, **kwargs)

                def save(name, value):
                    if name == 'stopped.json':
                        raise InterruptedError('fixture interrupted receipt')
                    return actual_save(name, value)

                boundary = patch.object(guard.sqlite3, 'connect', side_effect=connect) if interruption == 'before_completion' else (
                    patch.object(guard.os, 'link', side_effect=InterruptedError('fixture interrupted publication')) if interruption == 'after_completion' else patch.object(guard, 'save', side_effect=save))
                with boundary, self.assertRaises(InterruptedError):
                    guard.stop()
                self.assertFalse((guard.ROOT / 'stopped.json').exists())
                guard.finish_stop()
                self.assertEqual(len(calls), 1)
                with closing(sqlite3.connect(guard.ROOT / 'before-cutover.sqlite')) as backup:
                    self.assertEqual(guard.logical_digest(backup), original)

    def test_stop_proves_absence_and_keeps_a_read_only_verified_backup_without_replaying_bootout(self):
        with fixture() as (guard, child, calls, original):
            guard.stop()
            self.assertIsNotNone(child.poll())
            self.assertEqual(len(calls), 1)
            self.assertEqual(guard.load('stopped.json')['result'], 'EXACT_ISSUER_STOPPED')
            with closing(sqlite3.connect(guard.ROOT / 'before-cutover.sqlite')) as backup:
                self.assertEqual(guard.logical_digest(backup), original)
            guard.finish_stop()
            self.assertEqual(len(calls), 1)
            with self.assertRaises(AssertionError):
                guard.stop()
            self.assertEqual(len(calls), 1)

    def test_failed_postfreeze_admission_thaws_only_its_child_without_issuing_bootout(self):
        with fixture() as (guard, child, calls, _original):
            observations = []
            def native_quiet():
                observations.append(True)
                if len(observations) == 2:
                    raise RuntimeError('fixture became active after freeze')
            guard.native_quiet = native_quiet
            with self.assertRaisesRegex(RuntimeError, 'became active'):
                guard.stop()
            self.assertIsNone(child.poll())
            self.assertFalse(guard.stopped_issuer())
            self.assertEqual(calls, [])
            self.assertEqual(len(list(guard.ROOT.glob('watchdog-*.cancelled.json'))), 1)

    def test_guardian_thaws_before_bootout_but_never_after_an_issued_marker(self):
        for committed in (False, True):
            with self.subTest(committed=committed), fixture() as (guard, child, calls, _original):
                guardian = module('thaw_guardian')
                prefix = guard.ROOT / 'watchdog-fixture'
                Path(str(prefix) + '.gate').touch()
                binding = {'nonce': 'fixture', 'old_pid': child.pid, 'process_start_identity': guard.OLD_START}
                os.kill(child.pid, signal.SIGSTOP)
                deadline = time.monotonic() + 3
                while not guard.stopped_issuer():
                    self.assertLess(time.monotonic(), deadline)
                if committed:
                    Path(str(prefix) + '.bootout-issued.json').write_text(json.dumps(binding))
                result = guardian.finalize(prefix, binding, child.pid, guard.OLD_START)
                if committed:
                    self.assertEqual(result, 'BOOTOUT_COMMITTED_NO_THAW_MANUAL_AUDIT_IF_NEEDED')
                    self.assertTrue(guard.stopped_issuer())
                else:
                    self.assertEqual(result, 'EXACT_ISSUER_THAWED')
                self.assertEqual(calls, [])

    def test_unbound_rollback_refuses_before_any_process_or_service_operation(self):
        guard = module('cutover_guard')
        with patch.object(guard.subprocess, 'run', side_effect=AssertionError('service operation before admission')) as run:
            with self.assertRaisesRegex(RuntimeError, 'callback is not bound'):
                guard.restore_original()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
