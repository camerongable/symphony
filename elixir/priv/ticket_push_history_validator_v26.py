"""Physical validation of immutable worker lineage, including dedicated CI evidence successors."""
import datetime
import base64
import binascii
import hashlib
import json
import math
import os
import stat
import re
import pathlib
import types
import subprocess

GENERATED_ONLY_HELPER_SHA = 'bda020cc533f3aded80cb843637ff87ba5fd5c1b83bc592b7411cc37fb7b15a6'
GENERATION_ORIGINS_SHA = '64d28fa7b6dd58e5f6a8bd6f6b0acf2afb1945bdb9c8ee2fc5a53743e75fbf82'


HISTORY_PROGRAMS = {
    'ticket_push_executor_v6.py': 'ticket_push_history_validator_v3.py',
    'ticket_push_executor_v7.py': 'ticket_push_history_validator_v4.py',
    'ticket_push_executor_v8.py': 'ticket_push_history_validator_v5.py',
    'ticket_push_executor_v9.py': 'ticket_push_history_validator_v6.py',
    'ticket_push_executor_v10.py': 'ticket_push_history_validator_v7.py',
    'ticket_push_executor_v11.py': 'ticket_push_history_validator_v8.py',
    'ticket_push_executor_v12.py': 'ticket_push_history_validator_v9.py',
    'ticket_push_executor_v13.py': 'ticket_push_history_validator_v10.py',
    'ticket_push_executor_v14.py': 'ticket_push_history_validator_v11.py',
    'ticket_push_executor_v15.py': 'ticket_push_history_validator_v12.py',
    'ticket_push_executor_v16.py': 'ticket_push_history_validator_v13.py',
    'ticket_push_executor_v17.py': 'ticket_push_history_validator_v14.py',
    'ticket_push_executor_v18.py': 'ticket_push_history_validator_v15.py',
    'ticket_push_executor_v19.py': 'ticket_push_history_validator_v16.py',
    'ticket_push_executor_v20.py': 'ticket_push_history_validator_v17.py',
    'ticket_push_executor_v21.py': 'ticket_push_history_validator_v18.py',
    'ticket_push_executor_v22.py': 'ticket_push_history_validator_v18.py',
    'ticket_push_executor_v23.py': 'ticket_push_history_validator_v19.py',
    'ticket_push_executor_v24.py': 'ticket_push_history_validator_v19.py',
    'ticket_push_executor_v25.py': 'ticket_push_history_validator_v20.py',
    'ticket_push_executor_v26.py': 'ticket_push_history_validator_v20.py',
    'ticket_push_executor_v27.py': 'ticket_push_history_validator_v21.py',
    'ticket_push_executor_v28.py': 'ticket_push_history_validator_v21.py',
    'ticket_push_executor_v29.py': 'ticket_push_history_validator_v22.py',
    'ticket_push_executor_v30.py': 'ticket_push_history_validator_v22.py',
    'ticket_push_executor_v31.py': 'ticket_push_history_validator_v23.py',
    'ticket_push_executor_v32.py': 'ticket_push_history_validator_v23.py',
    'ticket_push_executor_v33.py': 'ticket_push_history_validator_v24.py',
    'ticket_push_executor_v34.py': 'ticket_push_history_validator_v24.py',
    'ticket_push_executor_v35.py': 'ticket_push_history_validator_v25.py',
    'ticket_push_executor_v36.py': 'ticket_push_history_validator_v25.py',
    'ticket_push_executor_v37.py': 'ticket_push_history_validator_v26.py',
    'ticket_push_executor_v38.py': 'ticket_push_history_validator_v26.py',
}
ORDINARY_PROGRAMS = frozenset(HISTORY_PROGRAMS) - {'ticket_push_executor_v6.py', 'ticket_push_executor_v7.py', 'ticket_push_executor_v8.py'}
LARGE_PROGRAMS = ORDINARY_PROGRAMS - {'ticket_push_executor_v9.py', 'ticket_push_executor_v10.py', 'ticket_push_executor_v11.py'}


def history_program_name(execution):
    name = os.path.basename(execution['helper_path'])
    require(name in HISTORY_PROGRAMS)
    return HISTORY_PROGRAMS[name]


def generated_only_commits(connection, execution, binding, run, read_git=None, read_blob=None):
    """Validate the immutable journal prefix and its exact controller child commits."""
    local = pathlib.Path(__file__).resolve().parent
    if read_git is None:
        read_git = lambda root,args,performed:_generated_git(root,args,performed,16384).decode().strip()
        read_blob = lambda root,candidate,path,performed:_generated_git(root,['show',candidate+':'+path],performed,262144)
    path = local / 'controller_generation_executor_v3.py'
    raw = path.read_bytes()
    require(sha(raw) == GENERATED_ONLY_HELPER_SHA and os.path.realpath(path) == str(path) and stat.S_ISREG(path.lstat().st_mode))
    validator = types.ModuleType('generated_only_authority')
    validator.__file__ = str(path)
    exec(compile(raw, str(path), 'exec', dont_inherit=True, optimize=0), validator.__dict__)
    journal = rows(connection,"SELECT i.* FROM ticket_ci_generation_intents i JOIN ticket_ci_repair_claims c ON c.claim_key=i.claim_key WHERE i.run_id=? AND c.round<=? AND json_extract(i.binding_json,'$.kind')='CONTROLLER_CI_GENERATED_ONLY' ORDER BY i.intent_key",(run['run_id'],run['code_repair_round']))
    require(len(journal) <= 10)
    history = execution['worker_history']
    names = ('generated_only_intents_json','generated_only_events_json')
    if not all(name in history for name in names):
        require(not journal and not any(name in history for name in names) and os.path.basename(execution['helper_path']) not in ('ticket_push_executor_v11.py','ticket_push_executor_v12.py','ticket_push_executor_v13.py','ticket_push_executor_v14.py','ticket_push_executor_v15.py','ticket_push_executor_v16.py','ticket_push_executor_v17.py','ticket_push_executor_v18.py','ticket_push_executor_v19.py','ticket_push_executor_v20.py','ticket_push_executor_v21.py','ticket_push_executor_v22.py','ticket_push_executor_v23.py','ticket_push_executor_v24.py','ticket_push_executor_v25.py','ticket_push_executor_v26.py','ticket_push_executor_v27.py','ticket_push_executor_v28.py','ticket_push_executor_v29.py','ticket_push_executor_v30.py','ticket_push_executor_v31.py','ticket_push_executor_v32.py','ticket_push_executor_v33.py','ticket_push_executor_v34.py','ticket_push_executor_v35.py','ticket_push_executor_v36.py','ticket_push_executor_v37.py','ticket_push_executor_v38.py'))
        return
    captured_intents, captured_events = (decode(history[name]) for name in names)
    require(type(captured_intents) is list and len(captured_intents) <= 10 and type(captured_events) is list and len(captured_events) <= 4096)
    compacted = [{key:sha(value.encode()) if key=='binding_json' else value for key,value in row.items()} for row in journal]
    require(captured_intents == compacted)
    all_events = []
    for intent in journal:
        require(sha(intent['binding_json'].encode()) == intent['binding_sha256'])
        saved = decode(intent['binding_json'])
        capability = validator.validate_intent(connection,intent,saved)
        events = rows(connection,'SELECT * FROM ticket_ci_generation_events WHERE intent_key=? ORDER BY event_key',(intent['intent_key'],))
        require(len(events) <= 256 and all(sha(event['receipt_json'].encode()) == event['receipt_sha256'] for event in events))
        require(not any(event['event_type'] in ('UNCERTAIN','BLOCKED') for event in events))
        all_events.extend(events)
        values = {(event['event_type'],event['path']):decode(event['receipt_json']) for event in events}
        require(len(values) == len(events))
        finalized = values[('FINALIZED','')]
        changed = finalized['changed_paths']
        require(type(changed) is list and 1 <= len(changed) <= len(capability['generated_paths']) and changed == sorted(set(changed)) and set(changed) <= set(capability['generated_paths']))
        execution_event = next(event for event in events if event['event_type']=='EXECUTION_RECEIPT' and event['path']=='')
        require(finalized['version'] == 1 and finalized['execution_sha256'] == execution_event['receipt_sha256'])
        generation_session(intent,values,'',values[('EXECUTION_RECEIPT','')],saved['run_preimage'],local,saved['toolset'],True)
        require(values[('EXECUTION_RECEIPT','')]['kind'] == 'CONTROLLER_GENERATION_EXECUTED')
        require({event['path'] for event in events if event['event_type']=='APPLIED'} == set(changed))
        expected = {}
        for generated in changed:
            applied = values[('APPLIED',generated)]
            generation_session(intent,values,generated,applied,saved['run_preimage'],local,saved['toolset'],True)
            proposal = values[('APPLY_PREPARED',generated)]['proposal']
            before = next(value for value in capability['build_inputs'] if value['path']==generated)
            require(proposal['path']==generated and proposal['before_sha256']==before['sha256'] and sha(proposal['content'].encode())==proposal['after_sha256'])
            require(applied['kind']=='CONTROLLER_GENERATION_APPLIED' and applied['result']=={'path':generated,'sha256':proposal['after_sha256']})
            expected[generated] = proposal['after_sha256']
        parent = capability['failed_candidate_sha']
        descendants = read_git(run['worktree'],['rev-list','--reverse','--ancestry-path',parent+'..'+binding['candidate_sha']],execution).splitlines()
        require(1 <= len(descendants) <= 1024 and all(hex_digest(value,40) for value in descendants))
        child = descendants[0]
        require(read_git(run['worktree'],['show','-s','--format=%P',child],execution) == parent)
        require(read_git(run['worktree'],['diff','--name-only','--no-renames',parent,child],execution).splitlines() == changed)
        worker = rows(connection,'SELECT output_json FROM worker_evidence WHERE request_key=?',(intent['request_key'],))
        require(len(worker)==1)
        output = decode(worker[0]['output_json'])
        message = output['commit_message'] or 'fix('+saved['run_preimage']['issue_key']+'): repair generated CI inputs'
        require(read_git(run['worktree'],['show','-s','--format=%B',child],execution) == message.strip())
        for value in capability['go_inputs'] + capability['build_inputs']:
            blob = read_blob(run['worktree'],parent,value['path'],execution)
            require(sha(blob)==value['sha256'] and hashlib.sha1(b'blob '+str(len(blob)).encode()+b'\0'+blob).hexdigest()==value['git_blob_sha'])
            tree = read_git(run['worktree'],['ls-tree',parent,'--',value['path']],execution)
            require(tree == value['mode']+' blob '+value['git_blob_sha']+'\t'+value['path'])
        for value in capability['go_inputs']:
            require(sha(read_blob(run['worktree'],child,value['path'],execution))==value['sha256'])
        for value in capability['build_inputs']:
            package = os.path.dirname(value['path'])
            siblings = read_git(run['worktree'],['ls-tree','--name-only',parent,'--',package+'/BUILD',package+'/BUILD.bazel'],execution).splitlines()
            require(siblings == [value['path']])
            require(sha(read_blob(run['worktree'],child,value['path'],execution))==expected.get(value['path'],value['sha256']))
    all_events.sort(key=lambda value:value['event_key'])
    compacted_events = [{key:sha(value.encode()) if key=='receipt_json' else value for key,value in row.items()} for row in all_events]
    require(captured_events == compacted_events)


def _generated_git(root, args, execution, limit):
    command = [CHECK_GIT,'--no-lazy-fetch','--no-replace-objects','-C',root,'-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-c','gc.auto=0']+args
    result = subprocess.run(command,env=execution['git_environment'],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=3,check=True)
    require(len(result.stdout)<=limit)
    return result.stdout


def validate_prepared_requalification(connection, execution, binding, run):
    reference=binding.get('prepared_requalification')
    if reference is None:
        require(connection.execute('SELECT 1 FROM ticket_push_prepared_requalifications WHERE run_id=? AND (original_nonce=? OR successor_nonce=?) LIMIT 1',(run['run_id'],execution['invocation'],execution['invocation'])).fetchone() is None)
        return
    require(type(reference) is dict and set(reference)=={'authorization_key','original_sha256','attempt'} and type(reference['attempt']) is int and reference['attempt']==1)
    require(type(reference['authorization_key']) is str and 1<=len(reference['authorization_key'].encode())<=256 and hex_digest(reference['original_sha256']))
    captured=rows(connection,'SELECT * FROM ticket_push_prepared_requalifications WHERE authorization_key=? AND run_id=?',(reference['authorization_key'],run['run_id']))
    require(len(captured)==1); row=captured[0]
    fields=set('authorization_key run_id original_nonce original_envelope original_sha256 authorization_json authorization_sha256 proof_json proof_sha256 successor_nonce successor_binding_json successor_binding_sha256 successor_reservation_key created_at'.split())
    require(set(row)==fields and all(type(value) is str for value in row.values()) and reference['original_sha256']==row['original_sha256'])
    require(len(canonical(row))<=8_388_608)
    for raw,expected in (('original_envelope','original_sha256'),('authorization_json','authorization_sha256'),('proof_json','proof_sha256'),('successor_binding_json','successor_binding_sha256')):
        require(sha(row[raw].encode())==row[expected])
    original=decode(row['original_envelope']); authorization=decode(row['authorization_json']); proof=decode(row['proof_json']); fresh=decode(row['successor_binding_json'],1_048_576)
    require(type(original) is dict and set(original)==set('version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json receipt_json receipt_sha256 remote_sha'.split()))
    require(type(original['version']) is int and original['version']==1 and original['kind']=='TICKET_PUSH' and original['phase']=='PREPARED' and all(original[key] is None for key in ('helper_pid','execution_json','receipt_json','receipt_sha256','remote_sha')))
    require(type(original['reservation_generation']) is int and original['reservation_generation']>0)
    require(hex_digest(original['owner_nonce']) and original['owner_nonce']==row['original_nonce'] and hex_digest(row['successor_nonce']) and row['successor_nonce']!=row['original_nonce'])
    require(sha(original['binding_json'].encode())==original['binding_sha256'] and original['reservation_key']=='ticket-push:'+original['binding_sha256'])
    previous=decode(original['binding_json'])
    require(set(authorization)==set('run_id original_envelope_sha256 original_nonce candidate_sha spec_revision contract_sha256 authorization_reference maximum_implementation_iterations maximum_code_repair_rounds'.split()))
    require(authorization['run_id']==row['run_id']==run['run_id'] and authorization['original_nonce']==row['original_nonce'] and authorization['original_envelope_sha256']==row['original_sha256'])
    require(type(authorization['authorization_reference']) is str and 1<=len(authorization['authorization_reference'].encode())<=1024)
    require(type(authorization['spec_revision']) is int and authorization['spec_revision']>0 and hex_digest(authorization['candidate_sha'],40) and hex_digest(authorization['contract_sha256']))
    require(all(authorization[key]==fresh[key]==previous[key] for key in ('candidate_sha','spec_revision','contract_sha256')))
    require(type(proof) is dict and set(proof)==set('version kind original_access spool tick configured_limits'.split()) and type(proof['version']) is int and proof['version']==1 and proof['kind']=='NEVER_ISSUED_PREPARED_REQUALIFICATION_V1')
    require(proof['configured_limits']=={key:authorization[key] for key in ('maximum_implementation_iterations','maximum_code_repair_rounds')})
    require(type(authorization['maximum_implementation_iterations']) is int and authorization['maximum_implementation_iterations']>0 and type(authorization['maximum_code_repair_rounds']) is int and 0<=authorization['maximum_code_repair_rounds']<=10)
    require(type(proof['tick']) is dict and set(proof['tick'])=={'dispatcher_id','generation','scope','tick_id'} and type(proof['tick']['generation']) is int and proof['tick']['generation']>0)
    require(all(type(proof['tick'][key]) is str and 1<=len(proof['tick'][key].encode())<=1024 for key in ('dispatcher_id','scope','tick_id')))
    require(fresh['prepared_requalification']==reference and row['successor_reservation_key']=='ticket-push:'+row['successor_binding_sha256'])
    require({key:value for key,value in previous.items() if key!='ci_repair_policy_receipt'}=={key:value for key,value in fresh.items() if key not in ('ci_repair_policy_receipt','prepared_requalification')})
    old_policy,new_policy=previous.get('ci_repair_policy_receipt'),fresh.get('ci_repair_policy_receipt')
    if old_policy is None:require(new_policy is None)
    else:
        mutable={'workflow_sha256','workflow_stat','cached_policy_sha256'}
        require(type(old_policy) is dict and type(new_policy) is dict and {key:value for key,value in old_policy.items() if key not in mutable}=={key:value for key,value in new_policy.items() if key not in mutable})
        require(new_policy['configured_limit']==authorization['maximum_code_repair_rounds'])
    old_access=rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(original['reservation_key'],))
    require(len(old_access)==1); old_access=old_access[0]
    saved=proof['original_access']
    require(type(saved) is dict and saved['released_at'] is None and saved['release_receipt_json'] is None and {key:value for key,value in saved.items() if key not in ('released_at','release_receipt_json')}=={key:value for key,value in old_access.items() if key not in ('released_at','release_receipt_json')})
    require(old_access['released_at'] is not None and old_access['release_receipt_json']==row['proof_json'] and old_access['mode']=='MAINTENANCE' and old_access['task_key'] is None and old_access['run_id']==row['run_id'] and old_access['generation']==original['reservation_generation'] and old_access['request_key']==original['reservation_key'])
    new_access=rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(row['successor_reservation_key'],))
    require(len(new_access)==1); new_access=new_access[0]
    require(new_access['mode']=='MAINTENANCE' and new_access['task_key'] is None and new_access['run_id']==row['run_id'] and new_access['request_key']==row['successor_reservation_key'] and new_access['generation']>old_access['generation'])
    require(all(new_access[key]==old_access[key] for key in ('canonical_path','git_dir','common_dir')))
    historical_execution=None
    if execution['invocation']==row['successor_nonce']:
        require(execution['intent_json']==row['successor_binding_json'] and execution['intent_sha256']==row['successor_binding_sha256'] and binding==fresh)
    else:
        retirements=rows(connection,'SELECT * FROM ticket_push_rejection_retirements WHERE run_id=? AND original_nonce=?',(row['run_id'],row['successor_nonce']))
        if retirements:
            require(len(retirements)==1)
            retired=retirements[0]; original_child=decode(retired['original_envelope'],12_582_912)
            require(type(original_child) is dict and original_child['phase']=='PUSH_UNCERTAIN' and all(original_child[key] is None for key in ('receipt_json','receipt_sha256','remote_sha')))
            historical_execution=decode_push_execution(original_child['execution_json'])
            require(original_child['owner_nonce']==row['successor_nonce'] and original_child['binding_json']==row['successor_binding_json'] and original_child['binding_sha256']==row['successor_binding_sha256'] and original_child['reservation_key']==row['successor_reservation_key'])
            require(sha(retired['original_envelope'].encode())==retired['original_sha256'] and new_access['released_at'] is not None and new_access['release_receipt_json']==retired['proof_json'])
            expected=dict(fresh,preissuance_retirement={'retirement_key':retired['retirement_key'],'original_sha256':retired['original_sha256'],'attempt':1})
            if execution['invocation']==retired['successor_nonce']:
                require(binding==expected and execution['intent_sha256']==retired['successor_binding_sha256'])
                validate_preissuance_retirement(connection,execution,binding,run)
            else:
                require(binding['verified_ci_rollover']['prior_binding_sha256']==retired['successor_binding_sha256'])
                validate_retirement_audit(retired,original_child,decode(retired['proof_json']),fresh,run)
                access=rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(retired['successor_reservation_key'],))
                require(len(access)==1 and access[0]['released_at'] is not None)
                completed=decode_push_envelope(access[0]['release_receipt_json'])
                require(completed['phase']=='COMPLETED' and completed['owner_nonce']==retired['successor_nonce'] and completed['binding_sha256']==retired['successor_binding_sha256'] and sha(completed['binding_json'].encode())==retired['successor_binding_sha256'] and decode(completed['binding_json'])==expected)
        else:
            require(binding['verified_ci_rollover']['prior_binding_sha256']==row['successor_binding_sha256'])
        if 'verified_ci_rollover' in binding:
            require(fresh['state']=='CI_PUSHING' and binding['state']=='PUSHING' and all(binding[key]==fresh[key] for key in ('candidate_sha','spec_revision','contract_sha256','code_repair_round')))
    spool_keys=('database','root','spool','spool_device','spool_inode','companion_path','companion_sha256')
    require(set(proof['spool'])==set(spool_keys))
    require(all(proof['spool'][key]==execution[key] for key in spool_keys if key not in ('companion_path','companion_sha256')))
    recorded={key:proof['spool'][key] for key in ('companion_path','companion_sha256')}
    if recorded!={key:execution[key] for key in recorded}:
        require(historical_execution is not None and recorded=={key:historical_execution[key] for key in recorded})
        push_program_origin(historical_execution,pathlib.Path(__file__).resolve().parent)
    for suffix in ('.push-claim','.push-receipt','.push-rejection'):
        path=os.path.join(execution['spool'],row['original_nonce']+suffix)
        try:os.lstat(path)
        except FileNotFoundError:pass
        else:reject()


def validate_preissuance_retirement(connection, execution, binding, run):
    captured = rows(connection, 'SELECT * FROM ticket_push_rejection_retirements WHERE run_id=? AND candidate_sha=? AND code_repair_round=?', (run['run_id'], run['candidate_sha'], run['code_repair_round']))
    captured = [row for row in captured if all(decode(decode(row['original_envelope'])['binding_json'])[key] == run[key] for key in ('state','spec_revision','verifier_round','contract_sha256'))]
    if not captured:
        require('preissuance_retirement' not in binding)
        return
    require(len(captured) == 1)
    row = captured[0]
    require(binding['preissuance_retirement'] == {'retirement_key':row['retirement_key'],'original_sha256':row['original_sha256'],'attempt':1})
    require(row['original_sha256'] == sha(row['original_envelope'].encode()) and row['proof_sha256'] == sha(row['proof_json'].encode()))
    original, proof = decode(row['original_envelope']), decode(row['proof_json'])
    validate_retirement_audit(row,original,proof,binding,run)
    previous = decode(original['binding_json'])
    previous['preissuance_retirement'] = binding['preissuance_retirement']
    require(previous == binding and original['binding_sha256'] == sha(original['binding_json'].encode()))
    require(row['successor_nonce'] == execution['invocation'])
    require(row['successor_binding_sha256'] == execution['intent_sha256'] == sha(execution['intent_json'].encode()))
    prior_access = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?',(original['reservation_key'],run['run_id']))
    require(len(prior_access) == 1)
    prior_access = prior_access[0]
    require(prior_access['mode'] == 'MAINTENANCE' and prior_access['task_key'] is None and prior_access['generation'] == original['reservation_generation'] and prior_access['released_at'] is not None and prior_access['release_receipt_json'] == row['proof_json'])
    current = decode(connection.execute('SELECT candidate_handoff FROM runs WHERE run_id=?',(run['run_id'],)).fetchone()[0])
    require(current['reservation_key'] == row['successor_reservation_key'] and current['owner_nonce'] == row['successor_nonce'])


ORDINARY_AUDIT_FILES = (
    ('ticket_push_ordinary_rejection_v1.json','26bd05340fb03f21fb12506dc7b752cedfd33075b4d43995c7acb70ca6287d66'),
    ('ticket_push_ordinary_rejection_v2.json','830643e88f8c107a79c688444c78476a8e20d8c190d0d682e3aa19b96e38de2e'),
    ('ticket_push_ordinary_rejection_v3.json','57094189e04dbee26f6a316dac2d5f2b62cc4eb247016c39c69498932e14fa59'),
    ('ticket_push_ordinary_rejection_v4.json','dfc045f0753fa7d7ddaa3ddd28bbfe0c00031391bef216903a75c0c48314101f'),
)


def validate_ordinary_preissuance_retirement(connection, execution, binding, run, historical=False):
    captured = rows(connection, "SELECT id,payload_json FROM events WHERE run_id=? AND event_type='TICKET_ORDINARY_PUSH_REJECTION_RETIRED' ORDER BY id", (run['run_id'],))
    if not captured:
        require('ordinary_preissuance_retirement' not in binding)
        return
    require(1 <= len(captured) <= len(ORDINARY_AUDIT_FILES))
    identities = []
    contexts = []
    for row in captured:
        value = decode(row['payload_json'], 1_048_576)
        original = decode(value['original_envelope'], 1_048_576)
        previous = decode(original['binding_json'], 1_048_576)
        recorded_binding = dict(previous)
        recorded_binding['ordinary_preissuance_retirement'] = ordinary_retirement_identity(row, value)
        validate_ordinary_retirement_record(connection, execution, recorded_binding, run, row,
                                            captured[:len(identities)+1], True, lineage_only=True)
        identities.append(ordinary_retirement_identity(row, value))
        contexts.append(previous)
    ref = binding.get('ordinary_preissuance_retirement')
    if ref is None:
        context = binding if historical else run
        require(all(any(previous[key] != context[key] for key in ('state','candidate_sha','code_repair_round','verifier_round','spec_revision','contract_sha256')) for previous in contexts))
        for row, previous, identity in zip(captured, contexts, identities):
            recorded_binding = dict(previous); recorded_binding['ordinary_preissuance_retirement'] = identity
            validate_ordinary_retirement_record(connection, execution, recorded_binding, run, row, captured, True, lineage_only=True)
        return
    selected = [row for row, identity in zip(captured, identities) if identity == ref]
    require(len(selected) == 1 and (historical or selected[0] == captured[-1]))
    if not historical:
        require(all(binding[key] == run[key] for key in ('state','candidate_sha','code_repair_round','verifier_round','spec_revision','contract_sha256')))
    validate_ordinary_retirement_record(connection, execution, binding, run, selected[0], captured, historical)


def ordinary_retirement_identity(row, value):
    return {'event_id':row['id'], 'event_sha256':sha(row['payload_json'].encode()), 'retirement_key':value['retirement_key'], 'original_sha256':value['original_sha256'], 'attempt':1}


