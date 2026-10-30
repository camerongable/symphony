"""Local launchd replacement using pinned stop/backup/thaw mechanics; no ledger writes."""

from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tomllib
import time
import urllib.error


TOOLS = Path(__file__).resolve().parent
_compat_spec = importlib.util.spec_from_file_location('review_native_runtime_compatibility', TOOLS / 'native_runtime_compatibility.py')
native_compatibility = importlib.util.module_from_spec(_compat_spec)
_compat_spec.loader.exec_module(native_compatibility)
HISTORICAL = TOOLS
GUARD_SHA = 'dd09fd64cb8e58b621bf424b55c4a827c73bd276f42d84cce31df7bb4c2c80f5'
THAW_SHA = 'cec22fd5003117f496bbe369baaf935f8c9f4797ae519ae0ca90578fb12b4534'
OLD_RELEASE = Path('/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-e47cce2-r2')
OLD_MANIFEST_SHA = 'bef269d33f281ea679b9050f7e0cbe5f54f0ab4b30dc4790ee8709cf1b05cda3'
OLD_LAUNCHER_SHA = '65693470cd838c9dcce60e8e9eb8898ddbc4e4d9118fd6e22433e7b2e50c42c5'
OLD_BOOT_SHA = '418b1a40af2c0ae5059fd841b9191ecacc0b8de6b451a4dd499e97bffcb60fb8'
RUN = 'ab5ab1fe-32cc-48c1-985e-3c3800adcfa2'
CANDIDATE = 'eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834'
REPORT = 'desktop:11b288b43e59ae80afdfc26b01e1bcf2f2d297249cc54e8f0d0af98829629c5a'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_plist(path, expected_sha, raw):
    assert path.is_file() and not path.is_symlink() and sha(path) == expected_sha
    original = path.stat()
    temporary = path.with_name(path.name + '.cutover-' + secrets.token_hex(8))
    with temporary.open('xb') as stream:
        os.fchmod(stream.fileno(), original.st_mode & 0o777)
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    assert sha(path) == expected_sha
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    assert path.read_bytes() == raw


def validate_artifact_evidence(value, validation):
    assert validation['source_tests_passed'] and validation['artifact_tests_passed']
    assert validation['source_commit'] == value['source_commit']
    assert validation['manifest_sha256'] == value['manifest_sha256']
    assert validation['factory_beam_fingerprint'] == value['factory_beam_fingerprint']
    assert validation['artifact_test_failures'] == 0
    assert validation['source_composed_recovery_publication_passed'] is True
    assert type(validation['source_composed_tests']) is int and validation['source_composed_tests'] == 1
    assert type(validation['source_composed_failures']) is int and validation['source_composed_failures'] == 0
    assert validation['test_commit_production_config_and_priv_diff_empty'] is True


def validate_current_publication_evidence(value, manifest, chain, rejection):
    for result in (chain, rejection):
        assert result['result'] == 'PASS'
        assert result['manifest_sha256'] == value['manifest_sha256']
        assert result['current_candidate_sha'] == CANDIDATE
        for field in ('live_ledger_writes', 'pushes', 'native_chats', 'native_model_turns'):
            assert type(result[field]) is int and result[field] == 0
    for field in ('current_repair_preparation_retirement_import_worker_and_generation_valid',
                  'exact_parent_committed_paths_and_generated_blob_hashes_valid',
                  'genuine_owned_stdin_open', 'current_raw_run_unchanged'):
        assert chain[field] is True
    assert type(chain['read_only_sqlite_reopens']) is int and chain['read_only_sqlite_reopens'] == 2
    assert chain['history_sha256'] == manifest['artifact'][
        'lib/symphony_elixir/priv/ticket_push_history_validator_v25.py']['sha256']
    assert rejection['source_commit'] == value['source_commit']
    assert rejection['original_envelope_sha256'] == '5935494d2f4b8b2ec0c3e5778a2e297d64f138c73469140db4c20ae3f549c209'
    assert rejection['rejection_sha256'] == '44477a82a476e1f83f47b5af4a3182ee4b9962be537e5c542989aa20dea6c40b'
    assert rejection['audit_sha256'] == 'dfc045f0753fa7d7ddaa3ddd28bbfe0c00031391bef216903a75c0c48314101f'
    assert rejection['audit_sha256'] == manifest['artifact'][
        'lib/symphony_elixir/priv/ticket_push_ordinary_rejection_v4.json']['sha256']
    assert rejection['child_pid'] is None and rejection['rejection_bytes'] == 365726
    assert rejection['exact_audited_closed_authority'] is True
    assert rejection['original_run_and_three_prior_retirements_unchanged'] is True


