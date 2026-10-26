defmodule SymphonyElixir.Factory.IntakeLedger do
  @moduledoc """
  Durable snapshots of the last successful Jira intake query.

  This ledger is intentionally separate from admitted runs. It lets operators
  distinguish an empty queue from a controller that has not successfully read
  Jira, and keeps eligible work visible before capacity and routing decisions.
  """

  alias SymphonyElixir.Factory.Store

  @blocked_decisions %{
    manual_validation_contract_missing: "Confirmed delivery contract must explicitly declare whether manual validation is required.",
    manual_validation_disabled: "Required manual validation is not enabled for new ticket admission.",
    ambiguous_manual_validation_section: "Confirmed delivery contract must contain one Manual Validation section.",
    ambiguous_manual_validation_decision: "Confirmed delivery contract must contain one manual-validation decision.",
    ambiguous_manual_validation_environment: "Confirmed delivery contract must select one manual-validation environment.",
    manual_validation_environment_missing: "Required manual validation must declare its environment.",
    manual_validation_format_unsupported: "Manual-validation declarations must use supported unquoted Markdown.",
    ticket_manual_validation_not_supported: "Required manual validation is not supported by the selected ticket route.",
    manual_validation_environment_not_allowed: "The declared manual-validation environment is not allowed for new ticket admission.",
    production_validation_forbidden: "Production manual validation is forbidden."
  }

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
            INSERT INTO intake_snapshots(scope, observed_at, snapshot_json, decisions_json)
            VALUES (?, ?, ?, '{}')
            ON CONFLICT(scope) DO UPDATE SET
              observed_at = excluded.observed_at,
              snapshot_json = excluded.snapshot_json,
              decisions_json = '{}'
            """,
            [scope, observed_at, snapshot_json]
          )

          {:ok, %{scope: scope, observed_at: observed_at, snapshots: snapshots}}
        end
    end
  end

  @doc "Returns the last successful Jira intake snapshot for one factory scope."
  @spec get(Store.connection(), String.t()) ::
          {:ok, %{scope: String.t(), observed_at: String.t(), snapshots: [map()], decisions: map()} | nil}
          | {:error, term()}
  def get(connection, scope) when is_binary(scope) do
    case Store.one!(
           connection,
           "SELECT scope, observed_at, snapshot_json, decisions_json FROM intake_snapshots WHERE scope = ?",
           [String.trim(scope)]
         ) do
      nil ->
        {:ok, nil}

      row ->
        with {:ok, snapshots} when is_list(snapshots) <- Jason.decode(row["snapshot_json"]),
             true <- Enum.all?(snapshots, &is_map/1),
             {:ok, decisions} when is_map(decisions) <- Jason.decode(row["decisions_json"]),
             true <- valid_decisions?(decisions) do
          {:ok,
           %{
             scope: row["scope"],
             observed_at: row["observed_at"],
             snapshots: snapshots,
             decisions: decisions
           }}
        else
          _other -> {:error, :invalid_stored_intake_snapshot}
        end
    end
  end

  def get(_connection, _scope), do: {:error, :invalid_intake_scope}

  @doc "Records a controller rejection only against the exact saved intake observation."
  @spec record_blocked(Store.connection(), String.t(), map(), String.t(), atom()) ::
          :ok | {:error, term()}
  def record_blocked(connection, scope, snapshot, observed_at, reason) when is_map_key(@blocked_decisions, reason) do
    Store.transaction!(connection, fn tx ->
      with {:ok, %{observed_at: ^observed_at, snapshots: snapshots, decisions: decisions}} <- get(tx, scope),
           issue_key when is_binary(issue_key) <- snapshot["key"],
           true <- Enum.find(snapshots, &(&1["key"] == issue_key)) == snapshot do
        decision = %{
          "code" => Atom.to_string(reason),
          "message" => Map.fetch!(@blocked_decisions, reason)
        }

        Store.query!(tx, "UPDATE intake_snapshots SET decisions_json = ? WHERE scope = ?", [Jason.encode!(Map.put(decisions, issue_key, decision)), String.trim(scope)])
        :ok
      else
        _ -> {:error, :intake_observation_changed}
      end
    end)
  end

  defp valid_decisions?(decisions) do
    Enum.all?(decisions, fn
      {key, %{"code" => code, "message" => message}}
      when is_binary(key) and is_binary(message) ->
        Enum.any?(@blocked_decisions, fn {reason, safe_message} -> Atom.to_string(reason) == code and safe_message == message end)

      _ ->
        false
    end)
  end
end