def validate_ordinary_retirement_record(connection, execution, binding, run, row, captured, historical, lineage_only=False):
    require(type(row['payload_json']) is str and len(row['payload_json'].encode()) <= 1_048_576)
    value = decode(row['payload_json'], 1_048_576)
    resources = ORDINARY_AUDIT_FILES
    audits = []
    for name, expected in resources:
        raw = pathlib.Path(__file__).resolve().with_name(name).read_bytes()
        require(sha(raw) == expected)
        audits.append((raw, decode(raw.decode())))
    matching = [(raw, audit) for raw, audit in audits if value['original_sha256'] == audit['original_sha256']]
    require(len(matching) == 1)
    audit_raw, audit = matching[0]
    require(value['original_sha256'] == audit['original_sha256'] == sha(value['original_envelope'].encode()))
    original = decode(value['original_envelope'], 1_048_576)
    previous = decode(original['binding_json'], 1_048_576)
    require(value['version'] == 1 and value['kind'] == 'ORDINARY_PUSH_REJECTION_RETIREMENT_V1' and value['run_id'] == run['run_id'] == audit['run_id'])
    ref = ordinary_retirement_identity(row, value)
    require(binding['ordinary_preissuance_retirement'] == ref)
    require(original['phase'] == 'PUSH_UNCERTAIN' and original['owner_nonce'] == value['original_nonce'] == audit['original_nonce'] and original['helper_pid'] == audit['helper_pid'])
    require(all(original[key] is None for key in ('receipt_json','receipt_sha256','remote_sha')))
    require(sha(original['execution_json'].encode()) == audit['execution_sha256'])
    require(sha(original['binding_json'].encode()) == original['binding_sha256'])
    expected_binding = dict(previous); expected_binding['ordinary_preissuance_retirement'] = ref
    require(expected_binding == binding and previous.get('ordinary_preissuance_retirement') == audit.get('prior_retirement_ref'))
    prefix = [prior for prior in captured if prior['id'] < row['id']]
    if 'closed_prior_retirements' in audit:
        count = {(3,'AUDITED_V24_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED'):2,
                 (4,'AUDITED_V34_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED'):3}.get((audit['version'],audit['kind']))
        require(count is not None and audit.get('prior_retirement_ref') is None and len(prefix) == count)
        require([ordinary_retirement_identity(prior, decode(prior['payload_json'],1_048_576)) for prior in prefix] == audit['closed_prior_retirements'])
        fields = ('state','candidate_sha','code_repair_round','verifier_round','spec_revision','contract_sha256')
        require(type(audit.get('current_context')) is dict and set(audit['current_context']) == set(fields))
        require({key:previous[key] for key in fields} == audit['current_context'])
        for prior in prefix:
            prior_value = decode(prior['payload_json'],1_048_576)
            prior_original = decode(prior_value['original_envelope'],1_048_576)
            prior_binding = decode(prior_original['binding_json'],1_048_576)
            require(any(prior_binding[key] != previous[key] for key in fields))
            prior_binding['ordinary_preissuance_retirement'] = ordinary_retirement_identity(prior, prior_value)
            validate_ordinary_retirement_record(connection, execution, prior_binding, run, prior, prefix, True, lineage_only=True)
    elif audit.get('prior_retirement_ref') is None:
        require(not prefix)
    else:
        require(len(prefix) == 1)
        prior_value = decode(prefix[0]['payload_json'], 1_048_576)
        require(ordinary_retirement_identity(prefix[0], prior_value) == audit['prior_retirement_ref'])
        validate_ordinary_retirement_record(connection, decode(original['execution_json'], 1_048_576), previous, run, prefix[0], prefix, True)
    require('ci_repair' not in previous and previous['ordinary_verifier_repair']['kind'] == 'ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1')
    require(sha(json.dumps(previous['ordinary_verifier_repair'],separators=(',',':'),ensure_ascii=False).encode()) == audit['ordinary_verifier_repair_sha256'])
    proof = value['proof']
    require(proof['kind'] == audit['kind'] and proof['audit_sha256'] == sha(audit_raw))
    require(sha(proof['rejection_json'].encode()) == proof['rejection_sha256'] == audit['rejection_sha256'])
    require(decode(proof['rejection_json'], 4_194_304) == {'version':1,'kind':'PREISSUANCE_REJECTED','execution_json':original['execution_json'],'helper_pid':original['helper_pid'],'child_pid':None,'reason':audit['reason']})
    require(value['retirement_key'] == 'ordinary-push-rejection:' + sha((value['original_envelope'] + proof['rejection_sha256']).encode()))
    if not lineage_only:
        require(execution['invocation'] == sha((value['retirement_key'] + ':successor:1').encode()))
        require(execution['intent_sha256'] == sha(execution['intent_json'].encode()))
    prior = rows(connection, 'SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?', (original['reservation_key'],run['run_id']))
    require(len(prior) == 1)
    prior = prior[0]
    require(prior['mode'] == 'MAINTENANCE' and prior['task_key'] is None and prior['generation'] == original['reservation_generation'])
    require(prior['released_at'] is not None and prior['release_receipt_json'] == row['payload_json'])
    prior['released_at'] = None; prior['release_receipt_json'] = None
    require(sha(json.dumps(prior,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()) == value['prior_access_sha256'])
    if lineage_only:
        return
    if historical:
        successor = rows(connection, 'SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?', ('ticket-push:' + execution['intent_sha256'],run['run_id']))
        require(len(successor) == 1 and successor[0]['generation'] == original['reservation_generation'] + 1 and successor[0]['mode'] == 'MAINTENANCE')
        return
    current = decode(connection.execute('SELECT candidate_handoff FROM runs WHERE run_id=?',(run['run_id'],)).fetchone()[0], 1_048_576)
    require(current['owner_nonce'] == execution['invocation'] and current['binding_json'] == execution['intent_json'])
    require(current['reservation_key'] == 'ticket-push:' + execution['intent_sha256'] and current['reservation_generation'] == original['reservation_generation'] + 1)


def validate_retirement_audit(row,original,proof,binding,run):
    resources = {'AUDITED_V3_PREISSUANCE_AUTHORITY_CLOSED': ('ticket_push_rejection_v1.json','795c9d4f35e1769f9f76e7ba8d5d0f82d53df34a38fdb47771509356c9a8c3bc'), 'AUDITED_V7_PREISSUANCE_AUTHORITY_CLOSED': ('ticket_push_rejection_v2.json','e90c8da94324c78b8f7488fa6997ac8725b45f62cbf34be617cf9052e1fef135'), 'AUDITED_V12_PREISSUANCE_AUTHORITY_CLOSED': ('ticket_push_rejection_v3.json','19e60bc3692adf92333f8508ef8fa122a4be8b91c3551660a4d839312924a171')}
    name, expected = resources[proof['kind']]
    raw = pathlib.Path(__file__).resolve().with_name(name).read_bytes()
    require(sha(raw) == expected == proof['audit_sha256'])
    audit = decode(raw.decode())
    require(all(row[key] == audit[key] for key in ('run_id','candidate_sha','code_repair_round','original_nonce','original_sha256')))
    require(audit['contract_sha256'] == run['contract_sha256'] and row['claim_key'] == binding['ci_repair']['claim_key'])
    require(original['phase'] == 'PUSH_UNCERTAIN' and original['owner_nonce'] == row['original_nonce'] and original['helper_pid'] == audit['helper_pid'])
    require(all(original[key] is None for key in ('receipt_json','receipt_sha256','remote_sha')))
    require(sha(original['execution_json'].encode()) == audit['execution_sha256'])
    rejected = decode(proof['rejection_json'], 4_194_304 if proof['kind']=='AUDITED_V12_PREISSUANCE_AUTHORITY_CLOSED' else 262144)
    require(sha(proof['rejection_json'].encode()) == proof['rejection_sha256'] == audit['rejection_sha256'])
    require(rejected == {'version':1,'kind':'PREISSUANCE_REJECTED','execution_json':original['execution_json'],'helper_pid':original['helper_pid'],'child_pid':None,'reason':audit['reason']})
    require(row['retirement_key'] == 'push-rejection:' + sha((row['original_envelope'] + proof['rejection_sha256']).encode()))
    require(row['successor_nonce'] == sha((row['retirement_key'] + ':successor:1').encode()))
    require(row['successor_reservation_key'] == 'ticket-push:' + row['successor_binding_sha256'])


def validate_import_history(connection, execution, binding, run):
    journal = rows(connection, 'SELECT * FROM ticket_human_empty_commit_imports WHERE run_id=? ORDER BY import_key', (run['run_id'],))
    if not journal:
        require('human_empty_commit_imports' not in binding and 'human_empty_commit_imports' not in execution)
        return
    require(1 <= len(journal) <= 32)
    expected = [{'import_key': row['import_key'], 'proof_sha256': row['proof_sha256']} for row in journal]
    require(binding.get('human_empty_commit_imports') == execution.get('human_empty_commit_imports') == expected)
    observer_path = pathlib.Path(__file__).resolve().with_name('ticket_empty_commit_read.py')
    observer_raw = observer_path.read_bytes()
    require(sha(observer_raw) == 'a9a8d5b72539d3ee3fb458eac0ebcc7d22f155655da6de668752cf45c81adb40')
    require(os.path.commonpath([str(observer_path), run['worktree']]) != run['worktree'])
    observer = types.ModuleType('empty_commit_objects')
    exec(compile(observer_raw, str(observer_path), 'exec'), observer.__dict__)
    for row in journal:
        require(set(row) == set('import_key run_id request_key candidate_sha proof_json proof_sha256 created_at'.split()))
        require(row['proof_sha256'] == sha(row['proof_json'].encode()) and row['import_key'] == 'human-empty-import:' + row['proof_sha256'])
        proof = push_budget_decode(row['proof_json'],'import')
        require(set(proof) == set('version kind prior_run request authorization_reference objects checkout origin mr inputs control history source_checks observed_at'.split()))
        require(type(proof['version']) is int and proof['version'] == 1 and proof['kind'] == 'HUMAN_EMPTY_COMMIT_IMPORT_V1')
        require(type(proof['authorization_reference']) is str and 1 <= len(proof['authorization_reference'].encode()) <= 1024)
        prior = proof['prior_run']
        require(all(prior[key] == run[key] for key in ('run_id', 'issue_key', 'repo_key', 'repo_path', 'worktree', 'branch', 'base_branch')))
        objects = proof['objects']
        require(set(objects) == {'kind', 'previous', 'candidate'} and objects['kind'] == 'EMPTY_CHILD_OBJECTS_V1')
        previous, candidate = objects['previous'], objects['candidate']
        require(previous['sha'] == prior['candidate_sha'] and candidate['sha'] == row['candidate_sha'] and candidate['parents'] == [previous['sha']] and candidate['tree'] == previous['tree'])
        require(hex_digest(previous['sha'],40) and hex_digest(candidate['sha'],40) and hex_digest(candidate['tree'],40))
        require(observer.read_commit(run['worktree'], previous['sha']) == previous)
        require(observer.read_commit(run['worktree'], candidate['sha']) == candidate)
        original = decode_push_envelope(prior['candidate_handoff'])
        validate_physical_predecessor(connection, prior, original, proof['checkout'], proof['origin'])
        require(original['kind'] == 'TICKET_PUSH' and original['phase'] == 'COMPLETED')
        physical, performed, receipt = decode(original['binding_json']), decode_push_execution(original['execution_json']), decode_push_receipt(original['receipt_json'], original['execution_json'])
        require(sha(original['binding_json'].encode()) == original['binding_sha256'] and sha(original['receipt_json'].encode()) == original['receipt_sha256'])
        require(all(physical[key] == prior[key] for key in ('run_id','issue_key','repo_path','worktree','branch','base_branch','candidate_sha','contract_sha256','spec_revision','verifier_round')))
        require(physical['origin'] == proof['origin'] and physical['checkout'] == proof['checkout'])
        require(original['remote_sha'] == previous['sha'] and performed['intent_json'] == original['binding_json'] and performed['intent_sha256'] == original['binding_sha256'] and performed['invocation'] == original['owner_nonce'])
        require(receipt['execution_json'] == original['execution_json'] and receipt['helper_pid'] == original['helper_pid'])
        access = rows(connection, 'SELECT * FROM workspace_access WHERE reservation_key=?', (original['reservation_key'],))
        require(len(access) == 1 and access[0]['run_id'] == run['run_id'] and access[0]['mode'] == 'MAINTENANCE' and access[0]['task_key'] is None and access[0]['released_at'] is not None)
        require(access[0]['release_receipt_json'] == prior['candidate_handoff'] and access[0]['generation'] == original['reservation_generation'])
        require(decode(access[0]['binding_json'])['expected_sha'] == previous['sha'])
        before = proof['request']
        require(before['request_key'] == row['request_key'] and before['status'] == 'PENDING' and before['target_kind'] == 'CONTROLLER')
        for key in 'claimed_at thread_id turn_id target_observation_json verified_cwd verified_project_id verified_head_sha output_json rejected_tool_call_id failure_code superseded_by'.split():
            require(before[key] is None)
        requests = rows(connection, 'SELECT * FROM desktop_requests WHERE request_key=?', (row['request_key'],))
        require(len(requests) == 1)
        current = requests[0]
        require(current['status'] == 'FAILED' and current['failure_code'] == 'SUPERSEDED_BY_' + row['import_key'])
        ignored = {'status', 'failure_code', 'updated_at'}
        require({key: value for key,value in current.items() if key not in ignored} == {key:value for key,value in before.items() if key not in ignored})
        require(not rows(connection,'SELECT request_key FROM ticket_mr_claims WHERE request_key=?',(row['request_key'],)))
        operation = decode(before['metadata_json'])['delivery_operation']
        require(all(operation[key] == prior[key] for key in ('run_id','candidate_sha','contract_sha256','spec_revision')) and operation['completed_push_sha256'] == sha(prior['candidate_handoff'].encode()))
        mr = proof['mr']
        require(mr['sha'] == mr['diff_refs']['head_sha'] == candidate['sha'] and mr['iid'] == prior['mr_iid'] and mr['web_url'] == prior['mr_url'] and mr['project_id'] == operation['gitlab_project_id'])
        require(mr['source_branch'] == prior['branch'] and mr['target_branch'] == prior['base_branch'] and mr['draft'] is True and mr['reviewers'] == [] and mr['state'] == 'opened')
        events = rows(connection,"SELECT payload_json FROM events WHERE run_id=? AND event_type='TICKET_HUMAN_EMPTY_COMMIT_IMPORTED' AND json_extract(payload_json,'$.import_key')=?",(run['run_id'],row['import_key']))
        require(len(events) == 1 and decode(events[0]['payload_json']) == {'import_key':row['import_key'],'prior_candidate_sha':previous['sha'],'candidate_sha':candidate['sha'],'retired_request_key':row['request_key'],'proof_sha256':row['proof_sha256']})


def validate_physical_predecessor(connection, prior, intent, checkout, origin):
    require(type(intent) is dict and set(intent) == set('version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json receipt_json receipt_sha256 remote_sha'.split()))
    require(type(intent['version']) is int and intent['version'] == 1 and intent['kind'] == 'TICKET_PUSH' and intent['phase'] == 'COMPLETED')
    physical, performed, receipt = decode(intent['binding_json']), decode_push_execution(intent['execution_json']), decode_push_receipt(intent['receipt_json'], intent['execution_json'])
    require(sha(intent['binding_json'].encode()) == intent['binding_sha256'] and sha(intent['receipt_json'].encode()) == intent['receipt_sha256'])
    require(intent['reservation_key'] == 'ticket-push:' + intent['binding_sha256'] and hex_digest(intent['owner_nonce']))
    require(type(intent['reservation_generation']) is int and intent['reservation_generation'] > 0)
    require(all(physical[key] == prior[key] for key in ('run_id','issue_key','repo_path','worktree','branch','base_branch','candidate_sha','contract_sha256','spec_revision','verifier_round')))
    require(physical['state'] == 'CI_PUSHING' and physical['origin'] == origin and physical['checkout'] == checkout and intent['remote_sha'] == prior['candidate_sha'])
    access = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?',(intent['reservation_key'],prior['run_id']))
    require(len(access) == 1); access = access[0]
    require(access['request_key'] == access['reservation_key'] == intent['reservation_key'] and access['mode'] == 'MAINTENANCE' and access['task_key'] is None and access['released_at'] is not None and access['release_receipt_json'] == prior['candidate_handoff'])
    require(access['generation'] == intent['reservation_generation'])
    owned = decode(access['binding_json'])
    require(owned['expected_sha'] == physical['candidate_sha'] and owned['run_id'] == prior['run_id'] and owned['reservation_key'] == owned['request_key'] == access['reservation_key'] and owned['mode'] == 'MAINTENANCE' and owned['task_key'] is None)
    require(all(owned[key] == checkout[key] for key in ('path','git_dir','common_dir','root_device','root_inode')))
    require(access['canonical_path'] == prior['worktree'] == checkout['path'] and access['git_dir'] == checkout['git_dir'] and access['common_dir'] == checkout['common_dir'])
    require(all(type(checkout[key]) is int and checkout[key] > 0 for key in ('root_device','root_inode')))
    require(all(performed[key] == value for key,value in {'run_id':prior['run_id'],'intent_json':intent['binding_json'],'intent_sha256':intent['binding_sha256'],'invocation':intent['owner_nonce']}.items()))
    validate_archived_ci_authority(connection, prior, physical, performed)
    local = pathlib.Path(__file__).resolve().parent
    programs = {'ticket_push_executor_v8.py':'4e60c5c0b3d5fdf8c72a775c5b31f7c949ca54d523b24dbbd34fe1c0b896120b','ticket_push_executor_v6.py':'7ca52f7bed65a85a0dfe6c5d585369514c306dc9bc66251aa12e716c00411584','ticket_push_executor_v7.py':'0a508832da9ae8dac08f4a7eabcf7699f9ce395a9355af2b67f8f10da514db2d','ticket_push_executor_v9.py':'a362cc92abe82a14f2ae9f9f21afaa65bce8a47cc88820a4e2e7286b749ccd16','ticket_push_executor_v10.py':sha((local/'ticket_push_executor_v10.py').read_bytes()),'ticket_push_executor_v11.py':sha((local/'ticket_push_executor_v11.py').read_bytes()),'ticket_push_executor_v12.py':sha((local/'ticket_push_executor_v12.py').read_bytes()),'ticket_push_executor_v13.py':sha((local/'ticket_push_executor_v13.py').read_bytes()),'ticket_push_executor_v14.py':sha((local/'ticket_push_executor_v14.py').read_bytes()),'ticket_push_executor_v15.py':sha((local/'ticket_push_executor_v15.py').read_bytes()),'ticket_push_executor_v16.py':sha((local/'ticket_push_executor_v16.py').read_bytes()),'ticket_push_executor_v17.py':sha((local/'ticket_push_executor_v17.py').read_bytes()),'ticket_push_executor_v18.py':sha((local/'ticket_push_executor_v18.py').read_bytes()),'ticket_push_executor_v19.py':sha((local/'ticket_push_executor_v19.py').read_bytes()),'ticket_push_executor_v20.py':sha((local/'ticket_push_executor_v20.py').read_bytes()),'ticket_push_executor_v21.py':sha((local/'ticket_push_executor_v21.py').read_bytes()),'ticket_push_executor_v22.py':sha((local/'ticket_push_executor_v22.py').read_bytes()),'ticket_push_executor_v23.py':sha((local/'ticket_push_executor_v23.py').read_bytes()),'ticket_push_executor_v24.py':sha((local/'ticket_push_executor_v24.py').read_bytes()),'ticket_push_executor_v25.py':sha((local/'ticket_push_executor_v25.py').read_bytes()),'ticket_push_executor_v26.py':sha((local/'ticket_push_executor_v26.py').read_bytes()),'worker_file_companion.py':'87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b','ticket_push_executor_v27.py':sha((local/'ticket_push_executor_v27.py').read_bytes()),'ticket_push_executor_v28.py':sha((local/'ticket_push_executor_v28.py').read_bytes()),'ticket_push_executor_v29.py':sha((local/'ticket_push_executor_v29.py').read_bytes()),'ticket_push_executor_v30.py':sha((local/'ticket_push_executor_v30.py').read_bytes()),'ticket_push_executor_v31.py':sha((local/'ticket_push_executor_v31.py').read_bytes()),'ticket_push_executor_v32.py':sha((local/'ticket_push_executor_v32.py').read_bytes()),'ticket_push_executor_v33.py':sha((local/'ticket_push_executor_v33.py').read_bytes()),'ticket_push_executor_v34.py':sha((local/'ticket_push_executor_v34.py').read_bytes()),'ticket_push_executor_v35.py':sha((local/'ticket_push_executor_v35.py').read_bytes()),'ticket_push_executor_v36.py':sha((local/'ticket_push_executor_v36.py').read_bytes()),'ticket_push_executor_v37.py':sha((local/'ticket_push_executor_v37.py').read_bytes()),'ticket_push_executor_v38.py':sha((local/'ticket_push_executor_v38.py').read_bytes())}
    for path_key,hash_key in (('helper_path','helper_sha256'),('companion_path','companion_sha256')):
        path = performed[path_key]
        require(type(path) is str and os.path.isabs(path) and os.path.realpath(path) == path and stat.S_ISREG(os.lstat(path).st_mode) and os.path.commonpath([path,prior['worktree']]) != prior['worktree'])
        basename = os.path.basename(path)
        require(basename in programs and performed[hash_key] == programs[basename])
        require((path_key == 'companion_path') == (basename == 'worker_file_companion.py'))
        require(sha(pathlib.Path(path).read_bytes()) == programs[basename])
    if os.path.basename(performed['helper_path']) in LARGE_PROGRAMS:
        push_program_origin(performed,local)
    elif pathlib.Path(performed['helper_path']).parent != local or pathlib.Path(performed['companion_path']) != local / 'worker_file_companion.py':
        entries=[]
        for name, expected in (('ticket_push_readback_origins_v1.json','469225e039512d5cc226163186ab827785705ec66f0a0bbc5a9f066bc0d96c7a'),('ticket_push_readback_origins_v3.json','3ab885c085c24781c1b9f009cc5043127526c30f24cd8d6ee8c21dde4ca4ed42')):
            raw=(local/name).read_bytes(); require(len(raw)<=65536 and sha(raw)==expected)
            resource=decode(raw.decode()); require(set(resource)=={'version','entries'} and resource['version']==1 and type(resource['entries']) is list and len(resource['entries'])<=8)
            entries.extend(resource['entries'])
        matching = [entry for entry in entries if all(performed[key] == entry[key] for key in ('helper_path','helper_sha256','companion_path','companion_sha256'))]
        require(len(matching) == 1)
        entry=matching[0]; manifest_path=entry['manifest_path']
        require(os.path.realpath(manifest_path)==manifest_path and stat.S_ISREG(os.lstat(manifest_path).st_mode) and os.stat(manifest_path).st_size<=4_194_304)
        manifest_raw=pathlib.Path(manifest_path).read_bytes(); require(sha(manifest_raw)==entry['manifest_sha256'])
        manifest=decode(manifest_raw.decode(),4_194_304)
        for kind in ('helper','companion'):
            relative='lib/symphony_elixir/priv/'+os.path.basename(entry[kind+'_path'])
            require(entry[kind+'_path'] in (str(pathlib.Path(manifest['release'])/relative),str(pathlib.Path(manifest['release'])/'dev'/relative)))
            require(manifest['artifact'][relative]=={'sha256':entry[kind+'_sha256']})
    require(performed['program_sha256'] == sha(pathlib.Path(CHECK_GIT).read_bytes()))
    require(type(receipt) is dict and set(receipt) == set('version execution_json helper_pid child_pid termination timed_out overflow output_base64 output_sha256 stderr_code stderr_bytes stderr_sha256'.split()))
    require(type(receipt['version']) is int and receipt['version'] == 1 and receipt['execution_json'] == intent['execution_json'])
    require(type(intent['helper_pid']) is int and intent['helper_pid'] > 0 and type(receipt['helper_pid']) is int and receipt['helper_pid'] == intent['helper_pid'] and type(receipt['child_pid']) is int and receipt['child_pid'] > 0)
    # COMPLETED and the exact released envelope authenticate remote reconciliation.
    # Terminal diagnostics do not independently establish push success.
    terminal = receipt['termination']
    require(type(terminal) is dict and (set(terminal) == {'kind','code'} and terminal['kind'] == 'exited' and type(terminal['code']) is int and 0 <= terminal['code'] <= 255 or set(terminal) == {'kind','signal'} and terminal['kind'] == 'signaled' and type(terminal['signal']) is int and 1 <= terminal['signal'] <= 64))
    require(type(receipt['timed_out']) is bool and type(receipt['overflow']) is bool)
    require(type(receipt['output_base64']) is str and len(receipt['output_base64']) <= 87384)
    try: output = base64.b64decode(receipt['output_base64'],validate=True)
    except (ValueError,binascii.Error): reject()
    require(len(output) <= 65536 and sha(output) == receipt['output_sha256'])
    require(receipt['stderr_code'] in ('GIT_EXIT_ZERO','GIT_EXIT_NONZERO','AUTHENTICATION_DENIED','TRANSPORT_FAILURE') and type(receipt['stderr_bytes']) is int and 0 <= receipt['stderr_bytes'] <= 16384 and hex_digest(receipt['stderr_sha256']))
    generated_only_commits(connection, performed, physical, prior)


def validate_archived_ci_authority(connection, prior, binding, execution):
    if 'ordinary_verifier_repair' in binding:
        require('ci_repair' not in binding and 'verified_ci_rollover' not in binding)
        ordinary_repair_proof(connection,execution,binding,prior,historical=True)
        if os.path.basename(execution['helper_path']) in ('ticket_push_executor_v16.py','ticket_push_executor_v17.py','ticket_push_executor_v18.py','ticket_push_executor_v19.py','ticket_push_executor_v20.py','ticket_push_executor_v21.py','ticket_push_executor_v22.py','ticket_push_executor_v23.py','ticket_push_executor_v24.py','ticket_push_executor_v25.py','ticket_push_executor_v26.py','ticket_push_executor_v27.py','ticket_push_executor_v28.py','ticket_push_executor_v29.py','ticket_push_executor_v30.py','ticket_push_executor_v31.py','ticket_push_executor_v32.py','ticket_push_executor_v33.py','ticket_push_executor_v34.py','ticket_push_executor_v35.py','ticket_push_executor_v36.py','ticket_push_executor_v37.py','ticket_push_executor_v38.py'):
            validate_ordinary_preissuance_retirement(connection,execution,binding,prior,historical=True)
        old=os.path.basename(execution['helper_path'])=='ticket_push_executor_v9.py'
        require(os.path.basename(execution['helper_path']) in ORDINARY_PROGRAMS)
        if 'ci_evidence_successor' not in binding:
            require(old and 'ci_evidence_successor' not in execution)
            require(not rows(connection,'SELECT s.successor_key FROM ticket_ci_repair_evidence_successors s JOIN ticket_ci_repair_claims c ON c.claim_key=s.claim_key WHERE s.run_id=? AND c.round<=?',(prior['run_id'],prior['code_repair_round'])))
            claims=rows(connection,'SELECT claim_key FROM ticket_ci_repair_claims WHERE run_id=? AND round<=?',(prior['run_id'],prior['code_repair_round']))
            require(len(claims)<=7)
        else:
            proof=binding['ci_evidence_successor']
            require(proof==execution['ci_evidence_successor'] and set(proof)==PUSH_KEYS and proof['version']==1 and proof['kind']=='CI_EVIDENCE_SUCCESSOR_PUSH_V1')
            require(proof['current_claim_key'] is None and proof['current_round']==prior['code_repair_round'])
            require(proof['attempt_limit']==(7 if old else 10))
            archived_projection(connection,prior,proof)
            require(type(proof['attempts_used']) is int and 0<=proof['attempts_used']<=proof['attempt_limit'])
        history_name = history_program_name(execution)
        history=pathlib.Path(execution['helper_path']).with_name(history_name)
        expected_history='0e78f263fa3985f9f274d0d842c085ae6a89f5209e83ca7252a717b7af0ca479' if old else sha((pathlib.Path(__file__).resolve().parent/history_name).read_bytes())
        require(os.path.realpath(history)==str(history) and stat.S_ISREG(os.lstat(history).st_mode))
        require(execution['history_program_path']==str(history) and execution['history_program_sha256']==sha(history.read_bytes())==expected_history)
        if not old:
            archived_generation_history(connection,execution,binding['ordinary_verifier_repair']['writer_request_key'])
        return
    repair = binding['ci_repair']
    require(type(repair) is dict and set(repair) == {'claim_key','claim_sha256','round'})
    found = rows(connection,'SELECT * FROM ticket_ci_repair_claims WHERE claim_key=? AND run_id=?',(repair['claim_key'],prior['run_id']))
    require(len(found) == 1)
    claim = found[0]
    require(sha(claim['claim_json'].encode()) == claim['claim_sha256'] == repair['claim_sha256'])
    saved = push_budget_decode(claim['claim_json'],'claim')
    require(saved['kind'] == 'TICKET_CI_REPAIR' and saved['claim_key'] == claim['claim_key'])
    require(type(repair['round']) is int and repair['round'] == claim['round'] == saved['round'] == binding['code_repair_round'] == prior['code_repair_round'])
    require(all(saved['prior_run'][key] == binding[key] for key in ('run_id','repo_path','worktree','branch','base_branch','contract_sha256','spec_revision')))
    claimed_diagnosis_v4(connection,claim)
    proof = binding['ci_evidence_successor']
    require(type(proof) is dict and set(proof) == PUSH_KEYS and proof == execution['ci_evidence_successor'])
    require(type(proof['version']) is int and proof['version'] == 1 and proof['kind'] == 'CI_EVIDENCE_SUCCESSOR_PUSH_V1')
    require(proof['current_claim_key'] == claim['claim_key'] and proof['current_round'] == repair['round'])
    require(type(proof['attempts_used']) is int and type(proof['attempt_limit']) is int and 1 <= proof['attempts_used'] <= proof['attempt_limit'] <= 10)
    captured=archived_projection(connection,prior,proof)
    policy = binding['ci_repair_policy_receipt']
    require(type(policy) is dict and policy == execution['ci_repair_policy_receipt'])
    keys = set('version kind workflow_path workflow_sha256 workflow_stat configured_limit effective_limit scope dispatcher_id repo_key cached_policy_sha256'.split())
    if policy.get('version') in (2,3): keys.add('scope_extension')
    require(set(policy) == keys and type(policy['version']) is int and (policy['version'],policy['kind']) in ((1,'CI_REPAIR_POLICY_V1'),(2,'CI_REPAIR_POLICY_V2'),(3,'CI_REPAIR_POLICY_V3')))
    require(type(policy['configured_limit']) is int and policy['configured_limit'] >= 1 and type(policy['effective_limit']) is int and policy['effective_limit'] == min(policy['configured_limit'],{1:5,2:7,3:10}[policy['version']]) == proof['attempt_limit'])
    require(policy['repo_key'] == prior['repo_key'] and hex_digest(policy['workflow_sha256']) and hex_digest(policy['cached_policy_sha256']))
    require(all(type(policy[key]) is str and 1 <= len(policy[key].encode()) <= 1024 for key in ('scope','dispatcher_id')))
    applicable = [row for row in captured if row['claim_key'] == claim['claim_key']]
    if applicable: require(policy.get('scope_extension') == push_budget_decode(applicable[-1]['proof_json'],'successor')['policy_receipt'].get('scope_extension'))
    scope_extension(policy,prior,claim)
    path = policy['workflow_path']
    require(type(path) is str and os.path.isabs(path) and os.path.normpath(path) == path and os.path.commonpath([path,prior['worktree']]) != prior['worktree'])
    recorded_stat = policy['workflow_stat']
    require(type(recorded_stat) is dict and set(recorded_stat) == set('inode device rdev size mtime_seconds uid mode'.split()) and all(type(value) is int for value in recorded_stat.values()))
    require(stat.S_ISREG(recorded_stat['mode']) and not recorded_stat['mode'] & 0o022 and recorded_stat['uid'] == os.geteuid() and 0 <= recorded_stat['size'] <= 1_048_576)
    history = pathlib.Path(__file__).resolve().with_name(history_program_name(execution))
    require(execution['history_program_path'] == str(pathlib.Path(execution['helper_path']).with_name(history.name)))
    require(os.path.realpath(execution['history_program_path'])==execution['history_program_path'] and stat.S_ISREG(os.lstat(execution['history_program_path']).st_mode))
    require(execution['history_program_sha256'] == sha(pathlib.Path(execution['history_program_path']).read_bytes()) == sha(history.read_bytes()))


def archived_projection(connection,prior,proof):
    heads = proof['heads']; require(type(heads) is list and len(heads)<=9)
    captured = []
    for head in heads:
        require(type(head) is dict and set(head) == {'claim_key','head_key','head_row_sha256','chain_keys'})
        require(type(head['chain_keys']) is list and len(head['chain_keys']) > 0)
        chain = rows(connection,'SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id=? AND claim_key=? ORDER BY attempt_index',(prior['run_id'],head['claim_key']))
        chain = chain[:len(head['chain_keys'])]
        require([row['successor_key'] for row in chain] == head['chain_keys'] and head['head_key'] == chain[-1]['successor_key'] and head['head_row_sha256'] == digest(chain[-1]))
        for row in chain:
            require(sha(row['proof_json'].encode()) == row['proof_sha256'] and sha(row['evidence_json'].encode()) == row['evidence_sha256'])
        captured.extend(chain)
    require([head['claim_key'] for head in heads] == sorted(set(head['claim_key'] for head in heads)))
    captured.sort(key=lambda row:row['attempt_index'])
    require(proof['all_rows_sha256'] == digest([{'successor_key':row['successor_key'],'row_sha256':digest(row)} for row in captured]))
    historical_claims = rows(connection,'SELECT claim_key FROM ticket_ci_repair_claims WHERE run_id=? AND round<=?',(prior['run_id'],prior['code_repair_round']))
    require(proof['attempts_used'] == len(historical_claims) + len(captured))
    return captured


def archived_generation_history(connection,execution,writer_key):
    history=execution['worker_history']
    captured={}
    for name,table,key,hashed,limit in (('generation_intents','ticket_ordinary_generation_intents','intent_key','binding_json',32),('generation_events','ticket_ordinary_generation_events','event_key','receipt_json',4096)):
        values=decode(history[name+'_json'])
        require(type(values) is list and len(values)<=limit and all(type(value) is dict for value in values))
        require(len({value[key] for value in values})==len(values))
        for value in values:
            found=rows(connection,'SELECT * FROM '+table+' WHERE '+key+'=?',(value[key],))
            require(len(found)==1)
            actual={field:sha(raw.encode()) if field==hashed and type(raw) is str else raw for field,raw in found[0].items()}
            require(actual==value)
        captured[name]=values
    required=rows(connection,'SELECT intent_key FROM ticket_ordinary_generation_intents WHERE run_id=? AND request_key=?',(execution['run_id'],writer_key))
    keys={value['intent_key'] for value in required}
    require(keys=={value['intent_key'] for value in captured['generation_intents'] if value['request_key']==writer_key})
    for key in keys:
        actual={value['event_key'] for value in rows(connection,'SELECT event_key FROM ticket_ordinary_generation_events WHERE intent_key=?',(key,))}
        recorded={value['event_key'] for value in captured['generation_events'] if value['intent_key']==key}
        require(actual==recorded and any(value['intent_key']==key and value['event_type']=='FINALIZED' and value['path']=='' for value in captured['generation_events']))


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def reject():
    raise ValueError("ci_evidence_successor_changed")


def require(condition):
    if not condition:
        reject()


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def decode(raw, maximum=2_097_152):
    require(type(raw) is str and len(raw.encode()) <= maximum)
    return json.loads(raw, object_pairs_hook=object_pairs, parse_constant=lambda value:reject())


PUSH_REMAINDER_LIMIT = 2_097_152
PUSH_ENVELOPE_LIMIT = 12_582_912
PUSH_HELPER_SHA = 'f5513fb5eda319b4df8d2796b37ec0efec08afec3793aab4962de3590c73255b'
PUSH_COMPANION_SHA = '87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b'


def push_absolute_limit(kind):
    layers = {'diagnosis_row':4,'successor':6,'preimage':2,'claim':2,'import':2,'ordinary_generation':2}
    return PUSH_REMAINDER_LIMIT + layers[kind] * PUSH_ENVELOPE_LIMIT


def push_completed_marker(raw, run):
    """Size accounting only; all independent historical authority checks remain."""
    intent = decode(raw, PUSH_ENVELOPE_LIMIT)
    require(type(intent) is dict and set(intent) == set('version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json receipt_json receipt_sha256 remote_sha'.split()))
    require(type(intent['version']) is int and intent['version']==1 and intent['kind']=='TICKET_PUSH' and intent['phase']=='COMPLETED')
    require(type(intent['reservation_generation']) is int and intent['reservation_generation']>0)
    require(hex_digest(run['candidate_sha'],40) and intent['remote_sha']==run['candidate_sha'])
    binding = decode(intent['binding_json'],1_048_576)
    execution = decode(intent['execution_json'],1_048_576)
    receipt = decode(intent['receipt_json'],4_194_304)
    require(sha(intent['binding_json'].encode())==intent['binding_sha256'] and intent['reservation_key']=='ticket-push:'+intent['binding_sha256'])
    identity='run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision'.split()
    require(type(binding) is dict and all(binding[key]==run[key] for key in identity))
    local=pathlib.Path(__file__).resolve().parent
    push_program_origin(execution,local)
    require(execution['companion_path']==str(pathlib.Path(execution['helper_path']).with_name('worker_file_companion.py')) and execution['companion_sha256']==PUSH_COMPANION_SHA)
    require(execution['history_program_path']==str(pathlib.Path(execution['helper_path']).with_name(history_program_name(execution))))
    require(execution['run_id']==run['run_id'] and execution['intent_json']==intent['binding_json'] and execution['intent_sha256']==intent['binding_sha256'] and execution['invocation']==intent['owner_nonce'] and hex_digest(intent['owner_nonce']))
    keys=set('version execution_json helper_pid child_pid termination timed_out overflow output_base64 output_sha256 stderr_code stderr_bytes stderr_sha256'.split())
    require(type(receipt) is dict and set(receipt)==keys and type(receipt['version']) is int and receipt['version']==1 and receipt['execution_json']==intent['execution_json'])
    require(sha(intent['receipt_json'].encode())==intent['receipt_sha256'] and type(intent['helper_pid']) is int and intent['helper_pid']>0 and type(receipt['helper_pid']) is int and receipt['helper_pid']==intent['helper_pid'] and type(receipt['child_pid']) is int and receipt['child_pid']>0)
    terminal=receipt['termination']
    require(type(terminal) is dict and (set(terminal)=={'kind','code'} and terminal['kind']=='exited' and type(terminal['code']) is int and 0<=terminal['code']<=255 or set(terminal)=={'kind','signal'} and terminal['kind']=='signaled' and type(terminal['signal']) is int and 1<=terminal['signal']<=64))
    require(type(receipt['timed_out']) is bool and type(receipt['overflow']) is bool and receipt['stderr_code'] in ('GIT_EXIT_ZERO','GIT_EXIT_NONZERO','AUTHENTICATION_DENIED','TRANSPORT_FAILURE') and type(receipt['stderr_bytes']) is int and 0<=receipt['stderr_bytes']<=16384 and hex_digest(receipt['stderr_sha256']))
    require(type(receipt['output_base64']) is str and len(receipt['output_base64'])<=87384)
    output=base64.b64decode(receipt['output_base64'],validate=True)
    require(len(output)<=65536 and sha(output)==receipt['output_sha256'])
    return {'kind':'COMPLETED_V12_PUSH_SIZE_V1','sha256':sha(raw.encode()),'bytes':len(raw.encode())}


def push_size_project(value,kind):
    require(type(value) is dict)
    if kind=='diagnosis_row':
        raw=value['preimage_json']; require(type(raw) is str and sha(raw.encode())==value['preimage_sha256'])
        inner,copies=push_size_project(decode(raw,push_absolute_limit('preimage')),'preimage')
        return dict(value,preimage_json=canonical(inner).decode()),copies
    if kind=='successor':
        direct,copies=push_size_project(value,'preimage')
        claim=value['claim']; raw=claim['claim_json']
        require(type(raw) is str and sha(raw.encode())==claim['claim_sha256'])
        decoded=decode(raw,push_absolute_limit('claim'))
        require(value['run']['candidate_handoff']==decoded['prior_run']['candidate_handoff'])
        inner,nested=push_size_project(decoded,'claim')
        direct['claim']=dict(claim,claim_json=canonical(inner).decode())
        return direct,copies+nested
    if kind=='ordinary_generation':
        require(type(value.get('version')) is int and value['version']==1 and value.get('kind')=='CONTROLLER_ORDINARY_GENERATION' and value.get('operation') in ('GOFMT_DIFF','GAZELLE_DIFF'))
        key='run_preimage'
    else:
        key='run' if kind=='preimage' else 'prior_run'
    require(kind in ('preimage','claim','import','ordinary_generation') and type(value[key]) is dict)
    marker_run=value[key]
    if kind=='ordinary_generation':
        proof=value.get('ordinary_verifier_repair')
        require(type(proof) is dict and type(proof.get('version')) is int and proof['version'] in (1,2,3) and proof.get('kind')=='ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1')
        require(hex_digest(proof.get('reviewed_candidate_sha'),40) and hex_digest(proof.get('source_parent_sha'),40))
        require(proof.get('candidate_sha')==proof['source_parent_sha']==marker_run['candidate_sha'])
        marker_run=dict(marker_run,candidate_sha=proof['reviewed_candidate_sha'])
    marker=push_completed_marker(value[key]['candidate_handoff'],marker_run)
    projected=dict(value,**{key:dict(value[key],candidate_handoff=marker)})
    if kind=='ordinary_generation': projected=confirmed_generation_response_size(projected)
    return projected,[marker['sha256']]


def confirmed_generation_response_size(value):
    """Discount only an authenticated duplicate; keep the complete first response."""
    observation=value.get('observation')
    if type(observation) is not dict:return value
    native=observation.get('native')
    if type(native) is not dict:return value
    latest=native.get('latest_turn_observation')
    if type(latest) is not dict:return value
    confirmation=latest.get('confirmation')
    if type(confirmation) is not dict:return value
    primary=latest.get('raw_response'); duplicate=confirmation.get('raw_response')
    if type(primary) is not dict or type(duplicate) is not dict:return value
    raw=canonical(primary); digest=sha(raw)
    if canonical(duplicate)!=raw or latest.get('sha256')!=digest or confirmation.get('sha256')!=digest:return value
    marker={'kind':'CONFIRMED_NATIVE_RESPONSE_SIZE_V1','sha256':digest,'bytes':len(raw)}
    # This projection must never alter the decoded journal returned to validators.
    return dict(value,observation=dict(observation,native=dict(native,latest_turn_observation=
                dict(latest,confirmation=dict(confirmation,raw_response=marker)))))


def push_budget_decode(raw,kind):
    """Decode supported journal paths without modifying raw digests or bytes."""
    value=decode(raw,push_absolute_limit(kind))
    require(type(value) is dict)
    if len(raw.encode())>PUSH_REMAINDER_LIMIT:
        projected,copies=push_size_project(value,kind)
        require(1<=len(copies)<=(2 if kind=='successor' else 1) and len(set(copies))==1 and len(canonical(projected))<=PUSH_REMAINDER_LIMIT)
    return value


def large_push(execution):
    return os.path.basename(execution.get('helper_path','')) in LARGE_PROGRAMS


def push_program_origin(execution,local):
    name=os.path.basename(execution['helper_path'])
    require(name in LARGE_PROGRAMS)
    history=history_program_name(execution)
    fixed={'ticket_push_executor_v12.py':PUSH_HELPER_SHA,'ticket_push_executor_v13.py':'8a4b90014af4b1e56e21c1698ba3657e08f7e57b78de58aad33bcebab43b0950','ticket_push_executor_v14.py':'59ca083a8a8771e261604acb7c946a92ef65576fec11aa161fbc0f89dd1335e0'}
    expected=fixed[name] if name in fixed else sha((local/name).read_bytes())
    require(execution['helper_sha256']==expected and execution['history_program_sha256']==sha((local/history).read_bytes()))
    if execution['helper_path']==str(local/name):return
    raw=generation_regular(str(local/'ticket_push_readback_origins_v20.json'),65536)
    require(sha(raw)=='5684cfb73af6c7299997fb86f864db82fbde3e6805ead4e77f81d15120ea84ec')
    catalog=decode(raw.decode(),65536)
    require(catalog['version']==20 and type(catalog['entries']) is list)
    matching=[entry for entry in catalog['entries'] if all(entry[key]==execution[key] for key in ('helper_path','helper_sha256','companion_path','companion_sha256'))]
    require(len(matching)==1)
    entry=matching[0]
    r18_current = (name == 'ticket_push_executor_v24.py' and entry.get('release_root') == '/Users/cgable/Library/Application Support/ai-factory/releases/symphony-generation-handoff-cnRVdUfY-r18' and entry.get('manifest_sha256') == '9264afddf4769e8bb4b475c7e3bcce1430d347e13d3ddb8e10f85d56105511e1')
    r19f_current = (name == 'ticket_push_executor_v26.py' and entry.get('release_root') == '/Users/cgable/Library/Application Support/ai-factory/releases/symphony-generation-handoff-cnRVdUfY-r19f' and entry.get('manifest_sha256') == '1b3bbe66c469a3aea634004c6b17f77f2b4533f87a6882a48649b7f3e8587d48')
    r216_current = (name == 'ticket_push_executor_v36.py' and entry.get('release_root') == '/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-216eadb' and entry.get('manifest_sha256') == '8119af4273e08dd17442790236bbcacecb884e3e8997dc99ba36a2159093af65')
    require(name in ('ticket_push_executor_v12.py','ticket_push_executor_v13.py','ticket_push_executor_v14.py','ticket_push_executor_v15.py','ticket_push_executor_v16.py','ticket_push_executor_v17.py','ticket_push_executor_v18.py','ticket_push_executor_v19.py','ticket_push_executor_v20.py') or r18_current or r19f_current or r216_current)
    entry=matching[0]; require(entry['kind']=='RELEASE_ARTIFACT_V2')
    raw=generation_regular(entry['manifest_path'],4_194_304)
    require(sha(raw)==entry['manifest_sha256'])
    manifest=decode(raw.decode(),4_194_304); root=entry['release_root']
    require(os.path.realpath(root)==root and entry['manifest_path']==str(pathlib.Path(root)/'evidence/release-manifest.json') and manifest['kind']==entry['expected_manifest_kind'] and manifest['release']==root)
    for filename,digest in ((name,expected),('worker_file_companion.py',PUSH_COMPANION_SHA),(history,execution['history_program_sha256'])):
        relative='lib/symphony_elixir/priv/'+filename
        path=str(pathlib.Path(root)/'dev'/relative)
        require(manifest['artifact'][relative]=={'sha256':digest} and sha(generation_regular(path,1_048_576))==digest)
        if filename==name:require(path==execution['helper_path'])


def decode_push_execution(raw):
    execution = decode(raw,1_048_576)
    require(type(execution) is dict and (large_push(execution) or len(raw.encode()) <= 262144))
    return execution


def decode_push_receipt(raw, performed):
    execution = decode_push_execution(performed)
    return decode(raw,4_194_304 if large_push(execution) else 2_097_152)


def decode_push_envelope(raw):
    # The envelope re-escapes both independently bounded JSON strings.
    value = decode(raw,12_582_912)
    require(type(value) is dict)
    execution = decode_push_execution(value['execution_json'])
    require(large_push(execution) or len(raw.encode()) <= 2_097_152)
    decode(value['binding_json'])
    decode_push_receipt(value['receipt_json'],value['execution_json'])
    return value


def digest(value):
    return sha(canonical(value))


def hex_digest(value, size=64):
    return type(value) is str and re.fullmatch('[0-9a-f]{'+str(size)+'}', value) is not None


def utc(value):
    require(type(value) is str and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z',value) is not None)
    return datetime.datetime.fromisoformat(value[:-1]+'+00:00')


def capability_grant_utc(value):
    capability_require(type(value) is str and re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|\+00:00)', value) is not None)
    try:
        return datetime.datetime.fromisoformat(value.removesuffix('Z') + ('+00:00' if value.endswith('Z') else ''))
    except ValueError:
        capability_require(False)


JOURNAL_KEYS = set('successor_key run_id claim_key prior_request_key prior_successor_key attempt_index configured_limit evidence_content_sha256 evidence_json evidence_sha256 proof_json proof_sha256 new_request_key new_reservation_key created_at'.split())
PROOF_KEYS = set('version kind run claim prior_evidence prior_task prior_access disposition_event accepted_outcome inputs source_observation authorization ci_snapshots content_members previous_content_sha256 total_before configured_limit admitted_at policy_receipt'.split())
PUSH_KEYS = set('version kind heads all_rows_sha256 current_claim_key current_round attempts_used attempt_limit'.split())
TRANSFER_KEYS = set('kind ci_evidence_successor_key old_request_key old_reservation_key new_request_key new_reservation_key new_generation disposition_key output_sha256 checkout_head_sha'.split())
APPLIED_KEYS = set('kind successor_key prior_request_key new_request_key new_reservation_key new_generation new_binding_sha256 proof_sha256 evidence_sha256 attempt_index accepted_outcome_sha256'.split())


def claimed_diagnosis_v4(connection, claim):
    try:
        original = connection.execute("SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key = ?", (claim["diagnosis_key"],)).fetchone()
        original_fields = {"diagnosis_key", "run_id", "candidate_sha", "pipeline_id", "preimage_json", "preimage_sha256", "diagnosis_json", "diagnosis_sha256", "verdict", "created_at"}
        if original is None or set(original.keys()) != original_fields or sha(original["diagnosis_json"].encode()) != original["diagnosis_sha256"]:
            raise ValueError("ci_repair_diagnosis_changed")
        push_budget_decode(canonical(dict(original)).decode(),'diagnosis_row')
        saved = push_budget_decode(claim["claim_json"],'claim')
        if 'budget_resume' in saved:
            validate_budget_resume(connection,claim,saved,dict(original))
        else:
            diagnosed=budget_diagnosis(connection,saved,dict(original))
            prior=push_budget_decode(diagnosed['preimage_json'],'preimage')['run']
            ignored={'updated_at','ci_last_checked_at'}
            require({key:value for key,value in prior.items() if key not in ignored}=={key:value for key,value in saved['prior_run'].items() if key not in ignored})
        key, expected = saved.get("reassessment_key"), saved.get("reassessment_sha256")
        if key is None and expected is None:
            if original["verdict"] != "REPAIRABLE":
                raise ValueError("ci_repair_diagnosis_changed")
            return json.loads(original["diagnosis_json"])
        row = connection.execute("SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key = ?", (key,)).fetchone()
        fields = {"reassessment_key", "diagnosis_key", "collector_version", "original_sha256", "run_id", "candidate_sha", "pipeline_id", "preimage_json", "preimage_sha256", "diagnosis_json", "diagnosis_sha256", "verdict", "created_at", "kind"}
        if row is None or set(row.keys()) != fields or digest(dict(row)) != expected or row["original_sha256"] != digest(dict(original)):
            raise ValueError("ci_repair_diagnosis_changed")
        push_budget_decode(canonical(dict(row)).decode(),'diagnosis_row')
        for value in (original, row):
            if type(value["pipeline_id"]) is not int or value["pipeline_id"] <= 0 or any(type(value[field]) is not str for field in value.keys() if field != "pipeline_id"):
                raise ValueError("ci_repair_diagnosis_changed")
        if original["verdict"] != "BLOCKED" or row["verdict"] != "REPAIRABLE" or row["kind"] != "COLLECTOR_REASSESSMENT_V1":
            raise ValueError("ci_repair_diagnosis_changed")
        encoded = json.dumps([claim["diagnosis_key"], row["collector_version"]], separators=(",", ":"), ensure_ascii=False).encode()
        if key != "ci-reassessment:" + sha(encoded) or any(row[field] != original[field] for field in ("diagnosis_key", "run_id", "candidate_sha", "pipeline_id")):
            raise ValueError("ci_repair_diagnosis_changed")
        for value in (original, row):
            if sha(value["preimage_json"].encode()) != value["preimage_sha256"] or sha(value["diagnosis_json"].encode()) != value["diagnosis_sha256"]:
                raise ValueError("ci_repair_diagnosis_changed")
            prior = json.loads(value["preimage_json"])["run"]
            diagnosis = json.loads(value["diagnosis_json"])
            if not isinstance(prior, dict) or not isinstance(diagnosis, dict) or diagnosis.get("status") != value["verdict"]:
                raise ValueError("ci_repair_diagnosis_changed")
            if (prior.get("run_id"), prior.get("candidate_sha"), prior.get("ci_pipeline_id")) != (value["run_id"], value["candidate_sha"], value["pipeline_id"]):
                raise ValueError("ci_repair_diagnosis_changed")
        if any(saved.get(field) != diagnosis.get(field) for field in ("allowed_writer_paths", "required_generated_paths")):
            raise ValueError("ci_repair_diagnosis_changed")
        return diagnosis
    except (KeyError, TypeError, AttributeError, json.JSONDecodeError):
        raise ValueError("ci_repair_diagnosis_changed") from None


def budget_failure_event(connection,run_id,cutoff):
    events=rows(connection,"SELECT * FROM events WHERE run_id=? AND event_type='RUN_UPDATED' AND (json_type(payload_json,'$.failure_code') IS NOT NULL OR json_type(payload_json,'$.last_error') IS NOT NULL) ORDER BY id DESC LIMIT 2001",(run_id,))
    require(len(events)<=2000)
    return next((event for event in events if utc(event['occurred_at'])<=utc(cutoff)),None)


def budget_failure_pair(event,run):
    require(type(event) is dict and event['run_id']==run['run_id'] and event['event_type']=='RUN_UPDATED')
    payload=decode(event['payload_json'])
    require(type(payload) is dict and set(payload)=={'failure_code','last_error','updated_at'})
    require(all(payload[key]==run[key] for key in ('failure_code','last_error')) and utc(payload['updated_at'])<=utc(event['occurred_at']))


def budget_diagnosis(connection,saved,original):
    diagnosis=original
    if saved.get('reassessment_key') is not None:
        found=rows(connection,'SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key=?',(saved['reassessment_key'],))
        require(len(found)==1 and digest(found[0])==saved['reassessment_sha256'])
        diagnosis=found[0]
    require(sha(diagnosis['preimage_json'].encode())==diagnosis['preimage_sha256'])
    return diagnosis


def validate_budget_resume(connection,claim,saved,original):
    proof=saved['budget_resume']
    keys=set('version kind diagnosis_key preimage_sha256 exhaustion_event_id exhaustion_event_payload_sha256 prior_exhaustion_event attempts_before exhausted_limit historical_hard_limit configured_limit effective_limit admitted_at'.split())
    require(type(proof) is dict and set(proof)==keys and type(proof['version']) is int and proof['version']==1 and proof['kind']=='CI_REPAIR_BUDGET_RESUMPTION_V1')
    diagnosis=budget_diagnosis(connection,saved,original)
    require(sha(diagnosis['preimage_json'].encode())==diagnosis['preimage_sha256']==proof['preimage_sha256'])
    require(proof['diagnosis_key']==saved['diagnosis_key']==claim['diagnosis_key']==diagnosis['diagnosis_key'])
    before=push_budget_decode(diagnosis['preimage_json'],'preimage')['run']; run=saved['prior_run']
    ignored={'updated_at','ci_last_checked_at','failure_code','last_error'}
    require({key:value for key,value in before.items() if key not in ignored}=={key:value for key,value in run.items() if key not in ignored})
    require(run['state']=='CI_WAITING' and run['failure_code']=='CI_REPAIR_EXHAUSTED')
    require((run['run_id'],run['candidate_sha'],run['ci_pipeline_id'])==(diagnosis['run_id'],diagnosis['candidate_sha'],diagnosis['pipeline_id']))
    require(saved['round']==claim['round'] and proof['admitted_at']==claim['created_at'])
    used=connection.execute('SELECT (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=? AND round<?)+(SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors s JOIN ticket_ci_repair_claims c ON c.claim_key=s.claim_key WHERE s.run_id=? AND c.round<?)',(claim['run_id'],claim['round'],claim['run_id'],claim['round'])).fetchone()[0]
    require(all(type(proof[key]) is int for key in ('attempts_before','configured_limit','effective_limit','exhausted_limit','historical_hard_limit','exhaustion_event_id')))
    limit=proof['exhausted_limit']; hard=proof['historical_hard_limit']; configured=proof['configured_limit']; effective=proof['effective_limit']
    require(proof['attempts_before']==used and configured>=1 and effective==min(configured,10) and hard in (7,10) and 1<=limit<=hard and limit<=used<effective and limit<effective)
    message=f"CI repair budget exhausted: {used} total cycles used; configured limit {limit} (hard maximum {hard}). Current failed pipeline {diagnosis['pipeline_id']}; assessment {diagnosis['diagnosis_key']}. Human investigation or a new authorized policy decision is required; no new writer or retry was issued."
    require(run['last_error']==message)
    event=budget_failure_event(connection,run['run_id'],proof['admitted_at'])
    budget_failure_pair(event,run)
    require(event['id']==proof['exhaustion_event_id'] and sha(event['payload_json'].encode())==proof['exhaustion_event_payload_sha256'] and utc(diagnosis['created_at'])<=utc(event['occurred_at']))
    if before['failure_code'] is None and before['last_error'] is None:
        require(proof['prior_exhaustion_event'] is None)
    else:
        require(before['failure_code']=='CI_REPAIR_EXHAUSTED')
        prior=budget_failure_event(connection,run['run_id'],diagnosis['created_at'])
        budget_failure_pair(prior,before)
        require(prior['id']<event['id'] and proof['prior_exhaustion_event']=={'id':prior['id'],'payload_sha256':sha(prior['payload_json'].encode())})


def claim_diagnosis(connection, claim):
    scope = push_budget_decode(claim['claim_json'],'claim')
    require(scope['diagnosis_key'] == claim['diagnosis_key'])
    original = connection.execute('SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key=?',(claim['diagnosis_key'],)).fetchone()
    require(original is not None)
    original = dict(original)
    require(set(original) == set('diagnosis_key run_id candidate_sha pipeline_id preimage_json preimage_sha256 diagnosis_json diagnosis_sha256 verdict created_at'.split()))
    require(type(original['pipeline_id']) is int and original['pipeline_id'] > 0 and all(type(value) is str for key,value in original.items() if key != 'pipeline_id'))
    require(original['run_id'] == claim['run_id'] == scope['prior_run']['run_id'] and original['candidate_sha'] == scope['prior_run']['candidate_sha'] and original['pipeline_id'] == scope['ci_snapshots']['pipeline']['id'])
    require(sha(original['preimage_json'].encode()) == original['preimage_sha256'] and sha(original['diagnosis_json'].encode()) == original['diagnosis_sha256'])
    preimage, raw_diagnosis = push_budget_decode(original['preimage_json'],'preimage'), decode(original['diagnosis_json'])
    require(type(preimage) is dict and type(preimage['run']) is dict and (preimage['run']['run_id'],preimage['run']['candidate_sha'],preimage['run']['ci_pipeline_id']) == (original['run_id'],original['candidate_sha'],original['pipeline_id']) and raw_diagnosis['status'] == original['verdict'])
    diagnosis = claimed_diagnosis_v4(connection,claim)
    require(type(diagnosis) is dict and diagnosis['status'] == 'REPAIRABLE' and diagnosis['allowed_writer_paths'] == scope['allowed_writer_paths'] and diagnosis['required_generated_paths'] == scope['required_generated_paths'])
    return diagnosis


def rows(connection, query, parameters):
    return [dict(row) for row in connection.execute(query, parameters)]


def snapshot_identity(snapshots):
    mr_keys = 'project_id iid sha source_branch target_branch draft reviewers assignee force_remove_source_branch web_url'.split()
    pipeline_keys = 'id project_id sha ref source status web_url'.split()
    job_keys = 'id name status allow_failure web_url pipeline'.split()
    mr = {key:snapshots['mr'].get(key) for key in mr_keys}
    pipeline = {key:snapshots['pipeline'].get(key) for key in pipeline_keys}
    require(mr['reviewers'] == [] and type(mr['project_id']) is int and mr['project_id'] > 0)
    mr['assignee'] = {'id':mr['assignee']['id']} if type(mr['assignee']) is dict else mr['assignee']
    jobs = []
    for value in snapshots['jobs']:
        job = {key:value.get(key) for key in job_keys}
        require(type(job['id']) is int and job['id'] > 0)
        job['pipeline'] = {key:value['pipeline'].get(key) for key in ('id','project_id','sha')}
        jobs.append(job)
    jobs.sort(key=lambda job:job['id'])
    require(len({job['id'] for job in jobs}) == len(jobs))
    return {'mr':mr,'pipeline':pipeline,'jobs':jobs}


def novelty(content):
    return {(member['project_id'],member['job_id'],member['member_sha256'],member['text_sha256']) for member in content}


def policy_shape(receipt, run):
    keys = set('version kind workflow_path workflow_sha256 workflow_stat configured_limit effective_limit scope dispatcher_id repo_key cached_policy_sha256'.split())
    if type(receipt) is dict and receipt.get('version') in (2,3):
        keys.add('scope_extension')
    stat_keys = set('inode device rdev size mtime_seconds uid mode'.split())
    require(type(receipt) is dict and set(receipt) == keys and type(receipt['version']) is int and (receipt['version'],receipt['kind']) in ((1,'CI_REPAIR_POLICY_V1'),(2,'CI_REPAIR_POLICY_V2'),(3,'CI_REPAIR_POLICY_V3')))
    require(type(receipt['configured_limit']) is int and receipt['configured_limit'] >= 1 and type(receipt['effective_limit']) is int and receipt['effective_limit'] == min(receipt['configured_limit'],{1:5,2:7,3:10}[receipt['version']]))
    require(type(receipt['workflow_path']) is str and os.path.isabs(receipt['workflow_path']) and os.path.normpath(receipt['workflow_path']) == receipt['workflow_path'] and os.path.commonpath([receipt['workflow_path'],run['worktree']]) != run['worktree'])
    require(type(receipt['workflow_stat']) is dict and set(receipt['workflow_stat']) == stat_keys and all(type(value) is int for value in receipt['workflow_stat'].values()))
    require(stat.S_ISREG(receipt['workflow_stat']['mode']) and not receipt['workflow_stat']['mode'] & 0o022 and receipt['workflow_stat']['uid'] == os.geteuid())
    require(hex_digest(receipt['workflow_sha256']) and hex_digest(receipt['cached_policy_sha256']) and receipt['repo_key'] == run['repo_key'])
    require(all(type(receipt[key]) is str and receipt[key] for key in ('scope','dispatcher_id','repo_key')))
    return receipt['effective_limit']


def scope_extension(receipt, run, claim):
    extension = receipt.get('scope_extension')
    if extension is None:
        return []
    keys = set('version run_id issue_key repo_key project_id claim_key claim_sha256 failed_candidate_sha spec_revision contract_sha256 allowed_writer_paths authorization_reference'.split())
    require(receipt['version'] in (2,3) and type(extension) is dict and set(extension) == keys and type(extension['version']) is int and extension['version'] == 1)
    require(type(extension['project_id']) is int and extension['project_id'] > 0 and type(extension['spec_revision']) is int)
    require(all(extension[key] == run[key] for key in ('run_id','issue_key','repo_key','spec_revision','contract_sha256')))
    require(extension['claim_key'] == claim['claim_key'] and extension['claim_sha256'] == claim['claim_sha256'])
    scope = push_budget_decode(claim['claim_json'],'claim')
    require(extension['failed_candidate_sha'] == scope['prior_run']['candidate_sha'] and extension['project_id'] == scope['ci_snapshots']['mr']['project_id'])
    paths = extension['allowed_writer_paths']
    require(type(paths) is list and len(paths) == 2 and all(type(path) is str and path.endswith('.go') for path in paths) and paths == sorted(set(paths)))
    for path in paths:
        require(not path.startswith('/') and not any(part in ('','.','..') for part in path.split('/')) and not re.search(r'[\x00-\x1f\x7f\\*?\[\]{}]',path))
        checked = path.replace('go/src/grail.com/workflows/','go/src/grail.com/',1) if path.startswith('go/src/grail.com/workflows/') else path
        require(not any(part.lower() in ('.git','.github','.gitlab','.agents','.codex','.cursor','.claude','.factory-file-io','node_modules','vendor','config','policy','policies','workflows') for part in checked.split('/')))
        require(not any(value in checked.lower() for value in ('/workflow','/policy','/config/')))
    require(type(extension['authorization_reference']) is str and 1 <= len(extension['authorization_reference'].encode()) <= 1024)
    return paths


def admission_inputs(connection, proof):
    inputs = proof['inputs']
    tables = ('ticket_chat_commands','ticket_chat_questions','ticket_contract_amendments')
    require(type(inputs) is dict and set(inputs) == set(tables)|{'parent','bootstrap','inputs'})
    links = rows(connection,'SELECT chat_key FROM ticket_chat_runs WHERE run_id=?',(proof['run']['run_id'],))
    require(len(links) == 1 and type(inputs['parent']) is dict and inputs['parent'].get('chat_key') == links[0]['chat_key'])
    for table in tables:
        require(type(inputs[table]) is list)
        columns = [row[1] for row in connection.execute('PRAGMA table_info('+table+')')]
        require(columns)
        for values in inputs[table]:
            require(type(values) is list and len(values) == len(columns) and all(sql_scalar(table,column,value) for column,value in zip(columns,values)))
            value = dict(zip(columns,values)); require(value['run_id'] == proof['run']['run_id'])
            require('chat_key' not in value or value['chat_key'] == inputs['parent']['chat_key'])
            if table == 'ticket_chat_commands': require(value['status'] not in ('PENDING','ACCEPTED'))
            if table == 'ticket_chat_questions': require(value['status'] != 'OPEN')
            if table == 'ticket_contract_amendments': require(value['active_owner'] != 1)
    for name,table in (('parent','ticket_chats'),('bootstrap','desktop_requests')):
        require(type(inputs[name]) is dict and set(inputs[name]) == {row[1] for row in connection.execute('PRAGMA table_info('+table+')')})
        require(all(type(value) in (str,int,type(None)) for value in inputs[name].values()))
    require(inputs['parent']['create_request_key'] == inputs['bootstrap']['request_key'] and inputs['bootstrap']['action'] == 'CREATE' and inputs['bootstrap']['status'] == 'SUCCEEDED' and inputs['bootstrap']['target_kind'] == 'TICKET_CHAT' and inputs['bootstrap']['target_key'] == inputs['parent']['chat_key'])
    input_columns = [row[1] for row in connection.execute('PRAGMA table_info(ticket_chat_inputs)')]
    require(input_columns and type(inputs['inputs']) is list and all(type(value) is list and len(value) == len(input_columns) and all(sql_scalar('ticket_chat_inputs',column,item) for column,item in zip(input_columns,value)) for value in inputs['inputs']))
    require('chat_key' in input_columns and all(dict(zip(input_columns,value))['chat_key'] == inputs['parent']['chat_key'] for value in inputs['inputs']))


def sql_scalar(table, column, value):
    if type(value) in (str,int,type(None)):
        return True
    return type(value) is float and math.isfinite(value) and (table,column) in {('ticket_chat_questions','opened_at'),('ticket_chat_inputs','started_at'),('ticket_chat_inputs','completed_at')}


def admission_authorization(proof):
    authorization = proof['authorization']; required = set('run_id issue_key spec_revision contract_sha256 snapshot_json observed_at'.split())
    require(type(authorization) is dict and set(authorization) == required)
    before = proof['run']; require(all(authorization[key] == before[key] for key in ('run_id','issue_key','spec_revision','contract_sha256')))
    observed = utc(authorization['observed_at'])
    admitted = utc(proof['admitted_at'])
    require(observed.utcoffset() == datetime.timedelta(0) and -5 <= (admitted-observed).total_seconds() <= 60)
    snapshot = decode(authorization['snapshot_json']); original = decode(before['snapshot_json'])
    require(type(snapshot) is dict and snapshot['id'] == original['id'] and type(snapshot['labels']) is list and all(type(label) is str for label in snapshot['labels']) and type(snapshot['status']) is str)
    allowed = ('ai-ready','ai-running','ai-verifying')
    require(any(label in allowed for label in snapshot['labels']) and 'ai-blocked' not in snapshot['labels'] and 'spec-needed' not in snapshot['labels'] and snapshot['status'].lower() in ('to do','in dev','in progress'))


def instruction_claim(connection, worker, task, claim, before, validate_supplement=True):
    binding = decode(worker['binding_json'])
    require(binding['role'] == task['role'] == 'feature-writer' and binding['stage'] == task['stage'] == 'REPAIRING' and binding['mode'] == 'SOURCE')
    require(binding['task_key'] == task['task_key'] and binding['run_id'] == task['run_id'] == before['run_id'] and binding['spec_revision'] == before['spec_revision'] and binding['contract_sha256'] == before['contract_sha256'])
    access = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(worker['reservation_key'],))
    require(len(access) == 1 and binding['reservation_key'] == worker['reservation_key'] and binding['reservation_generation'] == access[0]['generation'] and access[0]['mode'] == 'SOURCE' and access[0]['canonical_path'] == before['worktree'])
    require(binding['prompt_sha256'] == binding['input_sha256'] == task['prompt_sha256'] and hex_digest(task['prompt_sha256']))
    mappings = rows(connection,'SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?',(task['task_key'],task['prompt_sha256']))
    require(len(mappings) == 1)
    mapping = mappings[0]; require(set(mapping) == set('task_key prompt_sha256 instruction_binding_sha256 run_id role created_at'.split()) and mapping['run_id'] == before['run_id'] and mapping['role'] == 'feature-writer')
    snapshots = rows(connection,'SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?',(mapping['instruction_binding_sha256'],))
    require(len(snapshots) == 1)
    snapshot = snapshots[0]
    require(set(snapshot) == set('binding_sha256 run_id role binding_json bundle_json bundle_sha256 created_at'.split()) and snapshot['role'] == 'ci-repair-writer' and snapshot['run_id'] == before['run_id'] and sha(snapshot['binding_json'].encode()) == snapshot['binding_sha256'] and sha(snapshot['bundle_json'].encode()) == snapshot['bundle_sha256'])
    packet, bundle = decode(snapshot['binding_json']), decode(snapshot['bundle_json'])
    require(packet['role'] == 'feature-writer' and packet['stage'] == 'REPAIRING' and packet['code_repair_round'] == claim['round'] and all(packet[key] == before[key] for key in ('run_id','issue_key','spec_revision','contract_sha256')))
    scope = push_budget_decode(claim['claim_json'],'claim'); repair = packet['ci_repair']; diagnosis = claim_diagnosis(connection,claim)
    extra = []
    if packet.get('ci_repair_scope_extension') is not None:
        receipt = packet['ci_repair_scope_extension']; supplement = packet['ci_evidence_successor']
        captured = rows(connection,'SELECT * FROM ticket_ci_repair_evidence_successors WHERE successor_key=?',(supplement['successor_key'],))
        require(len(captured) == 1 and captured[0]['run_id'] == before['run_id'] and captured[0]['claim_key'] == claim['claim_key'])
        captured = captured[0]; proof = push_budget_decode(captured['proof_json'],'successor')
        require(sha(captured['proof_json'].encode()) == captured['proof_sha256'] == supplement['proof_sha256'] and proof['policy_receipt'] == receipt)
        policy_shape(receipt,proof['run']); extra = scope_extension(receipt,before,claim)
        require(captured['attempt_index'] == supplement['attempt_index'] and proof['run']['code_repair_round'] == before['code_repair_round'])
    require(type(repair) is dict and repair['claim_key'] == claim['claim_key'] and repair['failed_candidate_sha'] == scope['prior_run']['candidate_sha'] and repair['allowed_writer_paths'] == sorted(set(scope['allowed_writer_paths']+extra)) and repair['required_generated_paths'] == scope['required_generated_paths'])
    require(packet['candidate_sha'] == binding['expected_sha'] and hex_digest(packet['candidate_sha'],40))
    findings = decode(packet['repair_findings']); require(findings['kind'] == 'TICKET_CI_REPAIR' and findings['claim_key'] == claim['claim_key'])
    require(type(repair['diagnosis']) is dict and repair['diagnosis'] == diagnosis)
    require(type(bundle) is dict and set(bundle) == {'shared_instructions','instruction_delivery'} and type(bundle['instruction_delivery']) is str and bundle['instruction_delivery'] and type(bundle['shared_instructions']) is list)
    paths = []
    for instruction in bundle['shared_instructions']:
        require(type(instruction) is dict and set(instruction) == {'path','relative_path','content','sha256'} and all(type(value) is str for value in instruction.values()) and 1 <= len(instruction['content'].encode()) <= 65536 and sha(instruction['content'].encode()) == instruction['sha256'])
        paths.append(instruction['relative_path'])
    required = set('AGENTS.md rules/comment-discipline.mdc rules/gitlab-preferences.mdc rules/go-test-style.mdc rules/skills-directory.mdc skills/draft-feature-cycle/SKILL.md skills/select-tests/SKILL.md skills/fix-mr-pipeline/SKILL.md'.split())
    require(required <= set(paths) and len(set(paths)) == len(paths) and sum(len(value['content'].encode()) for value in bundle['shared_instructions']) <= 262144)

    if validate_supplement:
        instruction_supplement(connection,worker,claim,before,packet,access[0])
    return packet


CHECK_HELPER_SHA = 'fc9cfb83431dc117e36fd6bded44d086650dca56bb1753e7f01419cae52fea4f'
CHECK_COMPANION_SHA = '87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b'
CHECK_GIT = '/Library/Developer/CommandLineTools/usr/bin/git'
CHECK_PROFILE = '(version 1)(deny default)(allow process-exec (literal "'+CHECK_GIT+'"))(allow file-read*)(allow file-write* (literal "/dev/null"))(allow sysctl-read)(allow mach-lookup)'


def consumed_check(connection, worker, access, next_binding):
    binding = decode(worker['binding_json'])
    require(worker['status'] == 'CONSUMED' and sha(worker['binding_json'].encode()) == worker['binding_sha256'] and sha(worker['output_json'].encode()) == worker['output_sha256'])
    require(decode(worker['output_json'])['status'] == 'CONTINUE')
    admission_stop(connection,worker,access,{'kind':'CONTINUE'})
    receipt = {key:worker[key] for key in ('request_key','binding_sha256','output_sha256','consumed_at','owner_stopped_at')}
    require(decode(access['release_receipt_json']) == receipt)
    require(utc(access['acquired_at']) <= utc(worker['owner_stopped_at']) <= utc(worker['consumed_at']) <= utc(access['released_at']))
    pin = rows(connection,'SELECT base_sha FROM ticket_review_bases WHERE run_id=?',(worker['run_id'],))
    require(len(pin) == 1 and pin[0]['base_sha'] == binding['base_sha'])
    limits = connection.execute('SELECT COUNT(*),MAX(length(CAST(binding_json AS BLOB))),MAX(length(CAST(receipt_json AS BLOB))) FROM controller_checks WHERE reservation_key=?',(access['reservation_key'],)).fetchone()
    require(1 <= limits[0] <= 94 and limits[1] <= 2_097_152 and limits[2] is not None and limits[2] <= 2_097_152)
    checks = rows(connection,'SELECT * FROM controller_checks WHERE reservation_key=?',(access['reservation_key'],))
    require(checks and len(checks) <= 64)
    matched = 0
    scope = {'run_id':worker['run_id'],'candidate_sha':next_binding['expected_sha'],'spec_revision':binding['spec_revision'],'contract_sha256':binding['contract_sha256'],'base_sha':binding['base_sha'],'worker_request_key':worker['request_key'],'worker_binding_sha256':worker['binding_sha256'],'worker_output_sha256':worker['output_sha256'],'worker_stop_sha256':sha(worker['owner_stop_json'].encode()),'reservation_key':access['reservation_key'],'generation':access['generation'],'workspace_binding_sha256':sha(access['binding_json'].encode()),'cwd':access['canonical_path']}
    for check in checks:
        require(set(check) == set('check_key worker_request_key reservation_key binding_json binding_sha256 phase helper_pid receipt_json receipt_sha256 error'.split()))
        require(check['phase'] == 'COMPLETE' and check['error'] is None and check['worker_request_key'] == worker['request_key'] and check['reservation_key'] == access['reservation_key'])
        require(sha(check['binding_json'].encode()) == check['binding_sha256'] and sha(check['receipt_json'].encode()) == check['receipt_sha256'])
        fixed, result = decode(check['binding_json']), decode(check['receipt_json'])
        transport = set('database root spool spool_device spool_inode companion_path companion_sha256 invocation helper_path helper_sha256 root_device root_inode check_key'.split())
        require(set(fixed) == set(scope)|set('action program program_sha256 profile_sha256'.split())|transport and all(fixed[key] == value for key,value in scope.items()))
        require(fixed['check_key'] == check['check_key'] and fixed['action'] == 'git-diff-check' and fixed['program'] == CHECK_GIT and hex_digest(fixed['program_sha256']) and fixed['profile_sha256'] == sha(CHECK_PROFILE.encode()))
        require(fixed['helper_sha256'] == CHECK_HELPER_SHA and fixed['companion_sha256'] == CHECK_COMPANION_SHA and fixed['root'] == access['canonical_path'] and hex_digest(fixed['invocation']))
        owned = decode(access['binding_json'])
        require(all(fixed[key] == owned[key] for key in ('root_device','root_inode')))
        for key,basename in (('helper_path','worker_check_executor.py'),('companion_path','worker_file_companion.py')):
            path = fixed[key]
            require(type(path) is str and os.path.isabs(path) and os.path.normpath(path) == path and os.path.basename(path) == basename and os.path.commonpath([path,access['canonical_path']]) != access['canonical_path'])
        require(all(type(fixed[key]) is int and fixed[key] > 0 for key in ('root_device','root_inode','spool_device','spool_inode')))
        require(set(result) == set('version binding_json helper_pid pid cwd base_sha candidate_sha termination result output_base64 output_sha256 timed_out overflow'.split()))
        require(type(result['version']) is int and result['version'] == 1 and result['binding_json'] == check['binding_json'])
        require(type(check['helper_pid']) is int and check['helper_pid'] > 0 and type(result['helper_pid']) is int and result['helper_pid'] == check['helper_pid'] and type(result['pid']) is int and result['pid'] > 0)
        require(all(result[key] == fixed[key] for key in ('cwd','base_sha','candidate_sha')) and result['timed_out'] is False and result['overflow'] is False and result['termination'] == {'kind':'exited','code':0} and type(result['termination']['code']) is int and result['result'] == 'PASS')
        require(type(result['output_base64']) is str and len(result['output_base64']) <= 1_398_104)
        try:
            output = base64.b64decode(result['output_base64'],validate=True)
        except (ValueError,binascii.Error):
            reject()
        require(len(output) <= 1_048_576 and sha(output) == result['output_sha256'])
        matched += 1
    require(matched == 1)


def instruction_supplement(connection, worker, claim, before, packet, access):
    candidates = rows(connection,'SELECT s.*, a.generation AS destination_generation FROM ticket_ci_repair_evidence_successors s JOIN workspace_access a ON a.reservation_key=s.new_reservation_key WHERE s.run_id=? AND s.claim_key=? AND a.generation<=? ORDER BY s.attempt_index',(worker['run_id'],claim['claim_key'],access['generation']))
    if not candidates:
        require('ci_evidence_successor' not in packet and 'ci_evidence_successor_evidence' not in packet)
        return
    supplement = candidates[-1]; supplement.pop('destination_generation')
    expected = {'version':1,'kind':'CI_EVIDENCE_SUCCESSOR_PACKET_V1','successor_key':supplement['successor_key'],'proof_sha256':supplement['proof_sha256'],'evidence_sha256':supplement['evidence_sha256'],'evidence_content_sha256':supplement['evidence_content_sha256'],'attempt_index':supplement['attempt_index']}
    require(packet.get('ci_evidence_successor') == expected and packet.get('ci_evidence_successor_evidence') == decode(supplement['evidence_json'],262144))
    if worker['request_key'] == supplement['new_request_key']:
        return
    start = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(supplement['new_reservation_key'],))
    require(len(start) == 1 and start[0]['generation'] < access['generation'])
    path = rows(connection,"SELECT * FROM workspace_access WHERE run_id=? AND mode='SOURCE' AND generation>=? AND generation<=? ORDER BY generation",(worker['run_id'],start[0]['generation'],access['generation']))
    require(2 <= len(path) <= 1024 and path[0] == start[0] and path[-1] == access and len({value['generation'] for value in path}) == len(path))
    previous = None
    for step in path:
        require(all(step[key] == start[0][key] for key in ('run_id','task_key','canonical_path','git_dir','common_dir')) and step['task_key'] == worker['task_key'])
        found = rows(connection,'SELECT * FROM worker_evidence WHERE request_key=?',(step['request_key'],)); require(len(found) == 1)
        found = found[0]; wb = decode(found['binding_json']); owned = decode(step['binding_json'])
        require(found['reservation_key'] == step['reservation_key'] and found['thread_id'] == worker['thread_id'] and found['policy_json'] == worker['policy_json'] and sha(found['binding_json'].encode()) == found['binding_sha256'])
        require(all(owned[key] == step[key] for key in ('run_id','task_key','request_key','reservation_key','mode','git_dir','common_dir')) and owned['path'] == step['canonical_path'])
        require(all(owned[key] == wb[key] for key in ('spec_revision','contract_sha256','expected_sha','prompt_sha256')))
        task = {key:wb[key] for key in ('task_key','run_id','role','stage','prompt_sha256')}
        prior_packet = instruction_claim(connection,found,task,claim,before,False)
        require(prior_packet.get('ci_evidence_successor') == expected and prior_packet.get('ci_evidence_successor_evidence') == packet['ci_evidence_successor_evidence'])
        if previous:
            old, old_access, old_binding = previous
            require(utc(old_access['released_at']) <= utc(step['acquired_at']) and old_access['generation'] < step['generation'])
            require(all(wb.get(key) == old_binding.get(key) for key in ('run_id','task_key','role','stage','mode','model','reasoning_effort','schema','policy','contract_sha256','spec_revision','base_sha','worktree')))
            previous_owned = decode(old_access['binding_json'])
            require(all(owned[key] == previous_owned[key] for key in ('root_device','root_inode')))
            consumed_check(connection,old,old_access,wb)
        previous = found, step, wb


