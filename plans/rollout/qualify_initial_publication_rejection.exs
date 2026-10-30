[manifest_path, manifest_sha, evidence_path] = System.argv()
digest = fn raw -> Base.encode16(:crypto.hash(:sha256, raw), case: :lower) end
true = digest.(File.read!(manifest_path)) == manifest_sha
manifest = manifest_path |> File.read!() |> Jason.decode!()
true = manifest["kind"] == "FACTORY_REVIEW_REPORT_RELEASE_V1" and manifest["schema_version"] == 54
guard = Path.join(manifest["release"], "release_boot_guard.exs")
true = digest.(File.read!(guard)) == manifest["source_hashes"]["plans/rollout/review_release_boot_guard.exs"]
Code.eval_file(guard)
:ok = ReviewReportReleaseBootGuard.load(manifest_path, manifest_sha)
false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :symphony_elixir end)
false = File.exists?(evidence_path)
{:ok, _} = Application.ensure_all_started(:exqlite)
alias SymphonyElixir.Factory.{RunLedger, Store, TicketPushIO}
audit = Application.app_dir(:symphony_elixir, "priv/ticket_push_preissuance_audit_v3.json") |> File.read!() |> Jason.decode!()
captures = for _ <- 1..2 do
  {:ok, store} = Store.start_read_only(database: audit["database_identity"]["path"])
  try do
    Store.query!(store, "PRAGMA query_only=ON")
    {:ok, before} = RunLedger.get(store, audit["operation"]["run_id"])
    true = Map.take(before, Map.keys(audit["operation"])) == audit["operation"]
    true = digest.(before["candidate_handoff"]) == audit["original_envelope_sha256"]
    intent = Jason.decode!(before["candidate_handoff"])
    true = intent["phase"] == "PUSH_UNCERTAIN" and intent["owner_nonce"] == audit["owner_nonce"]
    {:ok, raw} = TicketPushIO.readback(intent)
    true = digest.(raw) == audit["rejection"]["sha256"]
    {:ok, reason} = TicketPushIO.rejection_reason(raw, intent)
    true = reason == audit["rejection"]["reason"]
    {:ok, ^before} = RunLedger.get(store, audit["operation"]["run_id"])
    [[0]] = Store.query!(store, "SELECT total_changes()").rows
    {before["candidate_sha"], digest.(raw)}
  after
    GenServer.stop(store)
  end
end
[capture, capture] = captures
false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :symphony_elixir end)
result = %{kind: "INITIAL_PREISSUANCE_READBACK_PROOF_V1", result: "PASS", source_commit: manifest["source_commit"],
  manifest_sha256: manifest_sha, run_id: audit["operation"]["run_id"], read_only_sqlite_reopens: 2,
  candidate_sha: elem(capture, 0), rejection_sha256: elem(capture, 1),
  live_ledger_writes: 0, pushes: 0, worker_starts: 0, mutation_authority: false}
File.write!(evidence_path, Jason.encode!(result), [:exclusive])
File.chmod!(evidence_path, 0o600)
IO.puts(Jason.encode!(result))
