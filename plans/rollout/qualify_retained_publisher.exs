[manifest_path, manifest_sha] = System.argv()
manifest = manifest_path |> File.read!() |> Jason.decode!()
Code.eval_file(Path.join(manifest["release"], "release_boot_guard.exs"))
:ok = ReviewReportReleaseBootGuard.load(manifest_path, manifest_sha)
{:ok, _} = Application.ensure_all_started(:exqlite)
alias SymphonyElixir.Factory.{RunLedger, Store, TicketPush, TicketPushIO}

run_id = "ab5ab1fe-32cc-48c1-985e-3c3800adcfa2"
request = "desktop:11b288b43e59ae80afdfc26b01e1bcf2f2d297249cc54e8f0d0af98829629c5a"
{:ok, store} = Store.start_read_only(database: "/Users/cgable/Documents/Codex/factory-state/factory.sqlite")

try do
  {:ok, current} = RunLedger.get(store, run_id)
  true = current["state"] == "CI_PUSHING" and current["candidate_sha"] == "eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834"
  true = current["verifier_round"] == 5 and current["code_repair_round"] == 13 and current["implementation_iteration"] == 27
  row = Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [request])
  true = row["status"] == "CONSUMED" and is_binary(row["owner_stopped_at"]) and is_binary(row["consumed_at"])
  true = row["output_sha256"] == "42840686cdc6a2a99a4ea7a92910010892f56cbd88dfcecb689b763c026b6350"
  task = Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]])
  true = task["status"] == "CONSUMED"
  intent = Jason.decode!(current["candidate_handoff"])
  true = intent["kind"] == "TICKET_PUSH" and intent["phase"] == "COMPLETED"
  true = intent["remote_sha"] == "4e5c48fc2150515c4cb5ce0771f4c204b10c532c"
  true = intent["receipt_sha256"] == "743b489bf716d072bb9955f827397588e1c8451974e90c27b64b67e4394b06e1"
  binding = Jason.decode!(intent["binding_json"])
  {:ok, raw} = TicketPushIO.readback(intent)
  true = raw == intent["receipt_json"] and TicketPushIO.receipt_valid?(raw, intent)
  prior = Map.merge(current, Map.take(binding, ~w(run_id issue_key repo_path worktree branch base_branch candidate_sha contract_sha256 spec_revision verifier_round)))
  :ok = TicketPush.validate_historical_completed_preimage(store, prior)
  {:ok, ^raw} = TicketPushIO.readback(intent)
  {:ok, ^current} = RunLedger.get(store, run_id)
  true = row == Store.one!(store, "SELECT * FROM worker_evidence WHERE request_key=?", [request])
  true = task == Store.one!(store, "SELECT * FROM factory_tasks WHERE task_key=?", [row["task_key"]])
  [[54]] = Store.query!(store, "SELECT MAX(version) FROM factory_schema_migrations").rows
  [[0]] = Store.query!(store, "SELECT total_changes()").rows
  IO.puts(Jason.encode!(%{
    result: "PASS", manifest_sha256: manifest_sha, source_commit: manifest["source_commit"],
    run_id: run_id, current_candidate_sha: current["candidate_sha"],
    retained_receipt_sha256: intent["receipt_sha256"], retained_readback_bytes: byte_size(raw),
    historical_completed_preimage_valid: true, raw_run_worker_and_task_unchanged: true,
    live_ledger_writes: 0, pushes: 0, native_chats: 0, native_model_turns: 0,
    limitation: "Read-only exact retained receipt compatibility, not current candidate push, CI, verifier or delivery acceptance."
  }))
after
  GenServer.stop(store)
end
