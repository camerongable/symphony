defmodule SymphonyElixir.FactoryTickLeaseTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.{Control, ControlServer, Store, TickLease}

  setup context do
    suffix = "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    database = Path.join(System.tmp_dir!(), "symphony-tick-#{suffix}.sqlite")
    fixture = if context[:journal], do: SymphonyElixir.TicketWorkerFixture.setup_fixture(context)
    database = if fixture, do: fixture.database, else: database
    store = if fixture, do: fixture.store, else: start_supervised!({Store, database: database})
    reader = start_supervised!(%{id: :reader, start: {Store, :start_read_only, [[database: database]]}})
    control_name = Module.concat(__MODULE__, "Control#{suffix}")

    factory = %{
      enabled: true,
      scope: "assigned-jira-work",
      dispatcher_id: "dispatcher-a",
      lease_seconds: if(context[:short_lease], do: 1, else: 240)
    }

    start_supervised!({ControlServer, store: store, read_store: reader, factory: factory, name: control_name})
    on_exit(fn -> File.rm(database) end)
    Map.merge(fixture || %{}, %{control_name: control_name, factory: factory, store: store, database: database})
  end

  test "paused control is a quiet no-op", context do
    ref = make_ref()

    assert {:skipped, "PAUSED"} =
             TickLease.run(context.factory, fn -> send(self(), ref) end, control_server: context.control_name)

    refute_received ^ref
  end

  test "runs under a lease and releases the exact tick", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)

    assert {:ran, :completed} =
             TickLease.run(context.factory, fn -> :completed end, control_server: context.control_name)

    assert %{"tick_id" => nil, "status" => "ACTIVE"} =
             Control.status(context.store, context.factory.scope)
  end

  test "abrupt owner death terminates a blocked callback without releasing its durable lease", context do
    assert {:ok, _} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    owner =
      spawn(fn ->
        TickLease.run(
          context.factory,
          fn tick ->
            send(parent, {:blocked_callback, self(), tick})

            receive do
              :old_barrier -> send(parent, :dead_callback_effect)
            end
          end,
          control_server: context.control_name
        )
      end)

    assert_receive {:blocked_callback, callback, tick}, 1_000
    on_exit(fn -> Process.exit(callback, :kill) end)
    callback_ref = Process.monitor(callback)
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^callback_ref, :process, ^callback, :killed}, 1_000
    send(callback, :old_barrier)
    refute_received :dead_callback_effect
    assert ControlServer.status(context.control_name)["tick_id"] == tick["tick_id"]
    assert %{result: "LEASE_HELD"} = ControlServer.acquire_tick("dispatcher-a", context.control_name)
  end

  @tag short_lease: true
  test "replacement waits for natural expiry and cannot overlap the dead callback", context do
    assert {:ok, _} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    owner =
      spawn(fn ->
        TickLease.run(
          context.factory,
          fn tick ->
            send(parent, {:first_callback, self(), tick})

            receive do
              :finish -> send(parent, :old_effect)
            end
          end,
          control_server: context.control_name
        )
      end)

    assert_receive {:first_callback, callback, old_tick}, 1_000
    callback_ref = Process.monitor(callback)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback, :killed}, 1_000
    assert {:skipped, "LEASE_HELD"} = TickLease.run(context.factory, fn -> flunk("unexpired lease") end, control_server: context.control_name)

    assert_eventually(fn ->
      case TickLease.run(context.factory, fn tick -> tick end, control_server: context.control_name) do
        {:skipped, "LEASE_HELD"} ->
          false

        {:ran, replacement} ->
          assert replacement["tick_id"] != old_tick["tick_id"]
          assert replacement["generation"] > old_tick["generation"]
          true
      end
    end)

    send(callback, :finish)
    refute_received :old_effect
    assert ControlServer.status(context.control_name)["tick_id"] == nil
  end

  test "owner death rolls back the callback's real SQLite transaction", context do
    assert {:ok, _} = ControlServer.activate("dispatcher-a", context.control_name)
    Store.query!(context.store, "CREATE TABLE callback_effects (value INTEGER)")
    parent = self()

    owner =
      spawn(fn ->
        TickLease.run(
          context.factory,
          fn ->
            Store.transaction!(context.store, fn tx ->
              Store.query!(tx, "INSERT INTO callback_effects VALUES (1)")
              send(parent, {:transaction_callback, self()})

              receive do
                :finish -> :completed
              end
            end)
          end,
          control_server: context.control_name
        )
      end)

    assert_receive {:transaction_callback, callback}, 1_000
    callback_ref = Process.monitor(callback)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback, :killed}, 1_000
    assert Store.query!(context.store, "SELECT value FROM callback_effects").rows == []
    assert is_binary(ControlServer.status(context.control_name)["tick_id"])
  end

  test "owner death at callback startup never leaves source work running", context do
    assert {:ok, _} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :start ->
            TickLease.run(
              context.factory,
              fn ->
                send(parent, {:startup_source, self()})

                receive do
                  :finish -> send(parent, :startup_effect)
                end
              end,
              control_server: context.control_name
            )
        end
      end)

    :erlang.trace(owner, true, [:procs])
    send(owner, :start)
    assert_receive {:trace, ^owner, :spawn, callback, _}, 1_000
    callback_ref = Process.monitor(callback)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback, reason}, 1_000
    assert reason in [:killed, :noproc]
    send(callback, :finish)
    refute_received :startup_effect
  end

  test "unexpected callback death exits the owner only after exact release", context do
    assert {:ok, _} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    owner =
      spawn(fn ->
        TickLease.run(
          context.factory,
          fn ->
            send(parent, {:unexpected_callback, self()})

            receive do
              :never -> :ok
            end
          end,
          control_server: context.control_name
        )
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:unexpected_callback, callback}, 1_000
    Process.exit(callback, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert ControlServer.status(context.control_name)["tick_id"] == nil
  end

  @tag journal: true
  test "issued Jira uncertainty remains unclaimable after owner death and Store reopen", context do
    alias SymphonyElixir.Factory.{RunLedger, TicketJiraJournal, Worktree}
    SymphonyElixir.TicketWorkerFixture.bind_parent(context)
    {:ok, %{run: run}} = RunLedger.update(context.store, "run", %{state: "MR_CREATING", mr_url: "https://gitlab.example.test/project/-/merge_requests/1"})
    {:ok, identity} = Worktree.checkout_identity(%{"path" => context.repo}, context.path, clean: true, detached: false, expected_branch: run["branch"], expected_sha: context.sha)
    checkout = Map.new(identity, fn {key, value} -> {Atom.to_string(key), value} end)
    {:ok, journal} = TicketJiraJournal.prepare(context.store, "run", "REVIEW_READY", "Synthetic review candidate", checkout)
    key = journal["operation_key"]
    assert {:ok, _} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    owner =
      spawn(fn ->
        TickLease.run(
          context.factory,
          fn ->
            assert {:ok, %{"phase" => "FIRST_UNCERTAIN"}} = TicketJiraJournal.claim(context.store, key)
            send(parent, {:issued_callback, self()})

            receive do
              :finish -> flunk("must not replay the issued effect")
            end
          end,
          control_server: context.control_name
        )
      end)

    assert_receive {:issued_callback, callback}, 1_000
    callback_ref = Process.monitor(callback)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback, :killed}, 1_000
    {:ok, reopened} = Store.start_link(database: context.database)

    try do
      assert {:ok, %{"phase" => "FIRST_UNCERTAIN"}} = TicketJiraJournal.get(reopened, key)
      assert {:error, :ticket_jira_effect_not_unissued} = TicketJiraJournal.claim(reopened, key)
    after
      GenServer.stop(reopened)
    end
  end

  test "the monitored callback receives only its acquired identity and renewal preserves it", context do
    assert {:ok, _} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    assert {:ran, :owned} =
             TickLease.run(
               context.factory,
               fn tick ->
                 send(parent, {:owned_tick_child, self(), tick})
                 assert {:ok, ^tick} = SymphonyElixir.Factory.TicketPushRecovery.tick_binding(context.store, operator_tick: tick)
                 assert %{result: "LEASE_RENEWED"} = ControlServer.renew_tick("dispatcher-a", tick["tick_id"], context.control_name)
                 assert {:ok, ^tick} = SymphonyElixir.Factory.TicketPushRecovery.tick_binding(context.store, operator_tick: tick)

                 for changed <- [Map.put(tick, "generation", tick["generation"] + 1), Map.put(tick, "tick_id", "foreign"), Map.put(tick, "dispatcher_id", "foreign")] do
                   assert {:error, :push_recovery_operator_tick_unproven} = SymphonyElixir.Factory.TicketPushRecovery.tick_binding(context.store, operator_tick: changed)
                 end

                 Store.query!(context.store, "UPDATE control SET lease_expires_at='2020-01-01T00:00:00Z' WHERE scope=?", [context.factory.scope])
                 assert {:error, :push_recovery_operator_tick_unproven} = SymphonyElixir.Factory.TicketPushRecovery.tick_binding(context.store, operator_tick: tick)
                 :owned
               end,
               control_server: context.control_name
             )

    assert_receive {:owned_tick_child, child, tick}
    assert child != self()
    assert Enum.sort(Map.keys(tick)) == ~w(dispatcher_id generation scope tick_id)
    assert Control.status(context.store, context.factory.scope)["tick_id"] == nil
    assert {:error, :push_recovery_operator_tick_unproven} = SymphonyElixir.Factory.TicketPushRecovery.tick_binding(context.store, operator_tick: tick)
  end

  test "disabled arity-one callbacks receive no ordinary lease authority", context do
    assert {:ran, nil} = TickLease.run(%{context.factory | enabled: false}, fn tick -> tick end, control_server: context.control_name)
    assert Control.status(context.store, context.factory.scope)["tick_id"] == nil
  end

  test "the real Controller passes its acquired tick to the normal Scheduler options", context do
    alias SymphonyElixir.Factory.{Controller, Scheduler}
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    settings = SymphonyElixir.Config.settings!()
    factory = Map.merge(settings.factory, Map.merge(context.factory, %{queue: %{}, repositories: %{}}))
    :erlang.trace_pattern({Scheduler, :tick, 2}, true, [])
    :erlang.trace(supervisor, true, [:call, :set_on_spawn])
    on_exit(fn -> :erlang.trace_pattern({Scheduler, :tick, 2}, false, []) end)
    owner = start_supervised!({Controller, settings: %{settings | factory: factory}, store: context.store, control_server: context.control_name, task_supervisor: supervisor, name: nil})
    assert {:ok, _} = ControlServer.activate(factory.dispatcher_id, context.control_name)
    assert :ok = Controller.reconcile_now(owner)
    assert_receive {:trace, child, :call, {Scheduler, :tick, [_scheduler_context, options]}}, 5_000
    tick = options |> Keyword.fetch!(:ticket_options) |> Keyword.fetch!(:operator_tick)
    assert Enum.sort(Map.keys(tick)) == ~w(dispatcher_id generation scope tick_id)
    assert tick["scope"] == factory.scope and tick["dispatcher_id"] == factory.dispatcher_id
    assert is_integer(tick["generation"]) and tick["generation"] > 0 and is_binary(tick["tick_id"])
    assert child != owner and child != self()
  end

  defmodule NoQueueRead do
    def search(_query, _opts), do: raise("recovery must not poll the queue")
    def issue(_key, _opts), do: raise("an empty recovery set must not read Jira")
  end

  test "paused recovery runs only the fixed readback entrypoint and releases without activating", context do
    recovery_context = %{store: context.store, factory: context.factory}
    options = [control_server: context.control_name, scheduler_options: [jira_reader: NoQueueRead]]
    assert {:ran, {:ok, %{launches: [], events: []}}} = TickLease.reconcile(recovery_context, options)
    assert %{"status" => "PAUSED", "tick_id" => nil} = ControlServer.status(context.control_name)
    assert {:skipped, "PAUSED"} = TickLease.run(context.factory, fn -> raise "must not run" end, control_server: context.control_name, recovery_only: true)
  end

  test "recovery obeys dispatcher identity and excludes competing leases while paused", context do
    wrong = %{store: context.store, factory: %{context.factory | dispatcher_id: "other"}}
    assert {:skipped, "DISPATCHER_CONFLICT"} = TickLease.reconcile(wrong, control_server: context.control_name)
    assert %{result: "ACQUIRED", tick_id: tick} = ControlServer.acquire_recovery_tick("dispatcher-a", context.control_name)
    assert %{result: "LEASE_HELD"} = ControlServer.acquire_recovery_tick("dispatcher-a", context.control_name)
    assert %{result: "LEASE_MISMATCH"} = ControlServer.renew_recovery_tick("other", tick, context.control_name)
    assert %{result: "LEASE_RENEWED"} = ControlServer.renew_recovery_tick("dispatcher-a", tick, context.control_name)
    recovery_context = %{store: context.store, factory: context.factory}
    assert {:skipped, "LEASE_HELD"} = TickLease.reconcile(recovery_context, control_server: context.control_name)
    assert {:error, :live_tick_lease} = ControlServer.activate("dispatcher-a", context.control_name)
    assert %{result: "RELEASED"} = ControlServer.release_tick("dispatcher-a", tick, context.control_name)
    assert %{result: "LEASE_MISMATCH"} = ControlServer.renew_recovery_tick("dispatcher-a", tick, context.control_name)
    assert %{"status" => "PAUSED", "tick_id" => nil} = ControlServer.status(context.control_name)
  end

  test "releases the lease when the bounded tick raises", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)

    assert_raise RuntimeError, "boom", fn ->
      TickLease.run(context.factory, fn -> raise "boom" end, control_server: context.control_name)
    end

    assert %{"tick_id" => nil} = Control.status(context.store, context.factory.scope)
  end

  test "a long tick renews its lease before it expires", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    task =
      Task.async(fn ->
        TickLease.run(
          context.factory,
          fn ->
            send(parent, :long_tick_started)
            Process.sleep(250)
            :completed
          end,
          control_server: context.control_name,
          renewal_interval_ms: 50
        )
      end)

    assert_receive :long_tick_started
    Process.sleep(120)

    assert %{result: "LEASE_HELD"} =
             ControlServer.acquire_tick("dispatcher-a", context.control_name)

    assert {:ran, :completed} = Task.await(task)
    assert ControlServer.status(context.control_name)["tick_id"] == nil
  end

  test "renewal survives a source transaction holding the shared connection beyond five seconds", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    task =
      Task.async(fn ->
        TickLease.run(
          context.factory,
          fn ->
            Store.transaction!(
              context.store,
              fn tx ->
                Store.query!(tx, "SELECT 1")
                send(parent, :source_transaction_started)
                Process.sleep(5_500)
                :completed
              end,
              timeout: 10_000
            )
          end,
          control_server: context.control_name,
          renewal_interval_ms: 50
        )
      end)

    assert_receive :source_transaction_started, 1_000
    assert {:ran, :completed} = Task.await(task, 15_000)
    assert %{"status" => "ACTIVE", "tick_id" => nil} = ControlServer.status(context.control_name)
  end

  @tag timeout: 80_000, renewal_envelope: true
  test "renewal covers the existing sixty-second source transaction envelope", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()

    task =
      Task.async(fn ->
        TickLease.run(
          context.factory,
          fn ->
            Store.transaction!(
              context.store,
              fn tx ->
                Store.query!(tx, "SELECT 1")
                send(parent, :long_transaction_started)
                Process.sleep(60_000)
                :completed
              end,
              timeout: 62_000
            )
          end,
          control_server: context.control_name,
          renewal_interval_ms: 50
        )
      end)

    assert_receive :long_transaction_started, 1_000
    assert_renewing(context.control_name)
    assert ControlServer.status(context.control_name)["tick_id"] != nil
    Process.sleep(6_100)
    assert ControlServer.status(context.control_name)["tick_id"] != nil
    assert Task.yield(task, 0) == nil
    assert {:ran, :completed} = Task.await(task, 70_000)
    assert ControlServer.status(context.control_name)["tick_id"] == nil
  end

  test "a bounded renewal timeout stops the source owner and cannot resurrect its lease", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
    parent = self()
    factory = %{context.factory | lease_seconds: 1}

    task =
      Task.async(fn ->
        TickLease.run(
          factory,
          fn ->
            Store.transaction!(
              context.store,
              fn tx ->
                Store.query!(tx, "SELECT 1")
                send(parent, {:bounded_source_started, self()})

                receive do
                  :finish -> send(parent, :incorrectly_completed)
                end
              end,
              timeout: 5_000
            )
          end,
          control_server: context.control_name,
          renewal_interval_ms: 50
        )
      end)

    assert_receive {:bounded_source_started, source}, 1_000
    monitor = Process.monitor(source)
    assert {:ran, {:error, {:tick_lease_lost, _reason}}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^source, :killed}, 1_000
    assert %{"tick_id" => nil} = ControlServer.status(context.control_name)
    send(source, :finish)
    refute_received :incorrectly_completed
    assert {:ran, :next_tick} = TickLease.run(context.factory, fn -> :next_tick end, control_server: context.control_name)
    assert %{"tick_id" => nil} = ControlServer.status(context.control_name)
  end

  for {column, value, result} <- [{"status", "PAUSED", "PAUSED"}, {"dispatcher_id", "other", "LEASE_MISMATCH"}, {"tick_id", "replacement", "LEASE_MISMATCH"}] do
    test "renewal still stops work when #{column} changes", context do
      assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
      parent = self()

      task =
        Task.async(fn ->
          TickLease.run(
            context.factory,
            fn ->
              send(parent, {:source_started, self()})

              receive do
                :finish -> :incorrectly_completed
              end
            end,
            control_server: context.control_name,
            renewal_interval_ms: 100
          )
        end)

      assert_receive {:source_started, source}, 1_000
      Store.query!(context.store, "UPDATE control SET #{unquote(column)} = ? WHERE scope = ?", [unquote(value), context.factory.scope])
      assert {:ran, {:error, {:tick_lease_lost, %{result: unquote(result)}}}} = Task.await(task, 5_000)
      refute Process.alive?(source)
      if unquote(column) == "tick_id", do: assert(Control.status(context.store, context.factory.scope)["tick_id"] == "replacement")
    end
  end

  test "an interval at lease expiry rejects the tick before source work starts", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)

    assert {:ran, {:error, :invalid_tick_renewal_interval}} =
             TickLease.run(context.factory, fn -> flunk("source must not start") end, control_server: context.control_name, renewal_interval_ms: 240_000)

    assert ControlServer.status(context.control_name)["tick_id"] == nil
  end

  test "an interval leaving no positive renewal budget does not start source work", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)

    assert {:ran, {:error, :invalid_tick_renewal_interval}} =
             TickLease.run(%{context.factory | lease_seconds: 1}, fn -> flunk("source must not start") end, control_server: context.control_name, renewal_interval_ms: 999)

    assert ControlServer.status(context.control_name)["tick_id"] == nil
  end

  test "an expired queued recovery renewal cannot extend the durable lease", context do
    assert %{result: "ACQUIRED", tick_id: tick} = ControlServer.acquire_recovery_tick("dispatcher-a", context.control_name)
    before = ControlServer.status(context.control_name)["lease_expires_at"]
    :sys.suspend(context.control_name)

    try do
      caller =
        Task.async(fn ->
          try do
            ControlServer.renew_recovery_tick("dispatcher-a", tick, context.control_name, 50)
          catch
            :exit, {:timeout, _} -> :timed_out
          end
        end)

      assert :timed_out = Task.await(caller, 1_000)
    after
      :sys.resume(context.control_name)
    end

    assert ControlServer.status(context.control_name)["lease_expires_at"] == before
    assert %{result: "RELEASED"} = ControlServer.release_tick("dispatcher-a", tick, context.control_name)
  end

  test "stopping control terminates its pending renewal helper", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
    assert %{result: "ACQUIRED", tick_id: tick} = ControlServer.acquire_tick("dispatcher-a", context.control_name)
    parent = self()

    holder =
      Task.async(fn ->
        Store.transaction!(context.store, fn tx ->
          Store.query!(tx, "SELECT 1")
          send(parent, :connection_held)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :connection_held, 1_000

    caller =
      Task.async(fn ->
        try do
          ControlServer.renew_tick("dispatcher-a", tick, context.control_name, 1_000)
        catch
          :exit, _ -> :control_stopped
        end
      end)

    assert_renewing(context.control_name)
    helper = :sys.get_state(context.control_name).renewal.pid
    ref = Process.monitor(helper)
    GenServer.stop(context.control_name, :normal)
    assert_receive {:DOWN, ^ref, :process, ^helper, :killed}, 1_000
    assert :control_stopped = Task.await(caller)
    send(holder.pid, :finish)
    assert :ok = Task.await(holder)
  end

  test "abnormal control death cannot renew its old lease", context do
    assert {:ok, _active} = ControlServer.activate("dispatcher-a", context.control_name)
    assert %{result: "ACQUIRED", tick_id: tick} = ControlServer.acquire_tick("dispatcher-a", context.control_name)
    before = ControlServer.status(context.control_name)["lease_expires_at"]
    parent = self()

    holder =
      Task.async(fn ->
        Store.transaction!(context.store, fn tx ->
          Store.query!(tx, "SELECT 1")
          send(parent, :connection_held)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :connection_held, 1_000

    caller =
      Task.async(fn ->
        try do
          ControlServer.renew_tick("dispatcher-a", tick, context.control_name, 1_000)
        catch
          :exit, _ -> :control_stopped
        end
      end)

    assert_renewing(context.control_name)
    helper = :sys.get_state(context.control_name).renewal.pid
    helper_ref = Process.monitor(helper)
    control = GenServer.whereis(context.control_name)
    control_ref = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^control_ref, :process, ^control, :killed}, 1_000
    assert :control_stopped = Task.await(caller)
    send(holder.pid, :finish)
    assert :ok = Task.await(holder)
    assert_receive {:DOWN, ^helper_ref, :process, ^helper, :normal}, 2_000
    assert Control.status(context.store, context.factory.scope)["lease_expires_at"] == before
  end

  defp assert_renewing(server, attempts \\ 100)
  defp assert_renewing(_server, 0), do: flunk("renewal helper did not start")

  defp assert_renewing(server, attempts) do
    case :sys.get_state(server) do
      %{renewal: _} ->
        :ok

      _ ->
        Process.sleep(10)
        assert_renewing(server, attempts - 1)
    end
  end

  defp assert_eventually(fun, attempts \\ 200)
  defp assert_eventually(_fun, 0), do: flunk("lease did not expire naturally")

  defp assert_eventually(fun, attempts) do
    unless fun.() do
      receive do
      after
        10 -> assert_eventually(fun, attempts - 1)
      end
    end
  end
end
