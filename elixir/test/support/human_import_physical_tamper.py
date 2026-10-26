import copy
import importlib.util
import json
import sqlite3
import sys


database, program = sys.argv[1:]
spec = importlib.util.spec_from_file_location('history', program)
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)
db = sqlite3.connect('file:' + database + '?mode=ro', uri=True)
db.row_factory = sqlite3.Row
row = db.execute('SELECT proof_json FROM ticket_human_empty_commit_imports').fetchone()
prior = json.loads(row['proof_json'])['prior_run']
original = json.loads(prior['candidate_handoff'])
binding = json.loads(original['binding_json'])
history.validate_physical_predecessor(db, prior, original, binding['checkout'], binding['origin'])


class AlteredRelease:
    def __init__(self, access):
        self.access = access

    def execute(self, sql, args=()):
        if 'FROM workspace_access WHERE reservation_key=? AND run_id=?' in sql:
            return self
        return db.execute(sql, args)

    def fetchall(self):
        return [self.access]

    def __iter__(self):
        return iter([self.access])


for missing in ('ci_repair', 'ci_evidence_successor', 'ci_repair_policy_receipt', 'attempts_used'):
    forged_prior = copy.deepcopy(prior)
    intent = copy.deepcopy(original)
    forged = json.loads(intent['binding_json'])
    execution = json.loads(intent['execution_json'])
    if missing == 'attempts_used':
        proof = forged['ci_evidence_successor']
        proof['attempts_used'] = proof['attempts_used'] + 1 if proof['attempts_used'] < proof['attempt_limit'] else proof['attempts_used'] - 1
        execution['ci_evidence_successor'] = copy.deepcopy(proof)
    else:
        forged.pop(missing)
        execution.pop(missing, None)
    intent['binding_json'] = json.dumps(forged, separators=(',', ':'))
    intent['binding_sha256'] = history.sha(intent['binding_json'].encode())
    intent['reservation_key'] = 'ticket-push:' + intent['binding_sha256']
    execution.update(intent_json=intent['binding_json'], intent_sha256=intent['binding_sha256'])
    intent['execution_json'] = json.dumps(execution, separators=(',', ':'))
    receipt = json.loads(intent['receipt_json'])
    receipt['execution_json'] = intent['execution_json']
    intent['receipt_json'] = json.dumps(receipt, separators=(',', ':'))
    intent['receipt_sha256'] = history.sha(intent['receipt_json'].encode())
    forged_prior['candidate_handoff'] = json.dumps(intent, separators=(',', ':'))
    access = dict(db.execute('SELECT * FROM workspace_access WHERE reservation_key=?', (original['reservation_key'],)).fetchone())
    access['request_key'] = access['reservation_key'] = intent['reservation_key']
    owned = json.loads(access['binding_json'])
    owned['request_key'] = owned['reservation_key'] = intent['reservation_key']
    access['binding_json'] = json.dumps(owned, separators=(',', ':'))
    access['release_receipt_json'] = forged_prior['candidate_handoff']
    try:
        history.validate_physical_predecessor(AlteredRelease(access), forged_prior, intent, binding['checkout'], binding['origin'])
    except (KeyError, ValueError):
        continue
    raise AssertionError('coherent authority deletion accepted: ' + missing)

def check_receipt(changes, accepted):
    intent = copy.deepcopy(original)
    receipt = json.loads(intent['receipt_json'])
    receipt.update(changes)
    intent['receipt_json'] = json.dumps(receipt, separators=(',', ':'))
    intent['receipt_sha256'] = history.sha(intent['receipt_json'].encode())
    captured = copy.deepcopy(prior)
    captured['candidate_handoff'] = json.dumps(intent, separators=(',', ':'))
    access = dict(db.execute('SELECT * FROM workspace_access WHERE reservation_key=?', (original['reservation_key'],)).fetchone())
    access['release_receipt_json'] = captured['candidate_handoff']
    try:
        history.validate_physical_predecessor(AlteredRelease(access), captured, intent, binding['checkout'], binding['origin'])
    except (KeyError, ValueError, TypeError):
        assert not accepted, changes
    else:
        assert accepted, changes


for changes in [
    {'termination': {'kind': 'exited', 'code': 1}, 'stderr_code': 'GIT_EXIT_NONZERO'},
    {'termination': {'kind': 'signaled', 'signal': 9}, 'timed_out': True, 'stderr_code': 'TRANSPORT_FAILURE'},
    {'overflow': True, 'stderr_code': 'AUTHENTICATION_DENIED'},
]:
    check_receipt(changes, True)

for changes in [
    {'child_pid': None},
    {'helper_pid': original['helper_pid'] + 1},
    {'execution_json': '{}'},
    {'termination': {'kind': 'exited', 'code': True}},
    {'termination': {'kind': 'exited', 'code': 256}},
    {'termination': {'kind': 'signaled', 'signal': 0}},
    {'termination': {'kind': 'signaled', 'signal': 65}},
    {'termination': {'kind': 'signaled', 'signal': 9, 'code': 0}},
    {'timed_out': 1}, {'overflow': None},
    {'output_base64': '!'}, {'output_sha256': '0' * 64},
    {'stderr_code': 'UNPROVEN'}, {'stderr_bytes': True}, {'stderr_bytes': 16385},
    {'stderr_sha256': 'unproven'},
]:
    check_receipt(changes, False)

for field, value in [('phase', 'PUSH_UNCERTAIN'), ('remote_sha', '0' * 40)]:
    intent = copy.deepcopy(original)
    intent[field] = value
    try:
        history.validate_physical_predecessor(db, prior, intent, binding['checkout'], binding['origin'])
    except (KeyError, ValueError):
        pass
    else:
        raise AssertionError('unauthenticated historical completion accepted: ' + field)

print('original physical receipt accepted; four coherently rehashed authority mutations rejected; terminal schema and completion guards passed')
