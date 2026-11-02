defmodule SymphonyElixir.Factory.StageSchemas do
  @moduledoc """
  JSON schemas for the durable outputs produced by factory Codex tasks.

  The controller treats these responses as untrusted input and performs its
  own digest, Git, Jira, and GitLab read-back checks before advancing a run.
  """

  @string_list %{"type" => "array", "items" => %{"type" => "string"}}

  @doc "Requires every declared producer field without changing durable output validation."
  @spec for_provider(map()) :: map()
  def for_provider(schema) when is_map(schema), do: normalize_provider_schema(schema)

  defp normalize_provider_schema(value) when is_map(value) do
    normalized = Map.new(value, fn {key, child} -> {key, normalize_provider_schema(child)} end)

    case normalized do
      %{"type" => "object", "properties" => properties} when is_map(properties) ->
        required = Map.get(normalized, "required", [])
        missing = properties |> Map.keys() |> Enum.reject(&(&1 in required)) |> Enum.sort()
        Map.put(normalized, "required", required ++ missing)

      _ ->
        normalized
    end
  end

  defp normalize_provider_schema(value) when is_list(value), do: Enum.map(value, &normalize_provider_schema/1)
  defp normalize_provider_schema(value), do: value

  @doc "Returns the strict structured-output schema for a factory stage."
  @spec for_stage(atom()) :: map()
  def for_stage(:specification_author) do
    object(
      ~w(status contract_markdown questions risk risk_signals manual_validation_required),
      %{
        "status" => enum(~w(DRAFTED BLOCKED)),
        "contract_markdown" => string(),
        "questions" => @string_list,
        "risk" => string(),
        "risk_signals" => @string_list,
        "manual_validation_required" => %{"type" => "boolean"}
      }
    )
  end

  def for_stage(:specification_critic) do
    object(~w(status findings required_questions), %{
      "status" => enum(~w(PASS REPAIR BLOCK)),
      "findings" => @string_list,
      "required_questions" => @string_list
    })
  end

  def for_stage(:feature_planner) do
    object(~w(status plan_markdown blockers), %{
      "status" => enum(~w(PLANNED BLOCKED)),
      "plan_markdown" => string(),
      "blockers" => @string_list
    })
  end

  def for_stage(:feature_writer) do
    object(~w(status summary commit_sha remaining_criteria blockers checks), %{
      "status" => enum(~w(CONTINUE COMPLETE BLOCKED)),
      "summary" => string(),
      "commit_sha" => nullable_string(),
      "remaining_criteria" => @string_list,
      "blockers" => @string_list,
      "checks" => @string_list
    })
  end

  def for_stage(:native_feature_writer) do
    object(~w(status changed_paths commit_message blockers checks), %{
      "status" => enum(~w(CONTINUE COMPLETE BLOCKED)),
      "summary" => string(),
      "changed_paths" => @string_list,
      "commit_message" => nullable_string(),
      "remaining_criteria" => @string_list,
      "next_slice" => string(),
      "blockers" => @string_list,
      "checks" => @string_list
    })
  end

  def for_stage(:change_verifier) do
    object(~w(status candidate_sha findings checks), %{
      "status" => enum(~w(PASS REPAIR BLOCK)),
      "candidate_sha" => string(),
      "findings" => @string_list,
      "checks" => @string_list
    })
  end

  def for_stage(:manual_validator) do
    object(
      ~w(
        status candidate_sha evidence_markdown findings human_action environment
        slack_claim_ts slack_release_confirmed teardown_confirmed synthetic_data_only
      ),
      %{
        "status" => enum(~w(PASS RETRY REPAIR BLOCK)),
        "candidate_sha" => string(),
        "evidence_markdown" => string(),
        "findings" => @string_list,
        "human_action" => nullable_string(),
        "environment" => nullable_string(),
        "slack_claim_ts" => nullable_string(),
        "slack_release_confirmed" => %{"type" => "boolean"},
        "teardown_confirmed" => %{"type" => "boolean"},
        "synthetic_data_only" => %{"type" => "boolean"}
      }
    )
  end

  def for_stage(:jira_snapshot) do
    object(~w(status issue_key snapshot_json), %{
      "status" => enum(~w(PASS BLOCK)),
      "issue_key" => string(),
      "snapshot_json" => %{"type" => ["string", "object", "array"]}
    })
  end

  def for_stage(:jira_write) do
    object(~w(status issue_key operation comment_id labels readback_text), %{
      "status" => enum(~w(PASS BLOCK)),
      "issue_key" => string(),
      "operation" => string(),
      "comment_id" => nullable_string(),
      "labels" => @string_list,
      "readback_text" => string()
    })
  end

  def for_stage(:gitlab_mr) do
    object(
      ~w(status mr_url iid source_branch target_branch sha draft reviewers_count assignee_id state),
      %{
        "status" => enum(~w(PASS BLOCK)),
        "mr_url" => string(),
        "iid" => %{"type" => "integer"},
        "source_branch" => string(),
        "target_branch" => string(),
        "sha" => string(),
        "draft" => %{"type" => "boolean"},
        "reviewers_count" => %{"type" => "integer"},
        "assignee_id" => %{"type" => "integer"},
        "state" => string()
      }
    )
  end

  def for_stage(:gitlab_ci_status) do
    object(
      ~w(status mr_url iid source_branch target_branch sha draft reviewers_count assignee_id mr_state
         pipeline_id pipeline_url pipeline_sha pipeline_ref pipeline_source pipeline_status required_jobs findings),
      %{
        "status" => enum(~w(PASS WAIT REPAIR BLOCK)),
        "mr_url" => string(),
        "iid" => %{"type" => "integer"},
        "source_branch" => string(),
        "target_branch" => string(),
        "sha" => string(),
        "draft" => %{"type" => "boolean"},
        "reviewers_count" => %{"type" => "integer"},
        "assignee_id" => %{"type" => "integer"},
        "mr_state" => string(),
        "pipeline_id" => %{"type" => ["integer", "null"]},
        "pipeline_url" => nullable_string(),
        "pipeline_sha" => nullable_string(),
        "pipeline_ref" => nullable_string(),
        "pipeline_source" => nullable_string(),
        "pipeline_status" => string(),
        "required_jobs" => %{
          "type" => "array",
          "items" =>
            object(~w(id name status web_url), %{
              "id" => %{"type" => "integer"},
              "name" => string(),
              "status" => string(),
              "web_url" => string()
            })
        },
        "findings" => @string_list
      }
    )
  end

  def for_stage(:gitlab_feedback_reply) do
    object(~w(status feedback_key reply_id reply_body reason), %{
      "status" => enum(~w(REPLIED CHANGE_REQUEST BLOCK STALE)),
      "feedback_key" => string(),
      "reply_id" => nullable_string(),
      "reply_body" => nullable_string(),
      "reason" => string()
    })
  end

  def for_stage(:gitlab_feedback_batch) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["results"],
      "properties" => %{
        "results" => %{"type" => "array", "items" => for_stage(:gitlab_feedback_reply)}
      }
    }
  end

  def for_stage(:cleanup_authorization) do
    object(~w(status candidates), %{
      "status" => enum(~w(PASS BLOCK)),
      "candidates" => %{
        "type" => "array",
        "items" =>
          object(~w(run_id issue_key jira_status mr_state), %{
            "run_id" => string(),
            "issue_key" => string(),
            "jira_status" => nullable_string(),
            "mr_state" => nullable_string()
          })
      }
    })
  end

  def for_stage(:native_worktree_probe) do
    object(~w(status run_id task_key thread_id writer_turn_id worktree candidate_sha source_cwd artifact_id artifact_identity_key reason), %{
      "status" => enum(~w(SUPPORTED UNAVAILABLE AMBIGUOUS)),
      "run_id" => string(),
      "task_key" => string(),
      "thread_id" => string(),
      "writer_turn_id" => string(),
      "worktree" => string(),
      "candidate_sha" => string(),
      "source_cwd" => string(),
      "artifact_id" => nullable_string(),
      "artifact_identity_key" => nullable_string(),
      "reason" => string()
    })
  end

  def for_stage(:native_maintenance_evidence) do
    binding =
      object(
        ~w(run_id task_key thread_id writer_turn_id codex_project_id worktree candidate_sha source_cwd),
        Map.new(~w(run_id task_key thread_id writer_turn_id codex_project_id worktree candidate_sha source_cwd), &{&1, string()})
      )

    object(~w(version provenance request_key binding tool artifact_output emitter_sha256), %{
      "version" => %{"type" => "integer", "enum" => [1]},
      "provenance" => enum(["TARGET_ATTESTED_NATIVE_CHAT"]),
      "request_key" => string(),
      "emitter_sha256" => string(),
      "binding" => binding,
      "tool" => enum(["mcp__codex_app__list_artifacts"]),
      "artifact_output" => object(["artifacts"], %{"artifacts" => %{"type" => "array", "items" => %{"type" => "object"}}})
    })
  end

  def for_stage(:native_maintenance_command_proof) do
    command =
      object(~w(type id command cwd status exitCode output), %{
        "type" => enum(["commandExecution"]),
        "id" => string(),
        "command" => string(),
        "cwd" => string(),
        "status" => enum(["completed"]),
        "exitCode" => %{"type" => "integer", "enum" => [0]},
        "durationMs" => %{"type" => "integer"},
        "output" => object(~w(text truncated), %{"text" => string(), "truncated" => %{"type" => "boolean", "enum" => [false]}})
      })

    object(~w(thread_id turn_id turn_status command_item), %{
      "thread_id" => string(),
      "turn_id" => string(),
      "turn_status" => enum(["completed"]),
      "command_item" => command
    })
  end

  @doc "Checks a decoded stage result against the supported strict JSON-schema subset."
  @spec validate(map(), map()) :: :ok | {:error, :factory_stage_output_schema_mismatch}
  def validate(output, schema) when is_map(output) and is_map(schema) do
    if valid_value?(output, schema), do: :ok, else: {:error, :factory_stage_output_schema_mismatch}
  end

  defp valid_value?(value, schema) do
    (not Map.has_key?(schema, "anyOf") or Enum.any?(schema["anyOf"], &valid_value?(value, &1))) and
      valid_type?(value, Map.get(schema, "type")) and
      valid_enum?(value, Map.get(schema, "enum")) and
      valid_object?(value, schema) and
      valid_array?(value, schema)
  end

  defp valid_type?(_value, nil), do: true
  defp valid_type?(value, types) when is_list(types), do: Enum.any?(types, &valid_type?(value, &1))
  defp valid_type?(value, "object"), do: is_map(value)
  defp valid_type?(value, "array"), do: is_list(value)
  defp valid_type?(value, "string"), do: is_binary(value)
  defp valid_type?(value, "boolean"), do: is_boolean(value)
  defp valid_type?(value, "integer"), do: is_integer(value)
  defp valid_type?(nil, "null"), do: true
  defp valid_type?(_value, _type), do: false

  defp valid_enum?(_value, nil), do: true
  defp valid_enum?(value, values) when is_list(values), do: value in values
  defp valid_enum?(_value, _values), do: false

  defp valid_object?(value, schema) when is_map(value) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    Enum.all?(required, &Map.has_key?(value, &1)) and
      (Map.get(schema, "additionalProperties") != false or
         Enum.all?(Map.keys(value), &Map.has_key?(properties, &1))) and
      Enum.all?(value, fn {key, field} ->
        case Map.fetch(properties, key) do
          {:ok, field_schema} -> valid_value?(field, field_schema)
          :error -> true
        end
      end)
  end

  defp valid_object?(_value, _schema), do: true

  defp valid_array?(value, schema) when is_list(value) do
    case Map.get(schema, "items") do
      nil -> true
      item_schema -> Enum.all?(value, &valid_value?(&1, item_schema))
    end
  end

  defp valid_array?(_value, _schema), do: true

  defp object(required, properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }
  end

  defp string, do: %{"type" => "string"}
  defp nullable_string, do: %{"type" => ["string", "null"]}
  defp enum(values), do: %{"type" => "string", "enum" => values}
end
