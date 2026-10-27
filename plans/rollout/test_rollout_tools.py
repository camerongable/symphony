"""Fail-closed preparation checks; never controls launchd or opens the live ledger."""

import hashlib
import importlib.util
import json
import plistlib
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class PreparationTests(unittest.TestCase):
    def test_cutover_requires_both_current_qualification_files(self):
        cutover = module('required_current_qualifications', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = ('candidate.json', 'validation.json', 'review-acceptance.json',
                     'service.original.plist', 'audited-protected.json', 'cutover-audit.json',
                     'cold-boot.json', 'historical-readback-qualification.json',
                     'current-publication-chain.json', 'current-rejection-qualification.json')
            approval = {'result': 'ACCEPT_FOR_CUTOVER_ONLY', 'manifest_sha256': 'manifest',
                        'cutover_guard_sha256': 'guard', 'guardian_sha256': cutover.THAW_SHA,
                        'evidence': dict.fromkeys(names, 'evidence')}
            cutover.validate_approval_evidence_files(approval)
            for name in ('current-publication-chain.json', 'current-rejection-qualification.json'):
                del approval['evidence'][name]
                with self.subTest(name=name), self.assertRaises(AssertionError):
                    cutover.validate_approval_evidence_files(approval)
                approval['evidence'][name] = 'evidence'

    def test_current_publication_gate_rejects_incomplete_or_other_candidate_evidence(self):
        cutover = module('current_publication_test', ROOT / 'review_cutover.py')
        candidate = {'source_commit': 'frozen-commit', 'manifest_sha256': 'candidate-manifest'}
        manifest = {'artifact': {'lib/symphony_elixir/priv/ticket_push_history_validator_v25.py':
                                {'sha256': 'frozen-history'},
                                'lib/symphony_elixir/priv/ticket_push_ordinary_rejection_v4.json':
                                {'sha256': 'dfc045f0753fa7d7ddaa3ddd28bbfe0c00031391bef216903a75c0c48314101f'}}}
        common = {'result': 'PASS', 'manifest_sha256': candidate['manifest_sha256'],
                  'current_candidate_sha': cutover.CANDIDATE, 'live_ledger_writes': 0,
                  'pushes': 0, 'native_chats': 0, 'native_model_turns': 0}
        chain = {**common, 'history_sha256': 'frozen-history', 'read_only_sqlite_reopens': 2,
                 'current_repair_preparation_retirement_import_worker_and_generation_valid': True,
                 'exact_parent_committed_paths_and_generated_blob_hashes_valid': True,
                 'genuine_owned_stdin_open': True, 'current_raw_run_unchanged': True}
        rejection = {**common, 'source_commit': candidate['source_commit'],
                     'original_envelope_sha256': '5935494d2f4b8b2ec0c3e5778a2e297d64f138c73469140db4c20ae3f549c209',
                     'rejection_sha256': '44477a82a476e1f83f47b5af4a3182ee4b9962be537e5c542989aa20dea6c40b',
                     'audit_sha256': 'dfc045f0753fa7d7ddaa3ddd28bbfe0c00031391bef216903a75c0c48314101f',
                     'child_pid': None, 'rejection_bytes': 365726,
                     'exact_audited_closed_authority': True,
                     'original_run_and_three_prior_retirements_unchanged': True}
        cutover.validate_current_publication_evidence(candidate, manifest, chain, rejection)
        for artifact in manifest['artifact']:
            mutated_manifest = {'artifact': {**manifest['artifact'], artifact: {'sha256': 'different-build'}}}
            with self.subTest(artifact=artifact), self.assertRaises(AssertionError):
                cutover.validate_current_publication_evidence(candidate, mutated_manifest, chain, rejection)
        for target, original in (('chain', chain), ('rejection', rejection)):
            for field, old in original.items():
                new = not old if type(old) is bool else 7 if old is None or type(old) is int else 'other'
                mutated = {**original, field: new}
                args = (mutated, rejection) if target == 'chain' else (chain, mutated)
                with self.subTest(target=target, field=field), self.assertRaises(AssertionError):
                    cutover.validate_current_publication_evidence(candidate, manifest, *args)
                missing = dict(original)
                del missing[field]
                args = (missing, rejection) if target == 'chain' else (chain, missing)
                with self.subTest(missing=target, field=field), self.assertRaises(KeyError):
                    cutover.validate_current_publication_evidence(candidate, manifest, *args)

    def test_artifact_inventory_excludes_only_bounded_regular_mix_test_metadata(self):
        builder = module('test_metadata_inventory', ROOT / 'build_review_release.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = root / 'lib/symphony_elixir/.mix'
            metadata.mkdir(parents=True)
            executable = root / 'lib/symphony_elixir/module.beam'
            executable.write_bytes(b'code')
            expected = builder.inventory(root)
            cache = metadata / '.mix_test_failures'
            cache.write_bytes(b'generated test result')
            self.assertEqual(builder.artifact_inventory(root), expected)
            unknown = metadata / 'unknown'
            unknown.write_bytes(b'unknown file')
            self.assertIn('lib/symphony_elixir/.mix/unknown', builder.artifact_inventory(root))
            executable.write_bytes(b'changed code')
            self.assertNotEqual(builder.artifact_inventory(root)['lib/symphony_elixir/module.beam'], expected['lib/symphony_elixir/module.beam'])

    def test_artifact_inventory_rejects_linked_test_metadata(self):
        builder = module('linked_metadata_inventory', ROOT / 'build_review_release.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = root / 'lib/symphony_elixir/.mix'
            metadata.mkdir(parents=True)
            external = root / 'external'
            external.write_bytes(b'external')
            (metadata / '.mix_test_failures').symlink_to(external)
            with self.assertRaises(AssertionError):
                builder.artifact_inventory(root)

    def test_original_c66_pins_validate_the_full_release_not_an_overlay(self):
        cutover = module('original_c66_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release, source = root / 'original', root / 'source'
            (release / 'evidence').mkdir(parents=True)
            (release / 'dev').mkdir()
            source.mkdir()
            artifact = release / 'dev/fixture.beam'
            artifact.write_bytes(b'original artifact')
            (source / 'fixture.ex').write_text('original source')
            launcher, guard = release / 'run-local-factory', release / 'release_boot_guard.exs'
            launcher.write_text('launcher')
            guard.write_text('guard')
            manifest = release / 'evidence/release-manifest.json'
            manifest.write_text(json.dumps({'build': str(release / 'dev'), 'source_root': str(source),
                                           'source_hashes': {'fixture.ex': cutover.sha(source / 'fixture.ex')},
                                           'artifact': {'fixture.beam': {'sha256': cutover.sha(artifact)}}}))
            with patch.multiple(cutover, OLD_RELEASE=release, OLD_MANIFEST_SHA=cutover.sha(manifest),
                                OLD_LAUNCHER_SHA=cutover.sha(launcher), OLD_BOOT_SHA=cutover.sha(guard)):
                g, _capture = cutover.bind(root)
                self.assertEqual(g.original_pins(), {'build': str(release / 'dev'), 'source': str(source)})
                artifact.write_bytes(b'changed artifact')
                with self.assertRaises(AssertionError):
                    g.original_pins()

    def test_atomic_plist_change_preserves_unrelated_settings_and_restores_exact_bytes(self):
        cutover = module('atomic_plist_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'service.plist'
            original = plistlib.dumps({'ProgramArguments': ['/old/launcher', 'workflow'],
                                      'EnvironmentVariables': {'MIX_BUILD_PATH': '/old/build', 'KEEP': 'value'},
                                      'KeepAlive': True, 'StandardErrorPath': '/logs/errors'})
            path.write_bytes(original)
            path.chmod(0o640)
            expected = plistlib.loads(original)
            expected['ProgramArguments'][0] = '/new/launcher'
            expected['EnvironmentVariables']['MIX_BUILD_PATH'] = '/new/build'
            changed = plistlib.dumps(expected)
            cutover.replace_plist(path, cutover.sha(path), changed)
            self.assertEqual(path.read_bytes(), changed)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(plistlib.loads(changed)['EnvironmentVariables']['KEEP'], 'value')
            with self.assertRaises(AssertionError):
                cutover.replace_plist(path, 'stale', original)
            self.assertEqual(path.read_bytes(), changed)
            cutover.replace_plist(path, cutover.sha(path), original)
            self.assertEqual(path.read_bytes(), original)

    def test_poststart_checks_allow_consumption_but_reject_changed_evidence_and_event_prefix(self):
        cutover = module('poststart_history_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / 'fixture.sqlite'
            with sqlite3.connect(database) as db:
                db.executescript('''
CREATE TABLE factory_schema_migrations(version INTEGER);
INSERT INTO factory_schema_migrations VALUES (54);
CREATE TABLE events(id INTEGER PRIMARY KEY, payload TEXT);
INSERT INTO events VALUES(1,'original');
CREATE TABLE worker_instruction_snapshots(value TEXT);
CREATE TABLE worker_instruction_task_bindings(value TEXT);
CREATE TABLE worker_file_operations(value TEXT);
CREATE TABLE ticket_mr_claims(value TEXT);
CREATE TABLE ticket_mr_actor_bindings(value TEXT);
CREATE TABLE ticket_push_rejection_retirements(value TEXT);
INSERT INTO ticket_push_rejection_retirements VALUES('prior-retirement');
CREATE TABLE ticket_ordinary_generation_intents(value TEXT);
INSERT INTO ticket_ordinary_generation_intents VALUES('prior-generation');
CREATE TABLE ticket_ordinary_generation_events(value TEXT);
INSERT INTO ticket_ordinary_generation_events VALUES('prior-generation-event');
CREATE TABLE synthetic_journal(phase TEXT,payload TEXT);
INSERT INTO synthetic_journal VALUES('FIRST_UNCERTAIN','original');
CREATE TABLE worker_evidence(request_key TEXT PRIMARY KEY,binding_json TEXT,binding_sha256 TEXT,
 output_json TEXT,output_sha256 TEXT,thread_id TEXT,turn_id TEXT,owner_stopped_at TEXT,owner_stop_json TEXT,status TEXT);
INSERT INTO worker_evidence VALUES('request','binding','binding-sha','output','output-sha','thread','turn','stopped','stop-proof','RESULT_RECORDED');
CREATE TABLE factory_tasks(task_key TEXT PRIMARY KEY,status TEXT,updated_at TEXT,output_json TEXT);
INSERT INTO factory_tasks VALUES('old-task','CONSUMED','old-time','original-output');
CREATE TABLE desktop_requests(request_key TEXT PRIMARY KEY,status TEXT);
INSERT INTO desktop_requests VALUES('old-uncertain','RECONCILE_REQUIRED');
''')
                with sqlite3.connect(root / 'before-cutover.sqlite') as backup:
                    db.commit()
                    db.backup(backup)
            with sqlite3.connect(database) as db:
                schema = [list(row) for row in db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')]
            schema_sha = hashlib.sha256(json.dumps(schema, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
            (root / 'audited-protected.json').write_text(json.dumps({'event_limit': 1, 'schema_sha256': schema_sha}))
            g, _capture = cutover.bind(root)
            g.readonly = lambda: sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
            g.historical_after_start()
            with sqlite3.connect(database) as db:
                db.execute("UPDATE worker_evidence SET request_key=?", (cutover.REPORT,))
            with sqlite3.connect(root / 'before-cutover.sqlite') as db:
                db.execute("UPDATE worker_evidence SET request_key=?", (cutover.REPORT,))
            with sqlite3.connect(database) as db:
                db.execute("UPDATE worker_evidence SET status='CONSUMED'")
                db.execute("INSERT INTO events VALUES(2,'ordinary adoption')")
            g.historical_after_start()
            for statement, restore in (
                ("UPDATE events SET payload='changed' WHERE id=1", "UPDATE events SET payload='original' WHERE id=1"),
                ("UPDATE worker_evidence SET output_json='rewritten'", "UPDATE worker_evidence SET output_json='output'"),
                ("UPDATE worker_evidence SET owner_stop_json='rewritten'", "UPDATE worker_evidence SET owner_stop_json='stop-proof'"),
                ("UPDATE ticket_push_rejection_retirements SET value='rewritten'", "UPDATE ticket_push_rejection_retirements SET value='prior-retirement'"),
                ("UPDATE ticket_ordinary_generation_intents SET value='rewritten'", "UPDATE ticket_ordinary_generation_intents SET value='prior-generation'"),
                ("UPDATE ticket_ordinary_generation_events SET value='rewritten'", "UPDATE ticket_ordinary_generation_events SET value='prior-generation-event'"),
                ("UPDATE factory_tasks SET output_json='rewritten'", "UPDATE factory_tasks SET output_json='original-output'"),
                ("UPDATE desktop_requests SET status='PENDING'", "UPDATE desktop_requests SET status='RECONCILE_REQUIRED'"),
                ("UPDATE synthetic_journal SET phase='CLEARED'", "UPDATE synthetic_journal SET phase='FIRST_UNCERTAIN'"),
                ("UPDATE factory_schema_migrations SET version=55", "UPDATE factory_schema_migrations SET version=54"),
                ("CREATE INDEX unexpected_history_index ON worker_evidence(status)", "DROP INDEX unexpected_history_index"),
            ):
                with sqlite3.connect(database) as db:
                    db.execute(statement)
                with self.subTest(statement=statement), self.assertRaises(AssertionError):
                    g.historical_after_start()
                with sqlite3.connect(database) as db:
                    db.execute(restore)

    def test_artifact_results_from_another_build_of_the_same_commit_are_rejected(self):
        cutover = module('review_evidence_test', ROOT / 'review_cutover.py')
        candidate = {'source_commit': 'same-commit', 'manifest_sha256': 'candidate-manifest',
                     'factory_beam_fingerprint': 'candidate-fingerprint'}
        validation = {**candidate, 'source_tests_passed': True, 'artifact_tests_passed': True,
                      'artifact_test_failures': 0}
        cutover.validate_artifact_evidence(candidate, validation)
        for field in ('manifest_sha256', 'factory_beam_fingerprint'):
            with self.subTest(field=field), self.assertRaises(AssertionError):
                cutover.validate_artifact_evidence(candidate, {**validation, field: 'other-build'})

    def test_stale_commit_is_rejected_before_evidence_is_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'evidence'
            completed = subprocess.run(
                ['python3', str(ROOT / 'build_review_release.py'),
                 '--worktree', str(ROOT.parents[1]), '--commit', 'not-current-head',
                 '--name', 'symphony-review-report-test', '--evidence', str(target)],
                capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn('AssertionError', completed.stderr)
            self.assertFalse(target.exists())

    def test_release_name_cannot_escape_the_release_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'evidence'
            completed = subprocess.run(
                ['python3', str(ROOT / 'build_review_release.py'),
                 '--worktree', str(ROOT.parents[1]), '--commit', 'irrelevant',
                 '--name', 'symphony-review-report-../../other', '--evidence', str(target)],
                capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(target.exists())

    def test_cutover_requires_broker_paused_and_leaves_monitor_paused(self):
        cutover = module('review_cutover_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            g, _capture = cutover.bind(root)
            g.BROKER, g.MONITOR, g.WORKFLOW = [root / name for name in ('broker.toml', 'monitor.toml', 'workflow.md')]
            g.BROKER.write_text('status="ACTIVE"\nrrule="FREQ=MINUTELY;INTERVAL=1"\n')
            g.MONITOR.write_text('status="PAUSED"\n')
            g.WORKFLOW.write_text('fixture')
            with self.assertRaises(AssertionError):
                g.configuration()
            g.BROKER.write_text('status="PAUSED"\nrrule="FREQ=MINUTELY;INTERVAL=1"\n')
            pins = g.configuration()
            self.assertEqual(set(pins), {str(g.BROKER), str(g.MONITOR), str(g.WORKFLOW)})
            g.MONITOR.write_text('status="ACTIVE"\n')
            with self.assertRaises(AssertionError):
                g.configuration()

    def test_cutover_rejects_changed_artifact_and_source(self):
        cutover = module('review_cutover_artifact_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / 'symphony-review-report-fixture'
            (release / 'evidence').mkdir(parents=True)
            build = release / 'dev'
            build.mkdir()
            artifact = build / 'fixture.beam'
            artifact.write_bytes(b'original compiled bytes')
            source = root / 'source'
            source.mkdir()
            source_file = source / 'fixture.ex'
            source_file.write_text('original source')
            guard, launcher = release / 'release_boot_guard.exs', release / 'run-local-factory'
            guard.write_text('guard fixture')
            launcher.write_text('launcher fixture')
            manifest = {'kind': 'FACTORY_REVIEW_REPORT_RELEASE_V1', 'schema_version': 54,
                        'build': str(build), 'source_root': str(source), 'source_commit': 'commit',
                        'factory_beam_fingerprint': 'fingerprint', 'factory_modules': {'fixture': 'digest'},
                        'previous_manifest_sha256': cutover.OLD_MANIFEST_SHA,
                        'artifact': {'fixture.beam': {'sha256': cutover.sha(artifact)}},
                        'source_hashes': {'fixture.ex': cutover.sha(source_file)}}
            manifest_path = release / 'evidence/release-manifest.json'
            manifest_path.write_text(json.dumps(manifest))
            candidate = {'release': str(release), 'build': str(build), 'source_commit': 'commit',
                         'schema_version': 54, 'factory_beam_fingerprint': 'fingerprint',
                         'factory_module_count': 1, 'manifest_sha256': cutover.sha(manifest_path),
                         'guard_sha256': cutover.sha(guard), 'launcher_sha256': cutover.sha(launcher)}
            (root / 'candidate.json').write_text(json.dumps(candidate))
            with patch.object(cutover, 'OLD_RELEASE', root / 'old-release'):
                g, _capture = cutover.bind(root)
                self.assertEqual(g.candidate()[0], candidate)
                artifact.write_bytes(b'changed compiled bytes')
                with self.assertRaises(AssertionError):
                    g.candidate()
                artifact.write_bytes(b'original compiled bytes')
                source_file.write_text('changed source')
                with self.assertRaises(AssertionError):
                    g.candidate()

    def test_restore_does_not_require_the_failed_replacement_candidate(self):
        cutover = module('review_restore_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            g, _capture = cutover.bind(root)
            g.BROKER, g.MONITOR, g.WORKFLOW = [root / name for name in ('broker.toml', 'monitor.toml', 'workflow.md')]
            g.PLIST = root / 'service.plist'
            g.BROKER.write_text('status="PAUSED"\nrrule="FREQ=MINUTELY;INTERVAL=1"\n')
            g.MONITOR.write_text('status="PAUSED"\n')
            g.WORKFLOW.write_text('fixture')
            original_runtime = {'build': '/original/build', 'source': '/original/source'}
            original = {'ProgramArguments': [str(cutover.OLD_RELEASE / 'run-local-factory'), str(g.WORKFLOW)],
                        'EnvironmentVariables': {'MIX_BUILD_PATH': original_runtime['build']}}
            saved = root / 'service.original.plist'
            saved.write_bytes(plistlib.dumps(original))
            changed = {'ProgramArguments': ['/broken/replacement/run-local-factory', str(g.WORKFLOW)],
                       'EnvironmentVariables': {'MIX_BUILD_PATH': '/broken/replacement/dev'}}
            g.PLIST.write_bytes(plistlib.dumps(changed))
            audit = {'kind': 'OWNED_REVIEW_REPORT_SERVICE_REPLACEMENT',
                     'issuer': {'pid': int(g.OLD_PID), 'started_at': g.OLD_START},
                     'replacement_launcher': changed['ProgramArguments'][0],
                     'replacement_build': changed['EnvironmentVariables']['MIX_BUILD_PATH']}
            audit_path = root / 'cutover-audit.json'
            audit_path.write_text(json.dumps(audit))
            (root / 'rollout-approved.json').write_text(json.dumps({'evidence': {'cutover-audit.json': cutover.sha(audit_path)}}))
            (root / 'captured.json').write_text(json.dumps({'configuration': g.configuration(), 'plist_sha256': cutover.sha(saved)}))
            database = root / 'fixture.sqlite'
            with sqlite3.connect(database) as db:
                db.execute('CREATE TABLE factory_schema_migrations(version INTEGER)')
                db.execute('INSERT INTO factory_schema_migrations VALUES (54)')
            checked = []
            g.absent = lambda: checked.append('absent')
            g.protected = lambda _audit: checked.append('protected')
            g.quiet = lambda: checked.append('quiet')
            g.original_pins = lambda: original_runtime
            g.native_quiet_for = lambda value: self.assertEqual(value, original_runtime)
            g.readonly = lambda: sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)
            g.candidate = lambda: (_ for _ in ()).throw(AssertionError('replacement is broken'))
            g.restore_check()
            self.assertEqual(checked, ['absent', 'protected', 'quiet'])


if __name__ == '__main__':
    unittest.main()
