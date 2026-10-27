"""Offline READY-only rollout seams; all database and artifact inputs are temporary."""

import copy
from contextlib import closing
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent


def load_tools():
    spec = importlib.util.spec_from_file_location('ready_rollout', ROOT / 'review_ready_cutover.py')
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class ReadyRolloutTests(unittest.TestCase):
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

    def fixture_artifact(self, tools, root):
        release = root / 'symphony-review-report-fixture'
        source, build = root / 'source', release / 'dev'
        (release / 'evidence').mkdir(parents=True)
        source.mkdir()
        build.mkdir()
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
                    'artifact': tools.inventory(build), 'source': tools.inventory(source, True),
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
        audit = {'replacement_launcher': '/replacement/run-local-factory', 'replacement_build': '/replacement/dev'}
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


if __name__ == '__main__':
    unittest.main()