def current_policy(connection, execution, binding, run):
    receipt_keys = set('version kind workflow_path workflow_sha256 workflow_stat configured_limit effective_limit scope dispatcher_id repo_key cached_policy_sha256'.split())
    receipt = binding['ci_repair_policy_receipt']
    if type(receipt) is dict and receipt.get('version') in (2,3):
        receipt_keys.add('scope_extension')
    require(type(receipt) is dict and set(receipt) == receipt_keys and receipt == execution['ci_repair_policy_receipt'] and type(receipt['version']) is int and (receipt['version'],receipt['kind']) in ((1,'CI_REPAIR_POLICY_V1'),(2,'CI_REPAIR_POLICY_V2'),(3,'CI_REPAIR_POLICY_V3')))
    actual = connection.execute('SELECT candidate_handoff FROM runs WHERE run_id=?',(execution['run_id'],)).fetchone()
    require(actual is not None)
    intent = decode(actual['candidate_handoff'])
    require(intent['binding_json'] == execution['intent_json'] and sha(intent['binding_json'].encode()) == intent['binding_sha256'] == execution['intent_sha256'] and decode(intent['binding_json']) == binding)
    require(type(receipt['configured_limit']) is int and receipt['configured_limit'] >= 1 and type(receipt['effective_limit']) is int and receipt['effective_limit'] == min(receipt['configured_limit'],{1:5,2:7,3:10}[receipt['version']]))
    require(receipt['repo_key'] == run['repo_key'] and hex_digest(receipt['workflow_sha256']) and hex_digest(receipt['cached_policy_sha256']))
    if receipt.get('scope_extension') is not None:
        claim = rows(connection,'SELECT * FROM ticket_ci_repair_claims WHERE claim_key=?',(binding['ci_repair']['claim_key'],))
        require(len(claim) == 1)
        scope_extension(receipt,run,claim[0])
    history = rows(connection,'SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id=? ORDER BY attempt_index DESC LIMIT 1',(run['run_id'],))
    if history and history[0]['claim_key'] == binding.get('ci_repair',{}).get('claim_key'):
        captured = push_budget_decode(history[0]['proof_json'],'successor')['policy_receipt']
        require(receipt.get('scope_extension') == captured.get('scope_extension'))
    control = connection.execute('SELECT dispatcher_id FROM control WHERE scope=?',(receipt['scope'],)).fetchone()
    require(control is not None and control['dispatcher_id'] == receipt['dispatcher_id'])
    path = receipt['workflow_path']; root = binding['worktree']
    require(type(path) is str and os.path.isabs(path) and os.path.realpath(path) == path and os.path.commonpath([path,root]) != root)
    descriptor = os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1 and not before.st_mode & 0o022 and before.st_size <= 1_048_576)
        observed = {'inode':before.st_ino,'device':before.st_dev,'rdev':before.st_rdev,'size':before.st_size,'mtime_seconds':int(before.st_mtime),'uid':before.st_uid,'mode':before.st_mode}
        require(type(receipt['workflow_stat']) is dict and set(receipt['workflow_stat']) == set(observed) and all(type(value) is int for value in receipt['workflow_stat'].values()) and receipt['workflow_stat'] == observed)
        raw = bytearray()
        while len(raw) <= 1_048_576:
            chunk = os.read(descriptor,min(65536,1_048_577-len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        require(len(raw) == before.st_size and sha(raw) == receipt['workflow_sha256'])
        require(os.fstat(descriptor) == before and os.stat(path,follow_symlinks=False) == before)
    finally:
        os.close(descriptor)
    return receipt['effective_limit']


ROLLOVER_KEYS = set('version kind archived_claim_key prior_reservation_key prior_envelope_sha256 prior_binding_sha256 prior_receipt_sha256 verifier_request_key verifier_binding_sha256 verifier_output_sha256 ci_evidence_sha256 ci_snapshots_sha256 observed_at policy_receipt'.split())
DELIVERY_KEYS = set('version kind workflow_path workflow_sha256 workflow_stat scope dispatcher_id repo_key cached_policy_sha256 control'.split())


def rollover_fence(connection, execution, binding, run):
    qualifier = binding['verified_ci_rollover']
    require(type(qualifier) is dict and set(qualifier) == ROLLOVER_KEYS and execution['verified_ci_rollover'] == qualifier)
    require(type(qualifier['version']) is int and qualifier['version'] == 1 and qualifier['kind'] == 'VERIFIED_CI_ROLLOVER_V1')
    require(type(qualifier['observed_at']) is str and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z',qualifier['observed_at']) is not None)
    now = datetime.datetime.now(datetime.timezone.utc)
    require(-5 <= (now-utc(qualifier['observed_at'])).total_seconds() <= 60)
    require(hex_digest(qualifier['ci_snapshots_sha256']))  # Controller-captured provenance, not raw snapshot verification.
    actual = connection.execute('SELECT candidate_handoff,ci_evidence_json FROM runs WHERE run_id=?',(run['run_id'],)).fetchone()
    require(actual is not None and actual['ci_evidence_json'] == run['ci_evidence_json'] and sha(actual['ci_evidence_json'].encode()) == qualifier['ci_evidence_sha256'])
    intent = decode(actual['candidate_handoff'])
    require(intent['binding_json'] == execution['intent_json'] and intent['binding_sha256'] == execution['intent_sha256'] == sha(execution['intent_json'].encode()) and decode(execution['intent_json']) == binding)
    policy = qualifier['policy_receipt']
    require(type(policy) is dict and set(policy) == DELIVERY_KEYS and type(policy['version']) is int and policy['version'] == 1 and policy['kind'] == 'VERIFIED_CI_DELIVERY_POLICY_V1' and policy['repo_key'] == run['repo_key'])
    require(hex_digest(policy['workflow_sha256']) and hex_digest(policy['cached_policy_sha256']) and all(type(policy[key]) is str and policy[key] for key in ('scope','dispatcher_id','repo_key')))
    tick = policy['control']; require(type(tick) is dict and set(tick) == set('scope dispatcher_id generation tick_id'.split()))
    require(type(tick['generation']) is int and tick['generation'] >= 0 and type(tick['tick_id']) is str and tick['tick_id'] and tick['scope'] == policy['scope'] and tick['dispatcher_id'] == policy['dispatcher_id'])
    control = connection.execute('SELECT * FROM control WHERE scope=?',(policy['scope'],)).fetchone()
    require(control is not None and control['status'] == 'ACTIVE' and all(control[key] == value for key,value in tick.items()) and utc(control['lease_expires_at']) > now)
    # Reuse the same exact file/stat checks, but do not invent an ON/cap admission.
    path = policy['workflow_path']; require(type(path) is str and os.path.isabs(path) and os.path.realpath(path) == path and os.path.commonpath([path,run['worktree']]) != run['worktree'])
    descriptor = os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid() and before.st_nlink == 1 and not before.st_mode & 0o022 and before.st_size <= 1_048_576)
        observed = {'inode':before.st_ino,'device':before.st_dev,'rdev':before.st_rdev,'size':before.st_size,'mtime_seconds':int(before.st_mtime),'uid':before.st_uid,'mode':before.st_mode}
        require(type(policy['workflow_stat']) is dict and set(policy['workflow_stat']) == set(observed) and all(type(value) is int for value in policy['workflow_stat'].values()) and observed == policy['workflow_stat'])
        raw = bytearray()
        while len(raw) <= 1_048_576:
            chunk = os.read(descriptor,min(65536,1_048_577-len(raw)))
            if not chunk: break
            raw.extend(chunk)
        require(len(raw) == before.st_size and sha(raw) == policy['workflow_sha256'] and os.fstat(descriptor) == before and os.stat(path,follow_symlinks=False) == before)
    finally:
        os.close(descriptor)


    final_now = datetime.datetime.now(datetime.timezone.utc)
    require(-5 <= (final_now-utc(qualifier['observed_at'])).total_seconds() <= 60 and utc(control['lease_expires_at']) > final_now)


def rollover_ci_evidence(run, qualifier):
    evidence = decode(run['ci_evidence_json'])
    fields = set('mr_url iid sha source_branch target_branch draft reviewers_count assignee_id mr_state pipeline_id pipeline_url pipeline_sha pipeline_ref pipeline_source pipeline_status status required_jobs failed_jobs findings source_binding'.split())
    require(type(evidence) is dict and set(evidence) in (fields,fields|{'pipeline_selector'}))
    require(evidence['status'] == 'PASS' and evidence['failed_jobs'] == [] and evidence['findings'] == [])
    require(evidence['sha'] == run['candidate_sha'] == run['ci_preflight_sha'] and evidence['iid'] == run['mr_iid'] and type(evidence['iid']) is int and evidence['iid'] > 0 and evidence['mr_url'] == run['mr_url'])
    require(evidence['source_branch'] == run['branch'] and evidence['target_branch'] == run['base_branch'] and evidence['draft'] is True and type(evidence['reviewers_count']) is int and evidence['reviewers_count'] == 0 and evidence['assignee_id'] == 11599766 and evidence['mr_state'] == 'opened')
    require(type(evidence['pipeline_id']) is int and evidence['pipeline_id'] > 0 and evidence['pipeline_id'] == run['ci_pipeline_id'] and evidence['pipeline_url'] == run['ci_pipeline_url'] and evidence['pipeline_status'] == 'success' and evidence['pipeline_source'] == 'merge_request_event')
    source = evidence['source_binding']
    if source == {'kind':'HEAD','candidate_sha':run['candidate_sha']}:
        require(evidence['pipeline_sha'] == run['candidate_sha'] and evidence['pipeline_ref'] == 'refs/merge-requests/'+str(run['mr_iid'])+'/head')
    else:
        require(type(source) is dict and set(source) == {'kind','candidate_sha','merge_sha','target_parent_sha'} and source['kind'] == 'MERGE' and source['candidate_sha'] == run['candidate_sha'] and source['merge_sha'] == evidence['pipeline_sha'] and hex_digest(source['merge_sha'],40) and hex_digest(source['target_parent_sha'],40) and source['target_parent_sha'] != run['candidate_sha'])
        require(evidence['pipeline_ref'] == 'refs/merge-requests/'+str(run['mr_iid'])+'/merge')
    required = evidence['required_jobs']
    require(type(required) is list and len(required) == 1 and set(required[0]) == {'id','name','status','web_url'} and type(required[0]['id']) is int and required[0]['id'] > 0 and required[0]['name'] == 'bazel' and required[0]['status'] == 'success' and type(required[0]['web_url']) is str and required[0]['web_url'])


def rollover_verifier(connection, binding, run, qualifier):
    key = run['run_id']+':change-verifier:'+str(run['verifier_round'])
    tasks = rows(connection,'SELECT * FROM factory_tasks WHERE task_key=? AND run_id=?',(key,run['run_id']))
    require(len(tasks) == 1 and tasks[0]['status'] == 'CONSUMED' and tasks[0]['role'] == 'change-verifier')
    task = tasks[0]
    found = rows(connection,"SELECT * FROM worker_evidence WHERE request_key=? AND run_id=? AND status='CONSUMED'",(qualifier['verifier_request_key'],run['run_id']))
    require(len(found) == 1); worker = found[0]; wb = decode(worker['binding_json'])
    require(worker['task_key'] == key and worker['binding_sha256'] == qualifier['verifier_binding_sha256'] == sha(worker['binding_json'].encode()) and worker['output_sha256'] == qualifier['verifier_output_sha256'] == sha(worker['output_json'].encode()))
    require(all(worker[key] == task[key] for key in ('thread_id','turn_id','output_json')) and all(wb[key] == task[key] for key in ('role','stage','model','reasoning_effort','prompt_sha256')))
    require(all(wb[key] == run[key] for key in ('run_id','spec_revision','contract_sha256')) and wb['role'] == 'change-verifier' and wb['stage'] == task['stage'] == 'VERIFYING' and wb['mode'] == 'REVIEW' and wb['expected_sha'] == run['candidate_sha'])
    require(binding['verifier'] and all(worker[key] == value for key,value in binding['verifier'].items()) and binding['verifier']['request_key'] == worker['request_key'])
    output = decode(worker['output_json']); require(output['status'] == 'PASS' and output['candidate_sha'] == run['candidate_sha'])
    access = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(worker['reservation_key'],)); require(len(access) == 1 and access[0]['mode'] == 'REVIEW' and access[0]['canonical_path'] == run['worktree'] and access[0]['released_at'] is not None)
    require(access[0]['run_id'] == worker['run_id'] == run['run_id'] and access[0]['task_key'] == worker['task_key'] == task['task_key'] == wb['task_key'] == key and access[0]['request_key'] == worker['request_key'])
    require(access[0]['reservation_key'] == worker['reservation_key'] == wb['reservation_key'] and type(wb['reservation_generation']) is int and wb['reservation_generation'] > 0 and access[0]['generation'] == wb['reservation_generation'])
    source = decode(access[0]['binding_json'])
    require(set(source) == set('allowed_root branch candidate_sha common_dir contract_sha256 expected_sha git_dir mode path prompt_sha256 request_key reservation_key root_device root_inode run_id run_state spec_revision task_key'.split()))
    require(all(type(source[key]) is int and source[key] > 0 for key in ('root_device','root_inode','spec_revision')))
    require(all(source[key] == access[0][key] for key in ('run_id','task_key','request_key','reservation_key','mode','git_dir','common_dir')) and source['run_state'] == 'VERIFYING')
    require(all(source[key] == run[key] for key in ('candidate_sha','spec_revision','contract_sha256','branch')) and source['expected_sha'] == run['candidate_sha'] and source['prompt_sha256'] == wb['prompt_sha256'])
    require(all(source[key] == binding['checkout'][key] for key in ('path','git_dir','common_dir','root_device','root_inode')) and source['path'] == access[0]['canonical_path'])
    require(type(source['allowed_root']) is str and os.path.isabs(source['allowed_root']) and os.path.normpath(source['allowed_root']) == source['allowed_root'] and os.path.commonpath([source['allowed_root'],source['path']]) == source['allowed_root'])
    admission_stop(connection,worker,access[0],{'kind':'ROLLOVER_VERIFIER'})
    require(decode(access[0]['release_receipt_json']) == {key:worker[key] for key in ('request_key','binding_sha256','output_sha256','consumed_at','owner_stopped_at')})
    require(utc(worker['owner_stopped_at']) <= utc(worker['consumed_at']) <= utc(access[0]['released_at']))
    require(wb['input_sha256'] == wb['prompt_sha256'] == task['prompt_sha256'])
    mapping = rows(connection,'SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?',(key,task['prompt_sha256']))
    require(len(mapping) == 1 and mapping[0]['run_id'] == run['run_id'] and mapping[0]['role'] == 'change-verifier')
    snapshots = rows(connection,'SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?',(mapping[0]['instruction_binding_sha256'],)); require(len(snapshots) == 1)
    snapshot = snapshots[0]
    require(snapshot['run_id'] == run['run_id'] and snapshot['role'] == 'change-verifier' and sha(snapshot['binding_json'].encode()) == snapshot['binding_sha256'] and sha(snapshot['bundle_json'].encode()) == snapshot['bundle_sha256'])
    packet,bundle = decode(snapshot['binding_json']),decode(snapshot['bundle_json'])
    require(all(packet[key] == run[key] for key in ('run_id','spec_revision','contract_sha256','candidate_sha','verifier_round')) and packet['role'] == 'change-verifier' and packet['stage'] == 'VERIFYING')
    require(type(bundle) is dict and set(bundle) == {'shared_instructions','instruction_delivery'} and type(bundle['instruction_delivery']) is str and bundle['instruction_delivery'])
    require(type(bundle['shared_instructions']) is list)
    paths=[]
    for instruction in bundle['shared_instructions']:
        require(type(instruction) is dict and set(instruction) == {'path','relative_path','content','sha256'} and all(type(value) is str for value in instruction.values()) and 1 <= len(instruction['content'].encode()) <= 65536 and sha(instruction['content'].encode()) == instruction['sha256'])
        paths.append(instruction['relative_path'])
    required=set('AGENTS.md rules/comment-discipline.mdc rules/gitlab-preferences.mdc rules/go-test-style.mdc rules/skills-directory.mdc skills/verify-feature-delivery/SKILL.md skills/verify-feature-delivery/references/verdict-contract.md skills/review-code/references/review-criteria.md'.split())
    require(required <= set(paths) and len(set(paths)) == len(paths) and sum(len(value['content'].encode()) for value in bundle['shared_instructions']) <= 262144)


    return worker


def verified_rollover(connection, execution, binding, run, latest, latest_task):
    rollover_fence(connection,execution,binding,run)
    qualifier = binding['verified_ci_rollover']
    size = connection.execute('SELECT length(CAST(release_receipt_json AS BLOB)) FROM workspace_access WHERE reservation_key=? AND run_id=?',(qualifier['prior_reservation_key'],run['run_id'])).fetchone()
    require(size is not None and type(size[0]) is int and 1 <= size[0] <= 12_582_912)
    prior = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?',(qualifier['prior_reservation_key'],run['run_id']))
    require(len(prior) == 1); access = prior[0]
    require(access['mode'] == 'MAINTENANCE' and access['task_key'] is None and access['released_at'] is not None and sha(access['release_receipt_json'].encode()) == qualifier['prior_envelope_sha256'])
    intent = decode_push_envelope(access['release_receipt_json'])
    require(set(intent) == set('version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json receipt_json receipt_sha256 remote_sha'.split()) and type(intent['version']) is int and intent['version'] == 1 and intent['kind'] == 'TICKET_PUSH' and intent['phase'] == 'COMPLETED')
    original, original_execution, receipt = decode(intent['binding_json']),decode_push_execution(intent['execution_json']),decode_push_receipt(intent['receipt_json'], intent['execution_json'])
    require(hex_digest(execution['helper_sha256']) and original_execution['helper_sha256'] in ('dc7ac631720ab9cdd167b186eef24fb5944047dc4f091e0b2fc29c83cb3a68f5','a362cc92abe82a14f2ae9f9f21afaa65bce8a47cc88820a4e2e7286b749ccd16','39646c62bb345a1f4c3776465545bf8afc29a870955e1e608b093fb869ffb8a7','f5513fb5eda319b4df8d2796b37ec0efec08afec3793aab4962de3590c73255b','8a4b90014af4b1e56e21c1698ba3657e08f7e57b78de58aad33bcebab43b0950','59ca083a8a8771e261604acb7c946a92ef65576fec11aa161fbc0f89dd1335e0',execution['helper_sha256']))
    require(original['state'] == 'CI_PUSHING' and 'verified_ci_rollover' not in original and 'verified_ci_rollover' not in original_execution)
    require(intent['binding_sha256'] == qualifier['prior_binding_sha256'] == sha(intent['binding_json'].encode()) and intent['receipt_sha256'] == qualifier['prior_receipt_sha256'] == sha(intent['receipt_json'].encode()))
    require(intent['reservation_key'] == access['reservation_key'] == 'ticket-push:'+intent['binding_sha256'] and intent['reservation_generation'] == access['generation'] and access['request_key'] == access['reservation_key'])
    require(original['verifier_round']+1 == run['verifier_round'] and type(original['verifier_round']) is int and intent['remote_sha'] == run['candidate_sha'])
    require(all(original[key] == run[key] for key in ('run_id','issue_key','repo_path','worktree','branch','base_branch','candidate_sha','spec_revision','contract_sha256','code_repair_round')) and original['origin'] == binding['origin'] and original['checkout'] == binding['checkout'])
    owned = decode(access['binding_json']); require(owned['expected_sha'] == run['candidate_sha'] and all(owned[key] == original['checkout'][key] for key in ('path','git_dir','common_dir','root_device','root_inode')) and access['canonical_path'] == run['worktree'] and access['git_dir'] == owned['git_dir'] and access['common_dir'] == owned['common_dir'])
    require(all(original_execution[key] == value for key,value in {'run_id':run['run_id'],'intent_json':intent['binding_json'],'intent_sha256':intent['binding_sha256'],'invocation':intent['owner_nonce']}.items()) and hex_digest(intent['owner_nonce']))
    receipt_keys=set('version execution_json helper_pid child_pid termination timed_out overflow output_base64 output_sha256'.split())
    extras=set('stderr_code stderr_bytes stderr_sha256'.split())
    require(set(receipt) in (receipt_keys,receipt_keys|extras) and type(receipt['version']) is int and receipt['version'] == 1 and receipt['execution_json'] == intent['execution_json'])
    require(type(intent['helper_pid']) is int and intent['helper_pid'] > 0 and type(receipt['helper_pid']) is int and receipt['helper_pid'] == intent['helper_pid'] and type(receipt['child_pid']) is int and receipt['child_pid'] > 0)
    terminal=receipt['termination']; require(type(terminal) is dict and (set(terminal) == {'kind','code'} and terminal['kind'] == 'exited' and type(terminal['code']) is int and 0 <= terminal['code'] <= 255 or set(terminal) == {'kind','signal'} and terminal['kind'] == 'signaled' and type(terminal['signal']) is int and 1 <= terminal['signal'] <= 64))
    require(type(receipt['timed_out']) is bool and type(receipt['overflow']) is bool and type(receipt['output_base64']) is str and len(receipt['output_base64']) <= 87384)
    try: output=base64.b64decode(receipt['output_base64'],validate=True)
    except (ValueError,binascii.Error): reject()
    require(len(output) <= 65536 and sha(output) == receipt['output_sha256'])
    if extras <= set(receipt):
        require(receipt['stderr_code'] in ('GIT_EXIT_ZERO','GIT_EXIT_NONZERO','AUTHENTICATION_DENIED','TRANSPORT_FAILURE') and type(receipt['stderr_bytes']) is int and 0 <= receipt['stderr_bytes'] <= 16384 and hex_digest(receipt['stderr_sha256']))
    if 'ordinary_verifier_repair' in binding:
        ordinary = ordinary_repair(connection,execution,binding,run)
        require(qualifier['archived_claim_key'] is None and original['ordinary_verifier_repair'] == ordinary and 'ci_repair' not in original)
    else:
        claim = rows(connection,'SELECT * FROM ticket_ci_repair_claims WHERE claim_key=? AND run_id=?',(qualifier['archived_claim_key'],run['run_id']))
        require(len(claim) == 1 and type(claim[0]['round']) is int and claim[0]['round'] == run['code_repair_round'] and sha(claim[0]['claim_json'].encode()) == claim[0]['claim_sha256'])
        require(original['ci_repair'] == {'claim_key':claim[0]['claim_key'],'claim_sha256':claim[0]['claim_sha256'],'round':claim[0]['round']})
        instruction_claim(connection,latest,latest_task,claim[0],run)
    verifier = rollover_verifier(connection,binding,run,qualifier)
    require(utc(access['released_at']) <= utc(verifier['owner_stopped_at']))
    rollover_ci_evidence(run,qualifier)
    require(connection.execute("SELECT 1 FROM workspace_access WHERE released_at IS NULL AND reservation_key!=? AND (canonical_path=? OR git_dir=? OR (common_dir=? AND json_extract(binding_json,'$.branch')=?)) LIMIT 1",(decode(connection.execute('SELECT candidate_handoff FROM runs WHERE run_id=?',(run['run_id'],)).fetchone()[0])['reservation_key'],run['worktree'],binding['checkout']['git_dir'],binding['checkout']['common_dir'],run['branch'])).fetchone() is None)
    repeat=connection.execute("SELECT 1 FROM workspace_access WHERE run_id=? AND mode='MAINTENANCE' AND released_at IS NOT NULL AND json_extract(release_receipt_json,'$.phase')='COMPLETED' AND json_type(json_extract(release_receipt_json,'$.binding_json'),'$.verified_ci_rollover') IS NOT NULL AND json_extract(json_extract(release_receipt_json,'$.binding_json'),'$.candidate_sha')=? AND json_extract(json_extract(release_receipt_json,'$.binding_json'),'$.spec_revision')=? AND json_extract(json_extract(release_receipt_json,'$.binding_json'),'$.contract_sha256')=? AND json_extract(json_extract(release_receipt_json,'$.binding_json'),'$.verifier_round')=? LIMIT 1",(run['run_id'],run['candidate_sha'],run['spec_revision'],run['contract_sha256'],run['verifier_round'])).fetchone()
    require(repeat is None)


def complete_content(artifacts, snapshots):
    project = snapshots['mr']['project_id']
    jobs = snapshots['jobs']
    require(type(project) is int and project > 0 and type(jobs) is list)
    failed = {job['id'] for job in jobs if job.get('status') in ('failed','canceled','canceling') and job.get('allow_failure') is False}
    require(all(type(job) is int and job > 0 for job in failed))
    require(type(artifacts) is list and len(artifacts) <= 100)
    members = []
    for artifact in artifacts:
        require(type(artifact) is dict)
        job = artifact.get('job_id')
        if job not in failed or artifact.get('status') not in ('COMPLETE', 'PARTIAL'):
            continue
        provenance = artifact.get('provenance', {})
        arguments = provenance.get('metadata_arguments', {})
        reader_exit = provenance.get('owned_reader', {}).get('exit_status')
        if arguments.get('project_id') != str(project) or arguments.get('job_id') != str(job) or type(reader_exit) is not int or reader_exit != 0:
            continue
        require(type(artifact.get('members')) is list)
        for member in artifact['members']:
            require(type(member) is dict)
            if member.get('complete') is not True:
                continue
            path, text, member_sha = member.get('path'), member.get('text'), member.get('sha256')
            require(type(path) is str and 1 <= len(path.encode()) <= 1024 and type(text) is str and 1 <= len(text.encode()) <= 1_048_576 and '\ufffd' not in text and hex_digest(member_sha))
            members.append({'project_id':project, 'job_id':job, 'path':path, 'member_sha256':member_sha, 'text_sha256':sha(text.encode())})
    members.sort(key=lambda member:(member['job_id'],member['path']))
    require(len(members) <= 256 and len({(m['job_id'],m['path']) for m in members}) == len(members))
    return members


def admission_stop(connection, worker, access, horizon):
    stop, process = decode(worker['owner_stop_json']), decode(worker['owner_process_json'])
    require(type(stop) is dict and set(stop) == set('transport thread_id pid invocation_nonce exit_status cwd'.split()))
    require(stop['transport'] == 'owned_app_server' and stop['thread_id'] == worker['thread_id'] and stop['cwd'] == access['canonical_path'])
    require(type(stop['exit_status']) is int and type(stop['pid']) is str and re.fullmatch('[1-9][0-9]*',stop['pid']) is not None and hex_digest(stop['invocation_nonce']))
    require(process == {'pid':stop['pid'],'invocation_nonce':stop['invocation_nonce']} and type(worker['owner_stopped_at']) is str and worker['owner_stopped_at'])
    if stop['exit_status'] != 0:
        native_completion_receipt(connection,worker,access,horizon)


def completion_text(value, maximum):
    require(type(value) is str and 1 <= len(value.encode('utf-8')) <= maximum)


def completion_horizon(connection, worker, access, binding, output, horizon):
    require(type(horizon) is dict and type(horizon.get('kind')) is str)
    kind = horizon['kind']
    if kind == 'CI_SUCCESSOR':
        require(set(horizon) == {'kind','disposition_event','admitted_at'})
        require(worker['status'] == 'RESULT_RECORDED' and access['mode'] == 'SOURCE' and access['released_at'] is None and access['release_receipt_json'] is None)
        require(binding['role'] == 'feature-writer' and binding['stage'] == 'REPAIRING' and output['status'] == 'BLOCKED')
        disposition = horizon['disposition_event']
        require(type(disposition) is dict and set(disposition) == {'id','occurred_at','event_type','run_id','payload_json'})
        require(type(disposition['id']) is int and disposition['id'] > 0 and disposition['event_type'] == 'TICKET_NATIVE_WRITER_BLOCKED' and disposition['run_id'] == worker['run_id'])
        require(rows(connection,'SELECT * FROM events WHERE id=?',(disposition['id'],)) == [disposition])
        payload = decode(disposition['payload_json'])
        require(all(payload[key] == worker[key] for key in ('request_key','task_key','reservation_key','output_json','output_sha256')) and payload['reservation_generation'] == access['generation'])
        upper = utc(disposition['occurred_at'])
        require(upper <= utc(horizon['admitted_at']))
        return upper
    contexts = {
        'CONTINUE': ('feature-writer','SOURCE',{'CONTINUE'}),
        'ORDINARY_WRITER': ('feature-writer','SOURCE',{'COMPLETE'}),
        'ORDINARY_VERIFIER': ('change-verifier','REVIEW',{'BLOCK','REPAIR'}),
        'ROLLOVER_VERIFIER': ('change-verifier','REVIEW',{'PASS'})}
    require(set(horizon) == {'kind'} and kind in contexts)
    role, mode, verdicts = contexts[kind]
    require(worker['status'] == 'CONSUMED' and access['released_at'] is not None and binding['role'] == role and access['mode'] == binding['mode'] == mode and output['status'] in verdicts)
    if kind == 'ORDINARY_WRITER': require(binding['stage'] == 'REPAIRING')
    if kind in ('ORDINARY_VERIFIER','ROLLOVER_VERIFIER'): require(binding['stage'] == 'VERIFYING')
    upper = utc(worker['consumed_at'])
    require(upper <= utc(access['released_at']))
    return upper


def native_completion_receipt(connection, worker, access, horizon):
    # A historical nonzero stop is adopted only through its atomic, body-free
    # completion receipt. It is never rewritten or treated as execution authority.
    require(len(worker['owner_stop_json'].encode()) <= 8192)
    binding, output = decode(worker['binding_json']), decode(worker['output_json'])
    require(sha(worker['binding_json'].encode()) == worker['binding_sha256'] and sha(worker['output_json'].encode()) == worker['output_sha256'])
    require(all(worker[key] == access[key] == binding[key] for key in ('run_id','task_key','reservation_key')) and access['request_key'] == worker['request_key'])
    require(type(binding['reservation_generation']) is int and binding['reservation_generation'] > 0 and type(access['generation']) is int and access['generation'] == binding['reservation_generation'])
    require(binding['mode'] == access['mode'] and binding['policy']['cwd'] == access['canonical_path'])
    upper = completion_horizon(connection,worker,access,binding,output,horizon)
    found = []
    for row in rows(connection,"SELECT * FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED' AND run_id=?",(worker['run_id'],)):
        require(set(row) == {'id','occurred_at','event_type','run_id','payload_json'} and type(row['id']) is int and row['id'] > 0)
        receipt = decode(row['payload_json'])
        require(type(receipt) is dict)
        completion_text(receipt.get('request_key'),4096)
        require(connection.execute('SELECT 1 FROM worker_evidence WHERE request_key=? AND run_id=?',(receipt['request_key'],worker['run_id'])).fetchone() is not None)
        if receipt['request_key'] == worker['request_key']:
            require(len(row['payload_json'].encode()) <= 32768)
            found.append((row,receipt))
    require(len(found) == 1)
    event, receipt = found[0]
    require(set(receipt) == set('kind version request_key task_key run_id reservation_key reservation_generation owner_id owner_stopped_at binding_sha256 failure_code owner_stop_json native_parsed_json_sha256 native_completion native_observation thread_id turn_id item_id output_sha256'.split()))
    require(receipt['kind'] == 'NATIVE_COMPLETION_RECEIPT_V1' and type(receipt['version']) is int and receipt['version'] == 1)
    require(type(receipt['reservation_generation']) is int and receipt['reservation_generation'] == binding['reservation_generation'])
    require(all(receipt[key] == worker[key] for key in ('request_key','task_key','run_id','reservation_key','owner_id','owner_stopped_at','binding_sha256','owner_stop_json','thread_id','turn_id','item_id','output_sha256')))
    for keys, maximum in ((('request_key','task_key','reservation_key'),4096),(('run_id','owner_id'),256),(('thread_id','turn_id','item_id'),1024),(('failure_code',),128)):
        for key in keys: completion_text(receipt[key],maximum)
    require(receipt['failure_code'] == ':turn_timeout' or re.fullmatch(r'\{:port_exit, -?\d+\}',receipt['failure_code']) is not None)
    require(all(hex_digest(receipt[key]) for key in ('binding_sha256','output_sha256','native_parsed_json_sha256')))
    require(type(receipt['native_completion']) is dict and receipt['native_completion'] == {'status':'completed','error':None})
    observed = receipt['native_observation']
    require(type(observed) is dict and set(observed) == {'thread','latest','confirmation','queue'})
    thread, latest, confirmation, queue = (observed[key] for key in ('thread','latest','confirmation','queue'))
    require(all(type(value) is dict for value in (thread,latest,confirmation,queue)))
    require(set(thread) == {'id','cwd','updatedAt','status'} and thread['id'] == worker['thread_id'] and thread['cwd'] == access['canonical_path'])
    completion_text(thread['cwd'],4096)
    require(type(thread['status']) is dict and set(thread['status']) == {'type'} and thread['status']['type'] in ('idle','notLoaded','systemError'))
    require(type(thread['updatedAt']) in (int,float) and math.isfinite(thread['updatedAt']) and thread['updatedAt'] >= 0)
    require(set(latest) == {'mode','parameters','sha256','updated_at','observed_at'} and latest['mode'] == 'LATEST_DESC')
    require(type(latest['updated_at']) in (int,float) and math.isfinite(latest['updated_at']) and latest['updated_at'] == thread['updatedAt'])
    parameters = latest['parameters']
    require(type(parameters) is dict and set(parameters) == {'threadId','limit','sortDirection','itemsView'} and parameters['threadId'] == worker['thread_id'] and type(parameters['limit']) is int and parameters['limit'] == 1 and parameters['sortDirection'] == 'desc' and parameters['itemsView'] == 'full')
    require(set(confirmation) == {'sha256','observed_at'})
    require(set(queue) == {'thread_id','empty_complete','count_lower_bound','has_more','sha256','observed_at'} and queue['thread_id'] == worker['thread_id'] and queue['empty_complete'] is True and type(queue['count_lower_bound']) is int and queue['count_lower_bound'] == 0 and queue['has_more'] is False)
    stopped, occurred = utc(worker['owner_stopped_at']), utc(event['occurred_at'])
    require(utc(access['acquired_at']) <= stopped <= occurred <= upper)
    for observation in (latest,confirmation,queue):
        require(hex_digest(observation['sha256']))
        at = utc(observation['observed_at'])
        require(stopped <= at <= occurred and occurred-at <= datetime.timedelta(seconds=10))


def validate_successors(connection, execution):
    try:
        limits = connection.execute('SELECT COUNT(*),MAX(length(CAST(proof_json AS BLOB))),MAX(length(CAST(evidence_json AS BLOB))) FROM ticket_ci_repair_evidence_successors WHERE run_id=?',(execution['run_id'],)).fetchone()
        require(limits[0] <= 9 and (limits[0] == 0 or (limits[1] <= push_absolute_limit('successor') and limits[2] <= 262144)))
        journal = rows(connection,'SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id=? ORDER BY attempt_index',(execution['run_id'],))
        if not journal:
            return {}
        require(len(journal) <= 9)
        validated = {}
        for row in journal:
            require(set(row) == JOURNAL_KEYS and row['run_id'] == execution['run_id'])
            require(row['successor_key'] == 'ci-evidence-successor:'+digest([row['claim_key'],row['prior_request_key'],row['evidence_content_sha256']]))
            require(type(row['attempt_index']) is int and type(row['configured_limit']) is int and 2 <= row['attempt_index'] <= row['configured_limit'] <= 10)
            require(all(type(row[key]) is str for key in JOURNAL_KEYS - {'prior_successor_key','attempt_index','configured_limit'}))
            require(row['prior_successor_key'] is None or type(row['prior_successor_key']) is str)
            require(sha(row['proof_json'].encode()) == row['proof_sha256'] and sha(row['evidence_json'].encode()) == row['evidence_sha256'])
            proof, evidence = push_budget_decode(row['proof_json'],'successor'), decode(row['evidence_json'],262144)
            require(type(proof) is dict and set(proof) == PROOF_KEYS and type(proof['version']) is int and proof['version'] == 1 and proof['kind'] == 'CI_EVIDENCE_SUCCESSOR_V1')
            require(type(evidence) is dict and set(evidence) == {'artifacts','content_members'})
            require(proof['configured_limit'] == row['configured_limit'] and type(proof['total_before']) is int and proof['total_before'] == row['attempt_index']-1 and proof['admitted_at'] == row['created_at'])
            admitted = utc(proof['admitted_at'])
            require(admitted.utcoffset() == datetime.timedelta(0))
            worker, task, access, before, claim = (proof[key] for key in ('prior_evidence','prior_task','prior_access','run','claim'))
            require(all(type(value) is dict for value in (worker,task,access,before,claim)))
            require(rows(connection,'SELECT * FROM worker_evidence WHERE request_key=?',(row['prior_request_key'],)) == [worker])
            require(rows(connection,'SELECT * FROM ticket_ci_repair_claims WHERE claim_key=?',(row['claim_key'],)) == [claim])
            require(claim['run_id'] == before['run_id'] == worker['run_id'] == access['run_id'] == task['run_id'] == row['run_id'])
            require(claim['claim_key'] == row['claim_key'] and sha(claim['claim_json'].encode()) == claim['claim_sha256'])
            claim_binding = push_budget_decode(claim['claim_json'],'claim')
            require(claim_binding['kind'] == 'TICKET_CI_REPAIR' and claim_binding['claim_key'] == claim['claim_key'] and claim_binding['round'] == claim['round'] == before['code_repair_round'])
            require(snapshot_identity(proof['ci_snapshots']) == snapshot_identity(claim_binding['ci_snapshots']))
            require(proof['ci_snapshots']['mr']['sha'] == proof['ci_snapshots']['pipeline']['sha'] == before['candidate_sha'])
            require(claim_binding['prior_run']['state'] == 'CI_WAITING' and claim_binding['prior_run']['code_repair_round'] == claim['round']-1)
            for key in ('run_id','repo_path','worktree','branch','base_branch','contract_sha256','spec_revision','candidate_sha'):
                require(claim_binding['prior_run'][key] == before[key])
            require(before['state'] == 'REPAIRING' and worker['status'] == 'RESULT_RECORDED' and task['status'] == 'COMPLETE' and access['mode'] == 'SOURCE' and access['released_at'] is None and access['release_receipt_json'] is None)
            require(policy_shape(proof['policy_receipt'],before) == row['configured_limit'])
            admission_inputs(connection,proof); admission_authorization(proof)
            require(worker['request_key'] == access['request_key'] == row['prior_request_key'] and worker['reservation_key'] == access['reservation_key'] and worker['task_key'] == task['task_key'] == access['task_key'])
            require((worker['thread_id'],worker['turn_id'],worker['output_json']) == (task['thread_id'],task['turn_id'],task['output_json']))
            require(sha(worker['output_json'].encode()) == worker['output_sha256'] and sha(worker['binding_json'].encode()) == worker['binding_sha256'])
            instruction_claim(connection,worker,task,claim,before)
            require(decode(worker['binding_json'])['expected_sha'] == before['candidate_sha'])
            output = decode(worker['output_json']); require(output['status'] == 'BLOCKED' and output['changed_paths'] == [])
            current_access = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(access['reservation_key'],))
            require(len(current_access) == 1 and {k:v for k,v in current_access[0].items() if k not in ('released_at','release_receipt_json')} == {k:v for k,v in access.items() if k not in ('released_at','release_receipt_json')} and current_access[0]['released_at'] is not None)
            source = proof['source_observation']; require(set(source) == {'canonical_path','head_sha','dirty_paths'} and source == {'canonical_path':access['canonical_path'],'head_sha':before['candidate_sha'],'dirty_paths':[]})
            event = proof['disposition_event']; require(type(event) is dict and rows(connection,'SELECT * FROM events WHERE id=?',(event['id'],)) == [event] and event['event_type'] == 'TICKET_NATIVE_WRITER_BLOCKED' and event['run_id'] == row['run_id'])
            outcome = proof['accepted_outcome']
            require(type(outcome) is dict and set(outcome) == set('kind event_id event_sha256 request_key output_sha256 candidate_sha'.split()) and outcome == {'kind':'BLOCKED_NO_EDIT_ACCEPTED_V1','event_id':event['id'],'event_sha256':digest(event),'request_key':worker['request_key'],'output_sha256':worker['output_sha256'],'candidate_sha':before['candidate_sha']})
            payload = decode(event['payload_json'])
            require(payload['request_key'] == worker['request_key'] and payload['output_sha256'] == worker['output_sha256'] and payload['output_json'] == worker['output_json'] and payload['reservation_key'] == access['reservation_key'] and payload['reservation_generation'] == access['generation'] and payload['task_key'] == task['task_key'] and payload['task_status'] == 'COMPLETE')
            task_projection = set('task_key stage role status thread_id turn_id updated_at'.split())
            run_projection = set('run_id state spec_revision contract_sha256 candidate_sha branch worktree implementation_iteration'.split())
            require(type(payload['task']) is dict and set(payload['task']) == task_projection and payload['task'] == {key:task[key] for key in task_projection})
            require(type(payload['run_binding']) is dict and set(payload['run_binding']) == run_projection and payload['run_binding'] == {key:before[key] for key in run_projection})
            require(type(payload['disposition_key']) is str and payload['disposition_key'])
            admission_stop(connection,worker,access,{'kind':'CI_SUCCESSOR','disposition_event':event,'admitted_at':proof['admitted_at']})
            content = complete_content(evidence['artifacts'],proof['ci_snapshots'])
            require(content and content == evidence['content_members'] == proof['content_members'] and digest(content) == row['evidence_content_sha256'])
            parent = validated.get(row['prior_successor_key'])
            same_claim = [value for value in validated.values() if value['row']['claim_key'] == row['claim_key']]
            require((not same_claim and row['prior_successor_key'] is None) or (same_claim and parent is same_claim[-1]))
            if parent:
                previous = parent['content']; expected_previous = parent['row']['evidence_content_sha256']
                require(row['attempt_index'] == parent['row']['attempt_index']+1)
                seen_content = parent['seen_content']
            else:
                previous = complete_content(claim_diagnosis(connection,claim).get('artifacts',[]),proof['ci_snapshots'])
                expected_previous = digest(previous) if previous else None
                seen_content = novelty(previous)
            require(proof['previous_content_sha256'] == expected_previous and bool(novelty(content)-seen_content))
            require(not any(v['row']['claim_key'] == row['claim_key'] and v['row']['evidence_content_sha256'] == row['evidence_content_sha256'] for v in validated.values()))
            validated[row['successor_key']] = {'row':row,'proof':proof,'content':content,'disposition_key':payload['disposition_key'],'seen_content':seen_content|novelty(content)}
            validate_applied(connection,validated[row['successor_key']])
        return validated
    except (KeyError, TypeError, AttributeError, json.JSONDecodeError, OverflowError):
        reject()


