alias SymphonyElixir.Factory.{DesktopRequest, Store, TicketMrPresendRecovery}

[database, key, broker] = System.argv()
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = Store.start_read_only(database: database)
{:ok, request} = DesktopRequest.get(store, key)
:ok = TicketMrPresendRecovery.available(store, request, broker)
reader = Module.concat(SymphonyElixir.Factory, "TicketMrPresendEvidence")
false = :code.is_loaded(reader)

policy = Application.app_dir(:symphony_elixir, "priv/ticket_mr_presend_registry_v2.json") |> File.read!() |> Jason.decode!()
digest = fn value -> :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower) end
raw = %{"data" => [%{"id" => "cold-recovery-turn", "status" => "interrupted", "items" => []}], "nextCursor" => nil}
queue = %{"data" => [], "nextCursor" => nil}

native = %{
  "id" => broker,
  "cwd" => policy["broker_cwd"],
  "projectId" => nil,
  "updatedAt" => 1,
  "status" => %{"type" => "notLoaded"},
  "latest_turn_observation" => %{
    "mode" => "LATEST_DESC",
    "raw_response" => raw,
    "updated_at" => 1,
    "sha256" => digest.(raw),
    "confirmation" => %{"raw_response" => raw, "sha256" => digest.(raw)}
  },
  "queue_observation" => %{"thread_id" => broker, "raw_response" => queue, "sha256" => digest.(queue)}
}

defmodule ColdNativeReader do
  def read_native_thread(_broker, _opts), do: {:ok, :persistent_term.get(__MODULE__)}
end

:persistent_term.put(ColdNativeReader, native)
options = [presend_native_reader: ColdNativeReader]
{:error, :mr_presend_request_unproven} = TicketMrPresendRecovery.observe(store, request, broker, options)
{:error, :mr_presend_broker_native_unproven} = reader.native_fence(native, broker)
{:file, _} = :code.is_loaded(reader)

defmodule ColdLegacyReader do
  def native_fence(native, broker) do
    reader = Module.concat(SymphonyElixir.Factory, "TicketMrPresendEvidence")
    reader.native_fence(native, broker)
  end

  def read(_request, _broker, _native), do: {:error, :legacy_evidence_intended_gate}
end

progress = %{"data" => [%{"id" => "cold-recovery-turn", "status" => "inProgress", "items" => []}], "nextCursor" => nil}
progress_native = put_in(native, ["latest_turn_observation", "raw_response"], progress)
progress_native = put_in(progress_native, ["latest_turn_observation", "sha256"], digest.(progress))
progress_native = put_in(progress_native, ["latest_turn_observation", "confirmation"], %{"raw_response" => progress, "sha256" => digest.(progress)})
:persistent_term.put(ColdNativeReader, progress_native)

legacy = Keyword.put(options, :presend_evidence_reader, ColdLegacyReader)
{:error, :legacy_evidence_intended_gate} = TicketMrPresendRecovery.observe(store, request, broker, legacy)

missing = Keyword.put(options, :presend_evidence_reader, MissingColdEvidenceReader)
{:error, :mr_presend_evidence_reader_unavailable} = TicketMrPresendRecovery.observe(store, request, broker, missing)

GenServer.stop(store)
IO.puts("COLD_PUBLIC_RECOVERY_REACHED_INCIDENT_GATE; STRICT_NATIVE_FENCE_REFUSED")
