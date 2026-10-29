"""Synthetic native format admission and generated-launcher boundaries; no service operations."""

import importlib.util
import hashlib
import fcntl
import os
import shutil
import subprocess
import json
import plistlib
from datetime import datetime, timezone
from pathlib import Path
import sqlite3
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from contextlib import contextmanager
from contextlib import ExitStack

ROOT = Path(__file__).resolve().parent
QUALIFIED = Path('/private/tmp/symphony-review-contract.gTnJeO/reliability-combined/elixir/_build/test/lib')
ELIXIR_BIN = Path('/Users/cgable/.local/share/mise/installs/elixir/1.19.5-otp-28/bin')
ERLANG_BIN = Path('/Users/cgable/.local/share/mise/installs/erlang/28.5/bin')


def load(name):
    spec = importlib.util.spec_from_file_location('admission_test_' + name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CompatibilityTests(unittest.TestCase):
    def test_generated_launcher_selects_workflow_before_restoring_configured_origin(self):
        with generated_launcher() as fixture:
            root = fixture['root']
            home, sqlite = root / 'codex', root / 'sqlite'
            home.mkdir(mode=0o700)
            sqlite.mkdir(mode=0o700)
            origin = {'version': 2, 'codex_home': directory_identity(home), 'sqlite_home': directory_identity(sqlite)}
            default = Path(fixture['manifest']['source_root']) / 'elixir/WORKFLOW.md'
            default.write_text('---\ntracker:\n  kind: linear\n---\nUnselected default requires unavailable credentials.\n')
            workflow = root / 'selected-workflow.md'
            workflow.write_text('---\ntracker:\n  kind: memory\nfactory:\n  enabled: false\n  ticket_supervisor:\n    native_runtime: ' + json.dumps(origin) + '\n---\nSelected workflow.\n')
            result = fixture['run'](workflow)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(fixture['sentinel'].exists())

    def test_manifest_formats_are_target_specific_and_strictly_typed(self):
        helper = load('native_runtime_compatibility')
        legacy = {'worker_binding_versions': [1], 'completion_receipt_versions': [1]}
        self.assertEqual(helper.validate_manifest({}), legacy)
        self.assertEqual(helper.validate_manifest({'native_runtime_formats': legacy}), legacy)
        for bindings in ([1], [1, 2]):
            for receipts in ([1], [1, 2]):
                target = {'worker_binding_versions': bindings, 'completion_receipt_versions': receipts}
                self.assertEqual(helper.validate_manifest({'native_runtime_formats': target}), target)
        for bad in (None, [], {}, {**legacy, 'extra': [1]},
                    {**legacy, 'worker_binding_versions': [True]},
                    {**legacy, 'worker_binding_versions': [1.0]},
                    {**legacy, 'completion_receipt_versions': [True]},
                    {**legacy, 'completion_receipt_versions': [1.0]},
                    {**legacy, 'worker_binding_versions': [2]},
                    {**legacy, 'worker_binding_versions': [1, True]},
                    {**legacy, 'worker_binding_versions': [1, 2.0]},
                    {**legacy, 'worker_binding_versions': [1, 2, 3]}):
            with self.subTest(bad=bad), self.assertRaises(helper.AdmissionRefused):
                helper.validate_manifest({'native_runtime_formats': bad})

    def test_quietness_limits_count_origin_thread_pairs_but_validate_every_attempt(self):
        helper = load('native_runtime_compatibility')
        manifest = {'native_runtime_formats': {'worker_binding_versions': [1, 2], 'completion_receipt_versions': [1, 2]}}
        for name, limit in (('review_cutover', 100), ('review_ready_cutover', 1000)):
            with self.subTest(tool=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                tools = load(name)
                g, _ = tools.bind(root)
                database = root / 'ledger.sqlite'
                with sqlite3.connect(database) as db:
                    db.execute('CREATE TABLE worker_evidence(binding_json TEXT,binding_sha256 TEXT,thread_id TEXT,run_id TEXT)')
                    for number in range(limit + 1):
                        raw = json.dumps({'legacy_attempt': number})
                        db.execute('INSERT INTO worker_evidence VALUES(?,?,?,?)', (raw, hashlib.sha256(raw.encode()).hexdigest(), 'same-thread', tools.RUN))
                g.DB, g.WORKFLOW = database, root / 'owned-workflow.md'
                g.readonly = lambda: sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
                runtime = {'build': str(root / 'build'), 'source': str(root / 'source'), 'native_runtime_formats': manifest['native_runtime_formats']}
                calls = []
                def no_native_call(args, **_options):
                    calls.append(json.loads(args[-1]))
                    return SimpleNamespace(returncode=0, stdout='NATIVE_SOURCE_QUIET\n')
                with patch.object(tools.subprocess, 'run', side_effect=no_native_call):
                    g.native_quiet_for(runtime)
                    self.assertEqual(len(calls[-1]['workers']), 1)
                    with sqlite3.connect(database) as db:
                        db.execute("UPDATE worker_evidence SET binding_sha256='corrupt' WHERE rowid=?", (limit + 1,))
                    before = len(calls)
                    with self.assertRaisesRegex(AssertionError, 'native_runtime_history_unreadable'):
                        g.native_quiet_for(runtime)
                    self.assertEqual(len(calls), before)
                    with sqlite3.connect(database) as db:
                        db.execute('DELETE FROM worker_evidence')
                        for number in range(limit + 1):
                            db.execute('INSERT INTO worker_evidence VALUES(?,?,?,?)', ('{}', hashlib.sha256(b'{}').hexdigest(), 'thread-' + str(number), tools.RUN))
                    with self.assertRaises(AssertionError):
                        g.native_quiet_for(runtime)
                    self.assertEqual(len(calls), before)

    def test_v2_history_is_consumed_only_by_the_verified_target_capabilities(self):
        helper = load('native_runtime_compatibility')
        origin = {'version': 2, 'codex_home': {'path': '/historical/removed/codex', 'device': [1, 2], 'inode': 3, 'uid': 501},
                  'sqlite_home': {'path': '/historical/removed/sqlite', 'device': [1, 2], 'inode': 4, 'uid': 501}}
        binding = {'binding_version': 2, 'native_runtime': origin}
        receipt = {'kind': 'NATIVE_COMPLETION_RECEIPT_V2', 'version': 2, 'native_runtime': origin,
                   'native_runtime_sha256': hashlib.sha256(json.dumps(origin, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'history.sqlite'
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE worker_evidence(binding_json TEXT,status TEXT)')
                db.execute("INSERT INTO worker_evidence VALUES('{}','CONSUMED')")
                db.execute("INSERT INTO worker_evidence VALUES(?,'CONSUMED')", (json.dumps(binding),))
                db.execute('CREATE TABLE events(event_type TEXT,payload_json TEXT)')
                db.execute("INSERT INTO events VALUES('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED',?)", (json.dumps(receipt),))
            before = path.read_bytes()
            current = {'worker_binding_versions': [1, 2], 'completion_receipt_versions': [1, 2]}
            self.assertTrue(helper.check_database(path, {'native_runtime_formats': current}))

            self.assertEqual(path.read_bytes(), before)
            for target in ({}, {'native_runtime_formats': {'worker_binding_versions': [1], 'completion_receipt_versions': [1, 2]}},
                           {'native_runtime_formats': {'worker_binding_versions': [1, 2], 'completion_receipt_versions': [1]}}):
                with self.assertRaisesRegex(helper.AdmissionRefused, 'unsupported_native_runtime_history'):
                    helper.check_database(path, target)
                self.assertEqual(path.read_bytes(), before)
            for changed in ({**origin, 'version': 2.0}, {**origin, 'extra': True},
                            {**origin, 'codex_home': {**origin['codex_home'], 'path': 'relative'}},
                            {**origin, 'sqlite_home': {**origin['sqlite_home'], 'inode': True}}):
                with sqlite3.connect(path) as db:
                    db.execute("UPDATE worker_evidence SET binding_json=? WHERE binding_json!='{}'", (json.dumps({**binding, 'native_runtime': changed}),))
                changed_before = path.read_bytes()
                with self.assertRaisesRegex(helper.AdmissionRefused, 'unsupported_native_runtime_history'):
                    helper.check_database(path, {'native_runtime_formats': current})
                self.assertEqual(path.read_bytes(), changed_before)
            with sqlite3.connect(path) as db:
                db.execute("UPDATE worker_evidence SET binding_json=? WHERE binding_json!='{}'", (json.dumps(binding),))
            self.assertTrue(helper.check_database(path, {'native_runtime_formats': current}))

    def test_origin_format_parity_covers_lexical_paths_and_exact_numeric_types(self):
        helper = load('native_runtime_compatibility')
        origin = {'version': 2, 'codex_home': {'path': '/historical/codex', 'device': [1, 2], 'inode': 3, 'uid': 501},
                  'sqlite_home': {'path': '/historical/sqlite', 'device': [1, 2], 'inode': 4, 'uid': 501}}
        caps = helper.validate_manifest({'native_runtime_formats': {'worker_binding_versions': [1, 2], 'completion_receipt_versions': [1, 2]}})
        invalid_paths = ('//double-leading', '/duplicate//slash', '/dot/./path', '/dot/../path', '/trailing/', '/control\u0085path')
        valid_paths = ('/unicode/é', '/unicode/\u200D', '/unicode/\u2028', '/quoted/\'"')
        for path, valid in [(path, False) for path in invalid_paths] + [(path, True) for path in valid_paths]:
            changed = {**origin, 'codex_home': {**origin['codex_home'], 'path': path}}
            raw = json.dumps({'binding_version': 2, 'native_runtime': changed})
            if valid:
                self.assertEqual(helper.parse_binding(raw, caps)['native_runtime'], changed)
            else:
                with self.assertRaises(helper.AdmissionRefused):
                    helper.parse_binding(raw, caps)
        bad = [None, False, [], {}, {'version': 2, 'codex_home': origin['codex_home']}, {**origin, 'version': True}]
        for field, value in (('device', [1.0, 2]), ('device', [1, False]), ('inode', 3.0), ('uid', True), ('uid', 501.0)):
            bad.append({**origin, 'codex_home': {**origin['codex_home'], field: value}})
        for changed in bad:
            with self.assertRaises(helper.AdmissionRefused):
                helper.parse_binding(json.dumps({'binding_version': 2, 'native_runtime': changed}), caps)
        common = {**origin, 'codex_home': {**origin['codex_home'], 'path': '/historical/é'}}
        self.assertEqual(hashlib.sha256(json.dumps(common, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest(),
                         '6d92c384eb7c1f38377a3ac0e8acf47e65d3a9c75024b164e181534ec96cc749')
        proof = {'kind': 'NATIVE_COMPLETION_RECEIPT_V2', 'version': 2, 'native_runtime': common,
                 'native_runtime_sha256': '6d92c384eb7c1f38377a3ac0e8acf47e65d3a9c75024b164e181534ec96cc749'}
        self.assertTrue(helper._receipt_format(json.dumps(proof), caps))

    def test_all_history_formats_are_strict_without_rewriting_legacy_or_unrelated_events(self):
        helper = load('native_runtime_compatibility')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = [('binding', '{}', True), ('binding', '{ "legacy": [1,2] }', True),
                     ('receipt', json.dumps({'kind': 'NATIVE_COMPLETION_RECEIPT_V1', 'version': 1}), True),
                     ('unrelated', '{malformed', True)]
            for key in ('binding_version', 'native_runtime'):
                cases += [('binding', json.dumps({key: value}), False) for value in (None, False, 1, 2, 2.0, 'future', {})]
            receipt = {'kind': 'NATIVE_COMPLETION_RECEIPT_V1', 'version': 1}
            cases += [('receipt', json.dumps({**receipt, 'version': value}), False) for value in (None, True, 1.0, 2, 2.0, '1')]
            cases += [('receipt', json.dumps(value), False) for value in ({}, {**receipt, 'kind': 'NATIVE_COMPLETION_RECEIPT_V2'}, {**receipt, 'native_runtime': None}, {**receipt, 'native_runtime_sha256': None})]
            cases += [(kind, raw, False) for kind in ('binding', 'receipt') for raw in ('[]', 'null', 'true', '{malformed')]
            for constant in ('NaN', 'Infinity', '-Infinity'):
                cases += [('binding', '{"legacy":[' + constant + ']}', False),
                          ('receipt', '{"kind":"NATIVE_COMPLETION_RECEIPT_V1","version":1,"legacy":[' + constant + ']}', False)]
            for raw_value in ('1e999', '"\\ud800"'):
                cases += [('binding', '{"legacy":[' + raw_value + ']}', False),
                          ('receipt', '{"kind":"NATIVE_COMPLETION_RECEIPT_V1","version":1,"legacy":[' + raw_value + ']}', False)]
            for index, (kind, raw, compatible) in enumerate(cases):
                path = root / f'{index}.sqlite'
                with sqlite3.connect(path) as db:
                    if kind == 'binding':
                        db.execute('CREATE TABLE worker_evidence(binding_json TEXT,status TEXT)')
                        db.execute("INSERT INTO worker_evidence VALUES(?,'CONSUMED')", (raw,))
                    else:
                        db.execute('CREATE TABLE events(event_type TEXT,payload_json TEXT)')
                        db.execute('INSERT INTO events VALUES(?,?)', ('UNRELATED' if kind == 'unrelated' else 'TICKET_WORKER_NATIVE_COMPLETION_RECOVERED', raw))
                before = path.read_bytes()
                with self.subTest(kind=kind, raw=raw):
                    if compatible:
                        self.assertTrue(helper.check_database(path, {}))
                    else:
                        with self.assertRaises(helper.AdmissionRefused):
                            helper.check_database(path, {})
                    self.assertEqual(path.read_bytes(), before)

    def test_absent_empty_older_and_incomplete_or_unreadable_database_boundaries(self):
        helper = load('native_runtime_compatibility')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            absent = root / 'not-created/new.sqlite'
            self.assertTrue(helper.check_database(absent, {}))
            self.assertFalse(absent.parent.exists())
            self.assertTrue(helper.check_database(':memory:', {}))
            empty = root / 'empty.sqlite'
            empty.write_bytes(b'')
            self.assertTrue(helper.check_database(empty, {}))
            self.assertEqual(empty.read_bytes(), b'')
            for index, (sql, admitted) in enumerate((
                    ('CREATE TABLE older(value TEXT)', True),
                    ('CREATE TABLE worker_evidence(status TEXT)', False),
                    ('CREATE TABLE events(event_type TEXT)', False),
                    ("CREATE VIEW worker_evidence AS SELECT '{}' AS binding_json", False))):
                path = root / f'boundary-{index}.sqlite'
                with sqlite3.connect(path) as db:
                    db.execute(sql)
                before = path.read_bytes()
                if admitted:
                    self.assertTrue(helper.check_database(path, {}))
                else:
                    with self.assertRaises(helper.AdmissionRefused):
                        helper.check_database(path, {})
                self.assertEqual(path.read_bytes(), before)
            corrupt = root / 'corrupt.sqlite'
            corrupt.write_bytes(b'not a database')
            for bad in (root, corrupt, 'file:' + str(corrupt), '', None):
                with self.assertRaises(helper.AdmissionRefused):
                    helper.check_database(bad, {})
            self.assertEqual(corrupt.read_bytes(), b'not a database')

    def test_committed_wal_only_history_is_current_and_lock_metadata_is_not_ledger_payload(self):
        helper = load('native_runtime_compatibility')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'held.sqlite'
            writer = sqlite3.connect(path)
            try:
                writer.execute('PRAGMA journal_mode=WAL')
                writer.execute('CREATE TABLE worker_evidence(binding_json TEXT,status TEXT)')
                writer.execute("INSERT INTO worker_evidence VALUES(?, 'CONSUMED')", ('{"native_runtime":null}',))
                writer.commit()
                wal = Path(str(path) + '-wal')
                self.assertIn(b'native_runtime', wal.read_bytes())
                self.assertNotIn(b'native_runtime', path.read_bytes())
                before = (path.read_bytes(), wal.read_bytes())
                with self.assertRaises(helper.AdmissionRefused):
                    helper.check_database(path, {})
                self.assertEqual((path.read_bytes(), wal.read_bytes()), before)
            finally:
                writer.close()
            self.assertFalse(Path(str(path) + '-wal').exists())
            self.assertFalse(Path(str(path) + '-shm').exists())
            before = path.read_bytes()
            with self.assertRaises(helper.AdmissionRefused):
                helper.check_database(path, {})
            self.assertEqual(path.read_bytes(), before)
            if Path(str(path) + '-wal').exists():
                self.assertEqual(Path(str(path) + '-wal').stat().st_size, 0)

    def test_case_insensitive_sqlite_objects_cannot_hide_native_history(self):
        helper = load('native_runtime_compatibility')
        for table in ('WORKER_EVIDENCE', 'WoRkEr_EvIdEnCe', 'EVENTS', 'EvEnTs'):
            with self.subTest(table=table), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / 'case.sqlite'
                with sqlite3.connect(path) as db:
                    if table.lower() == 'worker_evidence':
                        db.execute('CREATE TABLE ' + table + '(binding_json TEXT)')
                        db.execute('INSERT INTO ' + table + ' VALUES(?)', ('{"native_runtime":null}',))
                    else:
                        db.execute('CREATE TABLE ' + table + '(event_type TEXT,payload_json TEXT)')
                        db.execute('INSERT INTO ' + table + ' VALUES(?,?)', ('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED', '{"kind":"NATIVE_COMPLETION_RECEIPT_V2","version":2}'))
                before = path.read_bytes()
                with self.assertRaisesRegex(helper.AdmissionRefused, 'unsupported_native_runtime_history'):
                    helper.check_database(path, {})
                self.assertEqual(path.read_bytes(), before)

    def test_bound_stop_and_public_dispatch_refuse_before_the_retained_effect_boundary(self):
        for name in ('review_ready_cutover', 'review_cutover'):
            with self.subTest(tool=name), tempfile.TemporaryDirectory() as temporary:
                tools = load(name)
                root = Path(temporary)
                historical = root / 'historical'
                historical.mkdir()
                retained = historical / 'cutover_guard.py'
                retained.write_text('''from pathlib import Path
effects = []
def quiet(): pass
def absent(): pass
def stop(): effects.append('retained-stop')
def finish_stop(): effects.append('retained-finish-stop')
def finish_start(): effects.append('retained-finish-start')
def restore_original(): effects.append('retained-restore')
''')
                thaw = historical / 'thaw_guardian.py'
                thaw.write_text('raise AssertionError("must not execute")')
                database = root / 'history.sqlite'
                with sqlite3.connect(database) as db:
                    db.execute('CREATE TABLE worker_evidence(binding_json TEXT,status TEXT)')
                    db.execute("INSERT INTO worker_evidence VALUES(?, 'CONSUMED')", ('{"native_runtime":null}',))
                with patch.multiple(tools, HISTORICAL=historical, GUARD_SHA=tools.sha(retained), THAW_SHA=tools.sha(thaw)):
                    g, capture = tools.bind(root)
                g.DB = database
                g.candidate = lambda: ({}, {}, None)
                g.original_pins = lambda: {'build': 'owned fixture', 'source': 'owned fixture', 'native_runtime_formats': {'worker_binding_versions': [1], 'completion_receipt_versions': [1]}}
                operations = {'capture': capture, **{name: getattr(g, name.replace('-', '_')) for name in
                              ('stop', 'finish-stop', 'start', 'finish-start', 'restore-check', 'restore-original')}}
                origin = {'version': 2, 'codex_home': {'path': '/historical/codex', 'device': [1, 2], 'inode': 3, 'uid': 501},
                          'sqlite_home': {'path': '/historical/sqlite', 'device': [1, 2], 'inode': 4, 'uid': 501}}
                for raw in ('{"native_runtime":null}', json.dumps({'binding_version': 2, 'native_runtime': origin})):
                    with sqlite3.connect(database) as db:
                        db.execute('UPDATE worker_evidence SET binding_json=?', (raw,))
                    before = database.read_bytes()
                    for operation, action in operations.items():
                        with self.subTest(operation=operation, binding=raw), self.assertRaisesRegex(AssertionError, 'unsupported_native_runtime_history'):
                            action()
                        self.assertEqual(g.effects, [])
                    for operation in operations:
                        dispatched = lambda: g.effects.append('dispatch-' + operation)
                        if operation == 'capture':
                            selected_capture = dispatched
                        else:
                            setattr(g, operation.replace('-', '_'), dispatched)
                            selected_capture = capture
                        with patch.object(tools, 'bind', return_value=(g, selected_capture)), patch.object(tools.sys, 'argv', ['tool', operation, str(root)]):
                            with self.assertRaisesRegex(AssertionError, 'unsupported_native_runtime_history'):
                                tools.main()
                        self.assertEqual(g.effects, [])
                    self.assertEqual(database.read_bytes(), before)

    def test_actual_generated_launcher_checks_selected_history_before_cli(self):
        with generated_launcher() as fixture:
            workflow = fixture['root'] / 'selected.md'
            database = fixture['root'] / 'selected.sqlite'
            with sqlite3.connect(database) as db:
                db.execute('CREATE TABLE worker_evidence(binding_json TEXT,status TEXT)')
                db.execute("INSERT INTO worker_evidence VALUES('{}','CONSUMED')")
            workflow.write_text('---\ntracker:\n  kind: memory\nfactory:\n  enabled: true\n  dispatcher_id: fixture-dispatcher\n  controller_codex_project_id: fixture-project\n  database: ' + json.dumps(str(database)) + '\n---\nSynthetic\n')
            declared = fixture['manifest'].pop('native_runtime_formats')
            fixture['render']()
            missing = fixture['run'](workflow)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('unsupported_native_runtime_formats', missing.stderr)
            self.assertFalse(fixture['sentinel'].exists())
            fixture['manifest']['native_runtime_formats'] = declared
            fixture['render']()
            compatible = fixture['run'](workflow)
            self.assertEqual(compatible.returncode, 0, compatible.stdout + compatible.stderr)
            self.assertTrue(fixture['sentinel'].exists())
            self.assertEqual(json.loads(fixture['sentinel'].read_text())[-1], str(workflow))
            fixture['sentinel'].unlink()
            origin = {'version': 2, 'codex_home': {'path': '/historical/é\'"/codex', 'device': [1, 2], 'inode': 3, 'uid': 501},
                      'sqlite_home': {'path': '/historical/\u200D/sqlite', 'device': [1, 2], 'inode': 4, 'uid': 501}}
            receipt = {'kind': 'NATIVE_COMPLETION_RECEIPT_V2', 'version': 2, 'native_runtime': origin,
                       'native_runtime_sha256': hashlib.sha256(json.dumps(origin, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()}
            with sqlite3.connect(database) as db:
                db.execute("INSERT INTO worker_evidence VALUES(?,'CONSUMED')", (json.dumps({'binding_version': 2, 'native_runtime': origin}),))
                db.execute('CREATE TABLE events(event_type TEXT,payload_json TEXT)')
                db.execute("INSERT INTO events VALUES('TICKET_WORKER_NATIVE_COMPLETION_RECOVERED',?)", (json.dumps(receipt),))
            mixed_before = database.read_bytes()
            mixed = fixture['run'](workflow)
            self.assertEqual(mixed.returncode, 0, mixed.stdout + mixed.stderr)
            self.assertTrue(fixture['sentinel'].exists())
            self.assertEqual(database.read_bytes(), mixed_before)
            fixture['sentinel'].unlink()
            with sqlite3.connect(database) as db:
                db.execute('UPDATE worker_evidence SET binding_json=?', ('{"native_runtime":null}',))
            before = database.read_bytes()
            unsupported = fixture['run'](workflow)
            self.assertNotEqual(unsupported.returncode, 0, 'unsupported ledger reached the CLI')
            self.assertFalse(fixture['sentinel'].exists())
            self.assertEqual(database.read_bytes(), before)
            qualified = fixture['run'](fixture['root'] / 'nonexistent-workflow.md', qualify=True)
            self.assertEqual(qualified.returncode, 0, qualified.stdout + qualified.stderr)
            self.assertIn('FACTORY_REVIEW_REPORT_COLD_BOOT_ATTESTED', qualified.stdout)
            self.assertFalse(fixture['sentinel'].exists())
            self.assertEqual(database.read_bytes(), before)
            for reserved in (False, None):
                workflow.write_text('---\ntracker:\n  kind: memory\nfactory:\n  enabled: false\n  ticket_supervisor:\n    native_runtime: ' + json.dumps(reserved) + '\n---\nSynthetic\n')
                refused = fixture['run'](workflow)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn('unsupported_native_runtime_configuration', refused.stderr)
                self.assertFalse(fixture['sentinel'].exists())
            for bad in (None, {}, {**declared, 'worker_binding_versions': [1]}, {**declared, 'worker_binding_versions': [2]},
                        {**declared, 'worker_binding_versions': [True]},
                        {**declared, 'worker_binding_versions': [1.0]}):
                fixture['manifest']['native_runtime_formats'] = bad
                fixture['render']()
                refused = fixture['run'](workflow, qualify=True)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn('unsupported_native_runtime_formats', refused.stderr)
                self.assertFalse(fixture['sentinel'].exists())
            changed_source = next(iter(fixture['manifest']['source_hashes']))
            (Path(fixture['manifest']['source_root']) / changed_source).write_text('tampered source')
            attestation_refused = fixture['run'](workflow, qualify=True)
            self.assertNotEqual(attestation_refused.returncode, 0)
            self.assertNotIn('unsupported_native_runtime_formats', attestation_refused.stderr)
            self.assertFalse(fixture['sentinel'].exists())

    def test_both_quietness_probes_read_every_recorded_origin_under_containment(self):
        with generated_launcher() as fixture:
            root = fixture['root']
            workflow = root / 'quiet-workflow.md'
            workflow.write_text('---\ntracker:\n  kind: memory\nfactory:\n  enabled: false\n---\nSynthetic quietness only\n')
            origins = {}
            for label in ('a', 'b'):
                home, sqlite = root / (label + '-home'), root / (label + '-sqlite')
                home.mkdir(mode=0o700)
                sqlite.mkdir(mode=0o700)
                (home / 'thread-writer-locks').mkdir()
                create_queue(sqlite / 'queue_1.sqlite')
                origins[label] = {'version': 2, 'codex_home': directory_identity(home), 'sqlite_home': directory_identity(sqlite)}
            caps = {'worker_binding_versions': [1, 2], 'completion_receipt_versions': [1, 2]}
            helper = load('native_runtime_compatibility')
            real_run = subprocess.run
            calls = []
            profile = contained_profile(root)
            def execute_emitted(args, **options):
                self.assertEqual(args[:4], ['/opt/homebrew/bin/mise', 'exec', '--', 'elixir'])
                self.assertEqual(args[args.index('-e') + 1], helper.NATIVE_QUIET_SCRIPT)
                calls.append(args)
                command = ['/usr/bin/sandbox-exec', '-p', profile, str(ELIXIR_BIN / 'elixir'), '-pa', str(QUALIFIED / '*/ebin'), *args[4:]]
                result = real_run(command, **options)
                print(json.dumps({'contained_probe_exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}))
                return result
            for name in ('review_ready_cutover', 'review_cutover'):
                with self.subTest(tool=name), tempfile.TemporaryDirectory(dir=root) as directory:
                    tools = load(name)
                    evidence = Path(directory)
                    g, _ = tools.bind(evidence)
                    database = evidence / 'ledger.sqlite'
                    with sqlite3.connect(database) as db:
                        db.execute('CREATE TABLE worker_evidence(binding_json TEXT,binding_sha256 TEXT,thread_id TEXT,run_id TEXT)')
                        for label in ('a', 'b'):
                            raw = json.dumps({'binding_version': 2, 'native_runtime': origins[label]})
                            db.execute('INSERT INTO worker_evidence VALUES(?,?,?,?)', (raw, hashlib.sha256(raw.encode()).hexdigest(), 'same-thread', tools.RUN))
                    g.DB, g.WORKFLOW = database, workflow
                    g.readonly = lambda: sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
                    runtime = {'build': fixture['manifest']['build'], 'source': fixture['manifest']['source_root'], 'native_runtime_formats': caps}
                    before = database.read_bytes()
                    with patch.object(tools.subprocess, 'run', side_effect=execute_emitted):
                        # A and B are equally named but independently quiet; default-native access is denied.
                        g.native_quiet_for(runtime)
                        payload = json.loads(calls[-1][-1])
                        self.assertEqual(len(payload['workers']), 2)
                        self.assertEqual(payload['workflow'], str(workflow))
                        self.assertEqual(database.read_bytes(), before)
                        for target in ({'worker_binding_versions': [1], 'completion_receipt_versions': [1]},):
                            count = len(calls)
                            with self.assertRaisesRegex(AssertionError, 'unsupported_native_runtime_history'):
                                g.native_quiet_for({**runtime, 'native_runtime_formats': target})
                            self.assertEqual(len(calls), count)
                        queue = Path(origins['b']['sqlite_home']['path']) / 'queue_1.sqlite'
                        with sqlite3.connect(queue) as db:
                            db.execute("INSERT INTO queued_items VALUES('queued','same-thread','{}',1,1,1)")
                        with self.assertRaises(AssertionError):
                            g.native_quiet_for(runtime)
                        with sqlite3.connect(database) as db:
                            db.execute('UPDATE worker_evidence SET run_id=? WHERE rowid=2', ('other-run',))
                        if name == 'review_cutover':
                            g.native_quiet_for(runtime)
                            self.assertEqual(len(json.loads(calls[-1][-1])['workers']), 1)
                        else:
                            with self.assertRaises(AssertionError):
                                g.native_quiet_for(runtime)
                        with sqlite3.connect(database) as db:
                            db.execute('UPDATE worker_evidence SET run_id=? WHERE rowid=2', (tools.RUN,))
                        before = database.read_bytes()
                        with sqlite3.connect(queue) as db:
                            db.execute('DELETE FROM queued_items')
                        lock_path = Path(origins['b']['codex_home']['path']) / 'thread-writer-locks/same-thread.lock'
                        with lock_path.open('w') as lock:
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            with self.assertRaises(AssertionError):
                                g.native_quiet_for(runtime)
                        g.native_quiet_for(runtime)
                        home = Path(origins['b']['codex_home']['path'])
                        retained = home.with_name(home.name + '-retained')
                        home.rename(retained)
                        home.mkdir(mode=0o700)
                        with self.assertRaises(AssertionError):
                            g.native_quiet_for(runtime)
                        home.rmdir()
                        home.symlink_to(retained, target_is_directory=True)
                        with self.assertRaises(AssertionError):
                            g.native_quiet_for(runtime)
                        home.unlink()
                        retained.rename(home)
                        g.native_quiet_for(runtime)
                    self.assertEqual(database.read_bytes(), before)
    def test_retained_stop_and_backup_recheck_history_after_native_quiescence(self):
        with generated_launcher() as fixture:
            self.assert_retained_postquietness_guard(fixture)

    def assert_retained_postquietness_guard(self, fixture):
        real_run, real_popen = subprocess.run, subprocess.Popen
        profile = contained_profile(fixture['root'])
        for name in ('review_ready_cutover', 'review_cutover'):
            for operation in ('stop', 'finish_stop'):
                with self.subTest(tool=name, operation=operation), tempfile.TemporaryDirectory() as temporary:
                    tools = load(name)
                    root = Path(temporary).resolve()
                    release = root / 'symphony-review-report-fixture'
                    (release / 'evidence').mkdir(parents=True)
                    for filename in ('release_boot_guard.exs', 'run-local-factory'):
                        (release / filename).write_text('owned pinned fixture')
                    manifest = {'kind': 'FACTORY_REVIEW_REPORT_RELEASE_V1', 'schema_version': 54,
                                'source_commit': 'fixture', 'factory_beam_fingerprint': 'fixture',
                                'factory_modules': {}, 'artifact': {}, 'source_hashes': {},
                                'previous_manifest_sha256': getattr(tools, 'OLD_MANIFEST_SHA', ''),
                                'native_runtime_formats': {'worker_binding_versions': [1, 2], 'completion_receipt_versions': [1, 2]}}
                    path = release / 'evidence/release-manifest.json'
                    path.write_text(json.dumps(manifest))
                    value = {'release': str(release), 'build': fixture['manifest']['build'], 'source': fixture['manifest']['source_root'],
                             'source_commit': 'fixture', 'schema_version': 54, 'factory_beam_fingerprint': 'fixture',
                             'factory_module_count': 0, 'manifest_sha256': tools.sha(path),
                             'guard_sha256': tools.sha(release / 'release_boot_guard.exs'),
                             'launcher_sha256': tools.sha(release / 'run-local-factory')}
                    with patch.object(tools, 'OLD_RELEASE', root / 'original'):
                        g, _ = tools.bind(root)
                        database = root / 'ledger.sqlite'
                        home, sqlite = root / 'bound-home', root / 'bound-sqlite'
                        home.mkdir(mode=0o700)
                        sqlite.mkdir(mode=0o700)
                        (home / 'thread-writer-locks').mkdir()
                        create_queue(sqlite / 'queue_1.sqlite')
                        origin = {'version': 2, 'codex_home': directory_identity(home), 'sqlite_home': directory_identity(sqlite)}
                        raw_binding = json.dumps({'binding_version': 2, 'native_runtime': origin})
                        with sqlite3.connect(database) as db:
                            db.execute('CREATE TABLE worker_evidence(binding_json TEXT,binding_sha256 TEXT,thread_id TEXT,run_id TEXT)')
                            db.execute('INSERT INTO worker_evidence VALUES(?,?,?,?)', (raw_binding, hashlib.sha256(raw_binding.encode()).hexdigest(), 'synthetic-thread', tools.RUN))
                        g.DB = database
                        g.WORKFLOW = root / 'synthetic-workflow.md'
                        g.WORKFLOW.write_text('---\ntracker:\n  kind: memory\nfactory:\n  enabled: false\n---\nOwned postquietness fixture\n')
                        g.PLIST = root / 'service.plist'
                        g.PLIST.write_text('owned plist')
                        evidence = {'candidate.json': value, 'captured.json': {'plist_sha256': tools.sha(g.PLIST), 'configuration': {}},
                                    'stop-intent.json': {'manifest_sha256': value['manifest_sha256']}}
                        g.load = lambda key: evidence[key]
                        g.candidate = lambda: (value, manifest, None)
                        g.qualified = g.candidate
                        g.configuration = lambda: {}
                        g.old_binding = lambda _idle: None
                        g.quiet = g.await_absent = lambda: None
                        g.readonly = lambda: sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
                        effects = []
                        g.command = lambda *_args, **_options: effects.append('external-command')
                        g.save = lambda *_args: effects.append('evidence-write')
                        g.protected = lambda _audit: effects.append('protected-read')
                        def native_quiescence(args, **options):
                            self.assertEqual(args[:4], ['/opt/homebrew/bin/mise', 'exec', '--', 'elixir'])
                            command = ['/usr/bin/sandbox-exec', '-p', profile, str(ELIXIR_BIN / 'elixir'), '-pa', str(QUALIFIED / '*/ebin'), *args[4:]]
                            result = real_run(command, **options)
                            self.assertEqual(result.returncode, 0, result.stderr)
                            self.assertEqual(result.stdout.strip(), 'NATIVE_SOURCE_QUIET')
                            with sqlite3.connect(database) as db:
                                db.execute('UPDATE worker_evidence SET binding_json=?', ('{"native_runtime":null}',))
                            return result
                        def confined_child(args, *extra, **options):
                            if args[:3] == ['/usr/bin/sandbox-exec', '-p', profile]:
                                return real_popen(args, *extra, **options)
                            effects.append('guardian-spawn')
                            raise AssertionError('guardian must not run')
                        with patch.object(tools, 'validate_candidate', return_value=manifest, create=True), patch.object(tools.subprocess, 'run', side_effect=native_quiescence), patch.object(tools.subprocess, 'Popen', side_effect=confined_child):
                            with self.assertRaisesRegex(AssertionError, 'unsupported_native_runtime_history'):
                                getattr(g, operation)()
                        self.assertEqual(effects, [])
                        self.assertFalse((root / 'protected-after.json').exists())
                        self.assertFalse((root / 'before-cutover.sqlite').exists())

    def test_restore_uses_independently_pinned_original_capabilities_not_broken_replacement(self):
        for name in ('review_ready_cutover', 'review_cutover'):
            with self.subTest(tool=name), tempfile.TemporaryDirectory() as temporary:
                tools = load(name)
                root = Path(temporary).resolve()
                original = root / 'original'
                (original / 'evidence').mkdir(parents=True)
                build, source = root / 'build', root / 'source'
                build.mkdir()
                source.mkdir()
                if name == 'review_ready_cutover':
                    (source / 'elixir/assets').mkdir(parents=True)
                    placeholder = build / 'phoenix-colocated/symphony_elixir/node_modules'
                    placeholder.parent.mkdir(parents=True)
                    placeholder.symlink_to(os.path.relpath(source / 'elixir/assets/node_modules', placeholder.parent))
                for filename in ('run-local-factory', 'release_boot_guard.exs'):
                    (original / filename).write_text('owned original artifact')
                manifest = {'kind': 'FACTORY_REVIEW_REPORT_RELEASE_V1', 'schema_version': 54,
                            'source_commit': getattr(tools, 'OLD_SOURCE', 'fixture'),
                            'build': str(build), 'source_root': str(source), 'artifact': {}, 'source_hashes': {},
                            'native_runtime_formats': {'worker_binding_versions': [2], 'completion_receipt_versions': [1]}}
                path = original / 'evidence/release-manifest.json'
                path.write_text(json.dumps(manifest))
                suffix = '' if name == 'review_ready_cutover' else '_SHA'
                overrides = {'OLD_RELEASE': original, 'OLD_MANIFEST' + suffix: tools.sha(path),
                             'OLD_LAUNCHER' + suffix: tools.sha(original / 'run-local-factory'),
                             'OLD_BOOT' + suffix: tools.sha(original / 'release_boot_guard.exs')}
                with patch.multiple(tools, **overrides):
                    g, _ = tools.bind(root)
                    g.DB = root / 'absent.sqlite'
                    g.candidate = lambda: (_ for _ in ()).throw(AssertionError('replacement is broken'))
                    effects = []
                    g.command = lambda *_args, **_options: effects.append('external-command')
                    g.save = lambda *_args: effects.append('evidence-write')
                    for action in (g.restore_check, g.restore_original):
                        with self.assertRaisesRegex(AssertionError, 'unsupported_native_runtime_formats'):
                            action()
                    self.assertEqual(effects, [])

    def test_bound_start_rechecks_immediately_before_plist_and_bootstrap(self):
        for name in ('review_ready_cutover', 'review_cutover'):
            for boundary in ('plist', 'bootstrap'):
                with self.subTest(tool=name, boundary=boundary), tempfile.TemporaryDirectory() as temporary, ExitStack() as patches:
                    tools = load(name)
                    root = Path(temporary).resolve()
                    g, _ = tools.bind(root)
                    database = root / 'ledger.sqlite'
                    with sqlite3.connect(database) as db:
                        db.execute('CREATE TABLE worker_evidence(binding_json TEXT,binding_sha256 TEXT,thread_id TEXT,run_id TEXT)')
                        db.execute('INSERT INTO worker_evidence VALUES(?,?,?,?)', ('{}', hashlib.sha256(b'{}').hexdigest(), 'synthetic-thread', tools.RUN))
                    g.DB = database
                    g.PLIST = root / 'service.plist'
                    original = plistlib.dumps({'ProgramArguments': ['original', 'workflow'], 'EnvironmentVariables': {'MIX_BUILD_PATH': 'original'}})
                    g.PLIST.write_bytes(original)
                    (root / 'service.original.plist').write_bytes(original)
                    g.BROKER, g.MONITOR, g.WORKFLOW = [root / file for file in ('broker.toml', 'monitor.toml', 'workflow.md')]
                    g.BROKER.write_text('status="PAUSED"\nrrule="FREQ=MINUTELY;INTERVAL=1"\n')
                    g.MONITOR.write_text('status="PAUSED"\n')
                    g.WORKFLOW.write_text('synthetic workflow')
                    protected_path = root / 'audited-protected.json'
                    protected_path.write_text('{}')
                    value = {'release': str(root / 'release'), 'build': str(root / 'build'), 'source': str(root / 'source'), 'source_commit': 'fixture', 'manifest_sha256': 'fixture'}
                    metadata = database.stat()
                    audit = {'kind': 'OWNED_READY_SERVICE_REPLACEMENT_V1', 'issuer': {'pid': int(tools.OLD_PID) if hasattr(tools, 'OLD_PID') else int(g.OLD_PID), 'started_at': getattr(tools, 'OLD_START', g.OLD_START)},
                             'operation': {'run_id': tools.RUN, 'state': 'READY_FOR_REVIEW'},
                             'replacement_manifest': str(Path(value['release']) / 'evidence/release-manifest.json'),
                             'replacement_launcher': str(Path(value['release']) / 'run-local-factory'), 'replacement_build': value['build'],
                             'protected_snapshot': {'path': str(protected_path), 'sha256': tools.sha(protected_path)},
                             'database_identity': {'path': str(database), 'device': metadata.st_dev, 'inode': metadata.st_ino, 'uid': metadata.st_uid}}
                    (root / 'cutover-audit.json').write_text(json.dumps(audit))
                    accepted = {'result': 'ACCEPT', 'source_commit': 'fixture', 'manifest_sha256': 'fixture', 'accepted_scopes': {'014': 'ACCEPT', '022': 'ACCEPT', '023': 'ACCEPT', '025-tools': 'ACCEPT'}}
                    proof = {'result': 'PASS', 'manifest_sha256': 'fixture', 'native_chats': 0, 'native_model_turns': 0, 'initialization_only': True, 'signed_runtime_verified': True, 'completed_at': datetime.now(timezone.utc).isoformat()}
                    configuration = {str(path): tools.sha(path) for path in (g.BROKER, g.MONITOR, g.WORKFLOW)}
                    evidence = {'candidate.json': value, 'cutover-audit.json': audit, 'source-approved.json': accepted, 'review-acceptance.json': accepted,
                                'cold-boot.json': proof, 'runtime-preflight.json': proof, 'captured.json': {'configuration': configuration, 'plist_sha256': tools.sha(g.PLIST), 'ticket': 'fixture'},
                                'stopped.json': {'result': 'EXACT_ISSUER_STOPPED'}}
                    g.load = lambda key: evidence.get(key, {})
                    g.candidate = lambda: (value, {}, audit)
                    g.qualified = g.candidate
                    g.configuration = lambda: configuration
                    g.absent = g.quiet = lambda: None
                    g.readonly = lambda: sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
                    effects = []
                    def introduce_future_history(*_args):
                        if boundary == 'plist':
                            with sqlite3.connect(database) as db:
                                db.execute('UPDATE worker_evidence SET binding_json=?', ('{"native_runtime":null}',))
                    g.protected = introduce_future_history
                    g.native_quiet = lambda: None
                    g.save = lambda *_args: effects.append('save')
                    g.command = lambda *_args, **_options: effects.append('bootstrap')
                    actual_replace = tools.replace_plist
                    def replace_then_change(*args):
                        effects.append('replace')
                        actual_replace(*args)
                        with sqlite3.connect(database) as db:
                            db.execute('UPDATE worker_evidence SET binding_json=?', ('{"native_runtime":null}',))
                    for function in ('validate_approval', 'validate_validation', 'validate_publication'):
                        patches.enter_context(patch.object(tools, function, return_value=None, create=True))
                    patches.enter_context(patch.object(tools, 'validate_candidate', return_value={}, create=True))
                    patches.enter_context(patch.object(tools, 'validate_ticket', return_value='fixture', create=True))
                    patches.enter_context(patch.object(tools, 'preserve', side_effect=introduce_future_history, create=True))
                    patches.enter_context(patch.object(tools, 'OLD_PLIST', tools.sha(g.PLIST), create=True))
                    patches.enter_context(patch.object(tools.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='NATIVE_SOURCE_QUIET\n')))
                    patches.enter_context(patch.object(tools, 'replace_plist', side_effect=replace_then_change))
                    with self.assertRaisesRegex(AssertionError, 'unsupported_native_runtime_history'):
                        g.start()
                    self.assertNotIn('bootstrap', effects)
                    if boundary == 'plist':
                        self.assertEqual(effects, [])
                        self.assertEqual(g.PLIST.read_bytes(), original)
                    else:
                        self.assertIn('replace', effects)


def directory_identity(path):
    info = path.stat()
    return {'path': str(path), 'device': [info.st_dev, info.st_rdev], 'inode': info.st_ino, 'uid': info.st_uid}


def create_queue(path):
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE queued_items (id TEXT PRIMARY KEY NOT NULL, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL, queue_order INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL)')
        db.execute('CREATE TABLE queued_thread_revisions (revision INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL UNIQUE)')
        for event, row in (('insert', 'NEW'), ('update', 'NEW'), ('delete', 'OLD')):
            db.execute('CREATE TRIGGER queued_items_revision_after_' + event + ' AFTER ' + event.upper() + ' ON queued_items BEGIN INSERT INTO queued_thread_revisions (thread_id) VALUES (' + row + '.thread_id) ON CONFLICT(thread_id) DO UPDATE SET revision = (SELECT COALESCE(MAX(revision),0)+1 FROM queued_thread_revisions); END')


def contained_profile(root):
    denied = root / 'denied-sentinel'
    denied.mkdir()
    sentinel = denied / 'owned.txt'
    sentinel.write_text('owned deny sentinel')
    aliases = {Path('/Users/cgable/.codex'), Path('/System/Volumes/Data/Users/cgable/.codex')}
    canonical = Path('/Users/cgable/.codex').resolve(strict=True)
    aliases.add(canonical)
    identity = canonical.stat()
    assert all((path.stat().st_dev, path.stat().st_ino) == (identity.st_dev, identity.st_ino) for path in aliases)
    profile = '(version 1)(allow default)(deny file-read* file-write* ' + ' '.join('(subpath ' + json.dumps(str(path)) + ')' for path in sorted(aliases | {denied})) + ')'
    code = '''import os,subprocess,sys
path=sys.argv[1]
for operation in (lambda: open(path).read(),lambda: os.stat(path),lambda: open(path,'w')):
 try: operation()
 except PermissionError: pass
 else: raise AssertionError('owned sentinel denial failed')
assert open(sys.argv[2]).read()=='allowed A'
assert open(sys.argv[3]).read()=='allowed B'
if len(sys.argv)==4:
 result=subprocess.run([sys.executable,'-I','-S','-B','-c',os.environ['CONTAINMENT_CHECK_CODE'],*sys.argv[1:],'child'],capture_output=True,text=True)
 assert result.returncode==0,result.stderr
print('CONTAINMENT_PASS')
'''
    allowed = [root / 'allowed-a', root / 'allowed-b']
    for path, content in zip(allowed, ('allowed A', 'allowed B')):
        path.write_text(content)
    result = subprocess.run(['/usr/bin/sandbox-exec', '-p', profile, '/opt/homebrew/bin/python3.12', '-I', '-S', '-B', '-c', code, str(sentinel), *map(str, allowed)],
                            env={'PATH': '/usr/bin:/bin', 'CONTAINMENT_CHECK_CODE': code}, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0 and result.stdout.strip() == 'CONTAINMENT_PASS', result.stderr
    assert sentinel.read_text() == 'owned deny sentinel'
    return profile


@contextmanager
def generated_launcher():
    builder = load('build_review_release')
    with tempfile.TemporaryDirectory(prefix='admission-launcher-') as temporary:
        root = Path(temporary).resolve()
        source = root / 'source'
        project = source / 'elixir'
        build = root / 'build'
        ebin = build / 'lib/symphony_elixir/ebin'
        ebin.mkdir(parents=True)
        files = ['lib/symphony_elixir/factory/native_runtime_route.ex', 'lib/symphony_elixir/factory/native_runtime_compatibility.ex', 'lib/symphony_elixir/factory/supervisor.ex', 'lib/symphony_elixir/factory/store.ex']
        for name in files:
            target = project / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT.parents[1] / 'elixir' / name, target)
        fake_cli = project / 'lib/fixture_cli.ex'
        fake_cli.write_text('''defmodule SymphonyElixir.CLI do
  @spec main([String.t()]) :: :ok
  def main(args) do
    nil = Process.whereis(SymphonyElixir.Factory.Store)
    nil = Process.whereis(SymphonyElixir.Factory.ControlServer)
    File.write!(System.fetch_env!("NATIVE_ADMISSION_CLI_SENTINEL"), Jason.encode!(args))
  end
end
''')
        files.append('lib/fixture_cli.ex')
        environment = {'HOME': os.environ['HOME'], 'PATH': str(ELIXIR_BIN) + ':' + str(ERLANG_BIN) + ':/usr/bin:/bin', 'ERL_FLAGS': '+S 2:2', 'LANG': 'en_US.UTF-8'}
        compiled = subprocess.run([str(ELIXIR_BIN / 'elixirc'), '--warnings-as-errors', '--ignore-module-conflict', '-pa', str(QUALIFIED / '*/ebin'), '-o', str(ebin), *[str(project / name) for name in files]], env=environment, capture_output=True, text=True, timeout=30)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        project.joinpath('mix.exs').write_text('''Code.prepend_paths(Path.wildcard(%s))
Code.prepend_path(%s)
defmodule NativeAdmissionFixture.MixProject do
  use Mix.Project
  def project, do: [app: :symphony_elixir, version: "0.1.0", deps: [], prune_code_paths: false]
end
''' % (json.dumps(str(QUALIFIED / '*/ebin')), json.dumps(str(ebin))))
        project.joinpath('.tool-versions').write_text('erlang 28.5\nelixir 1.19.5-otp-28\n')
        ebin.joinpath('symphony_elixir.app').write_text('{application,symphony_elixir,[{vsn,"0.1.0"},{modules,[]},{applications,[kernel,stdlib,elixir,logger]}]}.\n')
        script = '''[source, build] = System.argv()
origins = for path <- Path.wildcard(Path.join(build, "lib/symphony_elixir/ebin/*.beam")) do
  {:ok, {module, [compile_info: info]}} = :beam_lib.chunks(String.to_charlist(path), [:compile_info])
  %{module: to_string(module), source: Path.relative_to(to_string(info[:source]), source), path: Path.relative_to(path, build)}
end
factories = for item <- origins, String.starts_with?(item.module, "Elixir.SymphonyElixir.Factory."), into: %{}, do: {item.module, Base.encode16(:crypto.hash(:sha256, File.read!(Path.join(build, item.path))), case: :lower)}
digests = factories |> Enum.sort() |> Enum.map(fn {name, hex} -> {name, Base.decode16!(hex, case: :lower)} end)
Code.prepend_path(Path.join(build, "lib/symphony_elixir/ebin"))
IO.puts(Jason.encode!(%{compiled_origins: origins, factory_modules: factories, native_runtime_formats: SymphonyElixir.Factory.NativeRuntimeCompatibility.supported_formats(), factory_beam_fingerprint: Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(digests)), case: :lower)}))
'''
        inspected = subprocess.run([str(ELIXIR_BIN / 'elixir'), '-pa', str(QUALIFIED / '*/ebin'), '-e', script, '--', str(source), str(build)], env=environment, capture_output=True, text=True, timeout=30)
        assert inspected.returncode == 0, inspected.stdout + inspected.stderr
        manifest = {'kind': 'FACTORY_REVIEW_REPORT_RELEASE_V1', 'build': str(build), 'source_root': str(source), **json.loads(inspected.stdout)}
        manifest['artifact'] = {path.relative_to(build).as_posix(): {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in build.rglob('*') if path.is_file()}
        manifest['source_hashes'] = {('elixir/' + name): hashlib.sha256((project / name).read_bytes()).hexdigest() for name in files}
        manifest_path = root / 'manifest.json'
        guard = root / 'release_boot_guard.exs'
        shutil.copyfile(ROOT / 'review_release_boot_guard.exs', guard)
        launcher = root / 'run-fixture'
        def render():
            manifest_path.write_text(json.dumps(manifest))
            guard_eval = ('path = ' + json.dumps(str(guard)) + '; raw = File.read!(path); true = Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == "' + builder.sha(guard) + '"; Code.eval_string(raw, [], file: path); :ok = ReviewReportReleaseBootGuard.load(' + json.dumps(str(manifest_path)) + ', "' + builder.sha(manifest_path) + '"); ')
            launcher.write_text(builder.render_launcher(build, source, guard_eval))
        render()
        launcher.chmod(0o755)
        sentinel = root / 'cli-entered.json'
        launch_environment = {**environment, 'NATIVE_ADMISSION_CLI_SENTINEL': str(sentinel), 'SYMPHONY_FACTORY_LOGS_ROOT': str(root / 'logs'), 'MISE_TRUSTED_CONFIG_PATHS': str(project)}
        def run(workflow, qualify=False):
            env = dict(launch_environment)
            if qualify:
                env['SYMPHONY_PUSH_HANDOFF_QUALIFY'] = '1'
            return subprocess.run([str(launcher), str(workflow)], env=env, capture_output=True, text=True, timeout=30)
        yield {'root': root, 'run': run, 'render': render, 'sentinel': sentinel, 'manifest': manifest, 'manifest_path': manifest_path, 'launcher': launcher}


if __name__ == '__main__':
    unittest.main()
