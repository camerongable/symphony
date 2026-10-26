[manifest_path, manifest_sha] = System.argv()
manifest = manifest_path |> File.read!() |> Jason.decode!()
guard_path = Path.join(manifest["release"], "release_boot_guard.exs")
Code.eval_file(guard_path)
:ok = ReviewReportReleaseBootGuard.load(manifest_path, manifest_sha)
{:ok, _} = Application.ensure_all_started(:exqlite)

alias SymphonyElixir.Factory.{ReviewProtocol, RunLedger, Store}

run_id = "ab5ab1fe-32cc-48c1-985e-3c3800adcfa2"
request = "desktop:b996c85fd59f267cb7ee029cac2f25f2e56e245de90f3945d6e8526a1b6c38bc"
{:ok, store} = Store.start_read_only(database: "/Users/cgable/Documents/Codex/factory-state/factory.sqlite")
{:ok, before_run} = RunLedger.get(store, run_id)
true = before_run["state"] == "VERIFYING"
true = before_run["candidate_sha"] == "4e5c48fc2150515c4cb5ce0771f4c204b10c532c"
true = before_run["verifier_round"] == 5 and before_run["code_repair_round"] == 12
true = before_run["ci_pipeline_id"] == 2_987_402_948
row = Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [request])
task = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]])
true = row["binding_sha256"] == "391f6257ff012c59c0302602e7aef1dc8b18fc84c7f2ee0d01b84abb63802918"
true = row["output_sha256"] == "4c6b969347b9fcba19241e1b48c1c297b0a81ca03b0b90f98cc840152a3f9c84"
true = row["status"] == "RESULT_RECORDED" and is_binary(row["owner_stopped_at"])
{:ok, packet} = ReviewProtocol.context(store, task)
true = packet["review_protocol"]["version"] == 1
true = packet["review_protocol"]["repairs_used"] == 2
binding = Jason.decode!(row["binding_json"])
output = Jason.decode!(row["output_json"])
"REPAIR" = output["status"]
{:error, :review_protocol_evidence_incomplete} = ReviewProtocol.validate_result(store, task, binding, output)

input = %{
  "run_id" => run_id,
  "request_key" => request,
  "binding_sha256" => row["binding_sha256"],
  "output_sha256" => row["output_sha256"],
  "mapping" => [%{"classification_index" => 0, "finding_index" => 0}]
}

{:ok, prepared} = ReviewProtocol.prepare_correction(store, input)
true = prepared["status"] == "REPORT_CORRECTION_PREPARED"
true = prepared["verdict"] == "REPAIR" and prepared["automatic_repairs_used"] == 2
true = Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [request]) == row
true = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]]) == task
{:ok, ^before_run} = RunLedger.get(store, run_id)
[[54]] = Store.query!(store, "SELECT MAX(version) FROM factory_schema_migrations").rows
[[0]] = Store.query!(store, "SELECT total_changes()").rows
GenServer.stop(store)

IO.puts(Jason.encode!(%{
  result: "PASS",
  manifest_sha256: manifest_sha,
  source_commit: manifest["source_commit"],
  original_report_status: "REPAIR",
  automatic_repairs_used: 2,
  correction_prepared: prepared,
  raw_worker_and_task_unchanged: true,
  run_unchanged: true,
  live_ledger_writes: 0,
  pushes: 0,
  native_chats: 0,
  limitation: "Read-only compatibility qualification. No correction, adoption, repair authorization or model turn was issued."
}))