def validate_transfer(successors, worker, access, destination, new_access, transfer):
    entry = successors.get(transfer.get('ci_evidence_successor_key'))
    require(entry is not None and set(transfer) == TRANSFER_KEYS)
    row, proof = entry['row'], entry['proof']
    require(worker == proof['prior_evidence'] and row['prior_request_key'] == worker['request_key'] and destination['request_key'] == row['new_request_key'] and new_access['reservation_key'] == row['new_reservation_key'])
    require(destination['thread_id'] == worker['thread_id'] and destination['policy_json'] == worker['policy_json'] and new_access['mode'] == 'SOURCE' and new_access['request_key'] == destination['request_key'])
    require(all(new_access[key] == access[key] for key in ('run_id','task_key','canonical_path','git_dir','common_dir')))
    require(transfer == {'kind':'CI_EVIDENCE_SUCCESSOR_TRANSFER_V1','ci_evidence_successor_key':row['successor_key'],'old_request_key':worker['request_key'],'old_reservation_key':access['reservation_key'],'new_request_key':destination['request_key'],'new_reservation_key':new_access['reservation_key'],'new_generation':new_access['generation'],'disposition_key':entry['disposition_key'],'output_sha256':worker['output_sha256'],'checkout_head_sha':proof['run']['candidate_sha']})
    binding = decode(destination['binding_json']); old_binding = decode(worker['binding_json'])
    require(sha(destination['binding_json'].encode()) == destination['binding_sha256'])
    for key in ('run_id','task_key','role','stage','mode','model','reasoning_effort','schema','policy','contract_sha256','spec_revision','expected_sha'):
        require(binding.get(key) == old_binding.get(key))
    require(binding['reservation_key'] == new_access['reservation_key'] and binding['reservation_generation'] == new_access['generation'])




