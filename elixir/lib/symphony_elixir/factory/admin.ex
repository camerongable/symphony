defmodule SymphonyElixir.Factory.Admin do
  @moduledoc """
  Local administrative operations for the durable factory control plane.

  These operations open a short-lived SQLite connection, so they can pause,
  activate, or inspect a running Symphony instance without using Jira as a
  control channel.
  """

  alias SymphonyElixir.Factory.{Control, Store}

  @doc """
  Reads the local control record.
  """
  @spec status(struct() | map()) :: {:ok, map()} | {:error, term()}
  def status(factory) do
    with_store(factory, fn connection, config ->
      {:ok, Control.status(connection, config.scope)}
    end)
  end

  @doc """
  Activates a dispatcher using the configured identity unless overridden.
  """
  @spec activate(struct() | map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def activate(factory, dispatcher_id \\ nil) do
    change_status(factory, dispatcher_id, &Control.activate/4)
  end

  @doc """
  Pauses a dispatcher using the configured identity unless overridden.
  """
  @spec pause(struct() | map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def pause(factory, dispatcher_id \\ nil) do
    change_status(factory, dispatcher_id, &Control.pause/4)
  end

  defp change_status(factory, dispatcher_id, operation) do
    with_store(factory, fn connection, config ->
      operation.(connection, config, dispatcher_id || config.dispatcher_id, [])
    end)
  end

  defp with_store(factory, operation) do
    with :ok <- validate_factory(factory),
         {:ok, connection} <- Store.start_link(database: Map.fetch!(factory, :database)) do
      try do
        config = control_config(factory)
        Control.initialize(connection, config)
        operation.(connection, config)
      after
        GenServer.stop(connection)
      end
    end
  end

  defp validate_factory(factory) do
    cond do
      not Map.get(factory, :enabled, false) -> {:error, :factory_disabled}
      not present_string?(Map.get(factory, :database)) -> {:error, :missing_factory_database}
      not present_string?(Map.get(factory, :scope)) -> {:error, :missing_factory_scope}
      not present_string?(Map.get(factory, :dispatcher_id)) -> {:error, :missing_factory_dispatcher_id}
      true -> :ok
    end
  end

  defp control_config(factory) do
    %{
      scope: Map.fetch!(factory, :scope),
      dispatcher_id: Map.fetch!(factory, :dispatcher_id),
      lease_seconds: Map.get(factory, :lease_seconds, 240)
    }
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
