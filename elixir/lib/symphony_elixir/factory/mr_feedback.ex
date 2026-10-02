defmodule SymphonyElixir.Factory.MrFeedback do
  @moduledoc """
  Filters untrusted GitLab discussion notes before they can enter the factory.

  Discovery is deterministic and does not run an agent on an unchanged poll.
  The caller must supply a freshly read Jira issue and GitLab MR; stale ledger
  snapshots cannot authorize review feedback.
  """

  @ready_states ~w(READY_FOR_REVIEW DELIVERED)
  @mention ~r/(?:^|[^[:alnum:]_])[$@]symphony\b/iu
  @edit_command ~r/\A(?:(?:ok(?:ay)?|yes|sure|sounds good)[,:!\s]+)?(?:(?:go ahead)(?:\s+and)?\s+)?(?:(?:please|can you|could you|would you)\s+)?(?:fix|change|simplify|remove|replace|refactor|update|rewrite|delete|add|implement|combine|merge|consolidate|extract|inline|rename|reorganize|restructure|convert|move|split|optimize|deduplicate|standardize|normalize|switch)\b/iu
  @make_edit_command ~r/\A(?:(?:ok(?:ay)?|yes|sure|sounds good)[,:!\s]+)?(?:(?:go ahead)(?:\s+and)?\s+)?(?:(?:please|can you|could you|would you)\s+)?(?:make|apply|implement)\s+(?:(?:the|that|this|those|these)\s+)?(?:(?:requested|suggested)\s+)?(?:changes?|edits?|updates?|suggestion)\b/iu
  @contextual_approval ~r/\A(?:ok(?:ay)?|yes|sure|sounds good|looks good|that works|I agree|agreed|approved|please proceed|go ahead(?:\s+(?:with|and)\s+(?:(?:the|this|that|those|these)\s+)?(?:change|changes|edit|edits|suggestion|proposal))?|please do|do that|do it)[,.!\s]*\z/iu

  @doc "Accepts a human mention only when the Jira, run, and MR identities agree."
  @spec candidate(map(), map(), map(), map(), map(), map(), [pos_integer()], pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def candidate(%{} = run, %{} = route, %{} = jira, %{} = mr, %{} = discussion, %{} = note, allowed_author_ids, bot_author_id)
      when is_list(allowed_author_ids) and is_integer(bot_author_id) do
    with :ok <- eligible?(run, route, jira, mr),
         :ok <- authorized_author?(note, allowed_author_ids, bot_author_id),
         :ok <- actionable_note?(note),
         :ok <- mentioned?(note["body"]),
         {:ok, discussion_id} <- nonempty(discussion["id"]),
         {:ok, updated_at} <- nonempty(note["updated_at"]),
         :ok <- valid_note_id?(note["id"]) do
      body_sha256 = digest(note["body"])
      project = mr["project"]
      iid = mr["iid"]
      feedback_key = digest(Enum.join([project, iid, discussion_id, note["id"], body_sha256], "\u0000"))

      {:ok,
       %{
         feedback_key: feedback_key,
         run_id: run["run_id"],
         project: project,
         mr_iid: iid,
         discussion_id: discussion_id,
         note_id: note["id"],
         note_updated_at: updated_at,
         author_id: note["author"]["id"],
         body_sha256: body_sha256
       }}
    end
  end

  @doc "Requires the exact factory MR and a current Jira review label."
  @spec eligible?(map(), map(), map(), map()) :: :ok | {:error, atom()}
  def eligible?(run, route, jira, mr) do
    with :ok <- ready_run?(run),
         :ok <- review_jira?(run, jira),
         :ok <- matching_mr_identity?(run, route, mr) do
      matching_mr_head?(run, mr)
    end
  end

  @doc "Recognizes an explicit edit instruction; criticism alone remains conversational."
  @spec explicit_edit_request?(String.t()) :: boolean()
  def explicit_edit_request?(body) when is_binary(body) do
    text = body |> String.replace(@mention, " ") |> String.trim()

    Regex.match?(@edit_command, text) or Regex.match?(@make_edit_command, text)
  end

  @doc "Recognizes an approval of a concrete edit proposed in an earlier Symphony reply."
  @spec approves_proposed_edit?(String.t(), [map()], pos_integer()) :: boolean()
  def approves_proposed_edit?(body, discussion_notes, note_id) when is_binary(body) and is_list(discussion_notes) do
    approval = body |> String.replace(@mention, " ") |> String.trim()

    Regex.match?(@contextual_approval, approval) and
      prior_edit_offer?(discussion_notes, note_id)
  end

  defp ready_run?(%{"kind" => "DELIVERY", "state" => state}) when state in @ready_states, do: :ok
  defp ready_run?(_run), do: {:error, :delivery_not_review_ready}

  defp review_jira?(run, jira) do
    labels = if is_list(jira["labels"]), do: jira["labels"], else: []

    if jira["key"] == run["issue_key"] and
         Enum.any?(labels, &(is_binary(&1) and String.downcase(&1) == "ai-review")),
       do: :ok,
       else: {:error, :jira_review_label_missing}
  end

  defp matching_mr_identity?(run, route, mr) do
    matching_identity? =
      route["repo_key"] == run["repo_key"] and mr["project"] == route["gitlab_project"] and
        mr["iid"] == run["mr_iid"] and mr["web_url"] == run["mr_url"]

    if valid_mr_binding?(run, route) and matching_identity?, do: :ok, else: {:error, :mr_identity_mismatch}
  end

  defp valid_mr_binding?(run, route) do
    is_binary(route["gitlab_project"]) and route["gitlab_project"] != "" and
      is_integer(run["mr_iid"]) and run["mr_iid"] > 0 and
      is_binary(run["mr_url"]) and run["mr_url"] != ""
  end

  defp matching_mr_head?(run, mr) do
    if mr["state"] == "opened" and mr["source_branch"] == run["branch"] and mr["sha"] == run["candidate_sha"],
      do: :ok,
      else: {:error, :mr_head_mismatch}
  end

  defp valid_note_id?(id) when is_integer(id) and id > 0, do: :ok
  defp valid_note_id?(_id), do: {:error, :invalid_note_identity}

  defp authorized_author?(%{"author" => %{"id" => id}}, allowed_ids, bot_id)
       when is_integer(id) and id > 0 do
    if id != bot_id and id in allowed_ids, do: :ok, else: {:error, :unauthorized_author}
  end

  defp authorized_author?(_note, _allowed_ids, _bot_id), do: {:error, :unauthorized_author}

  defp actionable_note?(%{"body" => body} = note) when is_binary(body) do
    if note["system"] == true or String.trim(body) == "" or String.contains?(body, "<!-- symphony-feedback:") do
      {:error, :non_actionable_note}
    else
      :ok
    end
  end

  defp actionable_note?(_note), do: {:error, :non_actionable_note}

  defp mentioned?(body) do
    visible =
      body
      |> String.split("\n")
      |> Enum.reduce({false, []}, fn line, {in_fence, lines} ->
        cond do
          String.match?(line, ~r/^\s*```/) -> {not in_fence, lines}
          in_fence or String.match?(line, ~r/^\s*>/) -> {in_fence, lines}
          true -> {in_fence, [String.replace(line, ~r/`+[^`\n]*`+/u, "") | lines]}
        end
      end)
      |> elem(1)
      |> Enum.join("\n")

    if Regex.match?(@mention, visible), do: :ok, else: {:error, :mention_missing}
  end

  defp nonempty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_note_identity}
      text -> {:ok, text}
    end
  end

  defp nonempty(_value), do: {:error, :invalid_note_identity}

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp prior_edit_offer?(notes, note_id) do
    notes
    |> Enum.take_while(&(&1["id"] != note_id))
    |> Enum.any?(fn note ->
      body = note["body"] || ""

      String.contains?(body, "<!-- symphony-feedback:") and
        (Regex.match?(~r/\b(?:would you like me to|should I|can I|could I|shall I|want me to)\b.*\b(?:change|edit|implement|update|fix|simplify|remove|replace|refactor)\b/is, body) or
           Regex.match?(
             ~r/\b(?:would|could|should)\b(?=.*\b(?:explicit|proposed|suggested|allowlist|change|edit|refactor|simplify|replace|update|fix|remove|case|switch)\b)(?=.*\b(?:clearer|cleaner|better|simpler|prefer|like|want)\b).*\?/is,
             body
           ))
    end)
  end
end