def validate_applied(connection, entry):
    row = entry['row']
    applied = rows(connection,"SELECT * FROM events WHERE run_id=? AND event_type='TICKET_CI_REPAIR_SUCCESSOR_APPLIED' AND json_extract(payload_json,'$.successor_key')=?",(row['run_id'],row['successor_key']))
    require(len(applied) == 1)
    new = rows(connection,'SELECT * FROM worker_evidence WHERE request_key=?',(row['new_request_key'],)); require(len(new) == 1)
    access = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(row['new_reservation_key'],)); require(len(access) == 1)
    payload = decode(applied[0]['payload_json'])
    require(type(payload) is dict and set(payload) == APPLIED_KEYS and payload == {'kind':'CI_EVIDENCE_SUCCESSOR_APPLIED_V1','successor_key':row['successor_key'],'prior_request_key':row['prior_request_key'],'new_request_key':row['new_request_key'],'new_reservation_key':row['new_reservation_key'],'new_generation':access[0]['generation'],'new_binding_sha256':sha(new[0]['binding_json'].encode()),'proof_sha256':row['proof_sha256'],'evidence_sha256':row['evidence_sha256'],'attempt_index':row['attempt_index'],'accepted_outcome_sha256':digest(entry['proof']['accepted_outcome'])})
    old = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(entry['proof']['prior_access']['reservation_key'],)); require(len(old) == 1)
    validate_transfer({row['successor_key']:entry},entry['proof']['prior_evidence'],old[0],new[0],access[0],decode(old[0]['release_receipt_json']))


