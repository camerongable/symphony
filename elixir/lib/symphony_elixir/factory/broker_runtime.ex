defmodule SymphonyElixir.Factory.BrokerRuntime do
  @moduledoc "Service-owned native checks for a sandboxed Desktop broker; never issues a Desktop model turn."
  use GenServer

  alias Mix.Tasks.Factory.Ticket
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.Supervisor
  alias SymphonyElixir.Factory.TicketMrOwnerAdmission
  alias SymphonyElixir.{PathSafety, Workflow}

  @owner_operations ~w(prepare-ticket-mr-correction prepare-ticket-mr-claim prepare-ticket-mr-recovery finalize-ticket-mr-correction finalize-ticket-mr-claim finalize-ticket-mr-recovery)
  @operations ~w(claim claim-ticket-followup claim-ticket-mr-owner correct-ticket-mr-owner complete-ticket-mr read-ticket-turn record-ticket-thread complete reconcile-negative-ticket-presentation prepare-ticket-stage authorize-ticket-verifier-repair authorize-ticket-policy-stop-repair prepare-ticket-report-correction apply-ticket-report-correction inspect-ticket-capability-recovery inspect-ticket-capability-runtime authorize-ticket-capability-recovery) ++
                @owner_operations
  @max_bytes 131_072
  @max_owner_admissions 16

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec bridged?([String.t()]) :: boolean()
  def bridged?([command | _]), do: command in @operations
  def bridged?(_), do: false

  @spec call([String.t()]) :: {:ok, term()} | {:error, term()}
  def call(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [workflow: :string])

    with true <- bridged?(args),
         {:ok, loaded} <- Workflow.load(Path.expand(opts[:workflow] || "WORKFLOW.md")),
         {:ok, settings} <- Schema.parse(loaded.config),
         {:ok, root} <- root(settings.factory.database),
         true <- File.dir?(root),
         id <- Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         payload <- Jason.encode!(%{"args" => args, "expires_at" => System.system_time(:millisecond) + 90_000}),
         true <- byte_size(payload) <= @max_bytes,
         :ok <- publish(root, id <> ".pending", payload) do
      await(root, id, System.monotonic_time(:millisecond) + 90_000)
    else
      _ -> {:error, :broker_runtime_unavailable}
    end
  end

  @impl true
  def init(opts) do
    factory = Keyword.fetch!(opts, :factory)
    {:ok, root} = root(factory.database)
    :yes = :global.register_name({__MODULE__, root}, self())
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    state = %{
      root: root,
      factory: factory,
      store: Keyword.get(opts, :store, Supervisor.store_name()),
      executor: Keyword.get(opts, :executor, &execute/3),
      presend_evidence_reader: Keyword.get(opts, :presend_evidence_reader, SymphonyElixir.Factory.TicketMrPresendEvidence),
      owner_admissions: %{}
    }

    Enum.each(paths(root, "running"), &respond(state, &1, {:error, :broker_runtime_outcome_uncertain}))
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = expire_owner_admissions(state)

    state =
      case paths(state.root, "pending") do
        [path | _] -> service(state, path)
        [] -> state
      end

    Process.send_after(self(), :poll, 250)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if :global.whereis_name({__MODULE__, state.root}) == self(), do: :global.unregister_name({__MODULE__, state.root})
    :ok
  end

  @doc false
  @spec owner_admission_active?(TicketMrOwnerAdmission.t()) :: boolean()
  def owner_admission_active?(%TicketMrOwnerAdmission{authority: authority, factory: %{database: database}} = context) when is_reference(authority) and is_binary(database) do
    root = Path.join(Path.dirname(context.factory.database), "broker-runtime")
    :global.whereis_name({__MODULE__, root}) == self() and Process.get({__MODULE__, :owner_admission}) === context
  end

  def owner_admission_active?(_context), do: false

  @spec root(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def root(database) do
    path = Path.join(Path.dirname(database), "broker-runtime")

    with {:ok, ^path} <- PathSafety.canonicalize(path) do
      {:ok, path}
    else
      _ -> {:error, :broker_runtime_root_mismatch}
    end
  end

  defp service(state, pending) do
    running = String.replace_suffix(pending, ".pending", ".running")
    stem = String.replace_suffix(pending, ".pending", "")

    cond do
      File.exists?(stem <> ".finished") or File.exists?(stem <> ".response") or File.exists?(running) ->
        File.rename(pending, stem <> ".duplicate")
        state

      File.rename(pending, running) == :ok ->
        {result, state} =
          try do
            with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(running),
                 true <- size <= @max_bytes,
                 {:ok, body} <- File.read(running),
                 {:ok, %{"args" => args, "expires_at" => expiry}} <- Jason.decode(body),
                 true <- is_list(args) and Enum.all?(args, &is_binary/1) and bridged?(args),
                 true <- is_integer(expiry) and expiry > System.system_time(:millisecond) and expiry <= System.system_time(:millisecond) + 90_000 do
              dispatch(state, args)
            else
              _ -> {{:error, :broker_runtime_request_invalid_or_expired}, state}
            end
          rescue
            _ -> {{:error, :broker_runtime_operation_failed}, state}
          catch
            _, _ -> {{:error, :broker_runtime_operation_failed}, state}
          end

        respond(state, running, result)
        state

      true ->
        state
    end
  end

  defp dispatch(state, [command | _] = args) when command in @owner_operations do
    case Mix.Tasks.Factory.Desktop.owner_runtime_args(args, state.store, state.factory) do
      {:ok, %{phase: :prepare} = input} -> prepare_owner(state, input)
      {:ok, %{phase: :finalize} = input} -> finalize_owner(state, input)
      {:error, _} = error -> {error, state}
    end
  end

  defp dispatch(state, args), do: {state.executor.(args, state.store, state.factory), state}

  defp prepare_owner(state, input) do
    state = expire_owner_admissions(state)
    alive = state.owner_admissions

    if map_size(alive) >= @max_owner_admissions or Enum.any?(alive, fn {_handle, context} -> context.key == input.key end) do
      {{:error, :mr_owner_admission_busy}, state}
    else
      options = Keyword.put(input.opts, :presend_evidence_reader, state.presend_evidence_reader)

      case TicketMrOwnerAdmission.prepare(state.store, input.key, input.action, input.expected_sha, state.factory, input.broker, options) do
        {:ok, context} ->
          handle = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
          context = %{context | handle: handle}

          response = %{
            status: "MR_OWNER_ADMISSION_PREPARED",
            request_key: input.key,
            action: Atom.to_string(input.action),
            handle: handle,
            expires_at: DateTime.to_iso8601(context.expires_at),
            payload_sha256: context.prepared.request["payload_sha256"]
          }

          {{:ok, response}, %{state | owner_admissions: Map.put(alive, handle, context)}}

        {:error, _} = error ->
          {error, state}
      end
    end
  end

  defp expire_owner_admissions(state) do
    %{state | owner_admissions: Map.reject(state.owner_admissions, fn {_handle, context} -> DateTime.compare(DateTime.utc_now(), context.expires_at) == :gt end)}
  end

  defp finalize_owner(state, input) do
    {context, admissions} = Map.pop(state.owner_admissions, input.handle)
    consumed = %{state | owner_admissions: admissions}

    result =
      try do
        with %TicketMrOwnerAdmission{} <- context,
             true <- {context.action, context.key, context.broker, context.factory} == {input.action, input.key, input.broker, state.factory} or {:error, :mr_owner_admission_binding_mismatch},
             :ok <- TicketMrOwnerAdmission.workflow_current(context),
             {:ok, owner} <- Mix.Tasks.Factory.Desktop.owner_runtime_observation(input) do
          Process.put({__MODULE__, :owner_admission}, context)
          TicketMrOwnerAdmission.finalize(state.store, context, state.factory, owner)
        else
          nil -> {:error, :mr_owner_admission_unavailable}
          {:error, _} = error -> error
          _ -> {:error, :mr_owner_admission_unavailable}
        end
      rescue
        _ -> {:error, :broker_runtime_operation_failed}
      catch
        _, _ -> {:error, :broker_runtime_operation_failed}
      after
        Process.delete({__MODULE__, :owner_admission})
      end

    {result, consumed}
  end

  defp execute(["prepare-ticket-stage" | _] = args, store, factory),
    do: Mix.Tasks.Factory.Ticket.runtime_prepare(args, store, factory)

  defp execute(["authorize-ticket-verifier-repair" | _] = args, store, factory),
    do: Ticket.runtime_authorize_verifier_repair(args, store, factory)

  defp execute(["authorize-ticket-policy-stop-repair" | _] = args, store, factory),
    do: Ticket.runtime_authorize_policy_stop_repair(args, store, factory)

  defp execute([operation | _] = args, store, factory) when operation in ~w(prepare-ticket-report-correction apply-ticket-report-correction),
    do: Ticket.runtime_report_correction(args, store, factory)

  defp execute([operation | _] = args, store, factory) when operation in ~w(inspect-ticket-capability-recovery inspect-ticket-capability-runtime authorize-ticket-capability-recovery),
    do: Ticket.runtime_capability_recovery(args, store, factory)

  defp execute(args, store, factory), do: Mix.Tasks.Factory.Desktop.runtime_operation(args, store, factory)

  defp respond(state, running, result) do
    id = running |> Path.basename() |> String.replace_suffix(".running", "")
    response = Path.join(state.root, id <> ".response")

    payload =
      case result do
        {:ok, value} -> %{"ok" => value}
        {:error, reason} -> %{"error" => inspect(reason)}
        _ -> %{"error" => "broker_runtime_result_invalid"}
      end

    publication = if valid_response?(response), do: :ok, else: publish(state.root, id <> ".response", Jason.encode!(payload))

    case publication do
      :ok -> File.rename(running, Path.join(state.root, id <> ".finished"))
      _ -> :ok
    end
  end

  defp publish(root, name, body) do
    temporary = Path.join(root, name <> ".writing." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    with :ok <- File.write(temporary, body, [:exclusive]), do: File.rename(temporary, Path.join(root, name))
  end

  defp await(root, id, deadline) do
    response = Path.join(root, id <> ".response")
    read = if valid_response?(response), do: File.read(response), else: {:error, :enoent}

    case read do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => value}} -> {:ok, value}
          {:ok, %{"error" => reason}} -> {:error, reason}
          _ -> {:error, :broker_runtime_result_invalid}
        end

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            100 -> await(root, id, deadline)
          end
        else
          {:error, :broker_runtime_outcome_uncertain}
        end
    end
  end

  defp valid_response?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 2_097_152 -> true
      _ -> false
    end
  end

  defp paths(root, phase) do
    root |> File.ls!() |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{32}\.#{phase}\z/, &1)) |> Enum.sort() |> Enum.map(&Path.join(root, &1))
  end
end
