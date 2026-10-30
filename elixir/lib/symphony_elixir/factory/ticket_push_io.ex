defmodule SymphonyElixir.Factory.TicketPushIO do
  @moduledoc "Once-only owned controller Git push and immutable stopped-process readback."
  alias SymphonyElixir.Factory.{
    RunLedger,
    Store,
    TicketCheckoutIO,
    TicketCiRepair,
    TicketCiRepairSuccessor,
    TicketPushWorkerHistory,
    TicketWorkerRunner,
    WorkerFileIO
  }

  alias SymphonyElixir.Factory.TicketPushPreissuanceRejection
  alias SymphonyElixir.PathSafety
  require Logger
  @helper Path.expand("../../../priv/ticket_push_executor_v2.py", __DIR__)
  @external_resource @helper
  @helper_sha :crypto.hash(:sha256, File.read!(@helper)) |> Base.encode16(case: :lower)
  @ci_helper Path.expand("../../../priv/ticket_push_executor_v3.py", __DIR__)
  @external_resource @ci_helper
  @ci_helper_sha :crypto.hash(:sha256, File.read!(@ci_helper)) |> Base.encode16(case: :lower)
  @next_ci_helper Path.expand("../../../priv/ticket_push_executor_v4.py", __DIR__)
  @external_resource @next_ci_helper
  @next_ci_helper_sha :crypto.hash(:sha256, File.read!(@next_ci_helper)) |> Base.encode16(case: :lower)
  @history_helper Path.expand("../../../priv/ticket_push_recovery_executor.py", __DIR__)
  @external_resource @history_helper
  @previous_successor_helper Path.expand("../../../priv/ticket_push_executor_v5.py", __DIR__)
  @external_resource @previous_successor_helper
  @previous_successor_helper_sha :crypto.hash(:sha256, File.read!(@previous_successor_helper)) |> Base.encode16(case: :lower)
  @successor_helper Path.expand("../../../priv/ticket_push_executor_v6.py", __DIR__)
  @external_resource @successor_helper
  @successor_helper_sha :crypto.hash(:sha256, File.read!(@successor_helper)) |> Base.encode16(case: :lower)
  @successor_history Path.expand("../../../priv/ticket_push_history_validator_v3.py", __DIR__)
  @external_resource @successor_history
  @previous_import_helper Path.expand("../../../priv/ticket_push_executor_v7.py", __DIR__)
  @external_resource @previous_import_helper
  @previous_import_helper_sha :crypto.hash(:sha256, File.read!(@previous_import_helper)) |> Base.encode16(case: :lower)
  @import_helper Path.expand("../../../priv/ticket_push_executor_v8.py", __DIR__)
  @external_resource @import_helper
  @import_helper_sha :crypto.hash(:sha256, File.read!(@import_helper)) |> Base.encode16(case: :lower)
  @import_history Path.expand("../../../priv/ticket_push_history_validator_v5.py", __DIR__)
  @external_resource @import_history
  @ordinary_helper Path.expand("../../../priv/ticket_push_executor_v9.py", __DIR__)
  @external_resource @ordinary_helper
  @ordinary_helper_sha :crypto.hash(:sha256, File.read!(@ordinary_helper)) |> Base.encode16(case: :lower)
  @ordinary_history Path.expand("../../../priv/ticket_push_history_validator_v6.py", __DIR__)
  @external_resource @ordinary_history
  @budget_helper Path.expand("../../../priv/ticket_push_executor_v10.py", __DIR__)
  @external_resource @budget_helper
  @budget_helper_sha :crypto.hash(:sha256, File.read!(@budget_helper)) |> Base.encode16(case: :lower)
  @current_helper Path.expand("../../../priv/ticket_push_executor_v11.py", __DIR__)
  @external_resource @current_helper
  @current_helper_sha :crypto.hash(:sha256, File.read!(@current_helper)) |> Base.encode16(case: :lower)
  @current_history Path.expand("../../../priv/ticket_push_history_validator_v8.py", __DIR__)
  @external_resource @current_history
  @previous_large_helper Path.expand("../../../priv/ticket_push_executor_v12.py", __DIR__)
  @external_resource @previous_large_helper
  @previous_large_helper_sha :crypto.hash(:sha256, File.read!(@previous_large_helper)) |> Base.encode16(case: :lower)
  @previous_large_history Path.expand("../../../priv/ticket_push_history_validator_v9.py", __DIR__)
  @external_resource @previous_large_history
  @previous_large_history_sha :crypto.hash(:sha256, File.read!(@previous_large_history)) |> Base.encode16(case: :lower)
  @origin_helper Path.expand("../../../priv/ticket_push_executor_v13.py", __DIR__)
  @external_resource @origin_helper
  @origin_helper_sha :crypto.hash(:sha256, File.read!(@origin_helper)) |> Base.encode16(case: :lower)
  @origin_history Path.expand("../../../priv/ticket_push_history_validator_v10.py", __DIR__)
  @external_resource @origin_history
  @origin_history_sha :crypto.hash(:sha256, File.read!(@origin_history)) |> Base.encode16(case: :lower)
  @large_helper Path.expand("../../../priv/ticket_push_executor_v14.py", __DIR__)
  @external_resource @large_helper
  @large_helper_sha :crypto.hash(:sha256, File.read!(@large_helper)) |> Base.encode16(case: :lower)
  @large_history Path.expand("../../../priv/ticket_push_history_validator_v11.py", __DIR__)
  @external_resource @large_history
  @large_history_sha :crypto.hash(:sha256, File.read!(@large_history)) |> Base.encode16(case: :lower)
  @previous_capability_helper Path.expand("../../../priv/ticket_push_executor_v15.py", __DIR__)
  @external_resource @previous_capability_helper
  @previous_capability_helper_sha :crypto.hash(:sha256, File.read!(@previous_capability_helper)) |> Base.encode16(case: :lower)
  @previous_capability_history Path.expand("../../../priv/ticket_push_history_validator_v12.py", __DIR__)
  @external_resource @previous_capability_history
  @previous_capability_history_sha :crypto.hash(:sha256, File.read!(@previous_capability_history)) |> Base.encode16(case: :lower)
  @retained_capability_helper Path.expand("../../../priv/ticket_push_executor_v16.py", __DIR__)
  @external_resource @retained_capability_helper
  @retained_capability_helper_sha :crypto.hash(:sha256, File.read!(@retained_capability_helper)) |> Base.encode16(case: :lower)
  @retained_capability_history Path.expand("../../../priv/ticket_push_history_validator_v13.py", __DIR__)
  @external_resource @retained_capability_history
  @retained_capability_history_sha :crypto.hash(:sha256, File.read!(@retained_capability_history)) |> Base.encode16(case: :lower)
  @legacy_v17_helper Path.expand("../../../priv/ticket_push_executor_v17.py", __DIR__)
  @external_resource @legacy_v17_helper
  @legacy_v17_helper_sha :crypto.hash(:sha256, File.read!(@legacy_v17_helper)) |> Base.encode16(case: :lower)
  @legacy_v17_history Path.expand("../../../priv/ticket_push_history_validator_v14.py", __DIR__)
  @external_resource @legacy_v17_history
  @legacy_v17_history_sha :crypto.hash(:sha256, File.read!(@legacy_v17_history)) |> Base.encode16(case: :lower)
  @legacy_v18_helper Path.expand("../../../priv/ticket_push_executor_v18.py", __DIR__)
  @external_resource @legacy_v18_helper
  @legacy_v18_helper_sha :crypto.hash(:sha256, File.read!(@legacy_v18_helper)) |> Base.encode16(case: :lower)
  @legacy_v18_history Path.expand("../../../priv/ticket_push_history_validator_v15.py", __DIR__)
  @external_resource @legacy_v18_history
  @legacy_v18_history_sha :crypto.hash(:sha256, File.read!(@legacy_v18_history)) |> Base.encode16(case: :lower)
  @legacy_v19_helper Path.expand("../../../priv/ticket_push_executor_v19.py", __DIR__)
  @external_resource @legacy_v19_helper
  @legacy_v19_helper_sha :crypto.hash(:sha256, File.read!(@legacy_v19_helper)) |> Base.encode16(case: :lower)
  @legacy_v19_history Path.expand("../../../priv/ticket_push_history_validator_v16.py", __DIR__)
  @external_resource @legacy_v19_history
  @legacy_v19_history_sha :crypto.hash(:sha256, File.read!(@legacy_v19_history)) |> Base.encode16(case: :lower)
  @legacy_v20_helper Path.expand("../../../priv/ticket_push_executor_v20.py", __DIR__)
  @external_resource @legacy_v20_helper
  @legacy_v20_helper_sha :crypto.hash(:sha256, File.read!(@legacy_v20_helper)) |> Base.encode16(case: :lower)
  @legacy_v20_history Path.expand("../../../priv/ticket_push_history_validator_v17.py", __DIR__)
  @external_resource @legacy_v20_history
  @legacy_v20_history_sha :crypto.hash(:sha256, File.read!(@legacy_v20_history)) |> Base.encode16(case: :lower)
  @acknowledged_helper Path.expand("../../../priv/ticket_push_executor_v22.py", __DIR__)
  @external_resource @acknowledged_helper
  @acknowledged_helper_sha :crypto.hash(:sha256, File.read!(@acknowledged_helper)) |> Base.encode16(case: :lower)
  @capability_helper Path.expand("../../../priv/ticket_push_executor_v21.py", __DIR__)
  @external_resource @capability_helper
  @capability_helper_sha :crypto.hash(:sha256, File.read!(@capability_helper)) |> Base.encode16(case: :lower)
  @capability_history Path.expand("../../../priv/ticket_push_history_validator_v18.py", __DIR__)
  @external_resource @capability_history
  @capability_history_sha :crypto.hash(:sha256, File.read!(@capability_history)) |> Base.encode16(case: :lower)
  @review_helper Path.expand("../../../priv/ticket_push_executor_v23.py", __DIR__)
  @external_resource @review_helper
  @review_helper_sha :crypto.hash(:sha256, File.read!(@review_helper)) |> Base.encode16(case: :lower)
  @review_capability_helper Path.expand("../../../priv/ticket_push_executor_v24.py", __DIR__)
  @external_resource @review_capability_helper
  @review_capability_helper_sha :crypto.hash(:sha256, File.read!(@review_capability_helper)) |> Base.encode16(case: :lower)
  @review_history Path.expand("../../../priv/ticket_push_history_validator_v19.py", __DIR__)
  @external_resource @review_history
  @review_history_sha :crypto.hash(:sha256, File.read!(@review_history)) |> Base.encode16(case: :lower)
  @current_review_helper Path.expand("../../../priv/ticket_push_executor_v25.py", __DIR__)
  @external_resource @current_review_helper
  @current_review_helper_sha :crypto.hash(:sha256, File.read!(@current_review_helper)) |> Base.encode16(case: :lower)
  @current_review_capability_helper Path.expand("../../../priv/ticket_push_executor_v26.py", __DIR__)
  @external_resource @current_review_capability_helper
  @current_review_capability_helper_sha :crypto.hash(:sha256, File.read!(@current_review_capability_helper)) |> Base.encode16(case: :lower)
  @current_review_history Path.expand("../../../priv/ticket_push_history_validator_v20.py", __DIR__)
  @external_resource @current_review_history
  @current_review_history_sha :crypto.hash(:sha256, File.read!(@current_review_history)) |> Base.encode16(case: :lower)
  @typed_review_helper Path.expand("../../../priv/ticket_push_executor_v27.py", __DIR__)
  @external_resource @typed_review_helper
  @typed_review_helper_sha :crypto.hash(:sha256, File.read!(@typed_review_helper)) |> Base.encode16(case: :lower)
  @typed_review_capability_helper Path.expand("../../../priv/ticket_push_executor_v28.py", __DIR__)
  @external_resource @typed_review_capability_helper
  @typed_review_capability_helper_sha :crypto.hash(:sha256, File.read!(@typed_review_capability_helper)) |> Base.encode16(case: :lower)
  @typed_review_history Path.expand("../../../priv/ticket_push_history_validator_v21.py", __DIR__)
  @external_resource @typed_review_history
  @typed_review_history_sha :crypto.hash(:sha256, File.read!(@typed_review_history)) |> Base.encode16(case: :lower)
  @writer_readiness_helper Path.expand("../../../priv/ticket_push_executor_v29.py", __DIR__)
  @external_resource @writer_readiness_helper
  @writer_readiness_helper_sha :crypto.hash(:sha256, File.read!(@writer_readiness_helper)) |> Base.encode16(case: :lower)
  @writer_readiness_capability_helper Path.expand("../../../priv/ticket_push_executor_v30.py", __DIR__)
  @external_resource @writer_readiness_capability_helper
  @writer_readiness_capability_helper_sha :crypto.hash(:sha256, File.read!(@writer_readiness_capability_helper)) |> Base.encode16(case: :lower)
  @writer_readiness_history Path.expand("../../../priv/ticket_push_history_validator_v22.py", __DIR__)
  @external_resource @writer_readiness_history
  @writer_readiness_history_sha :crypto.hash(:sha256, File.read!(@writer_readiness_history)) |> Base.encode16(case: :lower)
  @ordinary_bindings_helper Path.expand("../../../priv/ticket_push_executor_v31.py", __DIR__)
  @external_resource @ordinary_bindings_helper
  @ordinary_bindings_helper_sha :crypto.hash(:sha256, File.read!(@ordinary_bindings_helper)) |> Base.encode16(case: :lower)
  @ordinary_bindings_capability_helper Path.expand("../../../priv/ticket_push_executor_v32.py", __DIR__)
  @external_resource @ordinary_bindings_capability_helper
  @ordinary_bindings_capability_helper_sha :crypto.hash(:sha256, File.read!(@ordinary_bindings_capability_helper)) |> Base.encode16(case: :lower)
  @ordinary_bindings_history Path.expand("../../../priv/ticket_push_history_validator_v23.py", __DIR__)
  @external_resource @ordinary_bindings_history
  @ordinary_bindings_history_sha :crypto.hash(:sha256, File.read!(@ordinary_bindings_history)) |> Base.encode16(case: :lower)
  @retained_publisher_helper Path.expand("../../../priv/ticket_push_executor_v33.py", __DIR__)
  @external_resource @retained_publisher_helper
  @retained_publisher_helper_sha :crypto.hash(:sha256, File.read!(@retained_publisher_helper)) |> Base.encode16(case: :lower)
  @retained_publisher_capability_helper Path.expand("../../../priv/ticket_push_executor_v34.py", __DIR__)
  @external_resource @retained_publisher_capability_helper
  @retained_publisher_capability_helper_sha :crypto.hash(:sha256, File.read!(@retained_publisher_capability_helper)) |> Base.encode16(case: :lower)
  @retained_publisher_history Path.expand("../../../priv/ticket_push_history_validator_v24.py", __DIR__)
  @external_resource @retained_publisher_history
  @retained_publisher_history_sha :crypto.hash(:sha256, File.read!(@retained_publisher_history)) |> Base.encode16(case: :lower)
  @generation_publisher_helper Path.expand("../../../priv/ticket_push_executor_v35.py", __DIR__)
  @external_resource @generation_publisher_helper
  @generation_publisher_helper_sha :crypto.hash(:sha256, File.read!(@generation_publisher_helper)) |> Base.encode16(case: :lower)
  @generation_publisher_capability_helper Path.expand("../../../priv/ticket_push_executor_v36.py", __DIR__)
  @external_resource @generation_publisher_capability_helper
  @generation_publisher_capability_helper_sha :crypto.hash(:sha256, File.read!(@generation_publisher_capability_helper)) |> Base.encode16(case: :lower)
  @generation_publisher_history Path.expand("../../../priv/ticket_push_history_validator_v25.py", __DIR__)
  @external_resource @generation_publisher_history
  @generation_publisher_history_sha :crypto.hash(:sha256, File.read!(@generation_publisher_history)) |> Base.encode16(case: :lower)
  @publication_compat_helper Path.expand("../../../priv/ticket_push_executor_v37.py", __DIR__)
  @external_resource @publication_compat_helper
  @publication_compat_helper_sha :crypto.hash(:sha256, File.read!(@publication_compat_helper)) |> Base.encode16(case: :lower)
  @publication_compat_capability_helper Path.expand("../../../priv/ticket_push_executor_v38.py", __DIR__)
  @external_resource @publication_compat_capability_helper
  @publication_compat_capability_helper_sha :crypto.hash(:sha256, File.read!(@publication_compat_capability_helper)) |> Base.encode16(case: :lower)
  @publication_compat_history Path.expand("../../../priv/ticket_push_history_validator_v26.py", __DIR__)
  @external_resource @publication_compat_history
  @publication_compat_history_sha :crypto.hash(:sha256, File.read!(@publication_compat_history)) |> Base.encode16(case: :lower)
  @file_source_publication_helper Path.expand("../../../priv/ticket_push_executor_v39.py", __DIR__)
  @external_resource @file_source_publication_helper
  @file_source_publication_helper_sha :crypto.hash(:sha256, File.read!(@file_source_publication_helper)) |> Base.encode16(case: :lower)
  @file_source_publication_capability_helper Path.expand("../../../priv/ticket_push_executor_v40.py", __DIR__)
  @external_resource @file_source_publication_capability_helper
  @file_source_publication_capability_helper_sha :crypto.hash(:sha256, File.read!(@file_source_publication_capability_helper)) |> Base.encode16(case: :lower)
  @file_source_publication_history Path.expand("../../../priv/ticket_push_history_validator_v27.py", __DIR__)
  @external_resource @file_source_publication_history
  @file_source_publication_history_sha :crypto.hash(:sha256, File.read!(@file_source_publication_history)) |> Base.encode16(case: :lower)
  @capability_origins Path.expand("../../../priv/ticket_push_readback_origins_v20.json", __DIR__)
  @external_resource @capability_origins
  @capability_origins_raw File.read!(@capability_origins)
  @capability_origins_sha :crypto.hash(:sha256, @capability_origins_raw) |> Base.encode16(case: :lower)
  @capability_reader Path.expand("../../../priv/ticket_push_status_reader_v21.py", __DIR__)
  @external_resource @capability_reader
  @capability_reader_sha :crypto.hash(:sha256, File.read!(@capability_reader)) |> Base.encode16(case: :lower)
  @large_helper_shas [
    @retained_publisher_helper_sha,
    @generation_publisher_helper_sha,
    @publication_compat_helper_sha,
    @file_source_publication_helper_sha,
    @ordinary_bindings_helper_sha,
    @retained_publisher_capability_helper_sha,
    @generation_publisher_capability_helper_sha,
    @publication_compat_capability_helper_sha,
    @file_source_publication_capability_helper_sha,
    @ordinary_bindings_capability_helper_sha,
    @writer_readiness_helper_sha,
    @typed_review_helper_sha,
    @current_review_helper_sha,
    @writer_readiness_capability_helper_sha,
    @typed_review_capability_helper_sha,
    @current_review_capability_helper_sha,
    @capability_helper_sha,
    @review_helper_sha,
    @review_capability_helper_sha,
    @acknowledged_helper_sha,
    @legacy_v20_helper_sha,
    @legacy_v19_helper_sha,
    @legacy_v18_helper_sha,
    @legacy_v17_helper_sha,
    @retained_capability_helper_sha,
    @previous_capability_helper_sha,
    @large_helper_sha,
    @previous_large_helper_sha,
    @origin_helper_sha
  ]
  @legacy_helper Path.expand("../../../priv/ticket_push_executor.py", __DIR__)
  @external_resource @legacy_helper
  @legacy_helper_sha :crypto.hash(:sha256, File.read!(@legacy_helper)) |> Base.encode16(case: :lower)
  @companion Path.expand("../../../priv/worker_file_companion.py", __DIR__)
  @external_resource @companion
  @companion_sha :crypto.hash(:sha256, File.read!(@companion)) |> Base.encode16(case: :lower)
  @status_origins Path.expand("../../../priv/ticket_push_readback_origins_v1.json", __DIR__)
  @external_resource @status_origins
  @status_origins_raw File.read!(@status_origins)
  @status_origins_sha :crypto.hash(:sha256, @status_origins_raw) |> Base.encode16(case: :lower)
  @ordinary_status_origins Path.expand("../../../priv/ticket_push_readback_origins_v3.json", __DIR__)
  @external_resource @ordinary_status_origins
  @ordinary_status_origins_raw File.read!(@ordinary_status_origins)
  @ordinary_status_origins_sha :crypto.hash(:sha256, @ordinary_status_origins_raw) |> Base.encode16(case: :lower)
  @status_entry_keys ~w(manifest_path manifest_sha256 helper_path helper_sha256 companion_path companion_sha256)
  @attested_origins Path.expand("../../../priv/ticket_push_readback_origins_v2.json", __DIR__)
  @external_resource @attested_origins
  @attested_origins_raw File.read!(@attested_origins)
  @attested_origins_sha :crypto.hash(:sha256, @attested_origins_raw) |> Base.encode16(case: :lower)
  @status_reader Path.expand("../../../priv/ticket_push_status_reader_v1.py", __DIR__)
  @external_resource @status_reader
  @status_reader_sha :crypto.hash(:sha256, File.read!(@status_reader)) |> Base.encode16(case: :lower)
  @audited_unissuable_v1 "455102866c2b0264aa1e894d1a665999b88dfdccab842b02f22ee5977c73d29e"
  @git "/Library/Developer/CommandLineTools/usr/bin/git"
  @limit 262_144
  @receipt_limit 1_048_576
  @request_limit 1_048_576
  @large_receipt_limit 4_194_304
  @bounded_origins Path.expand("../../../priv/ticket_push_readback_origins_v4.json", __DIR__)
  @external_resource @bounded_origins
  @bounded_origins_raw File.read!(@bounded_origins)
  @bounded_origins_sha :crypto.hash(:sha256, @bounded_origins_raw) |> Base.encode16(case: :lower)
  @bounded_reader Path.expand("../../../priv/ticket_push_status_reader_v2.py", __DIR__)
  @external_resource @bounded_reader
  @bounded_reader_sha :crypto.hash(:sha256, File.read!(@bounded_reader)) |> Base.encode16(case: :lower)
  @large_origins Path.expand("../../../priv/ticket_push_readback_origins_v7.json", __DIR__)
  @external_resource @large_origins
  @large_origins_raw File.read!(@large_origins)
  @large_origins_sha :crypto.hash(:sha256, @large_origins_raw) |> Base.encode16(case: :lower)
  @large_reader Path.expand("../../../priv/ticket_push_status_reader_v5.py", __DIR__)
  @external_resource @large_reader
  @large_reader_sha :crypto.hash(:sha256, File.read!(@large_reader)) |> Base.encode16(case: :lower)
  @input_fence_helper Path.expand("../../../priv/ticket_push_input_fence_v1.py", __DIR__)
  @external_resource @input_fence_helper
  @input_fence_helper_sha :crypto.hash(:sha256, File.read!(@input_fence_helper)) |> Base.encode16(case: :lower)
  @input_fence_resource Path.expand("../../../priv/ticket_push_input_fence_v1.json", __DIR__)
  @external_resource @input_fence_resource
  @input_fence_resource_sha :crypto.hash(:sha256, File.read!(@input_fence_resource)) |> Base.encode16(case: :lower)

  @doc "Read-only verification of the curated original-runtime input fence and owned shutdown receipt."
  @spec input_fence_proof(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def input_fence_proof(receipt, receipt_sha, guard) do
    resource = Application.app_dir(:symphony_elixir, "priv/ticket_push_input_fence_v1.json")
    helper = Application.app_dir(:symphony_elixir, "priv/ticket_push_input_fence_v1.py")

    with {:ok, resource} <- PathSafety.canonicalize(resource),
         {:ok, helper} <- PathSafety.canonicalize(helper),
         {:ok, raw} <- File.read(helper),
         true <- hash(raw) == @input_fence_helper_sha or {:error, :input_fence_program_changed},
         {:ok, build} <- PathSafety.canonicalize(Path.expand("../..", Application.app_dir(:symphony_elixir))),
         true <- System.get_env("MIX_BUILD_PATH") == build or {:error, :input_fence_current_artifact_unproven},
         {__MODULE__, beam, _} <- :code.get_object_code(__MODULE__),
         {:ok, audit} <- File.read(resource),
         true <- hash(audit) == input_fence_resource_sha() or {:error, :input_fence_resource_changed} do
      packet =
        Jason.encode!(%{
          "resource_path" => resource,
          "resource_sha256" => hash(audit),
          "receipt_path" => receipt,
          "receipt_sha256" => receipt_sha,
          "guard_path" => guard,
          "current_build_path" => build,
          "current_io_sha256" => hash(beam)
        })

      port = Port.open({:spawn_executable, "/usr/bin/python3"}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: ["-I", "-S", "-B", helper]])

      try do
        true = Port.command(port, <<byte_size(packet)::unsigned-big-32, packet::binary>>)

        case collect_fence(port, <<>>, System.monotonic_time(:millisecond) + 8_000) do
          {:ok, encoded} -> Jason.decode(encoded)
          error -> error
        end
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  end

  defp input_fence_resource_sha do
    @input_fence_resource_sha
  end

  defp collect_fence(port, raw, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :input_fence_proof_timeout}
    else
      receive do
        {^port, {:data, bytes}} when byte_size(raw) + byte_size(bytes) <= 16_777_220 -> collect_fence(port, raw <> bytes, deadline)
        {^port, {:exit_status, 0}} -> frame(raw)
        {^port, _} -> {:error, :input_fence_proof_unproven}
      after
        remaining -> {:error, :input_fence_proof_timeout}
      end
    end
  end

  @spec prepare(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(store, intent, authorization, opts \\ []) do
    with {:ok, prepared} <- prepare_issuance(store, intent, authorization, opts),
         {:ok, prepared} <- observe_issuance_source(store, prepared, opts) do
      {:ok, prepared.execution}
    end
  end

  @doc false
  @spec prepare_issuance(Store.connection(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_issuance(store, intent, authorization, opts) do
    binding = Jason.decode!(intent["binding_json"])

    with {:ok, capability} <- TicketPushWorkerHistory.capability_recovery(store, binding["run_id"]),
         mode = if(capability, do: :capability, else: :large),
         {:ok, helper} <- helper(binding["repo_path"], mode),
         :ok <- WorkerFileIO.program_outside_source(helper, binding["worktree"]),
         {:ok, spool} <- WorkerFileIO.controller_spool(store, binding["repo_path"]),
         {:ok, program} <- File.read(@git),
         {:ok, history} <- ci_history(store, binding, opts, mode) do
      environment = %{
        "HOME" => System.user_home!(),
        "PATH" => "/usr/bin:/bin:/Library/Developer/CommandLineTools/usr/bin",
        "LC_ALL" => "C",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_NO_LAZY_FETCH" => "1",
        "GIT_NO_REPLACE_OBJECTS" => "1"
      }

      environment = Enum.reduce(~w(SSH_AUTH_SOCK GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM), environment, &environment_entry/2)

      execution =
        Map.merge(spool, %{
          "invocation" => intent["owner_nonce"],
          "intent_json" => intent["binding_json"],
          "intent_sha256" => intent["binding_sha256"],
          "run_id" => binding["run_id"],
          "helper_path" => helper,
          "helper_sha256" => helper_sha(mode),
          "program_sha256" => hash(program),
          "authorization" => authorization,
          "git_environment" => environment
        })
        |> Map.merge(history)
        |> Map.merge(Map.take(binding, ~w(ci_evidence_successor ci_repair_policy_receipt verified_ci_rollover human_empty_commit_imports ordinary_verifier_repair)))

      if transport_admissible?(execution),
        do: {:ok, %{execution: execution, mode: mode}},
        else: {:error, :ticket_push_input_too_large}
    end
  end

  @doc false
  @spec observe_issuance_source(Store.connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe_issuance_source(store, prepared, opts) do
    binding = Jason.decode!(prepared.execution["intent_json"])
    with {:ok, source} <- source_observation(store, binding, opts), do: {:ok, Map.put(prepared, :source, source)}
  end

  @doc false
  @spec recheck_issuance(Store.connection(), map()) :: :ok | {:error, term()}
  def recheck_issuance(store, prepared) do
    execution = prepared.execution
    binding = Jason.decode!(execution["intent_json"])

    with {:ok, run} <- RunLedger.get(store, execution["run_id"]),
         {:ok, capability} <- TicketPushWorkerHistory.capability_recovery(store, run["run_id"]),
         true <- if(capability, do: :capability, else: :large) == prepared.mode or {:error, :ticket_push_execution_changed},
         {:ok, expected} <- TicketCiRepairSuccessor.push_context(store, run),
         true <- Map.take(binding, ~w(ci_evidence_successor ci_repair_policy_receipt ordinary_verifier_repair)) == expected or {:error, :ci_successor_push_context_changed},
         :ok <- TicketCiRepairSuccessor.recheck_push_context(store, run, Map.take(binding, ~w(ci_evidence_successor ci_repair_policy_receipt verified_ci_rollover ordinary_verifier_repair)), store),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(store, run["run_id"]),
         true <- input_proof(inputs) == execution["ci_human_inputs"] or {:error, :ticket_push_execution_changed},
         {:ok, history} <-
           observe_history(
             store,
             run["run_id"],
             prepared.mode,
             execution["helper_sha256"] in [
               @retained_publisher_helper_sha,
               @generation_publisher_helper_sha,
               @publication_compat_helper_sha,
               @file_source_publication_helper_sha,
               @ordinary_bindings_helper_sha,
               @retained_publisher_capability_helper_sha,
               @generation_publisher_capability_helper_sha,
               @publication_compat_capability_helper_sha,
               @file_source_publication_capability_helper_sha,
               @ordinary_bindings_capability_helper_sha,
               @writer_readiness_helper_sha,
               @writer_readiness_capability_helper_sha,
               @typed_review_helper_sha,
               @typed_review_capability_helper_sha
             ]
           ),
         true <- Map.put_new(history, "successors_json", "[]") == execution["worker_history"] or {:error, :ticket_push_execution_changed} do
      :ok
    end
  end

  @doc false
  @spec recheck_issuance_freshness(Store.connection(), map()) :: :ok | {:error, term()}
  def recheck_issuance_freshness(store, prepared) do
    with :ok <- recheck_source(store, prepared.source),
         {:ok, run} <- RunLedger.get(store, prepared.execution["run_id"]),
         proof = prepared.execution["authorization"],
         authorized_run = if(proof["delivery_review"], do: Map.put(run, "state", "REVIEW_WRITING"), else: run) do
      TicketWorkerRunner.validate_authorization(authorized_run, proof)
    end
  end

  @doc false
  @spec transport_admissible?(map()) :: boolean()
  def transport_admissible?(execution) do
    encoded = Jason.encode!(execution)
    pid = 9_223_372_036_854_775_807
    request = %{"execution_json" => encoded, "helper_pid" => pid}

    terminal = %{
      "version" => 1,
      "execution_json" => encoded,
      "helper_pid" => pid,
      "child_pid" => pid,
      "termination" => %{"kind" => "signaled", "signal" => 64},
      "timed_out" => false,
      "overflow" => false,
      "output_base64" => String.duplicate("A", 87_384),
      "output_sha256" => String.duplicate("f", 64),
      "stderr_code" => "AUTHENTICATION_DENIED",
      "stderr_bytes" => 16_384,
      "stderr_sha256" => String.duplicate("f", 64)
    }

    rejected = %{"version" => 1, "kind" => "PREISSUANCE_REJECTED", "execution_json" => encoded, "helper_pid" => pid, "child_pid" => nil, "reason" => String.duplicate("x", 80)}

    {request_limit, receipt_limit} = transport_limits(execution)

    byte_size(encoded) <= request_limit and byte_size(Jason.encode!(request)) <= request_limit and
      Enum.all?([terminal, rejected], &(python_json_size(&1) <= receipt_limit))
  rescue
    _ -> false
  end

  defp transport_limits(%{"helper_sha256" => sha}) when sha not in @large_helper_shas, do: {@limit, @receipt_limit}
  defp transport_limits(_execution), do: {@request_limit, @large_receipt_limit}

  @doc false
  @spec execution_size_valid?(String.t()) :: boolean()
  def execution_size_valid?(raw) when is_binary(raw) and byte_size(raw) <= @limit, do: true

  def execution_size_valid?(raw) when is_binary(raw) and byte_size(raw) <= @request_limit do
    case Jason.decode(raw) do
      {:ok, %{"helper_sha256" => sha}} -> sha in @large_helper_shas
      _ -> false
    end
  end

  def execution_size_valid?(_raw), do: false

  @doc false
  @spec large_payload_origin?(map()) :: boolean()
  def large_payload_origin?(execution) do
    helper = execution["helper_path"]
    {name, history, history_sha, source} = large_payload_program(execution["helper_sha256"])

    %{"entries" => old_entries} = Jason.decode!(@large_origins_raw)
    %{"entries" => capability_entries} = Jason.decode!(@capability_origins_raw)
    entries = old_entries ++ capability_entries

    historical =
      Enum.any?(entries, &(Map.take(&1, ~w(helper_path helper_sha256 companion_path companion_sha256)) == Map.take(execution, ~w(helper_path helper_sha256 companion_path companion_sha256))))

    is_binary(helper) and Path.type(helper) == :absolute and Path.expand(helper) == helper and
      execution["helper_sha256"] in @large_helper_shas and
      (helper in [source, Application.app_dir(:symphony_elixir, "priv/" <> name)] or historical) and
      large_payload_programs?(execution, helper, history, history_sha)
  end

  defp large_payload_program(@previous_large_helper_sha),
    do: {"ticket_push_executor_v12.py", "ticket_push_history_validator_v9.py", @previous_large_history_sha, @previous_large_helper}

  defp large_payload_program(@origin_helper_sha),
    do: {"ticket_push_executor_v13.py", "ticket_push_history_validator_v10.py", @origin_history_sha, @origin_helper}

  defp large_payload_program(@review_helper_sha),
    do: {"ticket_push_executor_v23.py", "ticket_push_history_validator_v19.py", @review_history_sha, @review_helper}

  defp large_payload_program(@review_capability_helper_sha),
    do: {"ticket_push_executor_v24.py", "ticket_push_history_validator_v19.py", @review_history_sha, @review_capability_helper}

  defp large_payload_program(@current_review_helper_sha),
    do: {"ticket_push_executor_v25.py", "ticket_push_history_validator_v20.py", @current_review_history_sha, @current_review_helper}

  defp large_payload_program(@current_review_capability_helper_sha),
    do: {"ticket_push_executor_v26.py", "ticket_push_history_validator_v20.py", @current_review_history_sha, @current_review_capability_helper}

  defp large_payload_program(@ordinary_bindings_helper_sha),
    do: {"ticket_push_executor_v31.py", "ticket_push_history_validator_v23.py", @ordinary_bindings_history_sha, @ordinary_bindings_helper}

  defp large_payload_program(@ordinary_bindings_capability_helper_sha),
    do: {"ticket_push_executor_v32.py", "ticket_push_history_validator_v23.py", @ordinary_bindings_history_sha, @ordinary_bindings_capability_helper}

  defp large_payload_program(@file_source_publication_helper_sha),
    do: {"ticket_push_executor_v39.py", "ticket_push_history_validator_v27.py", @file_source_publication_history_sha, @file_source_publication_helper}

  defp large_payload_program(@file_source_publication_capability_helper_sha),
    do: {"ticket_push_executor_v40.py", "ticket_push_history_validator_v27.py", @file_source_publication_history_sha, @file_source_publication_capability_helper}

  defp large_payload_program(@publication_compat_helper_sha),
    do: {"ticket_push_executor_v37.py", "ticket_push_history_validator_v26.py", @publication_compat_history_sha, @publication_compat_helper}

  defp large_payload_program(@publication_compat_capability_helper_sha),
    do: {"ticket_push_executor_v38.py", "ticket_push_history_validator_v26.py", @publication_compat_history_sha, @publication_compat_capability_helper}

  defp large_payload_program(@generation_publisher_helper_sha),
    do: {"ticket_push_executor_v35.py", "ticket_push_history_validator_v25.py", @generation_publisher_history_sha, @generation_publisher_helper}

  defp large_payload_program(@generation_publisher_capability_helper_sha),
    do: {"ticket_push_executor_v36.py", "ticket_push_history_validator_v25.py", @generation_publisher_history_sha, @generation_publisher_capability_helper}

  defp large_payload_program(@retained_publisher_helper_sha),
    do: {"ticket_push_executor_v33.py", "ticket_push_history_validator_v24.py", @retained_publisher_history_sha, @retained_publisher_helper}

  defp large_payload_program(@retained_publisher_capability_helper_sha),
    do: {"ticket_push_executor_v34.py", "ticket_push_history_validator_v24.py", @retained_publisher_history_sha, @retained_publisher_capability_helper}

  defp large_payload_program(@writer_readiness_helper_sha),
    do: {"ticket_push_executor_v29.py", "ticket_push_history_validator_v22.py", @writer_readiness_history_sha, @writer_readiness_helper}

  defp large_payload_program(@writer_readiness_capability_helper_sha),
    do: {"ticket_push_executor_v30.py", "ticket_push_history_validator_v22.py", @writer_readiness_history_sha, @writer_readiness_capability_helper}

  defp large_payload_program(@typed_review_helper_sha),
    do: {"ticket_push_executor_v27.py", "ticket_push_history_validator_v21.py", @typed_review_history_sha, @typed_review_helper}

  defp large_payload_program(@typed_review_capability_helper_sha),
    do: {"ticket_push_executor_v28.py", "ticket_push_history_validator_v21.py", @typed_review_history_sha, @typed_review_capability_helper}

  defp large_payload_program(@capability_helper_sha),
    do: {"ticket_push_executor_v21.py", "ticket_push_history_validator_v18.py", @capability_history_sha, @capability_helper}

  defp large_payload_program(@acknowledged_helper_sha),
    do: {"ticket_push_executor_v22.py", "ticket_push_history_validator_v18.py", @capability_history_sha, @acknowledged_helper}

  defp large_payload_program(@legacy_v20_helper_sha),
    do: {"ticket_push_executor_v20.py", "ticket_push_history_validator_v17.py", @legacy_v20_history_sha, @legacy_v20_helper}

  defp large_payload_program(@legacy_v19_helper_sha),
    do: {"ticket_push_executor_v19.py", "ticket_push_history_validator_v16.py", @legacy_v19_history_sha, @legacy_v19_helper}

  defp large_payload_program(@legacy_v18_helper_sha),
    do: {"ticket_push_executor_v18.py", "ticket_push_history_validator_v15.py", @legacy_v18_history_sha, @legacy_v18_helper}

  defp large_payload_program(@legacy_v17_helper_sha),
    do: {"ticket_push_executor_v17.py", "ticket_push_history_validator_v14.py", @legacy_v17_history_sha, @legacy_v17_helper}

  defp large_payload_program(@previous_capability_helper_sha),
    do: {"ticket_push_executor_v15.py", "ticket_push_history_validator_v12.py", @previous_capability_history_sha, @previous_capability_helper}

  defp large_payload_program(@retained_capability_helper_sha),
    do: {"ticket_push_executor_v16.py", "ticket_push_history_validator_v13.py", @retained_capability_history_sha, @retained_capability_helper}

  defp large_payload_program(_sha),
    do: {"ticket_push_executor_v14.py", "ticket_push_history_validator_v11.py", @large_history_sha, @large_helper}

  defp large_payload_programs?(execution, helper, history, history_sha) do
    execution["companion_path"] == Path.join(Path.dirname(helper), "worker_file_companion.py") and execution["companion_sha256"] == @companion_sha and
      execution["history_program_path"] == Path.join(Path.dirname(helper), history) and execution["history_program_sha256"] == history_sha
  end

  defp python_json_size(value) do
    for <<point::utf8 <- Jason.encode!(value)>>, reduce: 0 do
      size ->
        size +
          cond do
            point < 127 -> 1
            point <= 65_535 -> 6
            true -> 12
          end
    end
  end

  defp ci_history(store, binding, opts, mode), do: retained_history(store, binding, opts, mode)

  defp retained_history(store, binding, _opts, mode) do
    {name, expected_history_sha} = history_program(mode)

    with {:ok, run} <- RunLedger.get(store, binding["run_id"]),
         {:ok, expected} <- TicketCiRepairSuccessor.push_context(store, run),
         true <- Map.take(binding, ~w(ci_evidence_successor ci_repair_policy_receipt ordinary_verifier_repair)) == expected or {:error, :ci_successor_push_context_changed},
         :ok <-
           TicketCiRepairSuccessor.recheck_push_context(
             store,
             run,
             Map.take(binding, ~w(ci_evidence_successor ci_repair_policy_receipt verified_ci_rollover ordinary_verifier_repair)),
             store
           ),
         {:ok, inputs} <- TicketCiRepair.input_snapshot(store, binding["run_id"]),
         {:ok, history} <- observe_history(store, binding["run_id"], mode),
         {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/" <> name)),
         :ok <- WorkerFileIO.program_outside_source(path, binding["worktree"]),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == expected_history_sha or {:error, :ticket_push_program_changed} do
      # v9 validates the complete successor projection even when it is empty.
      # Do not change the historical observe/receipt codec used by older helpers.
      history =
        Map.put_new(history, "successors_json", "[]")

      {:ok, %{"worker_history" => history, "ci_human_inputs" => input_proof(inputs), "history_program_path" => path, "history_program_sha256" => expected_history_sha}}
    end
  end

  defp history_program(:capability), do: {"ticket_push_history_validator_v27.py", @file_source_publication_history_sha}
  defp history_program(:large), do: {"ticket_push_history_validator_v27.py", @file_source_publication_history_sha}
  defp observe_history(store, run_id, mode, review? \\ true)
  defp observe_history(store, run_id, mode, true), do: TicketPushWorkerHistory.observe_review(store, run_id, mode)
  defp observe_history(store, run_id, :capability, false), do: TicketPushWorkerHistory.observe_capability(store, run_id)
  defp observe_history(store, run_id, :large, false), do: TicketPushWorkerHistory.observe_generated(store, run_id)

  defp source_observation(store, binding, opts) do
    if Enum.any?(~w(ci_repair ordinary_verifier_repair ci_evidence_successor), &Map.has_key?(binding, &1)),
      do: source_observation_for_run(store, binding["run_id"], opts),
      else: {:ok, nil}
  end

  defp source_observation_for_run(store, run_id, opts) do
    with {:ok, run} <- RunLedger.get(store, run_id), do: TicketCiRepair.observe_stopped_source(store, run, opts)
  end

  defp recheck_source(_store, nil), do: :ok
  defp recheck_source(store, source), do: TicketCiRepair.recheck_stopped_source(store, source)

  defp input_proof(inputs) do
    rows = Map.new(~w(ticket_chat_commands ticket_chat_questions ticket_contract_amendments inputs), &{&1, hash(Jason.encode!(inputs[&1]))})

    Enum.reduce(~w(parent bootstrap), rows, fn name, result ->
      keys = inputs[name] |> Map.keys() |> Enum.sort()
      Map.put(result, name, %{"keys" => keys, "sha256" => hash(Jason.encode!(Enum.map(keys, &inputs[name][&1])))})
    end)
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
        ordinary_receipt_valid?(raw, Map.put(intent, "run_id", run_id))

      _ ->
        false
    end
  end

  defp ordinary_receipt_valid?(raw, intent) do
    with {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || "null") do
      if execution["helper_sha256"] in [
           @ci_helper_sha,
           @next_ci_helper_sha,
           @previous_successor_helper_sha,
           @successor_helper_sha,
           @previous_import_helper_sha,
           @import_helper_sha,
           @ordinary_helper_sha,
           @budget_helper_sha,
           @current_helper_sha,
           @capability_helper_sha,
           @retained_publisher_helper_sha,
           @generation_publisher_helper_sha,
           @publication_compat_helper_sha,
           @file_source_publication_helper_sha,
           @ordinary_bindings_helper_sha,
           @retained_publisher_capability_helper_sha,
           @generation_publisher_capability_helper_sha,
           @publication_compat_capability_helper_sha,
           @file_source_publication_capability_helper_sha,
           @ordinary_bindings_capability_helper_sha,
           @writer_readiness_helper_sha,
           @typed_review_helper_sha,
           @current_review_helper_sha,
           @writer_readiness_capability_helper_sha,
           @typed_review_capability_helper_sha,
           @current_review_capability_helper_sha,
           @review_helper_sha,
           @review_capability_helper_sha,
           @acknowledged_helper_sha,
           @legacy_v20_helper_sha,
           @legacy_v19_helper_sha,
           @legacy_v18_helper_sha,
           @legacy_v17_helper_sha,
           @retained_capability_helper_sha,
           @previous_capability_helper_sha,
           @large_helper_sha,
           @origin_helper_sha,
           @previous_large_helper_sha
         ] do
        extras = ~w(stderr_code stderr_bytes stderr_sha256)

        {_request_limit, receipt_limit} = transport_limits(execution)

        with true <- is_binary(raw) and byte_size(raw) <= receipt_limit,
             {:ok, receipt} when is_map(receipt) <- Jason.decode(raw),
             true <- receipt["stderr_code"] in ~w(GIT_EXIT_ZERO GIT_EXIT_NONZERO AUTHENTICATION_DENIED TRANSPORT_FAILURE),
             true <- is_integer(receipt["stderr_bytes"]) and receipt["stderr_bytes"] in 0..16_384,
             true <- is_binary(receipt["stderr_sha256"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt["stderr_sha256"]) do
          bounded_receipt_valid?(receipt, intent, extras)
        else
          _ -> false
        end
      else
        TicketCheckoutIO.receipt_valid?(raw, intent)
      end
    else
      _ -> false
    end
  end

  defp bounded_receipt_valid?(receipt, intent, extras) do
    keys = ~w(version execution_json helper_pid child_pid termination timed_out overflow output_base64 output_sha256) ++ extras

    with true <- Enum.sort(Map.keys(receipt)) == Enum.sort(keys),
         true <- is_integer(receipt["version"]) and receipt["version"] == 1,
         true <- execution_size_valid?(intent["execution_json"]),
         true <- receipt["execution_json"] == intent["execution_json"],
         {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"]),
         true <-
           {execution["run_id"], execution["invocation"], execution["intent_json"], execution["intent_sha256"]} ==
             {intent["run_id"], intent["owner_nonce"], intent["binding_json"], intent["binding_sha256"]},
         true <- is_integer(intent["helper_pid"]) and intent["helper_pid"] > 0,
         true <- is_integer(receipt["helper_pid"]) and receipt["helper_pid"] == intent["helper_pid"],
         true <- is_integer(receipt["child_pid"]) and receipt["child_pid"] > 0,
         true <- terminal_receipt?(receipt["termination"]),
         true <- is_boolean(receipt["timed_out"]) and is_boolean(receipt["overflow"]),
         true <- is_binary(receipt["output_base64"]),
         {:ok, output} <- Base.decode64(receipt["output_base64"]),
         true <- byte_size(output) <= 65_536 and hash(output) == receipt["output_sha256"] do
      true
    else
      _ -> false
    end
  end

  defp terminal_receipt?(%{"kind" => "exited", "code" => code} = value), do: map_size(value) == 2 and is_integer(code) and code in 0..255
  defp terminal_receipt?(%{"kind" => "signaled", "signal" => signal} = value), do: map_size(value) == 2 and is_integer(signal) and signal in 1..64
  defp terminal_receipt?(_), do: false

  @doc "Recognizes only the reviewed CI push versions for a separately qualified post-verifier rollover."
  @spec verified_rollover_prior?(map()) :: boolean()
  def verified_rollover_prior?(intent) do
    with {:ok, execution} when is_map(execution) <- Jason.decode(intent["execution_json"] || "null"),
         true <-
           execution["helper_sha256"] in [
             @next_ci_helper_sha,
             @previous_successor_helper_sha,
             @successor_helper_sha,
             @previous_import_helper_sha,
             @import_helper_sha,
             @ordinary_helper_sha,
             @budget_helper_sha,
             @current_helper_sha,
             @capability_helper_sha,
             @retained_publisher_helper_sha,
             @generation_publisher_helper_sha,
             @publication_compat_helper_sha,
             @file_source_publication_helper_sha,
             @ordinary_bindings_helper_sha,
             @retained_publisher_capability_helper_sha,
             @generation_publisher_capability_helper_sha,
             @publication_compat_capability_helper_sha,
             @file_source_publication_capability_helper_sha,
             @ordinary_bindings_capability_helper_sha,
             @writer_readiness_helper_sha,
             @typed_review_helper_sha,
             @current_review_helper_sha,
             @writer_readiness_capability_helper_sha,
             @typed_review_capability_helper_sha,
             @current_review_capability_helper_sha,
             @review_helper_sha,
             @review_capability_helper_sha,
             @acknowledged_helper_sha,
             @legacy_v20_helper_sha,
             @legacy_v19_helper_sha,
             @legacy_v18_helper_sha,
             @legacy_v17_helper_sha,
             @retained_capability_helper_sha,
             @previous_capability_helper_sha,
             @large_helper_sha,
             @origin_helper_sha,
             @previous_large_helper_sha
           ] do
      receipt_valid?(intent["receipt_json"], intent)
    else
      _ -> false
    end
  end

  @spec rejection_reason(String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def rejection_reason(raw, intent) when is_binary(raw) and byte_size(raw) <= @large_receipt_limit do
    with {:ok, receipt} when is_map(receipt) <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(receipt)) == Enum.sort(~w(version kind execution_json helper_pid child_pid reason)),
         true <- receipt["version"] == 1 and receipt["kind"] == "PREISSUANCE_REJECTED" and is_nil(receipt["child_pid"]),
         true <- receipt["execution_json"] == intent["execution_json"] and receipt["helper_pid"] == intent["helper_pid"],
         {:ok, execution} <- Jason.decode(intent["execution_json"]),
         {_request_limit, receipt_limit} = transport_limits(execution),
         true <- byte_size(raw) <= receipt_limit and execution_size_valid?(intent["execution_json"]),
         true <-
           execution["helper_sha256"] in [
             @helper_sha,
             @ci_helper_sha,
             @next_ci_helper_sha,
             @previous_successor_helper_sha,
             @successor_helper_sha,
             @previous_import_helper_sha,
             @import_helper_sha,
             @ordinary_helper_sha,
             @budget_helper_sha,
             @current_helper_sha,
             @capability_helper_sha,
             @retained_publisher_helper_sha,
             @generation_publisher_helper_sha,
             @publication_compat_helper_sha,
             @file_source_publication_helper_sha,
             @retained_publisher_capability_helper_sha,
             @generation_publisher_capability_helper_sha,
             @publication_compat_capability_helper_sha,
             @file_source_publication_capability_helper_sha,
             @ordinary_bindings_helper_sha,
             @ordinary_bindings_capability_helper_sha,
             @writer_readiness_helper_sha,
             @typed_review_helper_sha,
             @current_review_helper_sha,
             @writer_readiness_capability_helper_sha,
             @typed_review_capability_helper_sha,
             @current_review_capability_helper_sha,
             @review_helper_sha,
             @review_capability_helper_sha,
             @acknowledged_helper_sha,
             @legacy_v20_helper_sha,
             @legacy_v19_helper_sha,
             @legacy_v18_helper_sha,
             @legacy_v17_helper_sha,
             @retained_capability_helper_sha,
             @previous_capability_helper_sha,
             @large_helper_sha,
             @origin_helper_sha,
             @previous_large_helper_sha
           ],
         reason when is_binary(reason) <- receipt["reason"],
         true <- String.match?(reason, ~r/\A[A-Za-z_]{1,80}\z/) do
      {:ok, reason}
    else
      _ -> {:error, :ticket_push_rejection_unproven}
    end
  end

  def rejection_reason(_, _), do: {:error, :ticket_push_rejection_unproven}

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
    case exchange_helper(execution, mode) do
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
          input = Jason.encode!(%{"execution_json" => encoded, "helper_pid" => original_pid || pid})

          result =
            cond do
              byte_size(input) > elem(transport_limits(execution), 0) -> {:error, :ticket_push_input_too_large}
              is_function(started, 2) -> attachment_ack(started.(pid, encoded), execution, pid, encoded)
              is_nil(started) and mode == "--status" -> {:ok, %{}}
              true -> {:error, :ticket_push_transport_unproven}
            end

          with {:ok, _} <- result do
            true = Port.command(port, <<byte_size(input)::unsigned-big-32, input::binary>>)
            collect(port, "", System.monotonic_time(:millisecond) + exchange_timeout(mode))
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

  # The execution window includes fresh history admission before Git's five-minute budget.
  # Status reads never inherit the longer write-operation lifetime.
  defp exchange_timeout("--execute"), do: 370_000
  defp exchange_timeout("--status"), do: 35_000

  defp attachment_ack({:error, _} = error, _execution, _pid, _encoded), do: error

  defp attachment_ack({:ok, bound} = result, execution, pid, encoded) when is_map(bound) do
    expected = %{
      "phase" => "PUSH_UNCERTAIN",
      "helper_pid" => pid,
      "execution_json" => encoded,
      "owner_nonce" => execution["invocation"],
      "binding_json" => execution["intent_json"]
    }

    if Map.take(bound, Map.keys(expected)) == expected,
      do: result,
      else: {:error, :ticket_push_transport_unproven}
  end

  defp attachment_ack(_result, _execution, _pid, _encoded), do: {:error, :ticket_push_transport_unproven}

  defp exchange_helper(execution, "--execute") do
    if transport_admissible?(execution) do
      execution_helper(execution, "--execute")
    else
      {:error, :ticket_push_program_changed}
    end
  end

  defp exchange_helper(execution, mode), do: execution_helper(execution, mode)

  defp collect(port, raw, deadline) do
    receive do
      {^port, {:data, bytes}} when byte_size(raw) + byte_size(bytes) <= @large_receipt_limit + 4 ->
        collect(port, raw <> bytes, deadline)

      {^port, {:exit_status, 0}} ->
        receipt_frame(raw)

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

  @doc false
  @spec receipt_frame(binary()) :: {:ok, binary()} | {:error, atom()}
  def receipt_frame(<<size::unsigned-big-32, raw::binary>>) when size in 1..@large_receipt_limit and byte_size(raw) == size, do: {:ok, raw}
  def receipt_frame(_), do: {:error, :ticket_push_transport_unproven}

  defp execution_helper(execution, "--status") do
    if TicketPushPreissuanceRejection.status_execution?(execution) and execution["helper_sha256"] != @previous_large_helper_sha do
      with :ok <- status_program(execution["helper_path"], execution["helper_sha256"], execution["root"]),
           :ok <- status_program(execution["companion_path"], @companion_sha, execution["root"]) do
        {:ok, execution["helper_path"]}
      end
    else
      status_helper(execution)
    end
  end

  defp execution_helper(execution, _mode) do
    capability_helpers = [
      @retained_publisher_capability_helper_sha,
      @generation_publisher_capability_helper_sha,
      @publication_compat_capability_helper_sha,
      @file_source_publication_capability_helper_sha,
      @ordinary_bindings_capability_helper_sha,
      @writer_readiness_capability_helper_sha,
      @typed_review_capability_helper_sha,
      @current_review_capability_helper_sha,
      @review_capability_helper_sha,
      @capability_helper_sha
    ]

    executable_helpers = [
      @retained_publisher_helper_sha,
      @generation_publisher_helper_sha,
      @publication_compat_helper_sha,
      @file_source_publication_helper_sha,
      @ordinary_bindings_helper_sha,
      @writer_readiness_helper_sha,
      @typed_review_helper_sha,
      @current_review_helper_sha,
      @review_helper_sha,
      @acknowledged_helper_sha | capability_helpers
    ]

    mode = if execution["helper_sha256"] in capability_helpers, do: :capability, else: :large

    with true <- execution["helper_sha256"] in executable_helpers,
         {:ok, path} <- helper(execution["root"], mode),
         true <- path == execution["helper_path"] do
      {:ok, path}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_helper(execution) do
    cond do
      capability_status_origin?(execution) ->
        capability_status_helper(execution)

      execution["helper_sha256"] in @large_helper_shas ->
        large_status_helper(execution)

      large_historical_origin?(execution) ->
        large_status_helper(execution)

      execution["helper_sha256"] == @current_helper_sha ->
        bounded_status_helper(execution)

      true ->
        case attested_status_origin(execution) do
          :unregistered -> original_status_helper(execution)
          result -> result
        end
    end
  end

  defp large_historical_origin?(execution) do
    %{"entries" => entries} = Jason.decode!(@large_origins_raw)
    Enum.any?(entries, &(&1["helper_path"] == execution["helper_path"]))
  end

  defp capability_status_helper(execution) do
    with {:ok, helper} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_executor_v21.py")),
         true <- capability_status_origin?(execution),
         true <- execution["companion_path"] == Path.join(Path.dirname(execution["helper_path"]), "worker_file_companion.py"),
         true <- execution["companion_sha256"] == @companion_sha,
         :ok <- status_program(helper, @capability_helper_sha, execution["root"]),
         {:ok, reader} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_status_reader_v21.py")),
         {:ok, origins} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_readback_origins_v20.json")),
         :ok <- status_program(reader, @capability_reader_sha, execution["root"]),
         :ok <- status_program(origins, @capability_origins_sha, execution["root"]) do
      {:ok, reader}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp capability_historical_origin?(execution) do
    %{"entries" => entries} = Jason.decode!(@capability_origins_raw)
    fields = ~w(helper_path helper_sha256 companion_path companion_sha256)

    Enum.any?(
      entries,
      &(&1["helper_sha256"] in [
          @large_helper_sha,
          @previous_capability_helper_sha,
          @retained_capability_helper_sha,
          @legacy_v17_helper_sha,
          @legacy_v18_helper_sha,
          @legacy_v19_helper_sha,
          @legacy_v20_helper_sha,
          @retained_publisher_helper_sha,
          @generation_publisher_helper_sha,
          @publication_compat_helper_sha,
          @file_source_publication_helper_sha,
          @ordinary_bindings_helper_sha,
          @retained_publisher_capability_helper_sha,
          @generation_publisher_capability_helper_sha,
          @publication_compat_capability_helper_sha,
          @file_source_publication_capability_helper_sha,
          @ordinary_bindings_capability_helper_sha,
          @writer_readiness_helper_sha,
          @typed_review_helper_sha,
          @current_review_helper_sha,
          @writer_readiness_capability_helper_sha,
          @typed_review_capability_helper_sha,
          @current_review_capability_helper_sha,
          @review_helper_sha,
          @review_capability_helper_sha,
          @acknowledged_helper_sha,
          @capability_helper_sha
        ] and
          Map.take(&1, fields) == Map.take(execution, fields))
    )
  end

  defp local_previous_capability?(execution) do
    Enum.any?(
      [
        {"ticket_push_executor_v15.py", @previous_capability_helper_sha},
        {"ticket_push_executor_v16.py", @retained_capability_helper_sha},
        {"ticket_push_executor_v17.py", @legacy_v17_helper_sha},
        {"ticket_push_executor_v18.py", @legacy_v18_helper_sha},
        {"ticket_push_executor_v19.py", @legacy_v19_helper_sha},
        {"ticket_push_executor_v20.py", @legacy_v20_helper_sha}
      ],
      fn {name, expected} ->
        local_capability?(execution, name, expected)
      end
    )
  end

  defp capability_status_origin?(execution) do
    local =
      Enum.any?(
        [
          {"ticket_push_executor_v33.py", @retained_publisher_helper_sha},
          {"ticket_push_executor_v34.py", @retained_publisher_capability_helper_sha},
          {"ticket_push_executor_v35.py", @generation_publisher_helper_sha},
          {"ticket_push_executor_v36.py", @generation_publisher_capability_helper_sha},
          {"ticket_push_executor_v39.py", @file_source_publication_helper_sha},
          {"ticket_push_executor_v40.py", @file_source_publication_capability_helper_sha},
          {"ticket_push_executor_v37.py", @publication_compat_helper_sha},
          {"ticket_push_executor_v38.py", @publication_compat_capability_helper_sha},
          {"ticket_push_executor_v31.py", @ordinary_bindings_helper_sha},
          {"ticket_push_executor_v32.py", @ordinary_bindings_capability_helper_sha},
          {"ticket_push_executor_v29.py", @writer_readiness_helper_sha},
          {"ticket_push_executor_v30.py", @writer_readiness_capability_helper_sha},
          {"ticket_push_executor_v27.py", @typed_review_helper_sha},
          {"ticket_push_executor_v28.py", @typed_review_capability_helper_sha},
          {"ticket_push_executor_v25.py", @current_review_helper_sha},
          {"ticket_push_executor_v26.py", @current_review_capability_helper_sha},
          {"ticket_push_executor_v23.py", @review_helper_sha},
          {"ticket_push_executor_v24.py", @review_capability_helper_sha},
          {"ticket_push_executor_v21.py", @capability_helper_sha},
          {"ticket_push_executor_v22.py", @acknowledged_helper_sha}
        ],
        fn {name, expected} -> local_capability?(execution, name, expected) end
      ) or local_previous_capability?(execution)

    local or capability_historical_origin?(execution)
  end

  defp local_capability?(execution, name, expected) do
    with true <- execution["helper_sha256"] == expected,
         {:ok, current} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/" <> name)) do
      execution["helper_path"] == current
    else
      _ -> false
    end
  end

  defp large_status_helper(execution) do
    resource = Application.app_dir(:symphony_elixir, "priv/ticket_push_readback_origins_v7.json")
    reader = Application.app_dir(:symphony_elixir, "priv/ticket_push_status_reader_v5.py")

    with {:ok, current} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_executor_v14.py")),
         true <-
           execution["helper_path"] in [current, Path.join(Path.dirname(current), "ticket_push_executor_v12.py"), Path.join(Path.dirname(current), "ticket_push_executor_v13.py")] or
             large_historical_origin?(execution),
         :ok <- status_program(current, @large_helper_sha, execution["root"]),
         true <- execution["companion_path"] == Path.join(Path.dirname(execution["helper_path"]), "worker_file_companion.py"),
         true <- execution["companion_sha256"] == @companion_sha,
         {:ok, reader} <- PathSafety.canonicalize(reader),
         {:ok, resource} <- PathSafety.canonicalize(resource),
         :ok <- status_program(reader, @large_reader_sha, execution["root"]),
         :ok <- status_program(resource, @large_origins_sha, execution["root"]) do
      {:ok, reader}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp bounded_status_helper(execution) do
    resource = Application.app_dir(:symphony_elixir, "priv/ticket_push_readback_origins_v4.json")
    reader = Application.app_dir(:symphony_elixir, "priv/ticket_push_status_reader_v2.py")

    with {:ok, current} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/ticket_push_executor_v11.py")),
         {:ok, %{"version" => 4, "entries" => entries}} <- Jason.decode(@bounded_origins_raw),
         true <- execution["helper_path"] == current or Enum.any?(entries, &(&1["helper_path"] == execution["helper_path"])),
         :ok <- status_program(current, @current_helper_sha, execution["root"]),
         true <- execution["companion_path"] == Path.join(Path.dirname(execution["helper_path"]), "worker_file_companion.py"),
         true <- execution["companion_sha256"] == @companion_sha,
         {:ok, reader} <- PathSafety.canonicalize(reader),
         {:ok, resource} <- PathSafety.canonicalize(resource),
         :ok <- status_program(reader, @bounded_reader_sha, execution["root"]),
         :ok <- status_program(resource, @bounded_origins_sha, execution["root"]) do
      {:ok, reader}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp attested_status_origin(execution) do
    with true <- byte_size(@attested_origins_raw) <= 65_536,
         {:ok, %{"version" => 2, "entries" => entries}} when is_list(entries) <- Jason.decode(@attested_origins_raw),
         matches = Enum.filter(entries, &(is_map(&1) and &1["helper_path"] == execution["helper_path"])) do
      case matches do
        [] -> :unregistered
        [entry] -> attested_status_reader(entry, execution)
        _ -> {:error, :ticket_push_program_changed}
      end
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp attested_status_reader(entry, execution) do
    resource = Application.app_dir(:symphony_elixir, "priv/ticket_push_readback_origins_v2.json")
    reader = Application.app_dir(:symphony_elixir, "priv/ticket_push_status_reader_v1.py")

    with true <- execution["helper_sha256"] in [@ci_helper_sha, @import_helper_sha],
         true <- entry["helper_sha256"] == execution["helper_sha256"],
         true <- entry["companion_path"] == execution["companion_path"] and execution["companion_sha256"] == @companion_sha,
         {:ok, reader} <- PathSafety.canonicalize(reader),
         :ok <- status_program(reader, @status_reader_sha, execution["root"]),
         {:ok, resource} <- PathSafety.canonicalize(resource),
         :ok <- status_program(resource, @attested_origins_sha, execution["root"]) do
      {:ok, reader}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp original_status_helper(execution) do
    with {:ok, origin, expected, cache_safe} <- status_version(execution["helper_sha256"]),
         {:ok, current} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/" <> Path.basename(origin))),
         path when is_binary(path) <- execution["helper_path"],
         :ok <- status_origin(path, origin, current, expected, execution),
         :ok <- status_program(path, expected, execution["root"]),
         companion = Path.join(Path.dirname(path), "worker_file_companion.py"),
         true <- execution["companion_path"] == companion and execution["companion_sha256"] == @companion_sha,
         :ok <- status_program(companion, @companion_sha, execution["root"]),
         :ok <- status_cache(companion, cache_safe) do
      {:ok, path}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_origin(path, origin, current, _expected, _execution) when path == origin or path == current, do: :ok

  defp status_origin(path, origin, _current, expected, execution) do
    with {:ok, historical} <- status_origin_entries(@status_origins_raw, @status_origins_sha),
         {:ok, ordinary} <- status_origin_entries(@ordinary_status_origins_raw, @ordinary_status_origins_sha),
         entries = historical ++ ordinary,
         true <- Enum.all?(entries, &status_entry?/1),
         true <- length(Enum.uniq_by(entries, & &1["helper_path"])) == length(entries),
         [entry] <- Enum.filter(entries, &(&1["helper_path"] == path)),
         true <- entry["helper_sha256"] == expected and entry["companion_sha256"] == @companion_sha,
         true <- entry["companion_path"] == execution["companion_path"],
         true <- Path.basename(path) == Path.basename(origin),
         true <- entry["companion_path"] == Path.join(Path.dirname(path), "worker_file_companion.py"),
         :ok <- status_manifest(entry, execution["root"]) do
      :ok
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_origin_entries(raw, expected) do
    with true <- byte_size(raw) <= 65_536 and hash(raw) == expected,
         {:ok, resource} when is_map(resource) <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(resource)) == ~w(entries version) and resource["version"] === 1,
         entries when is_list(entries) and length(entries) <= 8 <- resource["entries"] do
      {:ok, entries}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_entry?(entry) when is_map(entry) do
    Enum.sort(Map.keys(entry)) == Enum.sort(@status_entry_keys) and
      Enum.all?(~w(manifest_path helper_path companion_path), &(is_binary(entry[&1]) and Path.type(entry[&1]) == :absolute)) and
      Enum.all?(~w(manifest_sha256 helper_sha256 companion_sha256), &(is_binary(entry[&1]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, entry[&1])))
  end

  defp status_entry?(_), do: false

  defp status_manifest(entry, root) do
    path = entry["manifest_path"]

    with {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, %{type: :regular, size: size} = before} when size <= 4_194_304 <- File.lstat(path),
         :ok <- WorkerFileIO.program_outside_source(path, root),
         {:ok, raw} <- File.read(path),
         true <- byte_size(raw) <= 4_194_304 and hash(raw) == entry["manifest_sha256"],
         {:ok, ^before} <- File.lstat(path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw),
         release when is_binary(release) <- manifest["release"],
         {:ok, ^release} <- PathSafety.canonicalize(release),
         artifact when is_map(artifact) <- manifest["artifact"],
         true <- status_manifest_file?(artifact, release, entry, "helper"),
         true <- status_manifest_file?(artifact, release, entry, "companion") do
      :ok
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_manifest_file?(artifact, release, entry, kind) do
    path = entry[kind <> "_path"]
    relative = "lib/symphony_elixir/priv/" <> Path.basename(path)

    path in [Path.join(release, relative), Path.join([release, "dev", relative])] and
      artifact[relative] == %{"sha256" => entry[kind <> "_sha256"]}
  end

  # Prior releases require an exact compile-pinned manifest, never sibling trust.
  # This additional provenance is status-only; execution still uses helper/2.
  defp status_version(@helper_sha), do: {:ok, @helper, @helper_sha, false}
  defp status_version(@ci_helper_sha), do: {:ok, @ci_helper, @ci_helper_sha, true}
  defp status_version(@next_ci_helper_sha), do: {:ok, @next_ci_helper, @next_ci_helper_sha, true}
  defp status_version(@successor_helper_sha), do: {:ok, @successor_helper, @successor_helper_sha, true}
  defp status_version(@import_helper_sha), do: {:ok, @import_helper, @import_helper_sha, true}
  defp status_version(@ordinary_helper_sha), do: {:ok, @ordinary_helper, @ordinary_helper_sha, true}
  defp status_version(@budget_helper_sha), do: {:ok, @budget_helper, @budget_helper_sha, true}
  defp status_version(@current_helper_sha), do: {:ok, @current_helper, @current_helper_sha, true}
  defp status_version(@previous_import_helper_sha), do: {:ok, @previous_import_helper, @previous_import_helper_sha, true}
  defp status_version(@previous_successor_helper_sha), do: {:ok, @previous_successor_helper, @previous_successor_helper_sha, true}
  defp status_version(@legacy_helper_sha), do: {:ok, @legacy_helper, @legacy_helper_sha, false}
  defp status_version(_), do: {:error, :ticket_push_program_changed}

  defp status_program(path, expected, root) when is_binary(path) do
    with {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, %{type: :regular}} <- File.lstat(path),
         :ok <- WorkerFileIO.program_outside_source(path, root),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == expected do
      :ok
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_program(_, _, _), do: {:error, :ticket_push_program_changed}

  defp status_cache(_companion, true), do: :ok

  # -B prevents writes, not loading an existing timestamp-valid v1/v2 cache.
  # v3 compiles the verified source directly and never imports companion bytecode.
  defp status_cache(companion, false) do
    case File.lstat(companion <> "c") do
      {:error, :enoent} -> status_cache_directory(Path.join(Path.dirname(companion), "__pycache__"))
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_cache_directory(directory) do
    case File.lstat(directory) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :directory}} -> status_cache_entries(directory)
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp status_cache_entries(directory) do
    with {:ok, names} <- File.ls(directory),
         false <- Enum.any?(names, &(String.starts_with?(&1, "worker_file_companion.") and String.ends_with?(&1, ".pyc"))) do
      :ok
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp helper(root, ci_repair) do
    name = helper_name(ci_repair)
    expected = helper_sha(ci_repair)

    with {:ok, path} <- PathSafety.canonicalize(Application.app_dir(:symphony_elixir, "priv/" <> name)),
         :ok <- WorkerFileIO.program_outside_source(path, root),
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == expected do
      {:ok, path}
    else
      _ -> {:error, :ticket_push_program_changed}
    end
  end

  defp helper_name(:capability), do: "ticket_push_executor_v40.py"

  defp helper_name(mode) do
    case mode do
      :large -> "ticket_push_executor_v39.py"
      :current -> "ticket_push_executor_v11.py"
      :ordinary_repair -> "ticket_push_executor_v9.py"
      :successor -> "ticket_push_executor_v6.py"
      :human_import -> "ticket_push_executor_v8.py"
      :previous_successor -> "ticket_push_executor_v5.py"
      true -> "ticket_push_executor_v4.py"
      false -> "ticket_push_executor_v2.py"
    end
  end

  defp helper_sha(:successor), do: @successor_helper_sha
  defp helper_sha(:ordinary_repair), do: @ordinary_helper_sha
  defp helper_sha(:current), do: @current_helper_sha
  defp helper_sha(:large), do: @file_source_publication_helper_sha
  defp helper_sha(:capability), do: @file_source_publication_capability_helper_sha
  defp helper_sha(:human_import), do: @import_helper_sha
  defp helper_sha(:previous_successor), do: @previous_successor_helper_sha
  defp helper_sha(true), do: @next_ci_helper_sha
  defp helper_sha(false), do: @helper_sha

  defp hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  defp environment_entry(key, acc) do
    case System.get_env(key) do
      nil -> acc
      value -> Map.put(acc, key, value)
    end
  end
end
