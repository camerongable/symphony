defmodule SymphonyElixir.TestSupport.OrdinaryPushRejectionFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketPushIO, TicketPushOrdinaryRejection, Worktree}

  def boot(root, source) do
    app = Path.join(root, "private-app/lib/symphony_elixir")
    File.mkdir_p!(app)
    original = Application.app_dir(:symphony_elixir)
    File.cp_r!(Path.join(original, "ebin"), Path.join(app, "ebin"))
    File.cp_r!(Path.join(source, "priv"), Path.join(app, "priv"))
    private = Path.join(root, "source")
    File.mkdir_p!(private)
    File.cp_r!(Path.join(source, "priv"), Path.join(private, "priv"))
    File.cp_r!(Path.join(source, "lib"), Path.join(private, "lib"))
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(app, "ebin")))
    assert Application.app_dir(:symphony_elixir) == app
    Application.put_env(:symphony_elixir, :ordinary_rejection_private_fixture, %{app: app, source: private})
    filename = Path.join(private, "lib/symphony_elixir/factory/ticket_push_io.ex")

    old =
      File.read!(filename)
      |> String.replace("ticket_push_executor_v17.py", "ticket_push_executor_v15.py")
      |> String.replace("ticket_push_history_validator_v14.py", "ticket_push_history_validator_v12.py")

    Code.compile_string(old, filename)
    IO.puts("ORDINARY_REJECTION_PRIVATE_OLD_CODEC")
  end

  def install(ctx, run, intent, rejection) do
    install_audit(ctx, run, intent, rejection, 1)
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)

    for root <- [fixture.app, fixture.source] do
      path = Path.join(root, "priv/ticket_push_history_validator_v13.py")
      text = File.read!(path)
      marker = "def ordinary_generation(connection, execution, binding, run, go_paths, present_go):\n"
      assert length(String.split(text, marker)) == 2
      File.write!(path, String.replace(text, marker, marker <> "    if binding.get('ordinary_preissuance_retirement'): raise ValueError('ci_evidence_successor_changed')\n"))
    end

    filename = Path.join(fixture.source, "lib/symphony_elixir/factory/ticket_push_io.ex")

    text =
      File.read!(filename)
      |> String.replace("ticket_push_executor_v17.py", "ticket_push_executor_v16.py")
      |> String.replace("ticket_push_history_validator_v14.py", "ticket_push_history_validator_v13.py")

    Code.compile_string(text, filename)
  end

  def install_second(ctx, run, intent, rejection), do: install_audit(ctx, run, intent, rejection, 2)

  defp install_audit(ctx, run, intent, rejection, version) do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    assert Application.app_dir(:symphony_elixir) == fixture.app
    {:ok, remote} = Worktree.read_remote_branch(%{"path" => ctx.repo}, run["branch"])
    execution = Jason.decode!(intent["execution_json"])
    binding = Jason.decode!(intent["binding_json"])
    assert Path.basename(execution["helper_path"]) == if(version == 1, do: "ticket_push_executor_v15.py", else: "ticket_push_executor_v16.py")
    assert Jason.decode!(rejection)["child_pid"] == nil
    audit = Map.take(run, ~w(run_id candidate_sha contract_sha256 code_repair_round)) |> Map.merge(Map.take(execution, ~w(helper_path helper_sha256 companion_path companion_sha256)))

    audit =
      Map.merge(audit, %{
        "version" => version,
        "kind" => if(version == 1, do: "AUDITED_V15_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED", else: "AUDITED_V16_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"),
        "original_sha256" => hash(run["candidate_handoff"]),
        "original_nonce" => intent["owner_nonce"],
        "helper_pid" => intent["helper_pid"],
        "execution_sha256" => hash(intent["execution_json"]),
        "rejection_sha256" => hash(rejection),
        "reason" => Jason.decode!(rejection)["reason"],
        "expected_remote_sha" => remote,
        "ordinary_verifier_repair_sha256" => hash(Jason.encode!(binding["ordinary_verifier_repair"]))
      })

    audit = if version == 2, do: Map.put(audit, "prior_retirement_ref", binding["ordinary_preissuance_retirement"]), else: audit

    name = "ticket_push_ordinary_rejection_v#{version}.json"
    old_path = Path.join(fixture.app, "priv/" <> name)
    old_sha = hash(File.read!(old_path))
    for root <- [fixture.app, fixture.source], do: File.write!(Path.join(root, "priv/" <> name), Jason.encode!(audit))
    new_sha = hash(File.read!(old_path))

    for root <- [fixture.app, fixture.source], history <- if(version == 1, do: [13, 14], else: [14]) do
      path = Path.join(root, "priv/ticket_push_history_validator_v#{history}.py")
      text = File.read!(path)
      assert length(String.split(text, old_sha)) == 2
      File.write!(path, String.replace(text, old_sha, new_sha))
    end

    for name <- ~w(ticket_push_ordinary_rejection ticket_push_io), do: Code.compile_file(Path.join(fixture.source, "lib/symphony_elixir/factory/#{name}.ex"))
    assert TicketPushOrdinaryRejection.eligible?(run)
    assert {:ok, _} = TicketPushOrdinaryRejection.closed_authority(run, intent)
    IO.puts("ORDINARY_REJECTION_PRIVATE_CURRENT_CODEC")
  end

  def activate do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(fixture.app, "ebin")))
    assert Application.app_dir(:symphony_elixir) == fixture.app
  end

  def before_rearm(ctx, run) do
    before = protected(ctx.store)
    assert {:error, :push_rejection_normal_tick_required} = TicketPushOrdinaryRejection.rearm(ctx.store, "run", %{}, [])
    assert protected(ctx.store) == before
    Store.query!(ctx.store, "CREATE TRIGGER ordinary_fixture_cas BEFORE UPDATE OF candidate_handoff ON runs WHEN NEW.run_id='run' BEGIN SELECT RAISE(IGNORE); END")
    run
  end

  def assert_rollback(store, before) do
    assert protected(store) == before
    Store.query!(store, "DROP TRIGGER ordinary_fixture_cas")
  end

  def protected(store),
    do: Enum.map(~w(runs workspace_access events sqlite_sequence ticket_ci_repair_claims ticket_ci_repair_evidence_successors), &Store.query!(store, "SELECT * FROM #{&1} ORDER BY 1").rows)

  def assert_retired(ctx, prior, count \\ 1) do
    assert {:ok, run} = RunLedger.get(ctx.store, "run")
    intent = Jason.decode!(run["candidate_handoff"])
    old = Jason.decode!(prior["candidate_handoff"])
    assert intent["phase"] == "PREPARED" and intent["owner_nonce"] != old["owner_nonce"]
    assert Enum.all?(~w(helper_pid execution_json receipt_json receipt_sha256 remote_sha), &is_nil(intent[&1]))
    assert Map.take(run, ~w(candidate_sha implementation_iteration code_repair_round verifier_round)) == Map.take(prior, ~w(candidate_sha implementation_iteration code_repair_round verifier_round))
    assert Store.one!(ctx.store, "SELECT COUNT(*) AS n FROM events WHERE event_type='TICKET_ORDINARY_PUSH_REJECTION_RETIRED'")["n"] == count
    assert {:ok, before_raw} = TicketPushIO.readback(old)
    assert Jason.decode!(before_raw)["child_pid"] == nil
    assert {:ok, reader} = Store.start_read_only(database: ctx.database)
    binding = Jason.decode!(intent["binding_json"])
    assert TicketPushOrdinaryRejection.current(reader, run, intent, binding) == :ok
    assert TicketPushOrdinaryRejection.bind(reader, run, Map.delete(binding, "ordinary_preissuance_retirement")) == binding

    for ref <- [%{}, Map.put(binding["ordinary_preissuance_retirement"], "event_sha256", String.duplicate("0", 64))] do
      assert {:error, _} = TicketPushOrdinaryRejection.current(reader, run, intent, Map.put(binding, "ordinary_preissuance_retirement", ref))
    end

    if count == 2 do
      stale = Jason.decode!(old["binding_json"])
      assert {:error, _} = TicketPushOrdinaryRejection.current(reader, run, intent, stale)
    end

    GenServer.stop(reader)
    IO.puts("ORDINARY_REJECTION_RETIRED_WITHOUT_ISSUANCE")
    run
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
