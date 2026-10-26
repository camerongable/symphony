"""Validate an actual ordinary controller writer proof without issuing a push."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys

database, packet_path = sys.argv[1:]
path = Path(__file__).resolve().parents[2] / 'priv/ticket_push_history_validator_v22.py'
spec = importlib.util.spec_from_file_location('policy_stop_history', path)
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)
packet = json.loads(Path(packet_path).read_text())
proof, run = packet['proof'], packet['run']
with sqlite3.connect(Path(database).as_uri() + '?mode=ro', uri=True) as connection:
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA query_only=ON')
    observed = history.ordinary_repair_proof(connection, {'ordinary_verifier_repair': proof}, {'ordinary_verifier_repair': proof}, run)
    assert observed == proof and observed['version'] == 3
    before = proof['operator_authorization']['review_policy_stop']['automatic_repairs_used']
    assert before == 2
print('PHYSICAL_POLICY_STOP_PUBLICATION_PASS')
