"""Local launchd replacement using pinned stop/backup/thaw mechanics; no ledger writes."""

from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tomllib
import time
import urllib.error


TOOLS = Path(__file__).resolve().parent
HISTORICAL = Path('/private/tmp/symphony-push-handoff.cnRVdUfY/review-cutover-r19f2')
GUARD_SHA = '41c26ac2067bdba97ecbf92238e11f813e0e45c8068283b75565677abfe53482'
THAW_SHA = 'cec22fd5003117f496bbe369baaf935f8c9f4797ae519ae0ca90578fb12b4534'
OLD_RELEASE = Path('/Users/cgable/Library/Application Support/ai-factory/releases/symphony-ci-pass-overlay-cnRVdUfY-r20')
OLD_MANIFEST_SHA = 'cb6e49358a07192ed847893990a327f450f4d6c2c6a6955d8f89cbf777810801'
OLD_LAUNCHER_SHA = 'b20a594abb11e07bebb31643506d63e77d942d44b96f818c691add164aba49a0'
OLD_BOOT_SHA = '5a7ac6ec35ba8465e0eedb4122940016dd30fec1306e0bd5d700ade2204f8de6'
RUN = 'ab5ab1fe-32cc-48c1-985e-3c3800adcfa2'
CANDIDATE = '4e5c48fc2150515c4cb5ce0771f4c204b10c532c'
REPORT = 'desktop:b996c85fd59f267cb7ee029cac2f25f2e56e245de90f3945d6e8526a1b6c38bc'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_artifact_evidence(value, validation):
    assert validation['source_tests_passed'] and validation['artifact_tests_passed']
    assert validation['source_commit'] == value['source_commit']
    assert validation['manifest_sha256'] == value['manifest_sha256']
    assert validation['factory_beam_fingerprint'] == value['factory_beam_fingerprint']
    assert validation['artifact_test_failures'] == 0


