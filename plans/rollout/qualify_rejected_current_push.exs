[manifest_path, manifest_sha] = System.argv()
manifest = manifest_path |> File.read!() |> Jason.decode!()
Code.eval_file(Path.join(manifest["release"], "release_boot_guard.exs"))
:ok = ReviewReportReleaseBootGuard.load(manifest_path, manifest_sha)
{:ok, _} = Application.ensure_all_started(:exqlite)
alias SymphonyElixir.Factory.{RunLedger, Store, TicketPushIO, TicketPushOrdinaryRejection}
digest = fn raw -> Base.encode16(:crypto.hash(:sha256, raw), case: :lower) end
run_id = "ab5ab1fe-32cc-48c1-985e-3c3800adcfa2"
{:ok, store} = Store.start_read_only(database: "/Users/cgable/Documents/Codex/factory-state/factory.sqlite")

try do
  {:ok, before_run} = RunLedger.get(store, run_id)
  true = before_run["state"] == "CI_PUSHING" and before_run["candidate_sha"] == "eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834"
  true = before_run["implementation_iteration"] == 27 and before_run["code_repair_round"] == 13 and before_run["verifier_round"] == 5
  true = digest.(before_run["candidate_handoff"]) == "5935494d2f4b8b2ec0c3e5778a2e297d64f138c73469140db4c20ae3f549c209"
  intent = Jason.decode!(before_run["candidate_handoff"])
  true = intent["phase"] == "PUSH_UNCERTAIN" and intent["helper_pid"] == 5776
  true = intent["binding_sha256"] == "c74d7c25ae5f9d452aee999176cd6bc51ef8e8d0d20c30c157f45a0474d922da"
  true = Enum.all?(~w(receipt_json receipt_sha256 remote_sha), &is_nil(intent[&1]))
  retirement_query = "SELECT * FROM events WHERE run_id=? AND event_type='TICKET_ORDINARY_PUSH_REJECTION_RETIRED' ORDER BY id"
  prior_retirements = Store.query!(store, retirement_query, [run_id]).rows
  true = length(prior_retirements) == 3
  {:ok, rejection} = TicketPushIO.readback(intent)
  true = digest.(rejection) == "44477a82a476e1f83f47b5af4a3182ee4b9962be537e5c542989aa20dea6c40b"
  {:ok, "ordinary_verifier_repair_unproven"} = TicketPushIO.rejection_reason(rejection, intent)
  decoded = Jason.decode!(rejection)
  true = decoded["child_pid"] == nil and decoded["kind"] == "PREISSUANCE_REJECTED"
  true = TicketPushOrdinaryRejection.eligible?(before_run)
  {:ok, proof} = TicketPushOrdinaryRejection.closed_authority(before_run, intent)
  true = proof["kind"] == "AUDITED_V34_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"
  true = proof["rejection_json"] == rejection
  {:ok, ^before_run} = RunLedger.get(store, run_id)
  ^prior_retirements = Store.query!(store, retirement_query, [run_id]).rows
  [[54]] = Store.query!(store, "SELECT MAX(version) FROM factory_schema_migrations").rows
  [[0]] = Store.query!(store, "SELECT total_changes()").rows
  IO.puts(Jason.encode!(%{
    result: "PASS", manifest_sha256: manifest_sha, source_commit: manifest["source_commit"],
    current_candidate_sha: before_run["candidate_sha"], original_envelope_sha256: digest.(before_run["candidate_handoff"]),
    rejection_sha256: digest.(rejection), rejection_bytes: byte_size(rejection), child_pid: nil,
    exact_audited_closed_authority: true, audit_sha256: proof["audit_sha256"],
    original_run_and_three_prior_retirements_unchanged: true,
    live_ledger_writes: 0, pushes: 0, native_chats: 0, native_model_turns: 0,
    limitation: "Read-only current rejection proof; no retirement, successor preparation, push, CI or delivery was applied."
  }))
after
  GenServer.stop(store)
end
