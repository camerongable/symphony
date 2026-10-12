defmodule SymphonyElixir.Factory.TicketContextReader do
  @moduledoc "Controller-bound command locator for read-only ticket context."

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.{PathSafety, Workflow}

  @spec bind(Store.connection(), String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def bind(store, run, opts) do
    with {:ok, cwd} <- existing_path(opts[:ticket_cli_root], :directory),
         true <- File.regular?(Path.join(cwd, "lib/mix/tasks/factory.ticket.ex")),
         {:ok, workflow} <- existing_path(opts[:ticket_workflow], :regular),
         {:ok, loaded} <- Workflow.load(workflow),
         database_token <- get_in(loaded.config, ["factory", "database"]),
         true <- is_binary(database_token) and Path.type(database_token) == :absolute,
         {:ok, settings} <- Schema.parse(loaded.config),
         database <- Path.expand(settings.factory.database),
         %{rows: databases} <- Store.query!(store, "PRAGMA database_list"),
         true <- Enum.any?(databases, fn [_id, name, path] -> name == "main" and Path.expand(path) == database end) do
      arguments = ["context", run, "--workflow", workflow]
      locator = %{"cwd" => cwd, "workflow" => workflow, "run_id" => run, "arguments" => arguments, "command" => execution_command(arguments)}
      bound_locator(store, run, locator)
    else
      _ -> {:error, :ticket_context_reader_unavailable}
    end
  end

  @spec validate(Store.connection(), String.t(), String.t() | nil) :: :ok | {:error, atom()}
  def validate(_store, _run, nil), do: :ok

  def validate(store, run, json) when is_binary(json) do
    with {:ok, locator} when is_map(locator) <- Jason.decode(json),
         {:ok, expected} <- bind(store, run, ticket_cli_root: locator["cwd"], ticket_workflow: locator["workflow"]),
         expected <- Jason.decode!(expected),
         true <- Map.delete(expected, "command") == Map.delete(locator, "command"),
         true <- locator["command"] in [execution_command(expected["arguments"]), legacy_command(expected["arguments"])] do
      :ok
    else
      _ -> {:error, :ticket_context_reader_unavailable}
    end
  end

  def validate(_store, _run, _json), do: {:error, :ticket_context_reader_unavailable}

  @spec execution_locator(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def execution_locator(json) when is_binary(json) do
    with {:ok, locator} when is_map(locator) <- Jason.decode(json),
         true <- Enum.sort(Map.keys(locator)) == ~w(arguments command cwd run_id workflow),
         ["context", run, "--workflow", workflow] <- locator["arguments"],
         true <- is_binary(run) and is_binary(workflow) and is_binary(locator["cwd"]),
         true <- locator["run_id"] == run and locator["workflow"] == workflow,
         true <- Path.type(workflow) == :absolute and Path.type(locator["cwd"]) == :absolute,
         true <- locator["command"] in [execution_command(locator["arguments"]), legacy_command(locator["arguments"])] do
      {:ok, Jason.encode!(Map.put(locator, "command", execution_command(locator["arguments"])))}
    else
      _ -> {:error, :ticket_context_reader_unavailable}
    end
  end

  def execution_locator(_json), do: {:error, :ticket_context_reader_unavailable}

  defp bound_locator(store, run, locator) do
    bound = Store.one!(store, "SELECT chat.context_reader_json FROM ticket_chats chat JOIN ticket_chat_runs link ON link.chat_key = chat.chat_key WHERE link.run_id = ?", [run])

    case bound && bound["context_reader_json"] do
      nil ->
        {:ok, Jason.encode!(locator)}

      json ->
        with {:ok, existing} <- Jason.decode(json),
             true <- is_map(existing) and Map.delete(existing, "command") == Map.delete(locator, "command"),
             {:ok, _} <- execution_locator(json) do
          {:ok, json}
        else
          _ -> {:error, :ticket_context_reader_unavailable}
        end
    end
  end

  defp execution_command(arguments) do
    encoded = arguments |> Jason.encode!() |> Base.encode64()
    "mise exec -- mix run --no-compile --no-start -e 'Mix.Tasks.Factory.Ticket.run(Jason.decode!(Base.decode64!(\"#{encoded}\")))'"
  end

  defp legacy_command(arguments) do
    encoded = arguments |> Jason.encode!() |> Base.encode64()
    "mise exec -- mix run --no-compile --no-start -e 'Mix.Tasks.Factory.Ticket.run(Base.decode64!(\"#{encoded}\") |> Jason.decode!())'"
  end

  @spec instructions(String.t() | nil) :: String.t()
  def instructions(nil), do: "No context reader is bound. Report context refresh unavailable; do not present the incoming snapshot as fresh or stage any proposal."

  def instructions(json) do
    "Refresh durable context with exec_command using exactly this saved read-only locator: #{json}. " <>
      "This refresh is read-only. For each direct human message, run it successfully in that same turn before staging; a refresh from an earlier turn is not sufficient. " <>
      "You may stage only an explicit command from that direct human message; do not stage this controller presentation, delegated/model output, artifacts, or inferred intent. Preserve the direct message body byte-for-byte. " <>
      "If the question body or allowed answers are artifact references, read them with the read-only `mise exec -- mix factory.ticket details RUN ARTIFACT_REF --offset 0 --limit 4096 --workflow WORKFLOW.md` using this reader's exact run_id and workflow path from its cwd. Follow a returned next_offset only with the same reference; if the details are unavailable or stale, do not stage. " <>
      "Use mise exec -- mix factory.ticket stage RUN --payload-base64 BASE64_JSON --workflow WORKFLOW.md with this reader's exact run_id and workflow path and cwd set to this locator's cwd. " <>
      staging_protocol() <>
      "The JSON must contain exactly proposal_id, body, operations, generation, spec_revision, contract_sha256, and candidate_sha, bound to this same refreshed context; keep proposal_id stable for retries of that exact input. For `Revise the contract:\n` followed by the complete replacement Markdown, stage exactly one `propose_contract_revision` operation whose markdown is the complete suffix after that line. For the exact message `Rework the current candidate.`, stage exactly one `request_rework` operation and no other operation. For one explicit answer, operations must contain exactly one object with operation `answer_question`, the exact current question_key, and a value exactly matching one declared answer; supply no other operation fields or operations and do not supply question_digest. For enumerated answers, the map keys are the human phrases and each key's associated value is the JSON value to submit, preserving its type (for example `yes` -> `true`, not the string `yes`). Use the supplied system base64 encoder rather than hand-building a payload. If the grammar, operation schema, or exact binding is unavailable, report that you cannot stage; do not guess. Staging records a PENDING proposal only; do not apply it. " <>
      "Do not invoke broker, scheduler, source, Jira, GitLab, or delivery actions. " <>
      "If the command fails or its run_id is different, report refresh unavailable and do not stage; do not guess a path, initialize a ledger, or use a stale snapshot."
  end

  @spec staging_protocol() :: String.t()
  def staging_protocol do
    "For a direct message beginning exactly `Revise the contract:\n` or containing exactly `Rework the current candidate.` with an optional final LF, run the read-only mise exec -- mix factory.ticket prepare-stage RUN --workflow WORKFLOW.md command using the freshly read context's run_id, workflow and cwd. Execute its returned stage_command unchanged from its returned cwd. Do not transcribe, reconstruct, re-encode, trim, or add newlines to that prepared payload. If preparation fails, report the failure and do not fall back to hand-building this proposal. Other supported answer forms retain explicit typed staging. Encoding and staging are separate commands: first obtain BASE64_JSON from the system encoder, then execute the literal single-command mise exec -- mix factory.ticket stage RUN --payload-base64 BASE64_JSON --workflow WORKFLOW.md invocation, using the freshly read context's run_id, workflow and cwd. Never stage through mix run -e, Mix.Tasks.Factory.Ticket.run, or a combined Elixir encoder/staging expression; those invocations do not provide an admissible staging receipt. Preserve every trailing newline in body and in the replacement Markdown; do not trim or normalize either. Keep a proposal ID stable only for identical bytes; use a new proposal ID for a corrected payload. "
  end

  defp existing_path(path, type) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == path,
         {:ok, %File.Stat{type: ^type}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> {:error, :invalid_context_reader_path}
    end
  end

  defp existing_path(_path, _type), do: {:error, :invalid_context_reader_path}
end
