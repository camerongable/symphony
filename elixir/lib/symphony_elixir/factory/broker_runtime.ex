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
  @max_response_bytes 2_097_152
  @max_known_bytes 2_800_000
  @max_unpublished 16
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
      owner_admissions: %{},
      known_results: %{},
      publication_cursor: nil,
      after_known_link: Keyword.get(opts, :after_known_link),
      uid: File.stat!(root).uid
    }

    state = Enum.reduce(Enum.take(paths(root, "running"), @max_unpublished), state, &recover_publication(&2, &1))
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = state |> expire_owner_admissions() |> retry_publication()

    state =
      case paths(state.root, "pending") do
        [path | _] -> if map_size(state.known_results) < @max_unpublished and length(paths(state.root, "running")) < @max_unpublished, do: service(state, path), else: state
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
    settle_publication(state, pending, @max_bytes, &valid_request_record?/1)

    cond do
      linked_file?(pending) ->
        state

      present?(stem <> ".finished") or present?(stem <> ".response") or present?(stem <> ".known") or present?(running) ->
        File.rename(pending, stem <> ".duplicate")
        state

      File.rename(pending, running) == :ok ->
        request = read_owned(state, running, @max_bytes)

        {result, state} =
          try do
            with {:ok, body} <- request,
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

        case request do
          {:ok, body} -> remember_result(state, running, body, result)
          _ -> publish_uncertain(state, running, :broker_runtime_request_invalid_or_expired)
        end

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

  defp remember_result(state, running, request, result) do
    id = mailbox_id(running)
    body = serialize_result(result)

    envelope = %{
      "version" => 1,
      "mailbox_id" => id,
      "database_root" => Path.dirname(state.root),
      "request_sha256" => digest(request),
      "response_sha256" => digest(body),
      "response_base64" => Base.encode64(body)
    }

    state = %{state | known_results: Map.put(state.known_results, id, envelope)}
    recover_publication(state, running)
  end

  defp serialize_result(result) do
    payload =
      case result do
        {:ok, value} -> %{"ok" => value}
        {:error, reason} -> %{"error" => inspect(reason)}
        _ -> %{"error" => "broker_runtime_result_invalid"}
      end

    case Jason.encode(payload) do
      {:ok, body} when byte_size(body) <= @max_response_bytes -> body
      _ -> ~s({"error":"broker_runtime_result_invalid"})
    end
  rescue
    _ -> ~s({"error":"broker_runtime_result_invalid"})
  end

  defp retry_publication(state) do
    running = paths(state.root, "running")
    next = Enum.find(running, &(is_nil(state.publication_cursor) or &1 > state.publication_cursor)) || List.first(running)

    if next do
      %{recover_publication(state, next) | publication_cursor: next}
    else
      state
    end
  end

  defp recover_publication(state, running) do
    id = mailbox_id(running)
    known = Path.join(state.root, id <> ".known")

    settle_publication(state, known, @max_known_bytes, fn raw ->
      with {:ok, envelope} <- Jason.decode(raw), {:ok, _} <- known_response(state, running, id, envelope), true <- is_nil(state.known_results[id]) or state.known_results[id] == envelope, do: true
    end)

    cond do
      present?(known) ->
        with {:ok, raw} <- read_owned(state, known, @max_known_bytes, true),
             {:ok, envelope} <- Jason.decode(raw),
             {:ok, body} <- known_response(state, running, id, envelope),
             true <- is_nil(state.known_results[id]) or state.known_results[id] == envelope,
             :ok <- publish_response(state, id, body),
             :ok <- finish(state, running, id) do
          %{state | known_results: Map.delete(state.known_results, id)}
        else
          _ -> state
        end

      envelope = state.known_results[id] ->
        case publish(state.root, id <> ".known", Jason.encode!(envelope), state.after_known_link) do
          :ok -> recover_publication(state, running)
          _ -> state
        end

      true ->
        publish_uncertain(state, running, :broker_runtime_outcome_uncertain)
    end
  end

  defp known_response(state, running, id, envelope) when is_map(envelope) do
    keys = ~w(version mailbox_id database_root request_sha256 response_sha256 response_base64)

    with true <- Enum.sort(Map.keys(envelope)) == Enum.sort(keys),
         true <- envelope["version"] === 1 and envelope["mailbox_id"] == id and envelope["database_root"] == Path.dirname(state.root),
         encoded when is_binary(encoded) <- envelope["response_base64"],
         {:ok, body} <- Base.decode64(encoded),
         true <- byte_size(body) <= @max_response_bytes and envelope["response_sha256"] == digest(body),
         {:ok, payload} <- Jason.decode(body),
         true <- response_shape?(payload),
         {:ok, request} <- read_request(state, running),
         true <- envelope["request_sha256"] == digest(request) do
      {:ok, body}
    else
      _ -> {:error, :broker_runtime_known_result_invalid}
    end
  end

  defp known_response(_state, _running, _id, _envelope), do: {:error, :broker_runtime_known_result_invalid}

  defp response_shape?(%{"ok" => _} = payload), do: map_size(payload) == 1
  defp response_shape?(%{"error" => error} = payload), do: map_size(payload) == 1 and is_binary(error)
  defp response_shape?(_), do: false

  defp publish_uncertain(state, running, reason) do
    id = mailbox_id(running)
    response = Path.join(state.root, id <> ".response")

    result =
      case read_owned(state, response, @max_response_bytes) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, payload} -> if response_shape?(payload), do: :ok, else: {:error, :broker_runtime_result_invalid}
            _ -> {:error, :broker_runtime_result_invalid}
          end

        {:error, :enoent} ->
          publish_response(state, id, Jason.encode!(%{"error" => inspect(reason)}))

        error ->
          error
      end

    if result == :ok, do: finish(state, running, id)
    state
  end

  defp publish_response(state, id, body) do
    response = Path.join(state.root, id <> ".response")
    settle_publication(state, response, @max_response_bytes, &(&1 == body))

    case read_owned(state, response, @max_response_bytes) do
      {:ok, ^body} -> :ok
      {:error, :enoent} -> publish(state.root, id <> ".response", body)
      _ -> {:error, :broker_runtime_response_conflict}
    end
  end

  defp finish(state, running, id) do
    finished = Path.join(state.root, id <> ".finished")

    cond do
      not present?(finished) ->
        File.rename(running, finished)

      not present?(running) ->
        case read_owned(state, finished, @max_bytes) do
          {:ok, _} -> :ok
          _ -> {:error, :broker_runtime_finished_conflict}
        end

      true ->
        {:error, :broker_runtime_finished_conflict}
    end
  end

  defp read_request(state, running) do
    case read_owned(state, running, @max_bytes) do
      {:error, :enoent} -> read_owned(state, String.replace_suffix(running, ".running", ".finished"), @max_bytes)
      result -> result
    end
  end

  defp mailbox_id(running), do: running |> Path.basename() |> String.replace_suffix(".running", "")
  defp present?(path), do: File.lstat(path) != {:error, :enoent}
  defp linked_file?(path), do: match?({:ok, %File.Stat{type: :regular, links: links}} when links > 1, File.lstat(path))
  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp read_owned(state, path, maximum, private? \\ false, links \\ 1) do
    with {:ok, %File.Stat{type: :regular, uid: uid, links: ^links, size: size, mode: mode} = before} <- File.lstat(path),
         true <- uid == state.uid and size <= maximum and (not private? or Bitwise.band(mode, 0o077) == 0),
         {:ok, {:ok, body}} <- File.open(path, [:read, :binary], &read_unchanged(&1, path, before, maximum)) do
      {:ok, body}
    else
      {:error, :enoent} ->
        {:error, :enoent}

      {:ok, {:error, :enoent}} ->
        {:error, :enoent}

      {:ok, %File.Stat{type: :regular, uid: uid, links: 2, size: size, mode: mode}} when uid == state.uid and size <= maximum ->
        if Bitwise.band(mode, 0o077) == 0, do: {:error, :broker_runtime_publication_in_progress}, else: {:error, :broker_runtime_file_invalid}

      _ ->
        {:error, :broker_runtime_file_invalid}
    end
  end

  defp read_unchanged(file, path, before, maximum) do
    identity = Map.take(before, ~w(type uid gid links size mode mtime ctime inode major_device minor_device)a)

    with {:ok, opened} <- :file.read_file_info(file, time: :universal),
         true <- Map.take(File.Stat.from_record(opened), Map.keys(identity)) == identity,
         body when is_binary(body) <- IO.binread(file, maximum + 1),
         true <- byte_size(body) <= maximum,
         {:ok, after_read} <- File.lstat(path),
         true <- Map.take(after_read, Map.keys(identity)) == identity do
      {:ok, body}
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :broker_runtime_file_invalid}
    end
  end

  defp publish(root, name, body, after_link \\ nil) do
    temporary = Path.join(root, name <> ".writing." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))

    # The exclusive final link commits complete bytes without replacing a contender.
    # Readers wait until the temporary link is settled, including after owner death.
    with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]) do
      result =
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(file, body),
             :ok <- :file.sync(file),
             :ok <- File.ln(temporary, Path.join(root, name)) do
          if is_function(after_link, 0), do: after_link.()
          unlink_publication_temporary(temporary)
        end

      File.close(file)
      if result != :ok, do: File.rm(temporary)
      result
    end
  end

  defp unlink_publication_temporary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp settle_publication(state, path, maximum, valid?) do
    with {:ok, %File.Stat{type: :regular, uid: uid, links: 2, mode: mode, size: size} = final} <- File.lstat(path),
         true <- uid == state.uid and size <= maximum and Bitwise.band(mode, 0o077) == 0,
         {:ok, names} <- File.ls(state.root),
         grammar = Regex.compile!("\\A" <> Regex.escape(Path.basename(path)) <> "\\.writing\\.[0-9a-f]{16}\\z"),
         [name] <- Enum.filter(names, &Regex.match?(grammar, &1)),
         temporary = Path.join(state.root, name),
         {:ok, alias_stat} <- File.lstat(temporary),
         true <- publication_identity(alias_stat) == publication_identity(final),
         {:ok, body} <- read_owned(state, path, maximum, true, 2),
         true <- valid?.(body) == true,
         {:ok, destination} <- File.lstat(path),
         true <- publication_identity(destination) == publication_identity(final),
         {:ok, current} <- File.lstat(temporary),
         true <- publication_identity(current) == publication_identity(final) do
      unlink_publication_temporary(temporary)
    else
      _ -> :ok
    end
  end

  defp publication_identity(stat), do: Map.take(stat, ~w(type uid gid links size mode mtime ctime inode major_device minor_device)a)

  defp valid_request_record?(raw) do
    with {:ok, %{"args" => args, "expires_at" => expiry}} <- Jason.decode(raw), true <- is_list(args) and Enum.all?(args, &is_binary/1) and bridged?(args), true <- is_integer(expiry), do: true
  end

  defp await(root, id, deadline) do
    case read_response(root, id) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => value}} -> {:ok, value}
          {:ok, %{"error" => reason}} -> {:error, reason}
          _ -> {:error, :broker_runtime_result_invalid}
        end

      {:error, :broker_runtime_response_conflict} = error ->
        error

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

  defp read_response(root, id) do
    state = %{root: root, uid: File.stat!(root).uid}
    running = Path.join(root, id <> ".running")
    finished = Path.join(root, id <> ".finished")
    known = Path.join(root, id <> ".known")
    response = Path.join(root, id <> ".response")

    cond do
      present?(known) ->
        with {:ok, raw} <- read_owned(state, known, @max_known_bytes, true),
             {:ok, envelope} <- Jason.decode(raw),
             {:ok, expected} <- known_response(state, running, id, envelope) do
          case read_owned(state, response, @max_response_bytes) do
            {:ok, ^expected} -> {:ok, expected}
            {:error, :enoent} = missing -> missing
            {:error, :broker_runtime_publication_in_progress} = pending -> pending
            _ -> {:error, :broker_runtime_response_conflict}
          end
        else
          {:error, :broker_runtime_publication_in_progress} = pending -> pending
          _ -> {:error, :broker_runtime_response_conflict}
        end

      present?(finished) ->
        read_owned(state, response, @max_response_bytes)

      true ->
        {:error, :enoent}
    end
  end

  defp paths(root, phase) do
    root |> File.ls!() |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{32}\.#{phase}\z/, &1)) |> Enum.sort() |> Enum.map(&Path.join(root, &1))
  end
end
