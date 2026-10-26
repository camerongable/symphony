defmodule SymphonyElixir.FactoryPushPayloadBudgetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Factory.TicketPushPayloadBudget

  test "ordinary generation accounts for its reviewed push after local source commits advance" do
    prior = completed_run()
    current = Map.put(prior, "candidate_sha", String.duplicate("d", 40))

    proof = %{
      "version" => 1,
      "kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1",
      "reviewed_candidate_sha" => prior["candidate_sha"],
      "source_parent_sha" => current["candidate_sha"],
      "candidate_sha" => current["candidate_sha"]
    }

    journal = %{"version" => 1, "kind" => "CONTROLLER_ORDINARY_GENERATION", "operation" => "GOFMT_DIFF", "ordinary_verifier_repair" => proof, "run_preimage" => current}
    raw = Jason.encode!(journal)
    assert match?({:ok, _}, TicketPushPayloadBudget.object(raw, :ordinary_generation))
    assert match?({:ok, _}, TicketPushPayloadBudget.object(Jason.encode!(put_in(journal, ["ordinary_verifier_repair", "version"], 2)), :ordinary_generation))
    refute TicketPushPayloadBudget.bounded?(Map.delete(journal, "ordinary_verifier_repair"), :ordinary_generation)
    refute TicketPushPayloadBudget.bounded?(%{"run" => current}, :preimage)

    for changed <- [
          put_in(journal, ["ordinary_verifier_repair", "reviewed_candidate_sha"], String.duplicate("f", 40)),
          put_in(journal, ["ordinary_verifier_repair", "source_parent_sha"], String.duplicate("e", 40)),
          put_in(journal, ["ordinary_verifier_repair", "candidate_sha"], String.duplicate("e", 40)),
          put_in(journal, ["ordinary_verifier_repair", "version"], true)
        ] do
      refute TicketPushPayloadBudget.bounded?(changed, :ordinary_generation)
    end

    path = Path.join(System.tmp_dir!(), "advanced-generation-budget-#{System.unique_integer([:positive])}.json")
    File.write!(path, raw)
    on_exit(fn -> File.rm!(path) end)

    script = ~S'''
    import copy,importlib.util,json,pathlib,sys
    path=pathlib.Path(sys.argv[1]); spec=importlib.util.spec_from_file_location('history',path); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    raw=pathlib.Path(sys.argv[2]).read_text(); value=m.push_budget_decode(raw,'ordinary_generation')
    assert value==json.loads(raw)
    for kind,changed in (('ordinary_generation',{k:v for k,v in value.items() if k!='ordinary_verifier_repair'}),('preimage',dict(run=value['run_preimage']))):
        try:m.push_budget_decode(m.canonical(changed).decode(),kind)
        except (ValueError,KeyError,TypeError):continue
        raise AssertionError('candidate mismatch accepted outside the typed ordinary proof')
    for key,replacement in (('reviewed_candidate_sha','f'*40),('source_parent_sha','e'*40),('candidate_sha','e'*40),('version',True)):
        changed=copy.deepcopy(value);changed['ordinary_verifier_repair'][key]=replacement
        try:m.push_budget_decode(m.canonical(changed).decode(),'ordinary_generation')
        except (ValueError,KeyError,TypeError):continue
        raise AssertionError('unbound predecessor candidate accepted')
    assert pathlib.Path(sys.argv[2]).read_text()==raw
    print('advanced-generation-budget-PASS')
    '''

    assert {"advanced-generation-budget-PASS\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v16.py"), path], stderr_to_stdout: true)
  end

  test "ordinary generation journals retain complete bounded historical push evidence" do
    run = completed_run()
    journal = %{"version" => 1, "kind" => "CONTROLLER_ORDINARY_GENERATION", "operation" => "GOFMT_DIFF", "ordinary_verifier_repair" => ordinary_proof(run), "run_preimage" => run}
    raw = Jason.encode!(journal)
    assert byte_size(raw) > 2_097_152
    assert {:ok, ^journal} = TicketPushPayloadBudget.object(raw, :ordinary_generation)
    refute TicketPushPayloadBudget.bounded?(Map.put(journal, "extra", String.duplicate("x", 2_097_152)), :ordinary_generation)
    refute TicketPushPayloadBudget.bounded?(Map.put(journal, "elsewhere", run), :ordinary_generation)
    refute TicketPushPayloadBudget.bounded?(Map.put(journal, "kind", "UNRECOGNIZED"), :ordinary_generation)

    envelope = Jason.decode!(run["candidate_handoff"])
    uncompleted = put_in(journal, ["run_preimage", "candidate_handoff"], Jason.encode!(Map.put(envelope, "phase", "PUSH_UNCERTAIN")))
    refute TicketPushPayloadBudget.bounded?(uncompleted, :ordinary_generation)
  end

  test "physical ordinary generation decoder keeps exact bytes and bounded non-push remainder" do
    run = completed_run()
    journal = %{"version" => 1, "kind" => "CONTROLLER_ORDINARY_GENERATION", "operation" => "GOFMT_DIFF", "ordinary_verifier_repair" => ordinary_proof(run), "run_preimage" => run}
    raw = Jason.encode!(journal)
    path = Path.join(System.tmp_dir!(), "ordinary-generation-budget-#{System.unique_integer([:positive])}.json")
    File.write!(path, raw)
    on_exit(fn -> File.rm!(path) end)

    script = ~S'''
    import copy,importlib.util,json,pathlib,sys
    spec=importlib.util.spec_from_file_location('history',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    raw=pathlib.Path(sys.argv[2]).read_text(); before=module.sha(raw.encode())
    value=module.push_budget_decode(raw,'ordinary_generation')
    assert value==json.loads(raw) and module.sha(raw.encode())==before
    for operation in ('GOFMT_DIFF','GAZELLE_DIFF'):
        module.push_budget_decode(module.canonical(dict(value,operation=operation)).decode(),'ordinary_generation')
    projected,_=module.push_size_project(value,'ordinary_generation')
    exact=dict(value,padding='x'*(2097152-len(module.canonical(dict(projected,padding='')))))
    module.push_budget_decode(module.canonical(exact).decode(),'ordinary_generation')
    cases=[dict(exact,padding=exact['padding']+'x'),dict(value,elsewhere=value['run_preimage']),dict(value,version=True),dict(value,kind='UNRECOGNIZED'),dict(value,operation='WRITE')]
    for field,replacement in (('phase','PUSH_UNCERTAIN'),('remote_sha','f'*40),('receipt_sha256','0'*64)):
        changed=copy.deepcopy(value); envelope=json.loads(changed['run_preimage']['candidate_handoff']); envelope[field]=replacement
        changed['run_preimage']['candidate_handoff']=module.canonical(envelope).decode(); cases.append(changed)
    for changed in cases:
        try: module.push_budget_decode(module.canonical(changed).decode(),'ordinary_generation')
        except (ValueError,KeyError,TypeError): pass
        else: raise AssertionError('unqualified ordinary-generation payload accepted')
    ceiling=2097152+2*12582912
    module.push_budget_decode(raw+' '*(ceiling-len(raw.encode())),'ordinary_generation')
    try: module.push_budget_decode(raw+' '*(ceiling-len(raw.encode())+1),'ordinary_generation')
    except ValueError: pass
    else: raise AssertionError('first excess absolute byte accepted')
    assert pathlib.Path(sys.argv[2]).read_text()==raw
    print('ordinary-generation-budget-PASS')
    '''

    assert {"ordinary-generation-budget-PASS\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v16.py"), path], stderr_to_stdout: true)
  end

  test "completed external v18 history remains admissible after the publishing release moves" do
    path = Path.join(System.tmp_dir!(), "external-v18-history-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(completed_run()))
    on_exit(fn -> File.rm!(path) end)

    script = ~S'''
    import copy,importlib.util,json,pathlib,sys
    local=pathlib.Path(sys.argv[1]).resolve(strict=True)
    spec=importlib.util.spec_from_file_location('history',local/'ticket_push_history_validator_v16.py'); module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    original=pathlib.Path(sys.argv[2]).read_bytes(); run=json.loads(original); intent=json.loads(run['candidate_handoff'])
    entry=next(e for e in json.loads((local/'ticket_push_readback_origins_v12.json').read_bytes())['entries'] if e['helper_path'].endswith('/ticket_push_executor_v18.py'))
    assert pathlib.Path(entry['helper_path']).parent!=local
    execution=json.loads(intent['execution_json']); execution.update({k:entry[k] for k in ('helper_path','helper_sha256','companion_path','companion_sha256')})
    execution['history_program_path']=str(pathlib.Path(entry['helper_path']).with_name('ticket_push_history_validator_v15.py'))
    execution['history_program_sha256']=module.sha(pathlib.Path(execution['history_program_path']).read_bytes())
    module.push_program_origin(execution,local)
    intent['execution_json']=module.canonical(execution).decode()
    receipt=json.loads(intent['receipt_json']);receipt['execution_json']=intent['execution_json']
    intent['receipt_json']=module.canonical(receipt).decode().replace(chr(127),'\\u007f');intent['receipt_sha256']=module.sha(intent['receipt_json'].encode())
    run['candidate_handoff']=module.canonical(intent).decode();module.push_completed_marker(run['candidate_handoff'],run)
    proof=dict(version=1,kind='ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1',reviewed_candidate_sha=run['candidate_sha'],source_parent_sha=run['candidate_sha'],candidate_sha=run['candidate_sha'])
    journal=module.canonical(dict(version=1,kind='CONTROLLER_ORDINARY_GENERATION',operation='GAZELLE_DIFF',ordinary_verifier_repair=proof,run_preimage=run)).decode()
    assert len(journal.encode())>2097152 and module.push_budget_decode(journal,'ordinary_generation')['run_preimage']==run
    for key in ('helper_sha256','companion_sha256','history_program_sha256'):
        wrong=dict(execution,**{key:'0'*64})
        try:module.push_program_origin(wrong,local)
        except (ValueError,KeyError,TypeError):continue
        raise AssertionError('mutated external provenance accepted')
    sibling=dict(execution,helper_path=str(local.parent/'unregistered'/pathlib.Path(execution['helper_path']).name))
    try:module.push_program_origin(sibling,local)
    except (ValueError,KeyError,TypeError):pass
    else:raise AssertionError('unregistered sibling accepted')
    assert pathlib.Path(sys.argv[2]).read_bytes()==original
    print('external-v18-history-PASS-no-helper-execution')
    '''

    assert {"external-v18-history-PASS-no-helper-execution\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv"), path], stderr_to_stdout: true)
  end

  test "legacy and unqualified JSON retains the original two MiB remainder" do
    for kind <- [:preimage, :claim, :successor, :import, :diagnosis_row, :ordinary_generation] do
      assert TicketPushPayloadBudget.bounded?(%{"extra" => String.duplicate("x", 2_097_140)}, kind)
      refute TicketPushPayloadBudget.bounded?(%{"extra" => String.duplicate("x", 2_097_141)}, kind)
      refute TicketPushPayloadBudget.bounded?(%{"candidate_handoff" => String.duplicate("x", 3_000_000)}, kind)
      assert {:error, :push_payload_budget_exceeded} = TicketPushPayloadBudget.object(String.duplicate(" ", 2_097_152) <> "{}", kind)
    end
  end

  test "physical V9 accounting agrees and never hashes the projected bytes" do
    run = completed_run()
    raw_claim = Jason.encode!(%{"prior_run" => run})
    claim = %{"claim_json" => raw_claim, "claim_sha256" => digest(raw_claim)}

    objects = %{
      "preimage" => %{"run" => run},
      "claim" => Jason.decode!(raw_claim),
      "successor" => %{"run" => run, "claim" => claim},
      "import" => %{"prior_run" => run}
    }

    preimage = Jason.encode!(objects["preimage"])
    objects = Map.put(objects, "diagnosis_row", %{"preimage_json" => preimage, "preimage_sha256" => digest(preimage)})
    payload = Map.new(objects, fn {kind, object} -> {kind, Jason.encode!(object)} end)
    path = Path.join(System.tmp_dir!(), "push-budget-parity-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(payload))
    on_exit(fn -> File.rm!(path) end)

    script = """
    import importlib.util,json,pathlib,sys
    path=pathlib.Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('history',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    cases=json.loads(pathlib.Path(sys.argv[2]).read_text())
    for kind,raw in cases.items():
        before=module.sha(raw.encode());decoded=module.push_budget_decode(raw,kind)
        assert decoded==json.loads(raw) and module.sha(raw.encode())==before
        projected,_=module.push_size_project(decoded,kind)
        remainder=len(module.canonical(dict(projected,padding='')))
        exact=dict(decoded,padding='x'*(2097152-remainder))
        module.push_budget_decode(module.canonical(exact).decode(),kind)
        try:module.push_budget_decode(module.canonical(dict(exact,padding=exact['padding']+'x')).decode(),kind)
        except ValueError:pass
        else:raise AssertionError('one excess remainder byte accepted')
        ceiling=module.push_absolute_limit(kind)
        module.push_budget_decode(raw+' '*(ceiling-len(raw.encode())),kind)
        try:module.push_budget_decode(raw+' '*(ceiling-len(raw.encode())+1),kind)
        except ValueError:pass
        else:raise AssertionError('one excess absolute byte accepted')
        changed=dict(decoded,extra='x'*2097152)
        try:module.push_budget_decode(module.canonical(changed).decode(),kind)
        except ValueError:pass
        else:raise AssertionError('unqualified remainder accepted')
    print('fixed-path-parity-5-PASS')
    """

    assert {"fixed-path-parity-5-PASS\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v9.py"), path], stderr_to_stdout: true)
  end

  test "only exact completed v12 copies at the fixed paths receive a size marker" do
    run = completed_run()
    preimage = %{"run" => run, "ci_snapshots" => %{}}
    raw = Jason.encode!(preimage)
    claim = %{"kind" => "TICKET_CI_REPAIR", "prior_run" => run}
    claim_raw = Jason.encode!(claim)
    row = %{"claim_json" => claim_raw, "claim_sha256" => digest(claim_raw)}
    successor = %{"run" => run, "claim" => row}
    assert byte_size(raw) > 2_097_152
    assert TicketPushPayloadBudget.bounded?(preimage, :preimage)
    assert TicketPushPayloadBudget.bounded?(claim, :claim)
    assert TicketPushPayloadBudget.bounded?(successor, :successor)
    assert TicketPushPayloadBudget.bounded?(%{"prior_run" => run}, :import)
    assert TicketPushPayloadBudget.bounded?(%{"preimage_json" => raw, "preimage_sha256" => digest(raw)}, :diagnosis_row)
    assert {:ok, ^preimage} = TicketPushPayloadBudget.object(raw, :preimage)
    assert Jason.encode!(preimage) == raw

    refute TicketPushPayloadBudget.bounded?(%{"elsewhere" => run}, :preimage)
    refute TicketPushPayloadBudget.bounded?(%{"run" => run, "extra" => String.duplicate("x", 2_097_152)}, :preimage)
    refute TicketPushPayloadBudget.bounded?(Map.put(successor, "inputs", [%{"candidate_handoff" => run["candidate_handoff"]}]), :successor)
    refute TicketPushPayloadBudget.bounded?(put_in(successor, ["claim", "claim_sha256"], String.duplicate("0", 64)), :successor)
    changed = Map.put(run, "candidate_handoff", String.replace(run["candidate_handoff"], "GIT_EXIT_ZERO", "GIT_EXIT_NONZERO"))
    refute TicketPushPayloadBudget.bounded?(%{"run" => changed, "claim" => row}, :successor)
  end

  test "malformed completion bindings never exempt large payloads" do
    run = completed_run()
    envelope = Jason.decode!(run["candidate_handoff"])

    for changed <- [
          Map.put(envelope, "phase", "PUSH_UNCERTAIN"),
          Map.put(envelope, "remote_sha", String.duplicate("f", 40)),
          Map.put(envelope, "receipt_sha256", String.duplicate("0", 64)),
          Map.put(envelope, "binding_sha256", String.duplicate("0", 64)),
          Map.put(envelope, "extra", true),
          Map.put(envelope, "reservation_generation", 0)
        ] do
      refute TicketPushPayloadBudget.bounded?(%{"run" => Map.put(run, "candidate_handoff", Jason.encode!(changed))}, :preimage)
    end

    execution = Jason.decode!(envelope["execution_json"])

    for {field, value} <- [
          {"helper_sha256", String.duplicate("0", 64)},
          {"history_program_sha256", String.duplicate("0", 64)},
          {"companion_sha256", String.duplicate("0", 64)},
          {"helper_path", "/unregistered/ticket_push_executor_v12.py"},
          {"history_program_path", "/unregistered/ticket_push_history_validator_v9.py"}
        ] do
      changed = execution |> Map.put(field, value) |> Jason.encode!()
      receipt = Jason.decode!(envelope["receipt_json"]) |> Map.put("execution_json", changed) |> Jason.encode!() |> String.replace(<<127>>, "\\u007f")
      coherent = Map.merge(envelope, %{"execution_json" => changed, "receipt_json" => receipt, "receipt_sha256" => digest(receipt)})
      refute TicketPushPayloadBudget.bounded?(%{"run" => Map.put(run, "candidate_handoff", Jason.encode!(coherent))}, :preimage)
    end
  end

  test "fixed-path projected remainder and absolute raw ceilings reject the first excess byte" do
    run = completed_run()
    raw_claim = Jason.encode!(%{"prior_run" => run})
    marker = %{"kind" => "COMPLETED_V12_PUSH_SIZE_V1", "sha256" => digest(run["candidate_handoff"]), "bytes" => byte_size(run["candidate_handoff"])}
    projected_run = Map.put(run, "candidate_handoff", marker)
    raw_preimage = Jason.encode!(%{"run" => run})

    cases = [
      {:preimage, %{"run" => run}, %{"run" => projected_run}, 2},
      {:claim, %{"prior_run" => run}, %{"prior_run" => projected_run}, 2},
      {:import, %{"prior_run" => run}, %{"prior_run" => projected_run}, 2},
      {:ordinary_generation, %{"version" => 1, "kind" => "CONTROLLER_ORDINARY_GENERATION", "operation" => "GOFMT_DIFF", "ordinary_verifier_repair" => ordinary_proof(run), "run_preimage" => run},
       %{"version" => 1, "kind" => "CONTROLLER_ORDINARY_GENERATION", "operation" => "GOFMT_DIFF", "ordinary_verifier_repair" => ordinary_proof(run), "run_preimage" => projected_run}, 2},
      {:successor, %{"run" => run, "claim" => %{"claim_json" => raw_claim, "claim_sha256" => digest(raw_claim)}},
       %{"run" => projected_run, "claim" => %{"claim_json" => Jason.encode!(%{"prior_run" => projected_run}), "claim_sha256" => digest(raw_claim)}}, 6},
      {:diagnosis_row, %{"preimage_json" => raw_preimage, "preimage_sha256" => digest(raw_preimage)},
       %{"preimage_json" => Jason.encode!(%{"run" => projected_run}), "preimage_sha256" => digest(raw_preimage)}, 4}
    ]

    for {kind, object, projected, multiplier} <- cases do
      remainder = byte_size(Jason.encode!(Map.put(projected, "padding", "")))
      exact = Map.put(object, "padding", String.duplicate("x", 2_097_152 - remainder))
      assert TicketPushPayloadBudget.bounded?(exact, kind), inspect(kind)
      refute TicketPushPayloadBudget.bounded?(Map.update!(exact, "padding", &(&1 <> "x")), kind)
      raw = Jason.encode!(object)
      ceiling = 2_097_152 + multiplier * 12_582_912
      at_ceiling = raw <> String.duplicate(" ", ceiling - byte_size(raw))
      assert {:ok, ^object} = TicketPushPayloadBudget.object(at_ceiling, kind)
      assert {:error, :push_payload_budget_exceeded} = TicketPushPayloadBudget.object(at_ceiling <> " ", kind)
    end
  end

  defp ordinary_proof(run),
    do: %{
      "version" => 1,
      "kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1",
      "reviewed_candidate_sha" => run["candidate_sha"],
      "source_parent_sha" => run["candidate_sha"],
      "candidate_sha" => run["candidate_sha"]
    }

  defp completed_run do
    {:ok, priv} = SymphonyElixir.PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv"))

    run =
      Map.new(~w(run_id issue_key repo_path worktree branch base_branch contract_sha256), &{&1, "/fixture/" <> &1}) |> Map.merge(%{"candidate_sha" => String.duplicate("a", 40), "spec_revision" => 1})

    binding = run |> Map.put("state", "CI_PUSHING") |> Jason.encode!()
    nonce = String.duplicate("b", 64)

    execution =
      %{
        "run_id" => run["run_id"],
        "intent_json" => binding,
        "intent_sha256" => digest(binding),
        "invocation" => nonce,
        "helper_path" => Path.join(priv, "ticket_push_executor_v12.py"),
        "helper_sha256" => file_digest(priv, "ticket_push_executor_v12.py"),
        "companion_path" => Path.join(priv, "worker_file_companion.py"),
        "companion_sha256" => file_digest(priv, "worker_file_companion.py"),
        "history_program_path" => Path.join(priv, "ticket_push_history_validator_v9.py"),
        "history_program_sha256" => file_digest(priv, "ticket_push_history_validator_v9.py"),
        "authorization" => String.duplicate(<<127>>, 550_000)
      }
      |> Jason.encode!()

    receipt =
      %{
        "version" => 1,
        "execution_json" => execution,
        "helper_pid" => 1,
        "child_pid" => 2,
        "termination" => %{"kind" => "exited", "code" => 0},
        "timed_out" => false,
        "overflow" => false,
        "output_base64" => "",
        "output_sha256" => digest(""),
        "stderr_code" => "GIT_EXIT_ZERO",
        "stderr_bytes" => 0,
        "stderr_sha256" => digest("")
      }
      |> Jason.encode!()
      |> String.replace(<<127>>, "\\u007f")

    envelope = %{
      "version" => 1,
      "kind" => "TICKET_PUSH",
      "phase" => "COMPLETED",
      "binding_json" => binding,
      "binding_sha256" => digest(binding),
      "reservation_key" => "ticket-push:" <> digest(binding),
      "reservation_generation" => 1,
      "owner_nonce" => nonce,
      "helper_pid" => 1,
      "execution_json" => execution,
      "receipt_json" => receipt,
      "receipt_sha256" => digest(receipt),
      "remote_sha" => run["candidate_sha"]
    }

    Map.put(run, "candidate_handoff", Jason.encode!(envelope))
  end

  defp file_digest(priv, name), do: priv |> Path.join(name) |> File.read!() |> digest()
  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
