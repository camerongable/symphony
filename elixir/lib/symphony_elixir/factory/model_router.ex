defmodule SymphonyElixir.Factory.ModelRouter do
  @moduledoc """
  Resolves stable factory roles to provider-specific models and reasoning effort.

  The routing policy is provider-neutral. Delivery writers can be escalated to
  a high-risk role from either the declared risk or configured risk signals.
  """

  @reasoning_efforts ~w(none minimal low medium high xhigh max ultra)

  @type route :: %{
          result: String.t(),
          requested_role: String.t(),
          resolved_role: String.t(),
          provider: String.t(),
          model_class: String.t(),
          model: String.t(),
          reasoning_effort: String.t(),
          routing_reason: String.t()
        }

  @doc """
  Resolves a role using the configured provider and risk policy.
  """
  @spec resolve(map(), String.t(), keyword()) :: {:ok, route()} | {:error, term()}
  def resolve(policy, requested_role, opts \\ []) do
    with {:ok, resolved_role, routing_reason} <- resolve_role(policy, requested_role, opts),
         {:ok, role_policy} <- role_policy(policy, resolved_role),
         provider <-
           Keyword.get(opts, :provider) || value(role_policy, "provider") ||
             value(policy, "default_provider"),
         {:ok, provider_models} <- fetch_path(policy, ["providers", provider]),
         model_class when is_binary(model_class) <- value(role_policy, "model_class"),
         model when is_binary(model) <- value(provider_models, model_class),
         effort when effort in @reasoning_efforts <- value(role_policy, "reasoning_effort") do
      {:ok,
       %{
         result: "RESOLVED",
         requested_role: requested_role,
         resolved_role: resolved_role,
         provider: provider,
         model_class: model_class,
         model: model,
         reasoning_effort: effort,
         routing_reason: routing_reason
       }}
    else
      nil -> {:error, :missing_model_policy}
      {:error, _reason} = error -> error
      effort when is_binary(effort) -> {:error, {:unsupported_reasoning_effort, effort}}
      _other -> {:error, :invalid_model_policy}
    end
  end

  defp role_policy(policy, "workspace-maintainer") do
    case fetch_path(policy, ["roles", "workspace-maintainer"]) do
      {:ok, role} -> {:ok, role}
      {:error, _reason} -> {:ok, %{"model_class" => "fast", "reasoning_effort" => "low"}}
    end
  end

  defp role_policy(policy, role), do: fetch_path(policy, ["roles", role])

  defp resolve_role(policy, requested_role, opts) do
    delivery = value(policy, "delivery_routing") || %{}

    if requested_role == value(delivery, "default_role") do
      route_delivery_role(delivery, requested_role, opts)
    else
      {:ok, requested_role, "explicit-role"}
    end
  end

  defp route_delivery_role(delivery, requested_role, opts) do
    risk = opts |> Keyword.get(:risk) |> normalize_risk()
    provided_risk = Keyword.get(opts, :risk)

    risk_signals =
      opts
      |> Keyword.get(:risk_signals, [])
      |> normalize_values()

    high_risks = delivery |> value("high_risk_values", []) |> normalize_values()
    high_signals = delivery |> value("high_risk_signals", []) |> normalize_values()
    matched_signals = risk_signals |> MapSet.intersection(high_signals) |> Enum.sort()
    unknown_is_high = value(delivery, "unknown_risk_is_high", true)

    high_risk? =
      MapSet.member?(high_risks, risk) or matched_signals != [] or
        ((is_nil(provided_risk) or risk == "unknown") and unknown_is_high)

    if high_risk? do
      high_risk_role(delivery, risk, matched_signals)
    else
      {:ok, requested_role, "risk:#{risk}"}
    end
  end

  defp high_risk_role(delivery, risk, matched_signals) do
    case value(delivery, "high_risk_role") do
      role when is_binary(role) -> {:ok, role, high_risk_reason(risk, matched_signals)}
      _other -> {:error, :missing_high_risk_role}
    end
  end

  defp high_risk_reason(risk, []), do: "risk:#{risk}"
  defp high_risk_reason(_risk, signals), do: "high-risk-signal:#{Enum.join(signals, ",")}"

  defp fetch_path(policy, path) do
    Enum.reduce_while(path, {:ok, policy}, fn key, {:ok, current} ->
      case value(current, key) do
        nil -> {:halt, {:error, {:missing_model_policy, Enum.join(path, ".")}}}
        found -> {:cont, {:ok, found}}
      end
    end)
  end

  defp normalize_risk(nil), do: "unknown"

  defp normalize_risk(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_values(values) do
    values
    |> Enum.map(&normalize_risk/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, found} -> found
      :error -> value_from_existing_atom(map, key, default)
    end
  end

  defp value(_map, _key, default), do: default

  defp value_from_existing_atom(map, key, default) do
    Map.get(map, String.to_existing_atom(key), default)
  rescue
    ArgumentError -> default
  end
end
