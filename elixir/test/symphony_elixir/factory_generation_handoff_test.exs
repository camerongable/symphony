defmodule SymphonyElixir.FactoryGenerationHandoffTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.{Store, TicketCiGeneration, TicketCiGenerationIO, WorkerFileIO}

  test "new generation sessions have one confined executor" do
    assert {:ok, binding} = TicketCiGenerationIO.binding(System.tmp_dir!(), 6)
    assert Path.basename(binding["helper_path"]) == "controller_generation_executor_v6.py"
  end

  test "a recorded preview failure is read without executing the tool again" do
    root = Path.join(System.tmp_dir!(), "generation-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    store = start_supervised!({Store, database: Path.join(root, "factory.sqlite")})
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    assert {:ok, spool} = WorkerFileIO.controller_spool(store, source)
    assert {:ok, transport} = TicketCiGenerationIO.binding(source, 6)
    binding = Map.merge(spool, transport) |> Map.put("generation_version", 6)
    raw = Jason.encode!(binding)
    receipt = %{"version" => 1, "kind" => "CONTROLLER_GENERATION_FAILED", "reason" => "generation_tool_timeout", "binding_json" => raw, "helper_pid" => 999_999_999}
    File.write!(Path.join(spool["spool"], transport["invocation"] <> ".generation-claim"), raw)
    File.write!(Path.join(spool["spool"], transport["invocation"] <> ".generation-receipt"), Jason.encode!(receipt))
    assert {:ok, ^receipt} = TicketCiGenerationIO.status(binding, 999_999_999)
    assert {:ok, ^receipt} = TicketCiGenerationIO.status(binding, 999_999_999)
  end

  for {prefix, version} <- [{"ci", 1}, {"ordinary", 2}, {"ci", 3}] do
    @prefix prefix
    @version version
    test "interrupted preview is recoverable for #{@prefix} generation v#{@version}" do
      store = start_supervised!({Exqlite, database: ":memory:", pool_size: 1})

      for name <- ~w(ci ordinary) do
        Store.query!(store, "CREATE TABLE ticket_#{name}_generation_intents (intent_key TEXT, request_key TEXT, binding_json TEXT, binding_sha256 TEXT)")
        Store.query!(store, "CREATE TABLE ticket_#{name}_generation_events (event_key TEXT, intent_key TEXT, event_type TEXT, path TEXT, receipt_json TEXT, receipt_sha256 TEXT, created_at TEXT)")
      end

      key = "#{@prefix}-generation:fixture"
      raw = Jason.encode!(%{"kind" => "fixture"})
      Store.query!(store, "INSERT INTO ticket_#{@prefix}_generation_intents VALUES (?,?,?,?)", [key, "request", raw, hash(raw)])
      binding = %{"version" => 1, "intent_key" => key, "started_type" => "EXECUTION_STARTED", "proposal" => nil, "operation" => "GAZELLE_DIFF", "generation_version" => @version}
      prepared = Jason.encode!(binding)

      values = [
        {"EXECUTION_PREPARED", binding},
        {"EXECUTION_STARTED", %{"binding_json" => prepared, "helper_pid" => 999_999_999}},
        {"UNCERTAIN", %{"binding_sha256" => hash(prepared), "reason" => "OWNED_RECEIPT_UNPROVEN"}}
      ]

      for {type, value} <- values do
        encoded = Jason.encode!(value)
        event_key = "ci-generation-event:" <> hash(Jason.encode!([key, type, ""]))
        Store.query!(store, "INSERT INTO ticket_#{@prefix}_generation_events VALUES (?,?,?,'',?,?,?)", [event_key, key, type, encoded, hash(encoded), "2026-01-01T00:00:00Z"])
      end

      assert {:ok, %{intents: [intent]}} = TicketCiGeneration.readback(store, "request")
      assert intent.preview_retry.status == "AVAILABLE"
      raw = Jason.encode!(%{"version" => 1})
      Store.query!(store, "INSERT INTO ticket_#{@prefix}_generation_events VALUES (?,?,?,'BUILD',?,?,?)", ["uncertain-apply", key, "APPLY_PREPARED", raw, hash(raw), "2026-01-01T00:00:01Z"])
      assert {:ok, %{intents: [blocked]}} = TicketCiGeneration.readback(store, "request")
      assert blocked.preview_retry.status == "UNAVAILABLE"
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
