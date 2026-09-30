defmodule Mix.Tasks.Factory do
  use Mix.Task

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.Admin
  alias SymphonyElixir.Workflow

  @shortdoc "Inspect, activate, pause, or retry the local factory controller"

  @moduledoc """
  Manages the local SQLite-backed factory controller without using Jira.

      mix factory status --workflow /path/to/WORKFLOW.md
      mix factory activate --workflow /path/to/WORKFLOW.md
      mix factory pause --workflow /path/to/WORKFLOW.md
      mix factory retry-spec PPL-1234 --workflow /path/to/WORKFLOW.md
      mix factory replace-controller OLD_THREAD NEW_THREAD NEW_TURN FAILED_REQUEST_KEY --workflow /path/to/WORKFLOW.md
      mix factory recover-spec-readback REQUEST_KEY COMPLETED_TURN --workflow /path/to/WORKFLOW.md
      mix factory adopt-spec-revision REQUEST_KEY COMPLETED_TURN --workflow /path/to/WORKFLOW.md
      mix factory adopt-repair-slice REQUEST_KEY COMPLETED_TURN --workflow /path/to/WORKFLOW.md
      mix factory resume-ci-preflight RUN_ID CANDIDATE_SHA --workflow /path/to/WORKFLOW.md
      mix factory resume-native-branch-mismatch RUN_ID PRIOR_RUN_ID --workflow /path/to/WORKFLOW.md
      mix factory recover-native-writer REQUEST_KEY COMPLETED_TURN --workflow /path/to/WORKFLOW.md
      mix factory resume-interrupted-writer REQUEST_KEY INTERRUPTED_TURN --workflow /path/to/WORKFLOW.md
      mix factory resume-auth-failed-verifier REQUEST_KEY FAILED_TURN --workflow /path/to/WORKFLOW.md
      mix factory recover-native-verifier-create REQUEST_KEY BOOTSTRAP_TURN --workflow /path/to/WORKFLOW.md
      mix factory investigate-blocked-writer REQUEST_KEY BLOCKED_TURN --workflow /path/to/WORKFLOW.md
      mix factory reopen-blocked-delivery RUN_ID --workflow /path/to/WORKFLOW.md
      mix factory resume-controller-delivery RUN_ID CANDIDATE_SHA --workflow /path/to/WORKFLOW.md
      mix factory resume-rejected-create REQUEST_KEY REJECTED_TOOL_CALL_ID --workflow /path/to/WORKFLOW.md
      mix factory authorize-planner-repair REQUEST_KEY COMPLETED_TURN --workflow /path/to/WORKFLOW.md
      mix factory claim-planner-repair REQUEST_KEY --workflow /path/to/WORKFLOW.md
      mix factory recover-native-bootstrap REQUEST_KEY COMPLETED_BOOTSTRAP_TURN --workflow /path/to/WORKFLOW.md
      mix factory authorize-controller-repair REQUEST_KEY MALFORMED_TURN --workflow /path/to/WORKFLOW.md
      mix factory claim-controller-repair REQUEST_KEY --workflow /path/to/WORKFLOW.md

  `--dispatcher-id` is optional and defaults to the identity configured in the
  workflow. Status is read-only. Activate, pause, and retry-spec fail while a
  live tick lease is held. Retry-spec is a one-shot local request for the exact
  latest failed specification; it does not edit Jira or erase failure history.
  """

  @switches [workflow: :string, dispatcher_id: :string, help: :boolean]

  @impl Mix.Task
  def run(args) do
    ensure_runtime_dependencies!()
    {opts, actions, invalid} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] or not valid_action?(actions) ->
        Mix.raise("Invalid arguments.\n\n#{@moduledoc}")

      true ->
        workflow_path = Path.expand(opts[:workflow] || "WORKFLOW.md")
        factory = load_factory!(workflow_path)
        result = run_action!(actions, factory, opts[:dispatcher_id])
        Mix.shell().info(Jason.encode!(result, pretty: true))
    end
  end

  defp load_factory!(workflow_path) do
    with {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, settings} <- Schema.parse(workflow.config) do
      settings.factory
    else
      {:error, reason} -> Mix.raise("Unable to load factory workflow: #{inspect(reason)}")
    end
  end

  defp valid_action?([action]) when action in ~w(status activate pause), do: true
  defp valid_action?(["retry-spec", issue_key]), do: String.trim(issue_key) != ""

  defp valid_action?(["recover-spec-readback", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["adopt-spec-revision", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["adopt-repair-slice", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["resume-ci-preflight", run_id, sha]),
    do: String.trim(run_id) != "" and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)

  defp valid_action?(["resume-native-branch-mismatch", run_id, prior_run_id]),
    do: String.trim(run_id) != "" and String.trim(prior_run_id) != "" and run_id != prior_run_id

  defp valid_action?(["recover-native-writer", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["resume-interrupted-writer", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["resume-auth-failed-verifier", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["recover-native-verifier-create", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["investigate-blocked-writer", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["reopen-blocked-delivery", run_id]), do: String.trim(run_id) != ""

  defp valid_action?(["resume-controller-delivery", run_id, sha]),
    do: String.trim(run_id) != "" and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)

  defp valid_action?(["resume-rejected-create", request_key, tool_call_id]),
    do: String.trim(request_key) != "" and Regex.match?(~r/\Aexec-[0-9a-f-]+\z/, tool_call_id)

  defp valid_action?(["authorize-planner-repair", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["claim-planner-repair", request_key]), do: String.trim(request_key) != ""

  defp valid_action?(["recover-native-bootstrap", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["authorize-controller-repair", request_key, turn_id]),
    do: String.trim(request_key) != "" and String.trim(turn_id) != ""

  defp valid_action?(["claim-controller-repair", request_key]), do: String.trim(request_key) != ""

  defp valid_action?(["replace-controller" | identities]), do: length(identities) == 4 and Enum.all?(identities, &(String.trim(&1) != ""))
  defp valid_action?(_actions), do: false

  defp run_action!(["status"], factory, _dispatcher_id), do: unwrap!(Admin.overview(factory))
  defp run_action!(["activate"], factory, dispatcher_id), do: unwrap!(Admin.activate(factory, dispatcher_id))
  defp run_action!(["pause"], factory, dispatcher_id), do: unwrap!(Admin.pause(factory, dispatcher_id))

  defp run_action!(["retry-spec", issue_key], factory, _dispatcher_id),
    do: unwrap!(Admin.retry_specification(factory, issue_key))

  defp run_action!(["recover-spec-readback", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.recover_specification_readback(factory, request_key, turn_id))

  defp run_action!(["adopt-spec-revision", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.adopt_failed_specification_revision(factory, request_key, turn_id))

  defp run_action!(["adopt-repair-slice", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.adopt_failed_native_repair_slice(factory, request_key, turn_id))

  defp run_action!(["resume-ci-preflight", run_id, sha], factory, _dispatcher_id),
    do: unwrap!(Admin.resume_failed_ci_preflight(factory, run_id, sha))

  defp run_action!(["resume-native-branch-mismatch", run_id, prior_run_id], factory, _dispatcher_id),
    do: unwrap!(Admin.resume_native_branch_sha_mismatch(factory, run_id, prior_run_id))

  defp run_action!(["recover-native-writer", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.recover_native_writer(factory, request_key, turn_id))

  defp run_action!(["resume-interrupted-writer", request_key, interrupted_turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.resume_interrupted_native_writer(factory, request_key, interrupted_turn_id))

  defp run_action!(["resume-auth-failed-verifier", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.resume_authentication_failed_verifier(factory, request_key, turn_id))

  defp run_action!(["recover-native-verifier-create", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.recover_native_verifier_create(factory, request_key, turn_id))

  defp run_action!(["investigate-blocked-writer", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.resume_blocked_native_writer_investigation(factory, request_key, turn_id))

  defp run_action!(["reopen-blocked-delivery", run_id], factory, _dispatcher_id),
    do: unwrap!(Admin.reopen_factory_blocked_delivery(factory, run_id))

  defp run_action!(["resume-controller-delivery", run_id, sha], factory, _dispatcher_id),
    do: unwrap!(Admin.resume_controller_owned_delivery(factory, run_id, sha))

  defp run_action!(["resume-rejected-create", request_key, tool_call_id], factory, _dispatcher_id),
    do: unwrap!(Admin.resume_rejected_native_create(factory, request_key, tool_call_id))

  defp run_action!(["authorize-planner-repair", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.authorize_planner_format_repair(factory, request_key, turn_id))

  defp run_action!(["claim-planner-repair", request_key], factory, _dispatcher_id),
    do: unwrap!(Admin.claim_planner_format_repair(factory, request_key))

  defp run_action!(["recover-native-bootstrap", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.recover_native_bootstrap(factory, request_key, turn_id))

  defp run_action!(["authorize-controller-repair", request_key, turn_id], factory, _dispatcher_id),
    do: unwrap!(Admin.authorize_controller_format_repair(factory, request_key, turn_id))

  defp run_action!(["claim-controller-repair", request_key], factory, _dispatcher_id),
    do: unwrap!(Admin.claim_controller_format_repair(factory, request_key))

  defp run_action!(["replace-controller", old_thread, new_thread, new_turn, request_key], factory, _dispatcher_id),
    do: unwrap!(Admin.replace_controller(factory, old_thread, new_thread, new_turn, request_key))

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Mix.raise("Factory operation failed: #{inspect(reason)}")

  defp ensure_runtime_dependencies! do
    case Application.ensure_all_started(:exqlite) do
      {:ok, _applications} -> :ok
      {:error, reason} -> Mix.raise("Unable to start factory runtime dependencies: #{inspect(reason)}")
    end
  end
end