def ordinary_generation(connection, execution, binding, run, go_paths, present_go):
    proof = ordinary_repair(connection, execution, binding, run)
    require(type(go_paths) is list and len(go_paths) <= 128 and go_paths == sorted(set(go_paths)))
    require(all(type(path) is str and path.endswith('.go') and not path.startswith(('/', '-')) and not any(part in ('','..','.') for part in path.split('/')) and not re.search(r'[\x00-\x1f\x7f\\]',path) for path in go_paths))
    packages = {os.path.dirname(path) for path in go_paths}
    intents = rows(connection,'SELECT * FROM ticket_ordinary_generation_intents WHERE run_id=? AND request_key=? ORDER BY operation',(run['run_id'],proof['writer_request_key']))
    require(len(intents) <= 2)
    wanted = ({'GAZELLE_DIFF'} if packages else set()) | ({'GOFMT_DIFF'} if present_go else set())
    require({intent['operation'] for intent in intents} == wanted and len(intents) == len(wanted))
    changed = {}
    for intent in intents:
        require(sha(intent['binding_json'].encode()) == intent['binding_sha256'])
        saved = push_budget_decode(intent['binding_json'],'ordinary_generation')
        require(saved['version'] == 1 and saved['kind'] == 'CONTROLLER_ORDINARY_GENERATION' and saved['operation'] == intent['operation'])
        require(intent['intent_key'] == 'ordinary-generation:'+sha(json.dumps([proof['writer_request_key'],intent['operation']],ensure_ascii=False,separators=(',',':')).encode()))
        expected = dict(proof); expected['candidate_sha'] = proof['source_parent_sha']
        require(saved['ordinary_verifier_repair'] == expected and intent['verifier_request_key'] == proof['verifier_request_key'])
        require(all(saved['run_preimage'][key] == run[key] for key in ('run_id','spec_revision','contract_sha256','code_repair_round')) and saved['run_preimage']['candidate_sha'] == proof['source_parent_sha'])
        observer=saved['observer_path']
        require(type(observer) is str and os.path.realpath(observer)==observer and stat.S_ISREG(os.lstat(observer).st_mode) and os.path.commonpath([observer,run['worktree']])!=run['worktree'])
        require(saved['observer_sha256']=='90e032d34af8af6d92d4f56ece57e9671492c092db0a74a9bd2b2c7398555896' and sha(pathlib.Path(observer).read_bytes())==saved['observer_sha256'])
        local=pathlib.Path(__file__).resolve().parent
        toolset_raw=(local/'controller_generation_toolset_v1.json').read_bytes()
        require(sha(toolset_raw)=='a7b82db9826c6dcc1e7cf2f726f7ca47c3677125e164bbc9c27abf7f2350282e')
        toolset=decode(toolset_raw.decode()); toolset['manifest_sha256']=sha(toolset_raw)
        require(saved['toolset']==toolset and toolset['available'] is True and toolset['repo_key']==run['repo_key'])
        paths = saved['paths']; require(type(paths) is list and 1 <= len(paths) <= 32 and paths == sorted(set(paths)))
        if intent['operation'] == 'GAZELLE_DIFF':
            require(len(paths) == len(packages) and {os.path.dirname(path) for path in paths} == packages and all(os.path.basename(path) in ('BUILD','BUILD.bazel') for path in paths))
        else:
            require(paths == present_go)
        events = rows(connection,'SELECT * FROM ticket_ordinary_generation_events WHERE intent_key=? ORDER BY event_key',(intent['intent_key'],))
        require(len(events) <= 256 and all(sha(event['receipt_json'].encode()) == event['receipt_sha256'] for event in events))
        require(not any(event['event_type'] in ('UNCERTAIN','BLOCKED') for event in events))
        values = {(event['event_type'],event['path']):decode(event['receipt_json']) for event in events}
        require(len(values) == len(events))
        final = values[('FINALIZED','')]
        executed = next(event for event in events if event['event_type'] == 'EXECUTION_RECEIPT' and event['path'] == '')
        generation_session(intent,values,'',values[('EXECUTION_RECEIPT','')],run,local,toolset)
        require(values[('EXECUTION_RECEIPT','')]['kind']=='CONTROLLER_GENERATION_EXECUTED')
        require(final['version'] == 1 and final['execution_sha256'] == executed['receipt_sha256'])
        changed_paths = final['changed_paths']; require(type(changed_paths) is list and len(changed_paths) <= 32 and len(set(changed_paths)) == len(changed_paths) and all(path in paths for path in changed_paths))
        require({event['path'] for event in events if event['event_type'] == 'APPLIED'} == set(changed_paths))
        for path in changed_paths:
            applied = values[('APPLIED',path)]
            generation_session(intent,values,path,applied,run,local,toolset)
            prepared = values[('APPLY_PREPARED',path)]
            started = values[('APPLY_STARTED',path)]
            require(started['binding_json'] == applied['binding_json'] and decode(applied['binding_json']) == prepared)
            require(applied['helper_pid'] == started['helper_pid'] and applied['kind'] == 'CONTROLLER_GENERATION_APPLIED')
            proposal = prepared['proposal']
            require(prepared['intent_key'] == intent['intent_key'] and prepared['intent_sha256'] == intent['binding_sha256'] and proposal['path'] == path)
            require(sha(proposal['content'].encode()) == proposal['after_sha256'] and applied['result'] == {'path':path,'sha256':proposal['after_sha256']})
            require(path not in changed or changed[path] == proposal['after_sha256'])
            changed[path] = proposal['after_sha256']
    return changed


def generation_session(intent,values,path,receipt,run,local,toolset,generated_only=False):
    prefix='APPLY' if path else 'EXECUTION'
    prepared=values[(prefix+'_PREPARED',path)]; started=values[(prefix+'_STARTED',path)]
    require(type(started['helper_pid']) is int and started['helper_pid']>0 and receipt['version']==1 and receipt['helper_pid']==started['helper_pid'])
    require(started['binding_json']==receipt['binding_json'] and decode(receipt['binding_json'])==prepared)
    require(prepared['intent_key']==intent['intent_key'] and prepared['intent_sha256']==intent['binding_sha256'] and prepared['request_key']==intent['request_key'] and prepared['run_id']==run['run_id'])
    require(prepared['started_type']==prefix+'_STARTED' and prepared['toolset']==toolset and prepared['operation']==intent['operation'])
    helper = ('controller_generation_executor_v3.py', GENERATED_ONLY_HELPER_SHA) if generated_only else ('controller_generation_executor_v2.py','945f8ac69cc25a8de98bfe74a8b38ecde47a1fab2e6a234f34905767a6de4f43')
    require(not generated_only or prepared.get('generation_version') == 3)
    generation_programs(prepared, run, local, helper)
    require(prepared['root']==run['worktree'] and hex_digest(prepared['invocation']))


def generation_regular(path, maximum):
    require(type(path) is str and os.path.isabs(path) and os.path.realpath(path)==path)
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and 0<=before.st_size<=maximum)
        raw=bytearray()
        while len(raw)<=maximum:
            chunk=os.read(descriptor,min(65536,maximum+1-len(raw)))
            if not chunk:break
            raw.extend(chunk)
        require(len(raw)==before.st_size and generation_file_identity(os.fstat(descriptor))==generation_file_identity(before) and generation_file_identity(os.stat(path,follow_symlinks=False))==generation_file_identity(before))
        return bytes(raw)
    finally:
        os.close(descriptor)


def generation_file_identity(info):
    return tuple(getattr(info,key) for key in ('st_dev','st_ino','st_mode','st_uid','st_gid','st_nlink','st_size','st_mtime_ns','st_ctime_ns'))


def generation_programs(prepared, run, local, helper):
    companion=('worker_file_companion.py','87f3dd595ddc70205ed881b42ab5a9401b0705c13cdc8fda2c2b8b5bac4b0b3b')
    for key,(_,expected) in (('helper',helper),('companion',companion)):
        require(prepared[key+'_sha256']==expected)
        require(os.path.commonpath([prepared[key+'_path'],run['worktree']])!=run['worktree'])
        require(sha(generation_regular(prepared[key+'_path'],1_048_576))==expected)
    if prepared['helper_path']==str(local/helper[0]) and prepared['companion_path']==str(local/companion[0]):return
    raw=generation_regular(str(local/'ticket_generation_origins_v5.json'),65536)
    require(sha(raw)==GENERATION_ORIGINS_SHA)
    catalog=decode(raw.decode(),65536)
    require(set(catalog)=={'version','entries'} and type(catalog['version']) is int and catalog['version']==1 and type(catalog['entries']) is list and len(catalog['entries'])<=8)
    keys=set('kind manifest_path manifest_sha256 release_root manifest_kind helper_path helper_sha256 companion_path companion_sha256'.split())
    require(all(type(entry) is dict and set(entry)==keys for entry in catalog['entries']))
    matching=[entry for entry in catalog['entries'] if all(entry[key]==prepared[key] for key in ('helper_path','helper_sha256','companion_path','companion_sha256'))]
    require(len(matching)==1)
    entry=matching[0]; root=entry['release_root']
    require(entry['kind']=='RELEASE_GENERATION_ARTIFACT_V1' and type(root) is str and os.path.realpath(root)==root and os.path.isabs(root))
    require(entry['manifest_path']==str(pathlib.Path(root)/'evidence/release-manifest.json'))
    raw=generation_regular(entry['manifest_path'],4_194_304)
    require(sha(raw)==entry['manifest_sha256'])
    manifest=decode(raw.decode(),4_194_304)
    require(type(manifest) is dict and manifest.get('kind')==entry['manifest_kind'] and manifest['release']==root)
    for key,(name,expected) in (('helper',helper),('companion',companion)):
        relative='lib/symphony_elixir/priv/'+name
        require(entry[key+'_path']==str(pathlib.Path(root)/'dev'/relative))
        require(manifest['artifact'][relative]=={'sha256':expected})


def initial_writer(connection, execution, binding, run):
    validate_prepared_requalification(connection,execution,binding,run)
    require(connection.execute('SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=?',(run['run_id'],)).fetchone()[0] == 0)
    require(connection.execute('SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=?',(run['run_id'],)).fetchone()[0] == 0)
    task = rows(connection,"SELECT * FROM factory_tasks WHERE run_id=? AND role='feature-writer'",(run['run_id'],))
    require(len(task) == 1 and task[0]['stage'] in ('WRITING','REVIEW_WRITING') and task[0]['status'] == 'CONSUMED')
    require(not any(key in binding or key in execution for key in ('ordinary_verifier_repair','ci_repair','ci_evidence_successor','verified_ci_rollover','ci_repair_policy_receipt')))


def ordinary_repair(connection, execution, binding, run):
    validate_prepared_requalification(connection,execution,binding,run)
    try:
        return ordinary_repair_proof(connection, execution, binding, run)
    except (KeyError, TypeError, ValueError, AttributeError):
        raise ValueError('ordinary_verifier_repair_unproven') from None


def ordinary_repair_proof(connection, execution, binding, run, historical=False):
    proof = binding['ordinary_verifier_repair']
    fields = set('version kind candidate_sha source_parent_sha round verifier_round reviewed_candidate_sha verifier_request_key verifier_thread_id verifier_turn_id verifier_binding_sha256 verifier_output_sha256 writer_request_key writer_thread_id writer_turn_id writer_binding_sha256 writer_output_sha256 instruction_binding_sha256'.split())
    require(type(proof) is dict and type(proof.get('version')) is int and proof['version'] in (1,2,3))
    if proof['version'] in (2,3): fields.add('operator_authorization')
    require(set(proof) == fields and proof == execution['ordinary_verifier_repair'])
    require(proof['kind'] == 'ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1')
    require(type(proof['round']) is int and proof['round'] == run['code_repair_round'] and type(proof['verifier_round']) is int and proof['verifier_round'] in (run['verifier_round'],run['verifier_round']-1))
    require(connection.execute('SELECT 1 FROM ticket_ci_repair_claims WHERE run_id=? AND round=?',(run['run_id'],run['code_repair_round'])).fetchone() is None)
    found = []
    for prefix, role, stage, mode, verdict in (('writer','feature-writer','REPAIRING','SOURCE','COMPLETE'),('verifier','change-verifier','VERIFYING','REVIEW','BLOCK' if proof['version']==2 else 'REPAIR')):
        workers = rows(connection,"SELECT * FROM worker_evidence WHERE request_key=? AND run_id=? AND status='CONSUMED'",(proof[prefix+'_request_key'],run['run_id']))
        require(len(workers) == 1); worker = workers[0]
        require(type(proof[prefix+'_thread_id']) is str and proof[prefix+'_thread_id'] and type(proof[prefix+'_turn_id']) is str and proof[prefix+'_turn_id'] and worker['thread_id'] == proof[prefix+'_thread_id'] and worker['turn_id'] == proof[prefix+'_turn_id'])
        tasks = rows(connection,'SELECT * FROM factory_tasks WHERE task_key=?',(worker['task_key'],))
        require(len(tasks) == 1); task = tasks[0]
        require(sha(worker['binding_json'].encode()) == worker['binding_sha256'] == proof[prefix+'_binding_sha256'] and sha(worker['output_json'].encode()) == worker['output_sha256'] == proof[prefix+'_output_sha256'])
        wb = decode(worker['binding_json']); output = decode(worker['output_json'])
        if historical:
            # Only an exact authenticated COMPLETED predecessor calls this mode.
            # A later reuse of the task must not replace its consumed evidence.
            require(task['task_key']==worker['task_key'] and task['run_id']==run['run_id'] and task['role']==role)
            task=dict(task,stage=stage,status='CONSUMED',thread_id=worker['thread_id'],turn_id=worker['turn_id'],output_json=worker['output_json'],prompt_sha256=wb['input_sha256'])
        require(task['status'] == 'CONSUMED' and task['role'] == role and task['stage'] == stage and all(task[key] == worker[key] for key in ('thread_id','turn_id','output_json')))
        require(wb['role'] == role and wb['stage'] == stage and wb['mode'] == mode and wb['task_key'] == task['task_key'] and output['status'] == verdict)
        require(all(wb[key] == run[key] for key in ('run_id','spec_revision','contract_sha256')) and wb['prompt_sha256'] == wb['input_sha256'] == task['prompt_sha256'])
        accesses = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(worker['reservation_key'],)); require(len(accesses) == 1)
        access = accesses[0]
        require(access['mode'] == mode and access['released_at'] is not None and access['run_id'] == run['run_id'] and access['task_key'] == task['task_key'] and access['request_key'] == worker['request_key'])
        require(access['generation'] == wb['reservation_generation'] and access['reservation_key'] == wb['reservation_key'] and access['canonical_path'] == run['worktree'])
        admission_stop(connection,worker,access,{'kind':'ORDINARY_WRITER' if prefix == 'writer' else 'ORDINARY_VERIFIER'})
        require(decode(access['release_receipt_json']) == {key:worker[key] for key in ('request_key','binding_sha256','output_sha256','consumed_at','owner_stopped_at')})
        mapping = rows(connection,'SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?',(task['task_key'],task['prompt_sha256']))
        require(len(mapping) == 1 and mapping[0]['run_id'] == run['run_id'] and mapping[0]['role'] == role)
        snapshots = rows(connection,'SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?',(mapping[0]['instruction_binding_sha256'],)); require(len(snapshots) == 1)
        snapshot = snapshots[0]
        require(snapshot['run_id'] == run['run_id'] and snapshot['role'] == role)
        require(sha(snapshot['binding_json'].encode()) == snapshot['binding_sha256'] and sha(snapshot['bundle_json'].encode()) == snapshot['bundle_sha256'])
        packet = decode(snapshot['binding_json'])
        bundle = decode(snapshot['bundle_json'])
        require(type(bundle) is dict and set(bundle) == {'shared_instructions','instruction_delivery'} and type(bundle['instruction_delivery']) is str and bundle['instruction_delivery'])
        require(type(bundle['shared_instructions']) is list)
        paths=[]
        for instruction in bundle['shared_instructions']:
            require(type(instruction) is dict and set(instruction) == {'path','relative_path','content','sha256'} and all(type(value) is str for value in instruction.values()) and 1 <= len(instruction['content'].encode()) <= 65536 and sha(instruction['content'].encode()) == instruction['sha256'])
            paths.append(instruction['relative_path'])
        required=set('AGENTS.md rules/comment-discipline.mdc rules/gitlab-preferences.mdc rules/go-test-style.mdc rules/skills-directory.mdc'.split())
        required.update('skills/draft-feature-cycle/SKILL.md skills/select-tests/SKILL.md'.split() if role == 'feature-writer' else 'skills/verify-feature-delivery/SKILL.md skills/verify-feature-delivery/references/verdict-contract.md skills/review-code/references/review-criteria.md'.split())
        require(required <= set(paths) and len(set(paths)) == len(paths) and sum(len(value['content'].encode()) for value in bundle['shared_instructions']) <= 262144)
        require(packet['candidate_sha'] == wb['expected_sha'] and packet['role'] == role and packet['stage'] == stage and all(packet[key] == run[key] for key in ('run_id','spec_revision','contract_sha256')))
        validate_review_admission(connection, worker, wb, output, packet)
        found.append((worker,wb,output,packet,mapping[0]))
    writer,verifier = found
    require(verifier[3]['code_repair_round'] == run['code_repair_round']-1 and verifier[3]['ci_evidence']['status'] == 'PASS' and verifier[3]['ci_evidence']['sha'] == proof['reviewed_candidate_sha'])
    require(proof['candidate_sha'] == run['candidate_sha'] and proof['source_parent_sha'] == writer[1]['expected_sha'])
    if not historical:
        require(connection.execute('SELECT workspace_sha FROM factory_tasks WHERE task_key=?',(writer[0]['task_key'],)).fetchone()[0] == run['candidate_sha'])
    packet = writer[3]
    require(packet['code_repair_round'] == proof['round'] and packet['verifier_round'] == proof['verifier_round'] and 'ci_repair' not in packet and writer[4]['instruction_binding_sha256'] == proof['instruction_binding_sha256'])
    require(verifier[1]['task_key'] == run['run_id']+':change-verifier:'+str(proof['verifier_round']) and verifier[2]['candidate_sha'] == verifier[1]['expected_sha'] == proof['reviewed_candidate_sha'])
    findings = required_findings(verifier[2]); require(type(findings) is list and all(type(finding) is str for finding in findings))
    unique = list(dict.fromkeys(findings))
    expected_findings = review_finding_entries(run['contract_sha256'], verifier[0], verifier[1], verifier[2], verifier[3])
    if proof['version'] in (2,3):
        operator_repair_authority(connection,proof,run,verifier,packet,expected_findings)
        allowance = proof['operator_authorization'].get('review_policy_stop', {}).get('source_allowance')
        if allowance is not None:
            require(packet['implementation_iteration'] == allowance['prior_implementation_iteration'] and run['implementation_iteration'] == allowance['next_implementation_iteration'])
    if 'repair_review' in packet:
        review = packet['repair_review']; require(type(review) is dict)
        require(review['prior_candidate_sha'] == proof['reviewed_candidate_sha'] and review['verifier_request_key'] == proof['verifier_request_key'] and review['verifier_output_sha256'] == proof['verifier_output_sha256'])
        require(review['findings'] == expected_findings)
    carried=decode(packet['repair_findings']); require(type(carried) is list and all(type(finding) is str for finding in carried) and list(dict.fromkeys(carried)) == unique)
    require('ci_repair' not in binding and 'ci_repair_policy_receipt' not in binding and 'ci_repair_policy_receipt' not in execution)
    return proof


def review_finding_entries(contract, worker, binding, output, packet):
    if packet.get('review_protocol', {}).get('version') == 2:
        require('findings' not in output and 'findings' not in binding['schema']['properties'])
        require('review_report' in binding['schema']['required'] and output['review_report']['version'] == 2)
        require(output['review_report']['candidate_sha'] == binding['expected_sha'])
        typed_findings(packet['review_protocol'], output['review_report'])
        return [{'id': row['id'], 'finding': row['description']} for row in output['review_report']['findings'] if row['disposition'] == 'REQUIRED_REPAIR']
    findings = output['findings']
    require(type(findings) is list and all(type(finding) is str for finding in findings))
    properties = binding['schema']['properties']
    structured = 'review_report' in output
    require(structured == ('review_report' in properties) == ('review_protocol' in packet))
    if structured:
        require('review_report' in binding['schema']['required'])
        require(type(packet['review_protocol']) is dict and packet['review_protocol']['version'] == 1)
        require(type(output['review_report']) is dict and output['review_report']['candidate_sha'] == binding['expected_sha'])
        return [{'id':sha(json.dumps([contract, worker['request_key'], worker['output_sha256'], index], separators=(',', ':'), ensure_ascii=False).encode()), 'finding':finding} for index, finding in enumerate(findings)]
    return [{'id':sha(json.dumps([contract, finding], separators=(',', ':'), ensure_ascii=False).encode()), 'finding':finding} for finding in dict.fromkeys(findings)]


