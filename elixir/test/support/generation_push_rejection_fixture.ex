defmodule SymphonyElixir.TestSupport.GenerationPushRejectionFixture do
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
    prepare_generation_origin(root)
    select_capability(34)
  end

  def seed_closed_prefix(ctx, run) do
    if records(ctx.store) == [] do
      seed_prefix(ctx, run)
    end

    assert length(records(ctx.store)) == 3
    for record <- records(ctx.store), do: assert({:ok, _} = TicketPushOrdinaryRejection.validate_record(ctx.store, record))
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    current = retained_programs(fixture)

    case Application.get_env(:symphony_elixir, :generation_rejection_sealed_programs) do
      nil -> Application.put_env(:symphony_elixir, :generation_rejection_sealed_programs, current)
      prior -> assert current == prior
    end
  end

  defp seed_prefix(ctx, run) do
    ordinary = %{"kind" => "ORDINARY_VERIFIER_REPAIR_PREFLIGHT_V1"}
    binding = Map.take(run, ~w(state candidate_sha code_repair_round verifier_round spec_revision contract_sha256))
    binding = Map.merge(binding, %{"candidate_sha" => String.duplicate("1", 40), "code_repair_round" => 1, "ordinary_verifier_repair" => ordinary})
    first = historical(ctx, binding, 1, nil)
    second = historical(ctx, Map.put(binding, "ordinary_preissuance_retirement", first), 2, first)
    historical(ctx, Map.merge(binding, %{"candidate_sha" => String.duplicate("2", 40), "code_repair_round" => 2}), 3, nil)
    select_capability(34)
    records = records(ctx.store)
    assert length(records) == 3
    for record <- records, do: assert({:ok, _} = TicketPushOrdinaryRejection.validate_record(ctx.store, record))
    assert TicketPushOrdinaryRejection.current(ctx.store, run, %{}, Map.delete(binding, "ordinary_preissuance_retirement")) == :ok
    assert first != second
    IO.puts("GENERATION_REJECTION_THREE_CLOSED_CONTEXTS_VALIDATED")
  end

  defp prepare_generation_origin(root) do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    release = Path.join(root, "generation-a")
    app = Path.join(release, "dev/lib/symphony_elixir")
    File.mkdir_p!(app)
    File.cp_r!(Path.join(fixture.app, "ebin"), Path.join(app, "ebin"))
    File.cp_r!(Path.join(fixture.app, "priv"), Path.join(app, "priv"))
    names = ~w(controller_generation_executor_v2.py worker_file_companion.py)
    artifact = Map.new(names, &{"lib/symphony_elixir/priv/" <> &1, %{"sha256" => hash(File.read!(Path.join(app, "priv/" <> &1)))}})
    manifest = Jason.encode!(%{"kind" => "TEST_GENERATION_ORIGIN_V1", "release" => release, "artifact" => artifact})
    path = Path.join(release, "evidence/release-manifest.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, manifest)

    entry = %{
      "kind" => "RELEASE_GENERATION_ARTIFACT_V1",
      "release_root" => release,
      "manifest_path" => path,
      "manifest_sha256" => hash(manifest),
      "manifest_kind" => "TEST_GENERATION_ORIGIN_V1",
      "helper_path" => Path.join(app, "priv/controller_generation_executor_v2.py"),
      "helper_sha256" => artifact["lib/symphony_elixir/priv/controller_generation_executor_v2.py"]["sha256"],
      "companion_path" => Path.join(app, "priv/worker_file_companion.py"),
      "companion_sha256" => artifact["lib/symphony_elixir/priv/worker_file_companion.py"]["sha256"]
    }

    for target <- [fixture.app, fixture.source] do
      catalog = Path.join(target, "priv/ticket_generation_origins_v5.json")
      prior = File.read!(catalog)
      current = Jason.decode!(prior) |> Map.put("entries", [entry]) |> Jason.encode!()
      File.write!(catalog, current)
      history = Path.join(target, "priv/ticket_push_history_validator_v25.py")
      File.write!(history, String.replace(File.read!(history), hash(prior), hash(current)))
    end

    Application.put_env(:symphony_elixir, :generation_rejection_origin, app)
  end

  def activate_generation do
    app = Application.fetch_env!(:symphony_elixir, :generation_rejection_origin)
    true = :code.replace_path(:symphony_elixir, String.to_charlist(Path.join(app, "ebin")))
    IO.puts("GENERATION_REJECTION_SOURCE_A_OWNED_GENERATION")
  end

  def activate_publisher do
    Rejection.activate()
    IO.puts("GENERATION_REJECTION_PUBLISHER_B_RESTORED")
  end

  def proof_script do
    ~S'''
    import importlib.util,json,sqlite3,sys,pathlib
    d=json.load(open(sys.argv[1])); s=importlib.util.spec_from_file_location('producer',sys.argv[3]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
    c=sqlite3.connect('file:'+sys.argv[2]+'?mode=ro',uri=True); c.row_factory=sqlite3.Row; c.execute('PRAGMA query_only=ON')
    e,b,r=d['execution'],d['binding'],d['run']; p=b['ordinary_verifier_repair']
    h=pathlib.Path(e['history_program_path']); s=importlib.util.spec_from_file_location('codec',h); v=importlib.util.module_from_spec(s); s.loader.exec_module(v)
    output=json.loads(c.execute('SELECT output_json FROM worker_evidence WHERE request_key=?',(p['writer_request_key'],)).fetchone()[0])
    descendants=m.read_git(b['worktree'],['diff','--name-only','--no-renames',p['reviewed_candidate_sha']+'...'+p['source_parent_sha']],e).splitlines()
    go=sorted({name for name in descendants+output['changed_paths'] if name.endswith('.go')})
    present=m.read_git(b['worktree'],['ls-tree','-r','--name-only',b['candidate_sha'],'--']+go,e).splitlines() if go else []
    v.ordinary_generation(c,e,b,r,go,sorted(present))
    m.retained_history(c,e,b,r)
    assert c.total_changes==0
    print('GENERATION_REJECTION_UNWRAPPED_CURRENT_HISTORY_PASS')
    '''
  end

  def install(ctx, run, intent, raw) do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    execution = Jason.decode!(intent["execution_json"])
    binding = Jason.decode!(intent["binding_json"])
    assert Path.basename(execution["helper_path"]) == "ticket_push_executor_v34.py"
    assert Jason.decode!(raw)["reason"] == "ordinary_verifier_repair_unproven"
    assert Jason.decode!(raw)["child_pid"] == nil
    assert binding["ordinary_preissuance_retirement"] == nil
    assert retained_programs(fixture) == Application.fetch_env!(:symphony_elixir, :generation_rejection_sealed_programs)
    {:ok, remote} = Worktree.read_remote_branch(%{"path" => ctx.repo}, run["branch"])
    prefix = Enum.map(records(ctx.store), &identity/1)
    audit = Map.take(run, ~w(run_id candidate_sha contract_sha256 code_repair_round))
    audit = Map.merge(audit, Map.take(execution, ~w(helper_path helper_sha256 companion_path companion_sha256)))

    audit =
      Map.merge(audit, %{
        "version" => 4,
        "kind" => "AUDITED_V34_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED",
        "original_sha256" => hash(run["candidate_handoff"]),
        "original_nonce" => intent["owner_nonce"],
        "helper_pid" => intent["helper_pid"],
        "execution_sha256" => hash(intent["execution_json"]),
        "rejection_sha256" => hash(raw),
        "reason" => "ordinary_verifier_repair_unproven",
        "expected_remote_sha" => remote,
        "ordinary_verifier_repair_sha256" => hash(Jason.encode!(binding["ordinary_verifier_repair"])),
        "prior_retirement_ref" => nil,
        "closed_prior_retirements" => prefix,
        "current_context" => Map.take(binding, ~w(state candidate_sha code_repair_round verifier_round spec_revision contract_sha256))
      })

    install_resource(fixture, 4, audit)
    select_capability(36)
    assert retained_programs(fixture) == Application.fetch_env!(:symphony_elixir, :generation_rejection_sealed_programs)
    assert TicketPushOrdinaryRejection.eligible?(run)
    assert {:ok, _} = TicketPushOrdinaryRejection.closed_authority(run, intent)
    IO.puts("GENERATION_REJECTION_REAL_V34_REJECTED_WITHOUT_GIT")
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

    invocation = if prior, do: hash(prior["retirement_key"] <> ":successor:1"), else: hash("historical-#{version}")
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

    kind = Enum.at(~w(AUDITED_V15_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED AUDITED_V16_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED AUDITED_V24_ORDINARY_PREISSUANCE_AUTHORITY_CLOSED), version - 1)

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

    audit =
      if version == 3,
        do:
          Map.merge(audit, %{
            "closed_prior_retirements" => Enum.map(records(ctx.store), &identity/1),
            "current_context" => Map.take(binding, ~w(state candidate_sha code_repair_round verifier_round spec_revision contract_sha256))
          }),
        else: audit

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
    histories = [19, 20, 24, 25]

    for root <- [fixture.app, fixture.source] do
      File.write!(Path.join(root, "priv/" <> name), raw)

      for history <- histories do
        path = Path.join(root, "priv/ticket_push_history_validator_v#{history}.py")
        text = File.read!(path)
        assert length(String.split(text, old_sha)) in [1, 2]
        if String.contains?(text, old_sha), do: File.write!(path, String.replace(text, old_sha, hash(raw)))
      end
    end

    hash(raw)
  end

  defp select_capability(version) do
    fixture = Application.fetch_env!(:symphony_elixir, :ordinary_rejection_private_fixture)
    filename = Path.join(fixture.source, "lib/symphony_elixir/factory/ticket_push_io.ex")
    text = File.read!(filename)

    text =
      if version == 34 do
        text
        |> String.replace("defp helper_name(:capability), do: \"ticket_push_executor_v36.py\"", "defp helper_name(:capability), do: \"ticket_push_executor_v34.py\"")
        |> String.replace("defp helper_sha(:capability), do: @generation_publisher_capability_helper_sha", "defp helper_sha(:capability), do: @retained_publisher_capability_helper_sha")
        |> String.replace(":large -> \"ticket_push_executor_v35.py\"", ":large -> \"ticket_push_executor_v33.py\"")
        |> String.replace("defp helper_sha(:large), do: @generation_publisher_helper_sha", "defp helper_sha(:large), do: @retained_publisher_helper_sha")
        |> String.replace(
          "defp history_program(:large), do: {\"ticket_push_history_validator_v25.py\", @generation_publisher_history_sha}",
          "defp history_program(:large), do: {\"ticket_push_history_validator_v24.py\", @retained_publisher_history_sha}"
        )
        |> String.replace(
          "defp history_program(:capability), do: {\"ticket_push_history_validator_v25.py\", @generation_publisher_history_sha}",
          "defp history_program(:capability), do: {\"ticket_push_history_validator_v24.py\", @retained_publisher_history_sha}"
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

  defp retained_programs(fixture) do
    for root <- [fixture.app, fixture.source],
        name <- ~w(ticket_push_executor_v33.py ticket_push_executor_v34.py ticket_push_history_validator_v24.py),
        into: %{} do
      path = Path.join(root, "priv/" <> name)
      {path, File.read!(path)}
    end
  end

  defp identity(record) do
    value = Jason.decode!(record["payload_json"])
    %{"event_id" => record["id"], "event_sha256" => hash(record["payload_json"]), "retirement_key" => value["retirement_key"], "original_sha256" => value["original_sha256"], "attempt" => 1}
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
