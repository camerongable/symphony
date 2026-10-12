alias SymphonyElixir.Factory.{Store, WorkerFileTools}

[database, runtime] = System.argv()
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = Store.start_link(database: database)
{:ok, capability} = WorkerFileTools.bind(store, "reservation:request", "owner")
helper = Application.app_dir(:symphony_elixir, "priv/worker_file_io.py")
true = helper == Path.join(runtime, "priv/worker_file_io.py")
File.rm!(helper)
identity = %{"threadId" => "worker", "turnId" => "turn", "callId" => "missing-asset", "tool" => "repo_read"}
result = WorkerFileTools.execute(capability, "repo_read", %{"path" => "fixture.txt", "start_line" => 1}, identity)
IO.puts(Jason.encode!(%{helper: helper, result: result}))
