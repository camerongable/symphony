"""Public physical publication-history boundary; no Git, subprocesses or live ledger."""
import hashlib
import json
from pathlib import Path
import sqlite3
import unittest

PRIV = Path(__file__).resolve().parents[2] / 'priv'


def load(name):
    path = PRIV / name
    module = {'__name__': 'physical_history_test', '__file__': str(path)}
    exec(compile(path.read_bytes(), str(path), 'exec'), module)
    return module['worker_history']


class PublicationHistoryTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
CREATE TABLE worker_evidence(request_key TEXT,run_id TEXT,task_key TEXT,status TEXT,reservation_key TEXT,binding_json TEXT,output_json TEXT,policy_json TEXT,owner_stopped_at TEXT,owner_stop_json TEXT,owner_process_json TEXT,thread_id TEXT,turn_id TEXT);
CREATE TABLE factory_tasks(task_key TEXT,run_id TEXT,role TEXT,status TEXT,thread_id TEXT,turn_id TEXT,output_json TEXT);
CREATE TABLE workspace_access(reservation_key TEXT,run_id TEXT,generation INTEGER,canonical_path TEXT,mode TEXT,released_at TEXT,release_receipt_json TEXT);
CREATE TABLE events(id INTEGER,run_id TEXT,event_type TEXT,payload_json TEXT);
CREATE TABLE ticket_chat_commands(command_key TEXT,run_id TEXT,binding_json TEXT,payload_json TEXT,receipt_json TEXT,application_receipt_json TEXT);
CREATE TABLE ticket_ci_repair_evidence_successors(run_id TEXT,attempt_index INTEGER,proof_json TEXT,evidence_json TEXT);
CREATE TABLE ticket_ordinary_generation_intents(intent_key TEXT,run_id TEXT,binding_json TEXT);
CREATE TABLE ticket_ordinary_generation_events(event_key TEXT,intent_key TEXT,receipt_json TEXT);
CREATE TABLE worker_file_operations(request_key TEXT,call_id TEXT,phase TEXT,io_pending INTEGER);
''')
        process = {'pid': 'synthetic', 'invocation_nonce': 'a' * 64}
        stop = dict(process, transport='owned_app_server', thread_id='thread', exit_status=0, cwd='/synthetic/source')
        self.worker = dict(request_key='writer',run_id='run',task_key='writer-task',status='CONSUMED',reservation_key='source',
            binding_json='{}',output_json='{}',policy_json='{}',owner_stopped_at='stopped',
            owner_stop_json=json.dumps(stop),owner_process_json=json.dumps(process),thread_id='thread',turn_id='turn')
        self.insert('worker_evidence', self.worker)
        self.insert('factory_tasks', dict(task_key='writer-task',run_id='run',role='feature-writer',status='CONSUMED',thread_id='thread',turn_id='turn',output_json='{}'))
        self.insert('workspace_access', dict(reservation_key='source',run_id='run',generation=2,canonical_path='/synthetic/source',mode='SOURCE',released_at='released',release_receipt_json='{}'))

    def tearDown(self):
        self.db.close()

    def insert(self, table, value):
        self.db.execute('INSERT INTO '+table+'('+','.join(value)+') VALUES('+','.join('?' for _ in value)+')',tuple(value.values()))

    def execution(self, helper, version=None):
        fields = {'workers':('worker_evidence','request_key',('binding_json','output_json','policy_json')),
            'tasks':('factory_tasks','task_key',('output_json',)),
            'accesses':('workspace_access','reservation_key',('binding_json','release_receipt_json')),
            'events':('events','id',('payload_json',)),
            'commands':('ticket_chat_commands','command_key',('binding_json','payload_json','receipt_json','application_receipt_json')),
            'successors':('ticket_ci_repair_evidence_successors','attempt_index',('proof_json','evidence_json')),
            'generation_intents':('ticket_ordinary_generation_intents','intent_key',('binding_json',)),
            'generation_events':('ticket_ordinary_generation_events','event_key',('receipt_json',))}
        proof = {'worker_key_order':list(self.worker), 'review_events_json':'[]'}
        for name,(table,order,digests) in fields.items():
            rows = [dict(row) for row in self.db.execute('SELECT * FROM '+table+' ORDER BY '+order)]
            compact = [{key:hashlib.sha256(value.encode()).hexdigest() if key in digests and isinstance(value,str) else value for key,value in row.items()} for row in rows]
            proof[name+'_json'] = json.dumps(compact)
        if version is not None:
            proof['capability_recovery_version'] = version
        return {'helper_path':str(PRIV/helper),'run_id':'run','worker_history':proof}

    def test_ordinary_forward_helper_accepts_history_without_capability_marker(self):
        self.assertIsNone(load('ticket_push_history_validator_v20.py')(self.db,self.execution('ticket_push_executor_v25.py')))

    def test_capability_helper_requires_typed_version_even_without_transfer(self):
        self.assertIsNone(load('ticket_push_history_validator_v19.py')(self.db,self.execution('ticket_push_executor_v24.py')))
        check = load('ticket_push_history_validator_v20.py')
        for version in (None,True,0,2,'1'):
            with self.subTest(version=version),self.assertRaises(ValueError):
                check(self.db,self.execution('ticket_push_executor_v26.py',version))
        self.assertIsNone(check(self.db,self.execution('ticket_push_executor_v26.py',1)))

    def test_unknown_helper_cannot_claim_capability_format(self):
        with self.assertRaises(ValueError):
            load('ticket_push_history_validator_v20.py')(self.db,self.execution('unregistered.py',1))

    def test_file_source_publishers_preserve_required_capability_history(self):
        check = load('ticket_push_history_validator_v27.py')
        self.assertIsNone(check(self.db, self.execution('ticket_push_executor_v39.py')))
        self.assertIsNone(check(self.db, self.execution('ticket_push_executor_v39.py', 1)))
        for version in (None, True, 0, 2, '1'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                check(self.db, self.execution('ticket_push_executor_v40.py', version))
        self.assertIsNone(check(self.db, self.execution('ticket_push_executor_v40.py', 1)))

    def test_marker_does_not_authorize_a_transfer_without_its_grant(self):
        old = dict(self.worker,request_key='blocked',status='RESULT_RECORDED',reservation_key='old-source')
        self.insert('worker_evidence',old)
        transfer = {'kind':'BLOCKED_SOURCE_TRANSFER','old_request_key':'blocked','new_request_key':'writer','operational_recovery_key':'TCAP-unproven'}
        self.insert('workspace_access',dict(reservation_key='old-source',run_id='run',generation=1,canonical_path='/synthetic/source',mode='SOURCE',released_at='released',release_receipt_json=json.dumps(transfer)))
        check = load('ticket_push_history_validator_v20.py')
        for helper,version in [('ticket_push_executor_v25.py',None),('ticket_push_executor_v26.py',1)]:
            with self.subTest(helper=helper),self.assertRaises(ValueError):
                check(self.db,self.execution(helper,version))


if __name__ == '__main__':
    unittest.main()
