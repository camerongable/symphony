"""Exact READY-only local replacement. No ticket mutation or ledger write operation."""

from contextlib import contextmanager
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
import stat
import subprocess
import sys
import time
import tomllib
import urllib.error


TOOLS = Path(__file__).resolve().parent
HISTORICAL = Path('/private/tmp/symphony-push-handoff.cnRVdUfY/review-cutover-r19f2')
GUARD_SHA = '41c26ac2067bdba97ecbf92238e11f813e0e45c8068283b75565677abfe53482'
THAW_SHA = 'cec22fd5003117f496bbe369baaf935f8c9f4797ae519ae0ca90578fb12b4534'
OLD_RELEASE = Path('/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-216eadb')
OLD_SOURCE = '216eadbd5877a2c11760fa67c98bfe3a3bd7d779'
OLD_MANIFEST = '8119af4273e08dd17442790236bbcacecb884e3e8997dc99ba36a2159093af65'
OLD_LAUNCHER = 'cae5ab57c203cdaac623da550eb2500876ca0b874450d0bcadbf482a83610c66'
OLD_BOOT = '418b1a40af2c0ae5059fd841b9191ecacc0b8de6b451a4dd499e97bffcb60fb8'
OLD_PLIST = '69c5f18ef0933bc16f2abcb0d300e5d404b37f79a78cd9f227dea7e150717273'
OLD_PID = '94962'
OLD_START = 'Mon Oct 26 21:53:33 2026'
OLD_FINGERPRINT = 'cf4097a8ff4eaeb315034c991e4bf71e75ef2242b5fa7b5d0e452e571115497f'
RUN = 'ab5ab1fe-32cc-48c1-985e-3c3800adcfa2'
CANDIDATE = 'eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834'
DB = Path('/Users/cgable/Documents/Codex/factory-state/factory.sqlite')
TICKET = {
    'run_sha256': '03c804c87ea4e70b88357116fd4c539f93fd41f894d109b0532736e85c33fd01',
    'envelope_sha256': '574407d0b061ec4f13f4c870fde1d063c15c7329c8a8e979a41f612fbbb9e1ba',
    'receipt_sha256': 'f336451637ec70bc42481a15beed3f31f9aab31b6e483d85ccaa0a7806c2e12d',
    'receipt_bytes': 387927,
    'reservation_key': 'ticket-push:a9852b24ed6f4848230652c62bae09762c47572d8929874eff1b97f78a96d926',
}
EXCLUDED = {'control', 'tick_health', 'intake_snapshots', 'sqlite_sequence'}
TEST_CATEGORIES = {'completed-recovery', 'refusal', 'readback', 'broker', 'appserver', 'owner', 'composed'}
MAILBOX = Path('/Users/cgable/Documents/Codex/factory-state/broker-runtime')
REQUIRED_EVIDENCE = {'candidate.json', 'validation.json', 'source-approved.json', 'review-acceptance.json',
                     'cold-boot.json', 'runtime-preflight.json', 'public-completed-qualification.json',
                     'historical-completed-qualification.json', 'service.original.plist',
                     'cutover-audit.json', 'audited-protected.json'}


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def sha(path):
    return digest(path.read_bytes())


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def hex_value(value, length=64):
    assert type(value) is str and re.fullmatch('[0-9a-f]{'+str(length)+'}', value)
    return value


@contextmanager
def read_only(path):
    db = sqlite3.connect(path.resolve().as_uri()+'?mode=ro', uri=True, timeout=5)
    try:
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        yield db
        assert db.total_changes == 0
    finally:
        db.close()


