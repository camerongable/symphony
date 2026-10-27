"""Authenticate completed historical authority; never invoke issuance or a producer."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import types


def main():
    assert len(sys.argv) == 4
    manifest_path, expected_manifest, evidence_path = sys.argv[1:]
    manifest_path, evidence_path = Path(manifest_path), Path(evidence_path)
    assert manifest_path.is_absolute() and evidence_path.is_absolute() and not evidence_path.exists()
    # Import only the sibling source whose bytes the accepted artifact attests.
    import hashlib
    raw_manifest = manifest_path.read_bytes()
    assert hashlib.sha256(raw_manifest).hexdigest() == expected_manifest
    manifest = json.loads(raw_manifest)
    source = Path(manifest['source_root'])
    helper_path = source / 'plans/rollout/review_ready_cutover.py'
    assert helper_path == Path(__file__).resolve().with_name('review_ready_cutover.py')
    assert hashlib.sha256(helper_path.read_bytes()).hexdigest() == manifest['source_hashes']['plans/rollout/review_ready_cutover.py']
    spec = importlib.util.spec_from_file_location('ready_historical_audit', helper_path)
    tools = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tools)
    assert manifest['kind'] == 'FACTORY_REVIEW_REPORT_RELEASE_V1' and manifest['schema_version'] == 54
    assert manifest['previous_manifest_sha256'] == tools.OLD_MANIFEST
    assert tools.inventory(Path(manifest['build']), artifact_source=source) == manifest['artifact']
    assert tools.inventory(source, True) == manifest['source']
    local = Path(manifest['build']) / 'lib/symphony_elixir/priv'
    history_path = local / 'ticket_push_history_validator_v26.py'
    history_raw = history_path.read_bytes()
    assert tools.digest(history_raw) == manifest['artifact']['lib/symphony_elixir/priv/'+history_path.name]['sha256']
    codec = types.ModuleType('ready_historical_publication')
    codec.__file__ = str(history_path)
    exec(compile(history_raw, str(history_path), 'exec', dont_inherit=True), codec.__dict__)
    captured = None
    for _ in range(2):
        with tools.read_only(tools.DB) as db:
            tools.validate_ticket(db)
            before = tools.snapshot(db)
            current = dict(db.execute('SELECT * FROM runs WHERE run_id=?', (tools.RUN,)).fetchone())
            intent = codec.decode_push_envelope(current['candidate_handoff'])
            binding = codec.decode(intent['binding_json'])
            execution = codec.decode_push_execution(intent['execution_json'])
            qualifier = binding['verified_ci_rollover']
            assert qualifier == execution['verified_ci_rollover']
            assert set(qualifier) == codec.ROLLOVER_KEYS
            assert type(qualifier['version']) is int and qualifier['version'] == 1
            assert qualifier['kind'] == 'VERIFIED_CI_ROLLOVER_V1' and qualifier['archived_claim_key'] is None
            assert qualifier['prior_envelope_sha256'] == '579639cb9d9a4e17640886f56dd440f48a92dd5eca53463f48fa027d79da5df3'
            assert qualifier['prior_binding_sha256'] == '63e8a7bdfebf7772715a0545b36bfda0273b724589f9ddf7611da40d595dee0a'
            assert qualifier['prior_receipt_sha256'] == '725511e6682f710bab491c489c15682b1cf60c3b33073f4a857b4baab4041bd1'
            found = db.execute('SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?',
                               (qualifier['prior_reservation_key'], tools.RUN)).fetchall()
            assert len(found) == 1
            access = dict(found[0])
            assert access['mode'] == 'MAINTENANCE' and access['task_key'] is None and access['released_at']
            assert tools.digest(access['release_receipt_json'].encode()) == qualifier['prior_envelope_sha256']
            prior_intent = codec.decode_push_envelope(access['release_receipt_json'])
            assert prior_intent['kind'] == 'TICKET_PUSH' and prior_intent['phase'] == 'COMPLETED'
            original = codec.decode(prior_intent['binding_json'])
            performed = codec.decode_push_execution(prior_intent['execution_json'])
            receipt = codec.decode_push_receipt(prior_intent['receipt_json'], prior_intent['execution_json'])
            assert original['state'] == 'CI_PUSHING' and 'verified_ci_rollover' not in original and 'verified_ci_rollover' not in performed
            assert tools.digest(prior_intent['binding_json'].encode()) == prior_intent['binding_sha256'] == qualifier['prior_binding_sha256']
            assert tools.digest(prior_intent['receipt_json'].encode()) == prior_intent['receipt_sha256'] == qualifier['prior_receipt_sha256']
            assert prior_intent['reservation_key'] == access['reservation_key'] == 'ticket-push:'+prior_intent['binding_sha256']
            assert type(prior_intent['reservation_generation']) is int and prior_intent['reservation_generation'] == access['generation']
            assert prior_intent['remote_sha'] == current['candidate_sha'] and receipt['execution_json'] == prior_intent['execution_json']
            assert original['verifier_round']+1 == current['verifier_round']
            for key in ('run_id', 'issue_key', 'repo_path', 'worktree', 'branch', 'base_branch', 'candidate_sha', 'spec_revision', 'contract_sha256', 'code_repair_round'):
                assert original[key] == current[key]
            assert original['origin'] == binding['origin'] and original['checkout'] == binding['checkout']
            assert original['ordinary_verifier_repair'] == binding['ordinary_verifier_repair']
            historical = dict(current)
            for key in ('run_id', 'issue_key', 'repo_path', 'worktree', 'branch', 'base_branch', 'candidate_sha', 'contract_sha256', 'spec_revision', 'verifier_round', 'state', 'code_repair_round'):
                historical[key] = original[key]
            historical['candidate_handoff'] = access['release_receipt_json']
            ordinary = original['ordinary_verifier_repair']
            parent = ordinary['source_parent_sha']
            assert parent == ordinary['reviewed_candidate_sha'] == '4e5c48fc2150515c4cb5ce0771f4c204b10c532c'
            root = original['worktree']
            assert os.path.realpath(root) == root
            env = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin', 'HOME': os.path.expanduser('~'),
                   'GIT_NO_LAZY_FETCH': '1', 'GIT_NO_REPLACE_OBJECTS': '1', 'GIT_OPTIONAL_LOCKS': '0',
                   'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}

            def git(*args):
                return subprocess.check_output(['/opt/homebrew/bin/git', '--no-optional-locks',
                                                '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
                                                '-c', 'gc.auto=0', '-C', root, *args],
                                               env=env, stdin=subprocess.DEVNULL, timeout=30)

            head_before = git('rev-parse', 'HEAD')
            branch_before = git('symbolic-ref', 'HEAD')
            codec.validate_physical_predecessor(db, historical, prior_intent, original['checkout'], original['origin'])
            git('merge-base', '--is-ancestor', parent, tools.CANDIDATE)
            committed = git('diff', '--name-only', '--no-renames', parent, tools.CANDIDATE).decode().splitlines()
            go_paths = sorted(path for path in committed if path.endswith('.go'))
            assert len(go_paths) == 6
            present = sorted(git('ls-tree', '-r', '--name-only', tools.CANDIDATE, '--', *go_paths).decode().splitlines())
            generated = codec.ordinary_generation(db, performed, original, historical, go_paths, present)
            worker = dict(db.execute('SELECT * FROM worker_evidence WHERE request_key=?', (ordinary['writer_request_key'],)).fetchone())
            assert worker['status'] == 'CONSUMED' and tools.digest(worker['output_json'].encode()) == worker['output_sha256']
            output = codec.decode(worker['output_json'])
            assert sorted(set(output['changed_paths']) | set(generated)) == sorted(committed)
            for path, digest in generated.items():
                assert tools.digest(git('show', tools.CANDIDATE+':'+path)) == digest
            verifier = codec.rollover_verifier(db, binding, current, qualifier)
            codec.rollover_ci_evidence(current, qualifier)
            assert codec.utc(access['released_at']) <= codec.utc(verifier['owner_stopped_at'])
            assert git('rev-parse', 'HEAD') == head_before and git('symbolic-ref', 'HEAD') == branch_before
            tools.preserve(db, before)
            tools.validate_ticket(db)
            assert db.total_changes == 0
            capture = (current, access, before, head_before, branch_before)
            if captured is None:
                captured = capture
            else:
                assert capture == captured
    result = {'kind': 'READY_COMPLETED_HISTORY_PROOF_V1', 'result': 'PASS',
              'manifest_sha256': expected_manifest, 'source_commit': manifest['source_commit'],
              'run_id': tools.RUN, 'current_candidate_sha': tools.CANDIDATE,
              'envelope_sha256': tools.TICKET['envelope_sha256'],
              'receipt_sha256': tools.TICKET['receipt_sha256'], 'receipt_bytes': tools.TICKET['receipt_bytes'],
              'history_sha256': tools.digest(history_raw), 'read_only_sqlite_reopens': 2,
              'artifact_placeholder': tools.phoenix_placeholder(Path(manifest['build']), source),
              'full_physical_predecessor': True, 'retained_generation_authority': True,
              'recorded_git_diff_paths_and_generated_blobs': True, 'historical_rollover_verifier_and_ci': True,
              'entire_run_access_and_history_unchanged': True, 'human_head_unchanged': True,
              'issuance_freshness': 'NOT_RERUN_HISTORICAL_READ_ONLY', 'live_ledger_writes': 0,
              'pushes': 0, 'native_chats': 0, 'native_model_turns': 0,
              'limitation': 'Historical factory candidate only; current human branch CI/delivery is not qualified.'}
    with evidence_path.open('xb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(tools.encode(result))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
