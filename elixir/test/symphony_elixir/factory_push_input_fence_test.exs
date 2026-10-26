defmodule SymphonyElixir.FactoryPushInputFenceTest do
  use ExUnit.Case, async: true

  test "readonly input-fence verifier checks actual files, AST core, null tuple and bounded frame" do
    helper = Path.expand("../../priv/ticket_push_input_fence_v1.py", __DIR__)

    script = ~S'''
    import ast, hashlib, importlib.util, json, os, pathlib, select, shutil, struct, subprocess, sys, tempfile
    helper=sys.argv[1]
    spec=importlib.util.spec_from_file_location('fence', helper); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    sha=lambda raw:hashlib.sha256(raw).hexdigest()
    encode=lambda obj:json.dumps(obj,sort_keys=True,separators=(',',':')).encode()
    with tempfile.TemporaryDirectory(prefix='input-fence-fixture-') as root:
     root=os.path.realpath(root)
     os.chmod(root,0o700)
     def put(name, raw):
      path=os.path.join(root,name); os.makedirs(os.path.dirname(path),exist_ok=True)
      with open(path,'wb') as stream:stream.write(raw)
      os.chmod(path,0o600); return path
     def obj(name,value):return put(name,encode(value))
     source=put('archive/lib/symphony_elixir/factory/ticket_push.ex',b'fixture-original-source')
     artifact=os.path.join(root,'artifact'); beam=put('artifact/module.beam',b'fixture-beam')
     current_io=put('artifact/lib/symphony_elixir/ebin/Elixir.SymphonyElixir.Factory.TicketPushIO.beam',b'fixture-current-io')
     program=put('artifact/lib/symphony_elixir/priv/ticket_push_executor_v3.py',b'fixture-v3')
     old=obj('manifest.json',{'files':[{'path':'/Users/cgable/Repos/symphony-ticket-chat-implementation/elixir/lib/symphony_elixir/factory/ticket_push.ex','sha256':sha(b'fixture-original-source')}]})
     intent={'kind':'TICKET_PUSH','phase':'PUSH_UNCERTAIN','helper_pid':None,'execution_json':None,'receipt_json':None,'receipt_sha256':None,'remote_sha':None}
     envelope=encode(intent).decode(); operation={'run_id':'fixture-run','candidate_sha':'fixture-candidate','nonce':'fixture-nonce','envelope_sha256':sha(envelope.encode()),'reservation_key':'fixture-reservation','reservation_generation':22}
     snapshot={'run':{'run_id':'fixture-run','candidate_sha':'fixture-candidate','candidate_handoff':envelope},'repair':{},'access':[]}
     original=obj('snapshot.json',snapshot); before=obj('before.json',snapshot); after=obj('after.json',snapshot)
     original_trigger={'type':'trigger','name':'fixture-original','tbl_name':'runs','sql':'fixture original SQL'}
     addition={'type':'table','name':'ticket_push_input_retirements','tbl_name':'ticket_push_input_retirements','sql':'fixture reviewed42 SQL'}
     old_schema={'objects':[original_trigger],'migrations':[{'version':n,'applied_at':'2026-10-14T01:00:00.000000Z'} for n in range(1,42)]}
     schema=obj('schema.json',old_schema)
     delta_path=obj('delta.json',{'added_objects':[addition],'added_migrations':[{'version':42}],'empty_tables':['ticket_push_input_retirements']})
     runtime={'pid':99998,'uid':os.getuid(),'os_start':'fixture-start','artifact_path':artifact,'manifest_path':old,'manifest_sha256':sha(pathlib.Path(old).read_bytes()),'source_pins':{source:sha(b'fixture-original-source')},'beam_pins':{beam:sha(b'fixture-beam')},'v3_sha256':sha(b'fixture-v3')}
     interpreter={'path':'/usr/bin/python3','version':'.'.join(map(str,sys.version_info[:3])),'sha256':sha(pathlib.Path('/usr/bin/python3').read_bytes()),'executable_path':sys.executable,'binary_path':os.path.realpath(sys.executable),'executable_sha256':sha(pathlib.Path(os.path.realpath(sys.executable)).read_bytes())}
     scopes={key:[] for key in ['source_pins','beam_pins','test_pins','file_pins','source_additions','beam_additions','manifest_additions']}
     resource=os.path.join(root,'resource.json')
     pins={'old_pid':runtime['pid'],'uid':runtime['uid'],'old_start':runtime['os_start'],'old_build_path':artifact,'old_manifest_path':old,'old_manifest_sha256':runtime['manifest_sha256'],'audit_resource_path':resource,'audit_resource_sha256':'placeholder','protected_path':original,'protected_sha256':sha(pathlib.Path(original).read_bytes()),'schema_path':schema,'schema_sha256':sha(pathlib.Path(schema).read_bytes()),'schema_delta_sha256':'a'*64,**{key:{} for key in ['source_pins','beam_pins','test_pins','file_pins']}}
     for key in ['new_manifest_path','new_manifest_sha256','artifact_proof_path','artifact_proof_sha256','source_proof_path','source_proof_sha256','priv_proof_path','priv_proof_sha256','schema_delta_path','old_plist_path','old_plist_sha256','new_plist_sha256','new_build_path','workflow_sha256']:pins[key]='fixture-bound-value'
     pins['schema_delta_path']=delta_path;pins['schema_delta_sha256']=sha(pathlib.Path(delta_path).read_bytes())
     io_relative='lib/symphony_elixir/ebin/Elixir.SymphonyElixir.Factory.TicketPushIO.beam'
     pins['new_build_path']=artifact;pins['beam_pins']={io_relative:sha(b'fixture-current-io')};scopes['beam_pins']=[io_relative]
     def guard_raw():return ('MODE = '+repr('ROLLOUT_EXACT_HELD_PUSH_INPUT_FENCE')+'\nPINS = '+repr(pins)+'\nREVIEWED_SCOPES = '+repr({key:set(value) for key,value in scopes.items()})+'\n"fixture-core"\n').encode()
     _,core=module.guard_config(guard_raw())
     audit={'original_runtime':runtime,'operation':operation,'original_snapshot':{'path':original,'sha256':pins['protected_sha256']},'guard':{'core_sha256':core,'interpreter':interpreter,'reviewed_scopes':scopes}}
     obj('resource.json',audit); pins['audit_resource_sha256']=sha(pathlib.Path(resource).read_bytes()); guard=put('guard.py',guard_raw())
     receipt={'version':1,'kind':'OWNED_ISSUER_SHUTDOWN','run_id':operation['run_id'],'owner_nonce':operation['nonce'],'original_envelope_sha256':operation['envelope_sha256'],'reservation_key':operation['reservation_key'],'reservation_generation':22,'issuer':runtime,'operation':operation,'guard_sha256':sha(pathlib.Path(guard).read_bytes()),'guard_core_sha256':core,'protected_before_sha256':sha(encode(snapshot)),'protected_after_sha256':sha(encode(snapshot)),'protected_before_path':before,'protected_after_path':after,'original_pinned_protected_path':original,'original_pinned_protected_sha256':pins['protected_sha256'],'old_schema_path':schema,'old_schema_file_sha256':pins['schema_sha256'],'protected_row_counts':{'access':0},'repair_row_counts':{},'old_schema_sha256':sha(encode({'fixture':'schema41'})),'new_schema_sha256':'b'*64,'schema_delta_sha256':'a'*64,'shutdown_observation':{'argv':['/bin/ps','-p',str(runtime['pid']),'-o','pid='],'returncode':1,'stdout':'','stderr':''}}
     receipt['migration_window']={'startup_started_at':'2026-10-15T01:00:00.000000Z','migration_applied_at':'2026-10-15T01:00:01.000000Z','schema_observed_at':'2026-10-15T01:00:02.000000Z'}
     new_schema={'objects':[original_trigger,addition],'migrations':old_schema['migrations']+[{'version':42,'applied_at':receipt['migration_window']['migration_applied_at']}]}
     receipt['schema_delta_sha256']=pins['schema_delta_sha256']
     receipt['new_schema_path']=obj('new-schema.json',new_schema);receipt['new_schema_sha256']=sha(encode(new_schema));receipt['old_schema_sha256']=sha(encode(old_schema))
     receipt_path=obj('receipt.json',receipt)
     packet={'resource_path':resource,'resource_sha256':pins['audit_resource_sha256'],'receipt_path':receipt_path,'receipt_sha256':sha(pathlib.Path(receipt_path).read_bytes()),'guard_path':guard,'current_build_path':artifact,'current_io_sha256':sha(b'fixture-current-io')}
     result=module.verify(packet); assert result['kind']=='INPUT_NOT_ISSUED' and result['snapshot']==snapshot
     for key,value in [('current_build_path',root),('current_io_sha256','0'*64)]:
      changed=dict(packet);changed[key]=value
      try:module.verify(changed)
      except ValueError:pass
      else:raise AssertionError('foreign current artifact accepted')
     def deny(change):
      try:change();module.verify(packet)
      except (ValueError,OSError):return
      raise AssertionError('mutation accepted')
     original_guard=pathlib.Path(guard).read_bytes()
     deny(lambda:put('guard.py',original_guard+b'print("extension")\n'));put('guard.py',original_guard)
     deny(lambda:put('archive/lib/symphony_elixir/factory/ticket_push.ex',b'changed'));put('archive/lib/symphony_elixir/factory/ticket_push.ex',b'fixture-original-source')
     deny(lambda:put('after.json',b'{}'));obj('after.json',snapshot)
     os.unlink(after);os.symlink(before,after);deny(lambda:None);os.unlink(after);obj('after.json',snapshot)
     changed=dict(receipt);changed['unexpected']='rejected';obj('receipt.json',changed);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes());deny(lambda:None)
     changed=dict(receipt);changed['migration_window']=dict(receipt['migration_window'],migration_applied_at='2026-10-15T01:00:03.000000Z');obj('receipt.json',changed);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes());deny(lambda:None)
     changed=dict(receipt);changed['migration_window']=dict(receipt['migration_window'],schema_observed_at='2026-10-15T01:01:31.000000Z');obj('receipt.json',changed);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes());deny(lambda:None)
     changed_schema=json.loads(encode(new_schema));changed_schema['migrations'][0]['applied_at']='changed-old-row';obj('new-schema.json',changed_schema)
     changed=dict(receipt);changed['new_schema_sha256']=sha(encode(changed_schema));obj('receipt.json',changed);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes());deny(lambda:None)
     changed_schema=json.loads(encode(new_schema));changed_schema['migrations'][-1]['applied_at']='2026-10-15T01:00:01.999999Z';obj('new-schema.json',changed_schema)
     changed=dict(receipt);changed['new_schema_sha256']=sha(encode(changed_schema));obj('receipt.json',changed);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes());deny(lambda:None)
     changed_schema=json.loads(encode(new_schema));changed_schema['objects'][0]['sql']='replaced original trigger';obj('new-schema.json',changed_schema)
     changed=dict(receipt);changed['new_schema_sha256']=sha(encode(changed_schema));obj('receipt.json',changed);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes());deny(lambda:None)
     changed_schema=json.loads(encode(new_schema));changed_schema['objects'].append({'type':'trigger','name':'extra','tbl_name':'runs','sql':'extra SQL'});obj('new-schema.json',changed_schema)
     changed=dict(receipt);changed['new_schema_sha256']=sha(encode(changed_schema));obj('receipt.json',changed);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes());deny(lambda:None)
     obj('new-schema.json',new_schema)
     obj('receipt.json',receipt);packet['receipt_sha256']=sha(pathlib.Path(receipt_path).read_bytes())
     raw=encode(packet);completed=subprocess.run(['/usr/bin/python3','-I','-S','-B',helper],input=struct.pack('>I',len(raw))+raw,capture_output=True,timeout=8)
     assert completed.returncode==0,completed.stderr
     assert json.loads(completed.stdout[4:])['kind']=='INPUT_NOT_ISSUED'
     owned=subprocess.Popen(['/usr/bin/python3','-I','-S','-B',helper],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
     try:
      owned.stdin.write(struct.pack('>I',len(raw))+raw);owned.stdin.flush()
      assert select.select([owned.stdout],[],[],3)[0], 'open-stdin framing blocked'
      length=struct.unpack('>I',owned.stdout.read(4))[0];assert json.loads(owned.stdout.read(length))['kind']=='INPUT_NOT_ISSUED'
      assert owned.wait(timeout=3)==0
     finally:
      if owned.poll() is None:owned.kill();owned.wait(timeout=3)
     bad=subprocess.run(['/usr/bin/python3','-I','-S','-B',helper],input=struct.pack('>I',65537),capture_output=True,timeout=8);assert bad.returncode!=0
     print('input-fence actual-reader/AST/null-frame fixtures PASS')
    '''

    assert {output, 0} = System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, helper], stderr_to_stdout: true)
    assert output =~ "fixtures PASS"
  end
end