def validate_ticket(db, expected=TICKET):
    """The optional expected value is an offline fixture seam, never a CLI input."""
    db.row_factory = sqlite3.Row
    found = db.execute('SELECT * FROM runs WHERE run_id=?', (RUN,)).fetchall()
    assert len(found) == 1
    run = dict(found[0])
    assert digest(encode(run)) == expected['run_sha256']
    required = {'state': 'READY_FOR_REVIEW', 'candidate_sha': CANDIDATE,
                'ci_pipeline_id': 2992785001, 'verifier_round': 6,
                'code_repair_round': 13, 'implementation_iteration': 27,
                'mr_iid': 47818, 'last_error': None}
    assert all(type(run[key]) is type(value) and run[key] == value for key, value in required.items())
    raw = run['candidate_handoff']
    assert digest(raw.encode()) == expected['envelope_sha256']
    intent = json.loads(raw)
    assert intent['kind'] == 'TICKET_PUSH' and intent['phase'] == 'COMPLETED'
    receipt = intent['receipt_json'].encode()
    assert len(receipt) == expected['receipt_bytes']
    assert digest(receipt) == intent['receipt_sha256'] == expected['receipt_sha256']
    assert intent['reservation_key'] == expected['reservation_key']
    assert type(intent['reservation_generation']) is int and intent['reservation_generation'] == 67
    access = db.execute('SELECT * FROM workspace_access WHERE reservation_key=?', (intent['reservation_key'],)).fetchall()
    assert len(access) == 1
    access = dict(access[0])
    assert type(access['generation']) is int and access['generation'] == 67
    assert access['released_at'] and access['release_receipt_json'] == raw
    assert db.execute('SELECT MAX(version) FROM factory_schema_migrations').fetchone()[0] == 54
    return {'run_sha256': digest(encode(run)), 'envelope_sha256': digest(raw.encode()),
            'receipt_sha256': digest(receipt), 'receipt_bytes': len(receipt),
            'released_access_sha256': digest(encode(access))}


def quoted(name):
    return '"'+name.replace('"', '""')+'"'


def row_digest(rows):
    return digest(json.dumps(rows, separators=(',', ':'), ensure_ascii=False).encode())


