defmodule SymphonyElixir.Factory.MrFeedbackConsumer do
  @moduledoc """
  Binds one review question to the existing Desktop controller task.

  A completed reply is accepted only after fresh Jira, MR-head, source-note,
  and exact-thread reply readback. Uncertain writes stop for reconciliation.
  """

  alias SymphonyElixir.Factory.{Control, ControllerTask, DesktopRequest, DesktopStageRunner, GitLabMcpConnector}
  alias SymphonyElixir.Factory.{JiraMcpReader, MrFeedback}
  alias SymphonyElixir.Factory.{MrFeedbackLedger, MrFeedbackMcpReader, Prompt, RunLedger, StageSchemas}
  alias SymphonyElixir.Factory.Store
  alias SymphonyElixir.Tracker.Issue

  @stale_source_errors ~w(
    feedback_source_changed delivery_not_review_ready jira_review_label_missing
    mr_identity_mismatch mr_head_mismatch unauthorized_author non_actionable_note
    mention_missing invalid_note_identity
  )a

  @doc "Processes at most one pending review-feedback receipt."
  @spec process_one(map(), keyword()) :: {:ok, atom()} | {:error, term()}
  def process_one(context, opts) do
    case MrFeedbackLedger.next_batch(context.store) do
      [] ->
        {:ok, :idle}

      [%{"status" => "PENDING"} | _] = receipts ->
        if controller_busy?(context.store, context.factory.scope),
          do: {:ok, :controller_busy},
          else: process_receipts(context, receipts, opts)

      receipts ->
        process_receipts(context, receipts, opts)
    end
  end

  defp process_receipts(context, [%{"reply_phase" => 0} = receipt], opts), do: process_receipt(context, receipt, opts)
  defp process_receipts(context, receipts, opts), do: process_batch(context, receipts, opts)

  defp process_batch(context, receipts, opts) do
    first = hd(receipts)

    with {:ok, run} <- RunLedger.get(context.store, first["run_id"]),
         {:ok, route} <- route(context.factory.repositories, run),
         {:ok, source} <- fresh_source(context, first, run, route, opts),
         {:ok, notes} <- verify_batch_source(context, receipts, run, route, source) do
      run_batch_controller(context, receipts, run, route, notes, opts)
    else
      {:error, {reason, receipt}} when reason in @stale_source_errors ->
        dismiss_stale_batch_receipt(context, receipt, reason)

      {:error, reason} when reason in @stale_source_errors ->
        dismiss_stale_batch_receipt(context, first, reason)

      other ->
        other
    end
  end

  defp dismiss_stale_batch_receipt(context, %{"status" => "PENDING"} = receipt, reason) do
    :ok = MrFeedbackLedger.dismiss(context.store, receipt["feedback_key"], reason)
    {:ok, :dismissed}
  end

  defp dismiss_stale_batch_receipt(_context, _receipt, reason), do: {:error, reason}

  defp verify_batch_source(context, receipts, run, route, source) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, notes} ->
      with true <- receipt["run_id"] == run["run_id"] and receipt["mr_iid"] == run["mr_iid"],
           {:ok, note} <- source_note(source.discussions, receipt),
           :ok <- verify_source(context, receipt, run, route, %{source | note: note}) do
        prompt_note = %{
          feedback_key: receipt["feedback_key"],
          body: note["body"],
          discussion_id: receipt["discussion_id"],
          note_id: receipt["note_id"],
          author_id: receipt["author_id"],
          updated_at: receipt["note_updated_at"],
          body_sha256: receipt["body_sha256"]
        }

        {:cont, {:ok, [prompt_note | notes]}}
      else
        false -> {:halt, {:error, :feedback_batch_changed}}
        {:error, reason} -> {:halt, {:error, {reason, receipt}}}
      end
    end)
    |> case do
      {:ok, notes} -> {:ok, Enum.reverse(notes)}
      error -> error
    end
  end

  defp controller_busy?(store, scope) do
    Store.one!(
      store,
      "SELECT request_key FROM desktop_requests WHERE target_kind = 'CONTROLLER' AND target_key = ? AND status IN ('PENDING', 'CREATE_UNCERTAIN', 'FOLLOWUP_UNCERTAIN', 'THREAD_RECORDED', 'RECONCILE_REQUIRED') LIMIT 1",
      [scope]
    ) != nil
  end

  defp process_receipt(context, receipt, opts) do
    with {:ok, run} <- RunLedger.get(context.store, receipt["run_id"]),
         {:ok, route} <- route(context.factory.repositories, run),
         {:ok, source} <- fresh_source(context, receipt, run, route, opts),
         :ok <- verify_source(context, receipt, run, route, source) do
      run_controller(context, receipt, run, route, source.note, opts)
    else
      {:error, reason} = error when reason in @stale_source_errors ->
        if receipt["status"] == "PENDING" do
          :ok = MrFeedbackLedger.dismiss(context.store, receipt["feedback_key"], reason)
          {:ok, :dismissed}
        else
          error
        end

      other ->
        other
    end
  end

  defp fresh_source(_context, receipt, run, route, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    jira_reader = Keyword.get(opts, :jira_reader, JiraMcpReader)
    gitlab_reader = Keyword.get(opts, :gitlab_reader, MrFeedbackMcpReader)

    with {:ok, jira} <- jira_reader.issue(run["issue_key"], workspace: workspace, mcp_session: Keyword.get(opts, :mcp_session)),
         {:ok, %{mr: mr, discussions: discussions}} <-
           gitlab_reader.fetch(route, run, workspace: workspace, mcp_session: Keyword.get(opts, :mcp_session)),
         {:ok, note} <- source_note(discussions, receipt) do
      {:ok, %{jira: jira, mr: mr, discussions: discussions, note: note}}
    end
  end

  defp source_note(discussions, receipt) do
    note =
      Enum.find_value(discussions, fn discussion ->
        if discussion["id"] == receipt["discussion_id"],
          do: Enum.find(discussion["notes"], &(&1["id"] == receipt["note_id"]))
      end)

    if is_map(note) and note["updated_at"] == receipt["note_updated_at"],
      do: {:ok, note},
      else: {:error, :feedback_source_changed}
  end

  defp verify_source(context, receipt, run, route, source) do
    policy = Map.get(context.factory, :review_feedback, %{})
    allowed = Map.get(policy, "allowed_author_ids", [11_599_766])
    bot_id = Map.get(policy, "bot_author_id", 0)

    with {:ok, candidate} <-
           MrFeedback.candidate(
             run,
             route,
             source.jira,
             source.mr,
             %{"id" => receipt["discussion_id"]},
             source.note,
             allowed,
             bot_id
           ),
         true <- candidate.feedback_key == receipt["feedback_key"] or {:error, :feedback_source_changed} do
      :ok
    end
  end

  defp run_batch_controller(context, receipts, run, route, notes, opts) do
    first = hd(receipts)
    control = Control.status(context.store, context.factory.scope)
    prior_turn = first["controller_previous_turn_id"] || control["controller_turn_id"]

    prompt = Prompt.gitlab_feedback_batch(run, route, notes, batch_mode(first))
    key = DesktopStageRunner.request_key("controller:" <> context.factory.scope, prior_turn, prompt)

    case batch_controller_action(receipts, control, prior_turn, key) do
      :binding_changed ->
        {:error, :feedback_request_binding_changed}

      :reconcile ->
        reconcile_completed_batch_request(context, receipts, run, route, key, opts)

      :dispatch ->
        dispatch_batch_request(context, receipts, run, route, key, prior_turn, prompt, opts)
    end
  end

  defp batch_mode(%{"reply_phase" => 2}), do: :clarify
  defp batch_mode(%{"reply_phase" => 1}), do: :resolve
  defp batch_mode(_receipt), do: :classify

  defp batch_controller_action([first | _] = receipts, control, prior_turn, key) do
    cond do
      first["status"] == "CLAIMED" and Enum.any?(receipts, &(&1["request_key"] != key)) -> :binding_changed
      first["status"] == "CLAIMED" and control["controller_turn_id"] != prior_turn -> :reconcile
      true -> :dispatch
    end
  end

  defp reconcile_completed_batch_request(context, receipts, run, route, key, opts) do
    desktop_request = Keyword.get(opts, :desktop_request, DesktopRequest)
    control = Control.status(context.store, context.factory.scope)
    schema = StageSchemas.for_stage(:gitlab_feedback_batch)

    with {:ok, request} <- desktop_request.get(context.store, key),
         true <-
           desktop_request.payload_intact?(request) and request["status"] == "SUCCEEDED" and
             request["target_kind"] == "CONTROLLER" and request["target_key"] == context.factory.scope and
             request["thread_id"] == control["controller_thread_id"] and
             request["turn_id"] == control["controller_turn_id"],
         true <- is_binary(request["schema_json"]) and is_binary(request["output_json"]),
         {:ok, ^schema} <- Jason.decode(request["schema_json"]),
         {:ok, %{"result" => output}} <- Jason.decode(request["output_json"]),
         :ok <- StageSchemas.validate(output, schema) do
      consume_batch_result(context, receipts, run, route, key, {:ok, output}, opts)
    else
      _other -> mark_batch_reconciliation(context, receipts, key, "bound controller completion not proven")
    end
  end

  defp dispatch_batch_request(context, receipts, run, route, key, prior_turn, prompt, opts) do
    with {:ok, _claimed} <- MrFeedbackLedger.claim_batch(context.store, receipts, key, prior_turn) do
      controller = Keyword.get(opts, :controller_task, ControllerTask)

      result =
        controller.run(
          context.factory,
          Keyword.fetch!(opts, :workspace),
          %Issue{id: run["issue_key"], identifier: run["issue_key"], title: "MR review feedback"},
          prompt,
          StageSchemas.for_stage(:gitlab_feedback_batch),
          control_server: context.control_server,
          store: context.store,
          wait_timeout_ms: 2_000
        )

      consume_batch_result(context, receipts, run, route, key, result, opts)
    end
  end

  defp consume_batch_result(_context, _receipts, _run, _route, _key, {:error, {:desktop_request_pending, _, _}}, _opts),
    do: {:ok, :pending}

  defp consume_batch_result(context, receipts, _run, _route, key, {:error, reason}, _opts),
    do: mark_batch_reconciliation(context, receipts, key, inspect(reason))

  defp consume_batch_result(context, receipts, run, route, key, {:ok, %{"results" => results}}, opts)
       when is_list(results) do
    expected = Enum.map(receipts, & &1["feedback_key"])
    actual = Enum.map(results, & &1["feedback_key"])

    if expected == actual and Enum.zip(receipts, results) |> Enum.all?(fn {receipt, result} -> valid_batch_decision?(receipt, result) end) do
      with {:ok, replies} <- verify_batch_replies(context, receipts, results, run, route, opts),
           :ok <- MrFeedbackLedger.finish_batch(context.store, receipts, key, results, replies) do
        {:ok, :batch_complete}
      else
        {:error, reason} -> mark_batch_reconciliation(context, receipts, key, inspect(reason))
      end
    else
      mark_batch_reconciliation(context, receipts, key, "batch results mismatch")
    end
  end

  defp consume_batch_result(context, receipts, _run, _route, key, _result, _opts),
    do: mark_batch_reconciliation(context, receipts, key, "batch result invalid")

  defp valid_batch_decision?(%{"reply_phase" => 0}, %{"status" => "CHANGE_REQUEST", "reply_id" => nil, "reply_body" => nil}),
    do: true

  defp valid_batch_decision?(_receipt, %{"status" => "REPLIED", "reply_id" => id, "reply_body" => body}),
    do: is_binary(id) and is_binary(body)

  defp valid_batch_decision?(_receipt, _result), do: false

  defp verify_batch_replies(context, receipts, results, run, route, opts) do
    if Enum.any?(results, &(&1["status"] == "REPLIED")),
      do: read_batch_reply_proofs(context, receipts, results, run, route, opts),
      else: {:ok, %{}}
  end

  defp read_batch_reply_proofs(context, receipts, results, run, route, opts) do
    reader = Keyword.get(opts, :gitlab_reader, MrFeedbackMcpReader)
    bot_id = context.factory |> Map.get(:review_feedback, %{}) |> Map.get("bot_author_id", 0)

    with {:ok, author_id} <- authenticated_reply_author(opts),
         true <- bot_id == 0 or bot_id == author_id or {:error, :reply_author_configuration_mismatch},
         {:ok, %{discussions: discussions}} <-
           reader.fetch(route, run,
             workspace: Keyword.fetch!(opts, :workspace),
             mcp_session: Keyword.get(opts, :mcp_session)
           ) do
      collect_reply_proofs(receipts, results, discussions, author_id)
    end
  end

  defp collect_reply_proofs(receipts, results, discussions, author_id) do
    Enum.zip(receipts, results)
    |> Enum.reduce_while({:ok, %{}}, fn {receipt, result}, {:ok, reply_ids} ->
      case reply_proof(receipt, result, discussions, author_id) do
        {:ok, nil} -> {:cont, {:ok, reply_ids}}
        {:ok, id} -> {:cont, {:ok, Map.put(reply_ids, receipt["feedback_key"], id)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reply_proof(_receipt, %{"status" => "CHANGE_REQUEST"}, _discussions, _author_id), do: {:ok, nil}

  defp reply_proof(receipt, result, discussions, author_id) do
    with {:ok, reply} <- reply_in_discussion(discussions, receipt),
         true <-
           (get_in(reply, ["author", "id"]) == author_id and
              to_string(reply["id"]) == result["reply_id"] and reply["body"] == result["reply_body"]) or
             {:error, :reply_readback_mismatch} do
      {:ok, reply["id"]}
    end
  end

  defp mark_batch_reconciliation(context, receipts, key, reason) do
    :ok = MrFeedbackLedger.reconcile_batch(context.store, receipts, key, reason)
    {:ok, :reconcile_required}
  end

  defp run_controller(context, receipt, run, route, note, opts) do
    control = Control.status(context.store, context.factory.scope)
    prior_turn = receipt["controller_previous_turn_id"] || control["controller_turn_id"]

    prompt_note = %{
      body: note["body"],
      discussion_id: receipt["discussion_id"],
      note_id: receipt["note_id"],
      author_id: receipt["author_id"],
      updated_at: receipt["note_updated_at"],
      body_sha256: receipt["body_sha256"]
    }

    prompt = Prompt.gitlab_feedback_reply(run, route, prompt_note, receipt["feedback_key"])
    key = DesktopStageRunner.request_key("controller:" <> context.factory.scope, prior_turn, prompt)

    cond do
      receipt["status"] == "CLAIMED" and receipt["request_key"] != key ->
        {:error, :feedback_request_binding_changed}

      receipt["status"] == "CLAIMED" and control["controller_turn_id"] != prior_turn ->
        reconcile_completed_request(context, receipt, run, route, key, opts)

      true ->
        dispatch_bound_request(context, receipt, run, route, key, prior_turn, prompt, opts)
    end
  end

  defp reconcile_completed_request(context, receipt, run, route, key, opts) do
    desktop_request = Keyword.get(opts, :desktop_request, DesktopRequest)
    control = Control.status(context.store, context.factory.scope)

    with {:ok, request} <- desktop_request.get(context.store, key),
         true <-
           desktop_request.payload_intact?(request) and request["status"] == "SUCCEEDED" and
             request["target_kind"] == "CONTROLLER" and request["target_key"] == context.factory.scope and
             request["thread_id"] == control["controller_thread_id"] and
             request["turn_id"] == control["controller_turn_id"],
         true <- is_binary(request["schema_json"]) and is_binary(request["output_json"]),
         {:ok, schema} <- Jason.decode(request["schema_json"]),
         true <- schema == StageSchemas.for_stage(:gitlab_feedback_reply),
         {:ok, %{"result" => output}} <- Jason.decode(request["output_json"]),
         :ok <- StageSchemas.validate(output, schema) do
      consume_result(context, receipt, run, route, key, {:ok, output}, opts)
    else
      _other -> mark_reconciliation(context, receipt, key, "bound controller completion not proven")
    end
  end

  defp dispatch_bound_request(context, receipt, run, route, key, prior_turn, prompt, opts) do
    with {:ok, _claimed} <- MrFeedbackLedger.claim(context.store, receipt["feedback_key"], key, prior_turn) do
      controller = Keyword.get(opts, :controller_task, ControllerTask)

      result =
        controller.run(
          context.factory,
          Keyword.fetch!(opts, :workspace),
          %Issue{id: run["issue_key"], identifier: run["issue_key"], title: "MR review feedback"},
          prompt,
          StageSchemas.for_stage(:gitlab_feedback_reply),
          control_server: context.control_server,
          store: context.store,
          wait_timeout_ms: 2_000
        )

      consume_result(context, receipt, run, route, key, result, opts)
    end
  end

  defp consume_result(_context, _receipt, _run, _route, _key, {:error, {:desktop_request_pending, _, _}}, _opts),
    do: {:ok, :pending}

  defp consume_result(context, receipt, _run, _route, key, {:error, reason}, _opts),
    do: mark_reconciliation(context, receipt, key, inspect(reason))

  defp consume_result(context, receipt, run, route, key, {:ok, output}, opts) do
    cond do
      output["feedback_key"] != receipt["feedback_key"] ->
        mark_reconciliation(context, receipt, key, "feedback key mismatch")

      output["status"] == "CHANGE_REQUEST" and is_nil(output["reply_id"]) ->
        :ok = MrFeedbackLedger.finish(context.store, receipt["feedback_key"], key, "CHANGE_REQUEST", nil, output["reason"])
        {:ok, :change_request}

      output["status"] == "REPLIED" ->
        verify_reply(context, receipt, run, route, key, output, opts)

      true ->
        mark_reconciliation(context, receipt, key, output["reason"] || "no reply proven")
    end
  end

  defp verify_reply(context, receipt, run, route, key, output, opts) do
    reader = Keyword.get(opts, :gitlab_reader, MrFeedbackMcpReader)
    bot_id = context.factory |> Map.get(:review_feedback, %{}) |> Map.get("bot_author_id", 0)

    with {:ok, author_id} <- authenticated_reply_author(opts),
         true <- bot_id == 0 or bot_id == author_id or {:error, :reply_author_configuration_mismatch},
         {:ok, %{discussions: discussions}} <-
           reader.fetch(route, run,
             workspace: Keyword.fetch!(opts, :workspace),
             mcp_session: Keyword.get(opts, :mcp_session)
           ),
         {:ok, reply} <- reply_in_discussion(discussions, receipt),
         true <-
           (get_in(reply, ["author", "id"]) == author_id and
              to_string(reply["id"]) == output["reply_id"] and reply["body"] == output["reply_body"]) or
             {:error, :reply_readback_mismatch},
         :ok <- MrFeedbackLedger.finish(context.store, receipt["feedback_key"], key, "COMPLETE", reply["id"]) do
      {:ok, :complete}
    else
      _other -> mark_reconciliation(context, receipt, key, "reply not read back")
    end
  end

  defp authenticated_reply_author(opts) do
    connector = Keyword.get(opts, :gitlab_connector, GitLabMcpConnector)
    connector_opts = [workspace: Keyword.fetch!(opts, :workspace), mcp_session: Keyword.get(opts, :mcp_session)]

    connector_opts =
      case Keyword.get(opts, :gitlab_app_server) do
        nil -> connector_opts
        app_server -> Keyword.put(connector_opts, :app_server, app_server)
      end

    with {:ok, user} <- connector.call("whoami", %{}, connector_opts) do
      positive_author_id(user["id"])
    end
  end

  defp positive_author_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp positive_author_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 -> {:ok, number}
      _other -> {:error, :authenticated_gitlab_author_invalid}
    end
  end

  defp positive_author_id(_id), do: {:error, :authenticated_gitlab_author_invalid}

  defp reply_in_discussion(discussions, receipt) do
    marker_key =
      if receipt["reply_phase"] == 1,
        do: "#{receipt["feedback_key"]}:resolution",
        else: receipt["feedback_key"]

    marker = "<!-- symphony-feedback:#{marker_key} -->"

    replies =
      discussions
      |> Enum.filter(&(&1["id"] == receipt["discussion_id"]))
      |> Enum.flat_map(& &1["notes"])
      |> Enum.filter(&(is_binary(&1["body"]) and String.contains?(&1["body"], marker)))

    case replies do
      [reply] -> {:ok, reply}
      _other -> {:error, :reply_not_unique}
    end
  end

  defp mark_reconciliation(context, receipt, key, reason) do
    :ok = MrFeedbackLedger.finish(context.store, receipt["feedback_key"], key, "RECONCILE_REQUIRED", nil, reason)
    {:ok, :reconcile_required}
  end

  defp route(repositories, run) do
    case Map.get(repositories, run["repo_key"]) do
      %{} = selected -> {:ok, Map.put(selected, "repo_key", run["repo_key"])}
      _other -> {:error, :review_feedback_route_missing}
    end
  end
end
