defmodule SymphonyElixir.FactoryPushUnattachedRetirementTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Factory.{Control, Store, TicketPushUnattachedRetirement}

  test "equal empty snapshots and an unreviewed replacement cannot prove shutdown" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    File.chmod!(ctx.root, 0o700)
    audit_path = Application.app_dir(:symphony_elixir, "priv/ticket_push_unattached_audit_v1.json")
    audit_raw = File.read!(audit_path)
    audit = Jason.decode!(audit_raw)
    empty = Path.join(ctx.root, "empty-snapshot")
    File.write!(empty, "")
    File.chmod!(empty, 0o600)
    hash = fn raw -> Base.encode16(:crypto.hash(:sha256, raw), case: :lower) end

    proof = %{
      "version" => 1,
      "kind" => "OWNED_UNATTACHED_ISSUER_SHUTDOWN",
      "audit_sha256" => hash.(audit_raw),
      "issuer" => audit["issuer"],
      "original_envelope_sha256" => audit["original_envelope_sha256"],
      "replacement_launcher" => audit["replacement_launcher"],
      "replacement_build" => audit["replacement_build"],
      "replacement_manifest" => audit["replacement_manifest"],
      "protected_before_path" => empty,
      "protected_after_path" => empty,
      "protected_before_sha256" => hash.(""),
      "protected_after_sha256" => hash.("")
    }

    receipt = Path.join(ctx.root, "shutdown-receipt")
    File.write!(receipt, Jason.encode!(proof))
    File.chmod!(receipt, 0o600)
    assert {:error, :unattached_retirement_history_changed} = TicketPushUnattachedRetirement.verify_shutdown_fence(receipt, hash.(File.read!(receipt)))
    File.write!(receipt, Jason.encode!(Map.put(proof, "replacement_launcher", "/unreviewed/old-launcher")))
    assert {:error, :unattached_retirement_replacement_changed} = TicketPushUnattachedRetirement.verify_shutdown_fence(receipt, hash.(File.read!(receipt)))
  end

  test "retirement requires an owned live tick before reading a shutdown receipt" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    frozen = Store.query!(ctx.store, "SELECT * FROM events").rows
    sha = String.duplicate("a", 64)
    operation = %{run_id: "run", nonce: sha, envelope_sha256: sha}
    receipt = %{path: "/missing", sha256: sha}

    assert {:error, :push_recovery_operator_tick_unproven} =
             TicketPushUnattachedRetirement.prepare(ctx.store, operation, receipt, %{}, [])

    assert {:error, :push_recovery_operator_tick_unproven} =
             TicketPushUnattachedRetirement.execute(ctx.store, operation, receipt, sha, %{}, [])

    assert {:error, :push_recovery_operator_tick_unproven} =
             TicketPushUnattachedRetirement.prepare_preissuance(ctx.store, operation, receipt, %{}, [])

    assert {:error, :push_recovery_operator_tick_unproven} =
             TicketPushUnattachedRetirement.execute_preissuance(ctx.store, operation, receipt, sha, %{}, [])

    assert Store.query!(ctx.store, "SELECT * FROM events").rows == frozen

    assert {:ok, :ok} =
             Exqlite.transaction(ctx.store, fn tx ->
               assert {:error, :workspace_observation_inside_transaction} =
                        TicketPushUnattachedRetirement.prepare(tx, operation, receipt, %{}, [])

               assert {:error, :workspace_observation_inside_transaction} =
                        TicketPushUnattachedRetirement.prepare_preissuance(tx, operation, receipt, %{}, [])

               :ok
             end)
  end

  test "a live lease does not authorize an unaudited ledger or mutate its history" do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    config = %{scope: "unattached-fixture", dispatcher_id: "fixture", lease_seconds: 240}
    Control.initialize(ctx.store, config)
    assert {:ok, _} = Control.activate(ctx.store, config, config.dispatcher_id)
    assert %{result: "ACQUIRED"} = Control.acquire_tick(ctx.store, config, config.dispatcher_id)
    tick = Control.status(ctx.store, config.scope) |> Map.take(~w(scope dispatcher_id generation tick_id))
    before = Enum.map(~w(runs events workspace_access), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows)
    sha = String.duplicate("a", 64)
    operation = %{run_id: "run", nonce: sha, envelope_sha256: sha}
    receipt = %{path: "/missing", sha256: sha}
    assert {:error, :unattached_retirement_protected_history_changed} = TicketPushUnattachedRetirement.check_protected_history(ctx.store)

    assert {:error, :unattached_retirement_protected_history_changed} =
             TicketPushUnattachedRetirement.prepare(ctx.store, operation, receipt, %{}, operator_tick: tick)

    assert Enum.map(~w(runs events workspace_access), &Store.query!(ctx.store, "SELECT * FROM #{&1}").rows) == before
  end
end