def snapshot(db):
    schema = [list(row) for row in db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')]
    result = {'schema_sha256': row_digest(schema), 'tables': {}}
    for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
        if table in EXCLUDED:
            continue
        cursor = db.execute('SELECT rowid,* FROM '+quoted(table)+' ORDER BY rowid')
        rows = [list(row) for row in cursor]
        result['tables'][table] = {'columns': [column[0] for column in cursor.description],
                                   'max_rowid': max((row[0] for row in rows), default=0),
                                   'count': len(rows), 'sha256': row_digest(rows)}
    result['event_limit'] = db.execute('SELECT COALESCE(MAX(id),0) FROM events').fetchone()[0]
    return result


def preserve(db, expected):
    schema = [list(row) for row in db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')]
    assert row_digest(schema) == expected['schema_sha256']
    for table, saved in expected['tables'].items():
        cursor = db.execute('SELECT rowid,* FROM '+quoted(table)+' WHERE rowid<=? ORDER BY rowid', (saved['max_rowid'],))
        rows = [list(row) for row in cursor]
        assert [column[0] for column in cursor.description] == saved['columns'], table
        assert len(rows) == saved['count'] and row_digest(rows) == saved['sha256'], table
        # No implicit allowance for new publication/consumption rows. New normal-tick
        # rows also require a separately reviewed attribution before this can pass.
        assert db.execute('SELECT COUNT(*) FROM '+quoted(table)+' WHERE rowid>?', (saved['max_rowid'],)).fetchone()[0] == 0, table


def inventory(root, source=False):
    excluded = {'.git', '_build', 'deps', 'bin', 'log', 'logs', 'cover', '__pycache__'}
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if source and set(relative.parts) & excluded:
            continue
        assert not path.is_symlink(), str(path)
        if path.is_file():
            if relative.as_posix() == 'lib/symphony_elixir/.mix/.mix_test_failures':
                assert path.stat().st_size <= 1048576
                continue
            result[relative.as_posix()] = {'sha256': sha(path)}
    return result


def validate_candidate(value, release_parent=OLD_RELEASE.parent):
    assert value['result'] == 'BUILT_NOT_ACTIVATED'
    hex_value(value['source_commit'], 40)
    for field in ('manifest_sha256', 'guard_sha256', 'launcher_sha256', 'factory_beam_fingerprint'):
        hex_value(value[field])
    assert type(value['schema_version']) is int and value['schema_version'] == 54
    assert type(value['factory_module_count']) is int and value['factory_module_count'] > 0
    release = Path(value['release'])
    assert release.is_absolute() and release.resolve() == release and release.parent == release_parent
    assert release.name.startswith('symphony-review-report-') and release != OLD_RELEASE
    assert value['build'] == str(release / 'dev')
    for relative, field in (('evidence/release-manifest.json', 'manifest_sha256'),
                            ('release_boot_guard.exs', 'guard_sha256'), ('run-local-factory', 'launcher_sha256')):
        assert sha(release / relative) == value[field]
    manifest = json.loads((release / 'evidence/release-manifest.json').read_bytes())
    assert manifest['kind'] == 'FACTORY_REVIEW_REPORT_RELEASE_V1' and manifest['activation'] is False
    for field in ('schema_version', 'source_commit', 'factory_beam_fingerprint', 'build', 'release'):
        assert manifest[field] == value[field]
    assert manifest['source_root'] == value['source']
    assert manifest['deployed_baseline_commit'] == OLD_SOURCE
    assert manifest['previous_manifest_sha256'] == manifest['base_artifact_manifest_sha256'] == OLD_MANIFEST
    assert len(manifest['factory_modules']) == value['factory_module_count']
    assert inventory(Path(value['build'])) == manifest['artifact']
    source = inventory(Path(value['source']), True)
    assert source == manifest['source']
    assert {name: entry['sha256'] for name, entry in source.items()} == manifest['source_hashes']
    return manifest


def validate_validation(value, validation, root):
    assert validation['result'] == 'PASS'
    for field in ('source_commit', 'manifest_sha256', 'factory_beam_fingerprint'):
        assert validation[field] == value[field]
    tests = validation['tests']
    assert type(tests) is list
    seen = set()
    for test in tests:
        assert test['environment'] in ('source', 'artifact') and test['category'] in TEST_CATEGORIES
        assert type(test['count']) is int and test['count'] > 0
        assert type(test['failures']) is int and test['failures'] == 0
        assert type(test['exit_code']) is int and test['exit_code'] == 0
        assert type(test['command']) is str and test['command']
        name = test['log']
        assert Path(name).name == name and sha(root / name) == hex_value(test['log_sha256'])
        seen.add((test['environment'], test['category']))
    assert seen == {(environment, category) for environment in ('source', 'artifact') for category in TEST_CATEGORIES}
    assert validation['all_143_retained_and_five_022_private_resources_unchanged'] is True
    limits = validation['quality_limits']
    assert type(limits['credo_baseline']) is int and limits['credo_baseline'] == 653
    assert type(limits['credo_added']) is int and limits['credo_added'] == 0
    assert limits['coverage'] == limits['dialyzer'] == 'NOT_REACHED'


def validate_publication(value, manifest, public, history):
    for proof, kind in ((public, 'READY_COMPLETED_PUBLIC_PROOF_V1'), (history, 'READY_COMPLETED_HISTORY_PROOF_V1')):
        assert proof['result'] == 'PASS' and proof['kind'] == kind
        assert proof['manifest_sha256'] == value['manifest_sha256'] and proof['source_commit'] == value['source_commit']
        assert proof['run_id'] == RUN and proof['current_candidate_sha'] == CANDIDATE
        assert proof['envelope_sha256'] == TICKET['envelope_sha256']
        assert proof['receipt_sha256'] == TICKET['receipt_sha256']
        assert type(proof['receipt_bytes']) is int and proof['receipt_bytes'] == TICKET['receipt_bytes']
        assert type(proof['read_only_sqlite_reopens']) is int and proof['read_only_sqlite_reopens'] == 2
        for field in ('live_ledger_writes', 'pushes', 'native_chats', 'native_model_turns'):
            assert type(proof[field]) is int and proof[field] == 0
        assert proof['entire_run_access_and_history_unchanged'] is True and proof['human_head_unchanged'] is True
    for field in ('public_readback', 'receipt_valid', 'completed_proof', 'validate_completed_proof'):
        assert public[field] is True
    for field in ('full_physical_predecessor', 'retained_generation_authority',
                  'recorded_git_diff_paths_and_generated_blobs', 'historical_rollover_verifier_and_ci'):
        assert history[field] is True
    assert history['issuance_freshness'] == 'NOT_RERUN_HISTORICAL_READ_ONLY'
    assert history['history_sha256'] == manifest['artifact']['lib/symphony_elixir/priv/ticket_push_history_validator_v26.py']['sha256']


def replace_plist(path, expected_sha, raw):
    assert path.is_file() and not path.is_symlink() and sha(path) == expected_sha
    metadata = path.stat()
    temporary = path.with_name(path.name+'.cutover-'+secrets.token_hex(8))
    with temporary.open('xb') as stream:
        os.fchmod(stream.fileno(), metadata.st_mode & 0o777)
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


def replacement_plist(original, launcher, build):
    value = plistlib.loads(original)
    value['ProgramArguments'][0] = launcher
    value['EnvironmentVariables']['MIX_BUILD_PATH'] = build
    return plistlib.dumps(value)


def validate_restore_plist(original, current, audit, workflow, build):
    before = plistlib.loads(original)
    assert before['ProgramArguments'] == [str(OLD_RELEASE / 'run-local-factory'), workflow]
    assert before['EnvironmentVariables']['MIX_BUILD_PATH'] == build
    expected = replacement_plist(original, audit['replacement_launcher'], audit['replacement_build'])
    assert plistlib.loads(current) in (before, plistlib.loads(expected))


def validate_old_binding(control, started_at, launchd, idle):
    runtime = control['runtime_identity']
    assert runtime['os_pid'] == OLD_PID and runtime['factory_beam_fingerprint'] == OLD_FINGERPRINT
    assert started_at == OLD_START
    assert re.search(r'^\s*pid = '+OLD_PID+r'$', launchd, re.M)
    assert re.search(r'^\s*program = '+re.escape(str(OLD_RELEASE / 'run-local-factory'))+r'$', launchd, re.M)
    if idle:
        assert control['tick_id'] is None and control['lease_expires_at'] is None


def validate_approval(approval, value, root):
    assert approval['result'] == 'ACCEPT_FOR_CUTOVER_ONLY'
    assert approval['source_commit'] == value['source_commit']
    assert approval['manifest_sha256'] == value['manifest_sha256']
    assert approval['cutover_guard_sha256'] == sha(Path(__file__))
    assert approval['guardian_sha256'] == THAW_SHA == sha(root / 'thaw_guardian.py')
    assert REQUIRED_EVIDENCE <= approval['evidence'].keys()
    for name, expected in approval['evidence'].items():
        assert Path(name).name == name and sha(root / name) == hex_value(expected)


def import_pinned(path, expected, name):
    raw = path.read_bytes()
    assert not path.is_symlink() and digest(raw) == expected
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(raw, str(path), 'exec', dont_inherit=True), module.__dict__)
    return module


def mailbox_quiet(path):
    metadata = path.lstat()
    assert stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.getuid() and metadata.st_mode & 0o777 == 0o700
    phases = {'finished': set(), 'response': set()}
    for entry in path.iterdir():
        found = re.fullmatch(r'([0-9a-f]{32})\.(finished|response)', entry.name)
        assert found is not None, 'unresolved or unknown broker mailbox entry'
        item = entry.lstat()
        assert stat.S_ISREG(item.st_mode) and item.st_uid == os.getuid(), entry.name
        phases[found[2]].add(found[1])
    assert phases['finished'] == phases['response'] and phases['finished']
    return {'finished_count': len(phases['finished']), 'response_count': len(phases['response']),
            'names_sha256': digest(encode(sorted(item.name for item in path.iterdir())))}


def validate_replacement_absent(process_listing, audit):
    launcher = Path(audit['replacement_launcher'])
    release = launcher.parent
    assert launcher.is_absolute() and launcher.name == 'run-local-factory'
    assert release.resolve() == release and release.name.startswith('symphony-review-report-')
    assert audit['replacement_build'] == str(release / 'dev')
    assert audit['replacement_manifest'] == str(release / 'evidence/release-manifest.json')
    for line in process_listing.splitlines():
        # exec replaces the launcher with BEAM; only guard/manifest argv may remain.
        assert str(release) not in line, 'replacement process may still be alive'


def bind(evidence_root):
    """Retain only dynamic-global stop/thaw/backup primitives from the sealed guard."""
    assert sha(HISTORICAL / 'thaw_guardian.py') == THAW_SHA
    g = import_pinned(HISTORICAL / 'cutover_guard.py', GUARD_SHA, 'ready_retained_guard')
    g.ROOT, g.OLD_PID, g.OLD_START, g.OLD_FINGERPRINT = evidence_root, OLD_PID, OLD_START, OLD_FINGERPRINT
    g.readonly = lambda: read_only(g.DB)
    retained_quiet = g.quiet
    retained_absent = g.absent

    def absent():
        retained_absent()
        if (evidence_root / 'cutover-audit.json').exists():
            listing = g.command(['/bin/ps', '-axo', 'pid=,command='])
            validate_replacement_absent(listing, g.load('cutover-audit.json'))

    def quiet():
        retained_quiet()
        current = mailbox_quiet(MAILBOX)
        if (evidence_root / 'captured.json').exists():
            assert current == g.load('captured.json')['mailbox']

    def configuration():
        broker, monitor = (tomllib.loads(path.read_text()) for path in (g.BROKER, g.MONITOR))
        assert broker['status'] == monitor['status'] == 'PAUSED'
        assert broker['rrule'] == 'FREQ=MINUTELY;INTERVAL=1'
        return {str(path): sha(path) for path in (g.BROKER, g.MONITOR, g.WORKFLOW)}

    def candidate():
        value = g.load('candidate.json')
        manifest = validate_candidate(value)
        audit = g.load('cutover-audit.json') if (evidence_root / 'cutover-audit.json').exists() else None
        if audit is not None:
            assert audit['kind'] == 'OWNED_READY_SERVICE_REPLACEMENT_V1'
            assert audit['issuer'] == {'pid': int(OLD_PID), 'started_at': OLD_START}
            assert audit['operation'] == {'run_id': RUN, 'state': 'READY_FOR_REVIEW'}
            assert audit['replacement_manifest'] == str(Path(value['release']) / 'evidence/release-manifest.json')
            assert audit['replacement_launcher'] == str(Path(value['release']) / 'run-local-factory')
            assert audit['replacement_build'] == value['build']
        return value, manifest, audit

    def original_pins():
        path = OLD_RELEASE / 'evidence/release-manifest.json'
        assert sha(path) == OLD_MANIFEST
        assert sha(OLD_RELEASE / 'run-local-factory') == OLD_LAUNCHER
        assert sha(OLD_RELEASE / 'release_boot_guard.exs') == OLD_BOOT
        original = json.loads(path.read_bytes())
        assert original['kind'] == 'FACTORY_REVIEW_REPORT_RELEASE_V1'
        assert original['source_commit'] == OLD_SOURCE and original['schema_version'] == 54
        assert inventory(Path(original['build'])) == original['artifact']
        assert {name: entry['sha256'] for name, entry in inventory(Path(original['source_root']), True).items()} == original['source_hashes']
        return {'build': original['build'], 'source': original['source_root']}

    def eligible():
        with g.readonly() as db:
            return validate_ticket(db)

    def protected(audit):
        path = Path(audit['protected_snapshot']['path'])
        assert path == evidence_root / 'audited-protected.json'
        assert sha(path) == audit['protected_snapshot']['sha256']
        metadata = g.DB.stat()
        assert audit['database_identity'] == {'path': str(g.DB), 'device': metadata.st_dev,
                                               'inode': metadata.st_ino, 'uid': metadata.st_uid}
        with g.readonly() as db:
            preserve(db, json.loads(path.read_bytes()))
            validate_ticket(db)
        return path.read_bytes()

    def old_binding(idle):
        result = g.api()
        control = result['factory']['control']
        started = g.command(['/bin/ps', '-p', OLD_PID, '-o', 'lstart=']).strip()
        launchd = g.command(['/bin/launchctl', 'print', g.SERVICE])
        validate_old_binding(control, started, launchd, idle)
        original_pins()
        return result

    def native_quiet_for(value):
        with g.readonly() as db:
            threads = [row[0] for row in db.execute('SELECT DISTINCT thread_id FROM worker_evidence WHERE thread_id IS NOT NULL')]
        assert 1 <= len(threads) <= 1000
        script = '''
for thread <- System.argv() do
  {:ok, queue} = SymphonyElixir.Factory.NativeQueueReadback.read("/Users/cgable/.codex/queue_1.sqlite", thread)
  {:ok, lock} = SymphonyElixir.Factory.NativeQueueReadback.writer_unlocked("/Users/cgable/.codex", thread)
  true = queue["thread_id"] == thread and queue["item_count"] == 0
  true = lock["status"] in ["absent", "unlocked"]
end
IO.puts("NATIVE_SOURCE_QUIET")
'''
        result = subprocess.run(['/opt/homebrew/bin/mise', 'exec', '--', 'elixir', '-pa',
                                 str(Path(value['build']) / 'lib/*/ebin'), '-e', script, '--', *threads],
                                cwd=Path(value['source']) / 'elixir', env=clean_env(),
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0 and result.stdout.strip() == 'NATIVE_SOURCE_QUIET'

    def native_quiet():
        native_quiet_for(candidate()[0])

    def qualified():
        value, manifest, audit = candidate()
        assert audit is not None
        approval = g.load('rollout-approved.json')
        validate_approval(approval, value, evidence_root)
        validate_validation(value, g.load('validation.json'), evidence_root)
        source = g.load('source-approved.json')
        review = g.load('review-acceptance.json')
        for accepted in (source, review):
            assert accepted['result'] == 'ACCEPT' and accepted['source_commit'] == value['source_commit']
        assert source['accepted_scopes'] == {'014': 'ACCEPT', '022': 'ACCEPT', '023': 'ACCEPT', '025-tools': 'ACCEPT'}
        assert review['manifest_sha256'] == value['manifest_sha256']
        for name in ('cold-boot.json', 'runtime-preflight.json'):
            proof = g.load(name)
            assert proof['result'] == 'PASS' and proof['manifest_sha256'] == value['manifest_sha256']
            assert type(proof['native_chats']) is int and proof['native_chats'] == 0
            assert type(proof['native_model_turns']) is int and proof['native_model_turns'] == 0
        preflight = g.load('runtime-preflight.json')
        assert preflight['initialization_only'] is True and preflight['signed_runtime_verified'] is True
        age = (datetime.now(timezone.utc)-datetime.fromisoformat(preflight['completed_at'])).total_seconds()
        assert 0 <= age <= 300
        validate_publication(value, manifest, g.load('public-completed-qualification.json'),
                             g.load('historical-completed-qualification.json'))
        assert eligible() == g.load('captured.json')['ticket']
        return value, manifest, audit

    def capture():
        value, _manifest, prior = candidate()
        assert prior is None
        old_binding(True)  # Fresh compact API before the read-only ledger capture.
        g.quiet()
        native_quiet()
        ticket = eligible()
        pins = configuration()
        assert sha(g.PLIST) == OLD_PLIST
        original = g.PLIST.read_bytes()
        plist = plistlib.loads(original)
        assert plist['ProgramArguments'] == [str(OLD_RELEASE / 'run-local-factory'), str(g.WORKFLOW)]
        assert plist['EnvironmentVariables']['MIX_BUILD_PATH'] == original_pins()['build']
        with g.readonly() as db:
            saved = snapshot(db)
        g.save('audited-protected.json', saved)
        with (evidence_root / 'service.original.plist').open('xb') as stream:
            stream.write(original)
        shutil.copy2(HISTORICAL / 'thaw_guardian.py', evidence_root / 'thaw_guardian.py')
        metadata = g.DB.stat()
        audit = {'kind': 'OWNED_READY_SERVICE_REPLACEMENT_V1',
                 'issuer': {'pid': int(OLD_PID), 'started_at': OLD_START},
                 'database_identity': {'path': str(g.DB), 'device': metadata.st_dev, 'inode': metadata.st_ino, 'uid': metadata.st_uid},
                 'operation': {'run_id': RUN, 'state': 'READY_FOR_REVIEW'},
                 'protected_snapshot': {'path': str(evidence_root / 'audited-protected.json'),
                                        'sha256': sha(evidence_root / 'audited-protected.json')},
                 'replacement_build': value['build'], 'replacement_launcher': str(Path(value['release']) / 'run-local-factory'),
                 'replacement_manifest': str(Path(value['release']) / 'evidence/release-manifest.json')}
        g.save('cutover-audit.json', audit)
        g.save('captured.json', {'old_pid': OLD_PID, 'old_start': OLD_START,
                                 'plist_sha256': sha(g.PLIST), 'configuration': pins,
                                 'manifest_sha256': value['manifest_sha256'], 'ticket': ticket, 'mailbox': mailbox_quiet(MAILBOX),
                                 'guard_ledger_row_writes': 0})
        protected(audit)
        print('READ_ONLY_READY_CUTOVER_CAPTURE_PASS')

    def finish_start():
        value, _manifest, audit = candidate()
        intent = g.load('start-intent.json')
        assert intent['manifest_sha256'] == value['manifest_sha256'] and intent['plist_sha256'] == sha(g.PLIST)
        deadline = time.monotonic()+45
        while True:
            try:
                result = g.api()
                break
            except urllib.error.URLError:
                assert time.monotonic() < deadline
                time.sleep(0.25)
        runtime = result['factory']['control']['runtime_identity']
        pid = runtime['os_pid']
        assert type(pid) is str and pid.isdigit() and pid != OLD_PID
        assert runtime['factory_beam_fingerprint'] == value['factory_beam_fingerprint']
        assert runtime['factory_beam_module_count'] == value['factory_module_count']
        launchd = g.command(['/bin/launchctl', 'print', g.SERVICE])
        assert re.search(r'^\s*pid = '+pid+r'$', launchd, re.M)
        assert re.search(r'^\s*program = '+re.escape(audit['replacement_launcher'])+r'$', launchd, re.M)
        protected(audit)
        public = run_qualifiers(value, evidence_root, 'poststart')
        protected(audit)
        g.save_equal('started.json', {'result': 'PASS', 'runtime_identity': runtime,
                                     'manifest_sha256': value['manifest_sha256'], 'guard_ledger_row_writes': 0,
                                     'all_protected_old_rows_unchanged_after_start': True,
                                     'public_completed_requalified': public, 'schema_migration': None})
        print('STARTED_READY_HISTORY_PRESERVED')

    def start():
        value, _manifest, audit = qualified()
        assert g.load('stopped.json')['result'] == 'EXACT_ISSUER_STOPPED'
        g.absent()
        assert configuration() == g.load('captured.json')['configuration']
        g.quiet()
        native_quiet()
        protected(audit)
        saved = evidence_root / 'service.original.plist'
        assert sha(saved) == g.load('captured.json')['plist_sha256'] == sha(g.PLIST) == OLD_PLIST
        replace_plist(g.PLIST, sha(saved), replacement_plist(saved.read_bytes(), audit['replacement_launcher'], audit['replacement_build']))
        protected(audit)
        g.save('start-intent.json', {'manifest_sha256': value['manifest_sha256'], 'plist_sha256': sha(g.PLIST), 'attempts': 1})
        g.command(['/bin/launchctl', 'bootstrap', 'gui/505', str(g.PLIST)], timeout=15)
        finish_start()

    def restore_check():
        # Do not inspect or execute a broken replacement to restore the original.
        g.absent()
        audit, captured, approval = (g.load(name) for name in ('cutover-audit.json', 'captured.json', 'rollout-approved.json'))
        assert sha(evidence_root / 'cutover-audit.json') == approval['evidence']['cutover-audit.json']
        assert audit['kind'] == 'OWNED_READY_SERVICE_REPLACEMENT_V1'
        assert audit['issuer'] == {'pid': int(OLD_PID), 'started_at': OLD_START}
        protected(audit)
        assert configuration() == captured['configuration']
        saved = evidence_root / 'service.original.plist'
        assert sha(saved) == captured['plist_sha256'] == OLD_PLIST
        runtime = original_pins()
        validate_restore_plist(saved.read_bytes(), g.PLIST.read_bytes(), audit, str(g.WORKFLOW), runtime['build'])
        g.quiet()
        native_quiet_for(runtime)
        print('ORIGINAL_216_ONLY_RESTORE_ALLOWED')

    retained_restore = g.restore_original

    def restore_original():
        restore_check()
        saved = evidence_root / 'service.original.plist'
        if g.PLIST.read_bytes() != saved.read_bytes():
            replace_plist(g.PLIST, sha(g.PLIST), saved.read_bytes())
        retained_restore()

    for name, function in locals().copy().items():
        if name in {'configuration', 'candidate', 'original_pins', 'eligible', 'protected', 'old_binding', 'quiet', 'absent',
                    'native_quiet_for', 'native_quiet', 'qualified', 'finish_start', 'start',
                    'restore_check', 'restore_original'}:
            setattr(g, name, function)
    return g, capture


def clean_env():
    result = {key: value for key, value in os.environ.items() if key not in
              ('ELIXIR_ERL_OPTIONS', 'ERL_AFLAGS', 'ERL_ZFLAGS', 'ERL_LIBS', 'MIX_BUILD_PATH', 'MIX_ENV', 'MIX_TARGET', 'ERL_FLAGS')}
    result.update(ERL_FLAGS='+S 4:4', PYTHONDONTWRITEBYTECODE='1')
    return result


def run_qualifiers(value, evidence, prefix):
    source = Path(value['source'])
    args = [str(Path(value['release']) / 'evidence/release-manifest.json'), value['manifest_sha256']]
    attempt = prefix+'-'+secrets.token_hex(16)
    public = evidence / (attempt+'-public-completed.json')
    history = evidence / (attempt+'-historical-completed.json')
    assert not public.exists() and not history.exists()
    env = clean_env()
    env['MIX_BUILD_PATH'] = value['build']
    result = subprocess.run(['/opt/homebrew/bin/mise', 'exec', '--', 'elixir', '-pa',
                             str(Path(value['build']) / 'lib/*/ebin'),
                             str(source / 'plans/rollout/qualify_review_ready_publication.exs'), *args, str(public)],
                            cwd=source / 'elixir', env=env, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, 'public completed qualification failed; inspect bounded private evidence'
    result = subprocess.run([sys.executable, '-I', '-B', str(source / 'plans/rollout/qualify_review_ready_publication_history.py'),
                             *args, str(history)], cwd=source, env=env, capture_output=True, text=True, timeout=180)
    assert result.returncode == 0, 'historical completed qualification failed; inspect bounded private evidence'
    validate_publication(value, json.loads(Path(args[0]).read_bytes()), json.loads(public.read_bytes()), json.loads(history.read_bytes()))
    return True


def main():
    assert len(sys.argv) == 3
    operation, evidence = sys.argv[1], Path(sys.argv[2]).resolve()
    assert evidence.is_dir()
    assert operation in ('capture', 'stop', 'finish-stop', 'start', 'finish-start', 'restore-check', 'restore-original')
    g, capture = bind(evidence)
    {'capture': capture, 'stop': g.stop, 'finish-stop': g.finish_stop, 'start': g.start,
     'finish-start': g.finish_start, 'restore-check': g.restore_check, 'restore-original': g.restore_original}[operation]()


if __name__ == '__main__':
    main()
