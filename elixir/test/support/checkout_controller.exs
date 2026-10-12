alias SymphonyElixir.Factory.{Store, TicketCheckout, TicketCheckoutIO}

[database, packet] = System.argv()
config = packet |> Base.decode64!() |> Jason.decode!()
File.write!(Path.join(Path.dirname(database), "controller-vm.pid"), System.pid())
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, store} = Store.start_link(database: database)
keys = [:capacity_policy, :free_bytes, :workspace_root, :base_sha]
opts = Enum.map(keys, &{&1, config["opts"][Atom.to_string(&1)]})
{:ok, intent} = TicketCheckout.claim(store, "run", config["authorization"], opts)
{:ok, execution} = TicketCheckoutIO.prepare(store, intent, config["authorization"])

{:ok, _} =
  TicketCheckoutIO.execute(execution, fn pid, encoded ->
    Store.query!(store, "UPDATE ticket_checkout_intents SET helper_pid = ?, execution_json = ? WHERE run_id = 'run' AND helper_pid IS NULL", [pid, encoded])
    TicketCheckout.get(store, "run")
  end)

{:ok, current} = TicketCheckout.get(store, "run")
{:ok, raw} = TicketCheckoutIO.readback(current)
true = TicketCheckoutIO.receipt_valid?(raw, current)
File.write!(Path.join(Path.dirname(database), "reply-withheld"), "terminal checkout receipt observed\n")
Process.sleep(:infinity)
