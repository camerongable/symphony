defmodule SymphonyElixir.Factory.NativeRuntimeCompatibility do
  @moduledoc "Versioned native history admission before factory mutation; not a receipt semantic verifier."

  alias SymphonyElixir.{Config, Workflow}
  alias Exqlite.Sqlite3
  alias SymphonyElixir.Factory.NativeRuntimeRoute

  @legacy_formats %{"worker_binding_versions" => [1], "completion_receipt_versions" => [1]}

  @spec supported_formats() :: map()
  def supported_formats, do: %{"worker_binding_versions" => [1, 2], "completion_receipt_versions" => [1, 2]}

  @spec check_manifest(map()) :: :ok | {:error, atom()}
  def check_manifest(manifest) when is_map(manifest) do
    if Map.get(manifest, "native_runtime_formats", @legacy_formats) === supported_formats(),
      do: :ok,
      else: {:error, :unsupported_native_runtime_formats}
  end

  def check_manifest(_manifest), do: {:error, :unsupported_native_runtime_formats}

  @spec check_workflow(Path.t()) :: :ok | {:error, term()}
  def check_workflow(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Config.Schema.parse(workflow.config) do
      check_factory(settings.factory)
    end
  end

  @spec check_factory(map()) :: :ok | {:error, atom()}
  def check_factory(factory) do
    policy = Map.get(factory, :ticket_supervisor, Map.get(factory, "ticket_supervisor", %{}))
    database = Map.get(factory, :database, Map.get(factory, "database"))

    cond do
      is_map(policy) and (Map.has_key?(policy, "native_runtime") or Map.has_key?(policy, :native_runtime)) ->
        {:error, :unsupported_native_runtime_configuration}

      Map.get(factory, :enabled, Map.get(factory, "enabled")) === false ->
        :ok

      is_nil(database) ->
        :ok

      true ->
        check_database(database)
    end
  end

  @spec check_database(term()) :: :ok | {:error, atom()}
  def check_database(database) when database in [:memory, ":memory:"], do: :ok
  def check_database("file:" <> _uri), do: {:error, :native_runtime_history_unreadable}

  def check_database(database) when is_binary(database) and byte_size(database) > 0 do
    case File.lstat(database) do
      {:error, :enoent} -> :ok
      {:ok, _} -> check_existing(database)
      _ -> {:error, :native_runtime_history_unreadable}
    end
  end

  def check_database(_database), do: {:error, :native_runtime_history_unreadable}

  defp check_existing(database) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(database),
         {:ok, connection} <- Sqlite3.open(database, mode: :readonly) do
      try do
        :ok = Sqlite3.execute(connection, "PRAGMA busy_timeout=5000; PRAGMA query_only=ON; BEGIN DEFERRED")
        result = check_snapshot(connection)
        [[0]] = rows(connection, "SELECT total_changes()")
        :ok = Sqlite3.execute(connection, "COMMIT")
        result
      rescue
        _ -> {:error, :native_runtime_history_unreadable}
      after
        Sqlite3.close(connection)
      end
    else
      _ -> {:error, :native_runtime_history_unreadable}
    end
  end

  defp check_snapshot(connection) do
    objects = rows(connection, "SELECT lower(name),type FROM sqlite_master WHERE lower(name) IN ('worker_evidence','events')") |> Map.new(&List.to_tuple/1)

    with :ok <- check_table(connection, objects, "worker_evidence", ~w(binding_json), "SELECT binding_json FROM worker_evidence", &native_binding?/1),
         :ok <-
           check_table(connection, objects, "events", ~w(event_type payload_json), "SELECT payload_json FROM events WHERE event_type='TICKET_WORKER_NATIVE_COMPLETION_RECOVERED'", &native_receipt?/1) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :native_runtime_history_unreadable}
    end
  end

  defp check_table(connection, objects, table, columns, sql, valid?) do
    case objects[table] do
      nil ->
        :ok

      "table" ->
        actual = rows(connection, "PRAGMA table_info(#{table})") |> Enum.map(&Enum.at(&1, 1))

        cond do
          not Enum.all?(columns, &(&1 in actual)) -> {:error, :native_runtime_history_unreadable}
          Enum.all?(rows(connection, sql), fn [json] -> valid?.(json) end) -> :ok
          true -> {:error, :unsupported_native_runtime_history}
        end

      _ ->
        {:error, :native_runtime_history_unreadable}
    end
  end

  defp rows(connection, sql) do
    {:ok, statement} = Sqlite3.prepare(connection, sql)

    try do
      {:ok, rows} = Sqlite3.fetch_all(connection, statement)
      rows
    after
      Sqlite3.release(connection, statement)
    end
  end

  defp native_binding?(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, binding} when is_map(binding) ->
        if Map.has_key?(binding, "binding_version") or Map.has_key?(binding, "native_runtime"),
          do: binding["binding_version"] === 2 and NativeRuntimeRoute.validate_origin_format(binding["native_runtime"]) == :ok,
          else: true

      _ ->
        false
    end
  end

  defp native_binding?(_json), do: false

  defp native_receipt?(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"kind" => "NATIVE_COMPLETION_RECEIPT_V1", "version" => 1} = receipt} ->
        not Map.has_key?(receipt, "native_runtime") and not Map.has_key?(receipt, "native_runtime_sha256")

      {:ok, %{"kind" => "NATIVE_COMPLETION_RECEIPT_V2", "version" => 2} = receipt} ->
        NativeRuntimeRoute.validate_origin_format(receipt["native_runtime"]) == :ok and
          receipt["native_runtime_sha256"] ==
            Base.encode16(:crypto.hash(:sha256, Jason.encode!(receipt["native_runtime"])), case: :lower)

      _ ->
        false
    end
  end

  defp native_receipt?(_json), do: false
end
