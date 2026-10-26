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


def digest(value):
    return sha(canonical(value))


def hex_digest(value, size=64):
    return type(value) is str and re.fullmatch('[0-9a-f]{'+str(size)+'}', value) is not None


def utc(value):
    require(type(value) is str and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z',value) is not None)
    return datetime.datetime.fromisoformat(value[:-1]+'+00:00')


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
        saved = json.loads(claim["claim_json"])
        key, expected = saved.get("reassessment_key"), saved.get("reassessment_sha256")
        if key is None and expected is None:
            if original["verdict"] != "REPAIRABLE":
                raise ValueError("ci_repair_diagnosis_changed")
            return json.loads(original["diagnosis_json"])
        row = connection.execute("SELECT * FROM ticket_ci_repair_reassessments WHERE reassessment_key = ?", (key,)).fetchone()
        fields = {"reassessment_key", "diagnosis_key", "collector_version", "original_sha256", "run_id", "candidate_sha", "pipeline_id", "preimage_json", "preimage_sha256", "diagnosis_json", "diagnosis_sha256", "verdict", "created_at", "kind"}
        if row is None or set(row.keys()) != fields or digest(dict(row)) != expected or row["original_sha256"] != digest(dict(original)):
            raise ValueError("ci_repair_diagnosis_changed")
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


def claim_diagnosis(connection, claim):
    scope = decode(claim['claim_json'])
    require(scope['diagnosis_key'] == claim['diagnosis_key'])
    original = connection.execute('SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key=?',(claim['diagnosis_key'],)).fetchone()
    require(original is not None)
    original = dict(original)
    require(set(original) == set('diagnosis_key run_id candidate_sha pipeline_id preimage_json preimage_sha256 diagnosis_json diagnosis_sha256 verdict created_at'.split()))
    require(type(original['pipeline_id']) is int and original['pipeline_id'] > 0 and all(type(value) is str for key,value in original.items() if key != 'pipeline_id'))
    require(original['run_id'] == claim['run_id'] == scope['prior_run']['run_id'] and original['candidate_sha'] == scope['prior_run']['candidate_sha'] and original['pipeline_id'] == scope['ci_snapshots']['pipeline']['id'])
    require(sha(original['preimage_json'].encode()) == original['preimage_sha256'] and sha(original['diagnosis_json'].encode()) == original['diagnosis_sha256'])
    preimage, raw_diagnosis = decode(original['preimage_json']), decode(original['diagnosis_json'])
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
    stat_keys = set('inode device rdev size mtime_seconds uid mode'.split())
    require(type(receipt) is dict and set(receipt) == keys and type(receipt['version']) is int and receipt['version'] == 1 and receipt['kind'] == 'CI_REPAIR_POLICY_V1')
    require(type(receipt['configured_limit']) is int and receipt['configured_limit'] >= 1 and type(receipt['effective_limit']) is int and receipt['effective_limit'] == min(receipt['configured_limit'],5))
    require(type(receipt['workflow_path']) is str and os.path.isabs(receipt['workflow_path']) and os.path.normpath(receipt['workflow_path']) == receipt['workflow_path'] and os.path.commonpath([receipt['workflow_path'],run['worktree']]) != run['worktree'])
    require(type(receipt['workflow_stat']) is dict and set(receipt['workflow_stat']) == stat_keys and all(type(value) is int for value in receipt['workflow_stat'].values()))
    require(stat.S_ISREG(receipt['workflow_stat']['mode']) and not receipt['workflow_stat']['mode'] & 0o022 and receipt['workflow_stat']['uid'] == os.geteuid())
    require(hex_digest(receipt['workflow_sha256']) and hex_digest(receipt['cached_policy_sha256']) and receipt['repo_key'] == run['repo_key'])
    require(all(type(receipt[key]) is str and receipt[key] for key in ('scope','dispatcher_id','repo_key')))
    return receipt['effective_limit']


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
    scope = decode(claim['claim_json']); repair = packet['ci_repair']; diagnosis = claim_diagnosis(connection,claim)
    require(type(repair) is dict and repair['claim_key'] == claim['claim_key'] and repair['failed_candidate_sha'] == scope['prior_run']['candidate_sha'] and repair['allowed_writer_paths'] == scope['allowed_writer_paths'] and repair['required_generated_paths'] == scope['required_generated_paths'])
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
    admission_stop(worker,access)
    receipt = {key:worker[key] for key in ('request_key','binding_sha256','output_sha256','consumed_at','owner_stopped_at')}
    require(decode(access['release_receipt_json']) == receipt)
    require(utc(access['acquired_at']) <= utc(worker['owner_stopped_at']) <= utc(worker['consumed_at']) <= utc(access['released_at']))
    pin = rows(connection,'SELECT base_sha FROM ticket_review_bases WHERE run_id=?',(worker['run_id'],))
    require(len(pin) == 1 and pin[0]['base_sha'] == binding['base_sha'])
    limits = connection.execute('SELECT COUNT(*),MAX(length(CAST(binding_json AS BLOB))),MAX(length(CAST(receipt_json AS BLOB))) FROM controller_checks WHERE reservation_key=?',(access['reservation_key'],)).fetchone()
    require(1 <= limits[0] <= 64 and limits[1] <= 2_097_152 and limits[2] is not None and limits[2] <= 2_097_152)
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
    require(type(receipt) is dict and set(receipt) == receipt_keys and receipt == execution['ci_repair_policy_receipt'] and type(receipt['version']) is int and receipt['version'] == 1 and receipt['kind'] == 'CI_REPAIR_POLICY_V1')
    actual = connection.execute('SELECT candidate_handoff FROM runs WHERE run_id=?',(execution['run_id'],)).fetchone()
    require(actual is not None)
    intent = decode(actual['candidate_handoff'])
    require(intent['binding_json'] == execution['intent_json'] and sha(intent['binding_json'].encode()) == intent['binding_sha256'] == execution['intent_sha256'] and decode(intent['binding_json']) == binding)
    require(type(receipt['configured_limit']) is int and receipt['configured_limit'] >= 1 and type(receipt['effective_limit']) is int and receipt['effective_limit'] == min(receipt['configured_limit'],5))
    require(receipt['repo_key'] == run['repo_key'] and hex_digest(receipt['workflow_sha256']) and hex_digest(receipt['cached_policy_sha256']))
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
    admission_stop(worker,access[0])
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
    require(size is not None and type(size[0]) is int and 1 <= size[0] <= 2_097_152)
    prior = rows(connection,'SELECT * FROM workspace_access WHERE reservation_key=? AND run_id=?',(qualifier['prior_reservation_key'],run['run_id']))
    require(len(prior) == 1); access = prior[0]
    require(access['mode'] == 'MAINTENANCE' and access['task_key'] is None and access['released_at'] is not None and sha(access['release_receipt_json'].encode()) == qualifier['prior_envelope_sha256'])
    intent = decode(access['release_receipt_json'])
    require(set(intent) == set('version kind phase binding_json binding_sha256 reservation_key reservation_generation owner_nonce helper_pid execution_json receipt_json receipt_sha256 remote_sha'.split()) and type(intent['version']) is int and intent['version'] == 1 and intent['kind'] == 'TICKET_PUSH' and intent['phase'] == 'COMPLETED')
    original, original_execution, receipt = decode(intent['binding_json']),decode(intent['execution_json'],262144),decode(intent['receipt_json'])
    require(hex_digest(execution['helper_sha256']) and original_execution['helper_sha256'] in ('dc7ac631720ab9cdd167b186eef24fb5944047dc4f091e0b2fc29c83cb3a68f5',execution['helper_sha256']))
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


def admission_stop(worker, access):
    stop, process = decode(worker['owner_stop_json']), decode(worker['owner_process_json'])
    require(type(stop) is dict and set(stop) == set('transport thread_id pid invocation_nonce exit_status cwd'.split()))
    require(stop['transport'] == 'owned_app_server' and stop['thread_id'] == worker['thread_id'] and stop['cwd'] == access['canonical_path'])
    require(type(stop['exit_status']) is int and stop['exit_status'] == 0 and type(stop['pid']) is str and re.fullmatch('[1-9][0-9]*',stop['pid']) is not None and hex_digest(stop['invocation_nonce']))
    require(process == {'pid':stop['pid'],'invocation_nonce':stop['invocation_nonce']} and type(worker['owner_stopped_at']) is str and worker['owner_stopped_at'])


def validate_successors(connection, execution):
    try:
        limits = connection.execute('SELECT COUNT(*),MAX(length(CAST(proof_json AS BLOB))),MAX(length(CAST(evidence_json AS BLOB))) FROM ticket_ci_repair_evidence_successors WHERE run_id=?',(execution['run_id'],)).fetchone()
        require(limits[0] <= 4 and (limits[0] == 0 or (limits[1] <= 2_097_152 and limits[2] <= 262144)))
        journal = rows(connection,'SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id=? ORDER BY attempt_index',(execution['run_id'],))
        if not journal:
            return {}
        require(len(journal) <= 4)
        validated = {}
        for row in journal:
            require(set(row) == JOURNAL_KEYS and row['run_id'] == execution['run_id'])
            require(row['successor_key'] == 'ci-evidence-successor:'+digest([row['claim_key'],row['prior_request_key'],row['evidence_content_sha256']]))
            require(type(row['attempt_index']) is int and type(row['configured_limit']) is int and 2 <= row['attempt_index'] <= row['configured_limit'] <= 5)
            require(all(type(row[key]) is str for key in JOURNAL_KEYS - {'prior_successor_key','attempt_index','configured_limit'}))
            require(row['prior_successor_key'] is None or type(row['prior_successor_key']) is str)
            require(sha(row['proof_json'].encode()) == row['proof_sha256'] and sha(row['evidence_json'].encode()) == row['evidence_sha256'])
            proof, evidence = decode(row['proof_json']), decode(row['evidence_json'],262144)
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
            claim_binding = decode(claim['claim_json'])
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
            admission_stop(worker,access)
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


def validate_push_proof(connection, execution, binding, run):
    try:
        proof = binding['ci_evidence_successor']
        require(type(proof) is dict and set(proof) == PUSH_KEYS and proof == execution['ci_evidence_successor'] and type(proof['version']) is int and proof['version'] == 1 and proof['kind'] == 'CI_EVIDENCE_SUCCESSOR_PUSH_V1')
        successors = validate_successors(connection,execution)
        require(successors)
        actual_heads = []
        for claim_key in sorted({entry['row']['claim_key'] for entry in successors.values()}):
            chain = [entry['row'] for entry in successors.values() if entry['row']['claim_key'] == claim_key]
            actual_heads.append({'claim_key':claim_key,'head_key':chain[-1]['successor_key'],'head_row_sha256':digest(chain[-1]),'chain_keys':[row['successor_key'] for row in chain]})
        require(type(proof['heads']) is list and proof['heads'] == actual_heads)
        projection = [{'successor_key':entry['row']['successor_key'],'row_sha256':digest(entry['row'])} for entry in successors.values()]
        require(proof['all_rows_sha256'] == digest(projection))
        total = connection.execute('SELECT (SELECT COUNT(*) FROM ticket_ci_repair_claims WHERE run_id=?) + (SELECT COUNT(*) FROM ticket_ci_repair_evidence_successors WHERE run_id=?)',(execution['run_id'],execution['run_id'])).fetchone()[0]
        require(type(proof['attempts_used']) is int and type(proof['attempt_limit']) is int and total == proof['attempts_used'] and total <= proof['attempt_limit'] <= 5)
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
            require(latest_binding['stage'] == 'REPAIRING' and type(binding.get('ci_repair')) is dict)
            current_claim = rows(connection,'SELECT * FROM ticket_ci_repair_claims WHERE claim_key=? AND run_id=?',(proof['current_claim_key'],execution['run_id']))
            require(len(current_claim) == 1 and current_claim[0]['round'] == run['code_repair_round'] and proof['current_claim_key'] == binding['ci_repair']['claim_key'])
            instruction_claim(connection,latest,latest_task,current_claim[0],run)
            require(current_policy(connection,execution,binding,run) == proof['attempt_limit'])
        elif run['state'] == binding['state'] == 'PUSHING':
            require(proof['current_claim_key'] is None and 'ci_repair' not in binding and 'ci_repair_policy_receipt' not in binding and 'ci_repair_policy_receipt' not in execution and proof['attempt_limit'] == 5)
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
        return successors
    except (KeyError, TypeError, AttributeError, json.JSONDecodeError, OSError):
        reject()


def worker_history(connection, execution):
    proof = execution["worker_history"]
    run_id = execution["run_id"]
    successors = validate_successors(connection, execution)
    queries = {
        "workers": ("SELECT * FROM worker_evidence WHERE run_id = ? ORDER BY request_key",),
        "tasks": ("SELECT * FROM factory_tasks WHERE run_id = ? ORDER BY task_key",),
        "accesses": ("SELECT * FROM workspace_access WHERE run_id = ? ORDER BY reservation_key",),
        "events": ("SELECT * FROM events WHERE run_id = ? AND event_type IN ('TICKET_FAILED_TURN_RECOVERY_AUTHORIZED', 'TICKET_FAILED_TURN_RECOVERY_APPLIED', 'TICKET_INFRASTRUCTURE_RECOVERY_AUTHORIZED', 'TICKET_INFRASTRUCTURE_RECOVERY_APPLIED', 'TICKET_NATIVE_WRITER_BLOCKED', 'TICKET_CI_REPAIR_SUCCESSOR_APPLIED') ORDER BY id",),
        "commands": ("SELECT * FROM ticket_chat_commands WHERE run_id = ? ORDER BY command_key",),
        "successors": ("SELECT * FROM ticket_ci_repair_evidence_successors WHERE run_id = ? ORDER BY attempt_index",),
    }
    observed = {}
    digest_fields = {"workers": ("binding_json", "output_json", "policy_json"), "tasks": ("output_json",), "accesses": ("binding_json", "release_receipt_json"), "events": ("payload_json",), "commands": ("binding_json", "payload_json", "receipt_json", "application_receipt_json"), "successors": ("evidence_json", "proof_json")}
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
            if transfer.get("operational_recovery_key"):
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


