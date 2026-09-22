defmodule SymphonyElixir.Factory.RunLedger do
  @moduledoc """
  Durable issue, task, worktree, branch, candidate, and model-route ownership.
  """

  alias SymphonyElixir.Factory.Store

  @insert_columns ~w(
    run_id issue_key kind state dispatcher_id spec_revision contract_sha256
    repo_key repo_path base_branch worktree branch candidate_sha
    candidate_handoff attempt validation_attempt slack_claim_ts
    last_input_marker task_id mr_url jira_status mr_state runtime model_role model_provider model_class
    model reasoning_effort model_routing_reason factory_owned created_at updated_at
    parent_run_id snapshot_json contract_markdown plan_markdown
    repair_findings_json manual_validation_required implementation_iteration
    code_repair_round validation_repair_round verifier_round spec_comment_id
    confirmation_comment_id mr_iid last_error risk risk_signals_json
    workspace_state hibernated_at
  )

  @updatable_columns ~w(
    state dispatcher_id spec_revision contract_sha256 worktree branch
    candidate_sha candidate_handoff attempt validation_attempt slack_claim_ts
    last_input_marker task_id mr_url jira_status mr_state failure_code runtime
    model_role model_provider model_class model reasoning_effort
    model_routing_reason parent_run_id snapshot_json contract_markdown
    plan_markdown repair_findings_json manual_validation_required
    implementation_iteration code_repair_round validation_repair_round
    verifier_round spec_comment_id confirmation_comment_id mr_iid last_error
    risk risk_signals_json
    workspace_state hibernated_at
  )

  @doc """
  Registers a new factory run and its initial event.
  """
  @spec register(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def register(connection, attrs, opts \\ []) do
    with :ok <- require_fields(attrs, ~w(run_id issue_key kind state)),
         :ok <- validate_kind(value(attrs, "kind")) do
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> iso()

      normalized =
        attrs
        |> stringify_keys()
        |> Map.put_new("attempt", 1)
        |> Map.put_new("validation_attempt", 0)
        |> Map.put_new("implementation_iteration", 0)
        |> Map.put_new("code_repair_round", 0)
        |> Map.put_new("validation_repair_round", 0)
        |> Map.put_new("verifier_round", 0)
        |> Map.put_new("factory_owned", true)
        |> Map.put_new("workspace_state", "UNMATERIALIZED")
        |> Map.put("created_at", now)
        |> Map.put("updated_at", now)

      Store.transaction!(connection, &insert_run(&1, normalized))
    end
  end

  @doc """
  Reads a run by its stable run ID.
  """
  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, :unknown_run}
  def get(connection, run_id) do
    case Store.one!(connection, "SELECT * FROM runs WHERE run_id = ?", [run_id]) do
      nil -> {:error, :unknown_run}
      run -> {:ok, run}
    end
  end

  @doc """
  Lists runs, optionally restricted to one state.
  """
  @spec list(Store.connection(), keyword()) :: [map()]
  def list(connection, opts \\ []) do
    {statement, params} =
      case Keyword.get(opts, :state) do
        nil -> {"SELECT * FROM runs ORDER BY updated_at DESC", []}
        state -> {"SELECT * FROM runs WHERE state = ? ORDER BY updated_at DESC", [state]}
      end

    result = Store.query!(connection, statement, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  @doc """
  Updates only the allowlisted mutable fields and records the change event.
  """
  @spec update(Store.connection(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(connection, run_id, attrs, opts \\ []) do
    updates =
      attrs
      |> stringify_keys()
      |> Map.take(@updatable_columns)

    if map_size(updates) == 0 do
      {:error, :no_run_fields}
    else
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> iso()
      updates = Map.put(updates, "updated_at", now)
      columns = @updatable_columns |> Enum.filter(&Map.has_key?(updates, &1)) |> Kernel.++(["updated_at"])

      Store.transaction!(connection, &update_run(&1, run_id, updates, columns))
    end
  end

  @doc """
  Appends an auditable model route for a run and records the corresponding event.
  """
  @spec record_model_route(Store.connection(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, :unknown_run}
  def record_model_route(connection, run_id, usage_context, route, opts \\ []) do
    Store.transaction!(connection, fn transaction ->
      case get(transaction, run_id) do
        {:error, :unknown_run} ->
          {:error, :unknown_run}

        {:ok, _run} ->
          occurred_at = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> iso()
          task_id = Keyword.get(opts, :task_id)

          Store.query!(
            transaction,
            """
            INSERT INTO model_routes(
              occurred_at, run_id, task_id, usage_context, requested_role,
              resolved_role, provider, model_class, model, reasoning_effort,
              routing_reason
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
              occurred_at,
              run_id,
              task_id,
              usage_context,
              value(route, "requested_role"),
              value(route, "resolved_role"),
              value(route, "provider"),
              value(route, "model_class"),
              value(route, "model"),
              value(route, "reasoning_effort"),
              value(route, "routing_reason")
            ]
          )

          %{"id" => route_id} = Store.one!(transaction, "SELECT last_insert_rowid() AS id")

          payload = %{
            route_id: route_id,
            usage_context: usage_context,
            task_id: task_id,
            requested_role: value(route, "requested_role"),
            resolved_role: value(route, "resolved_role"),
            provider: value(route, "provider"),
            model_class: value(route, "model_class"),
            model: value(route, "model"),
            reasoning_effort: value(route, "reasoning_effort"),
            routing_reason: value(route, "routing_reason")
          }

          record_event!(transaction, "MODEL_ROUTE_RECORDED", run_id, payload)
          {:ok, payload}
      end
    end)
  end

  @doc """
  Lists append-only events for a run in occurrence order.
  """
  @spec events(Store.connection(), String.t()) :: [map()]
  def events(connection, run_id) do
    result =
      Store.query!(
        connection,
        "SELECT * FROM events WHERE run_id = ? ORDER BY id ASC",
        [run_id]
      )

    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp get!(connection, run_id) do
    {:ok, run} = get(connection, run_id)
    run
  end

  defp insert_run(transaction, normalized) do
    placeholders = Enum.map_join(@insert_columns, ", ", fn _column -> "?" end)
    values = Enum.map(@insert_columns, &database_value(Map.get(normalized, &1)))

    case Exqlite.query(
           transaction,
           "INSERT INTO runs(#{Enum.join(@insert_columns, ", ")}) VALUES (#{placeholders})",
           values
         ) do
      {:ok, _result} ->
        record_event!(transaction, "RUN_REGISTERED", normalized["run_id"], %{
          "state" => normalized["state"]
        })

        {:ok, %{result: "REGISTERED", run: get!(transaction, normalized["run_id"])}}

      {:error, error} ->
        {:error, {:register_failed, error}}
    end
  end

  defp update_run(transaction, run_id, updates, columns) do
    case get(transaction, run_id) do
      {:error, :unknown_run} ->
        {:error, :unknown_run}

      {:ok, _run} ->
        assignments = Enum.map_join(columns, ", ", &"#{&1} = ?")
        values = Enum.map(columns, &database_value(Map.fetch!(updates, &1))) ++ [run_id]
        Store.query!(transaction, "UPDATE runs SET #{assignments} WHERE run_id = ?", values)
        record_event!(transaction, "RUN_UPDATED", run_id, updates)
        {:ok, %{result: "UPDATED", run: get!(transaction, run_id)}}
    end
  end

  defp record_event!(connection, event_type, run_id, payload) do
    Store.query!(
      connection,
      "INSERT INTO events(occurred_at, event_type, run_id, payload_json) VALUES (?, ?, ?, ?)",
      [iso(DateTime.utc_now()), event_type, run_id, Jason.encode!(payload)]
    )

    :ok
  end

  defp require_fields(attrs, fields) do
    case Enum.reject(fields, &(is_binary(value(attrs, &1)) and String.trim(value(attrs, &1)) != "")) do
      [] -> :ok
      missing -> {:error, {:missing_run_fields, missing}}
    end
  end

  defp validate_kind(kind) when kind in ["SPECIFICATION", "DELIVERY", "VALIDATION"], do: :ok
  defp validate_kind(kind), do: {:error, {:invalid_run_kind, kind}}

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, item} -> {to_string(key), item} end)
  end

  defp database_value(true), do: 1
  defp database_value(false), do: 0
  defp database_value(value), do: value

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> value_from_existing_atom(map, key)
    end
  end

  defp value(_map, _key), do: nil

  defp value_from_existing_atom(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp iso(value), do: DateTime.to_iso8601(value)
end
