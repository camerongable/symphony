"""Read a closed diagnostic copy; project one audited child in memory, never issue."""
import hashlib
import importlib.util
import json
import pathlib
import sqlite3
import sys

sys.dont_write_bytecode = True


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def main():
    priv, evidence = (pathlib.Path(value).resolve() for value in sys.argv[1:])
    path = priv / 'ticket_push_history_validator_v10.py'
    spec = importlib.util.spec_from_file_location('read_only_history', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    audit_raw = (priv / 'ticket_push_rejection_v3.json').read_bytes()
    audit = json.loads(audit_raw)
    original_bytes = (evidence / 'rejected-envelope.json').read_bytes()
    original_raw = original_bytes.decode()
    original = json.loads(original_raw)
    execution = json.loads(original['execution_json'])
    binding = json.loads(original['binding_json'])
    rejection = (evidence / 'rejection.json').read_text()
    assert sha(original_raw.encode()) == audit['original_sha256']
    assert sha(rejection.encode()) == audit['rejection_sha256']
    database_path = evidence / 'diagnostic.sqlite'
    wal_path = evidence / 'diagnostic.sqlite-wal'
    assert not wal_path.exists() or wal_path.stat().st_size == 0
    database_sha = sha(database_path.read_bytes())
    source = sqlite3.connect(database_path.as_uri() + '?mode=ro&immutable=1', uri=True)
    source.execute('PRAGMA query_only=ON')
    assert source.execute('PRAGMA query_only').fetchone()[0] == 1
    source.row_factory = sqlite3.Row
    run = dict(source.execute('SELECT * FROM runs WHERE run_id=?', (execution['run_id'],)).fetchone())
    assert run['candidate_handoff'].encode() == original_bytes
    assert all(run[key] == audit[key] for key in ('run_id', 'candidate_sha', 'contract_sha256', 'code_repair_round'))
    assert all(run[key] == binding[key] for key in ('run_id', 'candidate_sha', 'spec_revision', 'contract_sha256'))
    active = dict(source.execute('SELECT * FROM workspace_access WHERE reservation_key=?', (original['reservation_key'],)).fetchone())
    assert active['released_at'] is None and active['release_receipt_json'] is None
    assert active['run_id'] == run['run_id'] and active['mode'] == 'MAINTENANCE' and active['task_key'] is None
    assert active['request_key'] == active['reservation_key'] == original['reservation_key']
    assert active['generation'] == original['reservation_generation']
    module.generated_only_commits(source, execution, binding, run)
    assert source.total_changes == 0
    database = sqlite3.connect(':memory:')
    source.backup(database)
    database.row_factory = sqlite3.Row
    proof = {'kind': audit['kind'], 'audit_sha256': sha(audit_raw), 'rejection_json': rejection,
             'rejection_sha256': audit['rejection_sha256']}
    proof_raw = encoded(proof)
    key = 'push-rejection:' + sha((original_raw + audit['rejection_sha256']).encode())
    identity = {'retirement_key': key, 'original_sha256': audit['original_sha256'], 'attempt': 1}
    child_binding = dict(binding, preissuance_retirement=identity)
    child_binding_raw = encoded(child_binding)
    child_hash = sha(child_binding_raw.encode())
    child_nonce = sha((key + ':successor:1').encode())
    row = dict(retirement_key=key, run_id=run['run_id'], candidate_sha=run['candidate_sha'],
               code_repair_round=run['code_repair_round'], claim_key=binding['ci_repair']['claim_key'],
               original_nonce=original['owner_nonce'], original_envelope=original_raw,
               original_sha256=audit['original_sha256'], proof_json=proof_raw,
               proof_sha256=sha(proof_raw.encode()), successor_nonce=child_nonce,
               successor_binding_sha256=child_hash, successor_reservation_key='ticket-push:' + child_hash,
               created_at='2026-10-21T00:00:00.000000Z')
    database.execute('INSERT INTO ticket_push_rejection_retirements VALUES (' + ','.join('?' for _ in row) + ')', tuple(row.values()))
    old_access = dict(database.execute('SELECT * FROM workspace_access WHERE reservation_key=?', (original['reservation_key'],)).fetchone())
    database.execute('UPDATE workspace_access SET released_at=?,release_receipt_json=? WHERE reservation_key=?',
                     (row['created_at'], proof_raw, original['reservation_key']))
    access = dict(old_access, reservation_key=row['successor_reservation_key'], request_key=row['successor_reservation_key'],
                  generation=old_access['generation'] + 1, released_at=None, release_receipt_json=None)
    access_binding = json.loads(access['binding_json'])
    access_binding.update(reservation_key=access['reservation_key'], request_key=access['request_key'])
    access['binding_json'] = encoded(access_binding)
    database.execute('INSERT INTO workspace_access (' + ','.join(access) + ') VALUES (' + ','.join('?' for _ in access) + ')', tuple(access.values()))
    child = dict(original, phase='PREPARED', binding_json=child_binding_raw, binding_sha256=child_hash,
                 owner_nonce=child_nonce, reservation_key=access['reservation_key'], reservation_generation=access['generation'],
                 helper_pid=None, execution_json=None)
    run['candidate_handoff'] = encoded(child)
    database.execute('UPDATE runs SET candidate_handoff=? WHERE run_id=?', (run['candidate_handoff'], run['run_id']))
    projected = dict(execution, intent_json=child_binding_raw, intent_sha256=child_hash, invocation=child_nonce,
                     helper_path=str(priv / 'ticket_push_executor_v13.py'), helper_sha256=sha((priv / 'ticket_push_executor_v13.py').read_bytes()),
                     history_program_path=str(path), history_program_sha256=sha(path.read_bytes()),
                     companion_path=str(priv / 'worker_file_companion.py'))
    module.validate_prepared_requalification(database, projected, child_binding, run)
    module.validate_preissuance_retirement(database, projected, child_binding, run)
    module.generated_only_commits(database, projected, child_binding, run)
    raw = encoded(projected)
    wire = encoded({'execution_json': raw, 'helper_pid': 9223372036854775807}).encode()
    receipt = encoded({'version': 1, 'execution_json': raw, 'helper_pid': 9223372036854775807,
                       'child_pid': 9223372036854775807, 'termination': {'kind': 'signaled', 'signal': 64},
                       'timed_out': False, 'overflow': False, 'output_base64': 'A' * 87384,
                       'output_sha256': 'f' * 64, 'stderr_code': 'AUTHENTICATION_DENIED', 'stderr_bytes': 16384,
                       'stderr_sha256': 'f' * 64}).encode()
    ascii_wire = json.dumps({'execution_json': raw, 'helper_pid': 9223372036854775807}, separators=(',', ':')).encode()
    ascii_terminal = json.dumps(json.loads(receipt), separators=(',', ':')).encode()
    assert len(wire) <= 1048576 and len(receipt) <= 4194304
    assert len(ascii_wire) <= 1048576 and len(ascii_terminal) <= 4194304
    assert sha(database_path.read_bytes()) == database_sha
    assert not wal_path.exists() or wal_path.stat().st_size == 0
    print(json.dumps({'generation': 'PASS', 'exact_two_journal_composition': 'PASS', 'source_sql_changes': source.total_changes,
                      'projected_execution_bytes': len(raw.encode()), 'projected_request_bytes': len(wire),
                      'python_ascii_request_bytes': len(ascii_wire), 'python_ascii_terminal_size_only_bytes': len(ascii_terminal),
                      'sizing_only_unvalidated_terminal_bytes': len(receipt), 'closed_source_sha256': database_sha,
                      'terminal_semantics': 'NONVALIDATED_SIZE_ONLY', 'script_sha256': sha(pathlib.Path(__file__).read_bytes()),
                      'v10_sha256': sha(path.read_bytes()), 'v13_sha256': projected['helper_sha256'],
                      'generation_origins_sha256': sha((priv / 'ticket_generation_origins_v1.json').read_bytes()),
                      'rejection_audit_sha256': sha(audit_raw), 'push_origins_sha256': sha((priv / 'ticket_push_readback_origins_v6.json').read_bytes()),
                      'projection_only_not_real_prepare_or_issuance': True}))


if __name__ == '__main__':
    main()
