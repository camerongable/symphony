defmodule SymphonyElixir.FactoryPushReassessmentBoundaryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.{CiRepairReassessment, TicketCiRepair}

  for version <- ["bounded_pages_v2", CiRepairReassessment.envelope_version()] do
    @version version
    test "physical push admission validates exact immutable reassessment #{@version}" do
      hash = fn raw -> :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) end
      run = %{"run_id" => "run", "candidate_sha" => String.duplicate("a", 40), "ci_pipeline_id" => 99}
      preimage = Jason.encode!(%{"run" => run, "unicode" => "λ😀\u2028\u2029\n\t\r\u0001e\u0301/\\\""})

      versions = TicketCiRepair.evidence_versions()

      diagnosis_body = %{
        "status" => "REPAIRABLE",
        "allowed_writer_paths" => ["test.go"],
        "required_generated_paths" => []
      }

      diagnosis = Jason.encode!(if String.starts_with?(@version, "evidence-pair-v1:"), do: Map.put(diagnosis_body, "evidence_versions", versions), else: diagnosis_body)
      revision_preimage = if String.starts_with?(@version, "evidence-pair-v1:"), do: Jason.decode!(preimage) |> Map.put("evidence_versions", versions) |> Jason.encode!(), else: preimage

      blocked = Jason.encode!(%{"status" => "BLOCKED", "reason" => "CI_TRACE_FRAMING_UNPROVEN"})

      original = %{
        "diagnosis_key" => "original",
        "run_id" => "run",
        "candidate_sha" => run["candidate_sha"],
        "pipeline_id" => 99,
        "preimage_json" => preimage,
        "preimage_sha256" => hash.(preimage),
        "diagnosis_json" => blocked,
        "diagnosis_sha256" => hash.(blocked),
        "verdict" => "BLOCKED",
        "created_at" => "2026-10-15T00:00:00.000000Z"
      }

      key = "ci-reassessment:" <> hash.(Jason.encode!(["original", @version]))

      revision =
        original
        |> Map.merge(%{
          "reassessment_key" => key,
          "collector_version" => @version,
          "preimage_json" => revision_preimage,
          "preimage_sha256" => hash.(revision_preimage),
          "original_sha256" => hash.(Jason.encode!(original)),
          "diagnosis_json" => diagnosis,
          "diagnosis_sha256" => hash.(diagnosis),
          "verdict" => "REPAIRABLE",
          "kind" => "COLLECTOR_REASSESSMENT_V1"
        })

      claim = %{
        "diagnosis_key" => "original",
        "claim_json" =>
          Jason.encode!(%{
            "reassessment_key" => key,
            "reassessment_sha256" => hash.(Jason.encode!(revision)),
            "allowed_writer_paths" => ["test.go"],
            "required_generated_paths" => []
          })
      }

      packet = Jason.encode!(%{"original" => original, "revision" => revision, "claim" => claim})

      script = ~S"""
      import copy, importlib.util, json, sqlite3, sys, types
      helper=types.ModuleType('helper'); helper.__file__=sys.argv[1]
      exec(compile(open(sys.argv[1]).read(),sys.argv[1],'exec'),helper.__dict__)
      data=json.loads(sys.argv[2]); c=sqlite3.connect(':memory:'); c.row_factory=sqlite3.Row
      for name,key in [('ticket_ci_repair_diagnoses','original'),('ticket_ci_repair_reassessments','revision')]:
        row=data[key]
        c.execute('CREATE TABLE '+name+' ('+','.join(k+(' INTEGER' if type(v) is int else ' TEXT') for k,v in row.items())+')')
        c.execute('INSERT INTO '+name+' VALUES ('+','.join('?' for _ in row)+')',list(row.values()))
      assert helper.claimed_diagnosis(c,data['claim'])['status']=='REPAIRABLE'
      for value in (None, True, 1.5, [], {}):
        try: helper.row_digest({'unexpected':value}); assert value is None
        except ValueError as error: assert value is not None and str(error)=='ci_repair_diagnosis_changed'
      for field,value in [('reassessment_key','foreign'),('reassessment_sha256','0'*64),('allowed_writer_paths',['foreign.go']),('required_generated_paths',['BUILD'])]:
        claim=copy.deepcopy(data['claim']); body=json.loads(claim['claim_json']); body[field]=value; claim['claim_json']=json.dumps(body)
        try: helper.claimed_diagnosis(c,claim); raise AssertionError('accepted changed claim')
        except ValueError as error: assert str(error)=='ci_repair_diagnosis_changed'
      for field,value in [('verdict','BLOCKED'),('candidate_sha','b'*40),('original_sha256','0'*64),('diagnosis_json','null'),('preimage_json','[]')]:
        before=c.execute('SELECT '+field+' FROM ticket_ci_repair_reassessments').fetchone()[0]
        c.execute('UPDATE ticket_ci_repair_reassessments SET '+field+'=?',(value,))
        try: helper.claimed_diagnosis(c,data['claim']); raise AssertionError('accepted changed row')
        except ValueError as error: assert str(error)=='ci_repair_diagnosis_changed'
        c.execute('UPDATE ticket_ci_repair_reassessments SET '+field+'=?',(before,))
      legacy={'diagnosis_key':'original','claim_json':'{}'}
      try: helper.claimed_diagnosis(c,legacy); raise AssertionError('accepted original blocked')
      except ValueError as error: assert str(error)=='ci_repair_diagnosis_changed'
      raw=data['revision']['diagnosis_json']
      c.execute('UPDATE ticket_ci_repair_diagnoses SET verdict=?,diagnosis_json=?,diagnosis_sha256=?',('REPAIRABLE',raw,helper.sha(raw.encode())))
      assert helper.claimed_diagnosis(c,legacy)['status']=='REPAIRABLE'
      print('exact_revision_and_unicode_hash_parity=PASS; changed_evidence_denied=10; legacy_repairable=PASS')
      """

      helper = Path.expand("../../priv/ticket_push_executor_v4.py", __DIR__)

      assert {"exact_revision_and_unicode_hash_parity=PASS; changed_evidence_denied=10; legacy_repairable=PASS\n", 0} =
               System.cmd(System.find_executable("python3"), ["-c", script, helper, packet], stderr_to_stdout: true)
    end
  end
end
