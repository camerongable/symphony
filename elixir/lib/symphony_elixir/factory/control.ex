defmodule SymphonyElixir.Factory.Control do
  @moduledoc """
  Transactional dispatcher control and tick leasing.

  Only the dispatcher named by the control row may acquire a tick. A live lease
  prevents a second scheduler from reconciling or dispatching the same work.
  """

  alias SymphonyElixir.Factory.Store

  @type config :: %{
          required(:scope) => String.t(),
          required(:dispatcher_id) => String.t(),
          optional(:lease_seconds) => pos_integer()
        }

  @type result :: map()

  @doc """
  Creates the paused control row when it does not yet exist.
  """
  @spec initialize(Store.connection(), config(), keyword()) :: result()
  def initialize(connection, config, opts \\ []) do
    now = now(opts)

    Store.query!(
      connection,
      """
      INSERT INTO control(scope, status, dispatcher_id, generation, updated_at)
      VALUES (?, 'PAUSED', ?, 0, ?)
      ON CONFLICT(scope) DO NOTHING
      """,
      [config.scope, config.dispatcher_id, iso(now)]
    )

    %{
      result: "INITIALIZED",
      control: fetch!(connection, config.scope)
    }
  end

  @doc """
  Reads the current control row for a scope.
  """
  @spec status(Store.connection(), String.t()) :: result() | nil
  def status(connection, scope), do: Store.one!(connection, "SELECT * FROM control WHERE scope = ?", [scope])

  @doc "Persists the visible controller Codex task identity after launch."
  @spec record_controller_task(Store.connection(), config(), String.t(), String.t() | nil, map()) :: result()
  def record_controller_task(connection, config, thread_id, turn_id, route \\ %{})
      when is_binary(thread_id) and is_map(route) do
    Store.query!(
      connection,
      """
      UPDATE control
      SET controller_thread_id = ?, controller_turn_id = ?,
          controller_codex_project_id = ?,
          controller_codex_section_id = ?,
          controller_model_role = ?, controller_model_provider = ?,
          controller_model_class = ?, controller_model = ?,
          controller_reasoning_effort = ?, controller_routing_reason = ?,
          updated_at = ?
      WHERE scope = ?
      """,
      [
        thread_id,
        turn_id,
        value(route, :project_id),
        value(route, :section_id),
        value(route, :resolved_role),
        value(route, :provider),
        value(route, :model_class),
        value(route, :model),
        value(route, :reasoning_effort),
        value(route, :routing_reason),
        iso(DateTime.utc_now()),
        config.scope
      ]
    )

    %{result: "CONTROLLER_TASK_RECORDED", control: fetch!(connection, config.scope)}
  end

  @doc "Records a resume conflict for the current controller without changing its identity."
  @spec record_controller_writer_conflict(
          Store.connection(),
          config(),
          String.t(),
          keyword()
        ) :: result()
  def record_controller_writer_conflict(connection, config, thread_id, opts \\ [])
      when is_binary(thread_id) do
    Store.transaction!(connection, fn transaction ->
      row = fetch!(transaction, config.scope)

      if row["controller_thread_id"] == thread_id do
        current_time = iso(now(opts))

        Store.query!(
          transaction,
          """
          UPDATE control
          SET controller_writer_conflict_since =
                COALESCE(controller_writer_conflict_since, ?),
              controller_writer_conflict_count = controller_writer_conflict_count + 1,
              updated_at = ?
          WHERE scope = ?
          """,
          [current_time, current_time, config.scope]
        )

        %{
          result: "CONTROLLER_WRITER_CONFLICT_RECORDED",
          control: fetch!(transaction, config.scope)
        }
      else
        %{result: "STALE_CONTROLLER", control: row}
      end
    end)
  end

  @doc "Clears the resume-conflict window after the current controller is usable again."
  @spec clear_controller_writer_conflict(
          Store.connection(),
          config(),
          String.t(),
          keyword()
        ) :: result()
  def clear_controller_writer_conflict(connection, config, thread_id, opts \\ [])
      when is_binary(thread_id) do
    Store.transaction!(connection, fn transaction ->
      row = fetch!(transaction, config.scope)

      if row["controller_thread_id"] == thread_id do
        Store.query!(
          transaction,
          """
          UPDATE control
          SET controller_writer_conflict_since = NULL,
              controller_writer_conflict_count = 0,
              updated_at = ?
          WHERE scope = ?
          """,
          [iso(now(opts)), config.scope]
        )

        %{
          result: "CONTROLLER_WRITER_CONFLICT_CLEARED",
          control: fetch!(transaction, config.scope)
        }
      else
        %{result: "STALE_CONTROLLER", control: row}
      end
    end)
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  @doc """
  Activates a dispatcher when no unexpired tick lease is held.
  """
  @spec activate(Store.connection(), config(), String.t(), keyword()) :: {:ok, result()} | {:error, atom()}
  def activate(connection, config, dispatcher_id, opts \\ []) do
    set_status(connection, config, dispatcher_id, "ACTIVE", opts)
  end

  @doc """
  Pauses dispatch when no unexpired tick lease is held.
  """
  @spec pause(Store.connection(), config(), String.t(), keyword()) :: {:ok, result()} | {:error, atom()}
  def pause(connection, config, dispatcher_id, opts \\ []) do
    set_status(connection, config, dispatcher_id, "PAUSED", opts)
  end

  @doc """
  Acquires one serialized scheduler tick or returns the reason it cannot run.
  """
  @spec acquire_tick(Store.connection(), config(), String.t(), keyword()) :: result()
  def acquire_tick(connection, config, dispatcher_id, opts \\ []) do
    acquire_lease(connection, config, dispatcher_id, opts, false)
  end

  @doc "Acquires the same exclusive lease for recovery without changing paused control."
  @spec acquire_recovery_tick(Store.connection(), config(), String.t(), keyword()) :: result()
  def acquire_recovery_tick(connection, config, dispatcher_id, opts \\ []) do
    acquire_lease(connection, config, dispatcher_id, opts, true)
  end

  defp acquire_lease(connection, config, dispatcher_id, opts, recovery) do
    Store.transaction!(connection, fn transaction ->
      row = fetch!(transaction, config.scope)
      current_time = now(opts)

      cond do
        not lease_status_allowed?(row, recovery) ->
          %{result: "PAUSED", control: row}

        row["dispatcher_id"] != dispatcher_id ->
          %{result: "DISPATCHER_CONFLICT", active_dispatcher_id: row["dispatcher_id"]}

        live_lease?(row, current_time) ->
          %{
            result: "LEASE_HELD",
            tick_id: row["tick_id"],
            lease_expires_at: row["lease_expires_at"]
          }

        true ->
          tick_id = Keyword.get_lazy(opts, :tick_id, &uuid4/0)
          generation = row["generation"] + 1
          lease_seconds = Map.get(config, :lease_seconds, 240)
          expires_at = DateTime.add(current_time, lease_seconds, :second)

          Store.query!(
            transaction,
            """
            UPDATE control
            SET generation = ?, tick_id = ?, lease_expires_at = ?, updated_at = ?
            WHERE scope = ?
            """,
            [generation, tick_id, iso(expires_at), iso(current_time), config.scope]
          )

          %{
            result: "ACQUIRED",
            tick_id: tick_id,
            generation: generation,
            lease_expires_at: iso(expires_at)
          }
      end
    end)
  end

  @doc """
  Releases only the exact dispatcher and tick identity that holds the lease.
  """
  @spec release_tick(Store.connection(), config(), String.t(), String.t(), keyword()) :: result()
  def release_tick(connection, config, dispatcher_id, tick_id, opts \\ []) do
    Store.transaction!(connection, fn transaction ->
      row = fetch!(transaction, config.scope)

      if row["dispatcher_id"] == dispatcher_id and row["tick_id"] == tick_id do
        generation = row["generation"] + 1

        Store.query!(
          transaction,
          """
          UPDATE control
          SET generation = ?, tick_id = NULL, lease_expires_at = NULL, updated_at = ?
          WHERE scope = ?
          """,
          [generation, iso(now(opts)), config.scope]
        )

        %{result: "RELEASED", tick_id: tick_id, generation: generation}
      else
        %{result: "LEASE_MISMATCH", control: row}
      end
    end)
  end

  @doc """
  Extends the lease held by the exact dispatcher and tick identity.

  Renewal is deliberately identity-bound. A stale scheduler can never renew a
  lease after another tick has replaced it.
  """
  @spec renew_tick(Store.connection(), config(), String.t(), String.t(), keyword()) :: result()
  def renew_tick(connection, config, dispatcher_id, tick_id, opts \\ []) do
    renew_lease(connection, config, dispatcher_id, tick_id, opts, false)
  end

  @doc "Renews only the exact recovery lease while retaining paused control."
  @spec renew_recovery_tick(Store.connection(), config(), String.t(), String.t(), keyword()) :: result()
  def renew_recovery_tick(connection, config, dispatcher_id, tick_id, opts \\ []) do
    renew_lease(connection, config, dispatcher_id, tick_id, opts, true)
  end

  defp renew_lease(connection, config, dispatcher_id, tick_id, opts, recovery) do
    Store.transaction!(connection, fn transaction ->
      row = fetch!(transaction, config.scope)
      current_time = now(opts)

      cond do
        not lease_status_allowed?(row, recovery) ->
          %{result: "PAUSED", control: row}

        row["dispatcher_id"] != dispatcher_id or row["tick_id"] != tick_id ->
          %{result: "LEASE_MISMATCH", control: row}

        true ->
          expires_at = DateTime.add(current_time, Map.get(config, :lease_seconds, 240), :second)

          Store.query!(
            transaction,
            """
            UPDATE control
            SET lease_expires_at = ?, updated_at = ?
            WHERE scope = ?
            """,
            [iso(expires_at), iso(current_time), config.scope]
          )

          %{
            result: "LEASE_RENEWED",
            tick_id: tick_id,
            lease_expires_at: iso(expires_at)
          }
      end
    end)
  end

  defp lease_status_allowed?(row, recovery), do: row["status"] == "ACTIVE" or (recovery and row["status"] == "PAUSED")

  defp set_status(connection, config, dispatcher_id, target_status, opts) do
    Store.transaction!(connection, fn transaction ->
      row = fetch!(transaction, config.scope)
      current_time = now(opts)

      if live_lease?(row, current_time) do
        {:error, :live_tick_lease}
      else
        generation = row["generation"] + 1

        Store.query!(
          transaction,
          """
          UPDATE control
          SET status = ?, dispatcher_id = ?, generation = ?, tick_id = NULL,
              lease_expires_at = NULL, updated_at = ?
          WHERE scope = ?
          """,
          [target_status, dispatcher_id, generation, iso(current_time), config.scope]
        )

        {:ok, %{result: target_status, control: fetch!(transaction, config.scope)}}
      end
    end)
  end

  defp fetch!(connection, scope) do
    Store.one!(connection, "SELECT * FROM control WHERE scope = ?", [scope]) ||
      raise ArgumentError, "factory control row is missing for scope #{inspect(scope)}"
  end

  defp live_lease?(%{"tick_id" => nil}, _now), do: false
  defp live_lease?(%{"lease_expires_at" => nil}, _now), do: false

  defp live_lease?(row, current_time) do
    case DateTime.from_iso8601(row["lease_expires_at"]) do
      {:ok, expires_at, _offset} -> DateTime.compare(expires_at, current_time) == :gt
      {:error, _reason} -> false
    end
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
  defp iso(value), do: DateTime.to_iso8601(value)

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) |> Bitwise.bor(0x4000)
    d = Bitwise.band(d, 0x3FFF) |> Bitwise.bor(0x8000)

    Enum.join(
      [
        Integer.to_string(a, 16) |> String.pad_leading(8, "0"),
        Integer.to_string(b, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(c, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(d, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(e, 16) |> String.pad_leading(12, "0")
      ],
      "-"
    )
  end
end
