alias SymphonyElixir.Factory.{RunLedger, Store, TicketPush, TicketPushIO}

[database, packet] = System.argv()
config = packet |> Base.decode64!() |> Jason.decode!()
File.write!(Path.join(Path.dirname(database), "controller-vm.pid"), System.pid())
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = Store.start_link(database: database)
keys = [:capacity_policy, :free_bytes, :workspace_root]
opts = Enum.map(keys, &{&1, config["opts"][Atom.to_string(&1)]})
{:ok, intent} = TicketPush.claim(store, "run", config["authorization"], opts)
{:ok, execution} = TicketPushIO.prepare(store, intent, config["authorization"])

barrier = fn ->
  File.write!(Path.join(Path.dirname(database), "reply-withheld"), config["checkpoint"])
  Process.sleep(:infinity)
end

{:ok, _} =
  TicketPushIO.execute(execution, fn pid, encoded ->
    if config["checkpoint"] == "before_attach", do: barrier.()
    {:ok, _} = result = TicketPush.attach_execution(store, "run", pid, encoded, config["authorization"], opts)
    if config["checkpoint"] == "after_attach", do: barrier.()
    result
  end)

{:ok, current} = RunLedger.get(store, "run")
intent = Jason.decode!(current["candidate_handoff"])
{:ok, raw} = TicketPushIO.readback(intent)
true = TicketPushIO.receipt_valid?(raw, intent)
barrier.()
