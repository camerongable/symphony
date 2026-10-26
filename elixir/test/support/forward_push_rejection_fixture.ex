defmodule SymphonyElixir.TestSupport.ForwardPushRejectionFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias SymphonyElixir.Factory.{Store, TicketPushOrdinaryRejection, Worktree}
  alias SymphonyElixir.TestSupport.OrdinaryPushRejectionFixture, as: Rejection

  def boot(root, source) do
    app = Path.join(root, "private-app/lib/symphony_elixir")
    private = Path.join(root, "source")
    File.mkdir_p!(app)
    File.mkdir_p!(private)
    File.cp_r!(Path.join(Application.app_dir(:symphony_elixir), "ebin"), Path.join(app, "ebin"))
    for target <- [app, private], do: File.cp_r!(Path.join(source, "priv"), Path.join(target, "priv"))
    File.cp_r!(Path.join(source, "lib"), Path.join(private, "lib"))
    Application.put_env(:symphony_elixir, :ordinary_rejection_private_fixture, %{app: app, source: private})
    Rejection.activate()
    select_capability(24)
  end

  def seed_closed_prefix(ctx, run) do
    ordinary = %{"kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1"}
    binding = Map.take(run, ~w(state candidate_sha code_repair_round verifier_round spec_revision contract_sha256))
    binding = Map.merge(binding, %{"candidate_sha" => String.duplicate("1", 40), "code_repair_round" => 1, "ordinary_verifier_repair" => ordinary})
    first = historical(ctx, binding, 1, nil)
    second = historical(ctx, Map.put(binding, "ordinary_preissuance_retirement", first), 2, first)
    select_capability(24)
    records = records(ctx.store)
    assert length(records) == 2
    for record <- records, do: assert({:ok, _} = TicketPushOrdinaryRejection.validate_record(ctx.store, record))
    assert TicketPushOrdinaryRejection.current(ctx.store, run, %{}, Map.delete(binding, "ordinary_preissuance_retirement")) == :ok
    assert first != second
    IO.puts("FORWARD_REJECTION_TWO_CLOSED_CONTEXTS_VALIDATED")
  end

  def install(ctx, run, intent, raw) do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    execution = Jason.decode!(intent["execution_json"])
    binding = Jason.decode!(intent["binding_json"])
    assert Path.basename(execution["helper_path"]) == "ticket_push_executor_v24.py"
    assert Jason.decode!(raw)["reason"] == "worker_history_changed"
    assert Jason.decode!(raw)["child_pid"] == nil
    assert binding["ordinary_preissuance_retirement"] == nil
    {:ok, remote} = Worktree.read_remote_branch(%{"path" => ctx.repo}, run["branch"])
    prefix = Enum.map(records(ctx.store), &identity/1)
    audit = Map.take(run, ~w(run_id candidate_sha contract_sha256 code_repair_round))
    audit = Map.merge(audit, Map.take(execution, ~w(helper_path helper_sha256 companion_path companion_sha256)))

    audit =
      Map.merge(audit, %{
        "version" => 3,
        "kind" => "AUDITED_V24_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED",
        "original_sha256" => hash(run["candidate_handoff"]),
        "original_nonce" => intent["owner_nonce"],
        "helper_pid" => intent["helper_pid"],
        "execution_sha256" => hash(intent["execution_json"]),
        "rejection_sha256" => hash(raw),
        "reason" => "worker_history_changed",
        "expected_remote_sha" => remote,
        "ordinary_verifier_repair_sha256" => hash(Jason.encode!(binding["ordinary_verifier_repair"])),
        "prior_retirement_ref" => nil,
        "closed_prior_retirements" => prefix,
        "current_context" => Map.take(binding, ~w(state candidate_sha code_repair_round verifier_round spec_revision contract_sha256))
      })

    install_resource(fixture, 3, audit)
    select_capability(26)
    assert TicketPushOrdinaryRejection.eligible?(run)
    assert {:ok, _} = TicketPushOrdinaryRejection.closed_authority(run, intent)
    IO.puts("FORWARD_REJECTION_REAL_V24_REJECTED_WITHOUT_GIT")
  end

  defp historical(ctx, binding, version, prior) do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    binding_raw = Jason.encode!(binding)
    access_key = "ticket-push:" <> hash(binding_raw)
    generation = 10_000 + version

    access = %{
      "reservation_key" => access_key,
      "run_id" => "run",
      "task_key" => nil,
      "request_key" => "forward-historical-#{version}",
      "mode" => "MAINTENANCE",
      "generation" => generation,
      "canonical_path" => ctx.path,
      "git_dir" => Path.join(ctx.path, ".git"),
      "common_dir" => Path.join(ctx.path, ".git"),
      "binding_json" => "{}",
      "acquired_at" => "2026-01-01T00:00:00Z",
      "released_at" => nil,
      "release_receipt_json" => nil
    }

    invocation = if version == 1, do: hash("historical-first"), else: hash(prior["retirement_key"] <> ":successor:1")
    execution = Jason.encode!(%{"invocation" => invocation, "intent_json" => binding_raw, "intent_sha256" => hash(binding_raw)})

    original =
      Jason.encode!(%{
        "phase" => "PUSH_UNCERTAIN",
        "owner_nonce" => invocation,
        "helper_pid" => 2_000_000_000 + version,
        "execution_json" => execution,
        "binding_json" => binding_raw,
        "binding_sha256" => hash(binding_raw),
        "reservation_key" => access_key,
        "reservation_generation" => generation,
        "receipt_json" => nil,
        "receipt_sha256" => nil,
        "remote_sha" => nil
      })

    rejection =
      Jason.encode!(%{
        "version" => 1,
        "kind" => "PREISSUANCE_REJECTED",
        "execution_json" => execution,
        "helper_pid" => 2_000_000_000 + version,
        "child_pid" => nil,
        "reason" => "synthetic_historical_rejection"
      })

    kind = if version == 1, do: "AUDITED_V15_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED", else: "AUDITED_V16_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED"

    audit = %{
      "version" => version,
      "kind" => kind,
      "run_id" => "run",
      "original_sha256" => hash(original),
      "original_nonce" => invocation,
      "helper_pid" => 2_000_000_000 + version,
      "execution_sha256" => hash(execution),
      "rejection_sha256" => hash(rejection),
      "reason" => "synthetic_historical_rejection",
      "prior_retirement_ref" => prior,
      "ordinary_verifier_repair_sha256" => hash(Jason.encode!(binding["ordinary_verifier_repair"]))
    }

    audit_sha = install_resource(fixture, version, audit)

    value = %{
      "version" => 1,
      "kind" => "ORDINARY_PUSH_REJECTION_RETIREMENT_V1",
      "run_id" => "run",
      "retirement_key" => "ordinary-push-rejection:" <> hash(original <> hash(rejection)),
      "original_envelope" => original,
      "original_sha256" => hash(original),
      "original_nonce" => invocation,
      "prior_access_sha256" => hash(Jason.encode!(access)),
      "proof" => %{"kind" => kind, "audit_sha256" => audit_sha, "rejection_sha256" => hash(rejection), "rejection_json" => rejection}
    }

    raw = Jason.encode!(value)

    [[id]] =
      Store.query!(ctx.store, "INSERT INTO events(event_type,run_id,payload_json,occurred_at) VALUES(?,?,?,?) RETURNING id", [
        "TICKET_ORDINARY_PUSH_REJECTION_RETIRED",
        "run",
        raw,
        "2026-01-01T00:00:00Z"
      ]).rows

    access = Map.merge(access, %{"released_at" => "2026-01-01T00:00:00Z", "release_receipt_json" => raw})
    columns = Map.keys(access)
    Store.query!(ctx.store, "INSERT INTO workspace_access(" <> Enum.join(columns, ",") <> ") VALUES(" <> Enum.map_join(columns, ",", fn _ -> "?" end) <> ")", Enum.map(columns, &access[&1]))
    identity(%{"id" => id, "payload_json" => raw})
  end

  defp install_resource(fixture, version, audit) do
    name = "ticket_push_ordinary_rejection_v#{version}.json"
    old_sha = hash(File.read!(Path.join(fixture.app, "priv/" <> name)))
    raw = Jason.encode!(audit)
    histories = if version in [1, 2], do: [19, 20], else: [20]

    for root <- [fixture.app, fixture.source] do
      File.write!(Path.join(root, "priv/" <> name), raw)

      for history <- histories do
        path = Path.join(root, "priv/ticket_push_history_validator_v#{history}.py")
        text = File.read!(path)
        assert length(String.split(text, old_sha)) == 2
        File.write!(path, String.replace(text, old_sha, hash(raw)))
      end
    end

    hash(raw)
  end

  defp select_capability(version) do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    filename = Path.join(fixture.source, "lib/symphony_elixir/factory/ticket_push_io.ex")
    text = File.read!(filename)

    text =
      if version == 24 do
        text
        |> String.replace("defp helper_name(:capability), do: \"ticket_push_executor_v26.py\"", "defp helper_name(:capability), do: \"ticket_push_executor_v24.py\"")
        |> String.replace("defp helper_sha(:capability), do: @current_review_capability_helper_sha", "defp helper_sha(:capability), do: @review_capability_helper_sha")
        |> String.replace(
          "defp history_program(:capability), do: {\"ticket_push_history_validator_v20.py\", @current_review_history_sha}",
          "defp history_program(:capability), do: {\"ticket_push_history_validator_v19.py\", @review_history_sha}"
        )
      else
        text
      end

    Code.compile_string(text, filename)
    recompile()
  end

  defp recompile do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    Code.compile_file(Path.join(fixture.source, "lib/symphony_elixir/factory/ticket_push_ordinary_rejection.ex"))
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
