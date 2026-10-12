alias SymphonyElixir.Factory.{Store, WorkerFileIO}

[database, source, binding_json, fixture] = System.argv()
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = Store.start_link(database: database)
binding = Jason.decode!(binding_json)
sha = :crypto.hash(:sha256, File.read!(fixture)) |> Base.encode16(case: :lower)
transport = %{path: fixture, sha256: sha, failure: "nonzero"}

results = %{
  request: inspect(WorkerFileIO.request(source, binding, "read", %{"path" => "fixture.txt"}, transport)),
  status: inspect(WorkerFileIO.recover_mutation(binding, transport)),
  spool: inspect(WorkerFileIO.workspace_allowed?(store, source, transport))
}

IO.puts(Jason.encode!(results))
