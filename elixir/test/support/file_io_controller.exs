alias SymphonyElixir.Factory.{Store, WorkerFileTools}

[database, transport] = System.argv()
File.write!(Path.join(Path.dirname(database), "controller-vm.pid"), System.pid())
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = Store.start_link(database: database)
{:ok, capability} = WorkerFileTools.bind(store, "reservation:request", "owner")
sha = :crypto.hash(:sha256, File.read!(transport)) |> Base.encode16(case: :lower)
capability = Map.put(capability, :file_io_transport, %{path: transport, sha256: sha})
before = :crypto.hash(:sha256, "base\n") |> Base.encode16(case: :lower)
identity = %{"threadId" => "worker", "turnId" => "turn", "callId" => "call", "tool" => "repo_write"}
result = WorkerFileTools.execute(capability, "repo_write", %{"path" => "fixture.txt", "expected_sha256" => before, "content" => "edited\n"}, identity)
IO.puts(Jason.encode!(result))
