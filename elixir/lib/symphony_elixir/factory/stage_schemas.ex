defmodule SymphonyElixir.Factory.StageSchemas do
  @moduledoc """
  JSON schemas for the durable outputs produced by factory Codex tasks.

  The controller treats these responses as untrusted input and performs its
  own digest, Git, Jira, and GitLab read-back checks before advancing a run.
  """

  @string_list %{"type" => "array", "items" => %{"type" => "string"}}

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
      "snapshot_json" => string()
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
      ~w(status mr_url iid source_branch target_branch sha draft reviewers_count state),
      %{
        "status" => enum(~w(PASS BLOCK)),
        "mr_url" => string(),
        "iid" => %{"type" => "integer"},
        "source_branch" => string(),
        "target_branch" => string(),
        "sha" => string(),
        "draft" => %{"type" => "boolean"},
        "reviewers_count" => %{"type" => "integer"},
        "state" => string()
      }
    )
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
