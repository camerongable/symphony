defmodule SymphonyElixir.Factory.TicketMrPresendEvidence do
  @moduledoc "Read-only recognition of one positively rejected historical broker invocation."
  alias SymphonyElixir.Factory.{BrokerRuntime, TicketMrOwnerAdmission}
  alias SymphonyElixir.PathSafety

  @program Path.expand("../../../priv/ticket_mr_presend_evidence_v3.py", __DIR__)
  @registry Path.expand("../../../priv/ticket_mr_presend_registry_v3.json", __DIR__)
  @external_resource @program
  @external_resource @registry
  @program_sha256 @program |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  @registry_sha256 @registry |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  @policy @registry |> File.read!() |> Jason.decode!()

  @spec incident?(map(), String.t()) :: boolean()
  def incident?(request, broker) do
    {request["request_key"], request["claimed_at"], broker} ==
      {@policy["incident"]["request_key"], @policy["incident"]["claimed_at"], @policy["broker_thread_id"]}
  end

  @spec read(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def read(request, broker, native), do: run(request, broker, native, nil)

  @spec recheck(map(), String.t(), map(), TicketMrOwnerAdmission.t()) :: {:ok, map()} | {:error, term()}
  def recheck(request, broker, native, %TicketMrOwnerAdmission{} = context) do
    with true <- (is_map(context.factory) and is_binary(Map.get(context.factory, :database))) or {:error, :mr_owner_service_authority_required},
         true <- BrokerRuntime.owner_admission_active?(context) or {:error, :mr_owner_service_authority_required},
         true <- context.action == :recover and context.broker == broker and context.prepared.request == request,
         %{evidence: previous} <- Map.get(context, :presend_recovery) do
      run(request, broker, native, previous, context)
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_presend_context_unproven}
    end
  end

  def recheck(_, _, _, _), do: {:error, :mr_owner_service_authority_required}

  defp run(request, broker, native, previous, context \\ nil) do
    with true <- incident?(request, broker) or {:error, :mr_presend_request_unproven},
         {:ok, fence} <- recovery_projection(native, broker),
         {:ok, program} <- pinned("ticket_mr_presend_evidence_v3.py", @program_sha256),
         {:ok, _registry} <- pinned("ticket_mr_presend_registry_v3.json", @registry_sha256),
         payload = %{
           "expected" => %{
             "request_key" => request["request_key"],
             "claimed_at" => request["claimed_at"],
             "broker_thread_id" => broker,
             "latest_turn_id" => fence["turn_id"],
             "latest_turn_status" => fence["turn_status"],
             "now_ms" => System.system_time(:millisecond),
             "require_source" => fence["turn_status"] != "completed",
             "prepare_handle" => if(context, do: context.handle),
             "prepare_payload_sha256" => if(context, do: context.prepared.request["payload_sha256"]),
             "prepare_expires_at" => if(context, do: DateTime.to_iso8601(context.expires_at)),
             "prepare_source_item_id" => if(context, do: get_in(context.presend_recovery.evidence, ["source_observation", "item_id"]))
           },
           "previous" => previous
         },
         json = Jason.encode!(payload),
         true <- byte_size(json) <= 131_072 or {:error, :mr_presend_input_limit},
         {raw, code} <- System.cmd("/usr/bin/python3", ["-I", "-S", "-B", program, Base.encode64(json)], stderr_to_stdout: true),
         true <- byte_size(raw) <= 262_144 or {:error, :mr_presend_output_limit},
         {:ok, response} <- Jason.decode(raw),
         {:ok, proof} <- result(code, response),
         true <- proof["registry_sha256"] == @registry_sha256 or {:error, :mr_presend_registry_changed} do
      {:ok, proof}
    else
      {:error, _} = error -> error
      _ -> {:error, :mr_presend_evidence_unproven}
    end
  end

  @spec native_fence(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def native_fence(native, broker) do
    with {:ok, fence} <- recovery_projection(native, broker),
         true <- fence["turn_status"] in ~w(completed inProgress) do
      {:ok, fence}
    else
      _ -> {:error, :mr_presend_broker_native_unproven}
    end
  end

  @doc false
  @spec recovery_projection(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def recovery_projection(native, broker) do
    with true <- {native["id"], native["cwd"], Map.fetch(native, "projectId")} == {broker, @policy["broker_cwd"], {:ok, nil}},
         %{"mode" => "LATEST_DESC", "raw_response" => %{"data" => [turn]} = raw, "updated_at" => version, "sha256" => sha} = latest <- native["latest_turn_observation"],
         true <- is_number(version) and version == native["updatedAt"] and sha == digest(raw),
         %{"raw_response" => %{"data" => [^turn]} = confirmation, "sha256" => confirmation_sha} <- latest["confirmation"],
         true <- confirmation_sha == digest(confirmation),
         %{"thread_id" => ^broker, "raw_response" => %{"data" => queue_items} = queued, "sha256" => queue_sha} <- native["queue_observation"],
         true <- is_list(queue_items),
         true <- queue_sha == digest(queued),
         true <- is_binary(turn["id"]) and turn["status"] in ~w(completed inProgress interrupted),
         true <- turn["status"] != "interrupted" or native["status"] == %{"type" => "notLoaded"} do
      identity = %{"id" => broker, "cwd" => native["cwd"], "updated_at" => version, "turn_id" => turn["id"]}
      {:ok, Map.merge(identity, %{"turn_status" => turn["status"], "latest_sha256" => sha, "queue_sha256" => queue_sha})}
    else
      _ -> {:error, :mr_presend_broker_native_unproven}
    end
  end

  defp result(0, %{"ok" => proof}) when is_map(proof), do: {:ok, proof}
  defp result(1, %{"error" => error}) when is_binary(error), do: {:error, error}
  defp result(_, _), do: {:error, :mr_presend_evidence_unproven}

  defp pinned(name, expected) do
    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/" <> name)),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, raw} <- File.read(path),
         true <- digest_raw(raw) == expected do
      {:ok, path}
    else
      _ -> {:error, :mr_presend_program_changed}
    end
  end

  defp digest(value), do: value |> Jason.encode!() |> digest_raw()
  defp digest_raw(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