def required_findings(output):
    if output.get('review_report', {}).get('version') == 2:
        return [row['description'] for row in output['review_report']['findings'] if row['disposition'] == 'REQUIRED_REPAIR']
    return output['findings']


def typed_findings(protocol, report):
    values = report['findings']; require(type(values) is list)
    known = {row['id']: row for row in protocol['finding_obligations']}
    ids = []
    for row in values:
        require(type(row) is dict and set(row) == set('id description classification disposition basis'.split()))
        require(all(type(row[key]) is str and row[key].strip() for key in ('id', 'description')))
        require(row['classification'] in ('NEW', 'REGRESSION', 'UNRESOLVED') and row['disposition'] in ('REQUIRED_REPAIR', 'OBSERVATION'))
        basis = row['basis']; require(type(basis) is dict and set(basis) == {'kind', 'reference'} and type(basis['reference']) is str and basis['reference'].strip())
        if basis['kind'] == 'ACCEPTANCE_CRITERION':
            require(basis['reference'] in protocol['criterion_ids'] and row['disposition'] == 'REQUIRED_REPAIR')
        elif basis['kind'] == 'SAFETY_INVARIANT':
            require(basis['reference'] in ('PRIVACY', 'SECURITY', 'CONTRACT_INTEGRITY', 'EXACT_IDENTITY') and row['disposition'] == 'REQUIRED_REPAIR')
        elif basis['kind'] == 'PRIOR_FINDING':
            require(row['id'] == basis['reference'] and row['id'] in known and row['disposition'] == 'REQUIRED_REPAIR')
        else:
            require(basis['kind'] == 'PREFERENCE' and row['disposition'] == 'OBSERVATION')
        if row['classification'] == 'NEW':
            require(row['id'] not in known)
        else:
            require(row['id'] in known and row['disposition'] == 'REQUIRED_REPAIR' and ('basis' not in known[row['id']] or known[row['id']]['basis'] == basis))
        ids.append(row['id'])
    require(len(ids) == len(set(ids)))


def report_schema(value, schema):
    kind = schema.get('type')
    kinds = kind if type(kind) is list else [kind]
    matched = any((item == 'object' and type(value) is dict) or (item == 'array' and type(value) is list) or (item == 'string' and type(value) is str) or (item == 'integer' and type(value) is int) or (item == 'boolean' and type(value) is bool) or (item == 'null' and value is None) or (item == 'number' and type(value) in (int, float)) for item in kinds)
    require(matched and ('enum' not in schema or value in schema['enum']))
    if type(value) is dict:
        require(set(schema.get('required', [])) <= set(value))
        properties = schema.get('properties', {})
        require(schema.get('additionalProperties', True) or set(value) <= set(properties))
        for key in set(value) & set(properties): report_schema(value[key], properties[key])
    if type(value) is list:
        for item in value: report_schema(item, schema['items'])


def historical_writer_boundary(packet, output, report, boundary):
    if packet['role'] != 'feature-writer' or output['status'] != 'COMPLETE' or boundary['status'] != 'UNAVAILABLE':
        return False
    scope = packet['review_protocol'].get('review_scope', {})
    if scope.get('mode') != 'FOCUSED':
        return False
    criterion = next((row for row in report['criteria'] if row['id'] == boundary['id']), None)
    covered = [(row, origin) for origin in scope['carried_evidence'] for row in origin.get('criteria') or [] if row['id'] == boundary['id']]
    if not criterion or criterion['status'] != 'NOT_CHECKED' or not covered:
        return False
    previous, origin = covered[-1]
    return previous['status'] == 'PASS' and report_texts(previous['evidence']) and report_texts(boundary['evidence']) and all(type(origin.get(key)) is str and origin[key].strip() for key in ('request_key', 'output_sha256', 'candidate_sha'))


def report_texts(values):
    return type(values) is list and bool(values) and all(type(value) is str and value.strip() for value in values)


def validate_report(packet, binding, output):
    protocol = packet['review_protocol']; report = output['review_report']
    report_schema(output, binding['schema'])
    require(report['candidate_sha'] == binding['expected_sha'])
    ids = protocol['criterion_ids'] if protocol['version'] == 1 else protocol['review_scope']['criterion_ids']
    for name, expected in (('criteria', ids), ('boundary_sweeps', ids), ('closures', [row['id'] for row in protocol['finding_obligations']])):
        require(sorted(row['id'] for row in report[name]) == sorted(expected))
        require(all(type(row['evidence']) is list and row['evidence'] and all(type(item) is str and item.strip() for item in row['evidence']) for row in report[name]))
    require(all(report_texts(row['paths']) or (protocol['version'] == 2 and row['paths'] == [] and historical_writer_boundary(packet, output, report, row)) for row in report['boundary_sweeps']))
    unresolved = [row['id'] for row in report['closures'] if row['status'] == 'UNRESOLVED']
    if protocol['version'] == 2:
        typed_findings(protocol, report)
        require(sorted(row['id'] for row in report['findings'] if row['classification'] == 'UNRESOLVED') == sorted(unresolved))
        require('findings' not in output and 'findings' not in binding['schema']['properties'])
    else:
        require(protocol['version'] == report['version'] == 1)
        classified = [row['finding'] for row in report['finding_classifications']]
        require(len(classified) == len(set(classified)) and all(type(item) is str and item.strip() for item in classified))
        require(not unresolved or protocol['repairs_used'] > 0)
        require(not any(row['classification'] == 'UNRESOLVED' for row in report['finding_classifications']) or unresolved)
        if packet['role'] == 'change-verifier': require(sorted(classified) == sorted(output['findings']))
    if protocol['version'] == 2:
        scope = protocol['review_scope']; active = scope['criterion_ids']
        require(len(active) == len(set(active)) and set(active) <= set(protocol['criterion_ids']))
        covered = {}
        for origin in scope['carried_evidence']:
            for row in origin.get('criteria') or []: covered[row['id']] = (row, origin)
        require(scope['mode'] in ('COMPREHENSIVE', 'FOCUSED'))
        for criterion in set(protocol['criterion_ids']) - set(active):
            require(scope['mode'] == 'FOCUSED' and criterion in covered)
            previous, origin = covered[criterion]
            require(previous['status'] == 'PASS' and previous['evidence'] and all(type(origin.get(key)) is str and origin[key].strip() for key in ('request_key', 'output_sha256', 'candidate_sha')))
        if packet['role'] == 'feature-writer' and 'affected_paths' not in scope:
            supplemental_ids = [row['id'] for row in report['affected_path_checks']]
            require(all(type(value) is str and value.strip() for value in supplemental_ids) and len(supplemental_ids) == len(set(supplemental_ids)))
        else:
            require(sorted(row['id'] for row in report['affected_path_checks']) == sorted(scope.get('affected_paths', [])))
        require(all(row['evidence'] and all(type(value) is str and value.strip() for value in row['evidence']) for row in report['affected_path_checks']))
    if packet['role'] != 'change-verifier':
        if output['status'] == 'COMPLETE':
            boundaries_ready = all(row['status'] == 'CHECKED' or (protocol['version'] == 2 and historical_writer_boundary(packet, output, report, row)) for row in report['boundary_sweeps'])
            require(not output['blockers'] and report['block_reason'] == 'NONE' and not unresolved and all(row['status'] in ('PASS', 'NOT_CHECKED') for row in report['criteria']) and boundaries_ready and all(row['status'] == 'CHECKED' for row in report.get('affected_path_checks', [])))
        return
    require(output['candidate_sha'] == binding['expected_sha'])
    findings = required_findings(output)
    checked = all(row['status'] == 'CHECKED' for row in report['boundary_sweeps'] + report.get('affected_path_checks', []))
    if output['status'] == 'PASS':
        require(not findings and not unresolved and checked and report['block_reason'] == 'NONE' and all(row['status'] == 'PASS' for row in report['criteria']))
    elif output['status'] == 'REPAIR':
        require(findings and checked and report['block_reason'] == 'NONE' and all(row['status'] in ('PASS', 'FAIL') for row in report['criteria']))
        if protocol['version'] == 1: require(any(row['status'] == 'FAIL' for row in report['criteria']))
    else:
        require(output['status'] == 'BLOCK' and findings and report['block_reason'] in ('CONTRACT_CHANGED', 'HUMAN_DECISION', 'ENVIRONMENT'))


def validate_review_admission(connection, worker, binding, output, packet):
    if 'review_protocol' not in packet: return
    if packet['review_protocol']['version'] == 2:
        for origin in packet['review_protocol']['review_scope']['carried_evidence']:
            prior = rows(connection, "SELECT * FROM worker_evidence WHERE request_key=? AND run_id=? AND status='CONSUMED'", (origin['request_key'], worker['run_id']))
            require(len(prior) == 1 and prior[0]['output_sha256'] == sha(prior[0]['output_json'].encode()) == origin['output_sha256'] and sha(prior[0]['binding_json'].encode()) == prior[0]['binding_sha256'])
            prior_binding = decode(prior[0]['binding_json']); prior_output = decode(prior[0]['output_json'])
            require(prior_binding['role'] == 'change-verifier' and all(prior_binding[key] == packet[key] for key in ('run_id', 'spec_revision', 'contract_sha256')))
            require(prior_output['candidate_sha'] == origin['candidate_sha'] and prior_output.get('review_report', {}).get('criteria') == origin.get('criteria'))
    try:
        validate_report(packet, binding, output)
        return
    except (ValueError, KeyError, TypeError):
        require(packet['review_protocol']['version'] == 1 and packet['role'] == 'change-verifier' and output['status'] in ('REPAIR', 'BLOCK'))
    corrections = rows(connection, "SELECT payload_json FROM events WHERE run_id=? AND event_type='TICKET_REVIEW_REPORT_CORRECTED' AND json_extract(payload_json,'$.request_key')=?", (worker['run_id'], worker['request_key']))
    require(len(corrections) == 1)
    receipt = decode(corrections[0]['payload_json'])
    require(receipt['version'] == 1 and receipt['kind'] == 'REVIEW_REPORT_CORRECTION_V1' and receipt['transform'] == 'V1_CLASSIFICATION_DESCRIPTION_BIJECTION_V1')
    require(all(receipt[key] == worker[key] for key in ('run_id', 'request_key', 'binding_sha256', 'output_sha256')) and receipt['verdict'] == output['status'])
    require(type(receipt['authorization_reference']) is str and receipt['authorization_reference'].strip())
    mapping = receipt['mapping']; count = len(output['findings'])
    require(count > 0 and len(output['review_report']['finding_classifications']) == count and type(mapping) is list and len(mapping) == count)
    require(all(type(item) is dict and set(item) == {'classification_index', 'finding_index'} and all(type(value) is int for value in item.values()) for item in mapping))
    require(sorted(item['classification_index'] for item in mapping) == sorted(item['finding_index'] for item in mapping) == list(range(count)))
    projected = json.loads(json.dumps(output))
    for item in mapping: projected['review_report']['finding_classifications'][item['classification_index']]['finding'] = output['findings'][item['finding_index']]
    require(sha(canonical(projected)) == receipt['projection_sha256'])
    validate_report(packet, binding, projected)


def validate_operator_budget(auth, input, prior):
    if auth.get('version') == 4:
        require(auth['kind'] == 'REVIEW_POLICY_STOP_CONTINUATION_V2' and auth['automatic_repairs_used'] == 2 and auth['operator_repair_limit'] == 1)
        reference = input['review_policy_stop']
        require(type(reference['version']) is int and reference['version'] == 2)
        configured, effective = auth['configured_limits'], auth['limits']
        require(set(configured) == set(effective) == {'maximum_implementation_iterations', 'maximum_code_repair_rounds'})
        require(all(type(value) is int and value >= 0 for value in list(configured.values()) + list(effective.values())))
        require(type(prior['implementation_iteration']) is int and type(prior['code_repair_round']) is int)
        require(prior['implementation_iteration'] >= configured['maximum_implementation_iterations'] and prior['code_repair_round'] >= configured['maximum_code_repair_rounds'])
        expected = dict(configured_implementation_limit=configured['maximum_implementation_iterations'], prior_implementation_iteration=prior['implementation_iteration'], next_implementation_iteration=prior['implementation_iteration']+1, configured_code_repair_limit=configured['maximum_code_repair_rounds'], prior_code_repair_round=prior['code_repair_round'], next_code_repair_round=prior['code_repair_round']+1, maximum_additional_iterations=1)
        require(reference['source_allowance'] == expected and all(type(value) is int for value in reference['source_allowance'].values()))
        require(effective == dict(maximum_implementation_iterations=expected['next_implementation_iteration'], maximum_code_repair_rounds=expected['next_code_repair_round']))
        budget = {key:input[key] for key in 'run_id candidate_sha spec_revision contract_sha256 verifier_request_key verifier_output_sha256 authorization_reference'.split()}
        budget.update(kind='ONE_VERIFIER_REPAIR', verifier_round=prior['verifier_round'], prior_code_repair_round=prior['code_repair_round'], next_code_repair_round=prior['code_repair_round']+1, configured_limit=configured['maximum_code_repair_rounds'])
        require(auth['budget_exception'] == budget)
        return
    if auth.get('version') == 3:
        require(auth['kind'] == 'REVIEW_POLICY_STOP_CONTINUATION_V1' and auth['automatic_repairs_used'] == 2 and auth['operator_repair_limit'] == 1 and 'review_policy_stop' in input)
        return validate_operator_budget(dict(auth, version=2 if 'budget_exception' in auth else 1), input, prior)
    require(set(auth['limits']) == {'maximum_implementation_iterations', 'maximum_code_repair_rounds'})
    require(all(type(value) is int and value >= 0 for value in auth['limits'].values()))
    require(prior['implementation_iteration'] < auth['limits']['maximum_implementation_iterations'])
    require(prior['code_repair_round'] < auth['limits']['maximum_code_repair_rounds'])
    require(type(auth['version']) is int and auth['version'] in (1, 2))
    if auth['version'] == 1:
        require('budget_exception' not in auth and 'configured_limits' not in auth)
        return
    require(type(auth.get('budget_exception')) is dict and type(auth.get('configured_limits')) is dict)
    require(all(type(auth['budget_exception'].get(key)) is int for key in ('verifier_round', 'prior_code_repair_round', 'next_code_repair_round', 'configured_limit')))
    configured = auth['configured_limits']
    require(set(configured) == {'maximum_implementation_iterations', 'maximum_code_repair_rounds'})
    require(all(type(value) is int and value >= 0 for value in configured.values()))
    require(prior['implementation_iteration'] < configured['maximum_implementation_iterations'])
    require(prior['code_repair_round'] >= configured['maximum_code_repair_rounds'])
    expected = {key:input[key] for key in 'run_id candidate_sha spec_revision contract_sha256 verifier_request_key verifier_output_sha256 authorization_reference'.split()}
    expected.update(kind='ONE_VERIFIER_REPAIR', verifier_round=prior['verifier_round'], prior_code_repair_round=prior['code_repair_round'], next_code_repair_round=prior['code_repair_round']+1, configured_limit=configured['maximum_code_repair_rounds'])
    require(auth['budget_exception'] == expected)
    require(auth['limits'] == dict(configured, maximum_code_repair_rounds=prior['code_repair_round']+1))


def operator_repair_authority(connection,proof,run,verifier,packet,findings):
    """An explicit local operator approval preserves BLOCK; it is not a native parent message."""
    ref=proof['operator_authorization']
    ref_fields=set('authorization_event_id authorization_sha256 applied_event_id applied_sha256 authorization_key authorization_reference authorization_body_sha256 repair_instructions repair_instructions_sha256'.split())
    if proof.get('version') == 3: ref_fields.add('review_policy_stop')
    require(type(ref) is dict and set(ref)==ref_fields)
    require(packet['repair_review']['operator_authorization']==ref)
    events=[]
    for prefix,event_type in (('authorization','TICKET_VERIFIER_REPAIR_AUTHORIZED'),('applied','TICKET_VERIFIER_REPAIR_APPLIED')):
        require(type(ref[prefix+'_event_id']) is int and ref[prefix+'_event_id']>0)
        found=rows(connection,'SELECT * FROM events WHERE id=? AND run_id=? AND event_type=?',(ref[prefix+'_event_id'],run['run_id'],event_type))
        require(len(found)==1 and sha(found[0]['payload_json'].encode())==ref[prefix+'_sha256'])
        events.append(decode(found[0]['payload_json'],262144))
    auth,applied=events
    continuation = auth.get('version') in (3,4)
    require(type(auth['version']) is int and auth['version'] in (1,2,3,4) and auth['kind']==('REVIEW_POLICY_STOP_CONTINUATION_V'+str(auth['version']-2) if continuation else 'BLOCKED_VERIFIER_REPAIR_AUTHORIZATION_V'+str(auth['version'])) and auth['authority']=='LOCAL_OPERATOR_AUTHORIZATION')
    input=auth['authorization']; prior=auth['run']
    input_fields=set('authorization_key run_id candidate_sha spec_revision contract_sha256 verifier_request_key verifier_output_sha256 authorization_reference authorization_body repair_instructions'.split())
    if continuation: input_fields.add('review_policy_stop')
    require(type(input) is dict and set(input)==input_fields and continuation == (proof.get('version') == 3))
    require(type(input['spec_revision']) is int and input['spec_revision']>0 and all(type(value) is str and 1<=len(value.encode())<=8192 for key,value in input.items() if key not in ('spec_revision','review_policy_stop')))
    require(len(input['authorization_key'].encode())<=256 and len(input['authorization_reference'].encode())<=2048)
    require(hex_digest(input['candidate_sha'],40) and hex_digest(input['contract_sha256']) and hex_digest(input['verifier_output_sha256']))
    require(all(input[key]==prior[key]==run[key] for key in ('run_id','spec_revision','contract_sha256')) and input['candidate_sha']==prior['candidate_sha']==proof['reviewed_candidate_sha'])
    require(type(prior['code_repair_round']) is int and prior['code_repair_round']+1==proof['round'] and prior['verifier_round']==proof['verifier_round'])
    require(all(type(value) is int and value>=0 for value in (prior['implementation_iteration'],auth['limits']['maximum_implementation_iterations'],prior['code_repair_round'],auth['limits']['maximum_code_repair_rounds'])))
    validate_operator_budget(auth, input, prior)
    worker,wb,output,reviewed,mapping=verifier
    require(auth['verifier']=={key:worker[key] for key in 'request_key task_key thread_id turn_id binding_sha256 output_sha256 reservation_key consumed_at owner_stopped_at'.split()})
    require(input['verifier_request_key']==worker['request_key'] and input['verifier_output_sha256']==worker['output_sha256'] and output['status']==('REPAIR' if continuation else 'BLOCK'))
    authority_findings = [{'id':sha(json.dumps([run['contract_sha256'], finding], separators=(',', ':'), ensure_ascii=False).encode()), 'finding':finding} for finding in dict.fromkeys(required_findings(output))]
    require(auth['findings']==authority_findings and findings==review_finding_entries(run['contract_sha256'], worker, wb, output, reviewed))
    require(all(reviewed[key]==prior[key] for key in ('run_id','candidate_sha','spec_revision','contract_sha256','verifier_round','code_repair_round','implementation_iteration')))
    access=rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=?',(worker['reservation_key'],)); require(len(access)==1)
    require(sha(access[0]['release_receipt_json'].encode())==auth['review_release_sha256'])
    terminal=rows(connection,"SELECT * FROM events WHERE id=? AND run_id=? AND event_type='TICKET_NATIVE_VERIFIER_TERMINAL'",(auth['terminal_event_id'],run['run_id']))
    require(len(terminal)==1 and sha(terminal[0]['payload_json'].encode())==auth['terminal_sha256'])
    tr=decode(terminal[0]['payload_json'],262144)
    keys='run_id candidate_sha spec_revision contract_sha256 verifier_round code_repair_round implementation_iteration'.split()
    before={key:prior[key] for key in keys}
    expected_terminal={'version':1,'kind':'TICKET_VERIFIER_TERMINAL_V1','reason':'verification_blocked','request_key':worker['request_key'],'task_key':worker['task_key'],'binding_sha256':worker['binding_sha256'],'output_sha256':worker['output_sha256'],'prior_run':before}
    if continuation:
        reference = input['review_policy_stop']
        reference_fields = set('version automatic_repairs_used policy_event_id policy_sha256 required_finding_ids'.split())
        if auth['version'] == 4: reference_fields.add('source_allowance')
        require(reference == ref['review_policy_stop'] and set(reference) == reference_fields)
        require(type(reference['policy_event_id']) is int and reference['policy_event_id'] > 0 and hex_digest(reference['policy_sha256']))
        require(type(reference['version']) is int and reference['version'] == (2 if auth['version'] == 4 else 1) and type(reference['automatic_repairs_used']) is int and reference['automatic_repairs_used'] == 2)
        if auth['version'] == 4:
            require(packet['implementation_iteration'] == prior['implementation_iteration'] and packet['code_repair_round'] == prior['code_repair_round']+1)
        require(reference['required_finding_ids'] == [row['id'] for row in findings])
        policy_rows = rows(connection, "SELECT * FROM events WHERE id=? AND run_id=? AND event_type='TICKET_REVIEW_DECISION'", (reference['policy_event_id'], run['run_id']))
        require(len(policy_rows) == 1 and sha(policy_rows[0]['payload_json'].encode()) == reference['policy_sha256'])
        policy=decode(policy_rows[0]['payload_json'])
        require(policy['version'] == 1 and policy['kind'] == 'REVIEW_POLICY_DECISION_V1' and policy['result'] == 'POLICY_STOPPED' and policy['repairs_used_before'] == policy['repairs_used_after'] == policy['repair_attempt_limit'] == 2 and policy['stop']['reason'] == 'REPAIR_LIMIT')
        require(all(policy[key] == worker[key] for key in ('request_key','binding_sha256','output_sha256')) and all(policy[key] == prior[key] for key in ('candidate_sha','contract_sha256','spec_revision','verifier_round')))
        expected_terminal.update(version=2,kind='TICKET_VERIFIER_TERMINAL_V2',reason='verification_policy_stopped',review_policy=policy['stop'])
    require(tr==expected_terminal)
    require(type(applied['version']) is int and applied['version']==(2 if continuation else 1) and applied['kind']==('REVIEW_POLICY_STOP_CONTINUATION_APPLIED_V1' if continuation else 'BLOCKED_VERIFIER_REPAIR_APPLIED_V1') and applied['authorization_event_id']==ref['authorization_event_id'] and applied['authorization_sha256']==ref['authorization_sha256'])
    require(applied['prior_run']==before and applied['next_run']==dict(before,code_repair_round=before['code_repair_round']+1))
    require(auth['terminal_event_id']<ref['authorization_event_id']<ref['applied_event_id'])
    require(type(applied['tick']) is dict and set(applied['tick'])==set('scope dispatcher_id generation tick_id'.split()) and type(applied['tick']['generation']) is int and applied['tick']['generation']>0 and all(type(applied['tick'][key]) is str and applied['tick'][key] for key in ('scope','dispatcher_id','tick_id')))
    require(type(auth['control']) is dict and set(auth['control'])=={'scope','dispatcher_id'} and all(applied['tick'][key]==auth['control'][key] for key in auth['control']))
    require(auth['authorization_body_sha256']==ref['authorization_body_sha256']==sha(input['authorization_body'].encode()) and auth['repair_instructions_sha256']==ref['repair_instructions_sha256']==sha(input['repair_instructions'].encode()))
    require(all(ref[key]==input[key] for key in ('authorization_key','authorization_reference','repair_instructions')))
    require(len(rows(connection,"SELECT id FROM events WHERE run_id=? AND event_type='TICKET_VERIFIER_REPAIR_AUTHORIZED' AND json_extract(payload_json,'$.authorization.verifier_request_key')=?",(run['run_id'],worker['request_key'])))==1)
    require(len(rows(connection,"SELECT id FROM events WHERE run_id=? AND event_type='TICKET_VERIFIER_REPAIR_APPLIED' AND json_extract(payload_json,'$.authorization_event_id')=?",(run['run_id'],ref['authorization_event_id'])))==1)


def validate_push_proof(connection, execution, binding, run):
    validate_prepared_requalification(connection,execution,binding,run)
    try:
        proof = binding['ci_evidence_successor']
        require(type(proof) is dict and set(proof) == PUSH_KEYS and proof == execution['ci_evidence_successor'] and type(proof['version']) is int and proof['version'] == 1 and proof['kind'] == 'CI_EVIDENCE_SUCCESSOR_PUSH_V1')
        successors = validate_successors(connection,execution)
        # New issuance captures an explicit empty projection too. validate_successors
        # authenticates that projection against the actual table, never a missing key.
        actual_heads = []
        for claim_key in sorted({entry['row']['claim_key'] for entry in successors.values()}):
            chain = [entry['row'] for entry in successors.values() if entry['row']['claim_key'] == claim_key]
            actual_heads.append({'claim_key':claim_key,'head_key':chain[-1]['successor_key'],'head_row_sha256':digest(chain[-1]),'chain_keys':[row['successor_key'] for row in chain]})
        require(type(proof['heads']) is list and proof['heads'] == actual_heads)
        projection = [{'successor_key':entry['row']['successor_key'],'row_sha256':digest(entry['row'])} for entry in successors.values()]
        require(proof['all_rows_sha256'] == digest(projection))
        total = connection.execute('SELECT (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=?) + (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=?)',(execution['run_id'],execution['run_id'])).fetchone()[0]
        require(type(proof['attempts_used']) is int and type(proof['attempt_limit']) is int and total == proof['attempts_used'] and total <= proof['attempt_limit'] <= 10)
        require(type(proof['current_round']) is int and proof['current_round'] == run['code_repair_round'])
        latest_tasks = rows(connection,"SELECT * FROM factory_tasks WHERE run_id=? AND role='feature-writer'",(execution['run_id'],))
        require(len(latest_tasks) == 1 and latest_tasks[0]['status'] == 'CONSUMED')
        latest_task = latest_tasks[0]
        current_workers = rows(connection,"SELECT * FROM worker_evidence WHERE task_key=? AND status='CONSUMED' AND thread_id=? AND turn_id=? AND output_json=?",(latest_task['task_key'],latest_task['thread_id'],latest_task['turn_id'],latest_task['output_json']))
        require(len(current_workers) == 1)
        latest = current_workers[0]; latest_binding = decode(latest['binding_json'])
        require(sha(latest['binding_json'].encode()) == latest['binding_sha256'] and sha(latest['output_json'].encode()) == latest['output_sha256'])
        require(latest_binding['stage'] == latest_task['stage'] and latest_binding['run_id'] == run['run_id'] and latest_binding['spec_revision'] == run['spec_revision'] and latest_binding['contract_sha256'] == run['contract_sha256'])
        if run['state'] == binding['state'] == 'CI_PUSHING':
            require('verified_ci_rollover' not in binding and 'verified_ci_rollover' not in execution)
            require(latest_binding['stage'] == 'REPAIRING')
            if 'ordinary_verifier_repair' in binding:
                ordinary_repair(connection,execution,binding,run)
                require(proof['current_claim_key'] is None and proof['attempt_limit'] == 10)
            else:
                require(type(binding.get('ci_repair')) is dict)
                current_claim = rows(connection,'SELECT * FROM ticket_ci_repair_claims WHERE claim_key=? AND run_id=?',(proof['current_claim_key'],execution['run_id']))
                require(len(current_claim) == 1 and current_claim[0]['round'] == run['code_repair_round'] and proof['current_claim_key'] == binding['ci_repair']['claim_key'])
                instruction_claim(connection,latest,latest_task,current_claim[0],run)
                require(current_policy(connection,execution,binding,run) == proof['attempt_limit'])
        elif run['state'] == binding['state'] == 'PUSHING':
            require(proof['current_claim_key'] is None and 'ci_repair' not in binding and 'ci_repair_policy_receipt' not in binding and 'ci_repair_policy_receipt' not in execution and proof['attempt_limit'] == 10)
            if latest_binding['stage'] == 'REPAIRING':
                verified_rollover(connection,execution,binding,run,latest,latest_task)
            else:
                require(latest_binding['stage'] in ('WRITING','REVIEW_WRITING') and 'verified_ci_rollover' not in binding and 'verified_ci_rollover' not in execution)
            verifier = binding['verifier']
            actual_verifier = rows(connection,"SELECT * FROM worker_evidence WHERE request_key=? AND run_id=? AND status='CONSUMED'",(verifier['request_key'],execution['run_id']))
            require(len(actual_verifier) == 1 and all(actual_verifier[0][key] == value for key,value in verifier.items()))
            verified_output = decode(actual_verifier[0]['output_json'])
            require(sha(actual_verifier[0]['output_json'].encode()) == actual_verifier[0]['output_sha256'] and verified_output['status'] == 'PASS' and verified_output['candidate_sha'] == run['candidate_sha'])
        else:
            reject()
        require(connection.execute("SELECT 1 FROM ticket_ci_generation_intents i WHERE i.run_id=? AND NOT EXISTS(SELECT 1 FROM ticket_ci_generation_events e WHERE e.intent_key=i.intent_key AND e.event_type='FINALIZED' AND e.path='') LIMIT 1",(execution['run_id'],)).fetchone() is None)
        require(connection.execute("SELECT 1 FROM ticket_ordinary_generation_intents i WHERE i.run_id=? AND NOT EXISTS(SELECT 1 FROM ticket_ordinary_generation_events e WHERE e.intent_key=i.intent_key AND e.event_type='FINALIZED' AND e.path='') LIMIT 1",(execution['run_id'],)).fetchone() is None)
        return successors
    except (KeyError, TypeError, AttributeError, json.JSONDecodeError, OSError):
        reject()



