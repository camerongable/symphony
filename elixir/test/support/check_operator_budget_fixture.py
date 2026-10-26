"""Exercise the physical publication validator against an actual controller fixture."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys

database, packet_path = sys.argv[1:]
path = Path(__file__).resolve().parents[2] / 'priv/ticket_push_history_validator_v19.py'
spec = importlib.util.spec_from_file_location('review_history', path)
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)
packet = json.loads(Path(packet_path).read_text())
ref = packet['repair_review']['operator_authorization']
with sqlite3.connect(Path(database).as_uri() + '?mode=ro', uri=True) as connection:
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA query_only=ON')
    run = dict(connection.execute('SELECT * FROM runs WHERE run_id=?', (packet['run_id'],)).fetchone())
    worker = dict(connection.execute('SELECT * FROM worker_evidence WHERE request_key=?', (packet['repair_review']['verifier_request_key'],)).fetchone())
    binding, output = json.loads(worker['binding_json']), json.loads(worker['output_json'])
    mapping = dict(connection.execute('SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?', (worker['task_key'], binding['input_sha256'])).fetchone())
    reviewed = json.loads(connection.execute('SELECT binding_json FROM worker_instruction_snapshots WHERE binding_sha256=?', (mapping['instruction_binding_sha256'],)).fetchone()[0])
    if reviewed.get('review_protocol', {}).get('version') == 2:
        typed_path = path.with_name('ticket_push_history_validator_v21.py')
        typed_spec = importlib.util.spec_from_file_location('typed_review_history', typed_path)
        history = importlib.util.module_from_spec(typed_spec)
        typed_spec.loader.exec_module(history)
        history.validate_review_admission(connection, worker, binding, output, reviewed)
    proof = {'operator_authorization': ref, 'reviewed_candidate_sha': packet['repair_review']['prior_candidate_sha'], 'round': run['code_repair_round'], 'verifier_round': run['verifier_round']}
    findings = history.review_finding_entries(run['contract_sha256'], worker, binding, output, reviewed)
    assert findings == packet['repair_review']['findings']
    history.operator_repair_authority(connection, proof, run, (worker, binding, output, reviewed, mapping), packet, findings)
print('PHYSICAL_OPERATOR_AUTHORITY_PASS')