def bind(evidence_root):
    path = HISTORICAL / 'cutover_guard.py'
    raw = path.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == GUARD_SHA
    spec = importlib.util.spec_from_file_location('retained_review_cutover', path)
    g = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), 'exec', dont_inherit=True), g.__dict__)
    g.ROOT = evidence_root
    g.OLD_PID = '21641'
    g.OLD_START = 'Sun Oct 25 18:57:15 2026'
    g.OLD_FINGERPRINT = '279f7ab2d9ed171d682efb94bd357a18941dd98b784f58ccc3ea62e9d9400d5b'

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
        audit = g.load('cutover-audit.json') if (evidence_root / 'cutover-audit.json').exists() else None
        if audit:
            assert audit['kind'] == 'OWNED_REVIEW_REPORT_SERVICE_REPLACEMENT'
            assert audit['issuer'] == {'pid': int(g.OLD_PID), 'started_at': g.OLD_START}
            assert audit['replacement_manifest'] == str(release / 'evidence/release-manifest.json')
            assert audit['replacement_build'] == value['build']
        return value, manifest, audit

    def native_quiet_for(value):
        script = '''
thread = "01a13272-9eb0-7550-8411-9dbb54b09c57"
{:ok, queue} = SymphonyElixir.Factory.NativeQueueReadback.read("/Users/cgable/.codex/queue_1.sqlite", thread)
{:ok, lock} = SymphonyElixir.Factory.NativeQueueReadback.writer_unlocked("/Users/cgable/.codex", thread)
true = queue["thread_id"] == thread and queue["item_count"] == 0
true = lock["status"] in ["absent", "unlocked"]
IO.puts("NATIVE_SOURCE_QUIET")
'''
        env = {key: value for key, value in os.environ.items() if key not in
               ('ELIXIR_ERL_OPTIONS', 'ERL_AFLAGS', 'ERL_ZFLAGS', 'ERL_LIBS',
                'MIX_BUILD_PATH', 'MIX_ENV', 'MIX_TARGET', 'ERL_FLAGS')}
        env.update(ERL_FLAGS='+S 4:4')
        result = subprocess.run(['/opt/homebrew/bin/mise', 'exec', '--', 'elixir',
                                 '-pa', str(Path(value['build']) / 'lib/*/ebin'), '-e', script],
                                cwd=Path(value['source']) / 'elixir', env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0 and result.stdout.strip() == 'NATIVE_SOURCE_QUIET'

    def native_quiet():
        value, _manifest, _audit = candidate()
        native_quiet_for(value)

    def original_pins():
        path = OLD_RELEASE / 'evidence/overlay-manifest.json'
        assert sha(path) == OLD_MANIFEST_SHA
        assert sha(OLD_RELEASE / 'run-local-factory') == OLD_LAUNCHER_SHA
        assert sha(OLD_RELEASE / 'overlay_boot_guard.exs') == OLD_BOOT_SHA
        old = json.loads(path.read_bytes())
        for name, digest in old['source_hashes'].items():
            assert sha(Path(old['source_root']) / name) == digest, name
        override = old['override']
        assert sha(OLD_RELEASE / 'overrides' / (override['module'] + '.beam')) == override['sha256']
        base = OLD_RELEASE.parent / 'symphony-generation-handoff-cnRVdUfY-r19f'
        base_path = base / 'evidence/release-manifest.json'
        assert sha(base_path) == old['base_manifest_sha256']
        base_manifest = json.loads(base_path.read_bytes())
        for name, entry in base_manifest['artifact'].items():
            assert sha(base / 'dev' / name) == entry['sha256'], name
        return {'build': str(base / 'dev'), 'source': old['source_root']}

    def eligible():
        with g.readonly() as db:
            db.row_factory = sqlite3.Row
            run = dict(db.execute('SELECT * FROM runs WHERE run_id=?', (RUN,)).fetchone())
            assert run['state'] == 'VERIFYING' and run['candidate_sha'] == CANDIDATE
            assert run['verifier_round'] == 5 and run['code_repair_round'] == 12
            assert run['implementation_iteration'] == 26
            assert run['ci_pipeline_id'] == 2987402948
            evidence = dict(db.execute('SELECT * FROM worker_evidence WHERE request_key=?', (REPORT,)).fetchone())
            assert evidence['status'] == 'RESULT_RECORDED' and evidence['owner_stopped_at']
            assert json.loads(evidence['output_json'])['status'] == 'REPAIR'
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
        required = {'candidate.json', 'validation.json', 'review-acceptance.json',
                    'service.original.plist', 'audited-protected.json', 'cutover-audit.json',
                    'cold-boot.json', 'historical-readback-qualification.json'}
        assert required <= approval['evidence'].keys()
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
        assert plist['EnvironmentVariables']['MIX_BUILD_PATH'].endswith('symphony-generation-handoff-cnRVdUfY-r19f/dev')
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
        # No correction is staged until this proof completes, so even pending report rows stay exact.
        g.protected(audit)
        assert eligible() == g.load('captured.json')['ticket']
        g.save_equal('started.json', {'result': 'PASS', 'runtime_identity': runtime,
                                    'manifest_sha256': value['manifest_sha256'],
                                    'guard_ledger_row_writes': 0,
                                    'all_protected_tables_and_event_prefix_preserved': True,
                                    'schema_migration': None})
        print(json.dumps({'result': 'STARTED_HISTORY_PRESERVED', 'runtime': runtime}))

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
        print('ORIGINAL_R20_RESTORE_ALLOWED_AFTER_EXACT_PLIST_RESTORATION')

    g.configuration = configuration
    g.candidate = candidate
    g.native_quiet = native_quiet
    g.qualified = qualified
    g.finish_start = finish_start
    g.original_pins = original_pins
    g.native_quiet_for = native_quiet_for
    g.restore_check = restore_check
    return g, capture


def main():
    assert len(sys.argv) == 3
    operation, evidence = sys.argv[1], Path(sys.argv[2]).resolve()
    assert evidence.is_dir()
    assert operation in ('capture', 'stop', 'finish-stop', 'start', 'finish-start', 'restore-check', 'restore-original')
    g, capture = bind(evidence)
    {'capture': capture, 'stop': g.stop, 'finish-stop': g.finish_stop,
     'start': g.start, 'finish-start': g.finish_start,
     'restore-check': g.restore_check, 'restore-original': g.restore_original}[operation]()


if __name__ == '__main__':
    main()
