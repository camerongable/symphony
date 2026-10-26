{:ok, _} = Application.ensure_all_started(:exqlite)
alias SymphonyElixir.Factory.{ReviewProtocol, RunLedger, Store, WorkerEvidence}

run_id = "ab5ab1fe-32cc-48c1-985e-3c3800adcfa2"
request = "desktop:11b288b43e59ae80afdfc26b01e1bcf2f2d297249cc54e8f0d0af98829629c5a"
digest = fn raw -> Base.encode16(:crypto.hash(:sha256, raw), case: :lower) end
{:ok, store} = Store.start_read_only(database: "/Users/cgable/Documents/Codex/factory-state/factory.sqlite")

try do
  {:ok, run} = RunLedger.get(store, run_id)
  true = run["state"] == "REPAIRING" and run["candidate_sha"] == "4e5c48fc2150515c4cb5ce0771f4c204b10c532c"
  true = run["verifier_round"] == 5 and run["code_repair_round"] == 13 and run["implementation_iteration"] == 26
  row = Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=? AND run_id=?", [request, run_id])
  true = row["turn_id"] == "01a1796f-4ffd-74e1-9bfe-9fdbf19e1e57" and row["status"] == "RESULT_RECORDED"
  true = WorkerEvidence.owner_stopped?(store, row)
  true = digest.(row["binding_json"]) == row["binding_sha256"] and row["binding_sha256"] == "35247f2f01ea7036912112facde8d3342ec6357889d8695b773bc08cb01d4f5f"
  true = digest.(row["output_json"]) == row["output_sha256"] and row["output_sha256"] == "42840686cdc6a2a99a4ea7a92910010892f56cbd88dfcecb689b763c026b6350"
  task = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]])
  {:ok, packet} = ReviewProtocol.context(store, task)
  true = packet["role"] == "feature-writer" and packet["review_protocol"]["version"] == 2
  true = packet["review_protocol"]["review_scope"]["mode"] == "FOCUSED"
  false = Map.has_key?(packet["review_protocol"]["review_scope"], "affected_paths")
  binding = Jason.decode!(row["binding_json"])
  output = Jason.decode!(row["output_json"])
  "COMPLETE" = output["status"]
  :ok = ReviewProtocol.validate_result(store, task, binding, output)
  {:ok, ^packet} = ReviewProtocol.context(store, task)
  true = Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [request]) == row
  true = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]]) == task
  {:ok, ^run} = RunLedger.get(store, run_id)
  [[54]] = Store.query!(store, "SELECT MAX(version) FROM factory_schema_migrations").rows
  [[0]] = Store.query!(store, "SELECT total_changes()").rows

  IO.puts(
    Jason.encode!(%{
      result: "PASS",
      request_key: request,
      binding_sha256: row["binding_sha256"],
      output_sha256: row["output_sha256"],
      context_sha256: digest.(Jason.encode!(packet)),
      original_report_status: output["status"],
      raw_worker_task_and_context_unchanged: true,
      run_unchanged: true,
      live_ledger_writes: 0,
      native_turns: 0,
      pushes: 0,
      limitation: "Authenticated read-only source-readiness validation only; no adoption, product acceptance, repair or model turn."
    })
  )
after
  GenServer.stop(store)
end
