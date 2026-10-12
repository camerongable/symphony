defmodule Mix.Tasks.Factory.Ticket do
  use Mix.Task

  alias SymphonyElixir.Config.Schema

  alias SymphonyElixir.Factory.{
    Store,
    TicketChat,
    TicketChatCommands,
    TicketChatOutbox,
    TicketContext,
    TicketStagePayload
  }

  alias SymphonyElixir.Workflow

  @shortdoc "Read bounded ticket context or stage a non-authorizing ticket command"
  @moduledoc """
      mix factory.ticket context RUN --workflow WORKFLOW.md
      mix factory.ticket replay RUN --workflow WORKFLOW.md
      mix factory.ticket details RUN ARTIFACT_REF --offset 0 --limit 4096 --workflow WORKFLOW.md
      mix factory.ticket journal RUN --after 0 --high-water 123 --limit 10 --workflow WORKFLOW.md
      mix factory.ticket records RUN tasks --after 0 --high-water 123 --limit 10 --workflow WORKFLOW.md
      mix factory.ticket stage RUN --payload-base64 BASE64_JSON --workflow WORKFLOW.md
      mix factory.ticket prepare-stage RUN --workflow WORKFLOW.md
      mix factory.ticket command RUN COMMAND_KEY --workflow WORKFLOW.md
      mix factory.ticket synchronization RUN --workflow WORKFLOW.md

  Stage accepts only proposal_id, body, operations and the current generation,
  spec_revision, contract_sha256 and candidate_sha. It returns PENDING, never
  source or Jira authority. Native input collection is controller-owned; this
  command does not accept supplied origin/readback attestations.
  """

  @read_bounds [offset: :integer, limit: :integer, after: :integer, high_water: :integer]
  @switches @read_bounds ++ [workflow: :string, payload_base64: :string, help: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, action, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] -> Mix.shell().info(@moduledoc)
      invalid != [] -> Mix.raise("Invalid ticket arguments")
      true -> execute_with_store(action, opts)
    end
  end

  defp execute_with_store(action, opts) do
    {:ok, _} = Application.ensure_all_started(:exqlite)

    with {:ok, workflow} <- Workflow.load(Path.expand(opts[:workflow] || "WORKFLOW.md")),
         {:ok, settings} <- Schema.parse(workflow.config),
         {:ok, store} <- open_store(action, settings.factory.database) do
      try do
        case execute(action, store, opts) do
          {:ok, result} -> Mix.shell().info(Jason.encode!(result, pretty: true))
          {:error, reason} -> Mix.raise("Ticket operation failed: #{inspect(reason)}")
        end
      after
        GenServer.stop(store)
      end
    else
      reason -> Mix.raise("Unable to load ticket store: #{inspect(reason)}")
    end
  end

  defp open_store(["stage", _run], database), do: Store.start_link(database: database)
  defp open_store(_action, database), do: Store.start_read_only(database: Path.expand(database))

  defp execute(["context", run], store, _opts), do: TicketContext.context(store, run)
  defp execute(["replay", run], store, _opts), do: TicketContext.replay(store, run)
  defp execute(["synchronization", run], store, _opts), do: TicketChatOutbox.synchronization(store, run)

  defp execute(["prepare-stage", run], store, opts) do
    path = Path.expand(opts[:workflow] || "WORKFLOW.md")
    previous = Application.fetch_env(:symphony_elixir, :workflow_file_path)

    try do
      Workflow.set_workflow_file_path(path)
      TicketStagePayload.prepare(store, run, path)
    after
      case previous do
        {:ok, original} -> Workflow.set_workflow_file_path(original)
        :error -> Workflow.clear_workflow_file_path()
      end
    end
  end

  defp execute(["details", run, ref], store, opts) do
    with {:ok, chat} <- TicketChat.for_run(store, run) do
      TicketContext.details(store, chat["chat_key"], ref, opts[:offset] || 0, opts[:limit] || 4096)
    end
  end

  defp execute(["journal", run], store, opts), do: TicketContext.journal(store, run, opts[:after] || 0, opts[:high_water], opts[:limit] || 10)

  defp execute(["records", run, kind], store, opts),
    do: TicketContext.records(store, run, kind, opts[:after] || 0, opts[:high_water], opts[:limit] || 10)

  defp execute(["command", run, key], store, _opts) do
    with {:ok, command} <- TicketChatCommands.get(store, key),
         true <- command["run_id"] == run or {:error, :command_not_in_run} do
      {:ok, command}
    end
  end

  defp execute(["stage", run], store, opts) do
    payload = opts[:payload_base64]

    with true <- is_binary(payload) and byte_size(payload) <= 32_768,
         {:ok, json} <- Base.decode64(payload),
         true <- byte_size(json) <= 24_576,
         {:ok, attrs} when is_map(attrs) <- Jason.decode(json) do
      TicketChatCommands.stage(store, run, attrs)
    else
      _ -> {:error, :invalid_or_oversized_ticket_payload}
    end
  end

  defp execute(_action, _store, _opts), do: {:error, :invalid_ticket_action}
end
