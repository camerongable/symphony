defmodule SymphonyElixir.Factory.TicketPushIO do
  @moduledoc "Once-only owned controller Git push and immutable stopped-process readback."
  alias SymphonyElixir.Factory.{Store, TicketCheckoutIO, WorkerFileIO}
  alias SymphonyElixir.PathSafety
  require Logger
  @helper Path.expand("../../../priv/ticket_push_executor_v2.py", __DIR__)
  @external_resource @helper
  @helper_sha :crypto.hash(:sha256, File.read!(@helper)) |> Base.encode16(case: :lower)
  @legacy_helper Path.expand("../../../priv/ticket_push_executor.py", __DIR__)
  @external_resource @legacy_helper
  @legacy_helper_sha :crypto.hash(:sha256, File.read!(@legacy_helper)) |> Base.encode16(case: :lower)
  @audited_unissuable_v1 "455102866c2b0264aa1e894d1a665999b88dfdccab842b02f22ee5977c73d29e"
  @git "/Library/Developer/CommandLineTools/usr/bin/git"
  @limit 262_144

  @spec prepare(Store.connection(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(store, intent, authorization) do
    binding = Jason.decode!(intent["binding_json"])

    with {:ok, helper} <- helper(binding["repo_path"]),
         :ok <- WorkerFileIO.program_outside_source(helper, binding["worktree"]),
         {:ok, spool} <- WorkerFileIO.controller_spool(store, binding["repo_path"]),
         {:ok, program} <- File.read(@git) do
      environment = %{
        "HOME" => System.user_home!(),
        "PATH" => "/usr/bin:/bin:/Library/Developer/CommandLineTools/usr/bin",
        "LC_ALL" => "C",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_NO_LAZY_FETCH" => "1",
        "GIT_NO_REPLACE_OBJECTS" => "1"
      }

      environment = Enum.reduce(~w(SSH_AUTH_SOCK GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM), environment, &environment_entry/2)

      {:ok,
       Map.merge(spool, %{
         "invocation" => intent["owner_nonce"],
         "intent_json" => intent["binding_json"],
         "intent_sha256" => intent["binding_sha256"],
         "run_id" => binding["run_id"],
         "helper_path" => helper,
         "helper_sha256" => @helper_sha,
         "program_sha256" => hash(program),
         "authorization" => authorization,
         "git_environment" => environment
       })}
    end
  end

  @spec execute(map(), (pos_integer(), String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def execute(execution, started), do: exchange(execution, nil, "--execute", started)

  @spec readback(map()) :: {:ok, String.t()} | {:error, term()}
  def readback(intent) do
    with {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || ""),
         true <- is_integer(intent["helper_pid"]) do
      exchange(execution, intent["helper_pid"], "--status", nil)
    else
      _ -> {:error, :ticket_push_execution_unproven}
    end
  end

  @spec receipt_valid?(String.t(), map()) :: boolean()
  def receipt_valid?(raw, intent) do
    case Jason.decode(intent["binding_json"] || "") do
      {:ok, %{"run_id" => run_id}} when is_binary(run_id) ->
        TicketCheckoutIO.receipt_valid?(raw, Map.put(intent, "run_id", run_id))

      _ ->
        false
    end
  end

  @spec rejection_reason(String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def rejection_reason(raw, intent) do
    with {:ok, receipt} when is_map(receipt) <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(receipt)) == Enum.sort(~w(version kind execution_json helper_pid child_pid reason)),
         true <- receipt["version"] == 1 and receipt["kind"] == "PREISSUANCE_REJECTED" and is_nil(receipt["child_pid"]),
         true <- receipt["execution_json"] == intent["execution_json"] and receipt["helper_pid"] == intent["helper_pid"],
         {:ok, execution} <- Jason.decode(intent["execution_json"]),
         true <- execution["helper_sha256"] == @helper_sha,
         reason when is_binary(reason) <- receipt["reason"],
         true <- String.match?(reason, ~r/\A[A-Za-z_]{1,80}\z/) do
      {:ok, reason}
    else
      _ -> {:error, :ticket_push_rejection_unproven}
    end
  end

  @doc "Attests only the audited v1 contradictory bootstrap predicate, never historical execution success."
  @spec unissuable_v1_proof(map()) :: {:ok, String.t()} | {:error, atom()}
  def unissuable_v1_proof(intent) do
    with {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || "null"),
         {:ok, binding} when is_map(binding) <- Jason.decode(intent["binding_json"] || "null"),
         true <- intent["phase"] in ~w(PUSH_UNCERTAIN UNISSUABLE),
         true <- is_integer(intent["helper_pid"]) and intent["helper_pid"] > 0,
         true <- execution["helper_sha256"] == @audited_unissuable_v1 and @legacy_helper_sha == @audited_unissuable_v1,
         {:ok, _} <- execution_helper(execution, "--status"),
         true <- get_in(binding, ["bootstrap", "status"]) == "FAILED" and get_in(binding, ["bootstrap", "action"]) == "CREATE",
         true <-
           {execution["intent_json"], execution["intent_sha256"], execution["invocation"], execution["run_id"]} ==
             {intent["binding_json"], hash(intent["binding_json"]), intent["owner_nonce"], binding["run_id"]},
         {:ok, companion} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/worker_file_companion.py")),
         true <- companion == execution["companion_path"],
         {:ok, companion_raw} <- File.read(companion),
         true <- hash(companion_raw) == execution["companion_sha256"],
         {:ok, spool} <- PathSafety.canonicalize(execution["spool"]),
         true <- spool == execution["spool"],
         {:ok, stat} <- File.lstat(spool),
         true <- {stat.type, stat.major_device, stat.inode} == {:directory, execution["spool_device"], execution["spool_inode"]},
         true <- String.match?(intent["owner_nonce"], ~r/\A[0-9a-f]{64}\z/),
         true <- Enum.all?(~w(.push-claim .push-receipt .push-rejection), fn suffix -> File.lstat(Path.join(spool, intent["owner_nonce"] <> suffix)) == {:error, :enoent} end) do
      {:ok,
       Jason.encode!(%{
         "kind" => "CONTROLLER_UNISSUABLE_V1",
         "helper_sha256" => @audited_unissuable_v1,
         "execution_sha256" => hash(intent["execution_json"]),
         "binding_sha256" => hash(intent["binding_json"]),
         "predicate" => "captured FAILED equality and live SUCCEEDED required before issuance",
         "original_nonce" => intent["owner_nonce"]
       })}
    else
      _ -> {:error, :ticket_push_unissuable_v1_unproven}
    end
  rescue
    _ -> {:error, :ticket_push_unissuable_v1_unproven}
  end

  defp exchange(execution, original_pid, mode, started) do
    case execution_helper(execution, mode) do
      {:ok, path} ->
        port =
          Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(["-I", "-S", "-B", path, mode], &String.to_charlist/1),
            env: Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)
          ])

        try do
          {:os_pid, pid} = Port.info(port, :os_pid)
          encoded = Jason.encode!(execution)
          result = if started, do: started.(pid, encoded), else: {:ok, %{}}

          with {:ok, _} <- result do
            input = Jason.encode!(%{"execution_json" => encoded, "helper_pid" => original_pid || pid})
            true = Port.command(port, <<byte_size(input)::unsigned-big-32, input::binary>>)
            collect(port, "", System.monotonic_time(:millisecond) + 35_000)
          end
        after
          if Port.info(port) != nil, do: Port.close(port)
        end

      _ ->
        {:error, :ticket_push_program_changed}
    end
  rescue
    _ -> {:error, :ticket_push_transport_unproven}
  end

  defp collect(port, raw, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(raw) + byte_size(bytes) <= @limit + 4 ->
        collect(port, raw <> bytes, deadline)

      {^port, {:exit_status, 0}} ->
        frame(raw)

      {^port, {:exit_status, code}} ->
        reason =
          case Regex.run(~r/ValueError: ([a-z_]+)\s*\z/, raw) do
            [_, value] when value in ~w(program_changed frame_rejected packet_rejected execution_changed claim_changed bootstrap_changed nonce_rejected) -> value
            _ -> "unclassified"
          end

        Logger.warning("Ticket push transport failed exit_status=#{code} reason=#{reason}")
        {:error, :ticket_push_transport_unproven}

      {^port, _} ->
        {:error, :ticket_push_transport_unproven}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :ticket_push_transport_unproven}
    end
  end

  defp frame(<<size::unsigned-big-32, raw::binary>>) when byte_size(raw) == size, do: {:ok, raw}
  defp frame(_), do: {:error, :ticket_push_transport_unproven}

  defp execution_helper(%{"helper_sha256" => @legacy_helper_sha} = execution, "--status") do
    with {:ok, original} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_executor.py")),
         true <- execution["helper_path"] == original,
         {:ok, legacy} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_executor.py")),
         :ok <- WorkerFileIO.program_outside_source(legacy, execution["root"]),
         {:ok, raw} <- File.read(legacy),
         true <- hash(raw) == @legacy_helper_sha do
      {:ok, legacy}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp execution_helper(execution, _mode) do
    with {:ok, path} <- helper(execution["root"]),
         true <- path == execution["helper_path"] and execution["helper_sha256"] == @helper_sha do
      {:ok, path}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp helper(root) do
    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_executor_v2.py")),
         :ok <- WorkerFileIO.program_outside_source(path, root),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == @helper_sha do
      {:ok, path}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  defp environment_entry(key, acc) do
    case System.get_env(key) do
      nil -> acc
      value -> Map.put(acc, key, value)
    end
  end
end
