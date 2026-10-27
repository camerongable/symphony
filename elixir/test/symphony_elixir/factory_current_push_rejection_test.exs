defmodule SymphonyElixir.FactoryCurrentPushRejectionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Factory.Store

  test "the exact v34 retirement validates three closed contexts across a read-only reopen" do
    fixture = fixture()
    before = records(fixture.store)
    assert {:ok, _} = fixture.module.validate_record(fixture.store, List.last(before))
    for record <- before, do: assert({:ok, _} = fixture.module.validate_record(fixture.store, record))
    assert {:ok, reader} = Store.start_read_only(database: fixture.database)
    assert {:ok, _} = fixture.module.validate_record(reader, List.last(before))
    assert records(reader) == before
    GenServer.stop(reader)
  end

  test "changed exact retirement evidence or a sealed historical row cannot become valid" do
    fixture = fixture()
    before = records(fixture.store)

    mutations = [
      fn value -> Map.put(value, "original_nonce", String.duplicate("f", 64)) end,
      fn value -> Map.put(value, "original_sha256", String.duplicate("f", 64)) end,
      fn value -> put_in(value, ["proof", "rejection_sha256"], String.duplicate("f", 64)) end,
      fn value -> put_in(value, ["proof", "audit_sha256"], String.duplicate("f", 64)) end,
      fn value -> put_in(value, ["proof", "kind"], "AUDITED_V24_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED") end,
      fn value ->
        original = Jason.decode!(value["original_envelope"])
        Map.put(value, "original_envelope", Jason.encode!(Map.put(original, "helper_pid", 1)))
      end,
      fn value ->
        rejected = Jason.decode!(value["proof"]["rejection_json"])
        put_in(value, ["proof", "rejection_json"], Jason.encode!(Map.put(rejected, "child_pid", 123)))
      end
    ]

    for record <- [hd(before), List.last(before)], mutate <- mutations do
      assert {:error, :negative_fixture} =
               Exqlite.transaction(fixture.store, fn tx ->
                 raw = record["payload_json"] |> Jason.decode!() |> mutate.() |> Jason.encode!()
                 Store.query!(tx, "UPDATE events SET payload_json=? WHERE id=?", [raw, record["id"]])
                 changed = List.last(records(tx))
                 assert {:error, :ordinary_rejection_lineage_changed} = fixture.module.validate_record(tx, changed)
                 Exqlite.rollback(tx, :negative_fixture)
               end)

      assert records(fixture.store) == before
    end
  end

  test "the literal v4 authorization and catalog resources are exact committed input assets" do
    source = Path.expand("../..", __DIR__)
    literal = File.read!(Path.join(source, "../plans/qualification/ppl-9881-rejection-v4.json"))
    assert File.read!(Path.join(source, "priv/ticket_push_ordinary_rejection_v4.json")) == literal
    audit = Jason.decode!(literal)
    assert audit["version"] == 4
    assert audit["kind"] == "AUDITED_V34_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"
    assert length(audit["closed_prior_retirements"]) == 3
    assert audit["prior_retirement_ref"] == nil
    assert audit["authorization_reference"] =~ "direct human instruction"
  end

  defp fixture do
    ctx = SymphonyElixir.TicketChatFixture.setup_fixture(%{})
    root = Path.join(ctx.root, "current-rejection-private")
    app = Path.join(root, "lib/symphony_elixir")
    File.mkdir_p!(app)
    original = Application.app_dir(:symphony_elixir)
    File.cp_r!(Path.join(original, "ebin"), Path.join(app, "ebin"))
    File.cp_r!(Path.join(original, "priv"), Path.join(app, "priv"))
    previous = String.to_charlist(Path.join(original, "ebin"))
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(app, "ebin")))
    on_exit(fn -> true = :code.replace_path(:symphony_elixir, previous) end)

    Enum.reduce(1..4, [], fn version, captured ->
      prior = if version == 2, do: identity(hd(captured)), else: nil
      context_number = if version <= 2, do: 1, else: version
      ordinary = %{"kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1"}

      context = %{
        "state" => "CI_PUSHING",
        "candidate_sha" => String.duplicate(Integer.to_string(context_number), 40),
        "code_repair_round" => context_number,
        "verifier_round" => context_number,
        "spec_revision" => 1,
        "contract_sha256" => String.duplicate("a", 64)
      }

      binding = Map.merge(context, %{"ordinary_verifier_repair" => ordinary})
      binding = if prior, do: Map.put(binding, "ordinary_preissuance_retirement", prior), else: binding
      binding_raw = Jason.encode!(binding)
      nonce = if prior, do: hash(prior["retirement_key"] <> ":successor:1"), else: hash("current-origin-#{version}")
      execution = Jason.encode!(%{"invocation" => nonce, "intent_json" => binding_raw, "intent_sha256" => hash(binding_raw)})

      original =
        Jason.encode!(%{
          "phase" => "PUSH_UNCERTAIN",
          "owner_nonce" => nonce,
          "helper_pid" => 2_000_000_000 + version,
          "execution_json" => execution,
          "binding_json" => binding_raw,
          "binding_sha256" => hash(binding_raw),
          "reservation_key" => "ticket-push:" <> hash(binding_raw),
          "reservation_generation" => version,
          "receipt_json" => nil,
          "receipt_sha256" => nil,
          "remote_sha" => nil
        })

      rejected = Jason.encode!(%{"version" => 1, "kind" => "PREISSUANCE_REJECTED", "execution_json" => execution, "helper_pid" => 2_000_000_000 + version, "child_pid" => nil, "reason" => "synthetic"})

      kind =
        Enum.at(
          [
            "AUDITED_V15_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED",
            "AUDITED_V16_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED",
            "AUDITED_V24_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED",
            "AUDITED_V34_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"
          ],
          version - 1
        )

      audit = %{
        "version" => version,
        "kind" => kind,
        "run_id" => "run",
        "original_sha256" => hash(original),
        "original_nonce" => nonce,
        "helper_pid" => 2_000_000_000 + version,
        "execution_sha256" => hash(execution),
        "rejection_sha256" => hash(rejected),
        "reason" => "synthetic",
        "prior_retirement_ref" => prior,
        "ordinary_verifier_repair_sha256" => hash(Jason.encode!(ordinary))
      }

      audit = if version in [3, 4], do: Map.merge(audit, %{"closed_prior_retirements" => Enum.map(captured, &identity/1), "current_context" => context}), else: audit
      audit_raw = Jason.encode!(audit)
      File.write!(Path.join(app, "priv/ticket_push_ordinary_rejection_v#{version}.json"), audit_raw)

      value = %{
        "version" => 1,
        "kind" => "ORDINARY_PUSH_REJECTION_RETIREMENT_V1",
        "run_id" => "run",
        "retirement_key" => "ordinary-push-rejection:" <> hash(original <> hash(rejected)),
        "original_envelope" => original,
        "original_sha256" => hash(original),
        "original_nonce" => nonce,
        "proof" => %{"kind" => kind, "audit_sha256" => hash(audit_raw), "rejection_sha256" => hash(rejected), "rejection_json" => rejected}
      }

      raw = Jason.encode!(value)
      [[id]] = Store.query!(ctx.store, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES('TICKET_ORDINARY_PUSH_REJECTION_RETIRED','run',?,'fixture') RETURNING id", [raw]).rows
      captured ++ [%{"id" => id, "payload_json" => raw}]
    end)

    source = Path.expand("../../lib/symphony_elixir/factory/ticket_push_ordinary_rejection.ex", __DIR__)
    module = Module.concat(__MODULE__, "Pinned#{System.unique_integer([:positive])}")
    filename = Path.join(app, "lib/symphony_elixir/factory/ticket_push_ordinary_rejection.ex")
    File.mkdir_p!(Path.dirname(filename))
    Code.compile_string(String.replace(File.read!(source), "defmodule SymphonyElixir.Factory.TicketPushOrdinaryRejection do", "defmodule #{inspect(module)} do", global: false), filename)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    %{store: ctx.store, database: ctx.database, module: module}
  end

  defp records(store) do
    result = Store.query!(store, "SELECT id,payload_json FROM events WHERE event_type='TICKET_ORDINARY_PUSH_REJECTION_RETIRED' ORDER BY id")
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp identity(record) do
    value = Jason.decode!(record["payload_json"])
    %{"event_id" => record["id"], "event_sha256" => hash(record["payload_json"]), "retirement_key" => value["retirement_key"], "original_sha256" => value["original_sha256"], "attempt" => 1}
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
