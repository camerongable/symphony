defmodule SymphonyElixir.FactoryCapabilityCodecTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Factory.Ticket, as: TicketCLI
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Factory.{BrokerRuntime, Store, TicketCapabilityRecovery, TicketPushIO}

  test "current capability codec is exact while legacy large payload origin remains supported" do
    programs = [{33, 24}, {34, 24}, {31, 23}, {32, 23}, {29, 22}, {30, 22}, {16, 13}, {15, 12}, {14, 11}]

    for {issuer, history} <- programs do
      helper = Application.app_dir(:symphony_elixir, "priv/ticket_push_executor_v#{issuer}.py")
      program = Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v#{history}.py")
      companion = Application.app_dir(:symphony_elixir, "priv/worker_file_companion.py")

      execution = %{
        "helper_path" => helper,
        "helper_sha256" => hash(File.read!(helper)),
        "history_program_path" => program,
        "history_program_sha256" => hash(File.read!(program)),
        "companion_path" => companion,
        "companion_sha256" => hash(File.read!(companion))
      }

      assert TicketPushIO.large_payload_origin?(execution)
      refute TicketPushIO.large_payload_origin?(Map.put(execution, "history_program_sha256", String.duplicate("0", 64)))
      refute TicketPushIO.large_payload_origin?(Map.put(execution, "history_program_path", Path.join(Path.dirname(program), "ticket_push_history_validator_v1.py")))
      refute TicketPushIO.large_payload_origin?(Map.put(execution, "helper_path", "/tmp/untrusted/" <> Path.basename(helper)))
      assert TicketPushIO.execution_size_valid?(Jason.encode!(Map.put(execution, "padding", String.duplicate("x", 270_000))))
    end

    origins = Application.app_dir(:symphony_elixir, "priv/ticket_push_readback_origins_v8.json") |> File.read!() |> Jason.decode!()
    entry = Enum.find(origins["entries"], &String.ends_with?(&1["helper_path"], "/ticket_push_executor_v14.py"))
    history = Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v11.py")
    execution = Map.take(entry, ~w(helper_path helper_sha256 companion_path companion_sha256))

    execution =
      Map.merge(execution, %{"history_program_path" => Path.join(Path.dirname(entry["helper_path"]), "ticket_push_history_validator_v11.py"), "history_program_sha256" => hash(File.read!(history))})

    assert TicketPushIO.large_payload_origin?(execution)
  end

  test "capability grant codec accepts the authenticated UTC producer format without broadening historical timestamps" do
    script = ~S"""
    import datetime, pathlib, sys, types
    path = pathlib.Path(sys.argv[1])
    module = types.ModuleType('grant_codec')
    exec(compile(path.read_bytes(), str(path), 'exec'), module.__dict__)
    cases = ['2026-10-22T05:27:44.994276Z', '2026-10-22T05:27:44.994276+00:00',
             '2026-10-22T05:27:44Z', '2026-10-22T05:27:44+00:00']
    for value in cases:
        assert module.capability_grant_utc(value).utcoffset() == datetime.timedelta(0)
    assert module.capability_grant_utc(cases[0]) == module.capability_grant_utc(cases[1])
    for value in [None, 0, '', '2026-10-22 05:27:44+00:00', '2026-10-22T05:27:44',
                  '2026-10-22T05:27:44-00:00', '2026-10-22T06:27:44+01:00',
                  '2026-02-30T05:27:44Z', '2026-10-22T25:27:44Z',
                  '2026-10-22T05:27:60Z', '2026-10-22T05:27:44.1234567Z',
                  '2026-10-22T05:27:44+00:00\n']:
        try:
            module.capability_grant_utc(value)
        except ValueError:
            pass
        else:
            raise AssertionError(repr(value))
    try:
        module.utc(cases[1])
    except ValueError:
        pass
    else:
        raise AssertionError('legacy timestamp parser was broadened')
    print('grant codec passed')
    """

    assert {"grant codec passed\n", 0} =
             System.cmd("/usr/bin/python3", ["-I", "-S", "-B", "-c", script, Application.app_dir(:symphony_elixir, "priv/ticket_push_history_validator_v14.py")], stderr_to_stdout: true)
  end

  test "public capability grammar rejects unrelated operations and forged authority shape" do
    assert {:error, :capability_recovery_authorization_invalid} = TicketCapabilityRecovery.stage(nil, %{}, %{}, [])
    assert {:error, :capability_recovery_authorization_invalid} = TicketCLI.runtime_capability_recovery([], nil, %{})
    assert BrokerRuntime.bridged?(["inspect-ticket-capability-runtime"])
    assert %{"pid" => pid, "modules" => modules} = TicketCapabilityRecovery.runtime_attestation()
    assert pid == System.pid() and map_size(modules) == 16
    assert modules["Elixir.SymphonyElixir.Codex.AppServer"]["loaded_path"] == to_string(:code.which(AppServer))
  end

  @tag :capability_production_only
  test "production beams ignore a valid private test grant selector" do
    root = Path.join(System.tmp_dir!(), "capability-artifact-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, database: Path.join(root, "factory.sqlite")})
    token = "artifact-only-#{System.unique_integer([:positive])}"

    input = %{
      "authorization_key" => token,
      "authorization_reference" => "local-operator:artifact-denial",
      "authorization_body" => "Synthetic artifact denial only",
      "run_id" => "synthetic",
      "request_key" => "synthetic",
      "turn_id" => "synthetic",
      "output_sha256" => String.duplicate("0", 64),
      "binding_sha256" => String.duplicate("0", 64),
      "candidate_sha" => String.duplicate("0", 40),
      "spec_revision" => 1,
      "contract_sha256" => String.duplicate("0", 64),
      "base_sha" => String.duplicate("0", 40),
      "base_paths" => ["synthetic.txt"]
    }

    grant = %{
      "version" => 1,
      "kind" => "CONTRACT_BASE_CAPABILITY_OPERATOR_GRANT_V1",
      "grant_id" => token,
      "nonce" => String.duplicate("0", 64),
      "authorization_sha256" => String.duplicate("0", 64),
      "binding_sha256" => String.duplicate("0", 64),
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "expires_at" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601(),
      "purpose" => "RESUME_EXACT_BASE_PREIMAGE_BLOCKED_WRITER",
      "capability_blockers" => ["Synthetic"],
      "base_paths" => input["base_paths"]
    }

    raw = Jason.encode!(grant)
    File.write!(Path.join(root, token <> ".json"), raw)
    File.chmod!(Path.join(root, token <> ".json"), 0o600)
    input = Map.merge(input, %{"grant_id" => token, "grant_sha256" => hash(raw)})

    assert {:error, :capability_recovery_grant_unproven} =
             TicketCapabilityRecovery.stage(store, input, %{}, grant_root: root)

    assert Store.query!(store, "SELECT * FROM events").rows == []
    assert File.read!(Path.join(root, token <> ".json")) == raw
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
