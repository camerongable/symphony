"""Read the actual retained push twice; no issuance or writable SQLite connection."""

import hashlib
import json
from contextlib import closing
from pathlib import Path
import sqlite3
import sys
import types


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


manifest_path, expected_manifest, history_name = sys.argv[1:]
manifest_raw = Path(manifest_path).read_bytes()
assert sha(manifest_raw) == expected_manifest
manifest = json.loads(manifest_raw)
assert manifest['schema_version'] == 54
assert history_name in ('ticket_push_history_validator_v23.py', 'ticket_push_history_validator_v24.py')
local = Path(manifest['build']) / 'lib/symphony_elixir/priv'
history_path = local / history_name
history_raw = history_path.read_bytes()
assert sha(history_raw) == manifest['artifact']['lib/symphony_elixir/priv/' + history_name]['sha256']
codec = types.ModuleType('retained_publisher_history')
codec.__file__ = str(history_path)
exec(compile(history_raw, str(history_path), 'exec', dont_inherit=True), codec.__dict__)
database = Path('/Users/cgable/Documents/Codex/factory-state/factory.sqlite')
run_id = 'ab5ab1fe-32cc-48c1-985e-3c3800adcfa2'
expected_current = 'eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834'
captured = None
for _ in range(2):
    with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        db.row_factory = sqlite3.Row
        current = dict(db.execute('SELECT * FROM runs WHERE run_id=?', (run_id,)).fetchone())
        assert current['state'] == 'CI_PUSHING' and current['candidate_sha'] == expected_current
        assert current['verifier_round'] == 5 and current['code_repair_round'] == 13
        assert current['implementation_iteration'] == 27
        intent = json.loads(current['candidate_handoff'])
        assert intent['kind'] == 'TICKET_PUSH' and intent['phase'] == 'COMPLETED'
        assert intent['receipt_sha256'] == '743b489bf716d072bb9955f827397588e1c8451974e90c27b64b67e4394b06e1'
        binding = json.loads(intent['binding_json'])
        execution = json.loads(intent['execution_json'])
        assert binding['candidate_sha'] == '4e5c48fc2150515c4cb5ce0771f4c204b10c532c'
        assert binding['verifier_round'] == 4 and binding['code_repair_round'] == 12
        prior = dict(current, **binding)
        codec.validate_archived_ci_authority(db, prior, binding, execution)
        codec.validate_physical_predecessor(db, prior, intent, binding['checkout'], binding['origin'])
        assert db.total_changes == 0
        if captured is None:
            captured = current
        else:
            assert current == captured

print(json.dumps({
    'result': 'PASS', 'manifest_sha256': expected_manifest,
    'history_program': history_name, 'history_sha256': sha(history_raw),
    'current_candidate_sha': expected_current,
    'retained_receipt_sha256': intent['receipt_sha256'],
    'archived_authority_and_full_physical_predecessor': True,
    'read_only_sqlite_reopens': 2, 'current_raw_run_unchanged': True,
    'live_ledger_writes': 0, 'pushes': 0, 'native_chats': 0,
    'limitation': 'Retained-history compatibility only; not current candidate delivery.'
}, sort_keys=True))
