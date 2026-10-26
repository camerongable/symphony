defmodule SymphonyElixir.TestSupport.MrPresendFixture do
  @moduledoc false

  @spec build(Path.t(), map(), String.t(), Path.t()) :: module()
  def build(root, request, broker, cwd) do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(root)
    directory = Path.join(root, "presend-fixture")
    File.mkdir_p!(directory)
    path = Path.join(directory, "session.jsonl")
    incident = "fixture guard rejected before the fixture send"
    loader = "fixture canonical recovery loader"
    output = [%{"type" => "input_text", "text" => "COMMITTED_CLAIM_OUTPUT_INVALID"}]
    driver = Application.app_dir(:symphony_elixir, "priv/ticket_mr_broker_driver_v2.js") |> File.read!()

    policy = %{
      "session_path" => path,
      "broker_thread_id" => broker,
      "broker_cwd" => cwd,
      "launcher" => "/synthetic/elixir/scripts/factory-broker",
      "workflow" => "/synthetic/WORKFLOW.md",
      "current_driver" => %{"sha256" => digest(driver), "bytes" => byte_size(driver)},
      "incident" => %{
        "request_key" => request["request_key"],
        "claimed_at" => request["claimed_at"],
        "turn_id" => "incident",
        "call_id" => "incident-call",
        "input_at" => "input-at",
        "output_at" => "output-at",
        "input_sha256" => digest(incident),
        "input_bytes" => byte_size(incident),
        "output_sha256" => digest(Jason.encode!(output))
      },
      "recovery_loader" => %{"input_sha256" => digest(loader), "input_bytes" => byte_size(loader)},
      "approved_inputs" => %{}
    }

    event = fn kind, turn -> %{"type" => "event_msg", "payload" => %{"type" => kind, "turn_id" => turn}} end
    call = fn id, input, at -> %{"type" => "response_item", "timestamp" => at, "payload" => %{"type" => "custom_tool_call", "name" => "exec", "call_id" => id, "input" => input}} end

    records = [
      %{"type" => "session_meta", "payload" => %{"id" => broker, "cwd" => cwd, "originator" => "Codex Desktop", "source" => "vscode", "thread_source" => "agent_created_thread"}},
      event.("task_started", "incident"),
      call.("incident-call", incident, "input-at"),
      %{"type" => "response_item", "timestamp" => "output-at", "payload" => %{"type" => "custom_tool_call_output", "call_id" => "incident-call", "output" => output}},
      event.("task_complete", "incident"),
      event.("task_started", "recovery-turn"),
      call.("loader-call", loader, DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()),
      %{
        "type" => "event_msg",
        "payload" => %{
          "type" => "item_completed",
          "thread_id" => broker,
          "turn_id" => "recovery-turn",
          "started_at_ms" => System.system_time(:millisecond) - 600,
          "completed_at_ms" => System.system_time(:millisecond) - 500,
          "item" => %{
            "type" => "CommandExecution",
            "id" => "current-export",
            "command" => ["/bin/zsh", "-lc", policy["launcher"] <> " mr-driver"],
            "source" => "unified_exec_startup",
            "cwd" => "file:///synthetic/elixir",
            "status" => "completed",
            "exit_code" => 0,
            "aggregated_output" => Jason.encode!(%{version: 1, sha256: digest(driver), source: driver})
          }
        }
      },
      %{"type" => "response_item", "payload" => %{"type" => "custom_tool_call_output", "call_id" => "loader-call", "output" => "Script running with cell ID 1271\nWall time 1.0 seconds\nOutput:\n"}},
      %{
        "type" => "response_item",
        "payload" => %{"type" => "function_call", "name" => "wait", "call_id" => "wait-call", "arguments" => Jason.encode!(%{cell_id: "1271", yield_time_ms: 60_000, max_tokens: 1500})}
      }
    ]

    File.write!(path, Enum.map(records, &(Jason.encode!(&1) <> "\n")))
    registry = Jason.encode!(policy)
    File.write!(Path.join(directory, "ticket_mr_presend_registry_v3.json"), registry)
    source = Application.app_dir(:symphony_elixir, "priv/ticket_mr_presend_evidence_v3.py") |> File.read!()
    # The fixture changes only policy loading; the production bounded session parser remains exact.
    source = Regex.replace(~r/REGISTRY_SHA256 = "[a-f0-9]+"/, source, "REGISTRY_SHA256 = \"#{digest(registry)}\"")
    source = String.replace(source, "policy = registry()", "policy = json.loads(Path(__file__).with_name('ticket_mr_presend_registry_v3.json').read_text())")
    File.write!(Path.join(directory, "ticket_mr_presend_evidence_v3.py"), source)
    module = Module.concat(__MODULE__, "Reader#{System.unique_integer([:positive])}")
    adapter = Path.expand("../../lib/symphony_elixir/factory/ticket_mr_presend_evidence.ex", __DIR__) |> File.read!()
    adapter = String.replace(adapter, "defmodule SymphonyElixir.Factory.TicketMrPresendEvidence do", "defmodule #{inspect(module)} do")
    adapter = String.replace(adapter, "Path.expand(\"../../../priv/ticket_mr_presend_evidence_v3.py\", __DIR__)", inspect(Path.join(directory, "ticket_mr_presend_evidence_v3.py")))
    adapter = String.replace(adapter, "Path.expand(\"../../../priv/ticket_mr_presend_registry_v3.json\", __DIR__)", inspect(Path.join(directory, "ticket_mr_presend_registry_v3.json")))
    adapter = String.replace(adapter, "Application.app_dir(:symphony_elixir, \"priv/\" <> name)", "Path.join(#{inspect(directory)}, name)")
    observer = "SymphonyElixir.TestSupport.MrPresendFixture.host_observation(#{inspect(path)}, #{inspect(broker)}, #{inspect(cwd)}, "

    adapter =
      String.replace(
        adapter,
        "def read(request, broker, native), do: run(request, broker, native, nil)",
        "def read(request, broker, native) do\n#{observer}nil)\nrun(request, broker, native, nil)\nend"
      )

    adapter = String.replace(adapter, "run(request, broker, native, previous, context)", "#{observer}context)\nrun(request, broker, native, previous, context)")
    Code.compile_string(adapter)
    module
  end

  @spec host_observation(Path.t(), String.t(), Path.t(), map() | nil) :: :ok
  def host_observation(path, broker, cwd, context) do
    now = System.system_time(:millisecond) - 5
    id = Integer.to_string(System.unique_integer([:positive]))

    event = fn item, started, completed ->
      %{
        "type" => "event_msg",
        "payload" => %{"type" => "item_completed", "thread_id" => broker, "turn_id" => "recovery-turn", "started_at_ms" => started, "completed_at_ms" => completed, "item" => item}
      }
    end

    prepared =
      if context do
        response = %{
          status: "MR_OWNER_ADMISSION_PREPARED",
          request_key: context.key,
          action: "recover",
          handle: context.handle,
          payload_sha256: context.prepared.request["payload_sha256"],
          expires_at: DateTime.to_iso8601(context.expires_at)
        }

        command = "/synthetic/elixir/scripts/factory-broker desktop prepare-ticket-mr-recovery #{context.key} --source-thread-id #{broker} --workflow /synthetic/WORKFLOW.md"

        [
          event.(
            %{
              "type" => "CommandExecution",
              "id" => "prepare-#{context.handle}",
              "command" => ["/bin/zsh", "-lc", command],
              "cwd" => "file:///synthetic/elixir",
              "source" => "unified_exec_startup",
              "status" => "completed",
              "exit_code" => 0,
              "aggregated_output" => Jason.encode!(response)
            },
            now - 3,
            now - 2
          )
        ]
      else
        []
      end

    prepared = if context && String.contains?(File.read!(path), "prepare-#{context.handle}"), do: [], else: prepared

    envelope = %{
      "schemaVersion" => 1,
      "thread" => %{"id" => broker, "hostId" => "local", "cwd" => cwd, "status" => %{"type" => "active", "activeFlags" => []}},
      "page" => %{"order" => "newest_first", "limit" => 1, "hasMore" => true},
      "turns" => [%{"id" => "recovery-turn", "status" => "inProgress", "error" => nil, "completedAt" => nil}]
    }

    item = %{
      "type" => "McpToolCall",
      "id" => "owning-#{id}",
      "server" => "codex_app",
      "pluginId" => "codex-app-tools@openai-bundled",
      "tool" => "read_thread",
      "status" => "completed",
      "arguments" => %{"threadId" => broker, "includeOutputs" => true, "turnLimit" => 1, "maxOutputCharsPerItem" => 500},
      "result" => %{"isError" => false, "content" => [%{"type" => "text", "text" => Jason.encode!(envelope)}]}
    }

    File.write!(path, Enum.map(prepared ++ [event.(item, now - 1, now)], &(Jason.encode!(&1) <> "\n")), [:append])
  end

  @spec native(String.t(), Path.t()) :: {map(), map()}
  def native(broker, cwd) do
    {%{"id" => broker, "cwd" => cwd, "projectId" => nil, "updatedAt" => 2, "status" => %{"type" => "notLoaded"}},
     %{"data" => [%{"id" => "recovery-turn", "status" => "interrupted", "items" => []}], "nextCursor" => nil}}
  end

  @spec observing(module(), atom()) :: module()
  def observing(adapter, scenario) do
    module = Module.concat(__MODULE__, "Observations#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      @adapter #{inspect(adapter)}
      @scenario #{inspect(scenario)}
      @spec native_fence(map(), String.t()) :: {:ok, map()} | {:error, term()}
      def native_fence(native, broker), do: @adapter.native_fence(native, broker)
      @spec recovery_projection(map(), String.t()) :: {:ok, map()} | {:error, term()}
      def recovery_projection(native, broker) do
        count = bump(:fence)
        with {:ok, fence} <- @adapter.recovery_projection(native, broker) do
          case {scenario(), count} do
            {:two_races, 3} -> {:ok, Map.update!(fence, "updated_at", &(&1 + 1))}
            {:turn, 2} -> {:ok, Map.put(fence, "turn_id", "foreign-turn")}
            {:cwd, 2} -> {:ok, Map.put(fence, "cwd", "/foreign-cwd")}
            _ -> {:ok, fence}
          end
        end
      end
      @spec read(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
      def read(request, broker, native) do
        count = bump(:read)
        case {scenario(), count} do
          {:two_races, 1} -> {:error, "mr_presend_session_changed"}
          {:budget, _} -> {:error, "mr_presend_session_changed"}
          {:terminal, _} -> {:error, "mr_presend_recovery_already_returned"}
          {:unknown, _} -> {:error, "mr_presend_input_unreviewed:unknown"}
          {:prefix, _} -> {:error, "mr_presend_prefix_changed"}
          {:claim, 1} ->
            %{store: store} = :persistent_term.get({__MODULE__, :state})
            SymphonyElixir.Factory.Store.query!(store, "UPDATE ticket_mr_claims SET claimed_at='changed-claim' WHERE request_key=?", [request["request_key"]])
            {:error, "mr_presend_session_changed"}
          _ -> @adapter.read(request, broker, native)
        end
      end
      @spec recheck(map(), String.t(), map(), SymphonyElixir.Factory.TicketMrOwnerAdmission.t()) :: {:ok, map()} | {:error, term()}
      def recheck(request, broker, native, context) do
        count = bump(:recheck)
        if scenario() == :two_races and count == 1,
          do: {:error, "mr_presend_session_changed"},
          else: @adapter.recheck(request, broker, native, context)
      end
      defp scenario, do: Process.get({__MODULE__, :scenario}, @scenario)
      defp bump(kind) do
        count = Process.get({__MODULE__, kind}, 0) + 1
        Process.put({__MODULE__, kind}, count)
        count
      end
    end
    """)

    module
  end

  defp digest(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
