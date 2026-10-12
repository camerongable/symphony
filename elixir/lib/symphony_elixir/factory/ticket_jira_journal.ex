defmodule SymphonyElixir.Factory.TicketJiraJournal do
  @moduledoc "Two fixed Jira effects with durable uncertainty; storage receipts never authorize dispatch or external writes."
  alias SymphonyElixir.Factory.{RunLedger, Store, TicketChat, TicketPush, WorkspaceAccess}

  @fields ~w(run_id issue_key execution_mode spec_revision contract_sha256 repo_key repo_path worktree branch candidate_sha mr_url state verifier_round)
  @semantic ~w(run_id issue_key spec_revision contract_sha256 candidate_sha mr_url)
  @review_v2_prefix "ticket-jira:v2:"
  @checkout_fields ~w(path git_dir common_dir root_device root_inode)
  @phases ~w(FIRST_PENDING FIRST_UNCERTAIN SECOND_PENDING SECOND_UNCERTAIN COMPLETE)

  @doc "Records an immutable effect pair after the caller has independently qualified its authority and checkout."
  @type first_effect :: String.t() | :already_in_dev
  @spec prepare(Store.connection(), String.t(), String.t(), first_effect(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(store, run_id, operation, first, checkout) do
    transaction(store, fn tx ->
      with {:ok, run} <- RunLedger.get(tx, run_id),
           :ok <- TicketChat.ordinary_delivery_eligibility(run),
           :ok <- stage(run, operation),
           :ok <- checkout_shape(run, checkout),
           {:ok, effects} <- effects(run, operation, first) do
        binding = binding(tx, run) |> Map.put("checkout", checkout) |> Map.put("operation", operation)
        key = identity_key(run, operation)
        bind_or_replay(tx, key, run_id, operation, binding, effects)
      end
    end)
  end

  @doc false
  @spec select_review_operation(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def select_review_operation(store, run_id) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         {:ok, key, version, disposition, row} <- select_review_key(store, run, push) do
      {:ok,
       %{
         operation_key: key,
         identity_version: version,
         push_sha256: push.envelope_sha256,
         disposition: disposition,
         row: row
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_review_identity_unproven}
    end
  end

  @doc false
  @spec prepare_review(Store.connection(), String.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare_review(store, run_id, comment_body, checkout, selection) do
    with {:ok, run} <- RunLedger.get(store, run_id),
         {:ok, push} <- TicketPush.completed_proof(store, run_id),
         :ok <- validate_selection(store, run, push, selection) do
      prepare_review_transaction(store, run_id, comment_body, checkout, selection, run, push)
    else
      {:error, _} = error -> error
    end
  end

  defp prepare_review_transaction(store, run_id, comment_body, checkout, selection, run, push) do
    transaction(store, fn tx ->
      with {:ok, current} <- RunLedger.get(tx, run_id),
           true <- current == run or {:error, :ticket_jira_binding_changed},
           :ok <- TicketPush.validate_completed_proof(tx, run_id, push),
           :ok <- validate_selection(tx, current, push, selection),
           :ok <- TicketChat.ordinary_delivery_eligibility(current),
           :ok <- stage(current, "REVIEW_READY"),
           :ok <- checkout_shape(current, checkout),
           {:ok, effects} <- effects(current, "REVIEW_READY", comment_body),
           binding = current_review_binding(tx, current, checkout, push, selection),
           :ok <- review_binding_key(selection.operation_key, current, push, selection.identity_version) do
        bind_or_replay(tx, selection.operation_key, run_id, "REVIEW_READY", binding, effects)
      end
    end)
  end

  @doc "Returns semantic storage identity only, never mutation authority."
  @spec identity_key(map(), String.t()) :: String.t()
  def identity_key(run, operation), do: "ticket-jira:" <> hash(Jason.encode!([operation, Map.take(run, @semantic)]))

  @doc false
  @spec review_identity_key(map(), String.t()) :: String.t()
  def review_identity_key(run, push_sha) do
    identity = ["REVIEW_READY", Enum.map(@semantic, &run[&1]), run["verifier_round"], push_sha]
    @review_v2_prefix <> hash(Jason.encode!(identity))
  end

  defp select_review_key(store, run, push) do
    v2_key = review_identity_key(run, push.envelope_sha256)

    case get(store, v2_key) do
      {:ok, row} ->
        with {:ok, _} <- current(store, v2_key),
             :ok <- current_review_access(store, v2_key, run, row) do
          {:ok, v2_key, 2, :reuse, row}
        end

      {:error, :ticket_jira_operation_missing} ->
        with :ok <- prior_review_history(store, run, push, v2_key),
             do: select_legacy_review_key(store, run, push, v2_key)
    end
  end

  defp select_legacy_review_key(store, run, push, v2_key) do
    legacy_key = identity_key(run, "REVIEW_READY")

    case get(store, legacy_key) do
      {:error, :ticket_jira_operation_missing} ->
        {:ok, v2_key, 2, :new, nil}

      {:ok, row} ->
        case legacy_review_binding(store, row, run) do
          {:ok, binding} ->
            select_legacy_review_disposition(store, legacy_key, v2_key, row, binding, run, push)

          {:error, _} = error ->
            error
        end
    end
  end

  defp select_legacy_review_disposition(store, legacy_key, v2_key, row, binding, run, push) do
    if {binding["push_sha256"], binding["verifier_round"]} == {push.envelope_sha256, run["verifier_round"]} do
      current_legacy_reuse(store, legacy_key, row)
    else
      with :ok <- terminal_legacy_review(store, row, binding, run, push), do: {:ok, v2_key, 2, :new, nil}
    end
  end

  defp current_legacy_review(store, key) do
    case current(store, key) do
      {:ok, _row} -> :ok
      {:error, _} = error -> error
    end
  end

  defp legacy_review_binding(_store, row, run) do
    with true <- row["operation"] == "REVIEW_READY" and row["run_id"] == run["run_id"],
         true <- intact?(row) or {:error, :ticket_jira_receipt_corrupt},
         {:ok, binding} when is_map(binding) <- Jason.decode(row["binding_json"]),
         true <- (is_nil(binding["identity_version"]) and not Map.has_key?(binding, "review_push_sha256")) or {:error, :ticket_jira_receipt_corrupt},
         true <- identity_key(binding, "REVIEW_READY") == row["operation_key"] or {:error, :ticket_jira_receipt_corrupt},
         true <- Map.take(binding, @semantic) == Map.take(run, @semantic) or {:error, :ticket_jira_legacy_review_changed},
         {:ok, effects} when is_list(effects) <- Jason.decode(row["effects_json"]),
         true <- receipts_consistent?(row, binding, effects) or {:error, :ticket_jira_receipt_corrupt},
         historical = Map.merge(run, Map.take(binding, @fields)),
         true <- valid_effect_pair?(historical, row["operation"], effects) or {:error, :ticket_jira_receipt_corrupt} do
      {:ok, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_receipt_corrupt}
    end
  end

  defp current_legacy_reuse(store, key, row) do
    with :ok <- current_legacy_review(store, key),
         {:ok, access} <- WorkspaceAccess.get(store, key),
         true <-
           {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {row["run_id"], "MAINTENANCE", key, nil} or {:error, :ticket_jira_legacy_review_ownership_unproven} do
      cond do
        is_nil(access["released_at"]) and row["phase"] in @phases ->
          {:ok, key, 1, :reuse, row}

        not is_nil(access["released_at"]) and row["phase"] == "COMPLETE" ->
          {:error, :ticket_jira_same_generation_released}

        true ->
          {:error, :ticket_jira_legacy_review_unresolved}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp terminal_legacy_review(store, row, binding, run, push) do
    with true <- row["phase"] == "COMPLETE" or {:error, :ticket_jira_legacy_review_unresolved},
         true <-
           (is_binary(binding["push_sha256"]) and binding["push_sha256"] != push.envelope_sha256) or
             {:error, :ticket_jira_legacy_review_unresolved},
         true <-
           (is_integer(binding["verifier_round"]) and binding["verifier_round"] < run["verifier_round"]) or
             {:error, :ticket_jira_legacy_review_unresolved},
         true <- released_operation?(store, row) or {:error, :ticket_jira_legacy_review_unproven} do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp prior_review_history(store, run, push, current_key) do
    rows = Store.query!(store, "SELECT * FROM ticket_jira_effects WHERE run_id = ? AND operation = 'REVIEW_READY' AND operation_key != ?", [run["run_id"], current_key])

    Enum.reduce_while(rows.rows, :ok, fn values, :ok ->
      row = Map.new(Enum.zip(rows.columns, values))

      case prior_review_history_step(store, row, push, run) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp prior_review_history_step(store, row, push, run) do
    with {:ok, binding} <- historical_review_binding(store, row, run) do
      prior_review_history_entry(store, row, binding, push, run)
    end
  end

  defp prior_review_history_entry(store, row, binding, push, run) do
    same_generation = {binding["push_sha256"], binding["verifier_round"]} == {push.envelope_sha256, run["verifier_round"]}

    cond do
      same_generation ->
        same_generation_review_history(store, row)

      row["phase"] == "COMPLETE" and released_operation?(store, row) and
        is_integer(binding["verifier_round"]) and binding["verifier_round"] < run["verifier_round"] ->
        :ok

      true ->
        {:error, :ticket_jira_legacy_review_unresolved}
    end
  end

  defp same_generation_review_history(store, row) do
    if prior_review_workspace_unreleased?(store, row) and
         row["phase"] in ["FIRST_PENDING", "FIRST_UNCERTAIN", "SECOND_PENDING", "SECOND_UNCERTAIN", "COMPLETE"],
       do: :ok,
       else: {:error, :ticket_jira_same_generation_released}
  end

  defp prior_review_workspace_unreleased?(store, row) do
    Store.one!(store, "SELECT released_at FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]])
    |> then(&is_nil((&1 || %{})["released_at"]))
  end

  defp historical_review_binding(_store, row, run) do
    with true <- row["run_id"] == run["run_id"] and row["operation"] == "REVIEW_READY",
         true <- intact?(row) or {:error, :ticket_jira_receipt_corrupt},
         {:ok, binding} when is_map(binding) <- Jason.decode(row["binding_json"]),
         {:ok, effects} when is_list(effects) <- Jason.decode(row["effects_json"]),
         true <- receipts_consistent?(row, binding, effects) or {:error, :ticket_jira_receipt_corrupt},
         historical = Map.merge(run, Map.take(binding, @fields)),
         true <- valid_effect_pair?(historical, row["operation"], effects) or {:error, :ticket_jira_receipt_corrupt},
         :ok <- historical_review_key(row, binding, historical) do
      {:ok, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_receipt_corrupt}
    end
  end

  defp historical_review_key(row, binding, run) do
    cond do
      is_nil(binding["identity_version"]) and not Map.has_key?(binding, "review_push_sha256") and row["operation_key"] == identity_key(run, "REVIEW_READY") ->
        :ok

      binding["identity_version"] == 2 and is_binary(binding["review_push_sha256"]) and row["operation_key"] == review_identity_key(run, binding["review_push_sha256"]) and
          binding["push_sha256"] == binding["review_push_sha256"] ->
        :ok

      true ->
        {:error, :ticket_jira_receipt_corrupt}
    end
  end

  defp current_review_binding(store, run, checkout, push, selection) do
    base = binding(store, run) |> Map.put("checkout", checkout) |> Map.put("operation", "REVIEW_READY")

    if selection.identity_version == 1 do
      base
    else
      Map.merge(base, %{"identity_version" => 2, "review_push_sha256" => push.envelope_sha256})
    end
  end

  defp review_binding_key(key, run, push, version) do
    expected = if version == 1, do: identity_key(run, "REVIEW_READY"), else: review_identity_key(run, push.envelope_sha256)
    if key == expected, do: :ok, else: {:error, :ticket_jira_review_identity_changed}
  end

  defp validate_selection(store, run, push, selection) do
    with true <- is_map(selection) or {:error, :ticket_jira_review_selection_invalid},
         {:ok, key, version, disposition, row} <- select_review_key(store, run, push),
         true <-
           {key, version, disposition, row} ==
             {selection[:operation_key], selection[:identity_version], selection[:disposition], selection[:row]} or
             {:error, :ticket_jira_review_identity_changed} do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_review_identity_changed}
    end
  end

  defp current_review_access(store, key, run, row) do
    with {:ok, access} <- WorkspaceAccess.get(store, key),
         true <-
           {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {run["run_id"], "MAINTENANCE", key, nil} or {:error, :ticket_jira_review_ownership_unproven} do
      if is_nil(access["released_at"]), do: :ok, else: released_review_access(store, key, access, row)
    else
      {:error, _} = error -> error
    end
  end

  defp released_review_access(store, key, access, row) do
    case WorkspaceAccess.validate(store, key, access["generation"]) do
      {:error, :stale_workspace_reservation} ->
        {:error, :stale_workspace_reservation}

      {:error, _} = error ->
        error

      _ ->
        released_review_phase(row)
    end
  end

  defp released_review_phase(%{"phase" => "COMPLETE"}), do: {:error, :ticket_jira_same_generation_released}
  defp released_review_phase(_row), do: {:error, :ticket_jira_review_unresolved}

  @doc "Reads a storage row only; it is not proof of live Jira or workspace availability."
  @spec get(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(store, key) do
    case Store.one!(store, "SELECT * FROM ticket_jira_effects WHERE operation_key = ?", [key]) do
      nil -> {:error, :ticket_jira_operation_missing}
      row -> {:ok, row}
    end
  end

  @doc "Checks immutable operation and receipt consistency only; never authorizes an external effect."
  @spec bound_operation(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def bound_operation(store, key), do: current(store, key)

  @doc "Keeps issued Jira effects fenced until an exact historical workspace-release receipt proves completion."
  @spec controller_busy?(Store.connection(), String.t() | nil, String.t() | nil) :: boolean()
  def controller_busy?(store, scope \\ nil, except_operation \\ nil) do
    result =
      Store.query!(
        store,
        """
        SELECT operation.* FROM ticket_jira_effects AS operation
        LEFT JOIN runs ON runs.run_id = operation.run_id
        LEFT JOIN ticket_chat_runs AS link ON link.run_id = runs.run_id
        LEFT JOIN ticket_chats AS chat ON chat.chat_key = link.chat_key
        WHERE (? IS NULL OR chat.scope_key = ? OR chat.chat_key IS NULL)
          AND (? IS NULL OR operation.operation_key != ?)
          AND (operation.phase != 'FIRST_PENDING' OR operation.first_receipt_json IS NOT NULL)
        """,
        [scope, scope, except_operation, except_operation]
      )

    Enum.any?(result.rows, fn values -> not released_operation?(store, Map.new(Enum.zip(result.columns, values))) end)
  end

  defp released_operation?(store, %{"phase" => "COMPLETE"} = row) do
    with true <- intact?(row),
         {:ok, binding} when is_map(binding) <- Jason.decode(row["binding_json"]),
         {:ok, effects} when is_list(effects) <- Jason.decode(row["effects_json"]),
         true <- valid_effect_pair?(binding, row["operation"], effects),
         true <- receipts_consistent?(row, binding, effects),
         access when is_map(access) <- Store.one!(store, "SELECT * FROM workspace_access WHERE reservation_key = ?", [row["operation_key"]]),
         true <- is_binary(access["released_at"]),
         true <-
           {access["run_id"], access["mode"], access["request_key"], access["task_key"]} ==
             {row["run_id"], "MAINTENANCE", row["operation_key"], nil},
         {:ok, receipt} <- Jason.decode(access["release_receipt_json"] || "null"),
         true <- receipt == Map.take(row, ~w(operation_key binding_sha256 effects_sha256 first_receipt_json second_receipt_json)),
         {:ok, owned} when is_map(owned) <- Jason.decode(access["binding_json"]),
         checkout when is_map(checkout) <- binding["checkout"],
         true <-
           {checkout["path"], checkout["git_dir"], checkout["common_dir"]} ==
             {access["canonical_path"], access["git_dir"], access["common_dir"]},
         true <- Map.take(checkout, ~w(root_device root_inode)) == Map.take(owned, ~w(root_device root_inode)),
         true <- owned["expected_sha"] == (binding["candidate_sha"] || binding["review_base_sha"]) do
      true
    else
      _ -> false
    end
  end

  defp released_operation?(_store, _row), do: false

  @doc "Confirms both fixed effects from fresh source readback without advancing a phase."
  @spec confirm_targets(Store.connection(), String.t(), map()) :: :ok | {:error, term()}
  def confirm_targets(store, key, observation) do
    with {:ok, row} <- current(store, key),
         {:ok, binding} <- Jason.decode(row["binding_json"]),
         :ok <- observation_shape(observation, binding) do
      row["effects_json"]
      |> Jason.decode!()
      |> Enum.reduce_while(:ok, &reduce_observed(&1, &2, observation["issue"]))
    end
  end

  defp reduce_observed(effect, :ok, issue) do
    case observed_effect(effect, issue) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc "Atomically marks exactly one pending effect uncertain; replay never returns a second mutation claim."
  @spec claim(Store.connection(), String.t()) :: {:ok, map()} | {:error, term()}
  def claim(store, key) do
    transaction(store, fn tx ->
      with {:ok, row} <- current(tx, key),
           true <- row["phase"] in ~w(FIRST_PENDING SECOND_PENDING) or {:error, :ticket_jira_effect_not_unissued} do
        phase = String.replace(row["phase"], "PENDING", "UNCERTAIN")
        Store.query!(tx, "UPDATE ticket_jira_effects SET phase = ?, updated_at = ? WHERE operation_key = ? AND phase = ?", [phase, now(), key, row["phase"]])
        get(tx, key)
      end
    end)
  end

  @doc "Advances only from fresh bounded issue readback; an absent uncertain effect remains fenced."
  @spec reconcile(Store.connection(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile(store, key, observation) do
    transaction(store, fn tx ->
      with {:ok, row} <- current(tx, key) do
        reconcile_current(tx, row, observation)
      end
    end)
  end

  defp reconcile_current(_store, %{"phase" => "COMPLETE"} = row, _observation), do: {:ok, row}

  defp reconcile_current(store, row, observation) do
    index = if row["phase"] in ~w(FIRST_PENDING FIRST_UNCERTAIN), do: 0, else: 1
    binding = Jason.decode!(row["binding_json"])
    effect = row["effects_json"] |> Jason.decode!() |> Enum.at(index)

    with :ok <- observation_shape(observation, binding),
         :ok <- after_claim(row, observation),
         :ok <- observed_effect(effect, observation["issue"]) do
      receipt = Jason.encode!(%{"effect_index" => index, "binding_sha256" => row["binding_sha256"], "effects_sha256" => row["effects_sha256"], "observation" => observation})
      column = if index == 0, do: "first_receipt_json", else: "second_receipt_json"
      phase = if index == 0, do: "SECOND_PENDING", else: "COMPLETE"
      Store.query!(store, "UPDATE ticket_jira_effects SET #{column} = ?, phase = ?, updated_at = ? WHERE operation_key = ? AND phase = ?", [receipt, phase, now(), row["operation_key"], row["phase"]])
      get(store, row["operation_key"])
    end
  end

  defp bind_or_replay(store, key, run_id, operation, binding, effects) do
    raw = Jason.encode!(binding)
    effects_raw = Jason.encode!(effects)

    case get(store, key) do
      {:error, :ticket_jira_operation_missing} ->
        Store.query!(
          store,
          "INSERT INTO ticket_jira_effects(operation_key, run_id, operation, binding_json, binding_sha256, effects_json, effects_sha256, phase, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'FIRST_PENDING', ?, ?)",
          [key, run_id, operation, raw, hash(raw), effects_raw, hash(effects_raw), now(), now()]
        )

        get(store, key)

      {:ok, row} ->
        if {row["binding_json"], row["binding_sha256"], row["effects_json"], row["effects_sha256"]} == {raw, hash(raw), effects_raw, hash(effects_raw)},
          do: current(store, key),
          else: {:error, :ticket_jira_intent_changed}
    end
  end

  defp current(store, key) do
    with {:ok, row} <- get(store, key),
         true <- intact?(row) or {:error, :ticket_jira_receipt_corrupt},
         {:ok, binding} when is_map(binding) <- Jason.decode(row["binding_json"]),
         {:ok, effects} when is_list(effects) <- Jason.decode(row["effects_json"]),
         true <- receipts_consistent?(row, binding, effects) or {:error, :ticket_jira_receipt_corrupt},
         {:ok, run} <- RunLedger.get(store, row["run_id"]),
         true <- valid_effect_pair?(run, row["operation"], effects) or {:error, :ticket_jira_receipt_corrupt},
         :ok <- current_binding(store, key, run, binding),
         :ok <- TicketChat.ordinary_delivery_eligibility(run) do
      {:ok, row}
    else
      {:error, _} = error -> error
      _ -> {:error, :ticket_jira_receipt_corrupt}
    end
  end

  defp current_binding(store, key, run, binding) do
    base = binding(store, run)

    if String.starts_with?(key, @review_v2_prefix),
      do: current_v2_binding(store, key, run, binding, base),
      else: current_legacy_binding(binding, base)
  end

  defp current_v2_binding(store, key, run, binding, base) do
    with {:ok, push} <- TicketPush.completed_proof(store, run["run_id"]),
         expected = Map.merge(base, %{"identity_version" => 2, "review_push_sha256" => push.envelope_sha256}),
         true <- key == review_identity_key(run, push.envelope_sha256) or {:error, :ticket_jira_binding_changed},
         true <- Map.take(binding, Map.keys(expected)) == expected or {:error, :ticket_jira_binding_changed},
         true <- binding["operation"] == "REVIEW_READY" or {:error, :ticket_jira_binding_changed},
         :ok <-
           if(checkout_shape(run, binding["checkout"]) == :ok,
             do: :ok,
             else: {:error, :jira_workspace_binding_unproven}
           ) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp current_legacy_binding(binding, base) do
    if base == Map.take(binding, @fields ++ ~w(review_base_sha push_sha256)),
      do: :ok,
      else: {:error, :ticket_jira_binding_changed}
  end

  defp valid_effect_pair?(run, "START_IMPLEMENTATION", [%{"kind" => "TRANSITION", "transition_id" => id}, _] = stored) do
    case effects(run, "START_IMPLEMENTATION", id || :already_in_dev) do
      {:ok, expected} -> stored == expected
      _ -> false
    end
  end

  defp valid_effect_pair?(run, "REVIEW_READY", [%{"kind" => "COMMENT", "body" => body}, _] = stored) do
    case effects(run, "REVIEW_READY", body) do
      {:ok, expected} -> stored == expected
      _ -> false
    end
  end

  defp valid_effect_pair?(_run, _operation, _stored), do: false

  defp receipts_consistent?(row, binding, effects) do
    first = row["first_receipt_json"]
    second = row["second_receipt_json"]

    case row["phase"] do
      phase when phase in ~w(FIRST_PENDING FIRST_UNCERTAIN) -> is_nil(first) and is_nil(second)
      phase when phase in ~w(SECOND_PENDING SECOND_UNCERTAIN) -> receipt_valid?(first, row, binding, effects, 0) and is_nil(second)
      "COMPLETE" -> receipt_valid?(first, row, binding, effects, 0) and receipt_valid?(second, row, binding, effects, 1)
    end
  end

  defp receipt_valid?(raw, row, binding, effects, index) when is_binary(raw) do
    with {:ok, receipt} when is_map(receipt) <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(receipt)) == ~w(binding_sha256 effect_index effects_sha256 observation),
         true <- {receipt["effect_index"], receipt["binding_sha256"], receipt["effects_sha256"]} == {index, row["binding_sha256"], row["effects_sha256"]},
         {:ok, _} <- observation_identity(receipt["observation"], binding),
         :ok <- observed_effect(Enum.at(effects, index), receipt["observation"]["issue"]) do
      true
    else
      _ -> false
    end
  end

  defp receipt_valid?(_raw, _row, _binding, _effects, _index), do: false

  defp after_claim(%{"phase" => phase, "updated_at" => at}, observation) when phase in ~w(FIRST_UNCERTAIN SECOND_UNCERTAIN) do
    with {:ok, claimed, _} <- DateTime.from_iso8601(at),
         {:ok, observed, _} <- DateTime.from_iso8601(observation["observed_at"]),
         true <- DateTime.compare(observed, claimed) != :lt do
      :ok
    else
      _ -> {:error, :ticket_jira_readback_before_claim}
    end
  end

  defp after_claim(_row, _observation), do: :ok

  defp intact?(row) do
    row["phase"] in @phases and hash(row["binding_json"]) == row["binding_sha256"] and
      hash(row["effects_json"]) == row["effects_sha256"]
  end

  defp binding(store, run) do
    base = Store.one!(store, "SELECT base_sha FROM ticket_review_bases WHERE run_id = ?", [run["run_id"]])
    push = if is_binary(run["candidate_handoff"]), do: hash(run["candidate_handoff"]), else: nil
    Map.take(run, @fields) |> Map.put("review_base_sha", (base || %{})["base_sha"]) |> Map.put("push_sha256", push)
  end

  defp stage(%{"state" => "ADMITTING_WRITER"}, "START_IMPLEMENTATION"), do: :ok
  defp stage(%{"state" => "MR_CREATING", "candidate_sha" => sha, "mr_url" => url}, "REVIEW_READY") when is_binary(sha) and is_binary(url) and url != "", do: :ok
  defp stage(_run, _operation), do: {:error, :ticket_jira_stage_not_admitted}

  defp checkout_shape(run, checkout) when is_map(checkout) do
    valid =
      Enum.sort(Map.keys(checkout)) == Enum.sort(@checkout_fields) and checkout["path"] == run["worktree"] and
        Enum.all?(~w(path git_dir common_dir), &(is_binary(checkout[&1]) and checkout[&1] != "")) and
        Enum.all?(~w(root_device root_inode), &(is_integer(checkout[&1]) and checkout[&1] >= 0))

    if valid, do: :ok, else: {:error, :ticket_jira_checkout_binding_invalid}
  end

  defp checkout_shape(_run, _checkout), do: {:error, :ticket_jira_checkout_binding_invalid}

  defp effects(run, "START_IMPLEMENTATION", id) when is_binary(id) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, id),
      do: {:ok, [%{"kind" => "TRANSITION", "issue_key" => run["issue_key"], "transition_id" => id, "status" => "In Dev"}, labels(run, "ai-running", ~w(ai-ready ai-verifying))]},
      else: {:error, :ticket_jira_first_effect_invalid}
  end

  defp effects(run, "START_IMPLEMENTATION", :already_in_dev),
    do: {:ok, [%{"kind" => "TRANSITION", "issue_key" => run["issue_key"], "transition_id" => nil, "status" => "In Dev"}, labels(run, "ai-running", ~w(ai-ready ai-verifying))]}

  defp effects(run, "REVIEW_READY", body) when is_binary(body) and byte_size(body) > 0 and byte_size(body) <= 65_536,
    do: {:ok, [%{"kind" => "COMMENT", "issue_key" => run["issue_key"], "body" => body}, labels(run, "ai-review", ~w(ai-ready ai-running ai-verifying))]}

  defp effects(_run, _operation, _first), do: {:error, :ticket_jira_first_effect_invalid}

  defp labels(run, add, remove), do: %{"kind" => "LABELS", "issue_key" => run["issue_key"], "add_labels" => [add], "remove_labels" => remove}

  defp observation_shape(observation, binding) do
    with {:ok, at} <- observation_identity(observation, binding),
         age = DateTime.diff(DateTime.utc_now(), at, :millisecond),
         true <- age >= 0 and age <= 60_000 do
      :ok
    else
      _ -> {:error, :ticket_jira_readback_unproven}
    end
  end

  defp observation_identity(observation, binding) when is_map(observation) do
    with true <- Enum.sort(Map.keys(observation)) == ~w(issue observed_at source),
         true <- observation["source"] == "Jira/get_issue" and is_map(observation["issue"]),
         true <- observation["issue"]["key"] == binding["issue_key"],
         timestamp when is_binary(timestamp) <- observation["observed_at"],
         {:ok, at, _} <- DateTime.from_iso8601(timestamp),
         {:ok, raw} <- Jason.encode(observation),
         true <- byte_size(raw) <= 1_048_576 do
      {:ok, at}
    else
      _ -> {:error, :ticket_jira_readback_unproven}
    end
  end

  defp observation_identity(_observation, _binding), do: {:error, :ticket_jira_readback_unproven}

  defp observed_effect(%{"kind" => "TRANSITION", "status" => status}, %{"status" => status}), do: :ok

  defp observed_effect(%{"kind" => "LABELS"} = effect, %{"labels" => labels}) when is_list(labels) do
    if Enum.all?(labels, &is_binary/1) and Enum.all?(effect["add_labels"], &(&1 in labels)) and not Enum.any?(effect["remove_labels"], &(&1 in labels)),
      do: :ok,
      else: {:error, :ticket_jira_effect_not_observed}
  end

  defp observed_effect(%{"kind" => "COMMENT", "body" => body}, %{"comments" => comments}) when is_list(comments) and length(comments) < 100 do
    if Enum.all?(comments, &valid_comment?/1) do
      case Enum.filter(comments, &(comment_text(&1) == body)) do
        [_matching] -> :ok
        [] -> {:error, :ticket_jira_effect_not_observed}
        _ -> {:error, :ticket_jira_comment_readback_ambiguous}
      end
    else
      {:error, :ticket_jira_comment_readback_ambiguous}
    end
  end

  defp observed_effect(_effect, _issue), do: {:error, :ticket_jira_effect_not_observed}

  defp valid_comment?(%{"id" => id} = comment), do: is_binary(id) and id != "" and is_binary(comment_text(comment))
  defp valid_comment?(_comment), do: false

  defp comment_text(%{"text" => text}) when is_binary(text), do: text
  defp comment_text(%{"text" => _text}), do: nil
  defp comment_text(%{"body" => body}) when is_binary(body), do: body
  defp comment_text(_comment), do: nil

  defp hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp transaction(store, operation) do
    case Exqlite.transaction(store, &rollback_error(&1, operation.(&1))) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_error(tx, {:error, reason}), do: Exqlite.rollback(tx, reason)
  defp rollback_error(_tx, result), do: result
end
