defmodule SymphonyElixir.FactoryCiBudgetResumeTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketCiBudgetResume}

  test "an unchanged inherited exhaustion marker preserves the original exact-preimage path" do
    {ctx, diagnosis, _run} = fixture("old-five", 7)
    original = Jason.decode!(diagnosis["preimage_json"])["run"]
    assert {:ok, nil} = TicketCiBudgetResume.prepare(ctx.store, diagnosis, original, 10)
    assert {:ok, nil} = TicketCiBudgetResume.prepare(ctx.store, diagnosis, original, 7)
    assert {:error, _} = TicketCiBudgetResume.prepare(ctx.store, diagnosis, Map.put(original, "last_error", "unrelated changed marker"), 10)
    assert Store.one!(ctx.store, "SELECT count(*) AS n FROM ticket_ci_repair_claims")["n"] == 7
  end

  test "historical hard-seven exhaustion resumes only through exact two-event evidence" do
    for original <- [nil, "old-five"] do
      for hard <- [7, 10] do
        {ctx, diagnosis, run} = fixture(original, hard)
        before = Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows
        assert {:ok, proof} = TicketCiBudgetResume.prepare(ctx.store, diagnosis, run, 10)
        assert proof["attempts_before"] == 7 and proof["effective_limit"] == 10
        assert proof["historical_hard_limit"] == hard
        assert is_nil(proof["prior_exhaustion_event"]) == is_nil(original)
        assert Store.query!(ctx.store, "SELECT rowid,* FROM ticket_ci_repair_claims ORDER BY rowid").rows == before
        assert {:error, _} = TicketCiBudgetResume.prepare(ctx.store, diagnosis, run, 7)

        mutations = [
          Map.put(run, "candidate_sha", String.duplicate("f", 40)),
          Map.update!(run, "spec_revision", &(&1 + 1)),
          Map.put(run, "failure_code", "OTHER_FAILURE"),
          Map.put(run, "last_error", String.replace(run["last_error"], "7 total cycles", "8 total cycles")),
          Map.put(run, "last_error", String.replace(run["last_error"], "configured limit 7", "configured limit 8")),
          Map.put(run, "last_error", String.replace(run["last_error"], "pipeline 277", "pipeline 278")),
          Map.put(run, "last_error", String.replace(run["last_error"], "assessment resume", "assessment substituted")),
          Map.put(run, "last_error", run["last_error"] <> " changed")
        ]

        for changed <- mutations, do: assert(match?({:error, _}, TicketCiBudgetResume.prepare(ctx.store, diagnosis, changed, 10)))
        changed = put_in(Jason.decode!(diagnosis["preimage_json"]), ["run", "failure_code"], "UNRELATED_FAILURE") |> Jason.encode!()
        assert {:error, _} = TicketCiBudgetResume.prepare(ctx.store, Map.merge(diagnosis, %{"preimage_json" => changed, "preimage_sha256" => sha(changed)}), run, 10)
        stop_supervised!(Store)
      end
    end
  end

  test "consumed resumption remains authenticated after clear and later failure events" do
    {ctx, diagnosis, run} = fixture("old-five", 7)
    assert {:ok, base} = TicketCiBudgetResume.prepare(ctx.store, diagnosis, run, 10)
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    proof = Map.put(base, "admitted_at", at)
    claim = %{"kind" => "TICKET_CI_REPAIR", "claim_key" => "resumed", "diagnosis_key" => "resume", "prior_run" => run, "round" => 8, "budget_resume" => proof}
    raw = Jason.encode!(claim)
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES ('resumed','resume','run',8,?,?,?)", [raw, sha(raw), at])
    assert :ok = TicketCiBudgetResume.validate_claim(ctx.store, claim)
    {:ok, _} = RunLedger.update(ctx.store, "run", %{failure_code: nil, last_error: nil})
    {:ok, _} = RunLedger.update(ctx.store, "run", %{failure_code: "CI_REPAIR_EXHAUSTED", last_error: "A different later failure"})
    assert :ok = TicketCiBudgetResume.validate_claim(ctx.store, claim)
    assert {:error, _} = TicketCiBudgetResume.validate_claim(ctx.store, put_in(claim, ["budget_resume", "admitted_at"], "2100-01-01T00:00:00Z"))
    assert {:error, _} = TicketCiBudgetResume.validate_claim(ctx.store, put_in(claim, ["budget_resume", "exhaustion_event_payload_sha256"], String.duplicate("f", 64)))
    assert_physical_resume(ctx, claim)
  end

  defp assert_physical_resume(ctx, claim) do
    payload = Path.join(ctx.root, "budget-resume.json")
    raw = Jason.encode!(claim)
    File.write!(payload, raw)

    script = ~S'''
    import copy,hashlib,importlib.util,json,sqlite3,sys
    spec=importlib.util.spec_from_file_location('physical',sys.argv[3]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    source=sqlite3.connect('file:'+sys.argv[2]+'?mode=ro',uri=True); source.row_factory=sqlite3.Row
    saved=json.load(open(sys.argv[1])); claim=dict(source.execute("SELECT * FROM ticket_ci_repair_claims WHERE claim_key='resumed'").fetchone())
    original=dict(source.execute("SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key='resume'").fetchone())
    module.validate_budget_resume(source,claim,saved,original)
    cases=[]
    for field,value in (('attempts_before',8),('configured_limit',7),('effective_limit',7),('historical_hard_limit',10),('exhaustion_event_id',1),('exhaustion_event_payload_sha256','f'*64),('prior_exhaustion_event',None)):
        changed=copy.deepcopy(saved); changed['budget_resume'][field]=value; cases.append((field,changed,copy.deepcopy(claim)))
    for at in ('2100-01-01T00:00:00Z',original['created_at']):
        changed=copy.deepcopy(saved); changed['budget_resume']['admitted_at']=at; record=copy.deepcopy(claim); record['created_at']=at; cases.append(('coherent cutoff',changed,record))
    for name,changed,record in cases:
        encoded=json.dumps(changed,separators=(',',':')); record['claim_json']=encoded; record['claim_sha256']=hashlib.sha256(encoded.encode()).hexdigest()
        try: module.validate_budget_resume(source,record,changed,original)
        except (ValueError,KeyError,TypeError): pass
        else: raise AssertionError('physical budget corruption accepted: '+name)
    missing=copy.deepcopy(saved); del missing['budget_resume']; record=copy.deepcopy(claim); record['claim_json']=json.dumps(missing,separators=(',',':')); record['claim_sha256']=hashlib.sha256(record['claim_json'].encode()).hexdigest()
    try: module.claimed_diagnosis_v4(source,record)
    except (ValueError,KeyError,TypeError): pass
    else: raise AssertionError('stripped resumption proof accepted')
    assert source.total_changes==0
    print('physical historical resumption PASS; nine coherent proof/cutoff mutations and removed proof refused; zero writes')
    '''

    assert {output, 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, payload, ctx.database, Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v8.py")],
               stderr_to_stdout: true
             )

    assert output =~ "nine coherent"
    assert File.read!(payload) == raw
  end

  defp fixture(original, hard) do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})

    for round <- 1..7 do
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES (?,?,?,?,'{}','preimage','{}','diagnosis','REPAIRABLE','now')", ["old-#{round}", "run", "candidate-#{round}", round])
      Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_claims VALUES (?,?,?,?,'{}','claim','now')", ["old-#{round}", "old-#{round}", "run", round])
    end

    old =
      "CI repair budget exhausted: 5 total attempts used; configured limit 5 (hard maximum 5). Repair round 4, failed pipeline 99, stopped request desktop:old. No new writer, push, or retry was issued."

    {:ok, %{run: initial}} = RunLedger.update(ctx.store, "run", %{state: "CI_WAITING", code_repair_round: 7, ci_pipeline_id: 277})

    prior =
      if original do
        {:ok, %{run: updated}} = RunLedger.update(ctx.store, "run", %{failure_code: "CI_REPAIR_EXHAUSTED", last_error: old})
        updated
      else
        initial
      end

    raw = Jason.encode!(%{"run" => prior})
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    Store.query!(ctx.store, "INSERT INTO ticket_ci_repair_diagnoses VALUES ('resume','run',?,277,?,?,?,?,'REPAIRABLE',?)", [prior["candidate_sha"], raw, sha(raw), "{}", sha("{}"), at])

    message =
      "CI repair budget exhausted: 7 total cycles used; configured limit 7 (hard maximum #{hard}). Current failed pipeline 277; assessment resume. Human investigation or a new authorized policy decision is required; no new writer or retry was issued."

    {:ok, %{run: run}} = RunLedger.update(ctx.store, "run", %{failure_code: "CI_REPAIR_EXHAUSTED", last_error: message})
    {ctx, Store.one!(ctx.store, "SELECT * FROM ticket_ci_repair_diagnoses WHERE diagnosis_key='resume'"), run}
  end

  defp sha(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
