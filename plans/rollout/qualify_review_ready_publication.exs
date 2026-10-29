# Read-only packaged qualification. Never starts the factory application.
[manifest_path, manifest_sha, evidence_path] = System.argv()
try do
true = Path.type(manifest_path) == :absolute and Path.type(evidence_path) == :absolute
false = File.exists?(evidence_path)
digest = fn raw -> Base.encode16(:crypto.hash(:sha256, raw), case: :lower) end
true = digest.(File.read!(manifest_path)) == manifest_sha
manifest = manifest_path |> File.read!() |> Jason.decode!()
true = manifest["kind"] == "FACTORY_REVIEW_REPORT_RELEASE_V1" and manifest["schema_version"] == 54
guard = Path.join(manifest["release"], "release_boot_guard.exs")
true = digest.(File.read!(guard)) == manifest["source_hashes"]["plans/rollout/review_release_boot_guard.exs"]
Code.eval_file(guard)
:ok = ReviewReportReleaseBootGuard.load(manifest_path, manifest_sha)
false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :symphony_elixir end)
{:ok, _} = Application.ensure_all_started(:exqlite)
alias SymphonyElixir.Factory.{RunLedger, Store, TicketPush, TicketPushIO, TicketPushPreissuanceRejection}

snapshot = fn store ->
  tables = Store.query!(store, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").rows
  for [table] <- tables, table not in ~w(control tick_health intake_snapshots sqlite_sequence), into: %{} do
    quoted = "\"" <> String.replace(table, "\"", "\"\"") <> "\""
    result = Store.query!(store, "SELECT rowid,* FROM " <> quoted <> " ORDER BY rowid")
    {table, {result.columns, result.rows}}
  end
end

head = fn worktree ->
  {raw, 0} = System.cmd("/usr/bin/git", ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", worktree, "rev-parse", "HEAD"],
    env: [{"GIT_NO_LAZY_FETCH", "1"}, {"GIT_NO_REPLACE_OBJECTS", "1"}, {"GIT_OPTIONAL_LOCKS", "0"}])
  String.trim(raw)
end

run_id = "ab5ab1fe-32cc-48c1-985e-3c3800adcfa2"
database = "/Users/cgable/Documents/Codex/factory-state/factory.sqlite"
captures = for _ <- 1..2 do
  {:ok, store} = Store.start_read_only(database: database)
  try do
    Store.query!(store, "PRAGMA query_only=ON")
    [[1]] = Store.query!(store, "PRAGMA query_only").rows
    [[54]] = Store.query!(store, "SELECT MAX(version) FROM factory_schema_migrations").rows
    before = snapshot.(store)
    {:ok, run} = RunLedger.get(store, run_id)
    true = run["state"] == "READY_FOR_REVIEW" and run["last_error"] == nil
    true = run["candidate_sha"] == "eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834"
    true = run["ci_pipeline_id"] == 2992785001 and run["verifier_round"] == 6
    true = run["code_repair_round"] == 13 and run["implementation_iteration"] == 27 and run["mr_iid"] == 47818
    true = digest.(run["candidate_handoff"]) == "574407d0b061ec4f13f4c870fde1d063c15c7329c8a8e979a41f612fbbb9e1ba"
    intent = Jason.decode!(run["candidate_handoff"])
    true = intent["kind"] == "TICKET_PUSH" and intent["phase"] == "COMPLETED"
    execution = Jason.decode!(intent["execution_json"])
    false = TicketPushPreissuanceRejection.status_execution?(execution)
    true = execution["helper_path"] == "/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-216eadb/dev/lib/symphony_elixir/priv/ticket_push_executor_v36.py"
    true = execution["helper_sha256"] == "7c023c0e853aaea8a809280cd7c67f5182a85cc2199cdb5d074786c938083238"
    original_head = head.(run["worktree"])
    {:ok, raw} = TicketPushIO.readback(intent)
    true = raw == intent["receipt_json"] and byte_size(raw) == 387927
    true = digest.(raw) == "f336451637ec70bc42481a15beed3f31f9aab31b6e483d85ccaa0a7806c2e12d"
    true = TicketPushIO.receipt_valid?(raw, intent)
    {:ok, proof} = TicketPush.completed_proof(store, run_id)
    true = proof.run == run and proof.intent == intent and proof.envelope == run["candidate_handoff"]
    true = proof.released_access["generation"] == 67 and is_binary(proof.released_access["released_at"])
    true = proof.released_access["reservation_key"] == "ticket-push:a9852b24ed6f4848230652c62bae09762c47572d8929874eff1b97f78a96d926"
    :ok = TicketPush.validate_completed_proof(store, run_id, proof)
    {:ok, ^run} = RunLedger.get(store, run_id)
    true = before == snapshot.(store) and original_head == head.(run["worktree"])
    [[0]] = Store.query!(store, "SELECT total_changes()").rows
    {run, proof.released_access, before, original_head}
  after
    GenServer.stop(store)
  end
end
[first, second] = captures
true = first == second
false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :symphony_elixir end)
result = %{
  kind: "READY_COMPLETED_PUBLIC_PROOF_V1", result: "PASS", manifest_sha256: manifest_sha,
  source_commit: manifest["source_commit"], run_id: run_id,
  current_candidate_sha: "eb9c67f06a00a38d98dd0d4ba1dd2e83a0883834",
  envelope_sha256: "574407d0b061ec4f13f4c870fde1d063c15c7329c8a8e979a41f612fbbb9e1ba",
  receipt_sha256: "f336451637ec70bc42481a15beed3f31f9aab31b6e483d85ccaa0a7806c2e12d", receipt_bytes: 387927,
  read_only_sqlite_reopens: 2, public_readback: true, receipt_valid: true, completed_proof: true,
  validate_completed_proof: true, entire_run_access_and_history_unchanged: true, human_head_unchanged: true,
  live_ledger_writes: 0, pushes: 0, native_chats: 0, native_model_turns: 0,
  limitation: "Historical completed factory candidate only; current human branch CI/delivery is not qualified."
}
File.write!(evidence_path, Jason.encode!(result), [:exclusive])
File.chmod!(evidence_path, 0o600)
IO.puts(Jason.encode!(result))
rescue
  _ ->
    IO.puts(:stderr, "READY_COMPLETED_PUBLIC_QUALIFICATION_FAILED_NO_MUTATION_REQUESTED")
    System.halt(1)
end
