"""Offline READY-only rollout seams; all database and artifact inputs are temporary."""

import copy
from contextlib import closing
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.error
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent


def load_tools():
    spec = importlib.util.spec_from_file_location('ready_rollout', ROOT / 'review_ready_cutover.py')
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class ReadyRolloutTests(unittest.TestCase):
    def test_only_explicit_source_context_qualifies_the_exact_dangling_phoenix_placeholder(self):
        tools = load_tools()
        for name in ('symphony-review-report-216eadb', 'symphony-review-report-new-frozen'):
            with self.subTest(release=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                build = root / 'releases' / name / 'dev'
                source = root / 'source-snapshots' / name
                placeholder = build / 'phoenix-colocated/symphony_elixir/node_modules'
                placeholder.parent.mkdir(parents=True)
                (source / 'elixir/assets').mkdir(parents=True)
                (build / 'fixture.beam').write_bytes(b'compiled')
                raw = '../../../../../source-snapshots/'+name+'/elixir/assets/node_modules'
                placeholder.symlink_to(raw)
                expected = {'fixture.beam': {'sha256': '64ebd267717810f9524a58c6d7715bd9502b3c9235b291a7104389b372aeec4b'}}
                with self.assertRaises(AssertionError):
                    tools.inventory(build)
                self.assertEqual(tools.inventory(build, artifact_source=source), expected)
                proof = tools.phoenix_placeholder(build, source)
                self.assertEqual({key: proof[key] for key in ('path', 'raw_target', 'uid', 'gid', 'mode', 'nlink', 'dangling')},
                                 {'path': 'phoenix-colocated/symphony_elixir/node_modules', 'raw_target': raw,
                                  'uid': os.getuid(), 'gid': 20, 'mode': 0o755, 'nlink': 1, 'dangling': True})
                self.assertFalse(os.path.lexists(source / 'elixir/assets/node_modules'))

    def test_ready_ticket_requires_exact_whole_row_and_completed_receipt(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.sqlite'
            receipt = 'unchanged synthetic receipt'
            envelope = {'kind': 'TICKET_PUSH', 'phase': 'COMPLETED',
                        'receipt_json': receipt, 'receipt_sha256': tools.digest(receipt.encode()),
                        'reservation_key': 'access', 'reservation_generation': 67}
            row = {'run_id': tools.RUN, 'state': 'READY_FOR_REVIEW',
                   'candidate_sha': tools.CANDIDATE, 'ci_pipeline_id': 2992785001,
                   'verifier_round': 6, 'code_repair_round': 13,
                   'implementation_iteration': 27, 'mr_iid': 47818,
                   'last_error': None, 'candidate_handoff': json.dumps(envelope),
                   'unlisted_future_field': 'must also be preserved'}
            expected = {**tools.TICKET, 'run_sha256': tools.digest(tools.encode(row)),
                        'envelope_sha256': tools.digest(row['candidate_handoff'].encode()),
                        'receipt_sha256': tools.digest(receipt.encode()),
                        'receipt_bytes': len(receipt.encode()), 'reservation_key': 'access'}
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('CREATE TABLE runs (' + ','.join('"'+key+'"' for key in row) + ')')
                db.execute('INSERT INTO runs VALUES (' + ','.join('?' for _ in row) + ')', tuple(row.values()))
                db.execute('CREATE TABLE factory_schema_migrations(version INTEGER)')
                db.execute('INSERT INTO factory_schema_migrations VALUES(54)')
                db.execute('CREATE TABLE workspace_access(reservation_key TEXT,generation INTEGER,released_at TEXT,release_receipt_json TEXT)')
                db.execute('INSERT INTO workspace_access VALUES(?,?,?,?)', ('access', 67, 'released', row['candidate_handoff']))
            with tools.read_only(path) as db:
                self.assertEqual(tools.validate_ticket(db, expected)['run_sha256'], expected['run_sha256'])
                self.assertEqual(db.total_changes, 0)
            for field in row:
                if field == 'run_id':
                    continue
                changed = 1 if row[field] is None else 'different'
                with closing(sqlite3.connect(path)) as db, db:
                    db.execute('UPDATE runs SET "'+field+'"=?', (changed,))
                with self.subTest(field=field), tools.read_only(path) as db, self.assertRaises(AssertionError):
                    tools.validate_ticket(db, expected)
                with closing(sqlite3.connect(path)) as db, db:
                    db.execute('UPDATE runs SET "'+field+'"=?', (row[field],))

    def test_every_old_table_row_schema_and_uncertainty_remain_exact(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.sqlite'
            with closing(sqlite3.connect(path)) as db, db:
                db.executescript('''
CREATE TABLE events(id INTEGER PRIMARY KEY,event_type TEXT,payload_json TEXT);
INSERT INTO events VALUES(1,'OLD_UNKNOWN','original');
CREATE TABLE runs(run_id TEXT,state TEXT);
INSERT INTO runs VALUES('completed','READY_FOR_REVIEW');
CREATE TABLE worker_evidence(status TEXT,output_json TEXT);
INSERT INTO worker_evidence VALUES('RESULT_RECORDED','unchanged output');
CREATE TABLE arbitrary_history(phase TEXT,payload TEXT);
INSERT INTO arbitrary_history VALUES('PUSH_UNCERTAIN','do not clear');
CREATE TABLE control(value TEXT);
INSERT INTO control VALUES('timer');
''')
            with tools.read_only(path) as db:
                saved = tools.snapshot(db)
                tools.preserve(db, saved)
            mutations = (
                ("UPDATE events SET payload_json='rewritten'", "UPDATE events SET payload_json='original'"),
                ("UPDATE runs SET state='BUILDING'", "UPDATE runs SET state='READY_FOR_REVIEW'"),
                ("UPDATE worker_evidence SET status='CONSUMED'", "UPDATE worker_evidence SET status='RESULT_RECORDED'"),
                ("UPDATE arbitrary_history SET phase='CLEARED'", "UPDATE arbitrary_history SET phase='PUSH_UNCERTAIN'"),
                ("INSERT INTO arbitrary_history VALUES('NORMAL_LOOKING','not attributed')", "DELETE FROM arbitrary_history WHERE rowid=2"),
                ("INSERT INTO events VALUES(2,'NORMAL_TICK','not attributed')", "DELETE FROM events WHERE id=2"),
                ("CREATE INDEX changed_schema ON arbitrary_history(phase)", "DROP INDEX changed_schema"),
            )
            for change, restore in mutations:
                with closing(sqlite3.connect(path)) as db, db:
                    db.execute(change)
                with self.subTest(change=change), tools.read_only(path) as db, self.assertRaises(AssertionError):
                    tools.preserve(db, saved)
                with closing(sqlite3.connect(path)) as db, db:
                    db.execute(restore)
            with closing(sqlite3.connect(path)) as db, db:
                db.execute("UPDATE control SET value='later timer'")
            with tools.read_only(path) as db:
                tools.preserve(db, saved)

    def test_plist_changes_only_two_fields_and_compares_exact_preimage(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'service.plist'
            original = plistlib.dumps({'ProgramArguments': ['/original/launcher', 'workflow'],
                                      'EnvironmentVariables': {'MIX_BUILD_PATH': '/original/dev', 'KEEP': 'unchanged'},
                                      'KeepAlive': True, 'StandardErrorPath': '/logs/error'})
            path.write_bytes(original)
            path.chmod(0o640)
            changed = tools.replacement_plist(original, '/replacement/launcher', '/replacement/dev')
            tools.replace_plist(path, tools.sha(path), changed)
            expected = plistlib.loads(original)
            expected['ProgramArguments'][0] = '/replacement/launcher'
            expected['EnvironmentVariables']['MIX_BUILD_PATH'] = '/replacement/dev'
            self.assertEqual(plistlib.loads(path.read_bytes()), expected)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            with self.assertRaises(AssertionError):
                tools.replace_plist(path, tools.digest(original), original)
            self.assertEqual(path.read_bytes(), changed)
            tools.replace_plist(path, tools.sha(path), original)
            self.assertEqual(path.read_bytes(), original)

    def test_mailbox_is_owned_regular_complete_pairs_only(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            root.chmod(0o700)
            key = 'a'*32
            for phase in ('finished', 'response'):
                (root / (key+'.'+phase)).write_text('unread body')
            self.assertEqual(tools.mailbox_quiet(root)['finished_count'], 1)
            for phase in ('pending', 'running', 'known', 'response.json', 'newwriting'):
                path = root / ('b'*32+'.'+phase)
                path.write_text('must not be read')
                with self.subTest(phase=phase), self.assertRaises(AssertionError):
                    tools.mailbox_quiet(root)
                path.unlink()
            (root / (key+'.response')).unlink()
            with self.assertRaises(AssertionError):
                tools.mailbox_quiet(root)
            (root / (key+'.response')).symlink_to(root / (key+'.finished'))
            with self.assertRaises(AssertionError):
                tools.mailbox_quiet(root)

    def test_completed_known_result_requires_exact_unchanged_owned_pair(self):
        import base64

        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            root.chmod(0o700)
            key = 'c' * 32
            finished, response, known = (root / (key + '.' + phase) for phase in ('finished', 'response', 'known'))
            finished.write_bytes(b'exact request')
            response.write_bytes(b'exact response')
            finished.chmod(0o600)
            response.chmod(0o600)
            envelope = {'version': 1, 'mailbox_id': key, 'database_root': str(root.parent),
                        'request_sha256': tools.sha(finished), 'response_sha256': tools.sha(response),
                        'response_base64': base64.b64encode(response.read_bytes()).decode('ascii')}
            known.write_text(json.dumps(envelope))
            known.chmod(0o600)
            before = tools.mailbox_quiet(root)
            self.assertEqual(before['completed_known_hashes'][key]['known_sha256'], tools.sha(known))
            mutations = [('version', True), ('mailbox_id', 'd' * 32), ('database_root', str(root)),
                         ('request_sha256', '0' * 64), ('response_sha256', '0' * 64),
                         ('response_base64', envelope['response_base64'] + '\n'), ('unknown', 1)]
            for field, value in mutations:
                with self.subTest(field=field):
                    known.write_text(json.dumps({**envelope, field: value}))
                    with self.assertRaises(AssertionError):
                        tools.mailbox_quiet(root)
            for raw in (b'not JSON', b' ' * 2_800_001, json.dumps(envelope).replace('"version": 1', '"version": 1, "version": 1').encode()):
                with self.subTest(malformed_size=len(raw)):
                    known.write_bytes(raw)
                    with self.assertRaises(AssertionError):
                        tools.mailbox_quiet(root)
            known.write_text(json.dumps(envelope, indent=2))
            self.assertNotEqual(before, tools.mailbox_quiet(root))
            for mode in (0o644,):
                known.chmod(mode)
                with self.assertRaises(AssertionError):
                    tools.mailbox_quiet(root)
            known.chmod(0o600)
            response.unlink()
            with self.assertRaises(AssertionError):
                tools.mailbox_quiet(root)
            response.write_bytes(b'changed response')
            with self.assertRaises(AssertionError):
                tools.mailbox_quiet(root)
            response.write_bytes(b'exact response')
            known.unlink()
            known.symlink_to(finished)
            with self.assertRaises(AssertionError):
                tools.mailbox_quiet(root)

    def fixture_artifact(self, tools, root):
        release = root / 'symphony-review-report-fixture'
        source, build = root / 'source', release / 'dev'
        (release / 'evidence').mkdir(parents=True)
        source.mkdir()
        build.mkdir()
        (source / 'elixir/assets').mkdir(parents=True)
        placeholder = build / 'phoenix-colocated/symphony_elixir/node_modules'
        placeholder.parent.mkdir(parents=True)
        placeholder.symlink_to(os.path.relpath(source / 'elixir/assets/node_modules', placeholder.parent))
        (source / 'fixture.ex').write_text('source')
        (build / 'fixture.beam').write_text('compiled')
        (release / 'run-local-factory').write_text('launcher')
        (release / 'release_boot_guard.exs').write_text('guard')
        manifest = {'kind': 'FACTORY_REVIEW_REPORT_RELEASE_V1', 'activation': False,
                    'schema_version': 54, 'source_commit': 'a'*40,
                    'build': str(build), 'release': str(release), 'source_root': str(source),
                    'factory_beam_fingerprint': 'b'*64, 'factory_modules': {'module': 'c'*64},
                    'deployed_baseline_commit': tools.OLD_SOURCE,
                    'previous_manifest_sha256': tools.OLD_MANIFEST,
                    'base_artifact_manifest_sha256': tools.OLD_MANIFEST,
                    'artifact': tools.inventory(build, artifact_source=source), 'source': tools.inventory(source, True),
                    'source_hashes': {'fixture.ex': tools.sha(source / 'fixture.ex')}}
        path = release / 'evidence/release-manifest.json'
        path.write_bytes(tools.encode(manifest))
        candidate = {'result': 'BUILT_NOT_ACTIVATED', 'source_commit': 'a'*40, 'release': str(release),
                     'source': str(source), 'build': str(build), 'schema_version': 54,
                     'factory_beam_fingerprint': 'b'*64, 'factory_module_count': 1,
                     'manifest_sha256': tools.sha(path), 'guard_sha256': tools.sha(release / 'release_boot_guard.exs'),
                     'launcher_sha256': tools.sha(release / 'run-local-factory')}
        return candidate, manifest

    def test_artifact_full_inventory_and_typed_identity_fail_closed(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate, manifest = self.fixture_artifact(tools, root)
            self.assertEqual(tools.validate_candidate(candidate, root), manifest)
            for field in candidate:
                changed = False if type(candidate[field]) is int else 'wrong'
                with self.subTest(field=field), self.assertRaises((AssertionError, FileNotFoundError)):
                    tools.validate_candidate({**candidate, field: changed}, root)
            for path in (Path(candidate['build']) / 'fixture.beam', Path(candidate['source']) / 'fixture.ex'):
                original = path.read_bytes()
                path.write_bytes(b'changed')
                with self.subTest(path=path), self.assertRaises(AssertionError):
                    tools.validate_candidate(candidate, root)
                path.write_bytes(original)
            extra = Path(candidate['build']) / 'extra.beam'
            extra.write_bytes(b'unattested')
            with self.assertRaises(AssertionError):
                tools.validate_candidate(candidate, root)

    def fixture_validation(self, tools, root):
        candidate = {'source_commit': 'a'*40, 'manifest_sha256': 'b'*64, 'factory_beam_fingerprint': 'c'*64}
        log = root / 'tests.log'
        log.write_text('actual synthetic fixture result')
        tests = [{'environment': environment, 'category': category, 'count': 2,
                  'failures': 0, 'exit_code': 0, 'command': 'fixture-only synthetic command',
                  'log': log.name, 'log_sha256': tools.sha(log)}
                 for environment in ('source', 'artifact') for category in tools.TEST_CATEGORIES]
        validation = {**candidate, 'result': 'PASS', 'tests': tests,
                      'all_143_retained_and_five_022_private_resources_unchanged': True,
                      'quality_limits': {'credo_baseline': 653, 'credo_added': 0,
                                         'coverage': 'NOT_REACHED', 'dialyzer': 'NOT_REACHED'}}
        return candidate, validation

    def test_evidence_requires_all_source_and_package_categories_and_real_logs(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate, value = self.fixture_validation(tools, root)
            tools.validate_validation(candidate, value, root)
            for index in range(len(value['tests'])):
                changed = copy.deepcopy(value)
                del changed['tests'][index]
                with self.subTest(missing=index), self.assertRaises(AssertionError):
                    tools.validate_validation(candidate, changed, root)
            for field, changed in (('count', True), ('failures', True), ('exit_code', 1), ('command', ''), ('log_sha256', '0'*64)):
                bad = copy.deepcopy(value)
                bad['tests'][0][field] = changed
                with self.subTest(field=field), self.assertRaises(AssertionError):
                    tools.validate_validation(candidate, bad, root)
            for field in candidate:
                with self.subTest(identity=field), self.assertRaises(AssertionError):
                    tools.validate_validation(candidate, {**value, field: 'wrong'}, root)
            changed = copy.deepcopy(value)
            changed['quality_limits']['credo_added'] = 1
            with self.assertRaises(AssertionError):
                tools.validate_validation(candidate, changed, root)

    def test_publication_requires_two_actual_read_only_proofs_on_exact_build(self):
        tools = load_tools()
        candidate = {'source_commit': 'a'*40, 'manifest_sha256': 'b'*64}
        manifest = {'artifact': {'lib/symphony_elixir/priv/ticket_push_history_validator_v26.py': {'sha256': 'c'*64}}}
        common = {**candidate, 'result': 'PASS', 'run_id': tools.RUN, 'current_candidate_sha': tools.CANDIDATE,
                  'envelope_sha256': tools.TICKET['envelope_sha256'], 'receipt_sha256': tools.TICKET['receipt_sha256'],
                  'receipt_bytes': 387927, 'read_only_sqlite_reopens': 2,
                  'live_ledger_writes': 0, 'pushes': 0, 'native_chats': 0, 'native_model_turns': 0,
                  'entire_run_access_and_history_unchanged': True, 'human_head_unchanged': True}
        public = {**common, 'kind': 'READY_COMPLETED_PUBLIC_PROOF_V1', 'public_readback': True,
                  'receipt_valid': True, 'completed_proof': True, 'validate_completed_proof': True}
        history = {**common, 'kind': 'READY_COMPLETED_HISTORY_PROOF_V1', 'full_physical_predecessor': True,
                   'retained_generation_authority': True, 'recorded_git_diff_paths_and_generated_blobs': True,
                   'historical_rollover_verifier_and_ci': True, 'history_sha256': 'c'*64,
                   'issuance_freshness': 'NOT_RERUN_HISTORICAL_READ_ONLY'}
        tools.validate_publication(candidate, manifest, public, history)
        for target, original in (('public', public), ('history', history)):
            for field, old in original.items():
                changed = not old if type(old) is bool else -1 if type(old) is int else 'wrong'
                bad = {**original, field: changed}
                args = (bad, history) if target == 'public' else (public, bad)
                with self.subTest(target=target, field=field), self.assertRaises(AssertionError):
                    tools.validate_publication(candidate, manifest, *args)

    def test_pinned_guard_import_does_not_call_old_main_and_refuses_drift(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            guard, _ = tools.bind(root)
            self.assertEqual((guard.OLD_PID, guard.OLD_START, guard.OLD_FINGERPRINT),
                             (tools.OLD_PID, tools.OLD_START, tools.OLD_FINGERPRINT))
            self.assertNotEqual(guard.qualified.__code__.co_filename, str(tools.HISTORICAL / 'cutover_guard.py'))
            self.assertNotEqual(guard.start.__code__.co_filename, str(tools.HISTORICAL / 'cutover_guard.py'))
            changed = root / 'guard.py'
            changed.write_text('raise AssertionError("must not execute")')
            with self.assertRaises(AssertionError):
                tools.import_pinned(changed, '0'*64, 'wrong_guard')

    def test_cli_cannot_override_database_or_use_old_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            for args in (['prepare', directory], ['capture', directory, '--database', '/tmp/anything']):
                result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'review_ready_cutover.py'), *args], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_missing_or_changed_approval_file_is_not_acceptance(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate = {'source_commit': 'a'*40, 'manifest_sha256': 'b'*64}
            for name in tools.REQUIRED_EVIDENCE:
                (root / name).write_text('private synthetic evidence '+name)
            (root / 'thaw_guardian.py').write_bytes((tools.HISTORICAL / 'thaw_guardian.py').read_bytes())
            approval = {'result': 'ACCEPT_FOR_CUTOVER_ONLY', **candidate,
                        'cutover_guard_sha256': tools.sha(ROOT / 'review_ready_cutover.py'),
                        'guardian_sha256': tools.THAW_SHA,
                        'evidence': {name: tools.sha(root / name) for name in tools.REQUIRED_EVIDENCE}}
            tools.validate_approval(approval, candidate, root)
            for name in tools.REQUIRED_EVIDENCE:
                changed = copy.deepcopy(approval)
                del changed['evidence'][name]
                with self.subTest(missing=name), self.assertRaises(AssertionError):
                    tools.validate_approval(changed, candidate, root)
            for field in ('result', 'source_commit', 'manifest_sha256', 'cutover_guard_sha256', 'guardian_sha256'):
                with self.subTest(field=field), self.assertRaises(AssertionError):
                    tools.validate_approval({**approval, field: 'wrong'}, candidate, root)
            (root / 'validation.json').write_text('changed after review')
            with self.assertRaises(AssertionError):
                tools.validate_approval(approval, candidate, root)

    def test_stale_process_or_service_binding_is_rejected(self):
        tools = load_tools()
        control = {'tick_id': None, 'lease_expires_at': None,
                   'runtime_identity': {'os_pid': tools.OLD_PID, 'factory_beam_fingerprint': tools.OLD_FINGERPRINT}}
        launchd = 'pid = '+tools.OLD_PID+'\nprogram = '+str(tools.OLD_RELEASE / 'run-local-factory')+'\n'
        tools.validate_old_binding(control, tools.OLD_START, launchd, True)
        for field, value in (('os_pid', '1'), ('factory_beam_fingerprint', '0'*64)):
            bad = copy.deepcopy(control)
            bad['runtime_identity'][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                tools.validate_old_binding(bad, tools.OLD_START, launchd, True)
        for start, output in (('new start', launchd), (tools.OLD_START, 'pid = 1\n'),
                              (tools.OLD_START, launchd.replace('216eadb', 'e47cce2-r2'))):
            with self.subTest(start=start, output=output), self.assertRaises(AssertionError):
                tools.validate_old_binding(control, start, output, True)
        for field in ('tick_id', 'lease_expires_at'):
            with self.subTest(field=field), self.assertRaises(AssertionError):
                tools.validate_old_binding({**control, field: 'active'}, tools.OLD_START, launchd, True)

    def test_active_writer_check_io_and_control_are_refused_at_real_store_boundary(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            mailbox = root / 'mailbox'
            mailbox.mkdir(mode=0o700)
            for phase in ('finished', 'response'):
                (mailbox / ('a'*32+'.'+phase)).write_text('unread')
            database = root / 'quiet.sqlite'
            with closing(sqlite3.connect(database)) as db, db:
                db.executescript('''
CREATE TABLE control(scope TEXT,status TEXT,tick_id TEXT,lease_expires_at TEXT);
INSERT INTO control VALUES('assigned-jira-work','ACTIVE',NULL,NULL);
CREATE TABLE factory_tasks(status TEXT);
CREATE TABLE worker_file_operations(phase TEXT,io_pending INTEGER);
CREATE TABLE controller_checks(phase TEXT);
CREATE TABLE worker_evidence(owner_process_json TEXT,owner_stopped_at TEXT);
''')
            guard, _ = tools.bind(root)
            guard.DB = database
            with patch.object(tools, 'MAILBOX', mailbox):
                guard.quiet()
                for table, values in (('factory_tasks', "'RUNNING'"), ('controller_checks', "'PREPARED'"),
                                      ('worker_file_operations', "'PREPARED',0"), ('worker_file_operations', "'COMPLETE',1")):
                    with closing(sqlite3.connect(database)) as db, db:
                        db.execute('INSERT INTO '+table+' VALUES('+values+')')
                    with self.subTest(table=table, values=values), self.assertRaises(AssertionError):
                        guard.quiet()
                    with closing(sqlite3.connect(database)) as db, db:
                        db.execute('DELETE FROM '+table)
                with closing(sqlite3.connect(database)) as db, db:
                    db.execute('INSERT INTO worker_evidence VALUES(?,NULL)', (json.dumps({'pid': 123}),))
                with patch.object(guard.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '123\n', '')):
                    with self.assertRaises(AssertionError):
                        guard.quiet()
                with patch.object(guard.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')):
                    guard.quiet()

    def test_rollback_allows_only_original_216_or_its_exact_two_field_replacement(self):
        tools = load_tools()
        original = plistlib.dumps({'ProgramArguments': [str(tools.OLD_RELEASE / 'run-local-factory'), '/workflow'],
                                  'EnvironmentVariables': {'MIX_BUILD_PATH': '/original/dev', 'KEEP': 'yes'}})
        audit = {'replacement_launcher': '/symphony-review-report-fixture/run-local-factory',
                 'replacement_build': '/symphony-review-report-fixture/dev',
                 'replacement_manifest': '/symphony-review-report-fixture/evidence/release-manifest.json'}
        tools.validate_restore_plist(original, original, audit, '/workflow', '/original/dev')
        replacement = tools.replacement_plist(original, audit['replacement_launcher'], audit['replacement_build'])
        tools.validate_restore_plist(original, replacement, audit, '/workflow', '/original/dev')
        for raw in (original.replace(b'216eadb', b'e47cce2'),
                    plistlib.dumps({**plistlib.loads(replacement), 'KeepAlive': False})):
            with self.assertRaises(AssertionError):
                tools.validate_restore_plist(original, raw, audit, '/workflow', '/original/dev')
        tools.validate_replacement_absent('123 /unrelated/process', audit)
        for field in ('replacement_launcher', 'replacement_build'):
            with self.subTest(alive=field), self.assertRaises(AssertionError):
                tools.validate_replacement_absent('456 '+audit[field], audit)

    def test_beam_guard_and_manifest_argv_refuse_bound_absence_and_restore_before_bootstrap(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release = root / 'symphony-review-report-candidate'
            audit = {'replacement_launcher': str(release / 'run-local-factory'),
                     'replacement_build': str(release / 'dev'),
                     'replacement_manifest': str(release / 'evidence/release-manifest.json')}
            beam = ('123 /opt/erlang/erts/bin/beam.smp -- -extra -S mix run --no-compile --no-start -e '
                    'path = "'+str(release / 'release_boot_guard.exs')+'"; '
                    'ReviewReportReleaseBootGuard.load("'+audit['replacement_manifest']+'", "manifest"); '
                    'SymphonyElixir.CLI.main(System.argv())')
            self.assertNotIn(audit['replacement_launcher'], beam)
            self.assertNotIn(audit['replacement_build'], beam)
            with self.assertRaisesRegex(AssertionError, 'replacement process'):
                tools.validate_replacement_absent(beam, audit)
            (root / 'cutover-audit.json').write_bytes(tools.encode(audit))
            guard, _ = tools.bind(root)
            guard.DB = root / 'must-not-open.sqlite'
            guard.original_pins = lambda: {'build': 'owned fixture', 'source': 'owned fixture', 'native_runtime_formats': {'worker_binding_versions': [1], 'completion_receipt_versions': [1]}}
            commands = []

            def os_boundary(args, **_options):
                commands.append(args)
                if args == ['/bin/ps', '-p', tools.OLD_PID, '-o', 'pid=']:
                    return subprocess.CompletedProcess(args, 1, '', '')
                if args == ['/bin/launchctl', 'print', guard.SERVICE]:
                    return subprocess.CompletedProcess(args, 1, '', '')
                if args == ['/bin/ps', '-axo', 'pid=,command=']:
                    return subprocess.CompletedProcess(args, 0, beam, '')
                raise AssertionError('unexpected process-control call: '+repr(args))

            with patch.object(guard.subprocess, 'run', side_effect=os_boundary), \
                    patch.object(guard.urllib.request, 'urlopen', side_effect=urllib.error.URLError(ConnectionRefusedError())):
                for operation in (guard.absent, guard.restore_check, guard.restore_original):
                    with self.subTest(operation=operation.__name__), self.assertRaisesRegex(AssertionError, 'replacement process'):
                        operation()
            self.assertFalse(guard.DB.exists())
            self.assertFalse(any('bootstrap' in args or 'bootout' in args for args in commands))
            tools.validate_replacement_absent('456 /unrelated/process', audit)
            for field, value in (('replacement_launcher', 'relative/run-local-factory'),
                                 ('replacement_launcher', str(release / 'other-program')),
                                 ('replacement_build', '/other/dev'),
                                 ('replacement_manifest', str(release / 'other-manifest.json'))):
                with self.subTest(malformed=field, value=value), self.assertRaises(AssertionError):
                    tools.validate_replacement_absent('', {**audit, field: value})

    def test_partial_and_complete_poststart_proofs_never_block_fresh_read_only_reconciliation(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate, manifest = self.fixture_artifact(tools, root)
            manifest['artifact']['lib/symphony_elixir/priv/ticket_push_history_validator_v26.py'] = {'sha256': 'd'*64}
            manifest_path = Path(candidate['release']) / 'evidence/release-manifest.json'
            manifest_path.write_bytes(tools.encode(manifest))
            candidate['manifest_sha256'] = tools.sha(manifest_path)
            public_old = root / 'poststart-public-completed.json'
            public_old.write_text('retained partial proof bytes')
            common = {'result': 'PASS', 'manifest_sha256': candidate['manifest_sha256'],
                      'source_commit': candidate['source_commit'], 'run_id': tools.RUN,
                      'current_candidate_sha': tools.CANDIDATE, 'envelope_sha256': tools.TICKET['envelope_sha256'],
                      'receipt_sha256': tools.TICKET['receipt_sha256'], 'receipt_bytes': 387927,
                      'read_only_sqlite_reopens': 2, 'live_ledger_writes': 0, 'pushes': 0,
                      'native_chats': 0, 'native_model_turns': 0,
                      'entire_run_access_and_history_unchanged': True, 'human_head_unchanged': True}
            commands, outputs, fail_history = [], [], [False]

            def subprocess_boundary(args, **_options):
                commands.append(args)
                self.assertNotIn('bootstrap', args)
                self.assertNotIn('bootout', args)
                self.assertEqual(_options['env'].get('MIX_BUILD_PATH'), candidate['build'])
                path = Path(args[-1])
                self.assertFalse(path.exists(), 'each qualification needs a fresh exclusive output')
                if any(str(arg).endswith('qualify_review_ready_publication.exs') for arg in args):
                    proof = {**common, 'kind': 'READY_COMPLETED_PUBLIC_PROOF_V1',
                             'public_readback': True, 'receipt_valid': True,
                             'completed_proof': True, 'validate_completed_proof': True}
                else:
                    proof = {**common, 'kind': 'READY_COMPLETED_HISTORY_PROOF_V1',
                             'history_sha256': 'd'*64, 'full_physical_predecessor': True,
                             'retained_generation_authority': True, 'recorded_git_diff_paths_and_generated_blobs': True,
                             'historical_rollover_verifier_and_ci': True,
                             'issuance_freshness': 'NOT_RERUN_HISTORICAL_READ_ONLY'}
                    if fail_history[0]:
                        proof['result'] = 'FAIL'
                        fail_history[0] = False
                with path.open('xb') as stream:
                    stream.write(tools.encode(proof))
                outputs.append(path)
                return subprocess.CompletedProcess(args, 0, '', '')

            with patch.object(tools.subprocess, 'run', side_effect=subprocess_boundary), \
                    patch.dict(tools.os.environ, {'MIX_BUILD_PATH': '/hostile-caller-build'}):
                self.assertTrue(tools.run_qualifiers(candidate, root, 'poststart'))
                history_old = root / 'poststart-historical-completed.json'
                history_old.write_text('retained complete proof bytes')
                self.assertTrue(tools.run_qualifiers(candidate, root, 'poststart'))
                self.assertTrue(tools.run_qualifiers(candidate, root, 'poststart'))
                fail_history[0] = True
                with self.assertRaises(AssertionError):
                    tools.run_qualifiers(candidate, root, 'poststart')
                retained = {path: path.read_bytes() for path in outputs}
                self.assertTrue(tools.run_qualifiers(candidate, root, 'poststart'))
                self.assertTrue(all(path.read_bytes() == raw for path, raw in retained.items()))
                self.assertTrue(any(json.loads(raw)['result'] == 'FAIL' for raw in retained.values()))
            self.assertEqual(public_old.read_text(), 'retained partial proof bytes')
            self.assertEqual(history_old.read_text(), 'retained complete proof bytes')
            self.assertEqual(len(outputs), 10)
            self.assertEqual(len(set(outputs)), 10)
            self.assertTrue(all(path.is_file() for path in outputs))
            self.assertEqual(len(commands), 10)

    def test_placeholder_contract_rejects_changed_shape_target_context_and_other_links(self):
        tools = load_tools()
        changes = ('missing', 'file', 'directory', 'normalized-raw-alias', 'foreign-target',
                   'existing-target-directory', 'dangling-target-alias', 'extra-artifact-link',
                   'helper-link', 'redirected-placeholder-parent', 'redirected-root', 'redirected-source')
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                candidate, _ = self.fixture_artifact(tools, root)
                build, source = Path(candidate['build']), Path(candidate['source'])
                placeholder = build / 'phoenix-colocated/symphony_elixir/node_modules'
                target = source / 'elixir/assets/node_modules'
                if change in ('missing', 'file', 'directory', 'normalized-raw-alias', 'foreign-target'):
                    raw = os.readlink(placeholder)
                    placeholder.unlink()
                    if change == 'file':
                        placeholder.write_bytes(b'must not be skipped')
                    elif change == 'directory':
                        placeholder.mkdir()
                        (placeholder / 'unexpected.js').write_bytes(b'must not be traversed')
                    elif change == 'normalized-raw-alias':
                        placeholder.symlink_to('./'+raw)
                    elif change == 'foreign-target':
                        placeholder.symlink_to(root / 'foreign-absent')
                elif change == 'existing-target-directory':
                    target.mkdir()
                elif change == 'dangling-target-alias':
                    target.symlink_to(root / 'absent')
                elif change in ('extra-artifact-link', 'helper-link'):
                    path = build / ('other-link' if change == 'extra-artifact-link' else 'lib/symphony_elixir/priv/helper.py')
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.symlink_to(root / 'absent')
                elif change == 'redirected-placeholder-parent':
                    original = build / 'phoenix-colocated'
                    destination = root / 'redirected-colocated'
                    original.rename(destination)
                    original.symlink_to(destination, target_is_directory=True)
                elif change == 'redirected-root':
                    alias = root / 'build-alias'
                    alias.symlink_to(build, target_is_directory=True)
                    build = alias
                elif change == 'redirected-source':
                    alias = root / 'source-alias'
                    alias.symlink_to(source, target_is_directory=True)
                    source = alias
                with self.assertRaises((AssertionError, OSError)):
                    tools.inventory(build, artifact_source=source)

    def test_no_context_and_source_inventory_never_gain_a_link_exception(self):
        tools = load_tools()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate, _ = self.fixture_artifact(tools, root)
            build, source = Path(candidate['build']), Path(candidate['source'])
            with self.assertRaises(AssertionError):
                tools.inventory(build)
            with self.assertRaises(AssertionError):
                tools.inventory(source, True, artifact_source=source)
            link = source / 'elixir/priv/helper.py'
            link.parent.mkdir()
            link.symlink_to(root / 'absent')
            with self.assertRaises(AssertionError):
                tools.inventory(source, True)

    def test_placeholder_metadata_must_match_owned_pilot_link_without_privileged_chown(self):
        tools = load_tools()
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink', 'st_mtime_ns', 'st_ctime_ns')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate, _ = self.fixture_artifact(tools, root)
            build, source = Path(candidate['build']), Path(candidate['source'])
            placeholder = build / 'phoenix-colocated/symphony_elixir/node_modules'
            original_lstat = Path.lstat
            for field, value in (('st_uid', os.getuid()+1), ('st_gid', 21),
                                 ('st_nlink', 2), ('st_mode', 0o120777)):
                def metadata(path, *, _field=field, _value=value):
                    original = original_lstat(path)
                    if path == placeholder:
                        values = {name: getattr(original, name) for name in fields}
                        values[_field] = _value
                        return types.SimpleNamespace(**values)
                    return original
                with self.subTest(field=field), patch.object(Path, 'lstat', metadata), self.assertRaises(AssertionError):
                    tools.inventory(build, artifact_source=source)

    def test_changed_placeholder_at_enumeration_is_not_blindly_skipped(self):
        tools = load_tools()
        original_rglob = Path.rglob
        for replacement in ('file', 'directory', 'missing'):
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                candidate, _ = self.fixture_artifact(tools, root)
                build, source = Path(candidate['build']), Path(candidate['source'])
                placeholder = build / 'phoenix-colocated/symphony_elixir/node_modules'

                def changed_enumeration(path, pattern):
                    for item in original_rglob(path, pattern):
                        if item == placeholder:
                            placeholder.unlink()
                            if replacement == 'file':
                                placeholder.write_bytes(b'changed after validation')
                            elif replacement == 'directory':
                                placeholder.mkdir()
                        yield item

                with patch.object(Path, 'rglob', changed_enumeration), self.assertRaises((AssertionError, OSError)):
                    tools.inventory(build, artifact_source=source)

    def test_replaced_equivalent_link_after_enumeration_fails_final_identity_confirmation(self):
        tools = load_tools()
        original_rglob = Path.rglob
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate, _ = self.fixture_artifact(tools, root)
            build, source = Path(candidate['build']), Path(candidate['source'])
            placeholder = build / 'phoenix-colocated/symphony_elixir/node_modules'
            raw = os.readlink(placeholder)
            replacement = root / 'replacement-link'
            replacement.symlink_to(raw)

            def changed_after_enumeration(path, pattern):
                yield from original_rglob(path, pattern)
                os.replace(replacement, placeholder)

            with patch.object(Path, 'rglob', changed_after_enumeration), self.assertRaises(AssertionError):
                tools.inventory(build, artifact_source=source)


if __name__ == '__main__':
    unittest.main()
