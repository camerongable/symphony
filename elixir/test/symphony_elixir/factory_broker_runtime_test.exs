defmodule SymphonyElixir.FactoryBrokerRuntimeTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.BrokerRuntime
  alias SymphonyElixir.Config.Schema

  setup do
    root = Path.join(System.tmp_dir!(), "broker-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    workflow = Path.join(root, "WORKFLOW.md")
    database = Path.join(root, "factory.sqlite")
    File.write!(workflow, "---\nfactory:\n  database: #{database}\n---\nSynthetic bridge.\n")
    %{root: root, workflow: workflow, factory: %Schema.Factory{database: database}}
  end

  test "broker receives service result without executing native work locally", ctx do
    caller = self()

    executor = fn args, _, _ ->
      send(caller, {:executed, args})
      {:ok, %{"receipt" => "checked"}}
    end

    start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil, executor: executor})
    args = ["claim", "request", "--workflow", ctx.workflow]
    assert {:ok, %{"receipt" => "checked"}} = BrokerRuntime.call(args)
    assert_receive {:executed, ^args}
  end

  test "bridge rejects commands outside bounded runtime operations", ctx do
    assert {:error, :broker_runtime_unavailable} = BrokerRuntime.call(["activate", "--workflow", ctx.workflow])
    refute BrokerRuntime.bridged?(["run", "arbitrary"])
    refute BrokerRuntime.bridged?([])
  end

  test "typed MR owner evidence reaches the service without a local native invocation", ctx do
    caller = self()

    frame = %{
      "request_key" => "request",
      "source_thread_id" => "broker",
      "owner" => %{"source" => "codex_app/read_thread", "observed_at" => DateTime.to_iso8601(DateTime.utc_now()), "response" => %{"schemaVersion" => 1, "thread" => %{"id" => "controller"}}}
    }

    payload = frame |> Jason.encode!() |> Base.encode64()
    args = ["claim-ticket-mr-owner", "request", "--source-thread-id", "broker", "--payload-base64", payload, "--workflow", ctx.workflow]

    executor = fn received, _, _ ->
      assert received == args
      send(caller, :mr_owner_serviced)
      {:ok, %{"status" => "FOLLOWUP_UNCERTAIN", "arguments" => %{"threadId" => "controller"}}}
    end

    start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil, executor: executor})
    assert BrokerRuntime.bridged?(args)
    assert {:ok, %{"status" => "FOLLOWUP_UNCERTAIN"}} = BrokerRuntime.call(args)
    assert_receive :mr_owner_serviced
    refute BrokerRuntime.bridged?(["claim-ticket-mr-interactive", "request"])
    refute BrokerRuntime.bridged?(["claim-ticket-mr", "request"])
  end

  test "ticket preparation uses the service mailbox and rejects another workflow", ctx do
    caller = self()

    executor = fn args, _, _ ->
      send(caller, {:prepared_by_service, args})
      {:ok, %{"status" => "PREPARED_ONLY", "staged" => false}}
    end

    start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil, executor: executor})
    args = ["prepare-ticket-stage", "run", "--workflow", ctx.workflow]
    assert BrokerRuntime.bridged?(args)
    assert {:ok, %{"status" => "PREPARED_ONLY", "staged" => false}} = BrokerRuntime.call(args)
    assert_receive {:prepared_by_service, ^args}
    store = start_supervised!({SymphonyElixir.Factory.Store, database: ctx.factory.database})
    assert {:error, :ticket_runtime_preparation_forbidden} = Mix.Tasks.Factory.Ticket.runtime_prepare(args, store, ctx.factory)
    assert {:error, :ticket_runtime_preparation_forbidden} = Mix.Tasks.Factory.Ticket.runtime_prepare(["stage", "run"], store, ctx.factory)
  end

  test "service rejects arbitrary keys routes and workflow paths before execution", ctx do
    store = start_supervised!({SymphonyElixir.Factory.Store, database: ctx.factory.database})
    assert {:error, :broker_runtime_operation_forbidden} = Mix.Tasks.Factory.Desktop.runtime_operation(["claim", "unknown", "--workflow", ctx.workflow], store, ctx.factory)
    assert {:error, :broker_runtime_operation_forbidden} = Mix.Tasks.Factory.Desktop.runtime_operation(["list", "--workflow", ctx.workflow], store, ctx.factory)
  end

  test "restart marks interrupted runtime operation uncertain without replay", ctx do
    {:ok, root} = BrokerRuntime.root(ctx.factory.database)
    File.mkdir_p!(root)
    id = String.duplicate("a", 32)
    File.write!(Path.join(root, id <> ".running"), Jason.encode!(%{"args" => ["claim", "request"]}))
    executor = fn _, _, _ -> flunk("interrupted operation must not replay") end
    start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil, executor: executor})
    assert Jason.decode!(File.read!(Path.join(root, id <> ".response"))) == %{"error" => ":broker_runtime_outcome_uncertain"}
    assert File.exists?(Path.join(root, id <> ".finished"))
  end

  test "restart preserves an already published result", ctx do
    {:ok, root} = BrokerRuntime.root(ctx.factory.database)
    File.mkdir_p!(root)
    id = String.duplicate("b", 32)
    File.write!(Path.join(root, id <> ".running"), "{}")
    result = Jason.encode!(%{"ok" => %{"status" => "CREATE_UNCERTAIN"}})
    File.write!(Path.join(root, id <> ".response"), result)
    start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil})
    assert File.read!(Path.join(root, id <> ".response")) == result
  end

  test "reintroduced completed mailbox ID cannot replay an operation", ctx do
    {:ok, root} = BrokerRuntime.root(ctx.factory.database)
    File.mkdir_p!(root)
    id = String.duplicate("f", 32)
    File.write!(Path.join(root, id <> ".finished"), "{}")
    File.write!(Path.join(root, id <> ".response"), Jason.encode!(%{"ok" => "original receipt"}))
    File.write!(Path.join(root, id <> ".pending"), Jason.encode!(%{"args" => ["claim", "request"], "expires_at" => System.system_time(:millisecond) + 50_000}))
    executor = fn _, _, _ -> flunk("completed mailbox ID must not replay") end
    server = start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil, executor: executor})
    :sys.get_state(server)
    assert File.exists?(Path.join(root, id <> ".duplicate"))
    assert Jason.decode!(File.read!(Path.join(root, id <> ".response"))) == %{"ok" => "original receipt"}
  end

  test "restart rejects a linked response without replacing it or modifying its target", ctx do
    {:ok, root} = BrokerRuntime.root(ctx.factory.database)
    File.mkdir_p!(root)
    id = String.duplicate("0", 32)
    File.write!(Path.join(root, id <> ".running"), "{}")
    File.ln_s!(ctx.workflow, Path.join(root, id <> ".response"))
    before = File.read!(ctx.workflow)
    start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil})
    assert File.read!(ctx.workflow) == before
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(root, id <> ".response"))
    assert File.exists?(Path.join(root, id <> ".running"))
    refute File.exists?(Path.join(root, id <> ".finished"))
  end

  test "symlink mailbox roots are rejected rather than normalized", ctx do
    external = Path.join(ctx.root, "external")
    File.mkdir_p!(external)
    File.ln_s!(external, Path.join(ctx.root, "broker-runtime"))
    assert {:error, :broker_runtime_root_mismatch} = BrokerRuntime.root(ctx.factory.database)
  end

  test "interrupted response publication does not prevent restart reconciliation", ctx do
    {:ok, root} = BrokerRuntime.root(ctx.factory.database)
    File.mkdir_p!(root)
    id = String.duplicate("1", 32)
    File.write!(Path.join(root, id <> ".running"), "{}")
    File.write!(Path.join(root, id <> ".response.writing"), "unfinished")
    start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil})
    assert Jason.decode!(File.read!(Path.join(root, id <> ".response"))) == %{"error" => ":broker_runtime_outcome_uncertain"}
  end

  test "expired malformed and symlink requests never execute", ctx do
    {:ok, root} = BrokerRuntime.root(ctx.factory.database)
    File.mkdir_p!(root)

    for {id, body} <- [{"c", %{"args" => ["claim", "request"], "expires_at" => 0}}, {"d", %{}}] do
      File.write!(Path.join(root, String.duplicate(id, 32) <> ".pending"), Jason.encode!(body))
    end

    File.ln_s!(ctx.workflow, Path.join(root, String.duplicate("e", 32) <> ".pending"))
    executor = fn _, _, _ -> flunk("invalid request must not execute") end
    server = start_supervised!({BrokerRuntime, factory: ctx.factory, name: nil, executor: executor})
    send(server, :poll)
    send(server, :poll)
    :sys.get_state(server)

    for id <- ~w(c d e) do
      assert Jason.decode!(File.read!(Path.join(root, String.duplicate(id, 32) <> ".response"))) == %{"error" => ":broker_runtime_request_invalid_or_expired"}
    end
  end
end
