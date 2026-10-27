"""Validate current publication facts with owned stdin kept open; never invoke a producer."""

from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import types


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


manifest_path, expected_manifest = sys.argv[1:]
manifest_raw = Path(manifest_path).read_bytes()
assert sha(manifest_raw) == expected_manifest
manifest = json.loads(manifest_raw)
assert manifest['schema_version'] == 54
local = Path(manifest['build']) / 'lib/symphony_elixir/priv'
history_path = local / 'ticket_push_history_validator_v25.py'
raw = history_path.read_bytes()
assert sha(raw) == manifest['artifact']['lib/symphony_elixir/priv/' + history_path.name]['sha256']
assert sys.stdin.isatty(), 'qualification requires a genuine open owned stdin'
codec = types.ModuleType('current_publication_history')
codec.__file__ = str(history_path)
exec(compile(raw, str(history_path), 'exec', dont_inherit=True), codec.__dict__)
database = Path('/Users/cgable/Documents/Codex/factory-state/factory.sqlite')
captured = None
for _ in range(2):
    with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        db.row_factory = sqlite3.Row
        run = dict(db.execute('SELECT * FROM runs WHERE run_id=?', ('ab5ab1fe-32cc-48c1-985e-3c3800adcfa2',)).fetchone())
        assert run['state'] == 'CI_PUSHING' and run['candidate_sha'] == 'eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834'
        assert run['implementation_iteration'] == 27 and run['verifier_round'] == 5 and run['code_repair_round'] == 13
        assert sha(run['candidate_handoff'].encode()) == '5935494d2f4b8b2ec0c3e5778a2e297d64f138c73469140db4c20ae3f549c209'
        intent = json.loads(run['candidate_handoff'])
        binding = json.loads(intent['binding_json'])
        execution = json.loads(intent['execution_json'])
        assert intent['phase'] == 'PUSH_UNCERTAIN' and intent['helper_pid'] == 5776
        proof = binding['ordinary_verifier_repair']
        assert proof['source_parent_sha'] == proof['reviewed_candidate_sha'] == '4e5c48fc2150515c4cb5ce0771f4c204b10c532c'
        output = json.loads(db.execute('SELECT output_json FROM worker_evidence WHERE request_key=?', (proof['writer_request_key'],)).fetchone()[0])
        go_paths = sorted(path for path in output['changed_paths'] if path.endswith('.go'))
        assert len(go_paths) == 6
        root = binding['worktree']
        assert os.path.realpath(root) == root == run['worktree']
        def git(*args):
            return subprocess.check_output(['/opt/homebrew/bin/git', '--no-optional-locks', '-C', root, *args], stdin=subprocess.DEVNULL, timeout=20)
        assert git('rev-parse', 'HEAD').decode().strip() == run['candidate_sha']
        assert git('rev-parse', 'HEAD^').decode().strip() == proof['source_parent_sha']
        git('merge-base', '--is-ancestor', proof['source_parent_sha'], run['candidate_sha'])
        present = git('ls-tree', '-r', '--name-only', run['candidate_sha'], '--', *go_paths).decode().splitlines()
        codec.validate_prepared_requalification(db, execution, binding, run)
        codec.validate_preissuance_retirement(db, execution, binding, run)
        codec.validate_ordinary_preissuance_retirement(db, execution, binding, run)
        codec.validate_import_history(db, execution, binding, run)
        codec.ordinary_repair(db, execution, binding, run)
        generated = codec.ordinary_generation(db, execution, binding, run, go_paths, sorted(present))
        for path, expected in generated.items():
            assert sha(git('show', run['candidate_sha'] + ':' + path)) == expected
        effective = sorted(set(output['changed_paths']) | set(generated))
        committed = git('diff', '--name-only', '--no-renames', proof['source_parent_sha'], run['candidate_sha']).decode().splitlines()
        assert sorted(committed) == effective
        codec.worker_history(db, execution)
        codec.generated_only_commits(db, execution, binding, run)
        for key in ('helper', 'companion', 'history_program'):
            path, expected = execution[key + '_path'], execution[key + '_sha256']
            assert os.path.realpath(path) == path and Path(path).is_file() and sha(Path(path).read_bytes()) == expected
        assert db.total_changes == 0
        if captured is None:
            captured = run
        else:
            assert run == captured

print(json.dumps({
    'result': 'PASS', 'manifest_sha256': expected_manifest,
    'history_sha256': sha(raw), 'current_candidate_sha': run['candidate_sha'],
    'current_repair_preparation_retirement_import_worker_and_generation_valid': True,
    'exact_parent_committed_paths_and_generated_blob_hashes_valid': True,
    'genuine_owned_stdin_open': True, 'read_only_sqlite_reopens': 2,
    'current_raw_run_unchanged': True, 'live_ledger_writes': 0,
    'pushes': 0, 'native_chats': 0, 'native_model_turns': 0,
    'limitation': 'Current publication validation only; no producer authorize/execute/main, retirement, push or delivery.'
}, sort_keys=True))