CAPABILITY_HELPER_FORMAT = {
    **{f"ticket_push_executor_v{version}.py": "required" for version in range(15, 22)},
    "ticket_push_executor_v23.py": "optional",
    "ticket_push_executor_v24.py": "required",
    "ticket_push_executor_v25.py": "optional",
    "ticket_push_executor_v26.py": "required",
'ticket_push_executor_v27.py':"optional",'ticket_push_executor_v28.py':"required",
    "ticket_push_executor_v29.py": "optional",
    "ticket_push_executor_v30.py": "required",
    "ticket_push_executor_v31.py": "optional",
    "ticket_push_executor_v32.py": "required",
    "ticket_push_executor_v33.py": "optional",
    "ticket_push_executor_v34.py": "required",
    "ticket_push_executor_v35.py": "optional",
    "ticket_push_executor_v36.py": "required",
    "ticket_push_executor_v37.py": "optional",
    "ticket_push_executor_v38.py": "required",
}


def capability_projection(execution, proof):
    mode = CAPABILITY_HELPER_FORMAT.get(os.path.basename(execution["helper_path"]))
    version = proof.get("capability_recovery_version")
    if mode == "required":
        capability_require(type(version) is int and version == 1)
    elif version is not None:
        capability_require(mode == "optional" and type(version) is int and version == 1)
    return version == 1


CAPABILITY_EVENT_TYPES = (
    'TICKET_CAPABILITY_RECOVERY_AUTHORIZED', 'TICKET_CAPABILITY_RECOVERY_CHECKED',
    'TICKET_CAPABILITY_RECOVERY_APPLIED', 'TICKET_CAPABILITY_RECOVERY_PREPARED_ADMITTED',
)


def capability_require(value):
    if not value:
        raise ValueError("worker_history_blocked_transfer_unproven")


def capability_receipt(row, worker, access):
    check = capability_require
    binding_raw, receipt_raw = row['io_binding_json'], row['io_receipt_json']
    check(type(binding_raw) is str and len(binding_raw.encode()) <= 262144)
    check(type(receipt_raw) is str and len(receipt_raw.encode()) <= 262144)
    binding, receipt = decode(binding_raw), decode(receipt_raw)
    check(binding['version'] == 1 and binding['operation'] in ('replace', 'replace_binary'))
    expected = {name: row[name] for name in ('request_key', 'call_id', 'arguments_sha256', 'path', 'before_sha256', 'after_sha256')}
    expected.update(invocation=row['io_invocation'], root=access['canonical_path'],
                    generation=access['generation'], reservation_key=access['reservation_key'],
                    run_id=worker['run_id'], workspace_binding_sha256=sha(access['binding_json'].encode()))
    check(all(binding.get(name) == value for name, value in expected.items()))
    check(binding['helper_sha256'] == sha((pathlib.Path(__file__).parent/'worker_file_io.py').read_bytes()))
    check(binding['companion_sha256'] == PUSH_COMPANION_SHA)
    check(binding['profile_sha256'] == '5117bcddc83e15518ec518d7511956244d5a0dac73e0348ddff108a454fd039f')
    check(all(type(binding[name]) is int and binding[name] > 0 for name in ('root_device','root_inode','spool_device','spool_inode','generation')))
    check(all(type(binding[name]) is str and os.path.isabs(binding[name]) for name in ('spool','root','database')))
    check(all(hex_digest(binding[name]) for name in ('input_sha256', 'profile_sha256', 'worker_binding_sha256', 'worker_process_sha256')))
    check(binding['worker_binding_sha256'] == worker['binding_sha256'] and binding['worker_owner_id'] == worker['owner_id'])
    check((binding['worker_thread_id'], binding['worker_turn_id']) == (worker['thread_id'], worker['turn_id']))
    check(binding['worker_process_sha256'] == sha(worker['owner_process_json'].encode()))
    check(set(receipt) == set('transport pid nonce helper_sha256 input_sha256 arguments_sha256 exit_status termination binding_sha256 creator_json creator_sha256 cleanup'.split()) or
          set(receipt) == set('transport pid nonce helper_sha256 input_sha256 arguments_sha256 exit_status termination binding_sha256 creator_json creator_sha256 cleanup recovery'.split()))
    check(receipt['transport'] == 'owned_file_helper' and type(receipt['pid']) is int and receipt['pid'] > 0)
    check(receipt['exit_status'] == 0 and receipt['termination'] == {'code': 0, 'kind': 'exited'})
    check(receipt['binding_sha256'] == sha(binding_raw.encode()) and receipt['nonce'] == row['io_invocation'])
    check(all(receipt[name] == binding[name] for name in ('helper_sha256', 'input_sha256', 'arguments_sha256')))
    check('recovery' not in receipt or receipt['recovery'] == {'kind': 'COMPLETE_ARTIFACTS'})
    creator_raw = receipt['creator_json']
    check(type(creator_raw) is str and len(creator_raw.encode()) <= 4096 and sha(creator_raw.encode()) == receipt['creator_sha256'])
    creator = decode(creator_raw)
    check(set(creator) == set('version event nonce binding_sha256 pid path temporary root_device root_inode parent_device parent_inode device inode'.split()))
    check(creator['version'] == 1 and creator['event'] == 'TEMP_CREATED')
    check(creator['pid'] == receipt['pid'] and creator['nonce'] == binding['invocation'])
    check(creator['temporary'] == '.symphony-' + binding['invocation'])
    check(creator['binding_sha256'] == sha(binding_raw.encode()))
    check(all(type(creator[name]) is int and creator[name] > 0 for name in ('pid', 'root_device', 'root_inode', 'parent_device', 'parent_inode', 'device', 'inode')))
    check(all(creator[name] == binding[name] for name in ('path', 'root_device', 'root_inode')))
    cleanup = receipt['cleanup']
    check(set(cleanup) == set('version binding_sha256 original_pid creator_sha256 input_json input_sha256 pid helper_pid termination output_base64'.split()))
    check(cleanup['version'] == 1 and type(cleanup['pid']) is int and cleanup['pid'] > 0 and cleanup['helper_pid'] == cleanup['pid'])
    check(cleanup['termination'] == {'code': 0, 'kind': 'exited'} and cleanup['original_pid'] == receipt['pid'])
    check(cleanup['binding_sha256'] == sha(binding_raw.encode()) and cleanup['creator_sha256'] == receipt['creator_sha256'])
    check(type(cleanup['input_json']) is str and len(cleanup['input_json'].encode()) <= 8192 and sha(cleanup['input_json'].encode()) == cleanup['input_sha256'])
    check(type(cleanup['output_base64']) is str and len(cleanup['output_base64']) <= 8192)
    args = {name: creator[name] for name in ('path', 'parent_device', 'parent_inode', 'device', 'inode')}
    args.update(source_nonce=binding['invocation'], before_sha256=binding['before_sha256'], after_sha256=binding['after_sha256'])
    check(decode(cleanup['input_json']) == {'version': 1, 'nonce': binding['invocation'], 'root': binding['root'],
          'device': binding['root_device'], 'inode': binding['root_inode'], 'operation': 'temporary_recover', 'arguments': args})


def capability_transfer(connection, event_rows, worker, access, destination, new_access, transfer, encoded_worker):
    check = capability_require
    parsed = []
    for row in event_rows:
        if row['event_type'] in CAPABILITY_EVENT_TYPES:
            check(type(row['payload_json']) is str and len(row['payload_json'].encode()) <= 262144)
            parsed.append((row, decode(row['payload_json'],262144)))
    auths = [(row, value) for row, value in parsed if row['event_type'] == CAPABILITY_EVENT_TYPES[0] and value.get('authorization', {}).get('request_key') == worker['request_key']]
    apps = [(row, value) for row, value in parsed if row['event_type'] == CAPABILITY_EVENT_TYPES[2] and value.get('prior_request_key') == worker['request_key']]
    check(len(auths) == len(apps) == 1)
    auth_row, auth = auths[0]; app_row, app = apps[0]
    auth_sha = sha(auth_row['payload_json'].encode()); key = 'TCAP-' + auth_sha
    check(transfer['operational_recovery_key'] == app['recovery_key'] == key and app['authorization_sha256'] == auth_sha)
    check(auth['version'] == 1 and auth['kind'] == 'RESTORED_BASE_READ_CAPABILITY_V1' and auth['authority'] == 'LOCAL_OPERATOR_AUTHORIZATION')
    authorization = auth['authorization']; grant = auth['grant']
    check(grant['purpose'] == 'RESUME_EXACT_BASE_PREIMAGE_BLOCKED_WRITER')
    check(auth['grant_sha256'] == authorization['grant_sha256'] and grant['grant_id'] == authorization['grant_id'])
    check(hex_digest(auth['grant_sha256']) and hex_digest(grant['nonce']))
    global_grants = rows(connection,"SELECT id,payload_json FROM events WHERE event_type='TICKET_CAPABILITY_RECOVERY_AUTHORIZED' AND (json_extract(payload_json,'$.grant.grant_id')=? OR json_extract(payload_json,'$.grant_sha256')=? OR json_extract(payload_json,'$.grant.nonce')=?)",(grant['grant_id'],auth['grant_sha256'],grant['nonce']))
    check(len(global_grants) == 1 and global_grants[0]['id'] == auth_row['id'] and sha(global_grants[0]['payload_json'].encode()) == auth_sha)
    check(sha(authorization['authorization_body'].encode()) == auth['authorization_body_sha256'])
    check(type(authorization['authorization_reference']) is str and authorization['authorization_reference'])
    check(all(authorization[name] == worker[name] for name in ('run_id', 'request_key', 'turn_id', 'output_sha256', 'binding_sha256')))
    output = decode(worker['output_json']); old_binding = decode(worker['binding_json'])
    check(output['status'] == 'BLOCKED' and output['blockers'] == grant['capability_blockers'] and grant['base_paths'] == authorization['base_paths'])
    check(sorted(item['path'] for item in auth['base_blobs']) == sorted(authorization['base_paths']))
    check(len(set(authorization['base_paths'])) == len(authorization['base_paths']) and 1 <= len(authorization['base_paths']) <= 8)
    for blob in auth['base_blobs']:
        check(blob['revision'] == authorization['base_sha'] and blob['mode'] in ('100644','100755'))
        check(hex_digest(blob['blob_oid'],40) and hex_digest(blob['sha256']) and type(blob['total_bytes']) is int and 0 <= blob['total_bytes'] <= 262144)
    check(sha(worker['output_json'].encode()) == worker['output_sha256'] and sha(worker['binding_json'].encode()) == worker['binding_sha256'])
    check(all(authorization[name] == old_binding[name] for name in ('base_sha', 'spec_revision', 'contract_sha256')))
    check(authorization['candidate_sha'] == old_binding['expected_sha'] and old_binding['mode'] == 'SOURCE' and old_binding['role'] == 'feature-writer')
    created = capability_grant_utc(grant['created_at'])
    expires = capability_grant_utc(grant['expires_at'])
    check(created <= utc(auth['authorized_at']) < expires)
    check(0 < (expires - created).total_seconds() <= 900)
    check(len([1 for row, value in parsed if row['event_type'] == CAPABILITY_EVENT_TYPES[0] and
          (value.get('grant_sha256') == auth['grant_sha256'] or value.get('grant', {}).get('nonce') == grant['nonce'] or value.get('grant', {}).get('grant_id') == grant['grant_id'])]) == 1)
    checks = [(row, value) for row, value in parsed if row['event_type'] == CAPABILITY_EVENT_TYPES[1] and row['id'] == app['checked_event_id']]
    check(len(checks) == 1)
    checked_row, checked = checks[0]
    check(auth_row['id'] < checked_row['id'] < app_row['id'] and sha(checked_row['payload_json'].encode()) == app['checked_sha256'])
    check(checked['version'] == 1 and checked['kind'] == 'CAPABILITY_RECOVERY_CHECKED_V1' and checked['mode'] == 'INITIAL')
    check(checked['authorization_sha256'] == auth_sha and checked['ledger'] == auth['ledger'] and checked['policy'] == auth['policy'])
    tick = checked['tick']
    check(type(tick['generation']) is int and tick['generation'] > 0 and type(tick['tick_id']) is str and tick['tick_id'])
    check(tick['scope'] == auth['control']['scope'] and tick['dispatcher_id'] == auth['control']['dispatcher_id'])
    check(utc(checked['observed_at']) <= utc(app['applied_at']) < utc(checked['expires_at']))
    check(utc(auth['authorized_at']) <= utc(checked['observed_at']))
    check(0 <= (utc(app['applied_at']) - utc(checked['source_observed_at'])).total_seconds() <= 30)
    check(auth['ledger']['evidence'] == sha(encoded_worker))
    dispositions = [(row,decode(row['payload_json'])) for row in event_rows if row['event_type'] == 'TICKET_NATIVE_WRITER_BLOCKED' and digest({'id':row['id'],'payload_json':row['payload_json']}) == auth['ledger']['disposition']]
    check(len(dispositions) == 1)
    disposition = dispositions[0][1]
    check(disposition['request_key'] == worker['request_key'] and disposition['output_sha256'] == worker['output_sha256'])
    check(disposition['output_json'] == worker['output_json'] and disposition['blockers'] == output['blockers'])
    check(disposition['disposition_key'] == transfer['disposition_key'] and disposition['reservation_key'] == access['reservation_key'] and disposition['reservation_generation'] == access['generation'])
    original_access = dict(access, released_at=None, release_receipt_json=None)
    check(auth['ledger']['access'] == digest(original_access))
    check(app['release_sha256'] == sha(access['release_receipt_json'].encode()))
    check(app['version'] == 1 and app['kind'] == 'CAPABILITY_RECOVERY_APPLIED_V1')
    fields = ('old_request_key','old_reservation_key','new_request_key','new_reservation_key','disposition_key','output_sha256','checkout_head_sha','operational_recovery_key')
    check(all(transfer.get(name) == app.get(name) for name in fields))
    check(transfer['old_reservation_key'] == access['reservation_key'] and transfer['output_sha256'] == worker['output_sha256'])
    check(transfer['old_generation'] == access['generation'])
    check(all(transfer.get(name) is None for name in ('command_key','input_key','amendment_command_key')))
    check(transfer['checkout_head_sha'] == authorization['candidate_sha'] and new_access['generation'] == access['generation'] + 1 == app['new_generation'] == app['reservation_generation'])
    check((app['request_key'], app['reservation_key']) == (destination['request_key'], new_access['reservation_key']))
    check(all(new_access[name] == access[name] for name in ('run_id','task_key','mode','canonical_path','git_dir','common_dir')))
    check(access['mode'] == 'SOURCE' and destination['thread_id'] == worker['thread_id'])
    new_binding = decode(destination['binding_json'])
    check(sha(destination['binding_json'].encode()) == destination['binding_sha256'])
    check(all(new_binding[name] == old_binding[name] for name in ('base_sha','spec_revision','contract_sha256','role','mode','model','reasoning_effort','policy','schema')))
    check(checked['destination'] == {'request_key':destination['request_key'], 'reservation_key':new_access['reservation_key'],
          'generation':new_access['generation'], 'prompt_sha256':new_binding['input_sha256']})
    check(new_binding['prompt_sha256'] == new_binding['input_sha256'] and new_binding['reservation_generation'] == new_access['generation'])
    check(new_binding == dict(old_binding,prompt_sha256=new_binding['input_sha256'],input_sha256=new_binding['input_sha256'],reservation_key=new_access['reservation_key'],reservation_generation=new_access['generation']))
    old_access_binding = decode(access['binding_json']); new_access_binding = decode(new_access['binding_json'])
    check(new_access_binding == dict(old_access_binding,request_key=destination['request_key'],reservation_key=new_access['reservation_key'],prompt_sha256=new_binding['input_sha256']))
    journal = [dict(row) for row in connection.execute('SELECT rowid AS journal_rowid,* FROM worker_file_operations WHERE request_key=? ORDER BY rowid',(worker['request_key'],))]
    check(1 <= len(journal) <= 128 and digest(journal) == auth['ledger']['operations'])
    groups = {}
    for row in journal:
        check(row['phase'] == 'APPLIED' and row['io_pending'] == 0 and hex_digest(row['before_sha256']) and hex_digest(row['after_sha256']))
        capability_receipt(row, worker, access)
        groups.setdefault(row['path'], []).append(row)
    check(sorted(groups) == sorted(output['changed_paths']) == sorted(item['path'] for item in auth['files']))
    for file in auth['files']:
        chain = groups[file['path']]
        check(file['operations'] == [{'rowid':row['journal_rowid'], 'sha256':digest(row)} for row in chain])
        check(file['before_sha256'] == chain[0]['before_sha256'] and file['after_sha256'] == chain[-1]['after_sha256'])
        check(all(left['after_sha256'] == right['before_sha256'] for left,right in zip(chain,chain[1:])))
    admitted = [(row,value) for row,value in parsed if row['event_type'] == CAPABILITY_EVENT_TYPES[3] and value.get('operational_recovery_key') == key]
    for row,value in admitted:
        matching = [(r,v) for r,v in parsed if r['event_type'] == CAPABILITY_EVENT_TYPES[1] and r['id'] == value['checked_event_id']]
        check(len(matching) == 1 and matching[0][0]['id'] < row['id'])
        r,v = matching[0]
        check(sha(r['payload_json'].encode()) == value['checked_sha256'] and v['mode'] == 'PREPARED' and v['authorization_sha256'] == auth_sha)
        check(v['destination'] == checked['destination'] and value['prepared_request_key'] == destination['request_key'])
        check(value['prepared_reservation_key'] == new_access['reservation_key'] and value['prepared_reservation_generation'] == new_access['generation'])
        check(len([1 for rr,vv in admitted if vv['checked_event_id'] == r['id']]) == 1)


def worker_history(connection, execution):
    proof = execution["worker_history"]
    run_id = execution["run_id"]
    review_events = rows(connection, "SELECT * FROM events WHERE run_id=? AND event_type IN ('TICKET_REVIEW_REPORT_CORRECTED','TICKET_REVIEW_DECISION') ORDER BY id", (run_id,))
    captured = [{key:sha(value.encode()) if key == 'payload_json' else value for key,value in row.items()} for row in review_events]
    require(decode(proof['review_events_json']) == captured)
    for worker in rows(connection, "SELECT * FROM worker_evidence WHERE run_id=? AND status='CONSUMED' ORDER BY rowid", (run_id,)):
        wb = decode(worker['binding_json']); output = decode(worker['output_json'])
        if 'review_report' not in output: continue
        mapping = rows(connection, 'SELECT * FROM worker_instruction_task_bindings WHERE task_key=? AND prompt_sha256=?', (worker['task_key'],wb['input_sha256']))
        require(len(mapping) == 1)
        snapshots = rows(connection, 'SELECT * FROM worker_instruction_snapshots WHERE binding_sha256=?', (mapping[0]['instruction_binding_sha256'],))
        require(len(snapshots) == 1 and sha(snapshots[0]['binding_json'].encode()) == mapping[0]['instruction_binding_sha256'])
        packet = decode(snapshots[0]['binding_json'])
        validate_review_admission(connection, worker, wb, output, packet)
    successors = validate_successors(connection, execution)
    queries = {
        "workers": ("SELECT * FROM worker_evidence WHERE run_id = ? ORDER BY request_key",),
        "tasks": ("SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY task_key",),
        "accesses": ("SELECT * FROM workspace_access WHERE run_id = ? ORDER BY reservation_key",),
        "events": ("SELECT * FROM events WHERE run_id = ? AND event_type IN ('TICKET_FAILED_TURN_RECOVERY_AUTHORIZED', 'TICKET_FAILED_TURN_RECOVERY_APPLIED', 'TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED', 'TICKET_INFRASTRUCTURE_RECOVERY_APPLIED', 'TICKET_NATIVE_WRITER_BLOCKED', 'TICKET_CI_REPAIR_SUCCESSOR_APPLIED') ORDER BY id",),
        "commands": ("SELECT * FROM ticket_chat_commands WHERE run_id = ? ORDER BY command_key",),
        "successors": ("SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id = ? ORDER BY attempt_index",),
        "generation_intents": ("SELECT * FROM ticket_ordinary_generation_intents WHERE run_id=? ORDER BY intent_key",),
        "generation_events": ("SELECT e.* FROM ticket_ordinary_generation_events e JOIN ticket_ordinary_generation_intents i ON i.intent_key=e.intent_key WHERE i.run_id=? ORDER BY e.event_key",),
    }
    if capability_projection(execution, proof):
        capability_require(proof.get("capability_recovery_version") == 1)
        query = queries["events"][0]
        query = query.replace(") ORDER BY id", ", " + ", ".join("'" + name + "'" for name in CAPABILITY_EVENT_TYPES) + ") ORDER BY id")
        queries["events"] = (query,)
    observed = {}
    digest_fields = {"workers": ("binding_json", "output_json", "policy_json"), "tasks": ("output_json",), "accesses": ("binding_json", "release_receipt_json"), "events": ("payload_json",), "commands": ("binding_json", "payload_json", "receipt_json", "application_receipt_json"), "successors": ("evidence_json", "proof_json")}
    digest_fields.update({'generation_intents':('binding_json',),'generation_events':('receipt_json',)})
    for name, (query,) in queries.items():
        actual = [dict(row) for row in connection.execute(query, (run_id,))]
        compact = [{key: sha(value.encode()) if key in digest_fields[name] and isinstance(value, str) else value for key, value in row.items()} for row in actual]
        if compact != json.loads(proof[name + "_json"]):
            raise ValueError("worker_history_changed")
        observed[name] = actual
    workers = {row["request_key"]: row for row in observed["workers"]}
    accesses = {row["reservation_key"]: row for row in observed["accesses"]}
    commands = {row["command_key"]: row for row in observed["commands"]}
    events = [(row["event_type"], json.loads(row["payload_json"])) for row in observed["events"]]

    def stopped(worker):
        access = accesses.get(worker["reservation_key"])
        stop = json.loads(worker["owner_stop_json"] or "null")
        process = json.loads(worker["owner_process_json"] or "null")
        return (access is not None and worker["owner_stopped_at"] is not None and isinstance(stop, dict)
                and set(stop) == {"transport", "thread_id", "pid", "invocation_nonce", "exit_status", "cwd"}
                and (stop["transport"], stop["thread_id"], stop["cwd"]) == ("owned_app_server", worker["thread_id"], access["canonical_path"])
                and isinstance(stop["exit_status"], int) and isinstance(stop["pid"], str) and stop["pid"]
                and isinstance(stop["invocation_nonce"], str) and len(stop["invocation_nonce"]) == 64
                and all(char in "0123456789abcdef" for char in stop["invocation_nonce"])
                and process == {"pid": stop["pid"], "invocation_nonce": stop["invocation_nonce"]})

    edges = {}
    for key, worker in workers.items():
        keys = proof["worker_key_order"]
        if set(keys) != set(worker) or len(keys) != len(worker):
            raise ValueError("worker_history_encoding_unproven")
        encoded_worker = json.dumps({name: worker[name] for name in keys}, separators=(",", ":"), ensure_ascii=False).encode()
        access = accesses.get(worker["reservation_key"])
        if access is None or access["released_at"] is None:
            raise ValueError("worker_history_source_unreleased")
        if worker["status"] == "CONSUMED":
            if not stopped(worker):
                raise ValueError("worker_history_stop_unproven")
            continue
        transfer = json.loads(access["release_receipt_json"] or "null")
        if not isinstance(transfer, dict) or transfer.get("old_request_key") != key:
            raise ValueError("worker_history_transfer_unproven")
        destination = workers.get(transfer.get("new_request_key"))
        new_access = accesses.get(destination["reservation_key"]) if destination else None
        if destination is None or new_access is None or (destination["run_id"], destination["task_key"]) != (worker["run_id"], worker["task_key"]) or new_access["generation"] <= access["generation"] or new_access["canonical_path"] != access["canonical_path"]:
            raise ValueError("worker_history_lineage_unproven")
        if transfer.get("kind") in ("FAILED_TURN_QUIESCENCE", "INTERRUPTED_TURN_QUIESCENCE"):
            applied = next((payload for kind, payload in events if kind == "TICKET_FAILED_TURN_RECOVERY_APPLIED" and payload.get("old_request_key") == key), None)
            authorized = next((payload for kind, payload in events if kind == "TICKET_FAILED_TURN_RECOVERY_AUTHORIZED" and applied and payload.get("recovery_key") == applied.get("recovery_key")), None)
            fields = ("kind", "recovery_key", "old_request_key", "new_request_key", "new_reservation_key")
            if applied is None or authorized != {name: val for name, val in applied.items() if name not in ("new_generation", "new_binding_sha256")} or sha(encoded_worker) != applied["old_evidence_sha256"] or transfer != {name: applied[name] for name in fields} or applied["new_binding_sha256"] != sha(destination["binding_json"].encode()) or applied["new_generation"] != new_access["generation"]:
                raise ValueError("worker_history_failed_transfer_unproven")
        elif transfer.get("kind") == "BLOCKED_SOURCE_TRANSFER":
            command = commands.get(transfer.get("command_key"))
            if command is not None:
                application = json.loads(command["application_receipt_json"] or "null")
            else:
                application = None
            if str(transfer.get("operational_recovery_key", "")).startswith("TCAP-"):
                capability_require(capability_projection(execution, proof))
                capability_require(stopped(worker))
                capability_transfer(connection, observed["events"], worker, access, destination, new_access, transfer, encoded_worker)
                valid = True
            elif transfer.get("operational_recovery_key"):
                applied = next((payload for kind, payload in events if kind == "TICKET_INFRASTRUCTURE_RECOVERY_APPLIED" and payload.get("prior_request_key") == key), None)
                authorized = next((payload for kind, payload in events if kind == "TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED" and applied and payload.get("recovery_key") == applied.get("recovery_key")), None)
                fields = ("kind", "old_request_key", "old_reservation_key", "new_request_key", "new_reservation_key", "disposition_key", "output_sha256", "checkout_head_sha", "operational_recovery_key")
                valid = (stopped(worker) and applied is not None and authorized is not None and all(transfer.get(name) == applied.get(name) for name in fields)
                         and transfer["operational_recovery_key"] == applied["recovery_key"] == authorized["recovery_key"]
                         and authorized["request_key"] == key and authorized["output_sha256"] == worker["output_sha256"] and authorized["binding_sha256"] == worker["binding_sha256"]
                         and new_access["generation"] == applied["new_generation"])
            else:
                valid = (stopped(worker) and command is not None and command["status"] == "APPLIED" and isinstance(application, dict)
                         and application.get("kind") == "BLOCKED_WRITER_RESUMED" and application.get("prior_request_key") == key
                         and application.get("request_key") == destination["request_key"] and application.get("reservation_key") == new_access["reservation_key"]
                         and transfer.get("old_reservation_key") == access["reservation_key"] and transfer.get("output_sha256") == worker["output_sha256"]
                         and transfer.get("input_key") == command["input_key"] and transfer.get("disposition_key") == application.get("disposition_key"))
            if not valid:
                raise ValueError("worker_history_blocked_transfer_unproven")
        elif transfer.get("kind") == "CI_EVIDENCE_SUCCESSOR_TRANSFER_V1":
            validate_transfer(successors, worker, access, destination, new_access, transfer)
        else:
            raise ValueError("worker_history_transfer_kind_unproven")
        edges[key] = destination["request_key"]
    for key in edges:
        seen = set()
        while workers[key]["status"] != "CONSUMED":
            if key in seen or key not in edges:
                raise ValueError("worker_history_lineage_unproven")
            seen.add(key)
            key = edges[key]
    if not any(task["role"] == "feature-writer" for task in observed["tasks"]):
        raise ValueError("latest_writer_missing")
    for task in observed["tasks"]:
        if task["role"] == "feature-writer" and (task["status"] != "CONSUMED" or not any(worker["task_key"] == task["task_key"] and worker["status"] == "CONSUMED" and (worker["thread_id"], worker["turn_id"], worker["output_json"]) == (task["thread_id"], task["turn_id"], task["output_json"]) for worker in workers.values())):
            raise ValueError("latest_writer_unconsumed")
    if connection.execute("SELECT reservation_key FROM workspace_access WHERE run_id = ? AND mode = 'SOURCE' AND released_at IS NULL LIMIT 1", (run_id,)).fetchone() or connection.execute("SELECT op.call_id FROM worker_file_operations op JOIN worker_evidence worker ON worker.request_key = op.request_key WHERE worker.run_id = ? AND (op.phase = 'PREPARED' OR op.io_pending = 1) LIMIT 1", (run_id,)).fetchone():
        raise ValueError("worker_history_active_source")