def validate_approval_evidence_files(approval):
    required = {'candidate.json', 'validation.json', 'review-acceptance.json',
                'service.original.plist', 'audited-protected.json', 'cutover-audit.json',
                'cold-boot.json', 'historical-readback-qualification.json',
                'current-publication-chain.json', 'current-rejection-qualification.json'}
    assert required <= approval['evidence'].keys()


def bind(evidence_root):
    path = HISTORICAL / 'cutover_guard.py'
    raw = path.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == GUARD_SHA
    spec = importlib.util.spec_from_file_location('retained_review_cutover', path)
    g = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), 'exec', dont_inherit=True), g.__dict__)
    g.ROOT = evidence_root
    g.OLD_PID = '3930'
    g.OLD_START = 'Mon Oct 26 20:47:21 2026'
    g.OLD_FINGERPRINT = 'ac0413df7d55651da903b14b0cbc6ffe589ce454669c31f07dfac9a5ce859051'

    def configuration():
        broker = tomllib.loads(g.BROKER.read_text())
        monitor = tomllib.loads(g.MONITOR.read_text())
        assert broker['status'] == 'PAUSED'
        assert broker['rrule'] == 'FREQ=MINUTELY;INTERVAL=1'
        assert monitor['status'] == 'PAUSED'
        return {str(item): sha(item) for item in (g.BROKER, g.MONITOR, g.WORKFLOW)}

    def candidate():
        value = g.load('candidate.json')
        release = Path(value['release'])
        assert release.parent == OLD_RELEASE.parent
        assert release.name.startswith('symphony-review-report-')
        assert sha(release / 'evidence/release-manifest.json') == value['manifest_sha256']
        assert sha(release / 'release_boot_guard.exs') == value['guard_sha256']
        assert sha(release / 'run-local-factory') == value['launcher_sha256']
        manifest = json.loads((release / 'evidence/release-manifest.json').read_bytes())
        assert manifest['kind'] == 'FACTORY_REVIEW_REPORT_RELEASE_V1'
        assert manifest['schema_version'] == value['schema_version'] == 54
        assert manifest['source_commit'] == value['source_commit']
        assert manifest['factory_beam_fingerprint'] == value['factory_beam_fingerprint']
        assert len(manifest['factory_modules']) == value['factory_module_count']
        assert manifest['previous_manifest_sha256'] == OLD_MANIFEST_SHA
        for name, entry in manifest['artifact'].items():
            assert sha(Path(manifest['build']) / name) == entry['sha256'], name
        for name, digest in manifest['source_hashes'].items():
            assert sha(Path(manifest['source_root']) / name) == digest, name
        native_compatibility.validate_manifest(manifest)
        audit = g.load('cutover-audit.json') if (evidence_root / 'cutover-audit.json').exists() else None
        if audit:
            assert audit['kind'] == 'OWNED_REVIEW_REPORT_SERVICE_REPLACEMENT'
            assert audit['issuer'] == {'pid': int(g.OLD_PID), 'started_at': g.OLD_START}
            assert audit['replacement_manifest'] == str(release / 'evidence/release-manifest.json')
            assert audit['replacement_build'] == value['build']
        return value, manifest, audit

    def native_quiet_for(value):
        manifest = {'native_runtime_formats': value['native_runtime_formats']}
        native_compatibility.check_database(g.DB, manifest)
        with g.readonly() as db:
            workers = db.execute('SELECT DISTINCT thread_id,binding_json,binding_sha256 FROM worker_evidence WHERE run_id=? AND thread_id IS NOT NULL', (RUN,)).fetchall()
        payload, pairs = native_compatibility.quietness_payload(workers, g.WORKFLOW, manifest)
        assert 1 <= pairs <= 100
        env = {key: value for key, value in os.environ.items() if key not in
               ('ELIXIR_ERL_OPTIONS', 'ERL_AFLAGS', 'ERL_ZFLAGS', 'ERL_LIBS',
                'MIX_BUILD_PATH', 'MIX_ENV', 'MIX_TARGET', 'ERL_FLAGS')}
        env.update(ERL_FLAGS='+S 4:4')
        result = subprocess.run(['/opt/homebrew/bin/mise', 'exec', '--', 'elixir',
                                 '-pa', str(Path(value['build']) / 'lib/*/ebin'), '-e', native_compatibility.NATIVE_QUIET_SCRIPT, '--', payload],
                                cwd=Path(value['source']) / 'elixir', env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0 and result.stdout.strip() == 'NATIVE_SOURCE_QUIET'
        native_compatibility.check_database(g.DB, manifest)

    def native_quiet():
        value, manifest, _audit = candidate()
        native_quiet_for({**value, 'native_runtime_formats': native_compatibility.validate_manifest(manifest)})
        g.native_runtime_admit('stop')

    def original_pins():
        path = OLD_RELEASE / 'evidence/release-manifest.json'
        assert sha(path) == OLD_MANIFEST_SHA
        assert sha(OLD_RELEASE / 'run-local-factory') == OLD_LAUNCHER_SHA
        assert sha(OLD_RELEASE / 'release_boot_guard.exs') == OLD_BOOT_SHA
        old = json.loads(path.read_bytes())
        for name, digest in old['source_hashes'].items():
            assert sha(Path(old['source_root']) / name) == digest, name
        for name, entry in old['artifact'].items():
            assert sha(Path(old['build']) / name) == entry['sha256'], name
        native_compatibility.validate_manifest(old)
        return {'build': old['build'], 'source': old['source_root'], 'native_runtime_formats': native_compatibility.validate_manifest(old)}

    def eligible():
        with g.readonly() as db:
            db.row_factory = sqlite3.Row
            run = dict(db.execute('SELECT * FROM runs WHERE run_id=?', (RUN,)).fetchone())
            assert run['state'] == 'CI_PUSHING' and run['candidate_sha'] == CANDIDATE
            assert run['verifier_round'] == 5 and run['code_repair_round'] == 13
            assert run['implementation_iteration'] == 27
            assert run['ci_pipeline_id'] == 2987402948
            assert hashlib.sha256(run['candidate_handoff'].encode()).hexdigest() == '5935494d2f4b8b2ec0c3e5778a2e297d64f138c73469140db4c20ae3f549c209'
            intent = json.loads(run['candidate_handoff'])
            assert intent['kind'] == 'TICKET_PUSH' and intent['phase'] == 'PUSH_UNCERTAIN' and intent['helper_pid'] == 5776
            assert intent['binding_sha256'] == 'c74d7c25ae5f9d452aee999176cd6bc51ef8e8d0d20c30c157f45a0474d922da'
            assert all(intent[name] is None for name in ('receipt_json', 'receipt_sha256', 'remote_sha'))
            evidence = dict(db.execute('SELECT * FROM worker_evidence WHERE request_key=?', (REPORT,)).fetchone())
            assert evidence['status'] == 'CONSUMED' and evidence['owner_stopped_at'] and evidence['consumed_at']
            assert json.loads(evidence['output_json'])['status'] == 'COMPLETE'
            assert db.execute('SELECT MAX(version) FROM factory_schema_migrations').fetchone()[0] == 54
            return {'run': {key: run[key] for key in ('state', 'candidate_sha', 'verifier_round', 'code_repair_round', 'implementation_iteration')},
                    'report': {key: evidence[key] for key in ('request_key', 'binding_sha256', 'output_sha256', 'owner_stopped_at')}}

    def qualified():
        value, manifest, audit = candidate()
        assert audit is not None
        approval = g.load('rollout-approved.json')
        assert approval['result'] == 'ACCEPT_FOR_CUTOVER_ONLY'
        assert approval['manifest_sha256'] == value['manifest_sha256']
        assert approval['cutover_guard_sha256'] == sha(Path(__file__))
        assert approval['guardian_sha256'] == THAW_SHA == sha(evidence_root / 'thaw_guardian.py')
        validate_approval_evidence_files(approval)
        for name, expected in approval['evidence'].items():
            assert sha(evidence_root / name) == expected, name
        validation = g.load('validation.json')
        validate_artifact_evidence(value, validation)
        review = g.load('review-acceptance.json')
        assert review['result'] == 'ACCEPT' and review['source_commit'] == value['source_commit']
        cold = g.load('cold-boot.json')
        assert cold['result'] == 'PASS' and cold['manifest_sha256'] == value['manifest_sha256']
        readback = g.load('historical-readback-qualification.json')
        assert readback['result'] == 'PASS' and readback['manifest_sha256'] == value['manifest_sha256']
        assert readback['live_ledger_writes'] == readback['pushes'] == readback['native_chats'] == 0
        validate_current_publication_evidence(value, manifest,
            g.load('current-publication-chain.json'), g.load('current-rejection-qualification.json'))
        assert eligible() == g.load('captured.json')['ticket']
        return value, manifest, audit

    def capture():
        value, _manifest, prior = candidate()
        assert prior is None
        g.old_binding(True)
        g.quiet()
        native_quiet()
        ticket = eligible()
        pins = configuration()
        with g.readonly() as db:
            event_limit = db.execute('SELECT MAX(id) FROM events').fetchone()[0]
            digest_rows = lambda rows: hashlib.sha256(json.dumps(rows, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
            schema = [list(row) for row in db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')]
            protected = {'event_limit': event_limit, 'schema_sha256': digest_rows(schema), 'tables': {}}
            for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
                if table in ('control', 'intake_snapshots', 'sqlite_sequence', 'tick_health'):
                    continue
                quoted = '"' + table.replace('"', '""') + '"'
                suffix = ' WHERE id <= ' + str(event_limit) if table == 'events' else ''
                cursor = db.execute('SELECT rowid,* FROM ' + quoted + suffix + ' ORDER BY rowid')
                rows = [list(row) for row in cursor]
                protected['tables'][table] = {'columns': [item[0] for item in cursor.description],
                                              'count': len(rows), 'sha256': digest_rows(rows)}
        g.save('audited-protected.json', protected)
        original = g.PLIST.read_bytes()
        plist = plistlib.loads(original)
        assert plist['ProgramArguments'] == [str(OLD_RELEASE / 'run-local-factory'), str(g.WORKFLOW)]
        assert plist['EnvironmentVariables']['MIX_BUILD_PATH'] == g.original_pins()['build']
        with (evidence_root / 'service.original.plist').open('xb') as stream:
            stream.write(original)
        assert sha(HISTORICAL / 'thaw_guardian.py') == THAW_SHA
        shutil.copy2(HISTORICAL / 'thaw_guardian.py', evidence_root / 'thaw_guardian.py')
        stat = g.DB.stat()
        audit = {'kind': 'OWNED_REVIEW_REPORT_SERVICE_REPLACEMENT',
                 'issuer': {'pid': int(g.OLD_PID), 'started_at': g.OLD_START},
                 'database_identity': {'path': str(g.DB), 'device': stat.st_dev, 'inode': stat.st_ino, 'uid': stat.st_uid},
                 'operation': {'run_id': RUN},
                 'protected_snapshot': {'path': str(evidence_root / 'audited-protected.json'),
                                        'sha256': sha(evidence_root / 'audited-protected.json')},
                 'replacement_build': value['build'], 'replacement_launcher': str(Path(value['release']) / 'run-local-factory'),
                 'replacement_manifest': str(Path(value['release']) / 'evidence/release-manifest.json')}
        g.save('cutover-audit.json', audit)
        g.save('captured.json', {'old_pid': g.OLD_PID, 'old_start': g.OLD_START,
                                 'plist_sha256': sha(g.PLIST), 'configuration': pins,
                                 'manifest_sha256': value['manifest_sha256'], 'ticket': ticket,
                                 'guard_ledger_row_writes': 0})
        print('READ_ONLY_REVIEW_CUTOVER_CAPTURE_PASS')

    def finish_start():
        value, _manifest, audit = candidate()
        intent = g.load('start-intent.json')
        assert intent['manifest_sha256'] == value['manifest_sha256']
        assert intent['plist_sha256'] == sha(g.PLIST)
        deadline = time.monotonic() + 45
        while True:
            try:
                result = g.api()
                break
            except urllib.error.URLError:
                assert time.monotonic() < deadline
                time.sleep(0.25)
        runtime = result['factory']['control']['runtime_identity']
        assert runtime['os_pid'] != g.OLD_PID
        assert runtime['factory_beam_fingerprint'] == value['factory_beam_fingerprint']
        assert runtime['factory_beam_module_count'] == value['factory_module_count']
        launchd = g.command(['/bin/launchctl', 'print', g.SERVICE])
        assert re.search(r'^\s*pid = ' + runtime['os_pid'] + r'$', launchd, re.M)
        assert re.search(r'^\s*program = ' + re.escape(audit['replacement_launcher']) + r'$', launchd, re.M)
        # Full-row preservation is proven before bootstrap; ordinary ticks may now consume the result.
        before = g.load('prebootstrap-preservation.json')
        assert before['manifest_sha256'] == value['manifest_sha256']
        assert before['protected_sha256'] == audit['protected_snapshot']['sha256']
        historical_after_start()
        g.save_equal('started.json', {'result': 'PASS', 'runtime_identity': runtime,
                                    'manifest_sha256': value['manifest_sha256'],
                                    'guard_ledger_row_writes': 0,
                                    'all_protected_tables_preserved_before_bootstrap': True,
                                    'historical_evidence_and_event_prefix_preserved_after_start': True,
                                    'schema_migration': None})
        print(json.dumps({'result': 'STARTED_HISTORY_PRESERVED', 'runtime': runtime}))

    def historical_after_start():
        protected = g.load('audited-protected.json')
        backup = evidence_root / 'before-cutover.sqlite'
        with sqlite3.connect(backup.as_uri() + '?mode=ro&immutable=1', uri=True) as prior, g.readonly() as current:
            assert current.execute('SELECT MAX(version) FROM factory_schema_migrations').fetchone()[0] == 54
            schema = [list(row) for row in current.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')]
            assert hashlib.sha256(json.dumps(schema, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest() == protected['schema_sha256']
            for table in ('events', 'worker_instruction_snapshots', 'worker_instruction_task_bindings', 'worker_file_operations', 'ticket_mr_claims', 'ticket_mr_actor_bindings', 'ticket_push_rejection_retirements', 'ticket_ordinary_generation_intents', 'ticket_ordinary_generation_events'):
                quoted = '"' + table + '"'
                limit = ' WHERE id <= ' + str(protected['event_limit']) if table == 'events' else ''
                for row in prior.execute('SELECT rowid,* FROM ' + quoted + limit + ' ORDER BY rowid'):
                    assert current.execute('SELECT rowid,* FROM ' + quoted + ' WHERE rowid=?', (row[0],)).fetchone() == row, table
            for table, key in (('worker_evidence', 'request_key'), ('factory_tasks', 'task_key')):
                columns = [row[1] for row in prior.execute('PRAGMA table_info(' + table + ')')]
                for row in prior.execute('SELECT * FROM ' + table):
                    original = dict(zip(columns, row))
                    updated_row = current.execute('SELECT * FROM ' + table + ' WHERE ' + key + '=?', (original[key],)).fetchone()
                    assert updated_row is not None
                    updated = dict(zip(columns, updated_row))
                    mutable = set()
                    if table == 'worker_evidence' and original[key] == REPORT and original['status'] == 'RESULT_RECORDED':
                        assert original['status'] == 'RESULT_RECORDED' and updated['status'] in ('RESULT_RECORDED', 'CONSUMED')
                        mutable = {'status', 'consumed_at'}
                    if table == 'factory_tasks' and original[key] == RUN + ':feature-writer' and original['status'] == 'COMPLETE':
                        assert original['status'] == 'COMPLETE' and updated['status'] in ('COMPLETE', 'CONSUMED')
                        mutable = {'status', 'updated_at'}
                    assert {name: original[name] for name in columns if name not in mutable} == {name: updated[name] for name in columns if name not in mutable}
            for (table,) in prior.execute("SELECT name FROM sqlite_master WHERE type='table'"):
                quoted = '"' + table.replace('"', '""') + '"'
                columns = [row[1] for row in prior.execute('PRAGMA table_info(' + quoted + ')')]
                predicates = []
                for name in ('status', 'phase'):
                    if name in columns:
                        value = 'upper(COALESCE("' + name + '",\'\'))'
                        predicates += ["instr(" + value + ",'UNCERTAIN')>0", "instr(" + value + ",'UNKNOWN')>0", value + "='RECONCILE_REQUIRED'"]
                if table == 'desktop_requests':
                    predicates += ["request_key='desktop:c634fd01f6bdbc7dab875cddda848ad5fe1ca65086e1684dafc7957b7a351962'"]
                if predicates:
                    for row in prior.execute('SELECT rowid,* FROM ' + quoted + ' WHERE ' + ' OR '.join(predicates)):
                        assert current.execute('SELECT rowid,* FROM ' + quoted + ' WHERE rowid=?', (row[0],)).fetchone() == row, table

    def start():
        value, _manifest, audit = g.qualified()
        assert g.load('stopped.json')['result'] == 'EXACT_ISSUER_STOPPED'
        g.absent()
        assert g.configuration() == g.load('captured.json')['configuration']
        g.quiet()
        g.native_quiet()
        g.protected(audit)
        saved = evidence_root / 'service.original.plist'
        assert sha(saved) == g.load('captured.json')['plist_sha256'] == sha(g.PLIST)
        expected = plistlib.loads(saved.read_bytes())
        expected['ProgramArguments'][0] = audit['replacement_launcher']
        expected['EnvironmentVariables']['MIX_BUILD_PATH'] = audit['replacement_build']
        g.native_runtime_admit('start')
        replace_plist(g.PLIST, sha(saved), plistlib.dumps(expected))
        g.protected(audit)
        g.save('prebootstrap-preservation.json', {'manifest_sha256': value['manifest_sha256'],
               'protected_sha256': audit['protected_snapshot']['sha256'], 'guard_ledger_row_writes': 0})
        g.save('start-intent.json', {'manifest_sha256': value['manifest_sha256'], 'plist_sha256': sha(g.PLIST), 'attempts': 1})
        g.native_runtime_admit('start')
        g.command(['/bin/launchctl', 'bootstrap', 'gui/505', str(g.PLIST)], timeout=15)
        g.finish_start()

    def restore_check():
        # A broken replacement must not prevent recovery to the separately pinned original.
        g.absent()
        audit = g.load('cutover-audit.json')
        captured = g.load('captured.json')
        approval = g.load('rollout-approved.json')
        assert sha(evidence_root / 'cutover-audit.json') == approval['evidence']['cutover-audit.json']
        assert audit['kind'] == 'OWNED_REVIEW_REPORT_SERVICE_REPLACEMENT'
        assert audit['issuer'] == {'pid': int(g.OLD_PID), 'started_at': g.OLD_START}
        g.protected(audit)
        with g.readonly() as db:
            assert db.execute('SELECT MAX(version) FROM factory_schema_migrations').fetchone()[0] == 54
        assert configuration() == captured['configuration']
        saved = evidence_root / 'service.original.plist'
        assert sha(saved) == captured['plist_sha256']
        original = plistlib.loads(saved.read_bytes())
        assert original['ProgramArguments'] == [str(OLD_RELEASE / 'run-local-factory'), str(g.WORKFLOW)]
        original_runtime = g.original_pins()
        assert original['EnvironmentVariables']['MIX_BUILD_PATH'] == original_runtime['build']
        current = plistlib.loads(g.PLIST.read_bytes())
        replacement = plistlib.loads(saved.read_bytes())
        replacement['ProgramArguments'][0] = audit['replacement_launcher']
        replacement['EnvironmentVariables']['MIX_BUILD_PATH'] = audit['replacement_build']
        assert current == original or current == replacement
        g.quiet()
        g.native_quiet_for(original_runtime)
        g.native_runtime_admit('restore-check')
        print('ORIGINAL_C66_RESTORE_ALLOWED_AFTER_EXACT_PLIST_RESTORATION')

    def restore_original():
        g.restore_check()
        g.native_runtime_admit('restore-original')
        saved = evidence_root / 'service.original.plist'
        if g.PLIST.read_bytes() != saved.read_bytes():
            replace_plist(g.PLIST, sha(g.PLIST), saved.read_bytes())
        original_restore()

    g.configuration = configuration
    g.candidate = candidate
    g.native_quiet = native_quiet
    g.qualified = qualified
    g.finish_start = finish_start
    g.historical_after_start = historical_after_start
    g.start = start
    g.original_pins = original_pins
    g.native_quiet_for = native_quiet_for
    g.restore_check = restore_check
    original_restore = g.restore_original
    g.restore_original = restore_original

    def native_runtime_admit(operation):
        if operation.startswith('restore-'):
            original = g.original_pins()
            native_compatibility.check_database(g.DB, {'native_runtime_formats': original['native_runtime_formats']})
        else:
            _value, manifest, _audit = g.candidate()
            native_compatibility.check_database(g.DB, manifest)

    def guarded(operation, action):
        def checked():
            native_runtime_admit(operation)
            return action()
        return checked

    g.native_runtime_admit = native_runtime_admit
    for name in ('stop', 'finish_stop', 'start', 'finish_start', 'restore_check', 'restore_original'):
        setattr(g, name, guarded(name.replace('_', '-'), getattr(g, name)))
    return g, guarded('capture', capture)


def main():
    assert len(sys.argv) == 3
    operation, evidence = sys.argv[1], Path(sys.argv[2]).resolve()
    assert evidence.is_dir()
    assert operation in ('capture', 'stop', 'finish-stop', 'start', 'finish-start', 'restore-check', 'restore-original')
    g, capture = bind(evidence)
    g.native_runtime_admit(operation)
    {'capture': capture, 'stop': g.stop, 'finish-stop': g.finish_stop,
     'start': g.start, 'finish-start': g.finish_start,
     'restore-check': g.restore_check, 'restore-original': g.restore_original}[operation]()


if __name__ == '__main__':
    main()
