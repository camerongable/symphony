defmodule SymphonyElixir.Factory.IntakeLedger do
  @moduledoc """
  Durable snapshots of the last successful Jira intake query.

  This ledger is intentionally separate from admitted runs. It lets operators
  distinguish an empty queue from a controller that has not successfully read
  Jira, and keeps eligible work visible before capacity and routing decisions.
  """

  alias SymphonyElixir.Factory.Store

  @doc "Replaces the last successful Jira intake snapshot for one factory scope."
  @spec replace(Store.connection(), String.t(), [map()], keyword()) ::
          {:ok, %{scope: String.t(), observed_at: String.t(), snapshots: [map()]}}
          | {:error, term()}
  def replace(connection, scope, snapshots, opts \\ []) do
    cond do
      not is_binary(scope) or not is_list(snapshots) ->
        {:error, :invalid_intake_snapshot}

      String.trim(scope) == "" ->
        {:error, :invalid_intake_scope}

      not Enum.all?(snapshots, &is_map/1) ->
        {:error, :invalid_intake_snapshots}

      true ->
        scope = String.trim(scope)
        observed_at = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()

        with {:ok, snapshot_json} <- Jason.encode(snapshots) do
          Store.query!(
            connection,
            """
            INSERT INTO intake_snapshots(scope, observed_at, snapshot_json)
            VALUES (?, ?, ?)
            ON CONFLICT(scope) DO UPDATE SET
              observed_at = excluded.observed_at,
              snapshot_json = excluded.snapshot_json
            """,
            [scope, observed_at, snapshot_json]
          )

          {:ok, %{scope: scope, observed_at: observed_at, snapshots: snapshots}}
        end
    end
  end

  @doc "Returns the last successful Jira intake snapshot for one factory scope."
  @spec get(Store.connection(), String.t()) ::
          {:ok, %{scope: String.t(), observed_at: String.t(), snapshots: [map()]} | nil}
          | {:error, term()}
  def get(connection, scope) when is_binary(scope) do
    case Store.one!(
           connection,
           "SELECT scope, observed_at, snapshot_json FROM intake_snapshots WHERE scope = ?",
           [String.trim(scope)]
         ) do
      nil ->
        {:ok, nil}

      row ->
        with {:ok, snapshots} when is_list(snapshots) <- Jason.decode(row["snapshot_json"]),
             true <- Enum.all?(snapshots, &is_map/1) do
          {:ok,
           %{
             scope: row["scope"],
             observed_at: row["observed_at"],
             snapshots: snapshots
           }}
        else
          _other -> {:error, :invalid_stored_intake_snapshot}
        end
    end
  end

  def get(_connection, _scope), do: {:error, :invalid_intake_scope}
end
